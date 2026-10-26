"""Pestaña Agentes (plan The Factory D-5, AC-4b/AC-2b): muestra y edita el reparto dinámico de `bin/fabrik-modelos`.

  GET  /agentes                 reparto vigente + disponibilidad, perfiles, brazos 7 d, cuentas, reglas y avisos
  GET  /agentes/informe?dias=   informe de calidad (`fabrik-modelos informe <días> --json`)
  POST /agentes/validar         {reparto: parcial} → {errores}
  POST /agentes/guardar         igual → {ok, errores, salida}: escribe solo `modelos.reparto` en la config personal
  POST /agentes/aplicar         {} → {ok, salida}: `fabrik-modelos tick` (lista cerrada, sin shell, una línea de log)

El reparto parcial solo trae lo editable (roles, ultimo_recurso, topes, topes_cuenta); en los mapas, cada entrada dada
sustituye a la vigente y las demás se quedan. El catálogo de rutas no se edita aquí.
"""
from __future__ import annotations

import importlib.util
import json
import logging
import subprocess
import sys
from pathlib import Path

import fabrica_comun as comun
from fastapi import Body, Query

log = logging.getLogger("fabrica.agentes")
EDITABLES = ("roles", "ultimo_recurso", "topes", "topes_cuenta")
T_LEER, T_TICK = 120, 300  # s (sin PyYAML, fabrik-modelos lee la config con `uv run`: la primera vez tarda)
_mods: dict = {}


def _hermano(nombre: str, fichero):
    """Módulo hermano (fx_reglas) o scripts/fabrik_config.py, cargado una vez por ruta."""
    clave = str(fichero)
    if clave not in _mods:
        spec = importlib.util.spec_from_file_location(nombre, fichero)
        if spec is None or spec.loader is None:
            raise ImportError(f"no se puede cargar {fichero}")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _mods[clave] = mod
    return _mods[clave]


def _reglas_mod():
    return sys.modules.get("fabrica_fx_reglas") or _hermano("fabrica_fx_reglas_agentes",
                                                            Path(__file__).resolve().parent / "fx_reglas.py")


def _argv(*args: str) -> list[str]:
    # con el python del panel (trae PyYAML): fabrik-modelos lee la config sin pasar por uv
    return [sys.executable, str(comun.fabrik_home() / "bin" / "fabrik-modelos"), *args]


def _leer(*args: str) -> tuple[dict | None, list[str], str]:
    """(json de stdout | None, avisos de stderr, motivo del fallo). Lee stdout entero (no el resumen de
    `comun.ejecutar`, que se queda con los últimos 2000 caracteres)."""
    try:
        r = subprocess.run(_argv(*args), capture_output=True, text=True, timeout=T_LEER, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as e:
        return None, [], f"fabrik-modelos {' '.join(args)}: {e}"
    avisos = [f"fabrik-modelos: {x[len('aviso: '):]}" for x in r.stderr.splitlines() if x.startswith("aviso: ")]
    if r.returncode != 0:
        return None, avisos, f"fabrik-modelos {' '.join(args)} falló: {(r.stderr or r.stdout).strip()[-500:]}"
    try:
        return json.loads(r.stdout), avisos, ""
    except ValueError:
        return None, avisos, f"fabrik-modelos {' '.join(args)}: salida no es JSON"


def _reglas_config(cfg: dict) -> dict:
    modelos = cfg.get("modelos")
    reglas = modelos.get("reglas") if isinstance(modelos, dict) else None
    return reglas if isinstance(reglas, dict) else {}


def _efectivo(vigente: dict, parcial: dict) -> dict:
    nuevo = dict(vigente)
    for clave, valor in parcial.items():
        previo = vigente.get(clave)
        nuevo[clave] = {**previo, **valor} if isinstance(previo, dict) and isinstance(valor, dict) else valor
    return nuevo


def _errores(parcial) -> tuple[list[str], dict]:
    """(errores, config) del reparto parcial aplicado sobre el vigente, con las reglas D-6 de la config."""
    if not isinstance(parcial, dict):
        return ["reparto: tiene que ser un mapa"], {}
    errores = []
    for clave in parcial:
        if clave == "rutas":
            errores.append("rutas: el catálogo de rutas no se edita desde el panel (va en el yaml)")
        elif clave not in EDITABLES:
            errores.append(f"{clave}: clave desconocida (se editan {', '.join(EDITABLES)})")
    if errores:
        return errores, {}
    estado, _, motivo = _leer("estado", "--json")
    if estado is None:
        return [f"no se puede leer el reparto vigente: {motivo}"], {}
    cfg = comun.config()
    return _reglas_mod().validar_reparto(cfg, _efectivo(estado.get("reparto") or {}, parcial)), cfg


def registrar(router) -> None:
    @router.get("/agentes")
    def agentes() -> dict:
        estado, avisos, motivo = _leer("estado", "--json")
        if estado is None:
            return comun.no_disponible(motivo)
        cfg = comun.config()
        reparto = estado.get("reparto") or {}
        return {"reparto": reparto, "estado": estado.get("estado", []), "perfiles": estado.get("perfiles", []),
                "brazos_7d": estado.get("brazos_7d", []), "cuentas": estado.get("cuentas", []),
                "reglas": _reglas_config(cfg), "avisos": avisos + _reglas_mod().validar_reparto(cfg, reparto)}

    @router.get("/agentes/informe")
    def informe(dias: int = Query(14, ge=1, le=90)) -> dict:
        datos, _, motivo = _leer("informe", str(dias), "--json")
        return datos if datos is not None else comun.no_disponible(motivo)

    @router.post("/agentes/validar")
    def validar(cuerpo: dict = Body(default={})) -> dict:
        return {"errores": _errores(cuerpo.get("reparto", {}))[0]}

    @router.post("/agentes/guardar")
    def guardar(cuerpo: dict = Body(default={})) -> dict:
        parcial = cuerpo.get("reparto", {})
        errores, _ = _errores(parcial)
        if errores:
            return {"ok": False, "errores": errores, "salida": ""}
        try:
            fc = _hermano("fabrica_fabrik_config_agentes", comun.fabrik_home() / "scripts" / "fabrik_config.py")
            ruta = fc.guardar_reparto(parcial)
        except Exception as e:  # noqa: BLE001 - YAML personal roto, permisos…: se cuenta, no revienta
            return {"ok": False, "errores": [f"no se pudo guardar: {e}"], "salida": ""}
        log.info("fabrica: agentes guardar → modelos.reparto (%s) en %s", ", ".join(parcial) or "nada", ruta)
        return {"ok": True, "errores": [],
                "salida": f"Guardado en {ruta}. Se aplica en el próximo tick (≤10 min) o con «Aplicar ahora»."}

    @router.post("/agentes/aplicar")
    def aplicar(cuerpo: dict = Body(default={})) -> dict:  # noqa: ARG001 - el contrato es POST {}
        ok, salida = comun.ejecutar(_argv("tick"), T_TICK)
        log.info("fabrica: agentes aplicar → fabrik-modelos tick (%s)", "ok" if ok else "falló")
        return {"ok": ok, "salida": salida}
