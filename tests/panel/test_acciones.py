"""AC-2b (acciones con lista cerrada + comentario 🏭) y backend de Aprobar de AC-3a: `POST /acciones/*`.

`comun.ejecutar` simulado: se comprueban los argv exactos, el timeout y que lo inválido se rechaza sin ejecutar nada.
"""
import hashlib
import sqlite3
from pathlib import Path
from unittest import mock

from tests.panel.test_atascadas_util import AtascadasTest

BASE = ["hermes", "kanban", "--board", "demo"]


class AccionesTest(AtascadasTest):
    def setUp(self):
        super().setUp()
        self.llamadas = []
        self.fallan = set()  # verbos de kanban que devuelven error
        self.al_ejecutar = None  # efecto de lado opcional: f(argv)
        parche = mock.patch.object(self.comun, "ejecutar", side_effect=self.falso)
        parche.start()
        self.addCleanup(parche.stop)
        self.t = self.tablero("demo")

    def falso(self, argv, timeout):
        assert isinstance(argv, list), "ejecutar exige una lista (nunca shell)"
        self.llamadas.append((argv, timeout))
        if self.al_ejecutar:
            self.al_ejecutar(argv)
        verbo = argv[4] if len(argv) > 4 else None
        return (verbo not in self.fallan), ("error simulado" if verbo in self.fallan else "ok")

    def post(self, ruta, cuerpo):
        return self.client.post(f"/acciones/{ruta}", json=cuerpo)

    def argvs(self):
        return [a for a, _ in self.llamadas]

    def hash_db(self):
        return hashlib.sha256(Path(self.t.ruta).read_bytes()).hexdigest()


class TestAC2bValidacion(AccionesTest):
    def setUp(self):
        super().setUp()
        self.t.tarea("t_0a1", "PLAN algo", "blocked", block_kind="needs_input", assignee="orquestador")

    def test_rechaza_tableros_invalidos_o_inexistentes_sin_ejecutar_nada(self):
        for board in ["../x", "DEMO", "-demo", "demo;rm", "demo x", "", "no-existe", "default"]:
            for ruta in ("aprobar", "desatascar"):
                with self.subTest(board=board, ruta=ruta):
                    r = self.post(ruta, {"board": board, "task_id": "t_0a1"})
                    self.assertEqual(r.status_code, 400, r.text)
        self.assertEqual(self.llamadas, [])

    def test_rechaza_ids_invalidos_sin_ejecutar_nada(self):
        for tid in ["t_", "t_XYZ", "T_0a1", "t_0a1; rm -rf /", "t_0a1 --x", "0a1", "", "t_0a1\n"]:
            for ruta in ("aprobar", "desatascar"):
                with self.subTest(task_id=tid, ruta=ruta):
                    r = self.post(ruta, {"board": "demo", "task_id": tid})
                    self.assertEqual(r.status_code, 400, r.text)
        self.assertEqual(self.llamadas, [])

    def test_una_tarjeta_que_no_existe_da_404(self):
        self.assertEqual(self.post("aprobar", {"board": "demo", "task_id": "t_ffff"}).status_code, 404)
        self.assertEqual(self.llamadas, [])

    def test_faltan_campos_da_422(self):
        self.assertEqual(self.post("aprobar", {"board": "demo"}).status_code, 422)
        self.assertEqual(self.post("set-model", {"board": "demo", "task_id": "t_0a1", "modelo": "x"}).status_code, 422)
        self.assertEqual(self.llamadas, [])

    def test_ninguna_accion_escribe_en_sqlite(self):
        antes = self.hash_db()
        self.post("aprobar", {"board": "demo", "task_id": "t_0a1"})
        self.post("set-model", {"board": "demo", "task_id": "t_0a1", "modelo": "kimi-for-coding", "proveedor": "kimi-coding"})
        self.assertGreater(len(self.llamadas), 0)  # sí ejecutaron comandos…
        self.assertEqual(self.hash_db(), antes)  # …y el fichero del tablero no cambió


class TestAprobar(AccionesTest):
    def plan(self, tid="t_0a1", titulo="PLAN The Factory: plan", status="blocked", kind="needs_input"):
        self.t.tarea(tid, titulo, status, block_kind=kind, assignee="orquestador")
        return tid

    def test_aprueba_un_plan_bloqueado_needs_input_con_comentario_unblock_y_comentario_de_fabrica(self):
        tid = self.plan()
        r = self.post("aprobar", {"board": "demo", "task_id": tid})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertTrue(r.json()["ok"])
        self.assertEqual(
            self.llamadas,
            [
                (BASE + ["comment", tid, "adelante (desde The Factory)"], 30),
                (BASE + ["unblock", tid], 30),
                (BASE + ["comment", tid, "🏭 The Factory: aprobar"], 30),
            ],
        )

    def test_rechaza_lo_que_no_es_un_plan_bloqueado_needs_input(self):
        casos = {
            "no es PLAN": dict(titulo="IMPL-1 algo"),
            "PLAN pero ready": dict(status="ready"),
            "PLAN bloqueado por capability": dict(kind="capability"),
            "PLAN sin tipo de bloqueo": dict(kind=None),
            "PLANTILLA no es PLAN": dict(titulo="PLANTILLA nueva"),
            "PLAN hecho": dict(status="done"),
        }
        for nombre, kw in casos.items():
            with self.subTest(nombre):
                tid = f"t_{abs(hash(nombre)) % 10**8:08x}"
                self.plan(tid, **kw)
                r = self.post("aprobar", {"board": "demo", "task_id": tid})
                self.assertEqual(r.status_code, 409, r.text)
        self.assertEqual(self.llamadas, [])

    def test_si_unblock_falla_responde_ok_false_y_no_comenta_de_mas(self):
        tid = self.plan()
        self.fallan = {"unblock"}
        r = self.post("aprobar", {"board": "demo", "task_id": tid}).json()
        self.assertFalse(r["ok"])
        self.assertIn("unblock", r["salida"])
        self.assertIn("error simulado", r["salida"])
        self.assertEqual([a[4] for a in self.argvs()], ["comment", "unblock"])


class TestDesatascar(AccionesTest):
    def atascada(self, tid="t_0b1", assignee: str | None = "tester", status="review", error="429 usage limit"):
        self.t.tarea(tid, "Revisar", status, assignee=assignee, last_failure_error=error)
        return tid

    def limpia_el_error(self, tid):
        """Lo que hace el kernel al reasignar a otro perfil: borra last_failure_error."""
        def efecto(argv):
            if argv[4:6] == ["assign", tid] and argv[6] == "none":
                con = sqlite3.connect(self.t.ruta)
                con.execute("UPDATE tasks SET last_failure_error = NULL WHERE id = ?", (tid,))
                con.commit()
                con.close()
        self.al_ejecutar = efecto

    def test_asigna_a_none_y_devuelve_el_perfil_original_y_comenta(self):
        tid = self.atascada()
        self.limpia_el_error(tid)
        r = self.post("desatascar", {"board": "demo", "task_id": tid})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertTrue(r.json()["ok"])
        self.assertEqual(
            self.llamadas,
            [
                (BASE + ["assign", tid, "none"], 30),
                (BASE + ["assign", tid, "tester"], 30),
                (BASE + ["comment", tid, "🏭 The Factory: desatascar"], 30),
            ],
        )

    def test_si_last_failure_error_no_queda_vacio_dice_ok_false_con_el_motivo(self):
        tid = self.atascada()  # el kernel simulado no limpia el error
        r = self.post("desatascar", {"board": "demo", "task_id": tid}).json()
        self.assertFalse(r["ok"])
        self.assertIn("last_failure_error sigue", r["salida"])
        self.assertIn("429 usage limit", r["salida"])

    def test_si_falla_el_primer_assign_no_hace_nada_mas(self):
        tid = self.atascada()
        self.fallan = {"assign"}
        r = self.post("desatascar", {"board": "demo", "task_id": tid}).json()
        self.assertFalse(r["ok"])
        self.assertEqual(len(self.llamadas), 1)

    def test_si_falla_devolver_el_perfil_avisa_de_que_lo_compruebe(self):
        tid = self.atascada()
        self.fallan = set()
        self.al_ejecutar = lambda argv: self.fallan.add("assign") if len(self.llamadas) == 2 else None
        # el primer assign (none) va bien; el segundo (devolver el perfil) falla
        r = self.post("desatascar", {"board": "demo", "task_id": tid}).json()
        self.assertFalse(r["ok"])
        self.assertIn("conserve su perfil (tester)", r["salida"])
        self.assertEqual(len(self.llamadas), 2)

    def test_rechaza_tarjetas_sin_perfil_o_en_estados_que_no_se_desatascan(self):
        sin_perfil = self.atascada("t_0b2", assignee=None)
        corriendo = self.atascada("t_0b3", status="running")
        hecha = self.atascada("t_0b4", status="done")
        for tid in (sin_perfil, corriendo, hecha):
            with self.subTest(tid):
                self.assertEqual(self.post("desatascar", {"board": "demo", "task_id": tid}).status_code, 409)
        self.assertEqual(self.llamadas, [])

    def test_un_perfil_con_caracteres_raros_no_llega_al_argv(self):
        for n, perfil in enumerate(["--evil x", "--evil", "-x", ".oculto"]):
            with self.subTest(perfil=perfil):
                tid = self.atascada(f"t_0b{n + 5}", assignee=perfil)
                self.assertEqual(self.post("desatascar", {"board": "demo", "task_id": tid}).status_code, 409)
        self.assertEqual(self.llamadas, [])


class TestSetModel(AccionesTest):
    def setUp(self):
        super().setUp()
        self.t.tarea("t_0c1", "IMPL-1 algo", "ready", assignee="programador")

    def cuerpo(self, **kw):
        return {"board": "demo", "task_id": "t_0c1", "modelo": "claude-sonnet-5-5", "proveedor": "claude-subscription", **kw}

    def test_fija_el_modelo_con_su_proveedor_y_comenta(self):
        r = self.post("set-model", self.cuerpo())
        self.assertEqual(r.status_code, 200, r.text)
        self.assertTrue(r.json()["ok"])
        self.assertEqual(
            self.llamadas,
            [
                (BASE + ["set-model", "t_0c1", "claude-sonnet-5-5", "--provider", "claude-subscription"], 30),
                (BASE + ["comment", "t_0c1", "🏭 The Factory: set-model claude-subscription/claude-sonnet-5-5"], 30),
            ],
        )

    def test_acepta_los_modelos_de_roles_reservas_y_reparto(self):
        self.escribir_config(
            "  reparto:\n    rutas:\n      gemini: {proveedor: antigravity-oauth, modelo: gemini-3.8-flash-high}\n"
        )
        for prov, mod in [("kimi-coding", "kimi-for-coding"), ("antigravity-oauth", "gemini-3.8-flash-high")]:
            with self.subTest(mod):
                self.assertEqual(self.post("set-model", self.cuerpo(proveedor=prov, modelo=mod)).status_code, 200)

    def test_rechaza_pares_que_no_estan_configurados(self):
        for prov, mod in [
            ("claude-subscription", "claude-opus-9"),  # modelo ajeno
            ("otro-proveedor", "claude-sonnet-5-5"),  # proveedor ajeno
            ("kimi-coding", "claude-sonnet-5-5"),  # par cruzado
        ]:
            with self.subTest((prov, mod)):
                self.assertEqual(self.post("set-model", self.cuerpo(proveedor=prov, modelo=mod)).status_code, 400)
        self.assertEqual(self.llamadas, [])

    def test_rechaza_nombres_con_metacaracteres_u_opciones(self):
        for mod in ["--help", "x; rm -rf /", "a b", "$(id)", "x\n--provider y", ""]:
            with self.subTest(mod):
                self.assertEqual(self.post("set-model", self.cuerpo(modelo=mod)).status_code, 400)
        self.assertEqual(self.post("set-model", self.cuerpo(proveedor="-p")).status_code, 400)
        self.assertEqual(self.llamadas, [])

    def test_valida_tablero_y_tarjeta_como_las_demas(self):
        self.assertEqual(self.post("set-model", self.cuerpo(board="../x")).status_code, 400)
        self.assertEqual(self.post("set-model", self.cuerpo(task_id="t_zz")).status_code, 400)
        self.assertEqual(self.post("set-model", self.cuerpo(task_id="t_beef")).status_code, 404)
        self.assertEqual(self.llamadas, [])

    def test_sin_config_no_hay_modelos_permitidos(self):
        (self.tmp / "fabrik.yaml").write_text("modelos: {}\n", encoding="utf-8")
        self.assertEqual(self.post("set-model", self.cuerpo()).status_code, 400)

    def test_si_falla_set_model_responde_ok_false_sin_comentario(self):
        self.fallan = {"set-model"}
        r = self.post("set-model", self.cuerpo()).json()
        self.assertFalse(r["ok"])
        self.assertEqual(len(self.llamadas), 1)


class TestArgvYTimeout(AtascadasTest):
    """Todo comando va como lista de cadenas (nunca shell), empieza por `hermes kanban --board <slug>` y dura <= 30 s."""

    def test_timeout_de_30_s_y_argv_siempre_lista_de_cadenas(self):
        t = self.tablero("demo")
        t.tarea("t_0d1", "PLAN x", "blocked", block_kind="needs_input")
        with mock.patch.object(self.comun, "ejecutar", return_value=(True, "")) as ej:
            self.client.post("/acciones/aprobar", json={"board": "demo", "task_id": "t_0d1"})
        for llamada in ej.call_args_list:
            argv, timeout = llamada.args
            self.assertIsInstance(argv, list)
            self.assertTrue(all(isinstance(a, str) for a in argv))
            self.assertEqual(timeout, 30)
            self.assertEqual(argv[:4], BASE)
