package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Instance struct {
	ID        string `json:"id"`
	URL       string `json:"url"`
	IP        string `json:"ip"`
	Host      string `json:"host"`
	CreatedAt string `json:"created_at"`
}

var (
	instancesPath = filepath.FromSlash("./services/hosts.json")
	scriptsDir    = filepath.FromSlash("./scripts")
	dnsServerIP   = "192.168.56.11"
	dnsZone       = "grid.lab"
)

var mu sync.Mutex

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

// removed obsolete helper functions (scp/ssh/nsupdate/provisionWorker) now handled in scripts

func provisionSync(fqdn string, zipPath string) (Instance, error) {
	var zero Instance
	mu.Lock()
	list, _ := loadInstances()
	used := make([]string, 0, len(list))
	for _, it := range list {
		used = append(used, it.IP)
	}
	ip, err := nextIP(used)
	mu.Unlock()
	if err != nil {
		return zero, err
	}

	vmName := strings.SplitN(fqdn, ".", 2)[0]
	crearScript := filepath.Join(scriptsDir, "crearServidor.bat")
	if err := run("provision", crearScript, vmName, ip, fqdn, zipPath); err != nil {
		return zero, fmt.Errorf("provision fallo: %w", err)
	}
	// DNS ya se aplica dentro del script crearServidor.bat; aquí solo validamos.
	if err := run("nslookupA", "nslookup", fqdn, dnsServerIP); err != nil {
		return zero, fmt.Errorf("DNS A no disponible para %s", fqdn)
	}
	// Validación de PTR opcional: si falla, no bloquea
	_ = run("nslookupPTR", "nslookup", ip, dnsServerIP)
    client := &http.Client{Timeout: 10 * time.Second}
    // Intentar por FQDN primero
    resp, err := client.Get("http://" + fqdn + "/health.txt")
    if err != nil || resp.StatusCode < 200 || resp.StatusCode >= 300 {
        if resp != nil { resp.Body.Close() }
        // Fallback: por IP con Host header para que coincida el VirtualHost
        req, _ := http.NewRequest("GET", "http://"+ip+"/health.txt", nil)
        req.Host = fqdn
        resp2, err2 := client.Do(req)
        if err2 != nil {
            return zero, fmt.Errorf("servicio web no responde en %s", ip)
        }
        defer resp2.Body.Close()
        if resp2.StatusCode < 200 || resp2.StatusCode >= 300 {
            return zero, fmt.Errorf("servicio web HTTP %d en %s", resp2.StatusCode, ip)
        }
    } else {
        defer resp.Body.Close()
    }

	inst := Instance{ID: fmt.Sprintf("job-%d", time.Now().UnixNano()), URL: "http://" + fqdn, IP: ip, Host: fqdn, CreatedAt: time.Now().UTC().Format(time.RFC3339)}
	mu.Lock()
	list, _ = loadInstances()
	list = append(list, inst)
	_ = saveInstances(list)
	mu.Unlock()
	return inst, nil
}

func handleProvision(w http.ResponseWriter, r *http.Request) {
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
	// Normalizar: si no es FQDN, agregar zona
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

	inst, err := provisionSync(fqdn, tmpZip)
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
	http.Error(w, "not implemented", 501)
}

func main() {
	http.Handle("/", http.FileServer(http.Dir("./templates")))
	http.HandleFunc("/provision", handleProvision)
	http.HandleFunc("/instances", handleInstances)
	http.HandleFunc("/destroy/", handleDestroy)

	fmt.Println("Servidor web en http://localhost:8080")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		fmt.Println("Error al iniciar el servidor:", err)
	}
}
