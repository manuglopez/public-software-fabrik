"""The Factory — Memoria en Inicio (AC-3g) y memoria opcional (AC-6): `GET /memoria` y `POST /memoria/buscar`.

- Estado (documentos, nodos) con `fabrik-memoria estado`; última entrada y «hoy por fuente» con la API local de
  Hindsight (`FABRIK_MEMORIA_URL`, como la CLI: `/v1/default/banks/<banco>/documents`). Todo dentro de PRESUPUESTO s:
  con Hindsight caído o colgado el bloque dice «no disponible» en < 2 s.
- Buscar = `fabrik-memoria recall` tras comprobar el estado (si la memoria no responde, «no disponible» en < 2 s). El
  recall real tarda decenas de segundos con un banco grande: su timeout es TIMEOUT_RECALL, no el de AC-6.
- `grafo_url` = `memoria.grafo_url` de la config (Control Plane de Hindsight; `{banco}` se sustituye) si es http(s).
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import os
import shutil
import time
import urllib.request
from collections import Counter
from urllib.parse import quote, urlencode

import fabrica_comun as comun
from fastapi import HTTPException
from pydantic import BaseModel

PRESUPUESTO = 1.5  # s para GET /memoria entero y para la comprobación previa de buscar (AC-6: < 2 s)
TIMEOUT_RECALL = 60
MAX_TOKENS = 400  # `comun.ejecutar` devuelve los últimos MAX_SALIDA (2000) caracteres: así el recall cabe entero
MAX_Q = 500
URL_POR_DEFECTO = "http://127.0.0.1:8888"
NO_DISPONIBLE = "(memoria no disponible"

log = logging.getLogger(__name__)


class Busqueda(BaseModel):
    q: str


def ahora() -> dt.datetime:
    return dt.datetime.now().astimezone()


def _cli() -> str:
    """La CLI del mismo motor que el plugin; si no está, la del PATH."""
    propia = comun.fabrik_home() / "bin" / "fabrik-memoria"
    return str(propia) if propia.is_file() else (shutil.which("fabrik-memoria") or str(propia))


def _memoria_cfg() -> dict:
    cfg = comun.config().get("memoria")
    return cfg if isinstance(cfg, dict) else {}


def _banco() -> str:
    """El mismo banco que usa la CLI: FABRIK_MEMORIA_BANK, si no `memoria.banco`, si no «fabrica»."""
    return os.environ.get("FABRIK_MEMORIA_BANK") or str(_memoria_cfg().get("banco") or "fabrica")


def _estado(timeout: float) -> tuple[dict | None, str]:
    """(estado de `fabrik-memoria estado`, "") o (None, motivo). La CLI sale 0 aunque no haya memoria."""
    ok, salida = comun.ejecutar([_cli(), "estado"], timeout=timeout)
    texto = salida.lstrip()
    if ok and texto.startswith("{"):
        try:
            datos, _ = json.JSONDecoder().raw_decode(texto)
            if isinstance(datos, dict):
                return datos, ""
        except ValueError:
            pass
    return None, (texto.splitlines() or ["sin respuesta de fabrik-memoria"])[0][:200]


def _api(banco: str, ruta: str, params: dict, timeout: float) -> dict:
    if timeout <= 0.05:
        raise TimeoutError("sin tiempo")
    base = (os.environ.get("FABRIK_MEMORIA_URL") or URL_POR_DEFECTO).rstrip("/")
    url = f"{base}/v1/default/banks/{quote(banco, safe='')}{ruta}?{urlencode(params)}"
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


def _fuente(doc: dict) -> str:
    meta = doc.get("document_metadata") or {}
    etiqueta = next((t[len("fuente:"):] for t in doc.get("tags") or [] if str(t).startswith("fuente:")), None)
    return str(meta.get("fuente") or etiqueta or "otra")


def _grafo(banco: str) -> str | None:
    url = str(_memoria_cfg().get("grafo_url") or "")
    return url.replace("{banco}", quote(banco, safe="")) if url.startswith(("http://", "https://")) else None


def memoria() -> dict:
    t0 = time.monotonic()
    datos, motivo = _estado(PRESUPUESTO)
    if datos is None:
        return comun.no_disponible(motivo)
    banco = _banco()
    res = {"disponible": True, "banco": banco, "documentos": datos.get("total_documents"),
           "nodos": datos.get("total_nodes"), "hoy": {}}
    def resto() -> float:
        return PRESUPUESTO - (time.monotonic() - t0)

    try:
        ultimos = _api(banco, "/documents", {"time_field": "created_at", "limit": 1}, resto()).get("items") or []
        if ultimos:
            d = ultimos[0]
            res["ultima_entrada"] = {"id": d.get("id"), "fecha": d.get("created_at"), "fuente": _fuente(d)}
            medianoche = ahora().replace(hour=0, minute=0, second=0, microsecond=0)
            if dt.datetime.fromisoformat(str(d.get("created_at"))) >= medianoche:
                params = {"time_field": "created_at", "start_date": medianoche.isoformat(), "limit": 1000}
                hoy = _api(banco, "/documents", params, resto()).get("items") or []
                res["hoy"] = dict(Counter(_fuente(x) for x in hoy))
    except Exception as e:  # noqa: BLE001 - sin la API el estado de la CLI basta
        log.debug("fabrica: memoria sin detalle de documentos: %s", e)
    grafo = _grafo(banco)
    if grafo:
        res["grafo_url"] = grafo
    return res


def buscar(b: Busqueda) -> dict:
    q = b.q.strip()
    if not q or len(q) > MAX_Q:
        raise HTTPException(status_code=400, detail=f"q vacía o de más de {MAX_Q} caracteres")
    datos, motivo = _estado(PRESUPUESTO)
    if datos is None:
        return {**comun.no_disponible(motivo), "texto": ""}
    ok, salida = comun.ejecutar([_cli(), "recall", "--max", str(MAX_TOKENS), "--", q], timeout=TIMEOUT_RECALL)
    texto = "\n".join(linea for linea in salida.splitlines() if not linea.startswith("aviso:")).strip()
    if not ok or texto.startswith(NO_DISPONIBLE):
        return {**comun.no_disponible(texto[:200] or "sin respuesta de fabrik-memoria"), "texto": ""}
    return {"disponible": True, "texto": "" if texto == "(sin resultados)" else texto}


def registrar(router) -> None:
    router.get("/memoria")(memoria)
    router.post("/memoria/buscar")(buscar)
