# Spec · The Factory (panel de mando en Hermes Desktop)

**Talla:** L · **Repo:** software-fabrik (motor público) · **Tarjeta raíz:** t_7af36948 · **Diseño:** `docs/DESIGN.md` §4b, §4w, §4a ·
**Maquetas:** `docs/mockups/panel-fabrica.html`, `docs/mockups/panel-agentes.html` (v1) y `panel-fabrica-v2.html` (v2, adjunta a
la tarjeta raíz; se copia a `docs/mockups/` en IMPL-1).

## Objetivo
Un **puesto de mando** dentro de Hermes Desktop llamado **The Factory**: dice qué te toca, qué está atascado y por qué,
qué corre y con qué modelo, cuánto cupo queda y cómo va la máquina, con acciones directas de un clic. No es una copia del
Kanban (el detalle de tarjeta sigue en la página Kanban nativa) ni del chat (la conversación sigue con Opus). Es solo la
cara visible: el trabajo lo hacen las tarjetas y el gateway, y todo sigue igual con la app cerrada.

## Restricciones
- Plugin de escritorio que se carga en caliente (`desktop-plugins/`); **no se compila la app**.
- Motor público: **nada de ninguna organización en el código**. Tableros, repos, roles, modelos y reglas salen de la config fusionada
  (`fabrik config`), del pack y de `portfolio.yaml`.
- Acciones directas solo con la CLI de Hermes (`hermes kanban …`) o las herramientas de la fábrica (`fabrik-cupos`,
  `fabrik-memoria`, `fabrik-modelos tick`, que es quien hace `hermes -p <rol> config set …`). Sin modelo en el bucle,
  sin escribir en SQLite.
- Estilo solo con variables del tema (`var(--ui-*)`, `var(--accent)`, `currentColor`) y componentes del SDK; sin colores fijos.
- PRs ≤ 20 ficheros / ≤ 600 líneas de producción (no cuentan tests, `package-lock.json` ni el `plugin.js` generado).

## Criterios de aceptación

### Página y presencia (AC-1)
- **AC-1** Página `/the-factory` registrada con `ROUTES_AREA`, entrada **The Factory** en la barra lateral
  (`SIDEBAR_NAV_AREA`, codicon, ver D-3) y comando ⌘K «The Factory». Cabecera con el logo SVG de la maqueta v2
  (trazos `var(--accent)` y `currentColor`) y pestañas Inicio · Proyectos · Agentes · Cupos y costes · Memoria.
- **AC-1b** Chip en la barra de estado «The Factory · N» (N = elementos de «Te toca a ti»; destacado si hay atascadas);
  clic → página.
- **AC-1c** Sin colores fijos: un test busca `#hex`, `rgb(`, `hsl(` y nombres de color en `desktop/src/` y falla si los hay
  (salvo dentro de `var(...)`).

### Backend (AC-2)
- **AC-2** Backend Python `plugin/fabrica/dashboard/plugin_api.py` (namespace `/api/plugins/fabrica/`) que lee el Kanban en
  solo lectura, `gh`, la última foto de `fabrik-cupos`, el sistema y la memoria. Cada fuente con timeout propio; si una
  falla, su bloque devuelve `{"disponible": false, "motivo": "…"}` y el resto sigue.
- **AC-2b** Toda acción de escritura pasa por una lista cerrada de comandos (`hermes kanban --board B <verbo> …`,
  `fabrik-modelos tick`) ejecutados con `subprocess` sin shell, argumentos validados (slug de tablero, id
  `t_[0-9a-f]+`, modelo/proveedor de la lista permitida) y su salida resumida en la respuesta. Cada acción deja un comentario
  `🏭 The Factory: <acción>` en la tarjeta afectada.

### Inicio (AC-3)
- **AC-3a Te toca a ti**: PLAN bloqueados `needs_input` (con la primera línea del motivo = la pregunta), PRs listos para
  merge (tarjeta `PR*` hecha con `metadata.published_pr` abierto) y tarjetas bloqueadas `needs_input`/`capability`.
  Botones: **Ver** (abre la tarjeta en el Kanban nativo), **Aprobar** en los PLAN (comenta «adelante» + `unblock`), **Abrir PR**.
  Notificación del SO (`ctx.os.notify`) solo al aparecer un elemento nuevo.
- **AC-3b Atascadas** con motivo detectado y acción:
  - *error viejo de cupo en revisión*: tarjeta en `review` con `last_failure_error` que casa con el patrón de cupo
    (`rate.?limit|quota|429|usage limit|cupo|exhausted`) y sin run activo desde hace > 10 min. Acción **Desatascar** =
    `hermes kanban assign <id> none` y `assign <id> <perfil original>`; nunca se toca SQLite.
  - *sin cupo*: último run `rate_limited` y todas las bolsas de su cadena (`scripts/cupos.py: cadena_de/estado_cadena`)
    agotadas en la última foto. Acción **Pasar a <modelo>** = `hermes kanban set-model` al primer modelo de la cadena del
    rol + `reserva_final` cuyas bolsas estén < 90 %; si no hay ninguno, sin botón y con la hora de renovación más cercana.
  - *esperando merge*: tarjeta en `todo` cuyos padres están hechos salvo uno de tipo PR con PR abierto en GitHub; si la base
    del PR no es la rama por defecto, aviso «apilado sobre #N». Acción **Ver PRs**.
- **AC-3c Cadena**: grafo de dependencias de la feature en curso (componente conexo de las tarjetas en marcha, por tablero),
  nodos hecho / en marcha (con minutos) / pendiente, «k de n» hechas; clic en un nodo → tarjeta en el Kanban nativo.
- **AC-3d En marcha**: por tablero, tarjetas `running` con rol, modelo efectivo, minutos, **llamadas al modelo y
  herramientas** de su sesión; «activos / máximo» (`kanban.max_in_progress`); tableros en pausa nocturna con nº de aparcadas.
- **AC-3e Cupos**: barras por bolsa con % y hora de renovación de la última foto (`$FABRIK_DATA/logs/cupos.jsonl` vía
  `scripts/cupos.py`), hora de la foto, y aviso cuando la bolsa semanal de Claude (o la que marque la config como
  `cupos.aviso`) pase del 75 %.
- **AC-3f Máquina**: RAM y CPU (de `/proc`), titular y cola del turno de suites de `factory-test`.
- **AC-3g Memoria**: banco, documentos, nodos, última entrada, lo capturado hoy por fuente, **Buscar** (recall) y
  **Abrir grafo** (Control Plane de Hindsight en el navegador interno si el SDK lo permite, si no `ctx.os.openExternal`).
- **AC-3h Lanzar trabajo**: Nueva feature / Bug / Incorporar / Diagnosticar abren chat nuevo con `/fabrica <flujo>` vía
  `host.composer` (`setDraft('new', …)`); no se envía solo.
- Refresco con `useQuery` cada 15 s (30 s cupos/memoria) y `ctx.socket` solo como acelerador; nunca un bucle propio.

### Pestañas (AC-4)
- **AC-4a Proyectos**: catálogo de `portfolio.yaml` por producto, los de `ritmo: diario` fijados arriba; por repo: tarjetas
  activas, PRs abiertos de agentes (`agente/*`) y botón «Nueva feature aquí» (`/fabrica feature <repo>`).
- **AC-4b Agentes**: muestra y edita el **reparto dinámico** de `bin/fabrik-modelos` (D-5), no un modelo fijo por rol.
  - **Muestra**:
    - por rol, los modelos candidatos en orden, con la disponibilidad de cada ruta ahora (por cupo y por cuenta de
      Claude);
    - el modelo por defecto que tiene ahora el perfil;
    - las tarjetas de cada candidato en los últimos 7 días;
    - las cuentas de Claude con su % semanal y su tope;
    - el **informe de calidad** de `fabrik-modelos informe` (7, 14 o 30 días): tarjetas, hechas, % a la primera, rondas
      y fallos por rol × modelo.
  - **Edita** los candidatos por rol, el último recurso, los topes por bolsa y los topes por cuenta. **Guardar** valida y
    escribe `modelos.reparto` en la config personal.
  - **Aplicar ahora** lanza `fabrik-modelos tick`.

  Validaciones, configurables en `modelos.reglas` (D-6) y con mensajes claros que impiden guardar:
  1. los candidatos de los roles de código (`reglas.roles_codigo`) nunca casan con `reglas.prohibidos_codigo` (p. ej.
     `*flash*`);
  2. los modelos que casen con una clave de `reglas.sufijo_obligatorio` deben acabar en ese sufijo (p. ej. `gemini-*` →
     `-high`);
  3. cada rol tiene al menos un candidato, las rutas existen y los topes van de 1 a 100;
  4. los revisores pueden caer en otra familia que el programador (`reglas.revisor_otra_familia`).

  Sin `modelos.reglas` rigen la 3 y la 4 (motor público genérico). Si el reparto vigente incumple una regla, el panel lo
  avisa. Lo guardado afecta a tarjetas nuevas.
- **AC-4c Cupos y costes**: histórico de las bolsas (últimos 7 días de `cupos.jsonl`), `rate_limited` por día
  (`fabrik-cupos rate-limited --json`) y coste en $ de los proveedores de pago (los marcados de pago en el pool) desde el
  uso que registra Hermes; las suscripciones se muestran en tokens/% (nunca en $).
- **AC-4d Memoria** (pestaña): búsqueda (recall) con resultados y últimas lecciones.

### Consola (AC-5)
- **AC-5** Botón «Abrir consola aquí» en las tarjetas con worktree (En marcha, Atascadas, Cadena): terminal real
  (xterm.js) dentro del panel con un PTY del backend, arrancado en el worktree de la tarjeta (solo rutas bajo
  `<dir_codigo>/.factory-worktrees/`) con `.factory/env` cargado; título `<repo>/<slug>`; pestañas por tarjeta; aviso si la
  tarjeta está en marcha. Salida por `ctx.socket`, teclas y tamaño por `ctx.rest`; respaldo por sondeo si el socket no
  está, y botón «Abrir en terminal del sistema» (`fabrik-consola`). Máx. 6 consolas; se cierran al cerrar la pestaña o
  tras 30 min sin uso.

### Robustez (AC-6)
- **AC-6** Sin memoria (Hindsight caído o no instalado) el bloque Memoria dice «no disponible» en < 2 s y nada más se
  bloquea; sin `gh` o sin red, Te toca/Atascadas siguen con lo que sale del Kanban. El panel no guarda estado propio salvo
  preferencias de UI (`ctx.storage`): con la app cerrada no se pierde nada.
- **AC-6b** Instalación: `./install.sh` construye el plugin (`desktop/plugin.js`), enlaza `~/.hermes/plugins/fabrica` al
  checkout del motor y lo añade a `plugins.enabled`; avisa de activar la mitad de escritorio en Capabilities → Plugins.
  Sin `node`/`npm`, avisa y sigue (el resto de la fábrica no depende del panel).

## Fuera de alcance
Merge de PRs desde el panel (ver pregunta 2 del PLAN), editar tarjetas (eso es el Kanban nativo), compilar la app,
notificaciones distintas de «Te toca a ti».
