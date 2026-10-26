# The Factory (`fabrica`)

Control panel for [software-fabrik](https://github.com/manuglopez/public-software-fabrik), a multi-agent
software factory built on Hermes Kanban: an orchestrator turns an approved request into Kanban cards and
specialist profiles (programmer, tester, reviewer, explorer, security, docs) work them into reviewable PRs.

The plugin adds to Hermes Desktop:

- a **The Factory** page (`/the-factory`, sidebar entry) with:
  - **Home**: what needs you (plans to approve, PRs to merge, blocked cards), stuck cards and their dependency
    chain, what is running and on which model, subscription quotas, machine load, shared memory status, and
    shortcuts that open a new chat pre-filled with `/fabrica <flow>` (never sent for you);
  - **Projects**, **Agents** (model routing per role), **Quotas & costs** and **Memory** tabs;
  - a per-card **console**: a terminal opened in the card's git worktree;
- a status chip;
- a dashboard backend mounted at `/api/plugins/fabrica/`, which serves the page's data;
- the `/fabrica` skill (turns a request into a Kanban plan for the orchestrator).

The UI is currently in Spanish.

## Requirements

The panel reads the factory's state; without the engine it only shows the Kanban parts.

1. Install the engine (`git`, `gh`, `uv`, `python3`, `systemctl --user` required — see its README):

   ```bash
   git clone https://github.com/manuglopez/public-software-fabrik ~/Code/software-fabrik
   cd ~/Code/software-fabrik && ./install.sh --comprobar && ./install.sh
   ```

   `./install.sh` already links this plugin from the repository. Installing it from the catalog instead is fine:
   the installer leaves a non-symlink `~/.hermes/plugins/fabrica` alone, and the backend finds the engine through
   the `$FABRIK_DATA/scripts` link the installer creates (or `FABRIK_HOME` if you set it).

2. Enable the plugin and its Desktop half:

   ```bash
   hermes plugins install fabrica && hermes plugins enable fabrica
   ```

   Then Hermes Desktop → Capabilities → Plugins → **The Factory**.

Optional: `gh` logged in (PR states), the shared memory service (Hindsight on `127.0.0.1:8888`,
`FABRIK_MEMORIA_URL`), `fabrik-cupos` for quotas.

## What it does on your machine (disclosure)

- **Reads** the Hermes Kanban databases (`~/.hermes/kanban/…`, read-only SQLite), Hermes profile configs, the
  factory's data dir (`$FABRIK_DATA`, default `~/.hermes/factory`: logs, quota snapshots, `portfolio.yaml`) and
  its personal config (`~/.config/fabrica/fabrik.yaml`).
- **Runs local commands** (argument lists, never a shell string, with timeouts): `hermes kanban` (read, and on
  your click `comment`/`unblock`/`assign`/`set-model`), `gh repo view` / `gh pr list|view` (GitHub API through
  your own `gh` login), and the engine's tools (`fabrik-modelos`, `fabrik-memoria`, `fabrik-cupos`,
  `fabrik-consola`).
- **Writes** only on an explicit action: Kanban comments/unblocks/assignments/model changes through the
  `hermes kanban` CLI, and `modelos.reparto` in your personal factory config (Agents tab → Save).
- **Console**: opens an interactive shell (your `$SHELL`) in a card's worktree through a PTY owned by the
  dashboard backend, streamed over a WebSocket that uses the same authentication gate as Hermes's own sockets
  (loopback only if that gate is unavailable). "Open in system terminal" launches your terminal emulator through
  `fabrik-consola`. The shell lives until you close it or the backend stops.
- **Network**: only `127.0.0.1` (shared memory service, if you run it) and GitHub through `gh`. No telemetry.
- **Credentials**: none stored or read by the plugin; `gh` and `hermes` use their own logins.

## Development

Sources of the Desktop half are in `desktop/src/`; `desktop/plugin.js` is the generated bundle
(`scripts/plugin-desktop.sh build|watch|check` in the engine repo). Backend tests:
`bash tests/panel_backend_test.sh`.

License: MIT.
