#!/usr/bin/env bash
# Tests de bin/factory-test: turno único con prioridad por repo.
#
# AC-1  Uno con prioridad adelanta a uno sin prioridad que ya esperaba (prioridad por el fichero
#       $FABRIK_DATA/locks/prioridad comparado con `git rev-parse --show-toplevel`). Mientras espera se
#       apunta en locks/prio.d/<pid>; `factory-test estado` lo muestra; al coger el turno se borra.
# AC-2  Sin prioridad el comportamiento no cambia: espera al que tiene el turno, devuelve el código del
#       comando y no se apunta en prio.d. FX_TEST_PRIO=1 fuerza la prioridad.
# AC-3  Un pid muerto (o reutilizado por otro proceso) en prio.d no bloquea y se limpia.
# AC-4  Se respeta FX_TEST_WAIT en total, también cediendo el turno a un prioritario y esperando con
#       prioridad (que además se borra de prio.d al rendirse).
# AC-5  Editar el script en caliente (mismo inodo) no rompe a quien lo está ejecutando.
#
# Ligeros (sin turno, máx. FX_TEST_LIGEROS a la vez en locks/ligeros.d/):
# AC-L1 Con el turno ocupado por un pesado, `factory-test -- bash <script>` arranca y termina enseguida y
#       devuelve el rc del script; no toca factory-test.owner ni prio.d.
# AC-L2 Con el turno ocupado, un pesado (phpunit, paratest, php artisan test, phpunit-replay, bash -c "…artisan test",
#       npm, composer) sigue esperando como hoy. (Los AC-1..5 de la prioridad siguen en verde.)
# AC-L3 Con FX_TEST_LIGEROS=2 y dos ligeros en marcha, el tercero espera hasta que uno suelta; con FX_TEST_WAIT
#       corto se rinde con rc 75.
# AC-L4 FX_TEST_PESADO=1 hace cola aunque sea bash; FX_TEST_LIGERO=1 salta la cola aunque sea phpunit; con los dos, cola.
# AC-L5 `estado` muestra el titular pesado primero y una línea `ligero: …` por cada ligero en marcha; un .owner sin
#       flock vivo no aparece.
# AC-L6 Clasificación (tabla de ejemplos ligero/pesado de es_ligero).
# AC-L7 Sin argumentos imprime la ayuda de la cabecera completa y devuelve 2.
#
# Tres clases (ligero / dirigido / pesado), repos pesados por config y lock por BD efectiva:
# AC-T1 Con el turno ocupado, en un repo pesado, un dirigido (phpunit <ruta>, artisan test --filter, pest --group)
#       arranca y termina sin esperar y no toca factory-test.owner ni prio.d.
# AC-T2 Con el turno ocupado, en un repo pesado, esperan turno (rc 75): suite sin selector, paralelo, paratest,
#       infection, dusk, bash -c, composer.
# AC-T3 En un repo no pesado todo es dirigido; sin lista, todos pesados; FX_TEST_REPOS_PESADOS="" = ninguno; la env
#       manda sobre la config; FX_REPO de .factory/env manda sobre el basename.
# AC-T4 Replay: dry-run limpio → dirigido; con cambio estructural, rc≠0, timeout o sin baseline → pesado;
#       `run --fresh`, `record` → pesado sin llamar al dry-run.
# AC-T5 Huecos dirigidos (FX_TEST_DIRIGIDOS / tests.dirigidos): el siguiente espera; rc 75 al agotar FX_TEST_WAIT.
# AC-T6 Lock por BD efectiva (DB_HOST:DB_PORT/DB_DATABASE, o el toplevel sin .factory/env).
# AC-T7 `estado`: pesado, `dirigido: … bd=…`, `ligero: …`, en ese orden; un .owner sin flock vivo no aparece.
# AC-T8 Tabla de clasificación de clase_de.
#
# TEST_TOKEN de ParallelTesting para repos con BD de tests fija (tests.repos_token / FX_TEST_REPOS_TOKEN):
# AC-K1 Repo de la lista, dos dirigidos a la vez desde dos worktrees con el mismo DB_DATABASE: tokens distintos (≥100),
#       claves de BD distintas, y van a la vez (ninguno espera BD).
# AC-K2 Repo fuera de la lista: ni TEST_TOKEN ni LARAVEL_PARALLEL_TESTING; un TEST_TOKEN del que llama no se toca.
# AC-K3 Pesado o paralelo en un repo de la lista: sin token y lock sobre la BD base; un dirigido con token no lo espera.
# AC-K4 `estado` y el mensaje de arranque muestran la BD con token.
# AC-K5 Sin lista (clave ausente, lista vacía en la env o uv falla): nada de token.
#
# Los comandos de estos tests son `bash -c …`, que por la clasificación serían ligeros: se fuerza FX_TEST_PESADO=1 en
# todo el fichero (los titulares y esperas de AC-1..5 son pesados) y los casos AC-L lo quitan donde toca.
#
# Bash puro, sin red. HOME y FABRIK_DATA temporales: nunca toca el turno real de la máquina.
# Las esperas son por condición con límite (nada de esperas fijas). Uso: bash tests/factory_test_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FT="$FABRIK_DIR/bin/factory-test"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
pids_fondo=()
limpiar() {
  local p
  for p in "${pids_fondo[@]}"; do kill "$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap limpiar EXIT

export HOME="$tmp/home"
export FABRIK_DATA="$tmp/data"
mkdir -p "$HOME" "$FABRIK_DATA"
unset TEST_TOKEN LARAVEL_PARALLEL_TESTING FX_TEST_REPOS_TOKEN FAKE_ENVLOG FX_TEST_PRIO FX_TEST_WAIT FX_TEST_TIMEOUT FX_TEST_PAUSA FX_TEST_LIGERO FX_TEST_LIGEROS FX_TEST_DRYRUN_TIMEOUT HERMES_PROFILE
# Los tests nunca leen la config real del usuario: lista de repos pesados por env y FABRIK_CONFIG a un yaml de mentira.
export FX_TEST_REPOS_PESADOS="otro fabrik-prio-x pesado"
export FX_TEST_DIRIGIDOS=4
export FABRIK_CONFIG="$tmp/fabrik-vacio.yaml"; printf 'idioma: es\n' > "$FABRIK_CONFIG"
export FX_TEST_PESADO=1     # ver cabecera: los AC-L lo quitan donde hace falta
export FX_TEST_TIMEOUT=60   # ningún comando de los tests puede colgarse más de esto
export FX_TEST_PAUSA=0.3    # pausa al ceder el turno (2 s por defecto)
LOCKS="$FABRIK_DATA/locks"
PRIOD="$LOCKS/prio.d"

# repos de prueba: el que tiene prioridad y otro cualquiera
mkdir -p "$tmp/repos/fabrik-prio-x/sub" "$tmp/repos/otro"
git -C "$tmp/repos/fabrik-prio-x" init -q
git -C "$tmp/repos/otro" init -q

# espera hasta que se cumpla <condición> (máx. 15 s); 1 si no llega
hasta() {
  local i
  for ((i = 0; i < 300; i++)); do
    eval "$1" && return 0
    sleep 0.05
  done
  return 1
}

# un "titular" que coge el turno y lo mantiene hasta que se escriba en su fifo
n_titular=0
titular() { # <dir> → deja TIT_PID, TIT_FIFO, TIT_OUT
  n_titular=$((n_titular + 1))
  TIT_FIFO="$tmp/fifo$n_titular"; TIT_OUT="$tmp/titular$n_titular.out"
  mkfifo "$TIT_FIFO"
  (cd "$1" && exec bash "$FT" -- bash -c 'touch "$2"; read -r _ < "$1"' _ "$TIT_FIFO" "$tmp/titular$n_titular.dentro") \
    > "$TIT_OUT" 2>&1 &
  TIT_PID=$!; pids_fondo+=("$TIT_PID")
  hasta "[ -e '$tmp/titular$n_titular.dentro' ]" || fallo "el titular $n_titular no cogió el turno"
}
soltar() { echo > "$TIT_FIFO"; wait "$TIT_PID" 2>/dev/null; }

# ---------- AC-1: con prioridad adelanta al que ya esperaba ----------
printf '# repos con prioridad\n\n  fabrik-prio-x  \n' > "$FABRIK_DATA/prioridad.tmp"
mkdir -p "$LOCKS"; mv "$FABRIK_DATA/prioridad.tmp" "$LOCKS/prioridad"
orden="$tmp/orden"; : > "$orden"

titular "$tmp/repos/otro"
(cd "$tmp/repos/otro" && exec bash "$FT" -- bash -c 'echo B >> "$1"' _ "$orden") > "$tmp/b.out" 2>&1 &
B=$!; pids_fondo+=("$B")
hasta "grep -q 'esperando turno' '$tmp/b.out'" || fallo "AC-1 B no llegó a esperar"
(cd "$tmp/repos/fabrik-prio-x/sub" && exec bash "$FT" -- bash -c 'echo C >> "$1"' _ "$orden") > "$tmp/c.out" 2>&1 &
C=$!; pids_fondo+=("$C")
if hasta "[ -f '$PRIOD/$C' ]"; then ok_; else fallo "AC-1 C (con prioridad) no se apuntó en prio.d/$C"; fi
if [ -e "$PRIOD/$B" ]; then fallo "AC-1 B (sin prioridad) no debe apuntarse en prio.d"; else ok_; fi
hasta "grep -q 'esperando turno' '$tmp/c.out'" || fallo "AC-1 C no llegó a esperar"
if grep -q 'con prioridad' "$tmp/c.out"; then ok_; else fallo "AC-1 la espera de C no dice que va con prioridad"; fi

# estado: quién tiene el turno y quién está en cola con prioridad
est="$(bash "$FT" estado)"
if printf '%s\n' "$est" | grep -q '^ocupado:'; then ok_; else fallo "AC-1 estado no dice ocupado: $est"; fi
if printf '%s\n' "$est" | grep -q "con prioridad.*pid=$C"; then ok_; else fallo "AC-1 estado no muestra la cola con prioridad (pid=$C): $est"; fi

soltar
wait "$B" "$C"
if [ "$(tr '\n' ' ' < "$orden")" = "C B " ]; then ok_; else fallo "AC-1 orden esperado «C B», salió «$(tr '\n' ' ' < "$orden")»"; fi
if [ -z "$(ls -A "$PRIOD" 2>/dev/null)" ]; then ok_; else fallo "AC-1 prio.d no quedó vacío: $(ls -A "$PRIOD")"; fi
if [ "$(bash "$FT" estado)" = "libre" ]; then ok_; else fallo "AC-1 estado tras terminar: $(bash "$FT" estado)"; fi

# ---------- AC-2: sin prioridad, nada cambia ----------
rm -f "$LOCKS/prioridad"
: > "$orden"
titular "$tmp/repos/fabrik-prio-x"
(cd "$tmp/repos/fabrik-prio-x" && exec bash "$FT" -- bash -c 'echo D >> "$1"; exit 3' _ "$orden") > "$tmp/d.out" 2>&1 &
D=$!; pids_fondo+=("$D")
hasta "grep -q 'esperando turno' '$tmp/d.out'" || fallo "AC-2 D no llegó a esperar"
if [ -s "$orden" ]; then fallo "AC-2 D se ejecutó sin tener el turno"; else ok_; fi
if [ -e "$PRIOD/$D" ]; then fallo "AC-2 sin fichero de prioridad no se apunta en prio.d"; else ok_; fi
if grep -q 'con prioridad' "$tmp/d.out"; then fallo "AC-2 D no tiene prioridad y dice que sí"; else ok_; fi
soltar
wait "$D"; rc=$?
if [ "$rc" -eq 3 ]; then ok_; else fallo "AC-2 debe devolver el código del comando (3), devolvió $rc"; fi
if grep -q '── factory-test: rc=3' "$tmp/d.out"; then ok_; else fallo "AC-2 falta el resumen final"; fi
if grep -q 'cedo' "$tmp/d.out"; then fallo "AC-2 sin prioritarios en cola no debe ceder"; else ok_; fi
if [ "$(cat "$orden")" = "D" ]; then ok_; else fallo "AC-2 D no se ejecutó una vez"; fi

# FX_TEST_PRIO=1 fuerza la prioridad (sin fichero)
titular "$tmp/repos/otro"
(cd "$tmp/repos/otro" && FX_TEST_PRIO=1 exec bash "$FT" -- true) > "$tmp/e.out" 2>&1 &
E=$!; pids_fondo+=("$E")
if hasta "[ -f '$PRIOD/$E' ]"; then ok_; else fallo "AC-2 FX_TEST_PRIO=1 no se apuntó en prio.d"; fi
soltar; wait "$E"
if [ ! -e "$PRIOD/$E" ]; then ok_; else fallo "AC-2 FX_TEST_PRIO=1 no se borró de prio.d al coger el turno"; fi

# ---------- AC-3: pids muertos o reutilizados en prio.d no bloquean ----------
mkdir -p "$PRIOD"
true & muerto=$!; wait "$muerto"
printf 'inicio=1\nfalso pid=%s\n' "$muerto" > "$PRIOD/$muerto"
printf 'sin línea de inicio\n' > "$PRIOD/999999999"
printf 'inicio=1\nreutilizado pid=%s\n' "$$" > "$PRIOD/$$"    # pid vivo, pero no es quien se apuntó
printf 'basura\n' > "$PRIOD/no-es-un-pid"
: > "$orden"
(cd "$tmp/repos/otro" && FX_TEST_WAIT=5 exec bash "$FT" -- bash -c 'echo F >> "$1"' _ "$orden") > "$tmp/f.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$orden")" = "F" ]; then ok_; else fallo "AC-3 pids muertos bloquearon (rc=$rc): $(cat "$tmp/f.out")"; fi
if grep -q 'cedo' "$tmp/f.out"; then fallo "AC-3 cedió el turno a un pid muerto"; else ok_; fi
for f in "$muerto" 999999999 "$$" no-es-un-pid; do
  if [ -e "$PRIOD/$f" ]; then fallo "AC-3 no se limpió prio.d/$f"; else ok_; fi
done

# ---------- AC-4: límite de espera ----------
# (a) sin prioridad, con un prioritario vivo en cola y el turno libre: cede hasta agotar FX_TEST_WAIT
sleep 300 & falso=$!; pids_fondo+=("$falso")
# shellcheck disable=SC2086  # se parte /proc/<pid>/stat en campos a propósito
ini="$(s="$(cat "/proc/$falso/stat")"; s="${s##*) }"; set -- $s; echo "${20}")"
printf 'inicio=%s\nprioritario de prueba pid=%s\n' "$ini" "$falso" > "$PRIOD/$falso"
: > "$orden"
t0=$SECONDS
(cd "$tmp/repos/otro" && FX_TEST_WAIT=2 exec bash "$FT" -- bash -c 'echo G >> "$1"' _ "$orden") > "$tmp/g.out" 2>&1
rc=$?; dur=$((SECONDS - t0))
if [ "$rc" -eq 75 ]; then ok_; else fallo "AC-4a debe rendirse con 75, devolvió $rc: $(cat "$tmp/g.out")"; fi
if [ ! -s "$orden" ]; then ok_; else fallo "AC-4a ejecutó el comando con un prioritario en cola"; fi
if [ "$dur" -ge 1 ] && [ "$dur" -le 6 ]; then ok_; else fallo "AC-4a esperó ${dur}s con FX_TEST_WAIT=2"; fi
if grep -q 'cedo el turno' "$tmp/g.out"; then ok_; else fallo "AC-4a no avisa de que cede el turno"; fi
if [ -e "$PRIOD/$falso" ]; then ok_; else fallo "AC-4a borró la entrada de un prioritario vivo"; fi
kill "$falso"; wait "$falso" 2>/dev/null
(cd "$tmp/repos/otro" && FX_TEST_WAIT=5 exec bash "$FT" -- bash -c 'echo G >> "$1"' _ "$orden") > "$tmp/g2.out" 2>&1
if [ "$(cat "$orden")" = "G" ] && [ ! -e "$PRIOD/$falso" ]; then ok_; else fallo "AC-4a muerto el prioritario, no corrió o no limpió"; fi

# (b) con prioridad y el turno ocupado: se rinde a tiempo y se borra de prio.d
titular "$tmp/repos/otro"
t0=$SECONDS
(cd "$tmp/repos/otro" && FX_TEST_PRIO=1 FX_TEST_WAIT=1 exec bash "$FT" -- true) > "$tmp/h.out" 2>&1
rc=$?; dur=$((SECONDS - t0))
if [ "$rc" -eq 75 ] && [ "$dur" -le 4 ]; then ok_; else fallo "AC-4b rc=$rc en ${dur}s (esperado 75, ≤ 4 s)"; fi
if [ -z "$(ls -A "$PRIOD" 2>/dev/null)" ]; then ok_; else fallo "AC-4b quedó en prio.d tras rendirse: $(ls -A "$PRIOD")"; fi
soltar

# ---------- AC-5: editar el script en caliente no rompe al que lo ejecuta ----------
mkdir -p "$tmp/bin"
cp "$FT" "$tmp/bin/factory-test"
fifo="$tmp/fifo-caliente"; mkfifo "$fifo"
(cd "$tmp/repos/otro" && exec bash "$tmp/bin/factory-test" -- bash -c 'touch "$2"; read -r _ < "$1"; echo hecho' _ "$fifo" "$tmp/caliente.dentro") \
  > "$tmp/caliente.out" 2>&1 &
K=$!; pids_fondo+=("$K")
hasta "[ -e '$tmp/caliente.dentro' ]" || fallo "AC-5 la copia no arrancó el comando"
# reescritura en el mismo inodo (como un editor que guarda encima): todo el fichero pasa a ser «exit 42»
tam=$(wc -c < "$tmp/bin/factory-test")
yes 'exit 42' | head -c $((tam * 2)) > "$tmp/bin/factory-test"
echo > "$fifo"
wait "$K"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '── factory-test: rc=0' "$tmp/caliente.out"; then ok_; else fallo "AC-5 la edición en caliente rompió la ejecución (rc=$rc)"; fi

# ============================ Ligeros ============================
LIGD="$LOCKS/ligeros.d"
mkdir -p "$tmp/fakebin"
export FAKELOG="$tmp/fake.log"; : > "$FAKELOG"
for f in phpunit paratest php phpunit-replay npm composer artisan pest infection dusk; do
  cat > "$tmp/fakebin/$f" <<'FAKE'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$FAKELOG"
[ -n "${FAKE_ENVLOG:-}" ] && echo "token=${TEST_TOKEN-<sin>} par=${LARAVEL_PARALLEL_TESTING-<sin>}" >> "$FAKE_ENVLOG"
[ -n "${FAKE_DENTRO:-}" ] && touch "$FAKE_DENTRO"
[ -n "${FAKE_FIFO:-}" ] && read -r _ < "$FAKE_FIFO"
exit 0
FAKE
  chmod +x "$tmp/fakebin/$f"
done
printf '#!/usr/bin/env bash\nexit 7\n' > "$tmp/ligero-rc7.sh"
cat > "$tmp/ligero-marca.sh" <<'MARCA'
#!/usr/bin/env bash
echo L >> "$1"
MARCA

# un ligero «titular»: ocupa un hueco hasta que se escriba en su fifo (FX_TEST_PESADO fuera, FX_TEST_LIGEROS heredado)
n_lig=0
ligero_titular() { # → deja LIG_PID, LIG_FIFO
  n_lig=$((n_lig + 1))
  LIG_FIFO="$tmp/lfifo$n_lig"; mkfifo "$LIG_FIFO"
  (cd "$tmp/repos/otro" && unset FX_TEST_PESADO && exec bash "$FT" -- bash -c 'touch "$2"; read -r _ < "$1"' _ "$LIG_FIFO" "$tmp/lig$n_lig.dentro") \
    > "$tmp/lig$n_lig.out" 2>&1 &
  LIG_PID=$!; pids_fondo+=("$LIG_PID")
  hasta "[ -e '$tmp/lig$n_lig.dentro' ]" || fallo "el ligero titular $n_lig no arrancó"
}
soltar_ligero() { echo > "$1"; wait "$2" 2>/dev/null; }

# ---------- AC-L1: con el turno ocupado, un ligero no espera ----------
titular "$tmp/repos/otro"
owner_antes="$(cat "$LOCKS/factory-test.owner")"
t0=$SECONDS
(cd "$tmp/repos/otro" && unset FX_TEST_PESADO && FX_TEST_WAIT=20 FX_TEST_PRIO=1 exec bash "$FT" -- bash "$tmp/ligero-rc7.sh") > "$tmp/l1.out" 2>&1
rc=$?; dur=$((SECONDS - t0))
if [ "$rc" -eq 7 ]; then ok_; else fallo "AC-L1 debe devolver el rc del script (7), devolvió $rc: $(cat "$tmp/l1.out")"; fi
if [ "$dur" -le 5 ]; then ok_; else fallo "AC-L1 tardó ${dur}s con el turno ocupado"; fi
if grep -q '⚡ ligero (sin turno de suites)' "$tmp/l1.out"; then ok_; else fallo "AC-L1 falta el aviso de ligero"; fi
if grep -q 'esperando turno' "$tmp/l1.out"; then fallo "AC-L1 el ligero esperó turno"; else ok_; fi
if grep -q '── factory-test: rc=7' "$tmp/l1.out"; then ok_; else fallo "AC-L1 falta el resumen final"; fi
if [ "$(cat "$LOCKS/factory-test.owner")" = "$owner_antes" ]; then ok_; else fallo "AC-L1 el ligero tocó factory-test.owner"; fi
if [ -z "$(ls -A "$PRIOD" 2>/dev/null)" ]; then ok_; else fallo "AC-L1 el ligero (con FX_TEST_PRIO=1) tocó prio.d: $(ls -A "$PRIOD")"; fi
if [ -z "$(tr -d '[:space:]' < "$LIGD/1.owner")" ]; then ok_; else fallo "AC-L1 el .owner del hueco no se vació al salir"; fi
soltar

# ---------- AC-L2: con el turno ocupado, los pesados siguen esperando ----------
titular "$tmp/repos/otro"
pesado_espera() { # <palabras del comando…>: debe esperar turno y rendirse con 75 sin ejecutar nada
  : > "$FAKELOG"
  (cd "$tmp/repos/otro" && unset FX_TEST_PESADO && PATH="$tmp/fakebin:$PATH" FX_TEST_WAIT=1 exec bash "$FT" -- "$@") > "$tmp/l2.out" 2>&1
  local rc=$?
  if [ "$rc" -eq 75 ] && grep -q 'esperando turno' "$tmp/l2.out" && [ ! -s "$FAKELOG" ]; then ok_
  else fallo "AC-L2 «$*» no esperó como pesado (rc=$rc, fake: $(cat "$FAKELOG")): $(cat "$tmp/l2.out")"; fi
}
pesado_espera phpunit
pesado_espera vendor/bin/phpunit --filter X -p 8
pesado_espera paratest
pesado_espera php artisan test
pesado_espera phpunit-replay run --fresh
pesado_espera bash -c 'echo ok; php artisan test'
pesado_espera bash -c 'artisan test'
pesado_espera npm test
pesado_espera composer test
soltar

# ---------- AC-L3: límite de ligeros a la vez ----------
export FX_TEST_LIGEROS=2
ligero_titular; L1P=$LIG_PID; L1F=$LIG_FIFO
ligero_titular; L2P=$LIG_PID; L2F=$LIG_FIFO
: > "$orden"
# (a) con el límite alcanzado y FX_TEST_WAIT corto: se rinde con 75 sin ejecutar
t0=$SECONDS
(cd "$tmp/repos/otro" && unset FX_TEST_PESADO && FX_TEST_WAIT=1 exec bash "$FT" -- bash "$tmp/ligero-marca.sh" "$orden") > "$tmp/l3a.out" 2>&1
rc=$?; dur=$((SECONDS - t0))
if [ "$rc" -eq 75 ] && [ "$dur" -le 5 ]; then ok_; else fallo "AC-L3a rc=$rc en ${dur}s (esperado 75, ≤ 5 s): $(cat "$tmp/l3a.out")"; fi
if grep -q 'esperando hueco de tests ligeros (2 en marcha)' "$tmp/l3a.out"; then ok_; else fallo "AC-L3a falta el aviso de espera: $(cat "$tmp/l3a.out")"; fi
if [ "$(grep -c 'esperando hueco' "$tmp/l3a.out")" -eq 1 ]; then ok_; else fallo "AC-L3a el aviso debe salir una sola vez"; fi
if grep -q 'sin turno tras 1s' "$tmp/l3a.out"; then ok_; else fallo "AC-L3a falta «sin turno»"; fi
if [ ! -s "$orden" ]; then ok_; else fallo "AC-L3a ejecutó el comando sin hueco"; fi
if [ ! -e "$LIGD/3.lock" ]; then ok_; else fallo "AC-L3a usó un hueco por encima del límite"; fi
# (b) con tiempo, el tercero espera y entra cuando uno suelta
(cd "$tmp/repos/otro" && unset FX_TEST_PESADO && FX_TEST_WAIT=30 exec bash "$FT" -- bash "$tmp/ligero-marca.sh" "$orden") > "$tmp/l3b.out" 2>&1 &
L3P=$!; pids_fondo+=("$L3P")
hasta "grep -q 'esperando hueco' '$tmp/l3b.out'" || fallo "AC-L3b el tercero no llegó a esperar"
if [ ! -s "$orden" ]; then ok_; else fallo "AC-L3b el tercero corrió sin hueco"; fi
soltar_ligero "$L1F" "$L1P"
wait "$L3P"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$orden")" = "L" ]; then ok_; else fallo "AC-L3b el tercero no entró al soltar uno (rc=$rc): $(cat "$tmp/l3b.out")"; fi
soltar_ligero "$L2F" "$L2P"
# (c) un valor no numérico de FX_TEST_LIGEROS cae al defecto (3), no rompe
(cd "$tmp/repos/otro" && unset FX_TEST_PESADO && FX_TEST_LIGEROS=abc FX_TEST_WAIT=5 exec bash "$FT" -- true) > "$tmp/l3c.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '⚡ ligero' "$tmp/l3c.out"; then ok_; else fallo "AC-L3c FX_TEST_LIGEROS no numérico: $(cat "$tmp/l3c.out")"; fi
# (d) FX_TEST_LIGEROS=0 tampoco vale: vuelve al defecto (3) y arranca enseguida (no espera un hueco que no existe)
(cd "$tmp/repos/otro" && unset FX_TEST_PESADO && FX_TEST_LIGEROS=0 FX_TEST_WAIT=5 exec bash "$FT" -- true) > "$tmp/l3d.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '⚡ ligero' "$tmp/l3d.out" && ! grep -q 'esperando hueco' "$tmp/l3d.out"; then ok_; else fallo "AC-L3d FX_TEST_LIGEROS=0 debe volver a 3 y arrancar (rc=$rc): $(cat "$tmp/l3d.out")"; fi
unset FX_TEST_LIGEROS

# ---------- AC-L4: forzar con FX_TEST_PESADO / FX_TEST_LIGERO ----------
titular "$tmp/repos/otro"
: > "$FAKELOG"; : > "$orden"
# PESADO=1 con un bash «ligero»: cola
(cd "$tmp/repos/otro" && FX_TEST_PESADO=1 FX_TEST_WAIT=1 exec bash "$FT" -- bash "$tmp/ligero-marca.sh" "$orden") > "$tmp/l4a.out" 2>&1
rc=$?
if [ "$rc" -eq 75 ] && grep -q 'esperando turno' "$tmp/l4a.out" && [ ! -s "$orden" ]; then ok_; else fallo "AC-L4a FX_TEST_PESADO=1 no hizo cola (rc=$rc): $(cat "$tmp/l4a.out")"; fi
# LIGERO=1 con un phpunit falso: salta la cola
(cd "$tmp/repos/otro" && unset FX_TEST_PESADO && PATH="$tmp/fakebin:$PATH" FX_TEST_LIGERO=1 FX_TEST_WAIT=5 exec bash "$FT" -- phpunit) > "$tmp/l4b.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^phpunit' "$FAKELOG" && grep -q '⚡ ligero' "$tmp/l4b.out" && ! grep -q 'esperando turno' "$tmp/l4b.out"; then ok_; else fallo "AC-L4b FX_TEST_LIGERO=1 no saltó la cola (rc=$rc): $(cat "$tmp/l4b.out")"; fi
# los dos: gana PESADO
: > "$FAKELOG"
(cd "$tmp/repos/otro" && PATH="$tmp/fakebin:$PATH" FX_TEST_PESADO=1 FX_TEST_LIGERO=1 FX_TEST_WAIT=1 exec bash "$FT" -- bash "$tmp/ligero-marca.sh" "$orden") > "$tmp/l4c.out" 2>&1
rc=$?
if [ "$rc" -eq 75 ] && grep -q 'esperando turno' "$tmp/l4c.out" && [ ! -s "$orden" ]; then ok_; else fallo "AC-L4c con los dos debe ganar PESADO (rc=$rc): $(cat "$tmp/l4c.out")"; fi
soltar

# ---------- AC-L5: estado ----------
titular "$tmp/repos/otro"
ligero_titular; L1P=$LIG_PID; L1F=$LIG_FIFO
ligero_titular; L2P=$LIG_PID; L2F=$LIG_FIFO
# un hueco fantasma: .owner escrito pero sin flock vivo
: > "$LIGD/3.lock"; echo "fantasma pid=1 repo=muerto cmd=x desde=00:00:00" > "$LIGD/3.owner"
hasta "[ \"\$(bash '$FT' estado | grep -c '^ligero: .*pid=')\" -eq 2 ]" || fallo "AC-L5 estado no muestra los 2 ligeros"
est="$(bash "$FT" estado)"
if [ "$(printf '%s\n' "$est" | sed -n 1p | cut -c1-8)" = "ocupado:" ]; then ok_; else fallo "AC-L5 la primera línea debe ser el titular pesado: $est"; fi
if printf '%s\n' "$est" | grep -q "^ligero: .*pid=$L1P .*cmd="; then ok_; else fallo "AC-L5 estado no muestra el ligero $L1P: $est"; fi
if printf '%s\n' "$est" | grep -q "^ligero: .*pid=$L2P .*cmd="; then ok_; else fallo "AC-L5 estado no muestra el ligero $L2P: $est"; fi
if printf '%s\n' "$est" | grep -q 'fantasma'; then fallo "AC-L5 estado muestra un .owner sin flock vivo: $est"; else ok_; fi
ult="$(printf '%s\n' "$est" | grep -vn '^ligero:' | tail -1 | cut -d: -f1)"
pri="$(printf '%s\n' "$est" | grep -n '^ligero:' | head -1 | cut -d: -f1)"
if [ "$ult" -lt "$pri" ]; then ok_; else fallo "AC-L5 las líneas ligero: van después de las demás: $est"; fi
soltar_ligero "$L1F" "$L1P"; soltar_ligero "$L2F" "$L2P"; soltar
if [ "$(bash "$FT" estado)" = "libre" ]; then ok_; else fallo "AC-L5 estado tras terminar todo: $(bash "$FT" estado)"; fi

# hueco con flock vivo pero aún sin .owner (el ligero acaba de coger el hueco): «ligero: (arrancando)»
: > "$LIGD/1.lock"; : > "$LIGD/1.owner"
exec 9> "$LIGD/1.lock"; flock -n 9
est="$(bash "$FT" estado)"
if [ "$(printf '%s\n' "$est" | tail -1)" = "ligero: (arrancando)" ] && [ "$(printf '%s\n' "$est" | sed -n 1p)" = "libre" ]; then ok_; else fallo "AC-L5 hueco con flock y .owner vacío debe verse «ligero: (arrancando)»: $est"; fi
exec 9>&-
if [ "$(bash "$FT" estado)" = "libre" ]; then ok_; else fallo "AC-L5 soltado el flock el hueco no debe aparecer: $(bash "$FT" estado)"; fi

# ---------- AC-L7: sin argumentos imprime la ayuda de la cabecera completa (rc 2) ----------
(cd "$tmp/repos/otro" && exec bash "$FT") > "$tmp/ayuda.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then ok_; else fallo "AC-L7 sin argumentos debe devolver 2, devolvió $rc"; fi
if sed -n 1p "$tmp/ayuda.out" | grep -q '^# factory-test — turno único'; then ok_; else fallo "AC-L7 la ayuda debe empezar por el título: $(sed -n 1p "$tmp/ayuda.out")"; fi
if grep -q 'FX_TEST_PESADO' "$tmp/ayuda.out" && grep -q 'Máx. espera FX_TEST_WAIT' "$tmp/ayuda.out"; then ok_; else fallo "AC-L7 la ayuda no llega a las líneas de ligeros/espera: $(cat "$tmp/ayuda.out")"; fi
# la cabecera acaba en «# - Timeout…» + una línea «#» en blanco; lo siguiente («# Cómo funciona…») ya no es ayuda
for palabra in dirigido FX_TEST_DIRIGIDOS FX_TEST_REPOS_PESADOS tests.repos_pesados 'Lock de BD'; do
  if grep -q "$palabra" "$tmp/ayuda.out"; then ok_; else fallo "AC-L7 la ayuda no menciona «$palabra»"; fi
done
if [ "$(tail -1 "$tmp/ayuda.out")" = "#" ] && tail -2 "$tmp/ayuda.out" | head -1 | grep -q '^# - Timeout del comando FX_TEST_TIMEOUT'; then ok_; else fallo "AC-L7 la ayuda debe terminar en la última línea de la cabecera: $(tail -2 "$tmp/ayuda.out")"; fi
if grep -q 'Cómo funciona la prioridad' "$tmp/ayuda.out"; then fallo "AC-L7 la ayuda se pasa de la cabecera"; else ok_; fi

# ---------- AC-L6: clasificación ----------
clasif="$tmp/clasif.sh"
sed -n '/^LIGEROS_OK=/,/^}/p' "$FT" > "$clasif"
if [ -s "$clasif" ] && grep -q '^es_ligero()' "$clasif"; then ok_; else fallo "AC-L6 no se pudo extraer es_ligero"; fi
clasifica() { # <L|P> <comando como palabras sueltas>
  local esperado="$1" cmd="$2" palabras real
  read -ra palabras <<< "$cmd"
  # shellcheck disable=SC1090  # se carga la función extraída del script
  if (unset FX_TEST_PESADO FX_TEST_LIGERO; . "$clasif"; es_ligero "${palabras[@]}"); then real=L; else real=P; fi
  if [ "$real" = "$esperado" ]; then ok_; else fallo "AC-L6 «$cmd»: esperado $esperado, salió $real"; fi
}
while IFS='|' read -r esperado cmd; do
  [ -n "$esperado" ] && clasifica "$esperado" "$cmd"
done <<'TABLA'
L|bash tests/x.sh
L|sh tests/x.sh
L|zsh tests/x.sh
L|node --test plugin/
L|python3 tests/cupos_unit_test.py
L|python tests/x.py
L|python3 -m unittest discover tests
L|shellcheck bin/factory-test
L|bats tests/
L|true
L|false
L|env FOO=1 bash tests/x.sh
L|FOO=1 BAR=2 bash tests/x.sh
L|/usr/bin/env bash tests/x.sh
L|/bin/bash tests/x.sh
L|bash tests/php_helper_test.sh
L|bash scripts/artisan-wrapper.sh
P|vendor/bin/phpunit
P|vendor/bin/phpunit --filter X
P|php artisan test
P|php tests/x.php
P|paratest -p 4
P|vendor/bin/pest
P|phpunit-replay run -p 8
P|npm test
P|npm run test
P|npx vitest run
P|yarn test
P|pnpm test
P|composer test
P|make test
P|pytest tests/
P|python3 -m pytest tests/
P|bash -c php artisan test
P|bash -c echo ok; artisan test
P|bash -c phpunit-replay run
P|bash tests/x.sh phpunit-replay
P|bash tests/x.sh && psql -c select
P|bash tests/x.sh mysql
P|bash tests/run.php
P|sh -c make
P|ruby tests/x.rb
P|timeout 5 bash tests/x.sh
P|env -i bash tests/x.sh
P|FOO=1 php artisan test
P|jest
P|playwright test
P|dusk
TABLA

# ============================ Clases: ligero / dirigido / pesado ============================
DIRD="$LOCKS/dirigidos.d"; BDD="$LOCKS/bd.d"
mkdir -p "$tmp/repos/pesado" "$tmp/repos/chico"
git -C "$tmp/repos/pesado" init -q; git -C "$tmp/repos/chico" init -q
mkdir -p "$tmp/repos/pesado/vendor/bin"

# phpunit-replay falso (modo en FAKE_REPLAY_MODE): registra todas sus llamadas en FAKELOG
cat > "$tmp/repos/pesado/vendor/bin/phpunit-replay" <<'REPLAY'
#!/usr/bin/env bash
echo "phpunit-replay $*" >> "$FAKELOG"
if [[ " $* " == *" --dry-run "* ]]; then
  case "${FAKE_REPLAY_MODE:-limpio}" in
    limpio) echo "Replay  would run 2 test files" ;;
    estructural) echo "warning: structural change (phpunit_xml): the cached baseline cannot be used" >&2
                 echo "warning: recording a fresh baseline" >&2; echo "Replay  would record the full suite" ;;
    sinbase) echo "Replay  would record the full suite (no cached baseline)" ;;
    degradado) echo "Replay  would run the full suite via plain phpunit (degraded: no coverage driver)" ;;
    rc3) echo "boom" >&2; exit 3 ;;
    cuelga) exec sleep 30 ;;
  esac
fi
exit 0
REPLAY
chmod +x "$tmp/repos/pesado/vendor/bin/phpunit-replay"

# worktrees de la fábrica de mentira: .factory/env con su BD y su FX_REPO
mkwt() { # <nombre> <host> <puerto> <bd> [FX_REPO]
  mkdir -p "$tmp/wt/$1/.factory"; git -C "$tmp/wt/$1" init -q 2>/dev/null || { mkdir -p "$tmp/wt/$1"; git -C "$tmp/wt/$1" init -q; }
  printf 'DB_HOST=%s\nDB_PORT=%s\nDB_DATABASE=%s\nFX_REPO=%s\n' "$2" "$3" "$4" "${5:-$1}" > "$tmp/wt/$1/.factory/env"
}
mkwt a1 127.0.0.1 3307 fx_a;   mkwt a2 127.0.0.1 3307 fx_a;   mkwt b1 127.0.0.1 3307 fx_b
mkwt c1 127.0.0.1 3307 fx_c;   mkwt p1 127.0.0.1 5432 fx_a
mkwt hh1 127.0.0.1 3307 fx_hh pesado        # basename hh1, FX_REPO=pesado → pesado
mkdir -p "$tmp/repos2/otro"; git -C "$tmp/repos2/otro" init -q
mkdir -p "$tmp/repos2/otro/.factory"; printf 'FX_REPO=chico\n' > "$tmp/repos2/otro/.factory/env"   # basename otro, FX_REPO=chico → no pesado

# corre <dir> <FX_TEST_WAIT> <comando…> → RC, salida en $tmp/corre.out; fakes en PATH y sin FX_TEST_PESADO
corre() {
  local dir="$1" w="$2"; shift 2
  : > "$FAKELOG"
  (cd "$dir" && unset FX_TEST_PESADO && PATH="$tmp/fakebin:$PATH" FX_TEST_WAIT="$w" exec bash "$FT" -- "$@") > "$tmp/corre.out" 2>&1
  RC=$?
}
esta_en_fake() { grep -q -- "$1" "$FAKELOG"; }

# un dirigido «titular»: ocupa su hueco y su BD hasta que se escriba en su fifo
n_dt=0
dir_titular() { # <dir> [ruta de test] → deja DT_PID, DT_FIFO, DT_OUT
  n_dt=$((n_dt + 1))
  DT_FIFO="$tmp/dfifo$n_dt"; DT_OUT="$tmp/dt$n_dt.out"; mkfifo "$DT_FIFO"
  (cd "$1" && unset FX_TEST_PESADO && PATH="$tmp/fakebin:$PATH" FAKE_FIFO="$DT_FIFO" FAKE_DENTRO="$tmp/dt$n_dt.dentro" \
    exec bash "$FT" -- phpunit "${2:-tests/Feature/H$n_dt.php}") > "$DT_OUT" 2>&1 &
  DT_PID=$!; pids_fondo+=("$DT_PID")
  hasta "[ -e '$tmp/dt$n_dt.dentro' ]" || fallo "el dirigido titular $n_dt no arrancó: $(cat "$DT_OUT")"
}
dt_soltar() { echo > "$1"; wait "$2" 2>/dev/null; }

# ---------- AC-T1: con el turno ocupado, un dirigido no espera ----------
titular "$tmp/repos/otro"
owner_antes="$(cat "$LOCKS/factory-test.owner")"
while IFS= read -r cmd; do
  read -ra palabras <<< "$cmd"
  t0=$SECONDS
  corre "$tmp/repos/pesado" 20 "${palabras[@]}"
  if [ "$RC" -eq 0 ] && [ $((SECONDS - t0)) -le 5 ] && [ -s "$FAKELOG" ] && grep -q '▶ dirigido' "$tmp/corre.out" \
     && ! grep -q 'esperando turno' "$tmp/corre.out"; then ok_
  else fallo "AC-T1 «$cmd» debía ir como dirigido sin esperar (rc=$RC): $(cat "$tmp/corre.out")"; fi
done <<'CMDS'
phpunit tests/Feature/X.php
php artisan test --filter=Foo
pest --group a
CMDS
if [ "$(cat "$LOCKS/factory-test.owner")" = "$owner_antes" ]; then ok_; else fallo "AC-T1 un dirigido tocó factory-test.owner"; fi
if [ -z "$(ls -A "$PRIOD" 2>/dev/null)" ]; then ok_; else fallo "AC-T1 un dirigido tocó prio.d: $(ls -A "$PRIOD")"; fi
# el dirigido con prioridad forzada tampoco se apunta en prio.d
(cd "$tmp/repos/pesado" && unset FX_TEST_PESADO && PATH="$tmp/fakebin:$PATH" FX_TEST_PRIO=1 FX_TEST_WAIT=20 exec bash "$FT" -- phpunit tests/Feature/X.php) > "$tmp/t1p.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(ls -A "$PRIOD" 2>/dev/null)" ]; then ok_; else fallo "AC-T1 FX_TEST_PRIO=1 en un dirigido (rc=$rc): $(cat "$tmp/t1p.out")"; fi
# el log y el QUIEN llevan la clase; tras acabar el hueco queda con .owner vacío
compgen -G "$FABRIK_DATA/logs/tests/*-dirigido-*.log" > /dev/null && log_dirigido=1 || log_dirigido=0
if [ "$log_dirigido" = 1 ]; then ok_; else fallo "AC-T1 el nombre del log no lleva la clase: $(find "$FABRIK_DATA/logs/tests" -type f | tail -3)"; fi
if [ -z "$(tr -d '[:space:]' < "$DIRD/1.owner")" ]; then ok_; else fallo "AC-T1 el .owner del hueco dirigido no se vació al salir"; fi
soltar

# ---------- AC-T2: con el turno ocupado, esperan turno ----------
titular "$tmp/repos/otro"
while IFS= read -r cmd; do
  read -ra palabras <<< "$cmd"
  corre "$tmp/repos/pesado" 1 "${palabras[@]}"
  if [ "$RC" -eq 75 ] && grep -q 'esperando turno' "$tmp/corre.out" && grep -q '▶ pesado' "$tmp/corre.out" && [ ! -s "$FAKELOG" ]; then ok_
  else fallo "AC-T2 «$cmd» debía esperar turno (rc=$RC, fake: $(cat "$FAKELOG")): $(cat "$tmp/corre.out")"; fi
done <<'CMDS'
phpunit
phpunit tests
php artisan test
phpunit --testsuite Unit
phpunit --filter X -p 8
phpunit --filter X --processes=4
phpunit --processes 4 tests/Feature/X.php
php artisan test --filter X --parallel
paratest tests/X.php
infection
dusk
php artisan dusk
composer test
CMDS
corre "$tmp/repos/pesado" 1 bash -c 'php artisan test --filter X'
if [ "$RC" -eq 75 ] && grep -q 'esperando turno' "$tmp/corre.out" && [ ! -s "$FAKELOG" ]; then ok_; else fallo "AC-T2 bash -c «php artisan test --filter X» debía esperar turno (rc=$RC)"; fi
soltar

# ---------- AC-T3: repos pesados (env, config, FX_REPO) ----------
titular "$tmp/repos/otro"
# (a) repo no pesado: suite completa y -p 8 van como dirigido
for cmd in "phpunit" "phpunit -p 8" "composer test"; do
  read -ra palabras <<< "$cmd"
  corre "$tmp/repos/chico" 20 "${palabras[@]}"
  if [ "$RC" -eq 0 ] && grep -q '▶ dirigido' "$tmp/corre.out" && ! grep -q 'esperando turno' "$tmp/corre.out"; then ok_
  else fallo "AC-T3a «$cmd» en un repo no pesado debía ir como dirigido (rc=$RC): $(cat "$tmp/corre.out")"; fi
done
# (b) FX_TEST_REPOS_PESADOS vacía = ningún repo pesado (ni siquiera el listado antes)
(export FX_TEST_REPOS_PESADOS=""; corre "$tmp/repos/pesado" 20 phpunit; echo "$RC" > "$tmp/rc")
if [ "$(cat "$tmp/rc")" -eq 0 ] && ! grep -q 'esperando turno' "$tmp/corre.out"; then ok_; else fallo "AC-T3b FX_TEST_REPOS_PESADOS vacía debía dejar todo sin turno: $(cat "$tmp/corre.out")"; fi
# (c) sin lista (clave ausente, yaml inválido o sin fichero) todos los repos son pesados
(unset FX_TEST_REPOS_PESADOS; corre "$tmp/repos/chico" 1 phpunit; echo "$RC" > "$tmp/rc")
if [ "$(cat "$tmp/rc")" -eq 75 ] && grep -q 'esperando turno' "$tmp/corre.out"; then ok_; else fallo "AC-T3c sin lista debía ser pesado: $(cat "$tmp/corre.out")"; fi
printf 'tests: [sin cerrar\n' > "$tmp/fabrik-roto.yaml"
(unset FX_TEST_REPOS_PESADOS; FABRIK_CONFIG="$tmp/fabrik-roto.yaml" corre "$tmp/repos/chico" 1 phpunit; echo "$RC" > "$tmp/rc")
if [ "$(cat "$tmp/rc")" -eq 75 ] && grep -q 'esperando turno' "$tmp/corre.out"; then ok_; else fallo "AC-T3c yaml inválido debía ser pesado: $(cat "$tmp/corre.out")"; fi
# (d) con lista en la config: el listado es pesado y el resto, dirigido; la env manda sobre la config
printf 'tests:\n  repos_pesados: [chico]\n' > "$tmp/fabrik-chico.yaml"
(unset FX_TEST_REPOS_PESADOS; FABRIK_CONFIG="$tmp/fabrik-chico.yaml" corre "$tmp/repos/chico" 1 phpunit; echo "$RC" > "$tmp/rc")
if [ "$(cat "$tmp/rc")" -eq 75 ] && grep -q 'esperando turno' "$tmp/corre.out"; then ok_; else fallo "AC-T3d chico listado en la config debía ser pesado: $(cat "$tmp/corre.out")"; fi
(unset FX_TEST_REPOS_PESADOS; FABRIK_CONFIG="$tmp/fabrik-chico.yaml" corre "$tmp/repos/pesado" 20 phpunit; echo "$RC" > "$tmp/rc")
if [ "$(cat "$tmp/rc")" -eq 0 ] && grep -q '▶ dirigido' "$tmp/corre.out"; then ok_; else fallo "AC-T3d repo fuera de la lista de la config debía ser dirigido: $(cat "$tmp/corre.out")"; fi
(FABRIK_CONFIG="$tmp/fabrik-chico.yaml" corre "$tmp/repos/chico" 20 phpunit; echo "$RC" > "$tmp/rc")
if [ "$(cat "$tmp/rc")" -eq 0 ] && grep -q '▶ dirigido' "$tmp/corre.out"; then ok_; else fallo "AC-T3d la env debía mandar sobre la config: $(cat "$tmp/corre.out")"; fi
# (e) el nombre del repo es FX_REPO de .factory/env (exacto), no el basename
corre "$tmp/wt/hh1" 1 phpunit
if [ "$RC" -eq 75 ] && grep -q 'esperando turno' "$tmp/corre.out" && grep -q 'repo pesado' "$tmp/corre.out"; then ok_; else fallo "AC-T3e FX_REPO=pesado (basename hh1) debía ser pesado (rc=$RC): $(cat "$tmp/corre.out")"; fi
corre "$tmp/repos2/otro" 20 phpunit
if [ "$RC" -eq 0 ] && grep -q '▶ dirigido' "$tmp/corre.out"; then ok_; else fallo "AC-T3e FX_REPO=chico (basename otro) debía ser dirigido (rc=$RC): $(cat "$tmp/corre.out")"; fi
(FX_TEST_REPOS_PESADOS="pesad esado"; corre "$tmp/repos/pesado" 20 phpunit; echo "$RC" > "$tmp/rc")
if [ "$(cat "$tmp/rc")" -eq 0 ]; then ok_; else fallo "AC-T3e la comparación del nombre debe ser exacta, no por subcadena"; fi
# (f) FX_TEST_PESADO / FX_TEST_LIGERO mandan sobre el repo
(cd "$tmp/repos/chico" && PATH="$tmp/fakebin:$PATH" FX_TEST_PESADO=1 FX_TEST_WAIT=1 exec bash "$FT" -- phpunit tests/X.php) > "$tmp/t3f.out" 2>&1
if [ $? -eq 75 ] && grep -q 'esperando turno' "$tmp/t3f.out"; then ok_; else fallo "AC-T3f FX_TEST_PESADO=1 en un repo no pesado debía hacer cola: $(cat "$tmp/t3f.out")"; fi
soltar

# ---------- AC-T4: replay ----------
titular "$tmp/repos/otro"
RPL=vendor/bin/phpunit-replay
# dry-run limpio → dirigido; se llama al dry-run con los mismos args y luego al run real.
# El tope de procesos (4 por defecto) reescribe el -p 8 antes del dry-run y del run.
FAKE_REPLAY_MODE=limpio corre "$tmp/repos/pesado" 20 "$RPL" run -p 8
if [ "$RC" -eq 0 ] && grep -q '▶ dirigido' "$tmp/corre.out" && ! grep -q 'esperando turno' "$tmp/corre.out" \
   && grep -q 'tope de 4 procesos: vendor/bin/phpunit-replay run -p 8 → vendor/bin/phpunit-replay run -p 4' "$tmp/corre.out" \
   && [ "$(sed -n 1p "$FAKELOG")" = "phpunit-replay run --dry-run -p 4" ] && [ "$(sed -n 2p "$FAKELOG")" = "phpunit-replay run -p 4" ]; then ok_
else fallo "AC-T4 dry-run limpio debía ir como dirigido (rc=$RC, fake: $(cat "$FAKELOG")): $(cat "$tmp/corre.out")"; fi
# con env y php delante, el dry-run conserva el prefijo
FAKE_REPLAY_MODE=limpio corre "$tmp/repos/pesado" 20 env FOO=1 "$RPL" run
if [ "$RC" -eq 0 ] && [ "$(sed -n 1p "$FAKELOG")" = "phpunit-replay run --dry-run" ]; then ok_; else fallo "AC-T4 prefijo env: rc=$RC, fake: $(cat "$FAKELOG")"; fi
# dry-run que degrada → pesado: espera turno, se llamó solo al dry-run (no se ejecutó el run real)
for modo in estructural sinbase degradado rc3; do
  FAKE_REPLAY_MODE=$modo corre "$tmp/repos/pesado" 1 "$RPL" run
  if [ "$RC" -eq 75 ] && grep -q 'esperando turno' "$tmp/corre.out" && grep -q '▶ pesado' "$tmp/corre.out" \
     && [ "$(wc -l < "$FAKELOG")" -eq 1 ] && grep -q -- '--dry-run' "$FAKELOG"; then ok_
  else fallo "AC-T4 dry-run «$modo» debía ser pesado y no ejecutar el run (rc=$RC, fake: $(cat "$FAKELOG")): $(cat "$tmp/corre.out")"; fi
done
# timeout del dry-run → pesado
FX_TEST_DRYRUN_TIMEOUT=1 FAKE_REPLAY_MODE=cuelga corre "$tmp/repos/pesado" 1 "$RPL" run
if [ "$RC" -eq 75 ] && grep -q 'esperando turno' "$tmp/corre.out"; then ok_; else fallo "AC-T4 el timeout del dry-run debía ser pesado (rc=$RC): $(cat "$tmp/corre.out")"; fi
# run --fresh, record y otros subcomandos → pesado sin llamar al dry-run
for args in "run --fresh" "record" "verify"; do
  read -ra palabras <<< "$args"
  corre "$tmp/repos/pesado" 1 "$RPL" "${palabras[@]}"
  if [ "$RC" -eq 75 ] && grep -q 'esperando turno' "$tmp/corre.out" && [ ! -s "$FAKELOG" ]; then ok_
  else fallo "AC-T4 «replay $args» debía ser pesado sin dry-run (rc=$RC, fake: $(cat "$FAKELOG"))"; fi
done
# en un repo no pesado el replay va directo, sin dry-run previo
(FX_TEST_REPOS_PESADOS=otro FAKE_REPLAY_MODE=estructural corre "$tmp/repos/pesado" 20 "$RPL" run --fresh; echo "$RC" > "$tmp/rc"); RC="$(cat "$tmp/rc")"
if [ "$RC" -eq 0 ] && [ "$(wc -l < "$FAKELOG")" -eq 1 ] && ! grep -q -- '--dry-run' "$FAKELOG"; then ok_; else fallo "AC-T4 en repo no pesado no debe haber dry-run (rc=$RC, fake: $(cat "$FAKELOG"))"; fi
soltar

# ---------- AC-T5: huecos dirigidos ----------
export FX_TEST_DIRIGIDOS=2
dir_titular "$tmp/wt/a1"; D1P=$DT_PID; D1F=$DT_FIFO
dir_titular "$tmp/wt/b1"; D2P=$DT_PID; D2F=$DT_FIFO
# (a) con el límite alcanzado y poca espera: rc 75 sin ejecutar
t0=$SECONDS
corre "$tmp/wt/c1" 1 phpunit tests/Feature/Tercero.php
if [ "$RC" -eq 75 ] && [ $((SECONDS - t0)) -le 5 ] && ! esta_en_fake Tercero && grep -q 'esperando hueco de tests dirigidos (2 en marcha)' "$tmp/corre.out" \
   && [ "$(grep -c 'esperando hueco' "$tmp/corre.out")" -eq 1 ] && grep -q 'sin turno tras 1s' "$tmp/corre.out" && [ ! -e "$DIRD/3.lock" ]; then ok_
else fallo "AC-T5a el tercero debía esperar y rendirse con 75 (rc=$RC): $(cat "$tmp/corre.out")"; fi
# (b) con tiempo, entra cuando uno suelta
(cd "$tmp/wt/c1" && unset FX_TEST_PESADO && PATH="$tmp/fakebin:$PATH" FX_TEST_WAIT=30 exec bash "$FT" -- phpunit tests/Feature/Tercero.php) > "$tmp/t5b.out" 2>&1 &
T5P=$!; pids_fondo+=("$T5P")
hasta "grep -q 'esperando hueco' '$tmp/t5b.out'" || fallo "AC-T5b el tercero no llegó a esperar"
: > "$FAKELOG"
dt_soltar "$D1F" "$D1P"
wait "$T5P"; rc=$?
if [ "$rc" -eq 0 ] && esta_en_fake Tercero; then ok_; else fallo "AC-T5b el tercero no entró al soltar uno (rc=$rc): $(cat "$tmp/t5b.out")"; fi
dt_soltar "$D2F" "$D2P"
# (c) valor no numérico o 0 → defecto (4): arranca sin esperar con 2 en marcha
dir_titular "$tmp/wt/a1"; D1P=$DT_PID; D1F=$DT_FIFO
dir_titular "$tmp/wt/b1"; D2P=$DT_PID; D2F=$DT_FIFO
for v in abc 0; do
  # shellcheck disable=SC2030,SC2031  # el cambio de la env es local al subshell a propósito
  (export FX_TEST_DIRIGIDOS=$v; corre "$tmp/wt/c1" 5 phpunit tests/Feature/Z.php; echo "$RC" > "$tmp/rc")
  if [ "$(cat "$tmp/rc")" -eq 0 ] && ! grep -q 'esperando hueco' "$tmp/corre.out"; then ok_; else fallo "AC-T5c FX_TEST_DIRIGIDOS=$v debía volver al defecto: $(cat "$tmp/corre.out")"; fi
done
# (d) sin la env, el límite sale de tests.dirigidos de la config; la env manda sobre la config
printf 'tests:\n  dirigidos: 2\n' > "$tmp/fabrik-dir2.yaml"
(unset FX_TEST_DIRIGIDOS; FABRIK_CONFIG="$tmp/fabrik-dir2.yaml" corre "$tmp/wt/c1" 1 phpunit tests/Feature/Z.php; echo "$RC" > "$tmp/rc")
if [ "$(cat "$tmp/rc")" -eq 75 ] && grep -q 'esperando hueco de tests dirigidos (2 en marcha)' "$tmp/corre.out"; then ok_; else fallo "AC-T5d tests.dirigidos=2 de la config no se respetó: $(cat "$tmp/corre.out")"; fi
(FX_TEST_DIRIGIDOS=3 FABRIK_CONFIG="$tmp/fabrik-dir2.yaml" corre "$tmp/wt/c1" 5 phpunit tests/Feature/Z.php; echo "$RC" > "$tmp/rc")
if [ "$(cat "$tmp/rc")" -eq 0 ]; then ok_; else fallo "AC-T5d la env debía mandar sobre la config: $(cat "$tmp/corre.out")"; fi
dt_soltar "$D1F" "$D1P"; dt_soltar "$D2F" "$D2P"
# shellcheck disable=SC2031
export FX_TEST_DIRIGIDOS=4

# ---------- AC-T6: lock por BD efectiva ----------
# misma BD, mismo worktree: se serializan
dir_titular "$tmp/wt/a1"; D1P=$DT_PID; D1F=$DT_FIFO
corre "$tmp/wt/a1" 1 phpunit tests/Feature/Otro.php
if [ "$RC" -eq 75 ] && grep -q 'esperando la BD 127.0.0.1:3307/fx_a — la usa: .*pid=' "$tmp/corre.out" && ! esta_en_fake Otro \
   && [ "$(grep -c 'esperando la BD' "$tmp/corre.out")" -eq 1 ] && grep -q 'sin turno tras 1s' "$tmp/corre.out"; then ok_
else fallo "AC-T6 mismo worktree: el segundo debía esperar la BD y rendirse (rc=$RC): $(cat "$tmp/corre.out")"; fi
# misma BD, otro worktree (dos worktrees de un repo con una sola BD de test): también
corre "$tmp/wt/a2" 1 phpunit tests/Feature/Otro.php
if [ "$RC" -eq 75 ] && grep -q 'esperando la BD 127.0.0.1:3307/fx_a' "$tmp/corre.out" && ! esta_en_fake Otro; then ok_; else fallo "AC-T6 dos worktrees con la misma BD debían serializarse (rc=$RC): $(cat "$tmp/corre.out")"; fi
# el nombre del fichero de lock está saneado
if [ -e "$BDD/127.0.0.1_3307_fx_a.lock" ]; then ok_; else fallo "AC-T6 falta locks/bd.d/127.0.0.1_3307_fx_a.lock: $(ls "$BDD")"; fi
# BD distinta, o mismo nombre en otro puerto: a la vez
corre "$tmp/wt/b1" 20 phpunit tests/Feature/Otro.php
if [ "$RC" -eq 0 ] && esta_en_fake Otro && ! grep -q 'esperando' "$tmp/corre.out"; then ok_; else fallo "AC-T6 BD distinta debía ir a la vez (rc=$RC): $(cat "$tmp/corre.out")"; fi
corre "$tmp/wt/p1" 20 phpunit tests/Feature/Otro.php
if [ "$RC" -eq 0 ] && esta_en_fake Otro && ! grep -q 'esperando' "$tmp/corre.out"; then ok_; else fallo "AC-T6 mismo nombre en otro puerto (5432) debía ir a la vez (rc=$RC): $(cat "$tmp/corre.out")"; fi
# un pesado también coge el lock de BD, después del turno: con el turno libre espera la BD y suelta el turno al rendirse
(FX_TEST_REPOS_PESADOS=a1; corre "$tmp/wt/a1" 1 phpunit; echo "$RC" > "$tmp/rc")
if [ "$(cat "$tmp/rc")" -eq 75 ] && grep -q '▶ pesado' "$tmp/corre.out" && grep -q 'esperando la BD' "$tmp/corre.out" && ! grep -q 'esperando turno' "$tmp/corre.out" \
   && bash "$FT" estado | grep -q '^libre$'; then ok_
else fallo "AC-T6 un pesado debe esperar la BD tras coger el turno y soltarlo al rendirse: $(cat "$tmp/corre.out") / $(bash "$FT" estado)"; fi
# al soltar la BD, el que espera entra
(cd "$tmp/wt/a2" && unset FX_TEST_PESADO && PATH="$tmp/fakebin:$PATH" FX_TEST_WAIT=30 exec bash "$FT" -- phpunit tests/Feature/Otro.php) > "$tmp/t6.out" 2>&1 &
T6P=$!; pids_fondo+=("$T6P")
hasta "grep -q 'esperando la BD' '$tmp/t6.out'" || fallo "AC-T6 el segundo no llegó a esperar la BD"
: > "$FAKELOG"
dt_soltar "$D1F" "$D1P"
wait "$T6P"; rc=$?
if [ "$rc" -eq 0 ] && esta_en_fake Otro; then ok_; else fallo "AC-T6 al soltar la BD el segundo debía entrar (rc=$rc): $(cat "$tmp/t6.out")"; fi
# sin .factory/env la clave es el toplevel: mismo checkout se serializa, otro checkout no
dir_titular "$tmp/repos/chico"; D1P=$DT_PID; D1F=$DT_FIFO
corre "$tmp/repos/chico" 1 phpunit tests/Feature/Otro.php
if [ "$RC" -eq 75 ] && grep -q "esperando la BD $tmp/repos/chico" "$tmp/corre.out"; then ok_; else fallo "AC-T6 sin .factory/env debía bloquear por toplevel (rc=$RC): $(cat "$tmp/corre.out")"; fi
corre "$tmp/repos/pesado" 20 phpunit tests/Feature/Otro.php
if [ "$RC" -eq 0 ] && ! grep -q 'esperando' "$tmp/corre.out"; then ok_; else fallo "AC-T6 otro checkout debía ir a la vez (rc=$RC): $(cat "$tmp/corre.out")"; fi
dt_soltar "$D1F" "$D1P"
# los ligeros no cogen lock de BD
dir_titular "$tmp/repos/chico"; D1P=$DT_PID; D1F=$DT_FIFO
(cd "$tmp/repos/chico" && unset FX_TEST_PESADO && FX_TEST_WAIT=20 exec bash "$FT" -- true) > "$tmp/t6l.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '⚡ ligero' "$tmp/t6l.out" && ! grep -q 'esperando' "$tmp/t6l.out"; then ok_; else fallo "AC-T6 un ligero no debe esperar la BD: $(cat "$tmp/t6l.out")"; fi
dt_soltar "$D1F" "$D1P"

# ---------- AC-T7: estado ----------
titular "$tmp/repos/otro"
dir_titular "$tmp/wt/a1"; D1P=$DT_PID; D1F=$DT_FIFO
dir_titular "$tmp/wt/b1"; D2P=$DT_PID; D2F=$DT_FIFO
ligero_titular; L1P=$LIG_PID; L1F=$LIG_FIFO
# hueco dirigido fantasma: .owner escrito sin flock vivo
: > "$DIRD/4.lock"; printf 'fantasma pid=1 repo=muerto cmd=x desde=00:00:00\nmuerta\n' > "$DIRD/4.owner"
est="$(bash "$FT" estado)"
if [ "$(printf '%s\n' "$est" | sed -n 1p | cut -c1-8)" = "ocupado:" ]; then ok_; else fallo "AC-T7 la primera línea debe ser el pesado: $est"; fi
if printf '%s\n' "$est" | grep -q "^dirigido: .*pid=$D1P .*\[dirigido\].* · bd=127.0.0.1:3307/fx_a$"; then ok_; else fallo "AC-T7 falta el dirigido $D1P con su bd: $est"; fi
if printf '%s\n' "$est" | grep -q "^dirigido: .*pid=$D2P .* · bd=127.0.0.1:3307/fx_b$"; then ok_; else fallo "AC-T7 falta el dirigido $D2P con su bd: $est"; fi
if [ "$(printf '%s\n' "$est" | grep -c '^dirigido:')" -eq 2 ] && ! printf '%s\n' "$est" | grep -q fantasma; then ok_; else fallo "AC-T7 debe haber 2 dirigidos y no el fantasma: $est"; fi
if printf '%s\n' "$est" | grep -q "^ocupado: .*\[pesado\]"; then ok_; else fallo "AC-T7 el QUIEN del pesado debe llevar la clase: $est"; fi
if printf '%s\n' "$est" | grep -q "^ligero: .*pid=$L1P .*\[ligero\]"; then ok_; else fallo "AC-T7 falta el ligero con su clase: $est"; fi
ult_d="$(printf '%s\n' "$est" | grep -n '^dirigido:' | tail -1 | cut -d: -f1)"
pri_l="$(printf '%s\n' "$est" | grep -n '^ligero:' | head -1 | cut -d: -f1)"
ult_o="$(printf '%s\n' "$est" | grep -vn '^dirigido:\|^ligero:' | tail -1 | cut -d: -f1)"
if [ "$ult_o" -lt "$(printf '%s\n' "$est" | grep -n '^dirigido:' | head -1 | cut -d: -f1)" ] && [ "$ult_d" -lt "$pri_l" ]; then ok_; else fallo "AC-T7 orden: pesado, dirigido, ligero: $est"; fi
# hueco con flock vivo y aún sin .owner → «dirigido: (arrancando)»
dt_soltar "$D1F" "$D1P"; dt_soltar "$D2F" "$D2P"; soltar_ligero "$L1F" "$L1P"; soltar
: > "$DIRD/1.lock"; : > "$DIRD/1.owner"
exec 9> "$DIRD/1.lock"; flock -n 9
est="$(bash "$FT" estado)"
if [ "$(printf '%s\n' "$est" | tail -1)" = "dirigido: (arrancando)" ] && [ "$(printf '%s\n' "$est" | sed -n 1p)" = "libre" ]; then ok_; else fallo "AC-T7 hueco con flock y .owner vacío debe verse «dirigido: (arrancando)»: $est"; fi
exec 9>&-
if [ "$(bash "$FT" estado)" = "libre" ]; then ok_; else fallo "AC-T7 tras soltar todo: $(bash "$FT" estado)"; fi

# ---------- AC-T8: clasificación de clase_de ----------
clasif_t="$tmp/clasif_t.sh"
sed -n '/^LIGEROS_OK=/,/^# fin clasificación/p' "$FT" > "$clasif_t"
if [ -s "$clasif_t" ] && grep -q '^clase_de()' "$clasif_t"; then ok_; else fallo "AC-T8 no se pudo extraer clase_de"; fi
clase_t() { # <D|P|L|R> <H|N> <comando como palabras sueltas>
  local esperado="$1" repo="$2" cmd="$3" palabras real=""
  read -ra palabras <<< "$cmd"
  # shellcheck disable=SC1090  # se carga la función extraída del script
  real="$(unset FX_TEST_PESADO FX_TEST_LIGERO; . "$clasif_t"; clase_de "$([ "$repo" = H ] && echo 1 || echo 0)" "${palabras[@]}"; echo "$CLASE")"
  case "$real" in dirigido) real=D ;; pesado) real=P ;; ligero) real=L ;; replay) real=R ;; esac
  if [ "$real" = "$esperado" ]; then ok_; else fallo "AC-T8 «$repo $cmd»: esperado $esperado, salió $real"; fi
}
while IFS='|' read -r esperado repo cmd; do
  [ -n "$esperado" ] && clase_t "$esperado" "$repo" "$cmd"
done <<'TABLA'
D|H|phpunit tests/Feature/X.php
D|H|vendor/bin/phpunit tests/Feature/X.php
D|H|vendor/bin/phpunit tests/Unit
D|H|vendor/bin/phpunit --filter X
D|H|vendor/bin/phpunit --filter=X
D|H|vendor/bin/phpunit --group a
D|H|vendor/bin/phpunit --group=a
D|H|pest --group a
D|H|vendor/bin/pest --group=a
D|H|php artisan test --filter=Foo
D|H|php artisan test tests/Feature
D|H|php artisan test tests/Feature/
D|H|artisan test --filter Foo
D|H|env FOO=1 php vendor/bin/phpunit tests/X.php
D|H|FOO=1 vendor/bin/phpunit tests/X.php
D|H|env FOO=1 BAR=2 phpunit --filter X
D|H|phpunit -p1 tests/X.php
D|H|phpunit -p 1 --filter X
D|H|phpunit --processes=1 tests/X.php
D|H|phpunit --processes 1 tests/X.php
P|H|phpunit -p2 tests/X.php
P|H|phpunit -p 2 tests/X.php
P|H|php artisan migrate --filter X
D|H|phpunit --colors=always tests/X.php
D|H|phpunit --testdox tests/X.php
D|H|phpunit --testsuite Unit --filter X
D|H|jest tests/x.test.js
D|H|vitest run src/x.test.ts
D|H|pytest tests/test_x.py
D|H|pytest -p no:cacheprovider tests/test_x.py
P|H|phpunit
P|H|phpunit tests
P|H|phpunit tests/
P|H|phpunit .
P|H|phpunit ./
P|H|phpunit --testsuite Unit
P|H|phpunit --exclude-group slow
P|H|phpunit --testsuite Unit --exclude-group slow
P|H|phpunit --log-junit build/x.xml
P|H|phpunit --configuration phpunit.xml
P|H|php artisan test
P|H|vendor/bin/pest
P|H|pytest
P|H|jest
P|H|vendor/bin/phpunit --filter X -p 8
P|H|vendor/bin/phpunit -p 8 --filter X
P|H|phpunit -p8 tests/X.php
P|H|phpunit --processes=4 tests/X.php
P|H|phpunit --processes 4 tests/X.php
P|H|php artisan test --parallel
P|H|php artisan test --filter X --parallel
P|H|paratest tests/X.php
P|H|vendor/bin/paratest
P|H|php vendor/bin/infection
P|H|infection
P|H|php artisan dusk
P|H|dusk
P|H|bash -c php artisan test --filter X
P|H|composer test
P|H|npm test
P|H|make test
P|H|python3 -m pytest tests/test_x.py
P|H|cargo test
P|H|phpunit-replay record
P|H|phpunit-replay run --fresh
P|H|phpunit-replay verify
R|H|phpunit-replay run
R|H|vendor/bin/phpunit-replay run -p 8
R|H|env FOO=1 php vendor/bin/phpunit-replay run
R|H|phpunit-replay run --filter X
D|N|phpunit
D|N|phpunit -p 8
D|N|php artisan test --parallel
D|N|composer test
D|N|phpunit-replay run --fresh
D|N|make
L|N|bash tests/x.sh
L|H|bash tests/x.sh
L|H|true
TABLA
# FX_TEST_PESADO / FX_TEST_LIGERO mandan sobre todo lo demás
# shellcheck disable=SC1090  # se carga la función extraída del script
real="$(. "$clasif_t"; FX_TEST_PESADO=1 clase_de 0 phpunit tests/X.php; echo "$CLASE")"
if [ "$real" = pesado ]; then ok_; else fallo "AC-T8 FX_TEST_PESADO=1 debía ser pesado, salió $real"; fi
# shellcheck disable=SC1090
real="$(unset FX_TEST_PESADO; . "$clasif_t"; FX_TEST_LIGERO=1 clase_de 1 phpunit; echo "$CLASE")"
if [ "$real" = ligero ]; then ok_; else fallo "AC-T8 FX_TEST_LIGERO=1 debía ser ligero, salió $real"; fi
# shellcheck disable=SC1090
real="$(. "$clasif_t"; FX_TEST_PESADO=1 FX_TEST_LIGERO=1 clase_de 0 bash x.sh; echo "$CLASE")"
if [ "$real" = pesado ]; then ok_; else fallo "AC-T8 con los dos debía ganar pesado, salió $real"; fi

# ============================ TEST_TOKEN para repos con BD de tests fija ============================
mkwt k1 127.0.0.1 3307 fx_k tokrepo; mkwt k2 127.0.0.1 3307 fx_k tokrepo   # mismo DB_DATABASE, repo «tokrepo»
mkwt k3 127.0.0.1 3307 fx_k libre                                         # misma BD, repo fuera de la lista
ENVLOG="$tmp/envlog"
# titular con token: coge su hueco y su BD y los mantiene hasta que se escriba en su fifo
n_tt=0
tok_titular() { # <dir> <repos_pesados> <comando…> → deja TT_PID, TT_FIFO, TT_OUT, TT_ENV
  n_tt=$((n_tt + 1))
  TT_FIFO="$tmp/tfifo$n_tt"; TT_OUT="$tmp/tt$n_tt.out"; TT_ENV="$tmp/tt$n_tt.env"; mkfifo "$TT_FIFO"
  (cd "$1" && unset FX_TEST_PESADO && PATH="$tmp/fakebin:$PATH" FX_TEST_REPOS_TOKEN=tokrepo FX_TEST_REPOS_PESADOS="$2" \
    FAKE_ENVLOG="$TT_ENV" FAKE_FIFO="$TT_FIFO" FAKE_DENTRO="$tmp/tt$n_tt.dentro" exec bash "$FT" -- "${@:3}") > "$TT_OUT" 2>&1 &
  TT_PID=$!; pids_fondo+=("$TT_PID")
  hasta "[ -e '$tmp/tt$n_tt.dentro' ]" || fallo "el titular con token $n_tt no arrancó: $(cat "$TT_OUT")"
}
# corre_tok <dir> <wait> <comando…> → RC, $tmp/corre.out y $ENVLOG (lo que vio el comando); el repo «tokrepo» está en la lista
corre_tok() { : > "$ENVLOG"; (export FX_TEST_REPOS_TOKEN=tokrepo FAKE_ENVLOG="$ENVLOG"; corre "$@"; echo "$RC" > "$tmp/rc"); RC="$(cat "$tmp/rc")"; }

# ---------- AC-K1: dos dirigidos a la vez con la misma BD base, tokens y claves distintos ----------
tok_titular "$tmp/wt/k1" "" phpunit tests/Feature/A.php; T1P=$TT_PID; T1F=$TT_FIFO; T1E=$TT_ENV; T1O=$TT_OUT
tok_titular "$tmp/wt/k2" "" phpunit tests/Feature/B.php; T2P=$TT_PID; T2F=$TT_FIFO; T2E=$TT_ENV; T2O=$TT_OUT
if [ "$(cat "$T1E")" = "token=101 par=1" ] && [ "$(cat "$T2E")" = "token=102 par=1" ]; then ok_; else fallo "AC-K1 tokens esperados 101 y 102, salió «$(cat "$T1E")» y «$(cat "$T2E")»"; fi
if ! grep -q 'esperando' "$T1O" "$T2O"; then ok_; else fallo "AC-K1 ninguno debía esperar la BD: $(cat "$T2O")"; fi
if [ -e "$BDD/127.0.0.1_3307_fx_k_test_101.lock" ] && [ -e "$BDD/127.0.0.1_3307_fx_k_test_102.lock" ] && [ ! -e "$BDD/127.0.0.1_3307_fx_k.lock" ]; then ok_
else fallo "AC-K1 faltan los locks por BD con token (o sobra el de la base): $(ls "$BDD")"; fi
# AC-K4: el arranque y estado muestran la BD con token
if grep -q '🔑 ParallelTesting token=101 · bd 127.0.0.1:3307/fx_k_test_101$' "$T1O" && grep -q '🔑 ParallelTesting token=102 · bd 127.0.0.1:3307/fx_k_test_102$' "$T2O"; then ok_
else fallo "AC-K4 el arranque debía mostrar la BD con token: $(cat "$T1O") / $(cat "$T2O")"; fi
est="$(bash "$FT" estado)"
if printf '%s\n' "$est" | grep -q "^dirigido: .*pid=$T1P .* · bd=127.0.0.1:3307/fx_k_test_101$" \
   && printf '%s\n' "$est" | grep -q "^dirigido: .*pid=$T2P .* · bd=127.0.0.1:3307/fx_k_test_102$"; then ok_
else fallo "AC-K4 estado debía mostrar bd=…/fx_k_test_101 y _102: $est"; fi
# con los dos huecos ocupados, un tercero sigue dando un token distinto (103)
tok_titular "$tmp/wt/k1" "" phpunit tests/Feature/C.php; T3P=$TT_PID; T3F=$TT_FIFO; T3E=$TT_ENV
if [ "$(cat "$T3E")" = "token=103 par=1" ]; then ok_; else fallo "AC-K1 el tercero debía tener token 103: $(cat "$T3E")"; fi
dt_soltar "$T3F" "$T3P"; dt_soltar "$T1F" "$T1P"; dt_soltar "$T2F" "$T2P"
# la BD con token se reutiliza: un run posterior en el hueco 1 vuelve a la 101
corre_tok "$tmp/wt/k2" 20 phpunit tests/Feature/D.php
if [ "$RC" -eq 0 ] && [ "$(cat "$ENVLOG")" = "token=101 par=1" ]; then ok_; else fallo "AC-K1 un run posterior debía reutilizar el token 101 (rc=$RC): $(cat "$ENVLOG")"; fi
# el replay normal sin -p va como un dirigido, con token
corre_tok "$tmp/wt/k1" 20 phpunit-replay run
if [ "$RC" -eq 0 ] && [ "$(cat "$ENVLOG")" = "token=101 par=1" ]; then ok_; else fallo "AC-K1 el replay sin -p debía llevar token (rc=$RC): $(cat "$ENVLOG")"; fi

# ---------- AC-K2: repo fuera de la lista: nada; un TEST_TOKEN del que llama no se toca ----------
corre_tok "$tmp/wt/k3" 20 phpunit tests/Feature/A.php
if [ "$RC" -eq 0 ] && [ "$(cat "$ENVLOG")" = "token=<sin> par=<sin>" ] && ! grep -q '🔑' "$tmp/corre.out"; then ok_; else fallo "AC-K2 fuera de la lista no debía haber token (rc=$RC): $(cat "$ENVLOG")"; fi
if [ -e "$BDD/127.0.0.1_3307_fx_k.lock" ]; then ok_; else fallo "AC-K2 fuera de la lista el lock debía ser el de la BD base: $(ls "$BDD")"; fi
(export TEST_TOKEN=7; corre_tok "$tmp/wt/k3" 20 phpunit tests/Feature/A.php; cp "$ENVLOG" "$tmp/envlog2"; echo "$RC" > "$tmp/rc2")
if [ "$(cat "$tmp/rc2")" -eq 0 ] && [ "$(cat "$tmp/envlog2")" = "token=7 par=<sin>" ]; then ok_; else fallo "AC-K2 un TEST_TOKEN del que llama debía quedar como está: $(cat "$tmp/envlog2")"; fi
(export TEST_TOKEN=7; corre_tok "$tmp/wt/k1" 20 phpunit tests/Feature/A.php; cp "$ENVLOG" "$tmp/envlog2"; cp "$tmp/corre.out" "$tmp/corre2.out"; echo "$RC" > "$tmp/rc2")
if [ "$(cat "$tmp/rc2")" -eq 0 ] && [ "$(cat "$tmp/envlog2")" = "token=7 par=<sin>" ] && ! grep -q '🔑' "$tmp/corre2.out"; then ok_
else fallo "AC-K2 en un repo de la lista, un TEST_TOKEN del que llama tampoco se toca: $(cat "$tmp/envlog2")"; fi
# sin .factory/env (checkout del usuario) no se aplica token aunque el repo esté en la lista
: > "$ENVLOG"
(cd "$tmp/repos/chico" && unset FX_TEST_PESADO && PATH="$tmp/fakebin:$PATH" FX_TEST_REPOS_TOKEN=chico FAKE_ENVLOG="$ENVLOG" FX_TEST_WAIT=20 exec bash "$FT" -- phpunit tests/Feature/A.php) > "$tmp/k2c.out" 2>&1
if [ "$(cat "$ENVLOG")" = "token=<sin> par=<sin>" ]; then ok_; else fallo "AC-K2 sin .factory/env no debía haber token: $(cat "$ENVLOG")"; fi
# con .factory/env pero sin DB_DATABASE no hay BD que sufijar: sin token aunque el repo esté en la lista
mkwt k4 127.0.0.1 3307 "" tokrepo
corre_tok "$tmp/wt/k4" 20 phpunit tests/Feature/A.php
if [ "$RC" -eq 0 ] && [ "$(cat "$ENVLOG")" = "token=<sin> par=<sin>" ] && ! grep -q '🔑' "$tmp/corre.out"; then ok_; else fallo "AC-K2 sin DB_DATABASE no debía haber token (rc=$RC): $(cat "$ENVLOG")"; fi

# ---------- AC-K3: pesado y paralelo: sin token y lock sobre la BD base ----------
export FX_TEST_REPOS_PESADOS="otro fabrik-prio-x pesado tokrepo"
for cmd in "phpunit" "phpunit -p 4" "phpunit-replay run -p 8"; do
  read -ra palabras <<< "$cmd"
  corre_tok "$tmp/wt/k1" 20 "${palabras[@]}"
  # (el dry-run previo del replay también deja su línea: se compara el conjunto)
  if [ "$RC" -eq 0 ] && [ "$(sort -u "$ENVLOG")" = "token=<sin> par=<sin>" ] && grep -q 'bd 127.0.0.1:3307/fx_k$' "$tmp/corre.out" && ! grep -q '🔑' "$tmp/corre.out"; then ok_
  else fallo "AC-K3 «$cmd» no debía llevar token y su BD era la base (rc=$RC): $(cat "$ENVLOG") / $(cat "$tmp/corre.out")"; fi
done
# un pesado titular (BD base): un dirigido con token no la espera
tok_titular "$tmp/wt/k1" "tokrepo" phpunit; P1P=$TT_PID; P1F=$TT_FIFO; P1E=$TT_ENV
if [ "$(cat "$P1E")" = "token=<sin> par=<sin>" ]; then ok_; else fallo "AC-K3 el pesado titular no debía llevar token: $(cat "$P1E")"; fi
(export FX_TEST_REPOS_PESADOS="otro fabrik-prio-x pesado"; corre_tok "$tmp/wt/k2" 20 phpunit tests/Feature/A.php)
if [ "$RC" -eq 0 ] && [ "$(cat "$ENVLOG")" = "token=101 par=1" ] && ! grep -q 'esperando' "$tmp/corre.out"; then ok_
else fallo "AC-K3 un dirigido con token no debía esperar la BD base del pesado (rc=$RC): $(cat "$tmp/corre.out")"; fi
dt_soltar "$P1F" "$P1P"
# a la inversa: un dirigido con token titular no frena a un pesado de la misma base (BD distintas)
tok_titular "$tmp/wt/k1" "" phpunit tests/Feature/A.php; D1P=$TT_PID; D1F=$TT_FIFO
corre_tok "$tmp/wt/k2" 20 phpunit
if [ "$RC" -eq 0 ] && ! grep -q 'esperando' "$tmp/corre.out"; then ok_; else fallo "AC-K3 un pesado (BD base) no debía esperar a un dirigido con token (rc=$RC): $(cat "$tmp/corre.out")"; fi
dt_soltar "$D1F" "$D1P"
export FX_TEST_REPOS_PESADOS="otro fabrik-prio-x pesado"

# ---------- AC-K5: sin lista, nada de token ----------
for caso in ausente vacia uv; do
  : > "$ENVLOG"
  (
    case "$caso" in
      ausente) unset FX_TEST_REPOS_TOKEN ;;
      vacia) export FX_TEST_REPOS_TOKEN="" ;;
      uv) mkdir -p "$tmp/fakeuv"; printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/fakeuv/uv"; chmod +x "$tmp/fakeuv/uv"; export PATH="$tmp/fakeuv:$PATH"; unset FX_TEST_REPOS_TOKEN ;;
    esac
    export FAKE_ENVLOG="$ENVLOG"; corre "$tmp/wt/k1" 20 phpunit tests/Feature/A.php; echo "$RC" > "$tmp/rc"
  )
  if [ "$(cat "$tmp/rc")" -eq 0 ] && [ "$(cat "$ENVLOG")" = "token=<sin> par=<sin>" ]; then ok_; else fallo "AC-K5 «$caso»: no debía haber token: $(cat "$ENVLOG")"; fi
done
# la lista también puede venir de la config; la env manda sobre ella
printf 'tests:\n  repos_token: [tokrepo]\n' > "$tmp/fabrik-token.yaml"
: > "$ENVLOG"; (unset FX_TEST_REPOS_TOKEN; export FABRIK_CONFIG="$tmp/fabrik-token.yaml" FAKE_ENVLOG="$ENVLOG"; corre "$tmp/wt/k1" 20 phpunit tests/Feature/A.php)
if [ "$(cat "$ENVLOG")" = "token=101 par=1" ]; then ok_; else fallo "AC-K1 tests.repos_token de la config debía activar el token: $(cat "$ENVLOG")"; fi
: > "$ENVLOG"; (export FX_TEST_REPOS_TOKEN="" FABRIK_CONFIG="$tmp/fabrik-token.yaml" FAKE_ENVLOG="$ENVLOG"; corre "$tmp/wt/k1" 20 phpunit tests/Feature/A.php)
if [ "$(cat "$ENVLOG")" = "token=<sin> par=<sin>" ]; then ok_; else fallo "AC-K5 la env vacía debía mandar sobre la config: $(cat "$ENVLOG")"; fi

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
