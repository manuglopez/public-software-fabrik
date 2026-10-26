# software-fabrik

Fábrica de software multiagente sobre [Hermes Agent](https://github.com/NousResearch/hermes-agent). Un
**orquestador** convierte una petición aprobada en tarjetas de Kanban; especialistas (programador, tester,
revisor, explorador, seguridad, docs), cada uno con el modelo que elijas, las ejecutan y entregan PRs listos
para revisar. El humano aprueba tres cosas: la spec, el plan de tarjetas y el merge.

Aislamiento: **un worktree (rama + base de datos propia) por feature**, un clon de fábrica por proyecto y nunca
tu checkout. Los tests pasan por `factory-test` (turno único para suites pesadas y lock por base de datos) para no pisarse.

## Las tres capas

| Capa | Dónde vive | Qué contiene |
|---|---|---|
| **Motor** | este repo (`bin/`, `scripts/`, `profiles/`, `plugin/`, `docs/`) | Herramientas, perfiles genéricos, flujos y skill `/fabrica`. Sin nombres de ninguna organización. |
| **Packs** | `packs/<nombre>/` (o un repo git aparte) | Lo propio de una organización: owners, tableros, repos calientes, reglas añadidas a los perfiles, documentos y denylist. Se parte de [`packs/ejemplo`](packs/ejemplo/pack.yaml). |
| **Config personal** | `~/.config/fabrica/fabrik.yaml` | Tu usuario de GitHub, tus `owners`, qué packs activas y tus modelos por rol. Nunca se versiona. |

La config se fusiona en ese orden: motor < packs < personal (gana lo último). `fabrik config ver` muestra el
resultado.

## Requisitos

- [Hermes Agent](https://hermes-agent.nousresearch.com/docs) (`hermes`), con al menos un proveedor de modelos con login o clave.
- `git`, `gh` (con `gh auth login`), `uv`, `python3`, `flock` y `systemctl --user` (systemd de usuario).
- [Spec Kit](https://github.com/github/spec-kit) (`specify`) para el flujo de features.
- Opcionales: MariaDB (base de datos propia por worktree para repos PHP/Laravel), `greptile` (revisión local) y
  `age` (exportar/importar datos entre máquinas).

## Instalación

```bash
git clone <url-de-este-repo> ~/Code/software-fabrik && cd ~/Code/software-fabrik
./install.sh --comprobar
./install.sh
```

`./install.sh --comprobar` no instala nada: lista requisitos, logins y claves, y marca con ✗ lo que falta.
`./install.sh` crea tu config personal y configura perfiles, tableros y servicios de usuario (memoria compartida
opcional con `FABRIK_MEMORIA=si`). Para añadir el pack de tu organización (carpeta local o URL git):

```bash
./install.sh --pack git@github.com:acme/fabrica-pack-acme.git
```

El motor no lleva packs de organizaciones: `packs/*` está en `.gitignore` salvo `packs/ejemplo`. Un pack se instala
siempre con `--pack` (se enlaza o se clona en `$FABRIK_DATA/packs/<nombre>`) y se identifica por el `nombre:` de su
`pack.yaml`, no por el de la carpeta. Sin `--pack` y sin ningún pack instalado rige `packs/ejemplo` (`install.sh`
lo avisa). Los roles, el pool y la reserva final de modelos son personales: van en `~/.config/fabrica/fabrik.yaml`.
Todas las opciones: `./install.sh --help`.
Si te unes a una organización que ya tiene pack, sigue [`docs/onboarding.md`](docs/onboarding.md).

## Primer uso

Abre Hermes Desktop → Capacidades → Plugins → Plugins de escritorio → activa **Kanban** y, en el chat con el
orquestador:

```text
/fabrica estado
/fabrica feature <repo> "<qué quieres>"
```

`/fabrica estado` resume por tablero lo que está en marcha, bloqueado o en revisión, los PRs abiertos con etiqueta
`agente` y el turno de tests. `/fabrica feature` abre el flujo F2: el orquestador propone spec y plan, tú los
apruebas y los especialistas trabajan.

## Contenido

| Ruta | Qué es |
|---|---|
| [`docs/DESIGN.md`](docs/DESIGN.md) | Diseño vivo: decisiones, roles, modelos, límites. **Empieza aquí.** |
| [`docs/flows/C0-ciclo-tarjeta-codigo.md`](docs/flows/C0-ciclo-tarjeta-codigo.md) | Flujo C0: ciclo de una tarjeta de código (TDD, revisión, PR, CI). |
| [`docs/flows/F2-feature.md`](docs/flows/F2-feature.md) | Flujo F2: de «nueva feature» a «plan listo para aprobar». |
| [`docs/onboarding.md`](docs/onboarding.md) | Alta de un compañero en una organización que ya tiene pack. |
| [`docs/crear-pack.md`](docs/crear-pack.md) | Crear el pack de tu organización. |
| [`docs/publicar.md`](docs/publicar.md) | Publicar el motor sin datos privados. |
| `bin/` | Herramientas: `fabrik` (comando paraguas), `factory-test` (turnos y locks de tests), `factory-prep` (worktree + BD propia), `factory-juntar`, `factory-gc` (limpieza), `factory-greptile` (Greptile local: una vez por rama, caché por diff), `greptile` (envoltorio del CLI: `review` → `factory-greptile`; el resto pasa directo), `fabrik-cupos` (cupos; `semana`: coste y rondas por tablero), `fabrik-memoria`, `fabrik-exportar` / `fabrik-importar`. |
| `scripts/` | `build_portfolio.py` (catálogo de repos; `--seco` para probar, no pisa un portfolio de otra org sin `--forzar`), `apply_profile_policy.py` (modelos, herramientas y comandos prohibidos por perfil), `fabrik_config.py` (config fusionada). |
| `profiles/` | Perfiles de Hermes empaquetados (SOUL en plantilla, comunes a todas las organizaciones). |
| `plugin/` | Skill `/fabrica` de Hermes. |
| `config/` | Plantillas: `fabrik.yaml.ejemplo`, units de systemd, configuración de producción de ejemplo. |

## Qué NO vive aquí

Tu config personal, el catálogo generado `~/.hermes/factory/portfolio.yaml`, los tableros Kanban, las sesiones, la
memoria y las claves y logins (`~/.hermes/.env`, `gh`, proveedores). Nada de eso se versiona. Para llevarlo a otra
máquina: `fabrik-exportar <carpeta>` (cifrado con `age`) y `fabrik-importar <fichero>`.

## Turno de tests (`factory-test`)

Todas las ejecuciones de tests (agentes y sesiones del usuario) pasan por `factory-test -- <comando>`. El motor clasifica la ejecución en tres clases para maximizar el paralelismo sin colapsar la máquina ni pisar bases de datos. El tope de procesos en paralelo, la pausa de Dusk y la MariaDB en modo tests (con medidas) están en `docs/tests-compartidos.md`.

1. **Pesados (turno único en toda la máquina):** la suite completa o paralela (`-p N` con N>1, `--processes`, `--parallel`, paratest, infection, dusk) de un repo marcado como pesado. También el `phpunit-replay` que se degrada a suite completa (`--fresh`, `record` o aviso de baseline nuevo). Ante la duda (`bash -c`, `composer test`, runner desconocido en repo pesado), coge turno.
2. **Dirigidos (sin turno global, máx. concurrentes):** en un repo pesado, un runner conocido (`phpunit`, `pest`, `artisan test`, `jest`, `vitest`, `pytest`) con selector (`--filter`, `--group` o una ruta de tests; `tests/` o `--testsuite` solos no cuentan) y el `phpunit-replay` normal (antes de lanzarlo se hace un `run --dry-run`, máx. `FX_TEST_DRYRUN_TIMEOUT`, def. 60 s: si dice que se degrada a suite completa o falla, va a pesado; un replay paralelo de un repo de `tests.replay_simultaneo` entra en un hueco de `locks/replay.d/` y puede correr a la vez que otro: ver `docs/tests-compartidos.md`). En un repo que **no** sea pesado, cualquier cosa (también su suite completa y su `-p N`, rebajado al tope de 4 procesos). Usan huecos en `locks/dirigidos.d/` (máx. `FX_TEST_DIRIGIDOS`, por defecto 4, o `tests.dirigidos` en la config; la env manda; un valor no numérico o 0 vale 4).
3. **Ligeros (sin BD ni turno global):** un comando cuyo ejecutable (tras `env` y las `VAR=val` iniciales) es `bash sh zsh node shellcheck bats python python3 true false` **y** ninguna palabra de toda la línea (tampoco dentro de `bash -c "…"`) es `php phpunit paratest pest artisan phpunit-replay dusk vitest jest playwright pytest composer npm npx yarn pnpm make mysql mariadb psql`. Usan huecos en `locks/ligeros.d/` (máx. `FX_TEST_LIGEROS`, por defecto 3). `FX_TEST_PESADO=1` fuerza cola pesada (úsalo si tu script lanza PHP por dentro); `FX_TEST_LIGERO=1` fuerza ligero; si coinciden gana pesado.

**Una BD, un run:** todo run dirigido o pesado toma, después del hueco o del turno, un lock por **BD efectiva** (`locks/bd.d/<clave>.lock`, con la clave `DB_HOST:DB_PORT/DB_DATABASE` de `.factory/env` saneada para el nombre de fichero; sin `.factory/env`, el toplevel de git; vale para MariaDB y PostgreSQL). Dos ejecuciones nunca comparten base de datos a la vez; si coinciden, la segunda espera a que la primera termine (dentro de `FX_TEST_WAIT`). Los ligeros no toman lock de BD.

**Repos con BD de tests fija** (su guard solo acepta `<base>_test` y `<base>_test_<n>`, así que todos los worktrees compartirían BD): la lista `tests.repos_token` (o `FX_TEST_REPOS_TOKEN`, separada por espacios; sin lista, ningún repo) hace que un run **dirigido no paralelo** exporte `LARAVEL_PARALLEL_TESTING=1` y `TEST_TOKEN=100+<hueco de dirigidos>` (si quien llama ya trae `TEST_TOKEN`, no se toca). Laravel crea y migra la BD `<base>_test_<token>` y se reutiliza entre runs; el lock de BD usa esa clave y `estado` la muestra (`bd=…_test_101`). Los tokens empiezan en 101 para no chocar con los 1..N de paratest. Los pesados y los paralelos (`-p N`) van sin token y bloquean la BD base. El replay sin `-p` lleva token como un dirigido.

**Repos pesados:** lista `tests.repos_pesados` en la configuración (`fabrik config`, motor < pack < personal), por ejemplo `tests.repos_pesados: [api-acme]`. El nombre del repo es `FX_REPO` de `.factory/env` o, si no, el basename del toplevel de git. La variable de entorno `FX_TEST_REPOS_PESADOS` (separada por espacios) manda sobre la config, y vacía significa ningún repo pesado. Si la lista no está configurada (o la config no se puede leer), **todos los repos son pesados** por seguridad.

`factory-test estado` muestra el proceso pesado activo y su cola, una línea `dirigido: … bd=…` por cada dirigido activo y las líneas `ligero: …`.

**Prioridad en la cola pesada:** `flock` no garantiza orden; `$FABRIK_DATA/locks/prioridad` contiene patrones de repo (o `FX_TEST_PRIO=1`) para ordenar la espera mediante `locks/prio.d/<pid>`. Quien no tiene prioridad cede el turno si hay alguien esperando con ella. No interrumpe la suite en marcha. Tiempo de espera máximo: `FX_TEST_WAIT` (segundos, por defecto 7200). Los logs completos van a `$FABRIK_DATA/logs/tests/` y por pantalla sale solo el resumen.

```bash
cp packs/ejemplo/config/prioridad ~/.hermes/factory/locks/prioridad
factory-test estado
```

## Cupos y reparto de modelos (`fabrik-cupos`, `fabrik-modelos`)

`fabrik-cupos` fotografía lo que queda en cada bolsa (cada cuenta de Claude con `claude -p "/usage"` y su
`CLAUDE_CONFIG_DIR`, una bolsa por cuenta: `claude_5h@a`, `claude_sem@a`…; Kimi, Gemini y Antigravity aparte) y
`fabrik-modelos` reparte con esa foto el modelo y la cuenta de cada perfil:

```bash
fabrik-modelos tick                 # cada 10 min: refresca la foto si tiene > 3 min, reparte, avisa y comprueba el canal
fabrik-modelos asignar <tablero>    # (lo llama fabrik-triage) modelo a las tarjetas ready sin modelo
fabrik-modelos informe 7 --json     # calidad por modelo en los últimos 7 días
fabrik-modelos estado --json        # qué ruta está disponible ahora; por cuenta: % semanal, horas al reset, margen/hora
fabrik-modelos comprobar --json     # ¿el canal de avisos aguanta que se agote la bolsa Claude? (exit 1 si hay ⛔)
```

`comprobar` falla si el perfil `default` no tiene `fallback_providers` fuera de la bolsa de su modelo principal, o si
un cron de aviso con modelo fijado usa una bolsa de Anthropic. Cuando una bolsa cruza `modelos.reparto.aviso_bolsa`
(98 % por defecto, en tu `~/.config/fabrica/fabrik.yaml`) llega un `hermes send` (sin modelo) a `${FABRIK_AVISO:-telegram}`
con la bolsa, lo que queda y qué roles se han conmutado. Detalle en `docs/DESIGN.md` (§ 4s).

## Tests

Cada suite es un script de bash autocontenido (HOME temporal, sin red): `bash tests/<nombre>_test.sh`.
`tests/sin_privado_test.sh` es el guardián que impide que el motor contenga nombres, rutas o hosts privados, y
`tests/docs_test.sh` comprueba que los comandos de estos documentos existen.

## Licencia

[MIT](LICENSE).
