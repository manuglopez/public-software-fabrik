#!/usr/bin/env bash
# Tests del cargador de config de la fábrica: 3 capas (motor < packs < personal),
# pack ficticio (tests/fixtures/pack-acme) y pack ejemplo, subcomando `fabrik config` (get/ver/campos/requisitos)
# y códigos de salida.
# HOME y FABRIK_CONFIG siempre temporales: nunca se lee el ~/.config/fabrica real.
# Los tests de integración de los packs reales viven en packs/<pack>/tests/.
# Uso: bash tests/fabrik_config_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FABRIK="$FABRIK_DIR/bin/fabrik"
FIXTURE="$FABRIK_DIR/tests/fixtures/pack-acme"

ok=0
fail=0

fallo() {
  fail=$((fail + 1))
  echo "FALLO: $1" >&2
}

ok_() {
  ok=$((ok + 1))
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# HOME temporal: aislamiento total de la config real del usuario.
export HOME="$tmp/home"
mkdir -p "$HOME"
# FABRIK_CONFIG no se exporta: cada caso lo fija inline si lo necesita. El caso
# de descubrimiento por defecto depende de que aquí NO esté (ni heredado del
# entorno del que lanzó la suite).
unset FABRIK_CONFIG

OUT="$tmp/out"
ERR="$tmp/err"

run_fabrik() {
  : > "$OUT"
  : > "$ERR"
  env HOME="$HOME" "$FABRIK" "$@" > "$OUT" 2> "$ERR"
  RC=$?
}

# contiene <fichero> <texto fijo>
contiene() {
  grep -qF -- "$2" "$1"
}

# lineas_esperadas <fichero> <n>
lineas_esperadas() {
  [ "$(grep -c . "$1")" -eq "$2" ]
}

# ---------- AC-1: con un solo pack salen sus valores ----------
cat > "$tmp/personal-acme.yaml" <<EOF
usuario_github: acme-user
packs:
  - $FIXTURE
EOF

FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config ver
nombre="AC-1 config ver con el pack fixture exit 0"
if [ "$RC" -ne 0 ]; then
  fallo "$nombre (exit $RC: $(cat "$ERR"))"
else
  ok_
  faltan=""
  for slug in alfa beta gamma delta epsilon herramienta zeta-drones acme-ops; do
    contiene "$OUT" "$slug" || faltan="$faltan $slug"
  done
  if [ -n "$faltan" ]; then
    fallo "AC-1 tableros faltan:$faltan"
  elif ! contiene "$OUT" "acme-org"; then
    fallo "AC-1 owner acme-org"
  elif ! contiene "$OUT" "acme-user/herramienta"; then
    fallo "AC-1 extra_repos herramienta"
  elif ! contiene "$OUT" "acme-fabrica"; then
    fallo "AC-1 banco acme-fabrica"
  elif ! contiene "$OUT" "Memoria de la fábrica Acme"; then
    fallo "AC-1 nombre del banco"
  else
    for repo in beta api-acme web-acme gamma app-acme panel-acme; do
      contiene "$OUT" "$repo" || faltan="$faltan $repo"
    done
    if [ -n "$faltan" ]; then
      fallo "AC-1 repos calientes faltan:$faltan"
    else
      ok_
    fi
  fi
fi

# AC-1 por get: escalares, listas y objetos
FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config get tablero_por_defecto
if [ "$RC" -ne 0 ] || [ "$(cat "$OUT")" != "acme-ops" ] || [ -s "$ERR" ]; then
  fallo "AC-1 get tablero_por_defecto (exit $RC, out=$(cat "$OUT"))"
else
  ok_
fi

FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config get owners
if [ "$RC" -ne 0 ] || ! lineas_esperadas "$OUT" 1 || ! contiene "$OUT" "acme-org"; then
  fallo "AC-1 get owners (una línea)"
else
  ok_
fi

FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config get tableros
if [ "$RC" -ne 0 ] || ! lineas_esperadas "$OUT" 8; then
  fallo "AC-1 get tableros (8 líneas, exit $RC)"
else
  ok_
fi

FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config get tableros.0.slug
if [ "$RC" -ne 0 ] || [ "$(cat "$OUT")" != "alfa" ]; then
  fallo "AC-1 get tableros.0.slug (exit $RC, out=$(cat "$OUT"))"
else
  ok_
fi

FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config get memoria.banco
if [ "$RC" -ne 0 ] || [ "$(cat "$OUT")" != "acme-fabrica" ]; then
  fallo "AC-1 get memoria.banco"
else
  ok_
fi

FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config get memoria
if [ "$RC" -ne 0 ] || ! head -c 1 "$OUT" | grep -q '{'; then
  fallo "AC-1 get memoria objeto en JSON (exit $RC)"
else
  ok_
fi

# valor por defecto del motor: idioma
FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config get idioma
if [ "$RC" -ne 0 ] || [ "$(cat "$OUT")" != "es" ]; then
  fallo "AC-1 get idioma por defecto es"
else
  ok_
fi

# valor por defecto del motor: modelos del rol programador
FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config get modelos.programador.proveedor
if [ "$RC" -ne 0 ] || ! contiene "$OUT" "anthropic"; then
  fallo "AC-1 get modelos.programador.proveedor (motor)"
else
  ok_
fi

# ---------- AC-2: orden de fusión motor < pack < personal ----------
cat > "$tmp/personal-fusion.yaml" <<EOF
packs:
  - $FIXTURE
owners:
  - mi-usuario
repos_calientes:
  - beta
base_por_defecto: main
modelos:
  programador:
    modelo: mi-modelo-personal
EOF

FABRIK_CONFIG="$tmp/personal-fusion.yaml" run_fabrik config get owners
if [ "$RC" -ne 0 ]; then
  fallo "AC-2 get owners exit $RC"
elif ! lineas_esperadas "$OUT" 2 || ! contiene "$OUT" "acme-org" || ! contiene "$OUT" "mi-usuario"; then
  fallo "AC-2 owners: lista concatenada sin duplicados (pack+personal)"
else
  ok_
fi

FABRIK_CONFIG="$tmp/personal-fusion.yaml" run_fabrik config get repos_calientes
if [ "$RC" -ne 0 ]; then
  fallo "AC-2 get repos_calientes exit $RC"
elif ! lineas_esperadas "$OUT" 6; then
  fallo "AC-2 repos_calientes: 6 sin duplicar beta"
else
  ok_
fi

FABRIK_CONFIG="$tmp/personal-fusion.yaml" run_fabrik config get base_por_defecto
if [ "$RC" -ne 0 ] || [ "$(cat "$OUT")" != "main" ]; then
  fallo "AC-2 escalar sobrescrito: base_por_defecto main (out=$(cat "$OUT"))"
else
  ok_
fi

FABRIK_CONFIG="$tmp/personal-fusion.yaml" run_fabrik config get modelos.programador.modelo
if [ "$RC" -ne 0 ] || [ "$(cat "$OUT")" != "mi-modelo-personal" ]; then
  fallo "AC-2 modelos.programador.modelo sobrescrito"
else
  ok_
fi

# el resto del rol programador sigue viniendo del motor (fusión recursiva)
FABRIK_CONFIG="$tmp/personal-fusion.yaml" run_fabrik config get modelos.programador.compacta
if [ "$RC" -ne 0 ] || [ "$(cat "$OUT")" != "160000" ]; then
  fallo "AC-2 modelos.programador.compacta sigue del motor (out=$(cat "$OUT"))"
else
  ok_
fi

# ---------- AC-3: sin packs reales se carga ejemplo y sin términos privados ----------
mkdir -p "$tmp/sin-packs"
cat > "$tmp/personal-vacio.yaml" <<EOF
packs:
  - $tmp/sin-packs
EOF

FABRIK_CONFIG="$tmp/personal-vacio.yaml" run_fabrik config ver
if [ "$RC" -ne 0 ]; then
  fallo "AC-3 config ver con packs vacío exit $RC"
else
  ok_
  privado=""
  # términos privados de todas las denylists de packs reales, leídos en ejecución
  while IFS= read -r termino; do
    termino="$(printf '%s' "$termino" | tr -d '\r' | xargs 2>/dev/null || true)"
    [ -z "$termino" ] && continue
    if grep -qiF -- "$termino" "$OUT"; then
      privado="$privado $termino"
    fi
  done < <(cat "$FABRIK_DIR"/packs/*/denylist.txt 2>/dev/null)
  if [ -n "$privado" ]; then
    fallo "AC-3 términos privados en la salida:$privado"
  elif ! contiene "$OUT" "acme"; then
    fallo "AC-3 no se cargó el pack ejemplo (sin acme)"
  else
    ok_
  fi
fi

FABRIK_CONFIG="$tmp/personal-vacio.yaml" run_fabrik config get tablero_por_defecto
if [ "$RC" -ne 0 ] || [ "$(cat "$OUT")" != "acme-dev" ]; then
  fallo "AC-3 tablero_por_defecto del ejemplo (out=$(cat "$OUT"))"
else
  ok_
fi

# ---------- AC-4: errores ----------
FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config get no.existe.esta_clave
if [ "$RC" -ne 1 ]; then
  fallo "AC-4 clave inexistente exit 1 (exit $RC)"
elif [ -s "$OUT" ]; then
  fallo "AC-4 clave inexistente stdout vacío"
elif ! grep -q 'no.existe.esta_clave' "$ERR"; then
  fallo "AC-4 clave inexistente mensaje en stderr"
else
  ok_
fi

printf 'esto no es: [yaml valido\n  - ni de broma\n' > "$tmp/malo.yaml"
FABRIK_CONFIG="$tmp/malo.yaml" run_fabrik config ver
if [ "$RC" -ne 2 ]; then
  fallo "AC-4 YAML inválido exit 2 (exit $RC)"
elif ! grep -qF "$tmp/malo.yaml" "$ERR"; then
  fallo "AC-4 YAML inválido indica el fichero en stderr"
else
  ok_
fi

# subcomando de config desconocido: uso por stderr, exit 2
FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config xyz
if [ "$RC" -ne 2 ] || [ -s "$OUT" ] || ! grep -qi 'uso' "$ERR"; then
  fallo "AC-4 'config xyz' uso por stderr exit 2 (exit $RC)"
else
  ok_
fi

# ---------- AC-5: subcomando `campos` (lista de objetos → campos '|' por línea) ----------
FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config campos tableros slug nombre descripcion icono
if [ "$RC" -ne 0 ]; then
  fallo "AC-5 campos tableros exit $RC"
elif ! lineas_esperadas "$OUT" 8; then
  fallo "AC-5 campos tableros: 8 líneas (hay $(grep -c . "$OUT"))"
elif [ "$(head -n 1 "$OUT")" != "alfa|Alfa / Producto|api-acme + web-acme + app-acme + landings|⛳" ]; then
  fallo "AC-5 campos: primera línea no trae los campos pedidos: $(head -n 1 "$OUT")"
else
  ok_
fi

FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config campos tableros slug
if [ "$RC" -ne 0 ] || ! lineas_esperadas "$OUT" 8 || [ "$(head -n 1 "$OUT")" != "alfa" ]; then
  fallo "AC-5 campos con un solo campo (exit $RC, 1ª=$(head -n 1 "$OUT"))"
else
  ok_
fi

# clave que no es una lista → exit 1, aviso por stderr y stdout vacío
FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config campos memoria.banco slug
if [ "$RC" -ne 1 ] || [ -s "$OUT" ] || ! grep -q 'no es una lista' "$ERR"; then
  fallo "AC-5 campos sobre escalar: exit 1 con aviso (exit $RC, err=$(cat "$ERR"))"
else
  ok_
fi

# clave inexistente → exit 1, 'clave no encontrada' por stderr
FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config campos no.existe slug
if [ "$RC" -ne 1 ] || ! grep -q 'clave no encontrada' "$ERR"; then
  fallo "AC-5 campos clave inexistente: exit 1 (exit $RC)"
else
  ok_
fi

# sin campos → uso por stderr, exit 2
FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config campos tableros
if [ "$RC" -ne 2 ] || [ -s "$OUT" ] || ! grep -qi 'uso' "$ERR"; then
  fallo "AC-5 campos sin campos: uso exit 2 (exit $RC)"
else
  ok_
fi

# ---------- AC-6: subcomando `requisitos` (qué exige cada proveedor de `modelos`) ----------
FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config requisitos
if [ "$RC" -ne 0 ]; then
  fallo "AC-6 requisitos exit $RC"
elif ! lineas_esperadas "$OUT" 2 \
   || contiene "$OUT" "DEEPSEEK_API_KEY" \
   || contiene "$OUT" "KIMI_API_KEY" \
   || ! contiene "$OUT" "api_key ANTHROPIC_API_KEY" \
   || ! contiene "$OUT" "plugin antigravity-oauth"; then
  fallo "AC-6 requisitos: api_key ANTHROPIC (motor) + plugin antigravity-oauth (pool del pack), sin DeepSeek ni Kimi (out=$(tr '\n' ' ' < "$OUT"))"
else
  ok_
fi

# config personal con otro proveedor en un rol → cambia el requisito
cat > "$tmp/personal-override.yaml" <<EOF
packs:
  - $FIXTURE
modelos:
  programador:
    proveedor: mi-prov
    modelo: mi-modelo
EOF
FABRIK_CONFIG="$tmp/personal-override.yaml" run_fabrik config requisitos
if [ "$RC" -ne 0 ] || ! contiene "$OUT" "plugin mi-prov" || contiene "$OUT" "KIMI_API_KEY"; then
  fallo "AC-6 requisitos con override: mi-prov en lugar de kimi (out=$(tr '\n' ' ' < "$OUT"))"
else
  ok_
fi

# ---------- R1/AC-5: unitarios de fusionar/normalizar_reserva (reserva como lista ordenada) ----------
# La capa superior REEMPLAZA la reserva entera (no concatena), en las formas dict y lista;
# null/[] la vacía; sin clave reserva se hereda; cambio de proveedor no hereda la reserva anterior.
cat > "$tmp/unit_reserva.py" <<'PY'
import os
import sys

sys.path.insert(0, os.path.join(os.environ["FABRIK_DIR"], "scripts"))
import fabrik_config as fc

fallos = []

def check(nombre, cond):
    if not cond:
        fallos.append(nombre)

CADENA = [{"proveedor": "a", "modelo": "x"}, {"proveedor": "b", "modelo": "y"}]

# dict (forma antigua): la capa superior reemplaza entera
r = fc.fusionar({"proveedor": "p1", "modelo": "m1", "reserva": {"proveedor": "p2", "modelo": "m2"}},
                {"reserva": {"proveedor": "p3", "modelo": "m3"}})
check("dict reemplaza", r["reserva"] == {"proveedor": "p3", "modelo": "m3"})
# lista ordenada: reemplaza entera, NO concatena con la del motor
r = fc.fusionar({"proveedor": "p1", "modelo": "m1", "reserva": list(CADENA)},
                {"reserva": [{"proveedor": "c", "modelo": "z"}]})
check("lista reemplaza sin concatenar", r["reserva"] == [{"proveedor": "c", "modelo": "z"}])
# null/[]: vacía la reserva
r = fc.fusionar({"proveedor": "p1", "modelo": "m1", "reserva": list(CADENA)}, {"reserva": []})
check("[] vacía la reserva", r["reserva"] == [])
# sin clave reserva en la capa superior: se hereda la de abajo
r = fc.fusionar({"proveedor": "p1", "modelo": "m1", "reserva": list(CADENA)}, {"modelo": "m9"})
check("hereda reserva sin clave", r["reserva"] == CADENA and r["modelo"] == "m9")
# cambio de proveedor: NO se hereda la reserva del proveedor anterior
r = fc.fusionar({"proveedor": "p1", "modelo": "m1", "reserva": list(CADENA)}, {"proveedor": "otro"})
check("cambio de proveedor sin herencia", "reserva" not in r)
# normalizar_reserva: dict hereda proveedor por defecto
check("normaliza dict", fc.normalizar_reserva({"modelo": "m"}, "pd") == [{"proveedor": "pd", "modelo": "m"}])
# lista: cada entrada hereda por su cuenta
n = fc.normalizar_reserva([{"proveedor": "a", "modelo": "x"}, {"modelo": "y"}], "pd")
check("normaliza lista hereda", n == [{"proveedor": "a", "modelo": "x"}, {"proveedor": "pd", "modelo": "y"}])
# null y [] → sin reserva
check("normaliza null", fc.normalizar_reserva(None, "pd") == [])
check("normaliza []", fc.normalizar_reserva([], "pd") == [])

if fallos:
    print("FALLOS: " + ", ".join(fallos))
    sys.exit(1)
print("unit_reserva ok")
PY
if env HOME="$HOME" FABRIK_DIR="$FABRIK_DIR" PYTHONPATH="$FABRIK_DIR/scripts" \
     uv run --with pyyaml python "$tmp/unit_reserva.py" > "$tmp/out-unit" 2>&1; then
  ok_
else
  fallo "R1/AC-5 unitarios fusionar/normalizar_reserva: $(cat "$tmp/out-unit")"
fi

# requisitos incluye los proveedores de TODA la cadena de reservas (lista ordenada)
cat > "$tmp/personal-cadena.yaml" <<EOF
packs: []
modelos:
  tester:
    proveedor: prov-a
    modelo: mod-a
    reserva:
      - proveedor: prov-b
        modelo: mod-b
      - proveedor: prov-c
        modelo: mod-c
EOF
FABRIK_CONFIG="$tmp/personal-cadena.yaml" run_fabrik config requisitos
if [ "$RC" -ne 0 ]; then
  fallo "R1/AC-5 requisitos cadena exit $RC"
elif ! contiene "$OUT" "plugin prov-a" || ! contiene "$OUT" "plugin prov-b" || ! contiene "$OUT" "plugin prov-c"; then
  fallo "R1/AC-5 requisitos sin toda la cadena (out=$(tr '\n' ' ' < "$OUT"))"
else
  ok_
fi

# con argumentos de más → uso por stderr, exit 2
FABRIK_CONFIG="$tmp/personal-acme.yaml" run_fabrik config requisitos extra
if [ "$RC" -ne 2 ] || [ -s "$OUT" ] || ! grep -qi 'uso' "$ERR"; then
  fallo "AC-6 requisitos con args: uso exit 2 (exit $RC)"
else
  ok_
fi

# ---------- P1/AC-1: pool de modelos, reserva_final y permitir_pago ----------
# Unitarios de roles / pool_efectivo / reserva_final / validar / fusión por capas.
mkdir -p "$tmp/pack-pool"
cat > "$tmp/pack-pool/pack.yaml" <<'EOF'
nombre: pool-pack
modelos:
  permitir_pago: false
  reserva_final: {proveedor: prov-final, modelo: mod-final}
  pool:
    ligero:
      - {proveedor: prov-l, modelo: mod-l1, herramientas: false, coste: suscripcion}
    medio:
      - {proveedor: prov-m, modelo: mod-m1, herramientas: true, coste: suscripcion}
      - {proveedor: prov-pago, modelo: mod-m2, herramientas: true, coste: pago}
    dificil:
      - {proveedor: prov-d, modelo: mod-d1, herramientas: true, coste: suscripcion}
EOF
cat > "$tmp/personal-pool.yaml" <<EOF
packs:
  - $tmp/pack-pool
modelos:
  pool:
    medio:
      - {proveedor: prov-p, modelo: mod-p1, herramientas: true, coste: suscripcion}
EOF
cat > "$tmp/personal-pool-null.yaml" <<EOF
packs:
  - $tmp/pack-pool
modelos:
  reserva_final: null
EOF
cat > "$tmp/personal-pool-pack.yaml" <<EOF
packs:
  - $tmp/pack-pool
EOF
cat > "$tmp/personal-pool-vacio.yaml" <<EOF
packs: []
EOF
printf 'nombre: pago\nmodelos:\n  permitir_pago: true\n' > "$tmp/pack-pago.yaml"
cat > "$tmp/unit_pool.py" <<'PY'
import contextlib
import io
import os
import sys
sys.path.insert(0, os.path.join(os.environ["FABRIK_DIR"], "scripts"))
import fabrik_config as fc

fallos = []
def check(nombre, cond):
    if not cond:
        fallos.append(nombre)

def e(prov, mod, herr=True, coste="suscripcion"):
    return {"proveedor": prov, "modelo": mod, "herramientas": herr, "coste": coste}

RESERVADAS = {"pool", "reserva_final", "permitir_pago"}

# roles(): excluye las claves reservadas
cfg = {"modelos": {"tester": {"proveedor": "a", "modelo": "b"},
                   "pool": {"medio": []}, "reserva_final": {"proveedor": "x", "modelo": "y"},
                   "permitir_pago": False}}
check("roles excluye reservadas", list(fc.roles(cfg)) == ["tester"])
check("roles sin modelos", fc.roles({}) == {})
check("roles ignora no-dict", fc.roles({"modelos": {"r": None, "s": {"proveedor": "a"}}}) == {"s": {"proveedor": "a"}})

# pool_efectivo: orden canónico, sin niveles vacíos, sin pago por defecto
cfg = {"modelos": {"permitir_pago": False, "pool": {
    "critico": [e("c", "c1")],
    "ligero": [e("l", "l1", False)],
    "medio": [e("m", "m1"), e("pg", "m2", coste="pago")],
    "dificil": [],
}}}
pool, excl = fc.pool_efectivo(cfg)
check("orden canónico", list(pool) == ["ligero", "medio", "critico"])
check("sin niveles vacíos", "dificil" not in pool)
check("pago fuera", pool["medio"] == [e("m", "m1")])
check("excluidos", excl == [e("pg", "m2", coste="pago")])
cfg["modelos"]["permitir_pago"] = True
pool, excl = fc.pool_efectivo(cfg)
check("permitir_pago incluye pago", pool["medio"] == [e("m", "m1"), e("pg", "m2", coste="pago")])
check("sin excluidos con permitir_pago", excl == [])
check("pool vacío sin pool", fc.pool_efectivo({"modelos": {}}) == ({}, []))
check("pool vacío sin modelos", fc.pool_efectivo({}) == ({}, []))
check("nivel desconocido no entra en pool_efectivo",
      fc.pool_efectivo({"modelos": {"pool": {"raro": [e("a", "b")]}}}) == ({}, []))
# nivel solo de pago sin permitir_pago: desaparece y todo va a excluidos
pool, excl = fc.pool_efectivo({"modelos": {"pool": {"medio": [e("a", "b", coste="pago")]}}})
check("nivel solo de pago desaparece", pool == {} and excl == [e("a", "b", coste="pago")])

# reserva_final
check("reserva_final dict", fc.reserva_final({"modelos": {"reserva_final": {"proveedor": "p", "modelo": "m"}}})
      == {"proveedor": "p", "modelo": "m"})
check("reserva_final null", fc.reserva_final({"modelos": {"reserva_final": None}}) is None)
check("reserva_final ausente", fc.reserva_final({}) is None)

# fusionar: nivel del pool reemplaza (sin concatenar), niveles no tocados se heredan
base = {"modelos": {"pool": {"medio": [e("a", "1"), e("b", "2")], "ligero": [e("l", "1", False)]},
                    "reserva_final": {"proveedor": "p1", "modelo": "m1"}}}
sup = {"modelos": {"pool": {"medio": [e("c", "3")]}, "reserva_final": {"modelo": "m2", "proveedor": "p2"}}}
r = fc.fusionar(base, sup)
check("nivel reemplaza", r["modelos"]["pool"]["medio"] == [e("c", "3")])
check("otro nivel se hereda", r["modelos"]["pool"]["ligero"] == [e("l", "1", False)])
check("reserva_final reemplaza entera", r["modelos"]["reserva_final"] == {"proveedor": "p2", "modelo": "m2"})
r = fc.fusionar(base, {"modelos": {"reserva_final": {"modelo": "solo"}}})
check("reserva_final no se funde campo a campo", r["modelos"]["reserva_final"] == {"modelo": "solo"})
r = fc.fusionar(base, {"modelos": {"reserva_final": None}})
check("reserva_final null anula", r["modelos"]["reserva_final"] is None)
r = fc.fusionar(base, {"modelos": {"pool": {"medio": []}}})
check("nivel [] vacía el nivel", r["modelos"]["pool"]["medio"] == [])

# MOTOR genérico (D-P4): sin pool, reserva_final None, permitir_pago False, sin reservas por rol,
# solo `anthropic` (opus para orquestador/revisor/seguridad, sonnet para el resto)
m = fc.MOTOR["modelos"]
check("motor sin pool", "pool" not in m)
check("motor reserva_final None", "reserva_final" in m and m["reserva_final"] is None)
check("motor permitir_pago False", m.get("permitir_pago") is False)
roles_motor = {r: v for r, v in m.items() if r not in RESERVADAS}
check("motor: 7 roles", len(roles_motor) == 7)
check("motor sin reserva por rol", all("reserva" not in v for v in roles_motor.values()))
check("motor solo anthropic", {v["proveedor"] for v in roles_motor.values()} == {"anthropic"})
check("motor: opus en orquestador, revisor y seguridad",
      {r for r, v in roles_motor.items() if v["modelo"] == "claude-opus-5-5"} == {"orquestador", "revisor", "seguridad"})
check("motor: sonnet en el resto",
      {r for r, v in roles_motor.items() if v["modelo"] == "claude-sonnet-5-5"} ==
      {"explorador", "programador", "tester", "docs"})

# validar
ok = {"modelos": {"permitir_pago": False, "reserva_final": {"proveedor": "p", "modelo": "m"},
                  "pool": {"medio": [e("a", "b"), e("c", "d", coste="pago")]}}}
check("válida sin errores", fc.validar(ok) == [])
check("sin pool es válida", fc.validar({"modelos": {}}) == [] and fc.validar({}) == [])
check("el motor por defecto es válido", fc.validar({"modelos": fc.MOTOR["modelos"]}) == [])
def errs(modelos):
    return fc.validar({"modelos": modelos})
x = e("a", "b"); del x["herramientas"]
r = errs({"pool": {"medio": [e("a", "b"), x]}})
check("sin herramientas nombra ruta", len(r) == 1 and "modelos.pool.medio[1].herramientas" in r[0])
r = errs({"pool": {"medio": [e("a", "b", coste="gratis")]}})
check("coste inválido nombra ruta", len(r) == 1 and "modelos.pool.medio[0].coste" in r[0])
x = e("a", "b"); del x["coste"]
check("sin coste nombra ruta", any("modelos.pool.ligero[0].coste" in l for l in errs({"pool": {"ligero": [x]}})))
r = errs({"pool": {"experto": [e("a", "b")]}})
check("nivel desconocido nombra ruta", len(r) == 1 and "modelos.pool.experto" in r[0])
check("herramientas no bool", any("modelos.pool.medio[0].herramientas" in l
      for l in errs({"pool": {"medio": [e("a", "b", herr="si")]}})))
check("proveedor vacío", any("modelos.pool.medio[0].proveedor" in l
      for l in errs({"pool": {"medio": [e("", "b")]}})))
check("modelo no str", any("modelos.pool.medio[0].modelo" in l
      for l in errs({"pool": {"medio": [e("a", 3)]}})))
check("nivel no lista", any("modelos.pool.medio" in l for l in errs({"pool": {"medio": {"a": 1}}})))
check("entrada no dict", any("modelos.pool.medio[0]" in l for l in errs({"pool": {"medio": ["x"]}})))
check("pool no dict", any("modelos.pool" in l for l in errs({"pool": ["x"]})))
check("reserva_final sin modelo nombra ruta",
      any("modelos.reserva_final.modelo" in l for l in errs({"reserva_final": {"proveedor": "p"}})))
check("reserva_final sin proveedor nombra ruta",
      any("modelos.reserva_final.proveedor" in l for l in errs({"reserva_final": {"modelo": "m"}})))
check("reserva_final no dict", any("modelos.reserva_final" in l for l in errs({"reserva_final": "x"})))
check("reserva_final null válida", errs({"reserva_final": None}) == [])
check("permitir_pago no bool", any("modelos.permitir_pago" in l for l in errs({"permitir_pago": "si"})))

# requisitos: proveedores del pool efectivo y de reserva_final
def requisitos(cfg):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        fc.imprimir_requisitos(cfg)
    return buf.getvalue()
cfg = {"modelos": {"reserva_final": {"proveedor": "prov-final", "modelo": "m"},
                   "pool": {"medio": [e("prov-m", "m"), e("prov-pago", "m", coste="pago")]}}}
out = requisitos(cfg)
check("requisitos incluye pool", "plugin prov-m" in out)
check("requisitos incluye reserva_final", "plugin prov-final" in out)
check("requisitos omite pago excluido", "prov-pago" not in out)
cfg["modelos"]["permitir_pago"] = True
check("requisitos incluye pago con permitir_pago", "plugin prov-pago" in requisitos(cfg))
out = requisitos({"modelos": {"pool": {"medio": []}, "reserva_final": None, "permitir_pago": False,
                              "tester": {"proveedor": "t", "modelo": "m"}}})
check("requisitos no trata claves reservadas como roles", out.strip() == "plugin t")

# proponer_modelos: roles + pool + reserva_final, sin `permitir_pago` (lo fija el pack, no se propone)
modelos_prop, avisos_prop = fc.proponer_modelos({"antigravity-oauth", "kimi-coding"})
check("proponer_modelos: roles", set(modelos_prop) - RESERVADAS == set(fc.PREFERENCIAS_ROL))
check("proponer_modelos no propone permitir_pago", "permitir_pago" not in modelos_prop)
check("proponer_modelos: pool sin niveles vacíos", sorted(modelos_prop["pool"]) == ["ligero", "medio"])
check("proponer_modelos: reserva_final con proveedor detectado",
      modelos_prop["reserva_final"] == {"proveedor": "antigravity-oauth", "modelo": "gemini-3.8-flash-high"})
check("proponer_modelos: avisa de los niveles vacíos",
      [a for a in avisos_prop if a.startswith("nivel ")] ==
      [a for a in avisos_prop if a.startswith("nivel dificil") or a.startswith("nivel critico")] and
      sum(a.startswith("nivel ") for a in avisos_prop) == 2)
check("proponer_modelos: reserva explícita (lista) en cada rol",
      all(isinstance(modelos_prop[r]["reserva"], list) for r in fc.PREFERENCIAS_ROL))

# AC-24: nunca propone de pago sin permitir_pago, ni en roles, ni en reserva, ni en pool, ni en reserva_final
def proveedores_de(modelos):
    s = set()
    for r in set(modelos) - RESERVADAS:
        s |= {modelos[r]["proveedor"]} | {x["proveedor"] for x in modelos[r]["reserva"]}
    for nivel in modelos.get("pool", {}).values():
        s |= {x["proveedor"] for x in nivel}
    if modelos.get("reserva_final"):
        s.add(modelos["reserva_final"]["proveedor"])
    return s
todos = set(fc.PROVEEDORES_CONOCIDOS)
sin_pago, _ = fc.proponer_modelos(todos)
check("AC-24 sin permitir_pago no aparece deepseek en ningún sitio", "deepseek" not in proveedores_de(sin_pago))
check("AC-24 los de pago de las tablas están en PROVEEDORES_DE_PAGO", fc.PROVEEDORES_DE_PAGO == {"deepseek"})
solo_pago, av = fc.proponer_modelos({"deepseek"})
check("AC-24 solo deepseek y sin permitir_pago: nada propuesto", set(solo_pago) == set() and
      sum(a.startswith("nivel ") for a in av) == 4 and any(a.startswith("sin reserva_final") for a in av))
con_pago, _ = fc.proponer_modelos(todos, permitir_pago=True)
check("AC-24 con permitir_pago sí aparece deepseek", "deepseek" in proveedores_de(con_pago))
check("AC-24 con permitir_pago el pool lleva sus entradas de pago",
      {x["modelo"] for x in con_pago["pool"]["medio"]} >= {"deepseek-flash"})
# la reserva_final sale solo de proveedores detectados y permitidos
check("AC-24 reserva_final solo de proveedores detectados",
      fc.proponer_modelos({"anthropic"})[0]["reserva_final"]["proveedor"] == "anthropic")
check("AC-24 reserva_final ausente sin proveedores", "reserva_final" not in fc.proponer_modelos(set())[0])
# permitir_pago efectivo: lo da la capa del pack
os.environ["FABRIK_CONFIG"] = os.environ["T_VACIO"]
check("AC-24 permitir_pago_efectivo false por defecto", fc.permitir_pago_efectivo() is False)
check("AC-24 permitir_pago_efectivo con pack que lo activa", fc.permitir_pago_efectivo(os.environ["T_PAGO"]) is True)

# cargar() con capas reales: pack < personal, y sin recurrir a `ejemplo`
def cargar_con(personal):
    os.environ["FABRIK_CONFIG"] = personal
    return fc.cargar()
c = cargar_con(os.environ["T_PACK"])
pool, excl = fc.pool_efectivo(c)
check("pack sobre motor: pool", list(pool) == ["ligero", "medio", "dificil"])
check("pack: pago excluido", pool["medio"] == [e("prov-m", "mod-m1")] and
      excl == [e("prov-pago", "mod-m2", coste="pago")])
check("pack: reserva_final", fc.reserva_final(c) == {"proveedor": "prov-final", "modelo": "mod-final"})
check("pack: roles intactos", set(fc.roles(c)) == set(fc.MOTOR["modelos"]) - RESERVADAS)
c = cargar_con(os.environ["T_PERSONAL"])
pool, _ = fc.pool_efectivo(c)
check("personal reemplaza nivel del pack", pool["medio"] == [e("prov-p", "mod-p1")])
check("personal hereda otros niveles", pool["ligero"] == [e("prov-l", "mod-l1", False)])
c = cargar_con(os.environ["T_NULL"])
check("personal null anula reserva_final", fc.reserva_final(c) is None)
check("personal null no toca el pool", "medio" in fc.pool_efectivo(c)[0])
c = cargar_con(os.environ["T_VACIO"])
check("packs [] sin pool: pool vacío (no ejemplo)", fc.pool_efectivo(c) == ({}, []))
check("packs [] sin reserva_final", fc.reserva_final(c) is None)

if fallos:
    print("FALLOS: " + ", ".join(fallos))
    sys.exit(1)
print("unit_pool ok")
PY
if env HOME="$HOME" FABRIK_DIR="$FABRIK_DIR" PYTHONPATH="$FABRIK_DIR/scripts" \
     T_PACK="$tmp/personal-pool-pack.yaml" T_PERSONAL="$tmp/personal-pool.yaml" \
     T_NULL="$tmp/personal-pool-null.yaml" T_VACIO="$tmp/personal-pool-vacio.yaml" T_PAGO="$tmp/pack-pago.yaml" \
     uv run --with pyyaml python "$tmp/unit_pool.py" > "$tmp/out-unit" 2>&1; then
  ok_
else
  fallo "P1/AC-1 unitarios pool/reserva_final/validar/fusión: $(cat "$tmp/out-unit")"
fi

# CLI `fabrik config validar`: config válida → exit 0; cada error → exit 3 y nombra la ruta
FABRIK_CONFIG="$tmp/personal-pool.yaml" run_fabrik config validar
if [ "$RC" -ne 0 ]; then
  fallo "P1/AC-1 validar config válida: exit $RC ($(cat "$ERR"))"
else
  ok_
fi
FABRIK_CONFIG="$tmp/personal-pool-vacio.yaml" run_fabrik config validar
if [ "$RC" -ne 0 ]; then
  fallo "P1/AC-1 validar config sin pool: exit $RC ($(cat "$ERR"))"
else
  ok_
fi

# caso_invalido <nombre> <ruta esperada> <líneas YAML bajo modelos:>
caso_invalido() {
  local nombre="$1" ruta="$2" cuerpo="$3"
  printf 'packs: []\nmodelos:\n%s\n' "$cuerpo" > "$tmp/personal-invalido.yaml"
  FABRIK_CONFIG="$tmp/personal-invalido.yaml" run_fabrik config validar
  if [ "$RC" -ne 3 ]; then
    fallo "P1/AC-1 validar $nombre: exit $RC (esperado 3)"
  elif ! grep -qF -- "$ruta" "$OUT" "$ERR"; then
    fallo "P1/AC-1 validar $nombre: no nombra la ruta $ruta (out=$(tr '\n' ' ' < "$OUT") err=$(tr '\n' ' ' < "$ERR"))"
  else
    ok_
  fi
}
caso_invalido "entrada sin herramientas" "modelos.pool.medio[1].herramientas" \
'  pool:
    medio:
      - {proveedor: a, modelo: b, herramientas: true, coste: suscripcion}
      - {proveedor: a, modelo: c, coste: suscripcion}'
caso_invalido "coste inválido" "modelos.pool.medio[0].coste" \
'  pool:
    medio:
      - {proveedor: a, modelo: b, herramientas: true, coste: gratis}'
caso_invalido "nivel desconocido" "modelos.pool.experto" \
'  pool:
    experto:
      - {proveedor: a, modelo: b, herramientas: true, coste: suscripcion}'
caso_invalido "reserva_final sin modelo" "modelos.reserva_final.modelo" \
'  reserva_final:
    proveedor: a'

# requisitos por CLI incluye pool efectivo y reserva_final (y no el pago excluido)
FABRIK_CONFIG="$tmp/personal-pool-pack.yaml" run_fabrik config requisitos
if [ "$RC" -ne 0 ] || ! contiene "$OUT" "plugin prov-l" || ! contiene "$OUT" "plugin prov-final" \
   || contiene "$OUT" "prov-pago"; then
  fallo "P1/AC-2 requisitos CLI con pool y reserva_final (exit $RC, out=$(tr '\n' ' ' < "$OUT"))"
else
  ok_
fi

# mostrar-modelos no lista pool/reserva_final/permitir_pago como roles
FABRIK_CONFIG="$tmp/personal-pool-pack.yaml" run_fabrik config mostrar-modelos
if [ "$RC" -ne 0 ] || grep -qE '^ +(pool|reserva_final|permitir_pago) *:' "$OUT" || ! contiene "$OUT" "tester"; then
  fallo "P1/AC-1 mostrar-modelos trata claves reservadas como roles (exit $RC)"
else
  ok_
fi

# AC-25: `modelos-previos` (máquina ya configurada: perfiles de Hermes, sin fabrik.yaml, pack con modelos de referencia)
mkdir -p "$tmp/mp/pack/tests/fixtures" "$tmp/mp/h/.hermes/profiles/tester"
printf 'nombre: con\n' > "$tmp/mp/pack/pack.yaml"
: > "$tmp/mp/pack/tests/fixtures/modelos-x.yaml"
HOME_MP="$tmp/mp/h"
HOME="$HOME_MP" run_fabrik config modelos-previos "$tmp/mp/no-existe.yaml" "$tmp/mp/pack"
if [ "$RC" -ne 0 ] || [ "$(cat "$OUT")" != "$tmp/mp/pack/tests/fixtures/modelos-x.yaml" ]; then
  fallo "AC-25 modelos-previos con pack, perfiles y sin config: debe listar el fixture (rc=$RC out=$(cat "$OUT"))"
else
  ok_
fi
printf 'packs: []\n' > "$tmp/mp/cfg.yaml"
HOME="$HOME_MP" run_fabrik config modelos-previos "$tmp/mp/cfg.yaml" "$tmp/mp/pack"
if [ "$RC" -ne 1 ] || [ -s "$OUT" ]; then
  fallo "AC-25 modelos-previos con la config personal ya creada: no aplica (rc=$RC)"
else
  ok_
fi
mkdir -p "$tmp/mp/h2/.hermes"
HOME="$tmp/mp/h2" run_fabrik config modelos-previos "$tmp/mp/no-existe.yaml" "$tmp/mp/pack"
if [ "$RC" -ne 1 ] || [ -s "$OUT" ]; then
  fallo "AC-25 modelos-previos sin perfiles de Hermes (máquina nueva): no aplica (rc=$RC)"
else
  ok_
fi
# Sin pack explícito se miran los packs activos del repo (sin contar `ejemplo`): si un pack del repo trae fixture de modelos, se usa.
HOME="$HOME_MP" run_fabrik config modelos-previos "$tmp/mp/no-existe.yaml"
tiene_fixture=0; ls "$FABRIK_DIR"/packs/*/tests/fixtures/modelos-*.yaml >/dev/null 2>&1 && tiene_fixture=1
if [ "$tiene_fixture" -eq 1 ] && { [ "$RC" -ne 0 ] || ! contiene "$OUT" "modelos-"; }; then
  fallo "AC-25 modelos-previos sin pack explícito: debe usar los packs activos (rc=$RC)"
elif [ "$tiene_fixture" -eq 0 ] && [ "$RC" -ne 1 ]; then
  fallo "AC-25 modelos-previos sin packs con fixtures: no aplica (rc=$RC)"
else
  ok_
fi

# ---------- AC-35: motor sin pack propio ----------
# Sin config personal y sin ningún pack en el repo (solo `ejemplo`), rige el pack de ejemplo.
run_fabrik config ver
if [ "$RC" -ne 0 ]; then
  fallo "AC-35 sin config personal ni packs en el repo: exit $RC"
elif ! contiene "$OUT" "acme"; then
  fallo "AC-35 sin pack propio no rige el pack ejemplo"
else
  ok_
fi
# Rama de descubrimiento: con un pack en packs/ del repo (copia del motor) rige ese y no ejemplo.
# El nombre de la carpeta es irrelevante (D-P2).
copia="$tmp/motor-con-pack"
mkdir -p "$copia/packs/cualquier-nombre"
cp -r "$FABRIK_DIR/bin" "$FABRIK_DIR/scripts" "$FABRIK_DIR/config" "$copia/"
cp -r "$FABRIK_DIR/packs/ejemplo" "$copia/packs/"
cp -r "$FIXTURE/." "$copia/packs/cualquier-nombre/"
env HOME="$HOME" "$copia/bin/fabrik" config get owners > "$OUT" 2> "$ERR"; RC=$?
if [ "$RC" -ne 0 ] || [ "$(cat "$OUT")" != "acme-org" ]; then
  fallo "AC-35 un pack en packs/ del repo (nombre libre) debe regir sin config personal (rc=$RC, out=$(cat "$OUT"))"
else
  ok_
fi

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
