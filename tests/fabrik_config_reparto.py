"""Tests de modelos.reparto / modelos.reglas en scripts/fabrik_config.py (The Factory D-5/D-6).

Lo lanza tests/fabrik_config_test.sh con FABRIK_DIR y T_TMP (directorio temporal); nunca toca la config real.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.environ["FABRIK_DIR"], "scripts"))
import yaml  # noqa: E402

import fabrik_config as fc  # noqa: E402

fallos = []


def check(nombre, cond):
    if not cond:
        fallos.append(nombre)


tmp = os.environ["T_TMP"]
check("reservadas", {"reparto", "reglas"} <= set(fc.CLAVES_RESERVADAS))
check("roles excluye reparto/reglas",
      list(fc.roles({"modelos": {"docs": {"proveedor": "a"}, "reparto": {"roles": {}}, "reglas": {}}})) == ["docs"])
check("motor trae solo las reglas genéricas",
      fc.MOTOR["modelos"].get("reglas") == {"roles_codigo": ["programador", "tester"], "revisor_otra_familia": True})
check("motor sin reparto", "reparto" not in fc.MOTOR["modelos"])
check("motor válido", fc.validar({"modelos": fc.MOTOR["modelos"]}) == [])
bueno = {"rutas": {"x": {"proveedor": "p", "modelo": "m", "familia": "f", "cuenta_claude": False, "bolsas": ["b_5h"]}},
         "roles": {"programador": ["x"]}, "ultimo_recurso": "x", "topes": {"5h": 90}, "topes_cuenta": {"a": 90}}
check("AC-6c aviso_bolsa es clave del reparto", "aviso_bolsa" in fc.CLAVES_REPARTO)
check("AC-6c aviso_bolsa válido", fc.validar({"modelos": {"reparto": {"aviso_bolsa": 98}}}) == [])
check("AC-6c aviso_bolsa 100 válido", fc.validar({"modelos": {"reparto": {"aviso_bolsa": 100}}}) == [])
for malo in (0, "x", 101, 1.5):
    errs = fc.validar({"modelos": {"reparto": {"aviso_bolsa": malo}}})
    check(f"AC-6c aviso_bolsa {malo!r}: error de rango, no de clave desconocida",
          len(errs) == 1 and "entero entre 1 y 100" in errs[0])
check("AC-6c aviso_bolsa bool no vale", fc.validar({"modelos": {"reparto": {"aviso_bolsa": True}}}) != [])
check("reparto válido", fc.validar({"modelos": {"reparto": bueno, "reglas": {
    "prohibidos_codigo": ["*flash*"], "sufijo_obligatorio": {"gemini-*": "-high"},
    "roles_codigo": ["programador"], "revisor_otra_familia": False}}}) == [])

# fusión: en reparto y reglas las listas se REEMPLAZAN (el orden de candidatos importa); los mapas se fusionan
pack = os.path.join(tmp, "pack-rep")
os.makedirs(pack, exist_ok=True)
with open(os.path.join(pack, "pack.yaml"), "w") as f:
    yaml.safe_dump({"nombre": "rep", "modelos": {"reparto": {
        "rutas": {"x": {"proveedor": "p", "modelo": "m", "bolsas": ["a_5h", "a_sem"]}},
        "roles": {"programador": ["x", "y"], "docs": ["y"]}, "topes": {"5h": 90}},
        "reglas": {"prohibidos_codigo": ["*flash*", "*lite*"]}}}, f)
personal = os.path.join(tmp, "personal-rep.yaml")
with open(personal, "w") as f:
    yaml.safe_dump({"packs": [pack], "modelos": {"reparto": {
        "rutas": {"x": {"bolsas": ["b_5h"]}}, "roles": {"programador": ["y", "x"]}, "topes": {"sem": 80}},
        "reglas": {"roles_codigo": ["programador"], "prohibidos_codigo": ["*flash*"]}}}, f)
os.environ["FABRIK_CONFIG"] = personal
c = fc.cargar()
rep, reglas = c["modelos"].get("reparto", {}), c["modelos"].get("reglas", {})
check("roles: lista reemplazada", rep.get("roles", {}).get("programador") == ["y", "x"])
check("roles: rol del pack heredado", rep.get("roles", {}).get("docs") == ["y"])
check("rutas: campo fusionado y bolsas reemplazadas",
      rep.get("rutas", {}).get("x") == {"proveedor": "p", "modelo": "m", "bolsas": ["b_5h"]})
check("topes fusionados", rep.get("topes") == {"5h": 90, "sem": 80})
check("reglas: roles_codigo reemplaza al motor", reglas.get("roles_codigo") == ["programador"])
check("reglas: prohibidos reemplaza al pack", reglas.get("prohibidos_codigo") == ["*flash*"])
check("reglas: lo del motor que no se toca sigue", reglas.get("revisor_otra_familia") is True)

# guardar_reparto: escribe SOLO modelos.reparto (las entradas dadas, fundidas a un nivel) y conserva el resto
destino = os.path.join(tmp, "real-rep.yaml")
enlace = os.path.join(tmp, "enlace-rep.yaml")
original = {"usuario_github": "alguien", "packs": ["/x"], "modelos": {
    "programador": {"proveedor": "p", "modelo": "m"}, "reglas": {"roles_codigo": ["programador"]},
    "reparto": {"rutas": {"x": {"proveedor": "p", "modelo": "m"}}, "roles": {"docs": ["x"]}, "topes": {"5h": 80}}},
    "otra": {"clave": [1, 2]}}
with open(destino, "w") as f:
    yaml.safe_dump(original, f, sort_keys=False)
os.symlink(destino, enlace)
guardar = getattr(fc, "guardar_reparto", None)
if guardar is None:
    fallos.append("falta guardar_reparto")
else:
    escrito = guardar({"roles": {"programador": ["x"]}, "topes_cuenta": {"a": 90}}, enlace)
    datos = yaml.safe_load(open(destino))
    esperado = {**original, "modelos": {**original["modelos"], "reparto": {
        **original["modelos"]["reparto"], "roles": {"docs": ["x"], "programador": ["x"]}, "topes_cuenta": {"a": 90}}}}
    check("guardar: solo cambia modelos.reparto", datos == esperado)
    check("guardar: sigue siendo un enlace", os.path.islink(enlace) and str(escrito) == os.path.realpath(destino))
    check("guardar: sin temporales", not [n for n in os.listdir(tmp) if n.startswith("real-rep.yaml.")])
    try:
        guardar({"topes": {"5h": 500}}, enlace)
        check("guardar: esquema inválido lanza ValueError", False)
    except ValueError as e:
        check("guardar: el error nombra la ruta", "modelos.reparto.topes.5h" in str(e))
    check("guardar: inválido no toca el fichero", yaml.safe_load(open(destino)) == esperado)
    nuevo = os.path.join(tmp, "dir-nuevo", "fabrik.yaml")
    guardar({"ultimo_recurso": "x"}, nuevo)
    check("guardar: crea el fichero si no existe",
          yaml.safe_load(open(nuevo)) == {"modelos": {"reparto": {"ultimo_recurso": "x"}}})
    os.environ["FABRIK_CONFIG"] = nuevo
    guardar({"topes": {"5h": 70}})
    check("guardar: sin ruta usa la config personal",
          yaml.safe_load(open(nuevo))["modelos"]["reparto"]["topes"] == {"5h": 70})
    guardar({"topes": {"sem": 90}, "ultimo_recurso": "y"})
    check("guardar: mapas fundidos, escalares sustituidos",
          yaml.safe_load(open(nuevo))["modelos"]["reparto"] == {"ultimo_recurso": "y", "topes": {"5h": 70, "sem": 90}})
    # el temporal no tiene nombre predecible: el panel guarda desde varios hilos del mismo proceso (mismo pid)
    ocupado = os.path.join(os.path.dirname(nuevo), f"fabrik.yaml.{os.getpid()}.tmp")
    os.makedirs(ocupado)
    try:
        guardar({"topes": {"5h": 60}})
        with open(nuevo) as f:
            check("guardar: temporal único (no choca con otro guardado en curso)",
                  yaml.safe_load(f)["modelos"]["reparto"]["topes"]["5h"] == 60)
    except OSError as e:
        check(f"guardar: temporal único (no choca con otro guardado en curso): {e}", False)
    os.rmdir(ocupado)
    check("guardar: sin temporales tras guardar",
          sorted(os.listdir(os.path.dirname(nuevo))) == ["fabrik.yaml"])
    guardar({"aviso_bolsa": 90})
    with open(nuevo) as f:
        check("AC-6c guardar acepta aviso_bolsa", yaml.safe_load(f)["modelos"]["reparto"]["aviso_bolsa"] == 90)
    try:
        guardar({"aviso_bolsa": 0})
        check("AC-6c guardar rechaza aviso_bolsa 0", False)
    except ValueError as e:
        check("AC-6c guardar rechaza aviso_bolsa 0", "aviso_bolsa" in str(e))

if fallos:
    print("FALLOS: " + ", ".join(fallos))
    sys.exit(1)
print("fabrik_config_reparto ok")
