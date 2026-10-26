"""Backend real de The Factory para el E2E de «Aprobar» (desktop_tablero_e2e.test.mjs, AC-3a + AC-2b).

No es un test (no casa con `test_*.py`): lo lanza el test de escritorio, una vez por petición, desde la raíz del repo:

    uv run --with fastapi --with httpx --with pyyaml python -m tests.panel.tablero_e2e_servidor <dir> get
    … <dir> post '<cuerpo JSON>' [verbo que falla]

- `get`  → JSON de `GET /inicio/te-toca`.
- `post` → `{"status", "respuesta", "ejecutadas", "sqlite_igual"}` de `POST /acciones/aprobar`: los argv que se habrían
  ejecutado y si el fichero del tablero quedó idéntico (ninguna acción escribe en SQLite).

Sin red ni HOME real: el tablero `default` es un SQLite de fixture en `<dir>` (HERMES_KANBAN_HOME), sin `hermes_cli`
y con `comun.ejecutar` simulado (apunta el argv y responde ok, salvo el verbo que se pida que falle; `gh` nunca se llama).
"""
import hashlib
import json
import os
import sqlite3
import sys
from pathlib import Path
from unittest import mock

PLAN, BLOQUEADA = "t_0000aaaa", "t_0000eeee"
ESQUEMA = """
CREATE TABLE tasks (
    id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT, assignee TEXT, status TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT 0, started_at INTEGER, completed_at INTEGER,
    workspace_kind TEXT NOT NULL DEFAULT 'scratch', workspace_path TEXT, last_failure_error TEXT,
    model_override TEXT, provider_override TEXT, block_kind TEXT, current_run_id INTEGER);
CREATE TABLE task_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, profile TEXT, status TEXT NOT NULL,
    started_at INTEGER NOT NULL, ended_at INTEGER, outcome TEXT, summary TEXT, metadata TEXT, error TEXT);
CREATE TABLE task_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, run_id INTEGER, kind TEXT NOT NULL, payload TEXT,
    created_at INTEGER NOT NULL DEFAULT 0);
CREATE TABLE task_links (parent_id TEXT NOT NULL, child_id TEXT NOT NULL, PRIMARY KEY (parent_id, child_id));
"""


def preparar(raiz: Path) -> Path:
    """Crea (una vez) el tablero `default`: un PLAN bloqueado needs_input y una tarjeta bloqueada por capability."""
    ruta = raiz / "kanban.db"
    if ruta.exists():
        return ruta
    raiz.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(ruta)
    con.executescript(ESQUEMA)
    con.executemany(
        "INSERT INTO tasks (id, title, assignee, status, block_kind, created_at) VALUES (?,?,?,?,?,?)",
        [(PLAN, "PLAN tienda: pagos con tarjeta", "orquestador", "blocked", "needs_input", 1),
         (BLOQUEADA, "IMPL-2 tienda: falta acceso", "programador", "blocked", "capability", 2)],
    )
    con.executemany(
        "INSERT INTO task_events (task_id, kind, payload) VALUES (?, 'blocked', ?)",
        [(PLAN, json.dumps({"reason": "¿Apruebas el plan de pagos?\nDetalle en el cuerpo"})),
         (BLOQUEADA, json.dumps({"reason": "Sin credenciales de la pasarela"}))],
    )
    con.commit()
    con.close()
    return ruta


def main(argv: list[str]) -> None:
    raiz, orden, *resto = argv
    raiz = Path(raiz)
    ruta = preparar(raiz)
    os.environ.update(HERMES_KANBAN_HOME=str(raiz), HERMES_HOME=str(raiz), FABRIK_DATA=str(raiz / "data"))
    for var in ("HERMES_KANBAN_DB", "HERMES_KANBAN_BOARD"):
        os.environ.pop(var, None)
    sys.modules.update({"hermes_cli": None, "hermes_cli.kanban_db": None, "hermes_constants": None})

    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from tests.panel.base import cargar_api

    api = cargar_api()
    app = FastAPI()
    app.include_router(api.router)
    cliente = TestClient(app)
    comun = sys.modules["fabrica_comun"]
    falla = resto[1] if len(resto) > 1 else None
    ejecutadas = []

    def ejecutar(cmd, timeout):
        assert isinstance(cmd, list) and cmd[0] == "hermes", f"comando fuera de la lista cerrada: {cmd}"
        ejecutadas.append(cmd)
        return (False, "error simulado") if len(cmd) > 4 and cmd[4] == falla else (True, "ok")

    with mock.patch.object(comun, "ejecutar", side_effect=ejecutar):
        if orden == "get":
            r = cliente.get("/inicio/te-toca")
            r.raise_for_status()
            print(json.dumps(r.json()))
            return
        antes = hashlib.sha256(ruta.read_bytes()).hexdigest()
        r = cliente.post("/acciones/aprobar", json=json.loads(resto[0]))
        print(json.dumps({
            "status": r.status_code,
            "respuesta": r.json(),
            "ejecutadas": ejecutadas,
            "sqlite_igual": hashlib.sha256(ruta.read_bytes()).hexdigest() == antes,
        }))


if __name__ == "__main__":
    main(sys.argv[1:])
