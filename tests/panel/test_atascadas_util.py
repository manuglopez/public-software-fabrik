"""Piezas de test de la zona `atascadas` (IMPL-3): tableros SQLite de fixture, foto de cupos, perfiles y config.

No define tests (el nombre `test_*` es solo para quedar en la zona, D-9 R-2). Sin red ni HOME real: todo vive en un
directorio temporal que apuntan HERMES_KANBAN_HOME, FABRIK_DATA, FABRIK_CUPOS_LOG, FABRIK_PROFILES_DIR y FABRIK_CONFIG.
"""
import datetime
import json
import os
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path
from unittest import mock

from tests.panel.base import PanelTest

AHORA = 1_800_000_000  # reloj congelado (epoch s)
MIN = 60

ESQUEMA = """
CREATE TABLE tasks (
    id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT, assignee TEXT, status TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT 0, started_at INTEGER, completed_at INTEGER,
    workspace_kind TEXT NOT NULL DEFAULT 'scratch', workspace_path TEXT, last_failure_error TEXT,
    model_override TEXT, provider_override TEXT, block_kind TEXT, current_run_id INTEGER);
CREATE TABLE task_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, profile TEXT, status TEXT NOT NULL,
    started_at INTEGER NOT NULL, ended_at INTEGER, outcome TEXT, summary TEXT, metadata TEXT, error TEXT);
CREATE TABLE task_links (parent_id TEXT NOT NULL, child_id TEXT NOT NULL, PRIMARY KEY (parent_id, child_id));
"""


def iso(delta_s: int) -> str:
    """Instante ISO UTC a `delta_s` segundos del AHORA congelado."""
    return datetime.datetime.fromtimestamp(AHORA + delta_s, datetime.timezone.utc).isoformat()


class Tablero:
    """Un `kanban.db` de fixture con ayudas para poblarlo."""

    def __init__(self, ruta: Path):
        ruta.parent.mkdir(parents=True, exist_ok=True)
        self.ruta = ruta
        self.con = sqlite3.connect(ruta)
        self.con.executescript(ESQUEMA)

    def tarea(self, tid, titulo="Tarea", status="ready", **campos):
        columnas = {"id": tid, "title": titulo, "status": status, **campos}
        self.con.execute(
            f"INSERT INTO tasks ({', '.join(columnas)}) VALUES ({', '.join('?' * len(columnas))})", list(columnas.values())
        )
        self.con.commit()
        return tid

    def run(self, tid, inicio, fin=None, outcome=None, metadata=None):
        self.con.execute(
            "INSERT INTO task_runs (task_id, status, started_at, ended_at, outcome, metadata) VALUES (?,?,?,?,?,?)",
            (tid, "running" if fin is None else "done", inicio, fin, outcome, json.dumps(metadata) if metadata else None),
        )
        self.con.commit()

    def enlace(self, padre, hijo):
        self.con.execute("INSERT INTO task_links VALUES (?, ?)", (padre, hijo))
        self.con.commit()

    def cerrar(self):
        self.con.close()


class AtascadasTest(PanelTest):
    """`PanelTest` con tableros temporales, reloj congelado, foto de cupos, perfiles y config propios."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="fx-atascadas-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        entorno = {
            "HERMES_KANBAN_HOME": str(self.tmp / "home"),
            "FABRIK_DATA": str(self.tmp / "data"),
            "FABRIK_CUPOS_LOG": str(self.tmp / "cupos.jsonl"),
            "FABRIK_PROFILES_DIR": str(self.tmp / "perfiles"),
            "FABRIK_CONFIG": str(self.tmp / "fabrik.yaml"),
        }
        parche = mock.patch.dict(os.environ, entorno)
        parche.start()
        self.addCleanup(parche.stop)
        for var in ("HERMES_KANBAN_DB", "HERMES_KANBAN_BOARD"):
            os.environ.pop(var, None)
        sin_hermes = mock.patch.dict(sys.modules, {"hermes_cli": None, "hermes_cli.kanban_db": None})
        sin_hermes.start()
        self.addCleanup(sin_hermes.stop)
        super().setUp()
        self.comun = sys.modules["fabrica_comun"]
        self.fx = sys.modules.get("fabrica_fx_atascadas")
        self.tableros = []
        self.addCleanup(lambda: [t.cerrar() for t in self.tableros])
        self.escribir_config()
        if self.fx is not None:
            reloj = mock.patch.object(self.fx, "_ahora", return_value=AHORA)
            reloj.start()
            self.addCleanup(reloj.stop)

    def tablero(self, slug="demo") -> Tablero:
        ruta = self.tmp / "home" / ("kanban.db" if slug == "default" else f"kanban/boards/{slug}/kanban.db")
        t = Tablero(ruta)
        self.tableros.append(t)
        return t

    def escribir_config(self, extra: str = ""):
        (self.tmp / "fabrik.yaml").write_text(
            "modelos:\n"
            "  programador:\n"
            "    proveedor: kimi-coding\n    modelo: kimi-for-coding\n"
            "    reserva:\n      - {proveedor: antigravity-oauth, modelo: gemini-3.8-flash-high}\n"
            "  reserva_final: {proveedor: claude-subscription, modelo: claude-sonnet-5-5}\n" + extra,
            encoding="utf-8",
        )

    def perfil(self, nombre="programador", cadena=(("kimi-coding", "kimi-for-coding"), ("antigravity-oauth", "gemini-3.8-flash-high"))):
        (p, m), *reservas = cadena
        texto = f"model:\n  default: {m}\n  provider: {p}\nfallback_providers:\n"
        texto += "".join(f"  - provider: {rp}\n    model: {rm}\n" for rp, rm in reservas)
        d = self.tmp / "perfiles" / nombre
        d.mkdir(parents=True, exist_ok=True)
        (d / "config.yaml").write_text(texto, encoding="utf-8")

    def foto(self, bolsas: dict[str, float], reset_s: int = 3600, antiguedad_s: int = 60):
        """Última línea de cupos.jsonl: `bolsas` = {nombre: porcentaje}, todas con el mismo reset."""
        linea = {"t": AHORA - antiguedad_s, "bolsas": {b: [pct, iso(reset_s)] for b, pct in bolsas.items()}}
        (self.tmp / "cupos.jsonl").write_text(json.dumps(linea) + "\n", encoding="utf-8")

    def get(self, ruta):
        r = self.client.get(ruta)
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()
