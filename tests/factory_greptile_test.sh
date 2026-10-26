#!/usr/bin/env bash
# Tests de bin/factory-greptile: una ejecución de Greptile local por rama, caché por diff y registro.
#
# AC-G1 La primera llamada en una rama limpia ejecuta el binario una vez, registra «ejecutado» y devuelve su rc y su salida
#       (con los mismos argumentos: «review <args>»).
# AC-G2 La segunda llamada con el mismo HEAD y merge-base no ejecuta: devuelve la caché (línea de aviso + salida) y registra «cache».
# AC-G3 Con un commit nuevo y el tope por defecto: exit 3, mensaje de tope, registro «tope». FX_GREPTILE_TOPE=2 sí ejecuta y la
#       tercera vuelve a dar tope; =0 no ejecuta nunca; un valor inválido vale 1. (Límites N-1 / N / N+1.)
# AC-G4 Árbol sucio (modificado o sin seguimiento): exit 2, sin ejecutar, registro «sucio», sin consumir tope. Sin -b: exit 2.
# AC-G5 Un rc≠0 del binario cuenta para el tope y no se cachea.
# AC-G6 El registro es JSON válido línea a línea con las claves exactas; «repo» se parsea de un remoto ssh, uno https y sin
#       remoto; ramas distintas tienen topes independientes.
# AC-G7 Entorno: binario por defecto = primer greptile del PATH que no sea el propio envoltorio; sin binario, sin repo git,
#       sin merge-base y sin HEAD fallan con exit 2 y sin registrar; dos llamadas simultáneas ejecutan una sola vez.
#
# Bash puro, sin red. HOME, FABRIK_GREPTILE_LOG y FABRIK_GREPTILE_CACHE temporales: nunca toca el ~/.hermes real.
# Uso: bash tests/factory_greptile_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FG="$FABRIK_DIR/bin/factory-greptile"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export FABRIK_GREPTILE_LOG="$tmp/log/greptile.jsonl"
export FABRIK_GREPTILE_CACHE="$tmp/cache"
mkdir -p "$HOME"
unset FX_GREPTILE_TOPE FABRIK_GREPTILE_BIN FAKE_RC
# git aislado de la config del usuario (firma, credenciales, GIT_CONFIG_*)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE

# Greptile falso: apunta cada llamada (argumentos) en $FAKE_CUENTA, imprime una salida con su número y sale con $FAKE_RC.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/greptile" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CUENTA"
n=$(wc -l <"$FAKE_CUENTA")
echo "salida falsa $n"
echo "aviso en stderr $n" >&2
[ -n "${FAKE_PAUSA:-}" ] && sleep "$FAKE_PAUSA"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$tmp/bin/greptile"
export FABRIK_GREPTILE_BIN="$tmp/bin/greptile"
# gh falso: sin PR abierto (la guarda de PR abierto se prueba en tests/greptile_test.sh). Nunca la red ni el gh real.
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/gh"
export FABRIK_GH="$tmp/bin/gh"
export FAKE_CUENTA="$tmp/cuenta"
: >"$FAKE_CUENTA"

g() { git -c user.name=prueba -c user.email=prueba@ejemplo.invalid -c commit.gpgsign=false "$@"; }
commit() { # <fichero> → un commit nuevo
  echo "$RANDOM$RANDOM" >>"$1"
  g add -A && g commit -q -m "cambio en $1"
}
nuevo_repo() { # <dir> [remoto] → repo con main y la rama feature (un commit propio)
  mkdir -p "$1" && (
    cd "$1" || exit 1
    g init -q -b main .
    [ -n "${2:-}" ] && g remote add origin "$2"
    echo base >a.txt && g add -A && g commit -q -m base
    g checkout -q -b feature
    echo f >f.txt && g add -A && g commit -q -m feature
  )
}

cuenta() { wc -l <"$FAKE_CUENTA" | tr -d ' '; }
lineas() { wc -l <"$FABRIK_GREPTILE_LOG" 2>/dev/null | tr -d ' ' || echo 0; }
# campo <n> <clave> → valor de la línea n (1 = primera) del registro, tal cual
campo() { python3 -I -c '
import json, sys
l = open(sys.argv[1]).read().splitlines()[int(sys.argv[2]) - 1]
v = json.loads(l)[sys.argv[3]]
print(v if not isinstance(v, bool) else str(v).lower())
' "$FABRIK_GREPTILE_LOG" "$1" "$2"; }
ultimo() { campo "$(lineas)" "$1"; }
reset() { : >"$FAKE_CUENTA"; rm -rf "$FABRIK_GREPTILE_LOG" "$FABRIK_GREPTILE_CACHE"; unset FX_GREPTILE_TOPE FAKE_RC; }

# run <dir> args… → deja RC, OUT (stdout) y ERR (stderr) del envoltorio
run() {
  local d="$1"; shift
  (cd "$d" && bash "$FG" "$@") >"$tmp/run.out" 2>"$tmp/run.err"
  RC=$?
  OUT="$(cat "$tmp/run.out")"
  ERR="$(cat "$tmp/run.err")"
}
espera() { # <descripcion> <rc esperado> <nº ejecuciones esperado> <nº líneas de registro esperado> <evento esperado>
  if [ "$RC" -eq "$2" ]; then ok_; else fallo "$1: rc=$RC, esperaba $2 (out=$OUT err=$ERR)"; fi
  if [ "$(cuenta)" = "$3" ]; then ok_; else fallo "$1: el binario se ejecutó $(cuenta) veces, esperaba $3"; fi
  if [ "$(lineas)" = "$4" ]; then ok_; else fallo "$1: $(lineas) líneas de registro, esperaba $4"; fi
  if [ "$(ultimo evento 2>/dev/null)" = "$5" ]; then ok_; else fallo "$1: evento «$(ultimo evento 2>/dev/null)», esperaba $5"; fi
}

R="$tmp/r"
nuevo_repo "$R" git@github.com:acme/app.git

# ---------- AC-G1: primera llamada ----------
reset
run "$R" -b main --foo bar
espera "AC-G1 primera llamada" 0 1 1 ejecutado
[ "$(cat "$FAKE_CUENTA")" = "review -b main --foo bar" ] && ok_ || fallo "AC-G1 argumentos mal pasados: $(cat "$FAKE_CUENTA")"
[ "$OUT" = "$(printf 'salida falsa 1\naviso en stderr 1')" ] && ok_ || fallo "AC-G1 salida (stdout+stderr) mal: $OUT"
[ "$(ultimo rc)" = 0 ] && ok_ || fallo "AC-G1 rc del registro"
[ "$(ultimo sha)" = "$(git -C "$R" rev-parse HEAD)" ] && ok_ || fallo "AC-G1 sha del registro"
[ "$(ultimo base)" = "$(git -C "$R" merge-base HEAD main)" ] && ok_ || fallo "AC-G1 base del registro"
[ "$(ultimo rama)" = feature ] && ok_ || fallo "AC-G1 rama del registro"
d="$(git -C "$R" rev-parse HEAD)-$(git -C "$R" merge-base HEAD main)"
[ -f "$FABRIK_GREPTILE_CACHE/acme__app/feature/$d.out" ] && [ "$(cat "$FABRIK_GREPTILE_CACHE/acme__app/feature/$d.rc")" = 0 ] && ok_ || fallo "AC-G1 caché mal ubicada (esperaba acme__app/feature/$d.{out,rc})"
[ "$(cat "$FABRIK_GREPTILE_CACHE/acme__app/feature/$d.out")" = "$OUT" ] && ok_ || fallo "AC-G1 la caché debe guardar la salida tal cual"

# ---------- AC-G2: segunda llamada, misma clave → caché ----------
run "$R" -b main --foo bar
espera "AC-G2 segunda llamada" 0 1 2 cache
[ "$(sed -n 1p <<<"$OUT")" = "factory-greptile: resultado en caché ($(git -C "$R" rev-parse --short=7 HEAD)), sin ejecutar" ] && ok_ || fallo "AC-G2 línea de aviso: $(sed -n 1p <<<"$OUT")"
[ "$(sed -n '2,$p' <<<"$OUT")" = "$(printf 'salida falsa 1\naviso en stderr 1')" ] && ok_ || fallo "AC-G2 salida guardada: $OUT"
[ "$(ultimo rc)" = 0 ] && ok_ || fallo "AC-G2 rc del registro"
# la caché no cuenta como ejecución real: una tercera sigue siendo caché
run "$R" -b main
espera "AC-G2 tercera llamada" 0 1 3 cache

# ---------- AC-G3: tope por defecto con commit nuevo ----------
(cd "$R" && commit f.txt)
run "$R" -b main
espera "AC-G3 commit nuevo, tope por defecto" 3 1 4 tope
[ "$ERR" = "factory-greptile: tope de Greptile local alcanzado (1) en feature: las rondas del PR las revisa el Greptile de GitHub en cada push; si de verdad hace falta otra, bloquea la tarjeta y pide permiso al humano (FX_GREPTILE_TOPE)" ] && ok_ || fallo "AC-G3 mensaje de tope: $ERR"
[ "$OUT" = "" ] && ok_ || fallo "AC-G3 el tope no debe imprimir en stdout: $OUT"
[ "$(ultimo rc)" = 3 ] && ok_ || fallo "AC-G3 rc del registro de tope"
[ "$(ultimo sha)" = "$(git -C "$R" rev-parse HEAD)" ] && ok_ || fallo "AC-G3 sha del registro de tope"

# FX_GREPTILE_TOPE=2: el límite N-1 / N / N+1
reset
(cd "$R" && git reset -q --hard HEAD~1)
export FX_GREPTILE_TOPE=2
run "$R" -b main; espera "AC-G3 TOPE=2 primera (N-1)" 0 1 1 ejecutado
(cd "$R" && commit f.txt)
run "$R" -b main; espera "AC-G3 TOPE=2 segunda (N)" 0 2 2 ejecutado
(cd "$R" && commit f.txt)
run "$R" -b main; espera "AC-G3 TOPE=2 tercera (N+1)" 3 2 3 tope
[ "$ERR" = "factory-greptile: tope de Greptile local alcanzado (2) en feature: las rondas del PR las revisa el Greptile de GitHub en cada push; si de verdad hace falta otra, bloquea la tarjeta y pide permiso al humano (FX_GREPTILE_TOPE)" ] && ok_ || fallo "AC-G3 mensaje de tope con 2: $ERR"
(cd "$R" && commit f.txt)
run "$R" -b main; espera "AC-G3 TOPE=2 cuarta" 3 2 4 tope

# las llamadas «cache», «tope» y «sucio» ya registradas no cuentan como ejecución para el tope
reset
export FX_GREPTILE_TOPE=2
run "$R" -b main; run "$R" -b main; run "$R" -b main
(cd "$R" && commit f.txt)
run "$R" -b main; espera "AC-G3 la caché no consume tope (TOPE=2)" 0 2 4 ejecutado
(cd "$R" && git reset -q --hard HEAD~1)

# FX_GREPTILE_TOPE=0: nunca ejecuta, ni siquiera la primera
reset
export FX_GREPTILE_TOPE=0
run "$R" -b main; espera "AC-G3 TOPE=0 primera" 3 0 1 tope
[ "$ERR" = "factory-greptile: tope de Greptile local alcanzado (0) en feature: las rondas del PR las revisa el Greptile de GitHub en cada push; si de verdad hace falta otra, bloquea la tarjeta y pide permiso al humano (FX_GREPTILE_TOPE)" ] && ok_ || fallo "AC-G3 mensaje de tope con 0: $ERR"
run "$R" -b main; espera "AC-G3 TOPE=0 segunda" 3 0 2 tope

# valor inválido → 1; «08» no se trata como octal; «007» vale 7
for v in abc "" -1 1.5 " 2" "2 " "1e3"; do
  reset
  export FX_GREPTILE_TOPE="$v"
  run "$R" -b main; espera "AC-G3 TOPE inválido «$v» primera" 0 1 1 ejecutado
  (cd "$R" && commit f.txt)
  run "$R" -b main; espera "AC-G3 TOPE inválido «$v» segunda (vale 1)" 3 1 2 tope
  [ "$(sed -n 's/.*alcanzado (\([0-9]*\)).*/\1/p' <<<"$ERR")" = 1 ] && ok_ || fallo "AC-G3 TOPE «$v» debía mostrar (1): $ERR"
  (cd "$R" && git reset -q --hard HEAD~1)
done
reset
export FX_GREPTILE_TOPE=08
for n in 1 2 3 4 5 6 7 8; do
  (cd "$R" && commit f.txt); run "$R" -b main
done
[ "$(cuenta)" = 8 ] && [ "$RC" -eq 0 ] && ok_ || fallo "AC-G3 TOPE=08 debía permitir 8 ejecuciones (hechas $(cuenta), rc=$RC): $ERR"
(cd "$R" && commit f.txt); run "$R" -b main
espera "AC-G3 TOPE=08 novena" 3 8 9 tope
(cd "$R" && git reset -q --hard HEAD~9)

# ---------- AC-G4: árbol sucio y sin -b ----------
reset
echo sucio >>"$R/a.txt"
run "$R" -b main
espera "AC-G4 modificado" 2 0 1 sucio
[ "$ERR" = "factory-greptile: commitea antes: greptile solo revisa commits" ] && ok_ || fallo "AC-G4 mensaje de sucio: $ERR"
[ "$(ultimo rc)" = 2 ] && ok_ || fallo "AC-G4 rc del registro de sucio"
[ "$(ultimo sha)" = "$(git -C "$R" rev-parse HEAD)" ] && [ "$(ultimo base)" = "$(git -C "$R" merge-base HEAD main)" ] && ok_ || fallo "AC-G4 sha/base del registro de sucio"
[ ! -e "$FABRIK_GREPTILE_CACHE" ] && ok_ || fallo "AC-G4 el sucio no debe crear caché"
git -C "$R" checkout -q -- a.txt
echo nuevo >"$R/sin_seguimiento.txt"
run "$R" -b main
espera "AC-G4 fichero sin seguimiento" 2 0 2 sucio
git -C "$R" add -A && g -C "$R" commit -q -m nuevo; git -C "$R" reset -q --hard HEAD
# el sucio no consume tope: tras limpiar, la primera llamada ejecuta
echo sucio >>"$R/a.txt"; run "$R" -b main; espera "AC-G4 sucio otra vez" 2 0 3 sucio
git -C "$R" checkout -q -- a.txt
run "$R" -b main; espera "AC-G4 limpio tras sucios ejecuta" 0 1 4 ejecutado
# y tampoco sale de la caché cuando está sucio
echo sucio >>"$R/a.txt"; run "$R" -b main
espera "AC-G4 sucio con caché disponible" 2 1 5 sucio
git -C "$R" checkout -q -- a.txt

# sin -b (o -b sin valor, o valor vacío): exit 2, sin ejecutar y sin registrar
reset
for args in "" "--foo" "-b" "-b ''"; do
  eval "run \"\$R\" $args"
  [ "$RC" -eq 2 ] && ok_ || fallo "AC-G4 sin -b válido («$args»): rc=$RC"
  grep -q 'uso: factory-greptile -b <base>' <<<"$ERR" && ok_ || fallo "AC-G4 sin -b válido («$args») debía mostrar el uso: $ERR"
done
[ "$(cuenta)" = 0 ] && [ ! -e "$FABRIK_GREPTILE_LOG" ] && ok_ || fallo "AC-G4 sin -b no debe ejecutar ni registrar"

# ---------- AC-G5: rc≠0 cuenta para el tope y no se cachea ----------
reset
export FAKE_RC=7
run "$R" -b main
espera "AC-G5 primera con rc 7" 7 1 1 ejecutado
[ "$(ultimo rc)" = 7 ] && ok_ || fallo "AC-G5 el registro debe llevar el rc 7"
[ "$OUT" = "$(printf 'salida falsa 1\naviso en stderr 1')" ] && ok_ || fallo "AC-G5 la salida se imprime también con rc≠0: $OUT"
ls "$FABRIK_GREPTILE_CACHE"/acme__app/feature/*.out >/dev/null 2>&1 && fallo "AC-G5 un rc≠0 no se cachea (hay .out)" || ok_
ls "$FABRIK_GREPTILE_CACHE"/acme__app/feature/*.rc >/dev/null 2>&1 && fallo "AC-G5 un rc≠0 no se cachea (hay .rc)" || ok_
ls -A "$FABRIK_GREPTILE_CACHE"/acme__app/feature | grep -q '^\.salida' && fallo "AC-G5 queda un temporal .salida" || ok_
# mismo HEAD: no hay caché, pero el tope (1) ya se pagó → tope, no ejecuta
unset FAKE_RC
run "$R" -b main
espera "AC-G5 segunda tras rc≠0 (sin caché, con tope)" 3 1 2 tope
# con tope 2 se reintenta sobre el mismo diff (no había caché) y ahora sí se cachea
reset; export FAKE_RC=7 FX_GREPTILE_TOPE=2
run "$R" -b main; unset FAKE_RC
run "$R" -b main
espera "AC-G5 reintento tras rc≠0 con tope 2" 0 2 2 ejecutado
run "$R" -b main
espera "AC-G5 tras el éxito se cachea" 0 2 3 cache
# el rc del binario puede ser cualquiera: 255, 1
reset; export FAKE_RC=255; run "$R" -b main; [ "$RC" -eq 255 ] && ok_ || fallo "AC-G5 rc 255: $RC"
reset; export FAKE_RC=1; run "$R" -b main; [ "$RC" -eq 1 ] && [ "$(ultimo rc)" = 1 ] && ok_ || fallo "AC-G5 rc 1: $RC"
unset FAKE_RC FX_GREPTILE_TOPE

# ---------- AC-G6: registro, remotos y ramas ----------
reset
nuevo_repo "$tmp/https1" https://github.com/acme/web.git
nuevo_repo "$tmp/https2" https://github.com/acme/web
nuevo_repo "$tmp/https3" https://github.com/acme/web/
nuevo_repo "$tmp/sshurl" ssh://git@github.com/acme/api.git
nuevo_repo "$tmp/sin_remoto"
nuevo_repo "$tmp/con espacio y \"comillas\"" # sin remoto: el basename lleva caracteres que hay que escapar en JSON
nuevo_repo "$tmp/rarisimo" git@github.com:solo
i=0
for caso in "https1|acme/web" "https2|acme/web" "https3|acme/web" "sshurl|acme/api" "sin_remoto|local/sin_remoto" \
  'con espacio y "comillas"|local/con espacio y "comillas"' "rarisimo|local/rarisimo"; do
  d="${caso%%|*}"; esperado="${caso#*|}"
  i=$((i + 1))
  rm -f "$FABRIK_GREPTILE_LOG"
  run "$tmp/$d" -b main
  if [ "$RC" -eq 0 ] && [ "$(campo 1 repo)" = "$esperado" ]; then ok_; else fallo "AC-G6 repo de «$d»: «$(campo 1 repo 2>&1)», esperaba «$esperado» (rc=$RC $ERR)"; fi
done
rm -f "$FABRIK_GREPTILE_LOG"
run "$R" -b main
ok_claves="$(python3 -I -c '
import json, sys, re
n = 0
for l in open(sys.argv[1]):
    d = json.loads(l)
    assert list(d.keys()) == ["t", "repo", "rama", "sha", "base", "evento", "rc"], list(d.keys())
    assert type(d["t"]) is int and abs(d["t"] - __import__("time").time()) < 120, d["t"]
    assert type(d["rc"]) is int
    assert re.fullmatch("[0-9a-f]{40}", d["sha"]) and re.fullmatch("[0-9a-f]{40}", d["base"])
    assert d["evento"] in ("ejecutado", "cache", "tope", "sucio")
    n += 1
print(n)
' "$FABRIK_GREPTILE_LOG" 2>&1)"
[ "$ok_claves" = 1 ] && ok_ || fallo "AC-G6 claves/tipos del registro: $ok_claves"

# todas las líneas, de todos los eventos, son JSON válido con las claves exactas
reset
run "$R" -b main; run "$R" -b main; (cd "$R" && commit f.txt); run "$R" -b main; echo x >>"$R/a.txt"; run "$R" -b main
git -C "$R" checkout -q -- a.txt
python3 -I -c '
import json, sys
eventos = []
for l in open(sys.argv[1]):
    d = json.loads(l)
    assert sorted(d.keys()) == sorted(["t", "repo", "rama", "sha", "base", "evento", "rc"]), d
    eventos.append(d["evento"])
assert eventos == ["ejecutado", "cache", "tope", "sucio"], eventos
' "$FABRIK_GREPTILE_LOG" 2>"$tmp/py.err" && ok_ || fallo "AC-G6 secuencia de eventos: $(cat "$tmp/py.err")"
(cd "$R" && git reset -q --hard HEAD~1)

# ramas distintas: topes independientes; la caché y el tope no se mezclan; ramas con «/» y caracteres raros
reset
(cd "$R" && g checkout -q -b otra/rama-x && commit f.txt)
run "$R" -b main; espera "AC-G6 otra rama tiene su propio tope" 0 1 1 ejecutado
[ -d "$FABRIK_GREPTILE_CACHE/acme__app/otra__rama-x" ] && ok_ || fallo "AC-G6 rama saneada en la caché: $(ls "$FABRIK_GREPTILE_CACHE/acme__app")"
[ "$(ultimo rama)" = "otra/rama-x" ] && ok_ || fallo "AC-G6 el registro lleva la rama sin sanear"
(cd "$R" && g checkout -q feature)
run "$R" -b main; espera "AC-G6 feature no gastó el tope de otra/rama-x" 0 2 2 ejecutado
(cd "$R" && commit f.txt)
run "$R" -b main; espera "AC-G6 feature ya alcanzó su tope" 3 2 3 tope
(cd "$R" && g checkout -q otra/rama-x && commit f.txt)
run "$R" -b main; espera "AC-G6 otra/rama-x también" 3 2 4 tope
# mismo nombre de rama en repos distintos: el tope no se mezcla (clave repo+rama)
nuevo_repo "$tmp/gemelo" git@github.com:acme/otro.git
run "$tmp/gemelo" -b main; espera "AC-G6 mismo nombre de rama en otro repo" 0 3 5 ejecutado
# «a/b» y «a__b» no comparten caché ni tope
(cd "$R" && g checkout -q feature && g checkout -q -b a/b && commit f.txt && g checkout -q -b a__b && commit f.txt)
run "$R" -b main; espera "AC-G6 a__b ejecuta" 0 4 6 ejecutado
(cd "$R" && g checkout -q a/b)
run "$R" -b main; espera "AC-G6 a/b ejecuta aparte" 0 5 7 ejecutado
# registro con líneas ajenas o corruptas: se ignoran al contar
printf 'esto no es json\n[1,2]\n{"evento": "ejecutado"}\n' >>"$FABRIK_GREPTILE_LOG"
(cd "$R" && g checkout -q feature)
run "$R" -b main; espera "AC-G6 registro con basura" 3 5 11 tope
# el registro y la caché se crean aunque no existan los directorios
reset
export FABRIK_GREPTILE_LOG="$tmp/otro/dir/hondo/g.jsonl"
run "$R" -b main
[ -f "$FABRIK_GREPTILE_LOG" ] && ok_ || fallo "AC-G6 no creó el directorio del registro"
export FABRIK_GREPTILE_LOG="$tmp/log/greptile.jsonl"
# HEAD distinto con el mismo merge-base y mismo HEAD con otro merge-base: claves distintas
reset
export FX_GREPTILE_TOPE=9
(cd "$R" && g checkout -q feature)
run "$R" -b main; espera "AC-G6 clave: primera" 0 1 1 ejecutado
(cd "$R" && g branch base2 feature)  # base distinta: el merge-base con base2 es el propio HEAD, no el de main
run "$R" -b base2; espera "AC-G6 clave: mismo HEAD, otro merge-base no usa la caché" 0 2 2 ejecutado
run "$R" -b base2; espera "AC-G6 clave: repetida con base2 → caché" 0 2 3 cache
(cd "$R" && g checkout -q -- . 2>/dev/null)
unset FX_GREPTILE_TOPE

# ---------- AC-G7: entorno ----------
# binario por defecto: primer greptile del PATH que no sea el envoltorio (enlace simbólico incluido)
reset
mkdir -p "$tmp/enlace" "$tmp/otro-bin"
ln -s "$FG" "$tmp/enlace/greptile"
printf '#!/usr/bin/env bash\necho "greptile del PATH" >>"$FAKE_CUENTA"\n' >"$tmp/otro-bin/greptile"; chmod +x "$tmp/otro-bin/greptile"
(cd "$R" && unset FABRIK_GREPTILE_BIN && PATH="$tmp/enlace::$tmp/otro-bin:$PATH" bash "$FG" -b main) >"$tmp/run.out" 2>"$tmp/run.err"; RC=$?
[ "$RC" -eq 0 ] && [ "$(cat "$FAKE_CUENTA")" = "greptile del PATH" ] && ok_ || fallo "AC-G7 el binario por defecto debía saltarse el propio enlace (rc=$RC cuenta=$(cat "$FAKE_CUENTA")): $(cat "$tmp/run.err")"
# sin binario: exit 2, sin registrar, sin gastar tope
reset
(cd "$R" && unset FABRIK_GREPTILE_BIN && PATH="$tmp/enlace:/usr/bin:/bin" bash "$FG" -b main) >"$tmp/run.out" 2>"$tmp/run.err"; RC=$?
[ "$RC" -eq 2 ] && grep -q 'no encuentro el binario' "$tmp/run.err" && [ ! -e "$FABRIK_GREPTILE_LOG" ] && ok_ || fallo "AC-G7 sin binario: rc=$RC $(cat "$tmp/run.err")"
# FABRIK_GREPTILE_BIN con ruta inexistente: el rc de bash (127) se devuelve y cuenta como ejecución
reset
FABRIK_GREPTILE_BIN="$tmp/no-existe" run "$R" -b main
[ "$RC" -eq 127 ] && [ "$(ultimo evento)" = ejecutado ] && ok_ || fallo "AC-G7 binario inexistente: rc=$RC"
# fuera de un repo git
reset
mkdir -p "$tmp/nogit"
run "$tmp/nogit" -b main
[ "$RC" -eq 2 ] && grep -q 'no estás dentro de un repo git' <<<"$ERR" && [ ! -e "$FABRIK_GREPTILE_LOG" ] && [ "$(cuenta)" = 0 ] && ok_ || fallo "AC-G7 fuera de git: rc=$RC $ERR"
# repo sin commits
mkdir -p "$tmp/vacio" && git -C "$tmp/vacio" init -q -b main
run "$tmp/vacio" -b main
[ "$RC" -eq 2 ] && grep -q 'no tiene commits' <<<"$ERR" && ok_ || fallo "AC-G7 sin commits: rc=$RC $ERR"
# base inexistente: no hay merge-base
run "$R" -b no-existe-esta-rama
[ "$RC" -eq 2 ] && grep -q 'no encuentro el merge-base' <<<"$ERR" && [ "$(cuenta)" = 0 ] && [ ! -e "$FABRIK_GREPTILE_LOG" ] && ok_ || fallo "AC-G7 base inexistente: rc=$RC $ERR"
# HEAD suelto (sin rama): funciona, rama vacía en el registro, y el tope también aplica
reset
(cd "$R" && g checkout -q --detach feature)
run "$R" -b main; espera "AC-G7 HEAD suelto primera" 0 1 1 ejecutado
[ "$(ultimo rama)" = "" ] && ok_ || fallo "AC-G7 rama vacía en HEAD suelto"
(cd "$R" && commit f.txt)
run "$R" -b main; espera "AC-G7 HEAD suelto segunda" 3 1 2 tope
(cd "$R" && g checkout -q feature)
# la caché devuelve el rc guardado (no un 0 fijo); un .rc corrupto no vale como caché y cae al tope
reset
run "$R" -b main
rcf="$(ls "$FABRIK_GREPTILE_CACHE"/acme__app/feature/*.rc)"
echo 5 >"$rcf"
run "$R" -b main; espera "AC-G7 caché con rc guardado 5" 5 1 2 cache
[ "$(ultimo rc)" = 5 ] && ok_ || fallo "AC-G7 el registro de caché lleva el rc guardado"
echo xyz >"$rcf"
run "$R" -b main; espera "AC-G7 .rc corrupto no es caché" 3 1 3 tope
grep -q "en caché" <<<"$OUT" && fallo "AC-G7 .rc corrupto: no debe anunciar caché: $OUT" || ok_
# argumentos con espacios llegan intactos
reset
run "$R" -b main --comentario "dos palabras" 'con "comillas"'
[ "$(cat "$FAKE_CUENTA")" = 'review -b main --comentario dos palabras con "comillas"' ] && ok_ || fallo "AC-G7 argumentos con espacios: $(cat "$FAKE_CUENTA")"
# el -b puede ir en cualquier posición
reset
run "$R" --foo -b main bar
[ "$RC" -eq 0 ] && [ "$(cat "$FAKE_CUENTA")" = 'review --foo -b main bar' ] && ok_ || fallo "AC-G7 -b en medio: rc=$RC $(cat "$FAKE_CUENTA")"
# dos llamadas simultáneas sobre la misma clave: solo una ejecuta, la otra espera y sale de caché
reset
export FAKE_PAUSA=0.5
(cd "$R" && bash "$FG" -b main >"$tmp/par1.out" 2>&1; echo $? >"$tmp/par1.rc") &
p1=$!
(cd "$R" && bash "$FG" -b main >"$tmp/par2.out" 2>&1; echo $? >"$tmp/par2.rc") &
p2=$!
wait "$p1" "$p2"
unset FAKE_PAUSA
[ "$(cuenta)" = 1 ] && ok_ || fallo "AC-G7 dos llamadas simultáneas ejecutaron $(cuenta) veces, esperaba 1"
[ "$(cat "$tmp/par1.rc")" = 0 ] && [ "$(cat "$tmp/par2.rc")" = 0 ] && ok_ || fallo "AC-G7 rc de las simultáneas"
[ "$(lineas)" = 2 ] && [ "$(python3 -I -c 'import json,sys; print(sorted(json.loads(l)["evento"] for l in open(sys.argv[1])))' "$FABRIK_GREPTILE_LOG")" = "['cache', 'ejecutado']" ] && ok_ || fallo "AC-G7 eventos de las simultáneas: $(cat "$FABRIK_GREPTILE_LOG")"
# sin HOME real: con HOME temporal y sin variables FABRIK_GREPTILE_*, escribe bajo HOME
reset
(cd "$R" && env -u FABRIK_GREPTILE_LOG -u FABRIK_GREPTILE_CACHE bash "$FG" -b main) >/dev/null 2>&1
[ -f "$HOME/.hermes/factory/logs/greptile.jsonl" ] && [ -d "$HOME/.hermes/factory/cache/greptile/acme__app/feature" ] && ok_ || fallo "AC-G7 rutas por defecto bajo HOME"

# ---------- AC-G7 (ramas de error del entorno de caché y registro) ----------
# caché no creable (la ruta es un fichero normal): exit 2, mensaje, sin ejecutar ni registrar
reset
: >"$tmp/fichero-normal"
FABRIK_GREPTILE_CACHE="$tmp/fichero-normal" run "$R" -b main
[ "$RC" -eq 2 ] && grep -q 'no puedo crear la caché' <<<"$ERR" && [ "$(cuenta)" = 0 ] && [ ! -e "$FABRIK_GREPTILE_LOG" ] && ok_ || fallo "AC-G7 caché no creable: rc=$RC cuenta=$(cuenta) $ERR"
# registro no creable (el padre es un fichero): la llamada sigue, devuelve la salida y el rc del binario, y no deja registro
reset
FAKE_RC=4 FABRIK_GREPTILE_LOG="$tmp/fichero-normal/sub/log.jsonl" run "$R" -b main
[ "$RC" -eq 4 ] && [ "$(cuenta)" = 1 ] && grep -q 'salida falsa 1' <<<"$OUT" && [ ! -e "$tmp/fichero-normal/sub" ] && ok_ || fallo "AC-G7 registro no creable: rc=$RC cuenta=$(cuenta) out=$OUT err=$ERR"
# directorio de caché de la rama sin permiso de escritura (no hay .lock ni mktemp): exit 2, sin ejecutar ni registrar «ejecutado»
reset
mkdir -p "$FABRIK_GREPTILE_CACHE/acme__app/feature" && chmod 555 "$FABRIK_GREPTILE_CACHE/acme__app/feature"
run "$R" -b main
chmod 755 "$FABRIK_GREPTILE_CACHE/acme__app/feature"
if [ "$(id -u)" -ne 0 ]; then
  [ "$RC" -eq 2 ] && [ "$(cuenta)" = 0 ] && [ ! -e "$FABRIK_GREPTILE_LOG" ] && ok_ || fallo "AC-G7 caché sin permiso de escritura: rc=$RC cuenta=$(cuenta) $ERR"
fi

# el evento «tope» tampoco consume tope: 1 ejecución real + 1 «tope»; con TOPE=2 y otro HEAD aún queda una ejecución
reset
run "$R" -b main; espera "AC-G7 tope-no-consume: ejecutada" 0 1 1 ejecutado
(cd "$R" && commit f.txt)
run "$R" -b main; espera "AC-G7 tope-no-consume: tope" 3 1 2 tope
(cd "$R" && commit f.txt)
FX_GREPTILE_TOPE=2 run "$R" -b main; espera "AC-G7 tope-no-consume: el «tope» no gasta (TOPE=2 ejecuta)" 0 2 3 ejecutado
(cd "$R" && commit f.txt)
FX_GREPTILE_TOPE=2 run "$R" -b main; espera "AC-G7 tope-no-consume: ahora sí 2 reales" 3 2 4 tope
# bajar el tope después de haber ejecutado más veces: sigue bloqueado y el mensaje muestra el tope vigente, no las hechas
FX_GREPTILE_TOPE=1 run "$R" -b main
[ "$RC" -eq 3 ] && grep -q 'alcanzado (1) en feature' <<<"$ERR" && ok_ || fallo "AC-G7 hechas>tope: rc=$RC $ERR"
(cd "$R" && git reset -q --hard HEAD~3)

# caché a medias: un .rc sin .out (o un .out sin .rc) no sirve de caché; con tope para ejecutar, ejecuta de verdad
reset
export FX_GREPTILE_TOPE=3
run "$R" -b main
rcf="$(ls "$FABRIK_GREPTILE_CACHE"/acme__app/feature/*.rc)"; outf="${rcf%.rc}.out"
[ -f "$outf" ] && ok_ || fallo "AC-G7 la ejecución con rc 0 debe dejar .out y .rc"
rm -f "$outf"
run "$R" -b main; espera "AC-G7 .rc sin .out no es caché" 0 2 2 ejecutado
grep -q 'en caché' <<<"$OUT" && fallo "AC-G7 .rc sin .out: no debe anunciar caché: $OUT" || ok_
[ -f "$outf" ] && [ -f "$rcf" ] && ok_ || fallo "AC-G7 tras ejecutar de nuevo la caché queda completa"
rm -f "$rcf"
run "$R" -b main; espera "AC-G7 .out sin .rc no es caché" 0 3 3 ejecutado
unset FX_GREPTILE_TOPE
# con -b repetido gana el primero
reset
run "$R" -b main -b otra
[ "$RC" -eq 0 ] && [ "$(ultimo base)" = "$(git -C "$R" merge-base HEAD main)" ] && ok_ || fallo "AC-G7 -b repetido: gana el primero (rc=$RC): $ERR"

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
