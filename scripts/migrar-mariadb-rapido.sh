#!/usr/bin/env bash
# migrar-mariadb-rapido.sh — pasa el MariaDB propio de la fábrica (unidad fabrica-mariadb,
# puerto 3307) a las opciones «rápidas» de tests (config/systemd/fabrica-mariadb.service) y, en
# btrfs, a un datadir con No_COW (+C) para que las copias y purgas de BD no paguen el COW.
#
# Uso:
#   scripts/migrar-mariadb-rapido.sh          migra (para y rearra fabrica-mariadb)
#   scripts/migrar-mariadb-rapido.sh --seco   solo dice qué haría; no escribe ni para nada
#   scripts/migrar-mariadb-rapido.sh --help   esta ayuda
#
# Idempotente: si la unidad efectiva ya lleva las opciones y el datadir no necesita +C
# (o no es btrfs), sale con «ya migrado» sin parar el servicio. Antes de copiar comprueba que hay
# espacio (tamaño del datadir + 10 %); si falta, aborta SIN parar el servicio. Si el rearraque
# falla, deja el datadir viejo en su sitio y rearraanca. NUNCA borra la copia vieja: imprime su
# ruta y su tamaño para que la borre un humano cuando confirme que todo va.
#
# Cerrojos: coge todos los de $FABRIK_DATA/locks/ antes de parar, en este orden para no crear
# ciclos con factory-test: primero el turno pesado (factory-test.lock), después los huecos
# dirigidos (dirigidos.d/1..N.lock, con N = FX_TEST_DIRIGIDOS o 4, más los que existan) y por
# último los de BD (bd.d/*.lock). Espera como máximo FX_MIGRAR_WAIT s (def. 3600) por cerrojo y,
# mientras espera, avisa de quién tiene el turno (el .owner junto a cada lock).
set -uo pipefail

ok(){ printf '  \e[32m✓\e[0m %s\n' "$*"; }
av(){ printf '  \e[33m!\e[0m %s\n' "$*"; }
ko(){ printf '  \e[31m✗\e[0m %s\n' "$*" >&2; }
di(){ printf '  (seco) %s\n' "$*"; }   # --seco: lo que haría, sin hacerlo

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICIO=fabrica-mariadb
MDATA="${FABRIK_MDATA:-$HOME/.local/share/fabrica/mariadb}"
LOCKDIR="${FABRIK_DATA:-$HOME/.hermes/factory}/locks"
ESPERA="${FX_MIGRAR_WAIT:-3600}"
UNIDAD_DST="$HOME/.config/systemd/user/$SERVICIO.service"
OPTS_RAPIDAS="--innodb-buffer-pool-size=2G --innodb-flush-log-at-trx-commit=0 --innodb-doublewrite=0 --innodb-flush-method=O_DIRECT_NO_FSYNC --sync-binlog=0 --innodb-log-file-size=512M --skip-name-resolve"
SECO=0
COPIA_VIEJA=""

uso() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seco) SECO=1; shift ;;
    -h|--help) uso; exit 0 ;;
    *) ko "opción desconocida: $1 (prueba con --help)"; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- estado --
unidad_rapida() { # rc 0 si la unidad efectiva (con drop-ins) lleva todas las opciones rápidas
  local u o
  u="$(systemctl --user cat "$SERVICIO" 2>/dev/null)" || return 1
  for o in $OPTS_RAPIDAS; do grep -q -- "$o" <<<"$u" || return 1; done
  return 0
}

es_btrfs() { [[ "$(stat -f -c %T "$MDATA" 2>/dev/null)" == btrfs ]]; }

datadir_con_cow() { # rc 0 si el datadir tiene No_COW (+C)
  lsattr -d "$MDATA" 2>/dev/null | awk '{print $1}' | grep -q 'C'
}

hay_que_migrar_datadir() { es_btrfs && [[ -d "$MDATA" ]] && ! datadir_con_cow; }

if unidad_rapida && ! hay_que_migrar_datadir; then
  ok "ya migrado: la unidad efectiva lleva las opciones rápidas y el datadir no necesita +C; no se para nada"
  exit 0
fi

# --------------------------------------------------------- espacio (antes de nada) --
# La copia necesita tamaño(datadir) + 10 %. Si no cabe, se aborta ANTES de instalar la
# unidad, coger cerrojos o parar el servicio: la máquina queda exactamente como estaba.
if hay_que_migrar_datadir; then
  kb_datadir="$(du -sk "$MDATA" 2>/dev/null | awk '{print $1}')"; kb_datadir="${kb_datadir:-0}"
  # libre (KiB) = bloques disponibles × tamaño de bloque
  kb_libre="$(stat -f -c '%a %S' "$(dirname "$MDATA")" 2>/dev/null | awk '{printf "%d", $1*$2/1024}')"; kb_libre="${kb_libre:-0}"
  if (( kb_libre * 10 < kb_datadir * 11 )); then
    ko "espacio insuficiente para copiar el datadir: libres ${kb_libre} KiB, hacen falta $(( kb_datadir * 11 / 10 )) KiB. Libera espacio y vuelve a intentarlo. No se ha parado nada."
    exit 1
  fi
fi

# ----------------------------------------------- unidad nueva (como install.sh) --
if unidad_rapida; then
  ok "la unidad efectiva ya lleva las opciones rápidas"
elif [[ $SECO -eq 1 ]]; then
  di "instalaría $REPO/config/systemd/fabrica-mariadb.service en $UNIDAD_DST (con el sed de mariadbd) y haría daemon-reload"
else
  mkdir -p "$(dirname "$UNIDAD_DST")"
  sed "s#^ExecStart=[^ ]*mariadbd #ExecStart=$(command -v mariadbd) #" "$REPO/config/systemd/fabrica-mariadb.service" > "$UNIDAD_DST" \
    || { ko "no se pudo instalar $UNIDAD_DST"; exit 1; }
  systemctl --user daemon-reload || { ko "daemon-reload falló"; exit 1; }
  ok "unidad nueva instalada en $UNIDAD_DST y daemon-reload hecho"
fi

# ---------------------------------------------------------- cerrojos de tests --
FDS=()
declare -A LOCKED=()
soltar_locks() { local fd; for fd in ${FDS[*]+"${FDS[@]}"}; do flock -u "$fd" 2>/dev/null || true; done; FDS=(); }
trap soltar_locks EXIT

coger_lock() { # <fichero.lock>: flock de exclusión; espera como mucho $ESPERA s y avisa del .owner.
  # OJO: no se puede flock dos veces el mismo fichero desde el mismo proceso con fds distintos:
  # los locks de flock entran en conflicto entre descriptores del mismo proceso (auto-cerrojo).
  local f="$1" fd propietario
  [[ -n "${LOCKED[$f]:-}" ]] && return 0
  exec {fd}>>"$f" || { ko "no se pudo abrir $f"; exit 1; }
  if ! flock -n "$fd" 2>/dev/null; then
    propietario="$(head -1 "${f%.lock}.owner" 2>/dev/null)"
    av "esperando $(basename "$f")${propietario:+ — turno de: $propietario} (máx ${ESPERA}s)"
    flock -w "$ESPERA" "$fd" || { ko "sin $(basename "$f") tras ${ESPERA}s de espera"; exit 75; }
  fi
  LOCKED[$f]=1
  FDS+=("$fd")
}

if [[ $SECO -eq 1 ]]; then
  di "cogería los cerrojos: $LOCKDIR/factory-test.lock, dirigidos.d/1..N.lock (N = FX_TEST_DIRIGIDOS o 4, y los que existan) y bd.d/*.lock"
else
  mkdir -p "$LOCKDIR/dirigidos.d" "$LOCKDIR/bd.d"
  # 1) turno pesado (factory-test). 2) huecos dirigidos: 1..max aunque no existan + los que haya.
  coger_lock "$LOCKDIR/factory-test.lock"
  max="${FX_TEST_DIRIGIDOS:-4}"; [[ "$max" =~ ^[0-9]+$ ]] || max=4
  for ((n = 1; n <= max; n++)); do coger_lock "$LOCKDIR/dirigidos.d/$n.lock"; done
  for f in "$LOCKDIR/dirigidos.d"/*.lock; do [[ -e "$f" ]] || continue; coger_lock "$f"; done
  # 3) locks de BD (los que existan).
  for f in "$LOCKDIR/bd.d"/*.lock; do [[ -e "$f" ]] || continue; coger_lock "$f"; done
  ok "cerrojos cogidos (turno, dirigidos y BD): seguro parar la BD"
fi

# ------------------------------------------------------------------- stop --
if [[ $SECO -eq 1 ]]; then
  di "pararía fabrica-mariadb (systemctl --user stop $SERVICIO)"
else
  systemctl --user stop "$SERVICIO" || { ko "no se pudo parar $SERVICIO (systemctl --user status $SERVICIO)"; exit 1; }
  ok "fabrica-mariadb parado"
fi

# ------------------------------------- datadir nuevo con +C (solo en btrfs) --
swap_datadir() {
  local nuevo="$MDATA.nuevo" copia="$MDATA.cow-$(date +%Y%m%d%H%M)"
  if [[ $SECO -eq 1 ]]; then
    di "crearía $nuevo con chattr +C, copiaría con cp -a --reflink=never $MDATA/. $nuevo/, haría mv $MDATA $copia y mv $nuevo $MDATA"
    return 0
  fi
  mkdir -p "$nuevo" || { ko "no se pudo crear $nuevo"; exit 1; }
  chattr +C "$nuevo" 2>/dev/null || av "chattr +C falló en $nuevo: se sigue (el COW seguirá costando en el datadir nuevo)"
  cp -a --reflink=never "$MDATA"/. "$nuevo"/ || { ko "la copia real falló; $MDATA se queda como estaba"; rm -rf "$nuevo"; exit 1; }
  mv "$MDATA" "$copia" || { ko "no se pudo apartar $MDATA a $copia"; exit 1; }
  mv "$nuevo" "$MDATA" || { ko "no se pudo poner $nuevo en $MDATA (recupera: mv $copia $MDATA)"; exit 1; }
  COPIA_VIEJA="$copia"
  ok "datadir nuevo con No_COW (+C) en su sitio"
}

if hay_que_migrar_datadir; then
  swap_datadir
else
  ok "datadir sin migrar (no es btrfs o ya tiene +C): solo cambian las opciones de la unidad"
fi

# -------------------------------------------------------------- start y fx --
arrancar() {
  systemctl --user start "$SERVICIO" || return 1
  local i
  for ((i = 0; i < 30; i++)); do
    mariadb -h127.0.0.1 -P3307 -ufx -p"${FX_DB_PASSWORD:-}" -e "select 1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# shellcheck disable=SC1090
[[ -f "$HOME/.config/fabrica/db.env" ]] && . "$HOME/.config/fabrica/db.env"

if [[ $SECO -eq 1 ]]; then
  di "--seco: simulación completa; no se ha escrito ni parado nada"
  exit 0
fi

if arrancar; then
  ok "fabrica-mariadb arrancó y fx entra (select 1)"
else
  ko "fabrica-mariadb no arrancó con el datadir nuevo: se revierte el intercambio"
  if [[ -n "$COPIA_VIEJA" && -d "$COPIA_VIEJA" ]]; then
    mv "$MDATA" "$MDATA.nuevo-fallo" 2>/dev/null
    mv "$COPIA_VIEJA" "$MDATA" && av "datadir viejo restablecido en $MDATA (el nuevo va en $MDATA.nuevo-fallo)"
  fi
  systemctl --user start "$SERVICIO" 2>/dev/null \
    && av "rearraancado con el datadir viejo (revisa: journalctl --user -u $SERVICIO)" \
    || ko "ni siquiera rearraanca con el datadir viejo: revisa journalctl --user -u $SERVICIO"
  exit 1
fi

if [[ -n "$COPIA_VIEJA" ]]; then
  av "copia vieja NO borrada: $COPIA_VIEJA ($(du -sh "$COPIA_VIEJA" 2>/dev/null | awk '{print $1}')) — bórrala tú cuando confirmes que todo va"
fi
ok "migración hecha: opciones rápidas en la unidad y datadir sin COW"
