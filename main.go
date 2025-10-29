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
	diskPath      = filepath.FromSlash("C:/Users/mirao/VirtualBox VMs/Discos/APACHE PLANTILLA.vdi")
	dnsServerIP   = "192.168.56.11"
	dnsZone       = "grid.lab"
	dnsRevZone    = "56.168.192.in-addr.arpa"
	tsigKeyName   = "ddns-key"
	tsigSecret    = "hZ/c3VtNSShEc99TepE588evLVrsODotHd9rtLzO1iE="
	sshUser       = "unix"
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

func ensureProvisionScript() (string, error) {
	bat := filepath.Join(scriptsDir, "provision_apache.bat")
	if _, err := os.Stat(bat); err == nil {
		return bat, nil
	}
	if err := os.MkdirAll(scriptsDir, 0755); err != nil {
		return "", err
	}
	content := `@echo off
setlocal enabledelayedexpansion
set "VM_NAME=%~1"
set "SERVER_IP=%~2"
set "APACHE_DISK=%~3"
if "!VM_NAME!"=="" exit /b 1
if "!SERVER_IP!"=="" exit /b 1
if "!APACHE_DISK!"=="" exit /b 1
REM crear VM basica Debian_64
VBoxManage createvm --name "!VM_NAME!" --ostype "Debian_64" --register
VBoxManage modifyvm "!VM_NAME!" --memory 1024 --cpus 1 --nic1 hostonly --hostonlyadapter1 "VirtualBox Host-Only Ethernet Adapter" --nic2 nat
REM iniciar y apagar para generar MAC
VBoxManage startvm "!VM_NAME!" --type headless
timeout /t 10 /nobreak >nul
VBoxManage controlvm "!VM_NAME!" poweroff
timeout /t 5 /nobreak >nul
REM adjuntar disco plantilla Apache
call "%~dp0UnirMaquinaDisco.bat" "!APACHE_DISK!" "!VM_NAME!" "SATA"
if errorlevel 1 exit /b 2
REM reservar IP por MAC via script existente
call "%~dp0configurarIPs.bat" "!VM_NAME!" "!SERVER_IP!"
if errorlevel 1 exit /b 3
REM encender VM
VBoxManage startvm "!VM_NAME!" --type headless
exit /b 0
`
	return bat, os.WriteFile(bat, []byte(content), 0644)
}

func run(_ string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func scpTo(ip, local, remote string) error {
	return run("scp", "scp", local, fmt.Sprintf("%s@%s:%s", sshUser, ip, remote))
}

func sshRun(ip string, remoteCmd string) error {
	return run("ssh", "ssh", fmt.Sprintf("%s@%s", sshUser, ip), remoteCmd)
}

func nsupdateAdd(host, ip string) error {
	lines := []string{
		fmt.Sprintf("server %s", dnsServerIP),
		fmt.Sprintf("zone %s", dnsZone),
		fmt.Sprintf("update delete %s A", host),
		fmt.Sprintf("update add %s 300 A %s", host, ip),
		"send",
		fmt.Sprintf("zone %s", dnsRevZone),
		fmt.Sprintf("update delete %s PTR", revPtr(ip)),
		fmt.Sprintf("update add %s 300 PTR %s.", revPtr(ip), host+"."),
		"send",
	}
	tmp := filepath.Join(os.TempDir(), "nsupdate.txt")
	if err := os.WriteFile(tmp, []byte(strings.Join(lines, "\n")), 0600); err != nil {
		return err
	}
	defer os.Remove(tmp)
	return run("nsupdate", "nsupdate", "-y", fmt.Sprintf("hmac-sha256:%s:%s", tsigKeyName, tsigSecret), "-v", tmp)
}

func revPtr(ip string) string {
	parts := strings.Split(ip, ".")
	if len(parts) != 4 {
		return ""
	}
	return fmt.Sprintf("%s.%s.%s.%s.in-addr.arpa", parts[3], parts[2], parts[1], parts[0])
}

func provisionWorker(id string, fqdn string, zipPath string) {
	mu.Lock()
	list, _ := loadInstances()
	used := make([]string, 0, len(list))
	for _, it := range list {
		used = append(used, it.IP)
	}
	ip, err := nextIP(used)
	mu.Unlock()
	if err != nil {
		fmt.Println("no ip disponible:", err)
		return
	}

	vmName := strings.SplitN(fqdn, ".", 2)[0]

	// Usar el script crearServidor.bat existente para VM + IP + hostname + deploy
	crearScript := filepath.Join(scriptsDir, "crearServidor.bat")
	if err := run("provision", crearScript, vmName, ip, fqdn, zipPath); err != nil {
		fmt.Println("error crearServidor.bat:", err)
		return
	}
	_ = nsupdateAdd(fqdn, ip)

	mu.Lock()
	list, _ = loadInstances()
	inst := Instance{ID: id, URL: "http://" + fqdn, IP: ip, Host: fqdn, CreatedAt: time.Now().UTC().Format(time.RFC3339)}
	list = append(list, inst)
	_ = saveInstances(list)
	mu.Unlock()
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
		fqdn = fmt.Sprintf("app-%d.grid.lab", time.Now().Unix())
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

	id := fmt.Sprintf("job-%d", time.Now().UnixNano())
	go provisionWorker(id, fqdn, tmpZip)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	json.NewEncoder(w).Encode(map[string]string{"id": id})
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
