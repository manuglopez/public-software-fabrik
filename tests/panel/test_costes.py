"""AC-4c (Cupos y costes): `dashboard/fx_costes.py` → `GET /costes`.

Sin red ni HOME real: `cupos.jsonl` y los `state.db` de Hermes son ficheros de fixture en un directorio temporal, el
reloj está congelado (`fx.ahora`) y `fabrik-cupos` es un `comun.ejecutar` simulado.
"""
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tests.panel.base import PanelTest

AHORA = 1_800_000_000  # múltiplo de 3600: los cubos horarios caen justo en el límite
H, D = 3600, 86400
POOL = {
    "modelos": {
        "permitir_pago": False,
        "pool": {
            "medio": [
                {"proveedor": "kimi-coding", "modelo": "kimi", "herramientas": True, "coste": "suscripcion"},
                {"proveedor": "deepseek", "modelo": "ds-pro", "herramientas": True, "coste": "pago"},
            ],
            "ligero": [{"proveedor": "otro-pago", "modelo": "x", "herramientas": False, "coste": "pago"}],
        },
    }
}


def foto(t, **bolsas):
    return {"t": t, "bolsas": {k: [v, "2026-10-30T00:00:00Z"] for k, v in bolsas.items()}, "tokens": {}, "errores": {}}


def crear_state_db(ruta: Path, sesiones) -> None:
    """sesiones: [(billing_provider, started_at, actual_cost_usd, estimated_cost_usd)]"""
    ruta.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(ruta)
    con.execute(
        "CREATE TABLE sessions (id INTEGER PRIMARY KEY, billing_provider TEXT, started_at REAL, "
        "actual_cost_usd REAL, estimated_cost_usd REAL)"
    )
    con.executemany("INSERT INTO sessions (billing_provider, started_at, actual_cost_usd, estimated_cost_usd) VALUES (?,?,?,?)", sesiones)
    con.commit()
    con.close()


class CostesTest(PanelTest):
    def setUp(self):
        super().setUp()
        self.fx = sys.modules["fabrica_fx_costes"]
        self.sistema = sys.modules["fabrica_fx_sistema"]  # dueño de la lectura de cupos.jsonl
        self.comun = sys.modules["fabrica_comun"]
        self.tmp = Path(tempfile.mkdtemp(prefix="fx-costes-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        entorno = {
            "FABRIK_DATA": str(self.tmp / "data"),
            "HERMES_HOME": str(self.tmp / "hermes"),
            "FABRIK_CUPOS_LOG": str(self.tmp / "data" / "logs" / "cupos.jsonl"),
        }
        parche = mock.patch.dict(os.environ, entorno)
        parche.start()
        self.addCleanup(parche.stop)
        (self.tmp / "data" / "logs").mkdir(parents=True)
        self.salida_cupos = (True, json.dumps(self.fixture("proyectos_rate_limited")))
        self.llamadas = []
        for p in (
            mock.patch.object(self.fx, "ahora", return_value=AHORA),
            mock.patch.object(self.comun, "ejecutar", side_effect=self.ejecutar_falso),
            mock.patch.object(self.comun, "config", return_value=POOL),
        ):
            p.start()
            self.addCleanup(p.stop)

    def ejecutar_falso(self, argv, timeout):
        self.llamadas.append((list(argv), timeout))
        return self.salida_cupos

    def escribir_cupos(self, fotos, extra=""):
        (self.tmp / "data" / "logs" / "cupos.jsonl").write_text(
            "".join(json.dumps(f) + "\n" for f in fotos) + extra, encoding="utf-8"
        )

    def get(self):
        r = self.client.get("/costes")
        self.assertEqual(r.status_code, 200)
        return r.json()

    def historico(self, cuerpo):
        return {b["bolsa"]: b["puntos"] for b in cuerpo["bolsas_historico"]}


class TestHistorico(CostesTest):
    def test_ac4c_ultimos_7_dias_un_punto_por_hora_con_el_ultimo_valor(self):
        self.escribir_cupos([
            foto(AHORA - 8 * D, kimi_5h=99.0),  # fuera de la ventana
            foto(AHORA - 3 * D, kimi_5h=10.0, gemini_sem=1.0),
            foto(AHORA - 2 * H + 60, kimi_5h=20.0),
            foto(AHORA - 2 * H + 120, kimi_5h=25.0),  # misma hora: gana la última
            foto(AHORA - 60, kimi_5h=30.0, gemini_sem=2.0),
        ])
        h = self.historico(self.get())
        self.assertEqual(h["kimi_5h"], [[AHORA - 3 * D, 10.0], [AHORA - 2 * H + 120, 25.0], [AHORA - 60, 30.0]])
        self.assertEqual(h["gemini_sem"], [[AHORA - 3 * D, 1.0], [AHORA - 60, 2.0]])

    def test_ac4c_bolsas_ordenadas_por_nombre_y_puntos_cronologicos(self):
        self.escribir_cupos([foto(AHORA - 5 * H, zeta=1.0, alfa=2.0), foto(AHORA - H, zeta=3.0, alfa=4.0)])
        cuerpo = self.get()
        self.assertEqual([b["bolsa"] for b in cuerpo["bolsas_historico"]], ["alfa", "zeta"])
        for b in cuerpo["bolsas_historico"]:
            self.assertEqual(b["puntos"], sorted(b["puntos"]))

    def test_ac4c_lee_por_el_final_y_para_en_la_primera_foto_anterior_a_la_ventana(self):
        viejas = [foto(AHORA - 9 * D + i * 300, kimi_5h=-1.0) for i in range(200)]
        recientes = [foto(AHORA - D + i * 3600, kimi_5h=float(i)) for i in range(20)]
        self.escribir_cupos(viejas + recientes)
        with mock.patch.object(self.sistema, "BLOQUE", 200):
            puntos = self.historico(self.get())["kimi_5h"]
        self.assertEqual([p[1] for p in puntos], [float(i) for i in range(20)])

    def test_ac4c_bloques_pequenos_dan_lo_mismo_que_uno_grande(self):
        fotos = [foto(AHORA - 6 * D + i * 7200, kimi_5h=float(i)) for i in range(60)]
        self.escribir_cupos(fotos)
        grande = self.get()
        with mock.patch.object(self.sistema, "BLOQUE", 97):
            pequeno = self.get()
        self.assertEqual(pequeno["bolsas_historico"], grande["bolsas_historico"])
        self.assertEqual(len(grande["bolsas_historico"][0]["puntos"]), 60)

    def test_ac4c_linea_corrupta_se_salta_y_sin_fichero_avisa(self):
        self.escribir_cupos([foto(AHORA - H, kimi_5h=5.0)], extra="{no es json\n")
        self.assertEqual(self.historico(self.get())["kimi_5h"], [[AHORA - H, 5.0]])
        (self.tmp / "data" / "logs" / "cupos.jsonl").unlink()
        cuerpo = self.get()
        self.assertEqual(cuerpo["bolsas_historico"], [])
        self.assertTrue(any("cupos.jsonl" in a for a in cuerpo["avisos"]))

    def test_ac4c_tokens_de_la_ultima_foto_para_las_suscripciones(self):
        ultima = foto(AHORA - 60, kimi_5h=1.0)
        ultima["tokens"] = {"kimi": [100, 20, 3000], "gemini": [0, 0, 0]}
        self.escribir_cupos([foto(AHORA - D, kimi_5h=0.0), ultima])
        tokens = {t["familia"]: t for t in self.get()["tokens"]}
        self.assertEqual(tokens["kimi"], {"familia": "kimi", "entrada": 100, "salida": 20, "cache": 3000})
        self.assertNotIn("usd", tokens["kimi"])

    def test_ac4c_lee_el_mismo_cupos_jsonl_que_inicio(self):
        """La lectura de cupos.jsonl vive solo en fx_sistema: /costes y /cupos ven el mismo fichero."""
        os.environ.pop("FABRIK_CUPOS_LOG")  # sin la variable, ambos caen en $FABRIK_DATA/logs/cupos.jsonl
        self.escribir_cupos([foto(AHORA - H, kimi_5h=5.0), foto(AHORA - 60, kimi_5h=7.0)])
        with mock.patch.object(self.sistema, "ahora", return_value=AHORA):
            inicio = self.client.get("/cupos").json()
        self.assertEqual([(b["bolsa"], b["usado"]) for b in inicio["bolsas"]], [("kimi_5h", 7.0)])
        self.assertEqual(self.historico(self.get())["kimi_5h"][-1], [AHORA - 60, 7.0])
        otro = self.tmp / "otro.jsonl"
        otro.write_text(json.dumps(foto(AHORA - 60, otra=3.0)) + "\n", encoding="utf-8")
        with mock.patch.object(self.sistema, "ruta_cupos", return_value=otro):
            self.assertEqual(list(self.historico(self.get())), ["otra"])


class TestRateLimited(CostesTest):
    def test_ac4c_suma_los_tableros_por_dia_en_orden_cronologico(self):
        cuerpo = self.get()
        self.assertEqual(
            cuerpo["rate_limited"],
            [
                {"dia": "2026-10-22", "n": 0, "esperas": 0},
                {"dia": "2026-10-23", "n": 8, "esperas": 4},
                {"dia": "2026-10-24", "n": 2, "esperas": 1},
            ],
        )

    def test_ac4c_llama_a_fabrik_cupos_sin_shell_con_timeout(self):
        self.get()
        argv, timeout = self.llamadas[0]
        self.assertEqual(argv[1:], ["rate-limited", "--json"])
        self.assertTrue(argv[0].endswith("fabrik-cupos"))
        self.assertGreater(timeout, 0)

    def test_ac4c_json_precedido_de_avisos_en_stderr(self):
        self.salida_cupos = (True, "aviso: fallo leyendo tablero x\n" + json.dumps(self.fixture("proyectos_rate_limited")))
        self.assertEqual(len(self.get()["rate_limited"]), 3)

    def test_ac4c_si_fabrik_cupos_falla_lista_vacia_y_aviso_y_el_resto_sigue(self):
        self.salida_cupos = (False, "timeout tras 20s: fabrik-cupos")
        self.escribir_cupos([foto(AHORA - H, kimi_5h=5.0)])
        cuerpo = self.get()
        self.assertEqual(cuerpo["rate_limited"], [])
        self.assertTrue(any("rate-limited" in a for a in cuerpo["avisos"]))
        self.assertIn("kimi_5h", self.historico(cuerpo))

    def test_ac4c_salida_que_no_es_json_tambien_avisa(self):
        self.salida_cupos = (True, "nada de json")
        cuerpo = self.get()
        self.assertEqual(cuerpo["rate_limited"], [])
        self.assertTrue(any("rate-limited" in a for a in cuerpo["avisos"]))


class TestPago(CostesTest):
    def hermes(self, *partes):
        return self.tmp / "hermes" / Path(*partes)

    def test_ac4c_suma_el_coste_de_los_proveedores_de_pago_de_todos_los_state_db(self):
        crear_state_db(self.hermes("state.db"), [
            ("deepseek", AHORA - D, 1.25, None),
            ("deepseek", AHORA - 8 * D, 50.0, None),  # fuera de la ventana
            ("kimi-coding", AHORA - D, 7.0, 7.0),  # suscripción: nunca en $
            (None, AHORA - D, 3.0, None),
        ])
        crear_state_db(self.hermes("profiles", "programador", "state.db"), [
            ("deepseek", AHORA - 2 * D, None, 0.5),  # sin coste real: el estimado
            ("otro-pago", AHORA - H, 2.0, 9.0),  # el real manda sobre el estimado
        ])
        pago = {p["proveedor"]: p for p in self.get()["pago"]}
        self.assertEqual(set(pago), {"deepseek", "otro-pago"})
        self.assertEqual(pago["deepseek"]["usd"], 1.75)
        self.assertEqual(pago["deepseek"]["sesiones"], 2)
        self.assertEqual(pago["otro-pago"]["usd"], 2.0)

    def test_ac4c_proveedor_de_pago_sin_uso_aparece_con_cero_y_marca_si_esta_permitido(self):
        pago = {p["proveedor"]: p for p in self.get()["pago"]}
        self.assertEqual(pago["deepseek"], {"proveedor": "deepseek", "usd": 0.0, "sesiones": 0, "permitido": False})
        cfg = json.loads(json.dumps(POOL))
        cfg["modelos"]["permitir_pago"] = True
        with mock.patch.object(self.comun, "config", return_value=cfg):
            pago = {p["proveedor"]: p for p in self.get()["pago"]}
        self.assertTrue(pago["deepseek"]["permitido"])

    def test_ac4c_sin_proveedores_de_pago_en_la_config_pago_vacio(self):
        with mock.patch.object(self.comun, "config", return_value={}):
            self.assertEqual(self.get()["pago"], [])
        sin_pago = {"modelos": {"pool": {"medio": [{"proveedor": "k", "modelo": "m", "herramientas": True, "coste": "suscripcion"}]}}}
        with mock.patch.object(self.comun, "config", return_value=sin_pago):
            self.assertEqual(self.get()["pago"], [])

    def test_ac4c_state_db_roto_o_sin_tabla_se_salta(self):
        self.hermes("state.db").parent.mkdir(parents=True, exist_ok=True)
        self.hermes("state.db").write_bytes(b"no es sqlite")
        crear_state_db(self.hermes("profiles", "ok", "state.db"), [("deepseek", AHORA - H, 4.0, None)])
        sin_tabla = self.hermes("profiles", "vacio", "state.db")
        sin_tabla.parent.mkdir(parents=True)
        sqlite3.connect(sin_tabla).close()
        pago = {p["proveedor"]: p for p in self.get()["pago"]}
        self.assertEqual(pago["deepseek"]["usd"], 4.0)

    def test_ac4c_no_crea_ni_modifica_los_state_db(self):
        ruta = self.hermes("state.db")
        crear_state_db(ruta, [("deepseek", AHORA - H, 1.0, None)])
        antes = ruta.read_bytes()
        self.get()
        self.assertEqual(ruta.read_bytes(), antes)
        self.assertFalse(self.hermes("profiles").exists())

    def test_ac4c_hermes_home_de_un_perfil_apunta_a_la_raiz_de_hermes(self):
        crear_state_db(self.hermes("state.db"), [("deepseek", AHORA - H, 6.0, None)])
        os.environ["HERMES_HOME"] = str(self.hermes("profiles", "programador"))
        pago = {p["proveedor"]: p for p in self.get()["pago"]}
        self.assertEqual(pago["deepseek"]["usd"], 6.0)


class TestForma(CostesTest):
    def test_ac4c_forma_del_contrato(self):
        self.escribir_cupos([foto(AHORA - H, kimi_5h=5.0)])
        cuerpo = self.get()
        self.assertTrue(cuerpo["disponible"])
        self.assertTrue({"bolsas_historico", "rate_limited", "pago", "tokens", "avisos"} <= set(cuerpo))
        self.assertEqual(set(cuerpo["bolsas_historico"][0]), {"bolsa", "puntos"})


if __name__ == "__main__":
    unittest.main()
