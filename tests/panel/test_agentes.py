"""AC-4b / AC-2b: dashboard/fx_agentes.py — contrato /agentes* (plan The Factory D-5).

`fabrik-modelos` es falso (FABRIK_HOME temporal con bin/fabrik-modelos que apunta sus llamadas y responde con los
fixtures `agentes_*.json`); la config personal es un fichero temporal (FABRIK_CONFIG). Nunca toca HOME ni la
config real.
"""
import os
import shutil
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

import yaml

from tests.panel.base import FIXTURES, RAIZ, PanelTest

FALSO = textwrap.dedent('''\
    import json, os, sys
    from pathlib import Path
    base = Path(__file__).resolve().parents[1]
    with open(base / "llamadas.log", "a") as f:
        f.write(" ".join(sys.argv[1:]) + "\\n")
    if os.environ.get("FALLO_MODELOS"):
        print("Traceback: algo se rompió", file=sys.stderr)
        sys.exit(1)
    args = [a for a in sys.argv[1:] if a != "--json"]
    if args[0] == "estado":
        print("aviso: rol «x»: rutas desconocidas ['y']", file=sys.stderr)
        print((base / "estado.json").read_text())
    elif args[0] == "informe":
        datos = json.loads((base / "informe.json").read_text())
        datos["dias"] = int(args[1])
        print(json.dumps(datos))
    elif args[0] == "tick":
        print("programador  → opus@b  (disponibles: opus@b, kimi)")
''')

REGLAS = {"roles_codigo": ["programador", "tester"], "prohibidos_codigo": ["*flash*"],
          "sufijo_obligatorio": {"gemini-*": "-high"}, "revisor_otra_familia": True}


class AgentesTest(PanelTest):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="fx-agentes-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        fh = self.tmp / "fabrik"
        (fh / "bin").mkdir(parents=True)
        (fh / "scripts").mkdir()
        (fh / "scripts" / "fabrik_config.py").symlink_to(RAIZ / "scripts" / "fabrik_config.py")
        (fh / "bin" / "fabrik-modelos").write_text(FALSO)
        shutil.copy(FIXTURES / "agentes_estado.json", fh / "estado.json")
        shutil.copy(FIXTURES / "agentes_informe.json", fh / "informe.json")
        self.llamadas = fh / "llamadas.log"
        self.personal = self.tmp / "fabrik.yaml"
        self.original = {"usuario_github": "alguien", "packs": [], "modelos": {"reglas": REGLAS}}
        self.personal.write_text(yaml.safe_dump(self.original, sort_keys=False))
        entorno = {"FABRIK_HOME": str(fh), "FABRIK_CONFIG": str(self.personal), "HOME": str(self.tmp / "home"),
                   "FABRIK_DATA": str(self.tmp / "data")}
        parche = mock.patch.dict(os.environ, entorno)
        parche.start()
        self.addCleanup(parche.stop)
        os.environ.pop("FALLO_MODELOS", None)
        super().setUp()

    def llamadas_(self):
        return self.llamadas.read_text().splitlines() if self.llamadas.exists() else []

    def test_get_agentes_contrato(self):
        r = self.client.get("/agentes")
        self.assertEqual(r.status_code, 200)
        d = r.json()
        fx = self.fixture("agentes_estado")
        for clave in ("reparto", "estado", "perfiles", "brazos_7d", "cuentas"):
            self.assertEqual(d[clave], fx[clave], clave)
        self.assertEqual(d["reglas"], REGLAS)
        self.assertEqual(d["avisos"], [
            "fabrik-modelos: rol «x»: rutas desconocidas ['y']",
            *[f"{rol}: «gemini-med» (gemini-3.8-flash-medium) tiene que acabar en «-high» "
              "(reglas.sufijo_obligatorio «gemini-*»)" for rol in ("explorador", "docs")]])
        self.assertEqual(self.llamadas_(), ["estado --json"])

    def test_get_agentes_sin_fabrik_modelos(self):
        os.environ["FALLO_MODELOS"] = "1"
        d = self.client.get("/agentes").json()
        self.assertEqual(d["disponible"], False)
        self.assertIn("algo se rompió", d["motivo"])

    def test_informe_dias(self):
        d = self.client.get("/agentes/informe", params={"dias": 7}).json()
        self.assertEqual(d, {**self.fixture("agentes_informe"), "dias": 7})
        self.assertEqual(self.client.get("/agentes/informe").json()["dias"], 14)
        self.assertEqual(self.client.get("/agentes/informe", params={"dias": 0}).status_code, 422)
        self.assertEqual(self.client.get("/agentes/informe", params={"dias": "x"}).status_code, 422)
        self.assertEqual(self.llamadas_(), ["informe 7 --json", "informe 14 --json"])

    def test_validar(self):
        cambio = {"roles": {"tester": ["kimi", "gemini-high"]}}
        d = self.client.post("/agentes/validar", json={"reparto": cambio}).json()
        self.assertIn("tester: «gemini-high» (gemini-3.8-flash-high) no puede ser candidato de un rol de código: "
                      "casa con «*flash*» (reglas.prohibidos_codigo)", d["errores"])
        # el resto de roles sigue el reparto vigente: sus avisos (explorador, docs) también cuentan
        self.assertEqual(len(d["errores"]), 3)
        bien = {"roles": {"explorador": ["gemini-high"], "docs": ["gemini-high"]}, "topes": {"5h": 80},
                "topes_cuenta": {"a": 90}, "ultimo_recurso": "gemini-high"}
        self.assertEqual(self.client.post("/agentes/validar", json={"reparto": bien}).json(), {"errores": []})

    def test_validar_rechaza_lo_que_no_se_edita(self):
        d = self.client.post("/agentes/validar", json={"reparto": {"rutas": {}, "cadena_codigo": []}}).json()
        self.assertEqual(d["errores"], ["rutas: el catálogo de rutas no se edita desde el panel (va en el yaml)",
                                        "cadena_codigo: clave desconocida (se editan roles, ultimo_recurso, topes, "
                                        "topes_cuenta)"])
        self.assertEqual(self.client.post("/agentes/validar", json={"reparto": [1]}).json()["errores"],
                         ["reparto: tiene que ser un mapa"])

    def test_guardar_con_errores_no_escribe(self):
        antes = self.personal.read_text()
        d = self.client.post("/agentes/guardar", json={"reparto": {"topes": {"5h": 500}}}).json()
        self.assertEqual(d["ok"], False)
        self.assertEqual(d["errores"][-1], "tope de la bolsa 5h: 500 no vale, tiene que ser un entero entre 1 y 100")
        self.assertEqual(self.personal.read_text(), antes)

    def test_guardar_escribe_solo_reparto(self):
        bien = {"roles": {"explorador": ["gemini-high"], "docs": ["gemini-high"]}, "topes_cuenta": {"a": 90}}
        d = self.client.post("/agentes/guardar", json={"reparto": bien}).json()
        self.assertEqual((d["ok"], d["errores"]), (True, []))
        self.assertIn(str(self.personal), d["salida"])
        escrito = yaml.safe_load(self.personal.read_text())
        self.assertEqual(escrito, {**self.original, "modelos": {"reglas": REGLAS, "reparto": bien}})
        self.assertNotIn("tick", "\n".join(self.llamadas_()))  # guardar no aplica: eso es «Aplicar ahora»

    def test_aplicar_lanza_tick(self):
        with self.assertLogs("fabrica.agentes", "INFO") as logs:
            d = self.client.post("/agentes/aplicar", json={}).json()
        self.assertEqual(d["ok"], True)
        self.assertIn("programador  → opus@b", d["salida"])
        self.assertEqual(self.llamadas_(), ["tick"])
        self.assertEqual(len(logs.output), 1)

    def test_aplicar_falla(self):
        os.environ["FALLO_MODELOS"] = "1"
        d = self.client.post("/agentes/aplicar", json={}).json()
        self.assertEqual(d["ok"], False)
        self.assertIn("algo se rompió", d["salida"])


if __name__ == "__main__":
    unittest.main()
