#!/usr/bin/env bash
# Tests de la CLI `fabrik-modelos comprobar` y de los avisos de `fabrik-modelos tick`
# (cuotas-bolsas IMPL-3: AC-6, AC-7, AC-8 de la spec; AC-4, AC-5 y AC-6 de la tarjeta).
# HOME, FABRIK_CONFIG y `hermes` siempre falsos: nunca toca ~/.hermes ni envía nada real. Cuentas a/b (D-10).
# Uso: bash tests/canal_avisos_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELOS="$FABRIK_DIR/bin/fabrik-modelos"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
H="$tmp/home"
mkdir -p "$tmp/bin"

# hermes simulado: apunta cada llamada; sale con el código de $tmp/hermes.rc (0 si no existe)
cat > "$tmp/bin/hermes" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/hermes.log"
exit "\$(cat "$tmp/hermes.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$tmp/bin/hermes"

# Mundo: una cuenta de Claude (a), foto de cupos, perfiles de los siete roles en Claude opus.
# Fechas relativas a ahora y % lejos de los redondeos.
cat > "$tmp/mundo.py" <<'PY'
import json, os, sys, time
from datetime import datetime, timedelta, timezone
H, sem_a, horas_reset = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
iso = lambda horas: (datetime.now(timezone.utc) + timedelta(hours=horas)).strftime("%Y-%m-%dT%H:%M:%SZ")
os.makedirs(f"{H}/.config/fabrica/claude-a", exist_ok=True)
os.makedirs(f"{H}/.hermes/factory/logs", exist_ok=True)
bolsas = {
    "claude_5h@a": [40, iso(2)], "claude_sem@a": [sem_a, iso(horas_reset)],
    "agy_claude_5h": [20, iso(1)], "agy_claude_sem": [10, iso(96)],
    "kimi_5h": [10, iso(3)], "kimi_7d": [50, iso(84)],
    "gemini_5h": [20, iso(4)], "gemini_sem": [30, iso(150)],
}
with open(f"{H}/.hermes/factory/logs/cupos.jsonl", "w") as f:
    f.write(json.dumps({"t": time.time(), "bolsas": bolsas}) + "\n")   # foto fresca: `tick` no la refresca (AC-5)
for rol in ("programador", "tester", "revisor", "seguridad", "orquestador", "explorador", "docs"):
    os.makedirs(f"{H}/.hermes/profiles/{rol}", exist_ok=True)
    prov, mod = ("antigravity-oauth", "gemini-3.8-flash-medium") if rol in ("explorador", "docs") \
        else ("claude-subscription-directsdk-experimental", "claude-opus-5-5")
    with open(f"{H}/.hermes/profiles/{rol}/config.yaml", "w") as f:
        f.write(f"model:\n  default: {mod}\n  provider: {prov}\n")
PY

CONFIG_OK='model:
  default: claude-opus-5-5
  provider: claude-subscription-directsdk-experimental
fallback_providers:
  - provider: antigravity-oauth
    model: gemini-3.8-flash-high
'

# preparar [sem_a] [horas_reset]: mundo nuevo con config.yaml del default válida y sin jobs
preparar() {
  rm -rf "$H" "$tmp/hermes.log" "$tmp/hermes.rc"
  mkdir -p "$H"
  python3 "$tmp/mundo.py" "$H" "${1:-50}" "${2:-60}"
  printf '%s' "$CONFIG_OK" > "$H/.hermes/config.yaml"
  : > "$tmp/hermes.log"
}

# correr <nombre> <args…>: stdout+stderr de fabrik-modelos con el HOME falso
correr() {
  local nombre="$1"
  shift
  env HOME="$H" PATH="$tmp/bin:$PATH" FABRIK_HOY="${HOY:-2026-10-25}" FABRIK_CONFIG="${CONFIG:-$tmp/sin-config.yaml}" FABRIK_CUPOS=/bin/true \
    "$MODELOS" "$@" > "$tmp/$nombre.out" 2> "$tmp/$nombre.err"
  RC=$?
}

envios() { grep -c '^send ' "$tmp/hermes.log"; }
espera_envios() { # <n> <caso>
  [ "$(envios)" -eq "$1" ] && ok_ || fallo "$2: se esperaban $1 envíos y hay $(envios): $(cat "$tmp/hermes.log")"
}

cat > "$tmp/aviso90.yaml" <<'EOF'
packs: []
modelos:
  reparto:
    aviso_bolsa: 90
    topes_cuenta: {a: 90}
EOF

# ---------- AC-4: comprobar default ----------
preparar
correr c_ok comprobar
[ "$RC" -eq 0 ] && grep -q '^✅ default' "$tmp/c_ok.out" && ok_ || fallo "AC-4c ok: rc=$RC out=$(cat "$tmp/c_ok.out")"

printf 'model:\n  default: claude-opus-5-5\n  provider: claude-subscription-directsdk-experimental\n' > "$H/.hermes/config.yaml"
correr c_sin comprobar
[ "$RC" -eq 1 ] && grep -q '^⛔ default' "$tmp/c_sin.out" && ok_ || fallo "AC-4a sin fallback_providers: rc=$RC out=$(cat "$tmp/c_sin.out")"

printf 'model:\n  default: claude-opus-5-5\n  provider: claude-subscription-directsdk-experimental\nfallback_providers: []\n' > "$H/.hermes/config.yaml"
correr c_vacia comprobar
[ "$RC" -eq 1 ] && grep -q '^⛔ default' "$tmp/c_vacia.out" && ok_ || fallo "AC-4a lista vacía: rc=$RC out=$(cat "$tmp/c_vacia.out")"

printf 'model:\n  default: claude-opus-5-5\n  provider: claude-subscription-directsdk-experimental\nfallback_providers:\n  - provider: claude-subscription-directsdk-experimental\n    model: claude-sonnet-5-5\n' > "$H/.hermes/config.yaml"
correr c_misma comprobar
[ "$RC" -eq 1 ] && grep -q '^⛔ default.*claude_5h' "$tmp/c_misma.out" && ok_ || fallo "AC-4b misma bolsa: rc=$RC out=$(cat "$tmp/c_misma.out")"

printf '%s' "$CONFIG_OK" > "$H/.hermes/config.yaml"
printf 'fallback_providers:\n  - provider: antigravity-oauth\n    model: gemini-3.8-flash-high\n  - provider: nous\n    model: x\nmodel:\n  default: claude-opus-5-5\n  provider: claude-subscription-directsdk-experimental\n' > "$H/.hermes/config.yaml"
correr c_nous comprobar
[ "$RC" -eq 0 ] && ok_ || fallo "AC-4c antigravity y nous: rc=$RC out=$(cat "$tmp/c_nous.out")"

rm "$H/.hermes/config.yaml"
correr c_nocfg comprobar
[ "$RC" -eq 1 ] && grep -q '^⛔ default' "$tmp/c_nocfg.out" && ok_ || fallo "AC-4d sin config.yaml: rc=$RC out=$(cat "$tmp/c_nocfg.out")"

# ---------- AC-5: comprobar cron ----------
cron() { # <modelo|null> <proveedor|null> <deliver> <enabled>
  mkdir -p "$H/.hermes/cron"
  local m p
  [ "$1" = null ] && m=null || m="\"$1\""
  [ "$2" = null ] && p=null || p="\"$2\""
  printf '{"jobs":[{"name":"avisador","enabled":%s,"model":%s,"provider":%s,"deliver":"%s"}]}' "$4" "$m" "$p" "$3" \
    > "$H/.hermes/cron/jobs.json"
}
CL=claude-subscription-directsdk-experimental
preparar
cron claude-haiku-5-5 $CL "local,telegram:123" true
correr j_riesgo comprobar
[ "$RC" -eq 1 ] && grep -q '^⛔ cron.*avisador.*claude-haiku-5-5.*los jobs fijados no recorren reservas' "$tmp/j_riesgo.out" \
  && ok_ || fallo "AC-5a job en riesgo: rc=$RC out=$(cat "$tmp/j_riesgo.out")"
for caso in "gemini-3.8-flash-high antigravity-oauth local,telegram:123 true|fijado en antigravity" \
            "null null local,telegram:123 true|sin model" \
            "claude-haiku-5-5 $CL local true|deliver local" \
            "claude-haiku-5-5 $CL local,telegram:123 false|desactivado"; do
  cron ${caso%%|*}
  correr j_ok comprobar
  [ "$RC" -eq 0 ] && ! grep -q '⛔' "$tmp/j_ok.out" && ok_ || fallo "AC-5b ${caso#*|}: rc=$RC out=$(cat "$tmp/j_ok.out")"
done

preparar
correr j_json comprobar --json
python3 - "$tmp/j_json.out" <<'PY' && ok_ || fallo "AC-4/5 comprobar --json no es una lista de resultados: $(cat "$tmp/j_json.out")"
import json, sys
datos = json.load(open(sys.argv[1]))
assert isinstance(datos, list) and datos
assert all(sorted(d) == ["motivo", "nivel", "que"] for d in datos)
PY

# ---------- AC-6a/b: aviso al cruzar el umbral ----------
preparar 92 60
CONFIG="$tmp/aviso90.yaml" correr t1 tick
[ "$RC" -eq 0 ] && ok_ || fallo "AC-6a tick: rc=$RC err=$(cat "$tmp/t1.err")"
espera_envios 1 "AC-6a un solo envío"
linea="$(grep '^send ' "$tmp/hermes.log")"
case "$linea" in
  "send -t telegram "*) ok_ ;; *) fallo "AC-6a destino: $linea" ;;
esac
for trozo in "claude_sem@a" "92 %" "queda 8 %" "programador opus → kimi"; do
  case "$linea" in *"$trozo"*) ok_ ;; *) fallo "AC-6a falta «$trozo» en: $linea" ;; esac
done

CONFIG="$tmp/aviso90.yaml" correr t2 tick
espera_envios 1 "AC-6b mismo reset no reenvía"
# la foto trae un reset nuevo (+7 días) → avisa otra vez
python3 - "$H/.hermes/factory/logs/cupos.jsonl" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
f = json.loads(open(sys.argv[1]).readline())
f["bolsas"]["claude_sem@a"][1] = (datetime.now(timezone.utc) + timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
open(sys.argv[1], "w").write(json.dumps(f) + "\n")
PY
CONFIG="$tmp/aviso90.yaml" correr t3 tick
espera_envios 2 "AC-6b reset nuevo sí avisa"

# ---------- AC-6c: umbral por defecto y valor inválido ----------
preparar 97 60
correr d1 tick
espera_envios 0 "AC-6c sin clave el umbral es 98 (97 % no avisa)"
preparar 99 60
correr d2 tick
espera_envios 1 "AC-6c sin clave el umbral es 98 (99 % avisa)"

preparar 98 60
correr d1b tick
espera_envios 1 "AC-6c sin clave el umbral es 98 (98 % justo avisa)"

printf 'packs: []\nmodelos:\n  reparto:\n    aviso_bolsa: "x"\n' > "$tmp/invalido.yaml"
preparar 97 60
CONFIG="$tmp/invalido.yaml" correr d3 tick
grep -q 'aviso:.*aviso_bolsa' "$tmp/d3.err" && ok_ || fallo "AC-6c valor inválido sin aviso: $(cat "$tmp/d3.err")"
grep -q 'aviso:.*aviso_bolsa.*98' "$tmp/d3.err" && ok_ || fallo "AC-6c el aviso no dice que se queda en 98: $(cat "$tmp/d3.err")"
espera_envios 0 "AC-6c inválido → 98 (97 % no avisa)"
preparar 98 60
CONFIG="$tmp/invalido.yaml" correr d3b tick
espera_envios 1 "AC-6c inválido → 98 (98 % justo avisa)"
preparar 99 60
CONFIG="$tmp/invalido.yaml" correr d4 tick
espera_envios 1 "AC-6c inválido → 98 (99 % avisa)"

# ---------- AC-6d: envío fallido, no se marca y reintenta ----------
preparar 92 60
echo 1 > "$tmp/hermes.rc"
CONFIG="$tmp/aviso90.yaml" correr e1 tick
[ "$RC" -eq 0 ] && ok_ || fallo "AC-6d tick con envío fallido debe salir 0: rc=$RC err=$(cat "$tmp/e1.err")"
espera_envios 1 "AC-6d primer intento"
echo 0 > "$tmp/hermes.rc"
CONFIG="$tmp/aviso90.yaml" correr e2 tick
espera_envios 2 "AC-6d reintento en el siguiente tick"
CONFIG="$tmp/aviso90.yaml" correr e3 tick
espera_envios 2 "AC-6d tras enviar bien ya no repite"

# ---------- AC-6e: solo `hermes send`, nunca un modelo ----------
# cada llamada a hermes es `send -t <destino> <msg>` (avisos) o `-p <rol> config set …` (reparto de tick)
grep -vE '^(send -t [^ ]+ |-p [a-z]+ config set )' "$tmp/hermes.log" | grep -q . \
  && fallo "AC-6e: llamadas inesperadas a hermes: $(cat "$tmp/hermes.log")" || ok_
preparar 92 60
FABRIK_AVISO=otro CONFIG="$tmp/aviso90.yaml" correr e4 tick
grep -q '^send -t otro ' "$tmp/hermes.log" && ok_ || fallo "AC-6e FABRIK_AVISO: $(cat "$tmp/hermes.log")"

# ---------- AC-6f: comprobador en fallo → un aviso al día ----------
preparar
rm "$H/.hermes/config.yaml"
correr f1 tick
espera_envios 1 "AC-6f primer tick con fallo"
grep '^send ' "$tmp/hermes.log" | grep -q 'default' && ok_ || fallo "AC-6f el aviso no lista el fallo: $(cat "$tmp/hermes.log")"
correr f2 tick
espera_envios 1 "AC-6f mismo día no repite"
HOY=2026-10-26 correr f3 tick
espera_envios 2 "AC-6f al día siguiente avisa otra vez"
grep -q 'comprobar|2026-10-25' "$H/.hermes/factory/logs/modelos-avisos.json" && ok_ || fallo "AC-6f clave del día no está en el estado"

# ---------- AC-6: un fallo del propio canal de avisos no para el reparto ----------
preparar 92 60
mkdir -p "$H/.hermes/cron"
printf '{"jobs":["no-es-un-job"]}' > "$H/.hermes/cron/jobs.json"   # hace reventar al comprobador dentro de tick
CONFIG="$tmp/aviso90.yaml" correr g1 tick
[ "$RC" -eq 0 ] && grep -q '^aviso:.*canal de avisos' "$tmp/g1.err" && grep -q '^programador *→' "$tmp/g1.out" \
  && ok_ || fallo "AC-6 fallo del canal dentro de tick: rc=$RC err=$(cat "$tmp/g1.err") out=$(cat "$tmp/g1.out")"

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
