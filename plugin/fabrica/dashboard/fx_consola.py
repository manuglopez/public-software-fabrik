"""The Factory — consola por tarjeta (AC-5): un PTY del backend en el worktree de la tarjeta.

    POST /consola/abrir {board, task_id}     → {id, titulo, cwd, en_marcha}   (la misma consola si ya está abierta)
    WS   /consola/{id}?desde=n               → frames {datos, desde, hasta, viva} (latido sin datos cada ~2 s)
    GET  /consola/{id}/salida?desde=n&espera=ms → {datos, desde, hasta, viva}   (respaldo por sondeo: anillo de 256 KB)
    POST /consola/{id}/entrada {datos} · /tamano {cols, filas} · /cerrar {}
    POST /consola/sistema {board, task_id}   → `fabrik-consola <repo> <slug>` (terminal del sistema)

Seguridad: solo se abren worktrees cuya ruta real (`realpath`) es exactamente `<dir_codigo>/.factory-worktrees/<repo>/<slug>`;
el hijo entra por el descriptor del directorio ya validado (`fchdir`), así que un enlace cambiado después no lo desvía.
`.factory/env` se lee como `KEY=valor` (nunca se ejecuta) desde el descriptor del worktree, sin seguir enlaces ni abrir
FIFOs, fuera del cerrojo, y solo con las claves `DB_*`/`FX_*`; el shell no hereda los secretos de Hermes del servidor
(saneador de Hermes + filtro por sufijos `_API_KEY/_TOKEN/_SECRET/_PASSWORD`). Ids aleatorios (`secrets.token_urlsafe`).
Nunca se registran teclas ni salida. Máximo 6 consolas; las que llevan 30 min sin teclas ni cambios de tamaño se cierran solas; cerrar mata
toda la sesión del shell (SIGHUP y, si queda algo, SIGKILL).
"""
from __future__ import annotations

import asyncio
import fcntl
import logging
import os
import pty
import re
import secrets
import select
import signal
import stat
import struct
import termios
import threading
import time
import warnings
from contextlib import closing
from pathlib import Path

import fabrica_comun as comun
from fastapi import APIRouter, HTTPException, WebSocket
from pydantic import BaseModel

log = logging.getLogger(__name__)

MAX_CONSOLAS = 6
INACTIVIDAD_S = 30 * 60
ANILLO = 256 * 1024
LATIDO_S = 2.0
MAX_ENTRADA = 64 * 1024
MAX_ENV = 64 * 1024
# Claves de `.factory/env` que llegan al shell: las que escribe `factory-prep` (DB_HOST DB_PORT DB_DATABASE DB_USERNAME
# DB_PASSWORD DB_URL FX_REPO FX_SLUG FX_BRANCH). Cualquier otra (PROMPT_COMMAND, PS1, LD_PRELOAD, BASH_ENV, PATH, HOME…)
# ejecutaría código en el shell del humano, fuera de las aprobaciones de Hermes.
_CLAVE_ENV = re.compile(r"^(DB|FX)_[A-Z0-9_]+$")
# Sufijos de variables con secretos: el shell no los hereda del servidor (las `DB_*` llegan solo desde `.factory/env`).
_SUFIJOS_SECRETOS = ("_API_KEY", "_TOKEN", "_SECRET", "_PASSWORD")
_NOMBRE_SEGURO = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_reloj = time.monotonic  # los tests lo sustituyen para simular la inactividad

_consolas: dict[str, "Consola"] = {}
_cerrojo = threading.Lock()
_vigia: threading.Thread | None = None


class Tarjeta(BaseModel):
    board: str
    task_id: str


class Entrada(BaseModel):
    datos: str


class Tamano(BaseModel):
    cols: int
    filas: int


# ---------------------------------------------------------------- validación del worktree

def _raiz_worktrees() -> Path:
    dir_codigo = comun.config().get("dir_codigo") or "~/Code"
    return Path(os.path.realpath(Path(str(dir_codigo)).expanduser() / ".factory-worktrees"))


def _relativa_valida(real: str, raiz: Path) -> tuple[str, str] | None:
    """(repo, slug) si `real` es exactamente `<raiz>/<repo>/<slug>`; None si no."""
    try:
        partes = Path(real).relative_to(raiz).parts
    except ValueError:
        return None
    if len(partes) != 2 or any(p in ("", ".", "..") for p in partes):
        return None
    return partes[0], partes[1]


def _leer_tarjeta(board: str, task_id: str) -> tuple[str | None, str]:
    """(workspace_path, status) de la tarjeta; 404 si el tablero o la tarjeta no existen."""
    rutas = dict(comun.tableros())
    if board not in rutas:
        raise HTTPException(404, "tablero desconocido")
    try:
        with closing(comun.conectar_ro(rutas[board])) as con:
            fila = con.execute("SELECT workspace_path, status FROM tasks WHERE id = ?", (task_id,)).fetchone()
    except Exception as e:  # noqa: BLE001 - un tablero ilegible es «no disponible», no un 500
        raise HTTPException(503, f"no se pudo leer el tablero: {type(e).__name__}") from e
    if fila is None:
        raise HTTPException(404, "tarjeta desconocida")
    return fila["workspace_path"], fila["status"] or ""


def _abrir_worktree(workspace: str | None) -> tuple[int, str, str, str]:
    """Valida el worktree y devuelve (fd del directorio, ruta real, repo, slug). 400 si no es un worktree de la fábrica."""
    if not workspace:
        raise HTTPException(400, "la tarjeta no tiene worktree")
    raiz = _raiz_worktrees()
    real = os.path.realpath(os.path.expanduser(workspace))
    if _relativa_valida(real, raiz) is None or not os.path.isdir(real):
        raise HTTPException(400, "el worktree no está bajo <dir_codigo>/.factory-worktrees/<repo>/<slug>")
    try:
        fd = os.open(real, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    except OSError as e:
        raise HTTPException(400, "no se puede abrir el worktree") from e
    # Lo que de verdad se ha abierto (si alguien cambió un enlace entre la comprobación y el open, se nota aquí).
    abierto = os.path.realpath(f"/proc/self/fd/{fd}") if os.path.isdir("/proc/self/fd") else real
    partes = _relativa_valida(abierto, raiz)
    if partes is None:
        os.close(fd)
        raise HTTPException(400, "el worktree no está bajo <dir_codigo>/.factory-worktrees/<repo>/<slug>")
    return fd, abierto, partes[0], partes[1]


def _leer_fichero_env(dirfd: int) -> str:
    """Texto (≤ MAX_ENV) de `.factory/env` abierto desde `dirfd`, sin seguir enlaces ni bloquearse.

    `.factory/env` lo puede escribir cualquier agente del worktree: un enlace lo desviaría a otro fichero del sistema y un
    FIFO bloquearía el `open()` para siempre. Si no es un fichero normal, devuelve ""."""
    try:
        fd_factory = os.open(".factory", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dirfd)
    except OSError:
        return ""
    try:
        fd = os.open("env", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=fd_factory)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return ""
            trozos, resto = [], MAX_ENV
            while resto > 0:
                trozo = os.read(fd, resto)
                if not trozo:
                    break
                trozos.append(trozo)
                resto -= len(trozo)
            return b"".join(trozos).decode("utf-8", "replace")
        finally:
            os.close(fd)
    except OSError:
        return ""
    finally:
        os.close(fd_factory)


def leer_env(dirfd: int) -> dict[str, str]:
    """Variables de `.factory/env` del worktree abierto en `dirfd` (`KEY=valor`, `export KEY=valor`, comillas simples o
    dobles). Nunca lo ejecuta. Solo pasan las claves de `_CLAVE_ENV`; el resto se descarta sin registrar su valor."""
    texto = _leer_fichero_env(dirfd)
    salida: dict[str, str] = {}
    for linea in texto.splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#") or "=" not in linea:
            continue
        clave, valor = linea.split("=", 1)
        clave = clave.strip().removeprefix("export ").strip()
        valor = valor.strip()
        if not _CLAVE_ENV.match(clave):
            continue
        if len(valor) >= 2 and valor[0] == valor[-1] and valor[0] in "'\"":
            valor = valor[1:-1]
        salida[clave] = valor.replace("\0", "")
    return salida


def _argv_shell() -> list[str]:
    shell = os.environ.get("SHELL") or ""
    if not (os.path.isabs(shell) and os.access(shell, os.X_OK)):
        shell = "/bin/bash"
    return [shell, "-l"]


def _entorno_base() -> dict[str, str]:
    """Entorno del servidor sin los secretos de Hermes (claves de proveedores, tokens de bots…) ni `HERMES_KANBAN_*`.

    Base: el saneador de Hermes (el de los comandos de los agentes) si se puede importar; además, siempre, el filtro por
    sufijos, que cubre el caso de que no esté (tests, servidor suelto) y lo que el saneador no conozca."""
    base = dict(os.environ)
    try:
        from tools.environments.local import _sanitize_subprocess_env

        base = dict(_sanitize_subprocess_env(base))
    except Exception:  # noqa: BLE001 - sin Hermes cerca (o con otra versión): queda el filtro por sufijos
        pass
    # HERMES_KANBAN_*: que el shell del humano no actúe como un worker de tarjeta.
    return {k: v for k, v in base.items() if not k.startswith("HERMES_KANBAN_") and not k.upper().endswith(_SUFIJOS_SECRETOS)}


def _entorno(cwd: str, dirfd: int) -> dict[str, str]:
    env = _entorno_base()
    env.update(leer_env(dirfd))
    env.update({"TERM": "xterm-256color", "COLORTERM": "truecolor", "PWD": cwd})
    return env


# ---------------------------------------------------------------- la consola

def _corte_utf8(datos: bytes) -> int:
    """Longitud del prefijo de `datos` que no termina a mitad de un carácter UTF-8."""
    n = len(datos)
    for atras in range(1, min(4, n) + 1):
        b = datos[n - atras]
        if b & 0xC0 == 0x80:
            continue  # byte de continuación: seguir buscando el inicio
        largo = 2 if b & 0xE0 == 0xC0 else 3 if b & 0xF0 == 0xE0 else 4 if b & 0xF8 == 0xF0 else 1
        return n - atras if largo > atras else n
    return n


class Consola:
    def __init__(self, board: str, task_id: str, titulo: str, cwd: str, pid: int, fd: int):
        self.id = secrets.token_urlsafe(18)
        self.board, self.task_id, self.titulo, self.cwd = board, task_id, titulo, cwd
        self.pid, self.fd = pid, fd
        self.buf = bytearray()
        self.inicio = 0  # posición absoluta del primer byte del anillo
        self.viva = True
        self.cerrando = False
        self.uso = _reloj()
        self.cond = threading.Condition()
        self.hilo = threading.Thread(target=self._leer, name=f"fabrica-consola-{self.id[:6]}", daemon=True)
        self.hilo.start()

    @property
    def hasta(self) -> int:
        return self.inicio + len(self.buf)

    def _leer(self) -> None:
        while True:
            if self.cerrando:
                break
            try:
                listo, _, _ = select.select([self.fd], [], [], 0.5)
                datos = os.read(self.fd, 65536) if listo else b""
            except BlockingIOError:
                continue
            except OSError:  # EIO: el shell y todo lo que tenía el terminal se han ido
                break
            if listo and not datos:
                break
            if datos:
                with self.cond:
                    self.buf += datos
                    if len(self.buf) > ANILLO:
                        sobra = len(self.buf) - ANILLO
                        del self.buf[:sobra]
                        self.inicio += sobra
                    self.cond.notify_all()
            elif self._salio():
                break
        self._salio()
        with self.cond:
            self.viva = False
            self.cond.notify_all()

    def _salio(self) -> bool:
        try:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            return True
        return pid != 0

    def leer(self, desde: int) -> tuple[str, int, int, bool]:
        """(texto, desde real, hasta, viva) a partir de la posición absoluta `desde` (sin cortar caracteres)."""
        with self.cond:
            desde = min(max(desde, self.inicio), self.hasta)
            trozo = bytes(self.buf[desde - self.inicio:])
            viva = self.viva
        while trozo and trozo[0] & 0xC0 == 0x80 and desde == self.inicio:  # el anillo cortó un carácter por delante
            trozo, desde = trozo[1:], desde + 1
        fin = _corte_utf8(trozo) if viva else len(trozo)
        return trozo[:fin].decode("utf-8", "replace"), desde, desde + fin, viva

    def esperar(self, desde: int, segundos: float) -> None:
        with self.cond:
            self.cond.wait_for(lambda: self.hasta > desde or not self.viva, timeout=max(0.0, segundos))

    def escribir(self, datos: str) -> None:
        self.uso = _reloj()
        if not self.viva:
            raise HTTPException(410, "la consola ha terminado")
        b = datos.encode("utf-8")
        try:
            while b:
                _, listo, _ = select.select([], [self.fd], [], 2.0)
                if not listo:
                    raise HTTPException(503, "la consola no acepta entrada")
                try:
                    b = b[os.write(self.fd, b):]
                except BlockingIOError:
                    continue
        except OSError as e:  # se cerró a mitad
            raise HTTPException(410, "la consola ha terminado") from e

    def redimensionar(self, cols: int, filas: int) -> None:
        self.uso = _reloj()
        if not self.viva:
            raise HTTPException(410, "la consola ha terminado")
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", filas, cols, 0, 0))
        except OSError as e:
            raise HTTPException(410, "la consola ha terminado") from e

    def cerrar(self) -> None:
        """Mata la sesión entera del shell (sus trabajos incluidos), espera a que muera y libera el PTY."""
        for sig, plazo in ((signal.SIGHUP, 1.0), (signal.SIGKILL, 2.0)):
            for pid in _procesos_de_sesion(self.pid):
                try:
                    os.kill(pid, sig)
                except OSError:
                    pass
            try:
                os.killpg(self.pid, sig)
            except OSError:
                pass
            limite = _reloj() + plazo
            while not self._salio() and _reloj() < limite:
                with self.cond:
                    self.cond.wait(0.05)
            if self._salio() and not _procesos_de_sesion(self.pid):
                break
        # El fd lo cierra quien ya no lo usa: primero se para el lector (si no, podría leer de un fd reutilizado).
        self.cerrando = True
        if threading.current_thread() is not self.hilo:
            self.hilo.join(timeout=2.0)
        try:
            os.close(self.fd)
        except OSError:
            pass
        with self.cond:
            self.viva = False
            self.cond.notify_all()


def _procesos_de_sesion(sid: int) -> list[int]:
    """Pids de la sesión `sid` (el shell es líder de sesión: abarca trabajos en otros grupos). Solo Linux (/proc)."""
    pids = []
    try:
        entradas = os.listdir("/proc")
    except OSError:
        return pids
    for e in entradas:
        if not e.isdigit():
            continue
        try:
            with open(f"/proc/{e}/stat", "rb") as f:
                campos = f.read().rsplit(b")", 1)[1].split()
            if int(campos[3]) == sid and campos[0] != b"Z":
                pids.append(int(e))
        except (OSError, IndexError, ValueError):
            continue
    return pids


def _arrancar(board: str, task_id: str, dirfd: int, cwd: str, titulo: str, env: dict[str, str]) -> Consola:
    """Lanza el shell en `dirfd` con `env` (ya calculado: aquí no hay E/S de ficheros). `dirfd` lo cierra quien llama."""
    argv = _argv_shell()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)  # fork con hilos: el hijo solo hace fchdir + exec
        pid, fd = pty.fork()
    if pid == 0:  # hijo: nada que pueda tomar cerrojos antes del exec
        try:
            os.fchdir(dirfd)
            os.closerange(3, os.sysconf("SC_OPEN_MAX"))  # sin maestros de otras consolas ni fds del servidor
            os.execve(argv[0], argv, env)
        finally:
            os._exit(127)
    os.set_blocking(fd, False)
    return Consola(board, task_id, titulo, cwd, pid, fd)


def limpiar_inactivas() -> list[str]:
    """Cierra las consolas muertas o sin uso desde hace INACTIVIDAD_S; devuelve sus ids."""
    ahora = _reloj()
    with _cerrojo:
        fuera = [c for c in _consolas.values() if not c.viva or ahora - c.uso >= INACTIVIDAD_S]
        for c in fuera:
            _consolas.pop(c.id, None)
    for c in fuera:
        c.cerrar()
    return [c.id for c in fuera]


def cerrar_todas() -> None:
    with _cerrojo:
        todas = list(_consolas.values())
        _consolas.clear()
    for c in todas:
        c.cerrar()


def _vigilar() -> None:
    while True:
        threading.Event().wait(60)
        try:
            limpiar_inactivas()
        except Exception:  # noqa: BLE001 - el vigía no puede morir por una consola rara
            log.exception("fabrica: consola: fallo al limpiar inactivas")


def _arrancar_vigia() -> None:
    global _vigia
    if _vigia is None or not _vigia.is_alive():
        _vigia = threading.Thread(target=_vigilar, name="fabrica-consola-vigia", daemon=True)
        _vigia.start()


def _consola(cid: str) -> Consola:
    c = _consolas.get(cid)
    if c is None:
        raise HTTPException(404, "consola desconocida")
    return c


def _abierta_o_429(board: str, task_id: str) -> Consola | None:
    """La consola viva de la tarjeta, si la hay; 429 si no la hay y ya están las MAX_CONSOLAS. Con `_cerrojo` tomado."""
    for c in _consolas.values():
        if (c.board, c.task_id) == (board, task_id) and c.viva:
            return c
    if len(_consolas) >= MAX_CONSOLAS:
        raise HTTPException(429, f"ya hay {MAX_CONSOLAS} consolas abiertas: cierra alguna")
    return None


def _respuesta(c: Consola, en_marcha: bool) -> dict:
    return {"id": c.id, "titulo": c.titulo, "cwd": c.cwd, "en_marcha": en_marcha}


def _autorizar(ws: WebSocket) -> bool:
    """La misma puerta que los sockets del núcleo (como kanban-gantt). Sin núcleo, solo loopback; si la puerta falla, no."""
    try:
        from hermes_cli import web_server_chat as nucleo
    except ImportError:
        host = (ws.client.host if ws.client else "") or ""
        return host in ("127.0.0.1", "::1", "localhost")
    try:
        return bool(nucleo._ws_auth_ok(ws))
    except Exception:  # noqa: BLE001 - fallar cerrado
        return False


# ---------------------------------------------------------------- rutas

def registrar(router: APIRouter) -> None:
    @router.post("/consola/abrir")
    def abrir(t: Tarjeta) -> dict:
        workspace, estado = _leer_tarjeta(t.board, t.task_id)
        en_marcha = estado == "running"
        limpiar_inactivas()
        with _cerrojo:  # camino rápido: ya abierta, o sin hueco; sin tocar el disco
            c = _abierta_o_429(t.board, t.task_id)
        if c is not None:
            return _respuesta(c, en_marcha)
        # La E/S (worktree, `.factory/env`) va fuera del cerrojo: un fichero que se atasque no debe frenar a las demás.
        dirfd, cwd, repo, slug = _abrir_worktree(workspace)
        try:  # `dirfd` es de esta función: se cierra siempre al salir (el hijo no lo hereda: closerange)
            env = _entorno(cwd, dirfd)
            with _cerrojo:  # otro hilo pudo abrirla o llenar el cupo mientras tanto
                c = _abierta_o_429(t.board, t.task_id)
                if c is not None:
                    return _respuesta(c, en_marcha)
                c = _arrancar(t.board, t.task_id, dirfd, cwd, f"{repo}/{slug}", env)
                _consolas[c.id] = c
        except OSError as e:
            raise HTTPException(503, f"no se pudo arrancar el shell: {e.strerror or e}") from e
        finally:
            os.close(dirfd)
        _arrancar_vigia()
        log.info("fabrica: consola abierta (%s/%s)", t.board, t.task_id)
        return _respuesta(c, en_marcha)

    @router.get("/consola/{cid}/salida")
    def salida(cid: str, desde: int = 0, espera: int = 0) -> dict:
        c = _consola(cid)
        if espera > 0:
            c.esperar(desde, min(espera, 5000) / 1000)
        datos, d, hasta, viva = c.leer(desde)
        return {"datos": datos, "desde": d, "hasta": hasta, "viva": viva}

    @router.post("/consola/{cid}/entrada")
    def entrada(cid: str, e: Entrada) -> dict:
        if len(e.datos) > MAX_ENTRADA:
            raise HTTPException(413, "entrada demasiado larga")
        _consola(cid).escribir(e.datos)
        return {"ok": True}

    @router.post("/consola/{cid}/tamano")
    def tamano(cid: str, t: Tamano) -> dict:
        if not (1 <= t.cols <= 1000 and 1 <= t.filas <= 1000):
            raise HTTPException(400, "tamaño fuera de rango")
        _consola(cid).redimensionar(t.cols, t.filas)
        return {"ok": True}

    @router.post("/consola/{cid}/cerrar")
    def cerrar(cid: str) -> dict:
        with _cerrojo:
            c = _consolas.pop(cid, None)
        if c is not None:
            c.cerrar()
        return {"ok": True}

    @router.post("/consola/sistema")
    def sistema(t: Tarjeta) -> dict:
        workspace, _ = _leer_tarjeta(t.board, t.task_id)
        dirfd, _, repo, slug = _abrir_worktree(workspace)
        os.close(dirfd)
        if not (_NOMBRE_SEGURO.match(repo) and _NOMBRE_SEGURO.match(slug)):  # fabrik-consola los mete en un `bash -c`
            raise HTTPException(400, "nombre de worktree no admitido para la terminal del sistema")
        bin_ = comun.fabrik_home() / "bin" / "fabrik-consola"
        ok, texto = comun.ejecutar(["env", f"FX_WT={_raiz_worktrees()}", str(bin_), repo, slug], timeout=15)
        return {"ok": ok, "salida": texto}

    @router.websocket("/consola/{cid}")
    async def flujo(ws: WebSocket, cid: str) -> None:
        if not _autorizar(ws):
            await ws.close(code=1008)
            return
        c = _consolas.get(cid)
        if c is None:
            await ws.close(code=1008)
            return
        try:
            pos = int(ws.query_params.get("desde") or 0)
        except ValueError:
            pos = 0
        await ws.accept()
        recibir = asyncio.ensure_future(ws.receive())  # el cliente no manda nada: solo sirve para ver que se fue
        try:
            while True:
                espera = asyncio.ensure_future(asyncio.to_thread(c.esperar, pos, LATIDO_S))
                hecho, _ = await asyncio.wait({espera, recibir}, return_when=asyncio.FIRST_COMPLETED)
                if recibir in hecho:
                    espera.cancel()
                    break
                datos, desde, pos, viva = c.leer(pos)
                await ws.send_json({"datos": datos, "desde": desde, "hasta": pos, "viva": viva})
                if not viva and not datos:
                    await ws.close()
                    break
        except Exception:  # noqa: BLE001 - un cliente que se va a mitad de envío es lo normal
            pass
        finally:
            recibir.cancel()
