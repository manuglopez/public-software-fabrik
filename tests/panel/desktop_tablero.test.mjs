// Inicio · tablero (IMPL-2): «Te toca a ti» (AC-3a, con Aprobar) y «En marcha» (AC-3d, «Abrir consola aquí» de AC-5),
// AC-6 (sin datos o sin fuente no rompe; solo preferencias en ctx.storage) y AC-1c (sin colores fijos).
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, it, mock } from 'node:test'
import { SDK, SRC, coloresFijos, construir, fixture, h } from './comun.mjs'

const { act, cargar, html, montar, sdk } = await construir('tablero')
const S = await cargar(SDK)
const { fijarCtx } = await cargar('api')
const { TeToca } = await cargar('inicio/te_toca')
const { EnMarcha } = await cargar('inicio/en_marcha')
const { EVENTO_CONSOLA } = await cargar('ui')

const TE_TOCA = '/inicio/te-toca'
const EN_MARCHA = '/inicio/en-marcha'
let ctx
beforeEach(() => {
  ctx = S.ctxFalso()
  fijarCtx(ctx)
})
afterEach(() => mock.restoreAll())

const texto = nodo => (typeof nodo === 'string' ? nodo : (nodo.children ?? []).map(texto).join(''))
const boton = (arbol, etiqueta) => arbol.root.findAll(n => n.type === S.Button && texto(n) === etiqueta)
const llamadas = que => sdk().llamadas.filter(l => l.que === que).map(l => l.args)

describe('AC-3a Te toca a ti', () => {
  it('pinta plan, merge y bloqueada con su pregunta, detalle y número en la cabecera', () => {
    sdk().datos[TE_TOCA] = fixture('tablero_te_toca')
    const out = html(TeToca)
    assert.match(out, /<h3[^>]*>Te toca a ti<\/h3>/)
    assert.match(out, /data-sdk="Badge">3</)
    for (const t of ['PLAN tienda: pagos con tarjeta', '¿Apruebas el plan de pagos?', 'PR #7 abierto', 'capability · Sin credenciales']) {
      assert.ok(out.includes(t.replace(/«|»/g, '')), `falta «${t}»`)
    }
  })

  it('consulta /inicio/te-toca cada 15 s con useQuery (nunca un bucle propio)', () => {
    html(TeToca)
    const c = sdk().consultas.find(q => q.queryKey[1] === TE_TOCA)
    assert.equal(c.refetchInterval, 15000)
  })

  it('botones: Ver en todas, Aprobar solo en los PLAN y Abrir PR solo en los merge', () => {
    sdk().datos[TE_TOCA] = fixture('tablero_te_toca')
    const arbol = montar(TeToca)
    assert.equal(boton(arbol, 'Ver').length, 3)
    assert.equal(boton(arbol, 'Aprobar').length, 1)
    assert.equal(boton(arbol, 'Abrir PR').length, 1)
  })

  it('Ver abre la tarjeta en el Kanban nativo', () => {
    sdk().datos[TE_TOCA] = fixture('tablero_te_toca')
    const arbol = montar(TeToca)
    act(() => { boton(arbol, 'Ver')[2].props.onClick() })
    assert.deepEqual(sdk().navegaciones, ['/kanban?board=default&task=t_0000eeee'])
  })

  it('Abrir PR abre la URL del PR fuera de la app', () => {
    sdk().datos[TE_TOCA] = fixture('tablero_te_toca')
    const arbol = montar(TeToca)
    act(() => { boton(arbol, 'Abrir PR')[0].props.onClick() }) // onClick devuelve la promesa de openExternal
    assert.deepEqual(llamadas('ctx.os.openExternal'), [['https://github.com/acme/tienda/pull/7']])
  })

  it('Aprobar pide confirmación y solo al confirmar hace POST /acciones/aprobar {board, task_id}', async () => {
    sdk().datos[TE_TOCA] = fixture('tablero_te_toca')
    sdk().datos['/acciones/aprobar'] = () => ({ ok: true, salida: 'hecho' })
    const arbol = montar(TeToca)
    assert.equal(arbol.root.findAllByType(S.ConfirmDialog).length, 0)
    act(() => { boton(arbol, 'Aprobar')[0].props.onClick() })
    const dialogo = arbol.root.findByType(S.ConfirmDialog)
    assert.equal(dialogo.props.open, true)
    assert.match(texto(dialogo), /¿Apruebas el plan de pagos\?/)
    assert.deepEqual(llamadas('ctx.rest').filter(([r]) => r === '/acciones/aprobar'), [])
    await act(() => dialogo.props.onConfirm())
    assert.deepEqual(llamadas('ctx.rest').filter(([r]) => r === '/acciones/aprobar'), [
      ['/acciones/aprobar', { method: 'POST', body: { board: 'default', task_id: 't_0000aaaa' } }]
    ])
    act(() => { dialogo.props.onClose() })
    assert.equal(arbol.root.findAllByType(S.ConfirmDialog).length, 0)
  })

  it('si el backend no aprueba, el diálogo muestra el error (onConfirm lanza con la salida)', async () => {
    sdk().datos[TE_TOCA] = fixture('tablero_te_toca')
    sdk().datos['/acciones/aprobar'] = () => ({ ok: false, salida: 'unblock falló' })
    const arbol = montar(TeToca)
    act(() => { boton(arbol, 'Aprobar')[0].props.onClick() })
    await assert.rejects(() => arbol.root.findByType(S.ConfirmDialog).props.onConfirm(), /unblock falló/)
  })

  it('notifica al SO solo los elementos nuevos y recuerda los vistos en ctx.storage', () => {
    const datos = fixture('tablero_te_toca')
    sdk().datos[TE_TOCA] = { items: datos.items.slice(0, 2) }
    const arbol = montar(TeToca)
    assert.deepEqual(llamadas('ctx.os.notify'), [], 'la primera vez solo se apuntan los que ya había')
    act(() => { arbol.update(h(TeToca)) })
    assert.deepEqual(llamadas('ctx.os.notify'), [], 'sin cambios no se avisa')
    sdk().datos[TE_TOCA] = datos
    act(() => { arbol.update(h(TeToca)) })
    const avisos = llamadas('ctx.os.notify')
    assert.equal(avisos.length, 1)
    assert.match(avisos[0][0].title, /Te toca/)
    assert.match(avisos[0][0].body, /IMPL-2 tienda: falta acceso/)
    assert.equal(avisos[0][0].activate, '/the-factory')
    const vistos = ctx.storage.get('te-toca.vistos', null)
    assert.equal(vistos.length, 3)
  })

  it('con vistos guardados de otra sesión no repite el aviso', () => {
    sdk().datos[TE_TOCA] = fixture('tablero_te_toca')
    montar(TeToca)
    const vistos = ctx.storage.get('te-toca.vistos', null)
    ctx = S.ctxFalso()
    ctx.storage.set('te-toca.vistos', vistos)
    fijarCtx(ctx)
    sdk().llamadas.length = 0
    montar(TeToca)
    assert.deepEqual(llamadas('ctx.os.notify'), [])
  })

  it('AC-6: sin datos, vacío o no disponible conserva su <h3> y no rompe', () => {
    for (const datos of [undefined, { items: [] }, { disponible: false, motivo: 'sin kanban' }]) {
      sdk().datos[TE_TOCA] = datos
      const out = html(TeToca)
      assert.match(out, /<h3[^>]*>Te toca a ti<\/h3>/)
    }
    sdk().datos[TE_TOCA] = { items: [] }
    assert.match(html(TeToca), /Nada pendiente/)
    sdk().datos[TE_TOCA] = { disponible: false, motivo: 'sin kanban' }
    assert.match(html(TeToca), /sin kanban/)
  })

  it('AC-6: sin ctx (antes de register) pinta y no avisa', () => {
    fijarCtx(null)
    sdk().datos[TE_TOCA] = fixture('tablero_te_toca')
    montar(TeToca)
    assert.deepEqual(llamadas('ctx.os.notify'), [])
  })
})

describe('AC-3d En marcha', () => {
  // Reloj congelado solo en render estático: react-test-renderer no monta con Date.now fijo.
  const AHORA = 1700000060 * 1000 + 14 * 60 * 1000 // 14 min después del arranque de t_0000cccc

  it('pinta activos / máximo, tableros, rol · modelo, minutos y llamadas/herramientas', () => {
    mock.method(Date, 'now', () => AHORA)
    sdk().datos[EN_MARCHA] = fixture('tablero_en_marcha')
    const out = html(EnMarcha)
    assert.match(out, /<h3[^>]*>En marcha<\/h3>/)
    assert.match(out, /data-sdk="Badge">2 \/ 8</)
    for (const t of ['default', 'programador · modelo-rapido', 'IMPL-1 tienda: pasarela', '14 min', '59 llamadas al modelo · 71 herramientas',
      'revisor · modelo-perfil-rev', '10 min', 'tienda', 'pausa nocturna', '3 tarjetas aparcadas']) {
      assert.ok(out.includes(t), `falta «${t}»`)
    }
    assert.ok(!out.includes('null'), 'sin sesión no pinta «null»')
  })

  it('consulta /inicio/en-marcha cada 15 s', () => {
    html(EnMarcha)
    assert.equal(sdk().consultas.find(q => q.queryKey[1] === EN_MARCHA).refetchInterval, 15000)
  })

  it('«Abrir consola aquí» solo en las tarjetas con worktree y emite fabrica:consola {board, task_id}', () => {
    sdk().datos[EN_MARCHA] = fixture('tablero_en_marcha')
    const arbol = montar(EnMarcha)
    const botones = boton(arbol, 'Abrir consola aquí')
    assert.equal(botones.length, 1)
    const recibidos = []
    const oir = e => recibidos.push(e.detail)
    window.addEventListener(EVENTO_CONSOLA, oir)
    try {
      act(() => { botones[0].props.onClick() })
    } finally {
      window.removeEventListener(EVENTO_CONSOLA, oir)
    }
    assert.deepEqual(recibidos, [{ board: 'default', task_id: 't_0000cccc' }])
  })

  it('Ver abre la tarjeta en marcha en el Kanban nativo', () => {
    sdk().datos[EN_MARCHA] = fixture('tablero_en_marcha')
    const arbol = montar(EnMarcha)
    act(() => { boton(arbol, 'Ver')[1].props.onClick() })
    assert.deepEqual(sdk().navegaciones, ['/kanban?board=default&task=t_0000dddd'])
  })

  it('sin máximo muestra solo los activos; la pausa con hora la dice', () => {
    const datos = fixture('tablero_en_marcha')
    datos.maximo = null
    datos.grupos[1].pausa.hasta = '08:00'
    sdk().datos[EN_MARCHA] = datos
    const out = html(EnMarcha)
    assert.match(out, /data-sdk="Badge">2</)
    assert.ok(out.includes('3 tarjetas aparcadas hasta las 08:00'))
  })

  it('AC-6: sin datos, vacío o no disponible conserva su <h3> y no rompe', () => {
    for (const datos of [undefined, { activos: 0, maximo: 8, grupos: [] }, { disponible: false, motivo: 'sin kanban' }]) {
      sdk().datos[EN_MARCHA] = datos
      assert.match(html(EnMarcha), /<h3[^>]*>En marcha<\/h3>/)
    }
    sdk().datos[EN_MARCHA] = { activos: 0, maximo: 8, grupos: [] }
    assert.match(html(EnMarcha), /Nada en marcha/)
  })
})

describe('AC-1c sin colores fijos', () => {
  it('te_toca.js y en_marcha.js solo usan variables del tema', () => {
    for (const f of ['te_toca.js', 'en_marcha.js']) {
      assert.deepEqual(coloresFijos(readFileSync(join(SRC, 'inicio', f), 'utf8')), [], f)
    }
  })
})
