Actúa como arquitecto senior de Rust especializado en Windows, SMB/Kerberos, E/S de alto rendimiento, sincronización de archivos, aplicaciones de bandeja del sistema y herramientas operativas para entornos de producción.

Necesito diseñar y generar un programa en Rust para Windows 11 que sustituya a una solución basada en Robocopy. No debe invocar Robocopy. Debe implementar su propio motor de copia, verificación, logging, estadísticas, control de errores, montaje de NAS y operación continua.

El objetivo no es clonar Robocopy de forma generalista, sino crear un motor especializado para respaldo/ingesta local hacia NAS en red local de 10 GbE.

Contexto operativo:
- Sistema operativo cliente: Windows 11 actualizado.
- PowerShell disponible: versión 5.x para instalación auxiliar o creación de tarea programada si fuera necesario.
- Equipo cliente: estación de trabajo de gama muy alta, Intel i9 aproximadamente, GPU NVIDIA 5090 o similar, usada para IA local, generación de vídeo, foto y audio.
- Disco origen local: NVMe.
- NAS: conectado por red local de 10 GbE.
- NAS con SSD.
- Protocolo previsto: SMB.
- Autenticación: Kerberos.
- Entorno: producción serio.
- Objetivo de rendimiento: equilibrio entre consumo y velocidad, priorizando alcanzar la mayor velocidad posible sin comprometer estabilidad.
- El límite teórico de 10 GbE es aproximadamente 1.25 GB/s; el diseño debe intentar acercarse al máximo realista según disco, NAS, SMB y CPU.

Rutas y NAS:
- NAS primario: \\RAW-NAS\Repositorio
- IP del NAS: 10.71.11.41
- Unidad obligatoria para flujo de trabajo: R:\
- El programa debe validar R: en cada ciclo.
- El programa debe comprobar si R: ya está montada.
- Si R: apunta a \\RAW-NAS\Repositorio, debe considerarse válida.
- Si R: apunta a \\10.71.11.41\Repositorio, debe aceptarse solo si está habilitado el fallback por IP.
- El fallback por IP debe estar deshabilitado por defecto porque Kerberos debe priorizar el nombre RAW-NAS.
- Si R: apunta a otro recurso, no debe desmontarse automáticamente salvo configuración explícita.
- Debe existir opción configurable para permitir remapeo de R: si apunta mal, pero por defecto debe estar desactivada.
- El programa debe usar APIs Windows WNet como vía principal:
  - WNetGetConnection para consultar R:.
  - WNetAddConnection2 o WNetAddConnection3 para montar R: contra el NAS.
  - WNetCancelConnection2 solo si la configuración permite remapeo.
- Debe existir fallback mediante net use si la API WNet falla o si se configura explícitamente.
- El programa no debe almacenar credenciales.
- Si hacen falta credenciales, debe pedirlas al usuario.
- Formatos aceptados de usuario:
  - DOMINIO\usuario
  - usuario@dominio
- Número máximo de intentos de credenciales: 3.
- Si el usuario cancela o falla la autenticación, el programa debe quedar en estado de error operativo y no copiar nada.
- Si el programa se ejecuta sin sesión interactiva, no debe bloquearse esperando credenciales. Debe registrar error y esperar al siguiente ciclo.
- Como interfaz principal se requiere app con icono en bandeja del sistema.

Interfaz:
Crear una aplicación con icono en bandeja del sistema para Windows.
Debe mostrar estado:
- Verde: NAS disponible y motor funcionando.
- Amarillo: NAS no montado, esperando credenciales, cola vacía o pausado.
- Rojo: error persistente, NAS inaccesible, R: incorrecta o fallo grave.
Debe incluir menú contextual:
- Ver estado.
- Montar NAS.
- Reintentar conexión.
- Pausar.
- Reanudar.
- Parar de forma ordenada.
- Abrir carpeta de logs.
- Abrir archivo de configuración.
- Abrir métricas.
- Salir.
Debe mostrar notificaciones locales ante:
- NAS inaccesible durante más de X minutos.
- Error persistente.
- Conflictos append-only.
- Finalización de ciclo con errores.
- Credenciales requeridas.

Configuración:
Usar archivo TOML externo.
Los nombres de los parámetros deben ser largos, claros y entendibles por personal no familiarizado.
Evitar abreviaturas ambiguas.
Debe generarse un archivo de configuración de ejemplo.

Ejemplo orientativo de estructura TOML:

[general]
application_name = "Rust NAS Ingest Backup"
run_mode = "backup_append_only"
language = "es-ES"

[source]
source_directory_path = "C:\\Ruta\\ColaEntrada"
minimum_file_stable_seconds = 60
scan_interval_seconds_when_no_changes = 15
scan_interval_seconds_after_changes = 10

[nas]
required_drive_letter = "R:"
primary_unc_path = "\\\\RAW-NAS\\Repositorio"
fallback_unc_path_by_ip = "\\\\10.71.11.41\\Repositorio"
allow_ip_fallback = false
allow_automatic_remap_if_drive_points_elsewhere = false
prefer_windows_wnet_api = true
allow_net_use_fallback = true
maximum_credential_prompt_attempts = 3

[copy_engine]
worker_count = 8
maximum_worker_count = 16
copy_buffer_size_mib_per_worker = 16
large_file_threshold_mib = 1024
use_adaptive_scheduler = true
use_temporary_destination_extension = true
temporary_destination_extension = ".partial"
strict_append_only = true
delete_source_after_verified_copy = false
preserve_empty_directory_hierarchy = true
remove_empty_source_directories_after_successful_processing = true
ignore_symbolic_links = true
ignore_junctions = true

[verification]
verification_mode = "full_hash"
hash_algorithm = "blake3"
fallback_hash_algorithm = "sha256"
delete_or_mark_success_only_after_hash_match = true

[metadata]
preserve_file_attributes = true
preserve_creation_time = true
preserve_last_write_time = true
preserve_last_access_time = true
preserve_directory_timestamps = false
preserve_acl = false
preserve_owner = false
preserve_audit = false

[conflicts]
if_destination_file_exists = "hash_compare"
if_hash_is_equal = "mark_as_already_backed_up"
if_hash_is_different = "create_versioned_copy"
versioned_copy_naming_strategy = "timestamp_suffix"
conflict_directory_name = "_conflicts"
write_conflict_event_to_log = true

[exclusions]
excluded_directory_names = [
  ".stfolder",
  ".stversions",
  "$RECYCLE.BIN",
  "System Volume Information",
  ".Trashes",
  ".Spotlight-V100",
  ".fseventsd"
]

excluded_file_patterns = [
  "*.tmp",
  "~*.*",
  "Thumbs.db",
  ".DS_Store",
  "desktop.ini",
  "*.ffs_lock",
  "*.ffs_db",
  "*.partial",
  "*.download",
  "*.crdownload",
  "*.lock",
  "*.lck"
]

[retry_policy]
retries_per_file = 3
retry_delay_seconds_sequence = [2, 5, 15]
nas_retry_delay_seconds = 60
persistent_error_delay_seconds = 300
continue_on_file_error = true
maximum_consecutive_errors_before_extended_pause = 5

[logging]
human_log_file_path = "C:\\Ruta\\Logs\\rust-nas-sync.log"
metrics_csv_file_path = "C:\\Ruta\\Logs\\rust-nas-sync-stats.csv"
events_jsonl_file_path = "C:\\Ruta\\Logs\\rust-nas-sync-events.jsonl"
maximum_log_file_size_mib = 50
log_rotation_keep_file_count = 10
daily_summary_enabled = true

[scheduled_task]
create_scheduled_task = true
scheduled_task_name = "Rust NAS Ingest Backup"
run_only_when_user_is_logged_on = true
run_with_highest_privileges = false
start_at_user_logon = true
delay_after_logon_seconds = 30
prevent_parallel_instances = true

Requisitos funcionales principales:
1. El programa debe monitorizar continuamente el directorio origen.
2. Debe copiar datos hacia el NAS preservando jerarquía de carpetas.
3. Debe mantener la jerarquía de directorios en destino cuando existan archivos respaldados.
4. Debe ignorar symlinks y junctions.
5. Debe excluir archivos temporales, metadatos de Syncthing, macOS, Windows y FreeFileSync según configuración.
6. Debe evitar copiar archivos activos o en modificación.
7. Para considerar un archivo estable, debe comprobar que tamaño y LastWriteTime no han cambiado durante minimum_file_stable_seconds.
8. Debe soportar rutas largas superiores a 260 caracteres mediante APIs Windows compatibles y normalización adecuada.
9. Debe soportar Unicode aunque normalmente los nombres estarán en inglés.
10. Debe copiar a un archivo temporal en destino.
11. Solo cuando la copia esté completada, verificada y cerrada correctamente debe renombrarse al nombre final.
12. Debe aplicar metadatos después de la copia:
    - atributos;
    - fecha de creación;
    - fecha de modificación;
    - fecha de último acceso.
13. No debe preservar ACL, propietario ni auditoría en v1.
14. Debe poder eliminar directorios vacíos del origen después del procesamiento si está configurado.
15. No debe borrar nunca nada del destino.
16. No debe sobrescribir archivos existentes en destino.
17. Si el archivo de destino ya existe:
    - si el hash coincide, debe marcarse como ya respaldado;
    - si el hash difiere, debe crear una versión nueva con sufijo de timestamp o enviarlo a flujo de conflicto, según configuración.
18. El modo por defecto debe ser backup_append_only:
    - respaldar archivos estables;
    - conservar origen;
    - crear versiones si hay cambios posteriores;
    - no retirar archivos que el usuario pueda estar editando.
19. Debe existir un modo opcional move_after_verified_copy:
    - copiar;
    - verificar hash completo;
    - aplicar metadatos;
    - eliminar origen solo si la verificación completa coincide.
20. El modo move_after_verified_copy no debe ser el modo por defecto.

Rendimiento:
1. Diseñar para red local de 10 GbE.
2. Usar worker pool configurable.
3. Usar scheduler híbrido/adaptativo:
   - varios archivos en paralelo para cargas mixtas;
   - buffers grandes para archivos grandes;
   - no saturar el sistema con demasiados workers.
4. Buffer inicial recomendado: 16 MiB por worker.
5. Workers iniciales recomendados: 8.
6. Workers máximos configurables: 16.
7. Debe medir rendimiento real por archivo, por ciclo y acumulado.
8. Debe registrar:
   - bytes copiados;
   - tiempo de copia;
   - velocidad media MB/s;
   - velocidad pico aproximada;
   - número de archivos;
   - archivos en conflicto;
   - errores;
   - reintentos;
   - tiempo de hash;
   - tiempo de escritura;
   - tiempo total de ciclo.
9. La verificación fuerte por hash completo es obligatoria por configuración inicial.
10. Usar BLAKE3 como hash principal por rendimiento.
11. Permitir SHA-256 como alternativa.
12. El diseño debe advertir que el hash completo puede reducir throughput porque implica leer origen y destino completos para verificar.

Motor de copia:
Implementar internamente sin Robocopy.
Debe incluir:
- scanner recursivo;
- filtro de exclusiones;
- detector de estabilidad;
- planificador de trabajo;
- cola concurrente;
- pool de workers;
- escritor por bloques;
- archivo temporal de destino;
- flush/sync;
- verificador por hash;
- aplicación de metadatos;
- renombrado final;
- gestión de conflictos;
- limpieza de directorios vacíos;
- agregador de estadísticas;
- logger serializado.

Estados por archivo:
- detected
- excluded
- unstable
- pending
- copying
- copied_to_temporary
- verifying
- verified
- metadata_applied
- finalized
- already_exists_same_hash
- versioned_copy_created
- conflict_destination_exists_different_hash
- failed_read
- failed_write
- failed_hash
- failed_metadata
- failed_finalize
- skipped_after_retries

Estados globales:
- starting
- loading_configuration
- validating_configuration
- checking_nas_mapping
- waiting_for_credentials
- nas_available
- scanning
- copying
- idle
- paused
- error_transient
- error_persistent
- stopping
- stopped

Logging:
Crear tres salidas:
1. Log humano `.log`.
2. CSV de métricas.
3. JSON Lines de eventos estructurados.

Métricas por archivo:
- timestamp;
- cycle_id;
- relative_path;
- source_path;
- destination_path;
- file_size_bytes;
- copy_duration_ms;
- hash_duration_ms;
- total_duration_ms;
- average_speed_MBps;
- retry_count;
- final_state;
- error_message_if_any.

Métricas por ciclo:
- timestamp;
- cycle_id;
- files_detected;
- files_stable;
- files_unstable;
- files_copied;
- files_already_backed_up;
- files_versioned;
- files_conflicted;
- files_failed;
- bytes_copied;
- cycle_duration_seconds;
- average_speed_MBps;
- peak_speed_MBps;
- consecutive_errors.

Métricas acumuladas:
- uptime;
- total_files_processed;
- total_files_copied;
- total_files_failed;
- total_bytes_copied;
- global_average_speed_MBps;
- current_nas_status;
- current_queue_depth.

Errores y reintentos:
- Reintentos por archivo: 3.
- Backoff por archivo: 2s, 5s, 15s.
- Si un archivo falla, continuar con el resto.
- Si falla el NAS, pausar 60s.
- Si hay 5 errores consecutivos, pausar 300s.
- Si el NAS no está disponible, no copiar nada.
- Si R: no está correctamente montada, no copiar nada.
- Si se pierden credenciales o sesión SMB, pasar a estado rojo y reintentar.
- Nunca borrar ni modificar destino ante error.

Seguridad:
- No guardar credenciales.
- No escribir contraseñas en logs.
- No pasar contraseñas en argumentos visibles del proceso si se usa fallback externo.
- Priorizar WNetAddConnection3 o mecanismo seguro con prompt interactivo.
- Si se usa net use como fallback, documentar limitaciones de seguridad y no registrar la línea completa con credenciales.
- No requerir privilegios de administrador.
- La aplicación debe funcionar sin privilegios elevados.
- La firma de código será importante en fases posteriores; documentar pasos recomendados para firmar binario.

Tarea programada:
El programa debe incluir opción para crear tarea programada.
Debe crearla con:
- nombre configurable;
- al iniciar sesión del usuario;
- ejecutar solo cuando el usuario haya iniciado sesión;
- no ejecutar con privilegios elevados por defecto;
- impedir instancias paralelas;
- retraso tras logon configurable, por defecto 30 segundos.
Debe permitir no crear tarea si el usuario lo desactiva.
Debe documentar que si no hay sesión interactiva no se podrán solicitar credenciales.

Proyecto Rust:
Generar estructura Cargo modular.
Propuesta de módulos:
- main.rs
- config.rs
- tray.rs
- windows_nas.rs
- credentials.rs
- scanner.rs
- exclusions.rs
- stability.rs
- planner.rs
- copy_engine.rs
- hasher.rs
- metadata.rs
- verifier.rs
- conflict.rs
- stats.rs
- logging.rs
- scheduler.rs
- scheduled_task.rs
- shutdown.rs
- errors.rs

Preferencias técnicas:
- Usar crates mantenidas y maduras.
- Para Windows APIs usar crate windows.
- Para configuración TOML usar serde + toml.
- Para logging estructurado usar tracing o alternativa equivalente.
- Para CSV usar csv crate.
- Para JSONL usar serde_json.
- Para hashing usar blake3 y opcional sha2.
- Para concurrencia usar tokio o threads estándar/rayon, justificando la elección.
- Para tray icon usar crate adecuada para Windows y justificar.
- Diseñar con manejo de errores explícito mediante thiserror/anyhow o equivalente.
- Evitar unsafe salvo encapsulado estrictamente en módulos Windows API.
- Documentar cada bloque unsafe.

Criterios de aceptación:
1. Compila en Windows 11 estable.
2. Arranca con archivo TOML externo.
3. Crea logs y métricas.
4. Detecta y valida R:.
5. Monta R: contra \\RAW-NAS\Repositorio si no está montada.
6. Solicita credenciales si el montaje falla y hay sesión interactiva.
7. No guarda credenciales.
8. No usa Robocopy.
9. No borra nunca nada del destino.
10. No sobrescribe archivos existentes.
11. Copia archivos estables a temporal.
12. Verifica hash completo.
13. Renombra a destino final solo tras verificación.
14. Preserva atributos y timestamps.
15. Mantiene jerarquía de carpetas.
16. Ignora symlinks y junctions.
17. Excluye patrones configurados.
18. Registra métricas por archivo, ciclo y acumuladas.
19. Maneja errores sin detener todo el proceso.
20. Tiene icono de bandeja con estado y acciones básicas.
21. Permite parada ordenada.
22. Permite crear tarea programada interactiva al logon.
23. Soporta rutas largas.
24. Soporta cargas mixtas de archivos grandes y pequeños.
25. Permite ajustar workers y buffer para optimizar 10 GbE.

Plan de pruebas requerido:
- Test unitarios de exclusiones.
- Test unitarios de generación de rutas destino.
- Test unitarios de nombres versionados.
- Test de estabilidad de archivo.
- Test de conflicto append-only.
- Test de hash igual/diferente.
- Test de archivo ya existente.
- Test de logs y CSV.
- Test de configuración TOML inválida.
- Test manual de montaje R:.
- Test manual de credenciales incorrectas.
- Test manual con NAS desconectado.
- Test de carga con muchos archivos pequeños.
- Test de carga con archivos grandes.
- Test de rutas largas.
- Test de Unicode.
- Test de interrupción durante copia y recuperación de `.partial`.
- Test de parada ordenada.

Entregables esperados:
1. Diseño técnico.
2. Estructura del proyecto Cargo.
3. Código Rust completo por módulos.
4. Archivo TOML de ejemplo.
5. Instrucciones de compilación.
6. Instrucciones de ejecución.
7. Instrucciones para crear tarea programada.
8. Guía de tuning para 10 GbE.
9. Guía de resolución de problemas.
10. Plan de pruebas.
11. Limitaciones conocidas.
12. Roadmap para v2:
    - instalador;
    - firma de código;
    - métricas avanzadas;
    - modo servicio;
    - UI más completa;
    - verificación selectiva por hash;
    - benchmarking automático.