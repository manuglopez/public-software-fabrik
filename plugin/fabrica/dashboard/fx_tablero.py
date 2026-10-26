"""The Factory — Inicio · tablero (IMPL-2): «Te toca a ti» (AC-3a) y «En marcha» (AC-3d).

    GET /inicio/te-toca    {items:[{tipo:"plan"|"merge"|"bloqueada", board, task_id, titulo, detalle, pregunta?, pr_url?}]}
    GET /inicio/en-marcha  {activos, maximo, grupos:[{board, pausa?:{hasta, aparcadas},
                            items:[{task_id, titulo, rol, modelo, desde, llamadas, herramientas, worktree?}]}]}

Todo en solo lectura (`comun.conectar_ro`). Un tablero que no se puede leer se salta; sin `gh` o sin red no hay
elementos `merge` y lo demás sigue (AC-6). Tableros, perfiles y modelos salen de Hermes; nada fijo.
"""
from __future__ import annotations

import json
import logging
import os
import re
import shutil
import threading
import time
from concurrent.futures import ThreadPoolExecutor, wait
from contextlib import closing
from pathlib import Path

import fabrica_comun as comun

log = logging.getLogger(__name__)

GH_TIMEOUT = 5  # s por `gh pr view`
GH_ESPERA = 6  # s que espera la petición a gh; lo que llegue tarde queda en caché para la siguiente
GH_TTL_ABIERTO = 60  # s que se recuerda un PR abierto; cerrado o mergeado se recuerda siempre
PLAN = re.compile(r"^PLAN(?![A-Za-z])")
PR = re.compile(r"^PR(?![A-Za-z])")
BLOQUEOS = ("needs_input", "capability")

_gh_cache: dict[str, tuple[str, str, float]] = {}  # url → (state, url, cuándo)
_gh_lock = threading.Lock()
_gh_pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="fabrica-gh")


def hay_gh() -> bool:
    return shutil.which("gh") is not None


def _raiz_hermes() -> Path:
    """Raíz de Hermes (la del perfil por defecto, donde viven `config.yaml` y `profiles/`)."""
    try:
        from hermes_constants import get_default_hermes_root

        return Path(get_default_hermes_root())
    except Exception:  # noqa: BLE001 - sin el núcleo (tests, servidor suelto): por entorno
        return Path(os.environ.get("HERMES_HOME") or "~/.hermes").expanduser()


def _yaml(ruta: Path) -> dict:
    try:
        datos = comun.yaml_safe_load(ruta.read_text(encoding="utf-8"))
        return datos if isinstance(datos, dict) else {}
    except Exception:  # noqa: BLE001 - sin fichero o roto: sin datos
        return {}


def _modelo_perfil(rol: str | None, cache: dict) -> str | None:
    if not rol or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", rol):
        return None
    if rol not in cache:
        raiz = _raiz_hermes()
        cfg = _yaml(raiz / "config.yaml" if rol == "default" else raiz / "profiles" / rol / "config.yaml")
        m = cfg.get("model")
        cache[rol] = m if isinstance(m, str) else (m.get("default") or m.get("model")) if isinstance(m, dict) else None
    return cache[rol]


def _maximo() -> int | None:
    """`kanban.max_in_progress`; sin fijar, el que aplica el dispatcher de Hermes (derivado de la memoria) si está."""
    try:
        n = int(_yaml(_raiz_hermes() / "config.yaml").get("kanban", {}).get("max_in_progress"))
        if n >= 1:
            return n
    except (TypeError, ValueError, AttributeError):
        pass
    try:
        from hermes_cli.kanban_db_dispatch import resolve_max_in_progress

        n = resolve_max_in_progress(None)
        return n if isinstance(n, int) and n >= 1 else None
    except Exception:  # noqa: BLE001 - sin el núcleo: sin máximo
        return None


def _json(texto) -> dict:
    try:
        d = json.loads(texto or "")
        return d if isinstance(d, dict) else {}
    except (TypeError, ValueError):
        return {}


def _primera_linea(texto) -> str:
    return next((l.strip() for l in str(texto or "").splitlines() if l.strip()), "")


def _motivo(con, task_id: str) -> str:
    fila = con.execute(
        "SELECT payload FROM task_events WHERE task_id=? AND kind='blocked' ORDER BY id DESC LIMIT 1", (task_id,)
    ).fetchone()
    return _primera_linea(_json(fila["payload"]).get("reason")) if fila else ""


def _leer(fn) -> list:
    """Aplica `fn(slug, con)` a cada tablero en solo lectura; un tablero que falla se salta (AC-6)."""
    salida = []
    for slug, ruta in comun.tableros():
        try:
            with closing(comun.conectar_ro(ruta)) as con:
                salida.append(fn(slug, con))
        except Exception:  # noqa: BLE001 - tablero roto o con otro esquema
            log.warning("fabrica: no se pudo leer el tablero %s", slug, exc_info=True)
    return salida


# ---------------------------------------------------------------- Te toca a ti
def _estado_pr(url: str) -> tuple[str, str] | None:
    """(state, url) de `gh pr view`, con caché; None si gh no responde."""
    with _gh_lock:
        c = _gh_cache.get(url)
    if c and (c[0] != "OPEN" or time.monotonic() - c[2] < GH_TTL_ABIERTO):
        return c[0], c[1]
    ok, salida = comun.ejecutar(["gh", "pr", "view", url, "--json", "state,url"], timeout=GH_TIMEOUT)
    datos = _json(salida) if ok else {}
    if not datos.get("state"):
        return None
    res = (str(datos["state"]).upper(), str(datos.get("url") or url))
    with _gh_lock:
        _gh_cache[url] = (*res, time.monotonic())
    return res


def _te_toca_tablero(slug, con) -> list[dict]:
    items = []
    for t in con.execute(
        "SELECT id, title, status, block_kind FROM tasks WHERE status IN ('blocked','done') ORDER BY created_at, id"
    ):
        titulo = t["title"] or ""
        base = {"board": slug, "task_id": t["id"], "titulo": titulo}
        if t["status"] == "blocked" and t["block_kind"] in BLOQUEOS:
            motivo = _motivo(con, t["id"])
            if PLAN.match(titulo) and t["block_kind"] == "needs_input":
                plan = {"tipo": "plan", **base, "detalle": "Plan esperando tu aprobación"}
                items.append({**plan, "pregunta": motivo} if motivo else plan)
            else:
                detalle = f"{t['block_kind']} · {motivo}" if motivo else t["block_kind"]
                items.append({"tipo": "bloqueada", **base, "detalle": detalle})
        elif t["status"] == "done" and PR.match(titulo):
            fila = con.execute(
                "SELECT metadata FROM task_runs WHERE task_id=? AND metadata LIKE '%published_pr%' ORDER BY id DESC LIMIT 1",
                (t["id"],),
            ).fetchone()
            url = _json(fila["metadata"]).get("published_pr") if fila else None
            if isinstance(url, str) and url.startswith("https://"):
                items.append({"tipo": "merge", **base, "pr_url": url})
    return items


def te_toca() -> dict:
    items = [i for grupo in _leer(_te_toca_tablero) for i in grupo]
    merges = [i for i in items if i["tipo"] == "merge"]
    estados: dict[str, tuple[str, str] | None] = {}
    if merges and hay_gh():
        urls = list(dict.fromkeys(i["pr_url"] for i in merges))
        futuros = {u: _gh_pool.submit(_estado_pr, u) for u in urls}
        wait(futuros.values(), timeout=GH_ESPERA)
        for u, f in futuros.items():
            estados[u] = f.result() if f.done() and not f.exception() else None
    vistos, abiertos = set(), []
    for i in merges:
        est = estados.get(i["pr_url"])
        if est and est[0] == "OPEN" and est[1] not in vistos:
            vistos.add(est[1])
            n = est[1].rstrip("/").rsplit("/", 1)[-1]
            abiertos.append({**i, "detalle": f"PR #{n} abierto, listo para merge", "pr_url": est[1]})
    orden = {"plan": 0, "merge": 1, "bloqueada": 2}
    resto = [i for i in items if i["tipo"] != "merge"]
    return {"items": sorted(resto + abiertos, key=lambda i: orden[i["tipo"]])}


# ---------------------------------------------------------------- En marcha
def _sesion(con, task_id: str, run_id, cache: dict) -> tuple[int | None, int | None]:
    """(llamadas al modelo, herramientas) de la sesión del worker: evento `owner_admitted` → su state.db (ro)."""
    if run_id is not None:
        fila = con.execute(
            "SELECT payload FROM task_events WHERE task_id=? AND run_id=? AND kind='owner_admitted' ORDER BY id DESC LIMIT 1",
            (task_id, run_id),
        ).fetchone()
    else:
        fila = con.execute(
            "SELECT payload FROM task_events WHERE task_id=? AND kind='owner_admitted' ORDER BY id DESC LIMIT 1", (task_id,)
        ).fetchone()
    p = _json(fila["payload"]) if fila else {}
    db, sesion = p.get("db"), p.get("session_id")
    if not isinstance(db, str) or not isinstance(sesion, str):
        return None, None
    ruta = Path(db)
    if not ruta.is_absolute() or ruta.name != "state.db" or not ruta.is_file():
        return None, None
    try:
        if db not in cache:
            cache[db] = comun.conectar_ro(ruta)
        s = cache[db].execute("SELECT api_call_count, tool_call_count FROM sessions WHERE id=?", (sesion,)).fetchone()
        return (s["api_call_count"], s["tool_call_count"]) if s else (None, None)
    except Exception:  # noqa: BLE001 - state.db bloqueado o con otro esquema
        return None, None


def _pausa(slug: str, con) -> dict | None:
    """Pausa nocturna: `pausa-tableros.tsv` (tablero, tarjeta, perfil) activo mientras no exista `pausa-tableros.fin`."""
    d = comun.fabrik_data()
    tsv = d / "pausa-tableros.tsv"
    if not tsv.is_file() or (d / "pausa-tableros.fin").exists():
        return None
    try:
        en_revision = sum(1 for l in tsv.read_text(encoding="utf-8").splitlines() if l.split("\t", 1)[0] == slug)
    except OSError:
        en_revision = 0
    aparcadas = con.execute("SELECT count(*) FROM tasks WHERE status='scheduled'").fetchone()[0] + en_revision
    return {"hasta": None, "aparcadas": aparcadas} if aparcadas else None


def en_marcha() -> dict:
    modelos, sesiones = {}, {}

    def grupo(slug, con):
        items = []
        for t in con.execute(
            "SELECT t.id, t.title, t.assignee, t.model_override, t.workspace_kind, t.workspace_path, t.started_at,"
            " t.current_run_id, r.started_at AS run_desde FROM tasks t LEFT JOIN task_runs r ON r.id = t.current_run_id"
            " WHERE t.status='running' ORDER BY COALESCE(r.started_at, t.started_at), t.id"
        ):
            llamadas, herramientas = _sesion(con, t["id"], t["current_run_id"], sesiones)
            item = {
                "task_id": t["id"], "titulo": t["title"], "rol": t["assignee"],
                "modelo": t["model_override"] or _modelo_perfil(t["assignee"], modelos),
                "desde": t["run_desde"] or t["started_at"], "llamadas": llamadas, "herramientas": herramientas,
            }
            if t["workspace_kind"] == "dir" and t["workspace_path"]:
                item["worktree"] = t["workspace_path"]
            items.append(item)
        g = {"board": slug, "items": items}
        pausa = _pausa(slug, con)
        if pausa:
            g["pausa"] = pausa
        return g if items or pausa else None

    try:
        grupos = [g for g in _leer(grupo) if g]
    finally:
        for c in sesiones.values():
            c.close()
    return {"activos": sum(len(g["items"]) for g in grupos), "maximo": _maximo(), "grupos": grupos}


def registrar(router) -> None:
    router.add_api_route("/inicio/te-toca", te_toca, methods=["GET"])
    router.add_api_route("/inicio/en-marcha", en_marcha, methods=["GET"])
