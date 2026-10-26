#!/usr/bin/env bash
# Tests de bin/factory-test: pausa de Dusk y tope de procesos en paralelo (integra en el script lo que
# hacía el overlay ~/.hermes/factory/bin-live/factory-test, sin tocarlo).
#
# AC-1 Tope de procesos (por defecto 4; fuentes FX_TEST_MAX_PROCESOS > $CFG_DIR/max-procesos-tests >
#      tests.max_procesos, y un valor que no sea un entero ≥ 1 cae a la siguiente fuente):
#      · phpunit-replay run -p 8        → -p 4
#      · phpunit-replay run -p          → -p 4
#      · paratest -p8                   → -p4
#      · --processes=12                 → --processes=4
#      · php artisan test --parallel    → se añade --processes=4
#      · -p 2 se queda igual; phpunit --filter X no se toca; -p12 pegado multígito se rebaja
#      · precedencia env > fichero > config, con valor inválido cayendo a la siguiente fuente, y la env
#        válida mandando sobre el fichero aunque ambos estén presentes
# AC-2 Pausa de Dusk (misma precedencia: env > fichero dusk-pausado > tests.dusk_pausado):
#      · con el flag activo, `artisan` con el comando `dusk` → exit 3, y un .sh que llama a otro .sh que
#        lanza tests/<Browser> → exit 3; el exit 3 no deja ningún lock ni hueco cogido
#      · sin el flag, Dusk pasa al comando falso
#      (los literales que casarían la regex de Dusk se construyen en runtime: si este propio fichero los
#      trajera, el factory-test externo que lo ejecuta los detectaría y se auto-rechazaría con exit 3)
#
# Los comandos usan binarios falsos (phpunit-replay, paratest, php, phpunit) en un PATH temporal que
# imprimen sus argumentos; HOME, FABRIK_DATA y FABRIK_CONFIG son temporales (nunca el ~/.config/fabrica
# real). Bash puro, sin red. Uso: bash tests/factory_test_tope_dusk_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FT="$FABRIK_DIR/bin/factory-test"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
limpiar() { rm -rf "$tmp"; }
trap limpiar EXIT

mkdir -p "$tmp/bin" "$tmp/home" "$tmp/data" "$tmp/cfg"
# Binarios falsos: imprimen cada argumento recibido, uno por línea, y aciertan.
for b in php phpunit phpunit-replay paratest; do
  printf '#!/usr/bin/env bash\nprintf "ARG<%%s>\\n" "$@"\n' > "$tmp/bin/$b"
  chmod +x "$tmp/bin/$b"
done

export HOME="$tmp/home"
export FABRIK_DATA="$tmp/data"
export FABRIK_CONFIG="$tmp/cfg/fabrik.yaml"
export PATH="$tmp/bin:$PATH"
printf 'idioma: es\n' > "$FABRIK_CONFIG"
# Repo no pesado: todo es dirigido (sin turno único ni dry-run del replay) y cada run suelta enseguida.
export FX_TEST_REPOS_PESADOS=""
unset FX_TEST_DUSK_PAUSADO FX_TEST_MAX_PROCESOS FX_TEST_DIRIGIDOS FX_TEST_LIGEROS FX_TEST_LIGERO \
      FX_TEST_PESADO FX_TEST_PRIO FX_TEST_REPOS_TOKEN FX_TEST_WAIT FX_TEST_TIMEOUT FX_TEST_PAUSA \
      FX_TEST_DRYRUN_TIMEOUT TEST_TOKEN LARAVEL_PARALLEL_TESTING HERMES_PROFILE

CFG_DIR="$tmp/cfg"

# ft <cmd…> → ejecuta factory-test con los ajustes actuales; deja el rc en $rc y la salida en $out
ft() {
  out="$("$FT" -- "$@" 2>&1)"; rc=$?
}

# sin_locks → ¿el exit 3 (o cualquier ejecución) no dejó ningún lock ni hueco cogido?
sin_locks() {
  local f
  [[ -s "$FABRIK_DATA/locks/factory-test.owner" ]] && return 1
  for f in "$FABRIK_DATA/locks/dirigidos.d/"*.owner "$FABRIK_DATA/locks/ligeros.d/"*.owner \
           "$FABRIK_DATA/locks/bd.d/"*.owner; do
    [[ -e "$f" ]] || continue
    [[ -s "$f" ]] && return 1
  done
  return 0
}

# ---- AC-1: tope de procesos (tope por defecto 4) ----

ft phpunit-replay run -p 8
(( rc == 0 )) || fallo "AC-1 phpunit-replay run -p 8: rc=$rc"
grep -q 'tope de 4 procesos' <<< "$out" || fallo "AC-1 -p 8: sin línea de tope: $out"
grep -q 'ARG<-p>' <<< "$out" && grep -q 'ARG<4>' <<< "$out" || fallo "AC-1 -p 8: no rebajado a -p 4: $out"
grep -q 'ARG<8>' <<< "$out" && fallo "AC-1 -p 8: llegó el 8 al comando: $out"
ok_

ft phpunit-replay run -p
(( rc == 0 )) || fallo "AC-1 phpunit-replay run -p: rc=$rc"
grep -q 'ARG<-p>' <<< "$out" && grep -q 'ARG<4>' <<< "$out" || fallo "AC-1 -p suelto: no recibió 4: $out"
ok_

ft paratest -p8
(( rc == 0 )) || fallo "AC-1 paratest -p8: rc=$rc"
grep -q 'ARG<-p4>' <<< "$out" || fallo "AC-1 -p8: no rebajado a -p4: $out"
ok_

# pegado multígito también se rebaja
ft paratest -p12
(( rc == 0 )) || fallo "AC-1 paratest -p12: rc=$rc"
grep -q 'ARG<-p4>' <<< "$out" || fallo "AC-1 -p12: no rebajado a -p4: $out"
ok_

ft phpunit-replay run --processes=12
(( rc == 0 )) || fallo "AC-1 --processes=12: rc=$rc"
grep -q 'ARG<--processes=4>' <<< "$out" || fallo "AC-1 --processes=12: no rebajado a =4: $out"
ok_

ft php artisan test --parallel
(( rc == 0 )) || fallo "AC-1 artisan test --parallel: rc=$rc"
grep -q 'ARG<--processes=4>' <<< "$out" || fallo "AC-1 artisan --parallel: sin --processes=4: $out"
ok_

ft phpunit-replay run -p 2
(( rc == 0 )) || fallo "AC-1 -p 2: rc=$rc"
grep -q 'tope de 4 procesos' <<< "$out" && fallo "AC-1 -p 2: sobró la línea de tope: $out"
grep -q 'ARG<2>' <<< "$out" || fallo "AC-1 -p 2: no llegó el 2: $out"
ok_

# igual al tope: no se toca ni se anuncia rebaja
ft phpunit-replay run -p 4
(( rc == 0 )) || fallo "AC-1 -p 4 (igual al tope): rc=$rc"
grep -q 'tope de 4 procesos' <<< "$out" && fallo "AC-1 -p 4: sobró la línea de tope: $out"
grep -q 'ARG<4>' <<< "$out" || fallo "AC-1 -p 4: no llegó el 4: $out"
ok_

ft phpunit-replay run --parallel=12
(( rc == 0 )) || fallo "AC-1 --parallel=12: rc=$rc"
grep -q 'ARG<--parallel=4>' <<< "$out" || fallo "AC-1 --parallel=12: no rebajado a =4: $out"
ok_

ft phpunit --filter X
(( rc == 0 )) || fallo "AC-1 phpunit --filter X: rc=$rc"
grep -q 'tope de 4 procesos' <<< "$out" && fallo "AC-1 --filter X: sobró la línea de tope: $out"
grep -q 'ARG<--filter>' <<< "$out" && grep -q 'ARG<X>' <<< "$out" || fallo "AC-1 --filter X: tocado: $out"
ok_

# ---- AC-1: precedencia del tope (env > fichero > config) y valor inválido que cae ----

export FX_TEST_MAX_PROCESOS=2
ft phpunit-replay run -p 8
(( rc == 0 )) && grep -q 'tope de 2 procesos' <<< "$out" && grep -q 'ARG<2>' <<< "$out" \
  || fallo "AC-1 tope env=2: $out"
unset FX_TEST_MAX_PROCESOS
ok_

export FX_TEST_MAX_PROCESOS=1
ft phpunit-replay run -p 8
(( rc == 0 )) && grep -q 'tope de 1 procesos' <<< "$out" && grep -q 'ARG<1>' <<< "$out" \
  || fallo "AC-1 tope env=1: $out"
unset FX_TEST_MAX_PROCESOS
ok_

# env válida MANDA sobre el fichero (precedencia env > fichero con ambas presentes)
printf ' 3 \n' > "$CFG_DIR/max-procesos-tests"
export FX_TEST_MAX_PROCESOS=2
ft phpunit-replay run -p 8
(( rc == 0 )) && grep -q 'tope de 2 procesos' <<< "$out" && grep -q 'ARG<2>' <<< "$out" \
  || fallo "AC-1 env válida manda sobre fichero=3: $out"
unset FX_TEST_MAX_PROCESOS
ok_

# fichero sin env: manda el fichero
ft phpunit-replay run -p 8
(( rc == 0 )) && grep -q 'tope de 3 procesos' <<< "$out" && grep -q 'ARG<3>' <<< "$out" \
  || fallo "AC-1 fichero=3 sin env: $out"
ok_

# env inválida cae al fichero (fichero ya creado arriba)
ft phpunit-replay run -p 8
(( rc == 0 )) && grep -q 'tope de 3 procesos' <<< "$out" && grep -q 'ARG<3>' <<< "$out" \
  || fallo "AC-1 env inválido cae al fichero=3: $out"
export FX_TEST_MAX_PROCESOS=0   # 0 no es un entero ≥ 1: cae también
ft phpunit-replay run -p 8
(( rc == 0 )) && grep -q 'tope de 3 procesos' <<< "$out" \
  || fallo "AC-1 env=0 cae al fichero=3: $out"
unset FX_TEST_MAX_PROCESOS
ok_

printf 'cero\n' > "$CFG_DIR/max-procesos-tests"   # fichero inválido: cae a la config
printf 'tests:\n  max_procesos: 5\n' > "$FABRIK_CONFIG"
ft phpunit-replay run -p 8
(( rc == 0 )) && grep -q 'tope de 5 procesos' <<< "$out" && grep -q 'ARG<5>' <<< "$out" \
  || fallo "AC-1 fichero inválido cae a config=5: $out"
ok_

printf 'tests:\n  max_procesos: nada\n' > "$FABRIK_CONFIG"   # config inválida: cae al 4 por defecto
rm -f "$CFG_DIR/max-procesos-tests"
ft phpunit-replay run -p 8
(( rc == 0 )) && grep -q 'tope de 4 procesos' <<< "$out" && grep -q 'ARG<4>' <<< "$out" \
  || fallo "AC-1 config inválida cae al 4 por defecto: $out"
ok_

# ---- AC-2: pausa de Dusk ----
# DUSK y BR se ensamblan en runtime: si este fichero contuviera en claro los literales que casan la
# regex de Dusk, el propio factory-test externo que nos ejecuta (con la pausa activa) se detectaría a
# sí mismo en el contenido del script y se rechazaría con exit 3 antes de arrancar los tests.
DUSK="du""sk"; BR="Bro""wser"

printf 'idioma: es\n' > "$FABRIK_CONFIG"   # sin tests.dusk_pausado: el flag manda solo si existe

# flag activo vía env: rechazo directo en los argumentos
export FX_TEST_DUSK_PAUSADO=1
ft php artisan "$DUSK"
(( rc == 3 )) || fallo "AC-2 comando Dusk con flag: rc=$rc (out=$out)"
grep -q 'Dusk está en pausa (flag dusk-pausado)' <<< "$out" || fallo "AC-2 mensaje del flag: $out"
sin_locks || fallo "AC-2 exit 3 dejó lock/hueco cogido"
ok_

# flag activo vía fichero: un .sh que llama a otro .sh que lanza tests/<Browser> → exit 3
unset FX_TEST_DUSK_PAUSADO
printf 'pausa de mantenimiento\n' > "$CFG_DIR/dusk-pausado"
cat > "$tmp/nivel1.sh" <<'EOF'
#!/usr/bin/env bash
bash "$(dirname "$0")/nivel2.sh"
EOF
cat > "$tmp/nivel2.sh" <<EOF
#!/usr/bin/env bash
php artisan test "tests/$BR"
EOF
chmod +x "$tmp/nivel1.sh" "$tmp/nivel2.sh"
ft bash "$tmp/nivel1.sh"
(( rc == 3 )) || fallo "AC-2 .sh anidado con flag de fichero: rc=$rc (out=$out)"
grep -q 'Dusk está en pausa (pausa de mantenimiento)' <<< "$out" || fallo "AC-2 motivo del fichero: $out"
sin_locks || fallo "AC-2 exit 3 (.sh anidado) dejó lock/hueco cogido"
ok_

# límite de 2 niveles: el Dusk en un tercer .sh ya NO se detecta y el comando llega a ejecutarse
# (n1 llama a n2, n2 llama a n3; n1 y n2 están limpios, solo n3 tiene el token — nivel 3, fuera de alcance)
cat > "$tmp/n1.sh" <<'EOF'
#!/usr/bin/env bash
bash "$(dirname "$0")/n2.sh"
EOF
cat > "$tmp/n2.sh" <<'EOF'
#!/usr/bin/env bash
bash "$(dirname "$0")/nivel3.sh"
EOF
cat > "$tmp/nivel3.sh" <<EOF
#!/usr/bin/env bash
php artisan test "tests/$BR"
EOF
chmod +x "$tmp/n1.sh" "$tmp/n2.sh" "$tmp/nivel3.sh"
ft bash "$tmp/n1.sh"
(( rc == 0 )) && grep -q 'ARG<artisan>' <<< "$out" \
  || fallo "AC-2 tercer nivel no debe rechazarse: rc=$rc out=$out"
ok_

# fichero vacío: motivo por defecto
: > "$CFG_DIR/dusk-pausado"
ft php artisan "$DUSK"
(( rc == 3 )) && grep -q 'Dusk está en pausa (dusk-pausado)' <<< "$out" \
  || fallo "AC-2 fichero vacío con motivo por defecto: rc=$rc out=$out"
ok_

# valor «si» activa la pausa
export FX_TEST_DUSK_PAUSADO=si
ft php artisan "$DUSK"
(( rc == 3 )) || fallo "AC-2 env=si activa la pausa: rc=$rc"
unset FX_TEST_DUSK_PAUSADO
ok_

# env manda sobre el fichero: 0 desactiva aunque exista dusk-pausado
export FX_TEST_DUSK_PAUSADO=0
ft php artisan "$DUSK"
(( rc == 0 )) && grep -q "ARG<$DUSK>" <<< "$out" || fallo "AC-2 env=0 manda sobre fichero: rc=$rc out=$out"
unset FX_TEST_DUSK_PAUSADO
ok_

# env vacía también desactiva (está definida: manda ella y no se cae al fichero)
export FX_TEST_DUSK_PAUSADO=""
ft php artisan "$DUSK"
(( rc == 0 )) && grep -q "ARG<$DUSK>" <<< "$out" || fallo "AC-2 env vacía desactiva: rc=$rc out=$out"
unset FX_TEST_DUSK_PAUSADO
ok_

# sin env ni fichero ni config, Dusk pasa al comando falso
rm -f "$CFG_DIR/dusk-pausado"
ft php artisan "$DUSK"
(( rc == 0 )) && grep -q "ARG<$DUSK>" <<< "$out" || fallo "AC-2 sin fuente Dusk pasa: rc=$rc out=$out"
ok_

# fichero manda sobre la config: motivo del fichero, aunque la config diga true
printf 'tests:\n  dusk_pausado: true\n' > "$FABRIK_CONFIG"
printf 'motivo del fichero\n' > "$CFG_DIR/dusk-pausado"
ft php artisan "$DUSK"
(( rc == 3 )) && grep -q 'Dusk está en pausa (motivo del fichero)' <<< "$out" \
  || fallo "AC-2 fichero manda sobre config: rc=$rc out=$out"
rm -f "$CFG_DIR/dusk-pausado"
ok_

# la config activa la pausa cuando no hay env ni fichero
ft php artisan "$DUSK"
(( rc == 3 )) && grep -q 'Dusk está en pausa (config tests.dusk_pausado)' <<< "$out" \
  || fallo "AC-2 config activa la pausa: rc=$rc out=$out"
sin_locks || fallo "AC-2 exit 3 (config) dejó lock/hueco cogido"
printf 'idioma: es\n' > "$FABRIK_CONFIG"
ok_

# sin ninguna fuente, Dusk pasa al comando falso
ft php artisan "$DUSK"
(( rc == 0 )) && grep -q 'ARG<artisan>' <<< "$out" && grep -q "ARG<$DUSK>" <<< "$out" \
  || fallo "AC-2 sin flag Dusk pasa al comando falso: rc=$rc out=$out"
ok_

echo "ok=$ok fail=$fail"
(( fail == 0 ))
