#!/usr/bin/env bash
# Tests de onboarding (IMPL-5): config personal + install.sh --pack + alta de repos personales
# Criterios: AC-16, AC-17, AC-18, AC-19 (+ decisión humana 23/10: propuesta de modelos por
# proveedores detectados, nunca copiados del pack).
# Aislamiento: HOME temporal por escenario, falsos para gh, hermes, git y mariadb; nada de red,
# nada de ~/.hermes ni ~/.config reales. Fechas relativas (sin dependencia del reloj).
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }
# afirma "descripción" comando args… → ok si el comando sale 0
afirma() { local d="$1"; shift; if "$@"; then ok_; else fallo "$d"; fi; }

# La caché de uv y los Python gestionados se resuelven ANTES de cambiar HOME (sin red en los escenarios).
export UV_CACHE_DIR="${UV_CACHE_DIR:-$(uv cache dir 2>/dev/null)}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$(uv python dir 2>/dev/null)}"
PATH_ORIG="$PATH"
# Sin claves de proveedores heredadas del entorno real: la detección debe depender solo del escenario.
unset FABRIK_CONFIG FABRIK_DATA ANTHROPIC_API_KEY DEEPSEEK_API_KEY KIMI_API_KEY

tmp="$(mktemp -d)"
if [[ -n "${KEEP_TMP:-}" ]]; then echo "tmp conservado: $tmp" >&2; else trap 'rm -rf "$tmp"' EXIT; fi
BIN="$tmp/bin"
mkdir -p "$BIN"
export FAKE_LOG="$tmp/fake.log"
export PATH="$BIN:$PATH"

# --- utilidades ---
py() { uv run --with pyyaml python -I -c "$@"; }
limpio() { sed 's/\x1b\[[0-9;]*m//g' "$1"; }                  # salida sin colores
tiene() { limpio "$1" | grep -qE -- "$2"; }                    # fichero patrón
no_tiene() { ! tiene "$1" "$2"; }
cuenta() { limpio "$1" | grep -cE -- "$2" || true; }
packs_de() { py 'import sys,yaml
for p in yaml.safe_load(open(sys.argv[1])).get("packs") or []: print(p)' "$1"; }
slugs_de() { py 'import sys,yaml
for t in yaml.safe_load(open(sys.argv[1])).get("tableros") or []: print(t["slug"])' "$1"; }
provs_de() { py 'import sys,yaml
m=yaml.safe_load(open(sys.argv[1])).get("modelos") or {}
r={k:v for k,v in m.items() if k not in ("pool","reserva_final","permitir_pago")}
s={v["proveedor"] for v in r.values()}|{x["proveedor"] for v in r.values() for x in (v.get("reserva") or [])}
print(" ".join(sorted(s)))' "$1"; }
modelos_n() { py 'import sys,yaml;print(len([k for k in (yaml.safe_load(open(sys.argv[1])).get("modelos") or {}) if k not in ("pool","reserva_final","permitir_pago")]))' "$1"; }
iguales() { [ "$1" = "$2" ]; }

# HOME fresco por escenario (sin FABRIK_CONFIG/FABRIK_DATA heredados), con estado de hermes propio.
home_nuevo() {
  export HOME="$tmp/h_$1"
  mkdir -p "$HOME/.hermes"
  : > "$HOME/.hermes/.env"
  unset FABRIK_CONFIG FABRIK_DATA ANTHROPIC_API_KEY DEEPSEEK_API_KEY KIMI_API_KEY
  export HERMES_STATE="$tmp/hs_$1"
  mkdir -p "$HERMES_STATE"
  export BOARDS_FILE="$tmp/boards_$1"
  : > "$BOARDS_FILE"
  : > "$FAKE_LOG"
}

# --- fixtures de pack ---
# Pack con el que se prueba AC-16..AC-18: por defecto el ficticio acme del motor. Un pack real lo pasa con
# FIXTURE_SH=<pack>/tests/fixtures/ac18.sh (sus literales viven en el pack; ver el test de onboarding del propio pack).
FIXTURE_SH="${FIXTURE_SH:-$FABRIK_DIR/tests/fixtures/pack-acme/ac18.sh}"
if [[ ! -f "$FIXTURE_SH" ]]; then
  fallo "No existe el fixture de pack: $FIXTURE_SH"
  exit 1
fi
source "$FIXTURE_SH"
PACK_DIR="$FIXTURE_PACK_DIR"

# Pack genérico ficticio (nombres inventados) con productos, tableros y modelos propios.
ACME="$tmp/fx/pack-acme"
mkdir -p "$ACME"
cat > "$ACME/pack.yaml" <<'EOF'
nombre: acme
titulo: Acme
owners: [acme]
tableros:
  - {slug: web, nombre: Web, descripcion: "storefront y billing-api", icono: W}
  - {slug: infra, nombre: Infra, descripcion: "infraestructura", icono: I}
  - {slug: ops, nombre: Ops, descripcion: "operaciones", icono: O}
tablero_por_defecto: ops
products:
  tienda: {repos: [shop], board: web}
modelos:
  orquestador: {proveedor: deepseek, modelo: deepseek-v4-pro}
EOF

# Pack con un tablero sin `slug` (se ignora al asignar boards) cuya descripción menciona `misc`.
mkdir -p "$tmp/fx/pack-sinslug"
cat > "$tmp/fx/pack-sinslug/pack.yaml" <<'EOF'
nombre: sinslug
tableros:
  - {nombre: Sin slug, descripcion: "misc y más", icono: S}
EOF

# --- falsos ---
for c in php composer node greptile flock systemctl specify; do
  cat > "$BIN/$c" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$FAKE_LOG"
exit 0
FAKE
  chmod +x "$BIN/$c"
done

cat > "$BIN/mariadb" <<'FAKE'
#!/usr/bin/env bash
printf 'mariadb %s\n' "$*" >> "$FAKE_LOG"
exit 0
FAKE
chmod +x "$BIN/mariadb"

# git falso: `clone URL DEST` crea DEST con el pack.yaml de $FAKE_GIT_SRC (o falla con FAKE_GIT_FAIL=1);
# `-C DIR remote get-url origin` lee DIR/.fake_origin.
cat > "$BIN/git" <<'FAKE'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$FAKE_LOG"
if [[ "${1:-}" == clone ]]; then
  [[ "${FAKE_GIT_FAIL:-0}" == 1 ]] && exit 1
  mkdir -p "$3" && cp "$FAKE_GIT_SRC/pack.yaml" "$3/pack.yaml"
  exit 0
fi
if [[ "${1:-}" == -C && "${3:-}" == remote ]]; then
  cat "$2/.fake_origin" 2>/dev/null
  exit 0
fi
exit 0
FAKE
chmod +x "$BIN/git"

# gh falso: respuestas en ficheros de $GH_FIXTURES (repo list <owner> → <owner>.json,
# repo view <o/r> → view_<o>_<r>.json).
FAKE_USER="usuario_fake"
export FAKE_USER
mkdir -p "$tmp/gh"
export GH_FIXTURES="$tmp/gh"
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  "api user -q .login") echo "$FAKE_USER" ;;
  "auth status"*) ;;
  "repo list "*) f="$GH_FIXTURES/$3.json"; if [[ -f "$f" ]]; then cat "$f"; else echo '[]'; fi ;;
  "repo view "*) f="$GH_FIXTURES/view_${3//\//_}.json"; if [[ -f "$f" ]]; then cat "$f"; else exit 1; fi ;;
  "api repos/acme/shop/contents/CLAUDE.md?"*) ;;
  *) exit 1 ;;
esac
exit 0
FAKE
chmod +x "$BIN/gh"

# hermes falso con estado por escenario ($HERMES_STATE): plugins_list, plugins_enabled, auth_<prov>.
cat > "$BIN/hermes" <<'FAKE'
#!/usr/bin/env bash
printf 'hermes %s\n' "$*" >> "$FAKE_LOG"
case "$1 $2 $3" in
  "kanban boards list") cat "$BOARDS_FILE"; exit 0 ;;
  "kanban boards create") echo " $4 " >> "$BOARDS_FILE"; exit 0 ;;
  "config get plugins.enabled")
    if [[ -f "$HERMES_STATE/plugins_enabled" ]]; then cat "$HERMES_STATE/plugins_enabled"
    else echo "claude-subscription-directsdk-experimental"; fi
    exit 0 ;;
  "plugins list --plain") cat "$HERMES_STATE/plugins_list" 2>/dev/null; exit 0 ;;
  "auth status "*)
    if [[ -f "$HERMES_STATE/auth_$3" ]]; then cat "$HERMES_STATE/auth_$3"; else echo "$3: not logged in"; fi
    exit 0 ;;
esac
exit 0
FAKE
chmod +x "$BIN/hermes"

# Fechas relativas: un repo "reciente" (5 días) y uno muy antiguo.
reciente="$(date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)"
repo_obj() { # nombre nameWithOwner lenguaje rama visibilidad archivado fork descripción
  printf '{"name":"%s","nameWithOwner":"%s","pushedAt":"%s","isArchived":%s,"isFork":%s,"primaryLanguage":{"name":"%s"},"defaultBranchRef":{"name":"%s"},"description":"%s","url":"https://github.com/%s","visibility":"%s"}' \
    "$1" "$2" "$reciente" "${6:-false}" "${7:-false}" "$3" "$4" "${8:-}" "$2" "$5"
}
unico() { printf '[%s]\n' "$(repo_obj "$@")"; }
unico x "$FAKE_USER/x" Python main PUBLIC > "$tmp/gh/$FAKE_USER.json"
unico "$FIXTURE_REPO_NAME" "$FIXTURE_REPO_FULL" PHP develop PRIVATE > "$tmp/gh/$FIXTURE_ORG.json"

# Un `fabrik` falso no hace falta: install.sh llama a scripts/fabrik_config.py vía uv.

# ======================================================================
# AC-16: install.sh --pack <dir pack> en HOME temporal
# ======================================================================
home_nuevo main
bash "$FABRIK_DIR/install.sh" --pack "$PACK_DIR" > "$tmp/out-ac16.log" 2>&1
RC=$?
CFG="$HOME/.config/fabrica/fabrik.yaml"
DATA="$HOME/.hermes/factory"

afirma "AC-16 install.sh --pack salió con $RC (out: $(cat "$tmp/out-ac16.log"))" iguales "$RC" 0
afirma "AC-16 no creó $CFG" test -f "$CFG"
afirma "AC-16 usuario_github != $FAKE_USER" iguales "$(py 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1]))["usuario_github"])' "$CFG")" "$FAKE_USER"
afirma "AC-16 owners != [$FAKE_USER]" iguales "$(py 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1]))["owners"])' "$CFG")" "['$FAKE_USER']"
afirma "AC-16 packs != [$DATA/packs/$(basename "$PACK_DIR")]" iguales "$(packs_de "$CFG")" "$DATA/packs/$(basename "$PACK_DIR")"
afirma "AC-16 el pack no quedó enlazado en $DATA/packs/$(basename "$PACK_DIR")" test "$(readlink "$DATA/packs/$(basename "$PACK_DIR")")" = "$PACK_DIR"
afirma "AC-16 tablero_por_defecto != personal" iguales "$(py 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1]))["tablero_por_defecto"])' "$CFG")" personal
afirma "AC-16 fabrik.yaml sin tablero personal" iguales "$(slugs_de "$CFG")" personal
esperados="$( { py 'import sys,yaml;print("\n".join(t["slug"] for t in yaml.safe_load(open(sys.argv[1]+"/pack.yaml"))["tableros"]))' "$PACK_DIR"; echo personal; } | sort | tr '\n' ' ')"
creados="$(tr -d ' ' < "$BOARDS_FILE" | sort | tr '\n' ' ')"
afirma "AC-16 tableros creados: '$creados' (esperados: '$esperados')" iguales "$creados" "$esperados"
afirma "AC-16 deben ser 9 tableros (8 del pack + personal), hay $(wc -w <<< "$creados")" iguales "$(wc -w <<< "$creados" | tr -d ' ')" 9
afirma "AC-16 sin proveedores detectados, modelos debe ir vacío" iguales "$(modelos_n "$CFG")" 0
# Decisión del plan: el pack no incluye prod.conf y install.sh --pack no instala ninguno.
afirma "AC-16 no debe haber ningún prod.conf bajo HOME" iguales "$(find "$HOME" -name 'prod.conf*' | wc -l | tr -d ' ')" 0

# ======================================================================
# AC-17: re-ejecutar no duplica packs ni tableros
# ======================================================================
cp "$CFG" "$tmp/cfg-antes.yaml"
: > "$FAKE_LOG"
bash "$FABRIK_DIR/install.sh" --pack "$PACK_DIR" > "$tmp/out-ac17.log" 2>&1
RC=$?
afirma "AC-17 la re-ejecución salió con $RC" iguales "$RC" 0
afirma "AC-17 packs duplicados: $(packs_de "$CFG" | wc -l)" iguales "$(packs_de "$CFG" | wc -l | tr -d ' ')" 1
afirma "AC-17 re-creó tableros en hermes" iguales "$(grep -c -- 'kanban boards create' "$FAKE_LOG" || true)" 0
afirma "AC-17 tableros duplicados en la lista de hermes" iguales "$(sort "$BOARDS_FILE" | uniq -d | wc -l | tr -d ' ')" 0
afirma "AC-17 tableros duplicados en fabrik.yaml" iguales "$(slugs_de "$CFG" | sort | uniq -d | wc -l | tr -d ' ')" 0
afirma "AC-17 fabrik.yaml cambió al re-ejecutar" cmp -s "$tmp/cfg-antes.yaml" "$CFG"

# ======================================================================
# AC-18: build_portfolio.py asigna tableros (pack → tableros del pack; personales → personal)
# ======================================================================
export FABRIK_DATA="$DATA"
uv run --with pyyaml python "$FABRIK_DIR/scripts/build_portfolio.py" > "$tmp/out-ac18.log" 2>&1
RC=$?
PORTFOLIO="$DATA/portfolio.yaml"
afirma "AC-18 build_portfolio.py salió con $RC (out: $(cat "$tmp/out-ac18.log"))" iguales "$RC" 0
resumen() { py 'import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
for p in d["projects"]:
    print(p["full_name"], p["board"], p["state"], p["local_path"] or "-", p["claude_memory_notes"], ",".join(p["context"]) or "-")' "$1"; }
fila() { resumen "$1" | awk -v n="$2" '$1==n'; }
board_de() { fila "$1" "$2" | awk '{print $2}'; }
afirma "AC-18 repo personal asignado a '$(board_de "$PORTFOLIO" "$FAKE_USER/x")' (esperado: personal)" iguales "$(board_de "$PORTFOLIO" "$FAKE_USER/x")" personal
afirma "AC-18 repo del pack asignado a '$(board_de "$PORTFOLIO" "$FIXTURE_REPO_FULL")' (esperado: $FIXTURE_EXPECTED_BOARD)" iguales "$(board_de "$PORTFOLIO" "$FIXTURE_REPO_FULL")" "$FIXTURE_EXPECTED_BOARD"

# Los campos preservados no se tocan: se edita el board a mano y se regenera.
sed -i "/full_name: ${FAKE_USER}\/x\$/,/board:/ s/board: personal/board: editado-a-mano/" "$PORTFOLIO"
afirma "AC-18 (preparación) el board editado a mano no quedó en el fichero" iguales "$(board_de "$PORTFOLIO" "$FAKE_USER/x")" editado-a-mano
uv run --with pyyaml python "$FABRIK_DIR/scripts/build_portfolio.py" > /dev/null 2>&1
afirma "AC-18 se perdió el board editado a mano al regenerar" iguales "$(board_de "$PORTFOLIO" "$FAKE_USER/x")" editado-a-mano
afirma "AC-18 la regeneración tocó el board del repo del pack" iguales "$(board_de "$PORTFOLIO" "$FIXTURE_REPO_FULL")" "$FIXTURE_EXPECTED_BOARD"

# ======================================================================
# AC-18 (ampliado): precedencia de tableros, estados, clones locales, repos sueltos
# ======================================================================
home_nuevo pf
for r in "shop PHP" "infra Go" "billing-api PHP" "storefront JS" "misc Python" "oldthing Python"; do
  set -- $r
  printf '%s|%s\n' "$1" "$2"
done > "$tmp/acme-repos.txt"
{
  printf '['
  sep=''
  while IFS='|' read -r n l; do
    printf '%s%s' "$sep" "$(repo_obj "$n" "acme/$n" "$l" main PRIVATE)"; sep=','
  done < "$tmp/acme-repos.txt"
  printf '%s%s' ',' "$(repo_obj lib-old acme/lib-old Python main PRIVATE true false)"
  printf '%s%s' ',' "$(repo_obj shop-replay acme/shop-replay PHP main PRIVATE)"
  printf '%s%s' ',' "$(repo_obj forked acme/forked Python main PRIVATE false true)"
  printf ']\n'
} > "$tmp/gh/acme.json"
printf '[%s,%s]\n' "$(repo_obj proj colega/proj Python main PUBLIC)" "$(repo_obj infra colega/infra Python main PUBLIC)" > "$tmp/gh/colega.json"
repo_obj ops "$FAKE_USER/ops" Python main PUBLIC > "$tmp/gh/view_${FAKE_USER}_ops.json"
repo_obj viaextra "$FAKE_USER/viaextra" Python main PUBLIC > "$tmp/gh/view_${FAKE_USER}_viaextra.json"
repo_obj zzz otro/zzz Python main PUBLIC > "$tmp/gh/view_otro_zzz.json"
echo 'esto no es json' > "$tmp/gh/view_roto_uno.json"
echo '{"name":"dos"}' > "$tmp/gh/view_sincampos_dos.json"

mkdir -p "$HOME/.config/fabrica" "$HOME/.hermes/factory" "$HOME/Code/shop/.git"
echo "https://github.com/acme/shop.git" > "$HOME/Code/shop/.fake_origin"
mem_slug="-$(echo "${HOME#/}/Code/shop" | tr '/.' '--')"
mkdir -p "$HOME/.claude/projects/$mem_slug/memory"
echo nota > "$HOME/.claude/projects/$mem_slug/memory/n.md"
cat > "$HOME/.config/fabrica/fabrik.yaml" <<EOF
usuario_github: $FAKE_USER
owners: [colega]
packs: [$tmp/fx/pack-sinslug, $ACME]
tablero_por_defecto: mio
extra_repos: [$FAKE_USER/viaextra, $FAKE_USER/ops, otro/zzz, roto/uno, sincampos/dos]
EOF
cat > "$HOME/.hermes/factory/portfolio.yaml" <<'EOF'
projects:
  - name: proj
    full_name: colega/proj
    board: manual
    state: dormido
    state_confirmed: true
    ritmo: lento
products:
  legacy: {repos: [oldthing, billing-api], board: legacy-board}
provider_policy: {demo: 1}
EOF
PF="$HOME/.hermes/factory/portfolio.yaml"
uv run --with pyyaml python "$FABRIK_DIR/scripts/build_portfolio.py" > "$tmp/out-pf.log" 2>&1
RC=$?
afirma "AC-18 build_portfolio (escenario ampliado) salió con $RC: $(cat "$tmp/out-pf.log")" iguales "$RC" 0
R="$tmp/resumen-pf.txt"
resumen "$PF" > "$R"
esperado() { afirma "AC-18 fila '$1' → '$2' (real: '$(fila "$PF" "$1")')" iguales "$(fila "$PF" "$1")" "$1 $2"; }
esperado acme/shop "web activo $HOME/Code/shop 1 CLAUDE.md"   # products del pack + clon local + memoria + contexto
esperado acme/infra "infra activo - 0 -"                      # slug del tablero == nombre del repo
esperado acme/storefront "web activo - 0 -"                   # nombre dentro de la descripción del tablero
esperado acme/billing-api "legacy-board activo - 0 -"         # products previos > descripción del pack
esperado acme/oldthing "legacy-board activo - 0 -"
esperado acme/misc "ops activo - 0 -"                         # tablero_por_defecto del pack
esperado acme/lib-old "ops archivado - 0 -"
esperado acme/shop-replay "ops infra - 0 -"
esperado acme/forked "ops ignorar - 0 -"
esperado colega/proj "manual dormido - 0 -"                   # board y state_confirmed preservados
esperado "$FAKE_USER/viaextra" "mio activo - 0 -"             # usuario_github cuenta como owner personal
esperado otro/zzz "mio activo - 0 -"                          # ni personal ni pack: tablero_por_defecto
esperado colega/infra "mio activo - 0 -"                       # owner personal gana al slug de un tablero del pack
esperado "$FAKE_USER/ops" "mio activo - 0 -"                  # usuario_github gana al slug de un tablero del pack
afirma "AC-18 un repo sin JSON válido entró en el portfolio" iguales "$(grep -cE 'roto/uno|sincampos/dos' "$R" || true)" 0
afirma "AC-18 se perdió la sección products al regenerar" grep -q 'legacy-board' "$PF"
afirma "AC-18 se perdió provider_policy al regenerar" grep -q 'demo: 1' "$PF"
afirma "AC-18 se perdió ritmo preservado" grep -q 'ritmo: lento' "$PF"

# Búsqueda del tablero por nombre de repo en `descripcion`: sin distinguir mayúsculas.
home_nuevo caps
mkdir -p "$tmp/fx/pack-caps" "$HOME/.config/fabrica" "$HOME/.hermes/factory"
cat > "$tmp/fx/pack-caps/pack.yaml" <<'EOF'
nombre: caps
owners: [caps]
tableros:
  - {slug: tiendaweb, nombre: Tienda, descripcion: "Tienda Storefront online", icono: T}
EOF
printf '[%s]\n' "$(repo_obj storefront caps/storefront Python main PRIVATE)" > "$tmp/gh/caps.json"
printf 'usuario_github: %s\nowners: [%s]\npacks: [%s]\n' "$FAKE_USER" "$FAKE_USER" "$tmp/fx/pack-caps" > "$HOME/.config/fabrica/fabrik.yaml"
uv run --with pyyaml python "$FABRIK_DIR/scripts/build_portfolio.py" > "$tmp/out-caps.log" 2>&1
PFC="$HOME/.hermes/factory/portfolio.yaml"
afirma "AC-18 'Storefront' en la descripción debe casar con el repo 'storefront' (real: '$(fila "$PFC" caps/storefront)')" iguales "$(fila "$PFC" caps/storefront | awk '{print $2}')" tiendaweb

# ======================================================================
# install.sh --pack: enlace, clonado de URL, errores y primer arranque sin pack
# ======================================================================
home_nuevo pack
# Motor mínimo SIN packs propios (solo `ejemplo`), para probar el aviso sin depender de qué packs
# traiga este árbol (en el repo público no hay otros; en el de la organización sí).
MIN="$tmp/repo-min"
mkdir -p "$MIN/scripts" "$MIN/config" "$MIN/packs/ejemplo"
cp "$FABRIK_DIR/install.sh" "$MIN/"
cp "$FABRIK_DIR/scripts/fabrik_config.py" "$MIN/scripts/"
cp "$FABRIK_DIR/config/fabrik.yaml.ejemplo" "$MIN/config/"
cp "$FABRIK_DIR/packs/ejemplo/pack.yaml" "$MIN/packs/ejemplo/pack.yaml"
bash "$MIN/install.sh" --comprobar > "$tmp/out-sinpack.log" 2>&1
bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-sinpack-real.log" 2>&1
CFG="$HOME/.config/fabrica/fabrik.yaml"
afirma "sin --pack ni packs propios debe avisar del pack de ejemplo" tiene "$tmp/out-sinpack.log" 'Sin pack configurado: usando pack de ejemplo'
afirma "el aviso de pack de ejemplo debe ir con !" tiene "$tmp/out-sinpack.log" '! +Sin pack configurado'
if [[ -n "$(ls -d "$FABRIK_DIR"/packs/*/ 2>/dev/null | grep -v '/ejemplo/$')" ]]; then
  afirma "con un pack propio en el repo no debe avisar de ejemplo (D5)" no_tiene "$tmp/out-sinpack-real.log" 'Sin pack configurado'
fi
afirma "--comprobar es de solo lectura: no debe crear la config personal" test ! -e "$CFG"
afirma "--comprobar es de solo lectura: no debe crear nada en ~/.config/fabrica" test ! -e "$HOME/.config/fabrica"
afirma "--comprobar es de solo lectura: no debe crear packs/ ni datos" test ! -e "$HOME/.hermes/factory"
afirma "--comprobar avisa de lo que haría la instalación con la config" tiene "$tmp/out-sinpack.log" '! +--comprobar no escribe: la instalación crearía la configuración personal en '"$CFG"
afirma "--comprobar no debe anunciar la config como creada" no_tiene "$tmp/out-sinpack.log" '✓ configuración personal creada'
# Con ruta de pack local: tampoco enlaza ni crea config/datos; avisa de lo que haría.
bash "$FABRIK_DIR/install.sh" --comprobar --pack "$ACME" > "$tmp/out-ro-pack.log" 2>&1
afirma "--comprobar --pack local: no crea config ni datos" test ! -e "$HOME/.config/fabrica" -a ! -e "$HOME/.hermes/factory"
afirma "--comprobar --pack local: avisa de que no enlaza" tiene "$tmp/out-ro-pack.log" '! +--comprobar no enlaza: la instalación enlazaría '"$ACME"
afirma "--comprobar --pack local: valida el pack (sin ✗)" no_tiene "$tmp/out-ro-pack.log" '✗ (pack no encontrado|el pack no tiene)'
# Con URL: no clona ni escribe nada; avisa.
export FAKE_GIT_SRC="$ACME"
: > "$FAKE_LOG"
bash "$FABRIK_DIR/install.sh" --comprobar --pack "https://github.com/acme/pack-acme.git" > "$tmp/out-ro-url.log" 2>&1
afirma "--comprobar --pack URL: no debe clonar" iguales "$(grep -c 'git clone' "$FAKE_LOG" || true)" 0
afirma "--comprobar --pack URL: no crea config ni datos" test ! -e "$HOME/.config/fabrica" -a ! -e "$HOME/.hermes/factory"
afirma "--comprobar --pack URL: avisa de que no clona" tiene "$tmp/out-ro-url.log" '! +--comprobar no clona: la instalación clonaría https://github.com/acme/pack-acme.git'
# Con una config existente, --comprobar no la toca (ni con --pack).
mkdir -p "$HOME/.config/fabrica"
printf 'usuario_github: previo\nowners: [previo]\n' > "$CFG"
antes_cfg="$(cat "$CFG")"
bash "$FABRIK_DIR/install.sh" --comprobar --pack "$ACME" > "$tmp/out-ro-cfg.log" 2>&1
afirma "--comprobar --pack con config existente: no la modifica" iguales "$(cat "$CFG")" "$antes_cfg"
afirma "--comprobar --pack con config existente: avisa de lo que haría" tiene "$tmp/out-ro-cfg.log" '! +--comprobar no escribe: la instalación añadiría el pack a '"$CFG"
rm -rf "$HOME/.config/fabrica"
# Instalación real sin --pack (primer arranque): crea la config SIN clave `packs`.
bash "$FABRIK_DIR/install.sh" > "$tmp/out-sinpack-inst.log" 2>&1
afirma "primer arranque: debe anunciar la config personal creada" tiene "$tmp/out-sinpack-inst.log" 'configuración personal creada en '"$CFG"
afirma "primer arranque sin --pack: no escribe la clave packs" iguales "$(py 'import sys,yaml;print("packs" in yaml.safe_load(open(sys.argv[1])))' "$CFG")" False

# D5 (invariante de PR-1): el primer arranque sin --pack no cambia los packs efectivos.
# a) Repo con un pack propio además de `ejemplo`: sus tableros y owners siguen rigiendo.
cfgpy() { uv run --with pyyaml python "$1/scripts/fabrik_config.py" "${@:2}"; }
RAIZ_PRIV="$tmp/repo-con-pack"
mkdir -p "$RAIZ_PRIV/scripts" "$RAIZ_PRIV/config" "$RAIZ_PRIV/packs/propio" "$RAIZ_PRIV/packs/ejemplo"
cp "$FABRIK_DIR/scripts/fabrik_config.py" "$RAIZ_PRIV/scripts/"
cp "$FABRIK_DIR/config/fabrik.yaml.ejemplo" "$RAIZ_PRIV/config/"
cp "$ACME/pack.yaml" "$RAIZ_PRIV/packs/propio/pack.yaml"
cp "$FABRIK_DIR/packs/ejemplo/pack.yaml" "$RAIZ_PRIV/packs/ejemplo/pack.yaml"
home_nuevo d5a
ANTES_TABLEROS="$(cfgpy "$RAIZ_PRIV" campos tableros slug | sort | tr '\n' ' ')"
ANTES_OWNERS="$(cfgpy "$RAIZ_PRIV" get owners | sort | tr '\n' ' ')"
CFG_D5="$tmp/d5a/fabrik.yaml"; mkdir -p "$tmp/d5a"
cfgpy "$RAIZ_PRIV" init-personal "$CFG_D5" "$FAKE_USER" 2>/dev/null
DESPUES_TABLEROS="$(FABRIK_CONFIG="$CFG_D5" cfgpy "$RAIZ_PRIV" campos tableros slug | sort | tr '\n' ' ')"
DESPUES_OWNERS="$(FABRIK_CONFIG="$CFG_D5" cfgpy "$RAIZ_PRIV" get owners | sort | tr '\n' ' ')"
afirma "D5 repo con pack propio: los tableros 'infra ops web' del pack siguen presentes (antes '$ANTES_TABLEROS')" tiene <(echo "$DESPUES_TABLEROS") 'infra.*ops.*web'
afirma "D5 repo con pack propio: init-personal no cambia el pack de ejemplo por el pack propio (tableros: '$DESPUES_TABLEROS')" no_tiene <(echo "$DESPUES_TABLEROS") 'acme-dev|acme-ops'
afirma "D5 repo con pack propio: el owner del pack ('acme') sigue en owners (real: '$DESPUES_OWNERS')" tiene <(echo "$DESPUES_OWNERS") 'acme'
afirma "D5 repo con pack propio: tiene-pack → 0 (hay pack efectivo)" env FABRIK_CONFIG="$CFG_D5" uv run --with pyyaml python "$RAIZ_PRIV/scripts/fabrik_config.py" tiene-pack
# b) Repo solo con `ejemplo`: no hay pack propio, así que avisa (tiene-pack → 1) y rige `ejemplo`.
RAIZ_EJ="$tmp/repo-solo-ejemplo"
mkdir -p "$RAIZ_EJ/scripts" "$RAIZ_EJ/config" "$RAIZ_EJ/packs/ejemplo"
cp "$FABRIK_DIR/scripts/fabrik_config.py" "$RAIZ_EJ/scripts/"
cp "$FABRIK_DIR/config/fabrik.yaml.ejemplo" "$RAIZ_EJ/config/"
cp "$FABRIK_DIR/packs/ejemplo/pack.yaml" "$RAIZ_EJ/packs/ejemplo/pack.yaml"
CFG_EJ="$tmp/d5b/fabrik.yaml"; mkdir -p "$tmp/d5b"
cfgpy "$RAIZ_EJ" init-personal "$CFG_EJ" "$FAKE_USER" 2>/dev/null
FABRIK_CONFIG="$CFG_EJ" cfgpy "$RAIZ_EJ" tiene-pack
afirma "D5 repo solo con ejemplo: tiene-pack → 1 (se avisa de que se usa ejemplo)" iguales "$?" 1
afirma "D5 repo solo con ejemplo: rigen los tableros del pack ejemplo + personal" tiene <(FABRIK_CONFIG="$CFG_EJ" cfgpy "$RAIZ_EJ" campos tableros slug | sort | tr '\n' ' ') 'acme-dev acme-ops personal'
# c) Config con `packs: []` explícito (decisión del humano): sigue contando como sin pack.
printf 'packs: []\n' > "$tmp/d5b/vacio.yaml"
FABRIK_CONFIG="$tmp/d5b/vacio.yaml" cfgpy "$RAIZ_EJ" tiene-pack
afirma "tiene-pack con packs: [] y solo ejemplo → 1" iguales "$?" 1
# d) Config con `packs: [ejemplo]` explícito: ejemplo no cuenta como pack propio.
printf 'packs: [ejemplo]\n' > "$tmp/d5b/soloej.yaml"
FABRIK_CONFIG="$tmp/d5b/soloej.yaml" cfgpy "$RAIZ_EJ" tiene-pack
afirma "tiene-pack con packs: [ejemplo] → 1" iguales "$?" 1

# --pack con la config ya creada: lo añade (una vez), enlazado en $FABRIK_DATA/packs.
home_nuevo pack2
bash "$FABRIK_DIR/install.sh" > "$tmp/out-base.log" 2>&1   # primer arranque sin pack: crea la config
CFG="$HOME/.config/fabrica/fabrik.yaml"
bash "$FABRIK_DIR/install.sh" --pack "$ACME" > "$tmp/out-addpack.log" 2>&1
bash "$FABRIK_DIR/install.sh" --pack "$ACME" > "$tmp/out-addpack2.log" 2>&1
afirma "--pack sobre config existente: packs != [acme]" iguales "$(packs_de "$CFG")" "$HOME/.hermes/factory/packs/pack-acme"
afirma "--pack sobre config existente: enlace a $ACME" test "$(readlink "$HOME/.hermes/factory/packs/pack-acme")" = "$ACME"
afirma "con pack configurado ya no debe avisar del pack de ejemplo" no_tiene "$tmp/out-addpack.log" 'Sin pack configurado'
afirma "el pack añadido debe aportar sus tableros a la config fusionada" iguales "$(FABRIK_CONFIG="$CFG" uv run --with pyyaml python "$FABRIK_DIR/scripts/fabrik_config.py" campos tableros slug | sort | tr '\n' ' ')" "infra ops personal web "

# URL git: clona una sola vez en $FABRIK_DATA/packs/<nombre> y lo añade a packs.
home_nuevo url
export FAKE_GIT_SRC="$ACME"
URL="https://github.com/acme/pack-acme.git"
bash "$FABRIK_DIR/install.sh" --pack "$URL" > "$tmp/out-url.log" 2>&1
CFG="$HOME/.config/fabrica/fabrik.yaml"
DEST="$HOME/.hermes/factory/packs/pack-acme"
afirma "URL: debe clonar con git clone $URL $DEST" grep -qxF "git clone $URL $DEST" "$FAKE_LOG"
afirma "URL: packs != [$DEST]" iguales "$(packs_de "$CFG")" "$DEST"
afirma "URL: el pack clonado debe tener pack.yaml" test -f "$DEST/pack.yaml"
afirma "URL: no debe marcar ✗ el clon ni el pack" no_tiene "$tmp/out-url.log" '✗ (no se pudo clonar|el pack no tiene)'
: > "$FAKE_LOG"
bash "$FABRIK_DIR/install.sh" --pack "$URL" > "$tmp/out-url2.log" 2>&1
afirma "URL: la segunda ejecución no debe volver a clonar" iguales "$(grep -c 'git clone' "$FAKE_LOG" || true)" 0
afirma "URL: la segunda ejecución duplicó el pack" iguales "$(packs_de "$CFG" | wc -l | tr -d ' ')" 1

# Esquemas de URL SSH: también van por `git clone` (no por la rama de ruta local).
for URL_SSH in "git@github.com:acme/pack-acme.git" "ssh://github.com/acme/pack-acme.git"; do
  home_nuevo "urlssh_${URL_SSH%%[:/]*}"   # un HOME distinto por esquema (home_nuevo no vacía el HOME)
  export FAKE_GIT_SRC="$ACME"
  bash "$FABRIK_DIR/install.sh" --pack "$URL_SSH" > "$tmp/out-urlssh.log" 2>&1
  DEST="$HOME/.hermes/factory/packs/pack-acme"
  afirma "URL $URL_SSH: debe clonar con git clone" grep -qxF "git clone $URL_SSH $DEST" "$FAKE_LOG"
  afirma "URL $URL_SSH: no debe tratarse como ruta local" no_tiene "$tmp/out-urlssh.log" 'pack no encontrado'
  afirma "URL $URL_SSH: packs != [$DEST]" iguales "$(packs_de "$HOME/.config/fabrica/fabrik.yaml")" "$DEST"
done

# Enlace local idempotente: la 2.ª ejecución no crea un symlink dentro del pack de origen
# (`ln -s origen destino` con destino ya enlazado a un directorio) y el enlace sigue siendo único.
home_nuevo enlace
SRC_LINK="$tmp/fx/enlace/pack-enlace"
mkdir -p "$SRC_LINK"
cp "$ACME/pack.yaml" "$SRC_LINK/pack.yaml"
bash "$FABRIK_DIR/install.sh" --pack "$SRC_LINK" > "$tmp/out-enlace1.log" 2>&1
antes="$(ls -A "$SRC_LINK" | tr '\n' ' ')"
bash "$FABRIK_DIR/install.sh" --pack "$SRC_LINK" > "$tmp/out-enlace2.log" 2>&1
despues="$(ls -A "$SRC_LINK" | tr '\n' ' ')"
afirma "enlace: el pack de origen cambió en la 2.ª ejecución ('$antes' → '$despues')" iguales "$antes" "$despues"
afirma "enlace: debe haber un único elemento en packs/ ($(ls -A "$HOME/.hermes/factory/packs" | tr '\n' ' '))" iguales "$(ls -A "$HOME/.hermes/factory/packs" | wc -l | tr -d ' ')" 1
afirma "enlace: debe seguir siendo un symlink al origen" test "$(readlink "$HOME/.hermes/factory/packs/pack-enlace")" = "$SRC_LINK"

home_nuevo urlfalla
export FAKE_GIT_FAIL=1
bash "$FABRIK_DIR/install.sh" --pack "$URL" > "$tmp/out-urlfalla.log" 2>&1
unset FAKE_GIT_FAIL
afirma "clon fallido: debe marcar ✗ 'no se pudo clonar el pack desde $URL'" tiene "$tmp/out-urlfalla.log" "✗ no se pudo clonar el pack desde $URL"
afirma "clon fallido: la instalación termina avisando ('Instalada con avisos')" tiene "$tmp/out-urlfalla.log" 'Instalada con avisos'
afirma "clon fallido: no debe añadir el pack a la config" iguales "$(packs_de "$HOME/.config/fabrica/fabrik.yaml" | wc -l | tr -d ' ')" 0

home_nuevo packmal
bash "$FABRIK_DIR/install.sh" --comprobar --pack "$tmp/no-existe" > "$tmp/out-nopack.log" 2>&1
RC=$?
afirma "pack inexistente: debe marcar ✗ 'pack no encontrado'" tiene "$tmp/out-nopack.log" '✗ pack no encontrado: '"$tmp/no-existe"
afirma "pack inexistente: --comprobar debe salir ≠ 0 (salió $RC)" test "$RC" -ne 0
afirma "pack inexistente: no debe crear enlace" test ! -e "$HOME/.hermes/factory/packs/no-existe"
afirma "pack inexistente: no debe añadirse a la config" iguales "$(packs_de "$HOME/.config/fabrica/fabrik.yaml" | wc -l | tr -d ' ')" 0
mkdir -p "$tmp/fx/vacio"
bash "$FABRIK_DIR/install.sh" --comprobar --pack "$tmp/fx/vacio" > "$tmp/out-sinyaml.log" 2>&1
RC=$?
afirma "pack sin pack.yaml: debe marcar ✗ 'el pack no tiene pack.yaml'" tiene "$tmp/out-sinyaml.log" '✗ el pack no tiene pack.yaml: '"$tmp/fx/vacio"
afirma "pack sin pack.yaml: --comprobar debe salir ≠ 0 (salió $RC)" test "$RC" -ne 0
afirma "pack sin pack.yaml: no debe añadirse a la config" iguales "$(packs_de "$HOME/.config/fabrica/fabrik.yaml" | wc -l | tr -d ' ')" 0

# anadir-pack: idempotente también si la ruta se escribe distinto (misma ruta real) y sin config no hace nada.
CF="$tmp/ap.yaml"
printf 'packs:\n  - %s\n' "$ACME" > "$CF"
uv run --with pyyaml python "$FABRIK_DIR/scripts/fabrik_config.py" anadir-pack "$CF" "$tmp/fx/../fx/pack-acme"
afirma "anadir-pack: la misma ruta real escrita distinto duplicó el pack ($(packs_de "$CF" | wc -l))" iguales "$(packs_de "$CF" | wc -l | tr -d ' ')" 1
uv run --with pyyaml python "$FABRIK_DIR/scripts/fabrik_config.py" anadir-pack "$CF" "$tmp/otro-pack-inexistente"
afirma "anadir-pack: una ruta nueva (aunque no exista aún) debe añadirse" iguales "$(packs_de "$CF" | wc -l | tr -d ' ')" 2
printf 'packs: "no-es-lista"\n' > "$tmp/ap2.yaml"
uv run --with pyyaml python "$FABRIK_DIR/scripts/fabrik_config.py" anadir-pack "$tmp/ap2.yaml" "$ACME"
afirma "anadir-pack: con packs que no es lista debe reemplazarlo por una lista" iguales "$(packs_de "$tmp/ap2.yaml")" "$ACME"
uv run --with pyyaml python "$FABRIK_DIR/scripts/fabrik_config.py" anadir-pack "$tmp/no-hay-config.yaml" "$ACME"
afirma "anadir-pack: sin config no debe crearla" test ! -e "$tmp/no-hay-config.yaml"

# init-personal sobre una config que ya existe: no la sobrescribe; con pack lo añade.
CI="$tmp/init-existente.yaml"
printf 'usuario_github: otro\npacks: []\n' > "$CI"
FABRIK_PY="$FABRIK_DIR/scripts/fabrik_config.py"
uv run --with pyyaml python "$FABRIK_PY" init-personal "$CI" "$FAKE_USER"
afirma "init-personal sobre config existente no debe sobrescribirla" grep -q 'usuario_github: otro' "$CI"
uv run --with pyyaml python "$FABRIK_PY" init-personal "$CI" "$FAKE_USER" "$ACME"
afirma "init-personal sobre config existente con pack debe añadirlo (packs: $(packs_de "$CI" | tr '\n' ' '))" iguales "$(packs_de "$CI")" "$ACME"
afirma "init-personal sobre config existente no debe tocar el usuario" grep -q 'usuario_github: otro' "$CI"

# Si `hermes` no existe en la máquina, la detección no revienta: sin proveedores, modelos vacío.
SOLO_UV="$tmp/solo-uv"
mkdir -p "$SOLO_UV"
ln -sf "$(PATH="$PATH_ORIG" type -P uv)" "$SOLO_UV/uv"
afirma "(guarda) el PATH solo-uv no debe tener hermes" test -z "$(PATH="$SOLO_UV" type -P hermes)"
home_nuevo sinhermes
PATH="$SOLO_UV" uv run --with pyyaml python "$FABRIK_PY" init-personal "$HOME/c.yaml" "$FAKE_USER" 2> "$tmp/sinhermes.err"
RC=$?
afirma "sin hermes: init-personal salió con $RC" iguales "$RC" 0
afirma "sin hermes: modelos vacío" iguales "$(modelos_n "$HOME/c.yaml")" 0
afirma "sin hermes: 7 avisos de rol sin modelo" iguales "$(grep -c 'sin modelo (ningún proveedor' "$tmp/sinhermes.err" || true)" 7

# Rutas de pack relativas: junto a la config, en FABRIK_DATA/packs y en el repo (packs/ejemplo).
mkdir -p "$tmp/rel/mispacks/junto" "$tmp/datos/packs/endatos"
for d in "$tmp/rel/mispacks/junto" "$tmp/datos/packs/endatos"; do
  printf 'nombre: %s\ntableros:\n  - {slug: %s, nombre: N, descripcion: d, icono: x}\n' "$(basename "$d")" "$(basename "$d")" > "$d/pack.yaml"
done
printf 'packs: [mispacks/junto, endatos, ejemplo, no-existe-nunca]\n' > "$tmp/rel/fabrik.yaml"
sal="$(FABRIK_CONFIG="$tmp/rel/fabrik.yaml" FABRIK_DATA="$tmp/datos" uv run --with pyyaml python "$FABRIK_DIR/scripts/fabrik_config.py" campos tableros slug 2>"$tmp/rel.err" | sort | tr '\n' ' ')"
afirma "rutas relativas: tableros '$sal'" iguales "$sal" "acme-dev acme-ops endatos junto "
afirma "rutas relativas: un pack inexistente debe avisar" grep -q 'aviso: pack no encontrado, se omite: no-existe-nunca' "$tmp/rel.err"

# ======================================================================
# Propuesta de modelos por proveedores detectados (decisión del humano 23/10)
# ======================================================================
# a) plugin habilitado + clave en ~/.hermes/.env; claves vacías/comentarios no cuentan.
home_nuevo plugin
cat > "$HERMES_STATE/plugins_list" <<'EOF'
enabled      bundled  1.0.0    antigravity-oauth
not enabled  bundled  1.0.0    claude-subscription-directsdk-experimental
enabled      bundled  1.0.0    basic
EOF
echo antigravity-oauth > "$HERMES_STATE/plugins_enabled"
printf '# comentario\nDEEPSEEK_API_KEY=\n\nlinea-suelta\nKIMI_API_KEY=abc\n' > "$HOME/.hermes/.env"
bash "$FABRIK_DIR/install.sh" --pack "$ACME" > "$tmp/out-plugin.log" 2>&1
# Con la config ya creada, --comprobar (solo lectura) debe salir 0.
bash "$FABRIK_DIR/install.sh" --comprobar >> "$tmp/out-plugin.log" 2>&1
RC=$?
CFG="$HOME/.config/fabrica/fabrik.yaml"
afirma "detección: modelos != antigravity-oauth + kimi-coding (real: '$(provs_de "$CFG")')" iguales "$(provs_de "$CFG")" "antigravity-oauth kimi-coding"
afirma "detección: debe proponer los 7 roles" iguales "$(modelos_n "$CFG")" 7
afirma "detección: el programador debe ser kimi-coding/kimi-for-coding" iguales "$(py 'import sys,yaml;m=yaml.safe_load(open(sys.argv[1]))["modelos"]["programador"];print(m["proveedor"],m["modelo"])' "$CFG")" "kimi-coding kimi-for-coding"
afirma "detección: sin reserva detectada, 'reserva' va explícita como lista vacía (AC-24)" iguales "$(py 'import sys,yaml;m=yaml.safe_load(open(sys.argv[1]))["modelos"]["programador"];print("reserva" in m, m["reserva"])' "$CFG")" "True []"
afirma "detección: NO debe copiar los modelos del pack (deepseek)" no_tiene "$CFG" 'deepseek'
afirma "detección: avisa de roles sin modelo bueno" tiene "$tmp/out-plugin.log" 'aviso: rol orquestador: sin modelo bueno; propuesto kimi-coding/kimi-for-coding'
afirma "--comprobar muestra la propuesta para confirmarla" tiene "$tmp/out-plugin.log" 'Modelos por rol \(propuesta según tus proveedores; confirma o edita'
afirma "--comprobar lista el modelo del programador" tiene "$tmp/out-plugin.log" 'programador +: kimi-coding / kimi-for-coding'
afirma "--comprobar: clave KIMI_API_KEY presente → ✓" tiene "$tmp/out-plugin.log" '✓ KIMI_API_KEY en ~/.hermes/.env'
afirma "--comprobar: plugin antigravity-oauth activo → ✓" tiene "$tmp/out-plugin.log" '✓ plugin antigravity-oauth'
afirma "--comprobar: no debe pedir DEEPSEEK_API_KEY (proveedor no detectado ni usado)" no_tiene "$tmp/out-plugin.log" 'DEEPSEEK_API_KEY'
afirma "--comprobar: no debe pedir el plugin de Claude" no_tiene "$tmp/out-plugin.log" 'plugin claude-subscription'
afirma "detección con todo en regla: --comprobar sale 0 (salió $RC: $(tail -3 "$tmp/out-plugin.log"))" iguales "$RC" 0

# b) `hermes auth status <proveedor>`: solo "logged in" cuenta; "logged out"/"not logged in" no.
home_nuevo auth
echo "deepseek: logged in" > "$HERMES_STATE/auth_deepseek"
echo "kimi-coding: logged out" > "$HERMES_STATE/auth_kimi-coding"
echo "Not logged in" > "$HERMES_STATE/auth_antigravity-oauth"
ANTHROPIC_API_KEY=clave-en-entorno bash "$FABRIK_DIR/install.sh" > "$tmp/out-auth.log" 2>&1
CFG="$HOME/.config/fabrica/fabrik.yaml"
afirma "auth status: deepseek detectado pero de pago: no se propone sin permitir_pago (propuestos '$(provs_de "$CFG")')" iguales "$(provs_de "$CFG")" "anthropic"
afirma "auth status: orquestador = anthropic (clave en el entorno)" iguales "$(py 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1]))["modelos"]["orquestador"]["proveedor"])' "$CFG")" anthropic
afirma "auth status: programador anthropic sin reserva (deepseek es de pago)" iguales "$(py 'import sys,yaml;m=yaml.safe_load(open(sys.argv[1]))["modelos"]["programador"];print(m["proveedor"],m["reserva"])' "$CFG")" "anthropic []"
afirma "auth status: debe consultar hermes auth status deepseek" grep -qx 'hermes auth status deepseek' "$FAKE_LOG"

# b2) una clave vacía en ~/.hermes/.env no anula la clave real del entorno.
home_nuevo envvacio
echo "DEEPSEEK_API_KEY=" > "$HOME/.hermes/.env"
DEEPSEEK_API_KEY=clave-del-entorno bash "$FABRIK_DIR/install.sh" > "$tmp/out-envvacio.log" 2>&1
afirma "clave vacía en .env no debe anular la del entorno: deepseek detectado pero sin permitir_pago no se propone (propuestos: '$(provs_de "$HOME/.config/fabrica/fabrik.yaml")')" iguales "$(provs_de "$HOME/.config/fabrica/fabrik.yaml")" ""

# b3) AC-24: con `permitir_pago: true` en la capa efectiva (la fija el pack) sí se propone deepseek.
home_nuevo pago
mkdir -p "$tmp/packs-pago/pagador"
printf 'nombre: pagador\nmodelos:\n  permitir_pago: true\n' > "$tmp/packs-pago/pagador/pack.yaml"
DEEPSEEK_API_KEY=clave ANTHROPIC_API_KEY=clave bash "$FABRIK_DIR/install.sh" --pack "$tmp/packs-pago/pagador" > "$tmp/out-pago.log" 2>&1
CFG="$HOME/.config/fabrica/fabrik.yaml"
afirma "AC-24 con permitir_pago del pack se propone deepseek (propuestos '$(provs_de "$CFG")')" iguales "$(provs_de "$CFG")" "anthropic deepseek"
afirma "AC-24 con permitir_pago el pack no se copia: la config no lleva permitir_pago" no_tiene "$CFG" 'permitir_pago'
afirma "AC-24 cada rol lleva 'reserva' como lista" iguales "$(py 'import sys,yaml;m=yaml.safe_load(open(sys.argv[1]))["modelos"];print(all(isinstance(m[r]["reserva"],list) for r in m if r not in ("pool","reserva_final")))' "$CFG")" True

# b4) AC-24: avisa de los niveles del pool que quedan vacíos y propone el pool/reserva_final solo con lo detectado.
home_nuevo niveles
ANTHROPIC_API_KEY=clave bash "$FABRIK_DIR/install.sh" > "$tmp/out-niveles.log" 2>&1
CFG="$HOME/.config/fabrica/fabrik.yaml"
afirma "AC-24 avisa del nivel ligero vacío" tiene "$tmp/out-niveles.log" 'aviso: nivel ligero del pool: vacío'
afirma "AC-24 avisa del nivel medio vacío" tiene "$tmp/out-niveles.log" 'aviso: nivel medio del pool: vacío'
afirma "AC-24 pool solo con dificil y critico (anthropic detectado)" iguales "$(py 'import sys,yaml;print(sorted(yaml.safe_load(open(sys.argv[1]))["modelos"]["pool"]))' "$CFG")" "['critico', 'dificil']"
afirma "AC-24 reserva_final con proveedor detectado" iguales "$(py 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1]))["modelos"]["reserva_final"]["proveedor"])' "$CFG")" anthropic

# b5) AC-25: máquina ya configurada (perfiles de Hermes creados, sin fabrik.yaml) y un pack con los modelos de
# referencia de Manu: no se reescriben los modelos efectivos; avisa de copiar el fixture del pack.
home_nuevo previos
mkdir -p "$HOME/.hermes/profiles/programador" "$tmp/packs-previos/acme/tests/fixtures"
printf 'nombre: acme\n' > "$tmp/packs-previos/acme/pack.yaml"
printf 'modelos:\n  programador: {proveedor: kimi-coding, modelo: kimi-for-coding, reserva: []}\n' > "$tmp/packs-previos/acme/tests/fixtures/modelos-manu.yaml"
ANTHROPIC_API_KEY=clave bash "$FABRIK_DIR/install.sh" --pack "$tmp/packs-previos/acme" > "$tmp/out-previos.log" 2>&1
RC=$?
afirma "AC-25 no escribe la config personal (salió $RC)" test ! -e "$HOME/.config/fabrica/fabrik.yaml"
afirma "AC-25 sale distinto de 0 (salió $RC)" test "$RC" -ne 0
afirma "AC-25 avisa de copiar modelos-manu.yaml" tiene "$tmp/out-previos.log" 'cp .*/acme/tests/fixtures/modelos-manu.yaml '
afirma "AC-25 no aplica perfiles" no_tiene "$FAKE_LOG" "apply_profile_policy\|hermes profile"
# Con la config personal ya presente (ya copió el fixture) sigue el flujo normal.
mkdir -p "$HOME/.config/fabrica"
{ printf 'packs: [%s]\n' "$tmp/packs-previos/acme"; sed 1d "$tmp/packs-previos/acme/tests/fixtures/modelos-manu.yaml" | sed '1i modelos:'; } > "$HOME/.config/fabrica/fabrik.yaml"
ANTHROPIC_API_KEY=clave bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-previos2.log" 2>&1
afirma "AC-25 con fabrik.yaml presente no aborta por modelos previos" no_tiene "$tmp/out-previos2.log" 'máquina ya configurada'
# Sin perfiles de Hermes (máquina nueva) se propone como siempre.
home_nuevo previos2
ANTHROPIC_API_KEY=clave bash "$FABRIK_DIR/install.sh" --pack "$tmp/packs-previos/acme" > "$tmp/out-previos3.log" 2>&1
afirma "AC-25 máquina nueva (sin perfiles) propone modelos y crea la config" test -f "$HOME/.config/fabrica/fabrik.yaml"
afirma "AC-25 máquina nueva no avisa de máquina ya configurada" no_tiene "$tmp/out-previos3.log" 'máquina ya configurada'

# c) nada detectado: sin modelos propios, 7 avisos y --comprobar enseña los de por defecto y cómo cambiarlos.
home_nuevo nada
bash "$FABRIK_DIR/install.sh" > "$tmp/out-nada.log" 2>&1
CFG="$HOME/.config/fabrica/fabrik.yaml"
afirma "nada detectado: modelos debe ir vacío" iguales "$(modelos_n "$CFG")" 0
afirma "nada detectado: 7 avisos de rol sin modelo" iguales "$(cuenta "$tmp/out-nada.log" 'aviso: rol .*: sin modelo \(ningún proveedor detectado sirve\)')" 7
afirma "nada detectado: --comprobar avisa de que no hay modelos personales" tiene "$tmp/out-nada.log" '! +Sin modelos personales en ~/.config/fabrica/fabrik.yaml'
afirma "nada detectado: muestra los modelos por defecto" tiene "$tmp/out-nada.log" 'tester +: anthropic / claude-sonnet-5-5'
afirma "nada detectado: explica cómo cambiarlos" tiene "$tmp/out-nada.log" "Para personalizar tus modelos: define 'modelos:'"

# d) modelos personales parciales: avisa de los roles sin modelo propio y enseña la reserva.
home_nuevo parcial
cat > "$tmp/parcial.yaml" <<'EOF'
packs: []
modelos:
  programador:
    proveedor: kimi-coding
    modelo: kimi-for-coding
    reserva: {proveedor: deepseek, modelo: deepseek-flash}
EOF
FABRIK_CONFIG="$tmp/parcial.yaml" bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-parcial.log" 2>&1
afirma "parcial: avisa de roles sin modelo propio" tiene "$tmp/out-parcial.log" '! rol orquestador: sin modelo propio; usa el valor por defecto \(puede exigir un proveedor que no tienes\)'
afirma "parcial: el rol con modelo propio no se avisa" no_tiene "$tmp/out-parcial.log" 'rol programador: sin modelo propio'
afirma "parcial: muestra la reserva" tiene "$tmp/out-parcial.log" 'programador +: kimi-coding / kimi-for-coding \(reserva: deepseek/deepseek-flash\)'

# ======================================================================
# AC-19: --comprobar pide solo las claves/plugins de los proveedores de `modelos`
# ======================================================================
escribe_modelos() { # fichero proveedor-del-tester modelo-del-tester
  {
    echo "packs: []"; echo "modelos:"
    for r in orquestador explorador programador revisor seguridad docs; do
      printf '  %s:\n    proveedor: claude-subscription-directsdk-experimental\n    modelo: claude-sonnet-5-5\n' "$r"
    done
    printf '  tester:\n    proveedor: %s\n    modelo: %s\n' "$2" "$3"
  } > "$1"
}
home_nuevo comprobar
escribe_modelos "$tmp/solo-claude.yaml" claude-subscription-directsdk-experimental claude-sonnet-5-5
FABRIK_CONFIG="$tmp/solo-claude.yaml" bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-claude.log" 2>&1
RC=$?
afirma "AC-19 con solo Claude no debe pedir DEEPSEEK_API_KEY" no_tiene "$tmp/out-claude.log" 'DEEPSEEK_API_KEY'
afirma "AC-19 con solo Claude no debe pedir KIMI_API_KEY" no_tiene "$tmp/out-claude.log" 'KIMI_API_KEY'
afirma "AC-19 con solo Claude no debe pedir ANTHROPIC_API_KEY" no_tiene "$tmp/out-claude.log" 'ANTHROPIC_API_KEY'
afirma "AC-19 con solo Claude debe verificar el plugin de Claude" tiene "$tmp/out-claude.log" '✓ plugin claude-subscription-directsdk-experimental'
afirma "AC-19 con solo Claude --comprobar debe salir 0 (salió $RC)" iguales "$RC" 0
afirma "AC-19 con solo Claude debe decir 'Todo listo.'" tiene "$tmp/out-claude.log" '^Todo listo\.$'

# Control positivo: con `deepseek` en modelos SÍ se pide su clave (✗ y salida ≠ 0), y con la clave ya no.
escribe_modelos "$tmp/con-deepseek.yaml" deepseek deepseek-v4-pro
FABRIK_CONFIG="$tmp/con-deepseek.yaml" bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-ds-falta.log" 2>&1
RC=$?
afirma "AC-19 (control) con deepseek y sin clave: ✗ DEEPSEEK_API_KEY" tiene "$tmp/out-ds-falta.log" '✗ DEEPSEEK_API_KEY falta en ~/.hermes/.env'
afirma "AC-19 (control) con deepseek y sin clave: --comprobar sale ≠ 0 (salió $RC)" test "$RC" -ne 0
afirma "AC-19 (control) con deepseek y sin clave: 'Faltan cosas'" tiene "$tmp/out-ds-falta.log" '^Faltan cosas'
afirma "AC-19 (control) con deepseek sigue sin pedir KIMI_API_KEY" no_tiene "$tmp/out-ds-falta.log" 'KIMI_API_KEY'
echo "DEEPSEEK_API_KEY=sk-prueba" > "$HOME/.hermes/.env"
FABRIK_CONFIG="$tmp/con-deepseek.yaml" bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-ds-ok.log" 2>&1
RC=$?
afirma "AC-19 (control) con la clave presente: ✓ DEEPSEEK_API_KEY" tiene "$tmp/out-ds-ok.log" '✓ DEEPSEEK_API_KEY en ~/.hermes/.env'
afirma "AC-19 (control) con la clave presente: --comprobar sale 0 (salió $RC)" iguales "$RC" 0
: > "$HOME/.hermes/.env"

# Control positivo para plugins: un proveedor sin clave de API cuyo plugin no está activo → ✗.
escribe_modelos "$tmp/con-antigravity.yaml" antigravity-oauth gemini-3.8-flash-medium
FABRIK_CONFIG="$tmp/con-antigravity.yaml" bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-plug-falta.log" 2>&1
RC=$?
afirma "AC-19 (control) plugin inactivo: ✗ plugin antigravity-oauth" tiene "$tmp/out-plug-falta.log" '✗ plugin antigravity-oauth: hermes plugins install'
afirma "AC-19 (control) plugin inactivo: --comprobar sale ≠ 0 (salió $RC)" test "$RC" -ne 0

# ======================================================================
# MariaDB: aviso (no ✗) si ningún repo del portfolio es PHP; ✗ si lo hay.
# PATH acotado: sin ningún mariadb real de la máquina.
# ======================================================================
SAFE="$tmp/safe"
mkdir -p "$SAFE"
for t in bash env dirname basename cat grep sed awk head tail tr mkdir ln cp rm mktemp ls date sort uniq cut wc id uv python3 find readlink; do
  p="$(PATH="$PATH_ORIG" type -P "$t")" && ln -sf "$p" "$SAFE/$t"
done
for f in "$BIN"/*; do
  [[ "$(basename "$f")" == mariadb ]] || ln -sf "$f" "$SAFE/$(basename "$f")"
done
afirma "(guarda) el PATH acotado no debe contener mariadb" test -z "$(PATH="$SAFE" type -P mariadb)"

home_nuevo maria
mkdir -p "$HOME/.hermes/factory"
printf 'projects:\n  - name: solo-python\n    language: Python\n' > "$HOME/.hermes/factory/portfolio.yaml"
FABRIK_CONFIG="$tmp/solo-claude.yaml" PATH="$SAFE" bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-sin-mariadb.log" 2>&1
RC=$?
afirma "sin MariaDB y sin repos PHP: debe salir 0 (salió $RC: $(tail -3 "$tmp/out-sin-mariadb.log"))" iguales "$RC" 0
afirma "sin MariaDB y sin repos PHP: debe avisar con !" tiene "$tmp/out-sin-mariadb.log" '! +mariadb no instalado \(opcional: ningún repo PHP detectado en el portfolio\)'
afirma "sin MariaDB y sin repos PHP: no debe marcar ✗ mariadb" no_tiene "$tmp/out-sin-mariadb.log" '✗ mariadb'

printf 'projects:\n  - name: tienda\n    language: PHP\n' > "$HOME/.hermes/factory/portfolio.yaml"
FABRIK_CONFIG="$tmp/solo-claude.yaml" PATH="$SAFE" bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-php-sin-mariadb.log" 2>&1
RC=$?
afirma "sin MariaDB y con repo PHP: debe marcar ✗ mariadb" tiene "$tmp/out-php-sin-mariadb.log" '✗ mariadb no encontrado \(necesario para repos PHP\)'
afirma "sin MariaDB y con repo PHP: --comprobar sale ≠ 0 (salió $RC)" test "$RC" -ne 0

# Instalación completa (sin --comprobar) sin MariaDB: avisa de que omite la BD fx y no invoca mariadb.
home_nuevo mariafull
PATH="$SAFE" bash "$FABRIK_DIR/install.sh" > "$tmp/out-mariafull.log" 2>&1
RC=$?
afirma "instalación completa sin MariaDB: debe avisar con ! de que omite la BD fx" tiene "$tmp/out-mariafull.log" '! +mariadb no instalado; configuración de base de datos fx omitida'
afirma "instalación completa sin MariaDB: no debe invocar mariadb" iguales "$(grep -c 'mariadb' "$FAKE_LOG" || true)" 0
afirma "instalación completa sin MariaDB: no debe crear db.env" test ! -e "$HOME/.config/fabrica/db.env"
afirma "instalación completa sin MariaDB: no debe marcar ✗ la BD fx (salió $RC)" no_tiene "$tmp/out-mariafull.log" '✗ (no se pudo crear fx|usuario fx)'

FABRIK_CONFIG="$tmp/solo-claude.yaml" bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-con-mariadb.log" 2>&1
afirma "con MariaDB: ✓ mariadb" tiene "$tmp/out-con-mariadb.log" '✓ mariadb$'

# ======================================================================
# FIX-SEG-3 AC-2: la BD de los agentes es el MariaDB propio de la fábrica (127.0.0.1:3307).
# install.sh lo inicializa en ~/.local/share/fabrica/mariadb, instala la unidad de usuario y escribe 3307 en db.env.
# Falsos de mariadbd y mariadb-install-db (nunca se toca el MariaDB real ni sus datos).
# ======================================================================
cat > "$BIN/mariadbd" <<'FAKE'
#!/usr/bin/env bash
printf 'mariadbd %s\n' "$*" >> "$FAKE_LOG"
exit 0
FAKE
cat > "$BIN/mariadb-install-db" <<'FAKE'
#!/usr/bin/env bash
printf 'mariadb-install-db %s\n' "$*" >> "$FAKE_LOG"
for a in "$@"; do
  case "$a" in
    --datadir=*) mkdir -p "${a#--datadir=}/mysql" ;;
    --extra-file=*) cp "${a#--extra-file=}" "$FAKE_EXTRA_COPY" ;;
  esac
done
exit 0
FAKE
chmod +x "$BIN/mariadbd" "$BIN/mariadb-install-db"
export FAKE_EXTRA_COPY="$tmp/extra-file.sql"
port_de() { sed -n 's/^FX_DB_PORT=//p' "$1"; }

home_nuevo fxdb
bash "$FABRIK_DIR/install.sh" > "$tmp/out-fxdb.log" 2>&1
RC=$?
DBENV="$HOME/.config/fabrica/db.env"
afirma "AC-2: instalación nueva crea db.env" test -f "$DBENV"
afirma "AC-2: db.env escribe FX_DB_PORT=3307 (el MariaDB de la fábrica), no 3306 (escribió '$(port_de "$DBENV")')" iguales "$(port_de "$DBENV")" 3307
afirma "AC-2: db.env solo legible por el dueño (600)" iguales "$(stat -c %a "$DBENV")" 600
afirma "AC-2: db.env no tiene el puerto 3306" no_tiene "$DBENV" '^FX_DB_PORT=3306'
afirma "AC-2: inicializa el directorio de datos propio" test -d "$HOME/.local/share/fabrica/mariadb/mysql"
afirma "AC-2: mariadb-install-db sin defaults y con el datadir de la fábrica" tiene "$FAKE_LOG" "mariadb-install-db --no-defaults --datadir=$HOME/.local/share/fabrica/mariadb "
afirma "AC-2: el usuario fx se crea con GRANT solo sobre fx_%" grep -qF 'GRANT ALL PRIVILEGES ON `fx\_%`.* TO '"'fx'@'127.0.0.1'" "$FAKE_EXTRA_COPY"
afirma "AC-2: ningún GRANT global (ON *.*)" no_tiene "$FAKE_EXTRA_COPY" 'ON \*\.\*'
afirma "AC-2: el fichero SQL temporal con la contraseña no queda en disco" test -z "$(ls "${TMPDIR:-/tmp}"/fabrica-mariadb-init.* 2>/dev/null)"
UNIT="$HOME/.config/systemd/user/fabrica-mariadb.service"
afirma "AC-2: instala la unidad de usuario fabrica-mariadb.service" test -f "$UNIT"
afirma "AC-2: la unidad escucha en 3307 y solo en 127.0.0.1" tiene "$UNIT" '--port=3307 --bind-address=127\.0\.0\.1'
afirma "AC-2: la unidad usa el mariadbd resuelto en PATH" tiene "$UNIT" "^ExecStart=$BIN/mariadbd "
afirma "AC-2: arranca la unidad con systemctl --user" tiene "$FAKE_LOG" 'systemctl --user enable --now fabrica-mariadb'
afirma "AC-2: el aviso dice que el MariaDB de la fábrica está en 3307" tiene "$tmp/out-fxdb.log" '✓ +fabrica-mariadb en 127\.0\.0\.1:3307'
afirma "AC-2: sin ✗ en el bloque de base de datos (salió $RC)" no_tiene "$tmp/out-fxdb.log" '✗ (no se pudo|fabrica-mariadb)'

# Idempotencia: segunda ejecución no reinicializa los datos ni cambia la contraseña ni el puerto.
PASS1="$(sed -n 's/^FX_DB_PASSWORD=//p' "$DBENV")"
: > "$FAKE_LOG"
bash "$FABRIK_DIR/install.sh" > "$tmp/out-fxdb2.log" 2>&1
afirma "AC-2: reinstalar no reinicializa el MariaDB (no vuelve a llamar a mariadb-install-db)" no_tiene "$FAKE_LOG" 'mariadb-install-db'
afirma "AC-2: reinstalar conserva la contraseña de fx" iguales "$(sed -n 's/^FX_DB_PASSWORD=//p' "$DBENV")" "$PASS1"
afirma "AC-2: reinstalar conserva FX_DB_PORT=3307" iguales "$(port_de "$DBENV")" 3307

# db.env anterior con 3306: se respeta (no se pisa), se avisa y no se monta fabrica-mariadb.
home_nuevo fxdb_viejo
mkdir -p "$HOME/.config/fabrica"
printf 'FX_DB_USER=fx\nFX_DB_PASSWORD=Vieja123\nFX_DB_HOST=127.0.0.1\nFX_DB_PORT=3306\n' > "$HOME/.config/fabrica/db.env"
bash "$FABRIK_DIR/install.sh" > "$tmp/out-fxdb-viejo.log" 2>&1
afirma "AC-2: un db.env con 3306 no se sobrescribe" iguales "$(port_de "$HOME/.config/fabrica/db.env")" 3306
afirma "AC-2: avisa de que los agentes usarán el MariaDB del puerto 3306" tiene "$tmp/out-fxdb-viejo.log" '! +db\.env usa el puerto 3306, no el 3307'
afirma "AC-2: con db.env en 3306 no inicializa el MariaDB de la fábrica" no_tiene "$FAKE_LOG" 'mariadb-install-db'
rm -f "$BIN/mariadbd" "$BIN/mariadb-install-db"

# ======================================================================
# FIX-SEG-3 AC-4: fabrik-importar lee `usuario=` como dato, nunca lo ejecuta (con --seco no escribe nada).
# ======================================================================
home_nuevo imp
AGEKEY="$tmp/imp.key"
age-keygen -o "$AGEKEY" > /dev/null 2>&1
AGEPUB="$(age-keygen -y "$AGEKEY")"
# exporta_con_usuario <fichero.age> <valor de usuario=>
exporta_con_usuario() {
  local stg="$tmp/imp-stg-$RANDOM"
  mkdir -p "$stg/.config/fabrica"
  : > "$stg/.config/fabrica/hola.txt"
  printf 'fecha=hoy\nmaquina=m\nusuario=%s\ncon_logins=0\n' "$2" > "$stg/.fabrik-export.txt"
  tar -C "$stg" -c . | zstd -q | age -r "$AGEPUB" -o "$1"
}
MARCA="$tmp/inyeccion-ejecutada"
exporta_con_usuario "$tmp/malo.age" "\$(touch $MARCA)"
FABRIK_AGE_IDENTITY="$AGEKEY" bash "$FABRIK_DIR/bin/fabrik-importar" "$tmp/malo.age" --seco > "$tmp/out-imp-malo.log" 2>&1
RC=$?
afirma "AC-4: usuario= con \$(…) no ejecuta el comando (existe la marca)" test ! -e "$MARCA"
afirma "AC-4: usuario= con \$(…) se rechaza con ✗ y sale ≠ 0 (salió $RC)" test "$RC" -ne 0
afirma "AC-4: el rechazo dice que el usuario no es válido" tiene "$tmp/out-imp-malo.log" '✗ usuario de origen no válido'
exporta_con_usuario "$tmp/malo2.age" "a;touch $MARCA"
FABRIK_AGE_IDENTITY="$AGEKEY" bash "$FABRIK_DIR/bin/fabrik-importar" "$tmp/malo2.age" --seco > /dev/null 2>&1
afirma "AC-4: usuario= con ; tampoco ejecuta nada" test ! -e "$MARCA"
exporta_con_usuario "$tmp/bueno.age" "ana.lopez-2"
FABRIK_AGE_IDENTITY="$AGEKEY" bash "$FABRIK_DIR/bin/fabrik-importar" "$tmp/bueno.age" --seco > "$tmp/out-imp-bueno.log" 2>&1
RC=$?
afirma "AC-4: un usuario normal se acepta y --seco sale 0 (salió $RC)" iguales "$RC" 0
afirma "AC-4: --seco no escribe nada" tiene "$tmp/out-imp-bueno.log" '\(seco: no se ha escrito nada\)'

# ======================================================================
# API de la propuesta de modelos (unidad)
# ======================================================================
out=$(cd "$FABRIK_DIR" && uv run --with pyyaml python -I -c '
import sys
sys.path.insert(0, "scripts")
import fabrik_config as fc
m, avisos = fc.proponer_modelos({"deepseek", "kimi-coding"})
provs = {v["proveedor"] for r, v in m.items() if r in fc.PREFERENCIAS_ROL}
assert provs == {"kimi-coding"}, provs  # sin permitir_pago, deepseek no se propone
assert m["programador"]["proveedor"] == "kimi-coding", m["programador"]
assert any("orquestador" in a and "sin modelo bueno" in a for a in avisos), avisos
m2, avisos2 = fc.proponer_modelos(set())
assert m2 == {} and len(avisos2) > len(fc.PREFERENCIAS_ROL), (m2, avisos2)
print("PROPUESTA_OK")
')
afirma "propuesta de modelos (API): $out" iguales "$out" PROPUESTA_OK

# ======================================================================
# Pool de modelos (P3): --comprobar valida el esquema y comprueba que el SOUL del orquestador se genera
# ======================================================================
home_nuevo pool
escribe_modelos "$tmp/pool-ok.yaml" claude-subscription-directsdk-experimental claude-sonnet-5-5
cat >> "$tmp/pool-ok.yaml" <<'EOF'
  reserva_final: {proveedor: claude-subscription-directsdk-experimental, modelo: claude-sonnet-5-5}
  pool:
    medio:
      - {proveedor: claude-subscription-directsdk-experimental, modelo: claude-sonnet-5-5, herramientas: true, coste: suscripcion}
EOF
FABRIK_CONFIG="$tmp/pool-ok.yaml" bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-pool-ok.log" 2>&1
RC=$?
afirma "pool válido: --comprobar sale 0 (salió $RC: $(tail -3 "$tmp/out-pool-ok.log"))" iguales "$RC" 0
afirma "pool válido: muestra la validación de la config de modelos" tiene "$tmp/out-pool-ok.log" '✓ configuración de modelos válida'
afirma "pool válido: comprueba que el SOUL del orquestador se genera" tiene "$tmp/out-pool-ok.log" '✓ SOUL del orquestador se genera'
afirma "pool válido: --comprobar no escribe perfiles ni datos" test ! -e "$HOME/.hermes/profiles" -a ! -e "$HOME/.hermes/factory" -a ! -e "$HOME/.config/fabrica"

home_nuevo poolmal
escribe_modelos "$tmp/pool-mal.yaml" claude-subscription-directsdk-experimental claude-sonnet-5-5
cat >> "$tmp/pool-mal.yaml" <<'EOF'
  pool:
    medio:
      - {proveedor: p, modelo: m, herramientas: quizas, coste: gratis}
EOF
FABRIK_CONFIG="$tmp/pool-mal.yaml" bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-pool-mal.log" 2>&1
RC=$?
afirma "pool inválido: --comprobar sale ≠ 0 (salió $RC)" test "$RC" -ne 0
afirma "pool inválido: el mensaje nombra la ruta del error" tiene "$tmp/out-pool-mal.log" 'modelos\.pool\.medio\[0\]\.herramientas'
afirma "pool inválido: --comprobar sigue sin instalar nada" test ! -e "$HOME/.hermes/profiles" -a ! -e "$HOME/.hermes/factory" -a ! -e "$HOME/.config/fabrica"
# La instalación real aborta antes de aplicar perfiles ni crear enlaces.
FABRIK_CONFIG="$tmp/pool-mal.yaml" bash "$FABRIK_DIR/install.sh" > "$tmp/out-pool-mal-real.log" 2>&1
RC=$?
afirma "pool inválido: la instalación real aborta con ≠ 0 (salió $RC)" test "$RC" -ne 0
afirma "pool inválido: la instalación real no aplica perfiles" no_tiene "$tmp/out-pool-mal-real.log" '== Perfiles'
afirma "pool inválido: la instalación real no crea enlaces ni perfiles" test ! -e "$HOME/.hermes/profiles" -a ! -e "$HOME/.hermes/factory/DESIGN.md"

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
