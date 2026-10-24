#!/usr/bin/env bash
# Test de la documentación de uso (IMPL-6).
#
# AC-21  Los comandos de los docs existen: se extraen los bloques ```bash de README.md y de docs/*.md
#        (menos DESIGN.md, que es histórico) y de packs/*/docs/*.md, y por cada comando de la fábrica:
#          - `install.sh`: cada `--flag` figura en `./install.sh --help`;
#          - `fabrik <sub>`: el subcomando figura en `fabrik --help`;
#          - `factory-*` / `fabrik-*`: el ejecutable existe en bin/ y cada `--flag` aparece en su código.
#        Un MUTANTE (doc con un flag, subcomando y ejecutable inventados) debe ser detectado.
#        `install.sh --help` y un flag desconocido no instalan nada (HOME temporal: debe quedar vacío).
# AC-20  Los docs no meten nada privado y se pueden publicar: se ejecuta el bloque marcado
#        `# test: ejecutar` de docs/publicar.md (git archive de HEAD sin packs privados)
#        y el árbol resultante pasa tests/sin_privado_test.sh y tests/soul_test.sh.
# Enlaces rotos (AC-15): lo comprueba tests/enlaces_test.sh sobre los mismos .md.
# Uso: bash tests/docs_test.sh   (HOME temporal: nunca toca ~/.hermes ni ~/.config reales)
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
bien() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"
unset FABRIK_CONFIG FABRIK_DATA FABRIK_HOME HERMES_HOME HERMES_PROFILE HERMES_KANBAN_DB HERMES_KANBAN_BOARD
# Seguro por construcción: install.sh solo se invoca aquí con opciones que salen antes de instalar nada
# (--help, flag desconocido, --pack sin valor). Una instalación real jamás debe lanzarse desde un test.

# ---------- install.sh --help: informa y NO instala ----------
home_vacio() { [ -z "$(find "$HOME" -mindepth 1 -print -quit)" ]; }

bash "$FABRIK_DIR/install.sh" --help > "$tmp/help.out" 2> "$tmp/help.err"
rc=$?
if [ "$rc" -eq 0 ]; then bien; else fallo "install.sh --help debe salir 0 (salió $rc)"; fi
for flag in --comprobar --pack --help; do
  if grep -qF -- "$flag" "$tmp/help.out"; then bien; else fallo "install.sh --help no documenta $flag"; fi
done
if home_vacio; then bien; else fallo "install.sh --help tocó el HOME (instaló algo): $(find "$HOME" -mindepth 1 | head -5 | tr '\n' ' ')"; fi

bash "$FABRIK_DIR/install.sh" -h > "$tmp/h.out" 2>&1
if [ $? -eq 0 ] && grep -qF -- '--comprobar' "$tmp/h.out"; then bien; else fallo "install.sh -h debe comportarse como --help"; fi

bash "$FABRIK_DIR/install.sh" --inventado > "$tmp/bad.out" 2> "$tmp/bad.err"
rc=$?
if [ "$rc" -eq 2 ]; then bien; else fallo "install.sh con flag desconocido debe salir 2 (salió $rc)"; fi
if grep -qF -- '--inventado' "$tmp/bad.err"; then bien; else fallo "install.sh con flag desconocido debe nombrarlo en stderr"; fi
if home_vacio; then bien; else fallo "install.sh con flag desconocido instaló algo en el HOME"; fi

# `--pack` sin valor no puede colgarse ni instalar (timeout de seguridad).
timeout 20 bash "$FABRIK_DIR/install.sh" --pack > "$tmp/pack0.out" 2> "$tmp/pack0.err"
rc=$?
if [ "$rc" -eq 2 ]; then bien; else fallo "install.sh --pack sin valor debe salir 2 (salió $rc)"; fi
if home_vacio; then bien; else fallo "install.sh --pack sin valor instaló algo en el HOME"; fi

bash "$FABRIK_DIR/bin/fabrik" --help > "$tmp/fabrik-help.out" 2>&1

# ---------- extracción y comprobación de comandos (AC-21) ----------
cat > "$tmp/extraer.py" <<'PY'
"""Imprime «fichero<TAB>comando<TAB>argumentos» por cada comando de la fábrica en bloques ```bash."""
import re
import shlex
import sys
from pathlib import Path

raiz = Path(sys.argv[1])
ficheros = [Path(f) for f in sys.argv[2:]]
CMD = re.compile(r"^(?:\./|(?:\S*/)?bin/)?(install\.sh|fabrik|fabrik-[a-z-]+|factory-[a-z-]+)$")

for f in ficheros:
    dentro = False
    bloque = []
    for linea in f.read_text(encoding="utf-8").splitlines():
        if re.match(r"^\s*```bash\s*$", linea):
            dentro, bloque = True, []
            continue
        if dentro and linea.lstrip().startswith("```"):
            dentro = False
            texto = "\n".join(bloque).replace("\\\n", " ")
            for l in texto.splitlines():
                l = l.split(" #")[0].strip() if not l.lstrip().startswith("#") else ""
                if not l:
                    continue
                for tramo in re.split(r"&&|\|\||;|\|", l):
                    tramo = re.sub(r"^\s*(\$\s+|[A-Z_]+=\S+\s+)+", "", tramo)
                    try:
                        toks = shlex.split(tramo)
                    except ValueError:
                        toks = tramo.split()
                    if toks and CMD.match(toks[0]):
                        m = CMD.match(toks[0])
                        print(f"{f.relative_to(raiz) if f.is_relative_to(raiz) else f}\t{m.group(1)}\t{' '.join(toks[1:])}")
            continue
        if dentro:
            bloque.append(linea.strip())
PY

# comprobar_docs <raiz> <ficheros...>: imprime una línea por cada comando inexistente
comprobar_docs() {
  local raiz="$1"; shift
  local fichero cmd args tok
  while IFS=$'\t' read -r fichero cmd args; do
    case "$cmd" in
      install.sh)
        for tok in $args; do
          case "$tok" in
            --*) grep -qF -- "$tok" "$tmp/help.out" || echo "$fichero: install.sh $tok (flag inexistente)" ;;
          esac
        done ;;
      fabrik)
        tok="${args%% *}"
        case "$tok" in
          ""|-*) ;;
          *) grep -qE "^[[:space:]]+${tok}[[:space:]]" "$tmp/fabrik-help.out" || echo "$fichero: fabrik $tok (subcomando inexistente)" ;;
        esac ;;
      *)
        if [ ! -f "$FABRIK_DIR/bin/$cmd" ]; then
          echo "$fichero: $cmd (no existe en bin/)"
        else
          for tok in $args; do
            case "$tok" in
              --*) grep -qF -- "${tok%%=*}" "$FABRIK_DIR/bin/$cmd" || echo "$fichero: $cmd $tok (flag inexistente)" ;;
            esac
          done
        fi ;;
    esac
  done < <(python3 -I "$tmp/extraer.py" "$raiz" "$@")
}

# documentos de uso del motor y de los packs (el diseño es histórico y queda fuera)
mapfile -t DOCS < <(cd "$FABRIK_DIR" && ls README.md docs/*.md packs/*/docs/*.md 2>/dev/null | grep -v '^docs/DESIGN\.md$')
for requerido in README.md docs/onboarding.md docs/crear-pack.md docs/publicar.md; do
  if printf '%s\n' "${DOCS[@]}" | grep -qx "$requerido"; then bien; else fallo "AC-21 falta el documento $requerido"; fi
done
DOCS_ABS=()
for d in "${DOCS[@]}"; do DOCS_ABS+=("$FABRIK_DIR/$d"); done

if [ "${#DOCS_ABS[@]}" -gt 0 ]; then
  python3 -I "$tmp/extraer.py" "$FABRIK_DIR" "${DOCS_ABS[@]}" > "$tmp/comandos.tsv"
  total="$(grep -c . "$tmp/comandos.tsv")"
  if [ "$total" -ge 8 ]; then bien; else fallo "AC-21 extraje solo $total comandos de los docs (¿bloques \`\`\`bash vacíos?)"; fi
  # el README debe enseñar los dos comandos de arranque
  if grep -qP '^README\.md\tinstall\.sh\t--comprobar' "$tmp/comandos.tsv"; then bien; else fallo "AC-21 el README no enseña ./install.sh --comprobar"; fi
  comprobar_docs "$FABRIK_DIR" "${DOCS_ABS[@]}" > "$tmp/rotos.out"
  if [ -s "$tmp/rotos.out" ]; then
    fallo "AC-21 comandos de los docs que no existen ($(grep -c . "$tmp/rotos.out")):"
    head -n 30 "$tmp/rotos.out" >&2
  else
    bien
  fi
fi

# ---------- AC-21b: mutante — la comprobación muerde ----------
mkdir -p "$tmp/mut/docs"
cat > "$tmp/mut/docs/m.md" <<'EOF'
# Mutante
```bash
./install.sh --comprobar
./install.sh --inventado
fabrik config ver
fabrik inventado
factory-prep --limpiar
factory-inventada --x
```
```text
./install.sh --en-un-bloque-text-no-cuenta
```
EOF
comprobar_docs "$tmp/mut" "$tmp/mut/docs/m.md" > "$tmp/mut.out"
for esperado in 'install.sh --inventado' 'fabrik inventado' 'factory-inventada'; do
  if grep -qF "$esperado" "$tmp/mut.out"; then bien; else fallo "AC-21 mutante: no detecta «$esperado»"; fi
done
if [ "$(grep -c . "$tmp/mut.out")" -eq 3 ]; then bien; else fallo "AC-21 mutante: esperaba exactamente 3 hallazgos, hay: $(tr '\n' ';' < "$tmp/mut.out")"; fi

# ---------- AC-20: el procedimiento de publicar produce un árbol limpio ----------
python3 -I - "$FABRIK_DIR/docs/publicar.md" > "$tmp/publicar.sh" 2> "$tmp/publicar.err" <<'PY'
import re, sys
from pathlib import Path
try:
    texto = Path(sys.argv[1]).read_text(encoding="utf-8")
except OSError as e:
    sys.exit(f"no se puede leer {sys.argv[1]}: {e}")
for m in re.finditer(r"^[ \t]*```bash\n([ \t]*# test: ejecutar\n.*?)^[ \t]*```", texto, re.S | re.M):
    print(m.group(1))
PY
if [ -s "$tmp/publicar.sh" ]; then
  bien
  export DEST="$tmp/publico"
  # el bloque documentado se ejecuta tal cual, desde la raíz del repo, sobre HEAD
  if (cd "$FABRIK_DIR" && bash -e "$tmp/publicar.sh") > "$tmp/publicar.out" 2>&1; then bien; else fallo "AC-20 el bloque «test: ejecutar» de publicar.md falló: $(tail -n 8 "$tmp/publicar.out")"; fi
  if [ -d "$DEST/.git" ] && [ "$(git -C "$DEST" rev-list --count HEAD 2>/dev/null)" = "1" ]; then bien; else fallo "AC-20 el árbol publicado debe ser un repo con un solo commit"; fi
  privados="$(cd "$FABRIK_DIR" && git ls-files -- packs | cut -d/ -f1-2 | sort -u | grep -vx 'packs/ejemplo')"
  for p in $privados; do
    if [ -e "$DEST/$p" ]; then fallo "AC-20 el árbol publicado contiene el pack privado $p"; else bien; fi
  done
  if [ -f "$DEST/packs/ejemplo/pack.yaml" ] && [ -f "$DEST/LICENSE" ]; then bien; else fallo "AC-20 el árbol publicado debe llevar packs/ejemplo y LICENSE"; fi
  # el guardián y los tests del motor siguen en verde SIN pack real
  if (cd "$DEST" && bash tests/sin_privado_test.sh) > "$tmp/pub-guardian.out" 2>&1; then bien; else fallo "AC-20 sin_privado_test.sh en el árbol publicado: $(tail -n 6 "$tmp/pub-guardian.out")"; fi
  if (cd "$DEST" && bash tests/soul_test.sh) > "$tmp/pub-soul.out" 2>&1; then bien; else fallo "AC-20 soul_test.sh en el árbol publicado: $(tail -n 6 "$tmp/pub-soul.out")"; fi
  # ningún término privado en el árbol publicado (la denylist vive en el repo privado)
  terminos="$tmp/terminos.txt"
  for d in "$FABRIK_DIR"/packs/*/denylist.txt; do
    [ -f "$d" ] || continue   # sin packs con denylist el glob queda literal
    [ "$(basename "$(dirname "$d")")" = ejemplo ] && continue
    sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$d"
  done | grep -v '^$' | sort -u > "$terminos"
  # LICENSE nombra al titular (justificado en sin_privado.permitidos): se excluye solo ese fichero
  if [ -s "$terminos" ] && grep -rIiF -f "$terminos" --exclude=LICENSE --exclude-dir=.git --exclude=sin_privado.permitidos "$DEST" > "$tmp/fuga.out" 2>&1; then
    fallo "AC-20 términos privados en el árbol publicado: $(head -n 5 "$tmp/fuga.out" | cut -c1-160 | tr '\n' ';')"
  else
    bien
  fi
else
  fallo "AC-20 docs/publicar.md no tiene un bloque «# test: ejecutar» ($(cat "$tmp/publicar.err" 2>/dev/null))"
fi

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
