#!/usr/bin/env bash
# tests/triage_cupo_test.sh — Integración end-to-end de esperar_cupo con bin/fabrik-triage.
#
# Tablero temporal (HOME temporal con symlink a los installs de Hermes), un
# `hermes` falso en PATH que registra cada llamada y aplica schedule/unblock
# reales sobre el tablero (el efecto que tendría el hermes real), y fotos de
# cupos generadas con `date`. Nada de sleep; los cambios de foto fuerzan un
# mtime distinto con touch. Cada pasada es un proceso nuevo (`--una-vez`).
#
# AC-1 aparcado único tras N pasadas · AC-2 reserva con margen despacha ·
# AC-3 foto rota despacha sin filtrar, desaparca y avisa una vez por pasada ·
# AC-4 retomada al renovarse el cupo · conserje ignora el comentario ⏳.
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIAGE="$FABRIK_DIR/bin/fabrik-triage"
HELPER="$FABRIK_DIR/tests/helpers/kanban_apply.py"
HA="${HERMES_AGENT_SRC:-$HOME/.hermes/hermes-agent}"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }

# Python del venv de Hermes (mismo criterio que bin/fabrik-triage)
PY=""
for c in "$HOME"/.hermes/installs/*/environments/*/venv/bin/python; do
  if env -u VIRTUAL_ENV -u HERMES_DELEGATED_CHILD_CONTEXT -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD PYTHONPATH="$HA" "$c" -c "import hermes_cli.kanban_db" 2>/dev/null; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "FALLO: no encuentro el Python de Hermes" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Entorno temporal -------------------------------------------------------
mkdir -p "$tmp/home/.hermes" "$tmp/profiles/programador" "$tmp/bin"
ln -s "$HOME/.hermes/installs" "$tmp/home/.hermes/installs"

cat > "$tmp/profiles/programador/config.yaml" <<'YAML'
model:
  provider: kimi-coding
  model: kimi-for-coding
fallback_providers:
  - provider: claude-subscription
    model: claude-sonnet-5-5-high
YAML

# hermes falso: registra y aplica schedule/unblock reales (efecto del CLI real)
cat > "$tmp/bin/hermes" <<FAKE
#!/usr/bin/env bash
echo "hermes \$*" >> "\$FABRIK_HK_LOG"
if [ "\$1" = "kanban" ]; then
  args=("\${@:2}")
  board=""; action=""; tid=""
  i=0
  while [ \$i -lt \${#args[@]} ]; do
    case "\${args[\$i]}" in
      --board) board="\${args[\$((i+1))]}"; i=\$((i+2));;
      schedule|unblock) action="\${args[\$i]}"; tid="\${args[\$((i+1))]}"; break;;
      *) i=\$((i+1));;
    esac
  done
  case "\$action" in
    schedule) env -u VIRTUAL_ENV -u HERMES_DELEGATED_CHILD_CONTEXT -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD PYTHONPATH="$HA" "$PY" "$HELPER" schedule "\$board" "\$tid" >/dev/null;;
    unblock)  env -u VIRTUAL_ENV -u HERMES_DELEGATED_CHILD_CONTEXT -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD PYTHONPATH="$HA" "$PY" "$HELPER" unblock  "\$board" "\$tid" >/dev/null;;
  esac
fi
exit 0
FAKE
chmod +x "$tmp/bin/hermes"

export FABRIK_HK_LOG="$tmp/hk.log"
: > "$FABRIK_HK_LOG"

AHORA=$(date +%s)
RESET_CORTO=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)
RESET_LARGO=$(date -u -d '+3 days' +%Y-%m-%dT%H:%M:%SZ)
RESET_MEDIO=$(date -u -d '+30 hours' +%Y-%m-%dT%H:%M:%SZ)
export FABRIK_CUPOS_LOG="$tmp/cupos.jsonl"
export FABRIK_CUPO_ESTADO="$tmp/cupo-espera.json"
export FABRIK_PROFILES_DIR="$tmp/profiles"
# kanban_home() (connect/create_board) resuelve por HERMES_KANBAN_HOME como raíz
# hermes (boards en <raíz>/kanban/boards) y no por HOME; sin esto el tablero
# temporal acabaría en el kanban real de ~/.hermes.
export HERMES_KANBAN_HOME="$tmp/home/.hermes"

foto_agotada() { # toda la cadena (kimi + claude) al 100 %, resets futuros
  printf '{"t": %s, "bolsas": {"kimi_5h": [100.0, "%s"], "kimi_7d": [100.0, "%s"], "claude_5h": [100.0, "%s"], "claude_sem": [100.0, "%s"]}}\n' \
    "$(date +%s)" "$RESET_CORTO" "$RESET_LARGO" "$RESET_CORTO" "$RESET_LARGO" > "$FABRIK_CUPOS_LOG"
  touch -d "@$((AHORA + 10))" "$FABRIK_CUPOS_LOG" 2>/dev/null || true
}

foto_margen() { # kimi con margen → la cadena es lanzable aunque claude siga al 100 %
  printf '{"t": %s, "bolsas": {"kimi_5h": [10.0, "%s"], "kimi_7d": [50.0, "%s"], "claude_5h": [100.0, "%s"], "claude_sem": [100.0, "%s"]}}\n' \
    "$(date +%s)" "$RESET_CORTO" "$RESET_MEDIO" "$RESET_CORTO" "$RESET_LARGO" > "$FABRIK_CUPOS_LOG"
  touch -d "@$((AHORA + 20))" "$FABRIK_CUPOS_LOG" 2>/dev/null || true
}

pasada() { # pasada <n> → stdout+stderr en $tmp/out<n>
  local n="$1"
  env -u VIRTUAL_ENV -u HERMES_DELEGATED_CHILD_CONTEXT -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD \
      HOME="$tmp/home" PATH="$tmp/bin:$PATH" \
      FABRIK_HK_LOG="$FABRIK_HK_LOG" FABRIK_CUPOS_LOG="$FABRIK_CUPOS_LOG" \
      FABRIK_CUPO_ESTADO="$FABRIK_CUPO_ESTADO" FABRIK_PROFILES_DIR="$FABRIK_PROFILES_DIR" \
      HERMES_AGENT_SRC="$HA" \
      "$TRIAGE" --una-vez > "$tmp/out$n" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    fallo "pasada $n: exit $rc"; cat "$tmp/out$n" >&2
  fi
}

cuenta() { grep -c -- "$1" "$FABRIK_HK_LOG" 2>/dev/null; }
estado_de() {
  env -u VIRTUAL_ENV -u HERMES_DELEGATED_CHILD_CONTEXT -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD PYTHONPATH="$HA" HOME="$tmp/home" "$PY" "$HELPER" estado pruebas | grep "^$1:" | cut -d: -f2
}

# --- Setup: tablero y tarjetas ----------------------------------------------
env -u VIRTUAL_ENV -u HERMES_DELEGATED_CHILD_CONTEXT -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD \
    PYTHONPATH="$HA" HOME="$tmp/home" "$PY" "$HELPER" init || { echo "FALLO creando tablero" >&2; exit 1; }

IDS=$(env -u VIRTUAL_ENV -u HERMES_DELEGATED_CHILD_CONTEXT -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD PYTHONPATH="$HA" HOME="$tmp/home" "$PY" "$HELPER" crear '[
  {"title": "T1 kimi agotado", "assignee": "programador"},
  {"title": "T2 override deepseek", "assignee": "programador", "model_override": "deepseek-v4-pro", "provider_override": "deepseek"},
  {"title": "T3 manual [manual]", "assignee": "programador"}
]') || { echo "FALLO creando tarjetas: $IDS" >&2; exit 1; }
T1=$(printf '%s\n' "$IDS" | sed -n 1p)
T2=$(printf '%s\n' "$IDS" | sed -n 2p)
T3=$(printf '%s\n' "$IDS" | sed -n 3p)

# --- AC-1 + AC-2: aparcado único y reserva con margen -----------------------
foto_agotada
pasada 1
pasada 2   # N pasadas con la misma foto: sin schedule ni comentario repetidos

if [ "$(cuenta "schedule $T1 ")" -eq 1 ]; then ok_; else fallo "AC-1 schedule de $T1 único tras N pasadas"; fi
# `hermes kanban schedule <id> <texto>` ya añade el comentario «SCHEDULED: <texto>»: ningún `comment` explícito.
if [ "$(cuenta "kanban .*comment .*$T1")" -eq 0 ]; then ok_; else fallo "AC-1 un solo comentario de espera (sin comment explícito)"; fi
if grep -q -- "schedule $T2 " "$FABRIK_HK_LOG" || grep -q -- "schedule $T3 " "$FABRIK_HK_LOG"; then
  fallo "AC-2 T2 (override sin bolsa) o T3 ([manual]) no deben aparcarse"
else
  ok_
fi
if [ "$(cuenta 'dispatch')" -ge 1 ]; then ok_; else fallo "AC-2 las lanzables deben despacharse (dispatch)"; fi
if [ "$(estado_de "$T1")" = "scheduled" ]; then ok_; else fallo "AC-1 $T1 debe quedar scheduled"; fi
if grep -q -- "⏳ esperando cupo" "$FABRIK_HK_LOG"; then ok_; else fallo "AC-1 el comentario menciona la espera de cupo"; fi
if [ -f "$FABRIK_CUPO_ESTADO" ] && grep -q "$T1" "$FABRIK_CUPO_ESTADO"; then ok_; else fallo "AC-1 el estado de espera registra $T1"; fi

# --- AC-4: retomada al renovarse el cupo ------------------------------------
foto_margen
pasada 3

if [ "$(cuenta "unblock $T1")" -eq 1 ]; then ok_; else fallo "AC-4 $T1 debe retomarse (unblock) al renovarse el cupo"; fi
if grep -q "retomada" "$tmp/out3"; then ok_; else fallo "AC-4 log «retomada» en la pasada 3"; fi
if grep -q "$T1" "$FABRIK_CUPO_ESTADO"; then fallo "AC-4 $T1 debe salir del estado de espera"; else ok_; fi
if [ "$(estado_de "$T1")" = "ready" ]; then ok_; else fallo "AC-4 $T1 debe volver a ready"; fi

# --- Reaparcado tras una ventana nueva (renueva distinto) --------------------
foto_agotada   # renueva distinto: touch con mtime distinto fuerza foto nueva
touch -d "@$((AHORA + 25))" "$FABRIK_CUPOS_LOG" 2>/dev/null || true
pasada 4
if [ "$(cuenta "schedule $T1 ")" -eq 2 ]; then ok_; else fallo "reaparcado permitido en ventana nueva (schedule x2)"; fi

# --- AC-3: foto rota → sin filtrar, desaparca y avisa una vez por pasada -----
sched_antes=$(cuenta "schedule $T1 ")
printf '{no-es-json\n' > "$FABRIK_CUPOS_LOG"
touch -d "@$((AHORA + 30))" "$FABRIK_CUPOS_LOG" 2>/dev/null || true
pasada 5
pasada 6

if [ "$(cuenta "unblock $T1")" -eq 2 ]; then ok_; else fallo "AC-3 $T1 desaparcada con foto rota"; fi
if [ "$(cuenta "schedule $T1 ")" -eq "$sched_antes" ]; then ok_; else fallo "AC-3 con foto rota no se aparca nada"; fi
n5=$(grep -c "despacho sin filtrar" "$tmp/out5")
n6=$(grep -c "despacho sin filtrar" "$tmp/out6")
if [ "$n5" -eq 1 ] && [ "$n6" -eq 1 ]; then ok_; else fallo "AC-3 un aviso por pasada, no uno cada 2 s ($n5/$n6)"; fi

# --- salida del modo sin filtro ----------------------------------------------
# Nota: el aviso «✓ foto recuperada» solo se emite dentro de un proceso
# persistente (el servicio real); cada pasada de este test es un proceso nuevo,
# así que la salida del modo se verifica en tests/triage_cupos_unit_test.py.

# --- el conserje no procesa el comentario ⏳ ----------------------------------
env -u VIRTUAL_ENV -u HERMES_DELEGATED_CHILD_CONTEXT -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD PYTHONPATH="$HA" HOME="$tmp/home" "$PY" "$HELPER" comentario pruebas "$T2" "humano-uno" "⏳ esperando cupo de kimi_5h (renueva 24/10 05:00 hora local); cadena agotada: kimi_5h, claude_5h" || fallo "insertar comentario ⏳"
pasada 8
if [ "$(cuenta 'conserje chat')" -eq 0 ]; then ok_; else fallo "el conserje no debe procesar el comentario ⏳"; fi

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
