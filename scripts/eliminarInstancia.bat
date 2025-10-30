@echo off
setlocal enabledelayedexpansion
REM ============================================================================
REM  Script: eliminarInstancia.bat
REM  Elimina una instancia: borra VM de VirtualBox, limpia reserva DHCP y DNS.
REM  Uso: %~n0 "vmName" "ip" "fqdn" [sshUser]
REM ============================================================================

if "%~3"=="" (
  echo USO: %~n0 "vmName" "ip" "fqdn" [sshUser]
  exit /b 1
)

set "VM_NAME=%~1"
set "SERVER_IP=%~2"
set "FQDN=%~3"
set "SSH_USER=%~4"
if "!SSH_USER!"=="" set "SSH_USER=unix"

set "SCRIPT_DIR=%~dp0"
set "NETWORK_NAME=HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter"
set "DNS_SERVER=192.168.56.11"
set "DNS_ZONE=grid.lab"
set "DNS_REV_ZONE=56.168.192.in-addr.arpa"
set "TSIG_ALG=hmac-sha256"
set "TSIG_NAME=ddns-key"
set "TSIG_SECRET=hZ/c3VtNSShEc99TepE588evLVrsODotHd9rtLzO1iE="
set "SSH_PORT=22"

REM ===================== 1) Limpiar reserva DHCP ==============================
call "%SCRIPT_DIR%get_mac.bat" "%VM_NAME%" MAC_OUT >nul 2>&1
if defined MAC_OUT (
  echo [1/3] Eliminando reserva DHCP para !MAC_OUT! ...
  VBoxManage dhcpserver modify --network="%NETWORK_NAME%" --mac-address=!MAC_OUT! --remove >nul 2>&1
  VBoxManage dhcpserver restart --network="%NETWORK_NAME%" >nul 2>&1
) else (
  echo [1/3] No se pudo obtener MAC, continuando...
)

REM ===================== 2) Borrar VM ========================================
echo [2/3] Eliminando VM "%VM_NAME%" ...
VBoxManage controlvm "%VM_NAME%" poweroff >nul 2>&1
VBoxManage unregistervm "%VM_NAME%" --delete >nul 2>&1

REM ===================== 3) Limpiar DNS (A y PTR) ============================
echo [3/3] Limpiando DNS en %DNS_SERVER% ...
for /f "tokens=4 delims=." %%o in ("%SERVER_IP%") do set "LAST_OCTET=%%o"
set "FQ_ABS=%FQDN%."
set "PTR_NAME=%LAST_OCTET%.56.168.192.in-addr.arpa."
set "NSFILE=%TEMP%\nsupdate_del_%RANDOM%.txt"
>"%NSFILE%" echo server %DNS_SERVER%
>>"%NSFILE%" echo zone %DNS_ZONE%
>>"%NSFILE%" echo update delete %FQ_ABS% A
>>"%NSFILE%" echo send
>>"%NSFILE%" echo zone %DNS_REV_ZONE%
>>"%NSFILE%" echo update delete %PTR_NAME% PTR
>>"%NSFILE%" echo send

scp -P %SSH_PORT% -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "%NSFILE%" %SSH_USER%@%DNS_SERVER%:"/tmp/nsupd_del.txt" 2>nul
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p %SSH_PORT% %SSH_USER%@%DNS_SERVER% "nsupdate -v -y %TSIG_ALG%:%TSIG_NAME%:%TSIG_SECRET% /tmp/nsupd_del.txt && rm -f /tmp/nsupd_del.txt" 2>nul
del /f /q "%NSFILE%" >nul 2>&1

echo OK: Instancia eliminada (%VM_NAME%, %SERVER_IP%, %FQDN%)
exit /b 0


