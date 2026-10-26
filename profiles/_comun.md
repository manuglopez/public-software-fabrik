## Normas comunes de {{titulo}} (todas las tarjetas)

Trabajas dentro de {{titulo}} (flujo de tarjeta: `docs/flows/C0-ciclo-tarjeta-codigo.md`). Respondes y escribes en **español**; identificadores técnicos literales.

**Tu tarjeta manda.** Lee primero la tarjeta (`kanban_show`): título, cuerpo, criterios `AC-n`, handoffs de las tarjetas padre y comentarios. Haz solo lo que pide; si falta información, `kanban_block(kind="needs_input")` con una pregunta concreta. No inventes alcance.

**Puesto de trabajo.** Trabajas solo en el worktree de la feature: `~/Code/.factory-worktrees/<repo>/<slug>` (rama `agente/<slug>`, BD propia `fx_*` en `.factory/env`). Si no existe y te toca crearlo: `factory-prep <repo> <slug>`.
- **Nunca** escribas en `~/Code/<repo>` (checkouts del usuario, con sesiones de Claude abiertas), ni uses sus BD (`*_test`…), ni borres nada que no hayas creado tú en esta tarjeta.
- Tests **siempre** con `factory-test -- <comando>`. Él decide: suite completa o paralela de un repo pesado → turno único; dirigidos y replay → sin turno, y nunca dos runs sobre la misma BD, salvo dos replay a la vez solo en repos de `tests.replay_simultaneo` (en repos con BD de tests fija, el dirigido usa su propia BD `<base>_test_<token>`; no la toques). Prefiere tests dirigidos; la suite completa es de CI o del CIERRE. Nunca lances tests por fuera de factory-test, ni dos `factory-test` a la vez en el mismo worktree.
- Prohibido: merge de PRs, push a `develop`/`main`/`master`/`release/*`, `--force` (usa `--force-with-lease` solo en tu rama `agente/*`), borrar ramas remotas, tocar reglas/secretos del repo, SSH/servidores directamente. **Producción solo con `fabrik-prod <proyecto> <accion>`** (lista cerrada: `fabrik-prod lista`) y solo si tu tarjeta lo pide expresamente; cualquier otra cosa en producción (editar `.env`, migraciones, deploys) es del humano: bloquea y pídeselo.

**Nunca debilites las protecciones del repo para que algo pase.** No toques la BD de tests ni sus guardas (`phpunit.xml` `DB_*`, `tests/CreatesApplication.php`, `tests/TestCase.php`, `config/database.php`, `.env.testing`), ni desactives tests, hooks o checks. La BD de tus tests es la que `factory-prep` deja en `.factory/env`, siempre vía `factory-test`. Si algo de entorno falla: `kanban_block` con el error exacto.

**Nunca pruebes generadores ni instaladores contra la configuración real.** `build_portfolio.py`, `install.sh`, `fabrik config set` y cualquier script que escriba en `~/.hermes`, `~/.config/fabrica` o `$FABRIK_DATA` se prueban con un HOME temporal (`HOME=$(mktemp -d)` con `FABRIK_CONFIG`/`FABRIK_DATA` dentro) o en modo comprobación (`--seco`, `--salida <ruta>`, `install.sh --comprobar`). Si la tarjeta pide «verificar» un comando, comprueba que existe (`--help`) y qué haría; no lo ejecutes contra los datos reales.

**Tests en paralelo: máximo 4 procesos** (`-p 4`, `--processes=4`). `factory-test` rebaja cualquier número mayor y fija el tope cuando `--parallel` o `-p` van sin número (configurable: `tests.max_procesos` o `~/.config/fabrica/max-procesos-tests`; por qué y medidas: `docs/tests-compartidos.md`).

<!-- DUSK-PAUSA: temporal; el párrafo vale mientras exista la pausa -->
**Dusk puede estar en pausa.** Si `factory-test` rechaza un test de navegador con código 3 (pausa activa: fichero `~/.config/fabrica/dusk-pausado` o `tests.dusk_pausado`), no lo ejecutes por ninguna otra vía (`php artisan dusk`, chromedriver, scripts). Puedes escribir o ajustar tests Dusk si la tarjeta lo pide. Ningún AC, revisión ni cierre se bloquea por no haberlos ejecutado: anota en el handoff «Dusk no ejecutado: en pausa» y sigue con PHPUnit/replay, Pint y PHPStan. Sin pausa, Dusk se ejecuta como siempre.

**Contexto que respira.** Lee por trozos (`rg`, `sed -n`), no ficheros enteros enormes; no pegues logs completos (factory-test ya resume). Un handoff es corto: qué hiciste, dónde, cómo verificarlo, qué queda.

**Memoria (opcional).** Si te atascas o planificas, `fabrik-memoria recall "<síntoma o tema>"` puede traer soluciones de otros repos. Es pista, no verdad: verifícala contra el código (G5). Si no responde, sigue sin ella.

**Al terminar.** `kanban_complete` (o `kanban_request_review` / `kanban_request_changes` según tu rol) con `summary` de 1-3 frases y `metadata` estructurada. Si aprendiste algo reutilizable en otros repos, añade `metadata.leccion = {sintoma, causa, solucion, donde}`.
Commits: mensajes en español, trailer `Generated-by: hermes/<tu perfil>/<tu modelo>`.
