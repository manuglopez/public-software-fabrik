# Fábrica de software sobre Hermes — documento de diseño

> Documento vivo del motor (genérico). Fuente de verdad: el repo del motor (`docs/DESIGN.md`). Cualquier sesión nueva empieza leyendo esto + la skill `software-factory`.
> Lo específico de cada organización (productos, clientes, repos, decisiones propias) vive en su pack: **los packs pueden añadir flujos y diseño propio, ver `packs/<p>/docs`**.
> Última actualización: 2026-10-23.

## 1. Objetivo
Producir software robusto para los proyectos de **la organización GitHub configurada** (en `config/fabrik.yaml`) con un
sistema multiagente en Hermes: un **orquestador Opus** que dirige y **especialistas** baratos que ejecutan, sobre el
**Kanban de Hermes**, partiendo de una **spec de Spec Kit** cuando el cambio lo merece. La mayoría de repos son
**maduros** (hechos con Claude Code o a mano): el sistema convive con las sesiones de Claude Code del usuario.

## 2. Decisiones tomadas
| Tema | Decisión |
|---|---|
| Packs de organización | Cada organización vive en su pack, **fuera del motor**: repo git propio con `pack.yaml` en la raíz, instalado con `./install.sh --pack <url\|carpeta>` en `$FABRIK_DATA/packs/<nombre>` y identificado por el `nombre:` de `pack.yaml` (el nombre de la carpeta es irrelevante). `packs/*` está ignorado en el motor salvo `packs/ejemplo`. La historia del pack se extrajo con `git subtree split`. |
| Modelos | Personales: roles, `pool` y `reserva_final` van en `~/.config/fabrica/fabrik.yaml`. El motor es genérico (`anthropic`) y el pack solo declara `permitir_pago`. |
| Guardián de privacidad | `tests/sin_privado_test.sh` reúne las denylists del repo, las de los packs activos y las de `$FABRIK_DATA/packs/*` (sin `ejemplo`); sin ninguna avisa sin fallar. Los goldens de SOUL viven en el pack. |
| Lecciones | Por git en el pack: `fabrik-memoria leccion` escribe en el primer pack activo con `memoria.banco` (si no, en `$FABRIK_DATA/conocimiento`) y nunca en el motor; se comparten por rama + PR contra el `main` del pack. |
| Alcance | Solo las orgs configuradas (`owners` en `config/fabrik.yaml`); nada personal ni de otros hosts. Catálogo: `~/.hermes/factory/portfolio.yaml` (script `scripts/build_portfolio.py`, solo lectura). |
| Tableros | Uno **por producto**, no por repo (las dependencias del kanban no cruzan tableros). El reparto concreto de productos y tableros lo define el pack. |
| Impacto multi-consumidor | Toda tarjeta que toca una API declara el impacto en sus consumidores y variantes (apps, marcas, tenants). |
| Proveedores | Sin restricciones por repo. Las cuentas Anthropic se rotan antes de agotarse: cada cuenta tiene su propio umbral semanal para dejar de recibir trabajo nuevo, y ninguna ruta Claude recibe tarjetas nuevas desde el 75 % de la ventana de 5 h / 85 % semanal. Límites personales en `~/.config/fabrica/fabrik.yaml`. |
| Memoria | Built-in (MEMORY/USER) + skills (procedimientos) + contexto por repo (`.hermes.md`, `docs/agent-knowledge/`). Memoria compartida entre repos: **Hindsight** local (ver 4y), consultada **bajo demanda** (`fabrik-memoria`), no enchufada como proveedor automático de Hermes. |
| Aprobaciones humanas | **Spec + plan de tarjetas del orquestador + merge del PR**. Nada más. |
| Alcance del agente en PR | Protocolo de cierre del usuario: revisión Opus → `/code-review` → **Greptile CLI en local** → push → PR → Greptile automático en GitHub, **comentarios arreglados en el mismo PR** hasta 5/5 → `full-ci` → CI verde; el humano sólo hace merge. |
| Identidad GitHub | **Credenciales del usuario** (admin). `GH_TOKEN` en el `.env` de los perfiles que publican; denylist de merge/`--admin`/push a ramas protegidas; etiqueta `agente` + trailer `Generated-by`. |
| Canal | **App de escritorio de Hermes** (vista Kanban + notificaciones). |
| Paralelismo | **El usuario elige los proyectos y la prioridad, y puede cambiarla hora a hora** (prioridad por tarjeta/proyecto y pausa/reanudar desde el panel). **Regla de tests:** turno único solo para la suite completa o paralela de un repo pesado; tests dirigidos y `phpunit-replay` van sin turno (máx. `FX_TEST_DIRIGIDOS`=4) con lock exclusivo por BD efectiva; ligeros bash/node sin BD hasta `FX_TEST_LIGEROS`=3. Sin reglas fijas de día/noche: lo pesado va de noche sólo si el usuario lo programa. `max_in_progress` = 5 por defecto, ajustable desde el panel. |
| Ciclo de tarjeta | `flows/C0-ciclo-tarjeta-codigo.md` (v2): programador hace **TDD sin flakes**; **tester revisa los tests** (flakes, **≥ 98 % de cobertura del diff**, toda rama nueva con test, calidad); revisor Opus revisa el PR final. |
| Verificación local | Si el repo tiene **`phpunit-replay` usable, se usa**; si no, tests dirigidos. La suite completa es de CI. El tester no usa replay (flakes y cobertura necesitan ejecución real). |
| Features (F2) | `flows/F2-feature.md` (cerrado v1). Tallas **S** (sin Spec Kit) / **M** (spec + plan corto) / **L** (Spec Kit completo); **sin `tasks.md`**; specs **versionadas en el repo** dentro del primer PR; constitución del repo → modelos por rol (vía PR en F1). |
| Producción | Ningún agente accede a servidores ni producción (`ssh`, despliegues…): sólo el usuario, salvo la lista cerrada de `fabrik-prod` (§4v). |
| Tamaño de PR | **Minimizar nº de PRs** (uno por feature y repo) con presupuesto ≤ 20 ficheros / ≤ 600 líneas de producción; si no cabe, PRs secuenciales mergeables. |
| Norma de dirección | Opus dirige y revisa; escalera de modelo barata→cara; paralelo en lecturas, **nunca más de una suite pesada a la vez** (dirigidos sin turno con lock por BD); cada worktree con su propia BD `fx_<repo>_<slug>`; nada de `pkill` amplios. El pack puede enlazar las normas personales del usuario. |

## 3. Roles (perfiles Hermes) y modelos
| Perfil | Modelo | Proveedor | Estado |
|---|---|---|---|
| orquestador | Opus 5.5 | suscripción Claude | decidido |
| explorador | Gemini 3.8 Flash (medium) | `antigravity-oauth` (suscripción) | decidido, probado con tools |
| docs / mecánico | Gemini 3.8 Flash (medium) | `antigravity-oauth` | decidido |
| programador | **pendiente bake-off**: Kimi for Coding · DeepSeek Flash · DeepSeek V4 Pro · Gemini 3.8 Flash · Gemini 4 Argon | — | pendiente |
| tester | Gemini 3.8 Flash (high) | `antigravity-oauth` (suscripción) | decidido |
| revisor | Opus / Sonnet (familia distinta al programador) | suscripción Claude | decidido |
| seguridad | Opus | suscripción Claude | decidido |

Todos los proveedores están configurados y probados con tools (Kimi, DeepSeek, Antigravity) salvo Kimi con tools (solo texto).
Coste: DeepSeek en $ (tarifa oficial, punta 01–04 y 06–10 UTC L–V = ×2); suscripciones en tokens, tiempo y cuota.

### Pool de modelos y reserva final

Para optimizar coste, latencia y cuotas, el orquestador evalúa la dificultad técnica y el alcance de cada tarjeta en el momento de crearla (`kanban_create`) y le asigna explícitamente `model` y `provider`. Si una tarjeta no especifica modelo, hereda el configurado por defecto para su perfil/rol.

#### Niveles canónicos del pool y «Cuándo»

El pool organiza los modelos en cuatro niveles canónicos (fijos en el motor):

- **ligero**: tareas de lectura, síntesis, documentación (`docs`), triage y operaciones con pocas herramientas o sin ejecución compleja.
- **medio**: ejecución y diseño de tests, tareas de implementación acotadas (talla S), scripts de soporte y uso intensivo de terminal/herramientas.
- **dificil**: implementación con razonamiento profundo, integración de ramas, resolución de conflictos, cierre local (`CIERRE-LOCAL`) y tareas de talla M o L.
- **critico**: planificación general (`PLAN`), revisiones de arquitectura/seguridad (`revisor`, `seguridad`), cambios en tenancy, RBAC, migraciones de base de datos o pagos.

#### Modelos de pago y control de gasto

Cada entrada del pool declara:
- `proveedor` y `modelo`: identificadores exactos del proveedor y modelo.
- `herramientas` (`true`/`false`): si el modelo maneja llamadas a herramientas de forma fiable.
- `coste` (`suscripcion` o `pago`): distingue entre tarifas planas/suscripción/OAuth y proveedores con tarificación por token consumido.

Las entradas con `coste: pago` quedan **excluidas por defecto** salvo que la configuración activa declare explícitamente `permitir_pago: true`. Si `permitir_pago` es `false`, el orquestador no las asigna autónomamente y en su `SOUL.md` se listan como «De pago, solo si el humano lo pide: …».

Dentro de cada nivel, la lista está ordenada por preferencia de asignación (el modelo más barato o eficiente primero).

#### Reserva final (`reserva_final`)

Cada organización puede definir una `reserva_final` (`{proveedor, modelo}`) o establecer `reserva_final: null` para desactivarla.

Durante la aplicación de directivas (`apply_profile_policy.py`), la `reserva_final` se inyecta automáticamente como la **última** opción en la lista `fallback_providers` de todos los perfiles gestionados por la fábrica (`orquestador`, `explorador`, `programador`, `tester`, `revisor`, `seguridad`, `docs`), garantizando una vía de escape ante agotamiento de cuota o caídas de proveedor sin duplicar entradas. El perfil `conserje` no forma parte de `modelos` (no es un rol de ejecución del tablero) y su configuración de reserva es manual.

#### Generación dinámica del SOUL

Durante la instalación (`install.sh`), la tabla de modelos y niveles disponible para el orquestador en su prompt de sistema (`SOUL.md`) se genera dinámicamente a partir del pool resultante tras fusionar motor, pack y configuración personal.

## 4. Recursos de la máquina
16 hilos, 31 GB RAM, compartida con PhpStorm/Edge/sesiones de Claude Code del usuario.
- `kanban.max_in_progress` = 3; por perfil: programador 2, tester 1, resto 1.
- Cada worker bajo `systemd-run --user --scope -p MemoryMax=3G -p CPUQuota=300%` (a validar).
- Turno único solo para suite completa o paralela de un repo pesado (`factory-test`); dirigidos y `phpunit-replay` corren sin turno (máx. `FX_TEST_DIRIGIDOS`=4) con lock exclusivo por BD; ligeros (bash/node sin BD) máx. 3 a la vez. Tope de 4 procesos en paralelo, pausa de Dusk y MariaDB en modo tests: `docs/tests-compartidos.md` (con medidas).
- BD por worktree con usuario MariaDB restringido; **nunca** la BD de tests ni la de desarrollo del usuario.
- Antigravity: limitar pre-calentado de agy (~400 MB/proceso).

## 4z. Calidad medible (adoptado 2026-10-23: mejoras 1, 2 y 3)
1. **Métricas desde el primer día** (pestaña «Métricas» del panel; datos de eventos del Kanban + `gh`):
   tiempo idea→PR mergeado · **% de PRs aprobados a la primera** (sin `request_changes` del revisor) · rondas de revisión por tarjeta (tester y revisor) · flakes detectados · cobertura y **MSI** del diff · coste por PR (USD de DeepSeek + tokens de suscripciones) · **defectos escapados** (bugs/hotfix que apuntan a código mergeado por la fábrica en los 30 días siguientes).
   Cada umbral del sistema (98 % cobertura, MSI, 20 ficheros/600 líneas, tester obligatorio, tallas S/M/L) se revisa con estos datos, no por intuición.
2. **Pruebas de mutación sobre el diff** (Infection en PHP; Stryker en TS cuando toque): el tester ejecuta mutación sólo sobre las líneas cambiadas. Objetivo inicial **MSI cubierto ≥ 85 %**; cada mutante superviviente se justifica o genera `request_changes`. La cobertura dice «se ejecutó»; la mutación dice «el test lo habría detectado».
3. **Trazabilidad spec ↔ tests**: cada criterio de aceptación lleva id (`AC-1`, `AC-2`…) en la spec o en el cuerpo de la tarjeta (tallas S); cada test que lo cubre lo declara con `#[Group('AC-n')]` (PHPUnit) o `describe('AC-n …')` (TS). El tester genera la matriz criterio→tests; el revisor y `/speckit.converge` exigen **todo AC con al menos un test**.

## 4x. Puestos de trabajo (worktrees)
- **Un worktree por feature/PR**: `~/Code/.factory-worktrees/<repo>/<slug>`, rama `agente/<slug>`, BD `fx_<repo>_<slug>` (usuario MariaDB `fx`, solo `fx_*`). Los agentes de esa feature (programador, tester, revisor, docs) lo comparten **por turnos**: las tarjetas van en cadena, nunca dos escribiendo a la vez.
- **Un clon de fábrica por proyecto** (`<repo>/_repo`, de GitHub): su `develop` se resetea a `origin/develop` (Greptile local fiable). El checkout del usuario solo se lee (reflink de `vendor/`/`node_modules/`, plantilla de `.env`).
- Crear: `factory-prep <repo> <slug>` (~16 s). Tests: `factory-test` (turno para suites pesadas, lock por BD). Limpieza: `factory-gc` cada hora — PR mergeado/cerrado → borra worktree, rama local y BD(s); PR abierto → se conserva; sin PR > 7 días → aviso, no borra; nunca borra con cambios sin commitear o commits sin subir; BD `fx_*` huérfanas → se borran.

## 4y. Memoria compartida: opcional, nunca bloqueante
- La fábrica funciona **igual sin memoria**. Fuentes obligatorias de cada tarjeta: spec/AC, código, `CLAUDE.md`/`.hermes.md` del repo, handoffs de tarjetas padre. La memoria solo añade pistas de otros repos.
- Servidor: Hindsight local (`fabrica-memoria.service`, 127.0.0.1:8888, banco propio de la fábrica, extracción con DeepSeek Flash, embeddings `bge-m3` locales).
- Los agentes la consultan con `fabrik-memoria recall "…"` (timeout corto). Si el servidor no responde: aviso de una línea y sigue sin ella; nunca se reintenta ni se arranca desde el agente.
- Escritura: solo lecciones al cerrar tarjeta (síntoma → causa → solución → dónde) y siempre también en `conocimiento/lecciones/*.md` del repo, que es la fuente reconstruible.
- Lo recuperado es pista, no verdad: se verifica contra el código antes de usarlo.

## 4v. Producción desde las tarjetas (decisión del usuario, 2026-10-23; sustituye a «solo el humano toca producción»)
- Los agentes pueden ejecutar en producción **solo acciones de una lista cerrada por proyecto** con `fabrik-prod <proyecto> <accion>`; cada acción es exactamente `php artisan <accion>` sin argumentos en la ruta del proyecto (más `cloudflare:purge` vía API con token de solo purga). Config por máquina en `~/.config/fabrica/prod.conf` (fuera del repo; ejemplo ficticio en `config/prod.conf.ejemplo`).
- Sin aprobación por ejecución para las acciones de la lista (las elige el usuario); solo cuando la tarjeta lo pide. Todo queda en `logs/prod.log` y como comentario 🚀 en la tarjeta. Una acción a la vez por proyecto.
- Sigue siendo del humano: editar `.env` de producción, migraciones, deploys (Envoyer), rollback, borrar datos.
- `ssh`/`scp` directos siguen prohibidos a los agentes y no pueden leer la config ni las claves de SSH del usuario. **Límite conocido**: la lista negra es por patrón de comando y la clave es la del usuario; el cierre fuerte es la fase B: clave propia de la fábrica en el servidor con `command=` forzado (authorized_keys) que solo admite esas acciones, independiente del agente SSH del escritorio (que puede no firmar con la pantalla bloqueada).

## 4u. Kanban vivo (petición del usuario, 2026-10-23)
- **Vigilante** `fabrik-triage` (servicio, pasada cada 2 s): (1) enruta al orquestador las tarjetas creadas en la app (Triage/ajenas) y arrancan en ~8 s; (2) muestra las dependencias en el título («· ⏳ tras IMPL-1») y las quita al cumplirse; (3) **conserje**: cada comentario del humano en una tarjeta no en marcha lo interpreta Gemini 3.8 Flash low (perfil `conserje`, ~13 s) → aprobar/reanudar (desbloquea), cerrar (completa), nueva_tarea (sobre una terminada crea otra), nada; responde con un comentario 🤖.
- **Aparcamiento por cupo** (`fabrik-triage` + `scripts/cupos.py`; métrica con `fabrik-cupos rate-limited`): una tarjeta `ready` de rol cuya cadena de modelos no tiene cupo (según la última foto de `fabrik-cupos`) pasa a `scheduled` con un solo comentario ⏳ y se retoma al renovarse el cupo o pasar el reset; reserva con margen, override de modelo y tarjetas manuales no se aparcan, y sin foto fiable no se bloquea. **Límite conocido**: solo intercepta tarjetas `ready`; la primera ejecución de una tarjeta recién promovida por el gateway no se intercepta, y la columna `review` tampoco. Lo que se corta son los relanzamientos. Aparcar usa `hermes kanban schedule`, que también acepta tarjetas `running`: se vuelve a comprobar `ready` justo antes, pero queda una ventana de ~1-2 s (arranque de la CLI) en la que el gateway podría reclamarla.
- A un agente **en marcha** se le habla con «Message the running worker» (le llega en segundos); los comentarios normales solo se leen al reanudar.
- Cadena IMPL secuencial por diseño (mismo worktree): solo corre una IMPL a la vez por feature.

## 4s. Cupos, reparto y canal de avisos (feature `cuotas-bolsas`, 2026-10-25)

Spec y decisiones D-1..D-11 en `specs/cuotas-bolsas/`. Qué quedó fijado:

- **Una bolsa por cuenta.** Las cuentas de Claude **no** comparten bolsa (la premisa contraria era falsa y se retiró): `fabrik-cupos` mide cada una con `CLAUDE_CONFIG_DIR=<dir> claude -p "/usage"` y escribe `claude_5h@<cuenta>`, `claude_sem@<cuenta>`, `fable_sem@<cuenta>` con su porcentaje y su reset. La lectura anterior (`fetch_account_usage`) ignoraba la cuenta y duplicaba un solo dato. Si dos cuentas devuelven cifras idénticas se anota `errores.anthropic_sospecha`: se avisa, no se agrupa. La identidad de una cuenta sale de `claude auth status`, nunca de `.claude.json`, y no se leen ni registran tokens.
- **Reparto por margen/hora.** Entre las cuentas aptas `mejor_cuenta()` elige la de mayor `(tope − % semanal) / max(horas al reset, 0,5)`: iguala el agotamiento relativo y no el porcentaje a secas. `estado` lo muestra por cuenta.
- **`tick` con foto fresca.** Si la última foto tiene más de 180 s (`FABRIK_FOTO_MAX_EDAD`), `tick` ejecuta `fabrik-cupos registrar` antes de decidir y de avisar; si falla sigue con la vieja y avisa por stderr. Una bolsa con el reset ya pasado cuenta como renovada. `asignar` no refresca.
- **Canal de avisos a prueba de cuota** (`scripts/canal_avisos.py`). Al cruzar `modelos.reparto.aviso_bolsa` (98 %) una bolsa, un `hermes send -t ${FABRIK_AVISO:-telegram}` (sin modelo: no vive en ninguna bolsa) dice qué bolsa, cuánto queda y qué roles se conmutaron; el estado `modelos-avisos.json` evita repetirlo hasta el siguiente reset y reintenta si el envío falla. `fabrik-modelos comprobar` (y `tick`, un aviso al día) marca ⛔ si el perfil `default` no tiene reservas fuera de la bolsa de su modelo principal o si un cron de aviso con modelo fijado usa una bolsa de Anthropic.
- **Métrica semanal** (`fabrik-cupos semana [--dias N] [--json] [--sin-gh]`, lógica en `scripts/metrica_semanal.py`; feature `costes-revision`). Mide cada semana, por tablero, si la revisión proporcional y el auto-chequeo ampliado bajan el coste antes del PR. Ventana `[ahora − N días, ahora]` (N = 7, mínimo 1), todo en solo lectura. **Coste equivalente** = `input + cache_write + 0,1·cache_read + 5·output` tokens de las sesiones `kanban` (de las `state.db` de los perfiles); la sesión se atribuye a la tarjeta que sigue a `kanban task ` en su primer mensaje de usuario y esta, al tablero cuyo `kanban.db` la contiene (lo que no se puede atribuir va a `sin_tablero`). Salen: coste por tarjeta terminada y por línea de PR mergeado (`additions + deletions` vía `gh pr view`), rondas por tarjeta (`changes_requested` / tarjetas terminadas con `review_requested`), % de ejecuciones `rate_limited` y ejecuciones de Greptile por PR mergeado (locales, del registro de `factory-greptile`, más las reseñas de `greptile-apps[bot]` en GitHub). Cada división por cero da `null` (`—` en la tabla); con `--sin-gh` no se llama a `gh` y lo que depende de PRs queda a `null`. Una BD o una llamada a `gh` que falla avisa por stderr y se sigue.

## 4w. Consola desde la tarjeta (petición del usuario, 2026-10-23)
- Cada tarjeta con worktree tendrá en el panel «Fábrica» un botón **«Abrir consola aquí»**: abre una terminal **real** (con TTY: sirve `sudo`, `tinker`, etc.) ya situada en `~/Code/.factory-worktrees/<repo>/<slug>` y con `.factory/env` cargado (BD propia de la tarjeta), titulada `<repo>/<slug>`.
- Implementación: **consola integrada en el panel** (no la terminal de Hermes, que los plugins no pueden abrir): vista **xterm.js** dentro del plugin + **PTY real** en el backend Python del plugin (`dashboard/plugin_api.py`, módulo `pty`), arrancado en el worktree con `.factory/env` cargado. Salida por `ctx.socket` (WebSocket del plugin), teclas por `ctx.rest` (POST). Pestañas por tarjeta; se cierran al cerrar la tarjeta. Respaldo: «Abrir en terminal del sistema» (`fabrik-consola`).
- Aviso visual si la tarjeta está **en marcha**: el agente está escribiendo en ese worktree; mejor mandarle un mensaje que tocar ficheros a la vez.
- Los comandos que ejecuta el humano en esa consola no pasan por las prohibiciones de los agentes: son suyos.

## 4a. Higiene de contexto de los agentes (petición del usuario: que «respiren»)
- **Una tarjeta = un proceso nuevo = contexto limpio.** Cambiar de tarea nunca arrastra contexto; lo que pasa de una tarjeta a otra son handoffs cortos y estructurados (summary + metadata), no transcripciones.
- Tarjetas pequeñas (porciones IMPL) → contextos pequeños. Goal-mode con `goal_max_turns` acotado.
- Compactación por **tokens absolutos por rol** (compacta en lo que llegue antes: 50 % de la ventana o el tope): programador/tester 160k, explorador/docs 300k, orquestador/revisor/seguridad 200k. `proactive_prune_tokens 80000` (poda resultados grandes viejos), `micro_compact true`. Un % solo no sirve: el 40 % de 1M son 400k, demasiado. Se ajusta con las métricas de uso real.
- Prompt de sistema delgado: perfiles de agentes sólo con skills de `software-development`, `devops`, `autonomous-ai-agents` (antes heredaban 61), plugin `hermes-seo` desactivado; `.hermes.md` de cada repo corto (índice, no copia de CLAUDE.md).
- `factory-test` devuelve resumen (fallos + conteos), el log completo va a fichero.
- Panel: uso de contexto por agente en marcha y aviso si pasa del 70 %.

## 4b. Interfaz (todo dentro de Hermes Desktop) — APROBADA por el usuario
Panel = portada y mando (no es el motor: el trabajo son tarjetas que ejecuta el gateway). Botones de dos tipos: los que abren conversación (chat nuevo con `/fabrica …` vía `host.composer`) y los de acción directa (backend Python del plugin → comandos `hermes kanban …`/`config set`). Chat = conversación y tarjetas vivas con botones. Página Kanban = detalle. Notificaciones del SO = avisos.
1. **Chat con Opus (perfil default)** = puerta de entrada. Skill `fabrica` → slash `/fabrica feature|bug|incorporar|diagnostico|estado`; el lenguaje natural también vale. La fase de spec (Spec Kit) es conversación aquí.
2. **Página Kanban nativa** (selector de tablero por producto) = detalle de tarjetas, aprobación de PLAN, columna review.
3. **Plugin de escritorio «Fábrica»** (página propia + entrada en barra lateral + ⌘K + chip en barra de estado + notificaciones del SO):
   Inicio = *Te toca a ti* (planes por aprobar, PRs listos para merge, tarjetas bloqueadas) · *Lanzar trabajo* · *En marcha* · *Máquina* (RAM/CPU, cola de suites) · *Costes*.
   Pestañas Proyectos (catálogo por producto), Agentes, Costes. Backend Python (`plugin_api.py`) que lee portfolio.yaml, kanban, `gh` y el sistema.
   Maqueta: `mockups/panel-fabrica.html`.
4. **Modelos editables por el usuario** (pestaña Agentes, maqueta `mockups/panel-agentes.html`): por rol, selector de modelo (sólo modelos de proveedores configurados y probados con tools), esfuerzo, reserva (fallback); muestra si es pago o suscripción y la nota del bake-off. Guardar = `hermes -p <rol> config set model.provider/model.default` + fallback; afecta a tarjetas nuevas. Validaciones: revisor de otra familia que el programador; modelo probado con tools. Botón «Probar modelos» = prueba rápida de tools. Cambio puntual por tarjeta (`hermes kanban set-model`) desde la tarjeta, el plan o el chat; regla automática tenancy/RBAC/migraciones/facturación → Opus.

## 4c. Proyectos «calientes» (el usuario trabaja en ellos casi a diario) — propuesta
Qué repos son «calientes» y con qué ritmo (`diario` / `a-demanda`) lo confirma el usuario y se anota en el pack. Las reglas de convivencia aplican también a PRs y ramas de otras personas (colaboradores humanos, dependabot).
- **Detección automática** para `a-demanda` (y como red de seguridad en cualquier repo): el repo pasa a «caliente» si hay commits del usuario en las últimas 48 h, cambios sin commit en su checkout o una sesión de Claude Code reciente en ese repo (`~/.claude/projects/<slug>/` < 24 h). Mientras esté caliente, se aplican las reglas de abajo.
- Resto de repos: reglas normales, sin restricción diurna.
- `portfolio.yaml`: campo `ritmo: diario|semanal|ocasional` (propuesto automáticamente, confirmado por el usuario).
- **Antes del PLAN**, el orquestador inventaría el trabajo vivo del usuario en ese repo: PRs abiertos, ramas con commits recientes, sus worktrees, cambios sin commit en su checkout → ficheros que está tocando. El plan evita esos ficheros; si no puede, lo marca en el PLAN para que el usuario decida.
- Los agentes **nunca** tocan el checkout ni los worktrees del usuario; los suyos van aparte (`~/Code/.factory-worktrees/<repo>/<slug>`), sin ensuciar sus carpetas.
- Rebase sobre `develop` antes del PR y antes de la revisión final; conflicto con algo ya mergeado → lo resuelve el programador; conflicto con un PR abierto del usuario → bloquea y pregunta.
- **Coordinación de tests para todos**: `factory-test` también lo usan las sesiones de Claude Code del usuario (regla en su CLAUDE.md / director-de-orquesta) para que agentes y usuario no se pisen (turno único para suite completa/paralela de repo pesado; dirigidos sin turno en `locks/dirigidos.d/`, máx. `FX_TEST_DIRIGIDOS`=4; lock por BD en `locks/bd.d/`). De día, en repos calientes, prioridad al usuario en la cola pesada. Orden de la cola pesada: los repos que casan con `$FABRIK_DATA/locks/prioridad` (o `FX_TEST_PRIO=1`) van delante de los que esperan sin prioridad (se apuntan en `locks/prio.d/<pid>` y los demás les ceden el turno); no se interrumpe la suite en marcha. **Ligeros:** un comando bash/node/python sin tokens de PHP/BD/npm (lista cerrada en `bin/factory-test`) no coge turno ni lock de BD: usa `locks/ligeros.d/<n>.lock` (máx. `FX_TEST_LIGEROS`, def. 3) y `estado` lo lista como `ligero: …`; `FX_TEST_PESADO=1` fuerza la cola.
- Panel: «Mis proyectos» fijados arriba en Inicio, con actividad de agentes y **avisos de colisión** («el agente toca X, que tú tienes cambiado en la rama Y»).

## 5. Flujos (a diseñar uno a uno)
| # | Flujo | Disparo | Salida |
|---|---|---|---|
| F0 | Catálogo | cron semanal | portfolio.yaml actualizado + aviso de cambios de estado |
| F1 | Onboarding de repo maduro | primera tarea en un repo | `.hermes.md` ≤20k, skills expuestas, memoria de Claude destilada, Spec Kit con integración hermes, baseline de tests |
| F2 | Feature con spec | usuario + Opus con Spec Kit | grafo de tarjetas → PRs |
| F3 | Bugfix | tarjeta directa (sin spec) | PR |
| F4 | Cambio de contrato de API | variante de F2 | PR API + PRs de consumidores enlazados |
| F5 | Cierre de PR | PR abierto | protocolo del repo (p. ej. lint, análisis estático, verificación local, `/check-pr`, `/greploop` 5/5, etiqueta `full-ci`) |
| F6 | Diagnóstico de repo dormido/abandonado | usuario lo revive | informe de estado → decisión |

## 6. Bake-off de modelos (PAUSADO)
- Comparación de modelos por rol sobre tareas reales del propio repo: tests ocultos del PR real + revisión ciega + coste.
- Antes de relanzar: aislar el entorno de los hijos (`env -i` + directorio de trabajo propio, sin acceso al código real ni a las BD del usuario), límites de recursos y auditoría de transcripciones.
- El arnés y los resultados concretos viven en el pack de cada organización (`packs/<p>/docs`).

## 7. Preguntas abiertas
1. ~~Proveedor de memoria externo~~ Resuelto: Hindsight (vectorial + grafo, local, compartido por todos los perfiles), de momento **bajo demanda**. Revisar con métricas si conviene el modo automático (recall/retain en cada turno) para el chat del usuario.
