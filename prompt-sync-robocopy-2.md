## Aclaración de requisitos (según tu respuesta)

*   **Semántica correcta**: *ingesta/archivado* “cortar y pegar” desde **origen (A)** hacia **destino (B)**. En **B no se borra nunca nada**; A actúa como cola de entrada. Si.
*   Lo anterior **invalida** cualquier comportamiento tipo espejo (*/MIR*, “extras procesados” que impliquen purga, “eliminar del destino lo que no exista en origen”). Esa parte pertenece al modelo antiguo y debe eliminarse del diseño. si.

## Qué quería decir con “operación controlada / parada ordenada”

Aunque el proceso sea 24/7, en operación real necesitas **controles de ciclo de vida** para evitar estados incoherentes:

*   **Single-instance**: impedir que se ejecuten **dos instancias** simultáneas (por doble click, relanzado automático, o tarea duplicada). Dos instancias pueden competir por los mismos ficheros y producir reintentos/errores intermitentes. Esto habria que hacerlo.
*   **Parada ordenada**: capacidad de detener el proceso sin dejar operaciones a medias (p. ej., finalizar un ciclo, cerrar log de forma consistente, registrar motivo de parada). Esto es relevante en reinicios, mantenimiento, actualizaciones o cierres de sesión. Esto habria que hacerlo.
*   **Ejecución desacoplada de sesión**: si dependes de una unidad mapeada (R:), su disponibilidad puede variar por sesión. Para 24/7, el control debe ser robusto (idealmente UNC o mapeo gestionado por el propio proceso). Esto habria que hacerlo.

## Ajustes técnicos imprescindibles para cumplir “no borrar nada en destino”

### 1) Eliminar la lógica de espejo

*   No debe existir ningún modo que “igual\[e] B a A” mediante borrados en B. En el documento actual se describe comportamiento compatible con espejo y con “extras procesados” bajo */MIR*, lo cual contradice el requisito. De destino no se borra nada.

### 2) Mantener borrado **solo en origen** y solo tras copia correcta

*   El borrado debe aplicarse exclusivamente a A, y condicionado a éxito de copia por archivo/directorio (modelo “move”). Si.

### 3) Blindajes anti-catástrofe (muy recomendables)

*   **Fail-closed**: si el destino no es accesible/estable, **no mover** (para evitar borrados locales con destino degradado). En tu caso, como quieres quitar trabajo al usuario, esto debe ir acompañado de reintentos y notificación. SI.
*   **Validación fuerte de rutas**: ya existe validación básica de origen/destino; conviene endurecerla para evitar apuntar por error a una ruta raíz o equivocada (medida defensiva ante pérdidas). Si.

## Resiliencia NAS y automatización (lo que indicas como prioritario)

En el documento se menciona montaje del NAS a R:\ y comprobaciones previas; para minimizar intervención humana, el diseño debería contemplar: 

*   **Preferencia por rutas UNC** (evita dependencia de letra de unidad/sesión).
*   Si se mantiene letra (R:):
    *   **Autorecuperación**: detectar desconexión, reintentar montaje con backoff, y registrar causa.
    *   **Señalización al usuario**: aviso cuando el NAS no pueda montarse tras N intentos (no para cada fallo transitorio).
*   **Telemetría operativa**: diferenciar error de credenciales, desconexión, permisos, “share” no disponible, etc., en lugar de tratar todo como “exit code ≥ 8”. El documento actual se centra en la máscara de bits y en penalizaciones temporales, pero no clasifica causas típicas NAS. Si.

## Permisos/ACL: criterio recomendado

El documento actual indica copia de datos/atributos/fechas, pero no propietario/ACL/auditoría. Pues añadimos propietario/ACL/auditoría.

*   Si el NAS debe permitir **restauración fiel** (incluyendo seguridad NTFS/SMB): entonces sí, conviene **preservar ACL/owner** (asumiendo compatibilidad de dominio/permisos y que el destino soporte esa semántica). Esto puede aumentar incidencias por permisos, pero es lo correcto para “backup restaurable”. Si.

## Recomendación operativa para 24/7 (sin cambiar el objetivo)

*   Ejecutarlo como **tarea programada**/servicio con reinicio automático ante fallo, con credenciales estables y sin depender de la sesión interactiva. La intención 24/7 del bucle infinito ya está en el diseño, pero el hosting debe ser igualmente robusto. Si.
*   Mantener rotación de logs y reducción de ruido (ya contemplado) para que el diagnóstico sea sostenible. Si.

## Dos decisiones que faltan para cerrar el diseño

1.  **Notificación**: ¿cómo debe avisar cuando no pueda montar/acceder al NAS tras X minutos? (toast local, Event Log, correo, Teams/webhook). Valdria una ventana, rollo popup.
2.  **ACL**: ¿el destino debe conservar permisos/propietario o solo contenido y timestamps? ambas.

Si respondes a esas dos, el diseño queda coherente con “mover a NAS sin borrar destino” y con la resiliencia que pides.
