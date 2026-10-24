#!/usr/bin/env bash
# Test guardián (AC-13): el motor (todo lo versionado fuera de packs/) no contiene nada privado.
#
# Qué busca, en cada fichero de `git ls-files` fuera de `packs/`:
#   1. cada término de cada `packs/*/denylist.txt` (excepto el pack `ejemplo`), sin distinguir mayúsculas;
#   2. rutas personales `/home/<usuario>`;
#   3. direcciones IP (v4) y nombres de host (dominios con TLD habitual).
# Falsos positivos justificados: `tests/sin_privado.permitidos` (una línea por excepción,
# `ruta|fragmento  # motivo`; ruta `*` = cualquier fichero; sin fragmento = fichero entero; el motivo es obligatorio).
# Un fragmento solo silencia la línea si, sin él, la línea ya no coincide (no puede tapar otro hallazgo).
#
# Además comprueba con MUTANTES que el guardián muerde: en una copia del árbol se mete un término
# de la denylist, una ruta, una IP y un host en ficheros del motor y el escaneo debe encontrarlos.
# Uso: bash tests/sin_privado_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

PAT_RUTAS='/home/[a-z][a-z0-9_-]*'
# IPs v4 salvo loopback (127.x) y 0.0.0.0, que son valores por defecto legítimos del motor (servicios locales)
PAT_IP='\b(?!127\.|0\.0\.0\.0)([0-9]{1,3}\.){3}[0-9]{1,3}\b'
PAT_HOST='\b[a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)*\.(com|es|net|org|io|dev|app|local|lan|internal)\b'

# denylists (D-P5): las del repo (`packs/*` de <raiz>), las de los packs activos (`packs:` de la config personal)
# y las de $FABRIK_DATA/packs/*; sin contar `ejemplo`. Se resuelven los enlaces para no contar dos veces un pack.
packs_activos() { # directorios de los packs activos; se cachea por config (arrancar python en cada llamada es lento)
  local f="$tmp/activos.$(printf '%s|%s' "${FABRIK_CONFIG:-}" "$HOME" | md5sum | cut -c1-16)"
  [ -f "$f" ] || { uv run --with pyyaml python "$FABRIK_DIR/scripts/fabrik_config.py" pack-dir nombre 2>/dev/null | cut -f2 > "$f.tmp"; mv "$f.tmp" "$f"; }
  cat "$f"
}

denylists() { # <raiz> → una ruta por línea
  local d
  {
    for d in "$1"/packs/*/; do echo "${d%/}"; done
    packs_activos
    for d in "${FABRIK_DATA:-$HOME/.hermes/factory}"/packs/*/; do echo "${d%/}"; done
  } | while IFS= read -r d; do
    [ -f "$d/denylist.txt" ] || continue
    [ "$(basename "$(readlink -f "$d")")" = "ejemplo" ] && continue
    readlink -f "$d/denylist.txt"
  done | sort -u
}

# términos privados de todas las denylists, uno por línea, sin comentarios
terminos() { # <raiz>
  local d
  denylists "$1" | while IFS= read -r d; do
    sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$d"
  done | grep -v '^$' | sort -u
}

# ficheros del motor (rutas relativas a <raiz>, separadas por NUL)
ficheros_motor() { # <raiz>
  # la propia lista blanca se excluye: por definición nombra lo que justifica
  git -C "$1" ls-files -z | grep -zv '^packs/' | grep -zvx 'tests/sin_privado.permitidos'
}

# ¿la coincidencia «fichero:linea:texto» está en la lista blanca de <raiz>?
# Una excepción con fragmento solo silencia la coincidencia si, quitando ese fragmento, la línea YA NO coincide
# (así `github.com` no puede tapar un término privado que comparta línea).
sigue_coincidiendo() { # <raiz> <tipo> <texto>
  case "$2" in
    termino) terminos "$1" > "$tmp/t.sc"; [ -s "$tmp/t.sc" ] && grep -qiF -f "$tmp/t.sc" <<<"$3" ;;
    ruta) grep -qE -e "$PAT_RUTAS" <<<"$3" ;;
    ip) grep -qP -e "$PAT_IP" <<<"$3" ;;
    host) grep -qE -e "$PAT_HOST" <<<"$3" ;;
  esac
}

permitida() { # <raiz> <fichero> <texto> <tipo>
  local f="$1/tests/sin_privado.permitidos" ruta frag linea resto
  [ -f "$f" ] || return 1
  while IFS= read -r linea; do
    linea="${linea%%#*}"
    [ -n "${linea//[[:space:]]/}" ] || continue
    ruta="${linea%%|*}"; ruta="${ruta//[[:space:]]/}"
    frag=""; [[ "$linea" == *"|"* ]] && frag="${linea#*|}"
    frag="${frag#"${frag%%[![:space:]]*}"}"; frag="${frag%"${frag##*[![:space:]]}"}"
    [ "$ruta" = "*" ] || [ "$ruta" = "$2" ] || continue
    [ -z "$frag" ] && return 0
    if [[ "$3" == *"$frag"* ]]; then
      resto="${3//"$frag"/}"
      sigue_coincidiendo "$1" "$4" "$resto" || return 0
    fi
  done < "$f"
  return 1
}

# escanear <raiz>: imprime «tipo|fichero:linea:texto» por cada coincidencia no permitida
escanear() {
  local raiz="$1" t="$tmp/terminos.$$" tipo fich lin txt resto
  terminos "$raiz" > "$t"
  {
    if [ -s "$t" ]; then
      ficheros_motor "$raiz" | (cd "$raiz" && xargs -0 grep -InH -i -F -f "$t" -- 2>/dev/null | sed 's/^/termino|/')
    fi
    ficheros_motor "$raiz" | (cd "$raiz" && xargs -0 grep -InHE -e "$PAT_RUTAS" -- 2>/dev/null | sed 's/^/ruta|/')
    ficheros_motor "$raiz" | (cd "$raiz" && xargs -0 grep -InHP -e "$PAT_IP" -- 2>/dev/null | sed 's/^/ip|/')
    ficheros_motor "$raiz" | (cd "$raiz" && xargs -0 grep -InHE -e "$PAT_HOST" -- 2>/dev/null | sed 's/^/host|/')
  } | sort -u | while IFS= read -r l; do
    tipo="${l%%|*}"; resto="${l#*|}"
    fich="${resto%%:*}"; resto="${resto#*:}"
    lin="${resto%%:*}"; txt="${resto#*:}"
    permitida "$raiz" "$fich" "$txt" "$tipo" || echo "$tipo|$fich:$lin:$txt"
  done
  rm -f "$t"
}

# ---------- AC-13a: el árbol real no contiene nada privado ----------
n_terminos="$(terminos "$FABRIK_DIR" | grep -c .)"
n_denylists="$(denylists "$FABRIK_DIR" | grep -c .)"
echo "guardián: $n_terminos términos de $n_denylists denylist(s) externas (repo, packs activos, \$FABRIK_DATA/packs)"
if [ "$n_terminos" -eq 0 ]; then
  echo "aviso: no hay ninguna denylist externa; solo se buscan rutas, IPs y hosts. Instala tu pack (./install.sh --pack ...) para comprobar también sus términos." >&2
fi
escanear "$FABRIK_DIR" > "$tmp/real.out"
if [ -s "$tmp/real.out" ]; then
  fallo "AC-13 el motor contiene $(grep -c . "$tmp/real.out") coincidencias privadas (primeras 40 abajo)"
  head -n 40 "$tmp/real.out" | cut -c1-220 >&2
else
  ok_
fi

# ---------- AC-13b: la lista blanca es explícita y está justificada ----------
perm="$FABRIK_DIR/tests/sin_privado.permitidos"
if [ -f "$perm" ]; then
  sin_motivo="$(grep -vE '^[[:space:]]*(#.*)?$' "$perm" | grep -vE '#[[:space:]]*[^[:space:]]' || true)"
  if [ -n "$sin_motivo" ]; then
    fallo "AC-13 entradas de sin_privado.permitidos sin motivo (# motivo): $(echo "$sin_motivo" | head -3 | tr '\n' ';')"
  else
    ok_
  fi
else
  ok_
fi

# ---------- AC-13c: mutantes — el guardián debe morder ----------
# Los mutantes no deben depender de los packs que haya instalados en la máquina: datos y config vacíos.
export FABRIK_DATA="$tmp/data-vacio" FABRIK_CONFIG="$tmp/sin-config.yaml"
mkdir -p "$FABRIK_DATA"
mut="$tmp/mut"
mkdir -p "$mut"
git -C "$FABRIK_DIR" ls-files -z | (cd "$FABRIK_DIR" && xargs -0 -I{} sh -c 'test -f "$1" && cp --parents "$1" "$2"' _ {} "$mut")
git -C "$mut" init -q
git -C "$mut" add -A
# el término se compone aquí para que este propio fichero no lo contenga
TERMINO="lara""tik""neo"
# denylist propia del mutante: así el caso no depende de que haya un pack real presente
mkdir -p "$mut/packs/_mutante"
printf '%s\n' "$TERMINO" > "$mut/packs/_mutante/denylist.txt"
# ídem para la ruta, la IP y el host de los mutantes
RUTA="/ho""me/pepe/proyecto"; IP="10.20.30"".40"; HOST="servidor.mi""empresa"".com"

# mutar <fichero> <texto> <tipo>: añade el texto a un fichero del motor y exige que el escaneo lo encuentre
mutar() {
  local fich="$1" texto="$2" tipo="$3" out="$tmp/mut.out"
  cp "$mut/$fich" "$tmp/mut.backup"
  printf '\n%s\n' "$texto" >> "$mut/$fich"
  escanear "$mut" > "$out"
  if ! grep -qF "$tipo|$fich:" "$out" || ! grep -F "$tipo|$fich:" "$out" | grep -qF -- "$texto"; then
    fallo "AC-13 mutante «$texto» en $fich no detectado"
  else
    ok_
  fi
  cp "$tmp/mut.backup" "$mut/$fich"
}

# el árbol mutante parte limpio para esos ficheros: si no, el mutante no demuestra nada
mutar bin/factory-gc          "# usa $TERMINO como ejemplo"      termino
mutar docs/flows/F2-feature.md "# $TERMINO"                       termino
mutar tests/fabrik_test.sh    "# $(echo "$TERMINO" | tr 'a-z' 'A-Z')"  termino
mutar tests/consumidores_test.sh "# $TERMINO"                     termino
mutar tests/fabrik_config_test.sh "# $TERMINO"                   termino
mutar tests/consumidores_test.sh "# ruta $RUTA"                  ruta
mutar tests/fabrik_config_test.sh "# servidor $IP"               ip
mutar install.sh              "# ruta $RUTA"        ruta
mutar bin/fabrik-prod         "# servidor $IP"            ip
mutar config/prod.conf.ejemplo "# host=$HOST"   host

# un mutante en packs/ NO debe contar (el pack es privado por diseño)
cp "$mut/packs/_mutante/denylist.txt" "$tmp/denylist.backup"
mkdir -p "$mut/packs/otro"
printf '# %s en un pack: permitido\n' "$TERMINO" > "$mut/packs/otro/nota.md"
git -C "$mut" add -A
escanear "$mut" | grep -F 'packs/otro' > "$tmp/enpack.out" || true
if [ -s "$tmp/enpack.out" ]; then
  fallo "AC-13 el guardián escanea dentro de packs/ (no debería)"
else
  ok_
fi

# un fichero tests/golden/x.md con un término de la denylist DEBE detectarse (AC-28)
mkdir -p "$mut/tests/golden"
printf '# %s\n' "$TERMINO" > "$mut/tests/golden/x.md"
git -C "$mut" add "$mut/tests/golden/x.md"
escanear "$mut" | grep -F 'tests/golden/x.md' > "$tmp/golden-mut.out" || true
if ! grep -qF "termino|tests/golden/x.md:" "$tmp/golden-mut.out" || ! grep -F "termino|tests/golden/x.md:" "$tmp/golden-mut.out" | grep -qF "$TERMINO"; then
  fallo "AC-28 mutante en tests/golden/x.md no detectado"
else
  ok_
fi
git -C "$mut" rm -f "$mut/tests/golden/x.md" >/dev/null 2>&1 || true
rmdir "$mut/tests/golden" 2>/dev/null || true

# una excepción justificada silencia SOLO su coincidencia
printf '# %s\n' "$TERMINO" >> "$mut/docs/DESIGN.md"
escanear "$mut" | grep -F 'docs/DESIGN.md' | grep -qF "# $TERMINO" || fallo "AC-13 mutante base para lista blanca no detectado"
printf 'docs/DESIGN.md|%s  # falso positivo de prueba\n' "$TERMINO" >> "$mut/tests/sin_privado.permitidos"
if escanear "$mut" | grep -F 'docs/DESIGN.md' | grep -qF "# $TERMINO"; then
  fallo "AC-13 la lista blanca no silencia la coincidencia justificada"
else
  ok_
fi

# ---------- AC-37 (D-P5): denylists externas — se reúnen de FABRIK_DATA/packs y de los packs activos ----------
# Se parte de un árbol sin ninguna denylist: con el término solo en una denylist externa el escaneo debe verlo.
rm -rf "$mut/packs/_mutante" "$mut/packs/otro"
git -C "$mut" add -A
printf '\n# %s\n' "$TERMINO" >> "$mut/docs/flows/F2-feature.md"
git -C "$mut" add -A
sin_denylist="$(escanear "$mut" | grep -cF 'termino|docs/flows/F2-feature.md:' || true)"
if [ "$sin_denylist" -eq 0 ]; then ok_; else fallo "AC-37 sin denylist externa no debería haber hallazgos de término ($sin_denylist)"; fi
# a) $FABRIK_DATA/packs/x/denylist.txt (carpeta real, no enlace)
mkdir -p "$tmp/data-a/packs/x"
printf '%s\n' "$TERMINO" > "$tmp/data-a/packs/x/denylist.txt"
con_data="$(FABRIK_DATA="$tmp/data-a" escanear "$mut" | grep -F 'termino|docs/flows/F2-feature.md:' | grep -cF -- "$TERMINO" || true)"
if [ "$con_data" -gt 0 ]; then ok_; else fallo "AC-37 el término en FABRIK_DATA/packs/x/denylist.txt no se detectó en un fichero del motor"; fi
n_data="$(FABRIK_DATA="$tmp/data-a" terminos "$mut" | grep -c .)"
if [ "$n_data" -eq 1 ]; then ok_; else fallo "AC-37 se esperaba 1 término de FABRIK_DATA/packs, hay $n_data"; fi
# b) un pack enlazado en FABRIK_DATA/packs (como deja install.sh --pack): se cuenta una sola vez
mkdir -p "$tmp/pack-fuera-de-data" "$tmp/data-b/packs"
printf '%s\n' "$TERMINO" > "$tmp/pack-fuera-de-data/denylist.txt"
ln -s "$tmp/pack-fuera-de-data" "$tmp/data-b/packs/nombre-libre"
n_link="$(FABRIK_DATA="$tmp/data-b" denylists "$mut" | grep -c .)"
if [ "$n_link" -eq 1 ]; then ok_; else fallo "AC-37 un pack enlazado debe contar una vez, cuenta $n_link"; fi
# c) pack activo por la config personal (fuera de FABRIK_DATA y del repo)
mkdir -p "$tmp/pack-activo"
printf 'nombre: activo\nowners: [acme]\n' > "$tmp/pack-activo/pack.yaml"
printf '%s\n' "$TERMINO" > "$tmp/pack-activo/denylist.txt"
printf 'packs:\n  - %s\n' "$tmp/pack-activo" > "$tmp/cfg-activo.yaml"
con_activo="$(FABRIK_CONFIG="$tmp/cfg-activo.yaml" escanear "$mut" | grep -F 'termino|docs/flows/F2-feature.md:' | grep -cF -- "$TERMINO" || true)"
if [ "$con_activo" -gt 0 ]; then ok_; else fallo "AC-37 la denylist de un pack activo (config personal) no se aplicó"; fi
# d) el pack `ejemplo` no cuenta aunque esté en FABRIK_DATA/packs
mkdir -p "$tmp/data-c/packs/ejemplo"
printf '%s\n' "$TERMINO" > "$tmp/data-c/packs/ejemplo/denylist.txt"
n_ej="$(FABRIK_DATA="$tmp/data-c" terminos "$mut" | grep -c .)"
if [ "$n_ej" -eq 0 ]; then ok_; else fallo "AC-37 la denylist de ejemplo no debe contarse ($n_ej términos)"; fi

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
