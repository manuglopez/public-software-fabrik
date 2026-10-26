#!/usr/bin/env bash
# Integración de cuotas-bolsas (CIERRE-LOCAL): lo que ninguna IMPL podía probar sola.
#
#   IMPL-1 (medición por cuenta, AC-1) → foto con una bolsa por cuenta, `claude_sem@a` y `claude_sem@b` con cifras
#                                        distintas (AC-1b: dos cuentas, nunca mezcladas ni agrupadas).
#   IMPL-2 (foto fresca, AC-5)         → `tick` refresca una foto vieja con `fabrik-cupos registrar` antes de decidir.
#   IMPL-3 (avisos, AC-6)              → y antes de avisar: el aviso nombra la bolsa de la cuenta que cruza el umbral
#                                        (con la foto fresca, no con la vieja) y los roles que la usaban.
#
# HOME, FABRIK_CONFIG, `hermes` y `fabrik-cupos` siempre falsos: nunca toca ~/.hermes, no mide cuentas ni envía nada.
# Cuentas a y b (D-10). Fechas relativas a ahora, % lejos de los redondeos.
# Uso: bash tests/cuotas_integracion_test.sh
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

# hermes simulado: apunta cada llamada (los avisos son `send -t <destino> <msg>`)
cat > "$tmp/bin/hermes" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/hermes.log"
EOF
chmod +x "$tmp/bin/hermes"

# fabrik-cupos simulado: apunta cada llamada y añade la foto de $tmp/nueva.json con t=ahora
cat > "$tmp/bin/cupos-falso" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/cupos.log"
python3 - "\$HOME" "$tmp/nueva.json" <<'PYF'
import json, sys, time
d = json.load(open(sys.argv[2]))
d["t"] = time.time()
open(f"{sys.argv[1]}/.hermes/factory/logs/cupos.jsonl", "a").write(json.dumps(d) + "\n")
PYF
EOF
chmod +x "$tmp/bin/cupos-falso"

iso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }
R3="$(iso '+3 hours')"
R48="$(iso '+48 hours')"

# Foto vieja (400 s): las dos cuentas con margen. Foto nueva (la que mide `fabrik-cupos registrar`): la cuenta b
# ha agotado su semanal; la a sigue igual. Son cifras distintas por cuenta, como las da `/usage` (AC-1b).
VIEJA="{\"claude_5h@a\": [10, \"$R3\"], \"claude_5h@b\": [10, \"$R3\"], \"claude_sem@a\": [20, \"$R48\"], \"claude_sem@b\": [60, \"$R48\"]}"
cat > "$tmp/nueva.json" <<EOF
{"bolsas": {"claude_5h@a": [10, "$R3"], "claude_5h@b": [12, "$R3"],
            "claude_sem@a": [20, "$R48"], "claude_sem@b": [99, "$R48"]}}
EOF

# preparar <edad_foto_s>: mundo nuevo, cinco perfiles en opus (explorador y docs en Antigravity) y default con reservas fuera de la bolsa Claude
preparar() {
  rm -rf "$H" "$tmp/hermes.log" "$tmp/cupos.log"
  mkdir -p "$H/.config/fabrica/claude-a" "$H/.config/fabrica/claude-b" "$H/.hermes/factory/logs"
  python3 - "$H" "$1" "$VIEJA" <<'PY'
import json, os, sys, time
H, edad, bolsas = sys.argv[1], float(sys.argv[2]), json.loads(sys.argv[3])
with open(f"{H}/.hermes/factory/logs/cupos.jsonl", "w") as f:
    f.write(json.dumps({"t": time.time() - edad, "bolsas": bolsas}) + "\n")
for rol in ("programador", "tester", "revisor", "seguridad", "orquestador", "explorador", "docs"):
    os.makedirs(f"{H}/.hermes/profiles/{rol}", exist_ok=True)
    prov, mod = ("antigravity-oauth", "gemini-3.8-flash-medium") if rol in ("explorador", "docs") \
        else ("claude-subscription-directsdk-experimental", "claude-opus-5-5")
    with open(f"{H}/.hermes/profiles/{rol}/config.yaml", "w") as f:
        f.write(f"model:\n  default: {mod}\n  provider: {prov}\n")
with open(f"{H}/.hermes/config.yaml", "w") as f:
    f.write("model:\n  default: claude-opus-5-5\n  provider: claude-subscription-directsdk-experimental\n"
            "fallback_providers:\n  - provider: antigravity-oauth\n    model: gemini-3.8-flash-high\n")
PY
}

# correr <nombre> <args…>
correr() {
  local nombre="$1"
  shift
  env HOME="$H" PATH="$tmp/bin:$PATH" FABRIK_HOY=2026-10-25 FABRIK_CONFIG="$tmp/sin-config.yaml" \
    FABRIK_CUPOS="$tmp/bin/cupos-falso" "$MODELOS" "$@" > "$tmp/$nombre.out" 2> "$tmp/$nombre.err"
  RC=$?
}

# ---------- AC-1b + AC-3 + AC-6 + AC-5: foto vieja → tick refresca → decide y avisa con la foto nueva ----------
preparar 400
correr vieja tick
[ "$RC" -eq 0 ] && ok_ || fallo "AC-5/AC-6 tick con foto vieja: rc=$RC err=$(cat "$tmp/vieja.err")"
[ "$(cat "$tmp/cupos.log" 2>/dev/null)" = registrar ] && ok_ \
  || fallo "AC-5 tick debe ejecutar «fabrik-cupos registrar» una vez antes de decidir: $(cat "$tmp/cupos.log" 2>/dev/null)"

# AC-5: decide con la foto nueva. Con la vieja (b al 60 %) no habría ningún aviso; con la nueva (b al 99 %) hay uno
# y la cuenta elegida para los roles de Claude es la a.
grep -c '^send ' "$tmp/hermes.log" | grep -qx 1 && ok_ \
  || fallo "AC-3/AC-6 debe haber un único aviso (el de la bolsa que cruza el umbral con la foto fresca): $(cat "$tmp/hermes.log" 2>/dev/null)"
grep -q "^programador .*→ opus@a " "$tmp/vieja.out" && ok_ \
  || fallo "AC-5 con la foto fresca (b agotada) el reparto debe elegir la cuenta a: $(cat "$tmp/vieja.out")"

linea="$(grep '^send ' "$tmp/hermes.log" 2>/dev/null)"
case "$linea" in
  "send -t telegram "*) ok_ ;;
  *) fallo "AC-6 destino del aviso: $linea" ;;
esac
# AC-1b / AC-6: nombra la bolsa de la cuenta b con su % y su queda, y los roles que usaban Claude
for trozo in "claude_sem@b" "99 %" "queda 1 %" "programador" "tester" "revisor" "seguridad" "orquestador"; do
  case "$linea" in *"$trozo"*) ok_ ;; *) fallo "AC-6 falta «$trozo» en el aviso: $linea" ;; esac
done
# AC-1b: la cuenta a (20 %) no entra en el aviso y nunca hay bolsas agrupadas
case "$linea" in *"claude_sem@a"*) fallo "AC-1b el aviso mezcla la cuenta a: $linea" ;; *) ok_ ;; esac
case "$linea" in *"@a+b"*|*"a+b"*) fallo "AC-1b no hay bolsas agrupadas: $linea" ;; *) ok_ ;; esac
# los roles que no usaban Claude (explorador y docs, en Antigravity) no se nombran
case "$linea" in *explorador*|*docs*) fallo "AC-6 solo los roles que usaban la bolsa: $linea" ;; *) ok_ ;; esac

# La foto nueva queda en el registro (la ha escrito `registrar`) con las dos cuentas por separado
python3 - "$H/.hermes/factory/logs/cupos.jsonl" <<'PY' && ok_ || fallo "AC-1b la foto registrada no trae las dos cuentas con cifras distintas"
import json, sys
f = [json.loads(l) for l in open(sys.argv[1])][-1]["bolsas"]
assert f["claude_sem@a"][0] != f["claude_sem@b"][0] and "claude_sem@a+b" not in f, f
PY

# ---------- AC-5/AC-6: con la foto ya fresca, ni refresca ni avisa de lo que la vieja no decía ----------
preparar 100
correr fresca tick
[ "$RC" -eq 0 ] && [ ! -e "$tmp/cupos.log" ] && ok_ || fallo "AC-5 foto de 100 s: no debe refrescar: rc=$RC $(cat "$tmp/cupos.log" 2>/dev/null)"
! grep -q '^send ' "$tmp/hermes.log" && ok_ || fallo "AC-6 con b al 60 % no hay aviso: $(grep '^send ' "$tmp/hermes.log")"

# ---------- AC-6b: un segundo tick con la misma bolsa y el mismo reset no repite el aviso ----------
preparar 400
correr rep1 tick
correr rep2 tick
grep -c '^send ' "$tmp/hermes.log" | grep -qx 1 && ok_ || fallo "AC-6b segundo tick no debe reenviar: $(cat "$tmp/hermes.log")"

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
