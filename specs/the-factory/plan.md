# Plan · The Factory

Spec: `specs/the-factory/spec.md`. Las tareas son tarjetas del tablero de la fábrica (sin `tasks.md`).

## Decisiones (las toma el orquestador; cada tarjeta lleva las que usa)

- **D-1 Paquete.** Plugin unificado de Hermes con id **`fabrica`** en `plugin/fabrica/` (la carpeta que ya lleva la skill):
  `plugin.yaml` + `__init__.py` (mitad Python), `dashboard/manifest.json` (`{"name":"fabrica","label":"The Factory","api":"plugin_api.py"}`),
  `dashboard/plugin_api.py`, módulos de backend planos `dashboard/fx_*.py`, `desktop/src/**.js` (fuentes) y
  `desktop/plugin.js` (**generado, en `.gitignore`**). Instalación: enlace `~/.hermes/plugins/fabrica → $FABRIK_HOME/plugin/fabrica`
  (paquete «linked»: cada guardado recarga en caliente) + `plugins.enabled`.
- **D-2 Construcción del JS.** `esbuild` empaqueta `desktop/src/index.js` → `desktop/plugin.js` (ESM, `external`:
  `@hermes/plugin-sdk`, `react`, `react/jsx-runtime`), incluido xterm.js (`@xterm/xterm`, `@xterm/addon-fit`) y su CSS
  como texto inyectado. `desktop/package.json` + `package-lock.json` (deps fijadas). Script `scripts/plugin-desktop.sh
  build|watch|check`. Sin JSX: `jsx()` de `react/jsx-runtime`. Se comprueba con `hermes plugins doctor`/validador de
  escritorio que el cargador acepta el bundle (su lista de imports no es sintáctica: vigilar cadenas `from '…'` de xterm).
- **D-3 Icono lateral.** El SDK solo admite **codicon** en `SIDEBAR_NAV_AREA` (`SidebarNavContribution.codicon: string`).
  Propuesta ⭐ `tools`; alternativas `circuit-board`, `server-process`, `code`. El SVG del logo va en la cabecera de la
  página y, si `StatusbarItem.icon` acepta un elemento, también en el chip.
- **D-4 Registro sin choques.** `plugin_api.py` monta un `APIRouter` y carga, si existen, los módulos de la lista fija
  `MODULOS = ["fx_tablero", "fx_atascadas", "fx_acciones", "fx_sistema", "fx_memoria", "fx_proyectos", "fx_costes",
  "fx_reglas", "fx_agentes", "fx_consola"]` con `importlib.util.spec_from_file_location` (como kanban-gantt; el cargador
  de Hermes no pone `dashboard/` en `sys.path`). Cada módulo expone `registrar(router)`. En el front, IMPL-1 deja
  **stubs** de todas las secciones y pestañas (`desktop/src/inicio/{te_toca,atascadas,cadena,en_marcha,cupos,maquina,memoria,lanzar}.js`,
  `desktop/src/pestanas/{proyectos,agentes,costes,memoria}.js`, `desktop/src/consola.js`) ya importados desde
  `pagina.js`. Cada tarjeta posterior **solo edita sus ficheros**; así los PR-2..6 no chocan entre sí.
- **D-5 Agentes = reparto dinámico de `bin/fabrik-modelos`** (cambiada por el usuario al aprobar el plan, 24/10). La pestaña
  **no fija un modelo por rol**: muestra y edita el reparto con el que `fabrik-modelos` elige modelo y cuenta por cupo y
  calidad.
  - `fabrik-modelos` saca sus tablas del código. Lee `modelos.reparto` de la config fusionada (`scripts/fabrik_config.py`)
    y, si falta una clave, usa los valores actuales del script como valor por defecto. **Sin `modelos.reparto` se comporta
    igual que hoy** (test de no regresión). Claves:
    ```yaml
    modelos:
      reparto:
        rutas: {kimi: {proveedor: kimi-coding, modelo: kimi-for-coding, familia: moonshot, cuenta_claude: false, bolsas: [kimi_5h, kimi_7d]}, …}
        roles: {programador: [opus, kimi, agy-opus, sonnet], …}   # candidatos («brazos»), por orden de preferencia
        ultimo_recurso: gemini-high
        topes: {"5h": 92, sem: 97, "7d": 97, "30d": 60}           # % por tipo de bolsa
        topes_cuenta: {<cuenta>: 90}                               # % semanal por cuenta de Claude (personal)
    ```
    `topes_cuenta` es personal: el motor lo deja vacío y el valor actual del script pasa a la config del usuario (bloque
    en el handoff de PR-5). Así el motor queda sin nombres privados.
  - Salida legible por máquina: `fabrik-modelos estado --json` y `fabrik-modelos informe [días] --json`.
  - **Muestra**:
    - por rol, los candidatos en orden y la disponibilidad de cada ruta ahora (`estado`, también por cuenta de Claude);
    - el modelo por defecto que tiene ahora el perfil;
    - las tarjetas de cada brazo en los últimos 7 días;
    - las cuentas de Claude con su % semanal y su tope;
    - el **informe de calidad** (`fabrik-modelos informe`), con selector de 7, 14 o 30 días: por rol × ruta, tarjetas,
      hechas, % aprobadas a la primera, rondas por tarjeta y fallos.
  - **Edita**:
    - los candidatos por rol (añadir, quitar o reordenar entre las rutas existentes);
    - el `ultimo_recurso`;
    - los `topes` por bolsa;
    - los `topes_cuenta`.

    El catálogo de `rutas` es de solo lectura en el panel: una ruta nueva se añade en el yaml.
  - **Guardar**: valida (D-6) y escribe solo `modelos.reparto` en la config personal (`~/.config/fabrica/fabrik.yaml`).
    Respeta la ruta que use `fabrik_config.py` y conserva el resto del fichero.
  - **«Aplicar ahora»** lanza `fabrik-modelos tick`. Si no lo pulsas, el tick del servicio de cupos lo aplica en ≤10 min.
  - Las tarjetas con modelo ya fijado no se tocan. Nunca se edita `config.yaml` de un perfil a mano.
  - Deja de usarse `apply_profile_policy.py` desde el panel.
- **D-6 Reglas de modelos** en `modelos.reglas` (config personal o pack; el motor solo trae `revisor_otra_familia: true` y
  `roles_codigo: [programador, tester]`). Validan el **reparto** al guardar y también se muestran sobre el reparto vigente:
  ```yaml
  modelos:
    reglas:
      roles_codigo: [programador, tester]       # sustituye a ROLES_CODIGO de fabrik-modelos (sin último recurso)
      prohibidos_codigo: ["*flash*"]            # ningún candidato de un rol de código casa con estos globs de modelo
      sufijo_obligatorio: {"gemini-*": "-high"} # todo candidato y el último recurso
      revisor_otra_familia: true                # tester/revisor/seguridad con al menos un candidato de familia distinta
                                                # a alguna familia de los candidatos del programador
  ```
  Además, siempre:
  - cada rol tiene al menos un candidato;
  - las rutas citadas existen;
  - los topes son enteros entre 1 y 100.

  Familia = el campo `familia` de la ruta. Desaparece `cadena_codigo`: el experimento decide entre los candidatos. El bloque
  del usuario se le entrega en el handoff de PR-5 para que lo pegue en su `fabrik.yaml`.
- **D-7 Acciones.** Solo `hermes kanban --board <slug> {comment|unblock|assign|set-model}` y `fabrik-modelos tick`.
  Aprobar PLAN = `comment "adelante (desde The Factory)"` + `unblock`. Desatascar = `assign <id> none` + `assign <id> <perfil>`.
  Abrir tarjeta en el Kanban nativo = `host.navigate` a la ruta del Kanban con tablero y tarjeta (IMPL-2 confirma el
  formato en `apps/desktop/src/plugins/kanban`).
- **D-8 Tests.** Backend: `tests/panel/test_*.py` (unittest con `fastapi.testclient`, tableros SQLite de fixture creados
  con `hermes_cli.kanban_db` o el esquema copiado; `subprocess` simulado para acciones), lanzados por
  `tests/panel_backend_test.sh` (`uv run --with fastapi --with httpx --with pyyaml`), que descubre todos los `test_*.py`.
  Front: `tests/panel_desktop_test.sh` construye el bundle con un SDK falso (alias de esbuild a
  `tests/panel/sdk_falso.mjs`), llama a `register(ctx)` y comprueba rutas/nav/⌘K/chip, renderiza cada sección con datos de
  `tests/panel/fixtures/*.json` (react-dom/server) y pasa el test de colores fijos. Todo con `factory-test -- …`.
- **D-9 Piezas comunes y ficheros congelados (BASE).** Tras BASE, IMPL-2..7 van a la vez sin tocar un fichero común:
  - **R-1 Congelados** (solo se cambian en una tarjeta propia, nunca desde una IMPL de zona):
    `dashboard/plugin_api.py`, `dashboard/comun.py`, `desktop/src/{index,pagina,api,ui,chip,logo}.js`,
    `tests/panel/{base.py,comun.mjs,sdk_falso.mjs,desktop.test.mjs}`, `tests/panel_*_test.sh`, `install.sh`, `.gitignore`.
  - **R-2 Tests y fixtures por zona:** backend en `tests/panel/test_<zona>*.py`; front en
    `tests/panel/desktop_<zona>.test.mjs` con `construir('<zona>')` de `comun.mjs` (bundle propio en
    `desktop/.prueba/<zona>/`, corren en paralelo); fixtures en `tests/panel/fixtures/<zona>_*.json`.
    `desktop.test.mjs` no depende del contenido de ninguna sección (solo los `<h3>` de Inicio y que cada pestaña
    renderiza). `desktop_comun.test.mjs` vigila que `sdk_falso.mjs` exporte lo mismo que el SDK real.
  - **R-3 Botones y ctx compartidos** salen de `ui.js` y `api.js`: `abrirTarjeta({board, task_id})` (Kanban nativo,
    `#/kanban?board=…&task=…`; hoy el Kanban de Hermes no lee la query y abre el tablero que tenga activo),
    `abrirConsola({board, task_id})` (evento `fabrica:consola` en `window`) y `useAbrirConsola(cb)` (lo escucha la
    consola), y el ctx del plugin con `ctxPlugin()` (`os`, `storage`, `socket`, `runAction`…).
  - **R-4 Backend:** todo `fx_*.py` hace `import fabrica_comun as comun` (lo publica `plugin_api.py` antes de cargarlos):
    `tableros()`, `conectar_ro(ruta)`, `ejecutar(argv, timeout)`, `config()`, `fabrik_data()`, `no_disponible(motivo)`.
  - **R-5 Historia:** nunca rebase, amend ni squash en `agente/the-factory` (hay ramas apiladas encima): commits nuevos
    y merges.

## Contrato REST (namespace `/api/plugins/fabrica`)

Todas devuelven JSON; un bloque que no puede leer su fuente devuelve `{"disponible": false, "motivo": "…"}`.
Identificador de tarjeta en toda la API: `{board, task_id}`.

| Método y ruta | Respuesta / cuerpo | PR |
|---|---|---|
| `GET /salud` | `{ok, version, fuentes:{kanban,gh,cupos,memoria}}` | 1 |
| `GET /inicio/te-toca` | `{items:[{tipo:"plan"\|"merge"\|"bloqueada", board, task_id, titulo, detalle, pregunta?, pr_url?}]}` | 1 |
| `GET /inicio/en-marcha` | `{activos, maximo, grupos:[{board, pausa?:{hasta, aparcadas}, items:[{task_id, titulo, rol, modelo, desde, llamadas, herramientas, worktree?}]}]}` | 1 |
| `GET /inicio/atascadas` | `{items:[{board, task_id, titulo, motivo:"error_cupo_revision"\|"sin_cupo"\|"esperando_merge", detalle, accion?:{tipo:"desatascar"\|"set_model"\|"ver_prs", modelo?, proveedor?, prs?:[{numero,url,apilado_sobre?}]}}]}` | 2 |
| `GET /inicio/cadena` | `{cadenas:[{board, titulo, hechas, total, nodos:[{task_id, etiqueta, estado:"hecho"\|"en_marcha"\|"pendiente", minutos?}], aristas:[[padre,hijo]]}]}` | 2 |
| `POST /acciones/aprobar` | `{board, task_id}` → `{ok, salida}` | 2 |
| `POST /acciones/desatascar` | `{board, task_id}` → `{ok, salida}` | 2 |
| `POST /acciones/set-model` | `{board, task_id, modelo, proveedor}` → `{ok, salida}` | 2 |
| `GET /cupos` | `{foto, bolsas:[{bolsa, usado, renueva}], avisos:[texto]}` | 3 |
| `GET /maquina` | `{ram:{usado_gb,total_gb}, cpu:{carga,nucleos}, suite:{titular?, cola}}` | 3 |
| `GET /memoria` | `{disponible, banco, documentos, nodos, ultima_entrada?, hoy:{<fuente>:n}, grafo_url?}` | 3 |
| `POST /memoria/buscar` | `{q}` → `{disponible, texto}` | 3 |
| `GET /proyectos` | `{productos:[{nombre, repos:[{repo, ritmo, tarjetas_activas, prs:[{numero,titulo,url}]}]}]}` | 4 |
| `GET /costes` | `{bolsas_historico:[{bolsa, puntos:[[ts,%]]}], rate_limited:[{dia,n}], pago:[{proveedor, usd}]}` | 4 |
| `GET /agentes` | `{reparto:{rutas, roles, ultimo_recurso, topes, topes_cuenta}, estado:[{ruta, cuenta?, ok, motivo}], perfiles:[{rol, proveedor, modelo}], brazos_7d:[{rol, ruta, n}], cuentas:[{cuenta, sem_pct, renueva, tope}], reglas, avisos:[texto]}` | 5 |
| `GET /agentes/informe?dias=14` | `{dias, asignaciones, filas:[{rol, ruta, tarjetas, hechas, primera_pct, rondas_por_tarjeta, fallos}]}` | 5 |
| `POST /agentes/validar` | `{reparto}` (parcial: roles, ultimo_recurso, topes, topes_cuenta) → `{errores:[texto]}` | 5 |
| `POST /agentes/guardar` | igual → `{ok, errores, salida}` | 5 |
| `POST /agentes/aplicar` | `{}` → `{ok, salida}` (`fabrik-modelos tick`) | 5 |
| `POST /consola/abrir` | `{board, task_id}` → `{id, titulo, cwd, en_marcha}` | 6 |
| `WS /consola/{id}` | frames `{"datos": "<texto>"}` | 6 |
| `GET /consola/{id}/salida?desde=n` | `{datos, hasta, viva}` (respaldo por sondeo) | 6 |
| `POST /consola/{id}/entrada` · `/tamano` · `/cerrar` | `{datos}` · `{cols, filas}` · `{}` | 6 |

## PRs y tarjetas

Grafo del REPLAN t_d96d6f1f (BASE arranca en paralelo con la revisión de IMPL-1, REPLAN t_9f772621):
```
IMPL-1 → BASE ─┬→ CIERRE-1 → PR-1 ──────────────────────────────────┐
               ├→ IMPL-2 ∥ IMPL-3 → CIERRE-2 ─────────────→ PR-2 (tras PR-1)
  OLEADA 1     ├→ IMPL-4 ∥ IMPL-5 → CIERRE-3 ─────────────→ PR-3 (tras PR-1)
               ├→ IMPL-6 → CIERRE-5 ──────────────────────→ PR-5 (tras PR-1)
               └→ IMPL-7 → CIERRE-6 → SEG-6 ──────────────→ PR-6 (tras PR-1)
                           OLEADA 2 (cierres)               OLEADA 3 (PRs) → FIN
```
| PR | Contenido | Worktrees |
|---|---|---|
| PR-1 | IMPL-1 + BASE | `the-factory` (+ `the-factory-base`, que CIERRE-1 junta) |
| PR-2 | Inicio · tablero: IMPL-2 (te toca, en marcha, Aprobar en el front) + IMPL-3 (atascadas, cadena, acciones) | `the-factory-tablero` → `the-factory-atascadas` |
| PR-3 | Sistema y datos: IMPL-4 (cupos, máquina, memoria, lanzar) + IMPL-5 (proyectos, costes, pestaña Memoria) | `the-factory-proyectos` → `the-factory-sistema` |
| PR-5 | Agentes: IMPL-6 | `the-factory-agentes` |
| PR-6 | Consola: IMPL-7 + SEG-6 | `the-factory-consola` |

PR-2/3/5/6 parten de `agente/the-factory-base` (`git merge --ff-only`), van apilados con `--base agente/the-factory`, se
mergean con merge commit (no squash) **después** de PR-1 y no se tocan entre sí (D-4, D-9). CIERRE-4 y PR-4 quedan
absorbidos por CIERRE-3/PR-3.
