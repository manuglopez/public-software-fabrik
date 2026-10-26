"""The Factory — pestaña Proyectos (AC-4a) y últimas lecciones de la pestaña Memoria (AC-4d).

- `GET /proyectos`: catálogo de `$FABRIK_DATA/portfolio.yaml` agrupado por producto (los de `ritmo: diario` primero),
  con las tarjetas activas de cada repo (Kanban en solo lectura) y los PRs abiertos de ramas `agente/*` (`gh pr list`
  con timeout propio, en paralelo y con caché corta). Sin `gh` o con `gh` caído, `prs` queda vacío y se avisa.
- `GET /memoria/lecciones`: las últimas lecciones (`fabrik-memoria leccion`) de los ficheros de conocimiento (locales y de los packs activos con memoria.banco).
"""
from __future__ import annotations

import json
import re
import shutil
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path

import fabrica_comun as comun

TIMEOUT_GH = 10  # s por repo
CACHE_S = 45  # los PRs no cambian en segundos; evita una llamada por repo en cada refresco
MAX_TARJETAS = 12  # tarjetas listadas por repo (el total va en `tarjetas_activas`)
HILOS_GH = 6
CATALOGO_OCULTO = {"ignorar", "archivado", "infra"}
INACTIVAS = ("done", "archived")
SIN_PRODUCTO = "Sin producto"

CACHE_PRS: dict[str, tuple[float, list[dict] | None, str]] = {}

_WORKTREE = re.compile(r"/\.factory-worktrees/([^/]+)/")
_LINEA_REPO = re.compile(r"\*\*Repo\*\*\s*`([^`]+)`")
_URL_GITHUB = re.compile(r"^https://github\.com/([\w.-]+)/([\w.-]+?)(?:\.git)?/?$")


def _portfolio() -> tuple[dict | None, str]:
    ruta = comun.fabrik_data() / "portfolio.yaml"
    if not ruta.is_file():
        return None, f"sin portfolio.yaml ({ruta})"
    try:
        datos = comun.yaml_safe_load(ruta.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001 - yaml ausente o fichero roto: el bloque dice por qué
        return None, f"no se pudo leer el portfolio: {type(e).__name__}"
    return (datos, "") if isinstance(datos, dict) else (None, "portfolio.yaml no es un mapa")


def _full_name(proyecto: dict, org: str) -> str | None:
    """OWNER/REPO de un proyecto: `full_name` (con «/»), si no la `url` de GitHub, si no `org/name`; si no, None."""
    full = str(proyecto.get("full_name") or "")
    if "/" in full:
        return full
    m = _URL_GITHUB.match(str(proyecto.get("url") or ""))
    if m:
        return f"{m.group(1)}/{m.group(2)}"
    return f"{org}/{proyecto['name']}" if org else None


def _producto_de(proyecto: dict, por_repo: dict[str, str]) -> str:
    return str(proyecto.get("product") or por_repo.get(proyecto.get("name"), "") or "")


def _tarjetas_por_repo(avisos: list[str]) -> dict[str, list[dict]]:
    """{nombre de repo en minúsculas: [tarjeta activa]} de todos los tableros (solo lectura)."""
    salida: dict[str, list[dict]] = {}
    for slug, ruta in comun.tableros():
        try:
            with closing(comun.conectar_ro(ruta)) as con:
                filas = con.execute(
                    "SELECT id, title, status, workspace_path, substr(body, 1, 600) AS cuerpo FROM tasks "
                    f"WHERE status NOT IN ({','.join('?' * len(INACTIVAS))}) ORDER BY rowid DESC",
                    INACTIVAS,
                ).fetchall()
        except Exception as e:  # noqa: BLE001 - un tablero roto no tumba el resto
            avisos.append(f"tablero {slug}: {type(e).__name__}")
            continue
        for f in filas:
            repo = _repo_de(f["workspace_path"], f["cuerpo"])
            if repo:
                salida.setdefault(repo.lower(), []).append(
                    {"board": slug, "task_id": f["id"], "titulo": f["title"], "estado": f["status"]}
                )
    return salida


def _repo_de(workspace: str | None, cuerpo: str | None) -> str:
    """Repo de una tarjeta: el worktree `.factory-worktrees/<repo>/…` o la línea `**Repo** \\`owner/repo\\``."""
    m = _WORKTREE.search(workspace or "")
    if m:
        return m.group(1)
    m = _LINEA_REPO.search(cuerpo or "")
    return m.group(1).rsplit("/", 1)[-1] if m else ""


def _json_de(salida: str):
    inicio = min((i for i in (salida.find("["), salida.find("{")) if i >= 0), default=-1)
    if inicio < 0:
        raise ValueError("sin JSON")
    return json.JSONDecoder().raw_decode(salida[inicio:])[0]


def _prs(full_name: str) -> tuple[list[dict] | None, str]:
    """(PRs abiertos de ramas agente/*, "") o (None, motivo). Caché corta por repo."""
    ahora = time.monotonic()
    hit = CACHE_PRS.get(full_name)
    if hit and ahora - hit[0] < CACHE_S:
        return hit[1], hit[2]
    ok, salida = comun.ejecutar(
        ["gh", "pr", "list", "-R", full_name, "--state", "open", "--limit", "100",
         "--json", "number,title,url,headRefName"],
        timeout=TIMEOUT_GH,
    )
    prs, motivo = None, ""
    if not ok:
        motivo = (salida.splitlines() or ["sin respuesta"])[0][:120]
    else:
        try:
            prs = [
                {"numero": p["number"], "titulo": p["title"], "url": p["url"]}
                for p in _json_de(salida)
                if str(p.get("headRefName", "")).startswith("agente/")
            ]
        except Exception:  # noqa: BLE001 - salida inesperada de gh
            motivo = "salida de gh no válida"
    CACHE_PRS[full_name] = (ahora, prs, motivo)
    return prs, motivo


def _prs_de(repos: list[str], avisos: list[str]) -> dict[str, list[dict]]:
    if not repos:
        return {}
    if not shutil.which("gh"):
        avisos.append("gh no está instalado: PRs sin consultar")
        return {r: [] for r in repos}
    with ThreadPoolExecutor(max_workers=min(HILOS_GH, len(repos))) as pool:
        resultados = list(pool.map(_prs, repos))
    salida = {}
    for repo, (prs, motivo) in zip(repos, resultados):
        salida[repo] = prs or []
        if prs is None:
            avisos.append(f"gh {repo}: {motivo}")
    return salida


def catalogo() -> dict:
    datos, motivo = _portfolio()
    if datos is None:
        return {**comun.no_disponible(motivo), "productos": [], "avisos": []}
    avisos: list[str] = []
    productos_cfg = datos.get("products") if isinstance(datos.get("products"), dict) else {}
    por_repo = {r: k for k, v in productos_cfg.items() if isinstance(v, dict) for r in (v.get("repos") or [])}
    proyectos = [p for p in (datos.get("projects") or []) if isinstance(p, dict) and p.get("name")]
    tarjetas = _tarjetas_por_repo(avisos)

    def visible(p: dict) -> bool:
        if p.get("state") in CATALOGO_OCULTO:
            return False
        return bool(
            _producto_de(p, por_repo) or p.get("ritmo") or p.get("state") == "activo" or tarjetas.get(p["name"].lower())
        )

    elegidos = [p for p in proyectos if visible(p)]
    org = str(datos.get("org") or "")
    fulls = {p["name"]: _full_name(p, org) for p in elegidos}
    prs = _prs_de([f for f in fulls.values() if f], avisos)
    avisos.extend(f"{n}: sin full_name ni org, PRs sin consultar" for n, f in fulls.items() if not f)

    grupos: dict[str, list[dict]] = {}
    for p in elegidos:
        activas = tarjetas.get(p["name"].lower(), [])
        full = fulls[p["name"]]
        grupos.setdefault(_producto_de(p, por_repo) or SIN_PRODUCTO, []).append(
            {
                "repo": p["name"],
                "full_name": full or p["name"],
                "ritmo": p.get("ritmo") or "",
                "estado": p.get("state") or "",
                "tarjetas_activas": len(activas),
                "tarjetas": activas[:MAX_TARJETAS],
                "prs": prs.get(full, []) if full else [],
            }
        )
    productos = []
    for nombre, repos in grupos.items():
        repos.sort(key=lambda r: (r["ritmo"] != "diario", r["repo"]))
        cfg = productos_cfg.get(nombre) if isinstance(productos_cfg.get(nombre), dict) else {}
        productos.append({"nombre": nombre, "nota": cfg.get("note") or "", "repos": repos})
    productos.sort(key=lambda p: (p["nombre"] == SIN_PRODUCTO, not any(r["ritmo"] == "diario" for r in p["repos"]), p["nombre"]))
    return {"disponible": True, "productos": productos, "avisos": avisos}


# ---- Memoria: últimas lecciones ----
_CAMPOS = {"sintoma": "Síntoma", "causa": "Causa", "solucion": "Solución", "donde": "Dónde"}
MAX_CAMPO = 400


def _leccion(ruta: Path) -> dict | None:
    try:
        texto = ruta.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    cabecera = re.match(r"---\n(.*?)\n---\n", texto, re.S)
    meta = dict(
        m.groups() for m in re.finditer(r"^(\w+):\s*(.*)$", cabecera.group(1) if cabecera else "", re.M)
    )
    campos = {}
    for clave, nombre in _CAMPOS.items():
        m = re.search(rf"\*\*{nombre}:\*\*\s*(.*?)(?=\n\n\*\*|\Z)", texto, re.S)
        campos[clave] = (m.group(1).strip() if m else "")[:MAX_CAMPO]
    if not campos["sintoma"]:
        return None
    fecha = meta.get("fecha") or ruta.name[:10]
    return {"repo": meta.get("repo", ""), "fecha": fecha, "archivo": ruta.name, **campos}


def _carpetas_lecciones() -> list[Path]:
    """Las locales y las de cada pack activo con `memoria.banco` (el mismo criterio que `fabrik-memoria leccion`)."""
    carpetas = [comun.fabrik_data() / "conocimiento" / "lecciones"]
    ok, salida = comun.ejecutar([str(comun.fabrik_home() / "bin" / "fabrik"), "config", "pack-dir", "memoria.banco"], timeout=15)
    if ok:
        carpetas += [Path(f[1]) / "conocimiento" / "lecciones" for f in (l.split("\t", 1) for l in salida.splitlines()) if len(f) == 2]
    return carpetas


def lecciones(maximo: int = 10) -> list[dict]:
    rutas = [r for carpeta in _carpetas_lecciones() for r in carpeta.glob("*.md")]
    salida = [leccion for leccion in map(_leccion, rutas) if leccion]
    salida.sort(key=lambda x: (x["fecha"], x["archivo"]), reverse=True)
    return salida[:maximo]


def registrar(router) -> None:
    @router.get("/proyectos")
    def proyectos() -> dict:
        return catalogo()

    @router.get("/memoria/lecciones")
    def memoria_lecciones(max: int = 10) -> dict:  # noqa: A002 - nombre del parámetro de la URL
        return {"lecciones": lecciones(min(max, 50) if max > 0 else 10)}
