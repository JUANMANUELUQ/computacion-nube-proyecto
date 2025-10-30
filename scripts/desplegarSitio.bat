@echo off
setlocal enabledelayedexpansion
REM ==============================================================================
REM  Script: desplegarSitio.bat
REM  Despliega ZIP en VM existente y convierte el vhost en default.
REM  Uso: %~n0 "ip" "fqdn" "ruta-zip" [usuario-ssh]
REM ==============================================================================

if "%~3"=="" (
  echo USO: %~n0 "ip" "fqdn" "zip" [sshuser]
  exit /b 1
)

set "SERVER_IP=%~1"
set "FQDN=%~2"
set "ZIP_PATH=%~3"
set "SSH_USER=%~4"
if "!SSH_USER!"=="" set "SSH_USER=unix"

set "SSH_PORT=22"

if not exist "%ZIP_PATH%" (
  echo ERROR: ZIP no existe: %ZIP_PATH%
  exit /b 1
)

echo [1/2] Transfiriendo y desplegando contenido...
scp -P %SSH_PORT% -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "%ZIP_PATH%" %SSH_USER%@%SERVER_IP%:"/tmp/site.zip" 2>nul || exit /b 2
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p %SSH_PORT% %SSH_USER%@%SERVER_IP% "sudo /usr/local/bin/deploy_web.sh /tmp/site.zip %FQDN%" 2>nul || exit /b 2

echo [2/2] Estableciendo sitio como default y recargando Apache...
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p %SSH_PORT% %SSH_USER%@%SERVER_IP% "sudo a2dissite 000-default.conf >/dev/null 2>&1; sudo a2dissite '%FQDN%.conf' >/dev/null 2>&1; if [ -f '/etc/apache2/sites-available/%FQDN%.conf' ]; then sudo cp '/etc/apache2/sites-available/%FQDN%.conf' '/etc/apache2/sites-available/000-%FQDN%.conf'; fi; sudo a2ensite '000-%FQDN%.conf'; (sudo apache2ctl configtest && sudo systemctl reload apache2) || sudo systemctl restart apache2" 2>nul || exit /b 2

exit /b 0


