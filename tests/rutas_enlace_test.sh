#!/usr/bin/env bash
# Test de rutas por enlace simbólico: los bin/ en bash encuentran scripts/ y bin/ del repo aunque se les
# llame por un enlace (p. ej. ~/.local/bin/factory-prep → <repo>/bin/factory-prep) y desde otro cwd.
#
# Sin efectos: HOME temporal, `uv` falso que solo apunta sus argumentos, Python de Hermes falso para
# fabrik-triage y un repo git de juguete para factory-juntar. No toca BD ni crea worktrees reales.
# Uso: bash tests/rutas_enlace_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CONFIG_PY="$FABRIK_DIR/scripts/fabrik_config.py"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

H="$tmp/home"; LINKS="$H/.local/bin"; SOLO="$tmp/solo-juntar"; STUBS="$tmp/stubs"; OTRO="$tmp/otro-cwd"
mkdir -p "$LINKS" "$SOLO" "$STUBS" "$OTRO" "$H/.config/fabrica"
: > "$H/.config/fabrica/db.env"

# Enlaces a todos los bin/ en bash (los de Python ya usan Path(__file__).resolve()).
for f in "$FABRIK_DIR"/bin/*; do
  head -1 "$f" | grep -q bash && ln -s "$f" "$LINKS/$(basename "$f")"
done
# Doble enlace (enlace → enlace → script) para factory-prep.
ln -s "$LINKS/factory-prep" "$H/.local/factory-prep-alias"
# factory-juntar enlazado SOLO, sin factory-prep al lado: debe encontrar el factory-prep del repo.
ln -s "$FABRIK_DIR/bin/factory-juntar" "$SOLO/factory-juntar"

# uv falso: apunta sus argumentos (uno por línea) y no devuelve nada (config «vacía»).
cat > "$STUBS/uv" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$UV_LOG"
exit 0
FAKE
chmod +x "$STUBS/uv"

# Python de Hermes falso para fabrik-triage: pasa la sonda de import y, al ejecutar el script, informa de
# FABRIK_SRC y de si ahí está bin/fabrik-modelos.
PYF="$H/.hermes/installs/x/environments/y/venv/bin/python"
mkdir -p "$(dirname "$PYF")"
cat > "$PYF" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == "-c" ]] && exit 0
cat > /dev/null
echo "FABRIK_SRC=$FABRIK_SRC"
[[ -x "$FABRIK_SRC/bin/fabrik-modelos" ]] && echo "modelos=ok"
exit 0
FAKE
chmod +x "$PYF"

export UV_LOG="$tmp/uv.log"
# entorno controlado: nada del entorno real que cambie el camino (FX_ORG haría que no se consulte la config)
corre() { # <salida> <comando> [args…]  — desde otro cwd, HOME temporal, PATH con los falsos delante
  local out="$1"; shift
  : > "$UV_LOG"
  (cd "$OTRO" && env -u FX_ORG -u HERMES_AGENT_SRC -u FABRIK_SRC -u FABRIK_DIR \
      HOME="$H" FX_WT="$tmp/wt" FX_SRC_ROOT="$tmp/src" PATH="$STUBS:$LINKS:/usr/bin:/bin" \
      timeout 30 "$@") > "$out" 2>&1
}
usa_config_del_repo() { # <nombre>
  if grep -qxF "$CONFIG_PY" "$UV_LOG"; then ok_
  else fallo "$1 por enlace no usa $CONFIG_PY (uv recibió: $(tr '\n' ' ' < "$UV_LOG"))"; fi
}

# --- factory-prep (enlace, y enlace a enlace) ---
corre "$tmp/prep.out" "$LINKS/factory-prep" mirepo mislug
usa_config_del_repo "factory-prep"
grep -q 'fabrik_config.py' "$tmp/prep.out" && fallo "factory-prep se queja de fabrik_config.py: $(cat "$tmp/prep.out")" || ok_
[[ -e "$tmp/wt" ]] && fallo "factory-prep creó $tmp/wt (no debía tener efectos)" || ok_

corre "$tmp/prep2.out" "$H/.local/factory-prep-alias" mirepo mislug
usa_config_del_repo "factory-prep (enlace a enlace)"

# --- factory-gc ---
corre "$tmp/gc.out" "$LINKS/factory-gc" --seco
usa_config_del_repo "factory-gc"

# --- fabrik config ---
corre "$tmp/fabrik.out" "$LINKS/fabrik" config get owners
usa_config_del_repo "fabrik config"

# --- fabrik-triage: FABRIK_SRC es el repo y ahí está bin/fabrik-modelos ---
corre "$tmp/triage.out" "$LINKS/fabrik-triage" --seco
if grep -qxF "FABRIK_SRC=$FABRIK_DIR" "$tmp/triage.out" && grep -qx 'modelos=ok' "$tmp/triage.out"; then ok_
else fallo "fabrik-triage por enlace no resuelve el repo: $(cat "$tmp/triage.out")"; fi

# --- factory-juntar --limpiar: llama al factory-prep del repo aunque no haya otro enlace a su lado ---
W="$tmp/wt/mirepo/feat"
mkdir -p "$W"
git -C "$W" init -q -b agente/feat
git -C "$W" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
git -C "$W" branch agente/sub
corre "$tmp/juntar.out" "$SOLO/factory-juntar" mirepo feat sub --limpiar
if grep -q 'no es un worktree de la fábrica' "$tmp/juntar.out"; then ok_
else fallo "factory-juntar por enlace no llega al factory-prep del repo: $(cat "$tmp/juntar.out")"; fi

# --- ningún bin/ en bash calcula su ruta sin resolver el enlace ---
for f in "$FABRIK_DIR"/bin/*; do
  head -1 "$f" | grep -q bash || continue
  if grep -nE 'dirname "(\$\{BASH_SOURCE\[0\]\}|\$0)"' "$f" | grep -v 'readlink -f' > "$tmp/sin-resolver"; then
    fallo "$(basename "$f") calcula su ruta sin readlink -f: $(cat "$tmp/sin-resolver")"
  else ok_; fi
done

echo "rutas_enlace_test: $ok ok, $fail fallos"
[ "$fail" -eq 0 ]
