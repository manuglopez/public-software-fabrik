# F2 — Feature: de «Nueva feature» a «Plan listo para aprobar» (y cierre)

Estado: BORRADOR v1 (2026-10-23). Puntos ❓ pendientes del usuario.

## Dato de partida
En un repo real ya se usó Spec Kit completo para un cambio de 267 líneas de producción: **138 k caracteres de documentos**
(spec 17k, research 18k, tasks.md 86k). La ceremonia debe escalar con el tamaño del cambio (de ahí las tallas S/M/L).
Si el repo tiene constitución, se respeta; la fábrica solo la actualiza vía PR (❓3).

## Fases
| Fase | Dónde | Quién | Qué pasa | Salida |
|---|---|---|---|---|
| **A. Arranque** | Panel → «Nueva feature» abre chat con `/fabrica feature <proyecto>` | Opus (perfil default) | Carga ficha del portfolio, contexto del repo (`.hermes.md`/CLAUDE.md, constitución), **tu trabajo vivo** (repos calientes) y PRs abiertos. Te pide la idea en lenguaje natural. | Idea + contexto |
| **B. Talla** | chat | Opus propone, tú confirmas | **S**: 1 PR, sin cambio de contrato → sin Spec Kit, mini-spec dentro de la tarjeta. **M**: 1–2 PRs o cambia un contrato de API → Spec Kit ligero. **L**: varios PRs/repos, modelo de datos, migraciones → Spec Kit completo. | Talla |
| **C. Spec** ✋ | chat | Opus + tú | `/speckit.specify` → `/speckit.clarify` (preguntas con el formulario de opciones, máx. 5). Opus resume la spec en una tarjeta viva con **Aprobar**. | **spec.md aprobada** (puerta 1) |
| **D. Plan técnico** | chat + tarjetas de explorador | Opus; explorador (Gemini Flash) para mapear código en L | M: `plan.md` corto. L: `plan.md` + research + data-model + contracts + `/speckit.analyze`. Sin `tasks.md` (las tareas son las tarjetas), salvo L si lo pides. | plan.md |
| **E. Plan de tarjetas** ✋ | chat → Kanban | Opus crea; orquestador es dueño de la raíz | Convierte el plan en grafo C0: unidades de PR por repo dentro del presupuesto, porciones IMPL, decisiones compartidas, impacto en otros consumidores o variantes, escalados a Opus, colisiones con tu trabajo, qué va de noche. Crea raíz + PLAN `blocked` + hijas gateadas. Tarjeta viva en el chat + aviso. | **PLAN aprobado** (puerta 2) |
| **F. Ejecución** | Kanban | especialistas | Ciclo C0 por PR. | PRs listos para merge |
| **G. Merge** ✋ | GitHub | tú | Merge de cada PR. | (puerta 3) |
| **H. Cierre** | Kanban | orquestador | Al mergear el último PR: `/speckit.converge` contra la spec → si falta algo, nuevas tarjetas (vuelve a E); si no, cierra la feature, destila aprendizajes a `docs/agent-knowledge/` y actualiza el panel. | Feature cerrada |

## Trazabilidad (adoptado)
- En la fase C cada criterio de aceptación recibe id `AC-n`; en tallas S los AC van en el cuerpo de la tarjeta.
- En E, cada tarjeta IMPL lista qué AC cubre; el programador marca los tests con `#[Group('AC-n')]`.
- En H, `/speckit.converge` + la matriz del tester comprueban que todo AC tiene test antes de cerrar la feature.

## Variante F4 — cambio de contrato de API con consumidores
- En B, si el cambio toca una API, Opus pregunta por sus consumidores (apps, fronts, otras marcas o tenants).
- En E: PR de API primero; las tarjetas de consumidores dependen de la tarjeta PR de la API (aprobada y verde). Cada PR de consumidor declara «requiere desplegar antes el PR de API #N».
- Criterios de aceptación separados por consumidor o variante, y test de que las demás no cambian.
- Los packs pueden detallar esta variante con sus productos concretos: ver `packs/<p>/docs`.

## Reglas
- La fase de spec se hace en el perfil default (tiene las skills `speckit-*`); el orquestador sólo crea y gobierna tarjetas.
- Opus nunca escribe código en F2; si necesita saber cómo está el código, lanza una tarjeta de explorador.
- Si durante E el plan no cabe en el presupuesto de PR → lo parte y te lo explica en PLAN.

## ❓ Pendiente
1. ~~Tallas~~ → **DECIDIDO: tallas S/M/L y sin `tasks.md`** (las tarjetas son las tareas; `tasks.md` sólo en L si el usuario lo pide).
2. ~~Dónde viven las specs~~ → **DECIDIDO: versionadas en el repo** (`specs/NNN-slug/`), dentro del primer PR de la feature. En la fase C/D Opus las escribe en la rama de la feature (worktree), no en el checkout del usuario.
3. ~~Constitución~~ → **DECIDIDO**: la constitución del repo pide «modelos por rol, configurables desde el panel; revisor de otra familia que el programador; lo delicado (tenancy, RBAC, migraciones, facturación) a Opus». Se aplica vía PR durante el onboarding (F1) de cada repo con Spec Kit, nunca editando el checkout del usuario.

Estado de F2: **CERRADO v1** (2026-10-23).
