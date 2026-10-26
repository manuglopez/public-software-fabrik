#!/usr/bin/env bash
# Tests de config/agent-shell.sh: el bin/ de la fábrica va el PRIMERO del PATH de los agentes.
#
# AC-F2 Con un HOME falso que tiene .nvm/versions/node/vX/bin/greptile y un PATH que ya trae $FABRIK_HOME/bin detrás,
#       tras `source config/agent-shell.sh`, `command -v greptile` = $FABRIK_HOME/bin/greptile. Cargarlo dos veces no
#       duplica entradas. Sin nvm, el bin/ de la fábrica sigue el primero.
#
# Bash puro. HOME y FABRIK_HOME temporales: nunca toca el entorno real.
# Uso: bash tests/agent_shell_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_INIT="$FABRIK_DIR/config/agent-shell.sh"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
bien() { ok=$((ok + 1)); }
igual() { # <descripción> <esperado> <obtenido>
  if [ "$2" = "$3" ]; then bien; else fallo "$1: esperaba «$2», obtuve «$3»"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

FH="$tmp/fabrik"          # FABRIK_HOME falso, con un greptile (el envoltorio) en su bin/
mkdir -p "$FH/bin"
printf '#!/bin/sh\necho envoltorio\n' >"$FH/bin/greptile"
chmod +x "$FH/bin/greptile"

# ejecuta <HOME> <PATH inicial> <veces que se carga> <orden> en un bash limpio y devuelve la salida
en_shell() {
  local home="$1" path="$2" veces="$3" orden="$4"
  env -i HOME="$home" PATH="$path" FABRIK_HOME="$FH" bash -c '
    for _ in $(seq 1 '"$veces"'); do source "'"$SHELL_INIT"'"; done
    '"$orden"
}

cuenta() { # <texto> <entrada> → nº de veces que <entrada> aparece como elemento del PATH
  printf '%s' "$1" | tr ':' '\n' | grep -cxF -- "$2" || true
}

# ---------- AC-F2: nvm con su greptile real, y el PATH ya trae el bin/ de la fábrica detrás ----------
H1="$tmp/home1"
mkdir -p "$H1/.nvm/versions/node/v18.0.0/bin" "$H1/.nvm/versions/node/v20.1.0/bin"
for v in v18.0.0 v20.1.0; do
  printf '#!/bin/sh\necho real\n' >"$H1/.nvm/versions/node/$v/bin/greptile"
  chmod +x "$H1/.nvm/versions/node/$v/bin/greptile"
done
BASE="/usr/bin:/bin"
PATH_PREVIO="/opt/x:$FH/bin:$BASE"   # el bin/ de la fábrica ya está, pero detrás

igual "AC-F2 una carga: greptile = el envoltorio de la fábrica" "$FH/bin/greptile" \
  "$(en_shell "$H1" "$PATH_PREVIO" 1 'command -v greptile')"
igual "AC-F2 dos cargas: greptile = el envoltorio" "$FH/bin/greptile" \
  "$(en_shell "$H1" "$PATH_PREVIO" 2 'command -v greptile')"
igual "AC-F2 el primer elemento del PATH es el bin/ de la fábrica" "$FH/bin" \
  "$(en_shell "$H1" "$PATH_PREVIO" 1 'echo "${PATH%%:*}"')"
P1="$(en_shell "$H1" "$PATH_PREVIO" 1 'echo "$PATH"')"
P2="$(en_shell "$H1" "$PATH_PREVIO" 2 'echo "$PATH"')"
P3="$(en_shell "$H1" "$PATH_PREVIO" 3 'echo "$PATH"')"
igual "AC-F2 sin duplicados del bin/ de la fábrica (1 carga)" 1 "$(cuenta "$P1" "$FH/bin")"
igual "AC-F2 sin duplicados del bin/ de la fábrica (2 cargas)" 1 "$(cuenta "$P2" "$FH/bin")"
igual "AC-F2 sin duplicados del bin/ de nvm (2 cargas)" 1 "$(cuenta "$P2" "$H1/.nvm/versions/node/v20.1.0/bin")"
igual "AC-F2 idempotente: 2 y 3 cargas dan el mismo PATH" "$P2" "$P3"
igual "AC-F2 nvm sigue en el PATH (la versión más alta), detrás de la fábrica" \
  "$FH/bin:$H1/.nvm/versions/node/v20.1.0/bin:/opt/x:$BASE" "$P1"
# con el envoltorio fuera de la fábrica, el real de nvm queda alcanzable con una ruta que no pase por la fábrica
igual "AC-F2 el greptile real de nvm sigue encontrándose tras el envoltorio" "$H1/.nvm/versions/node/v20.1.0/bin/greptile" \
  "$(en_shell "$H1" "$PATH_PREVIO" 1 'PATH="${PATH#"$FABRIK_HOME/bin:"}"; command -v greptile')"

# ---------- varias apariciones previas del bin/ de la fábrica (delante, en medio y al final) ----------
P4="$(en_shell "$H1" "$FH/bin:/opt/x:$FH/bin:$BASE:$FH/bin" 1 'echo "$PATH"')"
igual "AC-F2 varias apariciones previas: una sola y la primera" 1 "$(cuenta "$P4" "$FH/bin")"
igual "AC-F2 varias apariciones previas: el primero es el bin/ de la fábrica" "$FH/bin" "${P4%%:*}"
igual "AC-F2 varias apariciones previas: el resto del PATH se conserva" \
  "$FH/bin:$H1/.nvm/versions/node/v20.1.0/bin:/opt/x:$BASE" "$P4"

# ---------- sin nvm y con el PATH sin el bin/ de la fábrica ----------
H2="$tmp/home2"
mkdir -p "$H2"
igual "AC-F2 sin nvm: la fábrica va la primera" "$FH/bin:$BASE" "$(en_shell "$H2" "$BASE" 1 'echo "$PATH"')"
igual "AC-F2 sin nvm y 2 cargas: igual" "$FH/bin:$BASE" "$(en_shell "$H2" "$BASE" 2 'echo "$PATH"')"

echo "agent_shell_test: $ok ok / $fail fallos"
[ "$fail" -eq 0 ]
