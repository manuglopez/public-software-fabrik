#!/usr/bin/env bash
# Tests de la mitad de escritorio de The Factory (plugin/fabrica/desktop): registro, página, chip, api y colores fijos.
# Construye con esbuild y un SDK falso (tests/panel/sdk_falso.mjs); sin Hermes ni red (salvo `npm ci` la primera vez).
# Uso: factory-test -- bash tests/panel_desktop_test.sh
set -u
FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP="$FABRIK_DIR/plugin/fabrica/desktop"
command -v node >/dev/null && command -v npm >/dev/null || { echo "SALTADO: faltan node/npm" >&2; exit 0; }
[[ -d "$DESKTOP/node_modules/esbuild" ]] || (cd "$DESKTOP" && npm ci --no-audit --no-fund --ignore-scripts >/dev/null) || { echo "FALLO: npm ci" >&2; exit 1; }
# Un fichero por zona (D-9 R-2): node --test los lanza en paralelo; cada uno construye en desktop/.prueba/<zona>/.
exec node --test "$FABRIK_DIR"/tests/panel/*.test.mjs
