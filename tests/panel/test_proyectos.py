"""AC-4a (Proyectos) y, para la pestaña Memoria (AC-4d), `GET /memoria/lecciones`: `dashboard/fx_proyectos.py`.

Sin red ni HOME real: el catálogo es un portfolio de fixture en FABRIK_DATA temporal, los tableros son SQLite de
fixture (HERMES_KANBAN_HOME) y `gh` es un `comun.ejecutar` simulado.
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

import yaml

from tests.panel.base import PanelTest

PRS = json.loads((Path(__file__).parent / "fixtures" / "proyectos_gh_prs.json").read_text(encoding="utf-8"))


def crear_tablero(ruta: Path, tarjetas) -> None:
    """tarjetas: [(id, titulo, estado, workspace_path, body)]"""
    ruta.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(ruta)
    con.execute("CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, status TEXT, workspace_path TEXT, body TEXT)")
    con.executemany("INSERT INTO tasks VALUES (?, ?, ?, ?, ?)", tarjetas)
    con.commit()
    con.close()


class ProyectosTest(PanelTest):
    def setUp(self):
        super().setUp()
        self.fx = sys.modules["fabrica_fx_proyectos"]
        self.comun = sys.modules["fabrica_comun"]
        self.tmp = Path(tempfile.mkdtemp(prefix="fx-proyectos-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        entorno = {"HERMES_KANBAN_HOME": str(self.tmp / "home"), "FABRIK_DATA": str(self.tmp / "data")}
        parche = mock.patch.dict(os.environ, entorno)
        parche.start()
        self.addCleanup(parche.stop)
        for var in ("HERMES_KANBAN_DB", "HERMES_KANBAN_BOARD"):
            os.environ.pop(var, None)
        sin_hermes = mock.patch.dict(sys.modules, {"hermes_cli": None, "hermes_cli.kanban_db": None})
        sin_hermes.start()
        self.addCleanup(sin_hermes.stop)
        (self.tmp / "data").mkdir()
        self.fx.CACHE_PRS.clear()
        self.llamadas = []
        self.packs = {}  # packs activos con memoria.banco: {nombre: directorio}
        self.gh_falla = set()
        for p in (
            mock.patch.object(self.comun, "ejecutar", side_effect=self.ejecutar_falso),
            mock.patch.object(self.fx.shutil, "which", return_value="/usr/bin/gh"),
        ):
            p.start()
            self.addCleanup(p.stop)

    def ejecutar_falso(self, argv, timeout):
        if argv[1:4] == ["config", "pack-dir", "memoria.banco"]:  # `fabrik config pack-dir`: «nombre<TAB>directorio»
            return True, "".join(f"{n}\t{d}\n" for n, d in self.packs.items())
        self.llamadas.append((list(argv), timeout))
        repo = argv[argv.index("-R") + 1]
        if repo in self.gh_falla:
            return False, "HTTP 502"
        return True, json.dumps(PRS.get(repo, []))

    def escribir_portfolio(self, datos=None):
        datos = datos if datos is not None else self.fixture("proyectos_portfolio")
        (self.tmp / "data" / "portfolio.yaml").write_text(yaml.safe_dump(datos, allow_unicode=True), encoding="utf-8")

    def tablero(self, slug, tarjetas):
        crear_tablero(self.tmp / "home" / "kanban" / "boards" / slug / "kanban.db", tarjetas)

    def get(self):
        r = self.client.get("/proyectos")
        self.assertEqual(r.status_code, 200)
        return r.json()

    def repos(self, cuerpo):
        return {r["repo"]: r for p in cuerpo["productos"] for r in p["repos"]}


class TestCatalogo(ProyectosTest):
    def test_ac4a_agrupa_por_producto_y_pone_primero_ritmo_diario(self):
        self.escribir_portfolio()
        cuerpo = self.get()
        nombres = [p["nombre"] for p in cuerpo["productos"]]
        # tienda tiene un repo diario → va antes que movil; «Sin producto» (blog) va siempre al final
        self.assertEqual(nombres, ["tienda", "movil", "Sin producto"])
        tienda = cuerpo["productos"][0]
        self.assertEqual([r["repo"] for r in tienda["repos"]], ["web-tienda", "api-tienda", "wiki"])
        self.assertEqual(tienda["repos"][0]["ritmo"], "diario")
        self.assertEqual(tienda["nota"], "Tienda online multimarca")

    def test_ac4a_producto_por_campo_del_proyecto_y_catalogo_sin_ruido(self):
        self.escribir_portfolio()
        repos = self.repos(self.get())
        self.assertEqual(set(repos), {"web-tienda", "api-tienda", "wiki", "app-movil", "blog"})  # sin abandonado/ignorar/infra
        self.assertEqual(repos["app-movil"]["full_name"], "acme/app-movil")

    def test_ac4a_cada_repo_trae_la_forma_del_contrato(self):
        self.escribir_portfolio()
        for r in self.repos(self.get()).values():
            self.assertTrue({"repo", "full_name", "ritmo", "tarjetas_activas", "tarjetas", "prs"} <= set(r))
            self.assertIsInstance(r["tarjetas_activas"], int)

    def test_ac4a_sin_portfolio_no_disponible_y_lista_vacia(self):
        cuerpo = self.get()
        self.assertFalse(cuerpo["disponible"])
        self.assertIn("portfolio", cuerpo["motivo"])
        self.assertEqual(cuerpo["productos"], [])

    def test_ac4a_portfolio_ilegible_no_disponible(self):
        (self.tmp / "data" / "portfolio.yaml").write_text("projects: [ {", encoding="utf-8")
        cuerpo = self.get()
        self.assertFalse(cuerpo["disponible"])
        self.assertEqual(cuerpo["productos"], [])


class TestTarjetas(ProyectosTest):
    def test_ac4a_tarjetas_activas_por_repo_con_worktree_o_con_linea_repo(self):
        self.escribir_portfolio()
        self.tablero("tienda", [
            ("t_aaaa0001", "IMPL carrito", "running", "/x/.factory-worktrees/web-tienda/carrito", "cuerpo"),
            ("t_aaaa0002", "IMPL precios", "ready", "/x/scratch/t_aaaa0002", "**Repo** `acme/api-tienda` · rama"),
            ("t_aaaa0003", "Hecha", "done", "/x/.factory-worktrees/web-tienda/vieja", ""),
            ("t_aaaa0004", "Archivada", "archived", "/x/.factory-worktrees/web-tienda/otra", ""),
            ("t_aaaa0005", "Sin repo", "todo", None, "nada"),
        ])
        repos = self.repos(self.get())
        self.assertEqual(repos["web-tienda"]["tarjetas_activas"], 1)
        self.assertEqual(repos["web-tienda"]["tarjetas"], [
            {"board": "tienda", "task_id": "t_aaaa0001", "titulo": "IMPL carrito", "estado": "running"}
        ])
        self.assertEqual(repos["api-tienda"]["tarjetas_activas"], 1)
        self.assertEqual(repos["api-tienda"]["tarjetas"][0]["task_id"], "t_aaaa0002")
        self.assertEqual(repos["blog"]["tarjetas_activas"], 0)

    def test_ac4a_tarjetas_de_varios_tableros_y_tablero_roto_solo_avisa(self):
        self.escribir_portfolio()
        self.tablero("tienda", [("t_bbbb0001", "A", "running", "/x/.factory-worktrees/web-tienda/a", "")])
        self.tablero("movil", [("t_bbbb0002", "B", "blocked", "/x/.factory-worktrees/web-tienda/b", "")])
        roto = self.tmp / "home" / "kanban" / "boards" / "roto" / "kanban.db"
        roto.parent.mkdir(parents=True)
        roto.write_bytes(b"no es sqlite")
        cuerpo = self.get()
        web = self.repos(cuerpo)["web-tienda"]
        self.assertEqual(web["tarjetas_activas"], 2)
        self.assertEqual({t["board"] for t in web["tarjetas"]}, {"tienda", "movil"})
        self.assertTrue(any("roto" in a for a in cuerpo["avisos"]))

    def test_ac4a_la_lista_de_tarjetas_se_acota_pero_el_total_no(self):
        self.escribir_portfolio()
        n = self.fx.MAX_TARJETAS + 5
        self.tablero("tienda", [(f"t_cccc{i:04x}", f"T{i}", "ready", "/x/.factory-worktrees/blog/s", "") for i in range(n)])
        blog = self.repos(self.get())["blog"]
        self.assertEqual(blog["tarjetas_activas"], n)
        self.assertEqual(len(blog["tarjetas"]), self.fx.MAX_TARJETAS)


class TestPrs(ProyectosTest):
    def test_ac4a_solo_prs_de_ramas_agente(self):
        self.escribir_portfolio()
        repos = self.repos(self.get())
        self.assertEqual(
            repos["web-tienda"]["prs"],
            [
                {"numero": 12, "titulo": "feat: carrito persistente", "url": "https://github.com/acme/web-tienda/pull/12"},
                {"numero": 14, "titulo": "fix: precio con IVA", "url": "https://github.com/acme/web-tienda/pull/14"},
            ],
        )
        self.assertEqual(repos["app-movil"]["prs"][0]["numero"], 3)
        self.assertEqual(repos["api-tienda"]["prs"], [])

    def test_ac4a_gh_se_llama_sin_shell_con_timeout_y_una_vez_por_repo(self):
        self.escribir_portfolio()
        self.get()
        self.assertEqual(len(self.llamadas), 5)  # un repo cada uno; el ruido y los abandonados no
        argv, timeout = next(c for c in self.llamadas if "acme/web-tienda" in c[0])
        self.assertEqual(argv[:3], ["gh", "pr", "list"])
        self.assertIn("--json", argv)
        self.assertIn("open", argv)
        self.assertGreater(timeout, 0)
        self.assertLessEqual(timeout, 15)

    def portfolio_de(self, proyecto, org=None):
        datos = {"projects": [{"ritmo": "diario", **proyecto}]}
        if org is not None:
            datos["org"] = org
        self.escribir_portfolio(datos)
        return self.repos(self.get())[proyecto["name"]]

    def repos_consultados(self):
        return [argv[argv.index("-R") + 1] for argv, _ in self.llamadas]

    def test_ac4_full_name_presente_se_usa_tal_cual(self):
        repo = self.portfolio_de({"name": "web", "full_name": "otra/web", "url": "https://github.com/x/y"}, org="acme")
        self.assertEqual(self.repos_consultados(), ["otra/web"])
        self.assertEqual(repo["full_name"], "otra/web")

    def test_ac4_sin_full_name_se_saca_de_la_url_de_github(self):
        repo = self.portfolio_de({"name": "web", "url": "https://github.com/acme/web/"})
        self.assertEqual(self.repos_consultados(), ["acme/web"])
        self.assertEqual(repo["full_name"], "acme/web")

    def test_ac4_url_con_punto_git(self):
        repo = self.portfolio_de({"name": "web", "url": "https://github.com/acme/web.git"}, org="otra")
        self.assertEqual(self.repos_consultados(), ["acme/web"])
        self.assertEqual(repo["full_name"], "acme/web")

    def test_ac4_sin_full_name_ni_url_usa_org_y_name(self):
        repo = self.portfolio_de({"name": "web"}, org="acme")
        self.assertEqual(self.repos_consultados(), ["acme/web"])
        self.assertEqual(repo["full_name"], "acme/web")

    def test_ac4_full_name_sin_barra_o_url_ajena_caen_al_org(self):
        repo = self.portfolio_de({"name": "web", "full_name": "web", "url": "https://servidor-ajeno/a/b"}, org="acme")
        self.assertEqual(self.repos_consultados(), ["acme/web"])
        self.assertEqual(repo["full_name"], "acme/web")

    def test_ac4_sin_full_name_url_ni_org_no_llama_a_gh_y_avisa(self):
        self.escribir_portfolio({"projects": [{"name": "web", "ritmo": "diario"}, {"name": "api", "ritmo": "diario", "full_name": "acme/api"}]})
        cuerpo = self.get()
        self.assertEqual(self.repos_consultados(), ["acme/api"])  # nunca un nombre sin «/»
        web = self.repos(cuerpo)["web"]
        self.assertEqual((web["full_name"], web["prs"]), ("web", []))
        self.assertIn("web: sin full_name ni org, PRs sin consultar", cuerpo["avisos"])

    def test_ac4a_segunda_lectura_usa_la_cache(self):
        self.escribir_portfolio()
        self.get()
        self.get()
        self.assertEqual(len(self.llamadas), 5)

    def test_ac4a_sin_gh_lista_vacia_y_aviso(self):
        self.escribir_portfolio()
        with mock.patch.object(self.fx.shutil, "which", return_value=None):
            cuerpo = self.get()
        self.assertEqual(self.llamadas, [])
        self.assertTrue(all(r["prs"] == [] for r in self.repos(cuerpo).values()))
        self.assertTrue(any("gh" in a for a in cuerpo["avisos"]))
        self.assertEqual(len(self.repos(cuerpo)), 5)  # el resto sigue

    def test_ac4a_gh_falla_en_un_repo_solo_vacia_ese_y_avisa(self):
        self.escribir_portfolio()
        self.gh_falla = {"acme/web-tienda"}
        cuerpo = self.get()
        repos = self.repos(cuerpo)
        self.assertEqual(repos["web-tienda"]["prs"], [])
        self.assertEqual(repos["app-movil"]["prs"][0]["numero"], 3)
        self.assertTrue(any("web-tienda" in a for a in cuerpo["avisos"]))

    def test_ac4a_salida_de_gh_que_no_es_json_no_rompe(self):
        self.escribir_portfolio()
        with mock.patch.object(self.comun, "ejecutar", return_value=(True, "no es json")):
            cuerpo = self.get()
        self.assertTrue(all(r["prs"] == [] for r in self.repos(cuerpo).values()))


class TestLecciones(ProyectosTest):
    def escribir(self, ruta, repo, fecha, sintoma):
        ruta.parent.mkdir(parents=True, exist_ok=True)
        ruta.write_text(
            f"---\nrepo: {repo}\nfecha: {fecha}\netiquetas: [a, b]\n---\n"
            f"**Síntoma:** {sintoma}\n\n**Causa:** la causa\n\n**Solución:** la solución\n\n**Dónde:** el sitio\n",
            encoding="utf-8",
        )

    def test_ac4d_lista_las_ultimas_lecciones_de_local_y_packs_mas_nuevas_primero(self):
        datos = self.tmp / "data"
        self.packs = {"acme": str(self.tmp / "pack-acme")}  # fuera de FABRIK_DATA: lo da `fabrik config pack-dir`
        self.escribir(datos / "conocimiento/lecciones/2026-10-01-blog-a.md", "blog", "2026-10-01", "Síntoma viejo")
        self.escribir(self.tmp / "pack-acme/conocimiento/lecciones/2026-10-20-web-b.md", "web-tienda", "2026-10-20", "Síntoma nuevo")
        self.escribir(self.tmp / "pack-acme/conocimiento/lecciones/2026-10-10-api-c.md", "api-tienda", "2026-10-10", "Síntoma medio")
        r = self.client.get("/memoria/lecciones")
        self.assertEqual(r.status_code, 200)
        lecciones = r.json()["lecciones"]
        self.assertEqual([x["sintoma"] for x in lecciones], ["Síntoma nuevo", "Síntoma medio", "Síntoma viejo"])
        primera = lecciones[0]
        self.assertEqual((primera["repo"], primera["fecha"]), ("web-tienda", "2026-10-20"))
        self.assertEqual((primera["causa"], primera["solucion"], primera["donde"]), ("la causa", "la solución", "el sitio"))

    def test_ac4d_sin_fabrik_o_con_salida_rara_solo_lee_las_locales(self):
        self.escribir(self.tmp / "data/conocimiento/lecciones/2026-10-01-blog-a.md", "blog", "2026-10-01", "Local")
        with mock.patch.object(self.comun, "ejecutar", return_value=(False, "no se pudo ejecutar fabrik")):
            self.assertEqual([x["sintoma"] for x in self.client.get("/memoria/lecciones").json()["lecciones"]], ["Local"])
        with mock.patch.object(self.comun, "ejecutar", return_value=(True, "aviso suelto\nsin tabulador\n")):
            self.assertEqual(len(self.client.get("/memoria/lecciones").json()["lecciones"]), 1)

    def test_ac4d_max_acota_y_sin_carpeta_devuelve_lista_vacia(self):
        self.assertEqual(self.client.get("/memoria/lecciones").json(), {"lecciones": []})
        for i in range(5):
            self.escribir(self.tmp / f"data/conocimiento/lecciones/2026-10-0{i + 1}-r-x.md", "r", f"2026-10-0{i + 1}", f"S{i}")
        self.assertEqual(len(self.client.get("/memoria/lecciones?max=2").json()["lecciones"]), 2)

    def test_ac4d_fichero_ilegible_o_sin_cabecera_se_ignora_sin_romper(self):
        d = self.tmp / "data/conocimiento/lecciones"
        d.mkdir(parents=True)
        (d / "2026-10-01-roto.md").write_bytes(b"\xff\xfe\x00")
        (d / "2026-10-02-libre.md").write_text("texto sin cabecera", encoding="utf-8")
        self.escribir(d / "2026-10-03-bien.md", "blog", "2026-10-03", "Bien")
        sintomas = [x["sintoma"] for x in self.client.get("/memoria/lecciones").json()["lecciones"]]
        self.assertIn("Bien", sintomas)


if __name__ == "__main__":
    unittest.main()
