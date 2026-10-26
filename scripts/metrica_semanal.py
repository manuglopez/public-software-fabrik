#!/usr/bin/env python3
"""Métrica semanal de la fábrica: `fabrik-cupos semana [--dias N] [--json] [--sin-gh]`.

Por tablero de Kanban, en la ventana [ahora − N días, ahora]:
  - coste equivalente por tarjeta terminada y por línea de PR mergeado,
  - rondas de revisión por tarjeta (y por perfil),
  - % de ejecuciones `rate_limited`,
  - ejecuciones de Greptile por PR mergeado (local y GitHub).

Fuentes, siempre en solo lectura: `$FABRIK_KANBAN_BOARDS/*/kanban.db`, las `state.db` de `$FABRIK_STATE_DBS`
(rutas separadas por `:`; por defecto las de los perfiles y la de Hermes), el registro de Greptile
(`$FABRIK_GREPTILE_LOG`) y, salvo `--sin-gh`, `$FABRIK_GH` (por defecto `gh`).

Las funciones de lectura, atribución, agregado y formato son puras (reciben rutas, datos y reloj); solo `main`
lee el entorno.
"""
import argparse
import glob
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from datetime import datetime

# Coste equivalente de una sesión = Σ tokens × peso. La entrada nueva y la escritura de caché cuestan 1; la
# lectura de caché 0,1 (la décima parte); la salida 5. Un token nulo cuenta 0.
PESOS = {"input_tokens": 1.0, "cache_write_tokens": 1.0, "cache_read_tokens": 0.1, "output_tokens": 5.0}

DIAS_DEFECTO = 7
GH_TIMEOUT = 30  # segundos por llamada a gh
SIN_PERFIL = "(sin perfil)"

RE_TARJETA = re.compile(r"kanban task (t_[0-9a-f]{8})", re.IGNORECASE)
RE_PR = re.compile(r"^https?://[^/]+/([^/]+)/([^/]+)/pull/(\d+)")
BOT_GREPTILE = "greptile-apps[bot]"


def avisar(msg):
    sys.stderr.write(f"aviso: {msg}\n")


def coste_eq(input_tokens, cache_write_tokens, cache_read_tokens, output_tokens):
    """Coste equivalente en tokens de una sesión; los nulos valen 0."""
    valores = {"input_tokens": input_tokens, "cache_write_tokens": cache_write_tokens,
               "cache_read_tokens": cache_read_tokens, "output_tokens": output_tokens}
    return sum(PESOS[k] * (v or 0) for k, v in valores.items())


def dividir(a, b):
    """a / b, o None si b es 0."""
    return a / b if b else None


def conectar_ro(ruta):
    return sqlite3.connect(f"file:{os.path.abspath(ruta)}?mode=ro", uri=True, timeout=5)


# ───────────────────────────── lectura ─────────────────────────────

def leer_tablero(ruta):
    """kanban.db → {"tasks": [(id, status, completed_at, branch_name)], "runs": [(task_id, profile, started_at,
    outcome, metadata)]}. Lanza sqlite3.Error si la BD no se puede leer."""
    conn = conectar_ro(ruta)
    try:
        tasks = conn.execute("SELECT id, status, completed_at, branch_name FROM tasks").fetchall()
        runs = conn.execute("SELECT task_id, profile, started_at, outcome, metadata FROM task_runs").fetchall()
    finally:
        conn.close()
    return {"tasks": tasks, "runs": runs}


def tarjeta_de_mensaje(contenido):
    """Primer `t_xxxxxxxx` que sigue a «kanban task » en el mensaje, o None."""
    m = RE_TARJETA.search(contenido or "")
    return m.group(1) if m else None


def leer_sesiones(ruta, desde, hasta):
    """state.db → sesiones `source='kanban'` con started_at en [desde, hasta]: [{id, coste, tarjeta}].
    La tarjeta sale del primer mensaje `user` de la sesión. Lanza sqlite3.Error si la BD no se puede leer."""
    conn = conectar_ro(ruta)
    try:
        filas = conn.execute(
            "SELECT id, input_tokens, cache_write_tokens, cache_read_tokens, output_tokens FROM sessions"
            " WHERE source = 'kanban' AND started_at >= ? AND started_at <= ?", (desde, hasta)).fetchall()
        sesiones = []
        for sid, i, cw, cr, o in filas:
            fila = conn.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'user'"
                                " ORDER BY id LIMIT 1", (sid,)).fetchone()
            sesiones.append({"id": sid, "coste": coste_eq(i, cw, cr, o),
                             "tarjeta": tarjeta_de_mensaje(fila[0] if fila else None)})
    finally:
        conn.close()
    return sesiones


def leer_registro_greptile(ruta):
    """Líneas JSON (objetos) del registro de Greptile con evento «ejecutado». Fichero ausente → []; las líneas
    que no son JSON se ignoran."""
    try:
        with open(ruta, encoding="utf-8", errors="replace") as f:
            lineas = f.read().splitlines()
    except OSError:
        return []
    res = []
    for linea in lineas:
        try:
            d = json.loads(linea)
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("evento") == "ejecutado":
            res.append(d)
    return res


def urls_pr(runs):
    """URLs `metadata.published_pr` de las runs `completed`, sin repetir y en orden de aparición."""
    vistas = []
    for _tid, _perfil, _ini, outcome, metadata in runs:
        if outcome != "completed" or not metadata:
            continue
        try:
            d = json.loads(metadata)
        except (ValueError, TypeError):
            continue
        url = d.get("published_pr") if isinstance(d, dict) else None
        if isinstance(url, str) and url and url not in vistas:
            vistas.append(url)
    return vistas


# ───────────────────────────── gh ─────────────────────────────

def ejecutar_gh(gh, args, timeout=GH_TIMEOUT):
    """gh <args> → objeto JSON, o None (con aviso) si falla, se agota el tiempo o la salida no es JSON."""
    try:
        p = subprocess.run([gh, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        avisar(f"gh {' '.join(args[:3])}: {type(e).__name__}: {str(e)[:100]}")
        return None
    if p.returncode != 0:
        avisar(f"gh {' '.join(args[:3])}: salió con {p.returncode}")
        return None
    try:
        return json.loads(p.stdout)
    except ValueError:
        avisar(f"gh {' '.join(args[:3])}: la salida no es JSON")
        return None


def epoch_iso(texto):
    """'2026-10-25T10:00:00Z' → epoch; None si no es una fecha válida."""
    try:
        return datetime.fromisoformat(texto.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def consultar_pr(url, gh, timeout=GH_TIMEOUT):
    """PR por URL → {owner, repo, additions, deletions, merged_at (epoch o None), rama, github (nº de reviews de
    Greptile en GitHub, solo si está mergeado)}. None (con aviso) si no se puede consultar."""
    m = RE_PR.match(url)
    if not m:
        avisar(f"URL de PR no reconocida: {url}")
        return None
    owner, repo, numero = m.groups()
    d = ejecutar_gh(gh, ["pr", "view", url, "--json", "additions,deletions,mergedAt,headRefName"], timeout)
    if d is None:  # ejecutar_gh ya avisó
        return None
    if not isinstance(d, dict) or not isinstance(d.get("additions"), int) or not isinstance(d.get("deletions"), int):
        avisar(f"gh pr view {url}: respuesta sin additions/deletions")
        return None
    merged = d.get("mergedAt")
    pr = {"owner": owner, "repo": repo, "additions": d["additions"], "deletions": d["deletions"],
          "merged_at": None, "rama": d.get("headRefName"), "github": 0}
    if not merged:
        return pr
    pr["merged_at"] = epoch_iso(merged)
    if pr["merged_at"] is None:
        avisar(f"gh pr view {url}: mergedAt ilegible ({merged!r})")
        return None
    reviews = ejecutar_gh(gh, ["api", f"repos/{owner}/{repo}/pulls/{numero}/reviews"], timeout)
    if reviews is None:  # ejecutar_gh ya avisó
        return None
    if not isinstance(reviews, list):
        avisar(f"gh api reviews de {url}: respuesta que no es una lista")
        return None
    pr["github"] = sum(1 for r in reviews if isinstance(r, dict) and isinstance(r.get("user"), dict)
                       and r["user"].get("login") == BOT_GREPTILE)
    return pr


def prs_en_ventana(urls, gh, desde, hasta, cache=None, timeout=GH_TIMEOUT):
    """PRs de `urls` mergeados dentro de [desde, hasta] (los que fallan, avisan y no cuentan)."""
    cache = {} if cache is None else cache
    res = []
    for url in urls:
        if url not in cache:
            cache[url] = consultar_pr(url, gh, timeout)
        pr = cache[url]
        if pr and pr["merged_at"] is not None and desde <= pr["merged_at"] <= hasta:
            res.append(pr)
    return res


# ───────────────────────────── agregado ─────────────────────────────

def atribuir(sesiones, tableros):
    """Reparte el coste de las sesiones por tablero según qué kanban.db contiene su tarjeta.
    → ({tablero: {"coste": x, "sesiones": n}}, coste_sin_tablero)."""
    tarjeta_a_tablero = {}
    for nombre in sorted(tableros):
        for tid, *_ in tableros[nombre]["tasks"]:
            tarjeta_a_tablero.setdefault(tid, nombre)
    por_tablero, sin_tablero = {}, 0.0
    for s in sesiones:
        nombre = tarjeta_a_tablero.get(s["tarjeta"])
        if nombre is None:
            sin_tablero += s["coste"]
            continue
        acc = por_tablero.setdefault(nombre, {"coste": 0.0, "sesiones": 0})
        acc["coste"] += s["coste"]
        acc["sesiones"] += 1
    return por_tablero, sin_tablero


def agregar_tablero(tablero, atribuido, desde, hasta, prs=None, greptile=()):
    """Métricas de un tablero. `atribuido` = {"coste", "sesiones"} (o None); `prs` = PRs mergeados en la
    ventana (None con --sin-gh); `greptile` = líneas `ejecutado` del registro. Devuelve el dict de claves fijas,
    o None si el tablero no tiene ninguna run, terminada ni sesión en la ventana."""
    atribuido = atribuido or {"coste": 0.0, "sesiones": 0}
    en_ventana = lambda ts: ts is not None and desde <= ts <= hasta  # noqa: E731
    terminadas = {tid for tid, status, completado, _rama in tablero["tasks"]
                  if status == "done" and en_ventana(completado)}
    runs_ventana = [r for r in tablero["runs"] if en_ventana(r[2])]
    if not (terminadas or runs_ventana or atribuido["sesiones"]):
        return None

    rate_limited = sum(1 for r in runs_ventana if r[3] == "rate_limited")
    runs_terminadas = [r for r in tablero["runs"] if r[0] in terminadas]
    cambios = [r for r in runs_terminadas if r[3] == "changes_requested"]
    con_revision = {r[0] for r in runs_terminadas if r[3] == "review_requested"}
    por_perfil = {}
    for r in cambios:
        perfil = r[1] or SIN_PERFIL
        por_perfil[perfil] = por_perfil.get(perfil, 0) + 1

    coste = round(atribuido["coste"], 1)  # los pesos tienen un decimal: se descarta el ruido de coma flotante
    res = {
        "terminadas": len(terminadas),
        "coste_eq": coste,
        "coste_por_tarjeta": dividir(coste, len(terminadas)),
        "runs": len(runs_ventana),
        "rate_limited": rate_limited,
        "pct_rate_limited": None if not runs_ventana else round(100 * rate_limited / len(runs_ventana), 1),
        "rondas_por_tarjeta": dividir(len(cambios), len(con_revision)),
        "rondas_por_perfil": dict(sorted(por_perfil.items())),
    }
    if prs is None:  # --sin-gh: Greptile local de todas las ramas del tablero
        ramas = {rama for *_, rama in tablero["tasks"] if rama}
        res.update(prs_mergeados=None, lineas_pr=None, coste_por_linea=None,
                   greptile_local=sum(1 for g in greptile if g.get("rama") in ramas),
                   greptile_github=None, greptile_por_pr=None)
        return res
    lineas = sum(p["additions"] + p["deletions"] for p in prs)
    local = sum(1 for p in prs if p["rama"] for g in greptile
                if g.get("rama") == p["rama"] and g.get("repo") == f"{p['owner']}/{p['repo']}")
    github = sum(p["github"] for p in prs)
    res.update(prs_mergeados=len(prs), lineas_pr=lineas, coste_por_linea=dividir(coste, lineas),
               greptile_local=local, greptile_github=github, greptile_por_pr=dividir(local + github, len(prs)))
    return res


def calcular(tableros, sesiones, ahora, dias, gh=None, greptile=(), timeout=GH_TIMEOUT):
    """Todo el informe. `gh` = ejecutable de gh, o None para --sin-gh. → dict con las claves fijas del JSON."""
    desde = ahora - dias * 86400
    atribuido, sin_tablero = atribuir(sesiones, tableros)
    cache, res = {}, {}
    for nombre in sorted(tableros):
        t = tableros[nombre]
        # Primero sin gh: solo se consulta a GitHub en los tableros que salen en el informe.
        if agregar_tablero(t, atribuido.get(nombre), desde, hasta=ahora) is None:
            continue
        prs = None if gh is None else prs_en_ventana(urls_pr(t["runs"]), gh, desde, ahora, cache, timeout)
        res[nombre] = agregar_tablero(t, atribuido.get(nombre), desde, ahora, prs, greptile)
    return {"desde": iso(desde), "hasta": iso(ahora), "tableros": res,
            "sin_tablero": {"coste_eq": round(sin_tablero, 1)}}


def iso(epoch):
    return datetime.fromtimestamp(epoch).astimezone().isoformat(timespec="seconds")


# ───────────────────────────── formato ─────────────────────────────

def _fmt(v, f):
    return "—" if v is None else f(v)


def formatear_tabla(informe):
    """Una fila por tablero. Coste en M (millones de tokens equivalentes) con 2 decimales, por línea en k."""
    cab = ["tablero", "term.", "coste", "/tarjeta", "/línea", "runs", "rl %", "rondas/t",
           "PRs", "líneas", "gr loc", "gr gh", "gr/PR"]
    filas = []
    for nombre, t in informe["tableros"].items():
        filas.append([
            nombre, str(t["terminadas"]), f"{t['coste_eq'] / 1e6:.2f} M",
            _fmt(t["coste_por_tarjeta"], lambda v: f"{v / 1e6:.2f} M"),
            _fmt(t["coste_por_linea"], lambda v: f"{v / 1e3:.2f} k"),
            str(t["runs"]), _fmt(t["pct_rate_limited"], lambda v: f"{v:.1f}"),
            _fmt(t["rondas_por_tarjeta"], lambda v: f"{v:.2f}"),
            _fmt(t["prs_mergeados"], str), _fmt(t["lineas_pr"], str),
            str(t["greptile_local"]), _fmt(t["greptile_github"], str),
            _fmt(t["greptile_por_pr"], lambda v: f"{v:.2f}")])
    anchos = [max(len(c[i]) for c in [cab, *filas]) for i in range(len(cab))]
    fmt = lambda fila: "  ".join(c.ljust(anchos[0]) if i == 0 else c.rjust(anchos[i])  # noqa: E731
                                 for i, c in enumerate(fila)).rstrip()
    lineas = [f"Ventana: {informe['desde']} → {informe['hasta']}", fmt(cab), *(fmt(f) for f in filas)]
    lineas.append(f"sin tablero: {informe['sin_tablero']['coste_eq'] / 1e6:.2f} M")
    lineas.append("coste = tokens equivalentes (entrada + escritura de caché + 0,1·lectura de caché + 5·salida)")
    return "\n".join(lineas)


# ───────────────────────────── CLI ─────────────────────────────

def rutas_state(env, home):
    crudo = env.get("FABRIK_STATE_DBS")
    if crudo is not None:
        return [r for r in crudo.split(":") if r]
    return sorted(glob.glob(f"{home}/.hermes/profiles/*/state.db")) + [f"{home}/.hermes/state.db"]


def main(argv, env=None, ahora=None):
    env = os.environ if env is None else env
    home = os.path.expanduser("~")
    p = argparse.ArgumentParser(prog="fabrik-cupos semana", description="Coste y rondas por tablero en la ventana.")
    p.add_argument("--dias", "-d", type=int, default=DIAS_DEFECTO, help=f"días de la ventana (defecto {DIAS_DEFECTO}, mínimo 1)")
    p.add_argument("--json", action="store_true", help="salida JSON")
    p.add_argument("--sin-gh", action="store_true", help="no llama a gh (PRs y Greptile de GitHub quedan a null)")
    args = p.parse_args(argv)
    dias = max(1, args.dias)
    ahora = time.time() if ahora is None else ahora
    desde = ahora - dias * 86400

    tableros = {}
    boards = env.get("FABRIK_KANBAN_BOARDS", f"{home}/.hermes/kanban/boards")
    for ruta in sorted(glob.glob(os.path.join(boards, "*", "kanban.db"))):
        try:
            tableros[os.path.basename(os.path.dirname(ruta))] = leer_tablero(ruta)
        except sqlite3.Error as e:
            avisar(f"fallo leyendo tablero {os.path.basename(os.path.dirname(ruta))}: {e}")
    sesiones = []
    for ruta in rutas_state(env, home):
        try:
            sesiones += leer_sesiones(ruta, desde, ahora)
        except sqlite3.Error as e:
            avisar(f"fallo leyendo sesiones de {ruta}: {e}")
    greptile = leer_registro_greptile(env.get("FABRIK_GREPTILE_LOG", f"{home}/.hermes/factory/logs/greptile.jsonl"))
    gh = None if args.sin_gh else env.get("FABRIK_GH", "gh")
    informe = calcular(tableros, sesiones, ahora, dias, gh, greptile)
    print(json.dumps(informe, indent=2, ensure_ascii=False) if args.json else formatear_tabla(informe))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
