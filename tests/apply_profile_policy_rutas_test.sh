#!/usr/bin/env bash
# Tests de las rutas que scripts/apply_profile_policy.py PERSISTE en la config de los perfiles.
#
# AC-F4 Ejecutado desde una copia en una ruta con `.factory-worktrees` y con un `hermes` falso que registra sus
#       `config set`, `terminal.shell_init_files` apunta a $FABRIK_HOME/config/agent-shell.sh (no a la copia: un
#       worktree se borra y los perfiles pierden su entorno). Sin FABRIK_HOME, a ~/Code/software-fabrik. Si FABRIK_HOME
#       es un worktree, aborta (exit ≠ 0, mensaje claro) sin escribir nada. Leer (SOUL, profiles/) sigue saliendo del repo.
#
# HOME temporal y `hermes` falso en el PATH: nunca toca el ~/.hermes real. Uso: bash tests/apply_profile_policy_rutas_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
bien() { ok=$((ok + 1)); }
igual() { # <descripción> <esperado> <obtenido>
  if [ "$2" = "$3" ]; then bien; else fallo "$1: esperaba «$2», obtuve «$3»"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"
unset FABRIK_CONFIG FABRIK_HOME

# hermes falso: registra «hermes <args>» y sale 0
mkdir -p "$tmp/bin"
export FAKE_LOG="$tmp/hermes.log"
cat >"$tmp/bin/hermes" <<'EOF'
#!/usr/bin/env bash
printf 'hermes %s\n' "$*" >>"$FAKE_LOG"
exit 0
EOF
chmod +x "$tmp/bin/hermes"
export PATH="$tmp/bin:$PATH"

# Copia del motor DENTRO de un directorio llamado .factory-worktrees (como un worktree de la fábrica)
WT="$tmp/.factory-worktrees/software-fabrik/prueba"
mkdir -p "$WT"
cp -r "$FABRIK_DIR/scripts" "$FABRIK_DIR/profiles" "$FABRIK_DIR/config" "$FABRIK_DIR/packs" "$WT/"
cat >"$tmp/config.yaml" <<'EOF'
packs: []
EOF
export FABRIK_CONFIG="$tmp/config.yaml"

aplicar() { # <FABRIK_HOME o vacío> <rol> → RC, ERR; $FAKE_LOG con los `config set`
  : >"$FAKE_LOG"
  if [ -n "$1" ]; then
    FABRIK_HOME="$1" uv run --with pyyaml python "$WT/scripts/apply_profile_policy.py" "$2" >"$tmp/out" 2>"$tmp/err"
  else
    uv run --with pyyaml python "$WT/scripts/apply_profile_policy.py" "$2" >"$tmp/out" 2>"$tmp/err"
  fi
  RC=$?
  ERR="$(cat "$tmp/err")"
}
shell_init() { grep 'config set terminal.shell_init_files' "$FAKE_LOG" || true; }

# ---------- FABRIK_HOME estable: la ruta persistida sale de FABRIK_HOME, no de la copia ----------
STABLE="$tmp/estable/software-fabrik"
mkdir -p "$STABLE"
aplicar "$STABLE" tester
igual "AC-F4 desde un worktree con FABRIK_HOME estable: rc" 0 "$RC"
igual "AC-F4 shell_init_files = \$FABRIK_HOME/config/agent-shell.sh" \
  "hermes -p tester config set terminal.shell_init_files [\"$STABLE/config/agent-shell.sh\"]" "$(shell_init)"
if grep -q '\.factory-worktrees' "$FAKE_LOG"; then fallo "AC-F4 se persistió una ruta de worktree: $(grep '\.factory-worktrees' "$FAKE_LOG")"; else bien; fi
[ -s "$HOME/.hermes/profiles/tester/SOUL.md" ] && bien || fallo "AC-F4 leer sigue funcionando: el SOUL se genera desde el repo (la copia)"

# ---------- sin FABRIK_HOME: ~/Code/software-fabrik ----------
aplicar "" tester
igual "AC-F4 sin FABRIK_HOME: rc" 0 "$RC"
igual "AC-F4 sin FABRIK_HOME: ~/Code/software-fabrik" \
  "hermes -p tester config set terminal.shell_init_files [\"$HOME/Code/software-fabrik/config/agent-shell.sh\"]" "$(shell_init)"

# ---------- FABRIK_HOME es un worktree: aborta sin escribir ----------
rm -rf "$HOME/.hermes"
aplicar "$WT" tester
if [ "$RC" -ne 0 ]; then bien; else fallo "AC-F4 FABRIK_HOME worktree: debería salir con exit ≠ 0"; fi
case "$ERR" in *".factory-worktrees"*"no se ha escrito nada"*) bien ;; *) fallo "AC-F4 FABRIK_HOME worktree: mensaje poco claro: $ERR" ;; esac
case "$ERR" in *Traceback*) fallo "AC-F4 FABRIK_HOME worktree: traceback en vez de mensaje claro: $ERR" ;; *) bien ;; esac
igual "AC-F4 FABRIK_HOME worktree: ningún hermes ejecutado" 0 "$(wc -l <"$FAKE_LOG" | tr -d ' ')"
[ ! -e "$HOME/.hermes" ] && bien || fallo "AC-F4 FABRIK_HOME worktree: escribió en ~/.hermes"

# también si FABRIK_HOME llega por un enlace simbólico a un worktree
ln -s "$WT" "$tmp/enlace-a-worktree"
aplicar "$tmp/enlace-a-worktree" tester
if [ "$RC" -ne 0 ]; then bien; else fallo "AC-F4 FABRIK_HOME enlace a worktree: debería salir con exit ≠ 0"; fi
[ ! -e "$HOME/.hermes" ] && bien || fallo "AC-F4 FABRIK_HOME enlace a worktree: escribió en ~/.hermes"

# y si HOME (el valor por defecto) es un worktree
SAVE_HOME="$HOME"
mkdir -p "$tmp/.factory-worktrees/h/Code/software-fabrik"
HOME="$tmp/.factory-worktrees/h" aplicar "" tester
if [ "$RC" -ne 0 ]; then bien; else fallo "AC-F4 por defecto dentro de un worktree: debería salir con exit ≠ 0"; fi
HOME="$SAVE_HOME"

# ---------- el modo de solo lectura no se ve afectado ----------
: >"$FAKE_LOG"
FABRIK_HOME="$WT" uv run --with pyyaml python "$WT/scripts/apply_profile_policy.py" --seco >"$tmp/out" 2>"$tmp/err"
igual "AC-F4 --seco con FABRIK_HOME worktree: sigue siendo solo lectura (rc 0)" 0 "$?"
FABRIK_HOME="$WT" uv run --with pyyaml python "$WT/scripts/apply_profile_policy.py" --solo-soul --seco tester >"$tmp/out" 2>"$tmp/err"
igual "AC-F4 --solo-soul --seco con FABRIK_HOME worktree: rc 0" 0 "$?"

echo "apply_profile_policy_rutas_test: $ok ok / $fail fallos"
[ "$fail" -eq 0 ]
