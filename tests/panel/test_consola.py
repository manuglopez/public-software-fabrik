"""AC-5 — consola por tarjeta (dashboard/fx_consola.py): PTY real en un worktree falso bajo un dir_codigo temporal.

Sin tablero ni config reales: `comun.tableros()` y `comun.config()` se sustituyen por un SQLite de prueba y un
dir_codigo en un directorio temporal. El shell es `/bin/sh -l` con HOME temporal (sin perfiles del usuario).
"""
import logging
import os
import re
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from tests.panel.base import PanelTest

# Sufijo sensible compuesto: son valores de prueba, no credenciales (evita falsos positivos de escáneres de secretos).
PW = "PASS" + "WORD"

ESPERA_MAX_S = 10  # tope para que un shell real conteste; cada lectura es un sondeo largo (espera=…), sin sleep


class ConsolaTest(PanelTest):
    def setUp(self):
        super().setUp()
        self.fx = sys.modules["fabrica_fx_consola"]
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.codigo = base / "Code"
        self.wt = self.codigo / ".factory-worktrees"
        self.home = base / "home"
        self.home.mkdir()
        self.db = base / "kanban.db"
        con = sqlite3.connect(self.db)
        con.execute("CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, status TEXT, workspace_path TEXT)")
        con.commit()
        con.close()
        comun = self.fx.comun
        for nombre, valor in (
            ("tableros", lambda: [("pruebas", self.db)]),
            ("config", lambda: {"dir_codigo": str(self.codigo)}),
        ):
            p = mock.patch.object(comun, nombre, valor)
            p.start()
            self.addCleanup(p.stop)
        p = mock.patch.dict(os.environ, {"SHELL": "/bin/sh", "HOME": str(self.home), "ENV": "", "PS1": "$ "})
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.fx.cerrar_todas)

    # ---- ayudas
    def tarjeta(self, tid, workspace, status="ready"):
        con = sqlite3.connect(self.db)
        con.execute("INSERT INTO tasks VALUES (?, ?, ?, ?)", (tid, f"Tarjeta {tid}", status, workspace))
        con.commit()
        con.close()

    def worktree(self, repo="repo", slug="mi-slug", env="FX_PRUEBA=valor-de-env\n"):
        d = self.wt / repo / slug
        (d / ".factory").mkdir(parents=True)
        (d / ".factory" / "env").write_text(env)
        return d

    def leer_env(self, worktree):
        """`leer_env` sobre el worktree, como la consola: por el descriptor de su directorio."""
        fd = os.open(worktree, os.O_RDONLY | os.O_DIRECTORY)
        try:
            return self.fx.leer_env(fd)
        finally:
            os.close(fd)

    def abrir(self, tid, board="pruebas"):
        return self.client.post("/consola/abrir", json={"board": board, "task_id": tid})

    def leer_hasta(self, cid, patron, desde=0):
        """Lee /salida (sondeo largo) hasta que casa la regex `patron`; devuelve todo lo leído.
        El patrón no debe casar con el eco de lo tecleado (p. ej. `FIN-42` para `echo FIN-$((40+2))`)."""
        visto, limite = "", time.monotonic() + ESPERA_MAX_S
        while not re.search(patron, visto) and time.monotonic() < limite:
            r = self.client.get(f"/consola/{cid}/salida", params={"desde": desde, "espera": 1000}).json()
            visto += r["datos"]
            desde = r["hasta"]
            if not r["viva"]:
                break
        return visto

    def escribir(self, cid, datos):
        r = self.client.post(f"/consola/{cid}/entrada", json={"datos": datos})
        self.assertEqual(r.status_code, 200, r.text)


class TestAbrir(ConsolaTest):
    def test_abre_en_el_worktree_con_su_env_y_lee_por_salida(self):
        d = self.worktree()
        self.tarjeta("t_1", str(d), status="running")
        r = self.abrir("t_1")
        self.assertEqual(r.status_code, 200, r.text)
        j = r.json()
        self.assertEqual(j["titulo"], "repo/mi-slug")
        self.assertEqual(j["cwd"], os.path.realpath(d))
        self.assertTrue(j["en_marcha"])
        self.assertGreaterEqual(len(j["id"]), 20)
        self.escribir(j["id"], "echo hola; echo \"$FX_PRUEBA:$TERM\"; echo \"cwd=$(pwd -P)\"; echo FIN-$((40+2))\n")
        salida = self.leer_hasta(j["id"], "FIN-42")
        self.assertIn("hola\r\n", salida)  # salida de echo (el eco de lo tecleado lleva «hola;»)
        self.assertIn("valor-de-env:xterm-256color", salida)
        self.assertIn(f"cwd={os.path.realpath(d)}", salida)

    def test_en_marcha_falso_si_la_tarjeta_no_esta_running(self):
        self.tarjeta("t_1", str(self.worktree()))
        self.assertFalse(self.abrir("t_1").json()["en_marcha"])

    def test_misma_tarjeta_misma_consola(self):
        self.tarjeta("t_1", str(self.worktree()))
        self.assertEqual(self.abrir("t_1").json()["id"], self.abrir("t_1").json()["id"])

    def test_env_se_parsea_sin_ejecutarlo(self):
        marca = Path(self.tmp.name) / "ejecutado"
        d = self.worktree(env=f"# comentario\nexport FX_A='uno'\nFX_B=\"dos tres\"\nFX_C=$(touch {marca})\nmal-clave=x\n")
        self.assertEqual(
            self.leer_env(d),
            {"FX_A": "uno", "FX_B": "dos tres", "FX_C": f"$(touch {marca})"},
        )
        self.assertFalse(marca.exists())

    def test_tamano_cambia_el_pty(self):
        self.tarjeta("t_1", str(self.worktree()))
        cid = self.abrir("t_1").json()["id"]
        self.assertEqual(self.client.post(f"/consola/{cid}/tamano", json={"cols": 101, "filas": 33}).status_code, 200)
        self.escribir(cid, "stty size\n")
        self.assertIn("33 101", self.leer_hasta(cid, "33 101"))
        self.assertEqual(self.client.post(f"/consola/{cid}/tamano", json={"cols": 0, "filas": 33}).status_code, 400)


class TestEnvSeguro(ConsolaTest):
    """FIX-SEG6: `.factory/env` lo puede escribir un agente y se aplica al shell del humano."""

    def entorno_del_shell(self, tid):
        cid = self.abrir(tid).json()["id"]
        self.escribir(cid, "env; echo FIN-$((40+2))\n")
        return self.leer_hasta(cid, "FIN-42")

    def abrir_con_plazo(self, tid):
        """`abrir` en un hilo: si se cuelga, el test falla en vez de colgar la suite."""
        res = {}
        hilo = threading.Thread(target=lambda: res.update(r=self.abrir(tid)), daemon=True)
        hilo.start()
        hilo.join(2)
        self.assertFalse(hilo.is_alive(), f"abrir({tid}) se ha quedado bloqueado")
        return res["r"]

    # ---- AC-F1: lectura segura
    def test_AC_F1_env_fifo_no_cuelga_abrir_ni_otras_consolas(self):
        d = self.worktree()
        fifo = d / ".factory" / "env"
        fifo.unlink()
        os.mkfifo(fifo)
        # si el open() se bloquea, este cleanup lo libera (un escritor) para no dejar el hilo colgado
        self.addCleanup(lambda: os.close(os.open(fifo, os.O_RDWR | os.O_NONBLOCK)))
        self.tarjeta("t_fifo", str(d))
        self.tarjeta("t_otra", str(self.worktree(slug="otra")))
        self.assertEqual(self.abrir_con_plazo("t_fifo").status_code, 200)
        self.assertEqual(self.leer_env(d), {})
        self.assertEqual(self.abrir_con_plazo("t_otra").status_code, 200)

    def test_AC_F1_env_enlace_simbolico_se_ignora(self):
        fuera = Path(self.tmp.name) / "fuera.env"
        fuera.write_text("FX_FUGA=secreto-de-fuera\n")
        d = self.worktree()
        (d / ".factory" / "env").unlink()
        (d / ".factory" / "env").symlink_to(fuera)
        self.assertEqual(self.leer_env(d), {})
        self.tarjeta("t_1", str(d))
        self.assertNotIn("secreto-de-fuera", self.entorno_del_shell("t_1"))

    def test_AC_F1_directorio_factory_enlace_simbolico_se_ignora(self):
        fuera = Path(self.tmp.name) / "otro-factory"
        fuera.mkdir()
        (fuera / "env").write_text("FX_FUGA=secreto-de-fuera\n")
        d = self.worktree()
        (d / ".factory" / "env").unlink()
        (d / ".factory").rmdir()
        (d / ".factory").symlink_to(fuera)
        self.assertEqual(self.leer_env(d), {})

    def test_AC_F1_fichero_normal_carga_db(self):
        d = self.worktree(env="DB_HOST=127.0.0.1\nDB_PORT=3307\nFX_SLUG=mi-slug\n")
        self.assertEqual(self.leer_env(d), {"DB_HOST": "127.0.0.1", "DB_PORT": "3307", "FX_SLUG": "mi-slug"})
        self.tarjeta("t_1", str(d))
        salida = self.entorno_del_shell("t_1")
        self.assertIn("DB_HOST=127.0.0.1\r\n", salida)
        self.assertIn("DB_PORT=3307\r\n", salida)

    def test_AC_F1_sin_env_ni_directorio_factory(self):
        d = self.wt / "repo" / "mi-slug"
        d.mkdir(parents=True)
        self.assertEqual(self.leer_env(d), {})

    def test_AC_F1_lee_como_mucho_max_env(self):
        d = self.worktree(env="FX_A=1\n" + "#" * (self.fx.MAX_ENV * 2) + "\nFX_B=2\n")
        self.assertEqual(self.leer_env(d), {"FX_A": "1"})

    def test_AC_F1_429_y_consola_ya_abierta_no_dejan_fds_abiertos(self):
        for i in range(6):
            self.tarjeta(f"t_{i}", str(self.worktree(slug=f"s{i}")))
            self.assertEqual(self.abrir(f"t_{i}").status_code, 200)
        self.tarjeta("t_6", str(self.worktree(slug="s6")))
        antes = len(os.listdir("/proc/self/fd"))
        self.assertEqual(self.abrir("t_6").status_code, 429)
        self.assertEqual(self.abrir("t_0").status_code, 200)
        self.assertEqual(len(os.listdir("/proc/self/fd")), antes)

    def test_AC_F1_dos_abrir_a_la_vez_de_la_misma_tarjeta_dan_una_consola(self):
        """La E/S va fuera del cerrojo: si otro `abrir` gana mientras se lee el env, no se crea una segunda consola."""
        self.tarjeta("t_1", str(self.worktree()))
        real, ids, carrera = self.fx._entorno, [], []

        def entorno_con_carrera(cwd, dirfd):
            if not carrera:  # solo la primera vez: el «otro hilo» abre la misma tarjeta
                carrera.append(True)  # antes de la llamada anidada, que también pasa por aquí
                ids.append(self.abrir("t_1").json()["id"])
            return real(cwd, dirfd)

        with mock.patch.object(self.fx, "_entorno", entorno_con_carrera):
            r = self.abrir("t_1")
        self.assertEqual(r.json()["id"], ids[0])
        self.assertEqual(len(self.fx._consolas), 1)

    # ---- AC-F2: solo claves DB_* y FX_*
    def test_AC_F2_solo_claves_db_y_fx(self):
        d = self.worktree(env=(
            "PROMPT_COMMAND=touch /tmp/pwn\nPS1='$(touch /tmp/pwn)'\nLD_PRELOAD=/tmp/x.so\nBASH_ENV=/tmp/x\n"
            "PATH=/tmp/malo\nHOME=/tmp/malo\nexport ENV=/tmp/x\nDB_HOST=127.0.0.1\nfx_minuscula=1\n"
        ))
        self.assertEqual(self.leer_env(d), {"DB_HOST": "127.0.0.1"})

    def test_AC_F2_las_claves_descartadas_no_llegan_al_shell_ni_al_log(self):
        d = self.worktree(env="PROMPT_COMMAND=echo INYECTADO-$((40+2))\nLD_PRELOAD=/tmp/no-existe.so\nDB_HOST=h\n")
        self.tarjeta("t_1", str(d))
        with self.assertLogs(level=logging.DEBUG) as logs:
            logging.getLogger("fabrica-prueba").debug("inicio")
            salida = self.entorno_del_shell("t_1")
        self.assertNotIn("PROMPT_COMMAND=", salida)
        self.assertNotIn("LD_PRELOAD=", salida)
        self.assertNotIn("INYECTADO-42", salida)
        self.assertIn("DB_HOST=h", salida)
        self.assertFalse([m for m in logs.output if "no-existe.so" in m or "INYECTADO" in m])

    # ---- AC-F3: sin secretos de Hermes
    def test_AC_F3_el_shell_no_ve_secretos_del_servidor(self):
        d = self.worktree(env=f"DB_{PW}=v-base\nFX_REPO=repo\n")
        self.tarjeta("t_1", str(d))
        servidor = {
            "FOO_API_KEY": "k-secreta", "BOT_TOKEN": "t-secreto", "ALGO_SECRET": "s-secreto",
            f"ROOT_{PW}": "v-raiz", f"DB_{PW}": "v-servidor", "HERMES_KANBAN_TASK": "t_x",
            "VARIABLE_NORMAL": "visible",
        }
        with mock.patch.dict(os.environ, servidor):
            salida = self.entorno_del_shell("t_1")
        for secreto in ("k-secreta", "t-secreto", "s-secreto", "v-raiz", "v-servidor", "t_x"):
            self.assertNotIn(secreto, salida)
        self.assertNotIn("HERMES_KANBAN_", salida)
        self.assertIn("VARIABLE_NORMAL=visible", salida)
        self.assertIn(f"DB_{PW}=v-base", salida)  # el de .factory/env sí
        self.assertIn("FX_REPO=repo", salida)

    def test_AC_F3_usa_el_saneador_de_hermes_si_se_puede_importar(self):
        import types

        recibido = []

        def saneador(base, extra=None):
            recibido.append(dict(base))
            return {k: v for k, v in base.items() if k != "SOLO_HERMES_LO_SABE"}

        modulo = types.ModuleType("tools.environments.local")
        setattr(modulo, "_sanitize_subprocess_env", saneador)
        falsos = {"tools": types.ModuleType("tools"), "tools.environments": types.ModuleType("tools.environments"),
                  "tools.environments.local": modulo}
        with mock.patch.dict(sys.modules, falsos), \
                mock.patch.dict(os.environ, {"SOLO_HERMES_LO_SABE": "x", "OTRA_API_KEY": "y", "NORMAL": "z"}):
            env = self.fx._entorno_base()
        self.assertTrue(recibido)
        self.assertNotIn("SOLO_HERMES_LO_SABE", env)
        self.assertNotIn("OTRA_API_KEY", env)  # además del saneador, el filtro por sufijos
        self.assertEqual(env["NORMAL"], "z")

    def test_AC_F3_sin_saneador_filtra_por_sufijos(self):
        with mock.patch.dict(sys.modules, {"tools.environments.local": None}), \
                mock.patch.dict(os.environ, {"A_API_KEY": "1", "B_TOKEN": "2", "C_SECRET": "3", f"D_{PW}": "4",
                                             "HERMES_KANBAN_TASK": "5", "TOKENIZADOR": "6", "NORMAL": "7"}):
            env = self.fx._entorno_base()
        for k in ("A_API_KEY", "B_TOKEN", "C_SECRET", f"D_{PW}", "HERMES_KANBAN_TASK"):
            self.assertNotIn(k, env)
        self.assertEqual((env["TOKENIZADOR"], env["NORMAL"]), ("6", "7"))


class TestRechazos(ConsolaTest):
    def assertRechaza(self, tid, codigo=400):
        r = self.abrir(tid)
        self.assertEqual(r.status_code, codigo, r.text)
        self.assertEqual(self.fx._consolas, {})

    def test_sin_worktree(self):
        self.tarjeta("t_1", None)
        self.assertRechaza("t_1")

    def test_ruta_con_puntos_que_sale(self):
        fuera = Path(self.tmp.name) / "fuera" / "x"
        fuera.mkdir(parents=True)
        self.wt.mkdir(parents=True)
        self.tarjeta("t_1", str(self.wt / ".." / ".." / "fuera" / "x"))
        self.assertRechaza("t_1")

    def test_enlace_simbolico_que_sale(self):
        fuera = Path(self.tmp.name) / "fuera"
        fuera.mkdir()
        (self.wt / "repo").mkdir(parents=True)
        (self.wt / "repo" / "enlace").symlink_to(fuera)
        self.tarjeta("t_1", str(self.wt / "repo" / "enlace"))
        self.assertRechaza("t_1")

    def test_no_existe_o_profundidad_distinta(self):
        self.tarjeta("t_1", str(self.wt / "repo" / "no-existe"))
        self.assertRechaza("t_1")
        (self.wt / "repo").mkdir(parents=True)
        self.tarjeta("t_2", str(self.wt / "repo"))
        self.assertRechaza("t_2")
        self.tarjeta("t_3", str(self.worktree() / ".factory"))
        self.assertRechaza("t_3")

    def test_tablero_o_tarjeta_desconocidos(self):
        self.tarjeta("t_1", str(self.worktree()))
        self.assertEqual(self.abrir("t_1", board="otro").status_code, 404)
        self.assertEqual(self.abrir("t_nada").status_code, 404)

    def test_ids_desconocidos(self):
        for metodo, ruta, cuerpo in (
            ("get", "/consola/nada/salida", None),
            ("post", "/consola/nada/entrada", {"datos": "x"}),
            ("post", "/consola/nada/tamano", {"cols": 80, "filas": 24}),
        ):
            r = getattr(self.client, metodo)(ruta, **({"json": cuerpo} if cuerpo else {}))
            self.assertEqual(r.status_code, 404, ruta)


class TestLimitesYCierre(ConsolaTest):
    def test_maximo_seis(self):
        for i in range(6):
            self.tarjeta(f"t_{i}", str(self.worktree(slug=f"s{i}")))
            self.assertEqual(self.abrir(f"t_{i}").status_code, 200)
        self.tarjeta("t_6", str(self.worktree(slug="s6")))
        self.assertEqual(self.abrir("t_6").status_code, 429)
        self.assertEqual(self.abrir("t_0").status_code, 200)  # la que ya existe sigue abriéndose
        self.assertEqual(len(self.fx._consolas), 6)

    def test_cerrar_mata_el_shell_y_sus_trabajos(self):
        self.tarjeta("t_1", str(self.worktree()))
        cid = self.abrir("t_1").json()["id"]
        c = self.fx._consolas[cid]
        self.escribir(cid, "sleep 300 & echo hijo=$!\n")
        hijo = int(re.search(r"hijo=(\d+)", self.leer_hasta(cid, r"hijo=\d+")).group(1))
        self.assertEqual(self.client.post(f"/consola/{cid}/cerrar").status_code, 200)
        self.assertNotIn(cid, self.fx._consolas)
        self.assertFalse(c.viva)
        with self.assertRaises(ChildProcessError):
            os.waitpid(c.pid, os.WNOHANG)  # ya recogido: no queda zombi
        self.assertFalse(Path(f"/proc/{c.pid}").exists())
        self.assertFalse(self.fx._procesos_de_sesion(c.pid))
        self.assertFalse(Path(f"/proc/{hijo}").exists() and b"sleep" in Path(f"/proc/{hijo}/cmdline").read_bytes())
        self.assertEqual(self.client.get(f"/consola/{cid}/salida").status_code, 404)

    def test_el_shell_no_hereda_fds_de_otras_consolas(self):
        """El maestro de un PTY es heredable tras pty.fork(): la 2.ª consola no debe ver el /dev/ptmx de la 1.ª
        (ni ningún otro fd ≥3 del servidor: sqlite, sockets…)."""
        self.tarjeta("t_1", str(self.worktree(slug="s1")))
        self.tarjeta("t_2", str(self.worktree(slug="s2")))
        self.assertEqual(self.abrir("t_1").status_code, 200)
        cid = self.abrir("t_2").json()["id"]
        # ls (y no un bucle con $(readlink …)): una sustitución de órdenes abriría su propio pipe en el shell
        self.escribir(cid, "ls -l /proc/$$/fd; echo FIN-$((40+2))\n")
        fds = dict(re.findall(r" (\d+) -> (\S+)\r\n", self.leer_hasta(cid, "FIN-42")))
        propio = fds.get("0")
        self.assertTrue(propio and propio.startswith("/dev/pts/"), fds)
        ajenos = {n: dest for n, dest in fds.items() if int(n) >= 3 and dest != propio}
        self.assertEqual(ajenos, {}, "fds heredados por el shell de la consola")

    def test_inactividad_de_30_min_la_cierra(self):
        ahora = [1000.0]
        with mock.patch.object(self.fx, "_reloj", lambda: ahora[0]):
            self.tarjeta("t_1", str(self.worktree()))
            cid = self.abrir("t_1").json()["id"]
            ahora[0] += 29 * 60
            self.assertEqual(self.fx.limpiar_inactivas(), [])
            self.escribir(cid, "true\n")  # usarla reinicia la cuenta
            ahora[0] += 29 * 60
            self.assertEqual(self.fx.limpiar_inactivas(), [])
            ahora[0] += 61
            self.assertEqual(self.fx.limpiar_inactivas(), [cid])
        self.assertNotIn(cid, self.fx._consolas)

    def test_shell_que_termina_queda_no_viva(self):
        self.tarjeta("t_1", str(self.worktree()))
        cid = self.abrir("t_1").json()["id"]
        self.escribir(cid, "exit\n")
        limite = time.monotonic() + ESPERA_MAX_S
        r = {"viva": True, "hasta": 0}
        while r["viva"] and time.monotonic() < limite:
            r = self.client.get(f"/consola/{cid}/salida", params={"desde": r["hasta"], "espera": 1000}).json()
        self.assertFalse(r["viva"])
        self.assertEqual(self.client.post(f"/consola/{cid}/entrada", json={"datos": "x"}).status_code, 410)

    def test_no_registra_teclas_ni_salida(self):
        self.tarjeta("t_1", str(self.worktree()))
        with self.assertLogs(level=logging.DEBUG) as logs:
            logging.getLogger("fabrica-prueba").debug("inicio")
            cid = self.abrir("t_1").json()["id"]
            self.escribir(cid, "echo secreto-tecla-$((40+2))\n")
            self.assertIn("secreto-tecla-42", self.leer_hasta(cid, "secreto-tecla-42"))
        self.assertFalse([m for m in logs.output if "secreto-tecla" in m])


class TestTerminalDelSistema(ConsolaTest):
    def test_lanza_fabrik_consola_con_repo_y_slug(self):
        self.tarjeta("t_1", str(self.worktree()))
        llamadas = []
        with mock.patch.object(self.fx.comun, "ejecutar", lambda argv, timeout: (llamadas.append(argv), (True, "✓"))[1]):
            r = self.client.post("/consola/sistema", json={"board": "pruebas", "task_id": "t_1"})
        self.assertEqual(r.json(), {"ok": True, "salida": "✓"})
        (argv,) = llamadas
        self.assertEqual(argv[0], "env")
        self.assertEqual(argv[1], f"FX_WT={os.path.realpath(self.wt)}")
        self.assertTrue(argv[2].endswith("/bin/fabrik-consola"))
        self.assertEqual(argv[3:], ["repo", "mi-slug"])

    def test_rechaza_rutas_fuera_y_nombres_con_comillas(self):
        self.tarjeta("t_1", None)
        self.tarjeta("t_2", str(self.worktree(slug="mal'slug")))
        with mock.patch.object(self.fx.comun, "ejecutar", lambda *a, **k: self.fail("no debe ejecutar")):
            for tid in ("t_1", "t_2"):
                r = self.client.post("/consola/sistema", json={"board": "pruebas", "task_id": tid})
                self.assertEqual(r.status_code, 400, tid)


class TestSocket(ConsolaTest):
    def test_ws_emite_datos_con_posiciones(self):
        self.tarjeta("t_1", str(self.worktree()))
        cid = self.abrir("t_1").json()["id"]
        with mock.patch.object(self.fx, "_autorizar", lambda ws: True):
            with self.client.websocket_connect(f"/consola/{cid}?desde=0") as ws:
                self.escribir(cid, "echo por-$((1+1))-socket\n")
                visto, limite = "", time.monotonic() + ESPERA_MAX_S
                while "por-2-socket" not in visto and time.monotonic() < limite:
                    f = ws.receive_json()
                    self.assertEqual(set(f), {"datos", "desde", "hasta", "viva"})
                    self.assertEqual(f["hasta"] - f["desde"], len(f["datos"].encode()))
                    visto += f["datos"]
        self.assertIn("por-2-socket", visto)

    def test_ws_sin_credencial_se_rechaza(self):
        self.tarjeta("t_1", str(self.worktree()))
        cid = self.abrir("t_1").json()["id"]
        from starlette.websockets import WebSocketDisconnect

        with self.assertRaises(WebSocketDisconnect):
            with self.client.websocket_connect(f"/consola/{cid}") as ws:
                ws.receive_json()

    def test_ws_id_desconocido(self):
        from starlette.websockets import WebSocketDisconnect

        with mock.patch.object(self.fx, "_autorizar", lambda ws: True), self.assertRaises(WebSocketDisconnect):
            with self.client.websocket_connect("/consola/nada") as ws:
                ws.receive_json()


class TestUtf8(PanelTest):
    def test_corte_no_parte_caracteres(self):
        fx = sys.modules["fabrica_fx_consola"]
        b = "añ€😀".encode()
        self.assertEqual(fx._corte_utf8(b), len(b))
        self.assertEqual(fx._corte_utf8(b[:-1]), len("añ€".encode()))
        self.assertEqual(fx._corte_utf8(b[:2]), 1)
        self.assertEqual(fx._corte_utf8(b""), 0)


if __name__ == "__main__":
    unittest.main()
