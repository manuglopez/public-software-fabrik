"""The Factory — pestaña «Cupos y costes» (AC-4c): `GET /costes`.

- `bolsas_historico`: últimos 7 días de `cupos.jsonl`, un punto por hora y bolsa. La ruta y la lectura por el final
  son las de `fx_sistema` (`ruta_cupos`, `fotos_desde`): el panel lee el log en un solo sitio.
- `rate_limited`: `fabrik-cupos rate-limited --json` sumado por día (con las esperas por cupo).
- `pago`: $ de los proveedores marcados `coste: pago` en `modelos.pool`, desde las sesiones que registra Hermes
  (`sessions.actual_cost_usd`, si no `estimated_cost_usd`, de `<hermes>/state.db` y `<hermes>/profiles/*/state.db`).
  Las suscripciones nunca van en $: su gasto son los % de las bolsas y los `tokens` de la última foto.
"""
from __future__ import annotations

import json
import os
import shutil
import time
from contextlib import closing
from pathlib import Path

import fabrica_comun as comun
import fabrica_fx_sistema as sistema  # lectura de cupos.jsonl; plugin_api lo carga antes que este módulo

DIAS = 7
TIMEOUT_CUPOS = 25
CUBO = 3600  # s: un punto por hora


def ahora() -> float:
    return time.time()


def historico(fotos: list[dict]) -> list[dict]:
    cubos: dict[str, dict[int, list]] = {}
    for foto in fotos:  # cronológico: en cada hora gana la última
        t = int(float(foto["t"]))
        for bolsa, valor in foto["bolsas"].items():
            try:
                pct = float(valor[0])
            except (TypeError, ValueError, IndexError, KeyError):
                continue
            cubos.setdefault(bolsa, {})[t // CUBO] = [t, pct]
    return [{"bolsa": b, "puntos": [c[k] for k in sorted(c)]} for b, c in sorted(cubos.items())]


def tokens(foto: dict | None) -> list[dict]:
    """[entrada nueva, salida, leída de caché] acumulados por familia: lo que gastan las suscripciones (no $)."""
    salida = []
    for familia, v in sorted(((foto or {}).get("tokens") or {}).items()):
        try:
            salida.append({"familia": familia, "entrada": int(v[0]), "salida": int(v[1]), "cache": int(v[2])})
        except (TypeError, ValueError, IndexError, KeyError):
            continue
    return salida


def _cli_cupos() -> str:
    propia = comun.fabrik_home() / "bin" / "fabrik-cupos"
    return str(propia) if propia.is_file() else (shutil.which("fabrik-cupos") or str(propia))


def rate_limited(avisos: list[str]) -> list[dict]:
    ok, salida = comun.ejecutar([_cli_cupos(), "rate-limited", "--json"], timeout=TIMEOUT_CUPOS)
    if not ok:
        avisos.append(f"rate-limited: {(salida.splitlines() or ['sin respuesta'])[-1][:160]}")
        return []
    try:
        datos, _ = json.JSONDecoder().raw_decode(salida[salida.index("{"):])
        dias, esperas = datos.get("dias") or {}, datos.get("esperas") or {}
        return [
            {"dia": d, "n": sum(dias[d].values()), "esperas": sum((esperas.get(d) or {}).values())}
            for d in sorted(dias)
        ]
    except (ValueError, AttributeError, TypeError):
        avisos.append("rate-limited: salida de fabrik-cupos no válida")
        return []


def _raiz_hermes() -> Path:
    """Raíz de Hermes (donde viven `state.db` y `profiles/`); `HERMES_HOME` de un perfil apunta a `<raíz>/profiles/<p>`."""
    casa = Path(os.environ.get("HERMES_HOME") or "~/.hermes").expanduser()
    return casa.parent.parent if casa.parent.name == "profiles" else casa


def _proveedores_de_pago(cfg: dict) -> list[str]:
    pool = (cfg.get("modelos") or {}).get("pool")
    entradas = [e for nivel in (pool.values() if isinstance(pool, dict) else []) if isinstance(nivel, list) for e in nivel]
    return sorted({e["proveedor"] for e in entradas if isinstance(e, dict) and e.get("coste") == "pago" and e.get("proveedor")})


def pago(avisos: list[str]) -> list[dict]:
    cfg = comun.config()
    proveedores = _proveedores_de_pago(cfg)
    if not proveedores:
        return []
    permitido = (cfg.get("modelos") or {}).get("permitir_pago") is True
    raiz = _raiz_hermes()
    desde = ahora() - DIAS * 86400
    usd = {p: 0.0 for p in proveedores}
    sesiones = {p: 0 for p in proveedores}
    marcas = ",".join("?" * len(proveedores))
    for db in [raiz / "state.db", *sorted(raiz.glob("profiles/*/state.db"))]:
        if not db.is_file():
            continue
        try:
            with closing(comun.conectar_ro(db)) as con:
                filas = con.execute(
                    "SELECT billing_provider, SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)), COUNT(*) "
                    f"FROM sessions WHERE started_at >= ? AND billing_provider IN ({marcas}) GROUP BY billing_provider",
                    (desde, *proveedores),
                ).fetchall()
        except Exception as e:  # noqa: BLE001 - un state.db roto no tumba el resto
            avisos.append(f"{db.parent.name}/state.db: {type(e).__name__}")
            continue
        for proveedor, suma, n in filas:
            usd[proveedor] += suma or 0.0
            sesiones[proveedor] += n
    return [
        {"proveedor": p, "usd": round(usd[p], 2), "sesiones": sesiones[p], "permitido": permitido} for p in proveedores
    ]


def costes() -> dict:
    avisos: list[str] = []
    ruta, fotos = sistema.ruta_cupos(), []
    if ruta.is_file():
        try:
            fotos = sistema.fotos_desde(ruta, ahora() - DIAS * 86400)
        except OSError as e:
            avisos.append(f"cupos.jsonl: {e.strerror or e}")
    else:
        avisos.append(f"sin cupos.jsonl ({ruta})")
    return {
        "disponible": True,
        "bolsas_historico": historico(fotos),
        "rate_limited": rate_limited(avisos),
        "pago": pago(avisos),
        "tokens": tokens(fotos[-1] if fotos else None),
        "avisos": avisos,
    }


def registrar(router) -> None:
    @router.get("/costes")
    def get_costes() -> dict:
        return costes()
