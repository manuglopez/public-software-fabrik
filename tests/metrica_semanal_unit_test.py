#!/usr/bin/env python3
"""Tests unitarios de scripts/metrica_semanal.py (AC-3, AC-3b).

Todo con BD temporales, reloj fijo (`AHORA`) y un `gh` falso en forma de script: sin red, sin ~/.hermes.
"""
import io
import json
import os
import sqlite3
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_DIR / "scripts"))

import metrica_semanal as ms  # noqa: E402

AHORA = 1_800_000_000.0
DIA = 86400


def crear_tablero(ruta, tasks=(), runs=(), esquema_completo=True):
    Path(ruta).parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(ruta)
    c.execute("CREATE TABLE tasks (id TEXT PRIMARY KEY, status TEXT, completed_at INTEGER, branch_name TEXT)")
    c.execute("CREATE TABLE task_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT, profile TEXT,"
              " started_at INTEGER, outcome TEXT, metadata TEXT)")
    c.executemany("INSERT INTO tasks VALUES (?,?,?,?)", tasks)
    c.executemany("INSERT INTO task_runs (task_id, profile, started_at, outcome, metadata) VALUES (?,?,?,?,?)", runs)
    c.commit()
    c.close()


def crear_state(ruta, sesiones):
    """sesiones: (id, source, started_at, in, cw, cr, out, primer_mensaje_user|None)."""
    Path(ruta).parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(ruta)
    c.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, started_at REAL, input_tokens INTEGER,"
              " cache_write_tokens INTEGER, cache_read_tokens INTEGER, output_tokens INTEGER)")
    c.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT)")
    for sid, source, ts, i, cw, cr, o, msg in sesiones:
        c.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,?)", (sid, source, ts, i, cw, cr, o))
        if msg is not None:
            c.execute("INSERT INTO messages (session_id, role, content) VALUES (?, 'system', 'sistema t_00000000')", (sid,))
            c.execute("INSERT INTO messages (session_id, role, content) VALUES (?, 'user', ?)", (sid, msg))
            c.execute("INSERT INTO messages (session_id, role, content) VALUES (?, 'user', 'kanban task t_ffffffff')", (sid,))
    c.commit()
    c.close()


def gh_falso(directorio, cuerpo):
    """Escribe un ejecutable `gh` con el cuerpo bash dado y devuelve su ruta."""
    d = Path(tempfile.mkdtemp(dir=directorio))   # un directorio por falso: no se pisan entre sí
    ruta = d / "gh"
    ruta.write_text("#!/usr/bin/env bash\n" + cuerpo + "\n")
    ruta.chmod(ruta.stat().st_mode | stat.S_IXUSR)
    return str(ruta)


def iso_utc(epoch):
    from datetime import datetime, timezone
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class TestCosteEq(unittest.TestCase):
    def test_pesos_y_nulos(self):  # AC-3
        self.assertEqual(ms.PESOS, {"input_tokens": 1.0, "cache_write_tokens": 1.0,
                                    "cache_read_tokens": 0.1, "output_tokens": 5.0})
        # 1000 + 2000 + 0,1·10000 + 5·100 = 4500
        self.assertEqual(ms.coste_eq(1000, 2000, 10000, 100), 4500.0)
        # Uno a uno: cada peso se aplica a su columna
        self.assertEqual(ms.coste_eq(1, 0, 0, 0), 1.0)
        self.assertEqual(ms.coste_eq(0, 1, 0, 0), 1.0)
        self.assertEqual(ms.coste_eq(0, 0, 10, 0), 1.0)
        self.assertEqual(ms.coste_eq(0, 0, 0, 1), 5.0)
        # Nulos = 0
        self.assertEqual(ms.coste_eq(None, None, None, None), 0)
        self.assertEqual(ms.coste_eq(3000, None, None, 200), 4000.0)

    def test_dividir(self):  # AC-3: división por cero → None
        self.assertIsNone(ms.dividir(5, 0))
        self.assertEqual(ms.dividir(6, 4), 1.5)
        self.assertEqual(ms.dividir(0, 4), 0.0)


class TestTarjeta(unittest.TestCase):
    def test_primera_tarjeta_tras_kanban_task(self):  # AC-3
        self.assertEqual(ms.tarjeta_de_mensaje("# Kanban task t_0123abcd: título"), "t_0123abcd")
        self.assertEqual(ms.tarjeta_de_mensaje("ver t_11111111 y luego kanban task t_aaaaaaa1 y kanban task t_bbbbbbb2"),
                         "t_aaaaaaa1")
        self.assertEqual(ms.tarjeta_de_mensaje("work kanban task t_deadbeef"), "t_deadbeef")

    def test_sin_tarjeta(self):  # AC-3
        self.assertIsNone(ms.tarjeta_de_mensaje(None))
        self.assertIsNone(ms.tarjeta_de_mensaje(""))
        self.assertIsNone(ms.tarjeta_de_mensaje("hola t_aaaaaaa1"))  # sin «kanban task »
        self.assertIsNone(ms.tarjeta_de_mensaje("kanban task t_xyz"))  # id mal formado
        self.assertIsNone(ms.tarjeta_de_mensaje("kanban task t_aaaaaaa"))  # 7 hex: no vale


class TestLeer(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))

    def test_leer_sesiones_ventana_y_atribucion(self):  # AC-3, AC-3b
        db = os.path.join(self.tmp, "state.db")
        d, h = AHORA - 7 * DIA, AHORA
        crear_state(db, [
            ("dentro", "kanban", AHORA - DIA, 1000, 2000, 10000, 100, "# Kanban task t_aaaaaaa1: x"),
            ("borde_d", "kanban", d, 1, 0, 0, 0, "kanban task t_aaaaaaa1"),         # started_at == desde: dentro
            ("borde_h", "kanban", h, 1, 0, 0, 0, "kanban task t_aaaaaaa1"),         # started_at == hasta: dentro
            ("fuera_d", "kanban", d - 1, 99, 0, 0, 0, "kanban task t_aaaaaaa1"),    # un segundo antes: fuera
            ("fuera_h", "kanban", h + 1, 99, 0, 0, 0, "kanban task t_aaaaaaa1"),    # después de ahora: fuera
            ("otra_fuente", "cli", AHORA - DIA, 99, 0, 0, 0, "kanban task t_aaaaaaa1"),
            ("sin_msgs", "kanban", AHORA - DIA, 5, 0, 0, 0, None),
            ("sin_tarjeta", "kanban", AHORA - DIA, 7, 0, 0, 0, "hola"),
        ])
        res = {s["id"]: s for s in ms.leer_sesiones(db, d, h)}
        self.assertEqual(sorted(res), ["borde_d", "borde_h", "dentro", "sin_msgs", "sin_tarjeta"])
        self.assertEqual(res["dentro"], {"id": "dentro", "coste": 4500.0, "tarjeta": "t_aaaaaaa1"})
        self.assertEqual(res["borde_d"]["coste"], 1.0)
        self.assertEqual(res["sin_msgs"]["tarjeta"], None)   # primer mensaje user ausente → sin tarjeta
        self.assertEqual(res["sin_tarjeta"], {"id": "sin_tarjeta", "coste": 7.0, "tarjeta": None})

    def test_primer_mensaje_user_manda(self):  # AC-3: solo el primero; el system se ignora
        db = os.path.join(self.tmp, "state.db")
        crear_state(db, [("s", "kanban", AHORA, 1, 0, 0, 0, "kanban task t_aaaaaaa1")])  # añade user t_ffffffff después
        self.assertEqual(ms.leer_sesiones(db, AHORA - 1, AHORA + 1)[0]["tarjeta"], "t_aaaaaaa1")

    def test_bd_ilegible_lanza_sqlite_error(self):  # AC-3: el que llama avisa y sigue
        roto = os.path.join(self.tmp, "roto.db")
        Path(roto).write_text("esto no es sqlite" * 50)
        with self.assertRaises(sqlite3.Error):
            ms.leer_sesiones(roto, 0, 1)
        with self.assertRaises(sqlite3.Error):
            ms.leer_tablero(roto)
        with self.assertRaises(sqlite3.Error):  # no existe: mode=ro no la crea
            ms.leer_sesiones(os.path.join(self.tmp, "no_existe.db"), 0, 1)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "no_existe.db")))

    def test_leer_tablero(self):  # AC-3
        db = os.path.join(self.tmp, "t", "kanban.db")
        crear_tablero(db, [("t_aaaaaaa1", "done", 5, "agente/uno")], [("t_aaaaaaa1", "tester", 3, "completed", "{}")])
        self.assertEqual(ms.leer_tablero(db), {"tasks": [("t_aaaaaaa1", "done", 5, "agente/uno")],
                                               "runs": [("t_aaaaaaa1", "tester", 3, "completed", "{}")]})

    def test_registro_greptile(self):  # AC-3
        reg = os.path.join(self.tmp, "g.jsonl")
        Path(reg).write_text("\n".join([
            json.dumps({"repo": "acme/app", "rama": "r1", "evento": "ejecutado"}),
            json.dumps({"repo": "acme/app", "rama": "r1", "evento": "cache"}),
            json.dumps({"repo": "acme/app", "rama": "r1", "evento": "tope"}),
            json.dumps({"repo": "acme/app", "rama": "r1", "evento": "sucio"}),
            "{línea rota", "", "[1, 2]", "42",
            json.dumps({"repo": "acme/app", "rama": "r2", "evento": "ejecutado"}),
        ]))
        self.assertEqual([(g["rama"]) for g in ms.leer_registro_greptile(reg)], ["r1", "r2"])
        self.assertEqual(ms.leer_registro_greptile(os.path.join(self.tmp, "no_existe.jsonl")), [])

    def test_urls_pr(self):  # AC-3
        def meta(d):
            return json.dumps(d)
        runs = [
            ("t1", "p", 1, "completed", meta({"published_pr": "https://github.com/acme/app/pull/1"})),
            ("t1", "p", 1, "completed", meta({"published_pr": "https://github.com/acme/app/pull/1"})),  # repetida
            ("t1", "p", 1, "completed", meta({"published_pr": "https://github.com/acme/app/pull/2"})),
            ("t1", "p", 1, "review_requested", meta({"published_pr": "https://github.com/acme/app/pull/3"})),
            ("t1", "p", 1, "completed", "no es json"),
            ("t1", "p", 1, "completed", meta({"otra": 1})),
            ("t1", "p", 1, "completed", meta(["lista"])),
            ("t1", "p", 1, "completed", meta({"published_pr": ""})),
            ("t1", "p", 1, "completed", meta({"published_pr": 7})),
            ("t1", "p", 1, "completed", None),
            ("t1", "p", 1, "completed", ""),
        ]
        self.assertEqual(ms.urls_pr(runs), ["https://github.com/acme/app/pull/1", "https://github.com/acme/app/pull/2"])


class TestGh(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))

    def llamar(self, fn, *a, **k):
        err = io.StringIO()
        with redirect_stderr(err):
            r = fn(*a, **k)
        return r, err.getvalue()

    def test_ejecutar_gh_ok(self):  # AC-3
        gh = gh_falso(self.tmp, "echo '{\"a\": 1}'")
        r, err = self.llamar(ms.ejecutar_gh, gh, ["pr", "view", "x"])
        self.assertEqual(r, {"a": 1})
        self.assertEqual(err, "")

    def test_ejecutar_gh_rc_distinto_de_cero(self):  # AC-3
        gh = gh_falso(self.tmp, "echo '{\"a\": 1}'; exit 3")
        r, err = self.llamar(ms.ejecutar_gh, gh, ["pr", "view", "x"])
        self.assertIsNone(r)
        self.assertIn("salió con 3", err)

    def test_ejecutar_gh_json_roto(self):  # AC-3
        gh = gh_falso(self.tmp, "echo 'no json'")
        r, err = self.llamar(ms.ejecutar_gh, gh, ["pr", "view", "x"])
        self.assertIsNone(r)
        self.assertIn("no es JSON", err)

    def test_ejecutar_gh_timeout(self):  # AC-3
        gh = gh_falso(self.tmp, "sleep 5")
        r, err = self.llamar(ms.ejecutar_gh, gh, ["pr", "view", "x"], timeout=0.2)
        self.assertIsNone(r)
        self.assertIn("TimeoutExpired", err)

    def test_ejecutar_gh_inexistente(self):  # AC-3
        r, err = self.llamar(ms.ejecutar_gh, os.path.join(self.tmp, "no-existe"), ["pr", "view", "x"])
        self.assertIsNone(r)
        self.assertIn("aviso:", err)

    def test_epoch_iso(self):  # AC-3
        self.assertEqual(ms.epoch_iso("2026-10-25T10:00:00Z"), 1792922400.0)
        self.assertIsNone(ms.epoch_iso("ayer"))
        self.assertIsNone(ms.epoch_iso(None))

    def cuerpo_gh(self, view, reviews):
        return ("case \"$1\" in\n  pr) echo '%s' ;;\n  api) echo '%s'; echo \"$2\" >> \"%s/api.log\" ;;\nesac"
                % (view, reviews, self.tmp))

    def test_consultar_pr_mergeado(self):  # AC-3
        view = json.dumps({"additions": 100, "deletions": 20, "mergedAt": "2026-10-25T10:00:00Z", "headRefName": "agente/uno"})
        reviews = json.dumps([{"user": {"login": "greptile-apps[bot]"}}, {"user": {"login": "greptile-apps[bot]"}},
                              {"user": {"login": "otra-persona"}}, {"user": None}, "basura", {"sin": "user"}])
        gh = gh_falso(self.tmp, self.cuerpo_gh(view, reviews))
        pr, err = self.llamar(ms.consultar_pr, "https://github.com/acme/app/pull/12", gh)
        self.assertEqual(pr, {"owner": "acme", "repo": "app", "additions": 100, "deletions": 20,
                              "merged_at": 1792922400.0, "rama": "agente/uno", "github": 2})
        self.assertEqual(Path(self.tmp, "api.log").read_text().strip(), "repos/acme/app/pulls/12/reviews")
        self.assertEqual(err, "")

    def test_consultar_pr_sin_mergear_no_pide_reviews(self):  # AC-3
        view = json.dumps({"additions": 1, "deletions": 2, "mergedAt": None, "headRefName": "r"})
        gh = gh_falso(self.tmp, self.cuerpo_gh(view, "[]"))
        pr, _ = self.llamar(ms.consultar_pr, "https://github.com/acme/app/pull/4", gh)
        self.assertIsNone(pr["merged_at"])
        self.assertFalse(Path(self.tmp, "api.log").exists())

    def test_consultar_pr_errores(self):  # AC-3: cada rama de error avisa y devuelve None
        ok_view = json.dumps({"additions": 1, "deletions": 2, "mergedAt": "2026-10-25T10:00:00Z", "headRefName": "r"})
        url = "https://github.com/acme/app/pull/4"
        casos = {
            "url": (gh_falso(self.tmp, "exit 1"), "https://ejemplo.invalid/nada", "no reconocida"),
            "view falla": (gh_falso(self.tmp, "exit 1"), url, "salió con 1"),
            "sin additions": (gh_falso(self.tmp, "echo '{\"deletions\": 1}'"), url, "sin additions/deletions"),
            "sin deletions": (gh_falso(self.tmp, "echo '{\"additions\": 1}'"), url, "sin additions/deletions"),
            "no es objeto": (gh_falso(self.tmp, "echo '[1]'"), url, "sin additions/deletions"),
            "mergedAt ilegible": (gh_falso(self.tmp, "echo '{\"additions\":1,\"deletions\":1,\"mergedAt\":\"ayer\"}'"),
                                  url, "ilegible"),
            "reviews falla": (gh_falso(self.tmp, "case \"$1\" in pr) echo '%s';; *) exit 1;; esac" % ok_view),
                              url, "salió con 1"),
            "reviews no es lista": (gh_falso(self.tmp, "case \"$1\" in pr) echo '%s';; *) echo '{}';; esac" % ok_view),
                                    url, "no es una lista"),
        }
        for nombre, (gh, u, esperado) in casos.items():
            with self.subTest(nombre):
                pr, err = self.llamar(ms.consultar_pr, u, gh)
                self.assertIsNone(pr)
                self.assertIn(esperado, err)

    def test_prs_en_ventana_limites_y_cache(self):  # AC-3, AC-3b
        d, h = AHORA - 7 * DIA, AHORA
        meta = {
            "https://github.com/acme/app/pull/1": h,          # justo ahora: dentro
            "https://github.com/acme/app/pull/2": d,          # justo desde: dentro
            "https://github.com/acme/app/pull/3": d - 1,      # un segundo antes: fuera
            "https://github.com/acme/app/pull/4": h + 1,      # un segundo después: fuera
            "https://github.com/acme/app/pull/5": None,       # sin mergear
        }
        ficheros = {}
        for url, merged in meta.items():
            n = url.rsplit("/", 1)[1]
            ficheros[n] = json.dumps({"additions": int(n), "deletions": 0, "headRefName": "r" + n,
                                      "mergedAt": None if merged is None else iso_utc(merged)})
        cuerpo = "\n".join("[ \"$3\" = \"%s\" ] && { echo '%s'; exit 0; }" % (u, ficheros[u.rsplit('/', 1)[1]])
                           for u in meta) + "\necho '[]'"
        gh = gh_falso(self.tmp, cuerpo)
        cache = {}
        prs, _ = self.llamar(ms.prs_en_ventana, list(meta), gh, d, h, cache)
        self.assertEqual([p["additions"] for p in prs], [1, 2])
        self.assertEqual(sorted(cache), sorted(meta))   # se guardan también los que no cuentan
        # Con la caché llena no se vuelve a llamar a gh (el falso nuevo falla si se le llama)
        gh2 = gh_falso(self.tmp, "echo LLAMADO >> \"%s/llamado\"; exit 1" % self.tmp)
        prs2, err = self.llamar(ms.prs_en_ventana, list(meta), gh2, d, h, cache)
        self.assertEqual([p["additions"] for p in prs2], [1, 2])
        self.assertFalse(Path(self.tmp, "llamado").exists())
        self.assertEqual(err, "")


def tablero(tasks=(), runs=()):
    return {"tasks": list(tasks), "runs": list(runs)}


class TestAgregar(unittest.TestCase):
    D, H = AHORA - 7 * DIA, AHORA

    def test_tablero_sin_actividad_no_sale(self):  # AC-3
        t = tablero([("t1", "done", self.D - 1, "r1"), ("t2", "todo", None, "r2")], [("t1", "p", self.D - 1, "completed", None)])
        self.assertIsNone(ms.agregar_tablero(t, None, self.D, self.H))
        self.assertIsNone(ms.agregar_tablero(t, {"coste": 0.0, "sesiones": 0}, self.D, self.H))

    def test_solo_sesion_basta_y_divisiones_por_cero(self):  # AC-3
        t = tablero([("t1", "todo", None, "r1")])
        r = ms.agregar_tablero(t, {"coste": 2000.0, "sesiones": 1}, self.D, self.H, prs=[])
        self.assertEqual(r, {
            "terminadas": 0, "coste_eq": 2000.0, "coste_por_tarjeta": None, "runs": 0, "rate_limited": 0,
            "pct_rate_limited": None, "rondas_por_tarjeta": None, "rondas_por_perfil": {},
            "prs_mergeados": 0, "lineas_pr": 0, "coste_por_linea": None,
            "greptile_local": 0, "greptile_github": 0, "greptile_por_pr": None})

    def test_solo_run_basta(self):  # AC-3
        t = tablero([("t1", "todo", None, "r1")], [("t1", "p", self.D, "rate_limited", None)])
        r = ms.agregar_tablero(t, None, self.D, self.H, prs=[])
        self.assertEqual((r["runs"], r["rate_limited"], r["pct_rate_limited"], r["coste_eq"]), (1, 1, 100.0, 0.0))

    def test_solo_terminada_basta(self):  # AC-3
        t = tablero([("t1", "done", self.H, "r1")])
        r = ms.agregar_tablero(t, None, self.D, self.H, prs=[])
        self.assertEqual((r["terminadas"], r["coste_por_tarjeta"], r["runs"]), (1, 0.0, 0))

    def test_terminadas_ventana_y_estado(self):  # AC-3: done + completed_at en [desde, hasta]
        t = tablero([
            ("t1", "done", self.D, "a"), ("t2", "done", self.H, "b"),            # límites: dentro
            ("t3", "done", self.D - 1, "c"), ("t4", "done", self.H + 1, "d"),    # fuera
            ("t5", "done", None, "e"), ("t6", "archived", self.D + 5, "f"),      # sin fecha / otro estado
            ("t7", "running", self.D + 5, "g"),
        ])
        r = ms.agregar_tablero(t, {"coste": 10.0, "sesiones": 1}, self.D, self.H, prs=[])
        self.assertEqual(r["terminadas"], 2)
        self.assertEqual(r["coste_por_tarjeta"], 5.0)

    def test_runs_ventana_y_rate_limited(self):  # AC-3: límites de started_at y % con 1 decimal
        runs = [("t1", "p", self.D, "rate_limited", None), ("t1", "p", self.H, "completed", None),
                ("t1", "p", self.D - 1, "rate_limited", None), ("t1", "p", self.H + 1, "rate_limited", None),
                ("t1", "p", self.D + 1, "crashed", None)]
        t = tablero([("t1", "todo", None, "r1")], runs)
        r = ms.agregar_tablero(t, None, self.D, self.H, prs=[])
        self.assertEqual((r["runs"], r["rate_limited"], r["pct_rate_limited"]), (3, 1, 33.3))
        runs2 = [("t1", "p", self.D, "rate_limited", None)] * 2 + [("t1", "p", self.D, "completed", None)] * 11
        r2 = ms.agregar_tablero(tablero([("t1", "todo", None, "r")], runs2), None, self.D, self.H, prs=[])
        self.assertEqual(r2["pct_rate_limited"], 15.4)   # 2/13 = 15,384…

    def test_rondas(self):  # AC-3
        inicio = self.D + 10
        runs = [
            ("t1", "tester", inicio, "changes_requested", None), ("t1", "tester", inicio, "changes_requested", None),
            ("t1", "revisor", inicio, "changes_requested", None), ("t1", None, inicio, "changes_requested", None),
            ("t1", "p", inicio, "review_requested", None), ("t1", "p", inicio, "review_requested", None),
            ("t2", "p", inicio, "review_requested", None),
            ("t3", "p", inicio, "completed", None),                       # terminada sin review_requested
            ("t4", "tester", inicio, "changes_requested", None),          # t4 no está terminada: no cuenta
            ("t1", "tester", self.D - 100, "changes_requested", None),    # run antigua de una tarjeta terminada: cuenta
        ]
        t = tablero([("t1", "done", inicio, "a"), ("t2", "done", inicio, "b"), ("t3", "done", inicio, "c"),
                     ("t4", "running", None, "d")], runs)
        r = ms.agregar_tablero(t, None, self.D, self.H, prs=[])
        # 5 changes_requested de t1 / 2 tarjetas terminadas con review_requested (t1, t2)
        self.assertEqual(r["rondas_por_tarjeta"], 2.5)
        self.assertEqual(r["rondas_por_perfil"], {"(sin perfil)": 1, "revisor": 1, "tester": 3})

    def test_rondas_cero_con_review(self):  # AC-3: 0 changes / 1 con review = 0.0 (no None)
        t = tablero([("t1", "done", self.H, "a")], [("t1", "p", self.H, "review_requested", None)])
        self.assertEqual(ms.agregar_tablero(t, None, self.D, self.H, prs=[])["rondas_por_tarjeta"], 0.0)

    def test_rondas_sin_review_es_null(self):  # AC-3
        t = tablero([("t1", "done", self.H, "a")], [("t1", "tester", self.H, "changes_requested", None)])
        r = ms.agregar_tablero(t, None, self.D, self.H, prs=[])
        self.assertIsNone(r["rondas_por_tarjeta"])
        self.assertEqual(r["rondas_por_perfil"], {"tester": 1})

    def test_prs_y_greptile(self):  # AC-3
        prs = [{"owner": "acme", "repo": "app", "additions": 100, "deletions": 20, "merged_at": self.H, "rama": "r1", "github": 2},
               {"owner": "acme", "repo": "app", "additions": 30, "deletions": 10, "merged_at": self.H, "rama": "r2", "github": 1},
               {"owner": "acme", "repo": "app", "additions": 0, "deletions": 0, "merged_at": self.H, "rama": None, "github": 0}]
        greptile = [{"repo": "acme/app", "rama": "r1", "evento": "ejecutado"},
                    {"repo": "acme/otro", "rama": "r1", "evento": "ejecutado"},   # otro repo: no cuenta
                    {"repo": "acme/app", "rama": "r2", "evento": "ejecutado"},
                    {"repo": "acme/app", "rama": "r2", "evento": "ejecutado"},
                    {"repo": "acme/app", "rama": "r9", "evento": "ejecutado"},    # rama sin PR: no cuenta
                    {"repo": "acme/app", "evento": "ejecutado"}]                  # sin rama: no casa con la rama None
        t = tablero([("t1", "done", self.H, "r1")])
        r = ms.agregar_tablero(t, {"coste": 3200.0, "sesiones": 1}, self.D, self.H, prs, greptile)
        self.assertEqual((r["prs_mergeados"], r["lineas_pr"], r["coste_por_linea"]), (3, 160, 20.0))
        self.assertEqual((r["greptile_local"], r["greptile_github"], r["greptile_por_pr"]), (3, 3, 2.0))

    def test_sin_gh_cuenta_ramas_del_tablero(self):  # AC-3b
        t = tablero([("t1", "done", self.H, "r1"), ("t2", "todo", None, "r2"), ("t3", "todo", None, None)])
        greptile = [{"repo": "acme/app", "rama": "r1", "evento": "ejecutado"},
                    {"repo": "acme/otro", "rama": "r2", "evento": "ejecutado"},   # el repo no se filtra con --sin-gh
                    {"repo": "acme/app", "rama": "r9", "evento": "ejecutado"},
                    {"repo": "acme/app", "evento": "ejecutado"}]
        r = ms.agregar_tablero(t, None, self.D, self.H, None, greptile)
        self.assertEqual(r["greptile_local"], 2)
        for k in ("prs_mergeados", "lineas_pr", "coste_por_linea", "greptile_github", "greptile_por_pr"):
            self.assertIsNone(r[k], k)

    def test_atribuir(self):  # AC-3
        tableros = {"b": tablero([("t_b", "todo", None, None)]), "a": tablero([("t_a", "todo", None, None), ("t_dup", "todo", None, None)]),
                    "c": tablero([("t_dup", "todo", None, None)])}
        ses = [{"id": "1", "coste": 10.0, "tarjeta": "t_a"}, {"id": "2", "coste": 5.0, "tarjeta": "t_a"},
               {"id": "3", "coste": 7.0, "tarjeta": "t_b"}, {"id": "4", "coste": 100.0, "tarjeta": None},
               {"id": "5", "coste": 1.0, "tarjeta": "t_desconocida"}, {"id": "6", "coste": 2.0, "tarjeta": "t_dup"}]
        por, sin = ms.atribuir(ses, tableros)
        self.assertEqual(por, {"a": {"coste": 17.0, "sesiones": 3}, "b": {"coste": 7.0, "sesiones": 1}})  # t_dup → «a» (orden alfabético)
        self.assertEqual(sin, 101.0)


class TestFormato(unittest.TestCase):
    def test_tabla_valores_y_nulos(self):  # AC-3
        informe = {"desde": "D", "hasta": "H", "sin_tablero": {"coste_eq": 200000.0}, "tableros": {
            "tablero1": {"terminadas": 2, "coste_eq": 7000000.0, "coste_por_tarjeta": 3500000.0, "runs": 13, "rate_limited": 2,
                         "pct_rate_limited": 15.4, "rondas_por_tarjeta": 1.5, "rondas_por_perfil": {"tester": 2},
                         "prs_mergeados": 2, "lineas_pr": 160, "coste_por_linea": 43750.0, "greptile_local": 3,
                         "greptile_github": 3, "greptile_por_pr": 3.0},
            "tablero3": {"terminadas": 0, "coste_eq": 2000000.0, "coste_por_tarjeta": None, "runs": 0, "rate_limited": 0,
                         "pct_rate_limited": None, "rondas_por_tarjeta": None, "rondas_por_perfil": {},
                         "prs_mergeados": None, "lineas_pr": None, "coste_por_linea": None, "greptile_local": 0,
                         "greptile_github": None, "greptile_por_pr": None}}}
        lineas = ms.formatear_tabla(informe).split("\n")
        self.assertEqual(lineas[0], "Ventana: D → H")
        self.assertEqual(lineas[1].split(), ["tablero", "term.", "coste", "/tarjeta", "/línea", "runs", "rl", "%", "rondas/t",
                                              "PRs", "líneas", "gr", "loc", "gr", "gh", "gr/PR"])
        self.assertEqual(lineas[2].split(), ["tablero1", "2", "7.00", "M", "3.50", "M", "43.75", "k", "13", "15.4", "1.50",
                                              "2", "160", "3", "3", "3.00"])
        self.assertEqual(lineas[3].split(), ["tablero3", "0", "2.00", "M", "—", "—", "0", "—", "—", "—", "—", "0", "—", "—"])
        self.assertEqual(lineas[4], "sin tablero: 0.20 M")
        self.assertIn("0,1·lectura de caché", lineas[5])
        self.assertEqual(len(lineas), 6)
        # Columnas alineadas: la fila de cabecera y las de datos terminan en la misma columna
        self.assertEqual(len({len(lineas[1]), len(lineas[2]), len(lineas[3])}), 1)

    def test_tabla_sin_tableros(self):  # AC-3
        informe = {"desde": "D", "hasta": "H", "sin_tablero": {"coste_eq": 0.0}, "tableros": {}}
        lineas = ms.formatear_tabla(informe).split("\n")
        self.assertEqual(lineas[2], "sin tablero: 0.00 M")


class TestMain(unittest.TestCase):
    """Fixtures completos: 2 tableros con actividad, 1 sin actividad, 1 ilegible; 2 state.db + 1 ilegible."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        t = self.tmp
        self.boards = os.path.join(t, "boards")
        self.env = {"FABRIK_KANBAN_BOARDS": self.boards, "FABRIK_GREPTILE_LOG": os.path.join(t, "g.jsonl"),
                    "FABRIK_STATE_DBS": ":".join([os.path.join(t, "p1", "state.db"), os.path.join(t, "p2", "state.db"),
                                                  os.path.join(t, "roto.db"), "", os.path.join(t, "no_existe.db")])}
        crear_tablero(os.path.join(self.boards, "tablero1", "kanban.db"),
                      [("t_aaaaaaa1", "done", AHORA - DIA, "agente/uno")],
                      [("t_aaaaaaa1", "tester", AHORA - DIA, "changes_requested", None),
                       ("t_aaaaaaa1", "programador", AHORA - DIA, "review_requested", None),
                       ("t_aaaaaaa1", "programador", AHORA - DIA, "completed",
                        json.dumps({"published_pr": "https://github.com/acme/app/pull/1"}))])
        crear_tablero(os.path.join(self.boards, "tablero2", "kanban.db"), [("t_bbbbbbb1", "todo", None, "agente/dos")],
                      [("t_bbbbbbb1", "programador", AHORA - DIA, "rate_limited", None)])
        crear_tablero(os.path.join(self.boards, "tablero4", "kanban.db"), [("t_dddddddd", "done", AHORA - 30 * DIA, None)])
        os.makedirs(os.path.join(self.boards, "tablero5"))
        Path(self.boards, "tablero5", "kanban.db").write_text("basura" * 100)
        crear_state(os.path.join(t, "p1", "state.db"),
                    [("s1", "kanban", AHORA - DIA, 1000, 2000, 10000, 100, "kanban task t_aaaaaaa1")])
        crear_state(os.path.join(t, "p2", "state.db"),
                    [("s2", "kanban", AHORA - DIA, 100, None, None, 10, "kanban task t_bbbbbbb1"),
                     ("s3", "kanban", AHORA - DIA, 50, 0, 0, 0, "sin tarjeta")])
        Path(t, "roto.db").write_text("basura" * 100)
        Path(self.env["FABRIK_GREPTILE_LOG"]).write_text(
            json.dumps({"repo": "acme/app", "rama": "agente/uno", "evento": "ejecutado"}) + "\nrota\n"
            + json.dumps({"repo": "acme/app", "rama": "agente/dos", "evento": "ejecutado"}) + "\n")
        self.gh = gh_falso(t, "echo \"$@\" >> \"%s/gh.log\"\ncase \"$1\" in\n  pr) echo '%s' ;;\n  api) echo '%s' ;;\nesac" % (
            t, json.dumps({"additions": 6, "deletions": 4, "mergedAt": iso_utc(AHORA - 3600), "headRefName": "agente/uno"}),
            json.dumps([{"user": {"login": "greptile-apps[bot]"}}])))
        self.env["FABRIK_GH"] = self.gh

    def correr(self, *argv, **env_extra):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = ms.main(list(argv), dict(self.env, **env_extra), ahora=AHORA)
        return rc, out.getvalue(), err.getvalue()

    def test_json_completo(self):  # AC-3
        rc, out, err = self.correr("--json")
        self.assertEqual(rc, 0)
        d = json.loads(out)
        self.assertEqual(sorted(d), ["desde", "hasta", "sin_tablero", "tableros"])
        self.assertEqual(d["sin_tablero"], {"coste_eq": 50.0})
        self.assertEqual(sorted(d["tableros"]), ["tablero1", "tablero2"])   # 4 sin actividad; 5 ilegible
        self.assertEqual(d["tableros"]["tablero1"], {
            "terminadas": 1, "coste_eq": 4500.0, "coste_por_tarjeta": 4500.0, "runs": 3, "rate_limited": 0,
            "pct_rate_limited": 0.0, "rondas_por_tarjeta": 1.0, "rondas_por_perfil": {"tester": 1},
            "prs_mergeados": 1, "lineas_pr": 10, "coste_por_linea": 450.0,
            "greptile_local": 1, "greptile_github": 1, "greptile_por_pr": 2.0})
        self.assertEqual(d["tableros"]["tablero2"]["coste_eq"], 150.0)   # 100 + 5·10; los None valen 0
        self.assertEqual(d["tableros"]["tablero2"]["pct_rate_limited"], 100.0)
        # Avisos: tablero ilegible y state.db ilegible o ausente; la vacía de FABRIK_STATE_DBS se salta
        self.assertIn("tablero5", err)
        self.assertIn("roto.db", err)
        self.assertIn("no_existe.db", err)
        self.assertEqual(err.count("aviso:"), 3)

    def test_ventana_dias_y_minimo(self):  # AC-3b: --dias cambia la ventana; 0 y negativos → 1
        t = self.tmp
        crear_state(os.path.join(t, "p1", "state2.db"), [
            ("dentro", "kanban", AHORA - 2 * DIA, 1000, 0, 0, 0, "kanban task t_bbbbbbb1"),        # justo en el límite de 2 días
            ("fuera", "kanban", AHORA - 2 * DIA - 1, 1_000_000, 0, 0, 0, "kanban task t_bbbbbbb1")])
        env = {"FABRIK_STATE_DBS": os.path.join(t, "p1", "state2.db")}
        _, out, _ = self.correr("--json", "--sin-gh", "--dias", "2", **env)
        self.assertEqual(json.loads(out)["tableros"]["tablero2"]["coste_eq"], 1000.0)
        _, out, _ = self.correr("--json", "--sin-gh", "--dias", "1", **env)
        # Con 1 día las dos sesiones quedan fuera (coste 0); tablero2 sigue saliendo por su run de hace 1 día
        self.assertEqual(json.loads(out)["tableros"]["tablero2"]["coste_eq"], 0.0)
        d3 = json.loads(self.correr("--json", "--sin-gh", "--dias", "3", **env)[1])
        self.assertEqual(d3["tableros"]["tablero2"]["coste_eq"], 1_001_000.0)
        d0 = json.loads(self.correr("--json", "--sin-gh", "--dias", "0", **env)[1])
        d1 = json.loads(self.correr("--json", "--sin-gh", "--dias", "1", **env)[1])
        self.assertEqual(d0, d1)
        self.assertEqual(json.loads(self.correr("--json", "--sin-gh", "--dias", "-5", **env)[1]), d1)

    def test_sin_gh_no_llama_a_gh(self):  # AC-3b
        rc, out, _ = self.correr("--json", "--sin-gh")
        self.assertEqual(rc, 0)
        self.assertFalse(Path(self.tmp, "gh.log").exists())
        t1 = json.loads(out)["tableros"]["tablero1"]
        self.assertEqual((t1["prs_mergeados"], t1["lineas_pr"], t1["coste_por_linea"], t1["greptile_github"], t1["greptile_por_pr"]),
                         (None, None, None, None, None))
        self.assertEqual(t1["greptile_local"], 1)

    def test_con_gh_lo_llama_una_vez_por_pr(self):  # AC-3
        self.correr("--json")
        lineas = Path(self.tmp, "gh.log").read_text().splitlines()
        self.assertEqual(lineas, ["pr view https://github.com/acme/app/pull/1 --json additions,deletions,mergedAt,headRefName",
                                  "api repos/acme/app/pulls/1/reviews"])

    def test_gh_por_defecto_y_tabla(self):  # AC-3: sin FABRIK_GH usa «gh»; sin --json sale la tabla
        env = dict(self.env)
        del env["FABRIK_GH"]
        bin_falso = os.path.join(self.tmp, "bin")
        os.makedirs(bin_falso)
        gh_falso(bin_falso, "exit 1")
        out, err = io.StringIO(), io.StringIO()
        viejo_path = os.environ["PATH"]
        os.environ["PATH"] = bin_falso + os.pathsep + viejo_path
        try:
            with redirect_stdout(out), redirect_stderr(err):
                rc = ms.main([], env, ahora=AHORA)
        finally:
            os.environ["PATH"] = viejo_path
        self.assertEqual(rc, 0)
        self.assertIn("tablero1", out.getvalue())
        self.assertIn("gh pr view", err.getvalue())   # el falso de PATH falló: aviso

    def test_rutas_por_defecto(self):  # AC-3: sin variables, todo bajo HOME
        home = os.path.join(self.tmp, "home")
        crear_tablero(os.path.join(home, ".hermes", "kanban", "boards", "tablero1", "kanban.db"), [("t_aaaaaaa1", "done", AHORA - 5, None)])
        crear_state(os.path.join(home, ".hermes", "profiles", "p1", "state.db"),
                    [("s", "kanban", AHORA - 5, 10, 0, 0, 0, "kanban task t_aaaaaaa1")])
        crear_state(os.path.join(home, ".hermes", "state.db"), [("s", "kanban", AHORA - 5, 5, 0, 0, 0, "kanban task t_aaaaaaa1")])
        viejo = os.environ["HOME"]
        os.environ["HOME"] = home
        try:
            out = io.StringIO()
            with redirect_stdout(out):
                ms.main(["--json", "--sin-gh"], {}, ahora=AHORA)
        finally:
            os.environ["HOME"] = viejo
        self.assertEqual(json.loads(out.getvalue())["tableros"]["tablero1"]["coste_eq"], 15.0)

    def test_gh_fallido_no_cuenta_y_se_sigue(self):  # AC-3
        self.env["FABRIK_GH"] = gh_falso(self.tmp, "exit 1")
        rc, out, err = self.correr("--json")
        self.assertEqual(rc, 0)
        t1 = json.loads(out)["tableros"]["tablero1"]
        self.assertEqual((t1["prs_mergeados"], t1["lineas_pr"], t1["coste_por_linea"], t1["greptile_local"],
                          t1["greptile_github"], t1["greptile_por_pr"]), (0, 0, None, 0, 0, None))
        self.assertIn("salió con 1", err)


if __name__ == "__main__":
    unittest.main()
