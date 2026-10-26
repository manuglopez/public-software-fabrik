# Tests compartidos: tope de paralelismo, pausa de Dusk y MariaDB en modo tests

Este documento explica las tres medidas que hacen sostenible ejecutar tests de muchos repos en la misma
máquina, y las cifras con las que se decidieron. Complementa al [turno de tests del README](../README.md#turno-de-tests-factory-test).

## Por qué

La máquina de la fábrica tiene **16 hilos y 31 GB de RAM, compartidos con el IDE, el navegador y las
sesiones del usuario**, y había un embudo de tests: suites que se encallaban, colas que esperaban y bases
de datos que se pisaban. Causa principal: `-p` o `--parallel` **sin número** autodetectan un proceso por
hilo (16), y en un repo Laravel cada proceso de tests prepara **su propia base de datos**. Dieciséis
preparaciones de BD a la vez saturan disco y MariaDB, y el tiempo de preparación se multiplica por
contención en vez de dividirse por paralelismo.

Dos medidas complementarias lo resolvieron:

1. **`factory-test` rebaja todo paralelismo a un máximo de 4 procesos** (sección siguiente).
2. **La MariaDB de la fábrica corre en modo tests** (opciones sin durabilidad, datadir sin
   copy-on-write), lo que hace cada preparación de BD mucho más barata (medida al final).

## Tope de 4 procesos

`factory-test` reescribe los argumentos del comando que recibe antes de ejecutarlo:

| Comando que se le pasa              | Después de la reescritura          |
| ----------------------------------- | ---------------------------------- |
| `phpunit-replay run -p 8`           | `phpunit-replay run -p 4`          |
| `phpunit-replay run -p`             | `phpunit-replay run -p 4`          |
| `paratest -p8`                      | `paratest -p4`                     |
| `phpunit --processes=12`            | `phpunit --processes=4`            |
| `artisan test --parallel`           | `artisan test --parallel --processes=4` |
| `phpunit -p 2`                      | sin cambios (ya está bajo el tope) |
| `phpunit --filter X`                | no se toca (no es paralelo)        |

**Configuración del tope** (la primera que exista gana): env `FX_TEST_MAX_PROCESOS` > fichero
`~/.config/fabrica/max-procesos-tests` > `tests.max_procesos` en la config de la fábrica > **4**.
Un valor no numérico o 0 vale 4.

**Límite de la reescritura**: solo toca el comando principal que recibe `factory-test`. **No** reescribe
dentro de `bash -c "…"` ni en los scripts que ese comando invoque; si metes un `-p 16` dentro de un
script propio, se ejecuta tal cual.

## Pausa de Dusk (temporal)

<!-- DUSK-PAUSA: temporal; la sección vale mientras exista la pausa -->

Los tests de navegador (Dusk) abren un navegador real y son los más caros de la máquina. La fábrica
puede tenerlos **en pausa** de forma explícita y temporal; mientras exista la pausa:

- `factory-test` **detecta** los intentos de ejecutarlos: palabras clave en los argumentos
  (`dusk`, `chromedriver`, rutas de `tests/Browser`), scripts `.sh` invocados directamente y los `.sh`
  que esos scripts llamen.
- Si la pausa está activa, **rechaza la ejecución con código 3** y un mensaje que lo dice; no hay que
  intentarlo por otra vía (`php artisan dusk`, chromedriver a mano, scripts).
- Escribir o ajustar tests Dusk sigue permitido; lo que no se hace es ejecutarlos. Ningún AC, revisión
  ni cierre se bloquea por ello: se anota «Dusk no ejecutado: en pausa» en el handoff y se sigue con
  PHPUnit/replay, Pint y PHPStan.
- **Sin pausa, Dusk se ejecuta como siempre.**

**Cómo se activa y cómo se quita** (la primera condición que exista gana): env `FX_TEST_DUSK_PAUSADO` >
fichero `~/.config/fabrica/dusk-pausado` (su contenido es el motivo de la pausa, se lee en el mensaje) >
`tests.dusk_pausado` en la config. Para quitarla, basta borrar el fichero:

```bash
rm ~/.config/fabrica/dusk-pausado
```

## Replay a la vez

Medido con dos `phpunit-replay run -p 4` de **un repo Laravel grande** lanzados a la vez: no se frenan entre sí.

| Run | Sola   | A la vez |
| --- | ------ | -------- |
| A   | 180 s  | 175 s    |
| B   | 158 s  | 161 s    |

La CPU media fue del **27 %** (pico del 60 %), con **+1,2 GB de RAM** y un iowait del 7 %. Hay holgura de
sobra, pero `factory-test` los ponía en fila: un replay normal va como «dirigido» y coge el lock de la BD
base (`127.0.0.1:3307/<repo>_test`), que comparten todos los worktrees del repo.

**Qué hace ahora.** Un replay entra en un **hueco de replay** (clase `replay`, visible en el `▶`, en el
nombre del log y en `QUIEN`) si se cumplen las tres: es un `phpunit-replay run` paralelo (`-p N`, N > 1, ya
rebajado por el tope) cuyo dry-run no lo degrada; hay `.factory/env` con `DB_DATABASE`; y el repo está en
la lista. Los huecos son `locks/replay.d/<n>.lock` (n = 1..H), **globales a la máquina** (también limitan la
carga). `factory-test` exporta siempre `FX_TOKEN_OFFSET=(n-1) × N`, con N el tope de procesos; si quien
llama ya traía otro valor, lo sobreescribe y avisa en una línea. El replay **no** coge hueco de dirigidos
ni el turno pesado. Fuera de esos casos todo sigue como antes: un replay no paralelo, sin `.factory/env` o
de un repo fuera de la lista va como dirigido con el lock de la BD base; un replay degradado va como pesado.

**Claves** (mismo patrón que `repos_token`):

- Lista de repos: env `FX_TEST_REPOS_REPLAY` (manda aunque esté vacía) > `tests.replay_simultaneo` de la
  config. Sin lista, ningún repo.
- Número de huecos: env `FX_TEST_REPLAY_HUECOS` > `tests.replay_huecos` > **2**. Un valor que no sea un
  entero ≥ 1 cae a la siguiente fuente.

**Hueco → desfase → lock de BD** (con el tope por defecto, N = 4):

| Hueco | `FX_TOKEN_OFFSET` | Tokens de Laravel (`-p 4`) | Lock de BD                          |
| ----- | ----------------- | -------------------------- | ----------------------------------- |
| 1     | 0                 | 1..4                       | la BD base, `127.0.0.1:3307/<repo>_test` |
| 2     | 4                 | 5..8                       | `127.0.0.1:3307/<repo>_test@desfase4` |
| n ≥ 2 | (n-1) × N         | (n-1)×N+1 .. n×N           | `<BD base>@desfase<offset>`         |

Con `FX_TEST_MAX_PROCESOS=2` los desfases son 0 y 2.

**Por qué el hueco 1 excluye al pesado.** El hueco 1 usa los mismos tokens 1..N que un pesado
(`artisan test --parallel`, paratest) y que un dirigido sin token, así que coge el lock de la **BD base** y
se excluyen entre sí con el lock de BD que ya existía: no hace falta tocar el turno pesado (global a la
máquina) ni darle desfase. El hueco n ≥ 2 usa un rango que un pesado, con el tope de N procesos, nunca
alcanza, así que no lo espera ni lo pisa. Por eso, con un pesado en la BD base, un replay entra directo en
el hueco 2 en vez de esperar.

**Cómo se cogen.** Para n = 1..H: `flock -n` del hueco y, después, `flock -n` de su BD; si la BD está
ocupada, suelta el hueco y prueba el siguiente. Sin ningún par libre muestra
`⏳ esperando hueco de replay (H en marcha) …` (una vez), espera `FX_TEST_PAUSA` y reintenta dentro de
`FX_TEST_WAIT`. Ambos son no bloqueantes, así que no hay ciclos con el resto de locks.

**`factory-test estado`** lista cada hueco cogido de verdad:
`replay <n>: <quién> · desfase=<k> · bd=<clave>` (`(arrancando)` si aún no ha escrito su `.owner`).

**Límite.** Si alguien sube `max_procesos` mientras hay un replay en el hueco ≥ 2, los rangos de token
se pueden solapar. Es raro y solo se avisa.

**Requisito en el repo.** El repo tiene que aceptar `FX_TOKEN_OFFSET`: el token de ParallelTesting de Laravel
pasa a ser `TEST_TOKEN + FX_TOKEN_OFFSET`. Sin ese soporte, dos replay del mismo repo comparten las BD
`<base>_test_1..N` y se pisan: **no añadas a la lista un repo que no lo acepte**. Los tests están en
`tests/factory_test_replay_huecos_test.sh`.

## MariaDB de la fábrica en modo tests

La MariaDB que usan los worktrees (`fx_*`, bases de tests de los repos) arranca con opciones de máximo
rendimiento y cero durabilidad:

```
--innodb-buffer-pool-size=2G --innodb-flush-log-at-trx-commit=0 --innodb-doublewrite=0
--innodb-flush-method=O_DIRECT_NO_FSYNC --sync-binlog=0 --innodb-log-file-size=512M --skip-name-resolve
```

con `MemoryMax=3G` en la unit de systemd.

**Por qué es aceptable**: es una base de datos **solo de tests**, que se tira y se rehace en cada
preparación; no persiste nada que no se pueda regenerar, así que las garantías de durabilidad de
producción no aplican. Nunca apuntan a ella datos reales ni de desarrollo.

**Datadir en btrfs sin copy-on-write**: el datadir lleva `chattr +C` (desactiva CoW, que en btrfs
duplica el trabajo de escritura de InnoDB). Ojo: `+C` **solo afecta a los ficheros nuevos**, así que el
datadir se crea copiando de verdad (`cp -a --reflink=never`) sobre un directorio ya marcado, no con un
reflink o un `mv` de ficheros existentes.

**Medida**: con el modo tests, la preparación de la base de datos de un proceso de tests de un
**repo Laravel grande del pack** bajó de **63 s a 14 s** por proceso, medido con la variable
`TEST_PRISTINE_DB_LOG` (registra los tiempos de preparación). Multiplicado por 4 procesos por run y
varios runs a la vez, es la diferencia entre un embudo y un caudal constante.

**Comprobación y migración**: `./install.sh --comprobar` informa del estado de la instalación sin tocar
nada. Para migrar una instalación existente al datadir rápido está `scripts/migrar-mariadb-rapido.sh`,
que coge todos los cerrojos de `locks/`, para el servicio, copia el datadir, intercambia el enlace,
arranca de nuevo y suelta los cerrojos; con `--seco` muestra lo que haría sin ejecutarlo:

```bash
./install.sh --comprobar
scripts/migrar-mariadb-rapido.sh --seco
```
