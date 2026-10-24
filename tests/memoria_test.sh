#!/usr/bin/env bash
# Tests de las lecciones compartidas por git en el pack (D-P7):
#   AC-30 fabrik-memoria leccion escribe en <pack activo con memoria.banco>/conocimiento/lecciones/ y nunca bajo
#         FABRIK_HOME ni en el repo del motor; sin pack así, en $FABRIK_DATA/conocimiento/lecciones/.
#   AC-31 memoria_ingest.py lecciones ingiere las lecciones de TODOS los packs activos (document_id estable
#         leccion/<pack>/<fichero>) y no lee $FABRIK_HOME/conocimiento.
#   AC-32 .gitignore del motor ignora conocimiento/.
#   AC-33 (motor) docs/onboarding.md cierra con «Lecciones compartidas»; las lecciones de la fase 1 viven en el pack
#         (su comprobación vive en los tests del pack).
# HOME, FABRIK_DATA, FABRIK_HOME y FABRIK_CONFIG temporales; la memoria es un servidor de juguete (sin Hindsight real).
# Uso: bash tests/memoria_test.sh
set -u

FABRIK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok=0
fail=0
fallo() { fail=$((fail + 1)); echo "FALLO: $1" >&2; }
ok_() { ok=$((ok + 1)); }

tmp="$(mktemp -d)"
trap 'kill "${SRV_PID:-}" 2>/dev/null || true; rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export FABRIK_DATA="$tmp/data"
export FABRIK_HOME="$tmp/motor"
mkdir -p "$HOME" "$FABRIK_DATA" "$FABRIK_HOME"
unset FABRIK_CONFIG FABRIK_MEMORIA_BANK FABRIK_MEMORIA_URL

# Packs de fixture: alfa y beta con banco de memoria, gamma sin él; uno dentro del «motor».
mkpack() { # <dir> <nombre> [banco]
  mkdir -p "$1"
  { printf 'nombre: %s\ntitulo: Pack %s\n' "$2" "$2"
    [ -n "${3:-}" ] && printf 'memoria:\n  banco: %s\n' "$3"
  } > "$1/pack.yaml"
}
mkpack "$tmp/packs/gamma" gamma
mkpack "$tmp/packs/alfa" alfa banco-a
mkpack "$tmp/packs/beta" beta banco-b
mkpack "$FABRIK_HOME/packs/dentro" dentro banco-d
printf 'packs:\n  - %s\n  - %s\n  - %s\n' "$tmp/packs/gamma" "$tmp/packs/alfa" "$tmp/packs/beta" > "$tmp/cfg-ab.yaml"
printf 'packs:\n  - %s\n' "$tmp/packs/gamma" > "$tmp/cfg-g.yaml"
printf 'packs:\n  - %s\n' "$FABRIK_HOME/packs/dentro" > "$tmp/cfg-dentro.yaml"
printf 'packs:\n  - ejemplo\n' > "$tmp/cfg-ejemplo.yaml"

# Servidor de juguete: registra «METODO ruta» + cuerpo y responde 200 {}.
cat > "$tmp/server.py" <<'PY'
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
python3 "$tmp/server.py" "$tmp/http.log" "$tmp/port" &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
if [ ! -s "$tmp/port" ]; then
  fallo "servidor de juguete no arrancó"
  echo "$ok ok / $fail fallos"
  exit 1
fi
URL="http://127.0.0.1:$(cat "$tmp/port")"
# Puerto cerrado: reservar uno libre y soltarlo.
MUERTO="http://127.0.0.1:$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"

leccion() { # <config> <url> <repo> <sintoma> → stdout+stderr en $tmp/out
  env FABRIK_CONFIG="$1" FABRIK_MEMORIA_URL="$2" \
    python3 "$FABRIK_DIR/bin/fabrik-memoria" leccion --repo "$3" --sintoma "$4" --causa "c1" --solucion "s1" \
    --donde "d1" --etiquetas "t1,t2" > "$tmp/out" 2>&1
}
hay() { compgen -G "$1" > /dev/null; }  # ¿algún fichero casa con el glob?
lista() { find "$1" -type f 2>/dev/null | sort; }  # ficheros de un árbol

# ---------- AC-30: destino de las lecciones ----------
# a) primer pack activo CON memoria.banco (gamma no lo tiene, alfa sí): sus lecciones/, nombre de fichero con fecha
: > "$tmp/http.log"
leccion "$tmp/cfg-ab.yaml" "$URL" api-acme "Falla el login con tilde"
RC=$?
dest="$tmp/packs/alfa/conocimiento/lecciones"
patron="$dest/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-api-acme-falla-el-login-con-tilde.md"
if [ "$RC" -ne 0 ]; then fallo "AC-30 leccion exit $RC: $(tail -3 "$tmp/out")"
elif ! hay "$patron"; then fallo "AC-30 no escribe <pack alfa>/conocimiento/lecciones/<fecha>-<repo>-<slug>.md: $(lista "$tmp/packs")"
else ok_; fi

# b) formato: frontmatter (repo, fecha, etiquetas) y las cuatro secciones
f="$(compgen -G "$patron" | head -1)"
if [ -n "$f" ] && grep -qx 'repo: api-acme' "$f" && grep -qE '^fecha: [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$f" \
   && grep -qxF 'etiquetas: [t1,t2]' "$f" && grep -qF '**Síntoma:** Falla el login con tilde' "$f" \
   && grep -qF '**Causa:** c1' "$f" && grep -qF '**Solución:** s1' "$f" && grep -qF '**Dónde:** d1' "$f"; then ok_
else fallo "AC-30 formato de la lección incorrecto: $(cat "${f:-/dev/null}" 2>/dev/null | head -8)"; fi

# c) ni el otro pack con banco, ni FABRIK_DATA, ni FABRIK_HOME reciben nada
if [ -n "$(lista "$tmp/packs/beta" | grep -v pack.yaml)" ] || [ -n "$(lista "$tmp/packs/gamma" | grep -v pack.yaml)" ]; then
  fallo "AC-30 escribió en un pack que no es el primero con memoria.banco"
elif [ -n "$(lista "$FABRIK_DATA")" ]; then fallo "AC-30 escribió en FABRIK_DATA habiendo pack con banco: $(lista "$FABRIK_DATA")"
elif [ -d "$FABRIK_HOME/conocimiento" ]; then fallo "AC-30 escribió bajo FABRIK_HOME (repo del motor)"
else ok_; fi

# d) la memoria recibe el document_id estable leccion/<pack>/<fichero> (el banco es el de la config fusionada: gana beta)
if grep -qF "POST /v1/default/banks/banco-b/memories" "$tmp/http.log" \
   && grep -qE '"document_id": "leccion/alfa/[0-9]{4}-[0-9]{2}-[0-9]{2}-api-acme-falla-el-login-con-tilde\.md"' "$tmp/http.log"; then ok_
else fallo "AC-30 document_id leccion/<pack>/<fichero> no enviado a la memoria: $(head -c 300 "$tmp/http.log")"; fi

# e) sin pack con memoria.banco → $FABRIK_DATA/conocimiento/lecciones/
leccion "$tmp/cfg-g.yaml" "$URL" api-acme "Sin pack con banco"
if hay "$FABRIK_DATA/conocimiento/lecciones/*-api-acme-sin-pack-con-banco.md" && [ ! -d "$FABRIK_HOME/conocimiento" ]; then ok_
else fallo "AC-30 sin pack con banco no escribe en FABRIK_DATA/conocimiento/lecciones: $(lista "$FABRIK_DATA")"; fi

# f) un pack con banco que vive DENTRO de FABRIK_HOME no recibe lecciones: van a FABRIK_DATA
leccion "$tmp/cfg-dentro.yaml" "$URL" api-acme "Pack dentro del motor"
if hay "$FABRIK_DATA/conocimiento/lecciones/*-api-acme-pack-dentro-del-motor.md" \
   && [ -z "$(lista "$FABRIK_HOME" | grep -v pack.yaml)" ]; then ok_
else fallo "AC-30 escribió bajo FABRIK_HOME: $(lista "$FABRIK_HOME")"; fi

# g) el pack `ejemplo` del repo del motor tampoco recibe lecciones (ni queda nada sin versionar en el repo)
leccion "$tmp/cfg-ejemplo.yaml" "$URL" api-acme "Pack ejemplo del motor"
if hay "$FABRIK_DATA/conocimiento/lecciones/*-api-acme-pack-ejemplo-del-motor.md" \
   && [ ! -e "$FABRIK_DIR/packs/ejemplo/conocimiento" ]; then ok_
else fallo "AC-30 escribió en packs/ejemplo del repo del motor"; fi

# h) la memoria no responde: la lección queda en el fichero y el comando sale 0
leccion "$tmp/cfg-ab.yaml" "$MUERTO" api-acme "Memoria caida"
RC=$?
if [ "$RC" -eq 0 ] && hay "$dest/*-api-acme-memoria-caida.md" && grep -qF 'la lección queda en el fichero' "$tmp/out"; then ok_
else fallo "AC-30 con la memoria caída exit $RC o sin fichero: $(tail -3 "$tmp/out")"; fi

# i) FABRIK_HOME sin definir: el repo del motor (el del script) tampoco recibe nada
antes="$(git -C "$FABRIK_DIR" status --porcelain --ignored -- conocimiento 2>/dev/null)"
env -u FABRIK_HOME FABRIK_CONFIG="$tmp/cfg-ejemplo.yaml" FABRIK_MEMORIA_URL="$MUERTO" \
  python3 "$FABRIK_DIR/bin/fabrik-memoria" leccion --repo r --sintoma "Sin home" --causa c --solucion s --donde d \
  > "$tmp/out" 2>&1
despues="$(git -C "$FABRIK_DIR" status --porcelain --ignored -- conocimiento 2>/dev/null)"
if [ "$antes" = "$despues" ] && [ ! -e "$FABRIK_DIR/conocimiento" ] && hay "$FABRIK_DATA/conocimiento/lecciones/*-r-sin-home.md"; then ok_
else fallo "AC-30 sin FABRIK_HOME escribió en el repo del motor: $(cat "$tmp/out")"; fi

# j) fabrik config pack-dir: directorio y nombre del primer pack activo con la clave; exit 1 si ninguno
cfgget() { FABRIK_CONFIG="$1" uv run --with pyyaml python "$FABRIK_DIR/scripts/fabrik_config.py" "${@:2}"; }
d="$(cfgget "$tmp/cfg-ab.yaml" pack-dir memoria.banco 2>/dev/null)"
cfgget "$tmp/cfg-g.yaml" pack-dir memoria.banco > /dev/null 2>&1; RC=$?
if [ "$d" = "$(printf 'alfa\t%s\nbeta\t%s' "$tmp/packs/alfa" "$tmp/packs/beta")" ] && [ "$RC" -eq 1 ]; then ok_
else fallo "AC-30 pack-dir: salida='$d' sin-pack-rc=$RC"; fi

# ---------- AC-31: memoria_ingest.py lecciones ----------
# alfa tiene 2 lecciones (la de arriba + las siguientes), beta 1, el local de FABRIK_DATA otra; en FABRIK_HOME hay una
# trampa que NO debe leerse.
mkdir -p "$tmp/packs/beta/conocimiento/lecciones" "$FABRIK_HOME/conocimiento/lecciones"
cat > "$tmp/packs/beta/conocimiento/lecciones/2026-01-02-api-b-leccion-de-beta.md" <<'MD'
---
repo: api-b
fecha: 2026-01-02
etiquetas: [x]
---
**Síntoma:** s

**Causa:** c

**Solución:** x

**Dónde:** d
MD
cp "$tmp/packs/beta/conocimiento/lecciones/2026-01-02-api-b-leccion-de-beta.md" \
   "$FABRIK_HOME/conocimiento/lecciones/2026-01-02-api-b-trampa-del-motor.md"
rm -f "$tmp/packs/alfa/conocimiento/lecciones/"*-memoria-caida.md   # solo para contar: 1 de alfa (login) en este pack

ingest() { # <config> → $tmp/out
  : > "$tmp/http.log"
  env FABRIK_CONFIG="$1" FABRIK_MEMORIA_URL="$URL" \
    uv run --with pyyaml python "$FABRIK_DIR/scripts/memoria_ingest.py" lecciones > "$tmp/out" 2>&1
}
ids() { grep -oE '"document_id": "[^"]*"' "$tmp/http.log" | sed 's/"document_id": //' | sort; }

ingest "$tmp/cfg-ab.yaml"; RC=$?
esperados="$(printf '%s\n' \
  '"leccion/alfa/'"$(basename "$(compgen -G "$patron" | head -1)")"'"' \
  '"leccion/beta/2026-01-02-api-b-leccion-de-beta.md"' | sort)"
if [ "$RC" -ne 0 ]; then fallo "AC-31 ingest exit $RC: $(tail -3 "$tmp/out")"
elif ! ids | grep -qxF '"leccion/beta/2026-01-02-api-b-leccion-de-beta.md"'; then fallo "AC-31 no ingiere las lecciones del pack beta: $(ids)"
elif ! ids | grep -qE '^"leccion/alfa/[0-9]{4}-[0-9]{2}-[0-9]{2}-api-acme-falla-el-login-con-tilde\.md"$'; then fallo "AC-31 no ingiere las lecciones del pack alfa: $(ids)"
else ok_; fi

# b) no lee $FABRIK_HOME/conocimiento; ids estables (misma salida al repetir); sin duplicados
primero="$(ids)"
ingest "$tmp/cfg-ab.yaml"
if ids | grep -q 'trampa-del-motor'; then fallo "AC-31 ingiere \$FABRIK_HOME/conocimiento (debe dejar de leerlo)"
elif [ "$primero" != "$(ids)" ]; then fallo "AC-31 document_id no estable entre ejecuciones"
elif [ "$(ids | sort | uniq -d | wc -l)" -ne 0 ]; then fallo "AC-31 document_id duplicado"
else ok_; fi

# c) tags/metadata de cada lección: repo, fuente y pack de origen
if grep -qF '"repo:api-b"' "$tmp/http.log" && grep -qF '"fuente:leccion"' "$tmp/http.log" && grep -qF '"pack": "beta"' "$tmp/http.log"; then ok_
else fallo "AC-31 faltan tags/metadata (repo, fuente, pack): $(head -c 400 "$tmp/http.log")"; fi

# d) las lecciones de $FABRIK_DATA/conocimiento/lecciones (destino sin pack) también se ingieren, como pack «local»
if ingest "$tmp/cfg-g.yaml" && ids | grep -qE '^"leccion/local/[0-9]{4}-[0-9]{2}-[0-9]{2}-api-acme-sin-pack-con-banco\.md"$'; then ok_
else fallo "AC-31 no ingiere FABRIK_DATA/conocimiento/lecciones como «local»: $(ids)"; fi

# e) sin ningún pack con lecciones ni FABRIK_DATA → no falla y no envía nada
rm -rf "$FABRIK_DATA/conocimiento" "$tmp/packs/alfa/conocimiento" "$tmp/packs/beta/conocimiento"
ingest "$tmp/cfg-ab.yaml"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$(ids)" ]; then ok_; else fallo "AC-31 sin lecciones debía salir 0 sin enviar: rc=$RC ids=$(ids)"; fi

# ---------- AC-32: .gitignore del motor ----------
if grep -qxE '/?conocimiento/' "$FABRIK_DIR/.gitignore"; then ok_; else fallo "AC-32 .gitignore no ignora conocimiento/"; fi
if git -C "$FABRIK_DIR" check-ignore -q conocimiento/lecciones/x.md; then ok_; else fallo "AC-32 git no ignora conocimiento/lecciones/x.md en la raíz"; fi

# ---------- AC-33: sección de onboarding (las lecciones de la fase 1 se comprueban en el pack) ----------
ON="$FABRIK_DIR/docs/onboarding.md"
ultima="$(grep -n '^## ' "$ON" | tail -1)"
if [ "${ultima#*:}" = "## Lecciones compartidas" ]; then ok_; else fallo "AC-33 la última sección de onboarding.md no es «Lecciones compartidas»: $ultima"; fi
seccion="$(sed -n '/^## Lecciones compartidas/,$p' "$ON")"
if printf '%s' "$seccion" | grep -qF 'conocimiento/lecciones' && printf '%s' "$seccion" | grep -qiE 'PR' \
   && printf '%s' "$seccion" | grep -qF 'main' && printf '%s' "$seccion" | grep -qF 'FABRIK_DATA'; then ok_
else fallo "AC-33 la sección «Lecciones compartidas» no explica destino, FABRIK_DATA, rama + PR y no empujar a main"; fi

echo "$ok ok / $fail fallos"
[ "$fail" -eq 0 ]
