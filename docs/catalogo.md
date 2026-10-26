# Listar el panel en el catálogo de plugins de Hermes

El panel **The Factory** (`plugin/fabrica`) aparece en *Plugins de la comunidad* de Hermes Desktop y en
`/docs/plugins` cuando hay una entrada `plugin-catalog/fabrica.yaml` en
[`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent). Esa entrada solo llega con un PR que
revisa y fusiona un mantenedor de Nous: no hay registro automático. Reglas completas:
[Submitting to the Plugin Catalog](https://hermes-agent.nousresearch.com/docs/developer-guide/plugins/catalog-submission).

## Qué exige y cómo lo cumple el motor

| Requisito del catálogo | Cómo se cumple |
|---|---|
| Repo público clonable | El repo **público** que sale de [`publicar.md`](publicar.md), nunca el privado (su historia lleva datos de packs). |
| SHA exacto de 40 caracteres | El commit del público que contiene la versión publicada. |
| Plugin cargable en ese SHA | `plugin.yaml` + `__init__.py` + `desktop/plugin.js` (el bundle se añade al publicar, paso 3) + `dashboard/manifest.json`. |
| `hermes plugins validate` en verde | Paso 2 de abajo, sobre el árbol publicado. |
| `requires_hermes` en `plugin.yaml` y en la entrada | `plugin/fabrica/plugin.yaml`; súbelo solo si el panel usa algo de una versión más nueva. |
| Solo superficies públicas de Hermes (regla 9) | Sin reasignaciones del núcleo. La validación avisa (no falla) de los imports de módulos internos del backend; un revisor puede pedir cambiarlos por APIs públicas. |
| Comportamiento sensible declarado (regla 13) | Sección *What it does on your machine* de `plugin/fabrica/README.md`; se copia en la descripción del PR. |
| Sin binarios ni `.pyc` (regla 17) | `plugin.js` es un bundle de esbuild legible (sin minificar); los `__pycache__` están ignorados. |

## Pasos

1. **Publica la versión** en el repo público siguiendo [`publicar.md`](publicar.md) (incluido el `plugin.js`) y
   anota el SHA del commit publicado: `git -C "$DEST" rev-parse HEAD`.

2. **Valida el árbol publicado**, como hará la CI del catálogo:

   ```bash
   hermes plugins validate "$DEST/plugin/fabrica" --install-deps
   ```

   Corrige cualquier ✗ en el repo privado y vuelve a publicar; lee también los avisos (⚠), porque el revisor los verá.

3. **Crea la entrada** en un fork de `NousResearch/hermes-agent`, en una rama nueva, como
   `plugin-catalog/fabrica.yaml`:

   ```yaml
   name: fabrica
   title: The Factory
   repo: https://github.com/<usuario>/<repo-publico>
   sha: <sha de 40 caracteres del paso 1>
   subdir: plugin/fabrica
   version: "0.1.0"
   description: "Control panel for software-fabrik, a multi-agent software factory on Hermes Kanban: what needs you, stuck cards and their dependency chain, running cards and their models, quotas, machine load, per-role model routing and a terminal in each card's worktree. Needs the software-fabrik engine for the full panel; the UI is in Spanish. Disclosure: runs local hermes kanban, gh and the engine's fabrik-* tools (argument lists, no shell strings), reads the Kanban databases and the factory's data dir, writes Kanban changes and the personal factory config only on explicit clicks, opens interactive shells in card worktrees over the dashboard WebSocket gate, and talks only to 127.0.0.1 and GitHub (through gh). No telemetry."
   maintainer: <usuario>
   tier: community
   category: automation
   requires_hermes: ">=0.22.5"
   readme: true
   platforms: [linux]
   capabilities:
     provides_tools: []
     provides_hooks: []
     provides_middleware: []
     requires_env: []
   ```

   `platforms: [linux]` porque el motor depende de `systemctl --user` y `flock`. `version` y `requires_hermes`
   deben coincidir con `plugin/fabrica/plugin.yaml` en ese SHA.

4. **Abre el PR** con el título `plugin-catalog: add fabrica`. En la descripción: qué hace, qué superficies usa
   (página y barra lateral del SDK de escritorio, chip de estado, backend de dashboard en
   `/api/plugins/fabrica/`, skill), la sección de divulgación del README y capturas de la página. Espera a que la
   CI del catálogo dé verde.

## Versiones siguientes

Cada versión nueva es otro PR que solo cambia `sha` (y `version`, subida también en `plugin.yaml`). El revisor lee
el rango de commits entre el SHA anterior y el nuevo, así que conviene publicar versiones con cambios agrupados.
