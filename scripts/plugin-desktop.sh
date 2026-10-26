#!/usr/bin/env bash
# plugin-desktop.sh — construye la mitad de escritorio de The Factory (plugin/fabrica/desktop → plugin.js).
#   scripts/plugin-desktop.sh build   instala dependencias si faltan (npm ci) y genera desktop/plugin.js
#   scripts/plugin-desktop.sh watch   reconstruye en cada guardado (con el paquete enlazado, Hermes recarga solo)
#   scripts/plugin-desktop.sh check   construye y comprueba el bundle (sintaxis + validador de escritorio de Hermes)
# desktop/plugin.js es un artefacto: no se versiona (.gitignore) y lo regenera ./install.sh.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$REPO/plugin/fabrica"
DESKTOP="$PLUGIN/desktop"

uso() { echo "Uso: scripts/plugin-desktop.sh build|watch|check" >&2; exit 2; }
[[ $# -eq 1 ]] || uso
command -v node >/dev/null && command -v npm >/dev/null || { echo "plugin-desktop: faltan node/npm" >&2; exit 1; }

dependencias() {
  [[ -d "$DESKTOP/node_modules/esbuild" ]] || (cd "$DESKTOP" && npm ci --no-audit --no-fund --ignore-scripts)
}

case "$1" in
  build)
    dependencias
    (cd "$DESKTOP" && node build.mjs)
    echo "plugin-desktop: $DESKTOP/plugin.js generado"
    ;;
  watch)
    dependencias
    cd "$DESKTOP" && exec node build.mjs --watch
    ;;
  check)
    dependencias
    (cd "$DESKTOP" && node build.mjs)
    node --check "$DESKTOP/plugin.js"
    # Los únicos imports permitidos en el bundle son el SDK y react (el cargador no resuelve nada más).
    if grep -nE "^\s*(import|export)\b[^;]*\bfrom\s*['\"]" "$DESKTOP/plugin.js" | grep -vE "from\s*['\"](@hermes/plugin-sdk|react|react/jsx-runtime)['\"]"; then
      echo "plugin-desktop: el bundle importa algo que el cargador no resuelve" >&2
      exit 1
    fi
    if command -v hermes >/dev/null; then
      # El validador recorre todo `desktop/**/*.js`, también node_modules (ruido de react/xterm que no se carga nunca).
      # Se valida una copia con lo que de verdad llega a Hermes: sin node_modules ni cachés.
      tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
      mkdir -p "$tmp/fabrica"
      tar -C "$PLUGIN" --exclude=node_modules --exclude=.prueba --exclude=__pycache__ -cf - . | tar -C "$tmp/fabrica" -xf -
      hermes plugins doctor "$tmp/fabrica"
      hermes plugins validate "$tmp/fabrica"
    else
      echo "plugin-desktop: sin hermes; se omite 'hermes plugins doctor'" >&2
    fi
    ;;
  *) uso ;;
esac
