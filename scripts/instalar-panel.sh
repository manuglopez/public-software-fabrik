#!/usr/bin/env bash
# instalar-panel.sh — monta The Factory (panel de escritorio de Hermes) en esta máquina. Lo llama install.sh; idempotente.
#   1. con node/npm: construye plugin/fabrica/desktop/plugin.js (scripts/plugin-desktop.sh build); sin ellos avisa y sigue
#   2. enlaza ~/.hermes/plugins/fabrica → <repo>/plugin/fabrica (paquete «linked»: Hermes recarga en caliente);
#      un ~/.hermes/plugins/fabrica que no sea un enlace no se toca
#   3. añade fabrica a plugins.enabled (`hermes plugins enable fabrica`) y avisa de activar la mitad de escritorio
# Siempre sale 0: el panel es opcional y el resto de la fábrica no depende de él.
# Variables para pruebas/CI: FABRIK_NODE (ejecutable de node a buscar), FABRIK_PLUGIN_DESKTOP (script que construye).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$REPO/plugin/fabrica"
DESTINO="$HOME/.hermes/plugins/fabrica"
CONSTRUIR="${FABRIK_PLUGIN_DESKTOP:-$REPO/scripts/plugin-desktop.sh}"
ok(){ printf '  \e[32m✓\e[0m %s\n' "$*"; }; av(){ printf '  \e[33m!\e[0m %s\n' "$*"; }

if command -v "${FABRIK_NODE:-node}" >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  if SALIDA="$(bash "$CONSTRUIR" build 2>&1)"; then
    ok "panel: desktop/plugin.js construido"
  else
    av "panel: no se pudo construir (bash scripts/plugin-desktop.sh build); la mitad de escritorio no se cargará"
    printf '%s\n' "$SALIDA" | tail -5 | sed 's/^/      /'
  fi
else
  av "panel: sin node/npm no se construye la mitad de escritorio (instala node y repite ./install.sh); el resto de la fábrica sigue"
fi

mkdir -p "$HOME/.hermes/plugins"
if [[ -e "$DESTINO" && ! -L "$DESTINO" ]]; then
  av "panel: ${DESTINO/#$HOME/~} existe y no es un enlace; no se toca (bórralo o muévelo para enlazar el del motor)"
else
  ln -sfn "$PLUGIN" "$DESTINO" && ok "panel: enlace ${DESTINO/#$HOME/~} → $PLUGIN"
  if hermes plugins enable fabrica >/dev/null 2>&1; then
    ok "panel: fabrica en plugins.enabled (reinicia el gateway: hermes gateway restart)"
  else
    av "panel: no se pudo activar; ejecuta: hermes plugins enable fabrica"
  fi
  av "panel: activa la mitad de escritorio en Hermes Desktop → Capabilities → Plugins → The Factory"
fi
exit 0
