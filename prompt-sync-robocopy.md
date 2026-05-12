## 1. Objetivo general del script

### Deficion de origenes

Siempre que nos refiramos a directorios el A es el origen y el B la destino. Ejemplo: "A.Fotos vacaciones" y "B.Fotos de vacaciones". El principal es "A.Fotos vacaciones" y la carpeta des

La carpeta de origen es:

*   `carpeta-a`

La carpeta de destino es:

*   `carpeta-b`

Este script ejecuta una **mover de manera continua** entre dos carpetas locales usando **Robocopy**. Asegurando que los elementos de A se copien en B y posteriormente se eliminen en A.

El comportamiento principal es:

*   Mover al destino los archivos nuevos o modificados en el origen.
*   Ejecutarse indefinidamente en ciclos.
*   Registrar actividad, errores y cambios en un fichero de log.
*   Adaptar las pausas entre ciclos según haya cambios, errores o ausencia de actividad.

***

## 2. Configuración inicial

### 2.1. Definición de rutas

El script define tres rutas principales:

1.  **Origen**
    *   Carpeta principal desde la cual se moveran los datos. El origen es local.

2.  **Destino**
    *   Carpeta que recibirá los archivos. el destino es un NAS.

3.  **Log**
    *   Archivo donde se registrará la actividad del script.
    *   Se guarda en la carpeta `Documents` del perfil del usuario actual.

***

#### 2.1.1 Montaje de rutas NAS en letras

Montar ruta del nas en R:\ para usarlo como disco. 


### 2.2. Límite de tamaño del log

Se define un tamaño máximo de log de **10 MB**.

Cuando el archivo de log supera ese tamaño:

*   Se renombra el log actual.
*   Se le añade una marca temporal al nombre.
*   Se crea un nuevo archivo de log vacío.
*   Se registra que ha ocurrido una rotación.

Esto evita que el log crezca indefinidamente.

***

## 3. Exclusiones configuradas

El script excluye determinados directorios y archivos para evitar copiar metadatos, ficheros temporales o elementos propios de otros sistemas.

***

### 3.1. Directorios excluidos

Se excluyen carpetas asociadas a:

#### Syncthing

*   `.stfolder`
*   `.stversions`

Estas carpetas contienen metadatos internos de Syncthing y no deberían replicarse manualmente con Robocopy.

#### Windows

*   `$RECYCLE.BIN`
*   `System Volume Information`

Son directorios del sistema. Copiarlos puede producir errores, permisos denegados o inconsistencias.

#### macOS

*   `.Trashes`
*   `.Spotlight-V100`
*   `.fseventsd`

Son carpetas de metadatos utilizadas por macOS para papelera, indexación y eventos del sistema de archivos.

***

### 3.2. Archivos excluidos

Se excluyen archivos temporales o de metadatos:

*   Archivos temporales `*.tmp`
*   Archivos temporales que comienzan por `~`
*   `Thumbs.db`
*   `.DS_Store`
*   `desktop.ini`
*   Bloqueos de FreeFileSync `*.ffs_lock`
*   Bases de datos de FreeFileSync `*.ffs_db`

El objetivo es evitar sincronizar elementos que no forman parte del contenido real del usuario o que pueden generar conflictos.

***

## 4. Configuración de pausas entre ciclos

El script define tres tiempos de espera:

### 4.1. Pausa normal

*   **15 segundos**
*   Se aplica cuando no hay cambios detectados.

### 4.2. Pausa tras error

*   **60 segundos**
*   Se aplica cuando Robocopy devuelve un error grave.

### 4.3. Pausa tras cambio

*   **10 segundos**
*   Se aplica después de detectar cambios, copias o eliminaciones.

Esto permite que el script sea más reactivo cuando hay actividad y menos agresivo cuando no hay cambios.

***

## 5. Función de escritura de log

El script incluye una función dedicada a registrar mensajes en el log.

Cada entrada del log contiene:

*   Fecha.
*   Hora.
*   Nivel del mensaje.
*   Texto descriptivo.

Los niveles usados son principalmente:

*   `INFO`
*   `WARN`
*   `ERROR`

Ejemplo conceptual de una entrada:

*   Fecha y hora.
*   Nivel informativo o de error.
*   Descripción del evento.

Esta función centraliza el registro de actividad para que todo el script use el mismo formato.

***

## 6. Función de rotación de log

Antes de cada ciclo de sincronización, el script comprueba si el log supera los **10 MB**.

Si el tamaño se supera:

1.  Comprueba que el archivo de log existe.
2.  Calcula su tamaño.
3.  Si excede el límite configurado:
    *   Renombra el archivo actual.
    *   Añade una marca temporal al nombre.
    *   Lo conserva como archivo histórico.
    *   Crea un nuevo log.
    *   Registra el evento de rotación.

Esto permite conservar trazabilidad sin mantener un único archivo demasiado grande.

***

## 7. Función de interpretación del código de salida de Robocopy

Robocopy no utiliza códigos de salida convencionales simples. Sus códigos funcionan como una **máscara de bits**.

El script interpreta esos códigos y genera un resumen legible.

***

### 7.1. Código 0

Indica que no hubo cambios.

Resultado interpretado:

*   Sin cambios.

***

### 7.2. Código 1

Indica que se copiaron archivos correctamente.

Resultado interpretado:

*   Copiados OK.

***

### 7.3. Código 2

Indica que se detectaron elementos extra en destino.

Con `/MIR`, normalmente implica que esos elementos pueden haber sido eliminados del destino para igualarlo al origen.

Resultado interpretado:

*   Extras procesados.

***

### 7.4. Código 4

Indica discrepancias o inconsistencias.

Resultado interpretado:

*   Mismatches.

No siempre implica fallo crítico, pero requiere revisión.

***

### 7.5. Código 8

Indica fallos de copia.

Resultado interpretado:

*   Fallos de copia.

Este código ya se trata como error grave.

***

### 7.6. Código 16

Indica error fatal.

Resultado interpretado:

*   Error fatal.

Este es el nivel más grave.

***

## 8. Validaciones iniciales

Antes de iniciar la sincronización continua, el script comprueba las rutas.

***

### 8.1. Validación del origen

Si la carpeta de origen no existe:

1.  Muestra un mensaje de error en consola.
2.  Detiene la ejecución del script.
3.  Sale con código de error.

Esto impide ejecutar una sincronización destructiva desde una ruta inexistente.

***

### 8.2. Validación del destino

Si la carpeta de destino no existe:

1.  Muestra un aviso en consola.
2.  Crea la carpeta destino.
3.  Continúa con la ejecución.

Esto permite arrancar el proceso aunque el destino aún no haya sido creado.

***

## 9. Inicialización del log

Después de validar las rutas, el script prepara el archivo de log.

Si el log no existe:

*   Crea un nuevo archivo.
*   Añade una cabecera inicial con fecha y hora.

Después registra información estructural del servicio:

*   Inicio del servicio.
*   Ruta de origen.
*   Ruta de destino.
*   Directorios excluidos.
*   Archivos excluidos.

Esta cabecera permite identificar con qué configuración se inició la sincronización.

***

## 10. Inicialización de contadores internos

Antes de entrar en el bucle principal, se crean dos contadores:

### 10.1. Contador de ciclo

Empieza en `0`.

Se incrementa en cada iteración del bucle.

Sirve para saber cuántas sincronizaciones se han ejecutado desde el inicio del script.

***

### 10.2. Contador de errores consecutivos

Empieza en `0`.

Se incrementa cuando Robocopy devuelve un error grave.

Se reinicia a `0` cuando un ciclo finaliza sin error grave.

Permite aplicar una penalización mayor si hay errores repetidos.

***

## 11. Bucle principal infinito

El script entra en un bucle permanente.

Esto significa que no ejecuta una única sincronización, sino que trabaja como un proceso continuo.

En cada ciclo realiza las siguientes acciones:

1.  Incrementa el número de ciclo.
2.  Comprueba si debe rotar el log.
3.  Registra el inicio del ciclo.
4.  Ejecuta Robocopy.
5.  Captura el código de salida.
6.  Interpreta el resultado.
7.  Decide qué registrar.
8.  Decide cuánto tiempo esperar antes del siguiente ciclo.

***

## 12. Ejecución de Robocopy

En cada ciclo, el script lanza Robocopy con varios parámetros diseñados para una sincronización.

***

### 12.1. Modo cortar y pegar

El script usa un modo de mover. Hace que el contenido de origen pase a destino.

Esto implica:

*   cortar de origen y pegar en destino archivos nuevos.
*   Actualizar archivos modificados.
*   Eliminar del destino archivos que ya no existen en el origen.

Punto crítico:

*   El destino actúa como copia histórica.

***

### 12.2. Copia de datos, atributos y fechas

El script copia:

*   Datos del archivo.
*   Atributos.
*   Marcas temporales.

No copia:

*   Propietario.
*   ACL de seguridad.
*   Información de auditoría.

Esto reduce problemas de permisos, especialmente entre carpetas con distinto contexto de seguridad.

***

### 12.3. Conservación de fechas en directorios

El script preserva las marcas temporales de los directorios.

Esto ayuda a mantener consistencia en la estructura replicada.

***

### 12.4. Ejecución multihilo

Robocopy se ejecuta con **16 hilos**.

Esto permite copiar varios archivos en paralelo.

Ventajas:

*   Mayor rendimiento.
*   Mejor aprovechamiento de disco y CPU en copias con muchos archivos.

Posible inconveniente:

*   Mayor carga de I/O.
*   Puede afectar al rendimiento del equipo si se ejecuta sobre discos lentos o ubicaciones de red.

***

### 12.5. Reintentos limitados

El script configura:

*   Un único reintento por archivo.
*   Dos segundos de espera entre intento y reintento.

Esto evita que el proceso quede bloqueado durante demasiado tiempo por archivos abiertos, bloqueados o inaccesibles.

***

### 12.6. Tolerancia de marcas temporales

Se habilita tolerancia de dos segundos en timestamps.

Esto es útil cuando intervienen distintos sistemas de archivos o herramientas que no almacenan las fechas con la misma precisión.

Ejemplos:

*   NTFS.
*   FAT.
*   Recursos compartidos.
*   Sistemas sincronizados por otras herramientas.

***

### 12.7. Reducción de ruido en el log

El script evita registrar:

*   Porcentajes de progreso.
*   Listado completo de directorios.

Esto mantiene el log más limpio y orientado a eventos relevantes.

***

### 12.8. Aplicación de exclusiones

Robocopy recibe las listas de:

*   Directorios excluidos.
*   Archivos excluidos.

Por tanto, esos elementos no se copian ni se procesan durante la sincronización.

***

### 12.9. Escritura en log

La salida de Robocopy se añade al archivo de log existente.

No se sobrescribe el log anterior en cada ejecución.

Esto permite mantener trazabilidad de todos los ciclos.

***

## 13. Captura del resultado de Robocopy

Después de cada ejecución, el script lee el código de salida generado por Robocopy.

Ese código se almacena internamente y se pasa a la función de interpretación.

El objetivo es convertir un número técnico en un mensaje más comprensible.

***

## 14. Tratamiento de errores graves

Si el código de salida es **8 o superior**, el script considera que ha ocurrido un error grave.

Acciones realizadas:

1.  Incrementa el contador de errores consecutivos.
2.  Registra el ciclo como error.
3.  Registra el número de errores consecutivos.
4.  Decide la pausa antes del siguiente ciclo.

***

### 14.1. Menos de 5 errores consecutivos

Si todavía no se han alcanzado 5 errores seguidos:

*   El script espera 60 segundos.
*   Después intenta sincronizar de nuevo.

***

### 14.2. Cinco errores consecutivos

Si se alcanzan 5 errores consecutivos:

1.  Registra una advertencia.
2.  Aplica una pausa extendida de 5 minutos.
3.  Reinicia el contador de errores consecutivos a 0.

Esto evita ciclos agresivos en situaciones persistentes, como:

*   Destino desconectado.
*   Permisos incorrectos.
*   Archivos bloqueados.
*   Ruta inaccesible.
*   Error de disco.
*   Problemas de red si se adaptase a rutas UNC.

***

## 15. Tratamiento de cambios detectados

Si el código de salida está entre **1 y 7**, el script interpreta que hubo actividad, pero no un error grave.

Puede incluir:

*   Archivos copiados.
*   Archivos eliminados en destino por estar de más.
*   Diferencias menores.
*   Mismatches no críticos según el umbral configurado.

Acciones realizadas:

1.  Reinicia el contador de errores consecutivos.
2.  Registra el resultado del ciclo.
3.  Espera 10 segundos.
4.  Inicia un nuevo ciclo.

La pausa es menor que la normal para reaccionar con rapidez si sigue habiendo cambios.

***

## 16. Tratamiento de ausencia de cambios

Si el código de salida es **0**, significa que origen y destino ya estaban sincronizados.

Acciones realizadas:

1.  Reinicia el contador de errores consecutivos.
2.  No registra todos los ciclos para evitar saturar el log.
3.  Solo registra un mensaje cada 20 ciclos.
4.  Espera 15 segundos antes del siguiente ciclo.

Esto reduce el volumen del log durante periodos de inactividad.

***

## 17. Estrategia de logging

El script combina dos tipos de registro:

### 17.1. Registro propio del script

Incluye eventos como:

*   Inicio del servicio.
*   Inicio de cada ciclo.
*   Resultado interpretado.
*   Errores consecutivos.
*   Rotación del log.
*   Pausas extendidas.

***

### 17.2. Registro generado por Robocopy

Incluye detalles propios de Robocopy:

*   Archivos copiados.
*   Archivos omitidos.
*   Errores específicos.
*   Estadísticas de copia.
*   Resultado operativo de cada ejecución.

Ambos se escriben en el mismo archivo de log.

***

## 18. Comportamiento práctico del sistema

En ejecución normal, el flujo sería:

1.  Se inicia el script.
2.  Verifica que existe el origen. 
3.  Comprueba que el destino esta montado, en nuestro caso dos carpetas NAS. Si no montar el nas en R:\.
4.  Crea o reutiliza el log.
5.  Ejecuta Robocopy.
6.  Si hay diferencias:
    *   Mueve, actualiza o elimina elementos.
    *   Espera 10 segundos.
7.  Si no hay diferencias:
    *   Espera 15 segundos.
8.  Si hay errores:
    *   Espera 60 segundos.
    *   Si se repiten 5 veces, espera 5 minutos.
9.  Repite indefinidamente.

***

## 19. Riesgo principal del script

El punto más crítico es el uso de sincronización.

El destino contiene todo lo guardado en origen.

Consecuencia directa:

*   El destino debe contener información exclusiva que se quiera conservar.

Este script es una solución de backup versionado. Para no almacenar datos en local y guardarlos en server nas.

***


## 22. Evaluación técnica

El script está orientado a robustez operativa básica:

*   Tiene validación inicial.
*   Registra eventos.
*   Excluye metadatos problemáticos.
*   Evita copiar permisos complejos.
*   Controla el crecimiento del log.
*   Tolera errores temporales.
*   No bloquea demasiado tiempo por archivos inaccesibles.
*   Reduce ruido en los registros.
*   Ajusta las pausas según el resultado.
