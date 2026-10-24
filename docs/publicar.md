# Publicar el motor sin datos privados

El motor ya no lleva packs privados: cada organización tiene el suyo en un repo aparte que se instala con
`./install.sh --pack` (`packs/*` está ignorado salvo `packs/ejemplo`). Aun así el procedimiento mantiene el bucle de
exclusión como **red de seguridad** (por si alguien fuerza un pack dentro de `packs/`) y el guardián reúne las
denylists externas (las de los packs instalados). El repo **público** solo lleva el motor y `packs/ejemplo`, y
arranca con **un solo commit**: así no se filtra nada de la historia anterior. Este documento es el procedimiento;
el destino concreto de cada organización va en su pack (por ejemplo `docs/publicar-<org>.md` dentro de él).

## Qué NO puede salir

- Todo `packs/<nombre>` salvo `packs/ejemplo`.
- Secretos: `.env`, claves, tokens, `portfolio.yaml`, bases de datos (ya están en `.gitignore`).
- La historia de git del repo privado.

## Procedimiento

1. **Parte de un árbol limpio y commiteado.** `git archive` solo exporta lo commiteado; lo que no esté en `HEAD`
   no se publica.

   ```bash
   git status --short
   ```

2. **Guardián en verde.** El motor no debe contener términos de ninguna denylist, rutas personales, IPs ni hosts
   privados. Las excepciones justificadas están en `tests/sin_privado.permitidos`.

   ```bash
   bash tests/sin_privado_test.sh
   bash tests/docs_test.sh
   ```

3. **Exporta `HEAD` sin los packs privados, hacia un repo nuevo con un solo commit.** Este bloque
   es el que ejecuta `tests/docs_test.sh`: si lo cambias, el test sigue comprobando el resultado.

   ```bash
   # test: ejecutar
   DEST="${DEST:-$HOME/publico}"
   mkdir -p "$DEST"
   EXCLUIR=()
   for p in $(git ls-files -- packs | cut -d/ -f1-2 | sort -u | grep -vx 'packs/ejemplo'); do
     EXCLUIR+=(":(exclude)$p")
   done
   git archive HEAD -- . "${EXCLUIR[@]}" | tar -x -C "$DEST"
   git -C "$DEST" init -q -b main
   git -C "$DEST" add -A
   git -C "$DEST" -c user.name="${GIT_AUTHOR_NAME:-publicador}" -c user.email="${GIT_AUTHOR_EMAIL:-publicador@localhost}" \
     commit -q -m "software-fabrik: versión pública inicial"
   ```

   `DEST` debe ser una carpeta nueva o vacía. Antes de seguir, revisa que contiene lo esperado
   (`git -C "$DEST" ls-files | head -50`): `LICENSE`, `README.md`, `bin/`, `docs/`, `packs/ejemplo/`… y nada más
   en `packs/`.

4. **Comprueba el árbol publicado, no solo el privado.** El guardián imprime cuántos términos de denylists
   externas ha reunido (con tu pack instalado, N > 0); sin ninguna avisa pero no falla y sigue exigiendo cero
   coincidencias de rutas, IPs y hosts:

   ```bash
   cd "$DEST" && bash tests/sin_privado_test.sh && bash tests/soul_test.sh
   ```

5. **Escanea secretos.** Si está instalado `gitleaks` o `trufflehog`, pásalo por el árbol y su único commit
   (si no lo tienes, instálalo; un escaneo con `grep` no lo sustituye):

   ```bash
   gitleaks detect --source "$DEST" --no-banner
   trufflehog git "file://$DEST" --only-verified
   ```

6. **Publica.** El repo público debe existir y estar vacío. Usa tu usuario y el nombre que le hayas dado:

   ```bash
   git -C "$DEST" remote add origin git@github.com:<tu-usuario>/<repo-publico>.git
   git -C "$DEST" push -u origin main
   ```

   La publicación es siempre un acto humano: la fábrica prepara el árbol, pero el `push` al repo público lo
   haces tú.

## Lista de comprobación

- [ ] `git status` limpio y todo commiteado en el repo de trabajo.
- [ ] `tests/sin_privado_test.sh` en verde en el repo de trabajo **y** en el árbol publicado.
- [ ] `packs/` del árbol publicado contiene solo `ejemplo`.
- [ ] `LICENSE` presente; el README no nombra a ninguna organización.
- [ ] El árbol publicado tiene exactamente un commit (`git -C "$DEST" rev-list --count HEAD` devuelve `1`).
- [ ] `gitleaks` o `trufflehog` sin hallazgos.
- [ ] Revisión humana de `git -C "$DEST" ls-files`.

## Sincronizar después

Publicar una vez no actualiza el público: cada versión nueva repite el procedimiento sobre un `DEST` limpio.
Para conservar historia en el público a partir de la segunda versión, clona el público, copia encima el nuevo árbol
exportado (pasos 1–3) y haz un commit normal; la regla de oro sigue igual: jamás empujes la historia del repo
privado.
