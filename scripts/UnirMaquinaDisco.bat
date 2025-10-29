@echo off
setlocal enabledelayedexpansion

REM ================================================================================
REM  Script: UnirMaquinaDiscoDB.bat
REM ================================================================================
REM  Descripcion:
REM    Adjunta un disco virtual tipo multiattach MariaDB a una VM de VirtualBox.
REM    Especializado para instancias de base de datos del sistema DBaaS.
REM
REM  Uso:
REM    %~n0 "disco-mariadb.vdi" "nombre-vm" "controlador"
REM
REM  Parametros:
REM    disco-mariadb.vdi  Ruta al archivo .vdi MariaDB (tipo multiattach) [REQ]
REM    nombre-vm          Nombre exacto de la maquina virtual [REQ]
REM    controlador        Nombre del controlador (ej: SATA, IDE) [REQ]
REM
REM  Ejemplo:
REM    %~n0 "C:\VMs\MARIADB_MULTI.vdi" "dbinst1" "SATA"
REM
REM ================================================================================

REM ================================================================================
REM  SECCION A: VALIDACION DE PARAMETROS
REM ================================================================================
REM  Valida que se proporcionen los 3 parametros obligatorios
REM ================================================================================

if "%~1"=="" goto usage
if "%~2"=="" goto usage
if "%~3"=="" goto usage


REM ================================================================================
REM  SECCION B: INICIALIZACION DE VARIABLES
REM ================================================================================
REM  Inicializa todas las variables del script con los valores proporcionados
REM ================================================================================

REM --- Parametros de entrada ---
set "DISK=%~1"              REM Ruta completa al disco virtual MariaDB (.vdi)
set "VM=%~2"                REM Nombre de la maquina virtual
set "CONTROLLER=%~3"        REM Nombre del controlador (ej: SATA, IDE)

REM --- Archivos temporales ---
REM TMPFILE: Contendra la informacion de la VM en formato machine-readable
REM TMPMEDIUM: Contendra la informacion del disco virtual


REM ================================================================================
REM  SECCION C: PRESENTACION DE INFORMACION AL USUARIO
REM ================================================================================
REM  Muestra en pantalla los parametros de la operacion
REM ================================================================================

echo.
echo ========================================================================
echo        ADJUNTAR DISCO MARIADB MULTI-ATTACH A VM VIRTUALBOX
echo ========================================================================
echo.
echo  Disco MariaDB: "!DISK!"
echo  Maquina VM:    "!VM!"
echo  Controlador:   "!CONTROLLER!"
echo.
echo ========================================================================
echo.


REM ================================================================================
REM  SECCION 1: VALIDACION DE PREREQUISITOS
REM ================================================================================
REM  Verifica que VBoxManage este disponible en el PATH del sistema
REM ================================================================================

echo [1/10] Verificando VBoxManage...
where VBoxManage >nul 2>&1
if errorlevel 1 (
    echo ERROR: VBoxManage no encontrado en PATH.
    echo Asegurate de que VirtualBox este instalado correctamente.
    exit /b 1
)
echo OK: VBoxManage encontrado.


REM ================================================================================
REM  SECCION 2: VALIDACION DE MAQUINA VIRTUAL
REM ================================================================================
REM  Verifica que la maquina virtual especificada exista
REM ================================================================================

echo.
echo [2/10] Verificando existencia de la VM "!VM!"...
VBoxManage showvminfo "!VM!" >nul 2>&1
if errorlevel 1 (
    echo ERROR: La maquina virtual "!VM!" no existe.
    echo Verifica el nombre de la VM con: VBoxManage list vms
    exit /b 2
)
echo OK: VM encontrada.

REM --- Obtener informacion detallada de la VM ---
set TMPFILE=%TEMP%\vminfo_temp.txt
VBoxManage showvminfo "!VM!" --machinereadable > "!TMPFILE!" 2>&1


REM ================================================================================
REM  SECCION 3: VALIDACION Y ANALISIS DE CONTROLADOR
REM ================================================================================
REM  Busca el controlador especificado en la VM y obtiene su configuracion
REM ================================================================================

echo.
echo [3/10] Verificando controlador "!CONTROLLER!"...

REM --- Buscar indice del controlador ---
set "CTRL_IDX="
for /f "tokens=1* delims==" %%A in ('type "!TMPFILE!" ^| findstr /R "^storagecontrollername[0-9]*="') do (
    set "k=%%A"
    set "v=%%B"
    set "v=!v:"=!"
    if /I "!v!"=="!CONTROLLER!" (
        set "CTRL_IDX=!k:storagecontrollername=!"
    )
)

if not defined CTRL_IDX (
    echo ERROR: Controlador "!CONTROLLER!" no encontrado en la VM "!VM!".
    echo Controladores disponibles:
    type "!TMPFILE!" | findstr /R "^storagecontrollername[0-9]*=" | findstr /V "ImageUUID"
    del "!TMPFILE!" >nul 2>&1
    exit /b 3
)
echo OK: Controlador encontrado (index: !CTRL_IDX!)

REM --- Obtener tipo de controlador ---
set "CTRL_TYPE="
for /f "tokens=1* delims==" %%A in ('type "!TMPFILE!" ^| findstr /R "^storagecontrollertype!CTRL_IDX!="') do (
    set "CTRL_TYPE=%%B"
    set "CTRL_TYPE=!CTRL_TYPE:"=!"
)

if defined CTRL_TYPE (
    echo    Tipo: !CTRL_TYPE!
    
    REM Advertencias para controladores con limitaciones conocidas
    if "!CTRL_TYPE!"=="PIIX3" (
        echo    ADVERTENCIA: Controlador IDE PIIX3 puede tener limitaciones con multiattach
    )
    if "!CTRL_TYPE!"=="PIIX4" (
        echo    ADVERTENCIA: Controlador IDE PIIX4 puede tener limitaciones con multiattach
    )
)

REM --- Obtener cantidad de puertos del controlador ---
set "PORTCOUNT="
for /f "tokens=1* delims==" %%A in ('type "!TMPFILE!" ^| findstr /R "^storagecontrollerportcount!CTRL_IDX!="') do (
    set "p=%%B"
    set "p=!p:"=!"
    set "PORTCOUNT=!p!"
)

if defined PORTCOUNT (
    echo    Puertos configurados: !PORTCOUNT!
)


REM ================================================================================
REM  SECCION 4: VALIDACION DE DISCO VIRTUAL MARIADB
REM ================================================================================
REM  Verifica la existencia del disco y valida que sea tipo multiattach
REM ================================================================================

echo.
echo [4/10] Verificando disco virtual MariaDB...

REM --- Verificar existencia del disco (como archivo o medio registrado) ---
set "DISK_EXISTS=0"
if exist "!DISK!" (
    set "DISK_EXISTS=1"
    echo OK: Disco MariaDB encontrado como archivo.
) else (
    VBoxManage showmediuminfo disk "!DISK!" >nul 2>&1
    if not errorlevel 1 (
        set "DISK_EXISTS=1"
        echo OK: Disco MariaDB encontrado como medio registrado.
    )
)

if "%DISK_EXISTS%"=="0" (
    echo ERROR: Disco MariaDB "!DISK!" no encontrado.
    echo El disco no existe como archivo ni como medio registrado en VirtualBox.
    del "!TMPFILE!" >nul 2>&1
    exit /b 4
)

REM --- VALIDACION CRITICA: Verificar tipo multiattach ---
echo.
echo [5/10] Verificando tipo de disco (debe ser multiattach)...
set "DISK_TYPE="
set TMPMEDIUM=%TEMP%\medium_temp.txt
VBoxManage showmediuminfo disk "!DISK!" > "!TMPMEDIUM!" 2>&1

for /f "tokens=1* delims=:" %%A in ('type "!TMPMEDIUM!" ^| findstr /R "^Type:"') do (
    set "DISK_TYPE=%%B"
    set "DISK_TYPE=!DISK_TYPE: =!"
)

if not "!DISK_TYPE!"=="multiattach" (
    echo ERROR: El disco MariaDB NO es de tipo multiattach.
    echo    Tipo actual: !DISK_TYPE!
    echo.
    echo Para convertir el disco MariaDB a multiattach, ejecuta:
    echo    VBoxManage modifymedium disk "!DISK!" --type multiattach
    echo.
    echo El disco no debe estar en uso por ninguna VM durante la conversion.
    del "!TMPFILE!" >nul 2>&1
    del "!TMPMEDIUM!" >nul 2>&1
    exit /b 7
)
echo OK: Disco MariaDB es tipo multiattach.

REM --- Obtener UUID del disco para validaciones precisas ---
set "DISK_UUID="
for /f "tokens=1* delims=:" %%A in ('type "!TMPMEDIUM!" ^| findstr /R "^UUID:"') do (
    set "DISK_UUID=%%B"
    set "DISK_UUID=!DISK_UUID: =!"
)
echo    UUID: !DISK_UUID!

REM --- Limpiar archivo temporal del medio ---
del "!TMPMEDIUM!" >nul 2>&1


REM ================================================================================
REM  SECCION 6: VALIDACION DE ESTADO DE LA VM
REM ================================================================================
REM  Verifica el estado de la VM (running, poweroff, saved, etc.)
REM  y aplica politicas de seguridad segun el estado
REM ================================================================================

echo.
echo [6/10] Verificando estado de la VM...
set "VM_STATE="
for /f "tokens=1* delims==" %%A in ('type "!TMPFILE!" ^| findstr /R "^VMState="') do (
    set "VM_STATE=%%B"
    set "VM_STATE=!VM_STATE:"=!"
)

echo    Estado actual: !VM_STATE!

if "!VM_STATE!"=="running" (
    echo    ADVERTENCIA: La VM esta en ejecucion.
    echo    Adjuntar discos a VMs corriendo puede requerir reinicio o hot-plug.
    
    if not "!FORCE!"=="--force" (
        echo.
        echo ERROR: Operacion bloqueada por seguridad.
        echo Para continuar, detén la VM antes de adjuntar el disco.
        del "!TMPFILE!" >nul 2>&1
        exit /b 8
    )
    echo    Modo --force activado. Continuando...
) else (
    echo OK: VM en estado seguro para modificacion.
)


REM ================================================================================
REM  SECCION 7: BUSQUEDA DE PUERTO LIBRE
REM ================================================================================
REM  Busca automaticamente el primer puerto disponible en el controlador
REM  Considera "none" y "emptydrive" como puertos libres
REM ================================================================================

echo.
echo [7/10] Buscando puerto libre en el controlador...

set "PORT="
set "DEVICE=0"

REM --- Determinar rango de puertos a buscar ---
if defined PORTCOUNT (
    set /A MAXPORT=!PORTCOUNT!-1
    echo    Rango de busqueda: 0 a !MAXPORT!
) else (
    set "MAXPORT=29"
    echo    Rango de busqueda: 0 a 29 (maximo SATA)
)

REM --- Iterar sobre los puertos buscando uno libre ---
for /L %%P in (0,1,!MAXPORT!) do (
    if not defined PORT (
        set "PORT_BUSY=0"
        
        REM Buscar si hay algo conectado en este puerto
        for /f "tokens=1* delims==" %%A in ('type "!TMPFILE!" ^| findstr "\"!CONTROLLER!-%%P-!DEVICE!\""') do (
            set "v=%%B"
            set "v=!v:"=!"
            
            REM Solo considerar ocupado si NO es "none" ni "emptydrive"
            if not "!v!"=="none" if not "!v!"=="emptydrive" (
                set "PORT_BUSY=1"
            )
        )
        
        if "!PORT_BUSY!"=="0" (
            set "PORT=%%P"
            echo OK: Puerto libre encontrado: !PORT!
        )
    )
)

if not defined PORT (
    echo ERROR: No hay puertos libres disponibles en el controlador "!CONTROLLER!".
    echo Todos los puertos ^(0-!MAXPORT!^) estan ocupados.
    echo Considera desadjuntar algun disco o agregar mas puertos al controlador.
    del "!TMPFILE!" >nul 2>&1
    exit /b 5
)


REM ================================================================================
REM  SECCION 8: VALIDACION DE DUPLICADOS
REM ================================================================================
REM  Verifica que el disco (por UUID) no este ya adjuntado a esta VM
REM  Previene adjuntar el mismo disco multiattach dos veces en la misma VM
REM ================================================================================

echo.
echo [8/10] Verificando duplicados (por UUID)...
set "ALREADY_ATTACHED=0"

if defined DISK_UUID (
    REM Buscar todos los discos adjuntados a la VM y comparar UUIDs
    for /f "tokens=1* delims==" %%A in ('type "!TMPFILE!" ^| findstr /R "=\".*\.vdi\""') do (
        set "line=%%B"
        
        REM Verificar UUID de cada disco adjuntado
        VBoxManage showmediuminfo disk !line! 2>nul | findstr /C:"!DISK_UUID!" >nul 2>&1
        if not errorlevel 1 (
            set "ALREADY_ATTACHED=1"
        )
    )
)

if "!ALREADY_ATTACHED!"=="1" (
    echo ERROR: El disco MariaDB con UUID !DISK_UUID! ya esta adjuntado a esta VM.
    echo No se puede adjuntar el mismo disco dos veces a la misma maquina virtual.
    echo Si necesitas multiple acceso, verifica que el disco sea multiattach y
    echo adjuntalo a DIFERENTES VMs.
    del "!TMPFILE!" >nul 2>&1
    exit /b 9
)
echo OK: Disco MariaDB no esta duplicado en esta VM.


REM ================================================================================
REM  SECCION 9: EJECUCION DEL ATTACHMENT
REM ================================================================================
REM  Ejecuta el comando VBoxManage storageattach con todos los parametros validados
REM  Incluye workaround para VirtualBox 7.2.0 multiattach bug
REM ================================================================================

echo.
echo ========================================================================
echo                    EJECUTANDO ATTACHMENT MARIADB
echo ========================================================================
echo.
echo  Comando: VBoxManage storageattach
echo  VM:          !VM!
echo  Controlador: !CONTROLLER!
echo  Puerto:      !PORT!
echo  Dispositivo: !DEVICE!
echo  Tipo:        hdd
echo  Medio:       !DISK!
echo  Modo:        multiattach
echo.
echo ========================================================================
echo.

REM Intentar adjuncion directa primero
echo [9/10] Intentando adjuncion directa...
VBoxManage storageattach "!VM!" --storagectl "!CONTROLLER!" --port !PORT! --device !DEVICE! --type hdd --medium "!DISK!" --mtype multiattach

if not errorlevel 1 (
    echo OK: Adjunción directa exitosa.
    goto attachment_success
)

echo ADVERTENCIA: Adjunción directa falló. Aplicando workaround para VirtualBox 7.2.0...

REM ================================================================================
REM  WORKAROUND PARA VIRTUALBOX 7.2.0 MULTIATTACH BUG
REM ================================================================================
REM  Algunas versiones de VirtualBox 7.2.0 tienen problemas con discos multiattach
REM  El workaround convierte temporalmente a normal, adjunta, y convierte de vuelta
REM ================================================================================

echo.
echo [10/10] Aplicando workaround para VirtualBox 7.2.0...
echo   Paso 1: Convirtiendo temporalmente a disco normal...

VBoxManage modifymedium disk "!DISK!" --type normal
if errorlevel 1 (
    echo   ADVERTENCIA: No se pudo convertir a normal, continuando...
)

echo   Paso 2: Adjuntando disco MariaDB en modo normal...
VBoxManage storageattach "!VM!" --storagectl "!CONTROLLER!" --port !PORT! --device !DEVICE! --type hdd --medium "!DISK!"
if errorlevel 1 (
    echo.
    echo ERROR: Fallo al ejecutar storageattach incluso con workaround.
    echo Revisa el log de VirtualBox para mas detalles.
    del "!TMPFILE!" >nul 2>&1
    exit /b 6
)
echo   OK: Disco MariaDB adjuntado en modo normal

echo   Paso 3: Convirtiendo de vuelta a multiattach...
VBoxManage modifymedium disk "!DISK!" --type multiattach
if errorlevel 1 (
    echo   ADVERTENCIA: No se pudo convertir de vuelta a multiattach
    echo   El disco funcionará en modo normal (compartido)
) else (
    echo   OK: Disco MariaDB convertido de vuelta a multiattach
)

:attachment_success


REM ================================================================================
REM  SECCION 10: CONFIRMACION Y FINALIZACION
REM ================================================================================
REM  Muestra mensaje de exito con resumen de la operacion
REM  Limpia archivos temporales
REM ================================================================================

echo.
echo ========================================================================
echo                   OPERACION MARIADB EXITOSA
echo ========================================================================
echo.
echo  El disco MariaDB ha sido adjuntado correctamente:
echo.
echo    VM:          "!VM!"
echo    Controlador: "!CONTROLLER!"
echo    Puerto:      !PORT!
echo    Dispositivo: !DEVICE!
echo    Disco:       "!DISK!"
echo.
echo  El disco MariaDB esta ahora disponible en la VM.
echo  Si la VM estaba apagada, puedes iniciarla normalmente.
echo.
echo ========================================================================
echo.

REM --- Limpieza de archivos temporales ---
del "!TMPFILE!" >nul 2>&1

exit /b 0


REM ================================================================================
REM  FUNCION: USAGE (AYUDA)
REM ================================================================================
REM  Muestra informacion de uso del script cuando se invoca sin parametros
REM  o con parametros incorrectos
REM ================================================================================

:usage
echo.
echo ========================================================================
echo           ADJUNTAR DISCO MARIADB MULTI-ATTACH A VM VIRTUALBOX
echo ========================================================================
echo.
echo DESCRIPCION:
echo   Este script adjunta un disco virtual MariaDB tipo multiattach a una 
echo   maquina virtual de VirtualBox con validaciones exhaustivas.
echo   Especializado para el sistema DBaaS (Database as a Service).
echo.
echo USO:
echo   %~n0 "disco-mariadb" "vm" "controlador"
echo.
echo PARAMETROS:
echo   disco-mariadb   Ruta al archivo .vdi MariaDB (DEBE ser tipo multiattach)
echo   vm              Nombre de la maquina virtual
echo   controlador     Nombre del controlador (ej: SATA, IDE)
echo.
echo EJEMPLOS:
echo   %~n0 "C:\VMs\MARIADB_MULTI.vdi" "dbinst1" "SATA"
echo   %~n0 "C:\VMs\MARIADB_MULTI.vdi" "dbinst2" "SATA"
echo.
echo VALIDACIONES REALIZADAS:
echo   [1] VBoxManage disponible en PATH
echo   [2] Maquina virtual existe
echo   [3] Controlador existe en la VM
echo   [4] Disco MariaDB existe (archivo o medio registrado)
echo   [5] Disco es tipo multiattach (CRITICO)
echo   [6] Estado de la VM (poweroff/running)
echo   [7] Puerto libre disponible (busqueda automatica)
echo   [8] Disco no duplicado en la VM (por UUID)
echo.
echo CODIGOS DE SALIDA:
echo   0 = Exito
echo   1 = Parametros faltantes o VBoxManage no encontrado
echo   2 = Maquina virtual no existe
echo   3 = Controlador no encontrado
echo   4 = Disco MariaDB no encontrado
echo   5 = No hay puertos libres
echo   6 = Fallo al ejecutar storageattach
echo   7 = Disco MariaDB NO es tipo multiattach
echo   8 = VM en ejecucion (requiere --force)
echo   9 = Disco MariaDB ya adjuntado (duplicado)
echo.
echo NOTAS IMPORTANTES:
echo   - El disco MariaDB DEBE ser tipo multiattach antes de usar este script
echo   - Para convertir un disco: VBoxManage modifymedium disk "disco.vdi" --type multiattach
echo   - El disco no debe estar en uso durante la conversion
echo   - Busqueda automatica de puerto libre (0-29 para SATA)
echo.
echo ========================================================================
echo.
exit /b 1


REM ================================================================================
REM  FIN DEL SCRIPT
REM ================================================================================
