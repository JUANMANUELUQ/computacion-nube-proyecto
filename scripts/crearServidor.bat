@echo off
setlocal enabledelayedexpansion
REM ================================================================================
REM  Script: crearServidor.bat (Apache)
REM ================================================================================
REM DESCRIPCION:
REM   Crea una VM Debian/Apache desde disco plantilla multiattach, reserva IP
REM   por MAC (configurarIPs.bat) y arranca la VM. Opcionalmente establece
REM   hostname FQDN y despliega un ZIP via deploy_web.sh
REM
REM PARAMETROS:
REM   %~n0 "nombre-vm" "ip-servidor" [fqdn] [ruta-zip] [usuario-ssh]
REM   nombre-vm   : Nombre de la VM a crear [REQ]
REM   ip-servidor : IP a reservar para la VM [REQ]
REM   fqdn        : FQDN para hostname (ej: app1.grid.lab) [OPC]
REM   ruta-zip    : ZIP a desplegar dentro de la VM [OPC]
REM   usuario-ssh : Usuario SSH (defecto: unix) [OPC]
REM
REM NOTAS:
REM   - Usa disco plantilla en: C:\Users\mirao\VirtualBox VMs\Discos\APACHE PLANTILLA.vdi
REM   - Requiere VBoxManage, ssh y scp en PATH
REM ================================================================================

REM ===================== 1) PARAMS Y PRECHECKS =====================
if "%~1"=="" (
  echo USO: %~n0 "nombre-vm" "ip" [fqdn] [zip] [sshuser]
  exit /b 1
)

set "VM_NAME=%~1"
set "SERVER_IP=%~2"
set "FQDN=%~3"
set "ZIP_PATH=%~4"
set "SSH_USER=%~5"
if "!SSH_USER!"=="" set "SSH_USER=unix"

set "SCRIPT_DIR=%~dp0"
set "APACHE_DISK=C:\Users\mirao\VirtualBox VMs\Discos\APACHE PLANTILLA.vdi"
set "CONTROLADOR=SATA"
set "SSH_PORT=22"
set "BOOT_WAIT=25"
set "DNS_SERVER=192.168.56.11"
set "DNS_ZONE=grid.lab"
set "DNS_REV_ZONE=56.168.192.in-addr.arpa"
set "TSIG_ALG=hmac-sha256"
set "TSIG_NAME=ddns-key"
set "TSIG_SECRET=hZ/c3VtNSShEc99TepE588evLVrsODotHd9rtLzO1iE="

if "!SERVER_IP!"=="" (
  echo ERROR: IP requerida.
  exit /b 1
)
call "!SCRIPT_DIR!validate_ip.bat" "!SERVER_IP!" "servidor"
if errorlevel 1 exit /b 1

if not exist "!APACHE_DISK!" (
  echo ERROR: Disco plantilla no existe: !APACHE_DISK!
  exit /b 1
)

where VBoxManage >nul 2>&1 || (echo ERROR: VBoxManage no encontrado.& exit /b 1)
ssh -V >nul 2>&1 || (echo ERROR: ssh no encontrado.& exit /b 1)
where scp >nul 2>&1 || (echo ADVERTENCIA: scp no disponible.)

REM ===================== 2) CREAR VM BASICA =====================
echo [1/5] Creando VM "!VM_NAME!"...
VBoxManage showvminfo "!VM_NAME!" >nul 2>&1 && (echo ERROR: La VM ya existe.& exit /b 2)
VBoxManage createvm --name "!VM_NAME!" --ostype "Debian_64" --register || exit /b 3
VBoxManage modifyvm "!VM_NAME!" --memory 1024 --cpus 1 --vram 32 --boot1 disk --boot2 none --nic1 hostonly --hostonlyadapter1 "VirtualBox Host-Only Ethernet Adapter" --nic2 nat --graphicscontroller vmsvga --audio-driver none || exit /b 3

echo   Inicializando para obtener MAC...
VBoxManage startvm "!VM_NAME!" --type headless || exit /b 3
powershell -NoProfile -Command "Start-Sleep -Seconds 10"
VBoxManage controlvm "!VM_NAME!" poweroff
powershell -NoProfile -Command "Start-Sleep -Seconds 5"

REM Asegurar que la VM existe y esta registrada antes de continuar
:wait_registered
VBoxManage showvminfo "!VM_NAME!" >nul 2>&1
if errorlevel 1 (
  echo   Esperando registro de VM en VirtualBox...
  powershell -NoProfile -Command "Start-Sleep -Seconds 2"
  goto wait_registered
)

REM ===================== 3) ADJUNTAR DISCO Y RESERVAR IP =====================
echo [2/5] Adjuntando disco plantilla Apache...
REM Crear controlador de almacenamiento SATA si no existe (VM nueva no lo trae)
VBoxManage storagectl "!VM_NAME!" --name "!CONTROLADOR!" --add sata --controller IntelAhci --portcount 4 >nul 2>&1
REM ignorar error si ya existia
call "!SCRIPT_DIR!UnirMaquinaDisco.bat" "!APACHE_DISK!" "!VM_NAME!" "!CONTROLADOR!" || (
  echo ERROR: No se pudo adjuntar el disco.
  exit /b 4
)

echo [3/5] Reservando IP !SERVER_IP! para "!VM_NAME!"...
call "!SCRIPT_DIR!configurarIPs.bat" "!VM_NAME!" "!SERVER_IP!" || (
  echo ERROR: No se pudo reservar IP.
  exit /b 5
)

REM ===================== 4) ARRANCAR VM Y OPCIONALES =====================
echo [4/5] Iniciando VM...
VBoxManage startvm "!VM_NAME!" --type headless || exit /b 3
echo   Esperando !BOOT_WAIT!s para boot...
powershell -NoProfile -Command "Start-Sleep -Seconds !BOOT_WAIT!"

if not "!FQDN!"=="" (
  echo   Estableciendo hostname: !FQDN!
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p !SSH_PORT! !SSH_USER!@!SERVER_IP! "sudo /usr/local/bin/set_hostname.sh !FQDN!" 2>nul
)

if not "!ZIP_PATH!"=="" (
  if exist "!ZIP_PATH!" (
    echo   Transfiriendo ZIP y desplegando...
    scp -P !SSH_PORT! -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "!ZIP_PATH!" !SSH_USER!@!SERVER_IP!:"/tmp/site.zip" 2>nul
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p !SSH_PORT! !SSH_USER!@!SERVER_IP! "sudo /usr/local/bin/deploy_web.sh /tmp/site.zip !FQDN!" 2>nul
    echo   Aplicando reload de Apache...
    REM Hacer que el VirtualHost de !FQDN! sea el "default" (000-*)
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p !SSH_PORT! !SSH_USER!@!SERVER_IP! "sudo a2dissite 000-default.conf >/dev/null 2>&1; sudo a2dissite '!FQDN!.conf' >/dev/null 2>&1; if [ -f '/etc/apache2/sites-available/!FQDN!.conf' ]; then sudo cp '/etc/apache2/sites-available/!FQDN!.conf' '/etc/apache2/sites-available/000-!FQDN!.conf'; fi; sudo a2ensite '000-!FQDN!.conf'; (sudo apache2ctl configtest && sudo systemctl reload apache2) || sudo systemctl restart apache2" 2>nul
    echo   Verificando health en la VM...
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p !SSH_PORT! !SSH_USER!@!SERVER_IP! "curl -s -H 'Host: !FQDN!' http://127.0.0.1/health.txt || true" 2>nul
  ) else (
    echo   ADVERTENCIA: ZIP no encontrado: !ZIP_PATH!
  )
)

REM ===================== 4.1) ACTUALIZAR DNS (A y PTR) =====================
if not "!FQDN!"=="" call :UPDATE_DNS "!FQDN!" "!SERVER_IP!"

REM ===================== 5) RESUMEN =====================
echo.
echo =============================================================================
echo  VM APACHE PROVISIONADA
echo =============================================================================
echo   VM:     !VM_NAME!
echo   IP:     !SERVER_IP!
if not "!FQDN!"=="" echo   Host:   !FQDN!
if not "!ZIP_PATH!"=="" echo   ZIP:    !ZIP_PATH!
echo   Estado: iniciada
echo.
exit /b 0

REM CODIGOS DE SALIDA
REM 0  OK
REM 1  Parametros/Prereqs
REM 2  VM ya existe
REM 3  Error creando/arrancando VM
REM 4  Error adjuntando disco
REM 5  Error reservando IP

REM ===================== SUBRUTINA: UPDATE_DNS =====================
:UPDATE_DNS
setlocal enabledelayedexpansion
set "FQ=%~1"
set "IP=%~2"
echo [4.1/5] Actualizando DNS (A y PTR) en !DNS_SERVER! ...
for /f "tokens=4 delims=." %%o in ("!IP!") do set "LAST_OCTET=%%o"
set "FQ_ABS=!FQ!."
set "PTR_NAME=!LAST_OCTET!.56.168.192.in-addr.arpa."

set "NSFILE=%TEMP%\nsupdate_!RANDOM!.txt"
>"!NSFILE!" echo server !DNS_SERVER!
>>"!NSFILE!" echo zone !DNS_ZONE!
>>"!NSFILE!" echo update delete !FQ_ABS! A
>>"!NSFILE!" echo update add !FQ_ABS! 300 A !IP!
>>"!NSFILE!" echo send
>>"!NSFILE!" echo zone !DNS_REV_ZONE!
>>"!NSFILE!" echo update delete !PTR_NAME! PTR
>>"!NSFILE!" echo update add !PTR_NAME! 300 PTR !FQ_ABS!
>>"!NSFILE!" echo send

scp -P !SSH_PORT! -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "!NSFILE!" !SSH_USER!@!DNS_SERVER!:"/tmp/nsupd.txt" 2>nul
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p !SSH_PORT! !SSH_USER!@!DNS_SERVER! "nsupdate -v -y !TSIG_ALG!:!TSIG_NAME!:!TSIG_SECRET! /tmp/nsupd.txt && rm -f /tmp/nsupd.txt" 

del /f /q "!NSFILE!" >nul 2>&1

set "DNS_OK=0"
nslookup !FQ! !DNS_SERVER! | find "!IP!" >nul
if not errorlevel 1 set "DNS_OK=1"
if "!DNS_OK!"=="1" (
  echo   OK: DNS aplicado para !FQ! -> !IP!
) else (
  echo   ERROR: DNS no aplicado para !FQ! en !DNS_SERVER!.
  endlocal & exit /b 6
)
endlocal & exit /b 0

