#!/usr/bin/env python3
"""scripts/cupos.py — Módulo puro para cálculo y consulta de cupos de modelos.

Sin dependencias de Hermes. Testeable de forma aislada.
"""
from __future__ import annotations

import datetime
import importlib.util
import json
import os
import time
from pathlib import Path
from typing import Any, Optional

LOG_DEFAULT = Path.home() / ".hermes/factory/logs/cupos.jsonl"
PROFILES_DIR_DEFAULT = Path.home() / ".hermes/profiles"
MAX_EDAD_DEFAULT = 1800
_REGLAS: Optional[list[dict[str, Any]]] = None  # caché de _reglas_bolsas()


def _strip_quotes(val: str) -> str:
    s = val.strip()
    if (s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'")):
        return s[1:-1]
    return s


def _cargar_yaml(text: str) -> dict[str, Any]:
    """Carga YAML con pyyaml o hermes_yaml si responden; si no, parser puro en Python.

    El parser puro tolera YAML malformado (líneas sueltas, comillas simples…)
    que las librerías rechazan, así que ante cualquier fallo se intenta él.
    """
    for nombre_modulo in ("yaml", "hermes_yaml"):
        try:
            modulo = __import__(nombre_modulo)
        except ImportError:
            continue
        try:
            res = modulo.safe_load(text)
            if isinstance(res, dict):
                return res
        except Exception:
            continue

    # Fallback puro para config.yaml de perfiles
    res_dict: dict[str, Any] = {}
    sec_actual: Optional[str] = None
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].rstrip()
        if not line or not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()
        if indent == 0 and stripped.endswith(":"):
            sec_actual = stripped[:-1].strip()
            if sec_actual in ("fallback_providers", "fallback_model"):
                res_dict[sec_actual] = []
            else:
                res_dict[sec_actual] = {}
            continue
        elif indent == 0 and ":" in stripped:
            k, v = stripped.split(":", 1)
            sec_actual = None
            res_dict[k.strip()] = _strip_quotes(v)
            continue

        if sec_actual == "model":
            if ":" in stripped:
                k, v = stripped.split(":", 1)
                # sec_actual == "model" implica que la sección se abrió como dict
                res_dict["model"][k.strip()] = _strip_quotes(v)
        elif sec_actual in ("fallback_providers", "fallback_model"):
            fb_list = res_dict.setdefault(sec_actual, [])
            if stripped.startswith("- "):
                item: dict[str, Any] = {}
                fb_list.append(item)
                rest = stripped[2:].strip()
                if ":" in rest:
                    k, v = rest.split(":", 1)
                    item[k.strip()] = _strip_quotes(v)
            elif ":" in stripped and fb_list:
                k, v = stripped.split(":", 1)
                fb_list[-1][k.strip()] = _strip_quotes(v)

    return res_dict


def _reglas_bolsas() -> list[dict[str, Any]]:
    """Reglas proveedor/modelo → bolsas: `BOLSAS_DEFECTO` de scripts/fabrik_config.py (sin PyYAML).

    Se carga por ruta, junto a este fichero: cupos.py se importa de formas distintas (paquete, ruta, plugin)."""
    global _REGLAS
    if _REGLAS is None:
        ruta = Path(__file__).resolve().with_name("fabrik_config.py")
        spec = importlib.util.spec_from_file_location("fabrik_config_defectos", ruta)
        assert spec is not None and spec.loader is not None
        modulo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(modulo)
        _REGLAS = modulo.BOLSAS_DEFECTO
    return _REGLAS


def bolsas_de(proveedor: Optional[str], modelo: Optional[str]) -> list[str]:
    """Devuelve la lista de bolsas que consume la pareja (proveedor, modelo).

    Es el único sitio del mapa proveedor/modelo → bolsas; las reglas (BOLSAS_DEFECTO) viven en
    scripts/fabrik_config.py. Se aplica la primera regla que case; cualquier otro → [].
    Una bolsa desconocida nunca bloquea.
    """
    p = str(proveedor or "").strip()
    m = str(modelo or "").strip()
    if not p and not m:
        return []
    if "/" in p and not m:
        parts = p.split("/", 1)
        p, m = parts[0], parts[1]

    for regla in _reglas_bolsas():
        casa = p == regla["proveedor"] if regla["casa"] == "igual" else p.startswith(regla["proveedor"])
        if not casa:
            continue
        if regla["modelos"] is None or any(m.startswith(pref) for pref in regla["modelos"]):
            return list(regla["bolsas"])

    return []


def ultima_foto(
    ruta: Optional[Path | str] = None,
    ahora: Optional[float | datetime.datetime] = None,
    max_edad: Optional[float] = None,
) -> tuple[Optional[dict[str, Any]], Optional[str]]:
    """Lee solo la última línea de cupos.jsonl.

    Devuelve (foto, None) o (None, motivo) si no existe, no es válido o es viejo (> max_edad s).
    """
    if ruta is None:
        ruta = os.environ.get("FABRIK_CUPOS_LOG", str(LOG_DEFAULT))
    if max_edad is None:
        try:
            max_edad = float(os.environ.get("FABRIK_CUPOS_MAX_EDAD", MAX_EDAD_DEFAULT))
        except (ValueError, TypeError):
            max_edad = float(MAX_EDAD_DEFAULT)
    if ahora is None:
        ahora_ts = time.time()
    elif isinstance(ahora, datetime.datetime):
        ahora_ts = ahora.timestamp()
    else:
        ahora_ts = float(ahora)

    p = Path(ruta)
    if not p.is_file():
        return None, f"fichero no existe ({p})"

    try:
        size = p.stat().st_size
        if size == 0:
            return None, "fichero vacío"

        with open(p, "rb") as f:
            f.seek(max(0, size - 8192))
            lines = f.read().splitlines()
            non_empty = [line for line in lines if line.strip()]
            if not non_empty:
                return None, "fichero vacío"
            last_line = non_empty[-1].decode("utf-8", errors="replace")

        data = json.loads(last_line)
    except json.JSONDecodeError:
        return None, "JSON inválido"
    except Exception as exc:
        return None, f"error leyendo foto: {exc}"

    if not isinstance(data, dict):
        return None, "línea no es un objeto JSON"

    if "t" not in data:
        return None, "campo 't' ausente"

    try:
        t_val = float(data["t"])
    except (ValueError, TypeError):
        return None, "campo 't' no es numérico"

    edad = ahora_ts - t_val
    if edad > max_edad:
        return None, f"foto vieja ({int(edad)}s > {int(max_edad)}s)"

    return data, None


def cadena_de(
    perfil_config_yaml: Any,
    model_override: Optional[str] = None,
    provider_override: Optional[str] = None,
) -> list[tuple[str, str]]:
    """Devuelve [(proveedor, modelo), …] = principal seguida de fallback_providers.

    Se lee el config.yaml del perfil (~/.hermes/profiles/<assignee>/config.yaml,
    raíz sobrescribible con FABRIK_PROFILES_DIR).
    Si la tarjeta trae model_override/provider_override, la principal es el override
    y las reservas siguen siendo las del perfil.
    """
    cfg: dict[str, Any] = {}
    if isinstance(perfil_config_yaml, dict):
        cfg = perfil_config_yaml
    elif isinstance(perfil_config_yaml, (str, Path)):
        s = str(perfil_config_yaml)
        p = Path(s)
        if p.is_file() or "/" in s or s.endswith(".yaml"):
            try:
                cfg = _cargar_yaml(p.read_text())
            except Exception:
                cfg = {}
        else:
            # Tratar como nombre de perfil (assignee)
            root = Path(os.environ.get("FABRIK_PROFILES_DIR", str(PROFILES_DIR_DEFAULT)))
            conf_file = root / s / "config.yaml"
            try:
                if conf_file.is_file():
                    cfg = _cargar_yaml(conf_file.read_text())
            except Exception:
                cfg = {}

    model_section = cfg.get("model", {})
    if isinstance(model_section, dict):
        p_def = model_section.get("provider") or cfg.get("provider")
        m_def = model_section.get("default") or model_section.get("model")
    else:
        p_def = cfg.get("provider")
        m_def = str(model_section) if model_section else None

    if model_override:
        m_def = model_override
    if provider_override:
        p_def = provider_override

    cadena: list[tuple[str, str]] = []
    if p_def and m_def:
        cadena.append((str(p_def), str(m_def)))

    fallbacks = cfg.get("fallback_providers")
    if not fallbacks:
        fallbacks = cfg.get("fallback_model")
    if isinstance(fallbacks, dict):
        fallbacks = [fallbacks]
    if isinstance(fallbacks, list):
        for fb in fallbacks:
            if isinstance(fb, dict):
                fp = fb.get("provider")
                fm = fb.get("model")
                if fp and fm:
                    cadena.append((str(fp), str(fm)))

    return cadena


def _parse_iso(s: str) -> Optional[float]:
    try:
        dt = datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
        return dt.timestamp()
    except Exception:
        return None


def estado_cadena(
    cadena: list[tuple[str, str]],
    foto: Any,
    ahora: float | datetime.datetime,
    umbral: float = 98,
) -> tuple[bool, Optional[str], Optional[str], list[str]]:
    """Determina si la cadena es lanzable según la foto de cupos.

    Devuelve (lanzable, bolsa_que_antes_renueva, renueva_iso, bolsas_agotadas).

    - Un modelo está agotado si alguna de sus bolsas cumple pct >= umbral y además reset > ahora.
    - Una bolsa cuyo reset ya pasó cuenta como renovada aunque la foto diga 100 %.
    - Una bolsa que no sale en la foto no bloquea.
    - La cadena no es lanzable solo si todos sus modelos están agotados y cada uno tiene alguna bolsa conocida.
    - La hora en que se libera un modelo es el máximo de los resets de sus bolsas agotadas;
      la de la cadena, el mínimo de esas horas entre sus modelos.
    """
    if isinstance(ahora, datetime.datetime):
        ahora_ts = ahora.timestamp()
    else:
        ahora_ts = float(ahora)

    bolsas_dict: dict[str, Any] = {}
    if isinstance(foto, dict):
        bolsas_dict = foto.get("bolsas", foto)

    if not cadena:
        return True, None, None, []

    cadena_agotada = True
    modelos_liberacion: list[tuple[float, str, str]] = []
    todas_bolsas_agotadas: list[str] = []

    for prov, mod in cadena:
        bags = bolsas_de(prov, mod)
        if not bags:
            # Modelo sin bolsas conocidas nunca bloquea
            cadena_agotada = False
            continue

        bolsas_agotadas_modelo: list[tuple[str, float, str]] = []
        max_reset_ts = -1.0
        max_reset_iso = ""
        max_reset_bolsa = ""

        for b in bags:
            if b not in bolsas_dict:
                continue
            val = bolsas_dict[b]
            if not isinstance(val, (list, tuple)) or len(val) < 2:
                continue
            pct, reset_raw = val[0], val[1]
            try:
                pct_f = float(pct)
            except (ValueError, TypeError):
                continue

            reset_ts = _parse_iso(str(reset_raw))
            if reset_ts is None:
                continue

            # Agotada solo si pct >= umbral y reset > ahora
            if pct_f >= umbral and reset_ts > ahora_ts:
                bolsas_agotadas_modelo.append((b, reset_ts, str(reset_raw)))
                if b not in todas_bolsas_agotadas:
                    todas_bolsas_agotadas.append(b)
                if reset_ts > max_reset_ts:
                    max_reset_ts = reset_ts
                    max_reset_iso = str(reset_raw)
                    max_reset_bolsa = b

        if not bolsas_agotadas_modelo:
            # Este modelo tiene al menos una bolsa renovada / con margen
            cadena_agotada = False
        else:
            modelos_liberacion.append((max_reset_ts, max_reset_bolsa, max_reset_iso))

    if not cadena_agotada or not modelos_liberacion:
        return True, None, None, []

    # La hora en que se libera la cadena es el mínimo de esas horas entre sus modelos
    modelos_liberacion.sort(key=lambda x: x[0])
    _, mejor_bolsa, mejor_iso = modelos_liberacion[0]
    return False, mejor_bolsa, mejor_iso, todas_bolsas_agotadas
