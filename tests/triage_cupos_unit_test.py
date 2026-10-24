#!/usr/bin/env python3
"""Tests unitarios de scripts/triage_cupos.py (esperar_cupo) con dobles.

AC-1..AC-4 a nivel de función: sqlite :memory:, hk doble, tiempo congelado,
fotos fixture generadas con timestamp fijo. Sin red, sin sleeps, sin Hermes.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_DIR / "scripts"))

import triage_cupos  # noqa: E402

AHORA = 1792796462.0  # ~ 2026-10-24 01:01:02 UTC
FOTO_T = 1792796400.0  # foto de hace 62 s (< 30 min)

# Cadena del perfil de prueba: kimi (principal) + claude (reserva)
PERFIL_YAML = """model:
  provider: kimi-coding
  model: kimi-for-coding
fallback_providers:
  - provider: claude-subscription
    model: claude-sonnet-5-5-high
"""

# Todas las bolsas de la cadena agotadas, resets futuros
BOLSAS_AGOTADAS = {
    "kimi_5h": [100.0, "2026-10-24T05:00:00Z"],
    "kimi_7d": [100.0, "2026-10-25T00:00:00Z"],
    "claude_5h": [100.0, "2026-10-24T06:00:00Z"],
    "claude_sem": [100.0, "2026-10-26T00:00:00Z"],
}
# La cadena entera libera cuando renueva la bolsa más próxima: kimi_7d (25/10)
RENUEVA_CADENA = "2026-10-25T00:00:00Z"


class HKFake:
    """Doble del hk de fabrik-triage: registra llamadas, no toca nada."""

    def __init__(self):
        self.llamadas: list[list[str]] = []

    def __call__(self, *args, timeout=60):
        self.llamadas.append([str(a) for a in args])

        class R:
            stdout = ""

        return R()

    def de_tipo(self, cmd: str) -> list[list[str]]:
        return [l for l in self.llamadas if len(l) >= 3 and l[2] == cmd or (cmd in l)]

    def cuenta(self, cmd: str) -> int:
        return sum(1 for l in self.llamadas if cmd in l)


class TestEsperarCupo(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        # Perfil de prueba
        (root / "profiles" / "programador").mkdir(parents=True)
        (root / "profiles" / "programador" / "config.yaml").write_text(PERFIL_YAML)
        os.environ["FABRIK_PROFILES_DIR"] = str(root / "profiles")
        self.addCleanup(lambda: os.environ.pop("FABRIK_PROFILES_DIR", None))

        # Foto de cupos (sobrescribible por test)
        self.foto_path = root / "cupos.jsonl"
        os.environ["FABRIK_CUPOS_LOG"] = str(self.foto_path)
        self.addCleanup(lambda: os.environ.pop("FABRIK_CUPOS_LOG", None))

        self.estado_path = root / "cupo-espera.json"
        self.hk = HKFake()
        self.logs: list[str] = []
        self.c = sqlite3.connect(":memory:")
        self.c.execute(
            "create table tasks (id text primary key, title text, status text, "
            "assignee text, model_override text, provider_override text)"
        )

        # Resetea los caches de módulo entre tests
        triage_cupos._aviso_sin_filtro.update(activo=False, motivo=None)

    def _foto(self, bolsas: dict) -> None:
        self.foto_path.write_text(json.dumps({"t": FOTO_T, "bolsas": bolsas}) + "\n")

    def _tarjeta(self, tid: str, status: str = "ready", assignee: str = "programador",
                 title: str = "Tarea", mo: str = "", po: str = "") -> None:
        self.c.execute(
            "insert into tasks values (?,?,?,?,?,?)", (tid, title, status, assignee, mo, po))

    def _pasa(self, ahora: float = AHORA) -> dict:
        return triage_cupos.esperar_cupo(
            "pruebas", self.c, hk=self.hk, ahora=ahora,
            estado_path=self.estado_path, log=self.logs.append)

    def _be(self) -> dict:
        return json.loads(self.estado_path.read_text()).get("pruebas", {})

    # ---------- AC-1 ----------
    def test_ac1_aparca_con_un_solo_schedule_y_comentario(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        for _ in range(3):  # N pasadas
            self._pasa()
        self.assertEqual(self.hk.cuenta("schedule"), 1)
        # El comentario de espera lo añade `hermes kanban schedule <id> <texto>` por sí solo
        # («SCHEDULED: <texto>»): un `comment` explícito lo duplicaría.
        self.assertEqual(self.hk.cuenta("comment"), 0)
        sched = self.hk.de_tipo("schedule")[0]
        self.assertEqual(sched[:4], ["--board", "pruebas", "schedule", "t1"])
        self.assertIn("⏳ esperando cupo", sched[4])
        self.assertIn("cadena agotada", sched[4])
        self.assertIn("kimi_5h", sched[4])
        self.assertIn("claude_5h", sched[4])
        estado = self._be()
        self.assertIn("t1", estado)
        self.assertEqual(estado["t1"]["renueva"], RENUEVA_CADENA)

    def test_ac1_nunca_toca_scheduled_ajena(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._tarjeta("tajena", status="scheduled")
        self._pasa()
        self.assertEqual(self.hk.cuenta("schedule"), 1)  # solo t1
        self.assertEqual(self.hk.cuenta("unblock"), 0)   # la ajena intacta

    def test_ac1_salta_manual_y_no_rol(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._tarjeta("tmanual", title="Algo [manual]")
        self._tarjeta("thumana", assignee="humano-uno")
        self._pasa()
        self.assertEqual(self.hk.cuenta("schedule"), 1)

    # ---------- AC-2 ----------
    def test_ac2_reserva_con_margen_no_se_aparca(self):
        foto_margen = dict(BOLSAS_AGOTADAS)
        foto_margen["claude_5h"] = [10.0, "2026-10-24T06:00:00Z"]
        foto_margen["claude_sem"] = [20.0, "2026-10-26T00:00:00Z"]
        self._foto(foto_margen)
        self._tarjeta("t1")
        self._pasa()
        self.assertEqual(self.hk.cuenta("schedule"), 0)
        self.assertEqual(self._be(), {})

    def test_ac2_override_a_modelo_sin_bolsa_no_bloquea(self):
        self._foto(BOLSAS_AGOTADAS)
        # Override a deepseek (sin bolsas): la principal no bloquea y la reserva
        # deepseek tampoco → la cadena es lanzable aunque kimi/claude estén al 100 %.
        self._tarjeta("t1", mo="deepseek-v4-pro", po="deepseek")
        self._pasa()
        self.assertEqual(self.hk.cuenta("schedule"), 0)
        self.assertEqual(self._be(), {})

    # ---------- AC-3 ----------
    def test_ac3_foto_rota_despacha_sin_filtrar_y_avisa_una_vez(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa()
        self.assertEqual(self.hk.cuenta("schedule"), 1)
        # Se rompe la foto: se desaparca y se avisa (una sola vez aunque repita).
        # El schedule real (hermes) habría puesto la tarjeta en scheduled; el doble
        # no toca la BD, así que se reproduce aquí.
        self.c.execute("update tasks set status='scheduled' where id='t1'")
        self.foto_path.write_text("{no-es-json\n")
        os.utime(self.foto_path, (AHORA + 400, AHORA + 400))
        for _ in range(3):
            self._pasa()
        self.assertEqual(self.hk.cuenta("unblock"), 1)  # t1 retomada una vez
        avisos = [m for m in self.logs if m.startswith("⚠ cupos:")]
        self.assertEqual(len(avisos), 1)
        self.assertIn("despacho sin filtrar", avisos[0])
        self.assertEqual(self.hk.cuenta("schedule"), 1)  # nada nuevo aparcado

    def test_ac3_foto_ausente_despacha_sin_filtrar(self):
        self._tarjeta("t1")
        self._pasa(ahora=AHORA)
        self.assertEqual(self.hk.cuenta("schedule"), 0)
        self.assertTrue(any(m.startswith("⚠ cupos:") for m in self.logs))

    def test_ac3_foto_que_envejece_en_el_mismo_proceso_deja_de_filtrar(self):
        # Medidor caído en un proceso largo: el fichero no cambia (mismo mtime) pero
        # la foto envejece. La edad se reevalúa en cada pasada: avisa, no aparca y retoma.
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa(ahora=AHORA)
        self.assertEqual(self.hk.cuenta("schedule"), 1)
        self.c.execute("update tasks set status='scheduled' where id='t1'")
        self._tarjeta("t2")
        self._pasa(ahora=FOTO_T + 1800 + 1)  # sin tocar el fichero, pasado max_edad
        self.assertEqual(self.hk.cuenta("schedule"), 1)  # t2 no se aparca
        self.assertEqual(self.hk.cuenta("unblock"), 1)  # t1 se retoma
        avisos = [m for m in self.logs if m.startswith("⚠ cupos:") and "foto vieja" in m]
        self.assertEqual(len(avisos), 1)

    def test_no_aparca_si_el_gateway_la_reclama_entre_el_select_y_el_schedule(self):
        # Carrera ready→running: `schedule` también aparca running y dejaría un worker huérfano.
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        corriendo = ("running", "programador", "Tarea", "", "")
        with mock.patch.object(triage_cupos, "_fila", return_value=corriendo):
            self._pasa()
        self.assertEqual(self.hk.cuenta("schedule"), 0)
        self.assertNotIn("t1", self._be())
        self._pasa()  # sin carrera: ya se aparca
        self.assertEqual(self.hk.cuenta("schedule"), 1)

    def test_estado_se_guarda_de_forma_atomica(self):
        triage_cupos._guardar_estado(self.estado_path, {"a": {"t1": {}}})
        self.assertEqual(json.loads(self.estado_path.read_text()), {"a": {"t1": {}}})
        self.assertEqual([p.name for p in self.estado_path.parent.glob("*.tmp")], [])
        # Si el reemplazo falla, el fichero anterior queda intacto (nunca a medias).
        with mock.patch.object(triage_cupos.os, "replace", side_effect=OSError("disco")):
            with self.assertRaises(OSError):
                triage_cupos._guardar_estado(self.estado_path, {"b": {}})
        self.assertEqual(json.loads(self.estado_path.read_text()), {"a": {"t1": {}}})

    def test_aviso_de_salida_del_modo_sin_filtro(self):
        # En un proceso persistente (el servicio real), al recuperarse la foto se
        # avisa una sola vez de la salida del modo «despacho sin filtrar».
        self._tarjeta("t1")
        self._pasa(ahora=AHORA)  # sin foto: entra en modo sin filtrar
        self.assertTrue(any(m.startswith("⚠ cupos:") for m in self.logs))
        self._foto(BOLSAS_AGOTADAS)
        os.utime(self.foto_path, (AHORA + 300, AHORA + 300))
        self._pasa(ahora=AHORA)
        salidas = [m for m in self.logs if m.startswith("✓ cupos:")]
        self.assertEqual(len(salidas), 1)
        self.assertIn("foto recuperada", salidas[0])
        # Y vuelve a filtrar: la tarjeta se aparca con la foto válida agotada
        self.assertEqual(self.hk.cuenta("schedule"), 1)

    # ---------- AC-4 ----------
    def test_ac4_retoma_al_renovarse_el_cupo(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa()
        self.assertEqual(self.hk.cuenta("schedule"), 1)
        self.c.execute("update tasks set status='scheduled' where id='t1'")
        # Renueva la foto: kimi_5h con margen → la cadena ya es lanzable
        foto_nueva = dict(BOLSAS_AGOTADAS)
        foto_nueva["kimi_5h"] = [10.0, "2026-10-24T05:00:00Z"]
        foto_nueva["kimi_7d"] = [50.0, "2026-10-25T00:00:00Z"]
        self._foto(foto_nueva)
        os.utime(self.foto_path, (AHORA + 500, AHORA + 500))  # fuerza nuevo mtime
        self._pasa()
        self.assertEqual(self.hk.cuenta("unblock"), 1)
        self.assertNotIn("t1", self._be())
        self.assertTrue(any("retomada" in m for m in self.logs))

    def test_ac4_retoma_cuando_pasa_la_hora_de_renueva(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa()
        self.assertIn("t1", self._be())
        self.c.execute("update tasks set status='scheduled' where id='t1'")
        # Misma foto agotada pero ya pasó la hora de renovación de la cadena
        ahora_despues = 1792972800.0  # 2026-10-26T05:00:00Z, tras el reset de la cadena
        self._pasa(ahora=ahora_despues)
        self.assertEqual(self.hk.cuenta("unblock"), 1)
        self.assertNotIn("t1", self._be())

    # ---------- Extras de la spec ----------
    def test_desbloqueo_humano_respetado_en_la_misma_ventana(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa()
        self.assertEqual(self.hk.cuenta("schedule"), 1)
        # El humano la desbloquea a mano: vuelve a ready con la misma foto/ventana
        self.c.execute("update tasks set status='ready' where id='t1'")
        self._pasa()
        self.assertEqual(self.hk.cuenta("schedule"), 1)  # no se reaparca
        estado = self._be()
        self.assertTrue(estado["t1"].get("desbloqueo_humano"))

    def test_desbloqueo_humano_se_limpia_al_cambiar_de_ventana(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa()
        self.c.execute("update tasks set status='ready' where id='t1'")
        self._pasa()
        # Cambia la ventana (renueva distinto): sí puede reaparcarse
        foto2 = dict(BOLSAS_AGOTADAS)
        foto2["kimi_7d"] = [100.0, "2026-10-27T00:00:00Z"]  # renueva más tarde
        self._foto(foto2)
        os.utime(self.foto_path, (AHORA + 500, AHORA + 500))
        self._pasa()
        self.assertEqual(self.hk.cuenta("schedule"), 2)

    def test_seco_no_persiste_ni_ejecuta(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        import io
        from contextlib import redirect_stdout
        out = io.StringIO()
        with redirect_stdout(out):
            triage_cupos.esperar_cupo(
                "pruebas", self.c, hk=self.hk, seco=True, ahora=AHORA,
                estado_path=self.estado_path, log=self.logs.append)
        self.assertFalse(self.estado_path.exists())  # nada persistido
        self.assertEqual(self.hk.llamadas, [])       # nada ejecutado
        self.assertIn("esperar-cupo pruebas t1", out.getvalue())

    def test_no_hay_comentario_explicito_porque_schedule_ya_comenta(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa()
        self.assertEqual([l for l in self.hk.llamadas if "comment" in l], [])
        self.assertEqual(self.hk.cuenta("schedule"), 1)

    # ---------- ramas defensivas ----------
    def test_parse_iso_ts_y_fmt_local_casos(self):
        self.assertIsNone(triage_cupos._parse_iso_ts(None))
        self.assertIsNone(triage_cupos._parse_iso_ts(""))
        self.assertIsNone(triage_cupos._parse_iso_ts("no-es-fecha"))
        self.assertEqual(triage_cupos._fmt_local(None), "?")
        self.assertEqual(triage_cupos._fmt_local(""), "?")
        self.assertEqual(triage_cupos._fmt_local("no-es-fecha"), "no-es-fecha")

    def test_tarjeta_borrada_se_limpia_del_estado(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa()
        self.assertIn("t1", self._be())
        self.c.execute("delete from tasks where id='t1'")
        self._pasa()  # foto válida: _procesar_aparcadas la quita
        self.assertNotIn("t1", self._be())
        # y con foto rota: _sin_filtro la quita sin unblock
        self._tarjeta("t2")
        self._pasa()
        self.c.execute("delete from tasks where id='t2'")
        self.foto_path.write_text("{rota\n")
        os.utime(self.foto_path, (AHORA + 700, AHORA + 700))
        self._pasa()
        self.assertEqual(self.hk.cuenta("unblock"), 0)
        self.assertNotIn("t2", self._be())

    def test_info_no_dict_se_limpia(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa()
        estado = {"pruebas": {"t1": "dato-corrupto"}}
        self.estado_path.write_text(json.dumps(estado))
        self._pasa()
        # El dato corrupto se limpia y la tarjeta (aún ready) se reaparca con
        # información sana: un solo schedule adicional.
        self.assertIsInstance(self._be()["t1"], dict)
        self.assertEqual(self._be()["t1"]["renueva"], "2026-10-25T00:00:00Z")
        self.assertEqual(self.hk.cuenta("schedule"), 2)

    def test_humano_la_vuelve_a_schedulear_no_se_toca(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa()
        self.c.execute("update tasks set status='ready' where id='t1'")   # unblock humano
        self._pasa()                                                       # marca desbloqueo_humano
        self.c.execute("update tasks set status='scheduled' where id='t1'")  # la vuelve a aparcar a mano
        self._pasa()
        self.assertEqual(self.hk.cuenta("unblock"), 0)
        self.assertEqual(self.hk.cuenta("schedule"), 1)
        self.assertTrue(self._be()["t1"].get("desbloqueo_humano"))

    def test_ventana_pasada_limpia_la_marca_humana(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa()
        self.c.execute("update tasks set status='ready' where id='t1'")
        ahora_despues = 1792972800.0  # tras el renueva de la cadena
        self._pasa(ahora=ahora_despues)
        self.assertNotIn("t1", self._be())

    def test_renueva_actualizado_mientras_sigua_scheduled(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa()
        self.c.execute("update tasks set status='scheduled' where id='t1'")
        foto2 = dict(BOLSAS_AGOTADAS)
        foto2["kimi_7d"] = [100.0, "2026-10-27T00:00:00Z"]      # renueva más tarde
        foto2["claude_sem"] = [100.0, "2026-10-28T00:00:00Z"]   # el mínimo pasa a 27
        self._foto(foto2)
        os.utime(self.foto_path, (AHORA + 800, AHORA + 800))
        self._pasa()
        self.assertEqual(self.hk.cuenta("unblock"), 0)
        self.assertEqual(self._be()["t1"]["renueva"], "2026-10-27T00:00:00Z")

    def test_seco_imprime_retomar_sin_ejecutar(self):
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        self._pasa()
        self.c.execute("update tasks set status='scheduled' where id='t1'")
        # Cadena entera lanzable: todas las bolsas bajo el umbral.
        foto_margen = {k: [10.0, v[1]] for k, v in BOLSAS_AGOTADAS.items()}
        self._foto(foto_margen)
        os.utime(self.foto_path, (AHORA + 900, AHORA + 900))
        import io
        from contextlib import redirect_stdout
        out = io.StringIO()
        with redirect_stdout(out):
            triage_cupos.esperar_cupo(
                "pruebas", self.c, hk=self.hk, seco=True, ahora=AHORA,
                estado_path=self.estado_path, log=self.logs.append)
        self.assertIn("retomar pruebas t1", out.getvalue())
        self.assertEqual(self.hk.cuenta("unblock"), 0)  # en seco no ejecuta

    def test_excepcion_en_la_logica_no_bloquea_la_pasada(self):
        # Conexión sin la columna status: la lógica de cupos lanza y se entra
        # en modo «despacho sin filtrar» sin romper la pasada.
        self._foto(BOLSAS_AGOTADAS)  # foto válida para que la excepción salte
        c_rota = sqlite3.connect(":memory:")
        c_rota.execute("create table tasks (id text primary key)")
        c_rota.execute("insert into tasks (id) values ('t1')")
        logs: list[str] = []
        triage_cupos.esperar_cupo(
            "pruebas", c_rota, hk=self.hk, ahora=AHORA,
            estado_path=self.estado_path, log=logs.append)
        avisos = [m for m in logs if m.startswith("⚠ cupos: excepción:")]
        self.assertEqual(len(avisos), 1)
        c_rota.close()

    def test_procesar_ready_respeta_aparcada_en_la_misma_ventana(self):
        # Unidad de _procesar_ready: tarjeta en estado aparcado (misma renueva)
        # y aún 'ready' en la BD → un solo schedule; no se reaparca.
        self._foto(BOLSAS_AGOTADAS)
        self._tarjeta("t1")
        be = {"t1": {"renueva": RENUEVA_CADENA, "bolsas": ["kimi_5h"], "aparcada_en": AHORA}}
        triage_cupos._procesar_ready("pruebas", self.c, be, {"bolsas": BOLSAS_AGOTADAS}, AHORA,
                                     self.hk, False, self.logs.append)
        self.assertEqual(self.hk.cuenta("schedule"), 0)
        self.assertEqual(self.hk.cuenta("comment"), 0)
        self.assertIn("t1", be)


class TestConserjeIgnoraComentarioDeEspera(unittest.TestCase):
    """El conserje de bin/fabrik-triage no debe procesar el comentario «⏳ esperando cupo…»."""

    def setUp(self):
        import types
        # Stub de hermes_cli: el head de fabrik-triage lo importa al cargar.
        self._mods_originales = {k: sys.modules.get(k) for k in
                                 ("hermes_cli", "hermes_cli.kanban_db_connect", "hermes_cli.kanban_db")}
        pkg = types.ModuleType("hermes_cli")
        conn = types.ModuleType("hermes_cli.kanban_db_connect")
        conn.connect = lambda *a, **k: None
        kdb = types.ModuleType("hermes_cli.kanban_db")
        kdb.specify_triage_task = lambda *a, **k: None
        sys.modules["hermes_cli"] = pkg
        sys.modules["hermes_cli.kanban_db_connect"] = conn
        sys.modules["hermes_cli.kanban_db"] = kdb

        src = (REPO_DIR / "bin/fabrik-triage").read_text()
        codigo = src.split("<<'PYEOF'\n", 1)[1].rsplit("\nPYEOF", 1)[0]
        cabeza = codigo.split("estado = cargar_estado()")[0]  # solo defs/constantes, sin el bucle
        os.environ["FABRIK_SRC"] = str(REPO_DIR)  # el wrapper bash lo exporta en producción
        self.ns: dict = {"__name__": "fabrik_triage_test"}
        exec(compile(cabeza, "bin/fabrik-triage", "exec"), self.ns)

        # Dobles: pool que registra submits sin ejecutarlos (sin red), SECO a False.
        self.submits: list[tuple] = []

        class PoolDoble:
            def __init__(self, registra):
                self.registros = registra

            def submit(self, fn, *args):
                self.registros.append(args)

        self.ns["pool"] = PoolDoble(self.submits)
        self.ns["SECO"] = False
        self.ns["en_curso"] = set()

        self.c = sqlite3.connect(":memory:")
        self.c.execute("create table tasks (id text primary key, status text, title text)")
        self.c.execute("create table task_comments (id integer primary key, task_id text, "
                       "author text, body text, created_at integer)")
        self.c.execute("insert into tasks values ('t1','ready','Tarea uno')")
        self.c.execute("insert into tasks values ('t2','ready','Tarea dos')")
        self.c.executemany("insert into task_comments values (?,?,?,?,?)", [
            (1, "t1", "humano-uno", "primer comentario", 1000),
            (2, "t2", "fabrik-triage", "⏳ esperando cupo de kimi_5h", 1001),
            (3, "t1", "humano-uno", "otro", 1002),
        ])
        self.c.commit()

    def tearDown(self):
        self.c.close()
        for k, v in self._mods_originales.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v

    def test_conserje_ignora_comentario_de_espera_y_autor_no_humano(self):
        comentarios = self.ns["comentarios"]
        estado: dict = {}
        # Primera pasada: fija el cursor sin procesar historial.
        self.assertTrue(comentarios("pruebas", self.c, estado))
        self.assertEqual(self.submits, [])
        # Comentario nuevo del humano: el de espera (⏳) se ignora; el normal se encola.
        self.c.execute("insert into task_comments values (4,'t1','humano-uno',"
                       "'⏳ esperando cupo de kimi_5h (renueva 24/10 05:00 hora local); "
                       "cadena agotada: kimi_5h, kimi_7d',1003)")
        # Comentario real de `hermes kanban schedule`: «SCHEDULED: <texto>», autor = perfil/usuario.
        self.c.execute("insert into task_comments values (7,'t1','user',"
                       "'SCHEDULED: ⏳ esperando cupo de kimi_5h (renueva 24/10 05:00 hora local)',1003)")
        self.c.execute("insert into task_comments values (5,'t2','humano-uno',"
                       "'¿puedes revisar el PR?',1004)")
        self.c.execute("insert into task_comments values (6,'t2','conserje',"
                       "'🤖 conserje: de acuerdo',1005)")
        self.c.commit()
        self.assertTrue(comentarios("pruebas", self.c, estado))
        # Un solo submit: el comentario humano normal de t2 (args=(board,key,tid,status,title,body)).
        self.assertEqual(len(self.submits), 1)
        self.assertEqual(self.submits[0][0], "pruebas")
        self.assertEqual(self.submits[0][2], "t2")
        self.assertEqual(estado["pruebas"], 7)


if __name__ == "__main__":
    unittest.main()
