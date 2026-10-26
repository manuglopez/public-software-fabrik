"""Piezas comunes del backend (BASE, D-9 R-4): `dashboard/comun.py`, que `plugin_api.py` publica como `fabrica_comun`.

Sin red ni HOME real: los tableros son SQLite de fixture en un directorio temporal (HERMES_KANBAN_HOME) y la config
apunta a ficheros temporales (FABRIK_CONFIG).
"""
import os
import shutil
import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

from fastapi import APIRouter, FastAPI
from fastapi.testclient import TestClient

from tests.panel.base import DASHBOARD, cargar_api


def crear_tablero(ruta: Path, titulos=("Uno",)) -> Path:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(ruta)
    con.execute("CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, status TEXT)")
    con.executemany("INSERT INTO tasks VALUES (?, ?, 'ready')", [(f"t_{i}", t) for i, t in enumerate(titulos)])
    con.commit()
    con.close()
    return ruta


class ComunTest(unittest.TestCase):
    def setUp(self):
        self.api = cargar_api()
        self.comun = sys.modules["fabrica_comun"]
        self.tmp = Path(tempfile.mkdtemp(prefix="fx-comun-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        entorno = {"HERMES_KANBAN_HOME": str(self.tmp / "home"), "FABRIK_DATA": str(self.tmp / "data")}
        parche = mock.patch.dict(os.environ, entorno)
        parche.start()
        self.addCleanup(parche.stop)
        for var in ("HERMES_KANBAN_DB", "HERMES_KANBAN_BOARD"):
            os.environ.pop(var, None)
        # Sin hermes_cli (como en uv run): el resolvedor cae al de entorno. Los tests que lo quieren lo inyectan.
        sin_hermes = mock.patch.dict(sys.modules, {"hermes_cli": None, "hermes_cli.kanban_db": None})
        sin_hermes.start()
        self.addCleanup(sin_hermes.stop)


class TestRegistro(ComunTest):
    def test_plugin_api_publica_fabrica_comun_desde_dashboard(self):
        self.assertEqual(Path(self.comun.__file__).resolve(), (DASHBOARD / "comun.py").resolve())

    def test_los_fx_pueden_importar_fabrica_comun_al_cargarse(self):
        d = self.tmp / "dashboard"
        d.mkdir()
        shutil.copy(DASHBOARD / "comun.py", d / "comun.py")
        (d / "fx_tablero.py").write_text(
            "import fabrica_comun as comun\n"
            "def registrar(r):\n"
            "    r.add_api_route('/prueba', lambda: comun.no_disponible('sin fuente'), methods=['GET'])\n",
            encoding="utf-8",
        )
        sys.modules.pop("fabrica_comun", None)
        r = APIRouter()
        self.assertEqual(self.api.cargar_modulos(r, d), ["fx_tablero"])
        app = FastAPI()
        app.include_router(r)
        self.assertEqual(TestClient(app).get("/prueba").json(), {"disponible": False, "motivo": "sin fuente"})
        self.assertEqual(Path(sys.modules["fabrica_comun"].__file__).resolve(), (d / "comun.py").resolve())

    def test_sin_comun_avisa_y_los_fx_que_no_lo_usan_cargan(self):
        d = self.tmp / "dashboard"
        d.mkdir()
        (d / "fx_tablero.py").write_text("def registrar(r):\n    pass\n", encoding="utf-8")
        with self.assertLogs(self.api.log, "WARNING") as logs:
            self.assertEqual(self.api.cargar_modulos(APIRouter(), d), ["fx_tablero"])
        self.assertIn("falta", logs.output[0])
        self.assertNotIn("fabrica_comun", sys.modules)

    def test_comun_roto_da_error_y_no_tumba_la_carga(self):
        d = self.tmp / "dashboard"
        d.mkdir()
        (d / "comun.py").write_text("raise RuntimeError('roto')\n", encoding="utf-8")
        (d / "fx_tablero.py").write_text("def registrar(r):\n    pass\n", encoding="utf-8")
        with self.assertLogs(self.api.log, "ERROR") as logs:
            self.assertEqual(self.api.cargar_modulos(APIRouter(), d), ["fx_tablero"])
        self.assertIn("no se pudo cargar comun.py", logs.output[0])
        self.assertNotIn("fabrica_comun", sys.modules)


class TestTableros(ComunTest):
    def test_default_primero_y_luego_los_tableros_con_kanban_db(self):
        home = self.tmp / "home"
        crear_tablero(home / "kanban.db")
        crear_tablero(home / "kanban" / "boards" / "zeta" / "kanban.db")
        crear_tablero(home / "kanban" / "boards" / "alfa" / "kanban.db")
        (home / "kanban" / "boards" / "vacio").mkdir()  # sin kanban.db: no es tablero
        crear_tablero(home / "kanban" / "boards" / "_archived" / "kanban.db")  # slug no válido
        crear_tablero(home / "kanban" / "boards" / "default" / "kanban.db")  # default vive en <home>/kanban.db
        self.assertEqual(
            self.comun.tableros(),
            [
                ("default", home / "kanban.db"),
                ("alfa", home / "kanban" / "boards" / "alfa" / "kanban.db"),
                ("zeta", home / "kanban" / "boards" / "zeta" / "kanban.db"),
            ],
        )

    def test_sin_nada_en_disco_devuelve_lista_vacia(self):
        self.assertEqual(self.comun.tableros(), [])

    def test_usa_el_resolvedor_de_hermes_cli_y_no_el_tablero_fijado_por_HERMES_KANBAN_DB(self):
        raiz = self.tmp / "otra"
        crear_tablero(raiz / "kanban.db")
        crear_tablero(raiz / "kanban" / "boards" / "ops" / "kanban.db")
        kb = types.ModuleType("hermes_cli.kanban_db")
        kb.kanban_home = lambda: raiz
        kb.boards_root = lambda: raiz / "kanban" / "boards"
        paquete = types.ModuleType("hermes_cli")
        paquete.kanban_db = kb
        os.environ["HERMES_KANBAN_DB"] = str(self.tmp / "fijado.db")  # un worker lo hereda: no debe colarse
        with mock.patch.dict(sys.modules, {"hermes_cli": paquete, "hermes_cli.kanban_db": kb}):
            self.assertEqual(
                self.comun.tableros(),
                [("default", raiz / "kanban.db"), ("ops", raiz / "kanban" / "boards" / "ops" / "kanban.db")],
            )


class TestConectarRo(ComunTest):
    def test_lee_pero_no_puede_escribir(self):
        db = crear_tablero(self.tmp / "con espacio" / "kanban.db", ("A", "B"))
        con = self.comun.conectar_ro(db)
        try:
            filas = con.execute("SELECT id, title FROM tasks ORDER BY id").fetchall()
            self.assertEqual([tuple(f) for f in filas], [("t_0", "A"), ("t_1", "B")])
            self.assertEqual(filas[0]["title"], "A")  # sqlite3.Row
            with self.assertRaises(sqlite3.OperationalError):
                con.execute("UPDATE tasks SET title = 'x'")
        finally:
            con.close()

    def test_no_crea_la_bd_si_no_existe(self):
        with self.assertRaises(sqlite3.OperationalError):
            self.comun.conectar_ro(self.tmp / "no-existe.db")
        self.assertFalse((self.tmp / "no-existe.db").exists())


class TestEjecutar(ComunTest):
    def test_ok_y_salida(self):
        ok, salida = self.comun.ejecutar([sys.executable, "-c", "print('hola')"], timeout=10)
        self.assertTrue(ok)
        self.assertEqual(salida, "hola")

    def test_fallo_con_stderr(self):
        ok, salida = self.comun.ejecutar([sys.executable, "-c", "import sys; sys.exit('mal')"], timeout=10)
        self.assertFalse(ok)
        self.assertIn("mal", salida)

    def test_timeout_no_cuelga(self):
        ok, salida = self.comun.ejecutar([sys.executable, "-c", "import time; time.sleep(30)"], timeout=0.5)
        self.assertFalse(ok)
        self.assertIn("timeout", salida)

    def test_comando_inexistente(self):
        ok, salida = self.comun.ejecutar(["fx-no-existe-este-comando"], timeout=5)
        self.assertFalse(ok)
        self.assertIn("fx-no-existe-este-comando", salida)

    def test_nunca_shell_ni_cadenas(self):
        with mock.patch.object(self.comun.subprocess, "run", wraps=self.comun.subprocess.run) as run:
            self.comun.ejecutar([sys.executable, "-c", "pass"], timeout=10)
        self.assertIs(run.call_args.kwargs["shell"], False)
        with self.assertRaises(TypeError):
            self.comun.ejecutar("echo hola; rm -rf /", timeout=5)

    def test_salida_resumida(self):
        ok, salida = self.comun.ejecutar([sys.executable, "-c", "print('x' * 10000 + 'FIN')"], timeout=10)
        self.assertTrue(ok)
        self.assertLessEqual(len(salida), self.comun.MAX_SALIDA + 1)
        self.assertTrue(salida.endswith("FIN"))  # se queda con el final, que es donde está el error


class TestConfigYDatos(ComunTest):
    def test_fabrik_data_por_entorno(self):
        self.assertEqual(self.comun.fabrik_data(), self.tmp / "data")

    def test_fabrik_data_por_defecto(self):
        os.environ.pop("FABRIK_DATA")
        self.assertEqual(self.comun.fabrik_data(), Path.home() / ".hermes" / "factory")

    def test_fabrik_home_por_entorno(self):
        with mock.patch.dict(os.environ, {"FABRIK_HOME": str(self.tmp / "motor")}):
            self.assertEqual(self.comun.fabrik_home(), self.tmp / "motor")

    def test_fabrik_home_enlazado_desde_el_repo_es_el_repo(self):
        os.environ.pop("FABRIK_HOME", None)
        self.assertEqual(self.comun.fabrik_home(), DASHBOARD.resolve().parents[2])

    def test_fabrik_home_instalado_desde_el_catalogo_sigue_el_enlace_de_install_sh(self):
        # Copia del catálogo (solo plugin/fabrica, sin el motor alrededor): el repo sale de $FABRIK_DATA/scripts,
        # el enlace que crea ./install.sh hacia <repo>/scripts.
        os.environ.pop("FABRIK_HOME", None)
        motor = self.tmp / "motor"
        (motor / "scripts").mkdir(parents=True)
        (self.tmp / "data").mkdir()
        (self.tmp / "data" / "scripts").symlink_to(motor / "scripts")
        copia = self.tmp / "plugins" / "fabrica" / "dashboard" / "comun.py"
        with mock.patch.object(self.comun, "__file__", str(copia)):
            self.assertEqual(self.comun.fabrik_home(), motor.resolve())

    def test_fabrik_home_del_catalogo_sin_motor_instalado_no_inventa_un_repo(self):
        os.environ.pop("FABRIK_HOME", None)
        copia = self.tmp / "plugins" / "fabrica" / "dashboard" / "comun.py"
        with mock.patch.object(self.comun, "__file__", str(copia)):
            self.assertEqual(self.comun.fabrik_home(), copia.parents[3])

    def test_config_fusionada_con_la_personal(self):
        personal = self.tmp / "fabrik.yaml"
        personal.write_text("idioma: eo\nproyectos_fx: [uno]\n", encoding="utf-8")
        with mock.patch.dict(os.environ, {"FABRIK_CONFIG": str(personal)}):
            cfg = self.comun.config()
        self.assertEqual(cfg["idioma"], "eo")
        self.assertEqual(cfg["proyectos_fx"], ["uno"])
        self.assertIn("modelos", cfg)  # capa motor

    def test_config_tolerante_a_yaml_roto(self):
        personal = self.tmp / "fabrik.yaml"
        personal.write_text("idioma: [sin cerrar\n", encoding="utf-8")
        with mock.patch.dict(os.environ, {"FABRIK_CONFIG": str(personal)}):
            self.assertEqual(self.comun.config(), {})

    def _sin_pyyaml(self):
        """Como dentro de Hermes: no hay PyYAML, solo `hermes_yaml` (aquí un doble que delega en PyYAML)."""
        import yaml as pyyaml

        doble = types.SimpleNamespace(safe_load=pyyaml.safe_load, safe_dump=pyyaml.safe_dump, YAMLError=pyyaml.YAMLError)
        parche = mock.patch.dict(sys.modules, {"yaml": None, "hermes_yaml": doble})
        parche.start()
        self.addCleanup(parche.stop)
        # fabrik_config se carga una vez por proceso: forzar que se reimporte sin PyYAML y dejarlo como estaba.
        recargar = mock.patch.object(self.comun, "_cfg_mod", None)
        recargar.start()
        self.addCleanup(recargar.stop)

    def test_yaml_sin_pyyaml_usa_hermes_yaml(self):
        self._sin_pyyaml()
        with self.assertRaises(ImportError):
            import yaml  # noqa: F401
        self.assertEqual(self.comun.yaml_safe_load("a: [1, 2]\n"), {"a": [1, 2]})

    def test_config_sin_pyyaml_usa_hermes_yaml(self):
        self._sin_pyyaml()
        personal = self.tmp / "fabrik.yaml"
        personal.write_text("idioma: eo\n", encoding="utf-8")
        with mock.patch.dict(os.environ, {"FABRIK_CONFIG": str(personal)}):
            self.assertEqual(self.comun.config()["idioma"], "eo")

    def test_no_disponible(self):
        self.assertEqual(self.comun.no_disponible("sin gh"), {"disponible": False, "motivo": "sin gh"})


if __name__ == "__main__":
    unittest.main()
