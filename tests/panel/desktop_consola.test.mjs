// AC-5 — consola por tarjeta (desktop/src/consola.js): pestañas que abre el evento `fabrica:consola`, aviso de tarjeta en
// marcha, cierre, terminal del sistema y el lector de salida (socket + sondeo sin duplicar). Bundle propio: .prueba/consola/.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, it } from 'node:test'
import { SDK, SRC, coloresFijos, construir } from './comun.mjs'

const { cargar, html, montar, act, sdk } = await construir('consola')
const { Consola, lectorSalida, colaEntrada, seguirSalida } = await cargar('consola')
const { abrirConsola } = await cargar('ui')
const { fijarCtx } = await cargar('api')
const { ctxFalso } = await cargar(SDK)

const ABIERTA = { id: 'c_aleatorio_1', titulo: 'repo/mi-slug', cwd: '/x/.factory-worktrees/repo/mi-slug', en_marcha: true }
const rutas = que => sdk().llamadas.filter(l => l.que === que).map(l => l.args[0])
const texto = arbol => JSON.stringify(arbol.toJSON())
/** Abre la consola de una tarjeta con el evento y espera a que termine el POST. */
async function abrir(arbol, tarjeta = { board: 'pruebas', task_id: 't_1' }) {
  await act(async () => {
    abrirConsola(tarjeta)
  })
  return arbol
}

describe('AC-5 Consola: pestañas', () => {
  it('sin consolas conserva el <h3> «Consola» y explica cómo abrir una', () => {
    const h = html(Consola)
    assert.match(h, /<h3[^>]*>Consola<\/h3>/)
    assert.match(h, /Sin consolas abiertas/)
  })

  it('el evento fabrica:consola abre una pestaña con el título <repo>/<slug> y el aviso de en marcha', async () => {
    fijarCtx(ctxFalso())
    sdk().datos['/consola/abrir'] = () => ABIERTA
    const arbol = await abrir(montar(Consola))
    const abiertas = sdk().llamadas.filter(l => l.que === 'ctx.rest' && l.args[0] === '/consola/abrir')
    assert.deepEqual(abiertas.map(l => l.args[1]), [{ method: 'POST', body: { board: 'pruebas', task_id: 't_1' } }])
    assert.match(texto(arbol), /repo\/mi-slug/)
    assert.match(texto(arbol), /La tarjeta está en marcha: mejor mándale un mensaje/)
    assert.match(texto(arbol), /Abrir en terminal del sistema/)
    // Se suscribe a la salida por socket y además sondea una vez (por si el socket no llega)
    assert.deepEqual(rutas('ctx.socket'), ['/consola/c_aleatorio_1?desde=0'])
    act(() => arbol.unmount())
  })

  it('la misma tarjeta otra vez no abre otra consola; sin en_marcha no hay aviso', async () => {
    fijarCtx(ctxFalso())
    sdk().datos['/consola/abrir'] = () => ({ ...ABIERTA, id: 'c_2', titulo: 'repo/otro', en_marcha: false })
    const arbol = montar(Consola)
    await abrir(arbol, { board: 'pruebas', task_id: 't_2' })
    await abrir(arbol, { board: 'pruebas', task_id: 't_2' })
    assert.equal(rutas('ctx.rest').filter(r => r === '/consola/abrir').length, 1)
    assert.doesNotMatch(texto(arbol), /mejor mándale un mensaje/)
    act(() => arbol.unmount())
  })

  it('una consola terminada (exit, inactividad, reinicio) se vuelve a pedir al reabrir su tarjeta', async () => {
    fijarCtx(ctxFalso())
    let n = 0
    sdk().datos['/consola/abrir'] = () => ({ ...ABIERTA, id: `c_muerta_${++n}`, titulo: 'repo/reabrir', en_marcha: n > 1 })
    sdk().datos['/consola/c_muerta_1/salida?desde=0'] = Object.assign(new Error('410: la consola ha terminado'), { statusCode: 410 })
    const arbol = await abrir(montar(Consola), { board: 'pruebas', task_id: 't_4' })
    await act(async () => {
      await new Promise(r => setImmediate(r)) // el sondeo inicial recibe el 410
    })
    await abrir(arbol, { board: 'pruebas', task_id: 't_4' })
    assert.equal(rutas('ctx.rest').filter(r => r === '/consola/abrir').length, 2)
    assert.deepEqual(rutas('ctx.socket').filter(r => r.includes('c_muerta')), ['/consola/c_muerta_1?desde=0', '/consola/c_muerta_2?desde=0'])
    assert.equal(arbol.root.findAllByProps({ role: 'tab', children: 'repo/reabrir' }).length, 1) // la sustituye, no añade otra
    assert.match(texto(arbol), /La tarjeta está en marcha/) // en_marcha refrescado
    act(() => arbol.unmount())
  })

  it('cerrar la pestaña cierra la consola en el backend', async () => {
    fijarCtx(ctxFalso())
    sdk().datos['/consola/abrir'] = () => ({ ...ABIERTA, id: 'c_3', titulo: 'repo/cerrar' })
    const arbol = await abrir(montar(Consola), { board: 'pruebas', task_id: 't_3' })
    await act(async () => {
      arbol.root.findByProps({ 'aria-label': 'Cerrar repo/cerrar' }).props.onClick()
    })
    assert.ok(rutas('ctx.rest').includes('/consola/c_3/cerrar'))
    assert.doesNotMatch(texto(arbol), /repo\/cerrar/)
    act(() => arbol.unmount())
  })

  it('«Abrir en terminal del sistema» llama a /consola/sistema y, si falla, revela la carpeta', async () => {
    fijarCtx(ctxFalso())
    sdk().datos['/consola/abrir'] = () => ({ ...ABIERTA, id: 'c_4', titulo: 'repo/sistema' })
    sdk().datos['/consola/sistema'] = () => ({ ok: false, salida: 'sin emulador' })
    const arbol = await abrir(montar(Consola), { board: 'pruebas', task_id: 't_4' })
    const boton = arbol.root.findAll(n => n.props?.children === 'Abrir en terminal del sistema')[0]
    await act(async () => {
      await boton.props.onClick()
    })
    const sistema = sdk().llamadas.find(l => l.que === 'ctx.rest' && l.args[0] === '/consola/sistema')
    assert.deepEqual(sistema.args[1].body, { board: 'pruebas', task_id: 't_4' })
    assert.deepEqual(rutas('ctx.os.revealPath'), [ABIERTA.cwd])
    act(() => arbol.unmount())
  })

  it('si el backend no abre la consola se avisa y no queda pestaña', async () => {
    fijarCtx(ctxFalso())
    sdk().datos['/consola/abrir'] = new Error('ya hay 6 consolas abiertas')
    const arbol = await abrir(montar(Consola), { board: 'pruebas', task_id: 't_5' })
    assert.match(texto(arbol), /No se pudo abrir la consola: ya hay 6 consolas abiertas/)
    assert.equal(arbol.root.findAll(n => n.props?.role === 'tab' && n.props?.['aria-selected']).length, 1) // sigue la anterior
    assert.doesNotMatch(texto(arbol), /t_5/)
    act(() => arbol.unmount())
  })
})

describe('AC-5 Consola: salida y teclas', () => {
  it('el lector escribe cada trozo una vez y detecta huecos', () => {
    const escrito = []
    const l = lectorSalida(d => escrito.push(d))
    assert.equal(l.aplicar({ datos: 'ab', desde: 0, hasta: 2 }), 'escrito')
    assert.equal(l.aplicar({ datos: 'ab', desde: 0, hasta: 2 }), 'repetido') // el socket se reconecta y repite
    assert.equal(l.aplicar({ datos: '', desde: 2, hasta: 2 }), 'repetido') // latido
    assert.equal(l.aplicar({ datos: 'ñ', desde: 2, hasta: 4 }), 'escrito')
    assert.equal(l.aplicar({ datos: 'z', desde: 9, hasta: 10 }), 'hueco')
    assert.equal(l.aplicar({ datos: 'ñx', desde: 2, hasta: 5 }), 'hueco') // solapa a medias
    assert.deepEqual(escrito, ['ab', 'ñ'])
    assert.equal(l.visto, 4)
    l.aplicar({ datos: '', desde: 4, hasta: 4, viva: false })
    assert.equal(l.viva, false)
  })

  it('el lector acepta el primer trozo aunque el anillo ya no empiece en 0', () => {
    const escrito = []
    const l = lectorSalida(d => escrito.push(d))
    assert.equal(l.aplicar({ datos: 'cola', desde: 300000, hasta: 300004 }), 'escrito')
    assert.deepEqual(escrito, ['cola'])
  })

  it('seguirSalida usa el socket y, ante un hueco, pide /salida desde lo visto', async () => {
    fijarCtx(ctxFalso())
    sdk().datos['/consola/c_9/salida?desde=0'] = () => ({ datos: 'hola', desde: 0, hasta: 4, viva: true })
    sdk().datos['/consola/c_9/salida?desde=4'] = () => ({ datos: ' mundo', desde: 4, hasta: 10, viva: true })
    const escrito = []
    const baja = seguirSalida('c_9', d => escrito.push(d))
    await new Promise(r => setImmediate(r))
    assert.deepEqual(escrito, ['hola'])
    sdk().sockets['/consola/c_9?desde=0']({ datos: 'hola', desde: 0, hasta: 4, viva: true })
    sdk().sockets['/consola/c_9?desde=0']({ datos: '!', desde: 10, hasta: 11, viva: true })
    await new Promise(r => setImmediate(r))
    assert.deepEqual(escrito, ['hola', ' mundo'])
    baja()
    assert.deepEqual(rutas('ctx.socket.cerrar'), ['/consola/c_9?desde=0'])
  })

  it('si el anillo rotó y /salida empieza más allá de lo visto, lo acepta y la pantalla no se congela', async () => {
    fijarCtx(ctxFalso())
    sdk().datos['/consola/c_10/salida?desde=0'] = () => ({ datos: 'ab', desde: 0, hasta: 2, viva: true })
    sdk().datos['/consola/c_10/salida?desde=2'] = () => ({ datos: 'tras-rotar', desde: 500000, hasta: 500010, viva: true })
    const escrito = []
    const baja = seguirSalida('c_10', d => escrito.push(d))
    await new Promise(r => setImmediate(r))
    // El socket sigue desde donde quedó el servidor (más allá de lo visto): hueco → /salida desde 2, que ya rotó
    sdk().sockets['/consola/c_10?desde=0']({ datos: 'x', desde: 499999, hasta: 500000, viva: true })
    await new Promise(r => setImmediate(r))
    sdk().sockets['/consola/c_10?desde=0']({ datos: 'sigue', desde: 500010, hasta: 500015, viva: true })
    assert.deepEqual(escrito, ['ab', 'tras-rotar', 'sigue'])
    baja()
  })

  it('si el backend ya no tiene la consola (404/410) deja de sondear y la da por terminada', async () => {
    fijarCtx(ctxFalso())
    sdk().datos['/consola/c_11/salida?desde=0'] = Object.assign(new Error('404: consola desconocida'), { statusCode: 404 })
    let terminada = 0
    const baja = seguirSalida('c_11', () => {}, () => terminada++)
    await new Promise(r => setImmediate(r))
    assert.equal(terminada, 1)
    baja()
    fijarCtx(ctxFalso())
    sdk().datos['/consola/c_12/salida?desde=0'] = new Error('410: la consola ha terminado') // por IPC sin statusCode
    const baja2 = seguirSalida('c_12', () => {}, () => terminada++)
    await new Promise(r => setImmediate(r))
    assert.equal(terminada, 2)
    baja2()
  })

  it('la cola de teclas manda en orden, una petición a la vez, juntando lo pendiente', async () => {
    const enviados = []
    let soltar
    const cola = colaEntrada(d => (enviados.push(d), new Promise(r => (soltar = r))))
    const fin = cola.poner('l')
    cola.poner('s')
    cola.poner('\r')
    assert.deepEqual(enviados, ['l'])
    soltar()
    await new Promise(r => setImmediate(r))
    assert.deepEqual(enviados, ['l', 's\r'])
    soltar()
    await fin
  })

  it('consola.js no usa colores fijos y empaqueta el CSS de xterm', () => {
    const fuente = readFileSync(join(SRC, 'consola.js'), 'utf8')
    assert.deepEqual(coloresFijos(fuente), [])
    assert.match(fuente, /@xterm\/xterm\/css\/xterm\.css/)
  })
})
