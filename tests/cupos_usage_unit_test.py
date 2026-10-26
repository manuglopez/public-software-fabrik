#!/usr/bin/env python3
"""Tests de la medición por cuenta de bin/fabrik-cupos (`claude -p "/usage"`): AC-1a..e, AC-2, AC-3, AC-9.

Todo con `subprocess.run` simulado y la hora congelada: sin red, sin claude real, sin dormir.
Uso: tests/cupos_usage_unit_test.py [ruta-al-fabrik-cupos]  (por defecto, bin/fabrik-cupos del repo).
"""
import builtins
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

sys.dont_write_bytecode = True  # cargar bin/ no debe dejar bin/__pycache__
REPO_DIR = Path(__file__).resolve().parent.parent
RUTA = sys.argv.pop(1) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else str(REPO_DIR / "bin/fabrik-cupos")
MADRID = ZoneInfo("Europe/Madrid")
HOY = datetime(2026, 10, 24, 23, 0, tzinfo=MADRID)  # fecha congelada


def cargar():
    loader = importlib.machinery.SourceFileLoader("fabrik_cupos_ut", RUTA)
    spec = importlib.util.spec_from_loader("fabrik_cupos_ut", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def salida(sesion, semana, fable=None, cab="You are currently using your subscription to power your Claude Code usage\n\n"):
    """Texto de `claude -p /usage`; cada argumento es 'NN% used · resets ...' o None si falta la línea."""
    lineas = [f"Current session: {sesion}", f"Current week (all models): {semana}"]
    if fable:
        lineas.append(f"Current week (Fable): {fable}")
    return cab + "\n".join(lineas) + "\n"


# Una cuenta al 17 % semanal (corte el 27) y otra al 97 % (corte el 25): las cifras de la medición real del 24/10.
USO_A = salida("8% used · resets Oct 25, 3:19am (Europe/Madrid)",
               "17% used · resets Oct 27, 10:59am (Europe/Madrid)",
               "0% used · resets Oct 27, 11am (Europe/Madrid)")
USO_B = salida("9% used · resets Oct 25, 12:59am (Europe/Madrid)",
               "97% used · resets Oct 25, 5:59pm (Europe/Madrid)",
               "0% used · resets Oct 25, 5:59pm (Europe/Madrid)")
SIN_CIFRAS = ("Total cost:            $0.0000\nTotal duration (API):  0s\n"
              "Usage:                 0 input, 0 output, 0 cache read, 0 cache write\n")


class Base(unittest.TestCase):
    def setUp(self):
        self.m = cargar()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.llamadas = []

    def dir(self, nombre):
        d = os.path.join(self.tmp.name, f"claude-{nombre}")
        os.makedirs(d)
        return d

    def medir(self, dirs, texto_por_cuenta, rc=0):  # rc: int o {dir: int}
        """Ejecuta anthropic() con `claude` simulado: la salida depende del CLAUDE_CONFIG_DIR de la llamada."""
        por_dir = {dirs[n]: t for n, t in texto_por_cuenta.items() if n in dirs}

        def falso_run(argv, **kw):
            self.llamadas.append((list(argv), kw))
            d = kw["env"]["CLAUDE_CONFIG_DIR"]
            if not os.path.isdir(d):  # el CLI real con un directorio inexistente: rc 0 y resumen sin cifras
                return subprocess.CompletedProcess(argv, 0, SIN_CIFRAS, "")
            r = rc.get(d, 0) if isinstance(rc, dict) else rc
            return subprocess.CompletedProcess(argv, r, por_dir.get(d, ""), "")

        errs = {}
        with mock.patch.object(self.m, "H", self.tmp.name), \
             mock.patch.object(self.m, "cuentas_claude", return_value=dirs), \
             mock.patch.object(self.m, "ahora", return_value=HOY, create=True), \
             mock.patch.object(self.m.subprocess, "run", side_effect=falso_run):
            return self.m.anthropic(errs), errs


class TestParsear(Base):
    def test_AC_1a_tres_bolsas_con_pct_y_reset_iso_con_zona(self):
        r = self.m.parsear_usage(USO_A, hoy=HOY)
        self.assertEqual(set(r), {"claude_5h", "claude_sem", "fable_sem"})
        self.assertEqual(r["claude_5h"], (8.0, "2026-10-25T03:19:00+01:00"))  # 03:00 del 25/10 el reloj retrocede: ya es +01:00
        self.assertEqual(r["claude_sem"], (17.0, "2026-10-27T10:59:00+01:00"))
        self.assertEqual(r["fable_sem"], (0.0, "2026-10-27T11:00:00+01:00"))
        for _, reset in r.values():
            self.assertIsNotNone(datetime.fromisoformat(reset).tzinfo)

    def test_AC_1d_sin_linea_de_fable_se_escriben_las_otras_dos(self):
        txt = salida("8% used · resets Oct 25, 3:19am (Europe/Madrid)", "17% used · resets Oct 27, 10:59am (Europe/Madrid)")
        self.assertEqual(set(self.m.parsear_usage(txt, hoy=HOY)), {"claude_5h", "claude_sem"})

    def test_AC_1d_salida_vacia_o_irreconocible_no_da_claves(self):
        for txt in ("", "   \n", SIN_CIFRAS, "Type /usage to see your usage\n"):
            self.assertEqual(self.m.parsear_usage(txt, hoy=HOY), {}, repr(txt))

    def test_AC_1e_reset_sin_anio_es_la_proxima_aparicion(self):
        r = self.m.parsear_usage(salida("8% used · resets Oct 25, 3:19am (Europe/Madrid)",
                                        "1% used · resets Oct 20, 11pm (Europe/Madrid)"), hoy=HOY)
        self.assertEqual(r["claude_5h"][1][:16], "2026-10-25T03:19")  # futuro: este año
        self.assertEqual(r["claude_sem"][1][:16], "2027-10-20T23:00")  # ya pasó: el año siguiente
        self.assertEqual(r["claude_sem"][1][-6:], "+02:00")  # 20/10/2027 sigue en horario de verano

    def test_AC_1e_12am_y_12pm(self):
        r = self.m.parsear_usage(salida("1% used · resets Oct 25, 12am (Europe/Madrid)",
                                        "1% used · resets Oct 25, 12:30pm (Europe/Madrid)"), hoy=HOY)
        self.assertEqual(r["claude_5h"][1][:16], "2026-10-25T00:00")
        self.assertEqual(r["claude_sem"][1][:16], "2026-10-25T12:30")


    def un(self, linea, hoy=HOY):
        return self.m.parsear_usage(f"Current session: {linea}\n", hoy=hoy).get("claude_5h")

    def test_AC_1e_reset_igual_a_ahora_cuenta_como_esta_aparicion(self):
        ahora = datetime(2026, 10, 25, 3, 19, tzinfo=MADRID)
        self.assertEqual(self.un("8% used · resets Oct 25, 3:19am (Europe/Madrid)", ahora), (8.0, "2026-10-25T03:19:00+01:00"))
        un_min_despues = datetime(2026, 10, 25, 3, 20, tzinfo=MADRID)
        self.assertEqual(self.un("8% used · resets Oct 25, 3:19am (Europe/Madrid)", un_min_despues)[1][:4], "2027")

    def test_AC_1e_ahora_en_otra_zona_que_la_del_texto(self):
        # 31/12 23:30 en Madrid ya es 01/01 en Auckland, pero el texto habla de Madrid: sigue siendo este año
        ahora = datetime(2026, 12, 31, 23, 30, tzinfo=MADRID).astimezone(ZoneInfo("Pacific/Auckland"))
        self.assertEqual(ahora.year, 2027)
        self.assertEqual(self.un("1% used · resets Dec 31, 11:45pm (Europe/Madrid)", ahora), (1.0, "2026-12-31T23:45:00+01:00"))
        # y a la inversa: aquí en Auckland ya es 1 ene 2027 y «Jan 1, 1am» de Madrid aún no ha pasado en 2027
        self.assertEqual(self.un("1% used · resets Jan 1, 1am (Europe/Madrid)", ahora)[1][:10], "2027-01-01")

    def test_AC_1e_zona_desconocida_o_ausente_usa_la_de_ahora(self):
        for txt in ("5% used · resets Oct 24, 11:30pm (Mars/Olympus)", "5% used · resets Oct 24, 11:30pm"):
            self.assertEqual(self.un(txt), (5.0, "2026-10-24T23:30:00+02:00"), txt)  # tz de HOY (23:00 del 24, Madrid)

    def test_AC_1e_29_de_febrero_busca_el_siguiente_bisiesto(self):
        r = self.un("5% used · resets Feb 29, 9am (Europe/Madrid)")
        self.assertEqual(r, (5.0, "2028-02-29T09:00:00+01:00"))

    def test_AC_1d_reset_ilegible_da_porcentaje_con_reset_vacio(self):
        self.assertEqual(self.un("5% used"), (5.0, ""))
        self.assertEqual(self.un("5% used · resets Foo 25, 3am (Europe/Madrid)"), (5.0, ""))
        self.assertEqual(self.un("5% used · resets Feb 30, 3am (Europe/Madrid)"), (5.0, ""))  # nunca existe

    def test_porcentaje_decimal_y_mayusculas(self):
        self.assertEqual(self.un("12.5% used · resets Oct 25, 3am (Europe/Madrid)")[0], 12.5)
        r = self.m.parsear_usage("CURRENT WEEK (ALL MODELS): 7% USED · RESETS OCT 27, 10AM (EUROPE/MADRID)", hoy=HOY)
        self.assertEqual(r, {"claude_sem": (7.0, "2026-10-27T10:00:00+01:00")})

    def test_linea_con_texto_delante_se_reconoce(self):
        self.assertEqual(self.m.parsear_usage("  > Current session: 3% used", hoy=HOY), {"claude_5h": (3.0, "")})

    def test_sin_hoy_usa_ahora_del_modulo(self):
        with mock.patch.object(self.m, "ahora", return_value=HOY) as a:
            r = self.m.parsear_usage("Current session: 8% used · resets Oct 25, 3:19am (Europe/Madrid)")
        a.assert_called_once()
        self.assertEqual(r["claude_5h"][1], "2026-10-25T03:19:00+01:00")

    def test_ahora_devuelve_hora_local_con_zona(self):
        self.assertIsNotNone(self.m.ahora().utcoffset())


class TestMedicion(Base):
    def test_AC_1b_dos_cuentas_distintas_cuatro_claves_sin_mezclar(self):
        dirs = {"a": self.dir("a"), "b": self.dir("b")}
        res, errs = self.medir(dirs, {"a": USO_A, "b": USO_B})
        self.assertEqual(res["claude_sem@a"], (17.0, "2026-10-27T10:59:00+01:00"))
        self.assertEqual(res["claude_sem@b"], (97.0, "2026-10-25T17:59:00+01:00"))
        self.assertEqual(res["claude_5h@a"][0], 8.0)
        self.assertEqual(res["claude_5h@b"][0], 9.0)
        self.assertEqual(len({res["claude_sem@a"], res["claude_sem@b"], res["claude_5h@a"], res["claude_5h@b"]}), 4)
        self.assertEqual(errs, {})

    def test_AC_1c_argv_exacto_y_config_dir_de_cada_cuenta(self):
        dirs = {"a": self.dir("a"), "b": self.dir("b")}
        self.medir(dirs, {"a": USO_A, "b": USO_B})
        self.assertEqual(len(self.llamadas), 2)
        self.assertEqual([c[0] for c in self.llamadas], [["claude", "-p", "/usage"]] * 2)
        self.assertEqual([c[1]["env"]["CLAUDE_CONFIG_DIR"] for c in self.llamadas], [dirs["a"], dirs["b"]])
        self.assertTrue(all(c[1]["timeout"] == 120 for c in self.llamadas))
        for argv, _ in self.llamadas:  # `claude usage` sin -p no es subcomando: abriría sesión y gastaría tokens
            self.assertNotEqual(argv[:2], ["claude", "usage"])
            self.assertIn("-p", argv)

    def test_AC_1d_cuenta_vacia_da_error_y_las_demas_se_miden(self):
        dirs = {"a": self.dir("a"), "b": self.dir("b")}
        res, errs = self.medir(dirs, {"a": "", "b": USO_B})
        self.assertIn("a", errs["anthropic"])
        self.assertNotIn("b", errs["anthropic"])
        self.assertFalse([k for k in res if k.endswith("@a")])
        self.assertEqual(res["claude_sem@b"][0], 97.0)

    def test_AC_1d_exit_distinto_de_cero_es_error_de_esa_cuenta(self):
        dirs = {"a": self.dir("a"), "b": self.dir("b")}
        res, errs = self.medir(dirs, {"a": USO_A, "b": USO_B}, rc={dirs["a"]: 1})
        self.assertIn("a", errs["anthropic"])
        self.assertFalse([k for k in res if k.endswith("@a")])
        self.assertIn("claude_5h@b", res)

    def test_AC_1d_timeout_es_error_de_esa_cuenta(self):
        dirs = {"a": self.dir("a"), "b": self.dir("b")}

        def run(argv, **kw):
            if kw["env"]["CLAUDE_CONFIG_DIR"] == dirs["a"]:
                raise subprocess.TimeoutExpired(argv, 120)
            return subprocess.CompletedProcess(argv, 0, USO_B, "")
        errs = {}
        with mock.patch.object(self.m, "cuentas_claude", return_value=dirs), \
             mock.patch.object(self.m, "ahora", return_value=HOY, create=True), \
             mock.patch.object(self.m.subprocess, "run", side_effect=run):
            res = self.m.anthropic(errs)
        self.assertIn("a", errs["anthropic"])
        self.assertIn("claude_sem@b", res)

    def test_AC_1d_claude_no_instalado_es_error_de_esa_cuenta_con_mensaje(self):
        dirs = {"a": self.dir("a"), "b": self.dir("b")}
        errs = {}
        with mock.patch.object(self.m, "cuentas_claude", return_value=dirs), \
             mock.patch.object(self.m, "ahora", return_value=HOY), \
             mock.patch.object(self.m.subprocess, "run", side_effect=FileNotFoundError("claude")):
            res = self.m.anthropic(errs)
        self.assertEqual(res, {})
        self.assertEqual(errs["anthropic"], {"a": "FileNotFoundError: claude", "b": "FileNotFoundError: claude"})

    def test_AC_1d_mensajes_de_error_distinguen_exit_y_salida_vacia(self):
        dirs = {"a": self.dir("a"), "b": self.dir("b")}
        _, errs = self.medir(dirs, {"a": USO_A, "b": ""}, rc={dirs["a"]: 3})
        self.assertEqual(errs["anthropic"], {"a": "exit 3", "b": "salida sin cifras de uso"})

    def test_AC_1d_sin_cuentas_no_hay_errores_ni_claves(self):
        res, errs = self.medir({}, {})
        self.assertEqual((res, errs, self.llamadas), ({}, {}, []))

    def test_anthropic_sin_argumento_no_falla(self):
        with mock.patch.object(self.m, "cuentas_claude", return_value={}):
            self.assertEqual(self.m.anthropic(), {})

    def test_AC_2_directorio_inexistente_acaba_en_error_nunca_en_cifras(self):
        """Prueba de control: un lector ciego a CLAUDE_CONFIG_DIR devolvería cifras aquí y este test fallaría."""
        fantasma = os.path.join(self.tmp.name, "no-existe", "claude-z")
        res, errs = self.medir({"z": fantasma}, {"z": USO_A})
        self.assertEqual(self.llamadas[0][1]["env"]["CLAUDE_CONFIG_DIR"], fantasma)
        self.assertIn("z", errs.get("anthropic", {}))
        self.assertEqual(res, {})

    def test_AC_9_la_identidad_no_se_lee_de_claude_json(self):
        d = self.dir("a")
        Path(d, ".claude.json").write_text('{"oauthAccount": {"emailAddress": "a"}}')
        abiertos = []
        real_open = builtins.open

        def espia(f, *a, **k):
            abiertos.append(str(f))
            return real_open(f, *a, **k)
        with mock.patch.object(builtins, "open", espia):
            self.medir({"a": d}, {"a": USO_A})
        self.assertEqual([p for p in abiertos if p.endswith(".claude.json")], [])


class TestSospecha(Base):
    def test_AC_3_cifras_identicas_en_5h_y_semanal_avisa_y_escribe_por_cuenta(self):
        dirs = {"a": self.dir("a"), "b": self.dir("b"), "c": self.dir("c")}
        res, errs = self.medir(dirs, {"a": USO_A, "b": USO_A, "c": USO_B})
        sosp = errs["anthropic_sospecha"]
        self.assertEqual(sosp, "posible lectura ciega: a y b devuelven cifras idénticas")  # nombra a y b, no c
        for cuenta in "abc":  # no se agrupa: una entrada por cuenta
            self.assertIn(f"claude_5h@{cuenta}", res)
            self.assertIn(f"claude_sem@{cuenta}", res)
        self.assertEqual(res["claude_sem@a"], res["claude_sem@b"])
        self.assertFalse([k for k in res if "+" in k])

    def test_AC_3_cifras_distintas_no_hay_sospecha(self):
        dirs = {"a": self.dir("a"), "b": self.dir("b")}
        _, errs = self.medir(dirs, {"a": USO_A, "b": USO_B})
        self.assertNotIn("anthropic_sospecha", errs)

    def test_AC_3_misma_semana_pero_distinta_sesion_no_es_sospecha(self):
        mismo_sem = "17% used · resets Oct 27, 10:59am (Europe/Madrid)"
        dirs = {"a": self.dir("a"), "b": self.dir("b")}
        _, errs = self.medir(dirs, {"a": salida("8% used · resets Oct 25, 3:19am (Europe/Madrid)", mismo_sem),
                                    "b": salida("9% used · resets Oct 25, 3:19am (Europe/Madrid)", mismo_sem)})
        self.assertNotIn("anthropic_sospecha", errs)


    def test_AC_3_misma_sesion_pero_distinta_semana_no_es_sospecha(self):
        misma_ses = "8% used · resets Oct 25, 3:19am (Europe/Madrid)"
        dirs = {"a": self.dir("a"), "b": self.dir("b")}
        _, errs = self.medir(dirs, {"a": salida(misma_ses, "17% used · resets Oct 27, 10:59am (Europe/Madrid)"),
                                    "b": salida(misma_ses, "18% used · resets Oct 27, 10:59am (Europe/Madrid)")})
        self.assertNotIn("anthropic_sospecha", errs)

    def test_AC_3_misma_semana_y_sesion_con_reset_distinto_no_es_sospecha(self):
        dirs = {"a": self.dir("a"), "b": self.dir("b")}
        _, errs = self.medir(dirs, {"a": salida("8% used · resets Oct 25, 3:19am (Europe/Madrid)",
                                                "17% used · resets Oct 27, 10:59am (Europe/Madrid)"),
                                    "b": salida("8% used · resets Oct 25, 3:19am (Europe/Madrid)",
                                                "17% used · resets Oct 28, 10:59am (Europe/Madrid)")})
        self.assertNotIn("anthropic_sospecha", errs)

    def test_AC_3_cuentas_con_solo_una_bolsa_no_cuentan_como_coincidencia(self):
        solo_5h = "Current session: 8% used · resets Oct 25, 3:19am (Europe/Madrid)\n"  # la semanal no sale
        dirs = {"a": self.dir("a"), "b": self.dir("b")}
        res, errs = self.medir(dirs, {"a": solo_5h, "b": solo_5h})
        self.assertNotIn("anthropic_sospecha", errs)
        self.assertEqual(sorted(res), ["claude_5h@a", "claude_5h@b"])

    def test_AC_3_tres_iguales_y_dos_grupos_se_nombran_todos(self):
        dirs = {n: self.dir(n) for n in "abcde"}
        res, errs = self.medir(dirs, {"a": USO_A, "b": USO_A, "c": USO_A, "d": USO_B, "e": USO_B})
        self.assertEqual(errs["anthropic_sospecha"],
                         "posible lectura ciega: a y b y c; d y e devuelven cifras idénticas")
        self.assertEqual(len(res), 15)  # 5 cuentas x 3 bolsas, ninguna agrupada


class TestRegistrar(Base):
    def correr(self, dirs, texto_por_cuenta, fuentes=None):
        """registrar() entera con las demás fuentes, el log y el aviso simulados: nada real, ni Telegram."""
        log = os.path.join(self.tmp.name, "logs", "cupos.jsonl")
        por_dir = {dirs[n]: t for n, t in texto_por_cuenta.items()}
        sin_fuente = {n: mock.Mock(return_value={}) for n in ("kimi", "google", "openai")}
        sin_fuente.update(fuentes or {})
        with mock.patch.object(self.m, "LOG", log), mock.patch.object(self.m, "H", self.tmp.name), \
             mock.patch.multiple(self.m, tokens=mock.Mock(return_value={}), avisar_umbrales=mock.Mock(),
                                 cuentas_claude=mock.Mock(return_value=dirs), ahora=mock.Mock(return_value=HOY),
                                 **sin_fuente), \
             mock.patch.object(self.m.subprocess, "run", side_effect=lambda argv, **kw: subprocess.CompletedProcess(
                 argv, 0, por_dir[kw["env"]["CLAUDE_CONFIG_DIR"]], "")):
            devuelta = self.m.registrar()
        with open(log) as f:
            lineas = f.read().splitlines()
        self.assertEqual(len(lineas), 1)
        escrita = json.loads(lineas[0])
        self.assertEqual(escrita["errores"], devuelta["errores"])
        return escrita

    def test_AC_3_registrar_lleva_los_errores_de_anthropic_a_la_foto(self):
        dirs = {"a": self.dir("a"), "b": self.dir("b"), "c": self.dir("c")}
        foto = self.correr(dirs, {"a": USO_A, "b": USO_A, "c": ""})
        self.assertEqual(foto["errores"]["anthropic"], {"c": "salida sin cifras de uso"})
        self.assertEqual(foto["errores"]["anthropic_sospecha"],
                         "posible lectura ciega: a y b devuelven cifras idénticas")
        self.assertEqual(foto["bolsas"]["claude_sem@a"], [17.0, "2026-10-27T10:59:00+01:00"])
        self.assertEqual(sorted(k for k in foto["bolsas"] if k.endswith("@a") or k.endswith("@b")),
                         sorted(f"{b}@{c}" for b in ("claude_5h", "claude_sem", "fable_sem") for c in "ab"))
        self.assertFalse([k for k in foto["bolsas"] if k.endswith("@c")])

    def test_registrar_una_fuente_caida_no_impide_las_demas(self):
        dirs = {"a": self.dir("a")}
        foto = self.correr(dirs, {"a": USO_A}, fuentes={"kimi": mock.Mock(side_effect=RuntimeError("caída"))})
        self.assertEqual(foto["errores"], {"kimi": "caída"})
        self.assertIn("claude_sem@a", foto["bolsas"])


class TestUmbrales(Base):
    def test_D_9_umbral_sin_arroba_vale_para_cualquier_cuenta(self):
        enviados = []
        foto = {"bolsas": {"claude_sem@b": (97.0, "2026-10-25T17:59:00+01:00"),
                           "claude_sem@a": (17.0, "2026-10-27T10:59:00+01:00")}}
        Path(self.tmp.name, ".hermes/factory/logs").mkdir(parents=True)
        with mock.patch.object(self.m, "H", self.tmp.name), \
             mock.patch.object(self.m.subprocess, "run", side_effect=lambda argv, **k: enviados.append(argv[-1])):
            self.m.avisar_umbrales(foto)
        self.assertEqual(self.m.UMBRALES["claude_sem"], [85, 95])
        self.assertEqual(len(enviados), 2)  # b cruza 85 y 95; a no cruza nada
        self.assertTrue(all("claude_sem@b" in t for t in enviados))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]] + sys.argv[1:], verbosity=2)
