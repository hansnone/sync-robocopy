# =============================================
# Sincronización Robocopy Mirror Continua - v4
# Versión endurecida con:
#  - Exclusiones de metadatos (Syncthing, macOS, Windows)
#  - Rotación automática de log
#  - Detección y registro de errores
#  - Reintentos optimizados
#  - Pausa adaptativa según actividad
#  - version 0.0.4
# =============================================

# ---------- Configuración ----------
$origen  = "C:\Users\locadmin\Desktop\prueba-sincronizacion-carpetas\carpeta-a"
$destino = "C:\Users\locadmin\Desktop\prueba-sincronizacion-carpetas\carpeta-b"
$log     = "$env:USERPROFILE\Documents\robocopy-sync.log"

# Tamaño máximo del log antes de rotar (en bytes)
$maxLogSize = 50MB

# Exclusiones: metadatos de Syncthing, macOS, Windows y temporales
$excludeDirs = @(
'.stfolder',                    # Syncthing marker
'.stversions',                  # Syncthing versioning
'$RECYCLE.BIN',                 # Papelera Windows
'System Volume Information',    # Metadata NTFS
'.Trashes',                     # macOS
'.Spotlight-V100',              # macOS
'.fseventsd'                    # macOS
)

$excludeFiles = @(
'*.tmp',
'~*.*',
'Thumbs.db',
'.DS_Store',
'desktop.ini',
'*.ffs_lock',                   # FreeFileSync lock
'*.ffs_db'                      # FreeFileSync database
)

# Pausa entre ciclos (segundos)
$pausaNormal = 15      # Cuando no hay cambios
$pausaTrasError = 60   # Cuando hay error grave
$pausaTrasCambio = 10  # Justo después de copiar algo

# ---------- Funciones auxiliares ----------
function Write-Log {
param([string]$mensaje, [string]$nivel = "INFO")
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
"$ts [$nivel] $mensaje" | Out-File $log -Append -Encoding UTF8
}

function Rotar-LogSiNecesario {
if ((Test-Path $log) -and (Get-Item $log).Length -gt $maxLogSize) {
    $archivado = "$log.$(Get-Date -Format 'yyyyMMdd_HHmmss').old"
    Move-Item $log $archivado -Force
    "=== Log rotado desde: $archivado ===" | Out-File $log -Encoding UTF8
    Write-Log "Log rotado. Archivo anterior: $archivado"
}
}

function Interpretar-ExitCode {
param([int]$code)
# Códigos Robocopy (bitmask):
#  0 = Sin cambios
#  1 = OK, ficheros copiados
#  2 = Extras detectados/eliminados
#  4 = Mismatches
#  8 = Fallos de copia
# 16 = Error fatal
$mensajes = @()
if ($code -eq 0)       { $mensajes += "Sin cambios" }
if ($code -band 1)     { $mensajes += "Copiados OK" }
if ($code -band 2)     { $mensajes += "Extras procesados" }
if ($code -band 4)     { $mensajes += "⚠ Mismatches" }
if ($code -band 8)     { $mensajes += "✗ Fallos de copia" }
if ($code -band 16)    { $mensajes += "✗✗ ERROR FATAL" }
return ($mensajes -join ", ")
}

# ---------- Validaciones iniciales ----------
if (-not (Test-Path $origen)) {
Write-Host "ERROR: No existe el origen: $origen" -ForegroundColor Red
exit 1
}
if (-not (Test-Path $destino)) {
Write-Host "Creando destino: $destino" -ForegroundColor Yellow
New-Item -ItemType Directory -Path $destino -Force | Out-Null
}

# ---------- Cabecera inicial ----------
if (-not (Test-Path $log)) {
"=== Robocopy Sync Started: $(Get-Date) ===" | Out-File $log -Encoding UTF8
}
Write-Log "================ INICIO DEL SERVICIO ================"
Write-Log "Origen : $origen"
Write-Log "Destino: $destino"
Write-Log "Exclusiones dir : $($excludeDirs -join ', ')"
Write-Log "Exclusiones file: $($excludeFiles -join ', ')"
Write-Log "====================================================="

# ---------- Bucle principal ----------
$ciclo = 0
$erroresConsecutivos = 0

while ($true) {
$ciclo++
Rotar-LogSiNecesario

Write-Log "--- Ciclo #$ciclo iniciado ---"

# Ejecutar Robocopy
# Parámetros clave:
#   /MIR         -> espejo completo (copia + borra extras)
#   /COPY:DAT    -> Data, Attributes, Timestamps (SIN Owner/Security -> evita error 1307)
#   /DCOPY:T     -> preserva timestamps de directorios
#   /MT:16       -> 16 hilos (balanceado para escritorio)
#   /R:1 /W:2    -> 1 reintento con 2s de espera (evita bloqueos largos)
#   /FFT         -> tolerancia de 2s en timestamps (multi-FS friendly)
#   /NP          -> sin porcentaje (log más limpio)
#   /NDL         -> sin listar directorios (menos ruido)
#   /XD / /XF    -> exclusiones
& robocopy $origen $destino `
    /MIR /COPY:DAT /DCOPY:T /MT:16 /R:1 /W:2 /FFT /NP /NDL `
    /XD $excludeDirs /XF $excludeFiles `
    /LOG+:$log | Out-Null

$exitCode = $LASTEXITCODE
$resumen = Interpretar-ExitCode $exitCode

# Decidir pausa y loguear según resultado
if ($exitCode -ge 8) {
    # Error grave
    $erroresConsecutivos++
    Write-Log "Ciclo #$ciclo finalizado (ExitCode=$exitCode): $resumen" "ERROR"
    Write-Log "Errores consecutivos: $erroresConsecutivos" "WARN"
    
    if ($erroresConsecutivos -ge 5) {
        Write-Log "5 errores consecutivos. Pausa extendida de 5 minutos." "WARN"
        Start-Sleep -Seconds 300
        $erroresConsecutivos = 0
    } else {
        Start-Sleep -Seconds $pausaTrasError
    }
}
elseif ($exitCode -ge 1 -and $exitCode -lt 8) {
    # Hubo cambios (copia o borrado)
    $erroresConsecutivos = 0
    Write-Log "Ciclo #$ciclo finalizado (ExitCode=$exitCode): $resumen"
    Start-Sleep -Seconds $pausaTrasCambio
}
else {
    # Sin cambios (código 0) - caso normal
    $erroresConsecutivos = 0
    # Log minimalista para no saturar
    if ($ciclo % 20 -eq 0) {
        Write-Log "Ciclo #$ciclo OK (sin cambios). Llevamos $ciclo ciclos."
    }
    Start-Sleep -Seconds $pausaNormal
}
}