---
name: fabrica
description: "Use when the user says /fabrica or asks the factory to build, fix or check something. Turns a request into a Kanban plan (C0/F2) for the orchestrator."
version: 0.1.0
author: software-fabrik
license: MIT
metadata:
  hermes:
    tags: [kanban, factory, orchestration]
    category: devops
    requires_toolsets: [kanban]
---

# /fabrica — entrada del usuario a la fábrica

Diseño: `~/Code/software-fabrik/docs/DESIGN.md`. Flujos: `docs/flows/C0-ciclo-tarjeta-codigo.md`, `docs/flows/F2-feature.md`.
Catálogo de repos: `~/.hermes/factory/portfolio.yaml` (producto → tablero, marca, ritmo, verificación local).

## Comandos

| El usuario dice | Qué haces |
|---|---|
| `/fabrica estado` | Por tablero: tarjetas en marcha/bloqueadas/en revisión (`hermes kanban --board <b> list`), PRs abiertos con etiqueta `agente` (para cada owner de `fabrik config get owners`: `gh search prs --owner <owner> --label agente --state open`), turno de tests (`factory-test estado`), memoria (`fabrik-memoria estado`). Tabla corta. |
| `/fabrica feature <repo> "<qué>"` | Alta de feature (abajo). |
| `/fabrica bug <repo> "<síntoma>"` | Igual que feature, talla S por defecto, AC-1 = «reproducido con test y arreglado». |
| `/fabrica aprobar <id>` | El usuario aprueba un PLAN: `kanban_unblock` de la tarjeta PLAN (el orquestador crea/libera las tarjetas). |
| `/fabrica pausa <tablero>` / `reanuda` | Bloquea/desbloquea las tarjetas `ready` del tablero (prioridad cambiante del usuario). |
| `/fabrica limpia` | `factory-gc --seco` y luego, si el usuario confirma, `factory-gc`. |

## Alta de feature/bug
1. Resuelve el repo en `portfolio.yaml` → `board`, `brand`, `product`, `verificacion_local`. Repo fuera del catálogo: usa `propietario/repo` y el tablero por defecto de la config (`fabrik config get tablero_por_defecto`).
2. Propón talla S/M/L (F2) en una línea y los **criterios de aceptación** `AC-1..n` (comprobables). Si es M/L, recuerda que primero va la spec con Spec Kit (`/speckit.specify`) y su aprobación ✋.
3. Crea la tarjeta raíz para el orquestador:
   `kanban_create(board=<board>, assignee="orquestador", title="FEAT <repo>: <qué>", body=<repo, talla, AC, contexto del usuario, restricciones: PR ≤20 ficheros/≤600 líneas, base develop (o main si el repo no tiene develop), impacto multimarca si aplica>)`.
4. Dile al usuario: id de la tarjeta, tablero, y que el orquestador le presentará el PLAN para aprobar (✋). Nada más: no implementes tú.

## Reglas
- El usuario aprueba spec, plan y merge. Tú nunca haces merge ni tocas sus checkouts (`~/Code/<repo>`).
- Prioridades: el usuario decide y cambia sobre la marcha; tú no reordenas por tu cuenta.
- Si el gateway no está en marcha (el dispatcher vive en él), avisa: `hermes gateway start`.
