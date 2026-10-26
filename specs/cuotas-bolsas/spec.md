# Spec · Medición real por cuenta, reparto equilibrado y canal de avisos a prueba de cuota

Talla M. Repo `software-fabrik`, base `main`. Plan de tarjetas: `plan.md` (sin `tasks.md`: las tareas son tarjetas).

> **Corrección del 25/10.** La primera versión de esta spec decía que las cuentas de una misma organización
> comparten bolsa. **Es falso** y se retira entera. Venía de `fetch_account_usage`, que ignora la cuenta.

## Por qué

`bin/fabrik-cupos` mide cada cuenta Claude lanzando un subproceso con `CLAUDE_CONFIG_DIR=<dir>` que llama a
`fetch_account_usage` (función `anthropic()`). **Esa lectura es ciega a la cuenta**: ni `CLAUDE_CONFIG_DIR` ni
`CLAUDE_SUBSCRIPTION_DIRECTSDK_CONFIG_DIR` la cambian, devuelve un valor cacheado idéntico al microsegundo en
llamadas separadas por minutos, y apuntándola a un directorio **inexistente** sigue devolviendo cifras en vez de
dar error de login.

Consecuencia: `claude_5h@<cuenta1>` y `claude_5h@<cuenta2>` son **la misma medición guardada con dos nombres**.

Medido el 24/10 con el método correcto (`CLAUDE_CONFIG_DIR=<dir> claude -p "/usage"`), las cuentas son
**independientes**, con porcentajes y horas de renovación distintas:

| cuenta | sesión 5 h | semanal | renueva |
|---|---|---|---|
| a | 8 % | 17 % | 27/10 10:59 |
| b | 6 % | **97 %** | 25/10 17:59 |

O sea que el router cree tener 83 puntos de margen donde quedan 3, `mejor_cuenta()` elige entre dos números
idénticos (reparto inexistente) y una cuenta puede agotarse sin que la foto lo vea. El 24/10 las dos marcaron
100 % a la vez porque era un solo dato duplicado; ese día el perfil `default` (chat y Telegram), que estaba en
Claude con `fallback_providers: []`, dejó de responder.

## Objetivo

Medir cada cuenta de verdad, repartir la carga para que ninguna llegue a su tope antes de su renovación, y que el
canal de avisos no dependa nunca de la bolsa que se está agotando.

## Criterios de aceptación

- **AC-1** `fabrik-cupos` mide cada cuenta con `CLAUDE_CONFIG_DIR=<dir> claude -p "/usage"` y parsea sesión,
  semanal y Fable con su porcentaje y su hora de renovación. No se usa `fetch_account_usage` para cifras por
  cuenta. Dos cuentas con consumos distintos producen entradas distintas en la foto.
- **AC-2** Prueba de control: un lector por cuenta apuntado a un directorio **inexistente** debe fallar, no
  devolver cifras. Es la prueba que delata una lectura ciega, y va en los tests.
- **AC-3** Si dos cuentas devuelven exactamente el mismo porcentaje **y** el mismo reset en la misma foto, se
  registra un aviso de sospecha de lectura ciega (`errores["anthropic_sospecha"]`). Las cuentas **siguen siendo
  bolsas separadas**: la sospecha se avisa, no se asume.
- **AC-4** `fabrik-modelos` reparte para **igualar el agotamiento relativo**: entre las cuentas aptas elige
  aquella cuyo consumo va más holgado respecto al tiempo que le queda hasta su propio reset, no la del
  porcentaje más bajo a secas. `estado` muestra por cuenta: % semanal, horas al reset y margen por hora.
- **AC-5** Si la última foto tiene más de 3 minutos, `fabrik-modelos tick` la refresca antes de decidir. Una
  bolsa cuyo `reset` ya pasó cuenta como renovada.
- **AC-6** Un comprobador **falla** si el perfil `default` no tiene `fallback_providers` o si todas sus entradas
  están en la misma bolsa que su modelo principal.
- **AC-7** El mismo comprobador marca como riesgo los cron de aviso con modelo fijado en una bolsa de Anthropic,
  porque los jobs fijados no recorren las reservas.
- **AC-8** Umbral configurable `modelos.reparto.aviso_bolsa` (por defecto 98 %). Cuando una bolsa lo cruza, se
  envía un aviso al Telegram privado con la bolsa, cuánto queda y a qué ruta se ha conmutado. El avisador no
  depende de ninguna bolsa de modelo.
- **AC-9** La identidad de una cuenta se lee de `claude auth status`, nunca del bloque `oauthAccount` de
  `.claude.json`: es una caché que puede tener semanas y dar un correo de un login anterior (pasó en el
  diagnóstico de esta feature).
- **AC-10** Hay tests para AC-1..AC-9 que citan el id, incluido el caso de dos cuentas con consumos distintos y
  el de la lectura ciega.

## Fuera de alcance

- Reglas de calidad: nada de Flash escribiendo código, el revisor es de otra familia.
- Rutas de pago por token (Nous Portal): las decide el usuario en otra tarjeta.
- Agrupar cuentas en una bolsa común: retirado, la premisa era falsa.
- `scripts/cupos.py`/`triage_cupos` (aparcado por cupo). Su `bolsas_de()` devuelve `claude_5h` sin `@cuenta`, así
  que hoy el triage nunca aparca por Claude. Se anota para otra tarjeta.
