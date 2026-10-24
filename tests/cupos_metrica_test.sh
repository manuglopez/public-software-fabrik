#!/usr/bin/env bash
# Tests de métrica rate_limited por día y tablero en fabrik-cupos (AC-8).
# Uso: factory-test -- bash tests/cupos_metrica_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FABRIK_CUPOS="$FABRIK_DIR/bin/fabrik-cupos"
PYTHON="${PYTHON:-python3}"

ok=0
fail=0

fallo() {
  fail=$((fail + 1))
  echo "FALLO: $1" >&2
}

ok_() {
  ok=$((ok + 1))
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export FABRIK_KANBAN_BOARDS="$tmp/boards"
export TZ="Europe/Madrid"

mkdir -p "$tmp/boards/tablero1" "$tmp/boards/tablero2" "$tmp/boards/tablero3" "$tmp/boards/tablero4" "$tmp/boards/tablero5"

# Esquema estándar de kanban.db
crear_esquema() {
  local db="$1"
  sqlite3 "$db" <<'SQL'
CREATE TABLE task_runs (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id             TEXT NOT NULL,
    profile             TEXT,
    step_key            TEXT,
    agent_session_id    TEXT,
    started_at          INTEGER NOT NULL,
    ended_at            INTEGER,
    outcome             TEXT NOT NULL,
    failure_reason      TEXT
);
CREATE TABLE task_events (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id             TEXT NOT NULL,
    run_id              INTEGER,
    kind                TEXT NOT NULL,
    payload             TEXT,
    created_at          INTEGER NOT NULL
);
SQL
}

crear_esquema "$tmp/boards/tablero1/kanban.db"
crear_esquema "$tmp/boards/tablero2/kanban.db"
crear_esquema "$tmp/boards/tablero4/kanban.db" # vacío, sin datos

# Tablero 5: solo tiene task_runs, no task_events
sqlite3 "$tmp/boards/tablero5/kanban.db" "CREATE TABLE task_runs (id INTEGER PRIMARY KEY, task_id TEXT, started_at INTEGER, ended_at INTEGER, outcome TEXT);"
sqlite3 "$tmp/boards/tablero5/kanban.db" "INSERT INTO task_runs (task_id, started_at, ended_at, outcome) VALUES ('t_50', 0, 0, 'rate_limited');" # ts=0 ignorado

# Tablero3 corrupto / no sqlite
echo "no es una base de datos sqlite valida" > "$tmp/boards/tablero3/kanban.db"

HOY=$(date +%Y-%m-%d)
AYER=$(date -d "yesterday" +%Y-%m-%d)
VIEJO=$(date -d "10 days ago" +%Y-%m-%d)

# Timestamp a las 01:30 local de HOY: en UTC corresponde al día anterior (23:30 UTC)
TS_HOY_MADRUGADA=$(date -d "$HOY 01:30:00" +%s)
TS_HOY_TARDE=$(date -d "$HOY 15:00:00" +%s)
TS_AYER=$(date -d "$AYER 12:00:00" +%s)
TS_VIEJO=$(date -d "$VIEJO 12:00:00" +%s)

# Sembrar tablero1
# 1) HOY madrugada: ended_at a caballo de medianoche
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_runs (task_id, started_at, ended_at, outcome) VALUES ('t_1', $TS_HOY_MADRUGADA - 60, $TS_HOY_MADRUGADA, 'rate_limited');"
# 2) HOY tarde: ended_at es NULL (se usa started_at)
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_runs (task_id, started_at, ended_at, outcome) VALUES ('t_2', $TS_HOY_TARDE, NULL, 'rate_limited');"
# 3) AYER: ended_at ayer
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_runs (task_id, started_at, ended_at, outcome) VALUES ('t_3', $TS_AYER - 60, $TS_AYER, 'rate_limited');"
# 4) VIEJO (10 días atrás): no debe entrar en --dias 7
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_runs (task_id, started_at, ended_at, outcome) VALUES ('t_4', $TS_VIEJO - 60, $TS_VIEJO, 'rate_limited');"
# 5) HOY completed: no debe contar como rate_limited
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_runs (task_id, started_at, ended_at, outcome) VALUES ('t_5', $TS_HOY_TARDE - 60, $TS_HOY_TARDE, 'completed');"
# Eventos tablero1:
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_events (task_id, kind, payload, created_at) VALUES ('t_1', 'scheduled', '{\"reason\": \"⏳ esperando cupo de kimi_5h (renueva 03:00)\"}', $TS_HOY_TARDE);"
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_events (task_id, kind, payload, created_at) VALUES ('t_3', 'scheduled', '{\"reason\": \"⏳ esperando cupo de gemini_sem\"}', $TS_AYER);"
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_events (task_id, kind, payload, created_at) VALUES ('t_2', 'scheduled', '{\"reason\": \"Pausa nocturna\"}', $TS_HOY_TARDE);"
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_events (task_id, kind, payload, created_at) VALUES ('t_2', 'comment', '{\"body\": \"comentario\"}', $TS_HOY_TARDE);"
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_events (task_id, kind, payload, created_at) VALUES ('t_2', 'scheduled', NULL, $TS_HOY_TARDE);"
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_events (task_id, kind, payload, created_at) VALUES ('t_2', 'scheduled', '{\"reason\": null}', $TS_HOY_TARDE);"
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_events (task_id, kind, payload, created_at) VALUES ('t_2', 'scheduled', 'no es json valido', $TS_HOY_TARDE);"
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_events (task_id, kind, payload, created_at) VALUES ('t_2', 'scheduled', '{\"reason\": \"ts cero\"}', 0);"
sqlite3 "$tmp/boards/tablero1/kanban.db" "INSERT INTO task_events (task_id, kind, payload, created_at) VALUES ('t_2', 'scheduled', '\"texto json plano\"', $TS_HOY_TARDE);"

# Sembrar tablero2
# HOY tarde
sqlite3 "$tmp/boards/tablero2/kanban.db" "INSERT INTO task_runs (task_id, started_at, ended_at, outcome) VALUES ('t_10', $TS_HOY_TARDE - 60, $TS_HOY_TARDE, 'rate_limited');"
# AYER (dos rate_limited)
sqlite3 "$tmp/boards/tablero2/kanban.db" "INSERT INTO task_runs (task_id, started_at, ended_at, outcome) VALUES ('t_11', $TS_AYER - 60, $TS_AYER, 'rate_limited');"
sqlite3 "$tmp/boards/tablero2/kanban.db" "INSERT INTO task_runs (task_id, started_at, ended_at, outcome) VALUES ('t_12', $TS_AYER - 30, $TS_AYER, 'rate_limited');"
# Evento tablero2
sqlite3 "$tmp/boards/tablero2/kanban.db" "INSERT INTO task_events (task_id, kind, payload, created_at) VALUES ('t_10', 'scheduled', '{\"reason\": \"⏳ esperando cupo de kimi_7d\"}', $TS_HOY_TARDE);"

OUT="$tmp/out"
ERR="$tmp/err"

# --- Test 1: subcomando rate-limited --json exacto con tableros temporales y fechas a caballo de medianoche ---
$PYTHON "$FABRIK_CUPOS" rate-limited --json > "$OUT" 2> "$ERR"
RC=$?

if [ "$RC" -ne 0 ]; then
  fallo "AC-8 rate-limited --json retorno no cero ($RC)"
elif ! jq . "$OUT" >/dev/null 2>&1; then
  fallo "AC-8 rate-limited --json no emite JSON valido"
else
  t1_hoy=$(jq -r ".dias[\"$HOY\"].tablero1" "$OUT")
  t2_hoy=$(jq -r ".dias[\"$HOY\"].tablero2" "$OUT")
  t1_ayer=$(jq -r ".dias[\"$AYER\"].tablero1" "$OUT")
  t2_ayer=$(jq -r ".dias[\"$AYER\"].tablero2" "$OUT")
  esp1_hoy=$(jq -r ".esperas[\"$HOY\"].tablero1" "$OUT")
  esp2_hoy=$(jq -r ".esperas[\"$HOY\"].tablero2" "$OUT")
  esp1_ayer=$(jq -r ".esperas[\"$AYER\"].tablero1" "$OUT")
  esp2_ayer=$(jq -r ".esperas[\"$AYER\"].tablero2" "$OUT")
  viejo=$(jq -r ".dias[\"$VIEJO\"] // empty" "$OUT")

  if [ "$t1_hoy" != "2" ]; then
    fallo "AC-8 json t1 hoy esperado 2, obtenido $t1_hoy (¿medianoche con TZ?)"
  elif [ "$t2_hoy" != "1" ]; then
    fallo "AC-8 json t2 hoy esperado 1, obtenido $t2_hoy"
  elif [ "$t1_ayer" != "1" ]; then
    fallo "AC-8 json t1 ayer esperado 1, obtenido $t1_ayer"
  elif [ "$t2_ayer" != "2" ]; then
    fallo "AC-8 json t2 ayer esperado 2, obtenido $t2_ayer"
  elif [ "$esp1_hoy" != "1" ]; then
    fallo "AC-8 json esperas t1 hoy esperado 1, obtenido $esp1_hoy"
  elif [ "$esp2_hoy" != "1" ]; then
    fallo "AC-8 json esperas t2 hoy esperado 1, obtenido $esp2_hoy"
  elif [ "$esp1_ayer" != "1" ]; then
    fallo "AC-8 json esperas t1 ayer esperado 1, obtenido $esp1_ayer"
  elif [ "$esp2_ayer" != "0" ]; then
    fallo "AC-8 json esperas t2 ayer esperado 0, obtenido $esp2_ayer"
  elif [ -n "$viejo" ]; then
    fallo "AC-8 json fecha vieja de hace 10 dias no debia entrar en defecto 7 dias"
  else
    ok_
  fi
fi

# --- Test 2: tablero roto no tumba el informe y emite aviso a stderr ---
if ! grep -qi "tablero3" "$ERR"; then
  fallo "AC-8 stderr no contiene aviso sobre tablero3 roto"
else
  ok_
fi

# --- Test 3: --dias recorta y dias <= 0 acotado a 1 ---
$PYTHON "$FABRIK_CUPOS" rate-limited --dias 1 --json > "$OUT" 2> "$ERR"
if [ $? -ne 0 ]; then
  fallo "AC-8 --dias 1 retorno no cero"
else
  tiene_ayer=$(jq -r ".dias[\"$AYER\"] // empty" "$OUT")
  t1_hoy_recortado=$(jq -r ".dias[\"$HOY\"].tablero1" "$OUT")
  if [ -n "$tiene_ayer" ]; then
    fallo "AC-8 --dias 1 no recorto ayer"
  elif [ "$t1_hoy_recortado" != "2" ]; then
    fallo "AC-8 --dias 1 t1 hoy esperado 2, obtenido $t1_hoy_recortado"
  else
    # Probar --dias 0: acota a minimo 1 dia
    $PYTHON "$FABRIK_CUPOS" rate-limited --dias 0 --json > "$OUT" 2> "$ERR"
    t1_dias0=$(jq -r ".dias[\"$HOY\"].tablero1" "$OUT")
    if [ "$t1_dias0" != "2" ]; then
      fallo "AC-8 --dias 0 esperado minimo 1 dia (hoy 2), obtenido $t1_dias0"
    else
      ok_
    fi
  fi
fi

# --- Test 4: tabla formateada por stdout ---
$PYTHON "$FABRIK_CUPOS" rate-limited > "$OUT" 2> "$ERR"
if [ $? -ne 0 ]; then
  fallo "AC-8 rate-limited tabla retorno no cero"
elif ! grep -q "tablero1" "$OUT" || ! grep -q "tablero2" "$OUT"; then
  fallo "AC-8 tabla no muestra columnas de tableros con datos"
elif grep -q "tablero4" "$OUT"; then
  fallo "AC-8 tabla incluye tablero4 que no tiene datos"
elif ! grep -q "total" "$OUT"; then
  fallo "AC-8 tabla no incluye columna o fila total"
elif ! grep -qi "esperas.*cupo" "$OUT"; then
  fallo "AC-8 tabla no incluye columna o fila esperas por cupo"
else
  # Verificar fila total final
  fila_total=$(grep "^total" "$OUT")
  if [ -z "$fila_total" ]; then
    fallo "AC-8 tabla no contiene fila final total que empiece por total"
  else
    ok_
  fi
fi

# --- Test 5: resumen en fabrik-cupos (sin argumentos) ---
# Mock de entorno para que informe() no llame a registrar()
mkdir -p "$tmp/home/.hermes/factory/logs"
echo '{"t": 1700000000, "bolsas": {}, "tokens": {"kimi":[0,0,0],"gemini":[0,0,0],"argon":[0,0,0],"agy-claude":[0,0,0],"openai":[0,0,0],"claude":[0,0,0]}, "errores": {}}' > "$tmp/home/.hermes/factory/logs/cupos.jsonl"

HOME="$tmp/home" $PYTHON "$FABRIK_CUPOS" > "$OUT" 2> "$ERR"
if [ $? -ne 0 ]; then
  fallo "AC-8 fabrik-cupos (informe) retorno no cero"
elif ! grep -qF "rate_limited últimos 7 días:" "$OUT"; then
  fallo "AC-8 informe no contiene linea de resumen rate_limited ultimos 7 dias"
else
  linea_resumen=$(grep "rate_limited últimos 7 días:" "$OUT")
  # Esperado: 6 total ultimos 7 dias, hoy 3
  if ! printf '%s' "$linea_resumen" | grep -q "rate_limited últimos 7 días: 6 (hoy 3) · detalle: fabrik-cupos rate-limited"; then
    fallo "AC-8 linea resumen no coincide con esperado. Salida: $linea_resumen"
  else
    ok_
  fi
fi

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
