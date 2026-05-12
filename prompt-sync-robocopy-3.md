## Prompt técnico final — Script de ingesta continua con Robocopy (versión corregida y endurecida)

### 1. Objetivo del sistema

Diseñar un script de **ingesta continua 24/7** basado en Robocopy que implemente un flujo **cortar/pegar (move)** entre:

*   **Origen (A)** → almacenamiento local (cola de entrada)
*   **Destino (B)** → NAS (repositorio persistente)

### Comportamiento obligatorio

*   Todo archivo en A debe:
    1.  Copiarse a B
    2.  Validarse
    3.  Eliminarse de A
*   En **B no se elimina absolutamente nada en ningún caso**
*   El destino funciona como **repositorio acumulativo (append-only)**

### Comportamiento prohibido

*   Uso de:
    *   `/MIR`
    *   Cualquier mecanismo de sincronización espejo
    *   Eliminaciones en destino
    *   Procesamiento de “extras”

***

## 2. Arquitectura operativa

### 2.1 Ejecución continua

*   Bucle infinito
*   Adaptación de pausas según resultado:
    *   Sin cambios → 15 s
    *   Con cambios → 10 s
    *   Error → 60 s
    *   5 errores seguidos → 5 min

### 2.2 Single-instance (obligatorio)

*   Solo puede ejecutarse **una instancia**
*   Debe prevenir:
    *   Ejecuciones múltiples
    *   Competencia sobre archivos
    *   Estados inconsistentes

### 2.3 Parada ordenada

*   El proceso debe:
    *   Finalizar ciclo actual
    *   No interrumpir copias en curso
    *   Cerrar logs correctamente
    *   Registrar motivo de parada

***

## 3. Gestión del NAS (automatización completa)

### 3.1 Conectividad

*   Preferencia: **ruta UNC**
        \\NAS\share
*   Alternativa: unidad mapeada (R:), con control interno

### 3.2 Recuperación automática

*   Detección de:
    *   NAS inaccesible
    *   Desmontaje
    *   Error de credenciales
*   Comportamiento:
    *   Reintentos con backoff progresivo
    *   Bloqueo de operaciones hasta recuperación

### 3.3 Notificación al usuario

*   Condición: fallo persistente
*   Medio: **popup local**
*   Contenido:
    *   Error
    *   Tiempo sin conexión
    *   Estado del sistema

***

## 4. Seguridad operativa

### 4.1 Fail-closed (crítico)

*   Si el destino no está disponible:
    *   ❌ NO copiar
    *   ❌ NO borrar en origen
*   Garantiza:
    *   Cero pérdida de datos

### 4.2 Validación estricta de rutas

*   Validar:
    *   Existencia
    *   No rutas vacías
    *   No rutas raíz peligrosas
*   Evita:
    *   Borrados masivos por error de configuración

***

## 5. Lógica de transferencia

### 5.1 Modelo de movimiento

*   Copia + eliminación en origen
*   Borrado condicionado a éxito

### 5.2 Parámetros Robocopy requeridos

*   Multihilo (≈16)
*   Reintentos bajos (1)
*   Espera corta entre reintentos (2s)
*   Tolerancia timestamps
*   Reducción de ruido log

### 5.3 Exclusiones

Directorios:

*   `.stfolder`, `.stversions`
*   `$RECYCLE.BIN`, `System Volume Information`
*   `.Trashes`, `.Spotlight-V100`, `.fseventsd`

Archivos:

*   `*.tmp`, `~*`
*   `Thumbs.db`, `.DS_Store`, `desktop.ini`
*   `*.ffs_lock`, `*.ffs_db`

***

## 6. Gestión avanzada de errores

### 6.1 Interpretación base

*   Uso de códigos Robocopy (bitmask)

### 6.2 Clasificación adicional

Identificar tipo de error:

*   Red (NAS no accesible)
*   Permisos
*   Archivo bloqueado
*   Unidad no montada

### 6.3 Respuesta adaptativa

*   Error leve → retry normal
*   Error persistente → backoff
*   Error crítico → notificación + pausa extendida

***

## 7. Permisos y seguridad NTFS (modo completo)

### Se debe copiar:

*   Datos
*   Atributos
*   Fechas
*   **ACL**
*   **Propietario**
*   **Auditoría**

### Objetivo

*   Restauración completa del sistema de archivos

### Riesgos asumidos

*   Mayor complejidad en permisos
*   Posibles conflictos en NAS

***

## 8. Logging

### 8.1 Características

*   Archivo único
*   Rotación a 10 MB
*   Niveles:
    *   INFO
    *   WARN
    *   ERROR

### 8.2 Contenido

*   Eventos del sistema
*   Resultado por ciclo
*   Salida de Robocopy
*   Errores y reconexiones

### 8.3 Eventos adicionales obligatorios

*   Inicio del servicio
*   Parada ordenada
*   Reconexión NAS
*   Activación fail-closed
*   Notificaciones generadas

***

## 9. Comportamiento global esperado

Sistema autónomo que:

*   Ejecuta **24/7 sin intervención**
*   **Mueve** archivos desde local → NAS
*   **Nunca elimina en destino**
*   Se **autoprotege ante fallos**
*   Se **autorecupera de desconexiones NAS**
*   Informa al usuario solo en fallos relevantes
*   Mantiene trazabilidad completa

***

## 10. Resumen operativo

Flujo final:

    [ A (local) ] → copiar → [ B (NAS) ] → validar → borrar en A
                             ↑
                     nunca se elimina nada

Condición crítica:

    Si B no está disponible:
        NO se mueve nada
        NO se borra nada

***

Este prompt define un sistema **coherente, seguro y alineado con producción real**, eliminando completamente la ambigüedad del diseño anterior y evitando pérdidas de datos.
