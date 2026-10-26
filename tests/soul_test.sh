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

# ---------- costes-revision: revisión proporcional, auto-chequeo ampliado y Greptile acotado ----------
orq_soul="$HOME/.hermes/profiles/orquestador/SOUL.md"
revisor_soul="$HOME/.hermes/profiles/revisor/SOUL.md"
C0="$FABRIK_DIR/docs/flows/C0-ciclo-tarjeta-codigo.md"
LISTA_COMPLETA='lógica de dominio o backend (PHP, Python, bash o JS con decisiones), seguridad y auth, pagos y facturación, migraciones y BD, tenancy y RBAC, contratos de API, despliegue y config de producción, y cualquier tarjeta M o L'
tiene() { # $1 fichero, $2 frase literal, $3 mensaje de fallo
  if [ -s "$1" ] && grep -qF -- "$2" "$1"; then bien; else fallo "$3"; fi
}
no_tiene() { # $1 fichero, $2 frase literal, $3 mensaje de fallo
  if [ -s "$1" ] && ! grep -qF -- "$2" "$1"; then bien; else fallo "$3"; fi
}

# AC-1: revisión proporcional (C0 + tester + programador + orquestador)
tiene "$C0" '## Revisión proporcional' "AC-1 C0: falta la sección «Revisión proporcional»"
tiene "$C0" '`Revisión: ligera` o `Revisión: completa`' "AC-1 C0: falta la línea Revisión: ligera|completa"
tiene "$C0" '**Sin marca = completa.**' "AC-1 C0: falta «sin marca = completa»"
tiene "$C0" '**3 semillas** aleatorias' "AC-1 C0: la ligera debe pedir 3 semillas"
tiene "$C0" '**No se hace**: mutantes ni umbral de cobertura del 98 %' "AC-1 C0: la ligera no debe pedir mutantes ni 98 %"
tiene "$C0" "**Siempre llevan la completa** (aunque vengan marcadas ligera): $LISTA_COMPLETA" "AC-1 C0: falta la lista de tipos que siempre llevan la completa"
tiene "$C0" '**escala a completa** y lo anota en `findings`, sin `kanban_request_changes` solo por eso' "AC-1 C0: falta el escalado del tester"
tiene "$C0" 'aplica «Revisión proporcional»' "AC-1 C0: la tabla de tarjetas no remite a «Revisión proporcional» en la fila del tester"
tiene "$C0" 'Primero lee la línea `Revisión:` de la tarjeta' "AC-1 C0: el checklist del tester no remite a la línea Revisión"
tiene "$C0" 'metadata = {revision, flake_runs' "AC-1 C0: el veredicto del tester no lleva metadata.revision"
tiene "$C0" 'Para ver si funciona: `fabrik-cupos semana`' "AC-1 C0: falta la línea D4 «Para ver si funciona: fabrik-cupos semana»"
for rol in tester programador orquestador; do
  s="$HOME/.hermes/profiles/$rol/SOUL.md"
  tiene "$s" 'Revisión: ligera' "AC-1 $rol: el SOUL no menciona la línea Revisión: ligera"
  tiene "$s" 'Revisión: completa' "AC-1 $rol: el SOUL no menciona la línea Revisión: completa"
  tiene "$s" 'cualquier tarjeta M o L' "AC-1 $rol: el SOUL no cierra la lista de tipos siempre completa"
done
tiene "$HOME/.hermes/profiles/tester/SOUL.md" "**Siempre completa**: $LISTA_COMPLETA" "AC-1 tester: falta la lista de tipos siempre completa"
tiene "$prog_soul" "**Siempre completa**: $LISTA_COMPLETA" "AC-1 programador: falta la lista de tipos siempre completa"
tiene "$orq_soul" "**Siempre \`Revisión: completa\`**: $LISTA_COMPLETA" "AC-1 orquestador: falta la lista de tipos siempre completa"
tiene "$HOME/.hermes/profiles/tester/SOUL.md" '**3 semillas** aleatorias' "AC-1 tester: la ligera debe pedir 3 semillas"
tiene "$HOME/.hermes/profiles/tester/SOUL.md" '**Sin mutantes ni umbral de cobertura del 98 %**' "AC-1 tester: la ligera no debe pedir mutantes ni 98 %"
tiene "$HOME/.hermes/profiles/tester/SOUL.md" '**escala a completa** y anótalo en `findings`, sin `kanban_request_changes` solo por eso' "AC-1 tester: falta el escalado a completa"
tiene "$HOME/.hermes/profiles/tester/SOUL.md" 'Pon `metadata.revision = "ligera"` o `"completa"` en tu veredicto' "AC-1 tester: falta metadata.revision"
tiene "$prog_soul" 'sin mutantes ni umbral del 98 %' "AC-1 programador: la ligera no debe pedir mutantes ni 98 %"
tiene "$orq_soul" '## Marca de revisión en cada IMPL/FIX (obligatoria)' "AC-1 orquestador: no obliga a marcar Revisión en cada IMPL/FIX"
tiene "$orq_soul" 'Si dudas entre las dos, marca `completa`.' "AC-1 orquestador: falta el desempate hacia completa"
tiene "$orq_soul" 'y la línea `Revisión:`' "AC-1 orquestador: el plan de tarjetas no incluye la línea Revisión"

# AC-2: auto-chequeo ampliado del programador (D2 a, b, c) + porqué
tiene "$prog_soul" '**(a) Mutar condiciones, constantes y límites**' "AC-2 programador: falta (a) mutar condiciones, constantes y límites"
tiene "$prog_soul" 'justo en el límite (p. ej. 97/98/99 para un umbral de 98) y de null/ausente' "AC-2 programador: (a) sin casos límite ni null"
tiene "$prog_soul" '**(b) Ramas de error y de null**' "AC-2 programador: falta (b) ramas de error y de null"
tiene "$prog_soul" '`catch`/`except`/`||`/`??`/fallo de un comando externo' "AC-2 programador: (b) sin el inventario de ramas"
tiene "$prog_soul" '**(c) Handoff verificable**' "AC-2 programador: falta (c) handoff verificable"
tiene "$prog_soul" '`metadata.commit` = `git rev-parse HEAD`' "AC-2 programador: (c) sin commit verificable"
tiene "$prog_soul" 'relanzado **después del último commit**' "AC-2 programador: (c) sin relanzar tras el último commit"
tiene "$prog_soul" 'tests que no protegen, ramas de error sin cubrir y handoff no verificable' "AC-2 programador: falta el porqué del auto-chequeo"
tiene "$C0" '(a) cada condición, constante y valor límite del diff mutada' "AC-2 C0: la fila IMPL no lleva (a)"
tiene "$C0" '(b) inventario de ramas de error y de null con su test' "AC-2 C0: la fila IMPL no lleva (b)"
tiene "$C0" '(c) handoff verificable' "AC-2 C0: la fila IMPL no lleva (c)"
tiene "$C0" 'tests que no protegen, ramas de error sin cubrir y handoff no verificable' "AC-2 C0: la fila IMPL no lleva el porqué"

# AC-5: Greptile acotado (solo factory-greptile, una vez; rondas del PR con el de GitHub)
tiene "$C0" 'solo con `factory-greptile -b <base> [--agent …]`' "AC-5 C0: falta «solo con factory-greptile»"
tiene "$C0" '**con los tests ya en verde y tras `/code-review`**' "AC-5 C0: falta tests en verde y tras /code-review"
tiene "$C0" '**no** se pasa el CLI local entre pushes' "AC-5 C0: falta la regla de no CLI local entre pushes"
tiene "$C0" '**sin pasar el CLI local entre pushes**' "AC-5 C0: la fila PR no prohíbe el CLI local entre pushes"
for f in "$prog_soul" "$revisor_soul" "$orq_soul"; do
  no_tiene "$f" 'greptile review' "AC-5 ${f##*/}: queda una instrucción «greptile review» directa"
done
# C0 es el único sitio que explica que `greptile review` pasa por el envoltorio y equivale a factory-greptile
tiene "$C0" '`greptile review …` equivale a `factory-greptile …`' "AC-5 C0: falta la equivalencia greptile review = factory-greptile"
for f in "$C0" "$prog_soul" "$revisor_soul" "$orq_soul"; do
  no_tiene "$f" 'pasando antes' "AC-5 ${f##*/}: queda «pasando antes» el CLI local"
  no_tiene "$f" 'Greptile CLI local' "AC-5 ${f##*/}: queda «Greptile CLI local»"
done
tiene "$prog_soul" 'Greptile local **una sola vez** con `factory-greptile -b develop --agent`' "AC-5 programador: CIERRE-LOCAL sin factory-greptile una sola vez"
tiene "$prog_soul" 'con los tests ya en verde y tras `/code-review`' "AC-5 programador: CIERRE-LOCAL sin tests en verde ni /code-review"
tiene "$prog_soul" 'nunca se lanza el binario `greptile` directamente' "AC-5 programador: falta prohibir el binario directo"
tiene "$prog_soul" 'cada ronda la comprueba el Greptile de GitHub (ya se ejecuta en cada push), **sin pasar el CLI local entre pushes**' "AC-5 programador: PR sin rondas con el Greptile de GitHub"
tiene "$revisor_soul" 'solo se lanza con `factory-greptile`, una vez por rama, con los tests en verde y tras `/code-review`' "AC-5 revisor: falta Greptile solo con factory-greptile y una vez"
tiene "$revisor_soul" 'sin CLI local entre pushes' "AC-5 revisor: faltan las rondas del PR con el Greptile de GitHub"
tiene "$orq_soul" 'Greptile 5/5 (el de GitHub, no el CLI local)' "AC-5 orquestador: «Cierre de feature» sin Greptile 5/5 de GitHub"
tiene "$orq_soul" 'Greptile local una sola vez con `factory-greptile` (el 5/5 es el Greptile de GitHub, en el PR)' "AC-5 orquestador: CIERRE-LOCAL sin factory-greptile ni 5/5 de GitHub"

# AC-F3: Greptile local UNA vez al final de CIERRE-LOCAL (tras /code-review) y, con PR, sin CLI local y un push por ronda
no_regex() { # $1 fichero, $2 expresión (grep -E), $3 mensaje de fallo
  if [ -s "$1" ] && ! grep -qE -- "$2" "$1"; then bien; else fallo "$3"; fi
}
antes() { # $1 fichero, $2 frase A, $3 frase B, $4 mensaje: en alguna línea, A aparece antes que B
  if [ -s "$1" ] && awk -v a="$2" -v b="$3" '{ i = index($0, a); j = index($0, b); if (i > 0 && j > 0 && i < j) ok = 1 } END { exit !ok }' "$1"; then bien; else fallo "$4"; fi
}
for f in "$C0" "$prog_soul" "$revisor_soul" "$orq_soul"; do
  n="${f##*/}"
  no_tiene "$f" 'repitiendo' "AC-F3 $n: queda «repitiendo»"
  no_regex "$f" 'cada ronda[^.]*Greptile CLI local' "AC-F3 $n: queda «cada ronda … Greptile CLI local»"
  no_regex "$f" 'pasando antes[^.]*Greptile CLI local' "AC-F3 $n: queda «pasando antes Greptile CLI local»"
  no_regex "$f" 'hasta (que )?no haya hallazgos|hasta sin hallazgos' "AC-F3 $n: queda «arreglar hasta sin hallazgos»"
done
antes "$C0" '`/code-review` sobre el diff completo contra el merge-base; todo commiteado y en verde → Greptile local **una sola vez**' 'sin volver a pasarlo' "AC-F3 C0 tabla: CIERRE-LOCAL no pasa Greptile local una vez tras /code-review y sin repetirlo"
tiene "$C0" 'todo commiteado y en verde → Greptile local **una sola vez** con **`factory-greptile -b develop --agent`**' "AC-F3 C0 tabla: falta el orden commiteado y en verde → Greptile una vez"
tiene "$C0" 'arreglar lo accionable **sin volver a pasarlo**' "AC-F3 C0 tabla: falta «sin volver a pasarlo»"
tiene "$C0" '**sin CLI local**: Greptile revisa solo en GitHub y `/check-pr` lee sus comentarios' "AC-F3 C0 tabla: la fila PR no dice «sin CLI local» y /check-pr"
tiene "$C0" 'todos en **un push por ronda**' "AC-F3 C0 tabla: la fila PR no pide un push por ronda"
tiene "$C0" '**Con el PR abierto no se usa el CLI local**' "AC-F3 C0: falta la regla de PR abierto"
tiene "$C0" '`bin/greptile`' "AC-F3 C0: falta el envoltorio bin/greptile"
antes "$prog_soul" '`/code-review` sobre el diff completo contra el merge-base · arreglos · todo commiteado y en verde → Greptile local **una sola vez**' 'sin volver a pasarlo' "AC-F3 programador: CIERRE-LOCAL no deja Greptile local tras /code-review, una vez y sin repetir"
tiene "$prog_soul" 'con `factory-greptile -b develop --agent`' "AC-F3 programador: CIERRE-LOCAL no nombra factory-greptile -b develop --agent"
tiene "$prog_soul" '→ arregla lo accionable **sin volver a pasarlo**' "AC-F3 programador: falta «sin volver a pasarlo»"
tiene "$prog_soul" '**sin CLI local**: Greptile revisa en GitHub y lees sus comentarios con `/check-pr`' "AC-F3 programador: el PR no dice «sin CLI local» y /check-pr"
tiene "$prog_soul" 'todos en un push por ronda' "AC-F3 programador: el PR no pide un push por ronda"
tiene "$revisor_soul" 'Con el PR abierto no hay CLI local' "AC-F3 revisor: falta «con el PR abierto no hay CLI local»"

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
