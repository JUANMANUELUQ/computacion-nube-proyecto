package main

// ============================== Imports =====================================
import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ============================== Types =======================================
type Instance struct {
	ID        string `json:"id"`
	URL       string `json:"url"`
	IP        string `json:"ip"`
	Host      string `json:"host"`
	CreatedAt string `json:"created_at"`
}

// ============================== Config ======================================
var (
	instancesPath = filepath.FromSlash("./services/hosts.json")
	scriptsDir    = filepath.FromSlash("./scripts")
	dnsServerIP   = "192.168.56.11"
	dnsZone       = "grid.lab"
)

var mu sync.Mutex

// ============================== Storage =====================================
func loadInstances() ([]Instance, error) {
	f, err := os.Open(instancesPath)
	if err != nil {
		if os.IsNotExist(err) {
			return []Instance{}, nil
		}
		return nil, err
	}
	defer f.Close()
	var list []Instance
	dec := json.NewDecoder(f)
	if err := dec.Decode(&list); err != nil {
		return []Instance{}, nil
	}
	return list, nil
}

func saveInstances(list []Instance) error {
	tmp := instancesPath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	if err := enc.Encode(list); err != nil {
		f.Close()
		return err
	}
	f.Close()
	return os.Rename(tmp, instancesPath)
}

// ============================== Utilities ===================================
func nextIP(used []string) (string, error) {
	usedSet := map[string]struct{}{}
	for _, ip := range used {
		usedSet[ip] = struct{}{}
	}
	for last := 12; last <= 254; last++ {
		ip := fmt.Sprintf("192.168.56.%d", last)
		if ip == "192.168.56.10" || ip == "192.168.56.11" {
			continue
		}
		if _, ok := usedSet[ip]; !ok {
			return ip, nil
		}
	}
	return "", errors.New("sin IP disponible en 192.168.56.12-254")
}

func run(_ string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func resolveIPv4(host string) (string, error) {
	ips, err := net.LookupIP(host)
	if err != nil {
		return "", err
	}
	for _, ip := range ips {
		if v4 := ip.To4(); v4 != nil {
			return v4.String(), nil
		}
	}
	return "", fmt.Errorf("no IPv4 for %s", host)
}

// ============================== Prepare Step ================================
func prepareSync(fqdn string) (string, string, error) {
	// returns ip, vmName
	mu.Lock()
	list, _ := loadInstances()
	used := make([]string, 0, len(list))
	for _, it := range list {
		used = append(used, it.IP)
	}
	ip, err := nextIP(used)
	mu.Unlock()
	if err != nil {
		return "", "", err
	}

	vmName := strings.SplitN(fqdn, ".", 2)[0]
	crear := filepath.Join(scriptsDir, "crearVMyDNS.bat")
	if err := run("prepare", crear, vmName, ip, fqdn); err != nil {
		return "", "", fmt.Errorf("prepare fallo: %w", err)
	}
	if err := run("nslookupA", "nslookup", fqdn, dnsServerIP); err != nil {
		return "", "", fmt.Errorf("DNS A no disponible para %s", fqdn)
	}
	return ip, vmName, nil
}

// ============================== Publish Step ================================
func publishSync(fqdn string, zipPath string) (Instance, error) {
	var zero Instance
	// Resolver IP ya preparada (vía DNS)
	ipStr, err := resolveIPv4(fqdn)
	if err != nil {
		return zero, fmt.Errorf("no se pudo resolver IP para %s: %w", fqdn, err)
	}

	// despliegue usando script
	zip := zipPath
	depl := filepath.Join(scriptsDir, "desplegarSitio.bat")
	if err := run("publish", depl, ipStr, fqdn, zip); err != nil {
		return zero, fmt.Errorf("deploy fallo: %w", err)
	}
	// Validación de PTR opcional: si falla, no bloquea
	_ = run("nslookupPTR", "nslookup", ipStr, dnsServerIP)
	client := &http.Client{Timeout: 10 * time.Second}
	// Intentar por FQDN primero
	resp, err := client.Get("http://" + fqdn + "/health.txt")
	if err != nil || resp.StatusCode < 200 || resp.StatusCode >= 300 {
		if resp != nil {
			resp.Body.Close()
		}
		// Fallback: por IP con Host header para que coincida el VirtualHost
		req, _ := http.NewRequest("GET", "http://"+ipStr+"/health.txt", nil)
		req.Host = fqdn
		resp2, err2 := client.Do(req)
		if err2 != nil {
			return zero, fmt.Errorf("servicio web no responde en %s", ipStr)
		}
		defer resp2.Body.Close()
		if resp2.StatusCode < 200 || resp2.StatusCode >= 300 {
			return zero, fmt.Errorf("servicio web HTTP %d en %s", resp2.StatusCode, ipStr)
		}
	} else {
		defer resp.Body.Close()
	}

	inst := Instance{ID: fmt.Sprintf("job-%d", time.Now().UnixNano()), URL: "http://" + fqdn, IP: ipStr, Host: fqdn, CreatedAt: time.Now().UTC().Format(time.RFC3339)}
	mu.Lock()
	list, _ := loadInstances()
	list = append(list, inst)
	_ = saveInstances(list)
	mu.Unlock()
	return inst, nil
}

// ============================== HTTP Handlers ===============================
func handlePrepare(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}
	if err := r.ParseMultipartForm(64 << 20); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	fqdn := strings.TrimSpace(r.FormValue("hostname"))
	if fqdn == "" {
		fqdn = fmt.Sprintf("app-%d.%s", time.Now().Unix(), dnsZone)
	}
	if !strings.Contains(fqdn, ".") {
		fqdn = fqdn + "." + dnsZone
	}
	ip, _, err := prepareSync(fqdn)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"fqdn": fqdn, "ip": ip})
}

func handlePublish(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}
	if err := r.ParseMultipartForm(64 << 20); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	fqdn := strings.TrimSpace(r.FormValue("hostname"))
	if fqdn == "" {
		http.Error(w, "hostname requerido", 400)
		return
	}
	if !strings.Contains(fqdn, ".") {
		fqdn = fqdn + "." + dnsZone
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, "archivo .zip requerido", 400)
		return
	}
	defer file.Close()
	if !strings.HasSuffix(strings.ToLower(header.Filename), ".zip") {
		http.Error(w, "el archivo debe ser .zip", 400)
		return
	}
	tmpDir := filepath.Join(os.TempDir(), "uploads")
	os.MkdirAll(tmpDir, 0755)
	tmpZip := filepath.Join(tmpDir, fmt.Sprintf("%d_%s", time.Now().UnixNano(), header.Filename))
	out, _ := os.Create(tmpZip)
	io.Copy(out, file)
	out.Close()

	inst, err := publishSync(fqdn, tmpZip)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(inst)
}

func handleInstances(w http.ResponseWriter, r *http.Request) {
	list, _ := loadInstances()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(list)
}

func handleDestroy(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", 405)
		return
	}
	// Expect /destroy/{id}
	path := strings.TrimPrefix(r.URL.Path, "/destroy/")
	id := strings.TrimSpace(path)
	if id == "" {
		http.Error(w, "id requerido", 400)
		return
	}
	mu.Lock()
	list, _ := loadInstances()
	var target *Instance
	var idx int
	for i := range list {
		if list[i].ID == id {
			target = &list[i]
			idx = i
			break
		}
	}
	mu.Unlock()
	if target == nil {
		http.Error(w, "instancia no encontrada", 404)
		return
	}
	// Derivar vmName del FQDN
	fqdn := target.Host
	vmName := strings.SplitN(fqdn, ".", 2)[0]
	ip := target.IP
	delScript := filepath.Join(scriptsDir, "eliminarInstancia.bat")
	if err := run("destroy", delScript, vmName, ip, fqdn); err != nil {
		http.Error(w, "error eliminando instancia", 502)
		return
	}
	// Remover del hosts.json
	mu.Lock()
	list, _ = loadInstances()
	if idx >= 0 && idx < len(list) {
		list = append(list[:idx], list[idx+1:]...)
		_ = saveInstances(list)
	}
	mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

// ============================== Server ======================================
func main() {
	http.Handle("/", http.FileServer(http.Dir("./templates")))
	http.HandleFunc("/prepare", handlePrepare)
	http.HandleFunc("/publish", handlePublish)
	http.HandleFunc("/instances", handleInstances)
	http.HandleFunc("/destroy/", handleDestroy)

	fmt.Println("Servidor web en http://localhost:8080")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		fmt.Println("Error al iniciar el servidor:", err)
	}
}
