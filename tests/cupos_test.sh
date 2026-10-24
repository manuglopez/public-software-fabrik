#!/usr/bin/env bash
# Tests unitarios de scripts/cupos.py
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 "$DIR/tests/cupos_unit_test.py"
rc=$?

if [ $rc -eq 0 ]; then
  echo "── final:"
  echo "1 ok / 0 fallos"
  exit 0
else
  echo "── final:"
  echo "0 ok / 1 fallos"
  exit 1
fi
