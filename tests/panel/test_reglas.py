"""AC-4b / D-6: dashboard/fx_reglas.py — validar_reparto(config, reparto) -> [errores].

Las mismas reglas dan los avisos del reparto vigente.

Reparto de fixture `agentes_estado.json` (el que da `fabrik-modelos estado --json` sin `modelos.reparto`).
"""
import copy
import unittest

from tests.panel.base import PanelTest, cargar_api

REGLAS_USUARIO = {"roles_codigo": ["programador", "tester"], "prohibidos_codigo": ["*flash*"],
                  "sufijo_obligatorio": {"gemini-*": "-high"}, "revisor_otra_familia": True}
REGLAS_MOTOR = {"roles_codigo": ["programador", "tester"], "revisor_otra_familia": True}


def _cfg(reglas):
    return {"modelos": {"reglas": reglas}}


class ReglasTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import sys

        cargar_api()
        cls.r = sys.modules["fabrica_fx_reglas"]
        cls.base = PanelTest.fixture("agentes_estado")["reparto"]

    def rep(self, **cambios):
        r = copy.deepcopy(self.base)
        r.update(cambios)
        return r

    def roles(self, **roles):
        return self.rep(roles={**self.base["roles"], **roles})

    def test_reparto_vigente(self):
        self.assertEqual(self.r.validar_reparto(_cfg(REGLAS_MOTOR), self.base), [])
        self.assertEqual(self.r.validar_reparto({}, self.base), [])
        # con las reglas del usuario, el reparto por defecto incumple el sufijo en explorador y docs: son los avisos
        self.assertEqual(self.r.validar_reparto(_cfg(REGLAS_USUARIO), self.base), [
            f"{rol}: «gemini-med» (gemini-3.8-flash-medium) tiene que acabar en «-high» "
            "(reglas.sufijo_obligatorio «gemini-*»)" for rol in ("explorador", "docs")])

    def test_regla1_prohibidos_en_roles_de_codigo(self):
        reglas = {**REGLAS_MOTOR, "prohibidos_codigo": ["*flash*"]}
        errores = self.r.validar_reparto(_cfg(reglas), self.roles(tester=["kimi", "gemini-high"]))
        self.assertEqual(errores, ["tester: «gemini-high» (gemini-3.8-flash-high) no puede ser candidato de un rol "
                                   "de código: casa con «*flash*» (reglas.prohibidos_codigo)"])
        # fuera de los roles de código sí vale; y sin la regla en la config, tampoco hay error
        self.assertEqual(self.r.validar_reparto(_cfg(reglas), self.roles(revisor=["kimi", "gemini-high"])), [])
        self.assertEqual(self.r.validar_reparto(_cfg(REGLAS_MOTOR), self.roles(tester=["gemini-high"])), [])

    def test_regla1_roles_codigo_de_la_config(self):
        reglas = {"roles_codigo": ["programador"], "prohibidos_codigo": ["*flash*"]}
        self.assertEqual(self.r.validar_reparto(_cfg(reglas), self.roles(tester=["kimi", "gemini-high"])), [])

    def test_regla2_sufijo_obligatorio(self):
        rep = self.roles(explorador=["gemini-high"], docs=["gemini-high", "gemini-med"])
        rep["ultimo_recurso"] = "gemini-med"
        self.assertEqual(self.r.validar_reparto(_cfg({"sufijo_obligatorio": {"gemini-*": "-high"}}), rep), [
            "docs: «gemini-med» (gemini-3.8-flash-medium) tiene que acabar en «-high» "
            "(reglas.sufijo_obligatorio «gemini-*»)",
            "último recurso: «gemini-med» (gemini-3.8-flash-medium) tiene que acabar en «-high» "
            "(reglas.sufijo_obligatorio «gemini-*»)",
        ])

    def test_regla3_candidatos_rutas_y_topes(self):
        rep = self.rep(roles={**self.base["roles"], "docs": [], "tester": ["kimi", "fantasma", "kimi"]},
                       ultimo_recurso="nada", topes={**self.base["topes"], "5h": 0, "sem": "97"},
                       topes_cuenta={"a": 101, "b": True})
        self.assertEqual(self.r.validar_reparto({}, rep), [
            "tester: la ruta «fantasma» no existe (rutas: " + ", ".join(self.base["rutas"]) + ")",
            "tester: «kimi» está repetida",
            "docs: necesita al menos un candidato",
            "último recurso: la ruta «nada» no existe",
            "tope de la bolsa 5h: 0 no vale, tiene que ser un entero entre 1 y 100",
            "tope de la bolsa sem: '97' no vale, tiene que ser un entero entre 1 y 100",
            "tope semanal de la cuenta a: 101 no vale, tiene que ser un entero entre 1 y 100",
            "tope semanal de la cuenta b: True no vale, tiene que ser un entero entre 1 y 100",
        ])

    def test_regla4_revisor_otra_familia(self):
        rep = self.roles(programador=["opus", "sonnet"], seguridad=["agy-opus", "opus"])
        self.assertEqual(self.r.validar_reparto({}, rep), [
            "revisor: todos sus candidatos son de la familia anthropic, como los del programador; añade uno de otra "
            "familia para que pueda revisar con otro modelo (reglas.revisor_otra_familia)",
            "seguridad: todos sus candidatos son de la familia anthropic, como los del programador; añade uno de otra "
            "familia para que pueda revisar con otro modelo (reglas.revisor_otra_familia)",
        ])
        self.assertEqual(self.r.validar_reparto(_cfg({"revisor_otra_familia": False}), rep), [])

    def test_reparto_malformado_no_revienta(self):
        errores = self.r.validar_reparto({}, {"rutas": "x", "roles": {"programador": "opus"}, "topes": []})
        self.assertIn("programador: los candidatos tienen que ser una lista de rutas", errores)
        self.assertIn("topes: tiene que ser un mapa bolsa → %", errores)


if __name__ == "__main__":
    unittest.main()
