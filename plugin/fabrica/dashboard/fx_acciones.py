"""The Factory · acciones de escritura (AC-2b, D-7): `POST /acciones/{aprobar,desatascar,set-model}`.

Lista cerrada: solo `hermes kanban --board <slug> {comment|unblock|assign|set-model}` ejecutados con
`comun.ejecutar` (sin shell, 30 s). Los argumentos se validan antes (slug de tablero que existe, `t_[0-9a-f]+`,
(proveedor, modelo) de los configurados) y cada acción deja un comentario `🏭 The Factory: <acción>`.
Nunca se escribe en SQLite: las lecturas previas usan `comun.conectar_ro`.
"""
import re
import sqlite3
from contextlib import closing

import fabrica_comun as comun
from fastapi import HTTPException
from pydantic import BaseModel

TIMEOUT = 30
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]*$")
TAREA = re.compile(r"^t_[0-9a-f]+$")
PERFIL = re.compile(r"[A-Za-z0-9][\w.\-]*")
NOMBRE_MODELO = re.compile(r"^[A-Za-z0-9][\w.\-:/]*$")
PLAN = re.compile(r"^\s*PLAN\b")
APROBADO = "adelante (desde The Factory)"


class Tarjeta(BaseModel):
    board: str
    task_id: str


class CambioModelo(Tarjeta):
    modelo: str
    proveedor: str


# ---- validación ------------------------------------------------------------------------------------------------

def modelos_configurados(cfg: dict) -> set[tuple[str, str]]:
    """(proveedor, modelo) de la config fusionada: roles (+ reservas), pool, reserva_final y `reparto.rutas` (D-5)."""
    modelos = cfg.get("modelos") if isinstance(cfg, dict) and isinstance(cfg.get("modelos"), dict) else {}
    par = lambda d, prov=None: (  # noqa: E731
        (str(d.get("proveedor") or prov), str(d["modelo"])) if isinstance(d, dict) and d.get("modelo") and (d.get("proveedor") or prov) else None
    )
    hallados = []
    for clave, datos in modelos.items():
        if clave == "reserva_final":
            hallados.append(par(datos))
        elif clave == "pool" and isinstance(datos, dict):
            hallados += [par(e) for nivel in datos.values() if isinstance(nivel, list) for e in nivel]
        elif clave == "reparto" and isinstance(datos, dict) and isinstance(datos.get("rutas"), dict):
            hallados += [par(r) for r in datos["rutas"].values()]
        elif isinstance(datos, dict) and clave != "permitir_pago":  # un rol
            hallados.append(par(datos))
            reserva = datos.get("reserva")
            hallados += [par(r, datos.get("proveedor")) for r in ([reserva] if isinstance(reserva, dict) else reserva or [])]
    return {p for p in hallados if p}


def _tarjeta(cuerpo: Tarjeta):
    """Valida tablero y tarjeta; devuelve (ruta del tablero, fila de la tarjeta) o responde 400/404."""
    if not SLUG.fullmatch(cuerpo.board):
        raise HTTPException(400, "board no válido")
    if not TAREA.fullmatch(cuerpo.task_id):
        raise HTTPException(400, "task_id no válido")
    ruta = dict(comun.tableros()).get(cuerpo.board)
    if ruta is None:
        raise HTTPException(400, f"el tablero {cuerpo.board} no existe")
    try:
        with closing(comun.conectar_ro(ruta)) as con:
            fila = con.execute(
                "SELECT status, block_kind, assignee, title, last_failure_error FROM tasks WHERE id = ?", (cuerpo.task_id,)
            ).fetchone()
    except sqlite3.Error as e:
        raise HTTPException(503, f"no se pudo leer el tablero: {e}") from e
    if fila is None:
        raise HTTPException(404, f"la tarjeta {cuerpo.task_id} no existe en {cuerpo.board}")
    return ruta, fila


# ---- ejecución ---------------------------------------------------------------------------------------------------

def _kanban(board: str, *args: str) -> tuple[bool, str]:
    return comun.ejecutar(["hermes", "kanban", "--board", board, *args], TIMEOUT)


def _comentario(board: str, task_id: str, accion: str) -> tuple[bool, str]:
    return _kanban(board, "comment", task_id, f"🏭 The Factory: {accion}")


def _pasos(board: str, task_id: str, accion: str, pasos: list[tuple[str, ...]]) -> dict:
    """Ejecuta los pasos en orden y, si todos van bien, deja el comentario 🏭. Se para en el primer fallo."""
    salidas = []
    for paso in pasos:
        ok, salida = _kanban(board, *paso)
        salidas.append(salida)
        if not ok:
            return {"ok": False, "salida": f"falló `{' '.join(paso)}`: {salida}"}
    ok, salida = _comentario(board, task_id, accion)
    salidas.append(salida)
    return {"ok": ok, "salida": "\n".join(s for s in salidas if s)}


def aprobar(cuerpo: Tarjeta) -> dict:
    _ruta, fila = _tarjeta(cuerpo)
    if not (fila["status"] == "blocked" and fila["block_kind"] == "needs_input" and PLAN.match(fila["title"] or "")):
        raise HTTPException(409, "solo se aprueba un PLAN bloqueado a la espera de una respuesta (needs_input)")
    return _pasos(cuerpo.board, cuerpo.task_id, "aprobar", [("comment", cuerpo.task_id, APROBADO), ("unblock", cuerpo.task_id)])


def desatascar(cuerpo: Tarjeta) -> dict:
    ruta, fila = _tarjeta(cuerpo)
    perfil = fila["assignee"]
    if not perfil or not PERFIL.fullmatch(perfil) or perfil == "none":  # nunca empieza por «-»: no es una opción
        raise HTTPException(409, "la tarjeta no tiene perfil asignado que restaurar")
    if fila["status"] in ("running", "done", "archived"):
        raise HTTPException(409, f"no se desatasca una tarjeta en estado {fila['status']}")
    res = _pasos(
        cuerpo.board, cuerpo.task_id, "desatascar",
        [("assign", cuerpo.task_id, "none"), ("assign", cuerpo.task_id, perfil)],
    )
    if not res["ok"]:
        return {**res, "salida": f"{res['salida']} · comprueba que la tarjeta conserve su perfil ({perfil})"}
    # `kanban show` mezclaría comentarios y eventos (y `ejecutar` recorta la salida): se lee el campo, solo lectura.
    try:
        with closing(comun.conectar_ro(ruta)) as con:
            error = con.execute("SELECT last_failure_error FROM tasks WHERE id = ?", (cuerpo.task_id,)).fetchone()[0]
    except sqlite3.Error as e:
        return {"ok": False, "salida": f"reasignada, pero no se pudo comprobar el error: {e}"}
    if error:
        return {"ok": False, "salida": f"reasignada a {perfil}, pero last_failure_error sigue: {str(error)[:200]}"}
    return res


def set_model(cuerpo: CambioModelo) -> dict:
    if not NOMBRE_MODELO.fullmatch(cuerpo.modelo) or not NOMBRE_MODELO.fullmatch(cuerpo.proveedor):
        raise HTTPException(400, "modelo o proveedor no válido")
    if (cuerpo.proveedor, cuerpo.modelo) not in modelos_configurados(comun.config()):
        raise HTTPException(400, f"{cuerpo.proveedor}/{cuerpo.modelo} no está entre los modelos configurados")
    _tarjeta(cuerpo)
    return _pasos(
        cuerpo.board, cuerpo.task_id, f"set-model {cuerpo.proveedor}/{cuerpo.modelo}",
        [("set-model", cuerpo.task_id, cuerpo.modelo, "--provider", cuerpo.proveedor)],
    )


def registrar(router) -> None:
    router.add_api_route("/acciones/aprobar", aprobar, methods=["POST"])
    router.add_api_route("/acciones/desatascar", desatascar, methods=["POST"])
    router.add_api_route("/acciones/set-model", set_model, methods=["POST"])
