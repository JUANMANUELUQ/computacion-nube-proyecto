@echo off
setlocal enabledelayedexpansion
REM ==============================================================================
REM  Script: crearVMyDNS.bat
REM  Crea VM Apache desde plantilla, reserva IP, establece hostname y aplica DNS.
REM  NO despliega contenido web.
REM  Uso: %~n0 "nombre-vm" "ip" "fqdn" [usuario-ssh]
REM ==============================================================================

if "%~3"=="" (
  echo USO: %~n0 "nombre-vm" "ip" "fqdn" [sshuser]
  exit /b 1
)

set "VM_NAME=%~1"
set "SERVER_IP=%~2"
set "FQDN=%~3"
set "SSH_USER=%~4"
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

call "%SCRIPT_DIR%validate_ip.bat" "%SERVER_IP%" "servidor"
if errorlevel 1 exit /b 1
if not exist "%APACHE_DISK%" ( echo ERROR: No existe %APACHE_DISK% & exit /b 1 )

where VBoxManage >nul 2>&1 || (echo ERROR: VBoxManage no encontrado.& exit /b 1)
ssh -V >nul 2>&1 || (echo ERROR: ssh no encontrado.& exit /b 1)

echo [1/3] Creando VM "%VM_NAME%"...
VBoxManage showvminfo "%VM_NAME%" >nul 2>&1 && (echo ERROR: VM ya existe.& exit /b 2)
VBoxManage createvm --name "%VM_NAME%" --ostype "Debian_64" --register || exit /b 3
VBoxManage modifyvm "%VM_NAME%" --memory 1024 --cpus 1 --vram 32 --boot1 disk --boot2 none --nic1 hostonly --hostonlyadapter1 "VirtualBox Host-Only Ethernet Adapter" --nic2 nat --graphicscontroller vmsvga --audio-driver none || exit /b 3
VBoxManage startvm "%VM_NAME%" --type headless || exit /b 3
powershell -NoProfile -Command "Start-Sleep -Seconds 10"
VBoxManage controlvm "%VM_NAME%" poweroff
powershell -NoProfile -Command "Start-Sleep -Seconds 5"

echo [2/3] Adjuntando disco y reservando IP...
VBoxManage storagectl "%VM_NAME%" --name "%CONTROLADOR%" --add sata --controller IntelAhci --portcount 4 >nul 2>&1
call "%SCRIPT_DIR%UnirMaquinaDisco.bat" "%APACHE_DISK%" "%VM_NAME%" "%CONTROLADOR%" || exit /b 4
call "%SCRIPT_DIR%configurarIPs.bat" "%VM_NAME%" "%SERVER_IP%" || exit /b 5

echo [3/3] Arrancando VM y configurando hostname...
VBoxManage startvm "%VM_NAME%" --type headless || exit /b 3
powershell -NoProfile -Command "Start-Sleep -Seconds !BOOT_WAIT!"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p %SSH_PORT% %SSH_USER%@%SERVER_IP% "sudo /usr/local/bin/set_hostname.sh %FQDN%" 2>nul

REM === DNS A y PTR ===
set "LAST_OCTET="
for /f "tokens=4 delims=." %%o in ("%SERVER_IP%") do set LAST_OCTET=%%o
set "FQ_ABS=%FQDN%."
set "PTR_NAME=%LAST_OCTET%.56.168.192.in-addr.arpa."
set "NSFILE=%TEMP%\nsupdate_%RANDOM%.txt"
>"%NSFILE%" echo server %DNS_SERVER%
>>"%NSFILE%" echo zone %DNS_ZONE%
>>"%NSFILE%" echo update delete %FQ_ABS% A
>>"%NSFILE%" echo update add %FQ_ABS% 300 A %SERVER_IP%
>>"%NSFILE%" echo send
>>"%NSFILE%" echo zone %DNS_REV_ZONE%
>>"%NSFILE%" echo update delete %PTR_NAME% PTR
>>"%NSFILE%" echo update add %PTR_NAME% 300 PTR %FQ_ABS%
>>"%NSFILE%" echo send
scp -P %SSH_PORT% -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "%NSFILE%" %SSH_USER%@%DNS_SERVER%:"/tmp/nsupd.txt" 2>nul
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p %SSH_PORT% %SSH_USER%@%DNS_SERVER% "nsupdate -v -y %TSIG_ALG%:%TSIG_NAME%:%TSIG_SECRET% /tmp/nsupd.txt && rm -f /tmp/nsupd.txt"
del /f /q "%NSFILE%" >nul 2>&1
REM Forzar sincronizacion de zona a disco para reflejar cambios inmediatamente
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p %SSH_PORT% %SSH_USER%@%DNS_SERVER% "sudo rndc sync -clean %DNS_ZONE% >/dev/null 2>&1 && sudo rndc sync -clean %DNS_REV_ZONE% >/dev/null 2>&1" 2>nul
nslookup %FQDN% %DNS_SERVER% | find "%SERVER_IP%" >nul || (echo ERROR: DNS no aplicado.& exit /b 6)

REM === Snapshot de zona directa (solo registros A) para verificacion ===
echo ---DNS_DIRECT_BEGIN---
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p %SSH_PORT% %SSH_USER%@%DNS_SERVER% "sudo awk 'BEGIN{IGNORECASE=1} $0 !~ /^;/ && $0 ~ /[[:space:]]A[[:space:]]/ {print}' /var/lib/bind/db.grid.lab" 2>nul
echo ---DNS_DIRECT_END---

echo OK: Preparacion completada para %FQDN% (%SERVER_IP%)
exit /b 0


