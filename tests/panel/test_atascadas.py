"""AC-3b (Atascadas con motivo y acción) y AC-3c (Cadena): `GET /inicio/atascadas` y `GET /inicio/cadena`.

Un caso por motivo y sus falsos positivos. Reloj congelado (AHORA), foto de cupos y perfiles en un directorio
temporal, `gh` simulado: nada de red ni del Kanban real.
"""
import json
from unittest import mock

from tests.panel.test_atascadas_util import AHORA, MIN, AtascadasTest

GH_ABIERTO = {"state": "OPEN", "baseRefName": "main", "number": 7, "url": "https://github.com/o/r/pull/7"}


class TestAC3bErrorCupoRevision(AtascadasTest):
    def revision(self, t, tid="t_aaa1", error="429 Too Many Requests: usage limit", fin=-20 * MIN, assignee: str | None = "tester", **kw):
        t.tarea(tid, "Revisar algo", "review", assignee=assignee, last_failure_error=error, **kw)
        t.run(tid, AHORA + fin - 600, AHORA + fin, "review_requested")
        return tid

    def items(self):
        return self.get("/inicio/atascadas")["items"]

    def test_review_con_error_de_cupo_y_sin_run_reciente_ofrece_desatascar(self):
        t = self.tablero("demo")
        self.revision(t)
        self.assertEqual(
            self.items(),
            [{
                "board": "demo", "task_id": "t_aaa1", "titulo": "Revisar algo", "motivo": "error_cupo_revision",
                "detalle": "429 Too Many Requests: usage limit · sin run desde hace 20 min",
                "accion": {"tipo": "desatascar"},
            }],
        )

    def test_el_patron_no_distingue_mayusculas_y_acepta_las_variantes(self):
        t = self.tablero("demo")
        for i, error in enumerate(["Rate-Limit exceeded", "RATELIMIT", "Quota agotada", "cupo semanal", "Resource EXHAUSTED"]):
            self.revision(t, f"t_a{i}", error)
        self.assertEqual(len(self.items()), 5)

    def test_un_error_que_no_es_de_cupo_no_es_atasco(self):
        t = self.tablero("demo")
        self.revision(t, error="pytest: 3 failed")
        self.assertEqual(self.items(), [])

    def test_un_run_reciente_no_es_atasco(self):
        t = self.tablero("demo")
        self.revision(t, fin=-5 * MIN)
        self.assertEqual(self.items(), [])

    def test_con_un_run_activo_no_es_atasco(self):
        t = self.tablero("demo")
        self.revision(t)
        t.run("t_aaa1", AHORA - 30 * MIN)  # sin ended_at: sigue en marcha
        self.assertEqual(self.items(), [])

    def test_solo_las_tarjetas_en_review(self):
        t = self.tablero("demo")
        t.tarea("t_bbb1", "Lista", "ready", assignee="tester", last_failure_error="429")
        t.tarea("t_bbb2", "Hecha", "done", assignee="tester", last_failure_error="429")
        self.assertEqual(self.items(), [])

    def test_sin_perfil_asignado_se_muestra_sin_boton(self):
        t = self.tablero("demo")
        self.revision(t, assignee=None)
        (item,) = self.items()
        self.assertNotIn("accion", item)

    def test_recorre_todos_los_tableros_y_marca_el_de_cada_item(self):
        self.revision(self.tablero("default"), "t_d001")
        self.revision(self.tablero("otro"), "t_o001")
        self.assertEqual([(i["board"], i["task_id"]) for i in self.items()], [("default", "t_d001"), ("otro", "t_o001")])

    def test_incluye_el_worktree_si_la_tarjeta_lo_tiene(self):
        t = self.tablero("demo")
        self.revision(t, workspace_kind="dir", workspace_path="/x/.factory-worktrees/r/s")
        self.assertEqual(self.items()[0]["worktree"], "/x/.factory-worktrees/r/s")

    def test_sin_tableros_el_bloque_no_esta_disponible(self):
        self.assertEqual(self.get("/inicio/atascadas"), {"disponible": False, "motivo": "sin tableros de Kanban"})

    def test_un_tablero_ilegible_no_tumba_a_los_demas(self):
        self.revision(self.tablero("bueno"), "t_g001")
        malo = self.tmp / "home" / "kanban" / "boards" / "malo" / "kanban.db"
        malo.parent.mkdir(parents=True)
        malo.write_bytes(b"esto no es sqlite" * 100)
        self.assertEqual([i["task_id"] for i in self.items()], ["t_g001"])


class TestAC3bSinCupo(AtascadasTest):
    TODAS = {"kimi_5h": 100, "kimi_7d": 100, "gemini_5h": 100, "gemini_sem": 100, "claude_5h": 100, "claude_sem": 100}

    def limitada(self, t, tid="t_cup1", status="ready", outcome="rate_limited", **kw):
        t.tarea(tid, "IMPL-9 algo", status, assignee="programador", **kw)
        t.run(tid, AHORA - 600, AHORA - 300, outcome)

    def items(self):
        return self.get("/inicio/atascadas")["items"]

    def preparar(self, bolsas, **kw):
        t = self.tablero("demo")
        self.perfil()
        self.foto(bolsas)
        self.limitada(t, **kw)
        return t

    def test_cadena_agotada_propone_la_reserva_final_con_margen(self):
        self.preparar({**self.TODAS, "claude_5h": 40, "claude_sem": 60})
        (item,) = self.items()
        self.assertEqual(item["motivo"], "sin_cupo")
        self.assertEqual(item["accion"], {"tipo": "set_model", "proveedor": "claude-subscription", "modelo": "claude-sonnet-5-5"})
        self.assertIn("kimi_5h", item["detalle"])

    def test_un_modelo_de_la_cadena_entre_el_90_y_el_98_por_ciento_la_deja_lanzable(self):
        # gemini al 95 % (no agotado: el umbral de cupos.py es 98) → la cadena es lanzable → sin atasco.
        self.preparar({**self.TODAS, "gemini_5h": 95, "gemini_sem": 10, "claude_5h": 0})
        self.assertEqual(self.items(), [])

    def test_una_bolsa_al_90_por_ciento_no_vale_como_reserva(self):
        self.preparar({**self.TODAS, "claude_5h": 90, "claude_sem": 10})
        (item,) = self.items()
        self.assertNotIn("accion", item)

    def test_sin_modelo_con_margen_no_hay_boton_y_el_detalle_dice_cuando_renueva(self):
        self.preparar(self.TODAS)
        (item,) = self.items()
        self.assertNotIn("accion", item)
        self.assertRegex(item["detalle"], r"renueva \w+ 2027-")

    def test_una_bolsa_cuyo_reset_ya_paso_cuenta_como_renovada(self):
        self.perfil()
        self.foto(self.TODAS, reset_s=-60)  # todo al 100 % pero con el reset en el pasado → renovado
        self.limitada(self.tablero("demo"))
        self.assertEqual(self.items(), [])

    def test_un_modelo_fuera_de_los_configurados_no_se_propone(self):
        t = self.tablero("demo")
        self.perfil(cadena=(("kimi-coding", "kimi-for-coding"), ("openai-codex", "gpt-x")))
        self.foto({**self.TODAS, "openai_30d": 100, "claude_5h": 100})
        self.limitada(t)
        (item,) = self.items()
        self.assertNotIn("accion", item)  # gpt-x no está en la config: set-model lo rechazaría

    def test_si_el_ultimo_run_no_fue_rate_limited_no_es_atasco(self):
        self.preparar(self.TODAS, outcome="completed")
        self.assertEqual(self.items(), [])

    def test_solo_cuenta_el_ultimo_run(self):
        t = self.preparar(self.TODAS)
        t.run("t_cup1", AHORA - 100, AHORA - 50, "completed")  # un run posterior que acabó bien
        self.assertEqual(self.items(), [])

    def test_una_tarjeta_que_no_esta_en_ready_no_es_atasco(self):
        self.preparar(self.TODAS, status="running")
        self.assertEqual(self.items(), [])

    def test_sin_foto_de_cupos_no_se_acusa_a_nadie(self):
        t = self.tablero("demo")
        self.perfil()
        self.limitada(t)
        self.assertEqual(self.items(), [])

    def test_una_foto_vieja_tampoco(self):
        t = self.tablero("demo")
        self.perfil()
        self.foto(self.TODAS, antiguedad_s=3 * 3600)
        self.limitada(t)
        self.assertEqual(self.items(), [])


class TestAC3bEsperandoMerge(AtascadasTest):
    def gh(self, pr=GH_ABIERTO, defecto="main", lista=None, falla=False):
        """`comun.ejecutar` simulado: responde a `gh pr view`, `gh repo view` y `gh pr list`."""
        llamadas = []

        def falso(argv, timeout):
            llamadas.append((list(argv), timeout))
            if falla:
                return False, "gh: no autenticado"
            if argv[:3] == ["gh", "pr", "view"]:
                return True, json.dumps(pr)
            if argv[:3] == ["gh", "repo", "view"]:
                return True, json.dumps({"defaultBranchRef": {"name": defecto}})
            if argv[:3] == ["gh", "pr", "list"]:
                return True, json.dumps(lista if lista is not None else [])
            return False, "inesperado"

        parche = mock.patch.object(self.comun, "ejecutar", side_effect=falso)
        parche.start()
        self.addCleanup(parche.stop)
        return llamadas

    def tablero_pr(self, estado_padre="review", con_pr=True, extra_padre=None):
        t = self.tablero("demo")
        t.tarea("t_pr01", "PR-1 The Factory: página", estado_padre)
        t.run("t_pr01", AHORA - 900, AHORA - 600, "review_requested", {"published_pr": "https://github.com/o/r/pull/7"} if con_pr else {"otra": 1})
        t.tarea("t_hij1", "PR-2 The Factory: inicio", "todo")
        t.enlace("t_pr01", "t_hij1")
        if extra_padre:
            t.tarea("t_pad2", "CIERRE-2", extra_padre)
            t.enlace("t_pad2", "t_hij1")
        return t

    def items(self):
        return self.get("/inicio/atascadas")["items"]

    def test_todo_cuyo_unico_padre_pendiente_tiene_un_pr_abierto_ofrece_ver_prs(self):
        llamadas = self.gh()
        self.tablero_pr()
        (item,) = self.items()
        self.assertEqual(item["motivo"], "esperando_merge")
        self.assertEqual(item["task_id"], "t_hij1")
        self.assertEqual(item["accion"], {"tipo": "ver_prs", "prs": [{"numero": 7, "url": "https://github.com/o/r/pull/7"}]})
        self.assertIn("PR #7", item["detalle"])
        self.assertIn("PR-1", item["detalle"])
        vista = [c for c in llamadas if c[0][:3] == ["gh", "pr", "view"]][0]
        self.assertEqual(vista, (["gh", "pr", "view", "https://github.com/o/r/pull/7", "--json", "state,baseRefName,number,url"], 5))

    def test_un_pr_cuya_base_no_es_la_rama_por_defecto_va_apilado_sobre_el_pr_de_esa_base(self):
        self.gh(pr={**GH_ABIERTO, "baseRefName": "agente/the-factory"}, lista=[{"number": 5}])
        self.tablero_pr()
        (item,) = self.items()
        self.assertEqual(item["accion"]["prs"][0]["apilado_sobre"], "#5")
        self.assertIn("apilado sobre #5", item["detalle"])

    def test_apilado_sin_pr_para_esa_base_nombra_la_rama(self):
        self.gh(pr={**GH_ABIERTO, "baseRefName": "agente/the-factory"}, lista=[])
        self.tablero_pr()
        self.assertEqual(self.items()[0]["accion"]["prs"][0]["apilado_sobre"], "agente/the-factory")

    def test_la_rama_por_defecto_sale_de_gh_repo_view(self):
        self.gh(pr={**GH_ABIERTO, "baseRefName": "develop"}, defecto="develop")
        self.tablero_pr()
        self.assertNotIn("apilado_sobre", self.items()[0]["accion"]["prs"][0])

    def test_un_pr_mergeado_o_cerrado_no_es_espera(self):
        for estado in ("MERGED", "CLOSED"):
            with self.subTest(estado):
                self.gh(pr={**GH_ABIERTO, "state": estado})
                self.tablero_pr()
                self.assertEqual(self.items(), [])
                for t in self.tableros:
                    t.cerrar()
                self.tableros.clear()
                (self.tmp / "home" / "kanban" / "boards" / "demo" / "kanban.db").unlink()

    def test_si_gh_falla_no_se_acusa_a_la_tarjeta(self):
        self.gh(falla=True)
        self.tablero_pr()
        self.assertEqual(self.items(), [])

    @staticmethod
    def vistas(llamadas):
        return len([c for c in llamadas if c[0][:3] == ["gh", "pr", "view"]])

    def test_un_pr_abierto_se_reutiliza_60_s_sin_volver_a_llamar_a_gh(self):
        llamadas = self.gh(pr={**GH_ABIERTO, "baseRefName": "agente/the-factory"}, lista=[{"number": 5}])
        self.tablero_pr()
        for _ in range(3):  # refrescos cada 15 s dentro del minuto
            self.assertIn("apilado sobre #5", self.items()[0]["detalle"])
        self.assertEqual(self.vistas(llamadas), 1)
        self.assertEqual(len([c for c in llamadas if c[0][:3] == ["gh", "pr", "list"]]), 1)
        self.fx._ahora.return_value = AHORA + 61
        self.assertEqual(len(self.items()), 1)
        self.assertEqual(self.vistas(llamadas), 2)

    def test_un_pr_cerrado_se_recuerda_para_siempre(self):
        llamadas = self.gh(pr={**GH_ABIERTO, "state": "MERGED"})
        self.tablero_pr()
        self.assertEqual(self.items(), [])
        self.fx._ahora.return_value = AHORA + 86400
        self.assertEqual(self.items(), [])
        self.assertEqual(self.vistas(llamadas), 1)

    def test_si_gh_falla_no_se_recuerda_y_se_reintenta_en_el_siguiente_refresco(self):
        llamadas = self.gh(falla=True)
        self.tablero_pr()
        self.items()
        self.items()
        self.assertEqual(self.vistas(llamadas), 2)

    def test_con_otro_padre_sin_terminar_no_es_solo_el_merge(self):
        self.gh()
        self.tablero_pr(extra_padre="running")
        self.assertEqual(self.items(), [])

    def test_con_el_otro_padre_hecho_si_lo_es(self):
        self.gh()
        self.tablero_pr(extra_padre="done")
        self.assertEqual(len(self.items()), 1)

    def test_un_padre_pendiente_sin_pr_publicado_no_es_espera_de_merge(self):
        self.gh()
        self.tablero_pr(con_pr=False)
        self.assertEqual(self.items(), [])

    def test_un_pr_que_no_es_de_github_se_ignora_sin_llamar_a_gh(self):
        llamadas = self.gh()
        t = self.tablero_pr(con_pr=False)
        t.run("t_pr01", AHORA - 100, AHORA - 50, "review_requested", {"published_pr": "http://x; rm -rf /"})
        self.assertEqual(self.items(), [])
        self.assertEqual(llamadas, [])

    def test_solo_las_tarjetas_en_todo(self):
        self.gh()
        t = self.tablero_pr()
        t.con.execute("UPDATE tasks SET status = 'blocked' WHERE id = 't_hij1'")
        t.con.commit()
        self.assertEqual(self.items(), [])


class TestAC3cCadena(AtascadasTest):
    def cadenas(self):
        return self.get("/inicio/cadena")["cadenas"]

    def feature(self, t):
        t.tarea("t_base", "BASE The Factory: piezas", "done")
        t.tarea("t_im2", "IMPL-2 The Factory: tablero", "running", started_at=AHORA - 12 * MIN)
        t.tarea("t_im3", "IMPL-3 The Factory: atascadas", "running", started_at=AHORA - 90 * MIN, workspace_kind="dir", workspace_path="/w/.factory-worktrees/r/a")
        t.tarea("t_cie", "CIERRE-2 The Factory: juntar · ⏳ tras IMPL-2, IMPL-3", "todo")
        t.tarea("t_pr2", "PR-2 The Factory: Inicio", "todo")
        for p, h in [("t_base", "t_im2"), ("t_base", "t_im3"), ("t_im2", "t_cie"), ("t_im3", "t_cie"), ("t_cie", "t_pr2")]:
            t.enlace(p, h)

    def test_componente_conexo_de_las_tarjetas_en_marcha_sin_duplicar(self):
        t = self.tablero("demo")
        self.feature(t)
        (c,) = self.cadenas()  # IMPL-2 e IMPL-3 comparten componente: una sola cadena
        self.assertEqual((c["board"], c["titulo"], c["hechas"], c["total"]), ("demo", "The Factory", 1, 5))
        self.assertEqual(
            c["nodos"],
            [
                {"task_id": "t_base", "etiqueta": "BASE", "estado": "hecho"},
                {"task_id": "t_cie", "etiqueta": "CIERRE-2", "estado": "pendiente"},
                {"task_id": "t_im2", "etiqueta": "IMPL-2", "estado": "en_marcha", "minutos": 12},
                {"task_id": "t_im3", "etiqueta": "IMPL-3", "estado": "en_marcha", "minutos": 90, "worktree": "/w/.factory-worktrees/r/a"},
                {"task_id": "t_pr2", "etiqueta": "PR-2", "estado": "pendiente"},
            ],
        )
        self.assertEqual(
            sorted(c["aristas"]),
            [["t_base", "t_im2"], ["t_base", "t_im3"], ["t_cie", "t_pr2"], ["t_im2", "t_cie"], ["t_im3", "t_cie"]],
        )

    def test_la_etiqueta_quita_el_texto_del_vigilante(self):
        t = self.tablero("demo")
        t.tarea("t_a", "IMPL-2 X: a", "running", started_at=AHORA)
        t.tarea("t_b", "PR-2 · ⏳ tras IMPL-2", "todo")
        t.enlace("t_a", "t_b")
        self.assertEqual([n["etiqueta"] for n in self.cadenas()[0]["nodos"]], ["IMPL-2", "PR-2"])

    def test_componentes_distintos_son_cadenas_distintas(self):
        t = self.tablero("demo")
        for i in ("a", "b"):
            t.tarea(f"t_{i}1", f"IMPL-1 Feat{i}: x", "running", started_at=AHORA)
            t.tarea(f"t_{i}2", f"PR-1 Feat{i}: y", "todo")
            t.enlace(f"t_{i}1", f"t_{i}2")
        self.assertEqual([c["titulo"] for c in self.cadenas()], ["Feata", "Featb"])

    def test_una_tarjeta_suelta_en_marcha_no_forma_cadena(self):
        t = self.tablero("demo")
        t.tarea("t_solo", "FIX-1 algo", "running", started_at=AHORA)
        self.assertEqual(self.cadenas(), [])

    def test_sin_tarjetas_en_marcha_no_hay_cadenas(self):
        t = self.tablero("demo")
        t.tarea("t_a", "IMPL-2 X: a", "done")
        t.tarea("t_b", "PR-2 X: b", "todo")
        t.enlace("t_a", "t_b")
        self.assertEqual(self.cadenas(), [])

    def test_las_archivadas_no_cuentan_ni_unen_componentes(self):
        t = self.tablero("demo")
        t.tarea("t_vieja", "IMPL-0 Otra: vieja", "archived")
        t.tarea("t_a", "IMPL-2 X: a", "running", started_at=AHORA)
        t.tarea("t_b", "PR-2 X: b", "todo")
        t.enlace("t_vieja", "t_a")
        t.enlace("t_a", "t_b")
        (c,) = self.cadenas()
        self.assertEqual(sorted(n["task_id"] for n in c["nodos"]), ["t_a", "t_b"])

    def test_cada_tablero_va_por_separado(self):
        for slug in ("uno", "dos"):
            t = self.tablero(slug)
            t.tarea("t_a", "IMPL-2 X: a", "running", started_at=AHORA)
            t.tarea("t_b", "PR-2 X: b", "todo")
            t.enlace("t_a", "t_b")
        self.assertEqual([c["board"] for c in self.cadenas()], ["dos", "uno"])  # tableros por nombre

    def test_sin_tableros_el_bloque_no_esta_disponible(self):
        self.assertEqual(self.get("/inicio/cadena")["disponible"], False)
