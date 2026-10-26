// Piezas comunes (BASE, D-9): SDK falso completo, ctxFalso, api.js (fijarCtx/ctxPlugin) y ui.js (abrirTarjeta,
// abrirConsola, useAbrirConsola). Construye su propio bundle (`construir('comun')`) y corre en paralelo con el resto.
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, sep } from 'node:path'
import { describe, it } from 'node:test'
import { DESKTOP, SDK, construir, exportsDeFuente, fixture, h } from './comun.mjs'

const { cargar, html, montar, act, sdk, salida } = await construir('comun')
const SDK_REAL = join(process.env.HERMES_AGENT_DIR || join(homedir(), '.hermes', 'hermes-agent'), 'apps', 'desktop', 'src', 'sdk', 'index.ts')
const EXTRAS = ['ctxFalso'] // lo que el SDK falso añade y el real no tiene

/** `leer` para exportsDeFuente: resuelve `./x` relativo a `dir` (x.ts, x.tsx, x/index.ts) y sigue anidando. */
function leerJuntoA(dir) {
  return spec => {
    if (!spec.startsWith('.')) return null
    const base = join(dir, spec)
    const ruta = [`${base}.ts`, `${base}.tsx`, join(base, 'index.ts')].find(existsSync)
    return ruta ? exportsDeFuente(readFileSync(ruta, 'utf8'), leerJuntoA(dirname(ruta))).map(n => `export const ${n} = 0`).join('\n') : null
  }
}

describe('comun.mjs: construir(zona)', () => {
  it('construye en desktop/.prueba/<zona>/ y carga cualquier fichero de src por su ruta', async () => {
    assert.equal(salida, join(DESKTOP, '.prueba', 'comun'))
    assert.equal(typeof (await cargar('inicio/en_marcha')).EnMarcha, 'function')
    assert.equal(typeof (await cargar('ui')).abrirTarjeta, 'function')
  })
  it('rechaza zonas que podrían salirse de .prueba/', async () => {
    for (const mala of ['', '..', `a${sep}b`, 'A B']) await assert.rejects(construir(mala), /zona no válida/, mala)
  })
  it('un solo SDK falso para todas las entradas: lo que hace ui.js lo ve el SDK cargado aparte', async () => {
    const { abrirTarjeta } = await cargar('ui')
    const { host } = await cargar(SDK)
    abrirTarjeta({ board: 'b', task_id: 't' })
    host.navigate('/x')
    assert.equal(sdk().navegaciones.length, 2)
  })
})

describe('sdk_falso.mjs: mismos nombres que el SDK real', () => {
  const lista = fixture('comun_sdk_exports').nombres
  it('exporta exactamente la lista fijada (más ctxFalso)', async () => {
    const nombres = Object.keys(await cargar(SDK)).sort()
    assert.deepEqual(nombres, [...lista, ...EXTRAS].sort())
  })
  it('la lista fijada coincide con el SDK real de Hermes', { skip: !existsSync(SDK_REAL) && `sin ${SDK_REAL}` }, () => {
    const real = exportsDeFuente(readFileSync(SDK_REAL, 'utf8'), leerJuntoA(dirname(SDK_REAL)))
    const faltan = real.filter(n => !lista.includes(n))
    const sobran = lista.filter(n => !real.includes(n))
    assert.deepEqual({ faltan, sobran }, { faltan: [], sobran: [] }, 'regenera tests/panel/fixtures/comun_sdk_exports.json y amplía sdk_falso.mjs')
  })
  it('exportsDeFuente: valores sí, tipos no; respeta alias y export * as', () => {
    const fuente = [
      "export { A, type B, C as D } from './x'",
      "export type { E } from './y'",
      "export type * from './z'",
      "export * as iconos from './i'",
      'export const F = 1',
      'export interface G {}',
      'export async function h() {}',
      "// export const Comentado = 1",
      "/* export { Bloque } */"
    ].join('\n')
    assert.deepEqual(exportsDeFuente(fuente), ['A', 'D', 'F', 'h', 'iconos'])
  })
  it('exportsDeFuente: `export * from` sigue el módulo con `leer` (y sin `leer` no inventa nombres)', () => {
    const modulos = {
      './areas': "export const PANES_AREA = 'p'\nexport * from './mas'\nexport type X = 1",
      './mas': 'export const TITLEBAR_AREAS = {}'
    }
    const fuente = "export { A } from './a'\nexport * from './areas'\nexport type * from './tipos'"
    assert.deepEqual(exportsDeFuente(fuente, spec => modulos[spec] ?? null), ['A', 'PANES_AREA', 'TITLEBAR_AREAS'])
    assert.deepEqual(exportsDeFuente(fuente), ['A'])
  })
})

describe('sdk_falso.mjs: componentes, host y estado', () => {
  it('cada componente se pinta como <div data-sdk="Nombre"> con sus hijos', async () => {
    const falso = await cargar(SDK)
    assert.equal(html(falso.Button, { children: 'Hola' }), '<div data-sdk="Button">Hola</div>')
    assert.equal(html(falso.PanelPill, {}), '<div data-sdk="PanelPill"></div>')
    assert.match(html(falso.EmptyState, { title: 'Vacío', description: 'Nada' }), /^<div data-sdk="EmptyState"><b>Vacío<\/b><p>Nada<\/p><\/div>$/)
    assert.match(html(falso.icons.RefreshCw, {}), /data-sdk="icons.RefreshCw"/)
  })
  it('host.navigate y host.composer.setDraft (y el resto de host) apuntan en llamadas', async () => {
    const { host } = await cargar(SDK)
    host.navigate('/kanban')
    assert.equal(await host.composer.setDraft(null, 'hola'), true)
    await host.request('kanban.list', { a: 1 })
    host.sessions.setColor('s1', 'x')
    assert.deepEqual(sdk().llamadas, [
      { que: 'host.navigate', args: ['/kanban'] },
      { que: 'host.composer.setDraft', args: [null, 'hola'] },
      { que: 'host.request', args: ['kanban.list', { a: 1 }] },
      { que: 'host.sessions.setColor', args: ['s1', 'x'] }
    ])
    assert.deepEqual(sdk().navegaciones, ['/kanban'])
  })
  it('host no es thenable (await host no se cuelga)', async () => {
    const { host } = await cargar(SDK)
    assert.equal(await host, host)
  })
  it('reiniciar() deja limpio todo el estado observable', async () => {
    const { host, ctxFalso } = await cargar(SDK)
    host.navigate('/a')
    ctxFalso().storage.set('k', 1)
    sdk().datos['/x'] = 1
    sdk().reiniciar()
    for (const k of ['llamadas', 'navegaciones', 'consultas', 'invalidadas', 'contribuciones']) assert.deepEqual(sdk()[k], [], k)
    assert.deepEqual(sdk().datos, {})
    assert.deepEqual(sdk().sockets, {})
  })
  it('utilidades básicas: cn junta clases, atom/useValue leen el valor', async () => {
    const { cn, atom, computed, useValue } = await cargar(SDK)
    assert.equal(cn('a', false, null, 'b', undefined), 'a b')
    const a = atom(2)
    const doble = computed(a, v => v * 2)
    a.set(3)
    assert.equal(useValue(a), 3)
    assert.equal(doble.get(), 6)
  })
})

describe('sdk_falso.mjs: ctxFalso()', () => {
  it('rest responde con datos[ruta] y apunta la llamada', async () => {
    const { ctxFalso } = await cargar(SDK)
    const ctx = ctxFalso()
    sdk().datos['/inicio/x'] = { ok: 1 }
    sdk().datos['/falla'] = new Error('boom')
    sdk().datos['/eco'] = opciones => ({ recibido: opciones.body })
    assert.deepEqual(await ctx.rest('/inicio/x'), { ok: 1 })
    await assert.rejects(ctx.rest('/falla'), /boom/)
    assert.deepEqual(await ctx.rest('/eco', { method: 'POST', body: { a: 1 } }), { recibido: { a: 1 } })
    assert.deepEqual(sdk().llamadas.map(l => l.que), ['ctx.rest', 'ctx.rest', 'ctx.rest'])
    assert.deepEqual(sdk().llamadas[0].args, ['/inicio/x', undefined])
  })
  it('storage guarda en memoria; os.notify, os.openExternal y runAction apuntan', async () => {
    const { ctxFalso } = await cargar(SDK)
    const ctx = ctxFalso()
    assert.equal(ctx.storage.get('k', 'def'), 'def')
    ctx.storage.set('k', 5)
    assert.equal(ctx.storage.get('k'), 5)
    ctx.storage.remove('k')
    assert.equal(ctx.storage.get('k', null), null)
    ctx.os.notify({ title: 'Hola' })
    assert.equal(await ctx.os.openExternal('https://example.test'), true)
    assert.deepEqual(ctx.runAction('session.new'), { ok: true })
    assert.deepEqual(sdk().llamadas.map(l => l.que), ['ctx.storage.get', 'ctx.storage.set', 'ctx.storage.get', 'ctx.storage.remove', 'ctx.storage.get', 'ctx.os.notify', 'ctx.os.openExternal', 'ctx.runAction'])
  })
  it('socket guarda el receptor para empujar frames y se da de baja', async () => {
    const { ctxFalso } = await cargar(SDK)
    const recibidos = []
    const baja = ctxFalso().socket('/consola/1', d => recibidos.push(d))
    sdk().sockets['/consola/1']({ datos: 'hola' })
    assert.deepEqual(recibidos, [{ datos: 'hola' }])
    baja()
    assert.equal(sdk().sockets['/consola/1'], undefined)
    assert.deepEqual(sdk().llamadas.map(l => l.que), ['ctx.socket', 'ctx.socket.cerrar'])
  })
  it('registerMany/register guardan contribuciones', async () => {
    const { ctxFalso } = await cargar(SDK)
    const ctx = ctxFalso()
    ctx.registerMany([{ id: 'a' }, { id: 'b' }])
    ctx.register({ id: 'c' })
    assert.deepEqual(sdk().contribuciones.map(c => c.id), ['a', 'b', 'c'])
  })
})

describe('api.js: fijarCtx / ctxPlugin', () => {
  it('fijarCtx guarda el ctx completo y conecta su rest con useFx/accion', async () => {
    const { fijarCtx, ctxPlugin, accion } = await cargar('api')
    const { ctxFalso } = await cargar(SDK)
    const ctx = ctxFalso()
    fijarCtx(ctx)
    assert.equal(ctxPlugin(), ctx)
    sdk().datos['/acciones/x'] = { ok: true }
    assert.deepEqual(await accion('/acciones/x', { a: 1 }), { ok: true })
    assert.deepEqual(sdk().llamadas[0], { que: 'ctx.rest', args: ['/acciones/x', { method: 'POST', body: { a: 1 } }] })
  })
  it('register(ctx) llama a fijarCtx: ctxPlugin() es el ctx del plugin', async () => {
    const { default: plugin } = await cargar('index')
    const { ctxPlugin } = await cargar('api')
    const { ctxFalso } = await cargar(SDK)
    const ctx = ctxFalso()
    plugin.register(ctx)
    assert.equal(ctxPlugin(), ctx)
    assert.ok(sdk().contribuciones.length >= 4)
  })
})

describe('ui.js: abrirTarjeta / abrirConsola / useAbrirConsola', () => {
  it('abrirTarjeta lleva al Kanban nativo con tablero y tarjeta en la ruta', async () => {
    const { abrirTarjeta } = await cargar('ui')
    abrirTarjeta({ board: 'mi tablero', task_id: 't_0000aaaa' })
    assert.deepEqual(sdk().navegaciones, ['/kanban?board=mi%20tablero&task=t_0000aaaa'])
  })
  it('abrirTarjeta sin tablero va al Kanban con solo la tarjeta', async () => {
    const { abrirTarjeta } = await cargar('ui')
    abrirTarjeta({ task_id: 't_1' })
    assert.deepEqual(sdk().navegaciones, ['/kanban?task=t_1'])
  })
  it('abrirConsola emite fabrica:consola en window con {board, task_id}', async () => {
    const { abrirConsola } = await cargar('ui')
    const vistos = []
    const oir = e => vistos.push([e.type, e.detail])
    window.addEventListener('fabrica:consola', oir)
    try {
      abrirConsola({ board: 'b', task_id: 't_1', extra: 'fuera' })
    } finally {
      window.removeEventListener('fabrica:consola', oir)
    }
    assert.deepEqual(vistos, [['fabrica:consola', { board: 'b', task_id: 't_1' }]])
  })
  it('useAbrirConsola llama al callback mientras está montado y se da de baja al desmontar', async () => {
    const { abrirConsola, useAbrirConsola } = await cargar('ui')
    const vistos = []
    const Oyente = ({ cb }) => (useAbrirConsola(cb), null)
    const arbol = montar(Oyente, { cb: d => vistos.push(['1', d]) })
    act(() => abrirConsola({ board: 'b', task_id: 't_1' }))
    act(() => arbol.update(h(Oyente, { cb: d => vistos.push(['2', d]) }))) // el callback nuevo, sin re-suscribir
    act(() => abrirConsola({ board: 'b', task_id: 't_2' }))
    act(() => arbol.unmount())
    abrirConsola({ board: 'b', task_id: 't_3' })
    assert.deepEqual(vistos, [['1', { board: 'b', task_id: 't_1' }], ['2', { board: 'b', task_id: 't_2' }]])
  })
})
