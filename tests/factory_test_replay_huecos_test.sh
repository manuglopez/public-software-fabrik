#!/usr/bin/env bash
# Tests de bin/factory-test: replay a la vez (clase `replay`, huecos de locks/replay.d/ y FX_TOKEN_OFFSET).
#
# AC-1.1  Con el repo en FX_TEST_REPOS_REPLAY, dos `phpunit-replay run -p 4` a la vez en dos worktrees con la
#         misma BD base cogen los huecos 1 y 2, con desfase 0 y 4, y corren a la vez.
# AC-1.2  Un tercero espera, entra cuando se libera un hueco y coge el desfase de ese hueco.
# AC-1.3  Un repo fuera de la lista va como dirigido con el lock de la BD base, sin FX_TOKEN_OFFSET, y dos van en fila.
# AC-1.4  Un replay degradado va como pesado (turno único), sin hueco de replay.
# AC-1.5  Con un pesado ocupando la BD base, el replay coge el hueco 2 (desfase 4) y no espera.
# AC-1.6  Con el replay en el hueco 1, un pesado sobre la misma BD base espera.
# AC-1.7  `estado` muestra los huecos con su desfase (y «(arrancando)» si el .owner está vacío).
# AC-1.8  FX_TEST_REPLAY_HUECOS=1 deja un solo hueco.
# AC-1.9  Un replay no paralelo de un repo de la lista sigue como dirigido.
# AC-1.10 El tope cambiado (FX_TEST_MAX_PROCESOS=2) da desfases 0 y 2.
# Extra   Config (tests.replay_simultaneo / tests.replay_huecos), la env vacía manda sobre la config, valores
#         inválidos de huecos, sin .factory/env → dirigido, FX_TOKEN_OFFSET ajeno se sobreescribe y se avisa.
#
# Binarios falsos en un PATH temporal; HOME, FABRIK_DATA y FABRIK_CONFIG temporales (nunca los reales). El
# `phpunit-replay` falso responde a `--dry-run` sin degradar (o con «structural change» si FAKE_REPLAY_DEGRADA=1)
# y, en `run`, escribe FX_TOKEN_OFFSET en un fichero y se queda bloqueado hasta que el test crea otro fichero.
# Bash puro, sin red. Uso: bash tests/factory_test_replay_huecos_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FT="$FABRIK_DIR/bin/factory-test"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
declare -A PIDS=()
limpiar() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap limpiar EXIT

F="$tmp/f"
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/data" "$tmp/cfg" "$F" "$tmp/wt"

# Binario falso bloqueante: en `run` anota el FX_TOKEN_OFFSET y los args, avisa y espera el fichero «libera».
cat > "$tmp/bin/fake-bloqueante" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == --dry-run ]]; then
    [[ -n "${FAKE_REPLAY_DEGRADA:-}" ]] && echo "structural change: remote baseline cannot be used"
    echo "dry-run ok"; exit 0
  fi
done
echo "${FX_TOKEN_OFFSET-<sin>}" > "$FAKE_DIR/$FAKE_ID.off"
echo "$*" > "$FAKE_DIR/$FAKE_ID.args"
: > "$FAKE_DIR/$FAKE_ID.dentro"
for ((i = 0; i < 300; i++)); do [[ -e "$FAKE_DIR/$FAKE_ID.libera" ]] && exit 0; sleep 0.1; done
exit 9
FAKE
chmod +x "$tmp/bin/fake-bloqueante"
for b in phpunit-replay paratest phpunit; do ln -s fake-bloqueante "$tmp/bin/$b"; done

export HOME="$tmp/home"
export FABRIK_DATA="$tmp/data"
export FABRIK_CONFIG="$tmp/cfg/fabrik.yaml"
export PATH="$tmp/bin:$PATH"
export FAKE_DIR="$F"
printf 'idioma: es\n' > "$FABRIK_CONFIG"
export FX_TEST_REPOS_PESADOS="tienda otro"
export FX_TEST_REPOS_REPLAY="tienda"
export FX_TEST_PAUSA=0.2
export FX_TEST_WAIT=60
unset FX_TEST_DUSK_PAUSADO FX_TEST_MAX_PROCESOS FX_TEST_DIRIGIDOS FX_TEST_LIGEROS FX_TEST_LIGERO FX_TEST_PESADO \
      FX_TEST_PRIO FX_TEST_REPOS_TOKEN FX_TEST_TIMEOUT FX_TEST_DRYRUN_TIMEOUT FX_TEST_REPLAY_HUECOS \
      FAKE_REPLAY_DEGRADA TEST_TOKEN LARAVEL_PARALLEL_TESTING FX_TOKEN_OFFSET HERMES_PROFILE

LOCKS="$FABRIK_DATA/locks"
BASE="127.0.0.1:3307/tienda_test"

# mkwt <nombre> [repo] → worktree con .factory/env (misma BD base 127.0.0.1:3307/<repo>_test)
mkwt() {
  mkdir -p "$tmp/wt/$1/.factory"
  printf 'FX_REPO=%s\nDB_HOST=127.0.0.1\nDB_PORT=3307\nDB_DATABASE=%s_test\n' "${2:-tienda}" "${2:-tienda}" > "$tmp/wt/$1/.factory/env"
}

# lanza <id> <worktree> <cmd…> → factory-test en segundo plano; salida en $tmp/<id>.out y rc en $tmp/<id>.rc
lanza() {
  local id="$1" wt="$2"; shift 2
  ( cd "$wt" && FAKE_ID="$id" "$FT" -- "$@" > "$tmp/$id.out" 2>&1; echo $? > "$tmp/$id.rc" ) &
  PIDS[$id]=$!
}

# espera_fichero <ruta> → rc 0 en cuanto existe (máx. ~20 s)
espera_fichero() {
  local i
  for ((i = 0; i < 200; i++)); do [[ -e "$1" ]] && return 0; sleep 0.1; done
  return 1
}
# espera_texto <fichero> <regex> → rc 0 en cuanto el fichero lo contiene
espera_texto() {
  local i
  for ((i = 0; i < 200; i++)); do grep -qE "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
dentro() { espera_fichero "$F/$1.dentro"; }
# libera <id> → deja terminar al falso y espera a que factory-test acabe
libera() { : > "$F/$1.libera"; wait "${PIDS[$1]}" 2>/dev/null; }
off() { cat "$F/$1.off" 2>/dev/null; }
no_dentro() { [[ ! -e "$F/$1.dentro" ]]; }
# espera un poco para dar tiempo a que algo (que NO debe pasar) se note
margen() { sleep 1; }
# Cuenta en cuántos de 50 sondeos (cada 50 ms) está suelto un lock. Un replay en espera
# solo lo coge un instante por reintento, así que debe verse suelto casi siempre.
sueltos() {
  local n=0 _
  for _ in $(seq 1 50); do
    if flock -n "$1" true; then n=$((n + 1)); fi
    sleep 0.05
  done
  echo "$n"
}

CMD=(phpunit-replay run -p 4)

# ---- AC-1.1 y AC-1.7: dos replay a la vez, huecos 1 y 2, desfase 0 y 4, y estado ----
mkwt a; mkwt b; mkwt c; mkwt p
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A || fallo "AC-1.1 A no arrancó: $(cat "$tmp/A.out")"
lanza B "$tmp/wt/b" "${CMD[@]}"; dentro B || fallo "AC-1.1 B no arrancó (¿esperó a A?): $(cat "$tmp/B.out")"
if [[ "$(off A)" == 0 && "$(off B)" == 4 ]]; then ok_; else fallo "AC-1.1 desfases esperados 0 y 4, salió «$(off A)» y «$(off B)»"; fi
if no_dentro A || no_dentro B; then fallo "AC-1.1 no corrían a la vez"; else ok_; fi
grep -q '▶ replay (phpunit-replay paralelo en hueco de replay)' "$tmp/A.out" || fallo "AC-1.1 el ▶ debía decir replay: $(cat "$tmp/A.out")"
grep -q "🔁 hueco de replay 1 · FX_TOKEN_OFFSET=0 · bd $BASE\$" "$tmp/A.out" || fallo "AC-1.1 línea del hueco 1: $(cat "$tmp/A.out")"
grep -q "🔁 hueco de replay 2 · FX_TOKEN_OFFSET=4 · bd $BASE@desfase4\$" "$tmp/B.out" || fallo "AC-1.1 línea del hueco 2: $(cat "$tmp/B.out")"
grep -q -- '-p 4' "$F/A.args" || fallo "AC-1.1 el replay debía recibir -p 4: $(cat "$F/A.args")"
ls "$tmp/data/logs/tests/" | grep -q -- '-tienda-replay-' || fallo "AC-1.1 el log debía llevar la clase replay: $(ls "$tmp/data/logs/tests/")"
# la BD con desfase tiene su propio lock y la base el suyo
[[ -e "$LOCKS/bd.d/127.0.0.1_3307_tienda_test.lock" && -e "$LOCKS/bd.d/127.0.0.1_3307_tienda_test_desfase4.lock" ]] \
  || fallo "AC-1.1 faltan los locks de BD (base y @desfase4): $(ls "$LOCKS/bd.d")"
# no coge hueco de dirigidos ni turno pesado
[[ ! -d "$LOCKS/dirigidos.d" ]] || ! ls "$LOCKS/dirigidos.d"/*.owner >/dev/null 2>&1 || fallo "AC-1.1 no debía usar dirigidos.d"
if "$FT" estado | grep -q '^libre$'; then ok_; else fallo "AC-1.1 el turno pesado debía seguir libre: $("$FT" estado)"; fi

# AC-1.7 estado
est="$("$FT" estado)"
grep -qE "^replay 1: .*repo=tienda \[replay\].* · desfase=0 · bd=$BASE\$" <<< "$est" || fallo "AC-1.7 línea del hueco 1: $est"
grep -qE "^replay 2: .*repo=tienda \[replay\].* · desfase=4 · bd=$BASE@desfase4\$" <<< "$est" || fallo "AC-1.7 línea del hueco 2: $est"
[[ "$(grep -c '^replay ' <<< "$est")" == 2 ]] && ok_ || fallo "AC-1.7 debía haber 2 líneas replay: $est"

# ---- AC-1.2: un tercero espera y coge el desfase del hueco que se libere ----
lanza C "$tmp/wt/c" "${CMD[@]}"
espera_texto "$tmp/C.out" '⏳ esperando hueco de replay \(2 en marcha\)' || fallo "AC-1.2 el tercero debía avisar de la espera: $(cat "$tmp/C.out")"
margen
no_dentro C && ok_ || fallo "AC-1.2 el tercero no debía entrar con los dos huecos cogidos"
libera B
dentro C || fallo "AC-1.2 el tercero no entró al liberarse el hueco 2: $(cat "$tmp/C.out")"
[[ "$(off C)" == 4 ]] && ok_ || fallo "AC-1.2 el tercero debía coger el desfase 4 (hueco 2), salió «$(off C)»"
[[ "$(grep -c 'esperando hueco de replay' "$tmp/C.out")" == 1 ]] && ok_ || fallo "AC-1.2 el aviso debía salir una sola vez: $(cat "$tmp/C.out")"
libera C; libera A
[[ "$(cat "$tmp/A.rc")" == 0 && "$(cat "$tmp/C.rc")" == 0 ]] && ok_ || fallo "AC-1.2 rc A=$(cat "$tmp/A.rc") C=$(cat "$tmp/C.rc")"
est="$("$FT" estado)"
grep -q '^replay ' <<< "$est" && fallo "AC-1.7 sin runs, estado no debía listar huecos de replay: $est" || ok_
rm -f "$F"/*

# ---- AC-1.5: con un pesado en la BD base, el replay coge el hueco 2 y no espera ----
lanza P "$tmp/wt/p" paratest -p 4; dentro P || fallo "AC-1.5 el pesado no arrancó: $(cat "$tmp/P.out")"
grep -q '▶ pesado' "$tmp/P.out" || fallo "AC-1.5 el paratest debía ir como pesado: $(cat "$tmp/P.out")"
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A || fallo "AC-1.5 el replay esperó al pesado: $(cat "$tmp/A.out")"
[[ "$(off A)" == 4 ]] && ok_ || fallo "AC-1.5 el replay debía coger el desfase 4 (hueco 2), salió «$(off A)»"
grep -q 'esperando' "$tmp/A.out" && fallo "AC-1.5 el replay no debía esperar: $(cat "$tmp/A.out")" || ok_
grep -q "bd $BASE@desfase4\$" "$tmp/A.out" && ok_ || fallo "AC-1.5 debía usar la BD @desfase4: $(cat "$tmp/A.out")"
# el hueco 1 queda libre pero su BD (la base) está ocupada: otro replay no entra en él
lanza B "$tmp/wt/b" "${CMD[@]}"
espera_texto "$tmp/B.out" '⏳ esperando hueco de replay' || fallo "AC-1.5 B debía esperar (hueco 2 y BD base ocupados): $(cat "$tmp/B.out")"
margen
no_dentro B && ok_ || fallo "AC-1.5 B no debía entrar con la BD base ocupada por el pesado"
# (B lo coge un instante en cada reintento para probar su BD: se sondea hasta verlo suelto)
suelto=$(sueltos "$LOCKS/replay.d/1.lock")
[[ $suelto -ge 25 ]] && ok_ || fallo "AC-1.5 el hueco 1 debía estar suelto mientras su BD estaba ocupada (suelto en $suelto/50 sondeos)"
libera P
dentro B || fallo "AC-1.5 B no entró al soltar el pesado la BD base: $(cat "$tmp/B.out")"
[[ "$(off B)" == 0 ]] && ok_ || fallo "AC-1.5 B debía coger el hueco 1 (desfase 0), salió «$(off B)»"
libera B; libera A
rm -f "$F"/*

# ---- AC-1.6: con el replay en el hueco 1, un pesado sobre la misma BD base espera ----
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A || fallo "AC-1.6 el replay no arrancó"
[[ "$(off A)" == 0 ]] && ok_ || fallo "AC-1.6 el replay debía estar en el hueco 1: «$(off A)»"
lanza P "$tmp/wt/p" paratest -p 4
espera_texto "$tmp/P.out" "⏳ esperando la BD $BASE" || fallo "AC-1.6 el pesado debía esperar la BD base: $(cat "$tmp/P.out")"
margen
no_dentro P && ok_ || fallo "AC-1.6 el pesado no debía entrar con el replay en el hueco 1"
libera A
dentro P || fallo "AC-1.6 el pesado no entró al terminar el replay: $(cat "$tmp/P.out")"
libera P
rm -f "$F"/*

# ---- AC-1.3: un repo fuera de la lista va como dirigido con la BD base, sin FX_TOKEN_OFFSET, y en fila ----
mkwt o1 otro; mkwt o2 otro
rm -rf "$LOCKS/replay.d"
lanza O1 "$tmp/wt/o1" "${CMD[@]}"; dentro O1 || fallo "AC-1.3 O1 no arrancó: $(cat "$tmp/O1.out")"
grep -q '▶ dirigido (phpunit-replay normal)' "$tmp/O1.out" || fallo "AC-1.3 debía ir como dirigido: $(cat "$tmp/O1.out")"
[[ "$(off O1)" == "<sin>" ]] && ok_ || fallo "AC-1.3 sin FX_TOKEN_OFFSET: «$(off O1)»"
[[ ! -d "$LOCKS/replay.d" ]] && ok_ || fallo "AC-1.3 no debía tocar replay.d"
lanza O2 "$tmp/wt/o2" "${CMD[@]}"
espera_texto "$tmp/O2.out" '⏳ esperando la BD 127.0.0.1:3307/otro_test' || fallo "AC-1.3 el segundo debía esperar la BD base: $(cat "$tmp/O2.out")"
margen
no_dentro O2 && ok_ || fallo "AC-1.3 los dos dirigidos debían ir en fila"
libera O1; dentro O2 || fallo "AC-1.3 O2 no entró al terminar O1"
libera O2
rm -f "$F"/*

# ---- AC-1.9: replay no paralelo de un repo de la lista sigue como dirigido ----
rm -rf "$LOCKS/replay.d"
lanza A "$tmp/wt/a" phpunit-replay run; dentro A || fallo "AC-1.9 no arrancó: $(cat "$tmp/A.out")"
grep -q '▶ dirigido (phpunit-replay normal)' "$tmp/A.out" || fallo "AC-1.9 debía ir como dirigido: $(cat "$tmp/A.out")"
[[ "$(off A)" == "<sin>" ]] && ok_ || fallo "AC-1.9 sin FX_TOKEN_OFFSET: «$(off A)»"
grep -q "bd $BASE\$" "$tmp/A.out" && ok_ || fallo "AC-1.9 debía llevar el lock de la BD base: $(cat "$tmp/A.out")"
[[ ! -d "$LOCKS/replay.d" ]] && ok_ || fallo "AC-1.9 no debía tocar replay.d"
libera A
rm -f "$F"/*
# -p 1 tampoco es paralelo
lanza A "$tmp/wt/a" phpunit-replay run -p 1; dentro A
grep -q '▶ dirigido' "$tmp/A.out" && ok_ || fallo "AC-1.9 -p 1 debía ir como dirigido: $(cat "$tmp/A.out")"
libera A
rm -f "$F"/*

# ---- sin .factory/env (checkout del usuario): dirigido ----
mkdir -p "$tmp/sinenv/tienda"
# (con DB_DATABASE en el entorno de quien llama: sin .factory/env sigue sin haber BD propia del worktree)
( cd "$tmp/sinenv/tienda" && FAKE_ID=S FX_REPO=tienda DB_DATABASE=tienda_test "$FT" -- phpunit-replay run -p 4 > "$tmp/S.out" 2>&1; echo $? > "$tmp/S.rc" ) &
PIDS[S]=$!
dentro S || fallo "sin env: no arrancó: $(cat "$tmp/S.out")"
if grep -q '▶ dirigido' "$tmp/S.out" && [[ "$(off S)" == "<sin>" ]]; then ok_; else fallo "sin .factory/env debía ir como dirigido y sin desfase: $(cat "$tmp/S.out") / «$(off S)»"; fi
libera S
rm -f "$F"/*

# ---- AC-1.4: replay degradado → pesado, sin hueco de replay ----
rm -rf "$LOCKS/replay.d"
export FAKE_REPLAY_DEGRADA=1
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A || fallo "AC-1.4 no arrancó: $(cat "$tmp/A.out")"
grep -q '▶ pesado (replay degradado a suite completa (structural change))' "$tmp/A.out" || fallo "AC-1.4 debía ir como pesado: $(cat "$tmp/A.out")"
[[ "$(off A)" == "<sin>" ]] && ok_ || fallo "AC-1.4 un pesado no lleva FX_TOKEN_OFFSET: «$(off A)»"
[[ ! -d "$LOCKS/replay.d" ]] && ok_ || fallo "AC-1.4 el degradado no debía tocar replay.d"
lanza B "$tmp/wt/b" "${CMD[@]}"
espera_texto "$tmp/B.out" '⏳ esperando turno de tests' || fallo "AC-1.4 el segundo degradado debía esperar el turno único: $(cat "$tmp/B.out")"
margen
no_dentro B && ok_ || fallo "AC-1.4 dos degradados no pueden ir a la vez (turno único)"
libera A; dentro B || fallo "AC-1.4 B no entró al soltar A el turno"
libera B
unset FAKE_REPLAY_DEGRADA
rm -f "$F"/*

# ---- AC-1.8: FX_TEST_REPLAY_HUECOS=1 deja un solo hueco ----
rm -rf "$LOCKS/replay.d"
export FX_TEST_REPLAY_HUECOS=1
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A || fallo "AC-1.8 A no arrancó"
lanza B "$tmp/wt/b" "${CMD[@]}"
espera_texto "$tmp/B.out" '⏳ esperando hueco de replay \(1 en marcha\)' || fallo "AC-1.8 B debía esperar con un solo hueco: $(cat "$tmp/B.out")"
margen
no_dentro B && ok_ || fallo "AC-1.8 con un solo hueco, B no debía entrar"
[[ ! -e "$LOCKS/replay.d/2.lock" ]] && ok_ || fallo "AC-1.8 no debía existir el hueco 2"
libera A; dentro B || fallo "AC-1.8 B no entró al liberarse el hueco"
[[ "$(off B)" == 0 ]] && ok_ || fallo "AC-1.8 B debía coger el hueco 1: «$(off B)»"
libera B
rm -f "$F"/*
# valores inválidos de huecos (abc, 0, vacío, negativo) caen a la siguiente fuente: aquí, el 2 por defecto
for v in abc 0 "" -3 1.5; do
  rm -rf "$LOCKS/replay.d"
  export FX_TEST_REPLAY_HUECOS="$v"
  lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
  lanza B "$tmp/wt/b" "${CMD[@]}"
  if dentro B; then ok_; else fallo "AC-1.8 FX_TEST_REPLAY_HUECOS=«$v» inválido debía caer a 2 huecos: $(cat "$tmp/B.out")"; fi
  libera A; libera B
  rm -f "$F"/*
done
unset FX_TEST_REPLAY_HUECOS
# y con 3 huecos, tres a la vez con desfases 0, 4 y 8
rm -rf "$LOCKS/replay.d"
export FX_TEST_REPLAY_HUECOS=3
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
lanza B "$tmp/wt/b" "${CMD[@]}"; dentro B
lanza C "$tmp/wt/c" "${CMD[@]}"; dentro C || fallo "AC-1.8 con 3 huecos C debía entrar: $(cat "$tmp/C.out")"
[[ "$(off A) $(off B) $(off C)" == "0 4 8" ]] && ok_ || fallo "AC-1.8 desfases 0 4 8, salió «$(off A) $(off B) $(off C)»"
libera A; libera B; libera C
unset FX_TEST_REPLAY_HUECOS
rm -f "$F"/*

# ---- AC-1.10: tope cambiado → desfases 0 y 2 ----
rm -rf "$LOCKS/replay.d"
export FX_TEST_MAX_PROCESOS=2
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
lanza B "$tmp/wt/b" "${CMD[@]}"; dentro B || fallo "AC-1.10 B no arrancó: $(cat "$tmp/B.out")"
[[ "$(off A) $(off B)" == "0 2" ]] && ok_ || fallo "AC-1.10 desfases 0 y 2, salió «$(off A) $(off B)»"
grep -q -- '-p 2' "$F/A.args" && ok_ || fallo "AC-1.10 el tope debía rebajar a -p 2: $(cat "$F/A.args")"
grep -q "@desfase2\$" "$tmp/B.out" && ok_ || fallo "AC-1.10 el hueco 2 debía usar @desfase2: $(cat "$tmp/B.out")"
libera A; libera B
unset FX_TEST_MAX_PROCESOS
rm -f "$F"/*

# ---- FX_TOKEN_OFFSET ajeno: se sobreescribe y se avisa; si coincide, sin aviso ----
rm -rf "$LOCKS/replay.d"
export FX_TOKEN_OFFSET=9
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
[[ "$(off A)" == 0 ]] && ok_ || fallo "FX_TOKEN_OFFSET ajeno debía sobreescribirse con 0: «$(off A)»"
[[ "$(grep -c 'FX_TOKEN_OFFSET=9 del entorno se sobreescribe con 0' "$tmp/A.out")" == 1 ]] && ok_ || fallo "debía avisar una vez de la sobreescritura: $(cat "$tmp/A.out")"
libera A
rm -f "$F"/*
export FX_TOKEN_OFFSET=0
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
grep -q 'se sobreescribe' "$tmp/A.out" && fallo "un FX_TOKEN_OFFSET igual no debía avisar: $(cat "$tmp/A.out")" || ok_
libera A
unset FX_TOKEN_OFFSET
rm -f "$F"/*

# ---- D-1: config (tests.replay_simultaneo / tests.replay_huecos) y la env vacía manda sobre la config ----
unset FX_TEST_REPOS_REPLAY
rm -rf "$LOCKS/replay.d"
# sin lista (env ausente y clave ausente): ningún repo → dirigido
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
grep -q '▶ dirigido' "$tmp/A.out" && ok_ || fallo "sin lista ningún repo debía ir como dirigido: $(cat "$tmp/A.out")"
libera A
rm -f "$F"/*
printf 'tests:\n  replay_simultaneo: [tienda, otro-repo]\n  replay_huecos: 1\n' > "$FABRIK_CONFIG"
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
grep -q '▶ replay' "$tmp/A.out" && ok_ || fallo "la config debía activar el replay a la vez: $(cat "$tmp/A.out")"
lanza B "$tmp/wt/b" "${CMD[@]}"
espera_texto "$tmp/B.out" '⏳ esperando hueco de replay \(1 en marcha\)' || fallo "tests.replay_huecos=1 debía dejar un hueco: $(cat "$tmp/B.out")"
libera A; dentro B; libera B
rm -f "$F"/*
# una env vacía manda sobre la config: ningún repo
export FX_TEST_REPOS_REPLAY=""
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
grep -q '▶ dirigido' "$tmp/A.out" && ok_ || fallo "FX_TEST_REPOS_REPLAY vacía debía mandar sobre la config: $(cat "$tmp/A.out")"
libera A
rm -f "$F"/*
# la env de huecos manda sobre la config
export FX_TEST_REPOS_REPLAY="tienda" FX_TEST_REPLAY_HUECOS=2
rm -rf "$LOCKS/replay.d"
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
lanza B "$tmp/wt/b" "${CMD[@]}"; dentro B && ok_ || fallo "FX_TEST_REPLAY_HUECOS=2 debía mandar sobre tests.replay_huecos=1: $(cat "$tmp/B.out")"
libera A; libera B
unset FX_TEST_REPLAY_HUECOS
rm -f "$F"/*
# config inválida de huecos → 2 por defecto
printf 'tests:\n  replay_huecos: 0\n' > "$FABRIK_CONFIG"
rm -rf "$LOCKS/replay.d"
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
lanza B "$tmp/wt/b" "${CMD[@]}"; dentro B && ok_ || fallo "tests.replay_huecos=0 debía caer a 2: $(cat "$tmp/B.out")"
libera A; libera B
printf 'idioma: es\n' > "$FABRIK_CONFIG"
rm -f "$F"/*

# ---- hueco libre pero con su BD ocupada: no se retiene el hueco mientras se espera ----
rm -rf "$LOCKS/replay.d"; mkdir -p "$LOCKS/bd.d"
export FX_TEST_REPLAY_HUECOS=2
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
( flock 7; sleep 8 ) 7>"$LOCKS/bd.d/127.0.0.1_3307_tienda_test_desfase4.lock" &
PIDS[H2]=$!
sleep 0.3
lanza B "$tmp/wt/b" "${CMD[@]}"
espera_texto "$tmp/B.out" '⏳ esperando hueco de replay \(2 en marcha\)' || fallo "hueco 2 con la BD ocupada: B debía esperar: $(cat "$tmp/B.out")"
suelto=$(sueltos "$LOCKS/replay.d/2.lock")
[[ $suelto -ge 25 ]] && ok_ || fallo "el hueco 2 debía soltarse mientras su BD estaba ocupada (suelto en $suelto/50 sondeos)"
no_dentro B && ok_ || fallo "B no debía entrar con el hueco 1 cogido y la BD del 2 ocupada"
kill "${PIDS[H2]}" 2>/dev/null; wait "${PIDS[H2]}" 2>/dev/null
dentro B || fallo "B no entró al liberarse la BD del hueco 2: $(cat "$tmp/B.out")"
[[ "$(off B)" == 4 ]] && ok_ || fallo "B debía coger el hueco 2 (desfase 4): «$(off B)»"
libera A; libera B
unset FX_TEST_REPLAY_HUECOS
rm -f "$F"/*

# ---- con .factory/env pero sin DB_DATABASE no hay BD que repartir: dirigido ----
mkdir -p "$tmp/wt/sinbd/.factory"
printf 'FX_REPO=tienda\n' > "$tmp/wt/sinbd/.factory/env"
rm -rf "$LOCKS/replay.d"
( cd "$tmp/wt/sinbd" && unset DB_DATABASE DB_HOST DB_PORT && FAKE_ID=N "$FT" -- phpunit-replay run -p 4 > "$tmp/N.out" 2>&1; echo $? > "$tmp/N.rc" ) &
PIDS[N]=$!
dentro N || fallo "sin DB_DATABASE: no arrancó: $(cat "$tmp/N.out")"
if grep -q '▶ dirigido' "$tmp/N.out" && [[ "$(off N)" == "<sin>" ]]; then ok_; else fallo "sin DB_DATABASE debía ir como dirigido y sin desfase: $(cat "$tmp/N.out") / «$(off N)»"; fi
libera N
rm -f "$F"/*

# ---- limpieza: al terminar, los .owner del hueco y de la BD quedan vacíos ----
rm -rf "$LOCKS/replay.d"
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
lanza B "$tmp/wt/b" "${CMD[@]}"; dentro B
[[ -s "$LOCKS/replay.d/2.owner" && -s "$LOCKS/bd.d/127.0.0.1_3307_tienda_test_desfase4.owner" ]] && ok_ || fallo "con el replay en marcha, los .owner del hueco 2 y su BD debían tener contenido"
[[ "$(sed -n 2p "$LOCKS/replay.d/2.owner")" == "$BASE@desfase4" && "$(sed -n 3p "$LOCKS/replay.d/2.owner")" == 4 ]] && ok_ || fallo "el .owner del hueco 2 debía llevar quién, clave y desfase: $(cat "$LOCKS/replay.d/2.owner")"
libera A; libera B
if [[ ! -s "$LOCKS/replay.d/1.owner" && ! -s "$LOCKS/replay.d/2.owner" && ! -s "$LOCKS/bd.d/127.0.0.1_3307_tienda_test.owner" && ! -s "$LOCKS/bd.d/127.0.0.1_3307_tienda_test_desfase4.owner" ]]; then ok_
else fallo "al salir, los .owner de hueco y de BD debían quedar vacíos"; fi
rm -f "$F"/*

# ---- ceros a la izquierda (FX_TEST_REPLAY_HUECOS=01 → un hueco, no error de octal) ----
rm -rf "$LOCKS/replay.d"
export FX_TEST_REPLAY_HUECOS=01
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
lanza B "$tmp/wt/b" "${CMD[@]}"
espera_texto "$tmp/B.out" '⏳ esperando hueco de replay \(1 en marcha\)' || fallo "FX_TEST_REPLAY_HUECOS=01 debía valer 1: $(cat "$tmp/B.out")"
libera A; dentro B; libera B
unset FX_TEST_REPLAY_HUECOS
rm -f "$F"/*

# ---- sin hueco libre dentro de FX_TEST_WAIT: «sin turno» y rc 75 ----
rm -rf "$LOCKS/replay.d"
export FX_TEST_REPLAY_HUECOS=1
lanza A "$tmp/wt/a" "${CMD[@]}"; dentro A
( cd "$tmp/wt/b" && FAKE_ID=W FX_TEST_WAIT=1 "$FT" -- "${CMD[@]}" > "$tmp/W.out" 2>&1; echo $? > "$tmp/W.rc" ) &
PIDS[W]=$!
wait "${PIDS[W]}"
[[ "$(cat "$tmp/W.rc")" == 75 ]] && grep -q '✗ sin turno tras 1s' "$tmp/W.out" && ok_ || fallo "sin hueco debía salir con rc 75 y «sin turno»: rc=$(cat "$tmp/W.rc") $(cat "$tmp/W.out")"
no_dentro W && ok_ || fallo "el que se quedó sin turno no debía ejecutar nada"
libera A
unset FX_TEST_REPLAY_HUECOS
rm -f "$F"/*

# ---- AC-1.7 (arrancando): hueco cogido (flock vivo) con el .owner vacío ----
rm -rf "$LOCKS/replay.d"; mkdir -p "$LOCKS/replay.d"
: > "$LOCKS/replay.d/1.owner"
( flock 8; sleep 5 ) 8>"$LOCKS/replay.d/1.lock" &
PIDS[H]=$!
sleep 0.3
est="$("$FT" estado)"
grep -q '^replay 1: (arrancando)$' <<< "$est" && ok_ || fallo "AC-1.7 debía mostrar (arrancando): $est"
kill "${PIDS[H]}" 2>/dev/null; wait "${PIDS[H]}" 2>/dev/null
# un .owner suelto de un proceso muerto no cuenta
printf 'alguien\nclave\n4\n' > "$LOCKS/replay.d/2.owner"; : > "$LOCKS/replay.d/2.lock"
est="$("$FT" estado)"
grep -q '^replay ' <<< "$est" && fallo "un .owner huérfano no debía listarse: $est" || ok_

echo "factory_test_replay_huecos_test: $ok ok, $fail fallos"
[[ $fail -eq 0 ]]
