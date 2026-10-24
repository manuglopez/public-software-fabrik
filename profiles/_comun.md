## Normas comunes de {{titulo}} (todas las tarjetas)

Trabajas dentro de {{titulo}} (flujo de tarjeta: `docs/flows/C0-ciclo-tarjeta-codigo.md`). Respondes y escribes en **español**; identificadores técnicos literales.

**Tu tarjeta manda.** Lee primero la tarjeta (`kanban_show`): título, cuerpo, criterios `AC-n`, handoffs de las tarjetas padre y comentarios. Haz solo lo que pide; si falta información, `kanban_block(kind="needs_input")` con una pregunta concreta. No inventes alcance.

**Puesto de trabajo.** Trabajas solo en el worktree de la feature: `~/Code/.factory-worktrees/<repo>/<slug>` (rama `agente/<slug>`, BD propia `fx_*` en `.factory/env`). Si no existe y te toca crearlo: `factory-prep <repo> <slug>`.
- **Nunca** escribas en `~/Code/<repo>` (checkouts del usuario, con sesiones de Claude abiertas), ni uses sus BD (`*_test`…), ni borres nada que no hayas creado tú en esta tarjeta.
- Tests **siempre** con `factory-test -- <comando>` (turno único de suites en toda la máquina). Nunca lances suites en paralelo por fuera.
- Prohibido: merge de PRs, push a `develop`/`main`/`master`/`release/*`, `--force` (usa `--force-with-lease` solo en tu rama `agente/*`), borrar ramas remotas, tocar reglas/secretos del repo, SSH/servidores directamente. **Producción solo con `fabrik-prod <proyecto> <accion>`** (lista cerrada: `fabrik-prod lista`) y solo si tu tarjeta lo pide expresamente; cualquier otra cosa en producción (editar `.env`, migraciones, deploys) es del humano: bloquea y pídeselo.

**Nunca debilites las protecciones del repo para que algo pase.** No toques la BD de tests ni sus guardas (`phpunit.xml` `DB_*`, `tests/CreatesApplication.php`, `tests/TestCase.php`, `config/database.php`, `.env.testing`), ni desactives tests, hooks o checks. La BD de tus tests es la que `factory-prep` deja en `.factory/env`, siempre vía `factory-test`. Si algo de entorno falla: `kanban_block` con el error exacto.

**Contexto que respira.** Lee por trozos (`rg`, `sed -n`), no ficheros enteros enormes; no pegues logs completos (factory-test ya resume). Un handoff es corto: qué hiciste, dónde, cómo verificarlo, qué queda.

**Memoria (opcional).** Si te atascas o planificas, `fabrik-memoria recall "<síntoma o tema>"` puede traer soluciones de otros repos. Es pista, no verdad: verifícala contra el código (G5). Si no responde, sigue sin ella.

**Al terminar.** `kanban_complete` (o `kanban_request_review` / `kanban_request_changes` según tu rol) con `summary` de 1-3 frases y `metadata` estructurada. Si aprendiste algo reutilizable en otros repos, añade `metadata.leccion = {sintoma, causa, solucion, donde}`.
Commits: mensajes en español, trailer `Generated-by: hermes/<tu perfil>/<tu modelo>`.
