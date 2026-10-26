#!/usr/bin/env bash
# Test de integración de `fabrik-cupos semana` (IMPL-B costes-revision).
#
# AC-3   `semana --json` y la tabla salen por tablero con los campos fijos; valores EXACTOS calculados a mano:
#        2 tableros con actividad (+ uno sin actividad y uno ilegible), sesiones de 2 perfiles en 2 state.db
#        (una fuera de ventana, una sin tarjeta, una con tarjeta desconocida), tarjetas terminadas dentro y fuera,
#        changes_requested de 2 perfiles, rate_limited, un `gh` falso con PRs (mergeado en ventana, fuera de
#        ventana, sin mergear, uno que falla) y un registro de Greptile con ejecutado/cache/tope y una línea rota.
# AC-3b  `--sin-gh` no llama a gh (el falso deja huella si se llama); `--dias` cambia la ventana.
# AC-3c  `fabrik-cupos` sin argumentos sigue funcionando y lleva la línea de pista.
# AC-4   Fixtures con `tablero1`, `acme/app`: nada de nombres reales (lo comprueba tests/sin_privado_test.sh).
#
# Tiempo: las BD se rellenan con epochs relativos a «ahora»; los márgenes (≥ 60 s) hacen inofensivo el reloj real.
# Los valores exactos de los límites de la ventana están en tests/metrica_semanal_unit_test.py (reloj fijo).
# Uso: bash tests/metrica_semanal_test.sh   (HOME y todas las rutas temporales: nunca toca ~/.hermes real)
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CUPOS="$FABRIK_DIR/bin/fabrik-cupos"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
bien() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"
export FABRIK_KANBAN_BOARDS="$tmp/boards"
export FABRIK_STATE_DBS="$tmp/p1/state.db:$tmp/p2/state.db:$tmp/roto.db"
export FABRIK_GREPTILE_LOG="$tmp/greptile.jsonl"
export TZ="Europe/Madrid"
unset FABRIK_GH

NOW="$(date +%s)"
DIA=86400
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# ---------- tableros ----------
esquema_tablero() {
  sqlite3 "$1" <<'SQL'
CREATE TABLE tasks (id TEXT PRIMARY KEY, status TEXT NOT NULL, completed_at INTEGER, branch_name TEXT);
CREATE TABLE task_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, profile TEXT,
  started_at INTEGER NOT NULL, outcome TEXT, metadata TEXT);
SQL
}
run() { # <db> <tarjeta> <perfil> <hace_s> <outcome> [metadata]
  sqlite3 "$1" "INSERT INTO task_runs (task_id, profile, started_at, outcome, metadata) VALUES ('$2', '$3', $((NOW - $4)), '$5', $( [ $# -ge 6 ] && printf "'%s'" "$6" || echo NULL ))"
}
tarea() { # <db> <id> <status> <completed_hace_s|-> <rama>
  local c=NULL
  [ "$4" != "-" ] && c=$((NOW - $4))
  sqlite3 "$1" "INSERT INTO tasks VALUES ('$2', '$3', $c, '$5')"
}
pr() { printf '{"published_pr": "https://github.com/acme/%s/pull/%s"}' "$1" "$2"; }

T1="$tmp/boards/tablero1/kanban.db"
T2="$tmp/boards/tablero2/kanban.db"
T3="$tmp/boards/tablero3/kanban.db"
T4="$tmp/boards/tablero4/kanban.db"
mkdir -p "$tmp/boards/tablero1" "$tmp/boards/tablero2" "$tmp/boards/tablero3" "$tmp/boards/tablero4" "$tmp/boards/tablero5"
for d in "$T1" "$T2" "$T3" "$T4"; do esquema_tablero "$d"; done
printf 'esto no es sqlite' > "$tmp/boards/tablero5/kanban.db"

H=3600
# tablero1: a1 y a2 terminadas en ventana; a3 terminada fuera; a4 en curso
tarea "$T1" t_aaaaaaa1 done $((1 * DIA)) agente/uno
tarea "$T1" t_aaaaaaa2 done $((2 * DIA)) agente/dos
tarea "$T1" t_aaaaaaa3 done $((10 * DIA)) agente/tres
tarea "$T1" t_aaaaaaa4 running - agente/cuatro
run "$T1" t_aaaaaaa1 programador $((DIA + H)) completed "$(pr app 1)"         # 1
run "$T1" t_aaaaaaa1 tester $DIA changes_requested                            # 2
run "$T1" t_aaaaaaa1 programador $DIA review_requested                        # 3
run "$T1" t_aaaaaaa2 tester $DIA changes_requested                            # 4
run "$T1" t_aaaaaaa2 revisor $DIA changes_requested                           # 5
run "$T1" t_aaaaaaa2 programador $DIA review_requested                        # 6
run "$T1" t_aaaaaaa2 programador $DIA completed "$(pr app 2)"                 # 7
run "$T1" t_aaaaaaa4 programador $DIA rate_limited                            # 8
run "$T1" t_aaaaaaa1 programador $DIA rate_limited                            # 9
run "$T1" t_aaaaaaa4 programador $DIA completed 'no es json'                  # 10
run "$T1" t_aaaaaaa4 programador $DIA completed '{"otra": 1}'                 # 11
run "$T1" t_aaaaaaa4 programador $DIA completed "$(pr app 4)"                 # 12 (sin mergear)
run "$T1" t_aaaaaaa4 programador $DIA completed "$(pr app 5)"                 # 13 (gh falla)
run "$T1" t_aaaaaaa4 programador $DIA completed "$(pr app 1)"                 # 14 (PR 1 repetido: gh se llama una vez)
run "$T1" t_aaaaaaa3 programador $((10 * DIA)) completed "$(pr app 3)"        # fuera de la ventana; PR 3 mergeado fuera
run "$T1" t_aaaaaaa3 tester $((10 * DIA)) changes_requested                   # fuera
run "$T1" t_aaaaaaa3 programador $((10 * DIA)) rate_limited                   # fuera
# tablero2: b1 terminada, una ronda de review sin cambios, un PR mergeado de otro repo
tarea "$T2" t_bbbbbbb1 done $((3 * DIA)) agente/b1
run "$T2" t_bbbbbbb1 programador $((3 * DIA)) review_requested
run "$T2" t_bbbbbbb1 programador $((3 * DIA)) completed "$(pr web 7)"
# tablero3: solo una sesión (sin runs ni terminadas) → divisiones por cero
tarea "$T3" t_ccccccc1 running - agente/c1
# tablero4: solo actividad fuera de la ventana → no sale
tarea "$T4" t_dddddddd done $((40 * DIA)) agente/d
run "$T4" t_dddddddd programador $((40 * DIA)) completed

# ---------- sesiones ----------
esquema_state() {
  sqlite3 "$1" <<'SQL'
CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, started_at REAL, input_tokens INTEGER,
  cache_write_tokens INTEGER, cache_read_tokens INTEGER, output_tokens INTEGER);
CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT);
SQL
}
sesion() { # <db> <id> <source> <hace_s> <in> <cw> <cr> <out> <primer mensaje user>
  sqlite3 "$1" "INSERT INTO sessions VALUES ('$2', '$3', $((NOW - $4)), $5, $6, $7, $8);
    INSERT INTO messages (session_id, role, content) VALUES ('$2', 'system', 'kanban task t_ffffffff');
    INSERT INTO messages (session_id, role, content) VALUES ('$2', 'user', '$9');
    INSERT INTO messages (session_id, role, content) VALUES ('$2', 'user', 'kanban task t_ffffffff')"
}
mkdir -p "$tmp/p1" "$tmp/p2"
esquema_state "$tmp/p1/state.db"
esquema_state "$tmp/p2/state.db"
printf 'esto no es sqlite' > "$tmp/roto.db"
# Coste = in + cw + 0,1·cr + 5·out
# p1/s1 → tablero1: 1 000 000 + 2 000 000 + 0,1·10 000 000 + 5·100 000 = 4 500 000
sesion "$tmp/p1/state.db" s1 kanban $DIA 1000000 2000000 10000000 100000 '# Kanban task t_aaaaaaa1: x'
# p1/s9 → fuera de la ventana (8 días): no cuenta
sesion "$tmp/p1/state.db" s9 kanban $((8 * DIA)) 99000000 0 0 0 'kanban task t_aaaaaaa1'
# p1/s10 → no es de kanban: no cuenta
sesion "$tmp/p1/state.db" s10 cli $DIA 99000000 0 0 0 'kanban task t_aaaaaaa1'
# p2/s5 → tablero1: 1 000 000 + 500 000 + 0,1·5 000 000 + 5·100 000 = 2 500 000
sesion "$tmp/p2/state.db" s5 kanban $DIA 1000000 500000 5000000 100000 'work kanban task t_aaaaaaa2'
# p2/s2 → tablero2: 3 000 000 + 0 + 0 + 5·200 000 = 4 000 000 (cache en NULL)
sqlite3 "$tmp/p2/state.db" "INSERT INTO sessions VALUES ('s2', 'kanban', $((NOW - 2 * DIA)), 3000000, NULL, NULL, 200000);
  INSERT INTO messages (session_id, role, content) VALUES ('s2', 'user', 'kanban task t_bbbbbbb1')"
# p2/s7 → tablero3: 2 000 000
sesion "$tmp/p2/state.db" s7 kanban $DIA 2000000 0 0 0 'kanban task t_ccccccc1'
# p2/s6 → sin tarjeta; p2/s8 → tarjeta que ningún tablero conoce: sin_tablero = 150 000 + 50 000 = 200 000
sesion "$tmp/p2/state.db" s6 kanban $DIA 100000 0 0 10000 'hola, sin tarjeta'
sesion "$tmp/p2/state.db" s8 kanban $DIA 50000 0 0 0 'kanban task t_deadbeef'

# ---------- registro de Greptile ----------
g() { printf '{"t": 1, "repo": "%s", "rama": "%s", "sha": "x", "base": "y", "evento": "%s", "rc": 0}\n' "$1" "$2" "$3"; }
{
  g acme/app agente/uno ejecutado
  g acme/app agente/uno cache
  g acme/app agente/uno tope
  echo 'línea rota {'
  g acme/otro agente/uno ejecutado      # otro repo: no cuenta con gh; sí con --sin-gh (no filtra repo)
  g acme/app agente/dos ejecutado
  g acme/app agente/dos ejecutado
  g acme/app agente/tres ejecutado      # PR mergeado fuera de la ventana
  g acme/web agente/b1 ejecutado
  g acme/web agente/b1 sucio
} > "$FABRIK_GREPTILE_LOG"

# ---------- gh falso ----------
mkdir -p "$tmp/bin" "$tmp/ghdata"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
# Fake: deja huella de cada llamada y responde con $GHDATA/<tipo>_<owner>_<repo>_<n>.json (sin fichero → rc 1).
echo "$*" >> "$GHDATA/llamadas.log"
case "$1" in
  pr)  url="$3"; tipo=view ;;
  api) url="$2"; tipo=reviews ;;
  *) exit 2 ;;
esac
n="$(echo "$url" | sed -E 's#.*/acme/([^/]+)/pulls?/([0-9]+).*#\1_\2#')"
f="$GHDATA/${tipo}_${n}.json"
[ -f "$f" ] || exit 1
cat "$f"
GH
chmod +x "$tmp/bin/gh"
export GHDATA="$tmp/ghdata"
export FABRIK_GH="$tmp/bin/gh"
vista() { printf '{"additions": %s, "deletions": %s, "mergedAt": %s, "headRefName": "%s"}' "$1" "$2" "$3" "$4"; }
vista 100 20 "\"$(iso $((NOW - DIA)))\"" agente/uno > "$GHDATA/view_app_1.json"        # mergeado en ventana
vista 30 10 "\"$(iso $((NOW - 2 * DIA)))\"" agente/dos > "$GHDATA/view_app_2.json"      # mergeado en ventana
vista 7 7 "\"$(iso $((NOW - 10 * DIA)))\"" agente/tres > "$GHDATA/view_app_3.json"      # mergeado fuera de la ventana
vista 8 8 null agente/cuatro > "$GHDATA/view_app_4.json"                                # sin mergear
# app/5: sin fichero → gh falla
vista 5 5 "\"$(iso $((NOW - 3 * DIA)))\"" agente/b1 > "$GHDATA/view_web_7.json"
bot='{"user": {"login": "greptile-apps[bot]"}}'
otro='{"user": {"login": "una-persona"}}'
echo "[$bot, $otro, $bot]" > "$GHDATA/reviews_app_1.json"     # 2 de Greptile
echo "[$bot]" > "$GHDATA/reviews_app_2.json"                  # 1
echo "[$otro]" > "$GHDATA/reviews_web_7.json"                 # 0
echo "[$bot, $bot, $bot]" > "$GHDATA/reviews_app_3.json"      # no debe pedirse (fuera de ventana)

OUT="$tmp/out"
ERR="$tmp/err"

# ============ AC-3: JSON con gh ============
python3 "$CUPOS" semana --json > "$OUT" 2> "$ERR"
rc=$?
if [ "$rc" -ne 0 ]; then fallo "AC-3 semana --json salió $rc"; else bien; fi

python3 - "$OUT" <<'PY' || fail=$((fail + 1))
import json, sys
d = json.load(open(sys.argv[1]))
errores = []
def eq(nombre, real, esperado):
    if real != esperado:
        errores.append(f"{nombre}: {real!r} != {esperado!r}")
eq("claves", sorted(d), ["desde", "hasta", "sin_tablero", "tableros"])
eq("ventana", round((__import__("datetime").datetime.fromisoformat(d["hasta"]) - __import__("datetime").datetime.fromisoformat(d["desde"])).total_seconds()), 7 * 86400)
eq("tableros", sorted(d["tableros"]), ["tablero1", "tablero2", "tablero3"])
eq("sin_tablero", d["sin_tablero"], {"coste_eq": 200000.0})
# tablero1: coste 4,5 M + 2,5 M = 7 M; 2 terminadas → 3,5 M; runs en ventana: 14; rate_limited 2 → 14,3 %
# rondas: 3 changes_requested (tester×2, revisor×1) / 2 tarjetas con review_requested = 1,5
# PRs mergeados en ventana: app/1 (120 líneas) y app/2 (40) → 160 líneas; 7 M / 160 = 43 750
# Greptile local: app/uno 1 + app/dos 2 = 3; GitHub: 2 + 1 = 3; (3 + 3) / 2 = 3,0
eq("tablero1", d["tableros"]["tablero1"], {
    "terminadas": 2, "coste_eq": 7000000.0, "coste_por_tarjeta": 3500000.0,
    "runs": 14, "rate_limited": 2, "pct_rate_limited": 14.3,
    "rondas_por_tarjeta": 1.5, "rondas_por_perfil": {"revisor": 1, "tester": 2},
    "prs_mergeados": 2, "lineas_pr": 160, "coste_por_linea": 43750.0,
    "greptile_local": 3, "greptile_github": 3, "greptile_por_pr": 3.0})
# tablero2: 4 M / 1 terminada; 2 runs, 0 rate_limited; rondas 0/1 = 0,0; PR web/7 (10 líneas) → 400 000 por línea
# Greptile: local 1 (acme/web agente/b1 ejecutado; el «sucio» no cuenta), GitHub 0 → 1/1 = 1,0
eq("tablero2", d["tableros"]["tablero2"], {
    "terminadas": 1, "coste_eq": 4000000.0, "coste_por_tarjeta": 4000000.0,
    "runs": 2, "rate_limited": 0, "pct_rate_limited": 0.0,
    "rondas_por_tarjeta": 0.0, "rondas_por_perfil": {},
    "prs_mergeados": 1, "lineas_pr": 10, "coste_por_linea": 400000.0,
    "greptile_local": 1, "greptile_github": 0, "greptile_por_pr": 1.0})
# tablero3: solo una sesión de 2 M: toda división por cero → null
eq("tablero3", d["tableros"]["tablero3"], {
    "terminadas": 0, "coste_eq": 2000000.0, "coste_por_tarjeta": None,
    "runs": 0, "rate_limited": 0, "pct_rate_limited": None,
    "rondas_por_tarjeta": None, "rondas_por_perfil": {},
    "prs_mergeados": 0, "lineas_pr": 0, "coste_por_linea": None,
    "greptile_local": 0, "greptile_github": 0, "greptile_por_pr": None})
for e in errores:
    print("FALLO: AC-3 json:", e, file=sys.stderr)
sys.exit(1 if errores else 0)
PY
[ $? -eq 0 ] && bien

# Avisos: tablero5 ilegible, roto.db ilegible, PR app/5 que falla en gh. Nada más.
n_avisos="$(grep -c '^aviso:' "$ERR")"
if [ "$n_avisos" -eq 3 ] && grep -q 'tablero5' "$ERR" && grep -q 'roto.db' "$ERR" && grep -q 'pull/5.*salió con 1' "$ERR"; then bien
else fallo "AC-3 avisos esperados (tablero5, roto.db, PR 5): $(cat "$ERR")"; fi

# gh: PR 1 una sola vez aunque salga en dos runs; PR 3 (fuera de ventana) no pide reviews; los sin mergear tampoco
gh_pr_view="$(grep -c '^pr view ' "$GHDATA/llamadas.log")"
gh_api="$(grep -c '^api ' "$GHDATA/llamadas.log")"
if [ "$gh_pr_view" -eq 6 ] && [ "$gh_api" -eq 4 ] && [ "$(grep -c 'pull/1 ' "$GHDATA/llamadas.log")" -eq 1 ]; then bien
else fallo "AC-3 llamadas a gh: pr view=$gh_pr_view (esperadas 6: PR 1-5 y web/7) api=$gh_api (esperadas 4: PR 1, 2, 3 y web/7)"; fi

# ============ AC-3: tabla ============
: > "$GHDATA/llamadas.log"
python3 "$CUPOS" semana > "$OUT" 2> "$ERR"
rc=$?
if [ "$rc" -ne 0 ]; then fallo "AC-3 semana (tabla) salió $rc"; else bien; fi
fila() { grep "^$1" "$OUT" | tr -s ' '; }
if [ "$(fila tablero1)" = "tablero1 2 7.00 M 3.50 M 43.75 k 14 14.3 1.50 2 160 3 3 3.00" ]; then bien
else fallo "AC-3 fila tablero1: $(fila tablero1)"; fi
if [ "$(fila tablero2)" = "tablero2 1 4.00 M 4.00 M 400.00 k 2 0.0 0.00 1 10 1 0 1.00" ]; then bien
else fallo "AC-3 fila tablero2: $(fila tablero2)"; fi
if [ "$(fila tablero3)" = "tablero3 0 2.00 M — — 0 — — 0 0 0 0 —" ]; then bien
else fallo "AC-3 fila tablero3: $(fila tablero3)"; fi
if grep -q '^sin tablero: 0.20 M$' "$OUT"; then bien; else fallo "AC-3 línea sin tablero"; fi
if grep -q '^Ventana: ' "$OUT" && ! grep -q '^tablero4\|^tablero5' "$OUT"; then bien; else fallo "AC-3 tabla: ventana o tableros de más"; fi

# ============ AC-3b: --sin-gh ============
: > "$GHDATA/llamadas.log"
python3 "$CUPOS" semana --json --sin-gh > "$OUT" 2> "$ERR"
rc=$?
if [ "$rc" -ne 0 ]; then fallo "AC-3b --sin-gh salió $rc"; else bien; fi
if [ ! -s "$GHDATA/llamadas.log" ]; then bien; else fallo "AC-3b --sin-gh llamó a gh: $(cat "$GHDATA/llamadas.log")"; fi
python3 - "$OUT" <<'PY' || fail=$((fail + 1))
import json, sys
d = json.load(open(sys.argv[1]))["tableros"]
errores = []
nulos = ("prs_mergeados", "lineas_pr", "coste_por_linea", "greptile_github", "greptile_por_pr")
for nombre, local in (("tablero1", 5), ("tablero2", 1), ("tablero3", 0)):
    for k in nulos:
        if d[nombre][k] is not None:
            errores.append(f"{nombre}.{k} = {d[nombre][k]!r}, esperado null")
    if d[nombre]["greptile_local"] != local:
        errores.append(f"{nombre}.greptile_local = {d[nombre]['greptile_local']!r}, esperado {local}")
# Lo demás no cambia: tablero1 sigue con 7 M y 14,3 %
if d["tablero1"]["coste_eq"] != 7000000.0 or d["tablero1"]["pct_rate_limited"] != 14.3:
    errores.append("tablero1 cambia con --sin-gh")
for e in errores:
    print("FALLO: AC-3b", e, file=sys.stderr)
sys.exit(1 if errores else 0)
PY
[ $? -eq 0 ] && bien
# Sin PRs ni gh, ya no hay aviso de PR 5 (solo los dos de BD ilegibles)
if [ "$(grep -c '^aviso:' "$ERR")" -eq 2 ]; then bien; else fallo "AC-3b avisos con --sin-gh: $(cat "$ERR")"; fi

# ============ AC-3b: --dias cambia la ventana ============
# Sesión de tablero2 a 2 días − 90 s (dentro de 2 días) y otra a 2 días + 90 s (fuera); sus costes son 1 000 y 1 000 000
sesion "$tmp/p1/state.db" sd1 kanban $((2 * DIA - 90)) 1000 0 0 0 'kanban task t_bbbbbbb1'
sesion "$tmp/p1/state.db" sd2 kanban $((2 * DIA + 90)) 1000000 0 0 0 'kanban task t_bbbbbbb1'
export FABRIK_STATE_DBS="$tmp/p1/state.db"
coste_t2() { python3 "$CUPOS" semana --json --sin-gh "$@" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["tableros"].get("tablero2", {}).get("coste_eq", "ausente"))'; }
# --dias 1: las dos sesiones de tablero2 y su tarjeta (hace 3 días) quedan fuera → el tablero no sale
if [ "$(coste_t2 --dias 1)" = "ausente" ]; then bien; else fallo "AC-3b --dias 1: $(coste_t2 --dias 1)"; fi
if [ "$(coste_t2 --dias 2)" = "1000.0" ]; then bien; else fallo "AC-3b --dias 2 (límite dentro/fuera): $(coste_t2 --dias 2)"; fi
if [ "$(coste_t2 --dias 3)" = "1001000.0" ]; then bien; else fallo "AC-3b --dias 3: $(coste_t2 --dias 3)"; fi
if [ "$(coste_t2 --dias 0)" = "ausente" ]; then bien; else fallo "AC-3b --dias 0 debe valer 1: $(coste_t2 --dias 0)"; fi
if [ "$(coste_t2)" = "1001000.0" ]; then bien; else fallo "AC-3b por defecto 7 días: $(coste_t2)"; fi
export FABRIK_STATE_DBS="$tmp/p1/state.db:$tmp/p2/state.db:$tmp/roto.db"

# ============ AC-3c: el informe sin argumentos sigue funcionando y lleva la pista ============
mkdir -p "$HOME/.hermes/factory/logs"
echo '{"t": 1700000000, "bolsas": {}, "tokens": {"kimi":[0,0,0],"gemini":[0,0,0],"argon":[0,0,0],"agy-claude":[0,0,0],"openai":[0,0,0],"claude":[0,0,0]}, "errores": {}}' > "$HOME/.hermes/factory/logs/cupos.jsonl"
python3 "$CUPOS" > "$OUT" 2> "$ERR"
rc=$?
if [ "$rc" -ne 0 ]; then fallo "AC-3c fabrik-cupos sin argumentos salió $rc"; else bien; fi
if grep -qx 'métrica semanal: fabrik-cupos semana' "$OUT"; then bien; else fallo "AC-3c falta la línea de pista"; fi
if grep -q 'rate_limited últimos 7 días:' "$OUT"; then bien; else fallo "AC-3c el informe perdió la línea de rate_limited"; fi
python3 "$CUPOS" --help > "$OUT" 2>&1
if grep -q 'fabrik-cupos semana \[--dias N\] \[--json\] \[--sin-gh\]' "$OUT" || head -12 "$CUPOS" | grep -q 'semana \[--dias N\] \[--json\] \[--sin-gh\]'; then bien
else fallo "AC-3c la ayuda de cabecera no documenta semana"; fi

# ============ Entorno por defecto: sin variables, todo bajo HOME ============
unset FABRIK_KANBAN_BOARDS FABRIK_STATE_DBS FABRIK_GREPTILE_LOG FABRIK_GH
python3 "$CUPOS" semana --sin-gh > "$OUT" 2> "$ERR"
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^sin tablero: 0.00 M$' "$OUT"; then bien; else fallo "semana con HOME vacío: rc=$rc $(cat "$OUT")"; fi

echo "── final:"
echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
