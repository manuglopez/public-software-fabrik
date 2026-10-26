#!/usr/bin/env bash
# Tests de bin/fabrik-modelos (reparto dinámico de modelos, plan The Factory D-5).
#
# No regresión: con una foto de cupos de fixture, un historial de asignaciones, un tablero SQLite y `hermes` simulado,
# `estado`, `tick` y `asignar` deciden EXACTAMENTE lo mismo que el script antes de leer `modelos.reparto`
# (fotos en tests/fixtures/modelos/, sacadas con el script anterior). Después, lo nuevo: `modelos.reparto` de la config
# fusionada, `estado --json` e `informe --json`.
# HOME, FABRIK_CONFIG y `hermes` siempre falsos: nunca toca ~/.hermes ni la config real.
# Uso: bash tests/fabrik_modelos_test.sh        (ACTUALIZAR=1 rehace las fotos; solo si el cambio de conducta es querido)
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELOS="$FABRIK_DIR/bin/fabrik-modelos"
FOTOS="$FABRIK_DIR/tests/fixtures/modelos"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
H="$tmp/home"
mkdir -p "$tmp/bin" "$H"

# hermes simulado: apunta cada llamada y responde bien
cat > "$tmp/bin/hermes" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/hermes.log"
EOF
chmod +x "$tmp/bin/hermes"

# fabrik-cupos simulado (AC-5): apunta cada llamada y, salvo FAKE_CUPOS=falla, añade la foto de $tmp/nueva.json con t=ahora
cat > "$tmp/bin/cupos-falso" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/cupos.log"
[ "\${FAKE_CUPOS:-}" = falla ] && { echo "cupos roto" >&2; exit 1; }
python3 - "\$HOME" "$tmp/nueva.json" <<'PYF'
import json, sys, time
d = json.load(open(sys.argv[2]))
d["t"] = time.time()
open(f"{sys.argv[1]}/.hermes/factory/logs/cupos.jsonl", "a").write(json.dumps(d) + "\n")
PYF
EOF
chmod +x "$tmp/bin/cupos-falso"

# Mundo de fixture: cuentas de Claude a y b, foto de cupos, historial, perfiles y un tablero `demo`.
# Las fechas son relativas a ahora y los % lejos de los redondeos, para que la salida no dependa del reloj.
cat > "$tmp/mundo.py" <<'PY'
import json, os, sqlite3, sys, time
from datetime import datetime, timedelta, timezone
H = sys.argv[1]
ahora = time.time()
iso = lambda horas: (datetime.now(timezone.utc) + timedelta(hours=horas)).strftime("%Y-%m-%dT%H:%M:%SZ")
for c in ("a", "b"):
    os.makedirs(f"{H}/.config/fabrica/claude-{c}", exist_ok=True)
os.makedirs(f"{H}/.hermes/factory/logs", exist_ok=True)
bolsas = {
    "claude_5h@a": [40, iso(2)], "claude_sem@a": [93, iso(12)], "fable_sem@a": [10, iso(12)],
    "claude_5h@b": [20, iso(3)], "claude_sem@b": [30, iso(96)],
    "agy_claude_5h": [95, iso(1)], "agy_claude_sem": [10, iso(96)],
    "kimi_5h": [10, iso(3)], "kimi_7d": [50, iso(84)],
    "gemini_5h": [20, iso(4)], "gemini_sem": [80, iso(150)],
}
with open(f"{H}/.hermes/factory/logs/cupos.jsonl", "w") as f:
    f.write(json.dumps({"bolsas": {}}) + "\n" + json.dumps({"t": ahora, "bolsas": bolsas}) + "\n")
hist = [
    ("demo", "t_impl", "programador", "opus", 1), ("demo", "t_padre", "programador", "kimi", 2),
    ("otro", "t_x", "programador", "kimi", 3), ("otro", "t_viejo", "programador", "opus", 10),
    ("otro", "t_y", "tester", "sonnet", 1), ("demo", "t_hecha", "tester", "kimi", 2),
]
with open(f"{H}/.hermes/factory/logs/modelos.jsonl", "w") as f:
    for b, t, rol, ruta, dias in hist:
        f.write(json.dumps({"t": ahora - dias * 86400, "board": b, "task": t, "rol": rol, "ruta": ruta}) + "\n")
perfiles = {
    "programador": ("claude-subscription-directsdk-experimental", "claude-opus-5-5"),
    "tester": ("kimi-coding", "kimi-for-coding"),
    "revisor": ("claude-subscription-directsdk-experimental", "claude-opus-5-5"),
    "seguridad": ("antigravity-oauth", "claude-opus-5-5-high"),
    "orquestador": ("claude-subscription-directsdk-experimental", "claude-opus-5-5"),
    "explorador": ("antigravity-oauth", "gemini-3.8-flash-medium"),
    "docs": ("antigravity-oauth", "gemini-3.8-flash-high"),
}
for rol, (prov, mod) in perfiles.items():
    os.makedirs(f"{H}/.hermes/profiles/{rol}", exist_ok=True)
    extra = f"plugins:\n  entries:\n    x:\n      settings:\n        claude_config_dir: {H}/.config/fabrica/claude-b\n" if rol == "revisor" else ""
    fb = "fallback_providers:\n  - provider: kimi-coding\n    model: kimi-for-coding\n" if rol == "tester" else ""
    with open(f"{H}/.hermes/profiles/{rol}/config.yaml", "w") as f:
        f.write(f"model:\n  default: {mod}\n  provider: {prov}\n{fb}{extra}")
# perfil default con reservas fuera de la bolsa Claude: `tick` ejecuta el comprobador del canal de avisos (IMPL-3)
# y, sin este fichero, mandaría un `hermes send` que ensuciaría el registro de llamadas de las fotos
with open(f"{H}/.hermes/config.yaml", "w") as f:
    f.write("model:\n  default: claude-opus-5-5\n  provider: claude-subscription-directsdk-experimental\n"
            "fallback_providers:\n  - provider: antigravity-oauth\n    model: gemini-3.8-flash-high\n")
os.makedirs(f"{H}/.hermes/kanban/boards/demo", exist_ok=True)
c = sqlite3.connect(f"{H}/.hermes/kanban/boards/demo/kanban.db")
c.executescript("""
CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, assignee TEXT, status TEXT, model_override TEXT);
CREATE TABLE task_links (parent_id TEXT, child_id TEXT);
CREATE TABLE task_events (id INTEGER PRIMARY KEY, task_id TEXT, kind TEXT, created_at INTEGER);
""")
c.executemany("INSERT INTO tasks VALUES (?,?,?,?,?)", [
    ("t_prog", "IMPL nueva", "programador", "ready", None),
    ("t_impl", "IMPL que revisa el tester", "tester", "ready", ""),
    ("t_cierre", "CIERRE-LOCAL", "revisor", "ready", None),
    ("t_padre", "IMPL padre", "programador", "done", None),
    ("t_fijada", "con modelo", "programador", "ready", "claude-opus-5-5"),
    ("t_docs", "DOCS", "docs", "ready", None),
    ("t_manual", "algo [manual]", "programador", "ready", None),
    ("t_ajena", "rol ajeno", "otro", "ready", None),
    ("t_seg", "SEG", "seguridad", "todo", None),
    ("t_hecha", "TEST hecho", "tester", "done", None),
])
c.execute("INSERT INTO task_links VALUES ('t_padre', 't_cierre')")
c.executemany("INSERT INTO task_events (task_id, kind, created_at) VALUES (?,?,?)", [
    ("t_padre", "changes_requested", int(ahora - 86400)), ("t_padre", "crashed", int(ahora - 86400)),
    ("t_hecha", "completed", int(ahora - 86400)),
])
c.commit()
PY

# preparar <dir>: mundo nuevo en $H (y logs de hermes limpios)
preparar() {
  rm -rf "$H" "$tmp/hermes.log" "$tmp/cupos.log"
  mkdir -p "$H"
  python3 "$tmp/mundo.py" "$H"
  : > "$tmp/hermes.log"
}

# correr <nombre> <args…>: stdout+stderr de fabrik-modelos con el HOME falso, rutas de $H normalizadas a ~
correr() {
  local nombre="$1"
  shift
  env HOME="$H" PATH="$tmp/bin:$PATH" FABRIK_CONFIG="${CONFIG:-$tmp/sin-config.yaml}" FABRIK_CUPOS="${CUPOS_BIN:-$tmp/bin/cupos-falso}" \
    "$MODELOS" "$@" \
    > "$tmp/$nombre.out" 2> "$tmp/$nombre.err"
  RC=$?
  sed -i "s#$H#~#g" "$tmp/$nombre.out" "$tmp/$nombre.err" "$tmp/hermes.log"
}

# foto <nombre> <fichero>: compara con tests/fixtures/modelos/<nombre> (ACTUALIZAR=1 la reescribe)
foto() {
  if [ "${ACTUALIZAR:-}" = 1 ]; then
    mkdir -p "$FOTOS"
    cp "$2" "$FOTOS/$1"
  fi
  if diff -u "$FOTOS/$1" "$2" > "$tmp/diff"; then
    ok_
  else
    fallo "no regresión $1 difiere de la foto:
$(cat "$tmp/diff")"
  fi
}

# asignaciones nuevas del log, sin el instante (lo único que depende del reloj)
asignaciones() {
  tail -n +7 "$H/.hermes/factory/logs/modelos.jsonl" | sed -E 's/"t": [0-9.]+, //' | sed "s#$H#~#g"
}

# ---------- No regresión: sin modelos.reparto, mismas decisiones que antes ----------
preparar
correr estado estado
[ "$RC" -eq 0 ] && [ ! -s "$tmp/estado.err" ] || fallo "estado: rc=$RC err=$(cat "$tmp/estado.err")"
foto estado.txt "$tmp/estado.out"
correr sin_args
foto estado.txt "$tmp/sin_args.out"

preparar
correr tick tick
[ "$RC" -eq 0 ] && [ ! -s "$tmp/tick.err" ] || fallo "tick: rc=$RC err=$(cat "$tmp/tick.err")"
foto tick.txt "$tmp/tick.out"
foto tick.hermes.txt "$tmp/hermes.log"

preparar
correr asignar asignar demo
[ "$RC" -eq 0 ] && [ ! -s "$tmp/asignar.err" ] || fallo "asignar: rc=$RC err=$(cat "$tmp/asignar.err")"
foto asignar.txt "$tmp/asignar.out"
foto asignar.hermes.txt "$tmp/hermes.log"
asignaciones > "$tmp/asignar.log"
foto asignar.log.txt "$tmp/asignar.log"

# ---------- AC-4b: salida para el panel (estado --json, informe --json) ----------
# comprobar <caso> <fichero json>: aserciones en Python (stdlib) sobre la salida
cat > "$tmp/comprobar.py" <<'PY'
import json, sys
caso, datos = sys.argv[1], json.load(open(sys.argv[2]))
def eq(nombre, a, b):
    if a != b:
        print(f"{caso}: {nombre}: {a!r} != {b!r}")
        sys.exit(1)
if caso == "estado":
    rep = datos["reparto"]
    eq("ruta opus", rep["rutas"]["opus"], {"proveedor": "claude-subscription-directsdk-experimental",
       "modelo": "claude-opus-5-5", "familia": "anthropic", "cuenta_claude": True, "bolsas": ["claude_5h", "claude_sem"]})
    eq("ruta kimi sin cuenta", rep["rutas"]["kimi"]["cuenta_claude"], False)
    eq("roles", rep["roles"]["programador"], ["opus", "kimi", "agy-opus", "sonnet"])
    eq("último recurso", rep["ultimo_recurso"], "gemini-high")
    eq("topes", rep["topes"], {"5h": 92, "sem": 97, "7d": 97, "30d": 60})
    eq("topes_cuenta vacío en el motor", rep["topes_cuenta"], {})
    eq("roles de código", datos["roles_codigo"], ["programador", "tester"])
    filas = {(e["ruta"], e["cuenta"]): (e["ok"], e["motivo"]) for e in datos["estado"]}
    eq("opus@b", filas[("opus", "b")], (True, "claude_5h@b 20%; claude_sem@b 30% (ritmo ≤68%)"))
    eq("agy-opus", filas[("agy-opus", None)], (False, "agy_claude_5h 95% ≥ tope 92%"))
    eq("nº filas", len(datos["estado"]), 11)
    cu = {c["cuenta"]: c for c in datos["cuentas"]}
    eq("cuentas", sorted(cu), ["a", "b"])
    eq("cuenta a", (cu["a"]["sem_pct"], cu["a"]["tope"], bool(cu["a"]["renueva"])), (93, None, True))
    eq("perfil programador", datos["perfiles"][0], {"rol": "programador",
       "proveedor": "claude-subscription-directsdk-experimental", "modelo": "claude-opus-5-5"})
    eq("perfil explorador", [p for p in datos["perfiles"] if p["rol"] == "explorador"][0]["modelo"], "gemini-3.8-flash-medium")
    eq("brazos 7d", sorted((b["rol"], b["ruta"], b["n"]) for b in datos["brazos_7d"]),
       [("programador", "kimi", 2), ("programador", "opus", 1), ("tester", "kimi", 1), ("tester", "sonnet", 1)])
elif caso == "ac4e":
    cu = {c["cuenta"]: c for c in datos["cuentas"]}
    eq("a sem_pct", cu["a"]["sem_pct"], 30)
    eq("a horas_reset", round(cu["a"]["horas_reset"]), 120)
    eq("a margen_hora", round(cu["a"]["margen_hora"], 2), 0.56)
    eq("b horas_reset", round(cu["b"]["horas_reset"]), 1)
    eq("b margen_hora", round(cu["b"]["margen_hora"], 1), 47.0)
    eq("claves antiguas", sorted(k for k in cu["a"] if k not in ("horas_reset", "margen_hora")), ["cuenta", "renueva", "sem_pct", "tope"])
    eq("sin sospecha", "sospecha_lectura_ciega" in datos, False)
    for k in ("reparto", "roles_codigo", "estado", "cuentas", "brazos_7d", "perfiles"):
        eq("clave " + k, k in datos, True)
elif caso == "ac4e_sosp":
    eq("sospecha", datos["sospecha_lectura_ciega"], ["a", "b"])
    eq("estado intacto", len(datos["estado"]), 11)
elif caso == "informe":
    eq("días", datos["dias"], 30)
    eq("asignaciones", datos["asignaciones"], 6)
    filas = {(f["rol"], f["ruta"]): f for f in datos["filas"]}
    eq("programador kimi", filas[("programador", "kimi")], {"rol": "programador", "ruta": "kimi", "tarjetas": 1,
       "hechas": 1, "primera_pct": 0, "rondas_por_tarjeta": 1.0, "fallos": 1})
    eq("tester kimi", filas[("tester", "kimi")]["primera_pct"], 100)
    eq("programador opus sin hechas", filas[("programador", "opus")]["primera_pct"], None)
elif caso == "informe7":
    eq("días", datos["dias"], 7)
    eq("asignaciones", datos["asignaciones"], 5)
elif caso == "personal":
    rep = datos["reparto"]
    eq("roles del yaml", rep["roles"]["programador"], ["kimi", "nueva"])
    eq("rol no tocado", rep["roles"]["revisor"], ["opus", "agy-opus", "sonnet"])
    eq("ruta nueva", rep["rutas"]["nueva"]["familia"], "deepseek")
    eq("ruta vieja intacta", rep["rutas"]["opus"]["modelo"], "claude-opus-5-5")
    eq("topes fusionados", rep["topes"], {"5h": 80, "sem": 97, "7d": 97, "30d": 60})
    eq("topes_cuenta", rep["topes_cuenta"], {"a": 90})
    eq("tope cuenta a", {c["cuenta"]: c["tope"] for c in datos["cuentas"]}["a"], 90)
    filas = {(e["ruta"], e["cuenta"]): e["ok"] for e in datos["estado"]}
    eq("opus@a ya no admite trabajo", filas[("opus", "a")], False)
    eq("roles de código del yaml", datos["roles_codigo"], ["programador"])
print("ok")
PY
comprobar() { # <caso> <fichero>
  if out="$(python3 "$tmp/comprobar.py" "$1" "$2" 2>&1)"; then ok_; else fallo "$out ($(head -c 300 "$2"))"; fi
}

preparar
correr estado_json estado --json
[ "$RC" -eq 0 ] && [ ! -s "$tmp/estado_json.err" ] || fallo "estado --json: rc=$RC err=$(cat "$tmp/estado_json.err")"
comprobar estado "$tmp/estado_json.out"
correr informe_json informe 30 --json
comprobar informe "$tmp/informe_json.out"
correr informe7 informe --json 7
comprobar informe7 "$tmp/informe7.out"
correr informe_txt informe 30
grep -qF "Últimos 30 días · 6 asignaciones" "$tmp/informe_txt.out" && ok_ || fallo "informe en texto: $(cat "$tmp/informe_txt.out")"

# ---------- D-5: modelos.reparto de la config fusionada (lo que falta, valor por defecto) ----------
cat > "$tmp/personal.yaml" <<'EOF'
packs: []
modelos:
  reparto:
    rutas:
      nueva: {proveedor: deepseek, modelo: deepseek-v4-pro, familia: deepseek, cuenta_claude: false, bolsas: [ds_30d]}
    roles:
      programador: [kimi, nueva]
    topes: {"5h": 80}
    topes_cuenta: {a: 90}
  reglas:
    roles_codigo: [programador]
EOF
preparar
CONFIG="$tmp/personal.yaml" correr personal estado --json
[ "$RC" -eq 0 ] && [ ! -s "$tmp/personal.err" ] || fallo "estado con reparto: rc=$RC err=$(cat "$tmp/personal.err")"
comprobar personal "$tmp/personal.out"
CONFIG="$tmp/personal.yaml" correr tick_personal tick
grep -q "^programador  → kimi " "$tmp/tick_personal.out" && ok_ || fallo "tick con roles del yaml: $(cat "$tmp/tick_personal.out")"
grep -q "^tester       → opus@b " "$tmp/tick_personal.out" && ok_ || fallo "tick: rol no tocado cambió: $(cat "$tmp/tick_personal.out")"
# tester ya no es rol de código (reglas.roles_codigo: [programador]) → recibe el último recurso como reserva
grep -q "^-p tester config set fallback_providers .*gemini-3.8-flash-high" "$tmp/hermes.log" && ok_ \
  || fallo "roles_codigo del yaml no se aplica: $(cat "$tmp/hermes.log")"

# reparto con errores: no rompe el reparto de la fábrica; avisa y usa lo válido
cat > "$tmp/roto.yaml" <<'EOF'
packs: []
modelos:
  reparto:
    rutas:
      rota: {familia: x}
    roles:
      programador: [fantasma, kimi]
      tester: [fantasma]
    ultimo_recurso: fantasma
    topes: {"5h": "mucho"}
EOF
preparar
CONFIG="$tmp/roto.yaml" correr roto tick
[ "$RC" -eq 0 ] && grep -q "^programador  → kimi " "$tmp/roto.out" && grep -q "^tester       → opus@b " "$tmp/roto.out" \
  && ok_ || fallo "reparto roto: rc=$RC out=$(cat "$tmp/roto.out") err=$(cat "$tmp/roto.err")"
for aviso in "rota" "fantasma" "5h"; do
  grep -q "aviso:.*$aviso" "$tmp/roto.err" && ok_ || fallo "reparto roto: sin aviso de «$aviso»: $(cat "$tmp/roto.err")"
done

# config ilegible: avisa y decide igual que sin reparto
printf 'modelos: [\n' > "$tmp/ilegible.yaml"
preparar
CONFIG="$tmp/ilegible.yaml" correr ilegible estado
grep -q "aviso:" "$tmp/ilegible.err" && ok_ || fallo "config ilegible sin aviso: $(cat "$tmp/ilegible.err")"
foto estado.txt "$tmp/ilegible.out"

# ---------- AC-4 / AC-5: reparto por agotamiento relativo y foto fresca ----------
# poner_foto <edad_s> <json de bolsas>: sustituye la foto de cupos. Cada bolsa es [pct, horas_al_reset] (horas
# relativas a ahora: negativas = ya pasó) o [pct, "ISO"] para fijar un instante exacto. extra: JSON a fusionar en la foto
# (p. ej. {"errores": {...}}). `edad_s` null = foto sin campo `t` (formato viejo); "-" = sin foto.
cat > "$tmp/foto.py" <<'PY'
import json, sys, time
from datetime import datetime, timedelta, timezone
H, edad, bolsas = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
extra = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
ruta = f"{H}/.hermes/factory/logs/cupos.jsonl"
if edad == "-":
    open(ruta, "w").close()
    sys.exit(0)
iso = lambda h: h if isinstance(h, str) else (datetime.now(timezone.utc) + timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")
foto = {"bolsas": {k: [v[0], iso(v[1])] for k, v in bolsas.items()}, **extra}
if edad != "null":
    foto["t"] = time.time() - float(edad)
open(ruta, "w").write(json.dumps(foto) + "\n")
PY
poner_foto() { python3 "$tmp/foto.py" "$H" "$@"; }
# Bolsas de relleno para que solo cuente la semanal de Claude: el resto de rutas queda libre y no estorba.
LIBRES='"claude_5h@a": [10, 3], "claude_5h@b": [10, 3], "claude_5h@c": [10, 3]'
# ganadora <nombre-salida>: cuenta de Claude que `tick` elige para el programador (opus@<cuenta>)
ganadora() { sed -n 's/^programador  → opus@\([a-z]*\) .*/\1/p' "$tmp/$1.out"; }

# AC-4a: gana la de mayor margen por hora, no la de menor %. a 30 % renueva en 120 h; b 50 % renueva en 1 h → b.
preparar
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [30, 120], \"claude_sem@b\": [50, 1]}"
correr ac4a tick
[ "$(ganadora ac4a)" = b ] && ok_ || fallo "AC-4a: debería ganar b (margen/hora mayor, renueva en 1 h): $(cat "$tmp/ac4a.out")"
# …y con los números al revés gana a
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [50, 1], \"claude_sem@b\": [30, 120]}"
correr ac4a_rev tick
[ "$(ganadora ac4a_rev)" = a ] && ok_ || fallo "AC-4a: con los números al revés debería ganar a: $(cat "$tmp/ac4a_rev.out")"

# AC-4b: si topes_cuenta excluye a la ganadora, la siguiente por margen por hora (c 40 % en 10 h, no a 30 % en 120 h)
cat > "$tmp/tope_b.yaml" <<'EOF'
packs: []
modelos:
  reparto:
    topes_cuenta: {b: 40}
EOF
preparar
mkdir -p "$H/.config/fabrica/claude-c"
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [30, 120], \"claude_sem@b\": [50, 1], \"claude_sem@c\": [40, 10]}"
correr ac4b_sin tick
[ "$(ganadora ac4b_sin)" = b ] && ok_ || fallo "AC-4b: sin tope por cuenta debería ganar b: $(cat "$tmp/ac4b_sin.out")"
CONFIG="$tmp/tope_b.yaml" correr ac4b tick
[ "$(ganadora ac4b)" = c ] && ok_ || fallo "AC-4b: con tope b=40 debería ganar c (siguiente por margen/hora): $(cat "$tmp/ac4b.out")"

# AC-4c: empate dentro del 1 % del margen por hora → orden alfabético, estable entre ejecuciones (b es 0,3 % mejor, aun así a)
preparar
MISMO_RESET="$(date -u -d '+100 hours' +%Y-%m-%dT%H:%M:%SZ)"
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [30, \"$MISMO_RESET\"], \"claude_sem@b\": [29.8, \"$MISMO_RESET\"]}"
for i in 1 2 3; do
  correr ac4c tick
  [ "$(ganadora ac4c)" = a ] && ok_ || fallo "AC-4c: el empate debe ganarlo a (alfabético), ejecución $i: $(cat "$tmp/ac4c.out")"
done

# AC-4d: una cuenta con el tope efectivo superado no es apta aunque su margen por hora salga enorme
cat > "$tmp/tope_a.yaml" <<'EOF'
packs: []
modelos:
  reparto:
    topes_cuenta: {a: 50}
EOF
preparar
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [55, 1], \"claude_sem@b\": [20, 150]}"
correr ac4d_sin tick
[ "$(ganadora ac4d_sin)" = a ] && ok_ || fallo "AC-4d: sin tope por cuenta a (55 %, renueva en 1 h) tiene el mayor margen: $(cat "$tmp/ac4d_sin.out")"
CONFIG="$tmp/tope_a.yaml" correr ac4d tick
[ "$(ganadora ac4d)" = b ] && ok_ || fallo "AC-4d: a supera su tope efectivo, no es apta; debería ganar b: $(cat "$tmp/ac4d.out")"
CONFIG="$tmp/tope_a.yaml" correr ac4d_estado estado
grep -q "^opus@a .*⛔ .*claude_sem@a 55% ≥ tope 50%" "$tmp/ac4d_estado.out" && ok_ || fallo "AC-4d: opus@a debería salir ⛔ por tope 50 %: $(cat "$tmp/ac4d_estado.out")"

# AC-4e: estado en texto (línea por cuenta) y --json (campos nuevos; las claves de siempre intactas)
preparar
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [30, 120], \"claude_sem@b\": [50, 1]}"
correr ac4e estado
grep -qx "cuenta a: semanal 30 % · renueva en 120 h · margen/hora 0,56" "$tmp/ac4e.out" && ok_ \
  || fallo "AC-4e: falta la línea de la cuenta a: $(cat "$tmp/ac4e.out")"
grep -qE "^cuenta b: semanal 50 % · renueva en 1 h · margen/hora 47,0[0-9]$" "$tmp/ac4e.out" && ok_ \
  || fallo "AC-4e: falta la línea de la cuenta b: $(cat "$tmp/ac4e.out")"
grep -q "sospecha" "$tmp/ac4e.out" && fallo "AC-4e: sin errores.anthropic_sospecha no debe haber línea de sospecha" || ok_
# las líneas por cuenta van antes de las filas de rutas, y las filas siguen igual
[ "$(grep -n '^cuenta ' "$tmp/ac4e.out" | tail -1 | cut -d: -f1)" -lt "$(grep -n '^fable@a ' "$tmp/ac4e.out" | cut -d: -f1)" ] \
  && ok_ || fallo "AC-4e: las líneas por cuenta deben ir antes de las filas de rutas: $(cat "$tmp/ac4e.out")"
correr ac4e_json estado --json
SOSP='{"errores": {"anthropic_sospecha": "las cuentas a y b devuelven cifras idénticas (claude_5h, claude_sem)"}}'
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [30, 120], \"claude_sem@b\": [50, 1]}" "$SOSP"
correr ac4e_sosp estado
grep -qxF "⚠ sospecha de lectura ciega: a y b devuelven cifras idénticas" "$tmp/ac4e_sosp.out" && ok_ \
  || fallo "AC-4e: falta la línea de sospecha: $(cat "$tmp/ac4e_sosp.out")"
correr ac4e_sosp_json estado --json
comprobar ac4e "$tmp/ac4e_json.out"
comprobar ac4e_sosp "$tmp/ac4e_sosp_json.out"

# AC-5a: foto de más de 180 s → tick ejecuta `fabrik-cupos registrar` y decide con la foto nueva; con foto fresca, no
R3="$(date -u -d '+3 hours' +%Y-%m-%dT%H:%M:%SZ)"
R120="$(date -u -d '+120 hours' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$tmp/nueva.json" <<EOF
{"bolsas": {"claude_5h@a": [10, "$R3"], "claude_5h@b": [10, "$R3"],
            "claude_sem@a": [20, "$R120"], "claude_sem@b": [60, "$R120"]}}
EOF
VIEJA="{\"claude_5h@a\": [99, 3], \"claude_5h@b\": [99, 3], \"claude_sem@a\": [20, 120], \"claude_sem@b\": [60, 120]}"
preparar
poner_foto 400 "$VIEJA"
correr ac5a tick
[ "$(cat "$tmp/cupos.log" 2>/dev/null)" = registrar ] && ok_ || fallo "AC-5a: con foto de 400 s tick debe ejecutar «fabrik-cupos registrar»: $(cat "$tmp/cupos.log" 2>/dev/null)"
[ "$(ganadora ac5a)" = a ] && ok_ || fallo "AC-5a: debe decidir con la foto nueva (opus@a): $(cat "$tmp/ac5a.out")"
preparar
poner_foto 100 "$VIEJA"
correr ac5a_fresca tick
[ ! -e "$tmp/cupos.log" ] && ok_ || fallo "AC-5a: con foto de 100 s no debe refrescar: $(cat "$tmp/cupos.log")"
grep -q "^programador  → kimi " "$tmp/ac5a_fresca.out" && ok_ || fallo "AC-5a: con la foto fresca (opus agotado) debe decidir con ella: $(cat "$tmp/ac5a_fresca.out")"
# sin foto, o foto sin campo `t` (formato viejo): también refresca
preparar
poner_foto - "{}"
correr ac5a_sin tick
[ "$(cat "$tmp/cupos.log" 2>/dev/null)" = registrar ] && ok_ || fallo "AC-5a: sin foto tick debe refrescar"
preparar
poner_foto null "$VIEJA"
correr ac5a_sin_t tick
[ "$(cat "$tmp/cupos.log" 2>/dev/null)" = registrar ] && ok_ || fallo "AC-5a: foto sin t debe refrescar"
# el límite se cambia con FABRIK_FOTO_MAX_EDAD; `asignar` nunca refresca
preparar
poner_foto 100 "$VIEJA"
FABRIK_FOTO_MAX_EDAD=60 correr ac5a_env tick
[ "$(cat "$tmp/cupos.log" 2>/dev/null)" = registrar ] && ok_ || fallo "AC-5a: FABRIK_FOTO_MAX_EDAD=60 con foto de 100 s debe refrescar"
preparar
poner_foto 400 "$VIEJA"
correr ac5a_asignar asignar demo
[ ! -e "$tmp/cupos.log" ] && ok_ || fallo "AC-5a: asignar no debe refrescar la foto"

# AC-5b: si fabrik-cupos falla, tick sigue con la foto vieja y avisa por stderr
preparar
poner_foto 400 "$VIEJA"
FAKE_CUPOS=falla correr ac5b tick
[ "$RC" -eq 0 ] && grep -q "^programador  → kimi " "$tmp/ac5b.out" && ok_ || fallo "AC-5b: debe seguir con la foto vieja: rc=$RC $(cat "$tmp/ac5b.out")"
grep -q "^aviso: " "$tmp/ac5b.err" && ok_ || fallo "AC-5b: falta «aviso:» en stderr: $(cat "$tmp/ac5b.err")"

# AC-5c: bolsa al 100 % con reset en el pasado = renovada → apta
preparar
poner_foto 10 "{\"claude_5h@a\": [100, -1], \"claude_sem@a\": [100, -2], \"claude_5h@b\": [99, 3], \"claude_sem@b\": [99, 3]}"
correr ac5c tick
[ "$(ganadora ac5c)" = a ] && ok_ || fallo "AC-5c: a (100 % con reset pasado) debe contar como apta: $(cat "$tmp/ac5c.out")"
correr ac5c_estado estado
grep -q "^opus@a .*✅ claude_5h@a renovada (foto anterior al corte); claude_sem@a renovada (foto anterior al corte)" "$tmp/ac5c_estado.out" \
  && ok_ || fallo "AC-5c: motivo «renovada (foto anterior al corte)» ausente: $(cat "$tmp/ac5c_estado.out")"
# …y una bolsa al 100 % con el reset en el futuro sigue sin serlo
poner_foto 10 "{\"claude_5h@a\": [100, 2], \"claude_sem@a\": [100, 100], \"claude_5h@b\": [99, 3], \"claude_sem@b\": [99, 3]}"
correr ac5c_futuro estado
grep -q "^opus@a .*⛔" "$tmp/ac5c_futuro.out" && ok_ || fallo "AC-5c: 100 % con reset futuro no es apta: $(cat "$tmp/ac5c_futuro.out")"

# ---------- AC-4 / AC-5: casos de frontera ----------
# cuenta_de <estado --json> <cuenta> <campo>: valor de ese campo en cuentas[] (null se imprime None)
cuenta_de() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next(c for c in d["cuentas"] if c["cuenta"]==sys.argv[2])[sys.argv[3]])' "$@"; }
cat > "$tmp/tope_a40.yaml" <<'EOF'
packs: []
modelos:
  reparto:
    topes_cuenta: {a: 40}
EOF

# AC-4b: el margen por hora usa el tope efectivo de cada cuenta (topes_cuenta), no solo el general.
# a 30 % con tope 40 → 10/100 h = 0,10; b 35 % sin tope por cuenta → 62/100 h = 0,62 → b. Sin el tope por cuenta a saldría 0,67.
preparar
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [30, 100], \"claude_sem@b\": [35, 100]}"
correr ac4b_margen_sin tick
[ "$(ganadora ac4b_margen_sin)" = a ] && ok_ || fallo "AC-4b: sin tope por cuenta debería ganar a (0,67 > 0,62): $(cat "$tmp/ac4b_margen_sin.out")"
CONFIG="$tmp/tope_a40.yaml" correr ac4b_margen tick
[ "$(ganadora ac4b_margen)" = b ] && ok_ || fallo "AC-4b: con tope a=40 el margen/hora de a es 0,10 y debe ganar b: $(cat "$tmp/ac4b_margen.out")"
CONFIG="$tmp/tope_a40.yaml" correr ac4b_margen_json estado --json
[ "$(cuenta_de "$tmp/ac4b_margen_json.out" a margen_hora)" = 0.1 ] && ok_ || fallo "AC-4b: margen_hora de a con tope 40 debe ser 0.1: $(cat "$tmp/ac4b_margen_json.out")"

# AC-4a: cuenta renovada (reset pasado → cuenta 0 %) frente a otra con menos margen: gana la renovada
preparar
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [100, -3], \"claude_sem@b\": [20, 10]}"
correr ac4a_renovada tick
[ "$(ganadora ac4a_renovada)" = a ] && ok_ || fallo "AC-4a: a (renovada, 0 %) debe ganar a b (20 % en 10 h): $(cat "$tmp/ac4a_renovada.out")"
correr ac4a_renovada_estado estado
grep -qx "cuenta a: semanal 0 % · renueva en 0 h · margen/hora 194,00" "$tmp/ac4a_renovada_estado.out" && ok_ \
  || fallo "AC-4a: cuenta renovada: «semanal 0 % · renueva en 0 h · margen/hora 194,00» (suelo 0,5 h): $(cat "$tmp/ac4a_renovada_estado.out")"

# AC-4a: suelo de 0,5 h. a 50 % renueva en 0,1 h → 47/0,5 = 94; b 0 % en 0,3 h → 97/0,5 = 194 → b (sin suelo a saldría 470)
preparar
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [50, 0.1], \"claude_sem@b\": [0, 0.3]}"
correr ac4a_suelo tick
[ "$(ganadora ac4a_suelo)" = b ] && ok_ || fallo "AC-4a: con el suelo de 0,5 h debe ganar b (194 > 94): $(cat "$tmp/ac4a_suelo.out")"
correr ac4a_suelo_json estado --json
[ "$(cuenta_de "$tmp/ac4a_suelo_json.out" a margen_hora)" = 94.0 ] && ok_ || fallo "AC-4a: margen_hora de a con reset en 0,1 h debe ser 94.0: $(cat "$tmp/ac4a_suelo_json.out")"
[ "$(cuenta_de "$tmp/ac4a_suelo_json.out" a horas_reset)" = 0.1 ] && ok_ || fallo "AC-4a: horas_reset de a debe ser 0.1: $(cat "$tmp/ac4a_suelo_json.out")"

# AC-4a: reset ilegible → se trata como lejano (999 h): a 50 % pierde ante b 60 % con reset en 100 h
preparar
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [50, \"ilegible\"], \"claude_sem@b\": [60, 100]}"
correr ac4a_ilegible tick
[ "$(ganadora ac4a_ilegible)" = b ] && ok_ || fallo "AC-4a: con reset ilegible a vale 47/999 y debe ganar b (37/100): $(cat "$tmp/ac4a_ilegible.out")"
correr ac4a_ilegible_json estado --json
[ "$(cuenta_de "$tmp/ac4a_ilegible_json.out" a horas_reset)" = None ] && [ "$(cuenta_de "$tmp/ac4a_ilegible_json.out" a margen_hora)" = 0.05 ] \
  && ok_ || fallo "AC-4a: reset ilegible → horas_reset null y margen_hora 0.05: $(cat "$tmp/ac4a_ilegible_json.out")"

# AC-4c: fuera del 1 % no hay empate: b es ~3 % mejor (69/100 h frente a 67/100 h) y gana aunque a sea alfabéticamente primera
preparar
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [30, \"$MISMO_RESET\"], \"claude_sem@b\": [28, \"$MISMO_RESET\"]}"
correr ac4c_fuera tick
[ "$(ganadora ac4c_fuera)" = b ] && ok_ || fallo "AC-4c: una diferencia del 3 % no es empate, debe ganar b: $(cat "$tmp/ac4c_fuera.out")"

# AC-4c: todas las aptas con margen 0 (a en su tope exacto no es apta; con ambas en el tope no hay cuenta y tick no se rompe)
preparar
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [97, 100], \"claude_sem@b\": [97, 100]}"
correr ac4c_cero tick
[ "$RC" -eq 0 ] && [ -z "$(ganadora ac4c_cero)" ] && ok_ || fallo "AC-4c: con todas las cuentas en su tope no hay ganadora y rc=0: rc=$RC $(cat "$tmp/ac4c_cero.out" "$tmp/ac4c_cero.err")"
correr ac4c_cero_estado estado
grep -qx "cuenta a: semanal 97 % · renueva en 100 h · margen/hora 0,00" "$tmp/ac4c_cero_estado.out" && ok_ \
  || fallo "AC-4c: margen/hora 0,00 en el tope: $(cat "$tmp/ac4c_cero_estado.out")"

# AC-4e: cuenta sin dato de claude_sem en la foto: sin línea en texto y campos null en --json; tick no se rompe
preparar
mkdir -p "$H/.config/fabrica/claude-c"
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [30, 120], \"claude_sem@b\": [50, 1]}"
correr ac4e_sindato estado
grep -q "^cuenta c:" "$tmp/ac4e_sindato.out" && fallo "AC-4e: sin dato de c no debe haber línea «cuenta c»: $(cat "$tmp/ac4e_sindato.out")" || ok_
grep -q "^cuenta a: " "$tmp/ac4e_sindato.out" && grep -q "^opus@c .*sin dato claude_sem@c" "$tmp/ac4e_sindato.out" && ok_ \
  || fallo "AC-4e: a sigue con su línea y opus@c sale «sin dato»: $(cat "$tmp/ac4e_sindato.out")"
correr ac4e_sindato_json estado --json
[ "$(cuenta_de "$tmp/ac4e_sindato_json.out" c sem_pct)/$(cuenta_de "$tmp/ac4e_sindato_json.out" c horas_reset)/$(cuenta_de "$tmp/ac4e_sindato_json.out" c margen_hora)" = "None/None/None" ] \
  && ok_ || fallo "AC-4e: c sin dato → sem_pct/horas_reset/margen_hora null: $(cat "$tmp/ac4e_sindato_json.out")"
correr ac4e_sindato_tick tick
[ "$RC" -eq 0 ] && [ "$(ganadora ac4e_sindato_tick)" = b ] && ok_ || fallo "AC-4e: tick con una cuenta sin dato elige b: rc=$RC $(cat "$tmp/ac4e_sindato_tick.out" "$tmp/ac4e_sindato_tick.err")"

# AC-4e: horas_reset con un decimal y margen_hora con dos en --json
preparar
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [30, 12.5], \"claude_sem@b\": [50, 1]}"
correr ac4e_dec estado --json
[ "$(cuenta_de "$tmp/ac4e_dec.out" a horas_reset)" = 12.5 ] && [ "$(cuenta_de "$tmp/ac4e_dec.out" a margen_hora)" = 5.36 ] \
  && ok_ || fallo "AC-4e: horas_reset 12.5 y margen_hora 5.36 (redondeo a 1 y 2 decimales): $(cat "$tmp/ac4e_dec.out")"

# AC-4e: la sospecha nombra cuentas como palabras completas: con las cuentas a, ab y c, «ab y c» no incluye a a
preparar
mkdir -p "$H/.config/fabrica/claude-ab" "$H/.config/fabrica/claude-c"
SOSP2='{"errores": {"anthropic_sospecha": "las cuentas ab y c devuelven cifras idénticas (claude_sem)"}}'
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [30, 120], \"claude_sem@ab\": [40, 100], \"claude_sem@c\": [40, 100]}" "$SOSP2"
correr ac4e_palabra estado
grep -qxF "⚠ sospecha de lectura ciega: ab y c devuelven cifras idénticas" "$tmp/ac4e_palabra.out" && ok_ \
  || fallo "AC-4e: la sospecha debe nombrar «ab y c», sin a: $(cat "$tmp/ac4e_palabra.out")"
correr ac4e_palabra_json estado --json
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sospecha_lectura_ciega"])' "$tmp/ac4e_palabra_json.out")" = "['ab', 'c']" ] \
  && ok_ || fallo "AC-4e: sospecha_lectura_ciega debe ser [ab, c]: $(cat "$tmp/ac4e_palabra_json.out")"

# AC-5a: FABRIK_FOTO_MAX_EDAD no numérico → se usa 180 s: foto de 100 s no refresca, una de 400 s sí
preparar
poner_foto 100 "$VIEJA"
FABRIK_FOTO_MAX_EDAD=abc correr ac5a_env_malo tick
[ ! -e "$tmp/cupos.log" ] && ok_ || fallo "AC-5a: FABRIK_FOTO_MAX_EDAD=abc debe caer a 180 s y no refrescar una foto de 100 s"
preparar
poner_foto 400 "$VIEJA"
FABRIK_FOTO_MAX_EDAD=abc correr ac5a_env_malo2 tick
[ "$(cat "$tmp/cupos.log" 2>/dev/null)" = registrar ] && ok_ || fallo "AC-5a: FABRIK_FOTO_MAX_EDAD=abc y foto de 400 s debe refrescar"

# AC-5b: el motivo del fallo llega al aviso (stderr con texto; stdout si stderr vacío) y un binario inexistente no rompe tick
preparar
poner_foto 400 "$VIEJA"
FAKE_CUPOS=falla correr ac5b_msg tick
grep -q "^aviso: .*rc=1.*cupos roto" "$tmp/ac5b_msg.err" && ok_ || fallo "AC-5b: el aviso debe llevar rc y el stderr de fabrik-cupos: $(cat "$tmp/ac5b_msg.err")"
cat > "$tmp/bin/cupos-stdout" <<'EOF'
#!/usr/bin/env bash
echo "fallo por stdout"
exit 3
EOF
chmod +x "$tmp/bin/cupos-stdout"
preparar
poner_foto 400 "$VIEJA"
CUPOS_BIN="$tmp/bin/cupos-stdout" correr ac5b_stdout tick
grep -q "^aviso: .*rc=3.*fallo por stdout" "$tmp/ac5b_stdout.err" && [ "$RC" -eq 0 ] && ok_ || fallo "AC-5b: con stderr vacío el aviso usa stdout: rc=$RC $(cat "$tmp/ac5b_stdout.err")"
preparar
poner_foto 400 "$VIEJA"
CUPOS_BIN="$tmp/no-existe" correr ac5b_oserror tick
[ "$RC" -eq 0 ] && grep -q "^aviso: no se pudo ejecutar fabrik-cupos registrar" "$tmp/ac5b_oserror.err" && grep -q "^programador  → kimi " "$tmp/ac5b_oserror.out" \
  && ok_ || fallo "AC-5b: binario inexistente → aviso y se sigue con la foto vieja: rc=$RC $(cat "$tmp/ac5b_oserror.err" "$tmp/ac5b_oserror.out")"

# AC-4c: umbral de empate del 1 %. Mismo reset (100 h): margen/hora = (97 - pct)/100 h.
# a 30 % → 67; b a 29,53 % → 67,47: b es un 0,7 % mejor → empate, gana a (alfabética) aunque b sea algo mejor
preparar
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [30, \"$MISMO_RESET\"], \"claude_sem@b\": [29.53, \"$MISMO_RESET\"]}"
correr ac4c_07 tick
[ "$(ganadora ac4c_07)" = a ] && ok_ || fallo "AC-4c: una diferencia del 0,7 % es empate, debe ganar a (alfabética): $(cat "$tmp/ac4c_07.out")"
# b a 28,95 % → 68,05: b es un 1,5 % mejor → no hay empate, gana b aunque a sea alfabéticamente primera
preparar
poner_foto 10 "{$LIBRES, \"claude_sem@a\": [30, \"$MISMO_RESET\"], \"claude_sem@b\": [28.95, \"$MISMO_RESET\"]}"
correr ac4c_15 tick
[ "$(ganadora ac4c_15)" = b ] && ok_ || fallo "AC-4c: una diferencia del 1,5 % no es empate, debe ganar b: $(cat "$tmp/ac4c_15.out")"

# AC-5a: valor por defecto de 180 s (sin FABRIK_FOTO_MAX_EDAD y con valor no numérico): 175 s no refresca, 185 s sí
for env_edad in "" abc; do
  preparar
  poner_foto 175 "$VIEJA"
  FABRIK_FOTO_MAX_EDAD="$env_edad" correr ac5a_170 tick
  [ ! -e "$tmp/cupos.log" ] && ok_ || fallo "AC-5a: con FABRIK_FOTO_MAX_EDAD='$env_edad' una foto de 175 s no debe refrescar"
  preparar
  poner_foto 185 "$VIEJA"
  FABRIK_FOTO_MAX_EDAD="$env_edad" correr ac5a_190 tick
  [ "$(cat "$tmp/cupos.log" 2>/dev/null)" = registrar ] && ok_ || fallo "AC-5a: con FABRIK_FOTO_MAX_EDAD='$env_edad' una foto de 185 s debe refrescar"
done

# AC-5a: la última línea de cupos.jsonl es JSON válido pero no un objeto → se trata como sin foto: refresca y decide con la nueva
for basura in '[]' '"x"' '3'; do
  preparar
  poner_foto 10 "$VIEJA"
  printf '%s\n' "$basura" >> "$H/.hermes/factory/logs/cupos.jsonl"
  correr ac5a_basura tick
  [ "$RC" -eq 0 ] && [ "$(cat "$tmp/cupos.log" 2>/dev/null)" = registrar ] && [ "$(ganadora ac5a_basura)" = a ] && ok_ \
    || fallo "AC-5a: última línea '$basura' debe tratarse como sin foto (refresca y decide con la nueva): rc=$RC $(cat "$tmp/ac5a_basura.out" "$tmp/ac5a_basura.err")"
  correr ac5a_basura_estado estado
  [ "$RC" -eq 0 ] && ok_ || fallo "AC-5a: estado con última línea '$basura' no debe romper: rc=$RC $(cat "$tmp/ac5a_basura_estado.err")"
done

# AC-5a: foto sin clave `bolsas` o con `bolsas: null`, y sin foto con fabrik-cupos fallando → foto vacía, tick y estado no revientan
for cuerpo in '{"t": TIEMPO}' '{"t": TIEMPO, "bolsas": null}'; do
  preparar
  printf '%s\n' "${cuerpo/TIEMPO/$(date +%s)}" > "$H/.hermes/factory/logs/cupos.jsonl"
  correr ac5a_sinbolsas tick
  [ "$RC" -eq 0 ] && [ ! -e "$tmp/cupos.log" ] && ok_ || fallo "AC-5a: foto fresca $cuerpo: tick no debe romper ni refrescar: rc=$RC $(cat "$tmp/ac5a_sinbolsas.err")"
  correr ac5a_sinbolsas_estado estado
  [ "$RC" -eq 0 ] && ok_ || fallo "AC-5a: foto $cuerpo: estado no debe romper: rc=$RC $(cat "$tmp/ac5a_sinbolsas_estado.err")"
done
preparar
poner_foto - "{}"
FAKE_CUPOS=falla correr ac5a_nada tick
[ "$RC" -eq 0 ] && grep -q "^aviso: " "$tmp/ac5a_nada.err" && ok_ || fallo "AC-5a: sin foto y fabrik-cupos fallando: tick rc 0 con aviso: rc=$RC $(cat "$tmp/ac5a_nada.err")"
FAKE_CUPOS=falla correr ac5a_nada_estado estado
[ "$RC" -eq 0 ] && ok_ || fallo "AC-5a: sin foto: estado no debe romper: rc=$RC $(cat "$tmp/ac5a_nada_estado.err")"

# AC-5a: `t` booleano no es una hora: se trata como sin `t` y refresca
preparar
printf '%s\n' '{"t": true, "bolsas": {"claude_sem@a": [20, "2999-01-01T00:00:00Z"]}}' > "$H/.hermes/factory/logs/cupos.jsonl"
correr ac5a_tbool tick
[ "$(cat "$tmp/cupos.log" 2>/dev/null)" = registrar ] && ok_ || fallo "AC-5a: foto con t=true debe refrescar: $(cat "$tmp/cupos.log" 2>/dev/null)"

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
