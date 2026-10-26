#!/usr/bin/env bash
# AC-6b: la instalación del panel (scripts/instalar-panel.sh, que llama install.sh): construye, enlaza y activa The Factory.
# Aislamiento: HOME temporal, `hermes` falso (registra llamadas) y constructor falso; nada de ~/.hermes ni de red.
# Uso: factory-test -- bash tests/panel_install_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }
afirma() { local d="$1"; shift; if "$@"; then ok_; else fallo "$d"; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/bin"
unset FABRIK_CONFIG FABRIK_DATA HERMES_HOME
export FAKE_LOG="$tmp/fake.log"
export PATH="$tmp/bin:$PATH"

# hermes falso: registra y obedece FAKE_HERMES_FALLA=1
printf '%s\n' '#!/usr/bin/env bash' 'printf "hermes %s\n" "$*" >> "$FAKE_LOG"' '[[ "${FAKE_HERMES_FALLA:-0}" == 1 ]] && exit 1' 'exit 0' > "$tmp/bin/hermes"
# constructor falso: registra y obedece FAKE_BUILD_FALLA=1
printf '%s\n' '#!/usr/bin/env bash' 'printf "build %s\n" "$*" >> "$FAKE_LOG"' '[[ "${FAKE_BUILD_FALLA:-0}" == 1 ]] && { echo "esbuild: boom" >&2; exit 1; }' 'exit 0' > "$tmp/construir.sh"
chmod +x "$tmp/bin/hermes" "$tmp/construir.sh"
export FABRIK_PLUGIN_DESKTOP="$tmp/construir.sh"

PANEL="$FABRIK_DIR/scripts/instalar-panel.sh"
DESTINO="$HOME/.hermes/plugins/fabrica"
limpio() { sed 's/\x1b\[[0-9;]*m//g' "$1"; }
tiene() { limpio "$1" | grep -qE -- "$2"; }
en_log() { grep -qE -- "$1" "$FAKE_LOG"; }
reinicia() { : > "$FAKE_LOG"; rm -rf "$HOME/.hermes"; }

# --- 1. instalación normal: construye, enlaza, activa y avisa ---
reinicia
bash "$PANEL" > "$tmp/o1" 2>&1; rc=$?
afirma "sale 0" [ "$rc" -eq 0 ]
afirma "construye una vez con 'build'" [ "$(grep -c '^build build$' "$FAKE_LOG")" -eq 1 ]
afirma "enlaza ~/.hermes/plugins/fabrica al checkout del motor" [ "$(readlink "$DESTINO")" = "$FABRIK_DIR/plugin/fabrica" ]
afirma "activa con hermes plugins enable fabrica" en_log '^hermes plugins enable fabrica$'
afirma "avisa de Capabilities → Plugins" tiene "$tmp/o1" 'Capabilities → Plugins'
afirma "no toca config.yaml a mano" [ ! -e "$HOME/.hermes/config.yaml" ]

# --- 2. idempotente ---
bash "$PANEL" > "$tmp/o2" 2>&1; rc=$?
afirma "segunda ejecución sale 0" [ "$rc" -eq 0 ]
afirma "el enlace sigue igual" [ "$(readlink "$DESTINO")" = "$FABRIK_DIR/plugin/fabrica" ]

# --- 3. un fabrica que no es enlace no se pisa ---
reinicia
mkdir -p "$DESTINO"; echo mio > "$DESTINO/marca"
bash "$PANEL" > "$tmp/o3" 2>&1; rc=$?
afirma "sale 0 con carpeta existente" [ "$rc" -eq 0 ]
afirma "la carpeta existente sigue ahí, sin convertirse en enlace" [ ! -L "$DESTINO" ] && [ -f "$DESTINO/marca" ]
afirma "avisa de que no se toca" tiene "$tmp/o3" 'no es un enlace'
afirma "no la activa" bash -c "! grep -q 'plugins enable' '$FAKE_LOG'"

# --- 4. sin node: avisa y sigue (enlaza y activa igualmente) ---
reinicia
FABRIK_NODE=node-que-no-existe bash "$PANEL" > "$tmp/o4" 2>&1; rc=$?
afirma "sin node sale 0" [ "$rc" -eq 0 ]
afirma "sin node avisa" tiene "$tmp/o4" 'sin node/npm'
afirma "sin node no construye" bash -c "! grep -q '^build' '$FAKE_LOG'"
afirma "sin node enlaza igualmente" [ -L "$DESTINO" ]
afirma "sin node activa igualmente" en_log '^hermes plugins enable fabrica$'

# --- 5. el constructor falla: avisa, enseña la causa y sigue ---
reinicia
FAKE_BUILD_FALLA=1 bash "$PANEL" > "$tmp/o5" 2>&1; rc=$?
afirma "build roto sale 0" [ "$rc" -eq 0 ]
afirma "build roto avisa y enseña el error" tiene "$tmp/o5" 'esbuild: boom'
afirma "build roto enlaza igualmente" [ -L "$DESTINO" ]

# --- 6. hermes no puede activar: avisa con el comando a mano ---
reinicia
FAKE_HERMES_FALLA=1 bash "$PANEL" > "$tmp/o6" 2>&1; rc=$?
afirma "enable roto sale 0" [ "$rc" -eq 0 ]
afirma "enable roto da el comando a mano" tiene "$tmp/o6" 'hermes plugins enable fabrica'

# --- 7. install.sh invoca el paso del panel, después de los perfiles y antes del Kanban ---
afirma "install.sh llama a instalar-panel.sh" grep -q 'scripts/instalar-panel.sh' "$FABRIK_DIR/install.sh"
afirma "el paso del panel va antes de == Kanban" bash -c "awk '/instalar-panel.sh/{p=NR} /^echo \"== Kanban\"/{k=NR} END{exit !(p && k && p<k)}' '$FABRIK_DIR/install.sh'"
afirma "plugin.js generado no se versiona" bash -c "cd '$FABRIK_DIR' && git check-ignore -q plugin/fabrica/desktop/plugin.js"
afirma "node_modules no se versiona" bash -c "cd '$FABRIK_DIR' && git check-ignore -q plugin/fabrica/desktop/node_modules/x"

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
