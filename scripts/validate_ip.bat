@echo off
REM ================================================================================
REM SCRIPT: validate_ip.bat
REM ================================================================================
REM Funcion simple para validar IPs de servidores web
REM Uso: call validate_ip.bat "192.168.56.21" "servidor"
REM Retorna: exit code 0 si es valida, 1 si es invalida
REM ================================================================================

setlocal enabledelayedexpansion
set "IP_TO_VALIDATE=%~1"
set "CONTEXT=%~2"

REM Verificar que empiece con 192.168.56.
echo !IP_TO_VALIDATE! | findstr /B "192.168.56." >nul
if errorlevel 1 (
    echo ERROR: IP invalida para !CONTEXT!. Debe estar en el rango 192.168.56.x
    echo IP recibida: !IP_TO_VALIDATE!
    echo Ejemplo valido: 192.168.56.21
    endlocal
    exit /b 1
)

REM Verificar que tenga exactamente 3 puntos
set "DOT_COUNT=0"
set "TEMP_IP=!IP_TO_VALIDATE!"
:count_dots
if "!TEMP_IP!"=="" goto dots_done
if "!TEMP_IP:~0,1!"=="." set /a DOT_COUNT+=1
set "TEMP_IP=!TEMP_IP:~1!"
goto count_dots
:dots_done
if !DOT_COUNT! NEQ 3 (
    echo ERROR: IP invalida para !CONTEXT!. Debe tener formato xxx.xxx.xxx.xxx
    echo IP recibida: !IP_TO_VALIDATE!
    endlocal
    exit /b 1
)

REM Validar que el ultimo octeto este en rango valido para servidores web (20-50)
for /f "tokens=4 delims=." %%a in ("!IP_TO_VALIDATE!") do set "LAST_OCTET=%%a"
if !LAST_OCTET! LSS 1 (
    echo ERROR: IP invalida para !CONTEXT!. El ultimo octeto debe estar entre 20 y 50 para instancias de servidores web
    echo IP recibida: !IP_TO_VALIDATE!
    echo Rango recomendado: 192.168.56.20 - 192.168.56.50
    endlocal
    exit /b 1
)
if !LAST_OCTET! GTR 255 (
    echo ERROR: IP invalida para !CONTEXT!. El ultimo octeto debe estar entre 20 y 50 para instancias de servidores web
    echo IP recibida: !IP_TO_VALIDATE!
    echo Rango recomendado: 192.168.56.20 - 192.168.56.50
    endlocal
    exit /b 1
)

echo   OK: IP de !CONTEXT! valida para servidores web (!IP_TO_VALIDATE!)
endlocal
exit /b 0
