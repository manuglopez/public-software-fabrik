"""The Factory · Atascadas y Cadena (AC-3b, AC-3c): `GET /inicio/atascadas` y `GET /inicio/cadena`.

Solo lectura: SQLite en `mode=ro` (`comun.conectar_ro`) y, para el estado de un PR, `gh` vía `comun.ejecutar`.
Las acciones que proponen (desatascar, set_model) las ejecuta `fx_acciones.py`; aquí nunca se escribe.
"""
from __future__ import annotations

import datetime
import importlib.util
import json
import re
import sqlite3
import sys
import time
from contextlib import closing
from pathlib import Path

import fabrica_comun as comun

MINUTOS_SIN_RUN = 10          # una tarjeta en review sin run desde hace más de esto está atascada
TOPE_RESERVA = 90             # % por debajo del cual una bolsa sirve para pasar a otro modelo
PATRON_CUPO = re.compile(r"rate.?limit|quota|429|usage limit|cupo|exhausted", re.IGNORECASE)
VIGILANTE = re.compile(r"\s*·\s*⏳.*$")  # « · ⏳ tras IMPL-2…» que añade el vigilante a los títulos
RAMAS_POR_DEFECTO = ("main", "master", "develop")  # si `gh repo view` no responde
PR_URL = re.compile(r"^https://github\.com/([\w.\-]+/[\w.\-]+)/pull/\d+/?$")
MAX_NODOS = 60
GH_TTL_ABIERTO = 60  # s que se reutiliza un PR abierto (refresco cada 15 s); uno cerrado o mergeado, para siempre

_cupos_mod = None
_prs: dict[str, tuple[float, dict | None]] = {}  # url → (cuándo, entrada del PR abierto | None si ya no lo está)


def _ahora() -> float:
    return time.time()


def _cupos():
    """`scripts/cupos.py` del repo de la fábrica (único sitio de bolsas y cadenas); None si no se puede cargar."""
    global _cupos_mod
    if _cupos_mod is None:
        try:
            ruta = comun.fabrik_home() / "scripts" / "cupos.py"
            spec = importlib.util.spec_from_file_location("fabrica_cupos", ruta)
            mod = importlib.util.module_from_spec(spec)
            sys.modules["fabrica_cupos"] = mod
            spec.loader.exec_module(mod)
            _cupos_mod = mod
        except Exception:  # noqa: BLE001 - sin cupos.py no hay detección de sin_cupo, el resto sigue
            sys.modules.pop("fabrica_cupos", None)
            return None
    return _cupos_mod


def _etiqueta(titulo: str) -> str:
    """`IMPL-3` de «IMPL-3 The Factory: … · ⏳ tras IMPL-2»."""
    limpio = VIGILANTE.sub("", titulo or "").strip()
    return limpio.split(" ", 1)[0] if limpio else ""


def _titulo_limpio(titulo: str) -> str:
    return VIGILANTE.sub("", titulo or "").strip()


def _worktree(fila) -> str | None:
    ruta = fila["workspace_path"] if "workspace_path" in fila.keys() else None
    return ruta if ruta and fila["workspace_kind"] != "scratch" else None


def _con_worktree(item: dict, fila) -> dict:
    ruta = _worktree(fila)
    if ruta:
        item["worktree"] = ruta
    return item


# ---- error viejo de cupo en revisión ---------------------------------------------------------------------------

def _error_cupo(con, slug: str, ahora: float) -> list[dict]:
    items = []
    filas = con.execute(
        "SELECT id, title, assignee, last_failure_error, workspace_kind, workspace_path FROM tasks"
        " WHERE status = 'review' AND last_failure_error IS NOT NULL AND last_failure_error != '' ORDER BY id"
    ).fetchall()
    for f in filas:
        if not PATRON_CUPO.search(f["last_failure_error"]):
            continue
        runs = con.execute(
            "SELECT MAX(COALESCE(ended_at, started_at)) AS ultimo, SUM(ended_at IS NULL) AS activos"
            " FROM task_runs WHERE task_id = ?", (f["id"],)
        ).fetchone()
        if runs["activos"]:
            continue  # hay un run en marcha: el error no es viejo
        if runs["ultimo"] is not None and ahora - runs["ultimo"] <= MINUTOS_SIN_RUN * 60:
            continue
        detalle = f["last_failure_error"].strip().splitlines()[0][:160]
        if runs["ultimo"] is not None:
            detalle += f" · sin run desde hace {int((ahora - runs['ultimo']) // 60)} min"
        item = {
            "board": slug, "task_id": f["id"], "titulo": f["title"], "motivo": "error_cupo_revision", "detalle": detalle,
        }
        if f["assignee"]:
            item["accion"] = {"tipo": "desatascar"}
        items.append(_con_worktree(item, f))
    return items


# ---- sin cupo ----------------------------------------------------------------------------------------------------

def _iso_a_ts(valor) -> float | None:
    try:
        return datetime.datetime.fromisoformat(str(valor).replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return None


def _bolsa_libre(bolsas: dict, nombre: str, ahora: float) -> bool:
    """Una bolsa sirve si no está en la foto, si su reset ya pasó o si está por debajo de TOPE_RESERVA %."""
    val = bolsas.get(nombre)
    if not isinstance(val, (list, tuple)) or len(val) < 2:
        return True
    try:
        pct = float(val[0])
    except (TypeError, ValueError):
        return True
    reset = _iso_a_ts(val[1])
    return pct < TOPE_RESERVA or reset is None or reset <= ahora


def _modelos_permitidos(cfg: dict) -> set[tuple[str, str]]:
    """Mismo conjunto que acepta `POST /acciones/set-model` (lo calcula fx_acciones)."""
    mod = sys.modules.get("fabrica_fx_acciones")
    if mod is None:
        spec = importlib.util.spec_from_file_location("fabrica_fx_acciones_lib", Path(__file__).with_name("fx_acciones.py"))
        mod = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = mod
        try:
            spec.loader.exec_module(mod)
        finally:
            sys.modules.pop(spec.name, None)
    return mod.modelos_configurados(cfg)


def _sin_cupo(con, slug: str, ahora: float, ctx: dict) -> list[dict]:
    cupos, foto = ctx["cupos"], ctx["foto"]
    if cupos is None or foto is None:
        return []
    items = []
    filas = con.execute(
        "SELECT t.id, t.title, t.assignee, t.model_override, t.provider_override, t.workspace_kind, t.workspace_path"
        " FROM tasks t JOIN task_runs r ON r.id = (SELECT MAX(id) FROM task_runs WHERE task_id = t.id)"
        " WHERE t.status = 'ready' AND r.outcome = 'rate_limited' ORDER BY t.id"
    ).fetchall()
    for f in filas:
        cadena = cupos.cadena_de(f["assignee"] or "", f["model_override"], f["provider_override"])
        lanzable, bolsa, renueva, agotadas = cupos.estado_cadena(cadena, foto, ahora)
        if lanzable:
            continue  # el último run chocó con el cupo, pero ya hay un modelo de la cadena con margen
        detalle = "Bolsas agotadas: " + ", ".join(agotadas)
        item = {"board": slug, "task_id": f["id"], "titulo": f["title"], "motivo": "sin_cupo"}
        reserva = ctx["reserva"]
        propuesta = next(
            ((p, m) for p, m in dict.fromkeys(cadena + reserva)
             if (p, m) in ctx["permitidos"]
             and all(_bolsa_libre(foto.get("bolsas", {}), b, ahora) for b in cupos.bolsas_de(p, m))),
            None,
        )
        if propuesta:
            item["accion"] = {"tipo": "set_model", "proveedor": propuesta[0], "modelo": propuesta[1]}
        else:
            detalle += f" · renueva {bolsa} {renueva}"
        item["detalle"] = detalle
        items.append(_con_worktree(item, f))
    return items


# ---- esperando merge ------------------------------------------------------------------------------------------

def _pr_publicado(con, task_id: str) -> str | None:
    """`metadata.published_pr` del último run de la tarjeta que lo declara."""
    for fila in con.execute("SELECT metadata FROM task_runs WHERE task_id = ? ORDER BY id DESC", (task_id,)):
        try:
            meta = json.loads(fila["metadata"] or "{}")
        except (TypeError, ValueError):
            continue
        url = meta.get("published_pr") if isinstance(meta, dict) else None
        if isinstance(url, str) and PR_URL.match(url):
            return url
    return None


def _json_de(salida: str):
    try:
        return json.loads(salida)
    except ValueError:
        return None


def _rama_por_defecto(repo: str, cache: dict) -> tuple[str, ...]:
    if repo not in cache:
        ok, salida = comun.ejecutar(["gh", "repo", "view", repo, "--json", "defaultBranchRef"], 5)
        datos = _json_de(salida) if ok else None
        nombre = ((datos or {}).get("defaultBranchRef") or {}).get("name") if isinstance(datos, dict) else None
        cache[repo] = (nombre,) if nombre else RAMAS_POR_DEFECTO
    return cache[repo]


def _apilado_sobre(repo: str, base: str) -> str:
    """`#N` del PR abierto cuya rama es la base de este; si no se encuentra, el nombre de la rama."""
    ok, salida = comun.ejecutar(
        ["gh", "pr", "list", "-R", repo, "--head", base, "--state", "open", "--json", "number", "--limit", "1"], 5
    )
    datos = _json_de(salida) if ok else None
    if isinstance(datos, list) and datos and isinstance(datos[0], dict) and datos[0].get("number"):
        return f"#{datos[0]['number']}"
    return base


def _pr_abierto(url: str, repo: str, ctx: dict) -> dict | None:
    """`{numero, url[, apilado_sobre]}` si el PR está abierto; None si no lo está o gh no responde (eso no se recuerda)."""
    c = _prs.get(url)
    if c and (c[1] is None or _ahora() - c[0] < GH_TTL_ABIERTO):
        return c[1]
    ok, salida = comun.ejecutar(["gh", "pr", "view", url, "--json", "state,baseRefName,number,url"], 5)
    pr = _json_de(salida) if ok else None
    if not isinstance(pr, dict) or not pr.get("state"):
        return None
    entrada = None
    if pr["state"] == "OPEN":
        entrada = {"numero": pr.get("number"), "url": pr.get("url") or url}
        base = pr.get("baseRefName")
        if base and base not in _rama_por_defecto(repo, ctx["ramas"]):
            entrada["apilado_sobre"] = _apilado_sobre(repo, base)
    _prs[url] = (_ahora(), entrada)
    return entrada


def _esperando_merge(con, slug: str, ctx: dict) -> list[dict]:
    items = []
    for f in con.execute(
        "SELECT id, title, workspace_kind, workspace_path FROM tasks WHERE status = 'todo' ORDER BY id"
    ).fetchall():
        padres = con.execute(
            "SELECT p.id, p.title, p.status FROM task_links l JOIN tasks p ON p.id = l.parent_id WHERE l.child_id = ?",
            (f["id"],),
        ).fetchall()
        pendientes = [p for p in padres if p["status"] != "done"]
        if len(pendientes) != 1:
            continue
        url = _pr_publicado(con, pendientes[0]["id"])
        m = PR_URL.match(url or "")
        if not m:
            continue
        entrada = _pr_abierto(m.group(0), m.group(1), ctx)
        if entrada is None:
            continue  # cerrado o mergeado, o gh no responde: no se acusa sin verlo
        detalle = f"Espera el merge del PR #{entrada['numero']} ({_etiqueta(pendientes[0]['title'])})"
        if "apilado_sobre" in entrada:
            detalle += f" · apilado sobre {entrada['apilado_sobre']}"
        items.append({
            "board": slug, "task_id": f["id"], "titulo": f["title"], "motivo": "esperando_merge", "detalle": detalle,
            "accion": {"tipo": "ver_prs", "prs": [entrada]},
        })
    return items


def atascadas() -> dict:
    tableros = comun.tableros()
    if not tableros:
        return comun.no_disponible("sin tableros de Kanban")
    ahora = _ahora()
    cupos = _cupos()
    foto = None
    if cupos is not None:
        foto, _motivo = cupos.ultima_foto(ahora=ahora)
    cfg = comun.config()
    modelos = cfg.get("modelos") if isinstance(cfg.get("modelos"), dict) else {}
    rf = modelos.get("reserva_final")
    reserva = [(str(rf["proveedor"]), str(rf["modelo"]))] if isinstance(rf, dict) and rf.get("proveedor") and rf.get("modelo") else []
    ctx = {
        "cupos": cupos, "foto": foto, "reserva": reserva, "ramas": {},
        "permitidos": _modelos_permitidos(cfg) if foto is not None else set(),
    }
    items: list[dict] = []
    for slug, ruta in tableros:
        try:
            with closing(comun.conectar_ro(ruta)) as con:
                items += _error_cupo(con, slug, ahora)
                items += _sin_cupo(con, slug, ahora, ctx)
                items += _esperando_merge(con, slug, ctx)
        except sqlite3.Error:
            continue  # un tablero ilegible no tumba el resto
    return {"items": items}


# ---- cadena ---------------------------------------------------------------------------------------------------------

def _componente(arranque: str, vecinos: dict[str, set[str]]) -> set[str]:
    visto, pila = {arranque}, [arranque]
    while pila:
        for v in vecinos.get(pila.pop(), ()):
            if v not in visto:
                visto.add(v)
                pila.append(v)
    return visto


def _nombre_feature(titulos: list[str]) -> str:
    """Lo que hay entre la etiqueta y los «:» (`The Factory`), el más repetido de la cadena."""
    cuentas: dict[str, int] = {}
    for t in titulos:
        resto = _titulo_limpio(t).split(" ", 1)[1] if " " in _titulo_limpio(t) else _titulo_limpio(t)
        nombre = resto.split(":", 1)[0].strip()
        if nombre:
            cuentas[nombre] = cuentas.get(nombre, 0) + 1
    return max(cuentas, key=cuentas.get) if cuentas else ""


def _cadenas_de(con, slug: str, ahora: float) -> list[dict]:
    tareas = {
        f["id"]: f for f in con.execute(
            "SELECT id, title, status, started_at, workspace_kind, workspace_path FROM tasks WHERE status != 'archived'"
        )
    }
    vecinos: dict[str, set[str]] = {}
    aristas: list[tuple[str, str]] = []
    for padre, hijo in con.execute("SELECT parent_id, child_id FROM task_links ORDER BY parent_id, child_id"):
        if padre in tareas and hijo in tareas:
            vecinos.setdefault(padre, set()).add(hijo)
            vecinos.setdefault(hijo, set()).add(padre)
            aristas.append((padre, hijo))
    cadenas, vistos = [], set()
    for tid in sorted(t for t, f in tareas.items() if f["status"] == "running"):
        if tid in vistos:
            continue
        miembros = _componente(tid, vecinos)
        vistos |= miembros
        if len(miembros) < 2:
            continue  # una tarjeta suelta no es una cadena
        nodos = []
        for m in sorted(miembros, key=lambda i: (tareas[i]["id"])):
            f = tareas[m]
            estado = "hecho" if f["status"] == "done" else "en_marcha" if f["status"] == "running" else "pendiente"
            nodo = {"task_id": m, "etiqueta": _etiqueta(f["title"]), "estado": estado}
            if estado == "en_marcha" and f["started_at"]:
                nodo["minutos"] = max(0, int((ahora - f["started_at"]) // 60))
            _con_worktree(nodo, f)
            nodos.append(nodo)
        cadenas.append({
            "board": slug,
            "titulo": _nombre_feature([tareas[m]["title"] for m in miembros]) or _titulo_limpio(tareas[tid]["title"]),
            "hechas": sum(1 for n in nodos if n["estado"] == "hecho"),
            "total": len(nodos),
            "nodos": nodos[:MAX_NODOS],
            "aristas": [[p, h] for p, h in aristas if p in miembros and h in miembros],
        })
    return cadenas


def cadena() -> dict:
    tableros = comun.tableros()
    if not tableros:
        return comun.no_disponible("sin tableros de Kanban")
    ahora = _ahora()
    cadenas: list[dict] = []
    for slug, ruta in tableros:
        try:
            with closing(comun.conectar_ro(ruta)) as con:
                cadenas += _cadenas_de(con, slug, ahora)
        except sqlite3.Error:
            continue
    return {"cadenas": cadenas}


def registrar(router) -> None:
    router.add_api_route("/inicio/atascadas", atascadas, methods=["GET"])
    router.add_api_route("/inicio/cadena", cadena, methods=["GET"])
