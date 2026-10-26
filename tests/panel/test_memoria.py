"""AC-3g Memoria en Inicio y AC-6 (memoria opcional): `GET /memoria` y `POST /memoria/buscar` (dashboard/fx_memoria.py).

`fabrik-memoria` se sustituye por scripts falsos en un directorio temporal y Hindsight por un servidor HTTP local de
pega (127.0.0.1, puerto libre); sin red real. El caso «memoria caída» también se prueba con el `bin/fabrik-memoria`
real apuntando a un puerto cerrado.
"""
import datetime as dt
import json
import os
import shutil
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlparse

from tests.panel.base import RAIZ, PanelTest

ESTADO = {"total_documents": 451, "total_nodes": 14595, "total_observations": 9, "pending_operations": 0, "failed_operations": 0}
# Como la CLI real: sale 0 siempre; `%s` es lo que hace `recall`.
ESTADO_Y_RECALL = """case $1 in
  estado) echo '{"total_documents": 1}' ;;
  recall) %s ;;
esac"""


class Hindsight(ThreadingHTTPServer):
    """Hindsight de pega: responde `documentos` en /documents y apunta cada petición en `peticiones`."""

    daemon_threads = True
    block_on_close = False

    def __init__(self, documentos, espera=0.0):
        self.documentos, self.espera, self.peticiones = documentos, espera, []

        class Manejador(BaseHTTPRequestHandler):
            def do_GET(h):
                url = urlparse(h.path)
                self.peticiones.append((url.path, parse_qs(url.query)))
                time.sleep(self.espera)
                q = parse_qs(url.query)
                docs = self.documentos
                if "start_date" in q:
                    desde = dt.datetime.fromisoformat(q["start_date"][0])
                    docs = [d for d in docs if dt.datetime.fromisoformat(d["created_at"]) >= desde]
                cuerpo = json.dumps({"items": docs[: int(q.get("limit", ["100"])[0])], "total": len(docs)}).encode()
                h.send_response(200)
                h.send_header("Content-Type", "application/json")
                h.end_headers()
                h.wfile.write(cuerpo)

            def log_message(h, *a):
                pass

        super().__init__(("127.0.0.1", 0), Manejador)

    def url(self):
        return f"http://127.0.0.1:{self.server_address[1]}"


AHORA = dt.datetime(2026, 10, 24, 12, 0).astimezone()  # reloj congelado: mediodía local


def doc(ident, hace_min, fuente=None, tags=()):
    creado = (AHORA - dt.timedelta(minutes=hace_min)).isoformat()
    return {"id": ident, "created_at": creado, "updated_at": creado, "tags": list(tags),
            "document_metadata": {"fuente": fuente} if fuente else {}}


class MemoriaTest(PanelTest):
    def setUp(self):
        super().setUp()
        self.fx = sys.modules["fabrica_fx_memoria"]
        self.comun = sys.modules["fabrica_comun"]
        self.tmp = Path(tempfile.mkdtemp(prefix="fx-memoria-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cfg = {"memoria": {"banco": "ejemplo"}}
        entorno = mock.patch.dict(os.environ, {"FABRIK_MEMORIA_URL": "http://127.0.0.1:9"})
        entorno.start()
        self.addCleanup(entorno.stop)
        os.environ.pop("FABRIK_MEMORIA_BANK", None)
        for parche in (
            mock.patch.object(self.comun, "config", side_effect=lambda: self.cfg),
            mock.patch.object(self.fx, "ahora", return_value=AHORA),
        ):
            parche.start()
            self.addCleanup(parche.stop)

    def cli(self, cuerpo: str):
        """`fabrik-memoria` falso: un script bash con `cuerpo`; recibe los argumentos en "$@"."""
        ruta = self.tmp / "fabrik-memoria"
        ruta.write_text("#!/usr/bin/env bash\n" + cuerpo + "\n", encoding="utf-8")
        ruta.chmod(0o755)
        parche = mock.patch.object(self.fx, "_cli", return_value=str(ruta))
        parche.start()
        self.addCleanup(parche.stop)
        return ruta

    def hindsight(self, documentos, espera=0.0):
        srv = Hindsight(documentos, espera)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        os.environ["FABRIK_MEMORIA_URL"] = srv.url()
        return srv

    def cli_estado(self):
        return self.cli(f"[[ $1 == estado ]] && echo '{json.dumps(ESTADO)}' && echo 'aviso: algo por stderr' >&2")


class TestMemoria(MemoriaTest):
    def test_estado_hoy_por_fuente_y_ultima_entrada(self):
        self.cli_estado()
        srv = self.hindsight([
            doc("tarjeta/t_1", 4, fuente="tarjeta"),
            doc("leccion/a.md", 30, tags=["repo:x", "fuente:leccion"]),
            doc("tarjeta/t_2", 60, fuente="tarjeta"),
            doc("suelto", 90),
        ])
        r = self.client.get("/memoria").json()
        self.assertEqual({k: r[k] for k in ("disponible", "banco", "documentos", "nodos")},
                         {"disponible": True, "banco": "ejemplo", "documentos": 451, "nodos": 14595})
        self.assertEqual(r["ultima_entrada"]["id"], "tarjeta/t_1")
        self.assertEqual(r["ultima_entrada"]["fuente"], "tarjeta")
        self.assertEqual(r["ultima_entrada"]["fecha"], srv.documentos[0]["created_at"])
        self.assertEqual(r["hoy"], {"tarjeta": 2, "leccion": 1, "otra": 1})
        rutas = [p for p, _ in srv.peticiones]
        self.assertTrue(all(p == "/v1/default/banks/ejemplo/documents" for p in rutas), rutas)
        self.assertNotIn("grafo_url", r)

    def test_hoy_pide_desde_medianoche_local_por_fecha_de_creacion(self):
        self.cli_estado()
        srv = self.hindsight([doc("a", 1)])
        self.client.get("/memoria")
        q = [q for _, q in srv.peticiones if "start_date" in q][0]
        desde = dt.datetime.fromisoformat(q["start_date"][0])
        self.assertEqual((desde.hour, desde.minute, desde.second), (0, 0, 0))
        self.assertEqual(desde.date(), AHORA.date())
        self.assertIsNotNone(desde.utcoffset())
        self.assertEqual(q["time_field"], ["created_at"])

    def test_sin_entradas_hoy_no_lista_y_hoy_vacio(self):
        self.cli_estado()
        srv = self.hindsight([doc("viejo", 60 * 24 * 3)])
        r = self.client.get("/memoria").json()
        self.assertEqual((r["hoy"], r["ultima_entrada"]["id"]), ({}, "viejo"))
        self.assertEqual(len(srv.peticiones), 1, "sin entradas hoy no hace falta pedir la lista de hoy")

    def test_banco_de_entorno_manda_y_se_escapa_en_la_url(self):
        self.cli_estado()
        srv = self.hindsight([])
        with mock.patch.dict(os.environ, {"FABRIK_MEMORIA_BANK": "otro banco"}):
            r = self.client.get("/memoria").json()
        self.assertEqual(r["banco"], "otro banco")
        self.assertEqual(srv.peticiones[0][0], "/v1/default/banks/otro%20banco/documents")
        self.assertNotIn("ultima_entrada", r)

    def test_grafo_url_de_la_config_con_banco(self):
        self.cli_estado()
        self.hindsight([])
        self.cfg = {"memoria": {"banco": "ejemplo", "grafo_url": "http://127.0.0.1:9999/banks/{banco}?vista=grafo"}}
        self.assertEqual(self.client.get("/memoria").json()["grafo_url"], "http://127.0.0.1:9999/banks/ejemplo?vista=grafo")
        self.cfg = {"memoria": {"banco": "ejemplo", "grafo_url": "javascript:alert(1)"}}
        self.assertNotIn("grafo_url", self.client.get("/memoria").json())

    def test_api_documentos_caida_no_quita_el_estado(self):
        self.cli_estado()  # FABRIK_MEMORIA_URL apunta a un puerto cerrado
        r = self.client.get("/memoria").json()
        self.assertEqual((r["disponible"], r["documentos"], r["hoy"]), (True, 451, {}))


class TestMemoriaCaida(MemoriaTest):
    """AC-6: sin memoria el bloque dice «no disponible» en < 2 s y no bloquea nada más."""

    def medir(self, ruta="/memoria", **kw):
        t0 = time.monotonic()
        r = self.client.post(ruta, **kw) if "json" in kw else self.client.get(ruta)
        return r, time.monotonic() - t0

    def test_cli_colgado_no_disponible_en_menos_de_2s(self):
        self.cli("sleep 10")
        r, t = self.medir()
        self.assertLess(t, 2.0)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["disponible"])
        self.assertIn("timeout", r.json()["motivo"])

    def test_hindsight_colgado_tras_estado_no_pasa_de_2s(self):
        self.cli_estado()
        self.hindsight([doc("a", 1)], espera=5)
        r, t = self.medir()
        self.assertLess(t, 2.0)
        self.assertEqual((r.json()["disponible"], r.json()["documentos"]), (True, 451))

    def test_fabrik_memoria_real_con_hindsight_apagado(self):
        with mock.patch.object(self.fx, "_cli", return_value=str(RAIZ / "bin" / "fabrik-memoria")):
            with mock.patch.dict(os.environ, {"FABRIK_MEMORIA_URL": "http://127.0.0.1:9", "FABRIK_MEMORIA_BANK": "ejemplo"}):
                r, t = self.medir()
        self.assertLess(t, 2.0)
        self.assertFalse(r.json()["disponible"])
        self.assertIn("memoria no disponible", r.json()["motivo"])

    def test_sin_fabrik_memoria(self):
        with mock.patch.object(self.fx, "_cli", return_value=str(self.tmp / "no-existe")):
            r, t = self.medir()
        self.assertLess(t, 2.0)
        self.assertEqual(r.json()["disponible"], False)

    def test_buscar_con_memoria_caida_no_disponible_en_menos_de_2s(self):
        self.cli("sleep 10")
        r, t = self.medir("/memoria/buscar", json={"q": "flakes"})
        self.assertLess(t, 2.0)
        self.assertEqual((r.json()["disponible"], r.json()["texto"]), (False, ""))


class TestBuscar(MemoriaTest):
    def test_recall_devuelve_el_texto_sin_avisos(self):
        self.cli_estado()
        args = self.tmp / "args"
        self.cli(f"""case $1 in
  estado) echo '{json.dumps(ESTADO)}' ;;
  recall) printf '%s\\n' "$@" > {args}; echo '- [api 2026-10-01] usa travelTo'; echo 'aviso: sin memoria.banco' >&2 ;;
esac""")
        r = self.client.post("/memoria/buscar", json={"q": "  -relojes congelados  "})
        self.assertEqual(r.json(), {"disponible": True, "texto": "- [api 2026-10-01] usa travelTo"})
        self.assertEqual(args.read_text().splitlines(), ["recall", "--max", str(self.fx.MAX_TOKENS), "--", "-relojes congelados"])

    def test_recall_que_dice_memoria_no_disponible(self):
        self.cli(ESTADO_Y_RECALL % "echo '(memoria no disponible: URLError; sigue sin ella)'")
        r = self.client.post("/memoria/buscar", json={"q": "x"}).json()
        self.assertEqual((r["disponible"], r["texto"]), (False, ""))
        self.assertIn("memoria no disponible", r["motivo"])

    def test_recall_sin_resultados_es_texto_vacio(self):
        self.cli(ESTADO_Y_RECALL % "echo '(sin resultados)'")
        self.assertEqual(self.client.post("/memoria/buscar", json={"q": "x"}).json(), {"disponible": True, "texto": ""})

    def test_q_vacia_o_larga_es_400_sin_llamar_a_nada(self):
        marca = self.tmp / "llamado"
        self.cli(f"touch {marca}")
        for q in ("", "   ", "x" * 501):
            with self.subTest(q=q[:5]):
                self.assertEqual(self.client.post("/memoria/buscar", json={"q": q}).status_code, 400)
        self.assertEqual(self.client.post("/memoria/buscar", json={}).status_code, 422)
        self.assertFalse(marca.exists())


class TestRegistro(PanelTest):
    def test_rutas_registradas(self):
        self.assertLessEqual({"/memoria", "/memoria/buscar"}, {r.path for r in self.api.router.routes})

    def test_cli_por_defecto_es_el_del_motor(self):
        fx = sys.modules["fabrica_fx_memoria"]
        self.assertEqual(Path(fx._cli()).resolve(), (RAIZ / "bin" / "fabrik-memoria").resolve())


if __name__ == "__main__":
    import unittest

    unittest.main()
