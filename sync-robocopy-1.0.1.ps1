<#
.SYNOPSIS
    Ingesta continua 24/7 con Robocopy (Move, Append-only).
    Versión 1.0.3
.DESCRIPTION
    Este script mueve archivos desde una cola de entrada (local) hacia un NAS.
    Garantiza que nunca se elimina nada en el destino.
    Implementa protección fail-closed, reintentos progresivos y single-instance.
#>

$Version = "1.0.3"

# ============================================================================
# CONFIGURACIÓN GENERAL (Ajustar rutas antes de usar)
# ============================================================================
$SourceDir = "C:\Ruta\ColaEntrada"      # ORIGEN (Cola local de ingesta)
$DestDir   = "\\NAS\Repositorio"        # DESTINO (NAS Append-only, ruta UNC)
$LogFile   = "C:\Ruta\Logs\sync-robocopy.log"
$MaxLogSizeMB = 10

# Tiempos de pausa (en segundos)
$PauseNoChange = 15
$PauseChange   = 10
$PauseError    = 60
$MaxConsecutiveErrors = 5
$PausePersistentError = 300 # 5 minutos (5 errores seguidos)
# ============================================================================

$global:IsRunning = $true
$ConsecutiveErrors = 0
$MutexName = "Global\SyncRobocopyMutex_$($SourceDir -replace '[\\:]','_')"

# 1. Single-instance (Obligatorio)
$MutexCreated = $false
$Mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$MutexCreated)
if (-not $MutexCreated) {
    Write-Host "Ya existe una instancia ejecutándose para esta ruta de origen. Saliendo para evitar conflictos."
    exit 1
}

# Función de Logging
function Write-Log {
    param(
        [Parameter(Mandatory=$true)] [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$Timestamp] [$Level] $Message"
    Write-Host $LogLine
    
    try {
        $LogDir = Split-Path $LogFile
        if ($LogDir -and -not (Test-Path $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }

        # Rotación de log (10 MB)
        if (Test-Path $LogFile) {
            $FileInfo = Get-Item $LogFile
            if ($FileInfo.Length -gt ($MaxLogSizeMB * 1024 * 1024)) {
                $BakFile = "$LogFile.bak"
                if (Test-Path $BakFile) { Remove-Item $BakFile -Force }
                Rename-Item -Path $LogFile -NewName (Split-Path $BakFile -Leaf) -Force
            }
        }
        Add-Content -Path $LogFile -Value $LogLine -ErrorAction SilentlyContinue
    } catch {
        Write-Host "[$Timestamp] [ERROR] Fallo al escribir en archivo de log: $_"
    }
}

# Notificación al usuario (Popup local)
function Show-Notification {
    param(
        [string]$Message,
        [int]$TimeOfflineMinutes
    )
    try {
        $wshell = New-Object -ComObject Wscript.Shell
        # 0x10 = Icono Crítico, 0 = Botón OK
        $FullMsg = "ALERTA DEL SISTEMA DE INGESTA`n`n$Message`n`nTiempo de desconexión: $TimeOfflineMinutes minutos."
        $wshell.Popup($FullMsg, 0, "Error de Conexión NAS", 0x10) | Out-Null
    } catch {
        Write-Log "Fallo al intentar mostrar popup de notificación: $_" "WARN"
    }
}

# Validación estricta de rutas
function Validate-Paths {
    if ([string]::IsNullOrWhiteSpace($SourceDir) -or [string]::IsNullOrWhiteSpace($DestDir)) {
        Write-Log "Error de configuración: La ruta de origen o destino está vacía." "ERROR"
        return $false
    }
    
    # Prevención de borrados masivos evitando rutas raíz peligrosas
    if ($SourceDir -match "^[a-zA-Z]:\\?$") {
        Write-Log "Protección activada: La ruta de origen es un directorio raíz ($SourceDir). Abortando por seguridad." "ERROR"
        return $false
    }
    
    if (-not (Test-Path $SourceDir)) {
        Write-Log "La ruta de origen no existe o no hay acceso: $SourceDir" "ERROR"
        return $false
    }
    return $true
}

# Comprobar conectividad y permisos del NAS
function Check-NasAvailability {
    if (-not (Test-Path $DestDir)) {
        Write-Log "Test-Path falló: La ruta $DestDir no existe o no es accesible." "WARN"
        return $false
    }
    
    # Hemos eliminado la prueba de escritura/borrado (Set-Content/Remove-Item) 
    # porque en un NAS configurado estrictamente como 'Append-Only' a nivel de permisos (sin permisos de borrado),
    # el Remove-Item falla y provocaba un falso negativo bloqueando todo el sistema.
    # Robocopy ya se encarga de probar la escritura real y abortará de forma segura si es de solo lectura.
    return $true
}

# Parada ordenada capturando Ctrl+C
try {
    [console]::TreatControlCAsInput = $true
} catch {
    # Ignorar en entornos que no soporten manipulación de consola (ej. ISE)
}

Write-Log "=== Iniciando Servicio de Ingesta Continua (v$Version) ===" "INFO"
Write-Log "Origen (A): $SourceDir" "INFO"
Write-Log "Destino (B): $DestDir" "INFO"

if (-not (Validate-Paths)) {
    Write-Log "Fallo en validación inicial de rutas. Servicio detenido." "ERROR"
    $Mutex.ReleaseMutex()
    exit 1
}

# ============================================================================
# BUCLE DE EJECUCIÓN CONTINUA (24/7)
# ============================================================================
while ($global:IsRunning) {
    
    # Comprobar si se pulsó Ctrl+C en la consola
    try {
        if ([console]::KeyAvailable) {
            $key = [console]::ReadKey($true)
            if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'C') {
                Write-Log "Señal de interrupción (Ctrl+C) recibida. Finalizando de forma segura..." "INFO"
                $global:IsRunning = $false
                continue
            }
        }
    } catch { }

    $WaitTime = $PauseNoChange

    # FAIL-CLOSED: Validar accesibilidad del NAS ANTES de llamar a robocopy
    if (-not (Check-NasAvailability)) {
        $ConsecutiveErrors++
        Write-Log "NAS inaccesible o en solo lectura ($DestDir). FAIL-CLOSED ACTIVADO: Operaciones de movimiento bloqueadas." "ERROR"
        
        if ($ConsecutiveErrors -ge $MaxConsecutiveErrors) {
            $WaitTime = $PausePersistentError
            $TimeOfflineMinutes = ($ConsecutiveErrors * $PauseError) / 60
            
            Write-Log "Fallo persistente detectado ($ConsecutiveErrors ciclos). Generando notificación de usuario." "WARN"
            Show-Notification -Message "El NAS no está accesible. No se están ingiriendo archivos." -TimeOfflineMinutes $TimeOfflineMinutes
        } else {
            $WaitTime = $PauseError
        }
        
        Write-Log "Esperando $WaitTime segundos antes de reintentar conexión..." "INFO"
        Start-Sleep -Seconds $WaitTime
        continue
    }

    # Evento de recuperación (Backoff recovery)
    if ($ConsecutiveErrors -gt 0) {
        Write-Log "Conexión con el NAS recuperada con éxito." "INFO"
        $ConsecutiveErrors = 0
    }

    # ============================================================================
    # PARÁMETROS ROBOCOPY
    # /MOVE : Corta en A y pega en B (Borrado local condicionado a éxito de copia)
    # /E    : Mantiene estructura incluyendo subdirectorios vacíos
    # /COPYALL   : Copia todo (Datos, Atributos, Timestamps, ACL, Owner, Auditoría)
    # /DCOPY:DAT : Copia atributos y fechas de los directorios
    # /MT:16 : Multihilo para maximizar rendimiento
    # /R:1 /W:2  : Reintentos bajos y espera corta (1 intento, 2s espera)
    # /FFT : Tolerancia FAT para fechas (útil con samba/NAS)
    # /NP  : Sin porcentaje de progreso (Reducción de ruido en logs)
    # /XJ  : Excluir puntos de unión (previene loops infinitos)
    # ============================================================================
    $RobocopyArgs = @(
        "`"$SourceDir`"", "`"$DestDir`"", "/MOVE", "/E", "/COPYALL", "/DCOPY:DAT",
        "/MT:16", "/R:1", "/W:2", "/FFT", "/NP", "/XJ"
    )

    # Exclusiones de directorios
    $RobocopyArgs += "/XD", ".stfolder", ".stversions", "`"`$RECYCLE.BIN`"", "`"System Volume Information`"", ".Trashes", ".Spotlight-V100", ".fseventsd"
    
    # Exclusiones de archivos
    $RobocopyArgs += "/XF", "*.tmp", "~*", "Thumbs.db", ".DS_Store", "desktop.ini", "*.ffs_lock", "*.ffs_db"
    
    Write-Log "Iniciando comprobación y transferencia local -> NAS..." "INFO"
    
    # Ejecutar Robocopy silenciando la ventana pero capturando salidas para log
    $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
    $ProcessInfo.FileName = "robocopy.exe"
    $ProcessInfo.Arguments = $RobocopyArgs -join " "
    $ProcessInfo.RedirectStandardOutput = $true
    $ProcessInfo.RedirectStandardError = $true
    $ProcessInfo.UseShellExecute = $false
    $ProcessInfo.CreateNoWindow = $true

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $ProcessInfo
    $Process.Start() | Out-Null
    
    $Output = $Process.StandardOutput.ReadToEnd()
    $ErrorOutput = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()

    $ExitCode = $Process.ExitCode

    # ============================================================================
    # GESTIÓN AVANZADA DE ERRORES (Bitmask Robocopy)
    # 0 = Sin cambios
    # 1 = Copiado OK
    # 2 = Extras en destino
    # 4 = Mismatch
    # 8 = Fallo en copia
    # 16 = Error crítico
    # ============================================================================
    if ($ExitCode -ge 8) {
        $ConsecutiveErrors++
        Write-Log "Robocopy finalizó con error severo (Código: $ExitCode)." "ERROR"
        
        $WaitTime = $PauseError
        
        # Clasificación adicional del error leyendo la salida
        if ($Output -match "Acceso denegado" -or $Output -match "Access is denied" -or $Output -match "ERROR 5 ") {
            Write-Log "Diagnóstico: Error de Permisos. Imposible escribir (ACL/Owner) o leer." "ERROR"
        } elseif ($Output -match "El archivo está siendo utilizado" -or $Output -match "The process cannot access the file" -or $Output -match "ERROR 32 ") {
            Write-Log "Diagnóstico: Archivo bloqueado en origen (Lock). Se reintentará en el próximo ciclo." "WARN"
            $WaitTime = $PauseChange # Es un error leve temporal, no hacemos backoff agresivo
            $ConsecutiveErrors-- # Evitar que esto gatille la alerta de NAS desconectado
        } elseif ($Output -match "No se ha encontrado la ruta" -or $Output -match "The network path was not found" -or $Output -match "ERROR 53 ") {
            Write-Log "Diagnóstico: Error de Red o Unidad desmontada durante transferencia." "ERROR"
        } else {
            Write-Log "Log Robocopy:`n$Output" "ERROR"
            if ($ErrorOutput) { Write-Log "Salida de error std:`n$ErrorOutput" "ERROR" }
        }

    } else {
        $ConsecutiveErrors = 0
        if ($ExitCode -band 1) {
            # Éxito con transferencia de archivos (Flag bit 1 encendido)
            Write-Log "Ciclo completado con transferencias exitosas (Código: $ExitCode)." "INFO"
            
            # Reducir ruido extrayendo solo las líneas relevantes de acción
            $FilteredOutput = $Output -split "`r`n" | Where-Object { $_ -match "^\s*(New (Dir|File)|Older|Newer|Changed|Extra)" }
            if ($FilteredOutput) {
                Write-Log "Resumen de operaciones:`n$($FilteredOutput -join "`n")" "INFO"
            }
            $WaitTime = $PauseChange
        } else {
            # Éxito sin transferencias (0) o solo detecciones menores (2, 4 sin 1)
            Write-Log "Ciclo completado. No se detectaron archivos nuevos para ingestar." "INFO"
            $WaitTime = $PauseNoChange
        }
    }

    # Espera adaptativa antes del siguiente ciclo
    if ($global:IsRunning) {
        Start-Sleep -Seconds $WaitTime
    }
}

# Limpieza al finalizar el proceso de forma ordenada
Write-Log "=== Parada Ordenada Completada ===" "INFO"
Write-Log "Logs y descriptores cerrados. Servicio apagado." "INFO"
if ($MutexCreated) {
    $Mutex.ReleaseMutex()
    $Mutex.Dispose()
}
