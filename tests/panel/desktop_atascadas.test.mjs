// Zona `atascadas` (IMPL-3): «Atascadas» (AC-3b), «Cadena» (AC-3c), confirmación de acciones (AC-2b) y «Abrir consola aquí» (AC-5).
import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { SDK, SRC, coloresFijos, construir, fixture } from './comun.mjs'

const { cargar, html, montar, act, sdk } = await construir('atascadas')
const falso = await cargar(SDK)

const botones = arbol => arbol.root.findAllByType(falso.Button)
const texto = b => [b.props.children].flat().join('')
const boton = (arbol, etiqueta, n = 0) => botones(arbol).filter(b => texto(b) === etiqueta)[n]
const dialogo = arbol => arbol.root.findByType(falso.ConfirmDialog)

async function atascadas(datos = fixture('atascadas_items')) {
  sdk().datos['/inicio/atascadas'] = datos
  const { Atascadas } = await cargar('inicio/atascadas')
  const { fijarCtx } = await cargar('api')
  fijarCtx(falso.ctxFalso())
  return { arbol: montar(Atascadas) }
}

describe('AC-3b: Atascadas', () => {
  it('conserva el <h3> «Atascadas» y pinta motivo y detalle de cada tarjeta', async () => {
    sdk().datos['/inicio/atascadas'] = fixture('atascadas_items')
    const { Atascadas } = await cargar('inicio/atascadas')
    const salida = html(Atascadas)
    assert.match(salida, /<h3[^>]*>Atascadas<\/h3>/)
    for (const t of ['Revisar algo', 'Error viejo de cupo en revisión', '429 usage limit · sin run desde hace 20 min', 'Sin cupo', 'Esperando merge', 'apilado sobre #5'])
      assert.ok(salida.includes(t), t)
  })

  it('estados vacío / no disponible / cargando', async () => {
    const { Atascadas } = await cargar('inicio/atascadas')
    assert.match(html(Atascadas), /Cargando/)
    sdk().datos['/inicio/atascadas'] = { items: [] }
    assert.match(html(Atascadas), /Nada atascado/)
    sdk().datos['/inicio/atascadas'] = { disponible: false, motivo: 'sin tableros de Kanban' }
    assert.match(html(Atascadas), /sin tableros de Kanban/)
  })

  it('cada tarjeta ofrece el botón de su acción y solo ese (sin acción, sin botón de acción)', async () => {
    const { arbol } = await atascadas()
    const etiquetas = botones(arbol).map(texto)
    assert.equal(etiquetas.filter(e => e === 'Desatascar').length, 1)
    assert.equal(etiquetas.filter(e => e === 'Pasar a claude-sonnet-5-5').length, 1)
    assert.equal(etiquetas.filter(e => e === 'Ver').length, 4)
    assert.deepEqual(etiquetas.filter(e => e.startsWith('Abrir PR')), ['Abrir PR #7'])
  })

  it('«Ver» abre la tarjeta (abrirTarjeta) con su tablero', async () => {
    const { arbol } = await atascadas()
    boton(arbol, 'Ver', 1).props.onClick()
    assert.deepEqual(sdk().navegaciones, ['/kanban?board=demo&task=t_bbb1'])
  })

  it('«Abrir consola aquí» solo sale en las que tienen worktree y emite fabrica:consola', async () => {
    const { arbol } = await atascadas()
    assert.equal(botones(arbol).filter(b => texto(b) === 'Abrir consola aquí').length, 1)
    const { EVENTO_CONSOLA } = await cargar('ui')
    const recibidos = []
    globalThis.window.addEventListener(EVENTO_CONSOLA, e => recibidos.push(e.detail))
    boton(arbol, 'Abrir consola aquí').props.onClick()
    assert.deepEqual(recibidos, [{ board: 'demo', task_id: 't_aaa1' }])
  })

  it('«Abrir PR» abre la URL con ctx.os.openExternal', async () => {
    const { arbol } = await atascadas()
    boton(arbol, 'Abrir PR #7').props.onClick()
    assert.deepEqual(sdk().llamadas.filter(l => l.que === 'ctx.os.openExternal').map(l => l.args), [['https://github.com/o/r/pull/7']])
  })
})

describe('AC-2b: acciones con confirmación', () => {
  it('pulsar la acción abre el diálogo y NO escribe hasta confirmar', async () => {
    const { arbol } = await atascadas()
    assert.equal(dialogo(arbol).props.open, false)
    act(() => boton(arbol, 'Desatascar').props.onClick())
    assert.equal(dialogo(arbol).props.open, true)
    assert.equal(dialogo(arbol).props.title, 'Desatascar t_aaa1')
    assert.deepEqual(sdk().llamadas.filter(l => l.que === 'ctx.rest'), [])
  })

  it('confirmar desatascar hace POST /acciones/desatascar con tablero y tarjeta', async () => {
    const { arbol } = await atascadas()
    act(() => boton(arbol, 'Desatascar').props.onClick())
    sdk().datos['/acciones/desatascar'] = { ok: true, salida: '' }
    await act(async () => { await dialogo(arbol).props.onConfirm() })
    assert.deepEqual(
      sdk().llamadas.filter(l => l.que === 'ctx.rest').map(l => l.args),
      [['/acciones/desatascar', { method: 'POST', body: { board: 'demo', task_id: 't_aaa1' } }]]
    )
    assert.deepEqual(sdk().invalidadas, [{ queryKey: ['fabrica'] }])
  })

  it('confirmar set_model envía modelo y proveedor a /acciones/set-model', async () => {
    const { arbol } = await atascadas()
    act(() => boton(arbol, 'Pasar a claude-sonnet-5-5').props.onClick())
    sdk().datos['/acciones/set-model'] = { ok: true, salida: '' }
    await act(async () => { await dialogo(arbol).props.onConfirm() })
    assert.deepEqual(
      sdk().llamadas.filter(l => l.que === 'ctx.rest').map(l => l.args),
      [['/acciones/set-model', { method: 'POST', body: { board: 'demo', task_id: 't_bbb1', modelo: 'claude-sonnet-5-5', proveedor: 'claude-subscription' } }]]
    )
  })

  it('si el backend dice ok:false, el diálogo recibe el error (se queda abierto)', async () => {
    const { arbol } = await atascadas()
    act(() => boton(arbol, 'Desatascar').props.onClick())
    sdk().datos['/acciones/desatascar'] = { ok: false, salida: 'last_failure_error sigue: 429' }
    await assert.rejects(dialogo(arbol).props.onConfirm(), /last_failure_error sigue/)
  })

  it('cancelar cierra sin escribir', async () => {
    const { arbol } = await atascadas()
    act(() => boton(arbol, 'Desatascar').props.onClick())
    act(() => dialogo(arbol).props.onClose())
    assert.equal(dialogo(arbol).props.open, false)
    assert.deepEqual(sdk().llamadas.filter(l => l.que === 'ctx.rest'), [])
  })
})

describe('AC-3c: Cadena', () => {
  it('niveles: padres a la izquierda, sin duplicar y tolerando ciclos', async () => {
    const { niveles } = await cargar('inicio/cadena')
    const { cadenas: [c] } = fixture('atascadas_cadena')
    assert.deepEqual(niveles(c.nodos, c.aristas).map(col => col.map(n => n.etiqueta)), [['BASE'], ['IMPL-2', 'IMPL-3'], ['CIERRE-2'], ['PR-2']])
    const a = [{ task_id: 'a' }, { task_id: 'b' }]
    assert.equal(niveles(a, [['a', 'b'], ['b', 'a']]).flat().length, 2)
  })

  it('conserva el <h3> «Cadena» y pinta etiqueta, estado y minutos', async () => {
    sdk().datos['/inicio/cadena'] = fixture('atascadas_cadena')
    const { Cadena } = await cargar('inicio/cadena')
    const salida = html(Cadena)
    assert.match(salida, /<h3[^>]*>Cadena<\/h3>/)
    for (const t of ['The Factory', '1/5 hechas', '✓ BASE', '● IMPL-2 · 12 min', '○ PR-2']) assert.ok(salida.includes(t), t)
  })

  it('clic en un nodo → abrirTarjeta; «Abrir consola aquí» solo en el que tiene worktree', async () => {
    sdk().datos['/inicio/cadena'] = fixture('atascadas_cadena')
    const { Cadena } = await cargar('inicio/cadena')
    const arbol = montar(Cadena)
    boton(arbol, '● IMPL-3 · 90 min').props.onClick()
    assert.deepEqual(sdk().navegaciones, ['/kanban?board=demo&task=t_im3'])
    assert.equal(botones(arbol).filter(b => texto(b) === 'Abrir consola aquí').length, 1)
  })

  it('estados vacío y no disponible', async () => {
    const { Cadena } = await cargar('inicio/cadena')
    sdk().datos['/inicio/cadena'] = { cadenas: [] }
    assert.match(html(Cadena), /Sin cadenas en marcha/)
    sdk().datos['/inicio/cadena'] = { disponible: false, motivo: 'sin tableros de Kanban' }
    assert.match(html(Cadena), /sin tableros de Kanban/)
  })
})

describe('estilo', () => {
  it('ni atascadas.js ni cadena.js llevan colores fijos', () => {
    for (const f of ['inicio/atascadas.js', 'inicio/cadena.js']) assert.deepEqual(coloresFijos(readFileSync(join(SRC, f), 'utf8')), [], f)
  })
})
