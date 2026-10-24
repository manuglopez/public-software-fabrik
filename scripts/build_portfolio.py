#!/usr/bin/env python3
"""Genera/actualiza ~/.hermes/factory/portfolio.yaml (solo lectura sobre GitHub y los clones locales).

Alcance: todos los repos de `owners` + los repos sueltos de `extra_repos` (p. ej. del usuario).
Los campos que edita el usuario se CONSERVAN entre regeneraciones (ver PRESERVE), igual que las
secciones `products` y `provider_policy`.
Uso: uv run --with pyyaml python build_portfolio.py
"""
import datetime as dt
import json
import os
import re
import subprocess
from pathlib import Path

import yaml

import fabrik_config

HOME = Path.home()
OUT = HOME / ".hermes/factory/portfolio.yaml"
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


def main():
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
    old = yaml.safe_load(OUT.read_text()) if OUT.exists() else {}
    old_products = (old or {}).get("products") or {}
    old_by = {(p.get("full_name") or f"{org}/{p['name']}"): p for p in (old or {}).get("projects", [])}
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
        for k in PRESERVE:
            if k in prev and (k != "state" or prev.get("state_confirmed")):
                entry[k] = prev[k]
        if entry.get("board") is None:
            entry["board"] = asignar_board(entry["owner"], name, config, personal, packs_info, old_products)
        out.append(entry)
    doc = {"org": org, "extra_repos": extra_repos, "projects": out}
    for k in ("provider_policy", "products"):
        if k in (old or {}):
            doc[k] = old[k]
    header = (f"# Catálogo de proyectos ({', '.join(owners) or org} + extra_repos). Generado {now:%Y-%m-%d %H:%M} UTC por scripts/build_portfolio.py.\n"
              f"# Campos editables a mano (se conservan al regenerar): {', '.join(PRESERVE)}.\n")
    OUT.write_text(header + yaml.safe_dump(doc, allow_unicode=True, sort_keys=False, width=120))
    for p in out:
        print(f"{p['state']:<11}{p['full_name']:<40}{p['last_push']}  {p.get('ritmo') or '-':<10}"
              f"{'local' if p['local_path'] else '—':<6} {','.join(p['context']) or '-'}  mem={p['claude_memory_notes']}")


if __name__ == "__main__":
    main()
