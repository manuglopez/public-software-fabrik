#!/usr/bin/env bash
# Tests de scripts/build_portfolio.py: guardas de org, copias con fecha y modo seco (portfolio-seguro).
# Criterios: AC-1 (guardas D-3a/b/c y --forzar), AC-2 (copias .bak fechadas, poda a 5),
#            AC-3 (--seco y --salida no tocan nada más), AC-5 (regla en profiles/_comun.md), D-1 (destino).
# Aislamiento: HOME temporal con FABRIK_CONFIG/FABRIK_DATA dentro y un `gh` falso en el PATH; nada de red,
# nada de ~/.hermes ni ~/.config reales. NUNCA ejecutes build_portfolio.py contra tu HOME real: fue el incidente.
# Uso: bash tests/portfolio_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }
# afirma "descripción" esperado real
afirma() { if [[ "$2" == "$3" ]]; then ok_; else fallo "$1 (esperado: '$2', real: '$3')"; fi; }
# contiene "descripción" texto aguja
contiene() { if [[ "$2" == *"$3"* ]]; then ok_; else fallo "$1 (no aparece '$3' en: $2)"; fi; }

# La caché de uv y los Python gestionados se resuelven ANTES de cambiar HOME (sin red en los escenarios).
export UV_CACHE_DIR="${UV_CACHE_DIR:-$(uv cache dir 2>/dev/null)}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$(uv python dir 2>/dev/null)}"
unset FABRIK_CONFIG FABRIK_DATA

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
REAL_HOME="$HOME"
export HOME="$tmp/home"
BIN="$tmp/bin"
mkdir -p "$HOME" "$BIN"
export FAKE_LOG="$tmp/fake.log"
export GH_FIXTURES="$tmp/gh"
mkdir -p "$GH_FIXTURES"

# gh falso: `repo list <owner>` → $GH_FIXTURES/<owner>.json (o []); lo demás falla. Registra cada llamada.
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  "repo list "*) f="$GH_FIXTURES/$3.json"; if [[ -f "$f" ]]; then cat "$f"; else echo '[]'; fi ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

reciente="$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)"
repo_json() { # nombre owner
  printf '{"name":"%s","nameWithOwner":"%s/%s","pushedAt":"%s","isArchived":false,"isFork":false,"primaryLanguage":{"name":"PHP"},"defaultBranchRef":{"name":"main"},"description":"d","url":"https://github.com/%s/%s","visibility":"PRIVATE"}' \
    "$1" "$2" "$1" "$reciente" "$2" "$1"
}
echo "[$(repo_json api acme-org),$(repo_json web acme-org)]" > "$GH_FIXTURES/acme-org.json"

# Configs personales con un pack vacío: `packs: []` (o sin clave) cae al pack de ejemplo, que aporta owners (las listas se suman).
mkdir -p "$tmp/pack-vacio"
printf 'nombre: vacio\n' > "$tmp/pack-vacio/pack.yaml"
printf 'packs: [%s]\nowners:\n  - acme-org\n' "$tmp/pack-vacio" > "$tmp/cfg-acme.yaml"
printf 'packs: [%s]\nowners:\n  - otra-org\n' "$tmp/pack-vacio" > "$tmp/cfg-otra.yaml"
printf 'packs: [%s]\nowners: []\n' "$tmp/pack-vacio" > "$tmp/cfg-vacia.yaml"

CFG="$tmp/cfg-acme.yaml"
DATA="$HOME/.hermes/factory"
PF="$DATA/portfolio.yaml"

# Con FAKE_NOW (ISO con zona, p. ej. 2026-03-05T23:30:00+00:00) el script corre bajo un reloj congelado, y con
# FAKE_FALLA_REPLACE=1 además `os.replace` falla (inyección de fallo para la limpieza del temporal).
# Solo se sustituyen el reloj y esa llamada; el script se importa y se ejecuta tal cual (main()).
cat > "$tmp/reloj.py" <<'PY'
import datetime, importlib.util, os, sys, types
ahora = datetime.datetime.fromisoformat(os.environ["FAKE_NOW"])
class Congelado(datetime.datetime):
    @classmethod
    def now(cls, tz=None):
        return ahora.astimezone(tz) if tz else ahora.astimezone().replace(tzinfo=None)
sys.path.insert(0, os.path.dirname(sys.argv[1]))  # como al ejecutar el script directamente
spec = importlib.util.spec_from_file_location("build_portfolio", sys.argv[1])
bp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bp)
bp.dt = types.SimpleNamespace(datetime=Congelado, timezone=datetime.timezone)
if os.environ.get("FAKE_FALLA_REPLACE"):
    def falla(*a, **k):
        raise OSError(28, "No space left on device (simulado)")
    bp.os.replace = falla
sys.argv = sys.argv[1:]
bp.main()
PY

# correr [args…] → RC, SALIDA, ERR. Siempre con HOME/FABRIK_CONFIG/FABRIK_DATA temporales.
correr() {
  : > "$FAKE_LOG"
  local script=("$FABRIK_DIR/scripts/build_portfolio.py")
  [[ -n "${FAKE_NOW-}" ]] && script=("$tmp/reloj.py" "${script[0]}")
  HOME="$HOME" FABRIK_CONFIG="$CFG" FABRIK_DATA="${DATA_ENV-$DATA}" \
    uv run --with pyyaml python "${script[@]}" "$@" > "$tmp/stdout" 2> "$tmp/stderr"
  RC=$?
  SALIDA="$(cat "$tmp/stdout")"
  ERR="$(cat "$tmp/stderr")"
}
huella() { find "$1" -printf '%p %s %T@\n' 2>/dev/null | sort; [[ -f "$1" ]] && sha256sum "$1"; }
huella_dir() { find "$1" -printf '%p %y %s %T@\n' 2>/dev/null | sort; find "$1" -type f -exec sha256sum {} + 2>/dev/null | sort; }
nuevo_caso() { rm -rf "$HOME/.hermes" "$tmp/otro"; mkdir -p "$DATA"; }
# Portfolio previo: org $1, un proyecto acme-org/api con campos editados a mano (ritmo, notas).
sembrar() {
  cat > "$PF" <<EOF
org: $1
extra_repos: []
projects:
- name: api
  full_name: acme-org/api
  owner: acme-org
  state: activo
  ritmo: lento
  notas: editado a mano
products:
  prod-x:
    repos: [api]
EOF
}
nbak() { find "$1" -maxdepth 1 -regextype posix-extended -regex ".*/$(basename "$2")\.[0-9]{8}-[0-9]{6}(-[0-9]+)?\.bak" | wc -l; }

# ---------- AC-1a: org distinta → código 3, no escribe, avisa, y no llama a gh ----------
nuevo_caso; sembrar acme; antes="$(huella_dir "$DATA")"
correr
afirma "AC-1a org distinta: código" 3 "$RC"
afirma "AC-1a org distinta: no toca nada" "$antes" "$(huella_dir "$DATA")"
contiene "AC-1a mensaje con la org actual" "$ERR" "es de la org «acme» y ahora se generaría «acme-org». No lo sobrescribo."
contiene "AC-1a mensaje sugiere --seco/--salida/--forzar" "$ERR" "usa --seco o --salida <ruta>; si de verdad quieres reemplazarlo, --forzar."
afirma "AC-1a no se llamó a gh (la guarda va antes)" 0 "$(grep -c '^gh' "$FAKE_LOG")"
afirma "AC-1a sin copias .bak" 0 "$(nbak "$DATA" portfolio.yaml)"

# AC-1a bis: la org nueva vacía también salta la guarda
nuevo_caso; sembrar acme-org; antes="$(huella_dir "$DATA")"
CFG="$tmp/cfg-vacia.yaml" correr
afirma "AC-1a org nueva vacía: código" 3 "$RC"
afirma "AC-1a org nueva vacía: no toca nada" "$antes" "$(huella_dir "$DATA")"
contiene "AC-1a org nueva vacía: mensaje" "$ERR" "ahora se generaría «»"

# AC-1a ter: destino sin org → no hay conflicto; misma org → se regenera
nuevo_caso; printf 'org: ""\nprojects: []\n' > "$PF"
correr
afirma "AC-1a destino con org vacía: se escribe" 0 "$RC"
nuevo_caso; sembrar acme-org
correr
afirma "AC-1a misma org: se regenera" 0 "$RC"
contiene "AC-1a misma org: contiene los repos de gh" "$(cat "$PF")" "acme-org/web"
afirma "AC-1a misma org: conserva ritmo editado" 1 "$(grep -c 'ritmo: lento' "$PF")"
afirma "AC-1a misma org: conserva products" 1 "$(grep -c 'prod-x' "$PF")"
afirma "AC-1a misma org: copia .bak fechada" 1 "$(nbak "$DATA" portfolio.yaml)"

# AC-1a con --forzar: escribe, con copia del anterior
nuevo_caso; sembrar acme
correr --forzar
afirma "AC-1a --forzar: código" 0 "$RC"
afirma "AC-1a --forzar: org nueva escrita" 1 "$(grep -c '^org: acme-org' "$PF")"
afirma "AC-1a --forzar: copia del anterior" 1 "$(grep -l '^org: acme$' "$DATA"/portfolio.yaml.*.bak | wc -l)"

# ---------- AC-1b: destino ilegible o que no es un mapa → código 3 ----------
for contenido in $'{ esto: [no cierra\n  - : :' $'- uno\n- dos' $'solo texto'; do
  nuevo_caso; printf '%s\n' "$contenido" > "$PF"; antes="$(huella_dir "$DATA")"
  correr
  afirma "AC-1b '${contenido:0:12}…': código" 3 "$RC"
  afirma "AC-1b '${contenido:0:12}…': no toca nada" "$antes" "$(huella_dir "$DATA")"
  contiene "AC-1b '${contenido:0:12}…': mensaje" "$ERR" "No lo sobrescribo"
  afirma "AC-1b '${contenido:0:12}…': no llamó a gh" 0 "$(grep -c '^gh' "$FAKE_LOG")"
done
nuevo_caso; printf -- '- uno\n- dos\n' > "$PF"
correr --forzar
afirma "AC-1b --forzar: código" 0 "$RC"
afirma "AC-1b --forzar: escribe un mapa" 1 "$(grep -c '^org: acme-org' "$PF")"
afirma "AC-1b --forzar: copia el ilegible" 1 "$(nbak "$DATA" portfolio.yaml)"
# fichero vacío: no hay nada que perder
nuevo_caso; : > "$PF"
correr
afirma "AC-1b fichero vacío: se escribe" 0 "$RC"
# binario (no UTF-8) y fichero sin permiso de lectura: también «no legible», sin traza de Python
nuevo_caso; printf '\xff\xfe\x00\x80' > "$PF"; antes="$(huella_dir "$DATA")"
correr
afirma "AC-1b binario: código 3" 3 "$RC"
afirma "AC-1b binario: no toca nada" "$antes" "$(huella_dir "$DATA")"
contiene "AC-1b binario: mensaje claro" "$ERR" "no es YAML legible"
afirma "AC-1b binario: sin traza de Python" 0 "$(grep -c Traceback <<< "$ERR")"
correr --forzar
afirma "AC-1b binario con --forzar: se escribe" 0 "$RC"
if [[ "$(id -u)" != 0 ]]; then
  nuevo_caso; sembrar acme-org; chmod 000 "$PF"; antes="$(huella_dir "$DATA")"
  correr
  afirma "AC-1b sin permiso de lectura: código 3" 3 "$RC"
  contiene "AC-1b sin permiso de lectura: mensaje claro" "$ERR" "no es YAML legible"
  afirma "AC-1b sin permiso de lectura: sin traza de Python" 0 "$(grep -c Traceback <<< "$ERR")"
  afirma "AC-1b sin permiso de lectura: no toca nada" "$antes" "$(huella_dir "$DATA")"
  chmod 644 "$PF"
fi

# ---------- AC-1c: 0 proyectos y el destino tenía alguno (gh sin sesión) → código 3 ----------
nuevo_caso; printf 'org: otra-org\nprojects:\n- {name: x, full_name: otra-org/x}\n' > "$PF"; antes="$(huella_dir "$DATA")"
CFG="$tmp/cfg-otra.yaml"
correr
afirma "AC-1c 0 proyectos: código" 3 "$RC"
afirma "AC-1c 0 proyectos: no toca nada" "$antes" "$(huella_dir "$DATA")"
contiene "AC-1c mensaje" "$ERR" "se generan 0 proyectos y"
contiene "AC-1c mensaje con el número exacto de proyectos del destino (1)" "$ERR" "tenía 1. No lo sobrescribo"
contiene "AC-1c se consultó gh antes de decidir" "$(cat "$FAKE_LOG")" "gh repo list otra-org"
correr --forzar
afirma "AC-1c --forzar: código" 0 "$RC"
contiene "AC-1c --forzar: vacía" "$(cat "$PF")" "projects: []"
afirma "AC-1c --forzar: copia" 1 "$(nbak "$DATA" portfolio.yaml)"
# el número del mensaje es el de proyectos del destino (3), no una constante
nuevo_caso; printf 'org: otra-org\nprojects:\n- {name: x, full_name: otra-org/x}\n- {name: y, full_name: otra-org/y}\n- {name: z, full_name: otra-org/z}\n' > "$PF"
CFG="$tmp/cfg-otra.yaml" correr
afirma "AC-1c con 3 proyectos: código" 3 "$RC"
contiene "AC-1c mensaje con el número exacto de proyectos del destino (3)" "$ERR" "tenía 3. No lo sobrescribo"
# 0 proyectos y el destino también vacío → normal
nuevo_caso; printf 'org: otra-org\nprojects: []\n' > "$PF"
CFG="$tmp/cfg-otra.yaml" correr
afirma "AC-1c destino sin proyectos: se escribe" 0 "$RC"
CFG="$tmp/cfg-acme.yaml"

# ---------- AC-1 en --seco: las tres guardas solo avisan (código 0) y no escriben ----------
nuevo_caso; sembrar acme; antes="$(huella_dir "$DATA")"
correr --seco
afirma "AC-1 --seco con org distinta: código 0" 0 "$RC"
contiene "AC-1 --seco con org distinta: avisa por stderr" "$ERR" "es de la org «acme»"
afirma "AC-1 --seco con org distinta: no escribe" "$antes" "$(huella_dir "$DATA")"
nuevo_caso; printf 'solo texto\n' > "$PF"; antes="$(huella_dir "$DATA")"
correr --seco
afirma "AC-1 --seco con destino ilegible: código 0" 0 "$RC"
contiene "AC-1 --seco con destino ilegible: avisa" "$ERR" "No lo sobrescribo"
afirma "AC-1 --seco con destino ilegible: no escribe" "$antes" "$(huella_dir "$DATA")"
nuevo_caso; printf 'org: otra-org\nprojects:\n- {name: x, full_name: otra-org/x}\n' > "$PF"; antes="$(huella_dir "$DATA")"
CFG="$tmp/cfg-otra.yaml" correr --seco
afirma "AC-1 --seco con 0 proyectos: código 0" 0 "$RC"
contiene "AC-1 --seco con 0 proyectos: avisa" "$ERR" "se generan 0 proyectos"
afirma "AC-1 --seco con 0 proyectos: no escribe" "$antes" "$(huella_dir "$DATA")"
CFG="$tmp/cfg-acme.yaml"

# ---------- AC-2: copia con fecha antes de sobrescribir; con 7 regeneraciones quedan 5 ----------
nuevo_caso; sembrar acme-org
echo "copia manual" > "$DATA/portfolio.yaml.bak"
echo "machacado" > "$DATA/portfolio.yaml.acme-machacado-20261024"
echo "ajeno" > "$DATA/otro.txt"
echo "no casa (sin segundos)" > "$DATA/portfolio.yaml.20200101-0000.bak"
echo "no casa (otro nombre)" > "$DATA/otro.yaml.20200101-000001.bak"
for n in 1 2 3; do echo "antigua $n" > "$DATA/portfolio.yaml.20200101-00000$n.bak"; done
ajenos="$(cd "$DATA" && sha256sum portfolio.yaml.bak portfolio.yaml.acme-machacado-20261024 otro.txt portfolio.yaml.20200101-0000.bak otro.yaml.20200101-000001.bak)"
for _ in 1 2 3 4 5 6 7; do correr; [[ "$RC" == 0 ]] || break; done
afirma "AC-2 7 regeneraciones: código" 0 "$RC"
afirma "AC-2 quedan exactamente 5 .<fecha>.bak" 5 "$(nbak "$DATA" portfolio.yaml)"
afirma "AC-2 las antiguas de 2020 se podaron" 0 "$(ls "$DATA" | grep -c '^portfolio.yaml.20200101-00000[123].bak$')"
afirma "AC-2 ajenos intactos (portfolio.yaml.bak, machacado, otros)" "$ajenos" \
  "$(cd "$DATA" && sha256sum portfolio.yaml.bak portfolio.yaml.acme-machacado-20261024 otro.txt portfolio.yaml.20200101-0000.bak otro.yaml.20200101-000001.bak)"
afirma "AC-2 sin temporales sueltos" 0 "$(ls -A "$DATA" | grep -c '\.tmp$')"
# La primera copia (el sembrado) ya se podó; la última es el portfolio generado en la pasada 6 (lleva cabecera).
ultima="$(ls "$DATA"/portfolio.yaml.2*.bak | sort | tail -1)"
contiene "AC-2 la última copia es de la pasada anterior" "$(head -1 "$ultima")" "Catálogo de proyectos"

# AC-2: el nombre de copia no se pisa si hay otra del mismo segundo (-2, -3…)
nuevo_caso; sembrar acme-org
sello="$(date +%Y%m%d-%H%M%S)"
for s in "$sello" "$(date -d '1 second ago' +%Y%m%d-%H%M%S)" "$(date -d '1 second' +%Y%m%d-%H%M%S)"; do echo previa > "$DATA/portfolio.yaml.$s.bak"; done
correr
afirma "AC-2 copias previas del mismo segundo no se machacan (4 en total)" 4 "$(nbak "$DATA" portfolio.yaml)"
afirma "AC-2 las previas conservan su contenido" 3 "$(grep -l '^previa$' "$DATA"/portfolio.yaml.*.bak | wc -l)"

# AC-2 con reloj congelado (TZ fija, sin carreras de segundo): nombres exactos, hora local, orden de poda
SELLO_UTC=20260305-233000
export FAKE_NOW=2026-03-05T23:30:00+00:00
export TZ=UTC
bakls() { (cd "$DATA" && ls portfolio.yaml.*.bak | tr '\n' ' ' | sed 's/ $//'); }
nuevo_caso; sembrar acme-org; echo previa > "$DATA/portfolio.yaml.$SELLO_UTC.bak"
correr
afirma "AC-2 colisión del mismo segundo: la primera copia nueva es -2" \
  "portfolio.yaml.$SELLO_UTC-2.bak portfolio.yaml.$SELLO_UTC.bak" "$(bakls)"
correr; correr
afirma "AC-2 colisiones sucesivas: -2, -3, -4 sin saltos ni pisadas" \
  "portfolio.yaml.$SELLO_UTC-2.bak portfolio.yaml.$SELLO_UTC-3.bak portfolio.yaml.$SELLO_UTC-4.bak portfolio.yaml.$SELLO_UTC.bak" "$(bakls)"
afirma "AC-2 la copia original del segundo no se pisa" "previa" "$(cat "$DATA/portfolio.yaml.$SELLO_UTC.bak")"
contiene "AC-2 -2 es copia del destino sembrado" "$(cat "$DATA/portfolio.yaml.$SELLO_UTC-2.bak")" "notas: editado a mano"
contiene "AC-2 -3 es copia del portfolio generado en la pasada anterior" "$(head -1 "$DATA/portfolio.yaml.$SELLO_UTC-3.bak")" "Generado 2026-03-05 23:30 UTC"

# orden de poda con -N: por sello y luego numérico (-10 es más reciente que -9, que -2); quedan las 5 más recientes
nuevo_caso; sembrar acme-org
echo vieja > "$DATA/portfolio.yaml.20260305-232959.bak"
for suf in "" -2 -3 -4 -5 -9 -10; do echo "previa$suf" > "$DATA/portfolio.yaml.$SELLO_UTC$suf.bak"; done
correr
afirma "AC-2 poda: código" 0 "$RC"
afirma "AC-2 poda por sello y por número (no por texto): quedan -4 -5 -6(nueva) -9 -10" \
  "portfolio.yaml.$SELLO_UTC-10.bak portfolio.yaml.$SELLO_UTC-4.bak portfolio.yaml.$SELLO_UTC-5.bak portfolio.yaml.$SELLO_UTC-6.bak portfolio.yaml.$SELLO_UTC-9.bak" "$(bakls)"

# poda: solo casan EXACTAMENTE con el patrón; nada más se borra, aunque sea lo más viejo (casi-coincidencias y un directorio)
nuevo_caso; sembrar acme-org
mkdir "$DATA/portfolio.yaml.20200101-000002.bak"; echo dentro > "$DATA/portfolio.yaml.20200101-000002.bak/f"
echo 1 > "$DATA/x.portfolio.yaml.20200101-000001.bak"
echo 2 > "$DATA/portfolio.yaml.20200101-000001.bak.old"
echo 3 > "$DATA/portfolio.yaml.20200101-000001.bak~"
echo 4 > "$DATA/portfolio.yaml.20200101-000001.bak2"
echo 5 > "$DATA/portfolioXyaml.20200101-000001.bak"
for n in 3 4 5 6 7 8; do echo "real $n" > "$DATA/portfolio.yaml.20200101-00000$n.bak"; done
correr
afirma "AC-2 poda con directorio y casi-coincidencias: código 0 (sin traza)" 0 "$RC"
afirma "AC-2 poda: el directorio que casa con el patrón sigue ahí con su contenido" "dentro" "$(cat "$DATA/portfolio.yaml.20200101-000002.bak/f" 2>/dev/null)"
for f in x.portfolio.yaml.20200101-000001.bak portfolio.yaml.20200101-000001.bak.old portfolio.yaml.20200101-000001.bak~ \
         portfolio.yaml.20200101-000001.bak2 portfolioXyaml.20200101-000001.bak; do
  afirma "AC-2 poda: no borra $f" 1 "$([[ -f "$DATA/$f" ]] && echo 1 || echo 0)"
done
afirma "AC-2 poda: de los ficheros reales quedan exactamente 5" 5 \
  "$(find "$DATA" -maxdepth 1 -type f -regextype posix-extended -regex '.*/portfolio\.yaml\.[0-9]{8}-[0-9]{6}(-[0-9]+)?\.bak' | wc -l)"
afirma "AC-2 poda: se borran los reales más viejos (3 y 4) y quedan 5, 6, 7, 8 y la nueva" "5 6 7 8" \
  "$(cd "$DATA" && ls | grep '^portfolio.yaml.20200101-00000[0-9].bak$' | sed 's/.*00000\(.\)\.bak/\1/' | grep -v '^[12]$' | tr '\n' ' ' | sed 's/ $//')"

# D-4 hora LOCAL (no UTC): con TZ=UTC+5 el sello del 05-03 23:30 UTC es el del 06-03 04:30
export TZ=LOC-5
nuevo_caso; sembrar acme-org
correr
afirma "AC-2 el sello de la copia es la hora local (UTC+5), no UTC" "portfolio.yaml.20260306-043000.bak" "$(bakls)"
contiene "AC-2 la cabecera sigue en UTC" "$(head -1 "$PF")" "Generado 2026-03-05 23:30 UTC"
export TZ=UTC

# escritura atómica: si falla el reemplazo no queda temporal suelto y el destino anterior sigue intacto
nuevo_caso; sembrar acme-org; antes_pf="$(sha256sum "$PF")"
FAKE_FALLA_REPLACE=1 correr
afirma "AC-2 fallo al reemplazar: el script falla" 1 "$RC"
contiene "AC-2 fallo al reemplazar: informa del error" "$ERR" "No space left on device"
afirma "AC-2 fallo al reemplazar: sin temporales sueltos" 0 "$(ls -A "$DATA" | grep -c '\.tmp$')"
afirma "AC-2 fallo al reemplazar: el destino anterior está intacto" "$antes_pf" "$(sha256sum "$PF")"
unset FAKE_NOW TZ

# permisos del destino: nuevo → 644 (aunque el umask sea 077); existente → conserva los suyos
nuevo_caso; rm -rf "$DATA"
(umask 077; correr)
afirma "AC-2 destino nuevo: modo 644" 644 "$(stat -c %a "$PF")"
chmod 640 "$PF"; correr
afirma "AC-2 destino existente: conserva su modo (640)" 640 "$(stat -c %a "$PF")"
# el directorio del destino se crea si no existe (primera ejecución)
nuevo_caso; DATA_ENV="$tmp/nuevo/sub/datos" correr
afirma "AC-2 primera ejecución: crea el directorio de FABRIK_DATA" 1 "$(grep -c '^org: acme-org' "$tmp/nuevo/sub/datos/portfolio.yaml")"
correr --salida "$tmp/otro/nuevo/dir/x.yaml"
afirma "AC-3 --salida: crea el directorio de RUTA" 1 "$(grep -c '^org: acme-org' "$tmp/otro/nuevo/dir/x.yaml")"

# state: solo se conserva si state_confirmed es true; si no, se regenera
nuevo_caso
cat > "$PF" <<EOF
org: acme-org
projects:
- {name: api, full_name: acme-org/api, state: dormido, ritmo: lento}
- {name: web, full_name: acme-org/web, state: abandonado, state_confirmed: true, ritmo: rapido}
EOF
correr
estado_de() { awk -v n="$1" '$1 == "-" && $2 == "name:" {dentro = ($3 == n)} dentro && $1 == "state:" {print $2; exit}' "$PF"; }
afirma "AC-3 state sin confirmar se regenera (activo)" "activo" "$(estado_de api)"
afirma "AC-3 state confirmado se conserva (abandonado)" "abandonado" "$(estado_de web)"
afirma "AC-3 el ritmo se conserva siempre" 2 "$(grep -cE 'ritmo: (lento|rapido)' "$PF")"

# ---------- AC-3: --seco no crea ni modifica nada ----------
nuevo_caso; sembrar acme-org; echo "ajeno" > "$DATA/otro.txt"
antes="$(huella_dir "$HOME")"
correr --seco
afirma "AC-3 --seco con destino: código" 0 "$RC"
afirma "AC-3 --seco con destino: listado y checksums iguales" "$antes" "$(huella_dir "$HOME")"
contiene "AC-3 --seco: tabla de siempre" "$SALIDA" "acme-org/web"
contiene "AC-3 --seco: resumen" "$SALIDA" "org actual «acme-org» → generada «acme-org» · 2 proyectos (1 con campos conservados) · no se ha escrito nada"
rm -rf "$HOME/.hermes"; antes="$(huella_dir "$HOME")"
correr --seco
afirma "AC-3 --seco sin destino: código" 0 "$RC"
afirma "AC-3 --seco sin destino: no crea ni el directorio" "$antes" "$(huella_dir "$HOME")"
afirma "AC-3 --seco sin destino: no existe $DATA" 0 "$([[ -e "$DATA" ]] && echo 1 || echo 0)"
contiene "AC-3 --seco sin destino: resumen con org actual vacía" "$SALIDA" "org actual «» → generada «acme-org» · 2 proyectos (0 con campos conservados) · no se ha escrito nada"

# ---------- AC-3: --salida escribe solo en esa ruta ----------
nuevo_caso; sembrar acme; mkdir -p "$tmp/otro"
antes="$(huella_dir "$DATA")"
correr --salida "$tmp/otro/prueba.yaml"
afirma "AC-3 --salida: código (el destino real es de otra org y no importa)" 0 "$RC"
afirma "AC-3 --salida: el destino real no se toca" "$antes" "$(huella_dir "$DATA")"
afirma "AC-3 --salida: escribe en la ruta" 1 "$(grep -c '^org: acme-org' "$tmp/otro/prueba.yaml")"
afirma "AC-3 --salida: solo ese fichero" "prueba.yaml" "$(ls -A "$tmp/otro")"
# conserva campos de RUTA (no del destino real) y hace copia al sobrescribir
printf 'org: acme-org\nprojects:\n- {name: api, full_name: acme-org/api, ritmo: rapido}\n' > "$tmp/otro/prueba.yaml"
correr --salida "$tmp/otro/prueba.yaml"
afirma "AC-3 --salida: lee los campos conservados de RUTA" 1 "$(grep -c 'ritmo: rapido' "$tmp/otro/prueba.yaml")"
afirma "AC-3 --salida: copia .bak junto a RUTA" 1 "$(nbak "$tmp/otro" prueba.yaml)"
afirma "AC-3 --salida: sin copias junto al destino real" 0 "$(nbak "$DATA" portfolio.yaml)"
# las guardas también valen sobre RUTA
printf 'org: acme\nprojects: []\n' > "$tmp/otro/prueba.yaml"
correr --salida "$tmp/otro/prueba.yaml"
afirma "AC-3 --salida con org distinta en RUTA: código 3" 3 "$RC"
# --seco y --salida son excluyentes
correr --seco --salida "$tmp/otro/x.yaml"
afirma "AC-3 --seco con --salida: argparse lo rechaza" 2 "$RC"
contiene "AC-3 --seco con --salida: mensaje" "$ERR" "not allowed with"

# ---------- D-1: destino = $FABRIK_DATA/portfolio.yaml; sin FABRIK_DATA, ~/.hermes/factory ----------
nuevo_caso; mkdir -p "$tmp/datos-alt"
DATA_ENV="$tmp/datos-alt" correr
afirma "D-1 con FABRIK_DATA: escribe ahí" 1 "$(grep -c '^org: acme-org' "$tmp/datos-alt/portfolio.yaml")"
afirma "D-1 con FABRIK_DATA: no escribe en ~/.hermes/factory" 0 "$([[ -e "$PF" ]] && echo 1 || echo 0)"
nuevo_caso
: > "$FAKE_LOG"
env -u FABRIK_DATA HOME="$HOME" FABRIK_CONFIG="$CFG" uv run --with pyyaml python "$FABRIK_DIR/scripts/build_portfolio.py" >/dev/null 2>&1
afirma "D-1 sin FABRIK_DATA: ~/.hermes/factory/portfolio.yaml" 1 "$(grep -c '^org: acme-org' "$PF")"

# ---------- --help ----------
correr --help
for o in --seco --salida --forzar; do contiene "--help documenta $o" "$SALIDA" "$o"; done

# ---------- AC-5: la regla está en profiles/_comun.md, justo tras «Nunca debilites…» ----------
COMUN="$FABRIK_DIR/profiles/_comun.md"
afirma "AC-5 regla «Nunca pruebes generadores…» en _comun.md" 1 "$(grep -c '^\*\*Nunca pruebes generadores ni instaladores contra la configuración real\.\*\*' "$COMUN")"
l_debilites="$(grep -n '^\*\*Nunca debilites' "$COMUN" | cut -d: -f1)"
l_regla="$(grep -n '^\*\*Nunca pruebes generadores' "$COMUN" | cut -d: -f1)"
afirma "AC-5 la regla va justo después del párrafo «Nunca debilites…»" "$((l_debilites + 2))" "$l_regla"
for t in 'HOME=$(mktemp -d)' '--seco' 'install.sh --comprobar' '--help'; do
  contiene "AC-5 la regla menciona $t" "$(sed -n "${l_regla}p" "$COMUN")" "$t"
done

# ---------- Docs: el onboarding usa --seco y explica guarda, --forzar y .bak ----------
sec5="$(sed -n '/^## 5\. Regenerar el portfolio/,/^## 6\./p' "$FABRIK_DIR/docs/onboarding.md")"
for t in 'build_portfolio.py --seco' '--forzar' '.bak' 'org'; do contiene "AC-3 onboarding §5 menciona $t" "$sec5" "$t"; done
l_seco="$(grep -n 'build_portfolio.py --seco' <<< "$sec5" | head -1 | cut -d: -f1)"
l_real="$(grep -nE 'build_portfolio.py *$' <<< "$sec5" | head -1 | cut -d: -f1)"
if [[ -n "$l_seco" && -n "$l_real" && "$l_seco" -lt "$l_real" ]]; then ok_; else fallo "AC-3 onboarding §5: --seco debe ir antes de la ejecución real (seco=$l_seco real=$l_real)"; fi

echo "portfolio_test: $ok ok, $fail fallos"
[[ "$fail" -eq 0 ]]
