#!/usr/bin/env python3
"""Tests de scripts/canal_avisos.py (cuotas-bolsas IMPL-3: AC-6, AC-7, AC-8 de la spec; AC-4/5/6 de la tarjeta).

Todo en directorios temporales: nunca toca ~/.hermes ni lanza `hermes`. Sin cuentas reales (D-10).
"""
import contextlib
import datetime
import io
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

REPO_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_DIR))

from scripts import canal_avisos  # noqa: E402

CLAUDE = "claude-subscription-directsdk-experimental"
AGY = "antigravity-oauth"

# ruta → (proveedor, modelo, familia, cuenta, bolsas) como RUTAS de bin/fabrik-modelos
RUTAS = {
    "opus": (CLAUDE, "claude-opus-5-5", "anthropic", "*", ["claude_5h", "claude_sem"]),
    "sonnet": (CLAUDE, "claude-sonnet-5-5", "anthropic", "*", ["claude_5h", "claude_sem"]),
    "kimi": ("kimi-coding", "kimi-for-coding", "moonshot", None, ["kimi_5h", "kimi_7d"]),
    "gemini-high": (AGY, "gemini-3.8-flash-high", "google", None, ["gemini_5h", "gemini_sem"]),
}


def yaml_default(principal, reservas):
    """config.yaml del perfil default con la sintaxis que escribe Hermes."""
    t = f"model:\n  default: {principal[1]}\n  provider: {principal[0]}\n"
    if reservas is None:
        return t
    if not reservas:
        return t + "fallback_providers: []\n"
    return t + "fallback_providers:\n" + "".join(f"  - provider: {p}\n    model: {m}\n" for p, m in reservas)


class Casa:
    """HOME temporal con .hermes/config.yaml y cron/jobs.json opcionales."""

    def __init__(self, test):
        self.dir = tempfile.TemporaryDirectory()
        test.addCleanup(self.dir.cleanup)
        self.home = self.dir.name
        os.makedirs(f"{self.home}/.hermes/cron")

    def config(self, texto):
        Path(f"{self.home}/.hermes/config.yaml").write_text(texto)

    def jobs(self, jobs):
        Path(f"{self.home}/.hermes/cron/jobs.json").write_text(json.dumps({"jobs": jobs}))


def job(**kw):
    base = {"name": "aviso-x", "enabled": True, "model": "claude-haiku-5-5", "provider": CLAUDE,
            "deliver": "local,telegram:123"}
    base.update(kw)
    return base


def fallos(res):
    return [r for r in res if r["nivel"] == "fallo"]


class TestComprobarDefault(unittest.TestCase):
    def comprobar_default(self, texto):
        c = Casa(self)
        if texto is not None:
            c.config(texto)
        res = [r for r in canal_avisos.comprobar(c.home) if r["que"] == "default"]
        self.assertEqual(len(res), 1, res)
        return res[0]

    def test_ac4a_sin_fallback_providers_falla(self):
        """AC-4a"""
        r = self.comprobar_default(yaml_default((CLAUDE, "claude-opus-5-5"), None))
        self.assertEqual(r["nivel"], "fallo")
        self.assertIn("fallback_providers", r["motivo"])

    def test_ac4a_lista_vacia_falla(self):
        """AC-4a"""
        self.assertEqual(self.comprobar_default(yaml_default((CLAUDE, "claude-opus-5-5"), []))["nivel"], "fallo")

    def test_ac4b_todas_las_reservas_en_la_misma_bolsa_falla(self):
        """AC-4b"""
        r = self.comprobar_default(yaml_default((CLAUDE, "claude-opus-5-5"),
                                                [(CLAUDE, "claude-sonnet-5-5"), (CLAUDE, "claude-haiku-5-5")]))
        self.assertEqual(r["nivel"], "fallo")
        self.assertIn("claude_5h", r["motivo"])

    def test_ac4c_reservas_en_otras_bolsas_ok(self):
        """AC-4c: antigravity y nous (proveedor sin bolsa conocida = bolsa distinta)."""
        r = self.comprobar_default(yaml_default((CLAUDE, "claude-opus-5-5"),
                                                [(AGY, "gemini-3.8-flash-high"), ("nous", "algun-modelo")]))
        self.assertEqual(r["nivel"], "ok", r)

    def test_ac4c_basta_una_reserva_fuera_de_la_bolsa(self):
        """AC-4c: «todas» comparten → falla; con una sola distinta ya vale."""
        r = self.comprobar_default(yaml_default((CLAUDE, "claude-opus-5-5"),
                                                [(CLAUDE, "claude-sonnet-5-5"), ("nous", "algun-modelo")]))
        self.assertEqual(r["nivel"], "ok", r)

    def test_ac4d_sin_config_falla(self):
        """AC-4d"""
        r = self.comprobar_default(None)
        self.assertEqual(r["nivel"], "fallo")
        self.assertIn("config.yaml", r["motivo"])

    def test_ac4d_config_ilegible_falla(self):
        """AC-4d: un config.yaml que no se puede leer no se da por bueno."""
        c = Casa(self)
        Path(f"{c.home}/.hermes/config.yaml").write_bytes(b"\xff\xfe\x00 no es utf-8")
        r = [r for r in canal_avisos.comprobar(c.home) if r["que"] == "default"][0]
        self.assertEqual(r["nivel"], "fallo")
        self.assertIn("ilegible", r["motivo"])

    def test_ac4_model_que_no_es_un_mapa_no_revienta(self):
        """AC-4: `model: texto` se trata como sin principal; las reservas siguen contando."""
        r = self.comprobar_default("model: claude-opus-5-5\nfallback_providers:\n"
                                   f"  - provider: {AGY}\n    model: gemini-3.8-flash-high\n")
        self.assertEqual(r["nivel"], "ok", r)

    def test_ac4_principal_en_model_model(self):
        """AC-4b: el modelo principal también puede venir como `model.model`."""
        r = self.comprobar_default(f"model:\n  model: claude-opus-5-5\n  provider: {CLAUDE}\n"
                                   f"fallback_providers:\n  - provider: {CLAUDE}\n    model: claude-sonnet-5-5\n")
        self.assertEqual(r["nivel"], "fallo", r)
        self.assertIn("claude-opus-5-5", r["motivo"])

    def test_ac4a_reservas_incompletas_no_cuentan(self):
        """AC-4a: una reserva sin `provider` (o sin `model`) se ignora; si no queda ninguna, falla."""
        cab = f"model:\n  default: claude-opus-5-5\n  provider: {CLAUDE}\nfallback_providers:\n"
        for texto in (cab + "  - model: x\n", cab + "  - provider: nous\n"):
            r = self.comprobar_default(texto)
            self.assertEqual(r["nivel"], "fallo", r)
            self.assertIn("fallback_providers", r["motivo"])

    def test_ac4b_reserva_incompleta_junto_a_una_valida_solo_cuenta_la_valida(self):
        """AC-4b: la incompleta no cuenta como «otra bolsa»: con la válida en la misma bolsa, falla."""
        r = self.comprobar_default(f"model:\n  default: claude-opus-5-5\n  provider: {CLAUDE}\nfallback_providers:\n"
                                   f"  - model: x\n  - provider: {CLAUDE}\n    model: claude-sonnet-5-5\n")
        self.assertEqual(r["nivel"], "fallo", r)
        self.assertIn("las 1 reservas", r["motivo"])

    def test_ac4a_fallback_providers_que_no_es_lista_falla(self):
        """AC-4a"""
        r = self.comprobar_default(f"model:\n  default: claude-opus-5-5\n  provider: {CLAUDE}\n"
                                   "fallback_providers: nous\n")
        self.assertEqual(r["nivel"], "fallo", r)
        self.assertIn("fallback_providers", r["motivo"])

    def test_ac4_resultado_con_forma_de_contrato(self):
        """AC-4: cada resultado tiene nivel ∈ {ok,fallo}, que y motivo textos."""
        c = Casa(self)
        for r in canal_avisos.comprobar(c.home):
            self.assertEqual(sorted(r), ["motivo", "nivel", "que"])
            self.assertIn(r["nivel"], ("ok", "fallo"))
            self.assertTrue(r["que"] and r["motivo"])


class TestComprobarCron(unittest.TestCase):
    def cron(self, jobs):
        c = Casa(self)
        if jobs is not None:
            c.jobs(jobs)
        return [r for r in canal_avisos.comprobar(c.home) if r["que"].startswith("cron")]

    def test_ac5a_job_fijado_en_claude_con_destino_externo_es_riesgo(self):
        """AC-5a"""
        res = self.cron([job(name="avisador")])
        self.assertEqual(len(fallos(res)), 1, res)
        m = fallos(res)[0]
        self.assertIn("avisador", m["que"] + m["motivo"])
        self.assertIn("claude-haiku-5-5", m["motivo"])
        self.assertIn("los jobs fijados no recorren reservas", m["motivo"])

    def test_ac5b_fijado_en_antigravity_ok(self):
        """AC-5b"""
        self.assertEqual(fallos(self.cron([job(model="gemini-3.8-flash-high", provider=AGY)])), [])

    def test_ac5b_sin_model_ok(self):
        """AC-5b"""
        self.assertEqual(fallos(self.cron([job(model=None, provider=None)])), [])

    def test_ac5b_model_vacio_ok(self):
        """AC-5b"""
        self.assertEqual(fallos(self.cron([job(model="")])), [])

    def test_ac5b_deliver_local_ok(self):
        """AC-5b"""
        self.assertEqual(fallos(self.cron([job(deliver="local")])), [])
        self.assertEqual(fallos(self.cron([job(deliver="origin,local")])), [])

    def test_ac5b_desactivado_ok(self):
        """AC-5b"""
        self.assertEqual(fallos(self.cron([job(enabled=False)])), [])

    def test_ac5b_deliver_vacio_o_nulo_ok(self):
        """AC-5b: sin destino externo no hay a quién avisar fuera."""
        for d in ("", None):
            self.assertEqual(fallos(self.cron([job(deliver=d)])), [], d)

    def test_ac5_plataforma_es_lo_que_va_antes_de_los_dos_puntos(self):
        """AC-5: `local:abc` sigue siendo local; los espacios no cuentan; basta un destino externo."""
        for d in ("local:abc", " local", "local , origin:x", ["local", "origin"], ["local"]):
            self.assertEqual(fallos(self.cron([job(deliver=d)])), [], d)
        for d in ("telegram:1, local", "local, telegram:1", ["local", "telegram:1"], "telegram", " telegram:9"):
            self.assertEqual(len(fallos(self.cron([job(deliver=d)]))), 1, d)

    def test_ac5_jobs_que_no_es_lista_no_es_riesgo(self):
        """AC-5"""
        c = Casa(self)
        Path(f"{c.home}/.hermes/cron/jobs.json").write_text(json.dumps({"jobs": {}}))
        res = [r for r in canal_avisos.comprobar(c.home) if r["que"].startswith("cron")]
        self.assertEqual((fallos(res), len(res)), ([], 1))

    def test_ac5_solo_el_job_en_riesgo_falla(self):
        """AC-5: varios jobs, cada uno su resultado."""
        res = self.cron([job(name="bueno", model=None, provider=None), job(name="malo"),
                         job(name="otro", model="gemini-3.8-flash-high", provider=AGY)])
        self.assertEqual([r["que"] for r in fallos(res)], ["cron «malo»"])

    def test_ac5b_sin_jobs_json_todo_ok(self):
        """AC-5b: sin jobs.json no hay fallos (y hay al menos un resultado ok de cron)."""
        res = self.cron(None)
        self.assertEqual(fallos(res), [])
        self.assertTrue(res)

    def test_ac5_jobs_json_ilegible_es_fallo(self):
        """AC-5: un jobs.json roto no se da por bueno."""
        c = Casa(self)
        Path(f"{c.home}/.hermes/cron/jobs.json").write_text("{no es json")
        res = [r for r in canal_avisos.comprobar(c.home) if r["que"].startswith("cron")]
        self.assertEqual(len(fallos(res)), 1)


# ---------------- aviso de bolsa ----------------
def iso(horas):
    t = time.gmtime(time.time() + horas * 3600)
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", t)


class Enviador:
    def __init__(self, ok=True):
        self.mensajes, self.ok = [], ok

    def __call__(self, msg):
        self.mensajes.append(msg)
        return self.ok


class TestAvisarBolsas(unittest.TestCase):
    def setUp(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        self.estado = os.path.join(d.name, "logs", "modelos-avisos.json")
        self.cambios = {"programador": {"antes": "sonnet", "despues": "kimi"},
                        "tester": {"antes": "opus", "despues": None},
                        "docs": {"antes": "gemini-high", "despues": "gemini-high"}}

    def avisar(self, bolsas, enviar, umbral=90, cambios=None):
        return canal_avisos.avisar_bolsas(bolsas, umbral, self.cambios if cambios is None else cambios,
                                          RUTAS, self.estado, enviar)

    def test_ac6a_mensaje_con_bolsa_resto_y_ruta(self):
        """AC-6a"""
        env = Enviador()
        self.avisar({"claude_sem@a": [92, iso(30)], "claude_5h@a": [10, iso(2)]}, env)
        self.assertEqual(len(env.mensajes), 1)
        m = env.mensajes[0]
        self.assertIn("claude_sem@a", m)
        self.assertIn("92 %", m)
        self.assertIn("queda 8 %", m)
        self.assertIn("programador sonnet → kimi", m)
        self.assertIn("Sin ruta apta: tester (aparcado)", m)
        self.assertNotIn("docs", m)   # su ruta de antes no consumía la bolsa

    def test_ac6c_justo_en_el_umbral_avisa(self):
        """AC-6c: pct ≥ umbral, no solo >."""
        env = Enviador()
        self.avisar({"claude_sem@a": [90, iso(30)]}, env, umbral=90)
        self.assertEqual(len(env.mensajes), 1)

    def test_ac6a_rol_que_no_cambia_de_ruta_se_anota(self):
        """AC-6a: «Sin conmutar»: la ruta de antes y la de después son la misma."""
        env = Enviador()
        self.avisar({"claude_sem@a": [92, iso(30)]}, env,
                    cambios={"docs": {"antes": "opus", "despues": "opus"}})
        self.assertIn("Sin conmutar: docs (sigue en opus).", env.mensajes[0])
        self.assertNotIn("Conmutado", env.mensajes[0])
        self.assertNotIn("Ningún rol", env.mensajes[0])

    def test_ac6a_antes_que_no_casa_con_ninguna_ruta_no_cuenta(self):
        """AC-6a: `antes` es un modelo suelto (no está en RUTAS): ni revienta ni se nombra."""
        env = Enviador()
        self.avisar({"claude_sem@a": [92, iso(30)]}, env,
                    cambios={"raro": {"antes": "modelo-suelto", "despues": "kimi"},
                             "programador": {"antes": "sonnet", "despues": "kimi"}})
        self.assertIn("Conmutado: programador sonnet → kimi.", env.mensajes[0])
        self.assertNotIn("raro", env.mensajes[0])
        env2 = Enviador()
        self.avisar({"kimi_5h": [95, iso(30)]}, env2, cambios={"raro": {"antes": "modelo-suelto", "despues": None}})
        self.assertIn("Ningún rol la usaba ahora", env2.mensajes[0])

    def test_ac6_dato_de_bolsa_mal_formado_se_salta(self):
        """AC-6: una bolsa con dato roto no impide avisar de las demás."""
        env = Enviador()
        self.avisar({"a_none": None, "b_vacio": [], "c_texto": ["abc", iso(30)], "d_dict": {},
                     "claude_sem@a": [92, iso(30)]}, env)
        self.assertEqual(len(env.mensajes), 1)
        self.assertIn("claude_sem@a", env.mensajes[0])

    def test_ac6b_envio_ok_pero_estado_no_se_guarda_no_revienta(self):
        """AC-6b: si el estado no se puede escribir, el aviso ya salió; se anota en stderr y no se propaga."""
        env = Enviador()
        err = io.StringIO()
        with mock.patch.object(canal_avisos, "_guardar_estado", side_effect=OSError("disco lleno")), \
                contextlib.redirect_stderr(err):
            enviadas = self.avisar({"claude_sem@a": [92, iso(30)]}, env)
        self.assertEqual((len(env.mensajes), len(enviadas)), (1, 1))
        self.assertIn("no se pudo guardar", err.getvalue())
        self.assertIn("disco lleno", err.getvalue())

    def test_ac6d_fallo_de_escritura_atomica_no_deja_temporales(self):
        """AC-6d: si el rename falla, el temporal se borra y el estado anterior queda intacto."""
        carpeta = os.path.dirname(self.estado)
        os.makedirs(carpeta)
        Path(self.estado).write_text('{"previo": "x"}')
        with mock.patch.object(canal_avisos.os, "replace", side_effect=OSError("rename")):
            with self.assertRaises(OSError):
                canal_avisos._guardar_estado(self.estado, {"nuevo": "y"})
        self.assertEqual(os.listdir(carpeta), ["modelos-avisos.json"])
        self.assertEqual(json.loads(Path(self.estado).read_text()), {"previo": "x"})

    def test_ac6b_estado_que_no_es_un_mapa_se_trata_como_vacio(self):
        """AC-6b: `[]`, `"x"`, `7` o `null` en el estado no impiden avisar (ni revientan al marcar)."""
        os.makedirs(os.path.dirname(self.estado))
        for basura in ("[]", '"x"', "7", "null"):
            Path(self.estado).write_text(basura)
            env = Enviador()
            self.avisar({"claude_sem@a": [92, iso(30)]}, env)
            self.assertEqual(len(env.mensajes), 1, basura)

    def test_ac6a_no_avisa_bajo_el_umbral(self):
        """AC-6a"""
        env = Enviador()
        self.avisar({"claude_sem@a": [89, iso(30)]}, env)
        self.assertEqual(env.mensajes, [])

    def test_ac6a_ningun_rol_la_usaba(self):
        """AC-6a"""
        env = Enviador()
        self.avisar({"argon_sem": [99, iso(5)]}, env)
        self.assertIn("Ningún rol la usaba ahora", env.mensajes[0])

    def test_ac6a_bolsa_sin_reset_futuro_no_avisa(self):
        """AC-6a: reset pasado o ilegible = ya renovada, no hay nada que avisar."""
        env = Enviador()
        self.avisar({"claude_sem@a": [99, iso(-1)], "kimi_5h": [99, "no-es-fecha"]}, env)
        self.assertEqual(env.mensajes, [])

    def test_ac6a_fecha_del_reset_en_hora_local(self):
        """AC-6a"""
        with mock.patch.dict(os.environ, {"TZ": "Europe/Madrid"}):
            time.tzset()
            try:
                self.assertEqual(canal_avisos.fecha_local("2026-10-27T09:59:00Z"), "27/10 10:59")
                env = Enviador()
                self.avisar({"kimi_5h": [95, "2999-12-27T09:59:00Z"]}, env, cambios={})
            finally:
                os.environ.pop("TZ", None)
                time.tzset()
        self.assertIn("se renueva 27/12 10:59", env.mensajes[0])   # diciembre: CET (UTC+1)

    def test_ac6b_mismo_reset_no_reenvia_reset_nuevo_si(self):
        """AC-6b"""
        env = Enviador()
        b = {"claude_sem@a": [92, "2999-01-01T10:59:00Z"]}
        self.avisar(b, env)
        self.avisar(b, env)
        self.assertEqual(len(env.mensajes), 1)
        self.avisar({"claude_sem@a": [92, "2999-01-08T10:59:00Z"]}, env)
        self.assertEqual(len(env.mensajes), 2)

    def test_ac6b_cada_bolsa_su_aviso(self):
        """AC-6b"""
        env = Enviador()
        self.avisar({"claude_sem@a": [92, iso(30)], "claude_sem@b": [95, iso(30)]}, env)
        self.assertEqual(len(env.mensajes), 2)

    def test_ac6d_envio_fallido_no_marca_y_reintenta(self):
        """AC-6d"""
        b = {"claude_sem@a": [92, iso(30)]}
        malo, bueno = Enviador(ok=False), Enviador()
        self.avisar(b, malo)
        self.avisar(b, bueno)
        self.assertEqual((len(malo.mensajes), len(bueno.mensajes)), (1, 1))

    def test_ac6d_excepcion_en_el_envio_no_marca_y_no_propaga(self):
        """AC-6d"""
        def revienta(msg):
            raise OSError("sin hermes")
        b = {"claude_sem@a": [92, iso(30)]}
        self.avisar(b, revienta)
        bueno = Enviador()
        self.avisar(b, bueno)
        self.assertEqual(len(bueno.mensajes), 1)

    def test_ac6d_estado_atomico_sin_temporales(self):
        """AC-6b/d: el estado queda como JSON y no sobran temporales."""
        self.avisar({"claude_sem@a": [92, "2999-01-01T10:59:00Z"]}, Enviador())
        estado = json.loads(Path(self.estado).read_text())
        self.assertIn("claude_sem@a|2999-01-01T10", estado)
        self.assertEqual(os.listdir(os.path.dirname(self.estado)), ["modelos-avisos.json"])

    def test_ac6_estado_corrupto_se_trata_como_vacio(self):
        """AC-6b"""
        os.makedirs(os.path.dirname(self.estado))
        Path(self.estado).write_text("{roto")
        env = Enviador()
        self.avisar({"claude_sem@a": [92, iso(30)]}, env)
        self.assertEqual(len(env.mensajes), 1)


class TestEnviarHermes(unittest.TestCase):
    def llamar(self, entorno=None, rc=0, error=None):
        with mock.patch.object(canal_avisos.subprocess, "run") as run, \
                mock.patch.dict(os.environ, entorno or {}, clear=False):
            if "FABRIK_AVISO" not in (entorno or {}):
                os.environ.pop("FABRIK_AVISO", None)
            run.return_value = mock.Mock(returncode=rc)
            if error:
                run.side_effect = error
            res = canal_avisos.enviar_hermes("hola")
        return res, run

    def test_ac6e_solo_hermes_send_sin_modelo(self):
        """AC-6e: el argv es exactamente `hermes send -t telegram <msg>`; nunca chat, -z ni modelo."""
        res, run = self.llamar()
        self.assertTrue(res)
        self.assertEqual(run.call_args.args[0], ["hermes", "send", "-t", "telegram", "hola"])
        self.assertEqual(run.call_args.kwargs["timeout"], 60)
        for malo in ("chat", "-z", "-m", "--model", "--provider"):
            self.assertNotIn(malo, run.call_args.args[0])

    def test_ac6e_destino_por_fabrik_aviso(self):
        """AC-6e"""
        _, run = self.llamar({"FABRIK_AVISO": "slack"})
        self.assertEqual(run.call_args.args[0][:4], ["hermes", "send", "-t", "slack"])

    def test_ac6d_rc_distinto_de_cero_es_fallo(self):
        """AC-6d"""
        self.assertFalse(self.llamar(rc=1)[0])

    def test_ac6d_excepcion_es_fallo(self):
        """AC-6d"""
        self.assertFalse(self.llamar(error=FileNotFoundError("hermes"))[0])

    def test_ac6e_el_modulo_no_importa_clientes_de_modelo(self):
        """AC-6e: el avisador no depende de ninguna bolsa de modelo (sin LLM)."""
        import ast
        arbol = ast.parse((REPO_DIR / "scripts" / "canal_avisos.py").read_text())
        importados = set()
        for n in ast.walk(arbol):
            if isinstance(n, ast.Import):
                importados |= {a.name.split(".")[0] for a in n.names}
            elif isinstance(n, ast.ImportFrom) and n.module:
                importados.add(n.module.split(".")[0])
        permitidos = {"__future__", "json", "os", "subprocess", "sys", "tempfile", "time", "datetime", "cupos",
                      "pathlib", "typing"}
        self.assertLessEqual(importados, permitidos)
        cadenas = {n.value for n in ast.walk(arbol) if isinstance(n, ast.Constant) and isinstance(n.value, str)}
        self.assertTrue({"chat", "-z"}.isdisjoint(cadenas))


class TestAvisarComprobacion(unittest.TestCase):
    def setUp(self):
        self.c = Casa(self)
        self.estado = os.path.join(self.c.home, "logs", "modelos-avisos.json")

    def test_ac6f_un_aviso_al_dia_con_la_lista(self):
        """AC-6f"""
        env = Enviador()
        canal_avisos.avisar_comprobacion(self.c.home, self.estado, env, hoy="2026-10-25")
        canal_avisos.avisar_comprobacion(self.c.home, self.estado, env, hoy="2026-10-25")
        self.assertEqual(len(env.mensajes), 1)
        self.assertIn("default", env.mensajes[0])
        canal_avisos.avisar_comprobacion(self.c.home, self.estado, env, hoy="2026-10-26")
        self.assertEqual(len(env.mensajes), 2)
        self.assertIn("comprobar|2026-10-25", json.loads(Path(self.estado).read_text()))

    def test_ac6f_clave_diaria_sale_de_la_fecha_de_hoy(self):
        """AC-6f: sin `hoy=` ni FABRIK_HOY la clave es `comprobar|<hoy>` y otro día vuelve a avisar"""
        class Dia:
            actual = "2026-10-25"

            @classmethod
            def today(cls):
                return datetime.date.fromisoformat(cls.actual)

        env = Enviador()
        with mock.patch.dict(os.environ), mock.patch.object(canal_avisos, "date", Dia):
            os.environ.pop("FABRIK_HOY", None)
            canal_avisos.avisar_comprobacion(self.c.home, self.estado, env)
            canal_avisos.avisar_comprobacion(self.c.home, self.estado, env)
            self.assertEqual(len(env.mensajes), 1)
            self.assertIn("comprobar|2026-10-25", json.loads(Path(self.estado).read_text()))
            Dia.actual = "2026-10-26"
            canal_avisos.avisar_comprobacion(self.c.home, self.estado, env)
            self.assertEqual(len(env.mensajes), 2)
            self.assertIn("comprobar|2026-10-26", json.loads(Path(self.estado).read_text()))

    def test_ac6f_sin_fallos_no_avisa(self):
        """AC-6f"""
        self.c.config(yaml_default((CLAUDE, "claude-opus-5-5"), [(AGY, "gemini-3.8-flash-high")]))
        env = Enviador()
        canal_avisos.avisar_comprobacion(self.c.home, self.estado, env, hoy="2026-10-25")
        self.assertEqual(env.mensajes, [])

    def test_ac6f_envio_fallido_se_reintenta(self):
        """AC-6f + AC-6d"""
        canal_avisos.avisar_comprobacion(self.c.home, self.estado, Enviador(ok=False), hoy="2026-10-25")
        env = Enviador()
        canal_avisos.avisar_comprobacion(self.c.home, self.estado, env, hoy="2026-10-25")
        self.assertEqual(len(env.mensajes), 1)


if __name__ == "__main__":
    unittest.main()
