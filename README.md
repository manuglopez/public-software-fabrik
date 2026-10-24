# software-fabrik

Fábrica de software multiagente sobre [Hermes Agent](https://github.com/NousResearch/hermes-agent). Un
**orquestador** convierte una petición aprobada en tarjetas de Kanban; especialistas (programador, tester,
revisor, explorador, seguridad, docs), cada uno con el modelo que elijas, las ejecutan y entregan PRs listos
para revisar. El humano aprueba tres cosas: la spec, el plan de tarjetas y el merge.

Aislamiento: **un worktree (rama + base de datos propia) por feature**, un clon de fábrica por proyecto y nunca
tu checkout. Los tests pasan por un turno único de toda la máquina para no pisarse.

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
| `bin/` | Herramientas: `fabrik` (comando paraguas), `factory-test` (turno único de suites), `factory-prep` (worktree + BD propia), `factory-juntar`, `factory-gc` (limpieza), `fabrik-memoria`, `fabrik-exportar` / `fabrik-importar`. |
| `scripts/` | `build_portfolio.py` (catálogo de repos), `apply_profile_policy.py` (modelos, herramientas y comandos prohibidos por perfil), `fabrik_config.py` (config fusionada). |
| `profiles/` | Perfiles de Hermes empaquetados (SOUL en plantilla, comunes a todas las organizaciones). |
| `plugin/` | Skill `/fabrica` de Hermes. |
| `config/` | Plantillas: `fabrik.yaml.ejemplo`, units de systemd, configuración de producción de ejemplo. |

## Qué NO vive aquí

Tu config personal, el catálogo generado `~/.hermes/factory/portfolio.yaml`, los tableros Kanban, las sesiones, la
memoria y las claves y logins (`~/.hermes/.env`, `gh`, proveedores). Nada de eso se versiona. Para llevarlo a otra
máquina: `fabrik-exportar <carpeta>` (cifrado con `age`) y `fabrik-importar <fichero>`.

## Tests

Cada suite es un script de bash autocontenido (HOME temporal, sin red): `bash tests/<nombre>_test.sh`.
`tests/sin_privado_test.sh` es el guardián que impide que el motor contenga nombres, rutas o hosts privados, y
`tests/docs_test.sh` comprueba que los comandos de estos documentos existen.

## Licencia

[MIT](LICENSE).
