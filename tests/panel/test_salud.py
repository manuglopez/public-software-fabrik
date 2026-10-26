"""AC-2 base: GET /salud y carga de módulos hermanos (D-4)."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

from tests.panel.base import DASHBOARD, PanelTest, cargar_api

COMANDOS = {"kanban": "hermes", "gh": "gh", "cupos": "fabrik-cupos", "memoria": "fabrik-memoria"}


class TestSalud(PanelTest):
    def test_salud_devuelve_forma_del_contrato(self):
        r = self.client.get("/salud")
        self.assertEqual(r.status_code, 200)
        cuerpo = r.json()
        self.assertTrue(cuerpo["ok"])
        self.assertEqual(set(cuerpo["fuentes"]), set(COMANDOS))
        self.assertEqual(set(cuerpo), set(self.fixture("salud")))

    def test_version_coincide_con_fixture_manifest_y_plugin_yaml(self):
        self.assertEqual(self.api.VERSION, self.fixture("salud")["version"])
        manifest = json.loads((DASHBOARD / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(self.api.VERSION, manifest["version"])
        plugin = yaml.safe_load((DASHBOARD.parent / "plugin.yaml").read_text(encoding="utf-8"))
        self.assertEqual(self.api.VERSION, plugin["version"])
        self.assertEqual(self.client.get("/salud").json()["version"], self.api.VERSION)

    def test_cada_fuente_depende_solo_de_su_comando(self):
        for fuente, cmd in COMANDOS.items():
            with self.subTest(fuente=fuente):
                with mock.patch.object(self.api.shutil, "which", side_effect=lambda c, cmd=cmd: f"/x/{c}" if c == cmd else None):
                    fuentes = self.client.get("/salud").json()["fuentes"]
                self.assertEqual({k for k, v in fuentes.items() if v}, {fuente})

    def test_sin_ningun_comando_todas_las_fuentes_son_false(self):
        with mock.patch.object(self.api.shutil, "which", return_value=None):
            r = self.client.get("/salud")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["fuentes"], {k: False for k in COMANDOS})

    def test_con_todos_los_comandos_todas_las_fuentes_son_true(self):
        with mock.patch.object(self.api.shutil, "which", return_value="/x/cmd"):
            fuentes = self.client.get("/salud").json()["fuentes"]
        self.assertEqual(fuentes, {k: True for k in COMANDOS})


class TestModulos(unittest.TestCase):
    def setUp(self):
        self.addCleanup(lambda: [sys.modules.pop(k) for k in [k for k in sys.modules if k.startswith("fabrica_fx_")]])

    def test_lista_fija_de_modulos(self):
        api = cargar_api("fabrica_api_modulos")
        self.assertEqual(
            api.MODULOS,
            ["fx_tablero", "fx_atascadas", "fx_acciones", "fx_sistema", "fx_memoria",
             "fx_proyectos", "fx_costes", "fx_reglas", "fx_agentes", "fx_consola"],
        )

    def test_carga_modulo_existente_y_omite_los_que_faltan(self):
        from fastapi import APIRouter
        api = cargar_api("fabrica_api_carga")
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "fx_tablero.py").write_text(
                "def registrar(router):\n"
                "    @router.get('/hola')\n"
                "    def hola():\n"
                "        return {'hola': 1}\n", encoding="utf-8")
            router = APIRouter()
            cargados = api.cargar_modulos(router, directorio=Path(d))
        self.assertEqual(cargados, ["fx_tablero"])
        self.assertIn("/hola", [r.path for r in router.routes])

    def test_modulo_que_falla_no_impide_el_resto(self):
        from fastapi import APIRouter
        api = cargar_api("fabrica_api_fallo")
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "fx_tablero.py").write_text("raise RuntimeError('roto')\n", encoding="utf-8")
            (Path(d) / "fx_atascadas.py").write_text("def registrar(router):\n    pass\n", encoding="utf-8")
            cargados = api.cargar_modulos(APIRouter(), directorio=Path(d))
        self.assertEqual(cargados, ["fx_atascadas"])

    def test_modulo_se_registra_en_sys_modules_para_que_pydantic_resuelva_anotaciones(self):
        from fastapi import APIRouter, FastAPI
        from fastapi.testclient import TestClient
        api = cargar_api("fabrica_api_pydantic")
        fuente = (
            "from __future__ import annotations\n"
            "import sys\n"
            "from pydantic import BaseModel\n"
            "class Cuerpo(BaseModel):\n"
            "    n: int\n"
            "REGISTRADO = sys.modules.get(__name__) is not None\n"
            "def registrar(router):\n"
            "    assert REGISTRADO\n"
            "    @router.post('/eco')\n"
            "    def eco(c: Cuerpo):\n"
            "        return {'n': c.n}\n"
        )
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "fx_tablero.py").write_text(fuente, encoding="utf-8")
            router = APIRouter()
            self.assertEqual(api.cargar_modulos(router, directorio=Path(d)), ["fx_tablero"])
        app = FastAPI()
        app.include_router(router)
        r = TestClient(app).post("/eco", json={"n": 3})
        self.assertEqual((r.status_code, r.json()), (200, {"n": 3}))
        self.assertIn("fabrica_fx_tablero", sys.modules)

    def test_modulo_roto_no_queda_en_sys_modules(self):
        from fastapi import APIRouter
        api = cargar_api("fabrica_api_limpieza")
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "fx_tablero.py").write_text("raise RuntimeError('roto')\n", encoding="utf-8")
            api.cargar_modulos(APIRouter(), directorio=Path(d))
        self.assertNotIn("fabrica_fx_tablero", sys.modules)

    def test_si_no_hay_spec_el_modulo_se_omite_sin_romper(self):
        from fastapi import APIRouter
        api = cargar_api("fabrica_api_sin_spec")
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "fx_tablero.py").write_text("def registrar(router):\n    pass\n", encoding="utf-8")
            with mock.patch.object(api.importlib.util, "spec_from_file_location", return_value=None):
                with self.assertLogs(api.log, level="ERROR") as logs:
                    cargados = api.cargar_modulos(APIRouter(), directorio=Path(d))
        self.assertEqual(cargados, [])
        self.assertIn("no se pudo cargar fx_tablero", logs.output[0])


if __name__ == "__main__":
    unittest.main()
