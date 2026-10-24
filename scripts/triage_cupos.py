#!/usr/bin/env python3
"""scripts/triage_cupos.py — Aparcar y retomar tarjetas según cupo de sus cadenas de modelos.

Lógica testeable extraída de bin/fabrik-triage. No importa Hermes: recibe la
conexión SQLite del tablero y un callable `hk` para ejecutar `hermes kanban …`
(en producción el `hk` de fabrik-triage; en tests un doble que registra).
"""
from __future__ import annotations

import datetime
import json
import os
import time
from pathlib import Path
from typing import Any, Callable, Optional

import cupos

ROLES = {"orquestador", "explorador", "programador", "tester", "revisor", "seguridad", "docs"}
ESTADO_DEFAULT = Path.home() / ".hermes/factory/cupo-espera.json"

_aviso_sin_filtro: dict[str, Any] = {"activo": False, "motivo": None}


def _cargar_estado(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _guardar_estado(path: Path, estado: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(estado))
    os.replace(tmp, path)  # atómico: nunca queda un JSON a medias


def _foto(ahora: float) -> tuple[Optional[dict[str, Any]], Optional[str]]:
    # Sin caché: la edad de la foto se evalúa en cada pasada (el proceso es largo y,
    # si el medidor cae, el mtime no cambia). Son ~8 KB cada 2 s.
    ruta = Path(os.environ.get("FABRIK_CUPOS_LOG", str(cupos.LOG_DEFAULT)))
    return cupos.ultima_foto(ruta, ahora=ahora)


def _aviso_entrada(motivo: str, log: Callable[[str], None]) -> None:
    if not _aviso_sin_filtro["activo"]:
        log(f"⚠ cupos: {motivo}; despacho sin filtrar")
        _aviso_sin_filtro["activo"] = True
        _aviso_sin_filtro["motivo"] = motivo


def _aviso_salida(log: Callable[[str], None]) -> None:
    if _aviso_sin_filtro["activo"]:
        log("✓ cupos: foto recuperada; despacho filtrado de nuevo")
        _aviso_sin_filtro["activo"] = False
        _aviso_sin_filtro["motivo"] = None


def _parse_iso_ts(iso: Optional[str]) -> Optional[float]:
    if not iso:
        return None
    try:
        dt = datetime.datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
        return dt.timestamp()
    except Exception:
        return None


def _pasado(iso: Optional[str], ahora: float) -> bool:
    ts = _parse_iso_ts(iso)
    return ts is not None and ts <= ahora


def _fmt_local(iso: Optional[str]) -> str:
    if not iso:
        return "?"
    ts = _parse_iso_ts(iso)
    if ts is None:
        return iso
    dt = datetime.datetime.fromtimestamp(ts).astimezone()
    return f"{dt:%d/%m %H:%M}"


def _fila(c: Any, tid: str) -> Optional[tuple[str, str, str, str, str]]:
    row = c.execute(
        "select status, coalesce(assignee,''), coalesce(title,''), "
        "coalesce(model_override,''), coalesce(provider_override,'') from tasks where id=?",
        (tid,),
    ).fetchone()
    if row is None:
        return None
    return row[0], row[1], row[2], row[3], row[4]


def _cadena(assignee: str, mo: str, po: str) -> list[tuple[str, str]]:
    return cupos.cadena_de(assignee, model_override=mo or None, provider_override=po or None)


def _retomar(board: str, tid: str, be: dict[str, Any], hk: Callable, seco: bool,
             log: Callable[[str], None], motivo: str) -> None:
    if seco:
        print(f"retomar {board} {tid}")
    else:
        hk("--board", board, "unblock", tid)
    be.pop(tid, None)
    log(f"{board} {tid}: retomada ({motivo})")


def _sin_filtro(board: str, c: Any, be: dict[str, Any], hk: Callable, seco: bool,
                log: Callable[[str], None], motivo: str) -> None:
    """Foto ausente/vieja/rota o excepción: no se aparca nada y se desaparca lo aparcado."""
    _aviso_entrada(motivo, log)
    for tid in list(be):
        fila = _fila(c, tid)
        if fila is not None and fila[0] == "scheduled":
            _retomar(board, tid, be, hk, seco, log, motivo="sin foto válida")
        else:
            be.pop(tid, None)


def _procesar_aparcadas(board: str, c: Any, be: dict[str, Any], foto: dict[str, Any],
                        ahora: float, hk: Callable, seco: bool,
                        log: Callable[[str], None]) -> None:
    """Retoma las aparcadas que ya pueden lanzarse; respeta desbloqueos humanos."""
    for tid, info in list(be.items()):
        if not isinstance(info, dict):
            del be[tid]
            continue
        fila = _fila(c, tid)
        if fila is None:
            del be[tid]
            continue
        status, assignee, _title, mo, po = fila
        if status != "scheduled":
            # Alguien la movió (p. ej. unblock manual). No se reaparca en la misma
            # ventana (mismo renueva): manda el humano. Se guarda y se limpia al
            # cambiar de ventana.
            if _pasado(info.get("renueva"), ahora):
                be.pop(tid, None)
            else:
                info["desbloqueo_humano"] = True
            continue
        if info.get("desbloqueo_humano"):
            continue
        cadena = _cadena(assignee, mo, po)
        lanzable, _bolsa, renueva_iso, agotadas = cupos.estado_cadena(cadena, foto, ahora)
        if lanzable or _pasado(info.get("renueva"), ahora):
            _retomar(board, tid, be, hk, seco, log, motivo="cupo disponible")
        elif renueva_iso and renueva_iso != info.get("renueva"):
            info.update(renueva=renueva_iso, bolsas=agotadas)


def _procesar_ready(board: str, c: Any, be: dict[str, Any], foto: dict[str, Any],
                    ahora: float, hk: Callable, seco: bool,
                    log: Callable[[str], None]) -> None:
    """Aparca las ready cuya cadena entera esté agotada (un comentario por espera)."""
    rows = c.execute(
        "select id, coalesce(assignee,''), coalesce(title,''), "
        "coalesce(model_override,''), coalesce(provider_override,'') from tasks where status='ready'"
    ).fetchall()
    for tid, assignee, title, mo, po in rows:
        if "[manual]" in (title or "") or assignee not in ROLES:
            continue
        cadena = _cadena(assignee, mo, po)
        lanzable, bolsa, renueva_iso, agotadas = cupos.estado_cadena(cadena, foto, ahora)
        if lanzable:
            continue
        info = be.get(tid)
        if info and info.get("desbloqueo_humano") and info.get("renueva") == renueva_iso:
            # Desbloqueada a mano en esta misma ventana: no se vuelve a aparcar.
            continue
        if info and info.get("renueva") == renueva_iso:
            # Ya aparcada en esta ventana: un solo schedule y un solo comentario.
            continue
        if not seco:
            # Guarda ready→running: el gateway puede haber reclamado la tarjeta desde el
            # `select` y `schedule` también aparca las running (dejaría un worker huérfano).
            fila_actual = _fila(c, tid)
            if fila_actual is None or fila_actual[0] != "ready":
                continue
        texto = (f"⏳ esperando cupo de {bolsa} (renueva {_fmt_local(renueva_iso)} hora local); "
                 f"cadena agotada: {', '.join(agotadas)}")
        if seco:
            print(f"esperar-cupo {board} {tid} → {bolsa} (renueva {renueva_iso})")
        else:
            # `schedule <id> <texto>` ya deja el comentario «SCHEDULED: <texto>» (uno por aparcado).
            hk("--board", board, "schedule", tid, texto)
        be[tid] = {"renueva": renueva_iso, "bolsas": agotadas, "aparcada_en": ahora}


def esperar_cupo(board: str, c: Any, *, hk: Callable[..., Any], seco: bool = False,
                 ahora: Optional[float] = None, estado_path: Optional[Path | str] = None,
                 log: Optional[Callable[[str], None]] = None) -> dict[str, Any]:
    """Una pasada de aparcado/retomada por cupo sobre un tablero.

    - board: nombre del tablero.
    - c: conexión SQLite del tablero (hermes_cli.kanban_db_connect.connect o un double).
    - hk: callable(*args, timeout=...) como el de fabrik-triage; en tests un doble.
    - seco: imprime `esperar-cupo …` / `retomar …` sin ejecutar nada.
    - ahora: timestamp fijo para tests (sin sleep ni tiempos relativos).
    - estado_path: ruta al JSON de esperas (FABRIK_CUPO_ESTADO por defecto).
    - log: callable de log (por defecto silencioso).
    """
    log = log or (lambda _msg: None)
    ts = time.time() if ahora is None else float(ahora)
    path = Path(estado_path) if estado_path is not None else Path(
        os.environ.get("FABRIK_CUPO_ESTADO", str(ESTADO_DEFAULT)))
    estado = _cargar_estado(path)
    be = estado.setdefault(board, {})

    try:
        foto, motivo = _foto(ts)
        if foto is None:
            _sin_filtro(board, c, be, hk, seco, log, motivo or "foto no disponible")
        else:
            _aviso_salida(log)
            _procesar_aparcadas(board, c, be, foto, ts, hk, seco, log)
            _procesar_ready(board, c, be, foto, ts, hk, seco, log)
    except Exception as e:  # el medidor nunca bloquea la fábrica
        _sin_filtro(board, c, be, hk, seco, log, f"excepción: {e}")

    estado[board] = be
    if not seco:
        # En seco no se persiste nada: `--seco` contra tableros reales no cambia estado.
        _guardar_estado(path, estado)
    return be
