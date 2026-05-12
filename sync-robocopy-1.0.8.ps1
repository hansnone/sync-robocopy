<#
.SYNOPSIS
Ingesta continua 24/7 interactiva con Robocopy hacia NAS montado como R:.

.VERSION
1.0.8

.DESCRIPTION
Mueve archivos desde una cola local hacia un NAS usando Robocopy.

Diseñado para ejecutarse como tarea programada con:
- "Ejecutar solo cuando el usuario haya iniciado sesión".
- Ventana interactiva disponible para solicitar credenciales si R: no está montada.
- NAS Kerberos priorizando nombre DNS/host: \\RAW-NAS\Repositorio.
- Unidad obligatoria de trabajo: R:\.

Características:
- Comprueba si R: ya está montada contra RAW-NAS o 10.71.11.41.
- Si R: no está montada, intenta montar contra \\RAW-NAS\Repositorio.
- Si falla el montaje con la sesión actual, solicita usuario y contraseña en consola.
- No almacena contraseñas en el script.
- No usa /MIR.
- No usa /PURGE.
- No elimina nada en destino.
- Usa /MOV para eliminar del origen únicamente archivos copiados correctamente por Robocopy.
- Append-only estricto opcional.
- Logging persistente.
- Rotación automática de log.
- Estadísticas por ciclo.
- Estadísticas acumuladas.
- CSV de métricas.
- Single-instance mediante Mutex.
- Parada ordenada mediante archivo .stop o Ctrl+C en consola interactiva.

.NOTES
Configurar la tarea programada como:
- Ejecutar solo cuando el usuario haya iniciado sesión.
- Ejecutar con los privilegios más altos.
- No iniciar nueva instancia si ya está en ejecución.
#>

#requires -version 5.1

# ============================================================================
# CONFIGURACIÓN GENERAL
# ============================================================================

$Version = "1.0.8"

# ORIGEN: cola local de ingesta.
$SourceDir = "C:\Ruta\ColaEntrada"

# NAS.
$NasHostName = "RAW-NAS"
$NasIp       = "10.71.11.41"
$NasShare    = "Repositorio"

$NasUncPrimary  = "\\$NasHostName\$NasShare"
$NasUncFallback = "\\$NasIp\$NasShare"

# Unidad requerida por flujo de trabajo.
$DriveLetter = "R:"
$DestDir     = "$DriveLetter\"

# Para Kerberos, mantener en $false salvo configuración específica de SPN por IP.
$AllowIpFallback = $false

# Si R: apunta a otro destino, no desmontar automáticamente por seguridad.
$AllowRemapWrongDrive = $false

# LOGS.
$LogFile      = "C:\Ruta\Logs\sync-robocopy.log"
$StatsCsvFile = "C:\Ruta\Logs\sync-robocopy-stats.csv"
$MaxLogSizeMB = 10

# Archivo de parada ordenada.
$StopFile = "C:\Ruta\Logs\sync-robocopy.stop"

# Pausas.
$PauseNoChange          = 15
$PauseChange            = 10
$PauseError             = 60
$MaxConsecutiveErrors   = 5
$PausePersistentError   = 300

# Notificaciones.
$EnablePopupNotification  = $true
$NotifyAfterNasDownMinutes = 5
$PopupCooldownMinutes      = 30

# Robocopy.
$Threads     = 16
$Retries     = 1
$WaitSeconds = 2

# Recomendado para NAS: datos, atributos y fechas.
# Usar /COPYALL solo si el NAS soporta ACL, propietario y auditoría, y el usuario tiene permisos.
$CopyMode = "/COPY:DAT"

# Append-only estricto:
# $true  = no sobrescribe archivos existentes en destino. Si existen, quedan pendientes en origen.
# $false = permite actualización normal según Robocopy.
$StrictAppendOnly = $true

# Exclusiones de directorios.
$ExcludeDirs = @(
    ".stfolder",
    ".stversions",
    '$RECYCLE.BIN',
    "System Volume Information",
    ".Trashes",
    ".Spotlight-V100",
    ".fseventsd"
)

# Exclusiones de archivos.
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

$global:IsRunning        = $true
$global:TotalFilesMoved  = 0
$global:TotalBytesMoved  = [Int64]0
$global:TotalCopySeconds = [double]0

$ConsecutiveErrors = 0
$FirstNasDownAt    = $null
$LastPopupAt       = $null

# ============================================================================
# LOGGING
# ============================================================================

function Initialize-LogDirectory {
    $dirs = @(
        (Split-Path -Parent $LogFile),
        (Split-Path -Parent $StatsCsvFile),
        (Split-Path -Parent $StopFile)
    )

    foreach ($dir in $dirs) {
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        }
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
        Write-Host "[$timestamp] [ERROR] No se pudo escribir en el log: $($_.Exception.Message)"
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

# ============================================================================
# VALIDACIÓN
# ============================================================================

function New-MutexNameFromSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hashBytes = $sha.ComputeHash($bytes)
        $hash = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")
        return "Global\RobocopyIngest_$hash"
    }
    finally {
        $sha.Dispose()
    }
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

    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
        Write-Log "No existe la carpeta de origen: $SourceDir" "ERROR"
        return $false
    }

    if ($SourceDir.TrimEnd("\") -ieq $DestDir.TrimEnd("\")) {
        Write-Log "Origen y destino no pueden ser la misma ruta." "ERROR"
        return $false
    }

    $robocopyCommand = Get-Command robocopy.exe -ErrorAction SilentlyContinue
    if ($null -eq $robocopyCommand) {
        Write-Log "No se encuentra robocopy.exe en el sistema." "ERROR"
        return $false
    }

    $netCommand = Get-Command net.exe -ErrorAction SilentlyContinue
    if ($null -eq $netCommand) {
        Write-Log "No se encuentra net.exe en el sistema." "ERROR"
        return $false
    }

    return $true
}

# ============================================================================
# MONTAJE NAS / R:
# ============================================================================

function Get-MappedDriveRemotePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Drive
    )

    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'" -ErrorAction Stop

        if ($null -eq $disk) {
            return $null
        }

        return $disk.ProviderName
    }
    catch {
        Write-Log "No se pudo consultar la unidad $Drive: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Test-DriveAccessible {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveRoot
    )

    try {
        return (Test-Path -LiteralPath $DriveRoot -PathType Container)
    }
    catch {
        return $false
    }
}

function Test-DriveMappingValid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Drive,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedTargets
    )

    $remotePath = Get-MappedDriveRemotePath -Drive $Drive

    if ([string]::IsNullOrWhiteSpace($remotePath)) {
        return $false
    }

    foreach ($target in $AllowedTargets) {
        if ($remotePath.TrimEnd("\") -ieq $target.TrimEnd("\")) {
            if (Test-DriveAccessible -DriveRoot "$Drive\") {
                return $true
            }

            Write-Log "La unidad $Drive apunta a $remotePath, pero no es accesible actualmente." "WARN"
            return $false
        }
    }

    Write-Log "La unidad $Drive está mapeada a una ruta no autorizada: $remotePath" "ERROR"
    return $false
}

function Mount-NasDriveCurrentUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Drive,

        [Parameter(Mandatory = $true)]
        [string]$UncPath
    )

    Write-Log "Intentando montar $Drive contra $UncPath usando credenciales de la sesión actual."

    $args = @(
        "use",
        $Drive,
        $UncPath,
        "/persistent:yes"
    )

    & net.exe @args | Out-Null
    $exit = $LASTEXITCODE

    if ($exit -eq 0 -and (Test-DriveAccessible -DriveRoot "$Drive\")) {
        Write-Log "Unidad $Drive montada correctamente contra $UncPath."
        return $true
    }

    Write-Log "No se pudo montar $Drive con la sesión actual. ExitCode=$exit" "WARN"
    return $false
}

function Mount-NasDrivePromptCredentials {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Drive,

        [Parameter(Mandatory = $true)]
        [string]$UncPath
    )

    if (-not [Environment]::UserInteractive) {
        Write-Log "No hay sesión interactiva. No se pueden solicitar credenciales al usuario." "ERROR"
        return $false
    }

    Write-Host ""
    Write-Host "Credenciales requeridas para acceder al NAS: $UncPath" -ForegroundColor Yellow
    Write-Host "Formato recomendado: DOMINIO\usuario o usuario@dominio" -ForegroundColor Yellow
    Write-Host "La contraseña la solicitará net use y no quedará escrita en el script." -ForegroundColor Yellow
    Write-Host ""

    $username = Read-Host "Usuario"

    if ([string]::IsNullOrWhiteSpace($username)) {
        Write-Log "No se introdujo usuario para montar el NAS." "ERROR"
        return $false
    }

    Write-Log "Solicitando contraseña interactiva para montar $Drive contra $UncPath con usuario $username."

    $args = @(
        "use",
        $Drive,
        $UncPath,
        "/user:$username",
        "*",
        "/persistent:yes"
    )

    & net.exe @args
    $exit = $LASTEXITCODE

    if ($exit -eq 0 -and (Test-DriveAccessible -DriveRoot "$Drive\")) {
        Write-Log "Unidad $Drive montada correctamente contra $UncPath con usuario $username."
        return $true
    }

    Write-Log "Fallo al montar $Drive contra $UncPath con usuario $username. ExitCode=$exit" "ERROR"
    return $false
}

function Ensure-NasDriveMounted {
    $allowedTargets = @($NasUncPrimary, $NasUncFallback)

    $currentRemote = Get-MappedDriveRemotePath -Drive $DriveLetter

    if (-not [string]::IsNullOrWhiteSpace($currentRemote)) {
        if (Test-DriveMappingValid -Drive $DriveLetter -AllowedTargets $allowedTargets) {
            Write-Log "Unidad $DriveLetter ya montada correctamente contra $currentRemote."
            return $true
        }

        if (-not $AllowRemapWrongDrive) {
            Write-Log "La unidad $DriveLetter está ocupada, desconectada o apunta a una ruta no válida. No se remapea automáticamente." "ERROR"
            return $false
        }

        Write-Log "Desmontando unidad $DriveLetter por mapeo incorrecto o inaccesible: $currentRemote" "WARN"

        $deleteArgs = @("use", $DriveLetter, "/delete", "/yes")
        & net.exe @deleteArgs | Out-Null

        if ($LASTEXITCODE -ne 0) {
            Write-Log "No se pudo desmontar $DriveLetter. ExitCode=$LASTEXITCODE" "ERROR"
            return $false
        }
    }

    if (Mount-NasDriveCurrentUser -Drive $DriveLetter -UncPath $NasUncPrimary) {
        return $true
    }

    if (Mount-NasDrivePromptCredentials -Drive $DriveLetter -UncPath $NasUncPrimary) {
        return $true
    }

    if ($AllowIpFallback) {
        Write-Log "Intentando fallback por IP: $NasUncFallback" "WARN"

        if (Mount-NasDriveCurrentUser -Drive $DriveLetter -UncPath $NasUncFallback) {
            return $true
        }

        if (Mount-NasDrivePromptCredentials -Drive $DriveLetter -UncPath $NasUncFallback) {
            return $true
        }
    }

    Write-Log "No se pudo montar la unidad $DriveLetter contra el NAS." "ERROR"
    return $false
}

# ============================================================================
# NOTIFICACIÓN Y PARADA
# ============================================================================

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

    if (-not [Environment]::UserInteractive) {
        Write-Log "Notificación omitida: sesión no interactiva." "WARN"
        return
    }

    try {
        $wshell = New-Object -ComObject Wscript.Shell
        $fullMessage = "ALERTA DEL SISTEMA DE INGESTA`n`n$Message`n`nTiempo de indisponibilidad: $TimeOfflineMinutes minutos."
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
        # Si el host no expone consola, se ignora.
    }

    return $false
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
# ESTADÍSTICAS
# ============================================================================

function Convert-BytesToReadable {
    param(
        [Parameter(Mandatory = $true)]
        [Int64]$Bytes
    )

    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }

    if ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }

    if ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }

    return "$Bytes B"
}

function Test-FileExcludedByName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    foreach ($pattern in $ExcludeFiles) {
        if ($FileName -like $pattern) {
            return $true
        }
    }

    return $false
}

function Test-PathContainsExcludedDir {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullPath
    )

    $sourceRoot = (Get-Item -LiteralPath $SourceDir).FullName.TrimEnd("\")
    $relative = $FullPath.Substring($sourceRoot.Length).TrimStart("\")
    $segments = $relative -split "\\"

    foreach ($segment in $segments) {
        foreach ($excludedDir in $ExcludeDirs) {
            if ($segment -ieq $excludedDir) {
                return $true
            }
        }
    }

    return $false
}

function Get-SourceManifest {
    $manifest = New-Object System.Collections.Generic.List[object]
    $sourceRoot = (Get-Item -LiteralPath $SourceDir).FullName.TrimEnd("\")

    $files = Get-ChildItem -LiteralPath $SourceDir -File -Recurse -Force -ErrorAction SilentlyContinue

    foreach ($file in $files) {
        if (Test-FileExcludedByName -FileName $file.Name) {
            continue
        }

        if (Test-PathContainsExcludedDir -FullPath $file.FullName) {
            continue
        }

        $relativePath = $file.FullName.Substring($sourceRoot.Length).TrimStart("\")

        $manifest.Add([PSCustomObject]@{
            FullName      = $file.FullName
            RelativePath  = $relativePath
            Length        = [Int64]$file.Length
            LastWriteTime = $file.LastWriteTime
        })
    }

    return $manifest
}

function Get-MovedFilesFromManifest {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Manifest
    )

    $moved = New-Object System.Collections.Generic.List[object]

    foreach ($item in $Manifest) {
        $sourceExists = Test-Path -LiteralPath $item.FullName
        $destPath = Join-Path -Path $DestDir -ChildPath $item.RelativePath
        $destExists = Test-Path -LiteralPath $destPath

        if ((-not $sourceExists) -and $destExists) {
            $moved.Add([PSCustomObject]@{
                RelativePath = $item.RelativePath
                Length       = [Int64]$item.Length
                DestPath     = $destPath
            })
        }
    }

    return $moved
}

function Initialize-StatsCsv {
    if (-not (Test-Path -LiteralPath $StatsCsvFile)) {
        $header = "Timestamp;Cycle;FilesMoved;BytesMoved;ReadableSize;ElapsedSeconds;SpeedMBs;SpeedMBmin;AvgFileSizeBytes;AvgSecondsPerFile;TotalFilesMoved;TotalBytesMoved;GlobalAvgSpeedMBs"
        Add-Content -LiteralPath $StatsCsvFile -Value $header -Encoding UTF8
    }
}

function Write-CycleStats {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Cycle,

        [Parameter(Mandatory = $true)]
        [array]$MovedFiles,

        [Parameter(Mandatory = $true)]
        [double]$ElapsedSeconds
    )

    if ($null -eq $MovedFiles) {
        $MovedFiles = @()
    }

    $filesMoved = $MovedFiles.Count
    $measure = $MovedFiles | Measure-Object -Property Length -Sum

    $bytesMoved = [Int64]0
    if ($null -ne $measure.Sum) {
        $bytesMoved = [Int64]$measure.Sum
    }

    if ($ElapsedSeconds -le 0) {
        $ElapsedSeconds = 0.001
    }

    $mbMoved    = $bytesMoved / 1MB
    $speedMBs   = $mbMoved / $ElapsedSeconds
    $speedMBmin = $speedMBs * 60

    $avgFileSizeBytes = [Int64]0
    $avgSecondsPerFile = [double]0

    if ($filesMoved -gt 0) {
        $avgFileSizeBytes = [Int64]($bytesMoved / $filesMoved)
        $avgSecondsPerFile = $ElapsedSeconds / $filesMoved
    }

    $global:TotalFilesMoved  += $filesMoved
    $global:TotalBytesMoved  += $bytesMoved
    $global:TotalCopySeconds += $ElapsedSeconds

    $globalAvgSpeedMBs = [double]0
    if ($global:TotalCopySeconds -gt 0) {
        $globalAvgSpeedMBs = ($global:TotalBytesMoved / 1MB) / $global:TotalCopySeconds
    }

    Write-Log ("ESTADÍSTICAS CICLO #{0} | Archivos movidos={1} | Datos movidos={2} | Tiempo={3:N2}s | Velocidad media={4:N2} MB/s | Velocidad media={5:N2} MB/min | Tamaño medio archivo={6} | Tiempo medio archivo={7:N2}s" -f `
        $Cycle,
        $filesMoved,
        (Convert-BytesToReadable -Bytes $bytesMoved),
        $ElapsedSeconds,
        $speedMBs,
        $speedMBmin,
        (Convert-BytesToReadable -Bytes $avgFileSizeBytes),
        $avgSecondsPerFile
    )

    Write-Log ("ESTADÍSTICAS ACUMULADAS | Archivos={0} | Datos={1} | Tiempo total={2:N2}s | Velocidad media global={3:N2} MB/s" -f `
        $global:TotalFilesMoved,
        (Convert-BytesToReadable -Bytes $global:TotalBytesMoved),
        $global:TotalCopySeconds,
        $globalAvgSpeedMBs
    )

    Initialize-StatsCsv

    $line = "{0};{1};{2};{3};{4};{5:N2};{6:N2};{7:N2};{8};{9:N2};{10};{11};{12:N2}" -f `
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
        $Cycle,
        $filesMoved,
        $bytesMoved,
        (Convert-BytesToReadable -Bytes $bytesMoved),
        $ElapsedSeconds,
        $speedMBs,
        $speedMBmin,
        $avgFileSizeBytes,
        $avgSecondsPerFile,
        $global:TotalFilesMoved,
        $global:TotalBytesMoved,
        $globalAvgSpeedMBs

    Add-Content -LiteralPath $StatsCsvFile -Value $line -Encoding UTF8
}

# ============================================================================
# ROBOCOPY
# ============================================================================

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
        $messages.Add("Elementos extra detectados en destino; no se eliminan")
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

function Invoke-RobocopyMove {
    $arguments = New-Object System.Collections.Generic.List[string]

    $arguments.Add($SourceDir)
    $arguments.Add($DestDir)

    # Copia subdirectorios y mueve archivos. No elimina extras del destino.
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

    # Evita junctions/enlaces que puedan provocar recursividad.
    $arguments.Add("/XJ")

    # Log Robocopy.
    $arguments.Add("/NP")
    $arguments.Add("/NDL")
    $arguments.Add("/TEE")
    $arguments.Add("/LOG+:$LogFile")

    # Append-only estricto.
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

    Write-Log "Ejecutando Robocopy. Origen=$SourceDir; Destino=$DestDir; Modo=$CopyMode; StrictAppendOnly=$StrictAppendOnly; Threads=$Threads; R=$Retries; W=$WaitSeconds"

    & robocopy.exe @arguments

    return $LASTEXITCODE
}

# ============================================================================
# ARRANQUE
# ============================================================================

try {
    [Console]::TreatControlCAsInput = $true
}
catch {
    # Algunos hosts no permiten modificar este comportamiento.
}

$Mutex = $null
$MutexCreated = $false

try {
    Initialize-LogDirectory
    Rotate-LogIfNeeded
    Initialize-StatsCsv

    Write-Log "=== Iniciando Servicio de Ingesta Continua v$Version ==="
    Write-Log "Origen: $SourceDir"
    Write-Log "NAS primario: $NasUncPrimary"
    Write-Log "NAS fallback IP: $NasUncFallback"
    Write-Log "Unidad requerida: $DriveLetter"
    Write-Log "Destino operativo: $DestDir"
    Write-Log "Log: $LogFile"
    Write-Log "CSV estadísticas: $StatsCsvFile"
    Write-Log "StopFile: $StopFile"
    Write-Log "CopyMode: $CopyMode"
    Write-Log "StrictAppendOnly: $StrictAppendOnly"
    Write-Log "AllowIpFallback: $AllowIpFallback"
    Write-Log "AllowRemapWrongDrive: $AllowRemapWrongDrive"

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

        if (-not (Ensure-NasDriveMounted)) {
            $ConsecutiveErrors++

            if ($null -eq $FirstNasDownAt) {
                $FirstNasDownAt = Get-Date
            }

            $offlineMinutesRaw = (Get-Date - $FirstNasDownAt).TotalMinutes
            $offlineMinutes = [int][Math]::Floor($offlineMinutesRaw)

            Write-Log "NAS no disponible o unidad $DriveLetter no montada. Se omite el ciclo. Errores consecutivos=$ConsecutiveErrors; Minutos indisponible=$offlineMinutes" "ERROR"

            if ($offlineMinutes -ge $NotifyAfterNasDownMinutes) {
                $shouldNotify = $false

                if ($null -eq $LastPopupAt) {
                    $shouldNotify = $true
                }
                else {
                    $minutesSinceLastPopup = (Get-Date - $LastPopupAt).TotalMinutes
                    if ($minutesSinceLastPopup -ge $PopupCooldownMinutes) {
                        $shouldNotify = $true
                    }
                }

                if ($shouldNotify) {
                    Show-NasNotification -Message "El NAS no está disponible o la unidad $DriveLetter no puede montarse contra $NasUncPrimary." -TimeOfflineMinutes $offlineMinutes
                    $LastPopupAt = Get-Date
                }
            }

            if ($ConsecutiveErrors -ge $MaxConsecutiveErrors) {
                Write-Log "Error persistente de NAS/mapeo. Pausa extendida de $PausePersistentError segundos." "WARN"
                Wait-WithStopCheck -Seconds $PausePersistentError
                $ConsecutiveErrors = 0
            }
            else {
                Wait-WithStopCheck -Seconds $PauseError
            }

            continue
        }

        if ($null -ne $FirstNasDownAt) {
            $offlineMinutes = [int][Math]::Floor((Get-Date - $FirstNasDownAt).TotalMinutes)
            Write-Log "NAS recuperado tras $offlineMinutes minutos de indisponibilidad." "INFO"
            $FirstNasDownAt = $null
            $LastPopupAt = $null
        }

        $manifestBefore = Get-SourceManifest
        $cycleStart = Get-Date

        $exitCode = Invoke-RobocopyMove

        $cycleEnd = Get-Date
        $elapsedSeconds = ($cycleEnd - $cycleStart).TotalSeconds

        $movedFiles = Get-MovedFilesFromManifest -Manifest $manifestBefore
        Write-CycleStats -Cycle $Cycle -MovedFiles $movedFiles -ElapsedSeconds $elapsedSeconds

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