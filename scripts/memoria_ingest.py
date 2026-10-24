#!/usr/bin/env python3
"""Carga fuentes de conocimiento en la memoria compartida de la fábrica (Hindsight, http://127.0.0.1:8888).

Uso (necesita pyyaml; lánzalo con uv):
  uv run --with pyyaml python memoria_ingest.py banco           # crea/actualiza el banco de `memoria.banco`
  uv run --with pyyaml python memoria_ingest.py claude [repo ...]
  uv run --with pyyaml python memoria_ingest.py docs <ruta_repo> [...] [--excluir=superpowers,plans]
  uv run --with pyyaml python memoria_ingest.py lecciones        # conocimiento/lecciones/*.md de todos los packs activos
  uv run --with pyyaml python memoria_ingest.py estado

Cada memoria lleva repo, fuente, tipo y fecha (la del contenido, no la de la carga) para que lo obsoleto pierda
frente a lo reciente. Idempotente: document_id estable por fichero (update_mode=replace).
"""
import datetime as dt, json, os, re, subprocess, sys, urllib.request
from pathlib import Path

import fabrik_config

API = os.environ.get("FABRIK_MEMORIA_URL", "http://127.0.0.1:8888") + "/v1/default/banks"
HOME = Path.home()

# banco, nombre y descripción salen de la clave `memoria` de la config (FABRIK_MEMORIA_BANK la pisa).
MEMORIA = fabrik_config.cargar().get("memoria") or {}
BANK = os.environ.get("FABRIK_MEMORIA_BANK") or MEMORIA.get("banco") or "fabrica"

BANK_CONFIG = {
    "name": MEMORIA.get("nombre", ""),
    "mission": MEMORIA.get("descripcion", ""),
    "retain_mission": ("Extrae hechos técnicos reutilizables: síntoma → causa raíz → solución; decisiones del dueño y su porqué; "
                       "convenciones y reglas de cada repo; trampas de herramientas (CI, Greptile, phpunit-replay, Laravel, MariaDB); "
                       "nombres de clases, rutas, comandos y PRs. Conserva el repo de origen. Ignora relleno conversacional."),
    "retain_custom_instructions": "Escribe los hechos en español. Mantén identificadores técnicos (clases, rutas, comandos, números de PR) literales.",
    "enable_observations": True,
    "enable_text_search": True,
    "enable_temporal_retrieval": True,
    "enable_graph_retrieval": True,
    "enable_reranking": True,
}


def call(method, path, body=None, timeout=120):
    req = urllib.request.Request(f"{API}/{BANK}{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}


def frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.S)
    if not m:
        return {}, text
    meta = {}
    for line in m.group(1).splitlines():
        mm = re.match(r"^\s*([A-Za-z_]+):\s*(.*)$", line)
        if mm:
            meta[mm.group(1)] = mm.group(2).strip().strip('"')
    return meta, m.group(2)


def repo_from_slug(slug):
    parts = slug.strip("-").split("-")
    for anchor in ("Code", "PycharmProjects", "WebstormProjects", "Projects"):
        if anchor in parts:
            return "-".join(parts[parts.index(anchor) + 1:])
    return None


def retain(items):
    for i in range(0, len(items), 20):
        call("POST", "/memories", {"items": items[i:i + 20], "async": True}, timeout=300)


def cmd_banco():
    call("PUT", "", BANK_CONFIG)
    print("banco", BANK, "OK")


def cmd_claude(only):
    total = 0
    for mem in sorted((HOME / ".claude/projects").glob("*/memory")):
        repo = repo_from_slug(mem.parent.name)
        if not repo or (only and repo not in only):
            continue
        items = []
        for f in sorted(mem.glob("*.md")):
            text = f.read_text(errors="replace")
            meta, body = frontmatter(text)
            if len(body.strip()) < 40:
                continue
            ts = meta.get("modified") or dt.datetime.fromtimestamp(f.stat().st_mtime, dt.timezone.utc).isoformat()
            kind = meta.get("type", "nota")
            items.append({
                "content": body.strip()[:30000],
                "timestamp": ts,
                "context": f"Nota de memoria de Claude Code del repo {repo} (tipo {kind}): {meta.get('description', f.stem)}",
                "document_id": f"claude-memory/{repo}/{f.name}",
                "update_mode": "replace",
                "tags": [f"repo:{repo}", "fuente:claude-memory", f"tipo:{kind}"],
                "metadata": {"repo": repo, "fuente": "claude-memory", "path": str(f), "name": meta.get("name", f.stem)},
            })
        if items:
            retain(items)
            total += len(items)
            print(f"{repo}: {len(items)} notas encoladas", flush=True)
    print("total", total)


def cmd_docs(args):
    excl = set()
    paths = []
    for a in args:
        if a.startswith("--excluir="):
            excl |= {x.strip().strip("/") for x in a.split("=", 1)[1].split(",") if x.strip()}
        else:
            paths.append(a)
    for p in paths:
        root = Path(p).expanduser().resolve()
        repo = root.name
        items = []
        for f in sorted((root / "docs").rglob("*.md")):
            rel = f.relative_to(root)
            if any(part in excl for part in rel.parts[1:-1]):
                continue
            text = f.read_text(errors="replace")
            if len(text.strip()) < 80:
                continue
            ts = subprocess.run(["git", "-C", str(root), "log", "-1", "--format=%aI", "--", str(rel)],
                                capture_output=True, text=True).stdout.strip() \
                or dt.datetime.fromtimestamp(f.stat().st_mtime, dt.timezone.utc).isoformat()
            items.append({
                "content": text[:120000],
                "timestamp": ts,
                "context": f"Documento {rel} del repo {repo} (última modificación {ts[:10]}; puede estar desactualizado)",
                "document_id": f"docs/{repo}/{rel}",
                "update_mode": "replace",
                "tags": [f"repo:{repo}", "fuente:docs"],
                "metadata": {"repo": repo, "fuente": "docs", "path": str(rel)},
            })
        retain(items)
        print(f"{repo}: {len(items)} documentos encolados", flush=True)


def carpetas_lecciones():
    """[(pack, carpeta)] con las lecciones a ingerir: `conocimiento/lecciones/` de TODOS los packs activos más la
    carpeta de respaldo `$FABRIK_DATA/conocimiento/lecciones/` (pack «local», donde escribe fabrik-memoria si no hay
    pack con banco). No lee `$FABRIK_HOME/conocimiento` (repo del motor)."""
    data = Path(os.environ.get("FABRIK_DATA", HOME / ".hermes/factory"))
    carpetas = [(nombre, d / "conocimiento/lecciones") for nombre, d in fabrik_config.packs_activos_dirs()]
    carpetas.append(("local", data / "conocimiento/lecciones"))
    return carpetas


def cmd_lecciones():
    total = 0
    for pack, carpeta in carpetas_lecciones():
        items = []
        for f in sorted(carpeta.glob("*.md")):
            text = f.read_text(errors="replace")
            meta, body = frontmatter(text)
            repo = meta.get("repo") or "desconocido"
            etiquetas = [t.strip() for t in meta.get("etiquetas", "").strip("[]").split(",") if t.strip()]
            items.append({
                "content": text[:30000],
                "timestamp": (meta.get("fecha") or dt.datetime.fromtimestamp(f.stat().st_mtime, dt.timezone.utc).date().isoformat()) + "T00:00:00+00:00",
                "context": f"Lección verificada al cerrar una tarjeta en el repo {repo}",
                "document_id": f"leccion/{pack}/{f.name}",
                "update_mode": "replace",
                "tags": [f"repo:{repo}", "fuente:leccion"] + [f"tema:{t}" for t in etiquetas],
                "metadata": {"repo": repo, "fuente": "leccion", "pack": pack, "path": f"conocimiento/lecciones/{f.name}"},
            })
        if items:
            retain(items)
            total += len(items)
            print(f"{pack}: {len(items)} lecciones encoladas", flush=True)
    print("total", total)


def cmd_estado():
    s = call("GET", "/stats")
    llm = call("GET", "/llm-requests/stats")
    tok = {"input": 0, "output": 0, "cached": 0, "errores": 0}
    for b in llm.get("buckets", []):
        for k in ("input", "output", "cached"):
            tok[k] += b.get("tokens", {}).get(k, 0)
        tok["errores"] += b.get("statuses", {}).get("error", 0)
    print(json.dumps({
        "documentos": s.get("total_documents"), "hechos": s.get("total_nodes"),
        "observaciones": s.get("total_observations"),
        "operaciones": s.get("operations_by_status"), "pendientes": s.get("pending_operations"),
        "fallidas": s.get("failed_operations"), "consolidacion_pendiente": s.get("pending_consolidation"),
        "tokens_llm_7d": tok}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    cmd, args = (sys.argv[1] if len(sys.argv) > 1 else ""), sys.argv[2:]
    {"banco": lambda: cmd_banco(), "claude": lambda: cmd_claude(set(args)), "docs": lambda: cmd_docs(args),
     "lecciones": lambda: cmd_lecciones(), "estado": lambda: cmd_estado()}.get(
        cmd, lambda: sys.exit(__doc__))()
