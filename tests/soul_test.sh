#!/usr/bin/env bash
# SOUL en plantilla + añadidos por pack + skill /fabrica genérica (IMPL-3).
# AC-11: con el pack ejemplo, ni los SOUL ni la skill contienen términos de las denylists externas (D-P5).
# AC-12: una variable de plantilla desconocida hace fallar `--solo-soul --seco` y se nombra.
# Uso: bash tests/soul_test.sh   (HOME temporal: nunca toca ~/.hermes reales)
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Denylists contra las que se comprueba AC-11 (D-P5): las de packs/* del repo, las de $FABRIK_DATA/packs/* y
# PACK_DENYLIST=<fichero> si se pasa; sin contar `ejemplo`. Sin ninguna, AC-11 no tiene contra qué comparar y se
# omite con un aviso (el motor solo lleva `packs/ejemplo`); el resto de casos corre igual con packs de fixture.
# La comparación contra los goldens de un pack real vive en el propio pack (tests/soul_*_test.sh).
DENYLISTS=()
for d in "$FABRIK_DIR"/packs/*/denylist.txt "${FABRIK_DATA:-$HOME/.hermes/factory}"/packs/*/denylist.txt ${PACK_DENYLIST:+"$PACK_DENYLIST"}; do
  [ -f "$d" ] || continue
  [ "$(basename "$(dirname "$(readlink -f "$d")")")" = "ejemplo" ] && continue
  DENYLISTS+=("$(readlink -f "$d")")
done
# Pack ficticio con pool de modelos para los casos del motor (POOL-3, AC-7, AC-12)
PACK_FIXTURE="$FABRIK_DIR/tests/fixtures/pack-acme"
SKILL_FILE="$FABRIK_DIR/plugin/fabrica/skills/fabrica/SKILL.md"
ROLES=(orquestador explorador programador tester revisor seguridad docs)

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
bien() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"
unset FABRIK_CONFIG

APPLY="$FABRIK_DIR/scripts/apply_profile_policy.py"
pyrun() { uv run --with pyyaml python "$@"; }

terminos_denylist() {
  [ "${#DENYLISTS[@]}" -gt 0 ] && sed 's/#.*//' "${DENYLISTS[@]}" | tr -d '[:blank:]' | grep -v '^$'
}

contiene_denylist() { # $1 fichero → imprime los términos encontrados
  local t hallados=""
  while IFS= read -r t; do
    grep -qiF -- "$t" "$1" && hallados="$hallados $t"
  done < <(terminos_denylist)
  echo "$hallados"
}

genera_souls() { # $1 yaml de config → SOUL de todos los roles en $HOME (perfiles pre-creados: no se invoca hermes)
  rm -rf "$HOME/.hermes/profiles"
  local r
  for r in "${ROLES[@]}"; do mkdir -p "$HOME/.hermes/profiles/$r"; done
  FABRIK_CONFIG="$1" pyrun "$APPLY" --solo-soul > "$tmp/out" 2> "$tmp/err"
}

cat > "$tmp/config-pack.yaml" <<EOF
packs:
  - $PACK_FIXTURE
EOF
cat > "$tmp/config-ejemplo.yaml" <<EOF
packs:
  - $FABRIK_DIR/packs/ejemplo
EOF

# ---------- SOUL con el pack ficticio con pool (POOL-3, AC-7) ----------
if genera_souls "$tmp/config-pack.yaml"; then
  bien
else
  fallo "--solo-soul con el pack ficticio falló: $(cat "$tmp/err")"
fi

# ---------- Pool de modelos (P3): SOUL del orquestador con el pack ficticio ----------
# (los SOUL se generaron con el pack ficticio)
orq_soul="$HOME/.hermes/profiles/orquestador/SOUL.md"
if [ -s "$orq_soul" ]; then
  if grep -qF '| Nivel | Cuándo | Modelos (proveedor) |' "$orq_soul"; then bien; else fallo "POOL-3 pack ficticio: falta la tabla del pool en el SOUL del orquestador"; fi
  for nivel in ligero medio dificil; do
    if grep -qE "^\| $nivel \| " "$orq_soul"; then bien; else fallo "POOL-3 pack ficticio: falta el nivel $nivel en la tabla"; fi
  done
  # permitir_pago: true en el pack ficticio → el modelo de pago entra en la tabla
  if grep -E '^\| medio \| ' "$orq_soul" | grep -qF '`acme-medio-pago`'; then bien; else fallo "POOL-3 pack ficticio: el modelo de pago debe estar en la tabla con permitir_pago: true"; fi
  if grep -qF 'a la reserva final: `acme-reserva` (`antigravity-oauth`).' "$orq_soul"; then bien; else fallo "POOL-3 pack ficticio: falta la reserva final en la regla de agotamiento"; fi
else
  fallo "POOL-3 falta el SOUL del orquestador"
fi
# permitir_pago: false en la config personal → el de pago sale de la tabla y queda en la línea «De pago…»
printf 'packs:\n  - %s\nmodelos:\n  permitir_pago: false\n' "$PACK_FIXTURE" > "$tmp/config-nopago.yaml"
if genera_souls "$tmp/config-nopago.yaml"; then
  orq_soul="$HOME/.hermes/profiles/orquestador/SOUL.md"
  if grep -E '^\| ' "$orq_soul" | grep -qF 'acme-medio-pago'; then fallo "POOL-3 sin pago: un modelo de pago entró en la tabla"; else bien; fi
  if grep -qE '^De pago, solo si el humano lo pide: .*`acme-medio-pago` \(`antigravity-oauth`\)' "$orq_soul"; then bien; else fallo "POOL-3 sin pago: falta la línea «De pago…» con acme-medio-pago"; fi
else
  fallo "POOL-3 sin pago: --solo-soul falló: $(cat "$tmp/err")"
fi
genera_souls "$tmp/config-pack.yaml" || fallo "--solo-soul con el pack ficticio falló (2ª vez): $(cat "$tmp/err")"

# ---------- AC-7: auto-chequeo programador y verificación tester ----------
prog_soul="$HOME/.hermes/profiles/programador/SOUL.md"
tester_soul="$HOME/.hermes/profiles/tester/SOUL.md"
if [ -s "$prog_soul" ]; then
  if grep -qi "auto-chequeo" "$prog_soul"; then bien; else fallo "AC-7 programador: falta paso de auto-chequeo"; fi
  if grep -q "98 %" "$prog_soul"; then bien; else fallo "AC-7 programador: falta umbral 98 % de cobertura"; fi
  if grep -q "85 %" "$prog_soul"; then bien; else fallo "AC-7 programador: falta umbral 85 % de MSI"; fi
  for clave in diff_coverage uncovered_lines msi surviving_mutants ac_matrix tests ficheros; do
    if grep -q "$clave" "$prog_soul"; then bien; else fallo "AC-7 programador: falta clave de metadata $clave"; fi
  done
else
  fallo "AC-7 falta SOUL del programador"
fi
if [ -s "$tester_soul" ]; then
  if grep -qiE "verifica(s)?.*cifras del programador" "$tester_soul"; then bien; else fallo "AC-7 tester: falta verificación de las cifras del programador"; fi
  if grep -q "kanban_request_changes" "$tester_soul"; then bien; else fallo "AC-7 tester: falta kanban_request_changes"; fi
else
  fallo "AC-7 falta SOUL del tester"
fi

# ---------- AC-11 ----------
if [ "${#DENYLISTS[@]}" -eq 0 ]; then
  echo "aviso: sin denylists externas (packs/*, \$FABRIK_DATA/packs, PACK_DENYLIST): AC-11 solo comprueba el control negativo" >&2
else
  echo "AC-11: $(terminos_denylist | grep -c .) términos de ${#DENYLISTS[@]} denylist(s) externas"
fi
# control negativo: con una denylist que lleva un término presente en el SOUL, el comprobador lo encuentra
genera_souls "$tmp/config-ejemplo.yaml" >/dev/null 2>&1
DENYLISTS_REAL=("${DENYLISTS[@]}")
printf '%s\n' 'auto-chequeo' > "$tmp/denylist-control.txt"
DENYLISTS=("$tmp/denylist-control.txt")
# (el SOUL del programador lleva «auto-chequeo»: lo comprueba AC-7 con el pack ficticio)
if grep -qi 'auto-chequeo' "$HOME/.hermes/profiles/programador/SOUL.md" && [ -n "$(contiene_denylist "$HOME/.hermes/profiles/programador/SOUL.md")" ]; then bien; else fallo "AC-11 control negativo: el comprobador no detectó un término de la denylist"; fi
DENYLISTS=("${DENYLISTS_REAL[@]}")
if genera_souls "$tmp/config-ejemplo.yaml"; then
  bien
  for rol in "${ROLES[@]}"; do
    soul="$HOME/.hermes/profiles/$rol/SOUL.md"
    if [ ! -s "$soul" ]; then fallo "AC-11 $rol: SOUL.md no generado"; continue; fi
    h="$(contiene_denylist "$soul")"
    if [ -n "$h" ]; then fallo "AC-11 SOUL $rol contiene términos de la denylist:$h"; else bien; fi
  done
else
  fallo "AC-11 --solo-soul con pack ejemplo falló: $(cat "$tmp/err")"
fi
h="$(contiene_denylist "$SKILL_FILE")"
if [ -n "$h" ]; then fallo "AC-11 SKILL.md contiene términos de la denylist:$h"; else bien; fi
# El pack ejemplo no debe arrastrar el título ni las variables sin resolver.
if grep -q 'Pack de ejemplo' "$HOME/.hermes/profiles/programador/SOUL.md"; then bien; else fallo "AC-11 {{titulo}} no se sustituyó por el título del pack ejemplo"; fi

# ---------- AC-12 ----------
# --solo-soul --seco con las plantillas reales: exit 0 y no escribe nada.
rm -rf "$HOME/.hermes"
if FABRIK_CONFIG="$tmp/config-pack.yaml" pyrun "$APPLY" --solo-soul --seco > "$tmp/out" 2> "$tmp/err"; then
  bien
else
  fallo "AC-12 --solo-soul --seco válido debería salir con 0: $(cat "$tmp/err")"
fi
if [ -e "$HOME/.hermes" ]; then fallo "AC-12 --seco escribió en ~/.hermes"; else bien; fi

# Copia del motor con una variable inventada en un perfil: se ejecuta el script real.
fake="$tmp/fake-repo"
mkdir -p "$fake"
cp -r "$FABRIK_DIR/scripts" "$FABRIK_DIR/profiles" "$FABRIK_DIR/config" "$FABRIK_DIR/packs" "$fake/"
echo 'Texto con {{variable_inventada}} dentro.' >> "$fake/profiles/orquestador.md"
FABRIK_CONFIG="$tmp/config-pack.yaml" pyrun "$fake/scripts/apply_profile_policy.py" --solo-soul --seco > "$tmp/out" 2> "$tmp/err"
rc=$?
if [ "$rc" -eq 0 ]; then
  fallo "AC-12 variable desconocida: debería salir con exit != 0"
elif ! grep -q 'variable_inventada' "$tmp/err" "$tmp/out"; then
  fallo "AC-12 variable desconocida: falló (rc=$rc) pero no nombra la variable: $(cat "$tmp/err")"
else
  bien
fi
# El mensaje es el limpio (no un traceback de KeyError) y nombra la variable.
if grep -q 'variable de plantilla desconocida: variable_inventada' "$tmp/err" && ! grep -q 'Traceback' "$tmp/err"; then
  bien
else
  fallo "AC-12 mensaje esperado «variable de plantilla desconocida: variable_inventada» sin traceback: $(cat "$tmp/err")"
fi

# ---------- Variables por defecto y {{owners}} ----------
# {{titulo}} sin `titulo` en ningún pack → «la fábrica»; {{owners}} → owners del pack, unidos por «, ».
cp -r "$FABRIK_DIR/scripts" "$FABRIK_DIR/profiles" "$FABRIK_DIR/config" "$tmp/"  # copia limpia, sin la variable inventada
mkdir -p "$tmp/packs/sin-titulo"
cp -r "$FABRIK_DIR/packs/ejemplo/." "$tmp/packs/sin-titulo/"
cat > "$tmp/packs/sin-titulo/pack.yaml" <<EOF
nombre: sin-titulo
owners:
  - acme
  - globex
EOF
echo 'Owners: {{owners}}.' >> "$tmp/profiles/programador.md"
cat > "$tmp/config-sin-titulo.yaml" <<EOF
packs:
  - $tmp/packs/sin-titulo
EOF
rm -rf "$HOME/.hermes"
mkdir -p "$HOME/.hermes/profiles/programador"
if FABRIK_CONFIG="$tmp/config-sin-titulo.yaml" pyrun "$tmp/scripts/apply_profile_policy.py" --solo-soul programador > "$tmp/out" 2> "$tmp/err"; then
  soul="$HOME/.hermes/profiles/programador/SOUL.md"
  if head -1 "$soul" | grep -qx '# Programador de la fábrica'; then bien; else fallo "{{titulo}} sin título de pack debería dar «la fábrica»; cabecera: $(head -1 "$soul")"; fi
  if grep -qx 'Owners: acme, globex.' "$soul"; then bien; else fallo "{{owners}} debería dar «acme, globex»: $(grep '^Owners:' "$soul")"; fi
  if grep -q '{{' "$soul"; then fallo "quedan variables {{...}} sin sustituir"; else bien; fi
else
  fallo "--solo-soul con pack sin título falló: $(cat "$tmp/err")"
fi

echo "── final:"
echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
