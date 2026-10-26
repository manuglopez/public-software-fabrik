"""Reglas de modelos (plan The Factory D-6, AC-4b): validan el reparto de `bin/fabrik-modelos` antes de guardarlo y,
aplicadas al reparto vigente, dan los avisos de la pestaña Agentes.

`validar_reparto(config, reparto) -> [errores]`: `config` es la config fusionada (de ella solo se leen
`modelos.reglas`); `reparto` es el reparto completo (rutas, roles, ultimo_recurso, topes, topes_cuenta), como lo da
`fabrik-modelos estado --json`. Reglas:
  1. los candidatos de los roles de código (`reglas.roles_codigo`) no casan con `reglas.prohibidos_codigo`;
  2. los modelos que casan con una clave de `reglas.sufijo_obligatorio` acaban en ese sufijo (candidatos y último
     recurso);
  3. siempre: cada rol tiene al menos un candidato, las rutas existen (sin repetir) y los topes son enteros de 1 a 100;
  4. `reglas.revisor_otra_familia` (por defecto sí): tester, revisor y seguridad tienen algún candidato de una familia
     distinta de alguna de las del programador.
No es un router: `registrar` no añade rutas (lo usa fx_agentes).
"""
from __future__ import annotations

from fnmatch import fnmatchcase

REVISORES = ("tester", "revisor", "seguridad")
ROLES_CODIGO = ("programador", "tester")  # si la config no trae reglas.roles_codigo (el motor sí lo trae)


def registrar(router) -> None:  # noqa: ARG001 - plugin_api carga todos los fx_* igual
    return None


def _mapa(valor) -> dict:
    return valor if isinstance(valor, dict) else {}


def _lista(valor) -> list:
    return valor if isinstance(valor, list) else []


def _es_tope(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and 1 <= v <= 100


def _topes(errores: list[str], valor, clave: str, etiqueta: str) -> None:
    if not isinstance(valor, dict):
        errores.append(f"{clave}: tiene que ser un mapa {'bolsa' if clave == 'topes' else 'cuenta'} → %")
        return
    for k, v in valor.items():
        if not _es_tope(v):
            errores.append(f"{etiqueta} {k}: {v!r} no vale, tiene que ser un entero entre 1 y 100")


def validar_reparto(config: dict, reparto: dict) -> list[str]:
    """Errores (en español, uno por problema) del `reparto` según las reglas de `config`; [] si cumple todas."""
    reglas = _mapa(_mapa(_mapa(config).get("modelos")).get("reglas"))
    reparto = _mapa(reparto)
    rutas, roles = _mapa(reparto.get("rutas")), _mapa(reparto.get("roles"))
    roles_codigo = reglas["roles_codigo"] if isinstance(reglas.get("roles_codigo"), list) else ROLES_CODIGO
    prohibidos = [p for p in _lista(reglas.get("prohibidos_codigo")) if isinstance(p, str)]
    sufijos = _mapa(reglas.get("sufijo_obligatorio"))
    errores: list[str] = []

    def modelo(ruta: str) -> str:
        return str(_mapa(rutas.get(ruta)).get("modelo") or "")

    def familia(ruta) -> str:
        return str(_mapa(rutas.get(ruta)).get("familia") or "")

    def sufijo(quien: str, ruta: str) -> None:
        for patron, suf in sufijos.items():
            m = modelo(ruta)
            if isinstance(suf, str) and fnmatchcase(m, str(patron)) and not m.endswith(suf):
                errores.append(f"{quien}: «{ruta}» ({m}) tiene que acabar en «{suf}» "
                               f"(reglas.sufijo_obligatorio «{patron}»)")

    for rol, cands in roles.items():
        if not isinstance(cands, list):
            errores.append(f"{rol}: los candidatos tienen que ser una lista de rutas")
            continue
        if not cands:
            errores.append(f"{rol}: necesita al menos un candidato")
        vistos: set = set()
        for ruta in cands:
            if not isinstance(ruta, str) or ruta not in rutas:
                errores.append(f"{rol}: la ruta «{ruta}» no existe (rutas: {', '.join(rutas)})")
                continue
            if ruta in vistos:
                errores.append(f"{rol}: «{ruta}» está repetida")
                continue
            vistos.add(ruta)
            if rol in roles_codigo:
                for patron in prohibidos:
                    if fnmatchcase(modelo(ruta), patron):
                        errores.append(f"{rol}: «{ruta}» ({modelo(ruta)}) no puede ser candidato de un rol de código: "
                                       f"casa con «{patron}» (reglas.prohibidos_codigo)")
            sufijo(rol, ruta)

    ultimo = reparto.get("ultimo_recurso")
    if ultimo is not None:
        if not isinstance(ultimo, str) or ultimo not in rutas:
            errores.append(f"último recurso: la ruta «{ultimo}» no existe")
        else:
            sufijo("último recurso", ultimo)
    for clave, etiqueta in (("topes", "tope de la bolsa"), ("topes_cuenta", "tope semanal de la cuenta")):
        if clave in reparto:
            _topes(errores, reparto[clave], clave, etiqueta)

    if reglas.get("revisor_otra_familia", True) is not False:
        fam_prog = {familia(r) for r in _lista(roles.get("programador"))} - {""}
        for rol in [r for r in roles if r in REVISORES]:
            fam_rol = {familia(r) for r in _lista(roles[rol])} - {""}
            if fam_prog and fam_rol and not any(a != b for a in fam_rol for b in fam_prog):
                errores.append(f"{rol}: todos sus candidatos son de la familia {', '.join(sorted(fam_rol))}, como los "
                               "del programador; añade uno de otra familia para que pueda revisar con otro modelo "
                               "(reglas.revisor_otra_familia)")
    return errores
