"""The Factory — piezas comunes del backend (D-9 R-4). `plugin_api.py` lo publica como `fabrica_comun`:

    import fabrica_comun as comun
    for slug, ruta in comun.tableros(): ...
    with closing(comun.conectar_ro(ruta)) as con: ...
    ok, salida = comun.ejecutar(["hermes", "kanban", "--board", slug, "comment", tid, texto], timeout=20)
    return comun.no_disponible("sin gh")

Solo lectura salvo `ejecutar` (que nunca usa shell). Nada aquí lanza por una fuente ausente.
"""
from __future__ import annotations

import importlib.util
import os
import re
import sqlite3
import subprocess
from pathlib import Path
from urllib.parse import quote

MAX_SALIDA = 2000  # caracteres de salida que devuelve `ejecutar` (el final, que es donde está el error)
_SLUG = re.compile(r"^[a-z0-9][a-z0-9\-_]{0,63}$")  # el mismo que hermes_cli.kanban_db
_cfg_mod = None


def _raices_kanban() -> tuple[Path, Path]:
    """(home, boards_root) del Kanban. Usa el resolvedor del núcleo (`hermes_cli.kanban_db`, como kanban-gantt) y,
    si no está (tests, servidor suelto), el mismo cálculo por entorno."""
    try:
        from hermes_cli import kanban_db as kb

        return Path(kb.kanban_home()), Path(kb.boards_root())
    except Exception:  # noqa: BLE001 - sin hermes_cli: HERMES_KANBAN_HOME o ~/.hermes
        home = Path(os.environ.get("HERMES_KANBAN_HOME") or "~/.hermes").expanduser()
        return home, home / "kanban" / "boards"


def tableros() -> list[tuple[str, Path]]:
    """[(slug, ruta de kanban.db)] de los tableros que existen: `default` primero y luego por nombre.

    Se recorren los directorios en vez de `kanban_db_path(slug)`: un gateway lanzado desde un worker hereda
    HERMES_KANBAN_DB y el núcleo respondería con ese fichero para cualquier slug.
    """
    home, raiz = _raices_kanban()
    salida: list[tuple[str, Path]] = []
    if (home / "kanban.db").is_file():
        salida.append(("default", home / "kanban.db"))
    if raiz.is_dir():
        for d in sorted(raiz.iterdir(), key=lambda p: p.name):
            if d.name != "default" and _SLUG.match(d.name) and (d / "kanban.db").is_file():
                salida.append((d.name, d / "kanban.db"))
    return salida


def conectar_ro(ruta) -> sqlite3.Connection:
    """Conexión SQLite de solo lectura (`mode=ro`: no crea el fichero ni escribe). Filas como `sqlite3.Row`."""
    con = sqlite3.connect(f"file:{quote(str(ruta))}?mode=ro", uri=True, timeout=5)
    con.row_factory = sqlite3.Row
    return con


def _resumir(texto: str) -> str:
    texto = texto.strip()
    return texto if len(texto) <= MAX_SALIDA else "…" + texto[-MAX_SALIDA:]


def ejecutar(argv, timeout: float) -> tuple[bool, str]:
    """Ejecuta `argv` (lista, nunca shell) con `timeout` segundos. Devuelve (ok, salida resumida: stdout+stderr)."""
    if not isinstance(argv, (list, tuple)) or not argv:
        raise TypeError("ejecutar: argv tiene que ser una lista no vacía (nunca una cadena de shell)")
    argv = [str(a) for a in argv]
    try:
        r = subprocess.run(
            argv, shell=False, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL, check=False
        )
    except subprocess.TimeoutExpired:
        return False, f"timeout tras {timeout}s: {argv[0]}"
    except OSError as e:
        return False, f"no se pudo ejecutar {argv[0]}: {e.strerror or e}"
    salida = "\n".join(t for t in ((r.stdout or "").strip(), (r.stderr or "").strip()) if t)
    return r.returncode == 0, _resumir(salida)


def fabrik_home() -> Path:
    """Repo de la fábrica: FABRIK_HOME; el que contiene este fichero si el plugin está enlazado desde el repo
    (`scripts/instalar-panel.sh`); o, en una copia del catálogo de plugins (solo `plugin/fabrica`), el destino
    del enlace `$FABRIK_DATA/scripts` que crea `./install.sh`."""
    if os.environ.get("FABRIK_HOME"):
        return Path(os.environ["FABRIK_HOME"]).expanduser()
    aqui = Path(__file__).resolve().parents[3]
    if (aqui / "scripts").is_dir():
        return aqui
    enlace = fabrik_data() / "scripts"
    if enlace.is_symlink() and enlace.resolve().is_dir():
        return enlace.resolve().parent
    return aqui


def fabrik_data() -> Path:
    """Datos de la fábrica (locks, logs, cupos…): FABRIK_DATA o ~/.hermes/factory."""
    return Path(os.environ.get("FABRIK_DATA") or "~/.hermes/factory").expanduser()


def config() -> dict:
    """Config fusionada de la fábrica (motor < packs < personal) vía `scripts/fabrik_config.py`; {} si falla."""
    global _cfg_mod
    try:
        if _cfg_mod is None:
            spec = importlib.util.spec_from_file_location("fabrica_fabrik_config", fabrik_home() / "scripts" / "fabrik_config.py")
            if spec is None or spec.loader is None:
                return {}
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _cfg_mod = mod
        cfg = _cfg_mod.cargar()
        return cfg if isinstance(cfg, dict) else {}
    except Exception:  # noqa: BLE001 - sin config el panel sigue (cada bloque decide qué hacer)
        return {}


def yaml_safe_load(texto: str):
    """`safe_load` de PyYAML si está; si no, el del núcleo (`hermes_yaml`, ruamel): Hermes ya no trae PyYAML."""
    try:
        import yaml
    except ImportError:
        import hermes_yaml as yaml
    return yaml.safe_load(texto)


def no_disponible(motivo: str) -> dict:
    """Respuesta estándar de un bloque que no puede leer su fuente."""
    return {"disponible": False, "motivo": motivo}
