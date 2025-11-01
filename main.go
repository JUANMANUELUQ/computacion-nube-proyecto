package main

// ============================== Imports =====================================
import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ============================== Types =======================================

// Instance representa una instancia de aplicación web desplegada.
type Instance struct {
	ID        string `json:"id"`         // Identificador único de la instancia
	URL       string `json:"url"`        // URL completa de acceso (http://fqdn)
	IP        string `json:"ip"`         // Dirección IP asignada
	Host      string `json:"host"`       // FQDN completo del host
	CreatedAt string `json:"created_at"` // Fecha de creación en formato RFC3339
}

// DNSLog registra una operación DNS (agregado o eliminación de registro).
type DNSLog struct {
	Timestamp string `json:"timestamp"` // Timestamp UTC en formato RFC3339
	Action    string `json:"action"`    // "ADD" o "DELETE"
	FQDN      string `json:"fqdn"`      // Nombre de dominio completo
	IP        string `json:"ip"`        // Dirección IP asociada
}

// DNSDirectRecord representa un registro A directo leído del archivo de zona DNS.
type DNSDirectRecord struct {
	FQDN string `json:"fqdn"` // Nombre de dominio completo
	IP   string `json:"ip"`   // Dirección IPv4
}

// ============================== Config ======================================
var (
	// instancesPath ruta al archivo JSON que almacena las instancias desplegadas.
	instancesPath = filepath.FromSlash("./services/hosts.json")
	// dnsLogsPath ruta al archivo JSON que almacena los logs de operaciones DNS.
	dnsLogsPath = filepath.FromSlash("./services/dns-logs.json")
	// scriptsDir directorio que contiene los scripts batch de automatización.
	scriptsDir = filepath.FromSlash("./scripts")
	// dnsServerIP dirección IP del servidor DNS autoritativo.
	dnsServerIP = "192.168.56.11"
	// dnsZone zona DNS bajo la cual se crean los registros (ej: grid.lab).
	dnsZone = "grid.lab"
)

var (
	// mu protege el acceso concurrente a la lista de instancias.
	mu sync.Mutex
	// muLogs protege el acceso concurrente a los logs DNS.
	muLogs sync.Mutex
)

// ============================== Storage =====================================

// loadInstances carga la lista de instancias desde el archivo JSON.
// Retorna una lista vacía si el archivo no existe o está corrupto.
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

// saveInstances guarda la lista de instancias en el archivo JSON usando escritura atómica.
// Escribe primero a un archivo temporal y luego lo renombra para evitar corrupción.
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
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, instancesPath)
}

// ============================== DNS Logs Storage ============================

// loadDNSLogs carga los logs DNS desde el archivo JSON.
// Retorna una lista vacía si el archivo no existe o está corrupto.
func loadDNSLogs() ([]DNSLog, error) {
	muLogs.Lock()
	defer muLogs.Unlock()
	f, err := os.Open(dnsLogsPath)
	if err != nil {
		if os.IsNotExist(err) {
			return []DNSLog{}, nil
		}
		return nil, err
	}
	defer f.Close()
	var logs []DNSLog
	dec := json.NewDecoder(f)
	if err := dec.Decode(&logs); err != nil {
		return []DNSLog{}, nil
	}
	return logs, nil
}

// saveDNSLogs guarda los logs DNS en el archivo JSON usando escritura atómica.
func saveDNSLogs(logs []DNSLog) error {
	muLogs.Lock()
	defer muLogs.Unlock()
	tmp := dnsLogsPath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	if err := enc.Encode(logs); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dnsLogsPath)
}

// addDNSLog agrega una nueva entrada al log DNS y mantiene solo los últimos 100 registros.
// Si hay errores al guardar, los ignora silenciosamente.
func addDNSLog(action, fqdn, ip string) {
	logs, _ := loadDNSLogs()
	newLog := DNSLog{
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Action:    action,
		FQDN:      fqdn,
		IP:        ip,
	}
	logs = append(logs, newLog)
	// Mantener solo los últimos 100 logs
	if len(logs) > 100 {
		logs = logs[len(logs)-100:]
	}
	_ = saveDNSLogs(logs)
}

// ============================== Utilities ===================================

// nextIP asigna la próxima IP disponible en el rango 192.168.56.12-254,
// excluyendo las IPs ya usadas y las reservadas (.10 y .11).
// Retorna un error si no hay IPs disponibles.
func nextIP(used []string) (string, error) {
	usedSet := make(map[string]struct{}, len(used))
	for _, ip := range used {
		usedSet[ip] = struct{}{}
	}
	// Saltar 10 y 11 directamente en el loop
	for last := 12; last <= 254; last++ {
		ip := fmt.Sprintf("192.168.56.%d", last)
		if _, ok := usedSet[ip]; !ok {
			return ip, nil
		}
	}
	return "", errors.New("sin IP disponible en 192.168.56.12-254")
}

// run ejecuta un comando externo y redirige stdout y stderr a los streams del proceso actual.
// El parámetro op es ignorado (mantenido por compatibilidad con llamadas existentes).
func run(op, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// resolveIPv4 resuelve el FQDN y retorna la primera dirección IPv4 encontrada.
// Retorna un error si no se puede resolver o no hay direcciones IPv4.
func resolveIPv4(host string) (string, error) {
	ips, err := net.LookupIP(host)
	if err != nil {
		return "", fmt.Errorf("no se pudo resolver %s: %w", host, err)
	}
	for _, ip := range ips {
		if v4 := ip.To4(); v4 != nil {
			return v4.String(), nil
		}
	}
	return "", fmt.Errorf("no se encontró IPv4 para %s", host)
}

// ============================== Prepare Step ================================

// prepareSync realiza la preparación inicial: asigna una IP, crea la VM y configura DNS.
// Retorna la IP asignada, el nombre de la VM y un error si algo falla.
func prepareSync(fqdn string) (ip string, vmName string, err error) {
	// Asignar IP disponible
	mu.Lock()
	list, _ := loadInstances()
	used := make([]string, 0, len(list))
	for _, it := range list {
		used = append(used, it.IP)
	}
	ip, err = nextIP(used)
	mu.Unlock()
	if err != nil {
		return "", "", fmt.Errorf("asignación de IP: %w", err)
	}

	vmName = strings.SplitN(fqdn, ".", 2)[0]
	crear := filepath.Join(scriptsDir, "crearVMyDNS.bat")
	if err := run("prepare", crear, vmName, ip, fqdn); err != nil {
		return "", "", fmt.Errorf("crear VM falló: %w", err)
	}
	// Validar que el registro DNS A está disponible
	if err := run("nslookupA", "nslookup", fqdn, dnsServerIP); err != nil {
		return "", "", fmt.Errorf("DNS A no disponible para %s", fqdn)
	}
	// Registrar log de DNS agregado
	addDNSLog("ADD", fqdn, ip)
	return ip, vmName, nil
}

// ============================== Publish Step ================================

// publishSync despliega el contenido ZIP en la VM ya preparada y valida el servicio.
// Retorna la instancia creada o un error si el despliegue o validación falla.
func publishSync(fqdn string, zipPath string) (Instance, error) {
	var zero Instance
	// Resolver IP ya preparada (vía DNS)
	ipStr, err := resolveIPv4(fqdn)
	if err != nil {
		return zero, fmt.Errorf("resolver IP para %s: %w", fqdn, err)
	}

	// Desplegar usando script
	depl := filepath.Join(scriptsDir, "desplegarSitio.bat")
	if err := run("publish", depl, ipStr, fqdn, zipPath); err != nil {
		return zero, fmt.Errorf("despliegue falló: %w", err)
	}
	// Validación de PTR opcional: si falla, no bloquea
	_ = run("nslookupPTR", "nslookup", ipStr, dnsServerIP)

	// Validar que el servicio web responde
	client := &http.Client{Timeout: 10 * time.Second}
	// Intentar por FQDN primero
	resp, err := client.Get("http://" + fqdn + "/health.txt")
	if err != nil || resp == nil || resp.StatusCode < 200 || resp.StatusCode >= 300 {
		if resp != nil {
			resp.Body.Close()
		}
		// Fallback: por IP con Host header para que coincida el VirtualHost
		req, err := http.NewRequest("GET", "http://"+ipStr+"/health.txt", nil)
		if err != nil {
			return zero, fmt.Errorf("crear request HTTP: %w", err)
		}
		req.Host = fqdn
		resp2, err2 := client.Do(req)
		if err2 != nil {
			return zero, fmt.Errorf("servicio web no responde en %s: %w", ipStr, err2)
		}
		defer resp2.Body.Close()
		if resp2.StatusCode < 200 || resp2.StatusCode >= 300 {
			return zero, fmt.Errorf("servicio web HTTP %d en %s", resp2.StatusCode, ipStr)
		}
	} else {
		defer resp.Body.Close()
	}

	// Crear y guardar instancia
	inst := Instance{
		ID:        fmt.Sprintf("job-%d", time.Now().UnixNano()),
		URL:       "http://" + fqdn,
		IP:        ipStr,
		Host:      fqdn,
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
	}
	mu.Lock()
	list, _ := loadInstances()
	list = append(list, inst)
	_ = saveInstances(list)
	mu.Unlock()
	return inst, nil
}

// ============================== HTTP Handlers ===============================

// handlePrepare maneja POST /prepare para preparar una nueva instancia (crear VM y DNS).
// Espera un form field "hostname" (opcional, se auto-genera si está vacío).
// Retorna JSON con {"fqdn": "...", "ip": "..."} o un error.
func handlePrepare(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseMultipartForm(64 << 20); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
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

// handlePublish maneja POST /publish para desplegar contenido en una instancia preparada.
// Espera form fields "hostname" (requerido) y "file" (archivo ZIP).
// Retorna JSON con la instancia creada o un error.
func handlePublish(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseMultipartForm(64 << 20); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	fqdn := strings.TrimSpace(r.FormValue("hostname"))
	if fqdn == "" {
		http.Error(w, "hostname requerido", http.StatusBadRequest)
		return
	}
	if !strings.Contains(fqdn, ".") {
		fqdn = fqdn + "." + dnsZone
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, "archivo .zip requerido", http.StatusBadRequest)
		return
	}
	defer file.Close()
	if !strings.HasSuffix(strings.ToLower(header.Filename), ".zip") {
		http.Error(w, "el archivo debe ser .zip", http.StatusBadRequest)
		return
	}

	// Guardar archivo temporal
	tmpDir := filepath.Join(os.TempDir(), "uploads")
	if err := os.MkdirAll(tmpDir, 0755); err != nil {
		http.Error(w, "error creando directorio temporal", http.StatusInternalServerError)
		return
	}
	tmpZip := filepath.Join(tmpDir, fmt.Sprintf("%d_%s", time.Now().UnixNano(), header.Filename))
	out, err := os.Create(tmpZip)
	if err != nil {
		http.Error(w, "error creando archivo temporal", http.StatusInternalServerError)
		return
	}
	if _, err := io.Copy(out, file); err != nil {
		out.Close()
		os.Remove(tmpZip)
		http.Error(w, "error guardando archivo", http.StatusInternalServerError)
		return
	}
	if err := out.Close(); err != nil {
		os.Remove(tmpZip)
		http.Error(w, "error cerrando archivo", http.StatusInternalServerError)
		return
	}

	inst, err := publishSync(fqdn, tmpZip)
	if err != nil {
		os.Remove(tmpZip)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(inst)
}

// handleInstances maneja GET /instances para listar todas las instancias desplegadas.
// Retorna JSON con un array de instancias.
func handleInstances(w http.ResponseWriter, r *http.Request) {
	list, _ := loadInstances()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(list)
}

// handleDNSLogs maneja GET /dns-logs para obtener los logs de operaciones DNS.
// Los logs están ordenados por timestamp descendente (más recientes primero).
// Retorna JSON con un array de logs DNS.
func handleDNSLogs(w http.ResponseWriter, r *http.Request) {
	logs, _ := loadDNSLogs()
	// Ordenar por timestamp descendente (más recientes primero)
	sort.Slice(logs, func(i, j int) bool {
		return logs[i].Timestamp > logs[j].Timestamp
	})
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(logs)
}

// ============================== DNS Direct (read zone file) =================

// readDNSZoneRaw lee el estado actual de la zona DNS desde el servidor DNS remoto.
// Intenta primero leer desde named_dump.db (estado en memoria), con fallback al archivo de zona.
// Retorna el contenido completo de la zona o un error si falla la conexión SSH.
func readDNSZoneRaw() (string, error) {
	sshUser := "unix"
	remoteCmd := "sudo rndc dumpdb -zones >/dev/null 2>&1 && sudo cat /var/cache/bind/named_dump.db || sudo cat /var/lib/bind/db.grid.lab"
	args := []string{
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=10",
		sshUser + "@" + dnsServerIP,
		remoteCmd,
	}
	cmd := exec.Command("ssh", args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		errMsg := err.Error()
		stderrStr := strings.TrimSpace(stderr.String())

		// Proporcionar mensajes más descriptivos según el tipo de error
		if strings.Contains(errMsg, "Connection timed out") || strings.Contains(errMsg, "timeout") {
			return "", fmt.Errorf("no se puede conectar al servidor DNS (%s); verifica que: la VM DNS esté iniciada, el servicio SSH esté activo, la IP %s sea accesible desde esta máquina", dnsServerIP, dnsServerIP)
		}
		if strings.Contains(errMsg, "Connection refused") {
			return "", fmt.Errorf("conexión rechazada al servidor DNS (%s); el servicio SSH puede no estar corriendo", dnsServerIP)
		}
		if strings.Contains(errMsg, "Host key verification failed") || strings.Contains(errMsg, "authenticity") {
			return "", fmt.Errorf("error de autenticación SSH; verifica la configuración de claves")
		}
		if strings.Contains(errMsg, "Permission denied") || strings.Contains(stderrStr, "Permission denied") {
			return "", fmt.Errorf("permisos insuficientes; verifica que el usuario '%s' tenga permisos sudo sin contraseña para rndc y lectura de archivos de zona", sshUser)
		}

		// Error genérico con detalles
		if stderrStr != "" {
			errMsg += ": " + stderrStr
		}
		return "", fmt.Errorf("error SSH a %s@%s: %s", sshUser, dnsServerIP, errMsg)
	}
	if len(out) == 0 {
		return "", fmt.Errorf("comando SSH ejecutado pero no retornó datos; verifica que el archivo de zona exista")
	}
	return string(out), nil
}

// parseDirectARecords parsea el contenido de una zona DNS y extrae solo los registros A (IPv4).
// Ignora comentarios, directivas TTL y registros de zonas inversas.
// Retorna una lista de registros A con FQDN e IP normalizados.
func parseDirectARecords(zoneContent string) []DNSDirectRecord {
	lines := strings.Split(zoneContent, "\n")
	var out []DNSDirectRecord
	for _, ln := range lines {
		s := strings.TrimSpace(ln)
		if s == "" || strings.HasPrefix(s, ";") || strings.HasPrefix(strings.ToUpper(s), "$TTL") {
			continue
		}
		if strings.Contains(strings.ToLower(s), "in-addr.arpa") {
			continue
		}
		f := strings.Fields(s)
		// Buscar índice del token "A"
		ai := -1
		for i := 0; i < len(f); i++ {
			if strings.ToUpper(f[i]) == "A" {
				ai = i
				break
			}
		}
		if ai == -1 || ai+1 >= len(f) {
			continue
		}
		// owner es el primer token no numérico y distinto de "IN" antes de "A"
		owner := ""
		for k := 0; k < ai; k++ {
			tk := f[k]
			tku := strings.ToUpper(tk)
			if tku == "IN" {
				continue
			}
			// Verificar si es numérico (TTL)
			if _, err := strconv.Atoi(tk); err == nil {
				continue
			}
			owner = tk
			break
		}
		if owner == "" && len(f) > 0 {
			owner = f[0]
		}
		ip := f[ai+1]
		fqdn := owner
		if fqdn == "@" {
			fqdn = dnsZone
		}
		fqdn = strings.TrimSuffix(fqdn, ".")
		if !strings.HasSuffix(fqdn, dnsZone) && !strings.Contains(fqdn, ".") {
			fqdn = fqdn + "." + dnsZone
		}
		if v4 := net.ParseIP(ip).To4(); v4 != nil {
			out = append(out, DNSDirectRecord{FQDN: fqdn, IP: v4.String()})
		}
	}
	return out
}

// handleDNSDirect maneja GET /dns-direct para obtener el estado actual de los registros A.
// Lee directamente del archivo de zona DNS del servidor remoto.
// Retorna JSON con un array de registros DNS directos o un objeto de error.
func handleDNSDirect(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("Content-Type", "application/json")

	txt, err := readDNSZoneRaw()
	if err != nil {
		w.WriteHeader(http.StatusBadGateway)
		json.NewEncoder(w).Encode(map[string]string{
			"error": "Error leyendo zona DNS: " + err.Error(),
		})
		return
	}
	recs := parseDirectARecords(txt)
	json.NewEncoder(w).Encode(recs)
}

// handleDestroy maneja DELETE /destroy/{id} para eliminar una instancia.
// Ejecuta el script de eliminación, limpia DNS y remueve la instancia del registro.
// Retorna 204 No Content en éxito o un error.
func handleDestroy(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// Extraer ID de la ruta
	path := strings.TrimPrefix(r.URL.Path, "/destroy/")
	id := strings.TrimSpace(path)
	if id == "" {
		http.Error(w, "id requerido", http.StatusBadRequest)
		return
	}
	mu.Lock()
	list, _ := loadInstances()
	var target *Instance
	var idx int = -1
	for i := range list {
		if list[i].ID == id {
			target = &list[i]
			idx = i
			break
		}
	}
	mu.Unlock()
	if target == nil {
		http.Error(w, "instancia no encontrada", http.StatusNotFound)
		return
	}
	// Derivar vmName del FQDN
	fqdn := target.Host
	vmName := strings.SplitN(fqdn, ".", 2)[0]
	ip := target.IP
	delScript := filepath.Join(scriptsDir, "eliminarInstancia.bat")
	if err := run("destroy", delScript, vmName, ip, fqdn); err != nil {
		http.Error(w, "error eliminando instancia", http.StatusBadGateway)
		return
	}
	// Registrar log de DNS eliminado
	addDNSLog("DELETE", fqdn, ip)
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

// main inicia el servidor HTTP y registra todas las rutas de la API.
// El servidor escucha en el puerto 8080 y sirve archivos estáticos desde ./templates.
func main() {
	http.Handle("/", http.FileServer(http.Dir("./templates")))
	http.HandleFunc("/prepare", handlePrepare)
	http.HandleFunc("/publish", handlePublish)
	http.HandleFunc("/instances", handleInstances)
	http.HandleFunc("/destroy/", handleDestroy)
	http.HandleFunc("/dns-logs", handleDNSLogs)
	http.HandleFunc("/dns-direct", handleDNSDirect)

	fmt.Println("Servidor web en http://localhost:8080")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		fmt.Println("Error al iniciar el servidor:", err)
	}
}
