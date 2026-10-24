# C0 — Ciclo de una tarjeta de código (común a F2 feature y F3 bugfix; los packs pueden añadir variantes: ver `packs/<p>/docs`)

Estado: v2 (2026-10-23). Decisiones del usuario incorporadas.

## Principios
- **El programador hace TDD** (test rojo → código → verde) y escribe tests deterministas (sin flakes).
- **El tester es el revisor de los tests**: busca flakes, valora la cobertura y la calidad de los tests. No escribe el código de producción.
- **El revisor (Opus, otra familia de modelo) es la última puerta** sobre el PR real, ya pasado por Greptile y CI.
- **Pocos PRs, pero acotados**: un PR por feature y repo, con presupuesto de tamaño; si no cabe, el orquestador lo parte en PRs secuenciales que se pueden mergear por separado.
- **El humano aprueba 3 cosas**: spec, plan de tarjetas y merge. Canal: app de escritorio de Hermes.
- **Credenciales GitHub del usuario** (admin de la org), con salvaguardas:
  - `GH_TOKEN` en el `.env` de cada perfil que publica o verifica PRs (el kernel lee los checks como el perfil asignado). Lo pone el usuario; los agentes nunca manejan el token.
  - **Denylist** en perfiles de agentes: `gh pr merge`, `--admin`, `git push` a `develop`/`main`/`release/*`, `--force` fuera de su rama, borrar ramas ajenas, cambiar reglas del repo, y **cualquier acceso a servidores/producción** (`ssh`, `scp`, `rsync` remoto, despliegues, `artisan` contra entornos remotos) — producción sólo la toca el usuario (salvo las acciones de lista cerrada de `fabrik-prod`, y solo si la tarjeta las pide).
  - Trazabilidad: PRs con etiqueta `agente`, commits con trailer `Generated-by: hermes/<perfil>/<modelo>`.

## Grafo por PR (una rama = un worktree = un PR)
```
[PLAN ✋] ─► IMPL-1 ─► … ─► CIERRE-LOCAL ─────────► PR ─► [MERGE ✋]
orquestador  programador     programador               programador
             └ review: tester└ review: revisor (Opus)  └ Greptile remoto hasta 5/5 + CI verde
```
Protocolo de cierre del usuario (memorias `revision-antes-de-pr`, `feedback-code-review-before-greptile-local`):
revisión final Opus → `/code-review` sobre el diff completo → **Greptile CLI en local** → arreglar → push → PR →
Greptile automático en GitHub → **los comentarios se arreglan en el mismo PR** hasta 5/5 → `full-ci` → CI verde.
- **IMPL en paralelo dentro del PR** (desde 2026-10-23): las IMPL que no comparten ficheros van a la vez, cada una en su **sub-worktree** (`factory-prep <repo> <feature>--<impl> --desde <feature>`, rama que sale de la de la feature). Nunca dos agentes en el mismo worktree. CIERRE-LOCAL las junta con `factory-juntar` (merge --no-ff; se para en conflicto para resolverlo) y verifica todo. Solo van en cadena las que tocan los mismos ficheros o dependen de una base común.
```
            ┌► IMPL-A (sub-worktree a) ─┐
[PLAN ✋] ──┼► IMPL-B (sub-worktree b) ─┼► CIERRE-LOCAL (factory-juntar + verificación) ► PR ► [MERGE ✋]
            └► IMPL-C1 ► IMPL-C2 (c)  ──┘
```
- El paralelismo también está **entre PRs y entre repos** (p. ej. API y front de una feature en un mismo producto).
- Cada tarjeta IMPL es una porción coherente (p. ej. modelo+regla, endpoint, recurso de salida).
- El orquestador (padre de todo) despierta cuando terminan las hijas y decide si falta trabajo (p. ej. tarjetas de consumidores si cambia un contrato de API).

| Tarjeta | Perfil | Qué hace | Termina con |
|---|---|---|---|
| **PLAN** | orquestador (creada `blocked`) | Unidades de PR, porciones IMPL, decisiones compartidas, impacto en otros consumidores o variantes del producto, presupuesto de tamaño por PR. | El humano la completa desde la vista Kanban. |
| **IMPL-n** | programador | TDD: test rojo primero (se demuestra rojo), código, verde. Tests dirigidos, pint, phpstan sobre lo tocado, `changelog.d/`, commits. Reglas anti-flake (abajo). Auto-chequeo antes de pedir revisión (cobertura del diff ≥ 98 %, MSI ≥ 85 % o 0 mutantes vivos, AC con test; cifras en summary y metadata). | `kanban_request_review(reviewer="tester")` |
| (review de tests) | tester | Checklist de abajo: verifica las cifras del programador, flakes, cobertura del diff, calidad. | `kanban_complete` con métricas, o `kanban_request_changes` → vuelve al programador |
| **CIERRE-LOCAL** | programador | Rebase sobre `origin/develop`; verificación local (`phpunit-replay` si es usable); `/code-review` sobre el diff completo contra el merge-base; **`greptile review -b develop --agent`** en local y arreglar lo que salga, repitiendo hasta que no haya hallazgos accionables. Nada se sube todavía. | `kanban_request_review(reviewer="revisor")` |
| (review Opus) | revisor (Opus, `sdlc-review`) | Revisa el diff completo de la rama contra spec/AC, constitución y CLAUDE.md del repo, tenancy, N+1, impacto en otros consumidores o variantes, tamaño, informe del tester y de Greptile local. | `kanban_complete` o `kanban_request_changes` (vuelve al programador) |
| **PR** | programador | Push, `gh pr create` contra `develop` (etiqueta `agente`). Greptile revisa solo en GitHub; `/check-pr` + `/greploop`: **los comentarios se arreglan en el mismo PR**, una subida por ronda, pasando antes cada ronda por Greptile CLI local, hasta 5/5 con cero comentarios sin resolver. Después etiqueta `full-ci` (una vez) y CI verde. Si los arreglos de Greptile suman > 50 líneas de producción → vuelve a revisión de Opus antes de `full-ci`. `completion_contract=<org>/<repo>`. | `kanban_complete(metadata.published_pr=URL)` (el kernel sólo acepta con los checks requeridos en verde) |
| **MERGE** | humano | Merge en GitHub. | — |

## Presupuesto de tamaño por PR (valores iniciales, ajustables)
- **≤ 20 ficheros de producción** y **≤ 600 líneas de producción cambiadas**.
- No cuentan: tests, `changelog.d/`, lockfiles, ficheros generados.
- Si el plan no cabe: PRs **secuenciales**, cada uno mergeable y verde por sí mismo (si hace falta, la funcionalidad queda tras su módulo/flag hasta el último PR). El orquestador lo decide en PLAN; el revisor rechaza PRs fuera de presupuesto sin justificación.
- Referencia: los fix/feat típicos tienen 5–40 ficheros; un PR de 126 ficheros es lo que se parte.

## Reglas anti-flake para el programador
(Sacadas de fallos reales: tests con fechas relativas, dependencia del orden y de la base de cada worker, imputaciones en UTC.)
- Tiempo congelado: `Carbon::setTestNow()` / `$this->travelTo()`; nada de `now()`/`today()` sueltos en aserciones; fechas relativas a la fecha congelada; cuidado con fin de mes, cambio de hora y zona horaria (empresa vs UTC).
- Sin dependencia del orden: no asumir orden de ids/autoincrement; listas comparadas con orden explícito o ordenadas antes de comparar.
- Sin estado compartido: nada de estáticos/caches/config mutados sin restaurar; cada test con sus datos (factories), `RefreshDatabase`.
- Sin red real ni servicios externos: `Http::fake`, `Mail::fake`, `Queue::fake`, `Storage::fake`.
- Sin `sleep` ni esperas; valores aleatorios de factories nunca en aserciones exactas.
- Cada endpoint nuevo: test de forma del sobre + test de tenancy (regla del CLAUDE.md).

## Checklist del tester (review de tests)
El tester **verifica** las cifras del programador midiéndolas él (no se fía de ellas); si la tarjeta llega sin cifras o con cifras por debajo del listón → `request_changes` inmediato, pidiéndolas. Su papel no cambia.
1. **Flakes**
   - Tests nuevos/modificados **5 veces en orden aleatorio** (`--order-by=random --random-order-seed=<n>`, semillas distintas).
   - **1 vez en paralelo** (paratest `--processes=4`) para detectar estado compartido entre workers.
   - **1 vez con otra zona horaria y otra fecha** (`TZ=…` y `travelTo` a fin de mes/cambio de hora) si el código toca fechas.
   - Revisión estática de anti-patrones (lista de arriba).
   - Todo pasa por el wrapper `factory-test` (lock global: una suite a la vez en la máquina).
2. **Cobertura del diff** (pcov instalado): `--coverage-clover` sobre los tests relacionados → % de líneas de producción cambiadas cubiertas. Objetivo **≥ 98 %** de las líneas de producción cambiadas y **toda rama nueva con su test**. El tester lista cada línea sin cubrir con su motivo; el revisor (Opus) las valida. Por debajo del 98 %, o una rama nueva sin test → `request_changes`. Líneas inalcanzables por diseño (defensa en profundidad) pueden marcarse con `@codeCoverageIgnore` + motivo en el código.
3. **Mutación del diff**: Infection limitado a las líneas cambiadas (`--git-diff-lines --git-diff-base=origin/develop`), por el lock de suites. Objetivo **MSI cubierto ≥ 85 %**; lista de mutantes supervivientes con `fichero:línea` → cada uno se mata con un test o se justifica (mutante equivalente). Si el repo aún no tiene Infection, se añade en su onboarding (F1) vía PR.
4. **Trazabilidad**: matriz criterio→tests a partir de `#[Group('AC-n')]`; un AC sin test → `request_changes`.
5. **Calidad**: comprueban comportamiento y contrato (status, sobre, campos, mensajes, tenancy), no la implementación; casos negativos y límites; nombres descriptivos (convención del repo).
6. **Veredicto**: `request_changes` con hallazgos concretos (`fichero:línea`), o `complete` con `metadata = {flake_runs, seeds, diff_coverage, uncovered_lines, msi, surviving_mutants, ac_matrix, findings}` (alimenta las métricas del panel).

## Cuerpo obligatorio de cada tarjeta (lo escribe el orquestador)
1. **Contexto** — repo, worktree, rama, BD de test propia, skills del repo a leer (`.claude/skills/<x>/SKILL.md`).
2. **Decisiones compartidas** — esquemas, nombres, contratos de API (las tarjetas no ven a sus hermanas).
3. **Criterios de aceptación** — verificables: códigos HTTP, mensajes exactos, campos.
4. **Impacto en otros consumidores o variantes** del producto (otras apps, marcas, tenants); los packs pueden detallar este apartado.
5. **Fuera de alcance**.
6. **Cómo probar** — comandos exactos vía `factory-test`; nunca la suite completa en local (eso es CI con `full-ci`).

## Verificación local (decisión del usuario)
- **Si el repo tiene `phpunit-replay` usable, se usa** como verificación local (`vendor/bin/phpunit-replay run -p 8`): la suite completa ya la corre CI. Si replay selecciona > 80 % de los ficheros de test, se ejecutan sólo los tests propios.
- «Usable» = binario + config presentes y la ejecución termina sin error de caché/grabación; si no, se cae a tests dirigidos (`php artisan test <rutas>`). El onboarding (F1) lo detecta y lo anota en `portfolio.yaml` (`verificacion_local: phpunit-replay | tests-dirigidos`).
- Quién la usa: el programador al cerrar cada IMPL y antes del PR.
- El tester **no** usa replay para buscar flakes ni para la cobertura: replay reproduce resultados grabados y no ejecuta de verdad. Para eso, ejecuciones reales dirigidas a los tests nuevos/modificados (repetidas, aleatorias, paralelo) y pcov.
- Siempre por el lock global de suites (`factory-test`).

## Greptile CLI local (trampas conocidas, de las memorias del usuario)
- Binario: `greptile` instalado por el usuario, con sesión de la organización (si va vía nvm, se enlaza en `bin/` de la fábrica: el PATH de los agentes no carga nvm).
- Revisa **commits**, no el árbol de trabajo: commitear antes (avisa con `N uncommitted files not included`).
- Siempre `-b develop` (sin él compara contra `master` y falla por tamaño).
- Compara contra la ref **local** `develop`: si está atrasada respecto a `origin/develop`, el resultado mezcla PRs ya mergeados. Antes: `git fetch origin` y comprobar `git rev-list develop..origin/develop --count` = 0; si no, avisar en vez de tocar el `develop` del checkout del usuario.
- `greptile skills install greploop` deja `.agents/skills/greploop` sin ignorar: no commitearlo en PRs de producto.

## Reglas de ejecución
- `workspace_kind=worktree`, `workspace_path=<repo>/.worktrees/<slug>`, rama `fix|feat/<slug-en-español>` desde `develop`.
- BD de test por worktree `<repo>_test_<slug>` con usuario MariaDB restringido; nunca la BD del usuario.
- Escalado de modelo por tarjeta (`--model/--provider`) para tenancy, RBAC, migraciones, facturación.
- Tarjetas IMPL con `goal_mode` (el juez comprueba los criterios antes de cerrar).
- Concurrencia: día `max_in_progress=5`; noche (cron 22:00→08:00) más alto y trabajo pesado programado.

## Pendiente
- Validar en la práctica los umbrales (presupuesto de PR, 90 % de cobertura del diff, 5 repeticiones).
- Escribir `factory-test` (wrapper con `flock` + BD del worktree) y el script de cobertura del diff.
