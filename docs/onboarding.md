# Onboarding: alta de un compañero en una organización con pack

Esta guía es para quien se une a una organización que **ya tiene un pack** (repo git con `pack.yaml`, perfiles,
documentos y denylist de la organización). Al terminar tendrás la fábrica instalada con el pack de la
organización, tus repos personales añadidos y el Kanban visible en el escritorio. Si aún no hay pack, créalo antes
con [`crear-pack.md`](crear-pack.md).

En los ejemplos, `acme` es la organización y `tu-usuario` tu cuenta de GitHub.

## 1. Requisitos y logins

Instala lo que falta de la lista del [README](../README.md#requisitos) y haz login en cada servicio (lo pones tú:
la fábrica nunca guarda ni pide contraseñas):

```bash
gh auth login
```

- **`gh`**: con una cuenta que pertenezca a la organización. La fábrica lee y publica PRs con tus credenciales; los
  perfiles de los agentes tienen prohibido hacer merge, empujar a ramas protegidas y usar `--force`.
- **Proveedores de modelos**: según los modelos que vayas a usar (paso 3). Los de suscripción se activan con su
  plugin de Hermes y un login (por ejemplo `agy login` para Antigravity, o el plugin de la suscripción de Claude);
  los de API necesitan su clave en `~/.hermes/.env`.

## 2. Clonar el motor e instalar con el pack

```bash
git clone <url-de-este-repo> ~/Code/software-fabrik && cd ~/Code/software-fabrik
./install.sh --comprobar
```

La comprobación marca con ✗ lo que falta (requisitos, logins, claves). Resuélvelo y repítela hasta ver `Todo listo.`
Después instala con el pack de la organización:

```bash
./install.sh --pack git@github.com:acme/fabrica-pack-acme.git
```

`--pack` acepta una carpeta local o una URL git (`git@…`, `ssh://…`, `https://…`). Una URL se clona una sola vez en
`~/.hermes/factory/packs/<nombre>`; una carpeta local se enlaza. En ambos casos el pack queda anotado en `packs:` de
tu config personal. Repetir el comando no duplica nada.

## 3. Modelos y claves

`install.sh` detecta qué proveedores tienes y **propone** en `modelos:` de `~/.config/fabrica/fabrik.yaml` un modelo
por rol (con su `reserva`, una lista, vacía si no hay otro proveedor), el `pool` por niveles y la `reserva_final`,
usando solo los proveedores detectados; avisa de los niveles que quedan vacíos. Los modelos son **personales**: ni el
motor ni el pack los fijan (el motor trae solo un `anthropic` genérico y el pack solo `permitir_pago`). Revisa la
propuesta y edítala si quieres. Sin `permitir_pago: true` (lo decide el pack) nunca propone proveedores de pago
(`deepseek`).

```yaml
modelos:
  programador:
    proveedor: kimi-coding
    modelo: kimi-for-coding
    reserva: []        # explícita; con otro proveedor: [{proveedor: …, modelo: …}]
  pool:                # niveles ligero, medio, dificil, critico (más barato primero)
    medio:
      - {proveedor: kimi-coding, modelo: kimi-for-coding, herramientas: true, coste: suscripcion}
  reserva_final: {proveedor: kimi-coding, modelo: kimi-for-coding}
```

**Máquina ya configurada.** Si no tienes `fabrik.yaml` pero ya hay perfiles de Hermes y el pack trae modelos de
referencia (`tests/fixtures/modelos-*.yaml`), `install.sh` no propone nada
para no reescribir los modelos que ya rigen: te dice qué fichero copiar a `~/.config/fabrica/fabrik.yaml` y se
detiene hasta que lo hagas.

Las claves de API van en `~/.hermes/.env` (`KIMI_API_KEY=…`, `DEEPSEEK_API_KEY=…`, `ANTHROPIC_API_KEY=…`).
`./install.sh --comprobar` pide **solo** las de los proveedores que aparecen en tus `modelos`: con solo Claude no te
exige ninguna clave de API.

## Lo que no viene en el pack (canal aparte)

Ni el pack ni este repo llevan **ningún secreto**. Lo que sigue lo pones tú en tu máquina, nunca se versiona y
no se comparte por git, por el Kanban ni por el chat de un agente: si alguien de la organización tiene que pasarte
algo, que sea por un **canal privado** (gestor de contraseñas compartido o similar).

| Fichero | Qué es | Cómo se obtiene |
|---|---|---|
| `~/.hermes/.env` | Claves de API de los proveedores de modelos (`KIMI_API_KEY`, `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`…) | Las pone cada uno con su propia cuenta; solo hacen falta las de los proveedores que uses (paso 3). |
| `~/.config/fabrica/prod.conf` | Acciones de producción que permite `fabrik-prod` (alias SSH y comandos de la lista cerrada) | **Solo si la organización te da acciones de producción.** Nunca viene en el pack (solo un `prod.conf.ejemplo` sin valores). Créalo con `chmod 600`; los alias SSH y las llaves son tuyos (`~/.ssh`), no se comparten. Sin él, `fabrik-prod` no hace nada. |
| `~/.config/fabrica/cloudflare.env` | Token de Cloudflare para las acciones que lo usen | Solo si aplica a tu organización; te lo da un administrador por canal privado. `chmod 600`. |
| `~/.config/fabrica/hindsight.env` | Configuración de la memoria compartida (opcional), con la clave de API de su modelo | Cópialo de `config/hindsight.env.ejemplo`, `chmod 600`, y pon **tu propia** clave (`HINDSIGHT_API_LLM_API_KEY`); no se comparte. Sin él la memoria no arranca. |
| `~/.config/fabrica/db.env` | Usuario y contraseña de `fx` (la BD de los agentes) | La genera `install.sh` con una contraseña aleatoria (`chmod 600`); es local y no se comparte. |

Si cambias de máquina, `fabrik-exportar` lleva estos ficheros dentro de un archivo cifrado con `age`
(ver el [README](../README.md)); no los copies a mano por ningún otro medio.

### Base de datos de los agentes

Los repos PHP/Laravel usan una BD propia por worktree (`fx_<repo>_<slug>`). Si tienes `mariadb`, `mariadbd` y
`mariadb-install-db`, `install.sh` monta **el MariaDB propio de la fábrica**: datos en
`~/.local/share/fabrica/mariadb`, unidad de usuario `fabrica-mariadb` escuchando solo en `127.0.0.1:3307`, sin
privilegios de administrador, y un usuario `fx` con permisos solo sobre `fx_%`. Escribe `FX_DB_PORT=3307` en
`db.env`; tu MariaDB del día a día (3306) y sus bases de datos nunca se usan. Es opcional: sin MariaDB se omite y
los agentes no tendrán BD. Si ya tenías un `db.env` con otro puerto (por ejemplo el 3306), `install.sh` lo respeta y
te avisa de que los agentes usarán ese servidor (solo los protege el permiso de `fx` sobre `fx_%`); para pasar al
MariaDB de la fábrica borra `~/.config/fabrica/db.env` y repite `./install.sh`.

## 4. Tus repos personales

El pack aporta los `owners` de la organización. Para que la fábrica también gestione tus repos personales,
añade tu cuenta a `owners` en tu config personal:

```yaml
usuario_github: tu-usuario
owners:
  - acme
  - tu-usuario
```

Los tableros del pack se suman a los tuyos; los repos de `owners` sin tablero propio caen en el tablero por defecto
(`tablero_por_defecto`). Puedes ver el resultado fusionado:

```bash
fabrik config get owners
fabrik config ver
```

## 5. Regenerar el portfolio

El portfolio (`~/.hermes/factory/portfolio.yaml`) es el catálogo de repos que usan el orquestador y los tableros.
Se genera a partir de los `owners` y se **conservan** tus ediciones entre regeneraciones:

```bash
uv run --with pyyaml python scripts/build_portfolio.py
```

## 6. Activar el Kanban en el escritorio

Abre Hermes Desktop → Capacidades → Plugins → Plugins de escritorio → activa **Kanban**. Los tableros del pack y
el tuyo aparecen en el selector. Comprueba también que el dispatcher está en marcha (`hermes gateway start` si
`install.sh` lo avisó).

## 7. Comprobación final

```bash
./install.sh --comprobar
fabrik config ver
```

y en el chat con el orquestador:

```text
/fabrica estado
```

Debe listar tus tableros y los PRs con etiqueta `agente` de tus `owners`. Para tu primera tarea:
`/fabrica feature <repo> "<qué quieres>"` (flujo [F2](flows/F2-feature.md); el ciclo de cada tarjeta está en
[C0](flows/C0-ciclo-tarjeta-codigo.md)).

## Si algo falla

- `./install.sh --comprobar` sale con ✗: cada línea dice qué falta y dónde ponerlo.
- «Sin pack configurado»: no pasaste `--pack` o la ruta no tiene `pack.yaml`; revisa `packs:` en tu config.
- Cambiaste de máquina: `fabrik-exportar` / `fabrik-importar` llevan tus datos (ver el [README](../README.md)).

## Lecciones compartidas

Al cerrar una tarjeta, `fabrik-memoria leccion` guarda lo aprendido en un `.md` (síntoma, causa, solución, dónde) además de en la memoria:

- Se escribe en `conocimiento/lecciones/` del primer pack activo con `memoria.banco`; si no hay ninguno, en `$FABRIK_DATA/conocimiento/lecciones/`. Nunca en el repo del motor.
- Se comparten por git dentro del repo del pack: rama + PR contra su `main`, nunca push directo a `main`.
- `memoria_ingest.py lecciones` las carga en la memoria desde todos los packs activos.
