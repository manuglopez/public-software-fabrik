"""The Factory — backend del panel (namespace /api/plugins/fabrica/).

Monta un APIRouter y carga, si existen, los módulos hermanos `fx_*.py` (D-4): cada tarjeta añade su propio
módulo con `registrar(router)` y no toca este fichero. El gateway carga este fichero con
`spec_from_file_location` sin poner `dashboard/` en sys.path, así que los hermanos se cargan por ruta. Antes que
ellos se carga `comun.py` como `fabrica_comun` (D-9 R-4): tableros, SQLite de solo lectura, comandos y config.
Un bloque que no puede leer su fuente devuelve `{"disponible": false, "motivo": "…"}`; nada tumba el resto.
"""
from __future__ import annotations

import importlib.util
import logging
import shutil
import sys
from pathlib import Path

from fastapi import APIRouter

VERSION = "0.1.0"
MODULOS = [
    "fx_tablero", "fx_atascadas", "fx_acciones", "fx_sistema", "fx_memoria",
    "fx_proyectos", "fx_costes", "fx_reglas", "fx_agentes", "fx_consola",
]

COMUN = "fabrica_comun"

log = logging.getLogger(__name__)
router = APIRouter()


def cargar_comun(base: Path) -> None:
    """Publica `base/comun.py` como `fabrica_comun` (D-9 R-4) para que los `fx_*` hagan `import fabrica_comun`."""
    sys.modules.pop(COMUN, None)
    ruta = base / "comun.py"
    spec = importlib.util.spec_from_file_location(COMUN, ruta) if ruta.is_file() else None
    if spec is None or spec.loader is None:
        log.warning("fabrica: falta %s; los fx_* que importen fabrica_comun no cargarán", ruta)
        return
    try:
        mod = importlib.util.module_from_spec(spec)
        sys.modules[COMUN] = mod
        spec.loader.exec_module(mod)
    except Exception:  # noqa: BLE001 - sin comun los fx que lo importen fallarán solos; /salud sigue
        sys.modules.pop(COMUN, None)
        log.exception("fabrica: no se pudo cargar comun.py")


def cargar_modulos(r: APIRouter, directorio: Path | None = None) -> list[str]:
    """Registra en `r` los módulos de MODULOS que existan en `directorio` (antes, su comun.py); devuelve los cargados."""
    base = directorio or Path(__file__).resolve().parent
    cargar_comun(base)
    cargados: list[str] = []
    for nombre in MODULOS:
        ruta = base / f"{nombre}.py"
        if not ruta.is_file():
            continue
        try:
            spec = importlib.util.spec_from_file_location(f"fabrica_{nombre}", ruta)
            if spec is None or spec.loader is None:
                raise ImportError(f"no se puede cargar {ruta}")
            mod = importlib.util.module_from_spec(spec)
            # Se registra antes de ejecutar: pydantic resuelve anotaciones por nombre de módulo.
            sys.modules[spec.name] = mod
            spec.loader.exec_module(mod)
            mod.registrar(r)
            cargados.append(nombre)
        except Exception:  # noqa: BLE001 - un módulo roto no puede tumbar el panel
            sys.modules.pop(f"fabrica_{nombre}", None)
            log.exception("fabrica: no se pudo cargar %s", nombre)
    return cargados


@router.get("/salud")
def salud() -> dict:
    """Estado del backend y de cada fuente (true = utilizable). Las fuentes reales las rellenan los módulos."""
    return {
        "ok": True,
        "version": VERSION,
        "fuentes": {
            "kanban": shutil.which("hermes") is not None,
            "gh": shutil.which("gh") is not None,
            "cupos": shutil.which("fabrik-cupos") is not None,
            "memoria": shutil.which("fabrik-memoria") is not None,
        },
    }


cargar_modulos(router)
