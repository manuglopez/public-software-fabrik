# Spec · Revisión proporcional, auto-chequeo ampliado y Greptile acotado

Talla M. Repo `software-fabrik`, base `main`. Tarjeta raíz `t_bc134f7e`. Esta spec cubre la parte de **documentación y SOUL**
(tarjeta IMPL-A `t_cdac7fb4`, revisión ligera); los scripts los llevan `IMPL-G` (`bin/factory-greptile`) e `IMPL-B`
(métrica `fabrik-cupos semana`), cada uno con sus criterios en su tarjeta.

## Petición

Bajar el coste de revisar sin bajar la calidad. Tres focos, sacados del informe de motivos de la tarjeta raíz
(comentario 217, 40 `changes_requested` del tester):

- **29 de 40** por tests que no protegen el cambio (mutantes vivos, MSI) y **12** por cobertura (7 de ellas, ramas de
  error sin cubrir); **5** por handoff no verificable. Las tarjetas pequeñas de interfaz o textos pasaban por el mismo
  listón (cobertura ≥ 98 % + mutantes) que la lógica de dominio.
- El auto-chequeo del PR #6 nunca llegó a los SOUL activos (se generaron antes de su merge), así que el programador
  seguía pidiendo revisión sin él. FIN regenera los SOUL con `--solo-soul`.
- Greptile local (~1 $ por ejecución) se repetía en cada ronda del PR, cuando el Greptile de GitHub ya revisa en cada push.

## Decisiones (las fija el orquestador)

- **D1 · Revisión proporcional.** El orquestador escribe en el cuerpo de cada IMPL/FIX una línea `Revisión: ligera` o
  `Revisión: completa`; sin marca se entiende `completa`.
  - **Ligera**: solo tarjetas **talla S** cuyo diff es **solo de interfaz o markup** (Blade/plantillas/HTML, CSS,
    copys/traducciones, documentación y textos de SOUL/prompts) **sin lógica de servidor**. Se revisa: tests en verde,
    cada AC con su test (matriz), sin flakes con **3 semillas** aleatorias y calidad de los tests. **Sin** mutantes ni
    umbral de cobertura del 98 %.
  - **Siempre completa** (cobertura del diff ≥ 98 % + mutantes, MSI ≥ 85 %): lógica de dominio o backend (PHP, Python,
    bash o JS con decisiones), seguridad y auth, pagos y facturación, migraciones y BD, tenancy y RBAC, contratos de API,
    despliegue y config de producción, y cualquier tarjeta M o L.
  - Si el tester ve lógica en el diff de una tarjeta marcada ligera, **escala a completa** y lo anota en `findings`
    (sin `request_changes` solo por eso). El tester deja `metadata.revision = "ligera"|"completa"`.
- **D2 · Auto-chequeo ampliado del programador**, antes de pedir revisión y en la revisión completa:
  (a) cada condición, constante y valor límite del diff, mutada, con casos justo en el límite (97/98/99 para un umbral de 98)
  y de null/ausente; (b) inventario de ramas de error y de null (`catch`/`except`/`||`/`??`/fallo de comando externo),
  cada una con su test; (c) handoff verificable (`git status --porcelain` vacío, `metadata.commit` = `git rev-parse HEAD`,
  test relanzado tras el último commit, artefactos al día, `sin_privado` en verde).
- **D3 · Greptile acotado.** El Greptile local solo con `factory-greptile` (caché por `HEAD` + merge-base, tope
  `FX_GREPTILE_TOPE=1` por rama, registro `greptile.jsonl`), una vez, con los tests en verde y tras `/code-review`. Las
  rondas del PR las comprueba el Greptile de GitHub, sin CLI local entre pushes.
- **D4 · Métrica.** `fabrik-cupos semana`; coste equivalente = `in + cw + 0,1·cr + 5·out`; sesión → tarjeta por
  `kanban task t_…` en el primer mensaje (IMPL-B).

## Criterios de aceptación (esta tarjeta)

- **AC-1** C0 tiene una sección «Revisión proporcional» con: ligera (qué se revisa y qué no), completa, la lista de
  tipos que siempre llevan la completa (D1), la línea `Revisión: ligera|completa` del orquestador (sin marca =
  completa) y el escalado del tester. La tabla de tarjetas y el checklist del tester la remiten. `profiles/tester.md` y
  `profiles/programador.md` distinguen ligera y completa con la misma lista. `profiles/orquestador.md` obliga a marcar
  `Revisión:` en cada IMPL/FIX.
- **AC-2** `profiles/programador.md` y la fila IMPL de C0 llevan el auto-chequeo D2 (a), (b) y (c), con el porqué en una
  línea («motivos más frecuentes de changes_requested: tests que no protegen, ramas de error sin cubrir, handoff no
  verificable»).
- **AC-4** `tests/sin_privado_test.sh` en verde.
- **AC-5** (Greptile, D3) C0, `programador.md` (CIERRE-LOCAL y PR) y `revisor.md`: Greptile local solo con
  `factory-greptile`, una vez, con tests verdes y tras `/code-review`; rondas del PR con el Greptile de GitHub, sin CLI
  local entre pushes. No queda ninguna instrucción `greptile review` directa ni «pasando antes Greptile CLI local» en
  los SOUL ni en C0. `orquestador.md` sigue diciendo Greptile 5/5, pero del de GitHub.

## Tests

`tests/soul_test.sh`, bloques marcados `# AC-1`, `# AC-2` y `# AC-5`: aserciones con frases literales sobre los SOUL
generados (`apply_profile_policy.py --solo-soul` con el pack de fixture) de programador, tester, orquestador y revisor, y
sobre C0. Las ausencias (`greptile review`, `pasando antes`, `Greptile CLI local`) también se comprueban.

## Fuera de alcance

`bin/`, `scripts/`, `README.md` y `docs/DESIGN.md` (IMPL-G, IMPL-B y FIN). El despliegue de los SOUL en el perfil activo lo
hace FIN con `--solo-soul`.
