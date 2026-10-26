#!/usr/bin/env bash
# Tests de los consumidores de la config (IMPL-2): install.sh, build_portfolio.py,
# factory-prep/gc, apply_profile_policy.py --seco, memoria (fabrik-memoria y
# memoria_ingest) y ausencia de valores fijos.
# HOME, FABRIK_CONFIG y binarios falsos (hermes, gh, git, mariadb, …): sin efectos reales.
# Usa el pack ficticio tests/fixtures/pack-acme y el pack ejemplo; la integración con packs reales
# vive en packs/<pack>/tests/.
# Uso: bash tests/consumidores_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"
# FABRIK_DATA (lo exporta la shell de los agentes) apuntaría al portfolio real: aislado dentro del HOME temporal.
unset FABRIK_CONFIG FABRIK_DATA

BIN="$tmp/bin"
mkdir -p "$BIN"
export FAKE_LOG="$tmp/fake.log"
export FAKE_GIT_COMMON_DIR="$tmp/git-common"
mkdir -p "$FAKE_GIT_COMMON_DIR/info"
export FAKE_GIT_REMOTE=""
export FAKE_PLUGINS_ENABLED="claude-subscription-directsdk-experimental antigravity-oauth"
export FAKE_HERMES_CALLED="$HOME/hermes_called"
export PATH="$BIN:$PATH"

# --- falsos genéricos: registran «nombre args» y salen 0 ---
for c in php composer mariadb node greptile flock systemctl specify; do
  cat > "$BIN/$c" <<'FAKE'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$FAKE_LOG"
exit 0
FAKE
  chmod +x "$BIN/$c"
done

# gh: registra y sale 0 (auth status, repo list/view → vacío)
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$FAKE_LOG"
exit 0
FAKE
chmod +x "$BIN/gh"

# hermes: registra; `config get plugins.enabled` imprime los plugins; toca centinela
cat > "$BIN/hermes" <<'FAKE'
#!/usr/bin/env bash
touch "$FAKE_HERMES_CALLED"
printf 'hermes %s\n' "$*" >> "$FAKE_LOG"
if [[ "$1" == config && "$2" == get && "$3" == plugins.enabled ]]; then
  printf '%s\n' "$FAKE_PLUGINS_ENABLED"
fi
exit 0
FAKE
chmod +x "$BIN/hermes"

# fabrik: delega en el cargador real (registra la llamada)
cat > "$BIN/fabrik" <<FAKE
#!/usr/bin/env bash
printf 'fabrik %s\n' "\$*" >> "\$FAKE_LOG"
[[ "\${1:-}" == config ]] && shift
exec uv run --with pyyaml python "$FABRIK_DIR/scripts/fabrik_config.py" "\$@"
FAKE
chmod +x "$BIN/fabrik"

# git: registra; show-ref→1, ls-files→1, rev-parse→dir común, remote get-url→$FAKE_GIT_REMOTE
cat > "$BIN/git" <<'FAKE'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  *"show-ref"*) exit 1 ;;
  *"ls-files"*) exit 1 ;;
  *"rev-parse"*) printf '%s\n' "$FAKE_GIT_COMMON_DIR"; exit 0 ;;
  *"remote get-url"*) printf '%s\n' "$FAKE_GIT_REMOTE"; exit 0 ;;
esac
exit 0
FAKE
chmod +x "$BIN/git"

# db.env de la fábrica y ~/.hermes/.env con las claves (para factory-prep/gc e install.sh)
mkdir -p "$HOME/.config/fabrica" "$HOME/.hermes"
cat > "$HOME/.config/fabrica/db.env" <<EOF
FX_DB_USER=fx
FX_DB_PASSWORD=testpw
FX_DB_HOST=127.0.0.1
FX_DB_PORT=3306
EOF
cat > "$HOME/.hermes/.env" <<EOF
ANTHROPIC_API_KEY=test
EOF

cat > "$tmp/personal-acme.yaml" <<EOF
packs:
  - $FABRIK_DIR/tests/fixtures/pack-acme
EOF
cat > "$tmp/personal-ejemplo.yaml" <<EOF
packs:
  - $FABRIK_DIR/packs/ejemplo
EOF

# ---------- AC-5a: install.sh --comprobar con el pack fixture ----------
: > "$FAKE_LOG"
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-acme.yaml" PATH="$BIN:$PATH" \
  bash "$FABRIK_DIR/install.sh" --comprobar > "$tmp/out-comprobar" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fallo "AC-5 --comprobar exit $RC"
elif ! grep -q 'Todo listo' "$tmp/out-comprobar"; then
  fallo "AC-5 --comprobar sin 'Todo listo'"
elif ! grep -q 'gh autenticado' "$tmp/out-comprobar"; then
  fallo "AC-5 --comprobar sin comprobación de gh"
elif grep -q 'DEEPSEEK_API_KEY' "$tmp/out-comprobar"; then
  fallo "AC-5 --comprobar exige DEEPSEEK_API_KEY (D5: sin DeepSeek, como en main)"
elif ! grep -q 'ANTHROPIC_API_KEY en' "$tmp/out-comprobar"; then
  fallo "AC-5 --comprobar sin ANTHROPIC_API_KEY (proveedor del motor genérico)"
elif [ "$(grep -c 'hermes config get plugins.enabled' "$FAKE_LOG")" -ne 1 ]; then
  fallo "AC-5 --comprobar plugins.enabled: $(grep -c 'hermes config get plugins.enabled' "$FAKE_LOG") llamadas (esperado 1: antigravity-oauth de la reserva final del pack; anthropic no es plugin)"
elif grep -q 'boards create' "$FAKE_LOG"; then
  fallo "AC-5 --comprobar creó tableros Kanban (debe ser solo lectura)"
elif grep -q 'hermes config set' "$FAKE_LOG"; then
  fallo "AC-5 --comprobar mutó la config de hermes (debe ser solo lectura)"
else
  ok_
fi

# ---------- AC-5b: los tableros que se crearían son los del pack fixture ----------
: > "$FAKE_LOG"
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-acme.yaml" PATH="$BIN:$PATH" \
  bash "$FABRIK_DIR/install.sh" > "$tmp/out-install" 2>&1
faltan=""
for slug in alfa beta gamma delta epsilon herramienta zeta-drones acme-ops; do
  grep -q "boards create $slug " "$FAKE_LOG" || faltan="$faltan $slug"
done
if [ -n "$faltan" ]; then
  fallo "AC-5 tableros no creados:$faltan"
else
  ok_
fi

# ---------- AC-6: build_portfolio consulta owners + extra_repos de la config ----------
: > "$FAKE_LOG"
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-acme.yaml" PATH="$BIN:$PATH" \
  uv run --with pyyaml python "$FABRIK_DIR/scripts/build_portfolio.py" >/dev/null 2>&1
if ! grep -q 'repo list acme-org' "$FAKE_LOG"; then
  fallo "AC-6 fixture no consulta el owner acme-org"
elif ! grep -q 'repo view acme-user/herramienta' "$FAKE_LOG"; then
  fallo "AC-6 fixture no consulta extra_repos acme-user/herramienta"
else
  ok_
fi

# El caso anterior dejó un portfolio de acme-org: es de otra org y la guarda de build_portfolio no lo pisaría.
rm -f "$HOME/.hermes/factory/portfolio.yaml"
: > "$FAKE_LOG"
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-ejemplo.yaml" PATH="$BIN:$PATH" \
  uv run --with pyyaml python "$FABRIK_DIR/scripts/build_portfolio.py" >/dev/null 2>&1
if ! grep -q 'repo list acme' "$FAKE_LOG"; then
  fallo "AC-6 ejemplo no consulta el owner acme"
elif grep -q 'phpunit-replay' "$FAKE_LOG"; then
  fallo "AC-6 ejemplo consulta extra_repos que no tiene"
else
  ok_
fi

# ---------- AC-7: factory-prep/gc toman owner y base de la config, respetan FX_ORG ----------
export FX_SRC_ROOT="$tmp/src"
mkdir -p "$FX_SRC_ROOT"

: > "$FAKE_LOG"
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-ejemplo.yaml" PATH="$BIN:$PATH" \
  FX_WT="$tmp/wt" FX_SRC_ROOT="$FX_SRC_ROOT" \
  bash "$FABRIK_DIR/bin/factory-prep" repo-a slug-b > "$tmp/out-prep1" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fallo "AC-7 prep exit $RC: $(tail -3 "$tmp/out-prep1")"
elif ! grep -q 'git@github.com:acme/repo-a.git' "$FAKE_LOG"; then
  fallo "AC-7 prep no usa el owner acme de la config"
elif ! grep -q 'origin/main' "$FAKE_LOG"; then
  fallo "AC-7 prep no usa la base main de la config"
else
  ok_
fi

: > "$FAKE_LOG"
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-ejemplo.yaml" PATH="$BIN:$PATH" \
  FX_WT="$tmp/wt2" FX_SRC_ROOT="$FX_SRC_ROOT" FX_ORG=override-org \
  bash "$FABRIK_DIR/bin/factory-prep" repo-a slug-b > "$tmp/out-prep2" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fallo "AC-7 prep FX_ORG exit $RC: $(tail -3 "$tmp/out-prep2")"
elif ! grep -q 'git@github.com:override-org/repo-a.git' "$FAKE_LOG"; then
  fallo "AC-7 prep no respeta FX_ORG (override-org)"
else
  ok_
fi

mkdir -p "$tmp/wt-gc/repo-a/slug-b/.factory"
printf 'DB_DATABASE=fx_repo_a_slug_b\n' > "$tmp/wt-gc/repo-a/slug-b/.factory/env"
: > "$FAKE_LOG"
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-ejemplo.yaml" PATH="$BIN:$PATH" FX_WT="$tmp/wt-gc" \
  bash "$FABRIK_DIR/bin/factory-gc" --seco > "$tmp/out-gc" 2>&1
if ! grep -q 'pr list -R acme/repo-a' "$FAKE_LOG"; then
  fallo "AC-7 gc no usa el owner acme de la config"
else
  ok_
fi

: > "$FAKE_LOG"
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-ejemplo.yaml" PATH="$BIN:$PATH" FX_WT="$tmp/wt-gc" FX_ORG=override-org \
  bash "$FABRIK_DIR/bin/factory-gc" --seco > "$tmp/out-gc2" 2>&1
if ! grep -q 'pr list -R override-org/repo-a' "$FAKE_LOG"; then
  fallo "AC-7 gc no respeta FX_ORG (override-org)"
else
  ok_
fi

# AC-7 (config rota): prep y gc abortan con un mensaje claro en vez de seguir con ORG/BASEBR vacíos
printf 'packs: [\n' > "$tmp/personal-roto2.yaml"
: > "$FAKE_LOG"
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-roto2.yaml" PATH="$BIN:$PATH" FX_WT="$tmp/wt3" FX_SRC_ROOT="$FX_SRC_ROOT" \
  bash "$FABRIK_DIR/bin/factory-prep" repo-a slug-b > "$tmp/out-prep3" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
  fallo "AC-7 prep con config rota no abortó"
elif ! grep -q 'no pude determinar el propietario' "$tmp/out-prep3"; then
  fallo "AC-7 prep con config rota sin mensaje claro: $(tail -2 "$tmp/out-prep3")"
elif grep -q '^git ' "$FAKE_LOG"; then
  fallo "AC-7 prep con config rota llegó a ejecutar git"
else
  ok_
fi

: > "$FAKE_LOG"
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-roto2.yaml" PATH="$BIN:$PATH" FX_WT="$tmp/wt-gc" \
  bash "$FABRIK_DIR/bin/factory-gc" --seco > "$tmp/out-gc3" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
  fallo "AC-7 gc con config rota no abortó"
elif ! grep -q 'no pude determinar el propietario' "$tmp/out-gc3"; then
  fallo "AC-7 gc con config rota sin mensaje claro: $(tail -2 "$tmp/out-gc3")"
elif grep -q '^gh ' "$FAKE_LOG"; then
  fallo "AC-7 gc con config rota consultó gh"
else
  ok_
fi

# ---------- AC-8: apply_profile_policy.py --seco ----------
rm -f "$FAKE_HERMES_CALLED"
: > "$FAKE_LOG"
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-acme.yaml" PATH="$BIN:$PATH" \
  uv run --with pyyaml python "$FABRIK_DIR/scripts/apply_profile_policy.py" --seco > "$tmp/out-seco" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fallo "AC-8 --seco exit $RC: $(tail -3 "$tmp/out-seco")"
elif [ -e "$FAKE_HERMES_CALLED" ]; then
  fallo "AC-8 --seco llamó a hermes"
elif grep -q '^hermes ' "$FAKE_LOG"; then
  fallo "AC-8 --seco registró llamadas a hermes: $(grep '^hermes ' "$FAKE_LOG")"
elif ! grep -q 'anthropic/claude-sonnet-5-5' "$tmp/out-seco"; then
  fallo "AC-8 --seco no imprime programador anthropic/claude-sonnet-5-5"
elif ! grep -q 'anthropic/claude-opus-5-5' "$tmp/out-seco"; then
  fallo "AC-8 --seco no imprime orquestador anthropic/claude-opus-5-5"
else
  ok_
fi

# AC-6 golden (D-P4): con el pack fixture y sin modelos personales, `--seco` imprime EXACTAMENTE los modelos genéricos del motor
# (solo anthropic, sin reserva por rol) más la reserva final del pack. Si un merge los pisa, este test sale en rojo. Los 7 roles, en orden.
cat > "$tmp/seco-golden" <<'GOLD'
orquestador  anthropic/claude-opus-5-5 → reserva antigravity-oauth/acme-reserva · compacta 200k
explorador   anthropic/claude-sonnet-5-5 → reserva antigravity-oauth/acme-reserva · compacta 300k
programador  anthropic/claude-sonnet-5-5 → reserva antigravity-oauth/acme-reserva · compacta 160k
tester       anthropic/claude-sonnet-5-5 → reserva antigravity-oauth/acme-reserva · compacta 160k
revisor      anthropic/claude-opus-5-5 → reserva antigravity-oauth/acme-reserva · compacta 200k
seguridad    anthropic/claude-opus-5-5 → reserva antigravity-oauth/acme-reserva · compacta 200k
docs         anthropic/claude-sonnet-5-5 → reserva antigravity-oauth/acme-reserva · compacta 300k
GOLD
if ! diff -u "$tmp/seco-golden" "$tmp/out-seco" > "$tmp/seco-diff"; then
  fallo "AC-6 golden: --seco con el pack real difiere de la tabla de la decisión 3: $(head -8 "$tmp/seco-diff" | tr '\n' '|')"
elif grep -qi deepseek "$tmp/out-seco"; then
  fallo "AC-6 golden: --seco con el pack real menciona DeepSeek"
else
  ok_
fi

cat > "$tmp/personal-override.yaml" <<EOF
packs:
  - $FABRIK_DIR/tests/fixtures/pack-acme
modelos:
  programador:
    proveedor: mi-prov
    modelo: mi-modelo
EOF
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-override.yaml" PATH="$BIN:$PATH" \
  uv run --with pyyaml python "$FABRIK_DIR/scripts/apply_profile_policy.py" --seco > "$tmp/out-seco-override" 2>&1
if ! grep -q 'mi-prov/mi-modelo' "$tmp/out-seco-override"; then
  fallo "AC-8 la config personal no sobrescribe el modelo del rol"
else
  ok_
fi

# ---------- AC-5: apply_profile_policy.py aplica reserva a fallback_providers ----------
# Caso 1: dict (forma antigua)
: > "$FAKE_LOG"
cat > "$tmp/ac5-dict.yaml" <<EOF
packs: []
modelos:
  tester:
    proveedor: prov-a
    modelo: mod-a
    reserva:
      proveedor: prov-b
      modelo: mod-b
EOF
env HOME="$HOME" FABRIK_CONFIG="$tmp/ac5-dict.yaml" PATH="$BIN:$PATH" \
  uv run --with pyyaml python "$FABRIK_DIR/scripts/apply_profile_policy.py" tester > "$tmp/out-ac5-dict" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fallo "AC-5 dict exit $RC: $(tail -3 "$tmp/out-ac5-dict")"
elif ! grep -qF 'hermes -p tester config set fallback_providers [{"provider": "prov-b", "model": "mod-b"}]' "$FAKE_LOG"; then
  fallo "AC-5 dict no registró fallback_providers esperado: $(grep 'fallback_providers' "$FAKE_LOG")"
else
  ok_
fi

# Caso 2: lista de 2 reservas ordenada
: > "$FAKE_LOG"
cat > "$tmp/ac5-lista2.yaml" <<EOF
packs: []
modelos:
  tester:
    proveedor: prov-a
    modelo: mod-a
    reserva:
      - proveedor: prov-r1
        modelo: mod-r1
      - proveedor: prov-r2
        modelo: mod-r2
EOF
env HOME="$HOME" FABRIK_CONFIG="$tmp/ac5-lista2.yaml" PATH="$BIN:$PATH" \
  uv run --with pyyaml python "$FABRIK_DIR/scripts/apply_profile_policy.py" tester > "$tmp/out-ac5-lista2" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fallo "AC-5 lista de 2 exit $RC: $(tail -3 "$tmp/out-ac5-lista2")"
elif ! grep -qF 'hermes -p tester config set fallback_providers [{"provider": "prov-r1", "model": "mod-r1"}, {"provider": "prov-r2", "model": "mod-r2"}]' "$FAKE_LOG"; then
  fallo "AC-5 lista de 2 no registró fallback_providers esperado: $(grep 'fallback_providers' "$FAKE_LOG")"
else
  ok_
fi

# Caso 3: null o [] (sin reserva)
: > "$FAKE_LOG"
cat > "$tmp/ac5-null.yaml" <<EOF
packs: []
modelos:
  tester:
    proveedor: prov-a
    modelo: mod-a
    reserva: null
EOF
env HOME="$HOME" FABRIK_CONFIG="$tmp/ac5-null.yaml" PATH="$BIN:$PATH" \
  uv run --with pyyaml python "$FABRIK_DIR/scripts/apply_profile_policy.py" tester > "$tmp/out-ac5-null" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fallo "AC-5 null exit $RC: $(tail -3 "$tmp/out-ac5-null")"
elif ! grep -qF 'hermes -p tester config set fallback_providers []' "$FAKE_LOG"; then
  fallo "AC-5 null no registró fallback_providers []: $(grep 'fallback_providers' "$FAKE_LOG")"
else
  ok_
fi

# Caso 3b: --seco con rol sin reserva imprime exactamente «→ sin reserva»
env HOME="$HOME" FABRIK_CONFIG="$tmp/ac5-null.yaml" PATH="$BIN:$PATH" \
  uv run --with pyyaml python "$FABRIK_DIR/scripts/apply_profile_policy.py" --seco tester > "$tmp/out-ac5-seco-nulo" 2>&1
if ! grep -qF '→ sin reserva' "$tmp/out-ac5-seco-nulo"; then
  fallo "AC-5 --seco sin reserva: $(cat "$tmp/out-ac5-seco-nulo")"
else
  ok_
fi

# Caso 4: entrada sin proveedor (hereda el del principal)
: > "$FAKE_LOG"
cat > "$tmp/ac5-sinprov.yaml" <<EOF
packs: []
modelos:
  tester:
    proveedor: prov-a
    modelo: mod-a
    reserva:
      - modelo: mod-sin-prov
EOF
env HOME="$HOME" FABRIK_CONFIG="$tmp/ac5-sinprov.yaml" PATH="$BIN:$PATH" \
  uv run --with pyyaml python "$FABRIK_DIR/scripts/apply_profile_policy.py" tester > "$tmp/out-ac5-sinprov" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fallo "AC-5 sin proveedor exit $RC: $(tail -3 "$tmp/out-ac5-sinprov")"
elif ! grep -qF 'hermes -p tester config set fallback_providers [{"provider": "prov-a", "model": "mod-sin-prov"}]' "$FAKE_LOG"; then
  fallo "AC-5 sin proveedor no heredó el principal en fallback_providers: $(grep 'fallback_providers' "$FAKE_LOG")"
else
  ok_
fi

# Caso 5: fusión de capas en la que la personal reemplaza la lista del motor
: > "$FAKE_LOG"
cat > "$tmp/ac5-fusion.yaml" <<EOF
packs: []
modelos:
  programador:
    reserva:
      - proveedor: prov-override
        modelo: mod-override
EOF
env HOME="$HOME" FABRIK_CONFIG="$tmp/ac5-fusion.yaml" PATH="$BIN:$PATH" \
  uv run --with pyyaml python "$FABRIK_DIR/scripts/apply_profile_policy.py" programador > "$tmp/out-ac5-fusion" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fallo "AC-5 fusion exit $RC: $(tail -3 "$tmp/out-ac5-fusion")"
elif ! grep -qF 'hermes -p programador config set fallback_providers [{"provider": "prov-override", "model": "mod-override"}]' "$FAKE_LOG"; then
  fallo "AC-5 fusion no reemplazó la lista de reserva: $(grep 'fallback_providers' "$FAKE_LOG")"
else
  ok_
fi

# Caso 6: si hermes falla al fijar fallback_providers, apply aborta con error claro (exit != 0)
: > "$FAKE_LOG"
mkdir -p "$tmp/bin-falla"
cat > "$tmp/bin-falla/hermes" <<'FAKE'
#!/usr/bin/env bash
printf 'hermes %s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  *"config set fallback_providers"*) echo "boom de hermes" >&2; exit 1 ;;
esac
exit 0
FAKE
chmod +x "$tmp/bin-falla/hermes"
env HOME="$HOME" FABRIK_CONFIG="$tmp/ac5-lista2.yaml" PATH="$tmp/bin-falla:$BIN:$PATH" \
  uv run --with pyyaml python "$FABRIK_DIR/scripts/apply_profile_policy.py" tester > "$tmp/out-ac5-falla" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
  fallo "AC-5 fallo de hermes: exit 0 pese al fallo de config set fallback_providers"
elif ! grep -q "fallback_providers" "$tmp/out-ac5-falla" || ! grep -q "boom de hermes" "$tmp/out-ac5-falla"; then
  fallo "AC-5 fallo de hermes sin error claro: $(tail -3 "$tmp/out-ac5-falla")"
else
  ok_
fi

# Caso 7: rol con proveedor vacío y reserva sin proveedor → la entrada incompleta se descarta (fallback [])
: > "$FAKE_LOG"
cat > "$tmp/ac7-noprov.yaml" <<EOF
packs: []
modelos:
  tester:
    proveedor: null
    modelo: mod-a
    reserva:
      - modelo: mod-b
EOF
env HOME="$HOME" FABRIK_CONFIG="$tmp/ac7-noprov.yaml" PATH="$BIN:$PATH" \
  uv run --with pyyaml python "$FABRIK_DIR/scripts/apply_profile_policy.py" tester > "$tmp/out-ac7" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fallo "AC-5 entrada sin proveedor exit $RC: $(tail -3 "$tmp/out-ac7")"
elif ! grep -qF 'hermes -p tester config set fallback_providers []' "$FAKE_LOG"; then
  fallo "AC-5 entrada sin proveedor no descartó la reserva incompleta: $(grep 'fallback_providers' "$FAKE_LOG")"
else
  ok_
fi

# ---------- Consumo de `memoria`: bin/fabrik-memoria y scripts/memoria_ingest.py ----------
# Servidor HTTP de juguete: registra «METODO ruta» + cuerpo y responde 200 {}.
cat > "$tmp/memoria_server.py" <<'PY'
import http.server, pathlib, sys
log = pathlib.Path(sys.argv[1]); port = pathlib.Path(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def _r(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        with log.open("a", encoding="utf-8") as f:
            f.write(f"{self.command} {self.path}\n{body}\n--\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")
    do_GET = do_PUT = do_POST = _r
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
port.write_text(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$tmp/memoria_server.py" "$tmp/memoria_http.log" "$tmp/memoria_port" &
MEMORIA_PID=$!
for _ in $(seq 1 50); do [ -s "$tmp/memoria_port" ] && break; sleep 0.1; done

if [ ! -s "$tmp/memoria_port" ]; then
  fallo "MEM servidor de juguete no arrancó"
else
  MEMORIA_URL="http://127.0.0.1:$(cat "$tmp/memoria_port")"

  # MEM-1: fabrik-memoria estado con pack fixture → GET al banco acme-fabrica de la config
  : > "$tmp/memoria_http.log"
  env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-acme.yaml" PATH="$BIN:$PATH" \
    FABRIK_MEMORIA_URL="$MEMORIA_URL" \
    python3 "$FABRIK_DIR/bin/fabrik-memoria" estado > "$tmp/out-mem1" 2>&1
  RC=$?
  if [ "$RC" -ne 0 ]; then
    fallo "MEM-1 fabrik-memoria estado exit $RC: $(tail -3 "$tmp/out-mem1")"
  elif ! grep -q "GET /v1/default/banks/acme-fabrica/stats" "$tmp/memoria_http.log"; then
    fallo "MEM-1 fabrik-memoria no usa el banco acme-fabrica de la config: $(head -1 "$tmp/memoria_http.log")"
  else
    ok_
  fi

  # MEM-6: el cargador se resuelve por ruta relativa al script, NO por PATH: un `fabrik` ajeno que mienta no
  # debe influir, y sin `fabrik` en PATH sigue saliendo el banco de la config.
  mkdir -p "$tmp/bin-mentiroso"
  printf '#!/usr/bin/env bash\necho banco-ajeno\n' > "$tmp/bin-mentiroso/fabrik"
  chmod +x "$tmp/bin-mentiroso/fabrik"
  : > "$tmp/memoria_http.log"
  env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-acme.yaml" PATH="$tmp/bin-mentiroso:$PATH" \
    FABRIK_MEMORIA_URL="$MEMORIA_URL" \
    python3 "$FABRIK_DIR/bin/fabrik-memoria" estado > "$tmp/out-mem6" 2>&1
  RC=$?
  if [ "$RC" -ne 0 ]; then
    fallo "MEM-6 fabrik-memoria estado exit $RC: $(tail -3 "$tmp/out-mem6")"
  elif ! grep -q "GET /v1/default/banks/acme-fabrica/stats" "$tmp/memoria_http.log"; then
    fallo "MEM-6 fabrik-memoria usó un fabrik de PATH en vez del del repo: $(head -1 "$tmp/memoria_http.log")"
  else
    ok_
  fi

  # MEM-7: si la config falla (YAML inválido), avisa por stderr (no cae en silencio al banco por defecto)
  printf 'packs: [\n' > "$tmp/personal-roto.yaml"
  : > "$tmp/memoria_http.log"
  env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-roto.yaml" PATH="$BIN:$PATH" \
    FABRIK_MEMORIA_URL="$MEMORIA_URL" \
    python3 "$FABRIK_DIR/bin/fabrik-memoria" estado > "$tmp/out-mem7" 2> "$tmp/err-mem7"
  if ! grep -q "aviso: no pude leer 'memoria.banco'" "$tmp/err-mem7"; then
    fallo "MEM-7 sin aviso por stderr cuando la config falla: $(head -3 "$tmp/err-mem7")"
  else
    ok_
  fi

  # MEM-2: con pack ejemplo → banco ejemplo
  : > "$tmp/memoria_http.log"
  env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-ejemplo.yaml" PATH="$BIN:$PATH" \
    FABRIK_MEMORIA_URL="$MEMORIA_URL" \
    python3 "$FABRIK_DIR/bin/fabrik-memoria" estado > "$tmp/out-mem2" 2>&1
  RC=$?
  if [ "$RC" -ne 0 ]; then
    fallo "MEM-2 fabrik-memoria estado exit $RC: $(tail -3 "$tmp/out-mem2")"
  elif ! grep -q "GET /v1/default/banks/ejemplo/stats" "$tmp/memoria_http.log"; then
    fallo "MEM-2 fabrik-memoria no usa el banco ejemplo de la config: $(head -1 "$tmp/memoria_http.log")"
  else
    ok_
  fi

  # MEM-3: FABRIK_MEMORIA_BANK pisa la config
  : > "$tmp/memoria_http.log"
  env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-acme.yaml" PATH="$BIN:$PATH" \
    FABRIK_MEMORIA_URL="$MEMORIA_URL" FABRIK_MEMORIA_BANK=banco-propio \
    python3 "$FABRIK_DIR/bin/fabrik-memoria" estado > "$tmp/out-mem3" 2>&1
  RC=$?
  if [ "$RC" -ne 0 ]; then
    fallo "MEM-3 fabrik-memoria estado exit $RC: $(tail -3 "$tmp/out-mem3")"
  elif ! grep -q "GET /v1/default/banks/banco-propio/stats" "$tmp/memoria_http.log"; then
    fallo "MEM-3 FABRIK_MEMORIA_BANK no pisa el banco de la config"
  else
    ok_
  fi

  # MEM-4: memoria_ingest.py banco con pack fixture → PUT con nombre y descripción de la config
  : > "$tmp/memoria_http.log"
  env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-acme.yaml" FABRIK_MEMORIA_URL="$MEMORIA_URL" \
    uv run --with pyyaml python "$FABRIK_DIR/scripts/memoria_ingest.py" banco > "$tmp/out-mem4" 2>&1
  RC=$?
  if [ "$RC" -ne 0 ]; then
    fallo "MEM-4 memoria_ingest banco exit $RC: $(tail -3 "$tmp/out-mem4")"
  elif ! grep -q "PUT /v1/default/banks/acme-fabrica" "$tmp/memoria_http.log"; then
    fallo "MEM-4 memoria_ingest no crea el banco acme-fabrica de la config"
  elif ! grep -qF '"name": "Memoria de la f\u00e1brica Acme"' "$tmp/memoria_http.log"; then
    fallo "MEM-4 memoria_ingest no envía el nombre del banco de la config"
  elif ! grep -qF '"mission": "Memoria t\u00e9cnica compartida' "$tmp/memoria_http.log"; then
    fallo "MEM-4 memoria_ingest no envía la descripción del banco de la config"
  else
    ok_
  fi

  # MEM-5: con pack ejemplo → banco ejemplo con sus valores
  : > "$tmp/memoria_http.log"
  env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-ejemplo.yaml" FABRIK_MEMORIA_URL="$MEMORIA_URL" \
    uv run --with pyyaml python "$FABRIK_DIR/scripts/memoria_ingest.py" banco > "$tmp/out-mem5" 2>&1
  RC=$?
  if [ "$RC" -ne 0 ]; then
    fallo "MEM-5 memoria_ingest banco exit $RC: $(tail -3 "$tmp/out-mem5")"
  elif ! grep -q "PUT /v1/default/banks/ejemplo" "$tmp/memoria_http.log"; then
    fallo "MEM-5 memoria_ingest no crea el banco ejemplo de la config"
  elif ! grep -qF '"name": "Memoria de ejemplo"' "$tmp/memoria_http.log"; then
    fallo "MEM-5 memoria_ingest no envía el nombre del banco ejemplo"
  else
    ok_
  fi
fi
kill "$MEMORIA_PID" 2>/dev/null || true

# ---------- Pool de modelos (P3): SOUL del orquestador y cadena de fallback ----------
APPLY="$FABRIK_DIR/scripts/apply_profile_policy.py"
ROLES_POOL=(orquestador explorador programador tester revisor seguridad docs)
soul_orq() { # $1 config → SOUL del orquestador por stdout (HOME temporal, perfil pre-creado, sin hermes)
  mkdir -p "$HOME/.hermes/profiles/orquestador"
  : > "$HOME/.hermes/profiles/orquestador/SOUL.md"
  FABRIK_CONFIG="$1" uv run --with pyyaml python "$APPLY" --solo-soul orquestador > "$tmp/out-soul" 2>&1 || return 1
  cat "$HOME/.hermes/profiles/orquestador/SOUL.md"
}

# a) pack fixture con permitir_pago: true → la tabla trae los niveles con entradas y el de pago entra en la tabla
if soul_orq "$tmp/personal-acme.yaml" > "$tmp/soul-acme"; then
  if ! grep -qF '| Nivel | Cuándo | Modelos (proveedor) |' "$tmp/soul-acme"; then fallo "POOL-3 acme: falta la cabecera de la tabla"
  elif ! grep -qF '`acme-ligero` (`antigravity-oauth`) (sin herramientas)' "$tmp/soul-acme"; then fallo "POOL-3 acme: ligero sin «(sin herramientas)»"
  elif ! grep -qF '`acme-medio` (`antigravity-oauth`) · `acme-medio-pago` (`antigravity-oauth`)' "$tmp/soul-acme"; then fallo "POOL-3 acme: con permitir_pago el de pago debe estar en la tabla"
  elif grep -qF '| critico |' "$tmp/soul-acme"; then fallo "POOL-3 acme: salió un nivel sin entradas (critico)"
  elif grep -qF 'De pago, solo si el humano lo pide' "$tmp/soul-acme"; then fallo "POOL-3 acme: con permitir_pago no debe haber línea «De pago…»"
  elif ! grep -qF '`acme-reserva` (`antigravity-oauth`)' "$tmp/soul-acme"; then fallo "POOL-3 acme: falta la reserva final"
  elif grep -q '{{' "$tmp/soul-acme"; then fallo "POOL-3 acme: variables sin sustituir"
  else ok_; fi
else
  fallo "POOL-3 acme: no se pudo generar el SOUL: $(cat "$tmp/out-soul")"
fi

# b) pack ejemplo: sin pool → «Sin pool configurado…», reserva «ninguna» y ningún modelo concreto
if soul_orq "$tmp/personal-ejemplo.yaml" > "$tmp/soul-ejemplo"; then
  if ! grep -qF 'Sin pool configurado: usa el modelo del perfil.' "$tmp/soul-ejemplo"; then fallo "POOL-3 ejemplo: falta «Sin pool configurado…»"
  elif grep -qF '| Nivel |' "$tmp/soul-ejemplo"; then fallo "POOL-3 ejemplo: no debería haber tabla"
  elif grep -qE 'claude-opus|claude-sonnet|gemini-3\.8|kimi-for-coding|deepseek' "$tmp/soul-ejemplo"; then fallo "POOL-3 ejemplo: el SOUL menciona modelos concretos"
  else ok_; fi
else
  fallo "POOL-3 ejemplo: no se pudo generar el SOUL: $(cat "$tmp/out-soul")"
fi

# c) packs: [] no recurre a ejemplo ni inventa pool (el pool sale vacío)
printf 'packs: []\n' > "$tmp/personal-vacio.yaml"
if soul_orq "$tmp/personal-vacio.yaml" | grep -qF 'Sin pool configurado: usa el modelo del perfil.'; then ok_; else fallo "POOL-3 packs vacíos: debe decir «Sin pool configurado…»"; fi

# d) la plantilla genérica del orquestador no lleva modelos ni proveedores escritos a mano en la sección del pool
seccion="$(sed -n '/^## Modelo por tarjeta: eliges del pool/,/^## Visibilidad/p' "$FABRIK_DIR/profiles/orquestador.md")"
if [ -z "$seccion" ]; then fallo "POOL-3 plantilla: falta la sección «## Modelo por tarjeta: eliges del pool»"
elif printf '%s' "$seccion" | grep -qiE 'claude|opus|sonnet|gemini|kimi|deepseek|anthropic|antigravity'; then fallo "POOL-3 plantilla: la sección lleva nombres de modelo/proveedor"
elif ! printf '%s' "$seccion" | grep -qF '{{pool_modelos}}' || ! printf '%s' "$seccion" | grep -qF '{{reserva_final}}'; then fallo "POOL-3 plantilla: faltan {{pool_modelos}} o {{reserva_final}}"
elif ! printf '%s' "$seccion" | grep -qF 'fabrik-cupos' || ! printf '%s' "$seccion" | grep -qF 'set-model'; then fallo "POOL-3 plantilla: faltan fabrik-cupos o set-model"
else ok_; fi
if grep -qF 'model=<modelo>, provider=<proveedor>' "$FABRIK_DIR/profiles/orquestador.md"; then ok_; else fallo "POOL-3 plantilla: kanban_create sin model/provider"; fi

# e) --seco: la cadena de cada rol termina en reserva_final, sin duplicados (con el pack fixture)
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-acme.yaml" uv run --with pyyaml python "$APPLY" --seco > "$tmp/out-seco-final" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then fallo "POOL-3 --seco exit $RC: $(tail -3 "$tmp/out-seco-final")"
else
  malos=""
  for r in "${ROLES_POOL[@]}"; do
    l="$(grep "^$r " "$tmp/out-seco-final")"
    [ -n "$l" ] || { malos="$malos $r(sin línea)"; continue; }
    cadena="${l%% · compacta*}"
    [ "$(printf '%s' "$cadena" | grep -o 'antigravity-oauth/acme-reserva' | wc -l)" -eq 1 ] || malos="$malos $r(reserva_final repetida o ausente)"
    case "$cadena" in *"antigravity-oauth/acme-reserva") ;; *) malos="$malos $r(no termina en reserva_final)";; esac
  done
  [ -z "$malos" ] && ok_ || fallo "POOL-3 --seco:$malos"
fi
if grep -q '^pool \|^reserva_final \|^permitir_pago ' "$tmp/out-seco-final"; then fallo "POOL-3 --seco: pool/reserva_final/permitir_pago salen como roles"; else ok_; fi

# f) reserva_final ya en medio de la cadena → se quita de ahí y queda solo al final; si es el principal, no se añade
cat > "$tmp/personal-medio.yaml" <<EOF
packs:
  - $FABRIK_DIR/tests/fixtures/pack-acme
modelos:
  tester:
    proveedor: p1
    modelo: m1
    reserva:
      - {proveedor: antigravity-oauth, modelo: acme-reserva}
      - {proveedor: p2, modelo: m2}
  docs:
    proveedor: antigravity-oauth
    modelo: acme-reserva
    reserva: [{proveedor: p2, modelo: m2}]
EOF
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-medio.yaml" uv run --with pyyaml python "$APPLY" --seco tester docs > "$tmp/out-seco-medio" 2>&1
if [ "$(grep '^tester ' "$tmp/out-seco-medio" | sed 's/ · compacta.*//')" != "tester       p1/m1 → reserva p2/m2 → antigravity-oauth/acme-reserva" ]; then
  fallo "POOL-3 reserva_final en medio: $(grep '^tester ' "$tmp/out-seco-medio")"
elif [ "$(grep '^docs ' "$tmp/out-seco-medio" | sed 's/ · compacta.*//')" != "docs         antigravity-oauth/acme-reserva → reserva p2/m2" ]; then
  fallo "POOL-3 reserva_final = modelo principal: $(grep '^docs ' "$tmp/out-seco-medio")"
else ok_; fi

# g) fallback_providers del apply (hermes falso): reservas del rol + reserva_final al final
: > "$FAKE_LOG"
env HOME="$HOME" FABRIK_CONFIG="$tmp/personal-medio.yaml" PATH="$BIN:$PATH" \
  uv run --with pyyaml python "$APPLY" tester > "$tmp/out-apply-final" 2>&1
fb="$(grep 'hermes -p tester config set fallback_providers' "$FAKE_LOG")"
if [ "$fb" != 'hermes -p tester config set fallback_providers [{"provider": "p2", "model": "m2"}, {"provider": "antigravity-oauth", "model": "acme-reserva"}]' ]; then
  fallo "POOL-3 fallback_providers: $fb"
else ok_; fi

# ---------- AC-9: sin valores fijos en bin/, scripts/ e install.sh ----------
# modelos concretos: en el motor solo viven como defaults de config, no en scripts
PROHIBIDO='claude-opus|claude-sonnet|gemini-3\.8|kimi-for-coding|deepseek-v4|deepseek-flash|claude-subscription-directsdk-experimental|antigravity-oauth'
# + todo lo privado de los packs reales (excepto ejemplo): términos de su denylist y sus valores de
# config (owners, banco de memoria), leídos en ejecución para no repetirlos aquí
escapar() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|/]/\\&/g'; }
for p in "$FABRIK_DIR"/packs/*/; do
  [ "$(basename "$p")" = ejemplo ] && continue
  if [ -f "$p/denylist.txt" ]; then
    while IFS= read -r t; do
      t="${t%%#*}"; t="$(printf '%s' "$t" | tr -d '\r' | xargs 2>/dev/null || true)"
      [ -n "$t" ] && PROHIBIDO="$PROHIBIDO|$(escapar "$t")"
    done < "$p/denylist.txt"
  fi
  printf 'packs:\n  - %s\n' "${p%/}" > "$tmp/personal-real.yaml"
  for clave in owners memoria.banco; do
    while IFS= read -r v; do
      [ -n "$v" ] && PROHIBIDO="$PROHIBIDO|$(escapar "$v")"
    done < <(FABRIK_CONFIG="$tmp/personal-real.yaml" uv run --with pyyaml python "$FABRIK_DIR/scripts/fabrik_config.py" get "$clave" 2>/dev/null)
  done
done
privados=""
for f in "$FABRIK_DIR"/bin/* "$FABRIK_DIR"/install.sh; do
  grep -qnE "$PROHIBIDO" "$f" && privados="$privados $f"
done
for f in "$FABRIK_DIR"/scripts/*.py; do
  [ "$(basename "$f")" = "fabrik_config.py" ] && continue
  grep -qnE "$PROHIBIDO" "$f" && privados="$privados $f"
done
if [ -n "$privados" ]; then
  fallo "AC-9 valores fijos en:$privados"
else
  ok_
fi

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
