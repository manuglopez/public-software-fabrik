# Plan · Medición real por cuenta, reparto equilibrado y canal de avisos a prueba de cuota

Spec: `specs/cuotas-bolsas/spec.md`. Las tareas son tarjetas del tablero de operaciones de la fábrica.

> **Corrección del 25/10.** La versión anterior de este plan agrupaba las cuentas en una bolsa común
> (`claude_5h@a+b`, campo `cuentas_claude`). Se retira: las cuentas son independientes y el fallo real es que la
> medición por cuenta es ciega. D-1 a D-5 están reescritas; D-6 a D-11 se mantienen.

## Grafo

```
PLAN ✋ ─┬─ IMPL-1 medición  (AC-1..AC-3)        sub-worktree cuotas-bolsas--cupos   ─┐
         ├─ IMPL-2 reparto   (AC-4, AC-5)        sub-worktree cuotas-bolsas--reparto ─┼─ CIERRE-LOCAL ─ PR ─ FIN
         └─ IMPL-3 avisos    (AC-6..AC-8)        sub-worktree cuotas-bolsas--avisos  ─┘
```

Las tres IMPL van en paralelo, sin cadenas. Solo comparten el contrato de la foto (D-1), fijado aquí.
IMPL-2 e IMPL-3 tocan las dos `bin/fabrik-modelos`, pero en zonas distintas (D-11). CIERRE-LOCAL las junta con
`factory-juntar` y sale **un solo PR** (≈330 líneas de producción, ≈10 ficheros).

## Decisiones (las toma el orquestador; cada tarjeta lleva las que usa)

- **D-1 Formato de la foto** (`cupos.jsonl`, una línea por foto). **No cambia respecto a hoy**: las bolsas Claude
  siguen con la clave `<bolsa>@<cuenta>` (`claude_5h@a`, `claude_sem@a`, `fable_sem@a`), una entrada por cuenta,
  cada una con su propio porcentaje y su propio `reset`. No hay agrupación ni campo `cuentas_claude`. Lo que
  cambia es **de dónde salen las cifras** (D-2). Las fotos viejas se siguen leyendo igual.
- **D-2 Medición por cuenta (AC-1, AC-2, AC-3).** En `fabrik-cupos.anthropic()`:
  - Por cada directorio `~/.config/fabrica/claude-*` (y `~/.claude` si está configurado como cuenta), ejecuta
    `claude -p "/usage"` con `CLAUDE_CONFIG_DIR=<dir>` en el entorno y límite de 120 s.
    **`claude usage` sin `-p` NO es un subcomando**: el CLI lo toma como prompt, abre sesión, gasta una llamada
    al modelo y responde en prosa. Usa siempre `-p "/usage"`.
  - Parsea las tres líneas, tolerando que falte alguna:
    ```
    Current session: 8% used · resets Oct 25, 3:19am (Europe/Madrid)
    Current week (all models): 17% used · resets Oct 27, 10:59am (Europe/Madrid)
    Current week (Fable): 0% used · resets Oct 27, 11am (Europe/Madrid)
    ```
    → `claude_5h@<cuenta>`, `claude_sem@<cuenta>`, `fable_sem@<cuenta>`. El `reset` no trae año: se resuelve como
    la **próxima** aparición de esa fecha/hora, y se guarda en ISO 8601 con zona, como el resto de bolsas.
  - Función pura y testeable para el parseo, p. ej. `parsear_usage(texto) -> {bolsa: (pct, reset_iso)}`, separada
    de la ejecución del subproceso.
  - Si una cuenta falla (exit ≠ 0, salida vacía o sin ninguna línea reconocible), su error va a
    `errores["anthropic"][<cuenta>]` y esa cuenta no tiene claves. Las demás se miden igual.
  - **Sospecha de lectura ciega (AC-3):** si dos cuentas distintas devuelven el mismo porcentaje **y** el mismo
    `reset` en `claude_5h` y en `claude_sem`, añade `errores["anthropic_sospecha"]` describiendo qué cuentas
    coinciden. Las claves se escriben igual, por cuenta: se avisa, no se agrupa.
  - **Prueba de control (AC-2):** con `CLAUDE_CONFIG_DIR` a un directorio inexistente, la lectura de esa cuenta
    tiene que acabar en error. Si devuelve cifras, el lector es ciego y el test debe fallar.
  - **Coste:** `/usage` es un comando del CLI y no debería gastar tokens. Compruébalo una vez a mano (mide antes
    y después con la propia salida de `/usage`) y anótalo en el PR. Si gastara, se mide una vez por tick y se
    cachea 60 s.
- **D-3 Identidad de una cuenta (AC-9).** Donde haga falta saber de quién es un directorio, se usa
  `CLAUDE_CONFIG_DIR=<dir> claude auth status` (campos `email`, `orgId`). **Nunca** el bloque `oauthAccount` de
  `<dir>/.claude.json`: es una caché que puede tener semanas. Nada de tokens: no se leen, no se imprimen, no se
  registran. Ni el correo ni el `orgId` van a la foto.
- **D-4 `mejor_cuenta()` — reparto por agotamiento relativo (AC-4).**
  - Cuentas aptas: las que pasan `ruta_ok`, incluido el tope por asiento `topes_cuenta`.
  - Entre las aptas se elige la de mayor **margen por hora**:
    `margen_hora = (tope_efectivo − pct_semanal) / max(horas_al_reset, 0.5)`.
    Es decir, cuánto puede gastar por hora hasta su tope sin agotarse antes de renovar. Una cuenta al 50 % que
    renueva en 1 h está **mejor** que una al 30 % que renueva en 5 días, y el reparto lo refleja.
  - Empate (diferencia < 1 % del margen por hora): orden alfabético, para que sea determinista en los tests.
  - `topes_cuenta` sigue siendo el tope por asiento y entra en `tope_efectivo`.
- **D-5 `estado` (AC-4).**
  - Texto: una línea por cuenta Claude antes de las filas de rutas:
    `cuenta a: semanal 17 % · renueva en 58 h · margen/hora 1,17` y, si la hubiera,
    `⚠ sospecha de lectura ciega: a y b devuelven cifras idénticas`.
  - `--json`: en cada entrada de `cuentas[]`, los campos nuevos `sem_pct`, `horas_reset` y `margen_hora`, más
    `"sospecha_lectura_ciega": ["a","b"]` de primer nivel cuando aplique. Las claves que ya existen no cambian:
    el panel las lee (`plugin/fabrica/dashboard/fx_agentes.py`, `tests/panel/*`).
- **D-6 Foto fresca (AC-5).** Sin cambios respecto a la versión anterior.
  - `tick()` llama a `foto_fresca()`. Si la última foto tiene más de `FOTO_MAX_EDAD = 180` s
    (`FABRIK_FOTO_MAX_EDAD` lo cambia), ejecuta `[$FABRIK_CUPOS o <FABRIK>/bin/fabrik-cupos, "registrar"]` con un
    límite de 300 s y vuelve a leer.
  - Si la llamada falla, avisa por stderr y sigue con la foto vieja. Solo lo hace `tick`; `asignar` no.
  - En `bolsa_ok`, si el `reset` ya pasó, la bolsa cuenta como renovada (0 %) y el motivo es
    «renovada (foto anterior al corte)».
- **D-7 Comprobador (AC-6, AC-7).** Sin cambios. Módulo puro `scripts/canal_avisos.py` con
  `comprobar(home) -> list[{"nivel": "ok"|"fallo", "que": str, "motivo": str}]`. CLI
  `fabrik-modelos comprobar [--json]`, exit 1 si hay algún fallo.
  - **default**: lee `<home>/.hermes/config.yaml` (reutiliza el lector de YAML de `scripts/cupos.py`) y obtiene
    las bolsas con `scripts/cupos.bolsas_de`.
    - Falla si `fallback_providers` falta o está vacío.
    - Falla si **todas** las entradas comparten alguna bolsa con el modelo principal.
    - Un proveedor sin bolsa conocida (p. ej. `nous`) cuenta como bolsa distinta.
    - Si falta el fichero, falla.
  - **cron**: lee `<home>/.hermes/cron/jobs.json`. Es riesgo un job que cumpla todo esto: `enabled`; con `model`
    no vacío; con algún destino en `deliver` cuya plataforma no sea `local` ni `origin`; y con
    `bolsas_de(provider, model)` ∩ {`claude_5h`, `claude_sem`} ≠ ∅. Si no hay `jobs.json`, todo está bien.
- **D-8 Aviso de bolsa (AC-8).** Sin cambios salvo las claves, que ahora son siempre `<bolsa>@<cuenta>`.
  - `modelos.reparto.aviso_bolsa`, entero de 1 a 100 (por defecto 98), validado en `scripts/fabrik_config.py`
    (`CLAVES_REPARTO`) y leído en `aplicar_reparto` → `AVISO_BOLSA`.
  - En cada `tick` se anota, por rol, la ruta de antes (la del `model.default` actual) y la de después (la
    elegida, o `None` si no hay cupo apto). Al final se llama a `canal_avisos.avisar_bolsas(...)`.
  - Se avisa por cada bolsa de la foto con `pct ≥ umbral` y `reset` futuro que no esté ya en el estado (clave
    `f"{bolsa}|{reset[:13]}"`): «⚠️ Bolsa claude_sem@a al 98 % (queda 2 %), se renueva 27/10 10:59. Conmutado:
    programador sonnet → kimi. Sin ruta apta: tester (aparcado).» Solo se nombran los roles cuya ruta de antes
    consumía esa bolsa; si no hay ninguno: «Ningún rol la usaba ahora».
  - El envío es `hermes send -t ${FABRIK_AVISO:-telegram} <msg>`, que no usa LLM y por eso no depende de ninguna
    bolsa. El estado va en `~/.hermes/factory/logs/modelos-avisos.json`. Si el envío falla, no se marca y se
    reintenta en el siguiente tick.
  - `tick` también ejecuta `comprobar`. Si hay fallos, manda un aviso al día (clave `comprobar|AAAA-MM-DD`).
- **D-9 `UMBRALES` de `fabrik-cupos`.** Las claves pasan a ir sin `@` (`"claude_sem": [85, 95]`) y valen para
  cualquier `<bolsa>@<cuenta>`: se compara `clave.split("@")[0]`. La deduplicación usa la clave completa. Así
  salen los nombres de cuenta del código del motor.
- **D-10 Privacidad.** No puede haber nombres de cuenta reales, emails ni uuids en el código, los tests o los
  fixtures (lo vigila `tests/sin_privado_test.sh`). Se usan las cuentas `a`, `b`, `c`.
- **D-11 Zonas de `bin/fabrik-modelos`.**
  - IMPL-2: `foto`/`foto_fresca`, `bolsa_ok`, `ruta_ok`, `mejor_cuenta`, `estado` y la primera línea de `tick`
    (`foto()` → `foto_fresca()`).
  - IMPL-3: `aplicar_reparto` (`aviso_bolsa`), el registro de antes→después dentro del bucle de `tick`, la
    llamada final de `tick`, la rama `comprobar` de `__main__` y su línea en el docstring.

## Modelos

Kimi tiene la semana al 100 % (se renueva el 26/10 a las 00:27) y la bolsa Claude de Antigravity también está al
100 %. Todo el código va con `claude-sonnet-5-5`. La revisión la hacen `tester` (IMPL) y `revisor` (CIERRE), con
sus perfiles.
