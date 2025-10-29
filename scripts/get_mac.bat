@echo off
REM ================================================================================
REM SCRIPT: get_mac.bat
REM ================================================================================
REM Funcion simple para obtener direccion MAC de una VM
REM Uso: call get_mac.bat "VM_NAME" MAC_RESULT
REM Retorna: exit code 0 si exitoso, 1 si fallo
REM ================================================================================

setlocal enabledelayedexpansion
set "VM_NAME=%~1"
set "RETURN_VAR=%~2"

REM Obtener MAC de la VM (formato: macaddress1="08002764FE5B")
for /f "tokens=2 delims==" %%A in ('VBoxManage showvminfo "%VM_NAME%" --machinereadable 2^>nul ^| findstr "macaddress1"') do (
    set "MAC_RAW=%%A"
    REM Quitar comillas
    set "MAC_RAW=!MAC_RAW:"=!"
)

REM Verificar si se obtuvo la MAC
if not defined MAC_RAW (
    echo   ERROR: No se pudo obtener MAC para VM !VM_NAME!
    endlocal
    exit /b 1
)

REM Convertir formato: 08002764FE5B -> 08:00:27:64:FE:5B
REM Extraer cada par de caracteres
set "P1=!MAC_RAW:~0,2!"
set "P2=!MAC_RAW:~2,2!"
set "P3=!MAC_RAW:~4,2!"
set "P4=!MAC_RAW:~6,2!"
set "P5=!MAC_RAW:~8,2!"
set "P6=!MAC_RAW:~10,2!"

REM Construir MAC con formato de dos puntos
set "MAC_FORMATTED=!P1!:!P2!:!P3!:!P4!:!P5!:!P6!"

REM Devolver el resultado usando la sintaxis correcta
endlocal & set "%RETURN_VAR%=%MAC_FORMATTED%"
exit /b 0
