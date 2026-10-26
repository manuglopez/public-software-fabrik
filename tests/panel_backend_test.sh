#!/usr/bin/env bash
# Tests del backend de The Factory (plugin/fabrica/dashboard): descubre tests/panel/test_*.py.
# Uso: factory-test -- bash tests/panel_backend_test.sh
# Sin red ni HOME real: cada test usa fixtures de tests/panel/fixtures/ y subprocess simulado.
set -u
FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FABRIK_DIR" || exit 1
exec uv run --with fastapi --with httpx --with pyyaml python -m unittest discover -s tests/panel -p 'test_*.py' -t . -v
