"""The Factory — Cupos (AC-3e) y Máquina (AC-3f): `GET /cupos` y `GET /maquina`. Solo lectura.

- Cupos: última foto de `$FABRIK_DATA/logs/cupos.jsonl` (o `FABRIK_CUPOS_LOG`) leída con `scripts/cupos.py`. Avisa
  cuando una bolsa de `cupos.aviso` (config; por defecto la semanal de Claude, de cada cuenta) pasa del 75 %.
  Aquí vive la única lectura de `cupos.jsonl` del panel: `fx_costes` usa también `ruta_cupos()` y `fotos_desde()`.
- Máquina: RAM y carga de `/proc`, y el turno de `factory-test` (`locks/factory-test.{lock,owner}`; la cola son los
  procesos `factory-test` que esperan, con prioridad si tienen entrada en `locks/prio.d/<pid>`).
"""
from __future__ import annotations

import datetime as dt
import fcntl
import importlib.util
import json
import os
import re
import time
from pathlib import Path

import fabrica_comun as comun

PROC = Path("/proc")
UMBRAL_AVISO = 75  # % a partir del cual (estricto) se avisa
AVISO_POR_DEFECTO = ["claude_sem"]  # la semanal de Claude; con cuentas, claude_sem@<cuenta>
FOTO_VIEJA = 1800  # s: el timer saca una foto cada 10 min
_OWNER = re.compile(r"^(?P<quien>\S+) pid=(?P<pid>\d+) repo=(?P<repo>\S+) (?:\[(?P<etiqueta>[^\]]*)\] )?cmd=(?P<cmd>.*) desde=(?P<desde>\S+)$")
BLOQUE = 1 << 20  # bytes por lectura hacia atrás en fotos_desde
_cupos_mod = None


def ahora() -> float:
    return time.time()


def _cupos():
    global _cupos_mod
    if _cupos_mod is None:
        spec = importlib.util.spec_from_file_location("fabrica_cupos", comun.fabrik_home() / "scripts" / "cupos.py")
        if spec is None or spec.loader is None:
            raise ImportError("sin scripts/cupos.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _cupos_mod = mod
    return _cupos_mod


def _local(valor) -> str | None:
    """Fecha (epoch o ISO, con `Z` o espacio) → ISO local con offset; la cadena tal cual si no se entiende."""
    try:
        if isinstance(valor, (int, float)):
            return dt.datetime.fromtimestamp(valor).astimezone().isoformat(timespec="seconds")
        return dt.datetime.fromisoformat(str(valor).replace("Z", "+00:00")).astimezone().isoformat(timespec="seconds")
    except (ValueError, TypeError, OSError, OverflowError):
        return str(valor) if valor else None


def _vigiladas() -> list[str]:
    valor = (comun.config().get("cupos") or {}).get("aviso")
    if isinstance(valor, str) and valor.strip():
        return [valor.strip()]
    if isinstance(valor, list) and valor:
        return [str(v) for v in valor]
    return AVISO_POR_DEFECTO


def ruta_cupos() -> Path:
    """`FABRIK_CUPOS_LOG` o `$FABRIK_DATA/logs/cupos.jsonl`."""
    return Path(os.environ.get("FABRIK_CUPOS_LOG") or comun.fabrik_data() / "logs" / "cupos.jsonl")


def _foto(linea: bytes) -> dict | None:
    try:
        f = json.loads(linea)
        float(f["t"])
        return f if isinstance(f.get("bolsas"), dict) else None
    except (ValueError, TypeError, KeyError, AttributeError):
        return None


def fotos_desde(ruta: Path, desde: float) -> list[dict]:
    """Fotos con `t >= desde` en orden cronológico, leyendo `ruta` de atrás adelante hasta pasar la ventana.

    El log es cronológico y pesa decenas de MB: se lee por el final en bloques y se salta lo que no es una foto.
    """
    fotos: list[dict] = []
    with open(ruta, "rb") as f:
        pos, resto, fin = f.seek(0, os.SEEK_END), b"", False
        while pos > 0 and not fin:
            paso = min(BLOQUE, pos)
            pos -= paso
            f.seek(pos)
            lineas = (f.read(paso) + resto).split(b"\n")
            resto = lineas.pop(0) if pos > 0 else b""  # la primera línea del bloque puede venir cortada
            for linea in reversed(lineas):
                foto = _foto(linea)
                if foto is None:
                    continue
                if float(foto["t"]) < desde:
                    fin = True
                    break
                fotos.append(foto)
    fotos.reverse()
    return fotos


def cupos() -> dict:
    ruta = ruta_cupos()
    try:
        foto, motivo = _cupos().ultima_foto(ruta, ahora=ahora(), max_edad=float("inf"))
    except Exception as e:  # noqa: BLE001 - sin cupos.py el bloque dice por qué
        return comun.no_disponible(f"no se pudo leer cupos: {e}")
    if foto is None:
        return comun.no_disponible(f"sin foto de cupos: {motivo}")
    bolsas, avisos = [], []
    for nombre, valor in (foto.get("bolsas") or {}).items():
        try:
            usado, renueva = round(float(valor[0]), 1), _local(valor[1])
        except (TypeError, ValueError, IndexError):
            continue
        bolsas.append({"bolsa": nombre, "usado": usado, "renueva": renueva})
    vigiladas = _vigiladas()
    for b in bolsas:
        if any(b["bolsa"] == v or b["bolsa"].startswith(v + "@") for v in vigiladas) and b["usado"] > UMBRAL_AVISO:
            avisos.append(f"Cupo {b['bolsa']} al {b['usado']:.0f} %" + (f" (renueva {b['renueva'][:16].replace('T', ' ')})" if b["renueva"] else ""))
    edad = ahora() - float(foto["t"])
    if edad > FOTO_VIEJA:
        avisos.append(f"La foto de cupos tiene {int(edad // 60)} min: ¿está parado fabrica-cupos.timer?")
    for fuente, error in (foto.get("errores") or {}).items():
        avisos.append(f"Sin datos de {fuente}: {str(error)[:120]}")
    return {"foto": _local(float(foto["t"])), "bolsas": bolsas, "avisos": avisos}


# ---- Máquina ----
def _ram() -> dict:
    try:
        kb = {}
        for linea in (PROC / "meminfo").read_text().splitlines():
            clave, _, resto = linea.partition(":")
            kb[clave] = int(resto.split()[0])
        total, libre = kb["MemTotal"], kb["MemAvailable"]
    except (OSError, KeyError, ValueError, IndexError) as e:
        return comun.no_disponible(f"sin /proc/meminfo: {e}")
    return {"usado_gb": round((total - libre) / 1024**2, 1), "total_gb": round(total / 1024**2, 1)}


def _cpu() -> dict:
    try:
        carga = float((PROC / "loadavg").read_text().split()[0])
    except (OSError, ValueError, IndexError) as e:
        return comun.no_disponible(f"sin /proc/loadavg: {e}")
    return {"carga": carga, "nucleos": os.cpu_count() or 1}


def _ocupado(lock: Path) -> bool:
    """¿Alguien tiene el flock exclusivo de factory-test? (como `factory-test estado`, sin quedarse el turno)."""
    try:
        with open(lock, "rb") as f:
            try:
                fcntl.flock(f, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(f, fcntl.LOCK_UN)
    except OSError:
        pass
    return False


def _procesos_factory_test() -> dict[int, dict]:
    """{pid: {ppid, args, cwd}} de los procesos `factory-test <comando>` vivos (sin `estado`)."""
    procs = {}
    for d in PROC.iterdir():
        if not d.name.isdigit():
            continue
        try:
            argv = [a.decode(errors="replace") for a in (d / "cmdline").read_bytes().split(b"\0") if a]
            i = next((i for i, a in enumerate(argv[:2]) if Path(a).name == "factory-test"), None)
            if i is None or argv[i + 1:i + 2] in ([], ["estado"]):
                continue
            ppid = int((d / "stat").read_text().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            continue
        try:
            cwd = os.readlink(d / "cwd")
        except OSError:
            cwd = ""
        args = argv[i + 1:]
        if args[:1] == ["--etiqueta"]:
            args = args[2:]
        procs[int(d.name)] = {"ppid": ppid, "args": args[1:] if args[:1] == ["--"] else args, "cwd": cwd}
    return procs


def _quien(texto: str) -> dict:
    """Línea `QUIEN` de factory-test → {texto, quien, pid, repo, etiqueta?, cmd, desde} (solo `texto` si no casa)."""
    m = _OWNER.match(texto)
    return {"texto": texto, **({k: v for k, v in m.groupdict().items() if v is not None} if m else {})}


def _repo(cwd: str) -> str:
    """Como factory-test (`git rev-parse --show-toplevel`): el directorio con `.git` más cercano; si no, el cwd."""
    ruta = Path(cwd)
    return next((p.name for p in (ruta, *ruta.parents) if (p / ".git").exists()), ruta.name)


def _suite() -> dict:
    locks = comun.fabrik_data() / "locks"
    try:
        owner = (locks / "factory-test.owner").read_text(errors="replace").strip()
    except OSError:
        owner = ""
    titular = _quien(owner) if owner and _ocupado(locks / "factory-test.lock") else None
    try:
        procs = _procesos_factory_test()
    except OSError:
        procs = {}
    excluir = titular.get("pid") if titular else None
    cola = []
    for pid, p in sorted(procs.items()):
        if str(pid) == excluir or p["ppid"] in procs:  # los subshells de un factory-test no cuentan
            continue
        try:  # prio.d/<pid>: «inicio=…» y la línea QUIEN de quien espera con prioridad
            quien = _quien((locks / "prio.d" / str(pid)).read_text(errors="replace").splitlines()[1].strip())
        except (OSError, IndexError):
            quien = None
        if quien and "repo" in quien:
            cola.append({"pid": pid, "repo": quien["repo"], "cmd": quien["cmd"], "prioridad": True})
        else:
            cola.append({"pid": pid, "repo": _repo(p["cwd"]), "cmd": " ".join(p["args"]), "prioridad": quien is not None})
    cola.sort(key=lambda c: not c["prioridad"])  # quien tiene prioridad coge el turno antes
    return {"titular": titular, "cola": cola}


def maquina() -> dict:
    return {"ram": _ram(), "cpu": _cpu(), "suite": _suite()}


def registrar(router) -> None:
    router.get("/cupos")(cupos)
    router.get("/maquina")(maquina)
