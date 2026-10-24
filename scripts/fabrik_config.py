#!/usr/bin/env python3
"""Cargador de la configuración de la fábrica: 3 capas (motor < packs < personal).

- Motor: valores por defecto de este script (modelos por rol, idioma, dir_codigo).
- Packs: packs/<nombre>/pack.yaml de los packs activos.
- Personal: ~/.config/fabrica/fabrik.yaml (o lo que apunte FABRIK_CONFIG).

Fusión: las listas se concatenan sin duplicados y los valores sueltos los
sobrescribe la capa superior (los diccionarios se fusionan de forma recursiva).

Packs activos: la clave `packs` de la config personal (rutas a directorios con
pack.yaml o directamente a pack.yaml); si no existe, todos los packs/* del repo
excepto `ejemplo`; si no hay ninguno, `ejemplo`.

Uso: uv run --with pyyaml python fabrik_config.py <ver|get <clave.punteada>|campos <clave> <campo...>|requisitos>
- get: valor (escalar en crudo, lista una línea por elemento, dict en JSON).
- campos: para una lista de objetos, imprime los campos pedidos unidos por '|' (una línea por objeto).
- requisitos: qué exige cada proveedor de `modelos`, del pool efectivo y de la reserva final
  (api_key <CLAVE> o plugin <proveedor>).
- validar: comprueba el esquema de `modelos.pool`, `reserva_final` y `permitir_pago`; un error por línea (stderr)
  con su ruta. `cargar()` no valida.
Exit codes: 0 ok · 1 clave no encontrada · 2 YAML inválido (indica el fichero) · 3 config inválida (validar).

Dentro de `modelos` las claves `pool`, `reserva_final` y `permitir_pago` no son roles (`roles(config)`).
Las listas de cada nivel de `pool`, `reserva` y `reserva_final` se reemplazan con la capa superior
(no se concatenan); `reserva_final: null` en una capa superior la anula.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
EJEMPLO = "ejemplo"

# Capa motor: valores por defecto. Sin datos personales.
MOTOR = {
    "idioma": "es",
    "dir_codigo": "~/Code",
    # Proveedores que exigen clave de API (nombre de la env var). Los de suscripción
    # u OAuth no llevan clave: solo requieren su plugin habilitado en Hermes.
    "proveedores": {
        "anthropic": {"clave_api": "ANTHROPIC_API_KEY"},
        "deepseek": {"clave_api": "DEEPSEEK_API_KEY"},
        "kimi-coding": {"clave_api": "KIMI_API_KEY"},
    },
    # Modelos genéricos (D-P4): un solo proveedor, sin reserva, sin pool y sin reserva final. Los modelos
    # son personales: cada usuario pone sus roles, `pool` y `reserva_final` en su fabrik.yaml (`install.sh`
    # los propone según los proveedores detectados). El pack solo puede fijar `permitir_pago`.
    "modelos": {
        "orquestador": {"proveedor": "anthropic", "modelo": "claude-opus-5-5", "compacta": 200_000},
        "explorador": {"proveedor": "anthropic", "modelo": "claude-sonnet-5-5", "compacta": 300_000},
        "programador": {"proveedor": "anthropic", "modelo": "claude-sonnet-5-5", "compacta": 160_000},
        "tester": {"proveedor": "anthropic", "modelo": "claude-sonnet-5-5", "compacta": 160_000},
        "revisor": {"proveedor": "anthropic", "modelo": "claude-opus-5-5", "compacta": 200_000},
        "seguridad": {"proveedor": "anthropic", "modelo": "claude-opus-5-5", "compacta": 200_000},
        "docs": {"proveedor": "anthropic", "modelo": "claude-sonnet-5-5", "compacta": 300_000},
        # Claves reservadas (no son roles).
        "permitir_pago": False,
        "reserva_final": None,
    },
}

# Dentro de `modelos`, estas claves no son roles. Usa siempre `roles(config)` para recorrerlos.
CLAVES_RESERVADAS = ("pool", "reserva_final", "permitir_pago")
NIVELES_POOL = ("ligero", "medio", "dificil", "critico")  # orden canónico
COSTES_POOL = ("suscripcion", "pago")

class YamlInvalido(Exception):
    """YAML inválido; el mensaje lleva el fichero afectado."""


def cargar_yaml(fichero):
    if not fichero.is_file():
        return {}
    try:
        datos = yaml.safe_load(fichero.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        raise YamlInvalido(f"YAML inválido en {fichero}: {e}") from e
    return datos or {}


def resolver_ruta(entrada, config_personal):
    """Ruta de pack: absoluta, relativa al fabrik.yaml, en FABRIK_DATA/packs o relativa al repo."""
    p = Path(os.path.expandvars(os.path.expanduser(str(entrada))))
    if p.is_absolute():
        return p
    # `install.sh --comprobar` trabaja sobre una copia temporal de la config (solo lectura):
    # FABRIK_CONFIG_ORIGEN indica la config real para resolver las rutas relativas.
    origen = Path(os.environ.get("FABRIK_CONFIG_ORIGEN") or config_personal)
    relativa_config = origen.parent / p
    if relativa_config.exists():
        return relativa_config
    data_packs = Path(os.environ.get("FABRIK_DATA", Path.home() / ".hermes/factory")) / "packs" / p
    if data_packs.exists():
        return data_packs
    en_repo_packs = REPO / "packs" / p
    if en_repo_packs.exists():
        return en_repo_packs
    return REPO / p


def pack_yaml_de(ruta):
    """Acepta un directorio (busca pack.yaml dentro) o un pack.yaml directo."""
    return ruta / "pack.yaml" if ruta.is_dir() else ruta


def packs_activos(personal, config_personal):
    packs_dir = REPO / "packs"
    candidatos = []
    if isinstance(personal.get("packs"), list):
        for entrada in personal["packs"]:
            yaml_pack = pack_yaml_de(resolver_ruta(entrada, config_personal))
            if yaml_pack.is_file():
                candidatos.append(yaml_pack)
            else:
                print(f"aviso: pack no encontrado, se omite: {entrada}", file=sys.stderr)
    elif packs_dir.is_dir():
        # Sin clave `packs` en la config personal: todos los packs del repo
        # excepto `ejemplo`.
        candidatos = sorted(p / "pack.yaml" for p in packs_dir.iterdir()
                            if p.is_dir() and p.name != EJEMPLO
                            and (p / "pack.yaml").is_file())
    if not candidatos:
        # Último recurso: el pack de ejemplo.
        ejemplo = packs_dir / EJEMPLO / "pack.yaml"
        if ejemplo.is_file():
            candidatos = [ejemplo]
    return candidatos


def _clave_dedupe(item):
    return json.dumps(item, sort_keys=True, ensure_ascii=False) if isinstance(item, dict) else item


def fusionar(base, encima):
    """Listas concatenadas sin duplicados; dicts recursivos; escalares sobrescritos."""
    if isinstance(base, dict) and isinstance(encima, dict):
        resultado = dict(base)
        # Si se redefine el proveedor de un rol en modelos, no heredar la reserva del proveedor anterior
        if "proveedor" in encima and "proveedor" in base and encima["proveedor"] != base["proveedor"]:
            resultado.pop("reserva", None)
        for clave, valor in encima.items():
            if clave in ("reserva", "reserva_final"):
                # Se reemplazan enteras con la capa superior (`null` incluido: la anula).
                resultado[clave] = valor
            elif clave == "pool" and isinstance(base.get(clave), dict) and isinstance(valor, dict):
                # Cada nivel del pool reemplaza al de la capa inferior (sin concatenar);
                # los niveles que la capa superior no menciona se heredan.
                resultado[clave] = {**base[clave], **valor}
            else:
                resultado[clave] = fusionar(base[clave], valor) if clave in base else valor
        return resultado
    if isinstance(base, list) and isinstance(encima, list):
        resultado = list(base)
        vistos = {_clave_dedupe(i) for i in resultado}
        for item in encima:
            clave = _clave_dedupe(item)
            if clave not in vistos:
                vistos.add(clave)
                resultado.append(item)
        return resultado
    return encima


def config_personal_path():
    if os.environ.get("FABRIK_CONFIG"):
        return Path(os.path.expandvars(os.path.expanduser(os.environ["FABRIK_CONFIG"])))
    return Path.home() / ".config" / "fabrica" / "fabrik.yaml"


def cargar():
    personal_path = config_personal_path()
    personal = cargar_yaml(personal_path)
    yaml_packs = packs_activos(personal, personal_path)
    # `packs` es metadato del cargador (qué packs activar), no configuración
    # fusionada: no se propaga a la salida para no filtrar rutas locales.
    personal.pop("packs", None)
    config = MOTOR
    for yaml_pack in yaml_packs:
        config = fusionar(config, cargar_yaml(yaml_pack))
    return fusionar(config, personal)


def buscar(config, clave):
    actual = config
    for trozo in clave.split("."):
        if isinstance(actual, list):
            if not trozo.isdigit() or int(trozo) >= len(actual):
                raise KeyError(clave)
            actual = actual[int(trozo)]
        elif isinstance(actual, dict) and trozo in actual:
            actual = actual[trozo]
        else:
            raise KeyError(clave)
    return actual


def imprimir_valor(valor):
    if isinstance(valor, dict):
        print(json.dumps(valor, ensure_ascii=False))
    elif isinstance(valor, list):
        for item in valor:
            print(json.dumps(item, ensure_ascii=False) if isinstance(item, dict) else item)
    else:
        print(valor)


def imprimir_campos(config, clave, nombres):
    valor = buscar(config, clave)
    if not isinstance(valor, list):
        print(f"clave no es una lista: {clave}", file=sys.stderr)
        return 1
    for item in valor:
        if isinstance(item, dict):
            print("|".join(str(item.get(nombre, "")) for nombre in nombres))
        else:
            print(item)
    return 0


def normalizar_reserva(reserva, prov_defecto=None):
    """Normaliza reserva (dict, lista de dicts o null/[]) a lista de dicts [{'proveedor': ..., 'modelo': ...}]."""
    if not reserva:
        return []
    items = [reserva] if isinstance(reserva, dict) else (reserva if isinstance(reserva, list) else [])
    resultado = []
    for item in items:
        if isinstance(item, dict):
            p = item.get("proveedor") or prov_defecto
            m = item.get("modelo")
            resultado.append({"proveedor": p, "modelo": m})
    return resultado


def _modelos(config):
    modelos = (config or {}).get("modelos")
    return modelos if isinstance(modelos, dict) else {}


def roles(config):
    """{rol: datos} de `modelos`, sin las claves reservadas (pool, reserva_final, permitir_pago).

    Único punto por el que los consumidores recorren los roles.
    """
    return {rol: datos for rol, datos in _modelos(config).items()
            if rol not in CLAVES_RESERVADAS and isinstance(datos, dict)}


def pool_efectivo(config):
    """(pool, excluidos): pool = {nivel: [entradas]} en orden canónico, sin niveles vacíos y sin
    las entradas `coste: pago` salvo con `permitir_pago: true`; excluidos = las de pago omitidas."""
    modelos = _modelos(config)
    pool_cfg = modelos.get("pool")
    if not isinstance(pool_cfg, dict):
        pool_cfg = {}
    permitir_pago = modelos.get("permitir_pago") is True
    pool, excluidos = {}, []
    for nivel in NIVELES_POOL:
        entradas = pool_cfg.get(nivel)
        if not isinstance(entradas, list):
            continue
        validas = []
        for entrada in entradas:
            if not isinstance(entrada, dict):
                continue
            if entrada.get("coste") == "pago" and not permitir_pago:
                excluidos.append(entrada)
            else:
                validas.append(entrada)
        if validas:
            pool[nivel] = validas
    return pool, excluidos


def reserva_final(config):
    """{'proveedor', 'modelo'} de la reserva final, o None si no hay."""
    rf = _modelos(config).get("reserva_final")
    return rf if isinstance(rf, dict) and rf else None


def _no_vacio(valor):
    return isinstance(valor, str) and bool(valor.strip())


def validar(config):
    """Errores de esquema de `modelos.pool`, `modelos.reserva_final` y `modelos.permitir_pago`,
    uno por elemento de la lista, cada uno con su ruta. [] si todo está bien."""
    errores = []
    modelos = (config or {}).get("modelos")
    if modelos is None:
        return errores
    if not isinstance(modelos, dict):
        return ["modelos: debe ser un mapa de roles"]
    if "permitir_pago" in modelos and not isinstance(modelos["permitir_pago"], bool):
        errores.append("modelos.permitir_pago: debe ser true o false")
    rf = modelos.get("reserva_final")
    if rf is not None:
        if not isinstance(rf, dict):
            errores.append("modelos.reserva_final: debe ser {proveedor, modelo} o null")
        else:
            for campo in ("proveedor", "modelo"):
                if not _no_vacio(rf.get(campo)):
                    errores.append(f"modelos.reserva_final.{campo}: obligatorio, texto no vacío")
    pool = modelos.get("pool")
    if pool is None:
        return errores
    if not isinstance(pool, dict):
        errores.append("modelos.pool: debe ser un mapa nivel → lista de modelos")
        return errores
    for nivel, entradas in pool.items():
        ruta = f"modelos.pool.{nivel}"
        if nivel not in NIVELES_POOL:
            errores.append(f"{ruta}: nivel desconocido (válidos: {', '.join(NIVELES_POOL)})")
            continue
        if entradas is None:
            continue
        if not isinstance(entradas, list):
            errores.append(f"{ruta}: debe ser una lista de modelos")
            continue
        for i, entrada in enumerate(entradas):
            ruta_e = f"{ruta}[{i}]"
            if not isinstance(entrada, dict):
                errores.append(f"{ruta_e}: debe ser {{proveedor, modelo, herramientas, coste}}")
                continue
            for campo in ("proveedor", "modelo"):
                if not _no_vacio(entrada.get(campo)):
                    errores.append(f"{ruta_e}.{campo}: obligatorio, texto no vacío")
            if not isinstance(entrada.get("herramientas"), bool):
                errores.append(f"{ruta_e}.herramientas: obligatorio, true o false")
            if entrada.get("coste") not in COSTES_POOL:
                errores.append(f"{ruta_e}.coste: obligatorio, uno de {' | '.join(COSTES_POOL)}")
    return errores


def imprimir_requisitos(config):
    """Qué exige cada proveedor distinto de `modelos` (api_key <CLAVE> o plugin <prov>):
    los de los roles y sus reservas, los del pool efectivo y el de la reserva final."""
    proveedores = set()
    for m in roles(config).values():
        if m.get("proveedor"):
            proveedores.add(m["proveedor"])
        for r in normalizar_reserva(m.get("reserva"), m.get("proveedor")):
            if r.get("proveedor"):
                proveedores.add(r["proveedor"])
    for entradas in pool_efectivo(config)[0].values():
        proveedores.update(e["proveedor"] for e in entradas if e.get("proveedor"))
    rf = reserva_final(config)
    if rf and rf.get("proveedor"):
        proveedores.add(rf["proveedor"])
    mapa = config.get("proveedores") or {}
    for p in sorted(proveedores):
        clave = (mapa.get(p) or {}).get("clave_api") if isinstance(mapa, dict) else None
        print(f"api_key {clave}" if clave else f"plugin {p}")


CLAUDE_PLUGIN = "claude-subscription-directsdk-experimental"
# Proveedores cuyo modelo sabemos proponer; las claves de API que los activan.
CLAVES_PROVEEDOR = {"anthropic": "ANTHROPIC_API_KEY", "deepseek": "DEEPSEEK_API_KEY", "kimi-coding": "KIMI_API_KEY"}
PROVEEDORES_CONOCIDOS = (CLAUDE_PLUGIN, "antigravity-oauth", "anthropic", "deepseek", "kimi-coding")


def _cand(proveedor, modelo, herramientas=True, coste="suscripcion"):
    return {"proveedor": proveedor, "modelo": modelo, "herramientas": herramientas, "coste": coste}


# Candidatos genéricos del pool por nivel (más barato primero). `install.sh` propone solo los de
# proveedores detectados en la máquina y, salvo `permitir_pago: true`, ninguno con `coste: pago`.
CANDIDATOS_POOL = {
    "ligero": [_cand("antigravity-oauth", "gemini-3.8-flash-low", False),
               _cand("antigravity-oauth", "gemini-3.8-flash-medium", False)],
    "medio": [_cand("antigravity-oauth", "gemini-3.8-flash-high"),
              _cand("kimi-coding", "kimi-for-coding"),
              _cand("deepseek", "deepseek-flash", coste="pago")],
    "dificil": [_cand(CLAUDE_PLUGIN, "claude-sonnet-5-5"),
                _cand("anthropic", "claude-sonnet-5-5"),
                _cand("deepseek", "deepseek-v4-pro", coste="pago")],
    "critico": [_cand(CLAUDE_PLUGIN, "claude-opus-5-5"),
                _cand("anthropic", "claude-opus-5-5")],
}
# La reserva final sale de estos niveles, por este orden (primer candidato disponible).
NIVELES_RESERVA_FINAL = ("dificil", "medio")
PROVEEDORES_DE_PAGO = frozenset(e["proveedor"] for nivel in CANDIDATOS_POOL.values()
                                for e in nivel if e["coste"] == "pago")
# rol: (compacta, candidatos por orden de preferencia [(proveedor, modelo)], proveedores que dan modelo "bueno")
_TOP = [(CLAUDE_PLUGIN, "claude-opus-5-5"), ("anthropic", "claude-opus-5-5"),
        ("deepseek", "deepseek-v4-pro"), ("kimi-coding", "kimi-for-coding")]
_RAPIDO = [("antigravity-oauth", "gemini-3.8-flash-medium"), ("deepseek", "deepseek-flash"),
           (CLAUDE_PLUGIN, "claude-sonnet-5-5"), ("anthropic", "claude-sonnet-5-5"),
           ("kimi-coding", "kimi-for-coding")]
PREFERENCIAS_ROL = {
    "orquestador": (200_000, _TOP, {CLAUDE_PLUGIN, "anthropic"}),
    "explorador": (300_000, _RAPIDO, {"antigravity-oauth", "deepseek", CLAUDE_PLUGIN, "anthropic"}),
    "programador": (160_000, [("kimi-coding", "kimi-for-coding"), (CLAUDE_PLUGIN, "claude-sonnet-5-5"),
                              ("anthropic", "claude-sonnet-5-5"), ("deepseek", "deepseek-v4-pro")],
                    {"kimi-coding", CLAUDE_PLUGIN, "anthropic", "deepseek"}),
    "tester": (160_000, [("deepseek", "deepseek-v4-pro"), (CLAUDE_PLUGIN, "claude-sonnet-5-5"),
                         ("anthropic", "claude-sonnet-5-5"), ("kimi-coding", "kimi-for-coding")],
               {"deepseek", CLAUDE_PLUGIN, "anthropic", "kimi-coding"}),
    "revisor": (200_000, _TOP, {CLAUDE_PLUGIN, "anthropic"}),
    "seguridad": (200_000, _TOP, {CLAUDE_PLUGIN, "anthropic"}),
    "docs": (300_000, _RAPIDO, {"antigravity-oauth", "deepseek", CLAUDE_PLUGIN, "anthropic"}),
}

def _salida(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""


def detectar_proveedores_maquina():
    detectados = set()
    env_vars = dict(os.environ)
    env_file = Path.home() / ".hermes" / ".env"
    if env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                if v.strip():
                    env_vars[k.strip()] = v.strip()

    for prov, clave in CLAVES_PROVEEDOR.items():
        if env_vars.get(clave):
            detectados.add(prov)

    plugins_activos = _salida("hermes", "plugins", "list", "--plain")
    for linea in plugins_activos.splitlines():
        campos = linea.split()
        if len(campos) >= 2 and campos[0] == "enabled" and campos[-1] in PROVEEDORES_CONOCIDOS:
            detectados.add(campos[-1])

    for prov in PROVEEDORES_CONOCIDOS:
        if prov in detectados:
            continue
        estado = _salida("hermes", "auth", "status", prov).lower()
        if "logged in" in estado and "logged out" not in estado and "not logged in" not in estado:
            detectados.add(prov)
    return detectados


def proponer_modelos(detectados=None, permitir_pago=False):
    """Bloque `modelos` propuesto para el fabrik.yaml personal: roles (con `reserva` explícita, lista),
    `pool` y `reserva_final`, solo con proveedores detectados. Sin `permitir_pago` nunca propone
    proveedores de pago. Devuelve (modelos, avisos); los niveles sin candidatos se avisan y se omiten."""
    if detectados is None:
        detectados = detectar_proveedores_maquina()

    def sirve(proveedor):
        return proveedor in detectados and (permitir_pago or proveedor not in PROVEEDORES_DE_PAGO)

    modelos = {}
    avisos = []
    for rol, (compacta, candidatos, buenos) in PREFERENCIAS_ROL.items():
        disponibles = [(p, m) for p, m in candidatos if sirve(p)]
        if not disponibles:
            avisos.append(f"rol {rol}: sin modelo (ningún proveedor detectado sirve); asígnalo a mano en 'modelos:'")
            continue
        proveedor, modelo = disponibles[0]
        reserva = next(((p, m) for p, m in disponibles[1:] if p != proveedor), None)
        # `reserva` va siempre explícita (lista, vacía si no hay): si no, la fusión con los valores por
        # defecto heredaría la de otro proveedor que esta máquina no tiene.
        modelos[rol] = {"proveedor": proveedor, "modelo": modelo,
                        "reserva": [{"proveedor": reserva[0], "modelo": reserva[1]}] if reserva else [],
                        "compacta": compacta}
        if proveedor not in buenos:
            avisos.append(f"rol {rol}: sin modelo bueno; propuesto {proveedor}/{modelo} (mejora esperada con "
                          f"{' o '.join(sorted(buenos))})")

    pool = {}
    for nivel in NIVELES_POOL:
        entradas = [dict(e) for e in CANDIDATOS_POOL[nivel] if sirve(e["proveedor"])]
        if entradas:
            pool[nivel] = entradas
        else:
            avisos.append(f"nivel {nivel} del pool: vacío (ningún proveedor detectado sirve); "
                          f"añade modelos en 'modelos.pool.{nivel}'")
    if pool:
        modelos["pool"] = pool
    final = next((e for nivel in NIVELES_RESERVA_FINAL for e in CANDIDATOS_POOL[nivel] if sirve(e["proveedor"])), None)
    if final:
        modelos["reserva_final"] = {"proveedor": final["proveedor"], "modelo": final["modelo"]}
    else:
        avisos.append("sin reserva_final (ningún proveedor detectado sirve); defínela en 'modelos.reserva_final'")
    return modelos, avisos


def permitir_pago_efectivo(pack_path=None, cfg_path=None):
    """`modelos.permitir_pago` de la capa efectiva sin las propuestas: motor + packs que regirán
    (el `pack_path` dado o, sin él, los packs activos) + la config personal si existe."""
    cfg_path = Path(cfg_path) if cfg_path else config_personal_path()
    personal = cargar_yaml(cfg_path) if cfg_path.is_file() else {}
    config = MOTOR
    if pack_path:
        capas = [pack_yaml_de(Path(os.path.expanduser(str(pack_path))))]
    else:
        capas = packs_activos(personal, cfg_path)
    for capa in capas:
        if capa.is_file():
            config = fusionar(config, cargar_yaml(capa))
    return _modelos(fusionar(config, personal)).get("permitir_pago") is True


def modelos_previos(cfg_path, pack_path=None):
    """Máquina ya configurada: sin config personal, con perfiles de Hermes de la fábrica y con un pack
    que trae modelos de referencia (`tests/fixtures/modelos-*.yaml`). Devuelve esos ficheros, o []
    si no aplica. En ese caso el primer arranque no debe proponer modelos nuevos: reescribirían los
    que ya rigen los perfiles."""
    cfg_path = Path(cfg_path)
    perfiles = Path.home() / ".hermes" / "profiles"
    if cfg_path.exists() or not any((perfiles / rol).is_dir() for rol in PREFERENCIAS_ROL):
        return []
    if pack_path:
        carpetas = [pack_yaml_de(Path(os.path.expanduser(str(pack_path)))).parent]
    else:
        carpetas = [y.parent for y in packs_activos({}, cfg_path) if y.parent.name != EJEMPLO]
    return [f for c in carpetas for f in sorted((c / "tests" / "fixtures").glob("modelos-*.yaml"))]


def anadir_pack(cfg_path, pack_path):
    p = Path(cfg_path)
    if not p.is_file():
        return
    data = cargar_yaml(p)
    packs = data.get("packs")
    if not isinstance(packs, list):
        packs = []
    pack_str = str(pack_path)
    p_norm = Path(os.path.expanduser(pack_str)).resolve() if Path(os.path.expanduser(pack_str)).exists() else None
    for exist in packs:
        if str(exist) == pack_str:
            return
        e_norm = Path(os.path.expanduser(str(exist))).resolve() if Path(os.path.expanduser(str(exist))).exists() else None
        if p_norm and e_norm and p_norm == e_norm:
            return
    packs.append(pack_str)
    data["packs"] = packs
    p.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False, width=120), encoding="utf-8")


def init_personal(path_str, usuario_github, pack_path=None):
    cfg_path = Path(path_str)
    if cfg_path.exists():
        if pack_path:
            anadir_pack(cfg_path, pack_path)
        return 0
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    ejemplo_path = REPO / "config" / "fabrik.yaml.ejemplo"
    base = cargar_yaml(ejemplo_path) if ejemplo_path.is_file() else {}
    usuario = usuario_github or os.environ.get("USER", "usuario")
    base["usuario_github"] = usuario
    base["owners"] = [usuario]
    base.setdefault("tablero_por_defecto", "personal")
    base.setdefault("tableros", [{"slug": "personal", "nombre": "Personal",
                                  "descripcion": "Repositorios personales", "icono": "\U0001F9D1\u200D\U0001F4BB"}])
    # Sin pack no se escribe la clave `packs`: así rige la regla del cargador (todos los packs
    # del repo salvo `ejemplo`; `ejemplo` solo si no hay ninguno) y no se pisa un pack ya presente.
    if pack_path:
        base["packs"] = [str(pack_path)]
    else:
        base.pop("packs", None)
    modelos, avisos = proponer_modelos(permitir_pago=permitir_pago_efectivo(pack_path, cfg_path))
    base["modelos"] = modelos
    cfg_path.write_text(yaml.safe_dump(base, allow_unicode=True, sort_keys=False, width=120), encoding="utf-8")
    for a in avisos:
        print(f"aviso: {a}", file=sys.stderr)
    return 0


def mostrar_modelos():
    personal_path = config_personal_path()
    personal = cargar_yaml(personal_path)
    modelos_personal = personal.get("modelos")
    config = cargar()
    modelos = roles(config)
    if modelos_personal:
        print("  Modelos por rol (propuesta según tus proveedores; confirma o edita 'modelos:' en ~/.config/fabrica/fabrik.yaml):")
    else:
        print("  ! Sin modelos personales en ~/.config/fabrica/fabrik.yaml (usando valores por defecto):")
    for rol, datos in modelos.items():
        if isinstance(datos, dict):
            prov = datos.get("proveedor", "-")
            mod = datos.get("modelo", "-")
            reservas = normalizar_reserva(datos.get("reserva"), prov)
            if reservas:
                cadenas = [f"{r['proveedor']}/{r['modelo']}" for r in reservas if r.get("proveedor") and r.get("modelo")]
                res_str = f" (reserva: {' → '.join(cadenas)})" if cadenas else ""
            else:
                res_str = ""
            print(f"    {rol:<14}: {prov} / {mod}{res_str}")
    if not modelos_personal:
        print("  (Para personalizar tus modelos: define 'modelos:' en ~/.config/fabrica/fabrik.yaml)")
    else:
        for rol in PREFERENCIAS_ROL:
            if rol not in modelos_personal:
                print(f"  ! rol {rol}: sin modelo propio; usa el valor por defecto (puede exigir un proveedor que no tienes)")


def uso():
    print("Uso: fabrik config <ver|get <clave.punteada>|campos <clave> <campo...>|requisitos|validar>", file=sys.stderr)


def main(argv):
    if not argv or argv[0] in ("ayuda", "-h", "--help"):
        uso()
        return 2 if not argv else 0
    comando = argv[0]
    if comando == "init-personal" and len(argv) >= 3:
        pack = argv[3] if len(argv) >= 4 else None
        return init_personal(argv[1], argv[2], pack)
    if comando == "anadir-pack" and len(argv) == 3:
        anadir_pack(argv[1], argv[2])
        return 0
    if comando == "mostrar-modelos" and len(argv) == 1:
        mostrar_modelos()
        return 0
    if comando == "modelos-previos" and len(argv) in (2, 3):
        previos = modelos_previos(argv[1], argv[2] if len(argv) == 3 else None)
        for f in previos:
            print(f)
        return 0 if previos else 1
    if comando == "tiene-pack" and len(argv) <= 2:
        p_path = Path(argv[1]) if len(argv) == 2 else config_personal_path()
        # Packs efectivos sin contar `ejemplo`: solo avisa cuando de verdad se va a usar `ejemplo`.
        efectivos = [y for y in packs_activos(cargar_yaml(p_path), p_path) if y.parent.name != EJEMPLO]
        return 0 if efectivos else 1
    try:
        config = cargar()
    except YamlInvalido as e:
        print(e, file=sys.stderr)
        return 2
    if comando == "ver":
        print(yaml.dump(config, sort_keys=False, allow_unicode=True), end="")
        return 0
    if comando == "get" and len(argv) == 2:
        try:
            imprimir_valor(buscar(config, argv[1]))
        except KeyError:
            print(f"clave no encontrada: {argv[1]}", file=sys.stderr)
            return 1
        return 0
    if comando == "campos" and len(argv) >= 3:
        try:
            return imprimir_campos(config, argv[1], argv[2:])
        except KeyError:
            print(f"clave no encontrada: {argv[1]}", file=sys.stderr)
            return 1
    if comando == "requisitos" and len(argv) == 1:
        imprimir_requisitos(config)
        return 0
    if comando == "pack-dir" and len(argv) == 2:
        return imprimir_pack_dir(argv[1])
    if comando == "validar" and len(argv) == 1:
        errores = validar(config)
        for e in errores:
            print(e, file=sys.stderr)
        return 3 if errores else 0
    uso()
    return 2


def packs_activos_dirs(clave=None):
    """[(nombre, directorio)] de los packs activos (con `clave` definida en su pack.yaml, si se pide), por prioridad."""
    personal_path = config_personal_path()
    hallados = []
    for yaml_pack in packs_activos(cargar_yaml(personal_path), personal_path):
        datos = cargar_yaml(yaml_pack)
        if clave is not None:
            try:
                if buscar(datos, clave) in (None, "", [], {}):
                    continue
            except KeyError:
                continue
        hallados.append((str(datos.get("nombre") or yaml_pack.parent.name), yaml_pack.parent))
    return hallados


def imprimir_pack_dir(clave):
    """`pack-dir <clave>`: «nombre<TAB>directorio» de cada pack activo que define `clave`; exit 1 si ninguno."""
    hallados = packs_activos_dirs(clave)
    for nombre, directorio in hallados:
        print(f"{nombre}\t{directorio}")
    if not hallados:
        print(f"ningún pack activo define: {clave}", file=sys.stderr)
    return 0 if hallados else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
