#!/usr/bin/env bash
# Tests del envoltorio bin/greptile (el mismo nombre que el CLI real) y de la guarda de PR abierto de factory-greptile.
# Todo pasa por bin/greptile, con un `greptile` y un `gh` falsos que cuentan sus llamadas.
#
# AC-F1 (1) primera ejecución; (2) mismo sha → caché sin llamar al real; (3) otro sha en la misma rama → rechazo
#       (exit 3, «tope»); (4) árbol sucio → rechazo (exit 2, sin llamar al real); (5) PR abierto → rechazo (exit 3,
#       «pr_abierto», sin llamar al real); (6) otros subcomandos pasan directos con sus argumentos y rc, sin registro;
#       (7) el registro tiene una línea JSON válida por llamada con el evento correcto. Más: orden de las guardas
#       (sucio > caché > PR abierto > tope > ejecutar), `gh` que falla o no existe → ejecuta y avisa, el real del PATH
#       es el que va detrás de bin/ (sin bucle) y sin real → 127 / exit 2.
#
# Bash puro, sin red. HOME, FABRIK_GREPTILE_LOG y FABRIK_GREPTILE_CACHE temporales: nunca toca el ~/.hermes real ni gh.
# Uso: bash tests/greptile_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$FABRIK_DIR/bin/greptile"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }
igual() { # <descripción> <esperado> <obtenido>
  if [ "$2" = "$3" ]; then ok_; else fallo "$1: esperaba «$2», obtuve «$3»"; fi
}
contiene() { # <descripción> <texto> <fragmento>
  case "$2" in *"$3"*) ok_ ;; *) fallo "$1: no contiene «$3» (texto: $2)" ;; esac
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export FABRIK_GREPTILE_LOG="$tmp/log/greptile.jsonl"
export FABRIK_GREPTILE_CACHE="$tmp/cache"
mkdir -p "$HOME"
unset FX_GREPTILE_TOPE FABRIK_GREPTILE_BIN FAKE_RC FAKE_GH_PR FAKE_GH_RC
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE

# greptile real falso (directorio propio, detrás de bin/ en el PATH) y gh falso: cada llamada apunta sus argumentos.
mkdir -p "$tmp/real" "$tmp/ghbin"
cat >"$tmp/real/greptile" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CUENTA"
echo "salida falsa $(wc -l <"$FAKE_CUENTA")"
exit "${FAKE_RC:-0}"
EOF
cat >"$tmp/ghbin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_GH_CUENTA"
[ -n "${FAKE_GH_PR:-}" ] && echo "$FAKE_GH_PR"
exit "${FAKE_GH_RC:-0}"
EOF
chmod +x "$tmp/real/greptile" "$tmp/ghbin/gh"
export FAKE_CUENTA="$tmp/cuenta" FAKE_GH_CUENTA="$tmp/gh_cuenta"
: >"$FAKE_CUENTA"; : >"$FAKE_GH_CUENTA"
export FABRIK_GH="$tmp/ghbin/gh"
# El PATH de los agentes: bin/ de la fábrica el primero (con el envoltorio y factory-greptile) y el real detrás.
export PATH="$FABRIK_DIR/bin:$tmp/real:$PATH"

g() { git -c user.name=prueba -c user.email=prueba@ejemplo.invalid -c commit.gpgsign=false "$@"; }
commit() { # <fichero dentro de un repo de prueba> → un commit nuevo EN ESE repo (nunca en el cwd)
  local d; d="$(dirname "$1")"
  echo "$RANDOM$RANDOM" >>"$1"
  g -C "$d" add -A && g -C "$d" commit -q -m "cambio en $(basename "$1")"
}
nuevo_repo() { # <dir> → repo con main y la rama feature (un commit propio)
  mkdir -p "$1" && (
    cd "$1" || exit 1
    g init -q -b main .
    g remote add origin git@github.com:acme/app.git
    echo base >a.txt && g add -A && g commit -q -m base
    g checkout -q -b feature
    echo f >f.txt && g add -A && g commit -q -m feature
  )
}
cuenta() { wc -l <"$FAKE_CUENTA" | tr -d ' '; }
cuenta_gh() { wc -l <"$FAKE_GH_CUENTA" | tr -d ' '; }
lineas() { if [ -f "$FABRIK_GREPTILE_LOG" ]; then wc -l <"$FABRIK_GREPTILE_LOG" | tr -d ' '; else echo 0; fi; }
# campo <n> <clave> → valor de la línea n del registro (falla si la línea no es JSON válido)
campo() { python3 -I -c '
import json, sys
l = open(sys.argv[1]).read().splitlines()[int(sys.argv[2]) - 1]
print(json.loads(l)[sys.argv[3]])
' "$FABRIK_GREPTILE_LOG" "$1" "$2"; }
ultimo() { campo "$(lineas)" "$1"; }
reset() { : >"$FAKE_CUENTA"; : >"$FAKE_GH_CUENTA"; rm -rf "$FABRIK_GREPTILE_LOG" "$FABRIK_GREPTILE_CACHE"; unset FX_GREPTILE_TOPE FAKE_RC FAKE_GH_PR FAKE_GH_RC; }

# run <dir> args… → llama a bin/greptile (con timeout: un bucle se vería como 124) y deja RC, OUT y ERR
run() {
  local d="$1"; shift
  (cd "$d" && timeout 30 "$W" "$@") >"$tmp/run.out" 2>"$tmp/run.err"
  RC=$?
  OUT="$(cat "$tmp/run.out")"
  ERR="$(cat "$tmp/run.err")"
}
# espera <desc> <rc> <ejecuciones del real> <líneas de registro> <evento>
espera() {
  igual "$1: rc" "$2" "$RC"
  igual "$1: ejecuciones del real" "$3" "$(cuenta)"
  igual "$1: líneas de registro" "$4" "$(lineas)"
  igual "$1: evento" "$5" "$(ultimo evento 2>/dev/null)"
}
MSG_PR='ya tiene PR abierto: con PR abierto no se usa el CLI local (~1 $ por ejecución); Greptile de GitHub revisa cada push: lee sus comentarios con /check-pr y arréglalos todos en un único push por ronda'

R="$tmp/r"
nuevo_repo "$R"

# ---------- (1) primera ejecución ----------
reset
run "$R" review -b main --agent
espera "F1.1 primera ejecución" 0 1 1 ejecutado
igual "F1.1 argumentos al real (review incluido)" "review -b main --agent" "$(cat "$FAKE_CUENTA")"
igual "F1.1 salida del real" "salida falsa 1" "$OUT"
igual "F1.1 se consultó gh una vez" 1 "$(cuenta_gh)"
igual "F1.1 la consulta a gh" "pr list --head feature --state open --json number -q .[0].number" "$(cat "$FAKE_GH_CUENTA")"

# ---------- (2) mismo sha → caché sin llamar al real ni a gh ----------
run "$R" review -b main --agent
espera "F1.2 mismo sha" 0 1 2 cache
contiene "F1.2 devuelve lo guardado" "$OUT" "salida falsa 1"
igual "F1.2 sin consultar gh (la caché va antes que la guarda de PR)" 1 "$(cuenta_gh)"
# con PR abierto, el mismo diff también devuelve la caché
FAKE_GH_PR=42 run "$R" review -b main --agent
espera "F1.2b mismo sha con PR abierto" 0 1 3 cache
igual "F1.2b sigue sin consultar gh" 1 "$(cuenta_gh)"

# ---------- (3) otro sha en la misma rama → tope ----------
commit "$R/f.txt"
run "$R" review -b main --agent
espera "F1.3 otro sha" 3 1 4 tope
contiene "F1.3 mensaje de tope" "$ERR" "tope de Greptile local alcanzado (1)"
contiene "F1.3 pide permiso al humano" "$ERR" "bloquea la tarjeta y pide permiso al humano (FX_GREPTILE_TOPE)"

# ---------- (4) árbol sucio → rechazo sin llamar al real ni a gh ----------
reset
echo sucio >>"$R/f.txt"
FAKE_GH_PR=42 run "$R" review -b main --agent
espera "F1.4 árbol sucio" 2 0 1 sucio
igual "F1.4 el sucio va antes que la guarda de PR: no consulta gh" 0 "$(cuenta_gh)"
git -C "$R" checkout -q -- f.txt
echo nuevo >"$R/sin_seguimiento.txt"
run "$R" review -b main --agent
espera "F1.4b fichero sin seguimiento" 2 0 2 sucio
rm -f "$R/sin_seguimiento.txt"

# ---------- (5) PR abierto → rechazo sin llamar al real ----------
reset
FAKE_GH_PR=42 run "$R" review -b main --agent
espera "F1.5 PR abierto" 3 0 1 pr_abierto
contiene "F1.5 mensaje" "$ERR" "la rama feature $MSG_PR"
igual "F1.5 una consulta a gh" 1 "$(cuenta_gh)"
# el PR abierto va antes del tope: con una ejecución ya hecha, el evento es pr_abierto y no tope
reset
run "$R" review -b main --agent
commit "$R/f.txt"
FAKE_GH_PR=42 run "$R" review -b main --agent
espera "F1.5b PR abierto antes que tope" 3 1 2 pr_abierto
# sin PR (gh no devuelve número) y otro sha → ahora sí es tope
run "$R" review -b main --agent
espera "F1.5c sin PR, otro sha" 3 1 3 tope

# ---------- (6) otros subcomandos pasan directos, con sus argumentos y rc, sin registro ni gh ----------
reset
for args in "--version" "auth login --token x" "skills install greploop" "reviews list" ""; do
  : >"$FAKE_CUENTA"
  FAKE_RC=7 run "$R" $args
  igual "F1.6 «$args»: rc del real" 7 "$RC"
  igual "F1.6 «$args»: argumentos tal cual" "$args" "$(cat "$FAKE_CUENTA")"
  igual "F1.6 «$args»: salida del real" "salida falsa 1" "$OUT"
done
igual "F1.6 sin registro" 0 "$(lineas)"
igual "F1.6 sin consultar gh" 0 "$(cuenta_gh)"
[ ! -e "$FABRIK_GREPTILE_CACHE" ] && ok_ || fallo "F1.6 los subcomandos no crean caché"
# «review» exacto: «reviews» (otro subcomando) no entra por factory-greptile (ya cubierto arriba: sin registro)
# fuera de un repo git, un subcomando que no es review sigue funcionando
sin_repo="$tmp/sin_repo"; mkdir -p "$sin_repo"
: >"$FAKE_CUENTA"
run "$sin_repo" --version
espera "F1.6b fuera de un repo" 0 1 0 ""

# ---------- (7) el registro: una línea JSON válida por llamada, con el evento correcto ----------
reset
R7="$tmp/r7"; nuevo_repo "$R7"
run "$R7" review -b main                      # ejecutado
run "$R7" review -b main                      # cache
commit "$R7/f.txt"; run "$R7" review -b main  # tope
FAKE_GH_PR=7 run "$R7" review -b main         # pr_abierto
echo x >>"$R7/f.txt"; run "$R7" review -b main  # sucio
git -C "$R7" checkout -q -- f.txt
igual "F1.7 una línea por llamada" 5 "$(lineas)"
eventos=""
for i in 1 2 3 4 5; do eventos="$eventos $(campo "$i" evento)"; done
igual "F1.7 eventos en orden" " ejecutado cache tope pr_abierto sucio" "$eventos"
igual "F1.7 repo" "acme/app" "$(campo 4 repo)"
igual "F1.7 rama" "feature" "$(campo 4 rama)"
igual "F1.7 rc de pr_abierto" 3 "$(campo 4 rc)"
igual "F1.7 rc de sucio" 2 "$(campo 5 rc)"

# ---------- gh falla o no existe → ejecuta y avisa ----------
reset
R8="$tmp/r8"; nuevo_repo "$R8"
FAKE_GH_RC=1 FAKE_GH_PR=99 run "$R8" review -b main
espera "gh falla (rc≠0): ejecuta" 0 1 1 ejecutado
contiene "gh falla: aviso" "$ERR" "aviso: no pude consultar los PR abiertos de feature"
reset
FABRIK_GH="$tmp/no-existe/gh" run "$R8" review -b main
espera "gh no existe: ejecuta" 0 1 1 ejecutado
contiene "gh no existe: aviso" "$ERR" "aviso: no pude consultar los PR abiertos de feature"
reset
FAKE_GH_PR="no-es-un-numero" run "$R8" review -b main
espera "gh devuelve basura: no es PR, ejecuta" 0 1 1 ejecutado
# HEAD suelto: sin rama no hay guarda de PR (no consulta gh)
reset
R9="$tmp/r9"; nuevo_repo "$R9"; git -C "$R9" checkout -q --detach
FAKE_GH_PR=5 run "$R9" review -b main
espera "HEAD suelto: sin guarda de PR" 0 1 1 ejecutado
igual "HEAD suelto: no consulta gh" 0 "$(cuenta_gh)"

# ---------- el real es el del PATH detrás de bin/ (sin bucle) ----------
reset
run "$R" review -b main
igual "real tras bin/: rc (un bucle daría 124)" 0 "$RC"
igual "real tras bin/: lo ejecuta una vez" 1 "$(cuenta)"
# factory-greptile directo, con el mismo PATH
reset
(cd "$R" && timeout 30 "$FABRIK_DIR/bin/factory-greptile" -b main) >"$tmp/run.out" 2>"$tmp/run.err"
igual "factory-greptile directo salta bin/: rc" 0 "$?"
igual "factory-greptile directo salta bin/: ejecuta el real" 1 "$(cuenta)"
# un greptile ajeno delante de bin/ en el PATH manda (es el primero que no vive en bin/)
mkdir -p "$tmp/otro"; cp "$tmp/real/greptile" "$tmp/otro/greptile"
reset
PATH="$tmp/otro:$PATH" run "$R" --version
igual "el primero fuera de bin/ gana" 1 "$(cuenta)"
# FABRIK_GREPTILE_BIN manda sobre el PATH
printf '#!/usr/bin/env bash\necho "forzado $*"\n' >"$tmp/forzado"; chmod +x "$tmp/forzado"
FABRIK_GREPTILE_BIN="$tmp/forzado" run "$R" --version
igual "FABRIK_GREPTILE_BIN en subcomandos" "forzado --version" "$OUT"
# un enlace simbólico al envoltorio desde otro directorio tampoco entra en bucle
mkdir -p "$tmp/enlace"; ln -s "$W" "$tmp/enlace/greptile"
reset
PATH="$tmp/enlace:$PATH" run "$R" review -b main
igual "enlace al envoltorio: sin bucle" 0 "$RC"
igual "enlace al envoltorio: ejecuta el real" 1 "$(cuenta)"

# ídem con un enlace a factory-greptile (el envoltorio de IMPL-G) con el nombre greptile
mkdir -p "$tmp/enlace2"; ln -s "$FABRIK_DIR/bin/factory-greptile" "$tmp/enlace2/greptile"
reset
PATH="$tmp/enlace2:$PATH" run "$R" review -b main
igual "enlace a factory-greptile: sin bucle" 0 "$RC"
igual "enlace a factory-greptile: ejecuta el real" 1 "$(cuenta)"
reset
PATH="$tmp/enlace2:$PATH" run "$R" --version
igual "enlace a factory-greptile en un subcomando: sin bucle" 0 "$RC"
igual "enlace a factory-greptile en un subcomando: ejecuta el real" 1 "$(cuenta)"

# factory-greptile salta CUALQUIER greptile de su propio directorio (aunque no sea el envoltorio ni un enlace a él)
mkdir -p "$tmp/cb"
cp "$FABRIK_DIR/bin/factory-greptile" "$tmp/cb/factory-greptile"
printf '#!/usr/bin/env bash\necho "ajeno en el dir de factory-greptile" >>"$FAKE_CUENTA"\n' >"$tmp/cb/greptile"
chmod +x "$tmp/cb/greptile"
reset
(cd "$R" && PATH="$tmp/cb:$tmp/real:$PATH" timeout 30 "$tmp/cb/factory-greptile" -b main) >"$tmp/run.out" 2>"$tmp/run.err"
igual "greptile ajeno en el dir de factory-greptile: se salta" "review -b main" "$(cat "$FAKE_CUENTA")"
# ídem si es un enlace a un binario de fuera (el dir propio manda por encima del destino del enlace)
mkdir -p "$tmp/cb2"
cp "$FABRIK_DIR/bin/factory-greptile" "$tmp/cb2/factory-greptile"
printf '#!/usr/bin/env bash\necho "enlace externo" >>"$FAKE_CUENTA"\n' >"$tmp/externo"; chmod +x "$tmp/externo"
ln -s "$tmp/externo" "$tmp/cb2/greptile"
reset
(cd "$R" && PATH="$tmp/cb2:$tmp/real:$PATH" timeout 30 "$tmp/cb2/factory-greptile" -b main) >"$tmp/run.out" 2>"$tmp/run.err"
igual "enlace a un binario externo dentro del dir de factory-greptile: se salta" "review -b main" "$(cat "$FAKE_CUENTA")"

# ---------- sin real ----------
reset
sin_real="$FABRIK_DIR/bin:/usr/bin:/bin"
if PATH="$sin_real" command -v greptile >/dev/null 2>&1 && [ "$(PATH="$sin_real" command -v greptile)" != "$W" ]; then
  echo "aviso: hay un greptile real en /usr/bin o /bin: se omiten los casos «sin real»" >&2
else
  PATH="$sin_real" run "$R" --version
  igual "sin real (subcomando): 127" 127 "$RC"
  contiene "sin real (subcomando): mensaje" "$ERR" "no encuentro el binario real"
  PATH="$sin_real" run "$R" review -b main
  igual "sin real (review): exit 2" 2 "$RC"
  igual "sin real (review): sin registro" 0 "$(lineas)"
fi

echo "greptile_test: $ok ok / $fail fallos"
[ "$fail" -eq 0 ]
