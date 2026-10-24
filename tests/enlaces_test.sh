#!/usr/bin/env bash
# Test de enlaces internos (AC-15): ningún enlace interno roto en los .md versionados.
#
# Comprueba, en cada `*.md` de `git ls-files`:
#   1. enlaces Markdown `[texto](destino)` con destino relativo (se ignoran http(s), mailto y #ancla);
#   2. rutas de documentos entre comillas invertidas con carpeta y extensión .md (p. ej. `docs/flows/C0-….md`),
#      que se resuelven respecto al fichero, a la raíz del repo o a docs/ (los docs se citan de las tres formas).
# Se ignoran las referencias que no son del repo: `~/…`, rutas absolutas, carpetas ocultas (`.specify/…`,
# que viven en el repo del proyecto), comodines y marcadores (`<x>`, `$x`, `NNN`).
# Un mutante (enlace roto en una copia) comprueba que el test detecta lo que debe.
# Uso: bash tests/enlaces_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ¿existe <ruta> como la citaría <fichero> (relativa a su carpeta, a la raíz o a docs/)?
existe() { # <raiz> <fichero> <ruta>
  local raiz="$1" dir
  dir="$(dirname "$2")"
  [ -e "$raiz/$dir/$3" ] || [ -e "$raiz/$3" ] || [ -e "$raiz/docs/$3" ]
}

# comprobar <raiz>: imprime «fichero: destino» por cada enlace roto
comprobar() {
  local raiz="$1" f d
  while IFS= read -r -d '' f; do
    [ -f "$raiz/$f" ] || continue
    # 1. enlaces Markdown
    while IFS= read -r d; do
      d="${d%%#*}"; d="${d%% *}"
      [ -n "$d" ] || continue
      case "$d" in http://*|https://*|mailto:*|/*|'~'*) continue ;; esac
      [ -e "$raiz/$(dirname "$f")/$d" ] || echo "$f: $d"
    done < <(grep -oE '\]\([^)]+\)' "$raiz/$f" | sed -E 's/^\]\(//; s/\)$//')
    # 2. rutas de .md con carpeta entre comillas invertidas
    while IFS= read -r d; do
      case "$d" in '~'*|/*|.*|*'*'*|*'<'*|*'>'*|*'$'*|*NNN*|*' '*) continue ;; esac
      existe "$raiz" "$f" "$d" || echo "$f: $d"
    done < <(grep -oE '`[A-Za-z0-9_./-]+/[A-Za-z0-9_.-]+\.md`' "$raiz/$f" | tr -d '`' | sort -u)
  done < <(git -C "$raiz" ls-files -z -- '*.md')
}

# ---------- AC-15a: el árbol real no tiene enlaces rotos ----------
comprobar "$FABRIK_DIR" > "$tmp/real.out"
if [ -s "$tmp/real.out" ]; then
  fallo "AC-15 enlaces internos rotos ($(grep -c . "$tmp/real.out")):"
  head -n 40 "$tmp/real.out" >&2
else
  ok_
fi

# ---------- AC-15b: mutantes — el test detecta enlaces rotos ----------
mut="$tmp/mut"
mkdir -p "$mut/docs/flows" "$mut/packs/p/docs"
printf '# A\n[bueno](../B.md) y [ancla](#x) y [web](https://web/x.md)\n`docs/B.md` `packs/p/docs/C.md` `~/fuera/D.md` `docs/<x>/E.md`\n' > "$mut/docs/flows/A.md"
printf '# B\n' > "$mut/docs/B.md"
printf '# C\n' > "$mut/packs/p/docs/C.md"
git -C "$mut" init -q
git -C "$mut" add -A
if [ -n "$(comprobar "$mut")" ]; then
  fallo "AC-15 falso positivo en el árbol sano del mutante: $(comprobar "$mut" | tr '\n' ';')"
else
  ok_
fi

printf '[roto](../NO-EXISTE.md)\n' >> "$mut/docs/flows/A.md"
if comprobar "$mut" | grep -qF 'docs/flows/A.md: ../NO-EXISTE.md'; then ok_; else fallo "AC-15 mutante: enlace Markdown roto no detectado"; fi

printf '`docs/flows/FANTASMA.md`\n' >> "$mut/docs/flows/A.md"
if comprobar "$mut" | grep -qF 'docs/flows/A.md: docs/flows/FANTASMA.md'; then ok_; else fallo "AC-15 mutante: ruta entre comillas rota no detectada"; fi

# mover un doc (lo que hace IMPL-4 con F4 → packs/) debe romper el enlace que lo citaba
git -C "$mut" mv docs/B.md packs/p/docs/B.md
if comprobar "$mut" | grep -qF 'docs/flows/A.md: ../B.md'; then ok_; else fallo "AC-15 mutante: doc movido sin actualizar el enlace no detectado"; fi

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
