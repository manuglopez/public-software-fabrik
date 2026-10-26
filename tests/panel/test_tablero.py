"""Inicio · tablero (IMPL-2): GET /inicio/te-toca (AC-3a) y GET /inicio/en-marcha (AC-3d), robustez AC-6.

Sin red ni HOME real: los tableros son SQLite de fixture (tablero_kanban.json) en un directorio temporal
(HERMES_KANBAN_HOME), la config de Hermes y los perfiles en HERMES_HOME temporal, los datos de la fábrica en FABRIK_DATA
temporal y `gh` simulado (`comun.ejecutar`).
"""
import json
import os
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path
from unittest import mock

from tests.panel.base import PanelTest

TAREA = {"title": "", "status": "", "assignee": None, "block_kind": None, "model_override": None,
         "workspace_kind": "scratch", "workspace_path": None, "started_at": None, "current_run_id": None, "created_at": 0}


def volcar_tablero(ruta: Path, datos: dict, state_db: Path) -> None:
    """Subconjunto del esquema de hermes_cli.kanban_db que lee fx_tablero."""
    ruta.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(ruta)
    con.executescript(
        "CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, status TEXT NOT NULL, assignee TEXT,"
        " block_kind TEXT, model_override TEXT, workspace_kind TEXT NOT NULL DEFAULT 'scratch', workspace_path TEXT,"
        " started_at INTEGER, current_run_id INTEGER, created_at INTEGER NOT NULL);"
        "CREATE TABLE task_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, status TEXT NOT NULL,"
        " started_at INTEGER NOT NULL, metadata TEXT);"
        "CREATE TABLE task_events (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, run_id INTEGER,"
        " kind TEXT NOT NULL, payload TEXT, created_at INTEGER NOT NULL DEFAULT 0);"
    )
    for t in datos["tasks"]:
        fila = {**TAREA, **t}
        con.execute(f"INSERT INTO tasks ({','.join(fila)}) VALUES ({','.join('?' * len(fila))})", list(fila.values()))
    for r in datos["runs"]:
        con.execute("INSERT INTO task_runs (id, task_id, status, started_at, metadata) VALUES (?,?,?,?,?)",
                    (r["id"], r["task_id"], r["status"], r["started_at"], r.get("metadata")))
    for e in datos["events"]:
        payload = e["payload"].replace("{STATE_DB}", str(state_db))
        con.execute("INSERT INTO task_events (task_id, run_id, kind, payload) VALUES (?,?,?,?)",
                    (e["task_id"], e.get("run_id"), e["kind"], payload))
    con.commit()
    con.close()


class TableroTest(PanelTest):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="fx-tablero-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.datos = self.fixture("tablero_kanban")
        raiz, data = self.tmp / "hermes", self.tmp / "data"
        entorno = {"HERMES_KANBAN_HOME": str(raiz), "HERMES_HOME": str(raiz), "FABRIK_DATA": str(data)}
        parche = mock.patch.dict(os.environ, entorno)
        parche.start()
        self.addCleanup(parche.stop)
        for var in ("HERMES_KANBAN_DB", "HERMES_KANBAN_BOARD"):
            os.environ.pop(var, None)
        # Sin hermes_cli ni hermes_constants (como en uv run): todo se resuelve por entorno.
        sin = mock.patch.dict(sys.modules, {"hermes_cli": None, "hermes_cli.kanban_db": None, "hermes_constants": None})
        sin.start()
        self.addCleanup(sin.stop)

        self.state_db = raiz / "profiles" / "programador" / "state.db"
        self.state_db.parent.mkdir(parents=True)
        con = sqlite3.connect(self.state_db)
        con.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, api_call_count INTEGER, tool_call_count INTEGER)")
        con.executemany("INSERT INTO sessions VALUES (:id, :api_call_count, :tool_call_count)", self.datos["sesiones"])
        con.commit()
        con.close()
        for slug, tablero in self.datos["tableros"].items():
            ruta = raiz / "kanban.db" if slug == "default" else raiz / "kanban" / "boards" / slug / "kanban.db"
            volcar_tablero(ruta, tablero, self.state_db)
        for rol, modelo in self.datos["perfiles"].items():
            (raiz / "profiles" / rol).mkdir(parents=True, exist_ok=True)
            (raiz / "profiles" / rol / "config.yaml").write_text(f"model:\n  default: {modelo}\n", encoding="utf-8")
        (raiz / "config.yaml").write_text(json.dumps(self.datos["config"]), encoding="utf-8")
        data.mkdir()
        (data / "pausa-tableros.tsv").write_text(self.datos["pausa_tsv"], encoding="utf-8")
        self.data = data

        super().setUp()
        self.mod = sys.modules["fabrica_fx_tablero"]
        self.comun = sys.modules["fabrica_comun"]
        self.gh_llamadas = []
        self.gh = mock.patch.object(self.mod, "hay_gh", return_value=True)
        self.gh.start()
        self.addCleanup(self.gh.stop)
        ejecutar = mock.patch.object(self.comun, "ejecutar", side_effect=self.gh_falso)
        ejecutar.start()
        self.addCleanup(ejecutar.stop)

    def gh_falso(self, argv, timeout):
        self.gh_llamadas.append((list(argv), timeout))
        url = argv[3]
        if url not in self.datos["gh"]:
            return False, "no encontrado"
        return True, json.dumps(self.datos["gh"][url])


class TestTeToca(TableroTest):
    def test_ac3a_plan_merge_y_bloqueadas_segun_contrato(self):
        r = self.client.get("/inicio/te-toca")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json(), self.fixture("tablero_te_toca"))

    def test_ac3a_gh_pr_view_sin_shell_con_timeout_5s(self):
        self.client.get("/inicio/te-toca")
        urls = sorted(a[3] for a, _ in self.gh_llamadas)
        self.assertEqual(urls, ["https://github.com/acme/tienda/pull/6", "https://github.com/acme/tienda/pull/7"])
        for argv, timeout in self.gh_llamadas:
            self.assertEqual(argv[:3], ["gh", "pr", "view"])
            self.assertEqual(argv[4:], ["--json", "state,url"])
            self.assertEqual(timeout, 5)

    def test_ac3a_un_pr_cerrado_se_recuerda_y_no_se_vuelve_a_preguntar(self):
        self.client.get("/inicio/te-toca")
        self.gh_llamadas.clear()
        self.client.get("/inicio/te-toca")
        self.assertNotIn("https://github.com/acme/tienda/pull/6", [a[3] for a, _ in self.gh_llamadas])

    def test_ac6_sin_gh_sigue_con_lo_del_kanban_y_sin_merge(self):
        with mock.patch.object(self.mod, "hay_gh", return_value=False):
            items = self.client.get("/inicio/te-toca").json()["items"]
        self.assertEqual([i["tipo"] for i in items], ["plan", "bloqueada"])
        self.assertEqual(self.gh_llamadas, [])

    def test_ac6_gh_sin_red_no_inventa_merges(self):
        self.datos["gh"] = {}
        items = self.client.get("/inicio/te-toca").json()["items"]
        self.assertEqual([i["tipo"] for i in items], ["plan", "bloqueada"])

    def test_ac6_un_tablero_roto_no_tumba_los_demas(self):
        roto = self.tmp / "hermes" / "kanban" / "boards" / "roto" / "kanban.db"
        roto.parent.mkdir(parents=True)
        roto.write_text("no es sqlite", encoding="utf-8")
        with self.assertLogs(self.mod.log, "WARNING") as logs:
            r = self.client.get("/inicio/te-toca")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.json()["items"]), 3)
        self.assertIn("roto", logs.output[0])

    def test_ac3a_sin_tableros_lista_vacia(self):
        with mock.patch.object(self.comun, "tableros", return_value=[]):
            self.assertEqual(self.client.get("/inicio/te-toca").json(), {"items": []})


class TestEnMarcha(TableroTest):
    def test_ac3d_running_por_tablero_con_modelo_sesion_y_pausa(self):
        r = self.client.get("/inicio/en-marcha")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json(), self.fixture("tablero_en_marcha"))

    def test_ac3d_sin_pausa_activa_si_existe_el_fin(self):
        (self.data / "pausa-tableros.fin").touch()
        grupos = self.client.get("/inicio/en-marcha").json()["grupos"]
        self.assertEqual([g["board"] for g in grupos], ["default"])
        self.assertNotIn("pausa", grupos[0])

    def test_ac3d_sin_fichero_de_pausa_no_hay_pausa(self):
        (self.data / "pausa-tableros.tsv").unlink()
        grupos = self.client.get("/inicio/en-marcha").json()["grupos"]
        self.assertEqual([g["board"] for g in grupos], ["default"])

    def test_ac3d_sin_max_in_progress_maximo_null(self):
        (self.tmp / "hermes" / "config.yaml").write_text("kanban: {}\n", encoding="utf-8")
        self.assertIsNone(self.client.get("/inicio/en-marcha").json()["maximo"])

    def test_ac3d_sin_max_in_progress_usa_el_derivado_de_hermes(self):
        (self.tmp / "hermes" / "config.yaml").write_text("kanban: {}\n", encoding="utf-8")
        falso = mock.Mock(resolve_max_in_progress=mock.Mock(return_value=6))
        with mock.patch.dict(sys.modules, {"hermes_cli": mock.Mock(), "hermes_cli.kanban_db_dispatch": falso}):
            self.assertEqual(self.client.get("/inicio/en-marcha").json()["maximo"], 6)
        falso.resolve_max_in_progress.assert_called_once_with(None)

    def test_ac3d_solo_lee_state_db_y_nunca_otro_fichero(self):
        otro = self.tmp / "otro.db"
        shutil.copy(self.state_db, otro)
        con = sqlite3.connect(self.tmp / "hermes" / "kanban.db")
        con.execute("UPDATE task_events SET payload=? WHERE kind='owner_admitted' AND run_id=2",
                    (json.dumps({"db": str(otro), "session_id": "sesion-1"}),))
        con.commit()
        con.close()
        item = self.client.get("/inicio/en-marcha").json()["grupos"][0]["items"][0]
        self.assertEqual((item["llamadas"], item["herramientas"]), (None, None))

    def test_ac3d_no_escribe_en_el_kanban(self):
        ruta = self.tmp / "hermes" / "kanban.db"
        antes = ruta.read_bytes()
        self.client.get("/inicio/en-marcha")
        self.client.get("/inicio/te-toca")
        self.assertEqual(ruta.read_bytes(), antes)
        self.assertFalse(Path(f"{ruta}-journal").exists())

    def test_ac6_sin_tableros(self):
        with mock.patch.object(self.comun, "tableros", return_value=[]):
            self.assertEqual(self.client.get("/inicio/en-marcha").json(), {"activos": 0, "maximo": 8, "grupos": []})
