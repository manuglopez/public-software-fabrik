# Crear el pack de tu organización

El **motor** (este repo) es genérico. Todo lo propio de una organización vive en un **pack**: una carpeta con un
`pack.yaml` y, opcionalmente, reglas para los perfiles, documentos, una denylist y conocimiento. Un pack puede ir
en un repo git propio (con `pack.yaml` en la raíz) que los compañeros instalan con `./install.sh --pack <url>`.
El motor no admite packs privados dentro de su árbol (`packs/*` está ignorado salvo `packs/ejemplo`). Esta guía parte de [`packs/ejemplo`](../packs/ejemplo/pack.yaml), una organización
ficticia (`acme`).

## Estructura

```text
packs/<nombre>/
├── pack.yaml         obligatorio: owners, tableros, repos calientes, memoria
├── profiles/         opcional: reglas que se AÑADEN al SOUL de cada rol
│   ├── _comun.md         se añade al SOUL de todos los roles
│   └── <rol>.md          orquestador, explorador, programador, tester, revisor, seguridad, docs
├── docs/             opcional: documentos de la organización (flujos propios, bitácora, diseño)
├── denylist.txt      opcional: términos que no pueden aparecer en el motor (lo usa el guardián)
├── config/           opcional: plantillas de configuración de la organización
├── conocimiento/     opcional: lecciones y notas de la organización (texto legible)
└── tests/            opcional: tests y fixtures que dependen de este pack concreto
```

## Paso a paso

1. Copia el ejemplo y renómbralo (el nombre de la carpeta es el nombre del pack):

   ```bash
   cp -r packs/ejemplo packs/mi-org
   ```

2. Edita `packs/mi-org/pack.yaml`. Campos:

   | Campo | Qué es |
   |---|---|
   | `nombre`, `titulo` | Identificador y nombre legible. `titulo` se usa en las cabeceras de los SOUL (`{{titulo}}`). |
   | `owners` | Cuentas u organizaciones de GitHub cuyos repos gestiona la fábrica. |
   | `extra_repos` | Repos sueltos `propietario/repo` fuera de `owners`. |
   | `tableros` | Lista de `slug`, `nombre`, `descripcion`, `icono`: un tablero de Kanban por producto o equipo. |
   | `tablero_por_defecto` | Tablero para los repos que no encajan en ninguno. |
   | `repos_calientes` | Repos con trabajo habitual: se priorizan en el portfolio y en `/fabrica estado`. |
   | `base_por_defecto` | Rama base de los PRs (`main`, `develop`…). |
   | `memoria` | `banco`, `nombre` y `descripcion` del banco de memoria compartida (opcional). |
   | `modelos` | Opcional: solo `permitir_pago`. Roles, `pool` y `reserva_final` son personales (ver sección abajo). |

3. Añade reglas de organización a los perfiles. En `profiles/_comun.md` va lo que cambia el comportamiento de todos
   los roles (por ejemplo, convenciones de base de datos o de despliegue); en `profiles/<rol>.md`, lo de un rol. El
   SOUL final de un rol se compone en este orden: `profiles/<rol>.md` del motor + `<rol>.md` de cada pack activo +
   `_comun.md` del motor + `_comun.md` de cada pack activo. Las variables `{{titulo}}`, `{{owners}}` y
   `{{repos_calientes}}` se sustituyen con los valores de la config; una variable desconocida hace fallar la
   generación y se nombra en el error.

4. Rellena `denylist.txt`: un término privado por línea (nombre de la organización, de sus productos, de personas),
   `#` para comentarios. El guardián `tests/sin_privado_test.sh` falla si alguno aparece en el motor, que es lo que
   protege la publicación (ver [`publicar.md`](publicar.md)). El pack `ejemplo` no tiene denylist: no hay nada que ocultar.

5. Compruébalo antes de activarlo:

   ```bash
   ./install.sh --comprobar --pack packs/mi-org
   uv run --with pyyaml python scripts/apply_profile_policy.py --solo-soul --seco
   ```

   `--comprobar` no escribe nada: valida el pack y avisa de lo que haría la instalación. `--solo-soul --seco`
   genera los SOUL sin escribir nada, así que detecta variables mal escritas o perfiles vacíos.
   Para activarlo de verdad ejecuta `./install.sh --pack packs/mi-org`; después `fabrik config ver` debe mostrar tus
   `owners` y tableros fusionados con los del motor.

6. Si el pack va en un repo propio, súbelo (`git init` dentro de `packs/mi-org` o clónalo en otra ruta) y pasa su URL
   a tus compañeros: ver [`onboarding.md`](onboarding.md).

---

## Modelos: `permitir_pago` en el pack; pool y reserva final, personales

Los modelos son **personales**: los roles, el `pool` y la `reserva_final` los define cada usuario en su
`~/.config/fabrica/fabrik.yaml` (`install.sh` los propone según los proveedores que detecta). Un pack
**solo fija `permitir_pago`**, la política de la organización sobre proveedores de pago:

```yaml
modelos:
  permitir_pago: false            # bool opcional (false por defecto)
```

El motor trae solo un valor genérico (proveedor `anthropic`, sin reserva, sin pool y `reserva_final: null`). No
pongas modelos concretos de tu organización en el pack: cada persona tiene proveedores distintos y un pack con
modelos obliga a todos a tener los mismos.

El pool y la reserva final se escriben así, en la config personal:

```yaml
modelos:
  reserva_final:                  # {proveedor, modelo} o null para anular
    proveedor: proveedor-suscripcion
    modelo: modelo-reserva
  pool:                           # niveles canónicos: ligero, medio, dificil, critico
    ligero:
      - {proveedor: proveedor-oauth, modelo: modelo-flash, herramientas: false, coste: suscripcion}
    medio:
      - {proveedor: proveedor-oauth, modelo: modelo-medio, herramientas: true, coste: suscripcion}
      - {proveedor: proveedor-api, modelo: modelo-pago, herramientas: true, coste: pago}
    dificil:
      - {proveedor: proveedor-suscripcion, modelo: modelo-dificil, herramientas: true, coste: suscripcion}
    critico:
      - {proveedor: proveedor-suscripcion, modelo: modelo-critico, herramientas: true, coste: suscripcion}
```

### Claves del bloque

- `permitir_pago` (lo fija el pack): booleano (`false` por defecto). Si es `false`, las entradas con `coste: pago` se ignoran en el pool activo y `install.sh` no las propone.
- `reserva_final`: par `{proveedor, modelo}` que se inyecta como última opción en `fallback_providers` de todos los perfiles gestionados por la fábrica. Si se define `reserva_final: null`, se desactiva.
- `pool`: niveles canónicos (`ligero`, `medio`, `dificil`, `critico`), ordenados por preferencia de coste (el más barato primero). Cada entrada declara:
  - `proveedor` y `modelo`: strings no vacíos con los identificadores.
  - `herramientas`: booleano obligatorio (`true` si admite tool-calling).
  - `coste`: `suscripcion` o `pago` (obligatorio).

### Reglas de fusión (motor < pack < personal)

La configuración se resuelve fusionando las tres capas: motor por defecto, pack(s) activo(s) y configuración personal (`~/.config/fabrica/config.yaml`).

1. **Nivel del pool**: un nivel definido en una capa superior **reemplaza por completo** la lista de modelos de ese nivel de las capas inferiores (no se mezclan ni concatenan). Los niveles no especificados se heredan.
2. **Reserva final**: la `reserva_final` de una capa superior reemplaza la de las capas inferiores. Indicar `reserva_final: null` en una capa superior la anula explícitamente.
3. **Roles individuales**: los roles de `modelos` (`orquestador`, `programador`, etc.) se fusionan rol por rol sin sobrescribir las claves reservadas del pool ni los roles omitidos.

## Qué va en el pack y qué en el motor

- **Pack**: nombres de organización, productos, personas, repos y tableros concretos; reglas de negocio que solo
  tienen sentido en esa organización; documentos de diseño propios; tests que necesitan datos de ese pack.
- **Motor**: todo lo que serviría igual a otra organización. Si una regla del pack es en realidad general, súbela
  al motor y bórrala del pack.

Regla práctica: si al mirar un fichero del motor reconoces un nombre propio de tu organización, ese fichero (o esa
línea) debe pasar al pack. El guardián lo detecta si el nombre está en tu `denylist.txt`.

## Varios packs

`packs:` en tu config personal admite una lista; se fusionan en orden (los tableros y `owners` se suman, los
valores simples los pisa el último) y por encima de todos queda tu config personal. Sin clave `packs`, se activan
todos los packs de `packs/` excepto `ejemplo`; con `packs: []` no se activa ninguno y se usa `ejemplo`.
