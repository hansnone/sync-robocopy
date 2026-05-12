<#
.SYNOPSIS
Ingesta continua 24/7 con Robocopy: origen local -> NAS.

.VERSION
1.0.6

.DESCRIPTION
Mueve archivos desde una cola local hacia un destino NAS usando Robocopy.

Principios de diseño:
- Nunca borra contenido del destino.
- Nunca usa /MIR ni /PURGE.
- Mueve desde origen solo cuando Robocopy considera la copia correcta.
- Implementa single-instance por ruta de origen.
- Implementa logging persistente con rotación.
- Implementa pausa adaptativa.
- Implementa validación fail-closed del destino.
- Implementa parada ordenada mediante archivo de parada o Ctrl+C interactivo.
- Implementa popup local ante caída persistente del NAS.

NOTA OPERATIVA:
Para máxima seguridad, los procesos productores deberían escribir archivos con extensión temporal
por ejemplo ".tmp" y renombrarlos al nombre final solo cuando estén completamente cerrados.
#>

#requires -version 5.1

# ============================================================================
# CONFIGURACIÓN GENERAL
# ============================================================================

$Version = "1.0.6"

# ORIGEN: cola local de ingesta
$SourceDir = "C:\Ruta\ColaEntrada"

# DESTINO: NAS por ruta UNC
$DestDir = "\\NAS\Repositorio"

# LOG
$LogFile = "C:\Ruta\Logs\sync-robocopy.log"
$MaxLogSizeMB = 10

# Archivo de parada ordenada
# Si existe este archivo, el servicio termina al finalizar el ciclo actual.
$StopFile = "C:\Ruta\Logs\sync-robocopy.stop"

# Parámetros de pausa
$PauseNoChange = 15
$PauseChange = 10
$PauseError = 60
$MaxConsecutiveErrors = 5
$PausePersistentError = 300

# Notificaciones
$EnablePopupNotification = $true
$NotifyAfterNasDownMinutes = 5
$PopupCooldownMinutes = 30

# Robocopy
$Threads = 16
$Retries = 1
$WaitSeconds = 2

# Modo de copia:
# - Recomendado para NAS heterogéneo: /COPY:DAT
# - Si destino soporta ACL NTFS completas y se ejecuta con privilegios adecuados: /COPYALL
$CopyMode = "/COPY:DAT"

# Modo append-only estricto:
# Evita sobrescribir archivos existentes en destino si difieren por antigüedad o contenido.
# Los archivos que ya existan en destino quedarán pendientes en origen.
$StrictAppendOnly = $true

# Exclusiones de directorios
$ExcludeDirs = @(
    ".stfolder",
    ".stversions",
    '$RECYCLE.BIN',
    "System Volume Information",
    ".Trashes",
    ".Spotlight-V100",
    ".fseventsd"
)

# Exclusiones de archivos
$ExcludeFiles = @(
    "*.tmp",
    "~*.*",
    "Thumbs.db",
    ".DS_Store",
    "desktop.ini",
    "*.ffs_lock",
    "*.ffs_db"
)

# ============================================================================
# ESTADO GLOBAL
# ============================================================================

$global:IsRunning = $true
$ConsecutiveErrors = 0
$FirstNasDownAt = $null
$LastPopupAt = $null

# ============================================================================
# FUNCIONES
# ============================================================================

function Initialize-LogDirectory {
    $logDir = Split-Path -Parent $LogFile

    if ([string]::IsNullOrWhiteSpace($logDir)) {
        throw "La ruta de log no contiene directorio válido: $LogFile"
    }

    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
    catch {
        Write-Host "[$timestamp] [ERROR] No se pudo escribir en log: $($_.Exception.Message)"
    }

    Write-Host $line
}

function Rotate-LogIfNeeded {
    if (-not (Test-Path -LiteralPath $LogFile)) {
        return
    }

    $maxBytes = $MaxLogSizeMB * 1MB
    $currentSize = (Get-Item -LiteralPath $LogFile).Length

    if ($currentSize -le $maxBytes) {
        return
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $archivedLog = "$LogFile.$timestamp.old"

    try {
        Move-Item -LiteralPath $LogFile -Destination $archivedLog -Force
        Add-Content -LiteralPath $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] Log rotado. Archivo anterior: $archivedLog" -Encoding UTF8
    }
    catch {
        Write-Host "ERROR: No se pudo rotar el log: $($_.Exception.Message)"
    }
}

function New-MutexNameFromSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = $Path.ToLowerInvariant() -replace '[\\/:*?"<>| ]', '_'
    return "Global\RobocopyIngest_$normalized"
}

function Test-SyncConfiguration {
    if ([string]::IsNullOrWhiteSpace($SourceDir)) {
        Write-Log "La ruta de origen está vacía." "ERROR"
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($DestDir)) {
        Write-Log "La ruta de destino está vacía." "ERROR"
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($LogFile)) {
        Write-Host "ERROR: La ruta de log está vacía."
        return $false
    }

    if ($SourceDir.TrimEnd('\') -ieq $DestDir.TrimEnd('\')) {
        Write-Log "Origen y destino no pueden ser la misma ruta." "ERROR"
        return $false
    }

    if ($DestDir -notmatch '^\\\\') {
        Write-Log "El destino no parece ser una ruta UNC. Destino configurado: $DestDir" "WARN"
    }

    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
        Write-Log "No existe la carpeta de origen: $SourceDir" "ERROR"
        return $false
    }

    return $true
}

function Test-NasAvailability {
    if (-not (Test-Path -LiteralPath $DestDir -PathType Container)) {
        Write-Log "Destino no accesible o inexistente: $DestDir" "WARN"
        return $false
    }

    return $true
}

function Interpret-RobocopyExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Code
    )

    $messages = New-Object System.Collections.Generic.List[string]

    if ($Code -eq 0) {
        $messages.Add("Sin cambios")
    }

    if (($Code -band 1) -ne 0) {
        $messages.Add("Archivos copiados o movidos correctamente")
    }

    if (($Code -band 2) -ne 0) {
        $messages.Add("Elementos extra detectados en destino; no se eliminan al no usar /MIR ni /PURGE")
    }

    if (($Code -band 4) -ne 0) {
        $messages.Add("Diferencias detectadas")
    }

    if (($Code -band 8) -ne 0) {
        $messages.Add("Fallos de copia")
    }

    if (($Code -band 16) -ne 0) {
        $messages.Add("Error fatal de Robocopy")
    }

    if ($messages.Count -eq 0) {
        $messages.Add("Código no interpretado específicamente")
    }

    return ($messages -join "; ")
}

function Show-NasNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [int]$TimeOfflineMinutes
    )

    if (-not $EnablePopupNotification) {
        return
    }

    try {
        $wshell = New-Object -ComObject Wscript.Shell
        $fullMessage = "ALERTA DEL SISTEMA DE INGESTA`n`n$Message`n`nTiempo de desconexión: $TimeOfflineMinutes minutos."
        $wshell.Popup($fullMessage, 0, "Error de conexión NAS", 0x10) | Out-Null
    }
    catch {
        Write-Log "No se pudo mostrar popup de notificación: $($_.Exception.Message)" "WARN"
    }
}

function Test-StopRequested {
    if (Test-Path -LiteralPath $StopFile) {
        Write-Log "Detectado archivo de parada: $StopFile" "WARN"
        return $true
    }

    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)

            if (
                $key.Key -eq [ConsoleKey]::C -and
                (($key.Modifiers -band [ConsoleModifiers]::Control) -eq [ConsoleModifiers]::Control)
            ) {
                Write-Log "Detectada solicitud de parada por Ctrl+C." "WARN"
                return $true
            }
        }
    }
    catch {
        # En ejecución no interactiva puede no existir consola. Se ignora.
    }

    return $false
}

function Invoke-RobocopyMove {
    $arguments = New-Object System.Collections.Generic.List[string]

    $arguments.Add($SourceDir)
    $arguments.Add($DestDir)

    # Copia subdirectorios, mueve archivos y no elimina nada en destino.
    $arguments.Add("/E")
    $arguments.Add("/MOV")

    # Modo de copia.
    $arguments.Add($CopyMode)
    $arguments.Add("/DCOPY:T")

    # Rendimiento y resiliencia.
    $arguments.Add("/MT:$Threads")
    $arguments.Add("/R:$Retries")
    $arguments.Add("/W:$WaitSeconds")
    $arguments.Add("/FFT")
    $arguments.Add("/Z")

    # Log limpio.
    $arguments.Add("/NP")
    $arguments.Add("/NDL")
    $arguments.Add("/TEE")
    $arguments.Add("/LOG+:$LogFile")

    # Evita tratar junctions/enlaces simbólicos de directorio para reducir riesgos de recursividad.
    $arguments.Add("/XJ")

    # Append-only estricto: no sobrescribir archivos ya existentes en destino si son distintos.
    if ($StrictAppendOnly) {
        $arguments.Add("/XC")
        $arguments.Add("/XN")
        $arguments.Add("/XO")
    }

    if ($ExcludeDirs.Count -gt 0) {
        $arguments.Add("/XD")
        foreach ($dir in $ExcludeDirs) {
            $arguments.Add($dir)
        }
    }

    if ($ExcludeFiles.Count -gt 0) {
        $arguments.Add("/XF")
        foreach ($file in $ExcludeFiles) {
            $arguments.Add($file)
        }
    }

    Write-Log "Ejecutando Robocopy. Modo=$CopyMode; StrictAppendOnly=$StrictAppendOnly; Threads=$Threads; R=$Retries; W=$WaitSeconds"

    & robocopy @arguments | Out-Null

    return $LASTEXITCODE
}

function Wait-WithStopCheck {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Seconds
    )

    for ($i = 0; $i -lt $Seconds; $i++) {
        if (Test-StopRequested) {
            $global:IsRunning = $false
            break
        }

        Start-Sleep -Seconds 1
    }
}

# ============================================================================
# ARRANQUE
# ============================================================================

try {
    [Console]::TreatControlCAsInput = $true
}
catch {
    # No todos los hosts PowerShell permiten modificar este comportamiento.
}

$Mutex = $null
$MutexCreated = $false

try {
    Initialize-LogDirectory
    Rotate-LogIfNeeded

    Write-Log "=== Iniciando Servicio de Ingesta Continua v$Version ==="
    Write-Log "Origen: $SourceDir"
    Write-Log "Destino: $DestDir"
    Write-Log "Log: $LogFile"
    Write-Log "StopFile: $StopFile"
    Write-Log "CopyMode: $CopyMode"
    Write-Log "StrictAppendOnly: $StrictAppendOnly"

    if (-not (Test-SyncConfiguration)) {
        Write-Log "Fallo en validación inicial. Servicio detenido." "ERROR"
        exit 1
    }

    $MutexName = New-MutexNameFromSource -Path $SourceDir
    $Mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$MutexCreated)

    if (-not $MutexCreated) {
        Write-Log "Ya existe una instancia en ejecución para este origen. Mutex: $MutexName" "ERROR"
        exit 1
    }

    Write-Log "Single-instance activo. Mutex: $MutexName"

    # ============================================================================
    # BUCLE PRINCIPAL
    # ============================================================================

    $Cycle = 0

    while ($global:IsRunning) {
        $Cycle++

        Rotate-LogIfNeeded

        if (Test-StopRequested) {
            $global:IsRunning = $false
            break
        }

        Write-Log "--- Ciclo #$Cycle iniciado ---"

        if (-not (Test-NasAvailability)) {
            $ConsecutiveErrors++

            if ($null -eq $FirstNasDownAt) {
                $FirstNasDownAt = Get-Date
            }

            $offlineMinutes = [int]((Get-Date) - $FirstNasDownAt).TotalMinutes
            Write-Log "NAS no disponible. Errores consecutivos: $ConsecutiveErrors. Minutos sin conexión: $offlineMinutes" "WARN"

            if ($offlineMinutes -ge $NotifyAfterNasDownMinutes) {
                $shouldNotify = $false

                if ($null -eq $LastPopupAt) {
                    $shouldNotify = $true
                }
                else {
                    $minutesSinceLastPopup = [int]((Get-Date) - $LastPopupAt).TotalMinutes
                    if ($minutesSinceLastPopup -ge $PopupCooldownMinutes) {
                        $shouldNotify = $true
                    }
                }

                if ($shouldNotify) {
                    Show-NasNotification -Message "El destino NAS no está disponible: $DestDir" -TimeOfflineMinutes $offlineMinutes
                    $LastPopupAt = Get-Date
                }
            }

            if ($ConsecutiveErrors -ge $MaxConsecutiveErrors) {
                Write-Log "Error persistente. Pausa extendida de $PausePersistentError segundos." "WARN"
                Wait-WithStopCheck -Seconds $PausePersistentError
                $ConsecutiveErrors = 0
            }
            else {
                Wait-WithStopCheck -Seconds $PauseError
            }

            continue
        }

        # NAS recuperado.
        if ($null -ne $FirstNasDownAt) {
            $offlineMinutes = [int]((Get-Date) - $FirstNasDownAt).TotalMinutes
            Write-Log "NAS recuperado tras $offlineMinutes minutos de indisponibilidad." "INFO"
            $FirstNasDownAt = $null
            $LastPopupAt = $null
        }

        $exitCode = Invoke-RobocopyMove
        $summary = Interpret-RobocopyExitCode -Code $exitCode

        if ($exitCode -ge 8) {
            $ConsecutiveErrors++
            Write-Log "Ciclo #$Cycle finalizado con error. ExitCode=$exitCode. $summary" "ERROR"
            Write-Log "Errores consecutivos: $ConsecutiveErrors" "WARN"

            if ($ConsecutiveErrors -ge $MaxConsecutiveErrors) {
                Write-Log "Se alcanzaron $MaxConsecutiveErrors errores consecutivos. Pausa extendida de $PausePersistentError segundos." "WARN"
                Wait-WithStopCheck -Seconds $PausePersistentError
                $ConsecutiveErrors = 0
            }
            else {
                Wait-WithStopCheck -Seconds $PauseError
            }
        }
        elseif ($exitCode -ge 1 -and $exitCode -lt 8) {
            $ConsecutiveErrors = 0
            Write-Log "Ciclo #$Cycle finalizado con actividad. ExitCode=$exitCode. $summary" "INFO"
            Wait-WithStopCheck -Seconds $PauseChange
        }
        else {
            $ConsecutiveErrors = 0

            if (($Cycle % 20) -eq 0) {
                Write-Log "Ciclo #$Cycle finalizado sin cambios. ExitCode=$exitCode. $summary" "INFO"
            }

            Wait-WithStopCheck -Seconds $PauseNoChange
        }
    }
}
catch {
    Write-Log "Excepción no controlada: $($_.Exception.Message)" "ERROR"
    Write-Log "StackTrace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}
finally {
    Write-Log "=== Parada ordenada iniciada ==="

    if ($MutexCreated -and $null -ne $Mutex) {
        try {
            $Mutex.ReleaseMutex()
            $Mutex.Dispose()
            Write-Log "Mutex liberado correctamente."
        }
        catch {
            Write-Log "Error al liberar mutex: $($_.Exception.Message)" "WARN"
        }
    }

    Write-Log "=== Servicio detenido ==="
}