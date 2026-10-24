#!/usr/bin/env bash
# Tests de bin/fabrik: comando paraguas que delega en factory-test, factory-prep,
# factory-gc y fabrik-memoria (resolución por PATH, ayuda, subcomando desconocido).
# Bash puro, sin dependencias. Uso: bash tests/fabrik_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FABRIK="$FABRIK_DIR/bin/fabrik"

ok=0
fail=0

fallo() {
  fail=$((fail + 1))
  echo "FALLO: $1" >&2
}

ok_() {
  ok=$((ok + 1))
}

# --- Herramientas falsas: registran su identidad + sus argumentos (uno por línea)
#     y salen con FABRIK_FAKE_EXIT ---
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for herramienta in factory-test factory-prep factory-gc fabrik-memoria; do
  cat > "$tmp/$herramienta" <<'FAKE'
#!/usr/bin/env bash
{
  printf '%s\n' "$(basename "$0")"
  printf '%s\n' "$@"
} >> "$FABRIK_FAKE_LOG"
exit "${FABRIK_FAKE_EXIT:-7}"
FAKE
  chmod +x "$tmp/$herramienta"
done

export FABRIK_FAKE_LOG="$tmp/args.log"
export FABRIK_FAKE_EXIT=7

OUT="$tmp/out"
ERR="$tmp/err"

run_fabrik() {
  : > "$OUT"
  : > "$ERR"
  PATH="$tmp:$PATH" "$FABRIK" "$@" > "$OUT" 2> "$ERR"
  RC=$?
}

# delega <subcomando> <herramienta esperada> <args...>
delega() {
  local sub="$1" esperada="$2"
  shift 2
  : > "$FABRIK_FAKE_LOG"
  {
    printf '%s\n' "$esperada"
    printf '%s\n' "$@"
  } > "$tmp/args-esperados"
  run_fabrik "$sub" "$@"
  local nombre="AC-1 $sub delega en $esperada args y exit code"
  if [ "$RC" -ne "$FABRIK_FAKE_EXIT" ]; then
    fallo "$nombre (exit $RC, esperado $FABRIK_FAKE_EXIT)"
    return
  fi
  if ! diff -u "$tmp/args-esperados" "$FABRIK_FAKE_LOG" > "$tmp/diff"; then
    fallo "$nombre (herramienta/argumentos)"
    cat "$tmp/diff" >&2
    return
  fi
  ok_
}

menciona_cuatro_subcomandos() {
  grep -q 'test' "$OUT" && grep -q 'prep' "$OUT" && grep -q 'gc' "$OUT" && grep -q 'memoria' "$OUT"
}

# ---------- AC-1: delegación con args exactos y exit code ----------
delega test factory-test --filtro "nombre con espacios" "" -- -v
delega prep factory-prep acme/api-acme mi-slug --base develop
delega gc factory-gc --seco
delega memoria fabrik-memoria recall "síntoma con espacios"

# AC-1 extra: exit code distinto propagado (p. ej. 3)
FABRIK_FAKE_EXIT=3
delega test factory-test cualquier-cosa
FABRIK_FAKE_EXIT=7

# ---------- AC-2: ayuda en español por stdout, exit 0 ----------
for modo in "" "ayuda" "-h" "--help"; do
  run_fabrik $modo
  nombre="AC-2 ayuda (fabrik $modo)"
  if [ "$RC" -ne 0 ]; then
    fallo "$nombre (exit $RC)"
  elif [ -s "$ERR" ]; then
    fallo "$nombre (stderr no vacío)"
  elif ! menciona_cuatro_subcomandos; then
    fallo "$nombre (no menciona los 4 subcomandos)"
  else
    ok_
  fi
done

# AC-2 extra: argumentos tras 'ayuda' se ignoran
run_fabrik ayuda lo-que-sea
if [ "$RC" -ne 0 ]; then
  fallo "AC-2 'ayuda' ignora args extra (exit $RC)"
elif ! menciona_cuatro_subcomandos; then
  fallo "AC-2 'ayuda' ignora args extra (no menciona los 4 subcomandos)"
else
  ok_
fi

# ---------- AC-3: subcomando desconocido ----------
run_fabrik xyz
if [ "$RC" -ne 2 ]; then
  fallo "AC-3 desconocido exit 2 (exit $RC)"
elif ! grep -q 'subcomando desconocido: xyz' "$ERR"; then
  fallo "AC-3 mensaje por stderr"
elif [ -s "$OUT" ]; then
  fallo "AC-3 stdout debe estar vacío"
else
  ok_
fi

# AC-3 extra: la ayuda breve también va por stderr
run_fabrik no-existe
if [ "$RC" -ne 2 ]; then
  fallo "AC-3 breve exit 2 (exit $RC)"
elif ! grep -q 'subcomando desconocido: no-existe' "$ERR"; then
  fallo "AC-3 breve mensaje por stderr"
elif ! grep -Eq 'test|prep|gc|memoria' "$ERR"; then
  fallo "AC-3 ayuda breve por stderr"
elif [ -s "$OUT" ]; then
  fallo "AC-3 breve stdout debe estar vacío"
else
  ok_
fi

# ---------- AC-4: README lista bin/fabrik y las 4 herramientas ----------
fila_bin="$(grep '| `bin/`' "$FABRIK_DIR/README.md")"
if [ -z "$fila_bin" ]; then
  fallo "AC-4 README sin fila bin/"
elif ! printf '%s' "$fila_bin" | grep -qF '`fabrik`'; then
  fallo "AC-4 README fila bin/ sin \`fabrik\`"
elif ! printf '%s' "$fila_bin" | grep -qF '`factory-test`'; then
  fallo "AC-4 README fila bin/ sin \`factory-test\`"
elif ! printf '%s' "$fila_bin" | grep -qF '`factory-prep`'; then
  fallo "AC-4 README fila bin/ sin \`factory-prep\`"
elif ! printf '%s' "$fila_bin" | grep -qF '`factory-gc`'; then
  fallo "AC-4 README fila bin/ sin \`factory-gc\`"
elif ! printf '%s' "$fila_bin" | grep -qF '`fabrik-memoria`'; then
  fallo "AC-4 README fila bin/ sin \`fabrik-memoria\`"
else
  ok_
fi

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
