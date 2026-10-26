#!/usr/bin/env bash
# install.sh — monta la fábrica en esta máquina (idempotente; se puede re-ejecutar).
#   ./install.sh            instala/actualiza
#   ./install.sh --comprobar   solo comprueba requisitos y logins
set -uo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
DATA="${FABRIK_DATA:-$HOME/.hermes/factory}"
ok(){ printf '  \e[32m✓\e[0m %s\n' "$*"; }; ko(){ printf '  \e[31m✗\e[0m %s\n' "$*"; FALTA=1; }; av(){ printf '  \e[33m!\e[0m %s\n' "$*"; }
FALTA=0
cfg() { uv run --with pyyaml python "$REPO/scripts/fabrik_config.py" "$@" || true; }

uso() {
  cat <<'EOF'
Uso: ./install.sh [--comprobar] [--pack <ruta|url>] [--help]

  (sin opciones)       instala o actualiza la fábrica en esta máquina (idempotente)
  --comprobar          solo comprueba requisitos, logins y claves; no instala ni escribe nada
                       (con --pack muestra lo que haría, sin clonar, enlazar ni crear config)
  --pack <ruta|url>    añade un pack de organización (carpeta local o URL git) a tu configuración
  -h, --help           muestra esta ayuda y sale
EOF
}

# D-1/D-3: opciones «rápidas» de la unidad de MariaDB (config/systemd/fabrica-mariadb.service).
OPTS_RAPIDAS="--innodb-buffer-pool-size=2G --innodb-flush-log-at-trx-commit=0 --innodb-doublewrite=0 --innodb-flush-method=O_DIRECT_NO_FSYNC --sync-binlog=0 --innodb-log-file-size=512M --skip-name-resolve"

# D-3: informa (en --comprobar y en modo install) de las opciones rápidas de la unidad efectiva
# (systemctl --user cat, con drop-ins) y del No_COW (+C) del datadir en btrfs. Solo lee; lo que
# falta es «av», no «ko»: no rompe la comprobación.
comprobar_mariadb_rapido() {
  local mdir="${MDATA:-$HOME/.local/share/fabrica/mariadb}" unidad="" faltan="" o fs
  if unidad="$(systemctl --user cat fabrica-mariadb 2>/dev/null)"; then
    faltan=""
    for o in $OPTS_RAPIDAS; do
      grep -q -- "$o" <<<"$unidad" || faltan="$faltan $o"
    done
    if [[ -z "$faltan" ]]; then
      ok "fabrica-mariadb lleva las opciones rápidas de tests"
    else
      av "fabrica-mariadb sin las opciones rápidas:$faltan"
      av "migrar con: bash $REPO/scripts/migrar-mariadb-rapido.sh (o --seco para ver qué haría)"
    fi
  else
    av "unidad fabrica-mariadb no instalada en systemd --user (sin --comprobar la instala ./install.sh)"
  fi
  if [[ -d "$mdir" ]]; then fs="$(stat -f -c %T "$mdir" 2>/dev/null)"; else fs="$(stat -f -c %T "$(dirname "$mdir")" 2>/dev/null)"; fi
  case "$fs" in
    btrfs)
      if lsattr -d "$mdir" 2>/dev/null | awk '{print $1}' | grep -q 'C'; then
        ok "datadir con No_COW (+C) en btrfs"
      else
        av "datadir $mdir en btrfs sin No_COW (+C): copias de BD más lentas por COW"
        av "migrar con: bash $REPO/scripts/migrar-mariadb-rapido.sh (o --seco para ver qué haría)"
      fi
      ;;
    "" | desconocido)
      av "no se pudo saber el sistema de ficheros del datadir $mdir"
      ;;
    *)
      ok "datadir en $fs (sin COW: nada que hacer)"
      ;;
  esac
}

COMPROBAR=0
PACK_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      uso
      exit 0
      ;;
    --comprobar)
      COMPROBAR=1
      shift
      ;;
    --pack)
      [[ -n "${2:-}" ]] || { echo "install.sh: --pack necesita una ruta o una URL git" >&2; exit 2; }
      PACK_ARG="$2"
      shift 2
      ;;
    *)
      echo "install.sh: opción desconocida: $1" >&2
      uso >&2
      exit 2
      ;;
  esac
done

CONFIG_PERSONAL="${FABRIK_CONFIG:-$HOME/.config/fabrica/fabrik.yaml}"
# Con --comprobar no se escribe nada en la máquina: ni enlaces ni clones de packs ni config personal.
# Lo que haría la instalación se calcula sobre una copia temporal de la config y se muestra con `!`.
PACK_NAME=""
PACK_SRC=""   # dónde vive el pack (en --comprobar, un pack local se usa en su sitio, sin enlazarlo)
if [[ -n "$PACK_ARG" ]]; then
  [[ $COMPROBAR -eq 1 ]] || mkdir -p "$DATA/packs"
  if [[ "$PACK_ARG" =~ ^(https?://|git@|ssh://) ]]; then
    PACK_NAME="$(basename "$PACK_ARG" .git)"
    PACK_DEST="$DATA/packs/$PACK_NAME"
    PACK_SRC="$PACK_DEST"
    if [[ ! -d "$PACK_DEST" ]]; then
      if [[ $COMPROBAR -eq 1 ]]; then
        av "--comprobar no clona: la instalación clonaría $PACK_ARG en $PACK_DEST"; PACK_NAME=""
      else
        git clone "$PACK_ARG" "$PACK_DEST" >/dev/null 2>&1 || ko "no se pudo clonar el pack desde $PACK_ARG"
      fi
    fi
  else
    PACK_PATH="$(cd "$PACK_ARG" 2>/dev/null && pwd || echo "$PACK_ARG")"
    PACK_NAME="$(basename "$PACK_PATH")"
    PACK_DEST="$DATA/packs/$PACK_NAME"
    PACK_SRC="$PACK_DEST"
    if [[ ! -d "$PACK_PATH" ]]; then
      ko "pack no encontrado: $PACK_ARG"; PACK_NAME=""
    elif [[ ! -e "$PACK_DEST" ]]; then
      if [[ $COMPROBAR -eq 1 ]]; then
        av "--comprobar no enlaza: la instalación enlazaría $PACK_PATH en $PACK_DEST"; PACK_SRC="$PACK_PATH"
      else
        ln -s "$PACK_PATH" "$PACK_DEST"
      fi
    fi
  fi
  [[ -n "$PACK_NAME" && ! -f "$PACK_SRC/pack.yaml" ]] && { ko "el pack no tiene pack.yaml: $PACK_ARG"; PACK_NAME=""; }
fi
PACK_REF="${PACK_NAME:+$PACK_SRC}"

if [[ $COMPROBAR -eq 1 ]]; then
  CONFIG_REAL="$CONFIG_PERSONAL"
  TMP_COMPROBAR="$(mktemp -d)"
  trap 'rm -rf "$TMP_COMPROBAR"' EXIT
  CONFIG_PERSONAL="$TMP_COMPROBAR/fabrik.yaml"
  # Todas las llamadas de `cfg` leen la copia; las rutas relativas de packs siguen resolviéndose
  # respecto a la config real.
  export FABRIK_CONFIG="$CONFIG_PERSONAL" FABRIK_CONFIG_ORIGEN="$CONFIG_REAL"
  [[ -f "$CONFIG_REAL" ]] && cp "$CONFIG_REAL" "$CONFIG_PERSONAL"
else
  CONFIG_REAL="$CONFIG_PERSONAL"
fi

if [[ ! -f "$CONFIG_PERSONAL" ]] && MODELOS_PREVIOS="$(uv run --with pyyaml python "$REPO/scripts/fabrik_config.py" modelos-previos "$CONFIG_PERSONAL" "$PACK_REF" 2>/dev/null)"; then
  # Máquina ya configurada (perfiles de Hermes creados) y un pack que trae sus modelos de referencia:
  # proponer modelos nuevos reescribiría los que ya rigen los perfiles. No se escribe ni se aplica nada.
  ko "máquina ya configurada y sin ${CONFIG_REAL/#$HOME/~}: no se proponen modelos nuevos para no reescribir los actuales"
  av "copia los modelos de referencia del pack a ${CONFIG_REAL/#$HOME/~} y vuelve a ejecutar ./install.sh con los mismos argumentos:"
  while IFS= read -r f; do av "  mkdir -p $(dirname "${CONFIG_REAL/#$HOME/~}") && cp $f ${CONFIG_REAL/#$HOME/~}"; done <<< "$MODELOS_PREVIOS"
  echo "Instalación abortada: sin tus modelos personales no se aplican los perfiles." >&2
  exit 3
fi
if [[ ! -f "$CONFIG_PERSONAL" ]]; then
  [[ $COMPROBAR -eq 1 ]] || mkdir -p "$(dirname "$CONFIG_PERSONAL")"
  USUARIO_GITHUB="$(gh api user -q .login 2>/dev/null || echo "${USER:-usuario}")"
  cfg init-personal "$CONFIG_PERSONAL" "$USUARIO_GITHUB" "$PACK_REF"
  if [[ $COMPROBAR -eq 1 ]]; then
    av "--comprobar no escribe: la instalación crearía la configuración personal en $CONFIG_REAL"
  else
    ok "configuración personal creada en $CONFIG_PERSONAL"
  fi
elif [[ -n "$PACK_REF" ]]; then
  cfg anadir-pack "$CONFIG_PERSONAL" "$PACK_REF"
  [[ $COMPROBAR -eq 1 ]] && av "--comprobar no escribe: la instalación añadiría el pack a $CONFIG_REAL"
fi

# (sin `cfg`: su `|| true` taparía el código de salida que aquí se necesita)
if ! uv run --with pyyaml python "$REPO/scripts/fabrik_config.py" tiene-pack "$CONFIG_PERSONAL" >/dev/null 2>&1; then
  av "Sin pack configurado: usando pack de ejemplo (puedes instalar uno con ./install.sh --pack <ruta|url>)"
fi

echo "== Requisitos"
HAS_PHP=0
if [[ -f "$DATA/portfolio.yaml" ]]; then
  if grep -qiE 'language:\s*php' "$DATA/portfolio.yaml"; then
    HAS_PHP=1
  fi
fi

for c in hermes git gh python3 uv php composer node greptile flock systemctl; do
  if command -v "$c" >/dev/null 2>&1 || { [[ $c == node || $c == greptile ]] && ls -d "$HOME"/.nvm/versions/node/*/bin/$c >/dev/null 2>&1; }; then ok "$c"; else ko "$c no encontrado"; fi
done

if command -v mariadb >/dev/null 2>&1; then
  ok "mariadb"
else
  if [[ $HAS_PHP -eq 1 ]]; then
    ko "mariadb no encontrado (necesario para repos PHP)"
  else
    av "mariadb no instalado (opcional: ningún repo PHP detectado en el portfolio)"
  fi
fi
command -v specify >/dev/null 2>&1 && ok "specify (Spec Kit)" || ko "specify (Spec Kit): uv tool install specify-cli --from git+https://github.com/github/spec-kit.git"

echo "== Logins y claves (los pone el usuario)"
gh auth status >/dev/null 2>&1 && ok "gh autenticado" || ko "gh: ejecuta 'gh auth login'"
command -v agy >/dev/null 2>&1 && ok "agy (Antigravity) presente — si falla: 'agy login'" || av "agy no instalado (Gemini vía Antigravity)"
# Proveedores de la config (`modelos`): cada uno exige una clave de API o un plugin.
cfg mostrar-modelos
while read -r tipo nombre; do
  [[ -z "$tipo" ]] && continue
  if [[ "$tipo" == "api_key" ]]; then
    grep -q "^$nombre=." "$HOME/.hermes/.env" 2>/dev/null && ok "$nombre en ~/.hermes/.env" || ko "$nombre falta en ~/.hermes/.env"
  else
    hermes config get plugins.enabled 2>/dev/null | grep -q "$nombre" && ok "plugin $nombre" || ko "plugin $nombre: hermes plugins install …"
  fi
done < <(cfg requisitos)
echo "== Pool de modelos"
# Esquema de modelos.pool / reserva_final / permitir_pago: con errores no se instala ni se aplica nada.
if ! ERRORES_POOL="$(uv run --with pyyaml python "$REPO/scripts/fabrik_config.py" validar 2>&1 >/dev/null)"; then
  ko "configuración de modelos inválida:"
  printf '%s\n' "$ERRORES_POOL" | sed 's/^/      /'
  if [[ $COMPROBAR -eq 1 ]]; then
    echo "Faltan cosas (✗)."; exit 3
  fi
  echo "Instalación abortada: corrige la configuración de modelos y vuelve a ejecutar ./install.sh" >&2
  exit 3
fi
ok "configuración de modelos válida"
echo "== MariaDB de la fábrica (rápido)"
comprobar_mariadb_rapido
if [[ $COMPROBAR -eq 1 ]]; then
  # Solo comprueba que el SOUL del orquestador se genera (con el pool del pack activo); no escribe nada.
  if SOUL_OUT="$(uv run --with pyyaml python "$REPO/scripts/apply_profile_policy.py" --seco --solo-soul orquestador 2>&1)"; then
    ok "SOUL del orquestador se genera con el pool configurado"
  else
    ko "SOUL del orquestador no se genera: $SOUL_OUT"
  fi
fi
[[ $COMPROBAR -eq 1 ]] && { [[ $FALTA == 0 ]] && echo "Todo listo." || echo "Faltan cosas (✗)." ; exit $FALTA; }

echo "== Datos y enlaces"
mkdir -p "$DATA"/{logs/tests,locks} "$HOME/.config/fabrica" "$HOME/Code/.factory-worktrees"
for l in DESIGN.md:docs/DESIGN.md flows:docs/flows mockups:docs/mockups scripts:scripts; do
  ln -sfn "$REPO/${l#*:}" "$DATA/${l%%:*}"; done; ok "enlaces en $DATA"
[[ -f "$DATA/portfolio.yaml" ]] || { uv run --with pyyaml python "$REPO/scripts/build_portfolio.py" >/dev/null 2>&1 && ok "portfolio.yaml generado" || av "portfolio.yaml: ejecuta scripts/build_portfolio.py"; }

echo "== Perfiles"
uv run --with pyyaml python "$REPO/scripts/apply_profile_policy.py" | sed 's/^/  /'
S="$REPO/plugin/fabrica/skills/fabrica"
mkdir -p "$HOME/.hermes/skills/devops" "$HOME/.hermes/profiles/orquestador/skills/devops"
ln -sfn "$S" "$HOME/.hermes/skills/devops/fabrica"; ln -sfn "$S" "$HOME/.hermes/profiles/orquestador/skills/devops/fabrica"; ok "skill /fabrica"

echo "== Panel The Factory (plugin de escritorio)"
bash "$REPO/scripts/instalar-panel.sh"

echo "== Kanban"
hermes config set kanban.orchestrator_profile orquestador >/dev/null
hermes config set kanban.max_in_progress 8 >/dev/null
python3 - "$HOME/.hermes/config.yaml" <<'PY' || true
import re,sys; p=sys.argv[1]; t=open(p).read()
t=re.sub(r"(\n  max_in_progress_per_profile:)(\n    .*)*", r"\1 3", t, count=1); open(p,"w").write(t)
PY
hermes config set kanban.auto_decompose false >/dev/null
hermes config set kanban.dispatch_profiles '["orquestador","explorador","programador","tester","revisor","seguridad","docs"]' >/dev/null
while IFS='|' read -r slug name desc icon; do
  [[ -z "$slug" ]] && continue
  hermes kanban boards list 2>/dev/null | grep -q " $slug " || hermes kanban boards create "$slug" --name "$name" --description "$desc" --icon "$icon" >/dev/null
done < <(cfg campos tableros slug nombre descripcion icono)
ok "tableros"

echo "== Base de datos (MariaDB propio de la fábrica en 127.0.0.1:3307, usuario fx solo fx_*)"
# Los agentes usan SU MariaDB (unidad de usuario fabrica-mariadb: puerto 3307, solo 127.0.0.1, sin privilegios),
# nunca el de tu día a día. Si falta mariadbd/mariadb-install-db se omite: sin él los agentes no tienen BD.
FX_PORT_FABRICA=3307
if ! command -v mariadb >/dev/null 2>&1; then
  av "mariadb no instalado; configuración de base de datos fx omitida"
elif ! command -v mariadbd >/dev/null 2>&1 || ! command -v mariadb-install-db >/dev/null 2>&1; then
  av "faltan mariadbd/mariadb-install-db: no se monta el MariaDB propio de la fábrica; configuración de base de datos fx omitida"
else
  F="$HOME/.config/fabrica/db.env"
  if [[ ! -f "$F" ]]; then
    ( umask 077
      printf 'FX_DB_USER=fx\nFX_DB_PASSWORD=%s\nFX_DB_HOST=127.0.0.1\nFX_DB_PORT=%s\n' \
        "$(head -c 24 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 24)" "$FX_PORT_FABRICA" > "$F" )
  fi
  . "$F"
  MDATA="$HOME/.local/share/fabrica/mariadb"
  if [[ "${FX_DB_PORT:-}" != "$FX_PORT_FABRICA" ]]; then
  # db.env anterior apuntando a otro MariaDB (p. ej. el del usuario en 3306): se respeta, pero se avisa.
  av "db.env usa el puerto ${FX_DB_PORT:-?}, no el $FX_PORT_FABRICA de la fábrica: los agentes usarán ese MariaDB (solo protege el GRANT a fx_%)."
  av "para aislarlos, borra ~/.config/fabrica/db.env y vuelve a ejecutar ./install.sh"
  if mariadb -h"${FX_DB_HOST:-127.0.0.1}" -P"${FX_DB_PORT:-3306}" -u"${FX_DB_USER:-fx}" -p"$FX_DB_PASSWORD" -e "select 1" >/dev/null 2>&1; then ok "usuario fx"; else
    av "crea el usuario fx (necesita root de MariaDB; te lo pedirá):"
    mariadb -h127.0.0.1 -P"${FX_DB_PORT:-3306}" -uroot -p <<SQL && ok "usuario fx creado" || ko "no se pudo crear fx"
CREATE USER IF NOT EXISTS 'fx'@'localhost' IDENTIFIED BY '$FX_DB_PASSWORD';
CREATE USER IF NOT EXISTS 'fx'@'127.0.0.1' IDENTIFIED BY '$FX_DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`fx\_%\`.* TO 'fx'@'localhost';
GRANT ALL PRIVILEGES ON \`fx\_%\`.* TO 'fx'@'127.0.0.1';
SQL
  fi
  else
    # Primera vez: inicializa el directorio de datos con el usuario fx ya creado (sin contraseña de root, sin sudo).
    if [[ ! -d "$MDATA/mysql" ]]; then
      mkdir -p "$MDATA"
      # D-2: en btrfs el datadir se crea VACÍO con No_COW (+C) antes de mariadb-install-db: los
      # ficheros nuevos heredan el atributo y las copias/purgas de BD se salta el COW. Si chattr
      # falla se sigue sin No_COW (más lento, pero funciona).
      if [[ "$(stat -f -c %T "$(dirname "$MDATA")" 2>/dev/null)" == btrfs ]]; then
        chattr +C "$MDATA" 2>/dev/null && ok "datadir con No_COW (+C)" \
          || av "no se pudo aplicar chattr +C a $MDATA: se sigue sin No_COW"
      fi
      EXTRA="$(umask 077; mktemp "${TMPDIR:-/tmp}/fabrica-mariadb-init.XXXXXX")"
      cat > "$EXTRA" <<SQL
CREATE USER IF NOT EXISTS 'fx'@'localhost' IDENTIFIED BY '$FX_DB_PASSWORD';
CREATE USER IF NOT EXISTS 'fx'@'127.0.0.1' IDENTIFIED BY '$FX_DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`fx\_%\`.* TO 'fx'@'localhost';
GRANT ALL PRIVILEGES ON \`fx\_%\`.* TO 'fx'@'127.0.0.1';
SQL
      if mariadb-install-db --no-defaults --datadir="$MDATA" --skip-test-db --auth-root-authentication-method=socket \
           --extra-file="$EXTRA" >/dev/null 2>&1; then ok "MariaDB de la fábrica inicializado en $MDATA"; else ko "no se pudo inicializar el MariaDB de la fábrica en $MDATA"; fi
      rm -f "$EXTRA"
    fi
    # D-5: una instalación existente con datadir sin +C NO se migra sola desde install.sh
    # (llevaría un stop de la BD): solo se avisa y se apunta al migrador.
    if [[ -d "$MDATA/mysql" && "$(stat -f -c %T "$MDATA" 2>/dev/null)" == btrfs ]] \
       && ! lsattr -d "$MDATA" 2>/dev/null | awk '{print $1}' | grep -q 'C'; then
      av "datadir $MDATA sin No_COW (+C): scripts/migrar-mariadb-rapido.sh lo migra (con --seco para simular)"
    fi
    mkdir -p "$HOME/.config/systemd/user"
    sed "s#^ExecStart=[^ ]*mariadbd #ExecStart=$(command -v mariadbd) #" "$REPO/config/systemd/fabrica-mariadb.service" \
      > "$HOME/.config/systemd/user/fabrica-mariadb.service"
    systemctl --user daemon-reload
    if systemctl --user enable --now fabrica-mariadb >/dev/null 2>&1; then
      for _ in $(seq 1 30); do
        mariadb -h127.0.0.1 -P"$FX_PORT_FABRICA" -ufx -p"$FX_DB_PASSWORD" -e "select 1" >/dev/null 2>&1 && break; sleep 1
      done
      if mariadb -h127.0.0.1 -P"$FX_PORT_FABRICA" -ufx -p"$FX_DB_PASSWORD" -e "select 1" >/dev/null 2>&1; then
        ok "fabrica-mariadb en 127.0.0.1:$FX_PORT_FABRICA (usuario fx)"
      else
        ko "fabrica-mariadb arrancó pero fx no entra en 127.0.0.1:$FX_PORT_FABRICA (revisa: journalctl --user -u fabrica-mariadb)"
      fi
    else
      ko "no se pudo arrancar fabrica-mariadb (systemctl --user status fabrica-mariadb)"
    fi
  fi
fi

echo "== Servicios (systemd de usuario)"
mkdir -p "$HOME/.config/systemd/user"
cp "$REPO"/config/systemd/{fabrica-gc,fabrica-cupos}.{service,timer} "$HOME/.config/systemd/user/"
systemctl --user daemon-reload; systemctl --user enable --now fabrica-gc.timer >/dev/null 2>&1 && ok "fabrica-gc.timer (cada hora)"
systemctl --user enable --now fabrica-cupos.timer >/dev/null 2>&1 && ok "fabrica-cupos.timer (cupos de suscripciones cada 10 min)"
cp "$REPO"/config/systemd/fabrica-triage.service "$HOME/.config/systemd/user/"
systemctl --user daemon-reload; systemctl --user enable --now fabrica-triage >/dev/null 2>&1 && ok "fabrica-triage (tarjetas de la app → orquestador al instante)"
hermes config set kanban.default_assignee orquestador >/dev/null
if command -v hindsight-api >/dev/null 2>&1 || [[ "${FABRIK_MEMORIA:-}" == "si" ]]; then
  command -v hindsight-api >/dev/null || uv tool install hindsight-api --torch-backend cpu >/dev/null
  if [[ ! -f "$HOME/.config/fabrica/hindsight.env" ]]; then
    av "falta ~/.config/fabrica/hindsight.env (ver config/hindsight.env.ejemplo); memoria no arrancada"
  else
    cp "$REPO/config/systemd/fabrica-memoria.service" "$HOME/.config/systemd/user/"
    systemctl --user daemon-reload; systemctl --user enable --now fabrica-memoria >/dev/null 2>&1 && ok "memoria (Hindsight) en 127.0.0.1:8888"
  fi
else
  av "memoria compartida no instalada (opcional): FABRIK_MEMORIA=si ./install.sh"
fi
systemctl --user is-active hermes-gateway >/dev/null 2>&1 && ok "gateway activo (dispatcher del Kanban)" || av "arranca el gateway: hermes gateway start"

echo
[[ $FALTA == 0 ]] && echo "Fábrica instalada. Abre Hermes Desktop → Ajustes → Plugins → activa Kanban; en el chat: /fabrica estado" \
                  || echo "Instalada con avisos (✗ arriba): resuélvelos y vuelve a ejecutar ./install.sh"
