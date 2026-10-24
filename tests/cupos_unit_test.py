#!/usr/bin/env python3
import json
import os
import sys
import tempfile
import unittest
from contextlib import nullcontext as _nullcontext
from pathlib import Path

# Añadir raíz del repo a sys.path
REPO_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_DIR))

from scripts.cupos import bolsas_de, ultima_foto, cadena_de, estado_cadena


class TestBolsasDe(unittest.TestCase):
    def test_mapa_bolsas(self):
        # 1. kimi-coding/* → kimi_5h, kimi_7d
        self.assertEqual(bolsas_de("kimi-coding", "kimi-for-coding"), ["kimi_5h", "kimi_7d"])
        self.assertEqual(bolsas_de("kimi-coding/otro", "cualquiera"), ["kimi_5h", "kimi_7d"])

        # 2. antigravity-oauth/gemini-4-argon* → argon_sem
        self.assertEqual(bolsas_de("antigravity-oauth", "gemini-4-argon-high"), ["argon_sem"])
        self.assertEqual(bolsas_de("antigravity-oauth", "gemini-4-argon-medium"), ["argon_sem"])

        # 3. antigravity-oauth/gemini-* → gemini_5h, gemini_sem
        self.assertEqual(bolsas_de("antigravity-oauth", "gemini-3.8-flash-high"), ["gemini_5h", "gemini_sem"])
        self.assertEqual(bolsas_de("antigravity-oauth", "gemini-2.5-pro"), ["gemini_5h", "gemini_sem"])

        # 4. antigravity-oauth/claude*|gpt-oss* → agy_claude_5h, agy_claude_sem
        self.assertEqual(bolsas_de("antigravity-oauth", "claude-sonnet-4"), ["agy_claude_5h", "agy_claude_sem"])
        self.assertEqual(bolsas_de("antigravity-oauth", "gpt-oss-1"), ["agy_claude_5h", "agy_claude_sem"])

        # 5. claude-subscription*/* → claude_5h, claude_sem
        self.assertEqual(bolsas_de("claude-subscription", "claude-opus-5-5"), ["claude_5h", "claude_sem"])
        self.assertEqual(bolsas_de("claude-subscription-directsdk-experimental", "claude-opus-5-5"), ["claude_5h", "claude_sem"])

        # 6. openai-codex/* → openai_30d
        self.assertEqual(bolsas_de("openai-codex", "codex-5"), ["openai_30d"])

        # 7. Cualquier otro → [] (desconocida nunca bloquea)
        self.assertEqual(bolsas_de("deepseek", "deepseek-v4-pro"), [])
        self.assertEqual(bolsas_de("anthropic", "claude-3-opus"), [])
        self.assertEqual(bolsas_de("", ""), [])
        self.assertEqual(bolsas_de(None, None), [])

    def test_proveedor_y_modelo_en_un_solo_argumento(self):
        self.assertEqual(bolsas_de("kimi-coding/kimi-for-coding", ""), ["kimi_5h", "kimi_7d"])
        self.assertEqual(bolsas_de("antigravity-oauth/gemini-3.8-flash-high", None),
                         ["gemini_5h", "gemini_sem"])


class TestUltimaFoto(unittest.TestCase):
    def setUp(self):
        self.ahora = 1792796462.0
        self.fixtures = REPO_DIR / "tests/fixtures/cupos"

    def test_fichero_no_existe(self):
        foto, motivo = ultima_foto("/tmp/ruta/inexistente/cupos.jsonl", ahora=self.ahora)
        self.assertIsNone(foto)
        self.assertIn("no existe", motivo.lower())

    def test_fichero_vacio(self):
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            f.write("")
            path = f.name
        try:
            foto, motivo = ultima_foto(path, ahora=self.ahora)
            self.assertIsNone(foto)
            self.assertIn("vacío", motivo.lower())
        finally:
            os.unlink(path)

    def test_json_invalido(self):
        foto, motivo = ultima_foto(self.fixtures / "foto_rota.jsonl", ahora=self.ahora)
        self.assertIsNone(foto)
        self.assertIn("inválido", motivo.lower())

    def test_foto_vieja(self):
        foto, motivo = ultima_foto(self.fixtures / "foto_vieja.jsonl", ahora=self.ahora, max_edad=1800)
        self.assertIsNone(foto)
        self.assertIn("vieja", motivo.lower())

    def test_foto_valida_y_ultima_linea(self):
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            f.write(json.dumps({"t": self.ahora - 500, "bolsas": {"v": 1}}) + "\n")
            f.write(json.dumps({"t": self.ahora - 10, "bolsas": {"kimi_5h": [10, "2026-10-24T05:00:00Z"]}}) + "\n")
            path = f.name
        try:
            foto, motivo = ultima_foto(path, ahora=self.ahora, max_edad=1800)
            self.assertIsNotNone(foto)
            self.assertIsNone(motivo)
            self.assertIn("kimi_5h", foto["bolsas"])
        finally:
            os.unlink(path)


class TestCadenaDe(unittest.TestCase):
    def test_cadena_desde_dict(self):
        cfg = {
            "model": {
                "provider": "kimi-coding",
                "default": "kimi-for-coding",
            },
            "fallback_providers": [
                {"provider": "claude-subscription", "model": "claude-sonnet-5-5-high"},
            ],
        }
        cadena = cadena_de(cfg)
        self.assertEqual(cadena, [
            ("kimi-coding", "kimi-for-coding"),
            ("claude-subscription", "claude-sonnet-5-5-high"),
        ])

    def test_cadena_con_override(self):
        cfg = {
            "model": {
                "provider": "kimi-coding",
                "default": "kimi-for-coding",
            },
            "fallback_providers": [
                {"provider": "claude-subscription", "model": "claude-sonnet-5-5-high"},
            ],
        }
        # Override model y provider
        cadena = cadena_de(cfg, model_override="gemini-3.8-flash-high", provider_override="antigravity-oauth")
        self.assertEqual(cadena, [
            ("antigravity-oauth", "gemini-3.8-flash-high"),
            ("claude-subscription", "claude-sonnet-5-5-high"),
        ])

        # Override model solo (mantiene provider del perfil)
        cadena2 = cadena_de(cfg, model_override="kimi-otra-version")
        self.assertEqual(cadena2, [
            ("kimi-coding", "kimi-otra-version"),
            ("claude-subscription", "claude-sonnet-5-5-high"),
        ])

    def test_cadena_desde_perfil_dir(self):
        with tempfile.TemporaryDirectory() as pdir:
            prof = Path(pdir) / "mitester"
            prof.mkdir(parents=True)
            (prof / "config.yaml").write_text("""model:
  provider: antigravity-oauth
  model: gemini-3.8-flash-medium
fallback_providers:
  - provider: claude-subscription
    model: claude-sonnet-5-5
""")
            os.environ["FABRIK_PROFILES_DIR"] = pdir
            try:
                cadena = cadena_de("mitester")
                self.assertEqual(cadena, [
                    ("antigravity-oauth", "gemini-3.8-flash-medium"),
                    ("claude-subscription", "claude-sonnet-5-5"),
                ])
            finally:
                del os.environ["FABRIK_PROFILES_DIR"]


class TestEstadoCadena(unittest.TestCase):
    def setUp(self):
        self.ahora = 1792796462.0  # ~ 2026-10-24 01:01:02 UTC

    def test_cadena_agotada_ac1(self):
        # AC-1: todas las bolsas de todos los modelos agotadas con reset futuro
        cadena = [
            ("kimi-coding", "kimi-for-coding"),  # kimi_5h (reset 05:00), kimi_7d (reset 25/10)
            ("claude-subscription", "claude-sonnet-5-5-high"),  # claude_5h (reset 06:00), claude_sem
        ]
        foto = {
            "bolsas": {
                "kimi_5h": [100.0, "2026-10-24T05:00:00Z"],
                "kimi_7d": [100.0, "2026-10-25T00:00:00Z"],
                "claude_5h": [100.0, "2026-10-24T06:00:00Z"],
                "claude_sem": [100.0, "2026-10-26T00:00:00Z"],
            }
        }
        lanzable, bolsa, renueva_iso, agotadas = estado_cadena(cadena, foto, ahora=self.ahora)
        self.assertFalse(lanzable)
        # kimi se libera cuando ambas renuevan: max(05:00, 25/10) = 25/10
        # claude se libera: max(06:00, 26/10) = 26/10
        # min(kimi, claude) = 25/10 (kimi_7d)
        # Pero si solo kimi_5h estuviese agotada y kimi_7d al 50%:
        # probemos con kimi_7d con margen para ver la hora exacta:
        foto2 = {
            "bolsas": {
                "kimi_5h": [100.0, "2026-10-24T05:00:00Z"],
                "kimi_7d": [50.0, "2026-10-25T00:00:00Z"],
                "claude_5h": [100.0, "2026-10-24T06:00:00Z"],
                "claude_sem": [50.0, "2026-10-26T00:00:00Z"],
            }
        }
        lanz2, bolsa2, renueva_iso2, agotadas2 = estado_cadena(cadena, foto2, ahora=self.ahora)
        self.assertFalse(lanz2)
        self.assertEqual(bolsa2, "kimi_5h")
        self.assertEqual(renueva_iso2, "2026-10-24T05:00:00Z")
        self.assertIn("kimi_5h", agotadas2)
        self.assertIn("claude_5h", agotadas2)

    def test_principal_agotada_reserva_con_margen_ac2(self):
        # AC-2: principal al 100%, reserva con margen → lanzable=True
        cadena = [
            ("kimi-coding", "kimi-for-coding"),
            ("claude-subscription", "claude-sonnet-5-5-high"),
        ]
        foto = {
            "bolsas": {
                "kimi_5h": [100.0, "2026-10-24T05:00:00Z"],
                "kimi_7d": [50.0, "2026-10-25T00:00:00Z"],
                "claude_5h": [10.0, "2026-10-24T06:00:00Z"],
                "claude_sem": [20.0, "2026-10-26T00:00:00Z"],
            }
        }
        lanzable, bolsa, renueva_iso, agotadas = estado_cadena(cadena, foto, ahora=self.ahora)
        self.assertTrue(lanzable)
        self.assertIsNone(bolsa)

    def test_reset_pasado_cuenta_como_renovada_ac4(self):
        # Foto dice 100% pero reset ya pasó → cuenta como renovada
        cadena = [("kimi-coding", "kimi-for-coding")]
        foto = {
            "bolsas": {
                "kimi_5h": [100.0, "2026-10-20T00:00:00Z"],  # en el pasado
                "kimi_7d": [50.0, "2026-10-25T00:00:00Z"],
            }
        }
        lanzable, bolsa, renueva_iso, agotadas = estado_cadena(cadena, foto, ahora=self.ahora)
        self.assertTrue(lanzable)

    def test_modelo_sin_bolsa_nunca_bloquea(self):
        cadena = [
            ("kimi-coding", "kimi-for-coding"),  # agotada
            ("deepseek", "deepseek-v4-pro"),      # sin bolsa
        ]
        foto = {
            "bolsas": {
                "kimi_5h": [100.0, "2026-10-24T05:00:00Z"],
                "kimi_7d": [100.0, "2026-10-25T00:00:00Z"],
            }
        }
        lanzable, _, _, _ = estado_cadena(cadena, foto, ahora=self.ahora)
        self.assertTrue(lanzable)

    def test_bolsa_ausente_en_foto_no_bloquea(self):
        cadena = [("kimi-coding", "kimi-for-coding")]
        foto = {"bolsas": {}}  # fuente con error
        lanzable, _, _, _ = estado_cadena(cadena, foto, ahora=self.ahora)
        self.assertTrue(lanzable)


class TestCargarYamlFallback(unittest.TestCase):
    """Cubre el parser YAML puro (entorno sin pyyaml) y sus ramas."""

    def _sin_librerias_yaml(self):
        """Contexto que fuerza el uso del parser YAML puro bloqueando yaml y hermes_yaml."""
        import contextlib
        import sys

        @contextlib.contextmanager
        def _ctx():
            sys.modules["yaml"] = None
            sys.modules["hermes_yaml"] = None
            try:
                yield
            finally:
                sys.modules.pop("yaml", None)
                sys.modules.pop("hermes_yaml", None)

        return _ctx()

    def test_comillas_lineas_en_blanco_y_claves_raiz(self):
        from scripts.cupos import _cargar_yaml
        valido = (
            'model:\n'
            '  provider: kimi-coding\n'
            '  model: kimi-for-coding\n'
            'fallback_providers:\n'
            '  - provider: claude-subscription\n'
            '    model: claude-sonnet-5-5-high\n'
        )
        tolerante = (
            '# comentario inicial\n'
            'model:\n'
            '  provider: "kimi-coding"\n'
            '  model: \'kimi-for-coding\'\n'
            '  clave_suelta\n'
            '\n'
            'otra_clave: valor\n'
            'otra-suelta\n'
            'fallback_model:\n'
            '  - provider: claude-subscription\n'
            '    model: claude-sonnet-5-5-high\n'
        )
        esperado = {
            "model": {"provider": "kimi-coding", "model": "kimi-for-coding"},
            "fallback_providers": [{"provider": "claude-subscription", "model": "claude-sonnet-5-5-high"}],
        }
        for etiqueta, bloqueado in (("librería yaml", False), ("parser puro", True)):
            def _ctx():
                return self._sin_librerias_yaml() if bloqueado else _nullcontext()

            with _ctx():
                cfg = _cargar_yaml(valido)
            self.assertEqual(cfg, esperado, etiqueta)
            with _ctx():
                cfg = _cargar_yaml(tolerante)
            self.assertEqual(cfg["model"]["provider"], "kimi-coding", etiqueta)
            self.assertEqual(cfg["model"]["model"], "kimi-for-coding", etiqueta)
            self.assertEqual(cfg["otra_clave"], "valor", etiqueta)
            self.assertEqual(cfg["fallback_model"], esperado["fallback_providers"], etiqueta)

    def test_hermes_yaml_cuando_pyyaml_ausente(self):
        import sys
        import types
        from scripts.cupos import _cargar_yaml
        fake = types.ModuleType("hermes_yaml")
        fake.safe_load = lambda _t: {"model": {"provider": "kimi-coding", "model": "kimi-for-coding"}}
        sys.modules["yaml"] = None  # fuerza ImportError en `import yaml`
        sys.modules["hermes_yaml"] = fake
        try:
            cfg = _cargar_yaml("cualquier: cosa")
        finally:
            sys.modules.pop("yaml", None)
            sys.modules.pop("hermes_yaml", None)
        self.assertEqual(cfg["model"]["provider"], "kimi-coding")


class TestUltimaFotoRamas(unittest.TestCase):
    def setUp(self):
        self.ahora = 1792796462.0
        self.fixtures = REPO_DIR / "tests/fixtures/cupos"

    def test_ruta_por_env_y_max_edad_por_env(self):
        os.environ["FABRIK_CUPOS_LOG"] = str(self.fixtures / "foto_con_margen.jsonl")
        os.environ["FABRIK_CUPOS_MAX_EDAD"] = "no-numérico"
        try:
            foto, motivo = ultima_foto(None, ahora=self.ahora)  # ruta y edad por env
            self.assertIsNotNone(foto)
            self.assertIsNone(motivo)
        finally:
            del os.environ["FABRIK_CUPOS_LOG"]
            del os.environ["FABRIK_CUPOS_MAX_EDAD"]

    def test_ahora_none_usa_reloj_real(self):
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            f.write(json.dumps({"t": __import__("time").time(), "bolsas": {}}) + "\n")
            path = f.name
        try:
            foto, motivo = ultima_foto(path, ahora=None)
            self.assertIsNotNone(foto)
        finally:
            os.unlink(path)

    def test_ahora_datetime(self):
        foto, motivo = ultima_foto(
            self.fixtures / "foto_con_margen.jsonl",
            ahora=__import__("datetime").datetime.fromtimestamp(self.ahora, tz=__import__("datetime").timezone.utc),
        )
        self.assertIsNotNone(foto)
        self.assertIsNone(motivo)

    def test_solo_lineas_en_blanco(self):
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            f.write("\n\n  \n")
            path = f.name
        try:
            foto, motivo = ultima_foto(path, ahora=self.ahora)
            self.assertIsNone(foto)
            self.assertIn("vacío", motivo.lower())
        finally:
            os.unlink(path)

    def test_json_valido_pero_no_objeto(self):
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            f.write(json.dumps([1, 2, 3]) + "\n")
            path = f.name
        try:
            foto, motivo = ultima_foto(path, ahora=self.ahora)
            self.assertIsNone(foto)
            self.assertIn("objeto", motivo.lower())
        finally:
            os.unlink(path)

    def test_campo_t_ausente(self):
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            f.write(json.dumps({"bolsas": {}}) + "\n")
            path = f.name
        try:
            foto, motivo = ultima_foto(path, ahora=self.ahora)
            self.assertIsNone(foto)
            self.assertIn("'t' ausente", motivo)
        finally:
            os.unlink(path)

    def test_campo_t_no_numerico(self):
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            f.write(json.dumps({"t": "ayer", "bolsas": {}}) + "\n")
            path = f.name
        try:
            foto, motivo = ultima_foto(path, ahora=self.ahora)
            self.assertIsNone(foto)
            self.assertIn("no es numérico", motivo)
        finally:
            os.unlink(path)

    def test_error_de_lectura(self):
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f:
            f.write(json.dumps({"t": self.ahora, "bolsas": {}}) + "\n")
            path = f.name
        os.chmod(path, 0)
        try:
            foto, motivo = ultima_foto(path, ahora=self.ahora)
            self.assertIsNone(foto)
            self.assertIn("error", motivo.lower())
        finally:
            os.chmod(path, 0o600)
            os.unlink(path)


class TestCadenaDeRamas(unittest.TestCase):
    def test_ruta_yaml_directa(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "config.yaml"
            p.write_text(PERFIL_CADENA_YAML)
            cadena = cadena_de(str(p))
            self.assertEqual(cadena[0], ("kimi-coding", "kimi-for-coding"))

    def test_ruta_yaml_inexistente_devuelve_cadena_vacia(self):
        cadena = cadena_de("/no/existe/config.yaml")
        self.assertEqual(cadena, [])

    def test_perfil_con_config_roto(self):
        with tempfile.TemporaryDirectory() as d:
            prof = Path(d) / "programador"
            prof.mkdir()
            cfg_path = prof / "config.yaml"
            cfg_path.write_text("model:\n  provider: kimi-coding\n")
            os.chmod(cfg_path, 0)  # is_file() True pero read_text() lanza
            os.environ["FABRIK_PROFILES_DIR"] = d
            try:
                cadena = cadena_de("programador")
            finally:
                del os.environ["FABRIK_PROFILES_DIR"]
                os.chmod(cfg_path, 0o600)
            self.assertEqual(cadena, [])

    def test_modelo_como_clave_raiz(self):
        cfg = {"model": "kimi-for-coding", "provider": "kimi-coding"}
        cadena = cadena_de(cfg)
        self.assertEqual(cadena, [("kimi-coding", "kimi-for-coding")])

    def test_fallback_model_dict(self):
        cfg = {
            "model": {"provider": "kimi-coding", "model": "kimi-for-coding"},
            "fallback_model": {"provider": "claude-subscription", "model": "claude-sonnet-5-5-high"},
        }
        cadena = cadena_de(cfg)
        self.assertEqual(cadena, [
            ("kimi-coding", "kimi-for-coding"),
            ("claude-subscription", "claude-sonnet-5-5-high"),
        ])


class TestEstadoCadenaRamas(unittest.TestCase):
    def setUp(self):
        self.ahora = 1792796462.0
        self.cadena = [("kimi-coding", "kimi-for-coding")]

    def test_valor_de_bolsa_no_lista(self):
        foto = {"bolsas": {"kimi_5h": 100.0, "kimi_7d": [100.0, "2026-10-25T00:00:00Z"]}}
        lanzable, bolsa, renueva, _ = estado_cadena(self.cadena, foto, ahora=self.ahora)
        self.assertFalse(lanzable)
        self.assertEqual(bolsa, "kimi_7d")

    def test_pct_no_numerico(self):
        foto = {"bolsas": {"kimi_5h": ["alta", "2026-10-24T05:00:00Z"], "kimi_7d": [100.0, "2026-10-25T00:00:00Z"]}}
        lanzable, bolsa, _, _ = estado_cadena(self.cadena, foto, ahora=self.ahora)
        self.assertFalse(lanzable)
        self.assertEqual(bolsa, "kimi_7d")

    def test_reset_no_parseable(self):
        foto = {"bolsas": {"kimi_5h": [100.0, "no-es-fecha"], "kimi_7d": [100.0, "tampoco"]}}
        lanzable, _, _, _ = estado_cadena(self.cadena, foto, ahora=self.ahora)
        self.assertTrue(lanzable)  # sin resets válidos no se puede saber: no bloquea

    def test_ahora_datetime(self):
        import datetime
        foto = {"bolsas": {"kimi_5h": [100.0, "2026-10-24T05:00:00Z"], "kimi_7d": [100.0, "2026-10-25T00:00:00Z"]}}
        ahora_dt = datetime.datetime.fromtimestamp(self.ahora, tz=datetime.timezone.utc)
        lanzable, _, _, _ = estado_cadena(self.cadena, foto, ahora=ahora_dt)
        self.assertFalse(lanzable)

    def test_foto_plana_sin_clave_bolsas(self):
        foto = {"kimi_5h": [100.0, "2026-10-24T05:00:00Z"], "kimi_7d": [100.0, "2026-10-25T00:00:00Z"]}
        lanzable, bolsa, _, _ = estado_cadena(self.cadena, foto, ahora=self.ahora)
        self.assertFalse(lanzable)
        self.assertEqual(bolsa, "kimi_7d")

    def test_cadena_vacia_es_lanzable(self):
        lanzable, bolsa, renueva, agotadas = estado_cadena([], {"bolsas": {}}, ahora=self.ahora)
        self.assertTrue(lanzable)
        self.assertIsNone(bolsa)
        self.assertEqual(agotadas, [])

    def test_umbral_personalizado(self):
        foto = {"bolsas": {"kimi_5h": [90.0, "2026-10-24T05:00:00Z"], "kimi_7d": [50.0, "2026-10-25T00:00:00Z"]}}
        lanzable, _, _, _ = estado_cadena(self.cadena, foto, ahora=self.ahora, umbral=80)
        self.assertFalse(lanzable)  # 90 >= 80 agota
        lanzable2, _, _, _ = estado_cadena(self.cadena, foto, ahora=self.ahora, umbral=95)
        self.assertTrue(lanzable2)


PERFIL_CADENA_YAML = """model:
  provider: kimi-coding
  model: kimi-for-coding
fallback_providers:
  - provider: claude-subscription
    model: claude-sonnet-5-5-high
"""


if __name__ == "__main__":
    unittest.main()
