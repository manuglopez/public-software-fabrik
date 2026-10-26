"""Base común de los tests del backend de The Factory (patrón que copian los demás).

Uso en un test nuevo:
    from tests.panel.base import PanelTest
    class TestAlgo(PanelTest):
        def test_x(self):
            r = self.client.get("/inicio/te-toca")
            self.assertEqual(r.json(), self.fixture("te_toca"))
El router se monta en una FastAPI propia; `self.client` no toca red, HOME ni el Kanban real.
"""
import importlib.util
import json
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
DASHBOARD = RAIZ / "plugin" / "fabrica" / "dashboard"
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def cargar_api(nombre: str = "fabrica_plugin_api_test"):
    """Carga plugin_api.py como lo hace el gateway (spec_from_file_location, sin sys.path)."""
    spec = importlib.util.spec_from_file_location(nombre, DASHBOARD / "plugin_api.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class PanelTest(unittest.TestCase):
    def setUp(self):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        self.api = cargar_api()
        app = FastAPI()
        app.include_router(self.api.router)
        self.client = TestClient(app)

    @staticmethod
    def fixture(nombre: str):
        return json.loads((FIXTURES / f"{nombre}.json").read_text(encoding="utf-8"))
