#!/usr/bin/env python3
"""Genera/actualiza $FABRIK_DATA/portfolio.yaml (por defecto ~/.hermes/factory/portfolio.yaml).
Solo lee GitHub y los clones locales; lo único que escribe es el destino (con copia .bak fechada).

Alcance: todos los repos de `owners` + los repos sueltos de `extra_repos` (p. ej. del usuario).
Los campos que edita el usuario se CONSERVAN entre regeneraciones (ver PRESERVE), igual que las
secciones `products` y `provider_policy`.
Uso: uv run --with pyyaml python build_portfolio.py [--seco | --salida RUTA] [--forzar]
Salida 3 = una guarda ha impedido sobrescribir el destino (otra org, ilegible, o 0 proyectos).
"""
import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

import fabrik_config

HOME = Path.home()
COPIAS_MAX = 5  # copias .<fecha>.bak que se conservan junto al destino
INFRA_SUFFIXES = ("-replay",)  # cachés de phpunit-replay de cada proyecto, no son productos
PRESERVE = ("state", "state_confirmed", "ritmo", "product", "board", "onboarded", "allowed_providers",
            "colaboradores", "notas", "verificacion_local", "brand")
FIELDS = "name,nameWithOwner,pushedAt,isArchived,isFork,primaryLanguage,defaultBranchRef,description,url,visibility"


def gh(args):
    return subprocess.run(["gh", *args], capture_output=True, text=True).stdout


def has_path(full, branch, path):
    return subprocess.run(["gh", "api", f"repos/{full}/contents/{path}?ref={branch}", "--silent"],
                          capture_output=True).returncode == 0


def local_clones(full_names, search_dirs):
    wanted = {f.lower(): f for f in full_names}
    found = {}
    for base in search_dirs:
        if not base.is_dir():
            continue
        for d in base.iterdir():
            if not (d / ".git").exists():
                continue
            url = subprocess.run(["git", "-C", str(d), "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
            key = "/".join(url.rstrip("/").removesuffix(".git").replace(":", "/").split("/")[-2:]).lower()
            if key in wanted:
                found.setdefault(wanted[key], []).append(str(d))
    return found


def claude_memory(path):
    slug = "-" + path.strip("/").replace("/", "-").replace(".", "-")
    mem = HOME / ".claude/projects" / slug / "memory"
    return len(list(mem.glob("*.md"))) if mem.is_dir() else 0


def asignar_board(owner, repo_name, config, personal, packs_info, old_products):
    """Tablero de un repo sin `board` previo: personal > productos previos > pack > por defecto."""
    personal_owners = set(personal.get("owners") or [])
    if personal.get("usuario_github"):
        personal_owners.add(personal["usuario_github"])
    if owner in personal_owners:
        return personal.get("tablero_por_defecto") or "personal"

    if old_products and isinstance(old_products, dict):
        for prod_key, prod_val in old_products.items():
            if isinstance(prod_val, dict) and repo_name in (prod_val.get("repos") or []):
                if prod_val.get("board"):
                    return prod_val["board"]

    for p_info in packs_info:
        for prod_key, prod_val in (p_info.get("products") or {}).items():
            if isinstance(prod_val, dict) and repo_name in (prod_val.get("repos") or []):
                if prod_val.get("board"):
                    return prod_val["board"]

        for t in (p_info.get("tableros") or []):
            slug = t.get("slug")
            if not slug:
                continue
            if slug == repo_name:
                return slug
            desc = t.get("descripcion") or ""
            if re.search(r"\b" + re.escape(repo_name) + r"\b", desc, re.IGNORECASE):
                return slug

        if owner in (p_info.get("owners") or []):
            if p_info.get("tablero_por_defecto"):
                return p_info["tablero_por_defecto"]

    return config.get("tablero_por_defecto")


def destino_por_defecto():
    """$FABRIK_DATA/portfolio.yaml (igual que install.sh y el panel); se resuelve al llamar, no al importar."""
    return Path(os.environ.get("FABRIK_DATA") or HOME / ".hermes/factory") / "portfolio.yaml"


def leer_destino(ruta):
    """(doc, error): doc es el mapa actual ({} si no hay fichero o está vacío); error dice por qué no se entiende."""
    if not ruta.exists():
        return {}, None
    try:
        doc = yaml.safe_load(ruta.read_text())
    except (OSError, UnicodeDecodeError, yaml.YAMLError) as e:
        return {}, f"no es YAML legible ({type(e).__name__})"
    if doc is None:
        return {}, None
    if not isinstance(doc, dict):
        return {}, "no es un mapa YAML"
    return doc, None


def copia_con_fecha(ruta):
    """Copia `ruta` a <ruta>.<YYYYmmdd-HHMMSS>[-N].bak (hora local) y poda: quedan las COPIAS_MAX más recientes.

    Solo se tocan los ficheros que casan EXACTAMENTE con ese patrón; portfolio.yaml.bak y demás son ajenos."""
    sello = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    bak, n = ruta.with_name(f"{ruta.name}.{sello}.bak"), 1
    while bak.exists():
        n += 1
        bak = ruta.with_name(f"{ruta.name}.{sello}-{n}.bak")
    shutil.copy2(ruta, bak)
    patron = re.compile(r"^" + re.escape(ruta.name) + r"\.(\d{8}-\d{6})(?:-(\d+))?\.bak$")
    copias = sorted((m.group(1), int(m.group(2) or 1), f) for f in ruta.parent.iterdir()
                    if f.is_file() and (m := patron.match(f.name)))
    for _, _, f in copias[:-COPIAS_MAX]:
        f.unlink()
    return bak


def escribir_atomico(ruta, texto):
    ruta.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=ruta.parent, prefix=f".{ruta.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(texto)
        if ruta.exists():
            shutil.copymode(ruta, tmp)
        else:
            os.chmod(tmp, 0o644)
        os.replace(tmp, ruta)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def guarda(args, msg):
    """Ha saltado una guarda de D-3: con --forzar se ignora, con --seco solo avisa, si no sale con código 3."""
    if args.forzar:
        return
    print(f"build_portfolio: {msg}", file=sys.stderr)
    if not args.seco:
        sys.exit(3)


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="Genera el catálogo de proyectos ($FABRIK_DATA/portfolio.yaml).")
    modo = ap.add_mutually_exclusive_group()
    modo.add_argument("--seco", action="store_true",
                      help="genera y muestra qué saldría, pero no escribe nada (ni copia .bak)")
    modo.add_argument("--salida", metavar="RUTA",
                      help="escribe en RUTA en vez de en $FABRIK_DATA/portfolio.yaml (los campos conservados se leen de RUTA)")
    ap.add_argument("--forzar", action="store_true",
                    help="salta las guardas (otra org, destino ilegible, 0 proyectos); la copia .bak se hace igualmente")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    destino = Path(args.salida).expanduser() if args.salida else destino_por_defecto()
    config = fabrik_config.cargar()
    personal_path = fabrik_config.config_personal_path()
    personal = fabrik_config.cargar_yaml(personal_path)
    packs = fabrik_config.packs_activos(personal, personal_path)
    packs_info = [fabrik_config.cargar_yaml(p) for p in packs]
    owners = config.get("owners") or []
    extra_repos = config.get("extra_repos") or []
    dir_codigo = config.get("dir_codigo", "~/Code")
    search_dirs = [Path(os.path.expanduser(dir_codigo)),
                   HOME / "PycharmProjects", HOME / "WebstormProjects", HOME / "Projects"]
    org = owners[0] if owners else ""
    # Guardas (a) y (b): sobre el destino y ANTES de llamar a gh (la org sale de la config).
    old, ilegible = leer_destino(destino)
    org_actual = str(old.get("org") or "")
    if ilegible:
        guarda(args, f"{destino} existe pero {ilegible}. No lo sobrescribo. Revísalo a mano; si de verdad quieres "
                     "reemplazarlo, --forzar (se guarda copia .bak).")
    elif org_actual and org_actual != org:
        guarda(args, f"{destino} es de la org «{org_actual}» y ahora se generaría «{org}». No lo sobrescribo. "
                     "Para probar usa --seco o --salida <ruta>; si de verdad quieres reemplazarlo, --forzar.")
    repos = []
    for owner in owners:
        repos += json.loads(gh(["repo", "list", owner, "--limit", "500", "--json", FIELDS]) or "[]")
    for full in extra_repos:
        r = gh(["repo", "view", full, "--json", FIELDS])
        if r:
            try:
                data = json.loads(r)
                if isinstance(data, dict) and "nameWithOwner" in data and "pushedAt" in data:
                    repos.append(data)
            except Exception:
                pass
    repos = [r for r in repos if isinstance(r, dict) and "nameWithOwner" in r and "pushedAt" in r]
    clones = local_clones([r["nameWithOwner"] for r in repos], search_dirs)
    old_proyectos = [p for p in old.get("projects") or [] if isinstance(p, dict)] if isinstance(old.get("projects"), list) else []
    if not repos and old_proyectos:  # guarda (c): gh sin sesión o sin red no debe vaciar el catálogo
        guarda(args, f"se generan 0 proyectos y {destino} tenía {len(old_proyectos)}. No lo sobrescribo "
                     "(¿gh sin sesión o sin red?). Si de verdad quieres vaciarlo, --forzar.")
    old_products = old.get("products") or {}
    old_by = {(p.get("full_name") or f"{org}/{p.get('name')}"): p for p in old_proyectos}
    conservados = 0
    now = dt.datetime.now(dt.timezone.utc)
    out = []
    for r in sorted(repos, key=lambda x: x["pushedAt"], reverse=True):
        full, name = r["nameWithOwner"], r["name"]
        branch = (r.get("defaultBranchRef") or {}).get("name") or "main"
        days = (now - dt.datetime.fromisoformat(r["pushedAt"].replace("Z", "+00:00"))).days
        if r["isArchived"]:
            state = "archivado"
        elif name.endswith(INFRA_SUFFIXES):
            state = "infra"
        elif r["isFork"]:
            state = "ignorar"
        else:
            state = "activo" if days < 90 else "dormido" if days < 365 else "abandonado"
        paths = clones.get(full, [])
        canonical = next((p for p in paths if Path(p).name == name), paths[0] if paths else None)
        ctx = {f: has_path(full, branch, f) for f in ("CLAUDE.md", "AGENTS.md", ".hermes.md", ".specify", ".claude/skills")}
        entry = {
            "name": name, "full_name": full, "owner": full.split("/")[0], "visibility": r.get("visibility"),
            "url": r["url"], "default_branch": branch,
            "language": (r.get("primaryLanguage") or {}).get("name"), "description": r.get("description") or "",
            "last_push": r["pushedAt"][:10], "days_since_push": days,
            "state": state, "state_confirmed": False,
            "local_path": canonical, "duplicate_clones": [p for p in paths if p != canonical],
            "context": {k: v for k, v in ctx.items() if v},
            "claude_memory_notes": claude_memory(canonical) if canonical else 0,
            "board": None, "onboarded": False, "allowed_providers": "all",
        }
        prev = old_by.get(full, {})
        conservado = [k for k in PRESERVE if k in prev and (k != "state" or prev.get("state_confirmed"))]
        for k in conservado:
            entry[k] = prev[k]
        conservados += bool(conservado)
        if entry.get("board") is None:
            entry["board"] = asignar_board(entry["owner"], name, config, personal, packs_info, old_products)
        out.append(entry)
    doc = {"org": org, "extra_repos": extra_repos, "projects": out}
    for k in ("provider_policy", "products"):
        if k in (old or {}):
            doc[k] = old[k]
    header = (f"# Catálogo de proyectos ({', '.join(owners) or org} + extra_repos). Generado {now:%Y-%m-%d %H:%M} UTC por scripts/build_portfolio.py.\n"
              f"# Campos editables a mano (se conservan al regenerar): {', '.join(PRESERVE)}.\n")
    if not args.seco:
        if destino.exists():
            copia_con_fecha(destino)
        escribir_atomico(destino, header + yaml.safe_dump(doc, allow_unicode=True, sort_keys=False, width=120))
    for p in out:
        print(f"{p['state']:<11}{p['full_name']:<40}{p['last_push']}  {p.get('ritmo') or '-':<10}"
              f"{'local' if p['local_path'] else '—':<6} {','.join(p['context']) or '-'}  mem={p['claude_memory_notes']}")
    if args.seco:
        print(f"org actual «{org_actual}» → generada «{org}» · {len(out)} proyectos ({conservados} con campos conservados)"
              " · no se ha escrito nada")


if __name__ == "__main__":
    main()
