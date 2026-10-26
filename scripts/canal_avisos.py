"""Canal de avisos a prueba de cuota (cuotas-bolsas IMPL-3, D-7 y D-8).

- `comprobar(home)`: ¿el aviso llegaría aunque se agote la bolsa Claude? Mira el perfil `default` (reservas fuera de
  la bolsa del principal) y los cron con modelo fijado (no recorren reservas).
- `avisar_bolsas(...)`: un mensaje por bolsa que cruza el umbral, con los roles que se han conmutado.
- `avisar_comprobacion(...)`: un mensaje al día si `comprobar` marca fallos.

El envío es `hermes send`, que no usa ningún modelo: el avisador no vive en ninguna bolsa. Sin cuentas reales (D-10).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from datetime import date, datetime, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cupos  # noqa: E402

BOLSAS_ANTHROPIC = {"claude_5h", "claude_sem"}
LOCALES = {"local", "origin", ""}


def _res(nivel, que, motivo):
    return {"nivel": nivel, "que": que, "motivo": motivo}


def _comprobar_default(home):
    ruta = Path(home) / ".hermes" / "config.yaml"
    if not ruta.is_file():
        return _res("fallo", "default", "no existe ~/.hermes/config.yaml: no se puede saber qué reservas tiene")
    try:
        cfg = cupos._cargar_yaml(ruta.read_text())
    except (OSError, ValueError) as e:
        return _res("fallo", "default", f"config.yaml ilegible ({e})")
    modelo = cfg.get("model")
    if not isinstance(modelo, dict):
        modelo = {}
    prov, mod = modelo.get("provider"), modelo.get("default") or modelo.get("model")
    fb = cfg.get("fallback_providers")
    reservas = [(f["provider"], f["model"]) for f in (fb if isinstance(fb, list) else [])
                if isinstance(f, dict) and f.get("provider") and f.get("model")]
    if not reservas:
        return _res("fallo", "default",
                    "fallback_providers falta o está vacío: si se agota su bolsa, el perfil no responde")
    propias = set(cupos.bolsas_de(prov, mod))
    if all(set(cupos.bolsas_de(p, m)) & propias for p, m in reservas):
        return _res("fallo", "default", f"las {len(reservas)} reservas comparten bolsa con el principal "
                                        f"({prov}/{mod}): {', '.join(sorted(propias))}")
    return _res("ok", "default", f"{len(reservas)} reservas, alguna fuera de la bolsa del principal")


def _destino_externo(deliver):
    destinos = deliver if isinstance(deliver, list) else str(deliver or "").split(",")
    return any(str(d).split(":")[0].strip() not in LOCALES for d in destinos)


def _comprobar_cron(home):
    ruta = Path(home) / ".hermes" / "cron" / "jobs.json"
    if not ruta.is_file():
        return [_res("ok", "cron", "no hay jobs.json")]
    try:
        jobs = json.loads(ruta.read_text())["jobs"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        return [_res("fallo", "cron", f"jobs.json ilegible ({e.__class__.__name__}): no se puede comprobar")]
    res = []
    for j in jobs if isinstance(jobs, list) else []:
        nombre, modelo = j.get("name") or j.get("id") or "?", j.get("model")
        que = f"cron «{nombre}»"
        compartidas = sorted(BOLSAS_ANTHROPIC & set(cupos.bolsas_de(j.get("provider"), modelo))) if modelo else []
        if j.get("enabled") and compartidas and _destino_externo(j.get("deliver")):
            res.append(_res("fallo", que, f"modelo fijado {modelo} ({', '.join(compartidas)}) y avisa fuera: "
                                          "los jobs fijados no recorren reservas, si la bolsa se agota no avisa"))
        else:
            res.append(_res("ok", que, "sin riesgo"))
    return res or [_res("ok", "cron", "jobs.json sin jobs")]


def comprobar(home):
    """[{"nivel": "ok"|"fallo", "que": str, "motivo": str}] del perfil default y de cada cron."""
    return [_comprobar_default(home), *_comprobar_cron(home)]


# ---------------- avisos ----------------
def _parse(reset):
    try:
        t = datetime.fromisoformat(str(reset).replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def fecha_local(reset):
    t = _parse(reset)
    return t.astimezone().strftime("%d/%m %H:%M") if t else str(reset)


def enviar_hermes(msg):
    """`hermes send -t ${FABRIK_AVISO:-telegram} <msg>`: sin modelo. True si salió bien."""
    try:
        r = subprocess.run(["hermes", "send", "-t", os.environ.get("FABRIK_AVISO") or "telegram", msg],
                           capture_output=True, text=True, timeout=60)
        return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def _leer_estado(path):
    try:
        with open(path) as f:
            datos = json.load(f)
        return datos if isinstance(datos, dict) else {}
    except (OSError, ValueError):
        return {}


def _guardar_estado(path, estado):
    """Escritura atómica (temporal en el mismo directorio + rename)."""
    carpeta = os.path.dirname(path) or "."
    os.makedirs(carpeta, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".modelos-avisos.", suffix=".tmp", dir=carpeta)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(estado, f, ensure_ascii=False, indent=1)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def _avisar_una(estado, estado_path, clave, msg, enviar):
    """Envía `msg` y, solo si salió bien, marca `clave` en el estado. True si se envió."""
    try:
        ok = bool(enviar(msg))
    except Exception:  # noqa: BLE001 - un envío roto nunca para el tick
        ok = False
    if not ok:
        print(f"aviso: no se pudo enviar el aviso «{clave}»; se reintenta en el siguiente tick", file=sys.stderr)
        return False
    estado[clave] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        _guardar_estado(estado_path, estado)
    except OSError as e:
        print(f"aviso: enviado, pero no se pudo guardar {estado_path}: {e}", file=sys.stderr)
    return True


def _roles_de(prefijo, cambios, rutas):
    conmutados, parados, igual = [], [], []
    for rol, c in sorted(cambios.items()):
        antes, despues = c.get("antes"), c.get("despues")
        if antes not in rutas or prefijo not in rutas[antes][4]:
            continue
        if despues is None:
            parados.append(f"{rol} (aparcado)")
        elif despues == antes:
            igual.append(f"{rol} (sigue en {antes})")
        else:
            conmutados.append(f"{rol} {antes} → {despues}")
    return conmutados, parados, igual


def _mensaje_bolsa(bolsa, pct, reset, cambios, rutas):
    conmutados, parados, igual = _roles_de(bolsa.split("@")[0], cambios, rutas)
    partes = [f"Conmutado: {', '.join(conmutados)}." if conmutados else "",
              f"Sin ruta apta: {', '.join(parados)}." if parados else "",
              f"Sin conmutar: {', '.join(igual)}." if igual else ""]
    cola = " ".join(p for p in partes if p) or "Ningún rol la usaba ahora."
    return f"⚠️ Bolsa {bolsa} al {pct:.0f} % (queda {100 - pct:.0f} %), se renueva {fecha_local(reset)}. {cola}"


def avisar_bolsas(bolsas, umbral, cambios, rutas, estado_path, enviar=None):
    """Un aviso por bolsa de la foto con pct ≥ umbral y reset futuro que no esté ya en el estado
    (clave `bolsa|reset[:13]`). `cambios` = {rol: {"antes": ruta|modelo, "despues": ruta|None}}.
    Devuelve las claves enviadas."""
    enviar = enviar or enviar_hermes
    estado, enviadas = _leer_estado(estado_path), []
    ahora = datetime.now(timezone.utc)
    for bolsa, dato in sorted(bolsas.items()):
        try:
            pct, reset = float(dato[0]), dato[1]
        except (TypeError, ValueError, IndexError, KeyError):
            continue
        t, clave = _parse(reset), f"{bolsa}|{str(reset)[:13]}"
        if pct < umbral or t is None or t <= ahora or clave in estado:
            continue
        if _avisar_una(estado, estado_path, clave, _mensaje_bolsa(bolsa, pct, reset, cambios, rutas), enviar):
            enviadas.append(clave)
    return enviadas


def avisar_comprobacion(home, estado_path, enviar=None, hoy=None):
    """Si `comprobar` marca fallos, un aviso al día (clave `comprobar|AAAA-MM-DD`). True si se envió."""
    fallos = [r for r in comprobar(home) if r["nivel"] == "fallo"]
    clave = f"comprobar|{hoy or os.environ.get('FABRIK_HOY') or date.today().isoformat()}"
    estado = _leer_estado(estado_path)
    if not fallos or clave in estado:
        return False
    msg = "⛔ El canal de avisos puede quedarse mudo: " + "; ".join(f"{r['que']}: {r['motivo']}" for r in fallos)
    return _avisar_una(estado, estado_path, clave, msg, enviar or enviar_hermes)
