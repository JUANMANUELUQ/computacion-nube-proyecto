@echo off
REM ================================================================================
REM  Script: configurarIPsDB.bat
REM ================================================================================
REM Descripcion: Configura IPs fijas para VMs de base de datos en la red Host-Only 
REM              de VirtualBox mediante reservas DHCP.
REM              Especializado para instancias del sistema DBaaS.
REM
REM Uso:
REM   %~n0 "VM1" "IP1" "VM2" "IP2" [...]
REM
REM Parametros:
REM   VM1, VM2, ...  Nombres de las VMs de base de datos [REQ]
REM   IP1, IP2, ...  Direcciones IP a asignar (formato: xxx.xxx.xxx.xxx) [REQ]
REM
REM Ejemplos:
REM   %~n0 "dbinst1" "192.168.56.21" "dbinst2" "192.168.56.22"
REM   %~n0 "dbinst1" "192.168.56.21"
REM
REM ================================================================================

setlocal enabledelayedexpansion

REM Configurar directorio de scripts
set "SCRIPT_DIR=%~dp0"

echo ================================================================================
echo      CONFIGURAR IPs FIJAS PARA INSTANCIAS DE BASE DE DATOS
echo ================================================================================
echo.

REM Verificar que se proporcionaron parametros
if "%~1"=="" (
    echo ERROR: No se especificaron parametros.
    echo.
    echo Uso: %~n0 "VM1" "IP1" "VM2" "IP2" [...]
    echo.
    echo Ejemplos:
    echo   %~n0 "dbinst1" "192.168.56.21" "dbinst2" "192.168.56.22"
    echo   %~n0 "dbinst1" "192.168.56.21"
    echo.
    exit /b 1
)

echo [INFO] Parametros recibidos:
echo %~1 %~2 %~3 %~4 %~5 %~6 %~7 %~8
echo.

REM ================================================================================
REM SECCION 1: PROCESAMIENTO DE PARAMETROS
REM ================================================================================
echo [INFO] Procesando parametros...

REM Inicializar contador de VMs
set IDX=1

:LOOP
REM Verificar si hay mas parametros
if "%~1"=="" goto END

REM Almacenar nombre de VM e IP
echo Procesando: %~1 - %~2

REM Validar formato de IP para base de datos
call "!SCRIPT_DIR!validate_ip.bat" "%~2" "VM %~1"
if errorlevel 1 exit /b 1

set "VM[!IDX!]=%~1"
set "IP[!IDX!]=%~2"

REM Avanzar a los siguientes parametros
shift
shift
set /a IDX+=1
goto LOOP

:END
REM Calcular total de VMs procesadas
set /a TOTAL=%IDX%-1
echo.
echo [INFO] Total VMs de base de datos a configurar: %TOTAL%
echo.

REM ================================================================================
REM SECCION 2: CONFIGURACION DE RESERVAS DHCP
REM ================================================================================
echo [INFO] Configurando reservas DHCP para instancias de base de datos...

REM Iterar sobre cada VM y configurar su IP fija
for /L %%i in (1,1,%TOTAL%) do (
    echo.
    echo [%%i/%TOTAL%] Configurando !VM[%%i]!...
    
    REM Obtener direccion MAC de la VM
    echo   Obteniendo direccion MAC...
    call "!SCRIPT_DIR!get_mac.bat" "!VM[%%i]!" MAC_RESULT
    
    if defined MAC_RESULT (
        echo   MAC encontrada: !MAC_RESULT!
        
        REM Configurar reserva DHCP
        echo   Configurando reserva DHCP para IP !IP[%%i]!...
        VBoxManage dhcpserver modify --network="HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter" --mac-address=!MAC_RESULT! --fixed-address=!IP[%%i]!
        
        if errorlevel 0 (
            echo   OK: !VM[%%i]! configurado con IP !IP[%%i]!
        ) else (
            echo   ERROR: Fallo al configurar reserva DHCP para !VM[%%i]!
        )
    ) else (
        echo   ERROR: No se pudo obtener MAC para !VM[%%i]!
        echo   Verifica que la VM exista y tenga un adaptador de red configurado.
    )
)

REM ================================================================================
REM SECCION 3: REINICIO DEL SERVIDOR DHCP
REM ================================================================================
echo.
echo [INFO] Reiniciando servidor DHCP...
VBoxManage dhcpserver restart --network="HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter"

if errorlevel 0 (
    echo Servidor DHCP reiniciado exitosamente.
) else (
    echo ERROR: Fallo al reiniciar servidor DHCP.
)


echo.
echo ================================================================================
echo      CONFIGURACION DE BASE DE DATOS COMPLETADA
echo ================================================================================
echo.
echo [RESUMEN] Se configuraron %TOTAL% VM(s) de base de datos con IPs fijas.
echo.
echo [IMPORTANTE] Las VMs deben reiniciarse para obtener las nuevas IPs.
echo.
echo [SIGUIENTE PASO]
echo   Las instancias de base de datos estan listas para ser utilizadas.
echo   Registra las IPs asignadas en tu sistema de gestion DBaaS.
echo.
exit /b 0


