#!/usr/bin/env bash
# Tests de MariaDB rápido (IMPL-2): AC-2 (install.sh --comprobar informa de las opciones de la
# unidad y del +C del datadir) y AC-M1 (migración con falsos: --seco, ya migrado, orden con
# cerrojos cogidos, poco espacio y fallo de arranque con reverts).
# Aislamiento: HOME y FABRIK_DATA temporales por escenario; falsos para systemctl, mariadb,
# mariadbd, chattr, lsattr, stat, cp y mv (los binarios reales solo se usan dentro de los falsos);
# flock REAL: la comprobación de cerrojos durante el stop se hace con flock -n dentro del stop falso.
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRAR="$FABRIK_DIR/scripts/migrar-mariadb-rapido.sh"
ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }
afirma() { local d="$1"; shift; if "$@"; then ok_; else fallo "$d"; fi; }
iguales() { [ "$1" = "$2" ]; }

tmp="$(mktemp -d /tmp/mariadb-rapido-test.XXXXXX)"
if [[ -n "${KEEP_TMP:-}" ]]; then echo "tmp conservado: $tmp" >&2; else trap 'rm -rf "$tmp"' EXIT; fi
BIN="$tmp/bin"
mkdir -p "$BIN"
export FAKE_LOG="$tmp/fake.log"
: > "$FAKE_LOG"
export PATH="$BIN:$PATH"

# La caché de uv se resuelve ANTES de cambiar HOME (sin red en los escenarios).
export UV_CACHE_DIR="${UV_CACHE_DIR:-$(uv cache dir 2>/dev/null)}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$(uv python dir 2>/dev/null)}"
# Sin claves heredadas del entorno real: la detección de proveedores depende solo del escenario.
unset FABRIK_CONFIG FABRIK_DATA ANTHROPIC_API_KEY DEEPSEEK_API_KEY KIMI_API_KEY OPENAI_API_KEY

# Knobs de los falsos: los valores por escenario se resetean en escenario() y cada caso los ajusta.
export HERMES_ESTADO="$tmp/hermes-estado"
mkdir -p "$HERMES_ESTADO"
printf '%s\n' antigravity-oauth claude-subscription-directsdk-experimental > "$HERMES_ESTADO/plugins_enabled"

# ---------------------------------------------------------------- falsos --
for c in php composer node greptile specify; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$BIN/$c"
  chmod +x "$BIN/$c"
done

# systemctl falso: `cat` saca la unidad instalada si existe (como el real, con los drop-ins)
# o el fixture; stop/start/daemon-reload se anotan. El stop comprueba con flock -n real (fd 9)
# que el migrador tiene cogidos el turno pesado, un hueco dirigido y la BD.
cat > "$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "--user cat")
    if [[ -f "$HOME/.config/systemd/user/fabrica-mariadb.service" ]]; then cat "$HOME/.config/systemd/user/fabrica-mariadb.service"; exit 0; fi
    if [[ -n "${FAKE_UNIT_FILE:-}" && -f "$FAKE_UNIT_FILE" ]]; then cat "$FAKE_UNIT_FILE"; exit 0; fi
    exit 1 ;;
  "--user stop")
    for l in factory-test.lock dirigidos.d/1.lock bd.d/x.lock; do
      f="$FABRIK_DATA/locks/$l"
      mkdir -p "$(dirname "$f")"; : >> "$f"
      exec 9>>"$f"
      if flock -n 9 2>/dev/null; then echo "SIN_CERROJO:$l" >> "$FAKE_STOP_OUT"; else echo "CERROJO_OK:$l" >> "$FAKE_STOP_OUT"; fi
    done
    echo "stop" >> "$FAKE_OPS" ;;
  "--user start") echo "start" >> "$FAKE_OPS" ;;
  "--user daemon-reload") echo "daemon-reload" >> "$FAKE_LOG" ;;
esac
exit 0
FAKE
chmod +x "$BIN/systemctl"

# mariadb falso: select 1 sale 0 salvo FAKE_MARIADB_FAIL=1 (caso de arranque que falla).
cat > "$BIN/mariadb" <<'FAKE'
#!/usr/bin/env bash
printf 'mariadb %s\n' "$*" >> "$FAKE_LOG"
[[ "${FAKE_MARIADB_FAIL:-0}" == 1 ]] && exit 1
exit 0
FAKE
chmod +x "$BIN/mariadb"
printf '%s\n' '#!/usr/bin/env bash' 'echo "$BIN/mariadbd"' 'exit 0' > "$BIN/mariadbd"
chmod +x "$BIN/mariadbd"

# chattr falso: registra los +C aplicados (el fs falso no modela atributos); FAKE_CHATTR_FAIL=1 falla.
cat > "$BIN/chattr" <<'FAKE'
#!/usr/bin/env bash
printf 'chattr %s\n' "$*" >> "$FAKE_LOG"
[[ "${FAKE_CHATTR_FAIL:-0}" == 1 ]] && exit 1
case "$*" in
  *+C*) printf '%s\n' "${*: -1}" >> "$FAKE_MAS_C_FILE" ;;
esac
exit 0
FAKE
chmod +x "$BIN/chattr"
# lsattr falso: +C si el directorio está en el registro de chattr o FAKE_LSATTR_C=1.
cat > "$BIN/lsattr" <<'FAKE'
#!/usr/bin/env bash
printf 'lsattr %s\n' "$*" >> "$FAKE_LOG"
target="${*: -1}"
if [[ "${FAKE_LSATTR_C:-0}" == 1 ]] || grep -qxF "$target" "$FAKE_MAS_C_FILE" 2>/dev/null; then
  echo "--------------C------ $target"
else
  echo "--------------------- $target"
fi
exit 0
FAKE
chmod +x "$BIN/lsattr"

# stat falso: %T → FAKE_FS_TYPE (vacío = sin respuesta); '%a %S' → FAKE_FS_AVAIL/FAKE_FS_BSIZE.
cat > "$BIN/stat" <<'FAKE'
#!/usr/bin/env bash
printf 'stat %s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  *%T*) echo "${FAKE_FS_TYPE-btrfs}"; exit 0 ;;
  *%a*%S*) echo "${FAKE_FS_AVAIL:-2000000000} ${FAKE_FS_BSIZE:-1024}"; exit 0 ;;
esac
exec /usr/bin/stat "$@"
FAKE
chmod +x "$BIN/stat"

# mariadb-install-db falso (modo install de install.sh): registra y sale 0.
printf '%s\n' '#!/usr/bin/env bash' 'printf "mariadb-install-db %s\\n" "$*" >> "$FAKE_LOG"' 'exit 0' > "$BIN/mariadb-install-db"
chmod +x "$BIN/mariadb-install-db"

# cp/mv falsos: anotan la operación (para comprobar el orden y --reflink=never) y delegan en el real.
for c in cp mv; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "${FAKE_OPS:-$FAKE_LOG}"\nexec /usr/bin/%s "$@"\n' "$c" "$c" > "$BIN/$c"
  chmod +x "$BIN/$c"
done

# gh y hermes falsos (install.sh --comprobar los consulta).
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  "auth status"*) exit 0 ;;
  "api user -q .login") echo "usuario_fake" ;;
esac
exit 0
FAKE
chmod +x "$BIN/gh"
cat > "$BIN/hermes" <<'FAKE'
#!/usr/bin/env bash
printf 'hermes %s\n' "$*" >> "$FAKE_LOG"
case "$1 $2 $3" in
  "config get plugins.enabled") cat "$HERMES_ESTADO/plugins_enabled"; exit 0 ;;
esac
exit 0
FAKE
chmod +x "$BIN/hermes"

# ------------------------------------------------------------ utilidades --
limpio() { sed 's/\x1b\[[0-9;]*m//g' "$1"; }
tiene() { limpio "$1" | grep -qE -- "$2"; }
no_tiene() { ! tiene "$1" "$2"; }

# Unidad «vieja» (sin las opciones rápidas): como la unidad de este repo antes de IMPL-2.
cat > "$tmp/unidad-vieja" <<'EOF'
[Unit]
Description=MariaDB propio de la fábrica
[Service]
ExecStart=/usr/sbin/mariadbd --no-defaults --datadir=%h/.local/share/fabrica/mariadb --port=3307 --innodb-buffer-pool-size=256M --skip-log-bin --max-connections=200 --max-allowed-packet=64M --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
MemoryMax=1500M
EOF
# Unidad «nueva»: la que este repo instala tras IMPL-2 (con todas las opciones rápidas).
/usr/bin/cp "$FABRIK_DIR/config/systemd/fabrica-mariadb.service" "$tmp/unidad-nueva"

# Escenario: HOME y FABRIK_DATA frescos, con datadir (un «mysql/db.opt»), db.env, locks y unidad.
escenario() { # <nombre> — deja en FAKE_UNIT_FILE la ruta de la unidad efectiva del escenario
  local n="$1"
  export HOME="$tmp/h_$n" FABRIK_DATA="$tmp/fd_$n"
  mkdir -p "$HOME/.hermes" "$HOME/.config/fabrica" "$HOME/.local/share/fabrica/mariadb/mysql" \
           "$FABRIK_DATA/locks/dirigidos.d" "$FABRIK_DATA/locks/bd.d"
  : > "$FABRIK_DATA/locks/bd.d/x.lock"
  printf 'KIMI_API_KEY=clave-falsa\nANTHROPIC_API_KEY=clave-falsa\n' > "$HOME/.hermes/.env"
  printf 'FX_DB_USER=fx\nFX_DB_PASSWORD=clave-fx\nFX_DB_HOST=127.0.0.1\nFX_DB_PORT=3307\n' > "$HOME/.config/fabrica/db.env"
  echo "dato-de-prueba" > "$HOME/.local/share/fabrica/mariadb/mysql/db.opt"
  : > "$FAKE_LOG"   # el log de falsos también es por escenario
  export FAKE_UNIT_FILE="$tmp/unidad_$n" FAKE_OPS="$tmp/ops_$n" FAKE_STOP_OUT="$tmp/stop_$n" FAKE_MAS_C_FILE="$tmp/masc_$n"
  : > "$FAKE_OPS"; : > "$FAKE_STOP_OUT"; : > "$FAKE_MAS_C_FILE"
  # knobs por defecto del escenario: btrfs sin +C, sin fallos, espacio de sobra.
  export FAKE_FS_TYPE=btrfs FAKE_LSATTR_C=0 FAKE_MARIADB_FAIL=0 FAKE_CHATTR_FAIL=0
  export FAKE_FS_AVAIL=2000000000 FAKE_FS_BSIZE=1024
}

# install.sh --comprobar sobre el escenario actual: RC por stdout, salida en $tmp/out-<nombre>.log
comprobar() {
  bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-$1.log" 2>&1
  echo $?
}

# ======================================================================
# AC-2: install.sh --comprobar informa de las opciones y del +C
# ======================================================================

# Caso todo bien: unidad nueva + btrfs + C → ✓ y RC 0
/usr/bin/cp "$tmp/unidad-nueva" "$tmp/unidad_ac2bien"
escenario ac2bien
export FAKE_LSATTR_C=1
RC="$(comprobar ac2bien)"
afirma "AC-2 --comprobar (todo bien) salió con RC=$RC" iguales "$RC" 0
afirma "AC-2 informa ✓ de las opciones rápidas" tiene "$tmp/out-ac2bien.log" '✓ .*opciones rápidas'
afirma "AC-2 informa ✓ del No_COW" tiene "$tmp/out-ac2bien.log" '✓ .*No_COW'
afirma "AC-2 (todo bien) sin avisos de migración" no_tiene "$tmp/out-ac2bien.log" 'migrar-mariadb-rapido'

# Caso unidad sin opciones: aviso con la lista de las que faltan (no es «ko»: RC sigue 0)
/usr/bin/cp "$tmp/unidad-vieja" "$tmp/unidad_ac2vieja"
escenario ac2vieja
export FAKE_LSATTR_C=1
RC="$(comprobar ac2vieja)"
afirma "AC-2 (unidad vieja) RC=$RC (aviso, no ko)" iguales "$RC" 0
afirma "AC-2 lista una opción que falta (innodb-doublewrite)" tiene "$tmp/out-ac2vieja.log" 'innodb-doublewrite=0'
afirma "AC-2 lista skip-name-resolve" tiene "$tmp/out-ac2vieja.log" 'skip-name-resolve'
afirma "AC-2 avisa con el comando de migración" tiene "$tmp/out-ac2vieja.log" 'migrar-mariadb-rapido'

# Caso btrfs sin +C: aviso
/usr/bin/cp "$tmp/unidad-nueva" "$tmp/unidad_ac2sinc"
escenario ac2sinc
RC="$(comprobar ac2sinc)"
afirma "AC-2 (btrfs sin +C) RC=$RC (aviso, no ko)" iguales "$RC" 0
afirma "AC-2 avisa del datadir sin No_COW" tiene "$tmp/out-ac2sinc.log" 'sin No_COW'

# Caso no-btrfs: ✓ aunque no haya +C
/usr/bin/cp "$tmp/unidad-nueva" "$tmp/unidad_ac2ext4"
escenario ac2ext4
export FAKE_FS_TYPE=ext4
RC="$(comprobar ac2ext4)"
afirma "AC-2 (no-btrfs) RC=$RC" iguales "$RC" 0
afirma "AC-2 en ext4 no pide +C" tiene "$tmp/out-ac2ext4.log" '✓ .*nada que hacer'
afirma "AC-2 en ext4 sin aviso de No_COW" no_tiene "$tmp/out-ac2ext4.log" 'sin No_COW'

# ======================================================================
# AC-M1: migración con falsos
# ======================================================================
MDATA_REL=".local/share/fabrica/mariadb"

# --- --seco: no ejecuta stop/cp/mv ni escribe la unidad
escenario seco
/usr/bin/cp "$tmp/unidad-vieja" "$FAKE_UNIT_FILE"
bash "$MIGRAR" --seco > "$tmp/out-seco.log" 2>&1
RC=$?
afirma "AC-M1 --seco RC=$RC" iguales "$RC" 0
afirma "AC-M1 --seco no paró" no_tiene "$FAKE_OPS" '^stop$'
afirma "AC-M1 --seco no copió" no_tiene "$FAKE_OPS" '^cp '
afirma "AC-M1 --seco no movió" no_tiene "$FAKE_OPS" '^mv '
afirma "AC-M1 --seco no instaló la unidad" test ! -f "$HOME/.config/systemd/user/fabrica-mariadb.service"
afirma "AC-M1 --seco deja el datadir intacto" test -f "$HOME/$MDATA_REL/mysql/db.opt"
afirma "AC-M1 --seco dice qué haría" tiene "$tmp/out-seco.log" 'haría'

# --- ya migrado: no para nada
escenario yamigrado
/usr/bin/cp "$tmp/unidad-nueva" "$FAKE_UNIT_FILE"
export FAKE_LSATTR_C=1
bash "$MIGRAR" > "$tmp/out-yamigrado.log" 2>&1
RC=$?
afirma "AC-M1 ya migrado RC=$RC" iguales "$RC" 0
afirma "AC-M1 ya migrado no paró" no_tiene "$FAKE_OPS" '^stop$'
afirma "AC-M1 ya migrado no tocó locks (ops vacío)" test ! -s "$FAKE_OPS"
afirma "AC-M1 ya migrado lo dice" tiene "$tmp/out-yamigrado.log" 'ya migrado'

# --- caso normal: stop → cp --reflink=never → swap → start, con los cerrojos cogidos
escenario normal
/usr/bin/cp "$tmp/unidad-vieja" "$FAKE_UNIT_FILE"
bash "$MIGRAR" > "$tmp/out-normal.log" 2>&1
RC=$?
MDATA="$HOME/$MDATA_REL"
afirma "AC-M1 migración normal RC=$RC" iguales "$RC" 0
afirma "AC-M1 el stop tenía cogido el turno (factory-test.lock)" tiene "$FAKE_STOP_OUT" 'CERROJO_OK:factory-test.lock'
afirma "AC-M1 el stop tenía cogida la BD (bd.d/x.lock)" tiene "$FAKE_STOP_OUT" 'CERROJO_OK:bd.d/x.lock'
l_stop="$(grep -n '^stop$' "$FAKE_OPS" | head -1 | cut -d: -f1)"
l_cp="$(grep -n '^cp ' "$FAKE_OPS" | head -1 | cut -d: -f1)"
l_mv1="$(grep -n '^mv .*mariadb\.cow-' "$FAKE_OPS" | head -1 | cut -d: -f1)"
l_mv2="$(grep -n '^mv .*mariadb\.nuevo ' "$FAKE_OPS" | head -1 | cut -d: -f1)"
l_start="$(grep -n '^start$' "$FAKE_OPS" | head -1 | cut -d: -f1)"
afirma "AC-M1 orden stop<cp<mv(cow)<mv(nuevo)<start" \
  bash -c '[[ -n "$1" && -n "$2" && -n "$3" && -n "$4" && -n "$5" && "$1" -lt "$2" && "$2" -lt "$3" && "$3" -lt "$4" && "$4" -lt "$5" ]]' _ "$l_stop" "$l_cp" "$l_mv1" "$l_mv2" "$l_start"
afirma "AC-M1 la copia fue --reflink=never" tiene "$FAKE_OPS" '^cp -a --reflink=never '
afirma "AC-M1 aplicó chattr +C al datadir nuevo" tiene "$FAKE_LOG" "chattr \+C .*mariadb\.nuevo"
afirma "AC-M1 el datadir nuevo conserva los datos" test -f "$MDATA/mysql/db.opt"
afirma "AC-M1 la copia vieja queda en mariadb.cow-*" bash -c 'ls -d "$1"/../mariadb.cow-* >/dev/null 2>&1' _ "$MDATA"
afirma "AC-M1 el migrador anuncia la copia vieja para borrar" tiene "$tmp/out-normal.log" 'mariadb\.cow-'
afirma "AC-M1 instaló la unidad nueva" tiene "$HOME/.config/systemd/user/fabrica-mariadb.service" 'innodb-buffer-pool-size=2G'
# Idempotente: la segunda vez (datadir ya con +C, unidad ya instalada) no para nada.
stops_tras_primera="$(grep -c '^stop$' "$FAKE_OPS")"
export FAKE_LSATTR_C=1
bash "$MIGRAR" > "$tmp/out-normal2.log" 2>&1
RC=$?
afirma "AC-M1 re-ejecutar es no-op (RC=$RC)" iguales "$RC" 0
afirma "AC-M1 re-ejecutar no paró (stops: $stops_tras_primera → $(grep -c '^stop$' "$FAKE_OPS"))" \
  iguales "$(grep -c '^stop$' "$FAKE_OPS")" "$stops_tras_primera"

# --- poco espacio: aborta sin stop
escenario pocoespacio
/usr/bin/cp "$tmp/unidad-vieja" "$FAKE_UNIT_FILE"
export FAKE_LSATTR_C=0 FAKE_FS_AVAIL=1
bash "$MIGRAR" > "$tmp/out-pocoespacio.log" 2>&1
RC=$?
afirma "AC-M1 poco espacio aborta (RC=$RC)" test "$RC" -ne 0
afirma "AC-M1 poco espacio no paró" no_tiene "$FAKE_OPS" '^stop$'
afirma "AC-M1 poco espacio deja el datadir en su sitio" test -f "$HOME/$MDATA_REL/mysql/db.opt"
afirma "AC-M1 poco espacio avisa del espacio" tiene "$tmp/out-pocoespacio.log" 'espacio insuficiente para copiar'

# --- fallo de arranque: revierte el swap y rearranca con el datadir viejo
escenario fallo
/usr/bin/cp "$tmp/unidad-vieja" "$FAKE_UNIT_FILE"
export FAKE_LSATTR_C=0 FAKE_FS_AVAIL=2000000000 FAKE_MARIADB_FAIL=1
bash "$MIGRAR" > "$tmp/out-fallo.log" 2>&1
RC=$?
MDATA="$HOME/$MDATA_REL"
afirma "AC-M1 fallo de arranque RC=$RC (error)" test "$RC" -ne 0
afirma "AC-M1 revierte: el datadir viejo queda en su sitio" test -f "$MDATA/mysql/db.opt"
afirma "AC-M1 revierte: la copia vieja volvió (sin cow-* suelto)" bash -c '! ls -d "$1"/../mariadb.cow-* >/dev/null 2>&1' _ "$MDATA"
afirma "AC-M1 intentó rearrancar (start tras start)" iguales "$(grep -c '^start$' "$FAKE_OPS")" 2
afirma "AC-M1 avisa de la reversión" tiene "$tmp/out-fallo.log" 'revierte'

# --- migración «solo unidad» (fs no-btrfs): para y rearra, pero no copia ni mueve nada
escenario ext4mig
/usr/bin/cp "$tmp/unidad-vieja" "$FAKE_UNIT_FILE"
export FAKE_FS_TYPE=ext4 FX_TEST_DIRIGIDOS=abc   # inválido → cae al máximo por defecto
bash "$MIGRAR" > "$tmp/out-ext4mig.log" 2>&1
RC=$?
unset FX_TEST_DIRIGIDOS
afirma "AC-M1 migración solo-unidad RC=$RC" iguales "$RC" 0
afirma "AC-M1 solo-unidad: hizo stop y start" bash -c 'grep -q "^stop$" "$1" && grep -q "^start$" "$1"' _ "$FAKE_OPS"
afirma "AC-M1 solo-unidad: no copió ni movió" bash -c '! grep -qE "^(cp|mv) " "$1"' _ "$FAKE_OPS"
afirma "AC-M1 solo-unidad: sin chattr" no_tiene "$FAKE_LOG" 'chattr'
afirma "AC-M1 solo-unidad lo dice" tiene "$tmp/out-ext4mig.log" 'solo cambian las opciones'

# --- chattr +C falla en el swap: avisa y sigue (el datadir se intercambia igual)
escenario chattrfail
/usr/bin/cp "$tmp/unidad-vieja" "$FAKE_UNIT_FILE"
export FAKE_CHATTR_FAIL=1
bash "$MIGRAR" > "$tmp/out-chattrfail.log" 2>&1
RC=$?
afirma "AC-M1 chattr falla pero migra (RC=$RC)" iguales "$RC" 0
afirma "AC-M1 chattr falla: lo avisa" tiene "$tmp/out-chattrfail.log" 'chattr \+C falló'
afirma "AC-M1 chattr falla: el swap se hizo igual" test -f "$HOME/$MDATA_REL/mysql/db.opt"

# --- límite de espacio: con el mínimo exacto migra; con un KiB menos aborta
escenario limite
/usr/bin/cp "$tmp/unidad-vieja" "$FAKE_UNIT_FILE"
kb_datadir="$(du -sk "$HOME/$MDATA_REL" | awk '{print $1}')"
export FAKE_FS_AVAIL=$(( (kb_datadir * 11 + 9) / 10 )) FAKE_FS_BSIZE=1024
bash "$MIGRAR" > "$tmp/out-limite.log" 2>&1
RC=$?
afirma "AC-M1 con el mínimo exacto migra (RC=$RC)" iguales "$RC" 0
escenario limitemenos
/usr/bin/cp "$tmp/unidad-vieja" "$FAKE_UNIT_FILE"
kb_datadir="$(du -sk "$HOME/$MDATA_REL" | awk '{print $1}')"
export FAKE_FS_AVAIL=$(( (kb_datadir * 11 + 9) / 10 - 1 )) FAKE_FS_BSIZE=1024
bash "$MIGRAR" > "$tmp/out-limitemenos.log" 2>&1
RC=$?
afirma "AC-M1 con un KiB menos del mínimo aborta (RC=$RC)" test "$RC" -ne 0
afirma "AC-M1 con un KiB menos no paró" no_tiene "$FAKE_OPS" '^stop$'

# --- cerrojo contención: el turno es de otro → espera avisando y acaba sin él (exit 75)
escenario espera
/usr/bin/cp "$tmp/unidad-vieja" "$FAKE_UNIT_FILE"
printf 't_99999 tester phpunit\n' > "$FABRIK_DATA/locks/factory-test.owner"
exec 8>>"$FABRIK_DATA/locks/factory-test.lock"
flock 8   # el test «en curso» tiene el turno; el migrador no debe poder cogerlo
export FX_MIGRAR_WAIT=1
bash "$MIGRAR" > "$tmp/out-espera.log" 2>&1
RC=$?
flock -u 8
unset FX_MIGRAR_WAIT
afirma "AC-M1 con turno ajeno aborta (RC=$RC)" iguales "$RC" 75
afirma "AC-M1 avisa de quién tiene el turno" tiene "$tmp/out-espera.log" 'esperando factory-test.lock.*t_99999'
afirma "AC-M1 con turno ajeno no paró" no_tiene "$FAKE_OPS" '^stop$'

# --- cerrojo contención con liberación: espera avisando y, al soltar el turno, sigue y migra
escenario esperalibre
/usr/bin/cp "$tmp/unidad-vieja" "$FAKE_UNIT_FILE"
printf 't_99999 tester phpunit\n' > "$FABRIK_DATA/locks/factory-test.owner"
exec 8>>"$FABRIK_DATA/locks/factory-test.lock"
flock 8
export FX_MIGRAR_WAIT=20
bash "$MIGRAR" > "$tmp/out-esperalibre.log" 2>&1 &
MIG_PID=$!
sleep 2
flock -u 8   # liberamos el turno: el migrador, en espera, debe cogerlo y continuar
wait "$MIG_PID"
RC=$?
unset FX_MIGRAR_WAIT
afirma "AC-M1 espera y al liberar migra (RC=$RC)" iguales "$RC" 0
afirma "AC-M1 avisó mientras esperaba" tiene "$tmp/out-esperalibre.log" 'esperando factory-test.lock'
afirma "AC-M1 tras la espera llegó al stop" tiene "$FAKE_OPS" '^stop$'

# ======================================================================
# AC-2 (resto de ramas) y D-2/D-5: install.sh en modo install con falsos
# ======================================================================

# --comprobar con la unidad no instalada: aviso informativo, RC 0
escenario sinunidad
RC="$(comprobar sinunidad)"
afirma "AC-2 sin unidad instalada RC=$RC" iguales "$RC" 0
afirma "AC-2 dice que la unidad no está instalada" tiene "$tmp/out-sinunidad.log" 'no instalada'

# --comprobar sin poder saber el fs: aviso informativo, RC 0
escenario sinfs
export FAKE_FS_TYPE=""
RC="$(comprobar sinfs)"
afirma "AC-2 sin fs RC=$RC" iguales "$RC" 0
afirma "AC-2 avisa de que no sabe el fs" tiene "$tmp/out-sinfs.log" 'no se pudo saber'

# D-2: instalación nueva (sin datadir) en btrfs: chattr +C antes de mariadb-install-db
escenario d2
rm -rf "$HOME/$MDATA_REL"
bash "$FABRIK_DIR/install.sh" > "$tmp/out-d2.log" 2>&1
RC=$?
afirma "D-2 install.sh en btrfs RC=$RC" iguales "$RC" 0
afirma "D-2 chattr +C al datadir vacío" tiene "$FAKE_LOG" "chattr \+C .*mariadb$"
afirma "D-2 mariadb-install-db usó ese datadir" tiene "$FAKE_LOG" "mariadb-install-db .*--datadir=$HOME/$MDATA_REL"
l_chattr="$(grep -n 'chattr ' "$FAKE_LOG" | head -1 | cut -d: -f1)"
l_instdb="$(grep -n 'mariadb-install-db ' "$FAKE_LOG" | head -1 | cut -d: -f1)"
afirma "D-2 chattr +C va ANTES de mariadb-install-db" bash -c '[[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]' _ "$l_chattr" "$l_instdb"

# D-2 en no-btrfs: ni chattr ni +C (el fs no tiene COW)
escenario d2ext4
rm -rf "$HOME/$MDATA_REL"
export FAKE_FS_TYPE=ext4
bash "$FABRIK_DIR/install.sh" > "$tmp/out-d2ext4.log" 2>&1
RC=$?
afirma "D-2 install.sh en ext4 RC=$RC" iguales "$RC" 0
afirma "D-2 en ext4 no llama a chattr" no_tiene "$FAKE_LOG" 'chattr'

# D-2: si chattr falla, avisa y sigue
escenario d2chattrfail
rm -rf "$HOME/$MDATA_REL"
export FAKE_CHATTR_FAIL=1
bash "$FABRIK_DIR/install.sh" > "$tmp/out-d2chattrfail.log" 2>&1
RC=$?
afirma "D-2 chattr falla y sigue (RC=$RC)" iguales "$RC" 0
afirma "D-2 avisa de que sigue sin No_COW" tiene "$tmp/out-d2chattrfail.log" 'se sigue sin No_COW'

# D-5: instalación existente con datadir sin +C: solo avisa y apunta al migrador
escenario d5
bash "$FABRIK_DIR/install.sh" > "$tmp/out-d5.log" 2>&1
RC=$?
afirma "D-5 install.sh con datadir sin +C RC=$RC" iguales "$RC" 0
afirma "D-5 avisa y apunta al migrador" tiene "$tmp/out-d5.log" 'sin No_COW.*migrar-mariadb-rapido'

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
