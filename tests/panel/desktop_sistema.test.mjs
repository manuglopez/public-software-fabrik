// Zona `sistema` (IMPL-4): Cupos (AC-3e), Máquina (AC-3f), Memoria en Inicio (AC-3g, AC-6) y Lanzar trabajo (AC-3h).
// Reloj y zona horaria fijos: TZ=Europe/Madrid y Date congelado con mock.timers (sábado 24/10/2026 12:00).
process.env.TZ = 'Europe/Madrid'
import assert from 'node:assert/strict'
import { afterEach, beforeEach, describe, it, mock } from 'node:test'
import { construir, fixture } from './comun.mjs'

const { cargar, html, montar, act, sdk } = await construir('sistema')
const AHORA = Date.parse('2026-10-24T12:00:00+02:00')

beforeEach(() => mock.timers.enable({ apis: ['Date'], now: AHORA }))
afterEach(() => mock.timers.reset())

const conCtx = async () => {
  const ctx = (await cargar('_sdk_falso')).ctxFalso()
  ;(await cargar('api')).fijarCtx(ctx)
  return ctx
}
const llamadas = que => sdk().llamadas.filter(l => l.que === que).map(l => l.args)
const consulta = ruta => sdk().consultas.find(c => c.queryKey?.[1] === ruta)
const texto = arbol => JSON.stringify(arbol.toJSON())
const pulsar = async (arbol, nombre) => {
  const b = arbol.root.findAll(n => n.type === 'button' && [n.props.children].flat().join('') === nombre)
  assert.equal(b.length, 1, `un botón «${nombre}»`)
  await act(async () => b[0].props.onClick())
}

describe('AC-3e Cupos', () => {
  it('pinta cada bolsa con nombre, barra, % y renovación, y la hora de la foto', async () => {
    sdk().datos['/cupos'] = fixture('sistema_cupos')
    const { Cupos } = await cargar('inicio/cupos')
    const h = html(Cupos)
    assert.match(h, /<h3[^>]*>Cupos<\/h3>/)
    assert.match(h, /foto 05:20/)
    for (const t of ['Claude semana · uno', 'Claude 5 h · uno', 'Kimi 5 h', 'Kimi 7 días', 'Gemini semana', 'Antigravity-Claude semana']) {
      assert.ok(h.includes(`>${t}<`), t)
    }
    assert.match(h, /84 % · 18:00/)
    assert.match(h, /9 % · 05:00/)
    assert.match(h, /85 % · lun 00:27/)
    assert.match(h, /0 % · 31\/10/)
    assert.match(h, />100 %</, 'sin renovación no pinta « · »')
    assert.match(h, /width:84.4%/)
    assert.equal((h.match(/opacity-45/g) ?? []).length, 2, 'las dos bolsas llenas van atenuadas')
  })
  it('los avisos van arriba como alerta', async () => {
    sdk().datos['/cupos'] = fixture('sistema_cupos')
    const { Cupos } = await cargar('inicio/cupos')
    assert.match(html(Cupos), /role="alert"[^>]*>⚠ Cupo claude_sem@uno al 84 % \(renueva 2026-10-24 18:00\)</)
  })
  it('refresca cada 30 s', async () => {
    sdk().datos['/cupos'] = fixture('sistema_cupos')
    const { Cupos } = await cargar('inicio/cupos')
    html(Cupos)
    assert.equal(consulta('/cupos').refetchInterval, 30000)
  })
  it('sin foto dice por qué y conserva su <h3>', async () => {
    sdk().datos['/cupos'] = { disponible: false, motivo: 'sin foto de cupos: no existe' }
    const { Cupos } = await cargar('inicio/cupos')
    const h = html(Cupos)
    assert.match(h, /<h3[^>]*>Cupos<\/h3>/)
    assert.match(h, /Cupos no disponible/)
    assert.match(h, /sin foto de cupos: no existe/)
  })
  it('nombreBolsa y fmtRenueva', async () => {
    const { nombreBolsa, fmtRenueva } = await cargar('inicio/cupos')
    assert.equal(nombreBolsa('claude_sem@info'), 'Claude semana · info')
    assert.equal(nombreBolsa('openai_30d'), 'OpenAI 30 días')
    assert.equal(nombreBolsa('fable_sem@x'), 'Fable semana · x')
    assert.equal(nombreBolsa('raro_9h'), 'raro_9h')
    assert.equal(nombreBolsa('suelta'), 'suelta')
    assert.equal(fmtRenueva('2026-10-24T21:30:00Z', AHORA), '23:30', 'hoy: solo la hora local')
    assert.equal(fmtRenueva('2026-10-29T08:00:00+01:00', AHORA), 'jue 08:00')
    assert.equal(fmtRenueva('2026-10-30T13:00:00+01:00', AHORA), '30/10', 'a 6 días o más: fecha')
    assert.equal(fmtRenueva('2026-10-20T10:00:00+02:00', AHORA), '20/10', 'pasada: fecha')
    assert.equal(fmtRenueva(null, AHORA), '')
    assert.equal(fmtRenueva('no es fecha', AHORA), '')
  })
})

describe('AC-3f Máquina', () => {
  it('RAM, CPU y turno de tests con titular y cola', async () => {
    sdk().datos['/maquina'] = fixture('sistema_maquina')
    const { Maquina } = await cargar('inicio/maquina')
    const h = html(Maquina)
    assert.match(h, /<h3[^>]*>Máquina<\/h3>/)
    assert.match(h, />20 \/ 31 GB</)
    assert.match(h, /width:64.51612903225806%/)
    assert.match(h, />6,4 \/ 16</)
    assert.match(h, /width:40%/)
    assert.match(h, />🔒 programador · software-fabrik \[IMPL-4\]</)
    assert.match(h, /title="programador pid=100 repo=software-fabrik \[IMPL-4\] cmd=bash tests\/panel_backend_test.sh desde=18:31:02"/)
    assert.match(h, />cola: 2 \(1 con prioridad\)</)
    assert.match(h, /title="⏫ web: npm test\napi-acme: vendor\/bin\/phpunit"/)
  })
  it('turno libre, sin cola y sin /proc', async () => {
    sdk().datos['/maquina'] = { ram: { disponible: false, motivo: 'x' }, cpu: { disponible: false, motivo: 'y' }, suite: { titular: null, cola: [] } }
    const { Maquina } = await cargar('inicio/maquina')
    const h = html(Maquina)
    assert.match(h, />libre</)
    assert.match(h, />cola: 0</)
    assert.equal((h.match(/>—</g) ?? []).length, 2)
  })
  it('titular con formato desconocido se muestra tal cual', async () => {
    const { textoSuite } = await cargar('inicio/maquina')
    assert.deepEqual(textoSuite({ titular: { texto: 'alguien a mano' } }), { texto: '🔒 alguien a mano', titulo: 'alguien a mano' })
  })
  it('refresca cada 15 s', async () => {
    sdk().datos['/maquina'] = fixture('sistema_maquina')
    const { Maquina } = await cargar('inicio/maquina')
    html(Maquina)
    assert.equal(consulta('/maquina').refetchInterval, 15000)
  })
})

describe('AC-3g Memoria en Inicio', () => {
  it('banco, documentos, nodos, última entrada y hoy por fuente', async () => {
    sdk().datos['/memoria'] = fixture('sistema_memoria')
    const { Memoria } = await cargar('inicio/memoria')
    const h = html(Memoria)
    assert.match(h, /<h3[^>]*>Memoria<\/h3>/)
    assert.match(h, /ejemplo · <b[^>]*>451<\/b> documentos · <b[^>]*>14\.595<\/b> nodos/)
    assert.match(h, /title="tarjeta\/t_0000aaaa"[^>]*>última entrada rel:2026-10-24T09:56:00.000Z</)
    assert.match(h, />Hoy: 12 tarjetas · 5 lecciones · 3 PRs · 2 rara · 1 notas de Claude Code</)
    assert.equal(consulta('/memoria').refetchInterval, 30000)
  })
  it('sin entradas hoy ni última entrada', async () => {
    sdk().datos['/memoria'] = { disponible: true, banco: 'b', documentos: 0, nodos: 0, hoy: {} }
    const { Memoria } = await cargar('inicio/memoria')
    const h = html(Memoria)
    assert.match(h, />Hoy: nada todavía</)
    assert.doesNotMatch(h, /última entrada/)
  })
  it('Abrir grafo abre el Control Plane con ctx.os.openExternal', async () => {
    await conCtx()
    sdk().datos['/memoria'] = fixture('sistema_memoria')
    const { Memoria } = await cargar('inicio/memoria')
    await pulsar(montar(Memoria), 'Abrir grafo')
    assert.deepEqual(llamadas('ctx.os.openExternal'), [['http://127.0.0.1:9999/banks/ejemplo']])
  })
  it('sin grafo_url el botón está desactivado y dice qué configurar', async () => {
    sdk().datos['/memoria'] = { ...fixture('sistema_memoria'), grafo_url: undefined }
    const { Memoria } = await cargar('inicio/memoria')
    assert.match(html(Memoria), /<button[^>]*disabled=""[^>]*title="Configura memoria.grafo_url[^"]*"[^>]*>Abrir grafo</)
  })
  it('Buscar despliega el buscador y enseña el recall (POST /memoria/buscar)', async () => {
    await conCtx()
    sdk().datos['/memoria'] = fixture('sistema_memoria')
    sdk().datos['/memoria/buscar'] = op => ({ disponible: true, texto: `- [api] usa travelTo (${op.body.q})` })
    const { Memoria } = await cargar('inicio/memoria')
    const arbol = montar(Memoria)
    assert.equal(arbol.root.findAllByType('input').length, 0)
    await pulsar(arbol, 'Buscar')
    const input = arbol.root.findByType('input')
    await act(async () => input.props.onChange({ target: { value: '  relojes  ' } }))
    await act(async () => arbol.root.findByType('form').props.onSubmit({ preventDefault() {} }))
    assert.deepEqual(llamadas('ctx.rest').filter(([r]) => r === '/memoria/buscar'), [['/memoria/buscar', { method: 'POST', body: { q: 'relojes' } }]])
    assert.match(texto(arbol), /- \[api\] usa travelTo \(relojes\)/)
    assert.equal(sdk().invalidadas.length, 0, 'buscar no refresca el resto del panel')
  })
  it('Buscar con la memoria caída o el backend roto dice «no disponible»', async () => {
    await conCtx()
    const { buscarMemoria } = await cargar('inicio/memoria')
    sdk().datos['/memoria/buscar'] = { disponible: false, motivo: 'timeout tras 1.5s', texto: '' }
    assert.equal((await buscarMemoria('x')).disponible, false)
    sdk().datos['/memoria/buscar'] = new Error('HTTP 500')
    assert.deepEqual(await buscarMemoria('x'), { disponible: false, motivo: 'HTTP 500' })
  })
  it('sin resultados lo dice', async () => {
    await conCtx()
    sdk().datos['/memoria'] = fixture('sistema_memoria')
    sdk().datos['/memoria/buscar'] = { disponible: true, texto: '' }
    const { Memoria } = await cargar('inicio/memoria')
    const arbol = montar(Memoria)
    await pulsar(arbol, 'Buscar')
    await act(async () => arbol.root.findByType('input').props.onChange({ target: { value: 'x' } }))
    await act(async () => arbol.root.findByType('form').props.onSubmit({ preventDefault() {} }))
    assert.match(texto(arbol), /Sin resultados\./)
  })
  it('dos Enter seguidos mientras busca lanzan un solo recall', async () => {
    await conCtx()
    let responder
    sdk().datos['/memoria'] = fixture('sistema_memoria')
    sdk().datos['/memoria/buscar'] = () => new Promise(r => (responder = r))
    const { Memoria } = await cargar('inicio/memoria')
    const arbol = montar(Memoria)
    await pulsar(arbol, 'Buscar')
    await act(async () => arbol.root.findByType('input').props.onChange({ target: { value: 'x' } }))
    let pendiente
    act(() => {
      const enviar = arbol.root.findByType('form').props.onSubmit
      pendiente = enviar({ preventDefault() {} })
      enviar({ preventDefault() {} }) // mismo render: el cierre aún no ve «buscando»
    })
    assert.equal(llamadas('ctx.rest').filter(([r]) => r === '/memoria/buscar').length, 1)
    await act(async () => {
      responder({ disponible: true, texto: 'hecho' })
      await pendiente
    })
    assert.match(texto(arbol), /hecho/)
  })
})

describe('AC-6 memoria no disponible', () => {
  it('el bloque dice «no disponible» con el motivo y conserva su <h3>', async () => {
    sdk().datos['/memoria'] = { disponible: false, motivo: '(memoria no disponible: URLError; sigue sin ella)' }
    const { Memoria } = await cargar('inicio/memoria')
    const h = html(Memoria)
    assert.match(h, /<h3[^>]*>Memoria<\/h3>/)
    assert.match(h, /Memoria no disponible/)
    assert.match(h, /URLError/)
    assert.doesNotMatch(h, /Abrir grafo/)
  })
})

describe('AC-3h Lanzar trabajo', () => {
  it('cuatro flujos con su botón, como la maqueta', async () => {
    const { Lanzar } = await cargar('inicio/lanzar')
    const h = html(Lanzar)
    assert.match(h, /<h3[^>]*>Lanzar trabajo<\/h3>/)
    for (const t of ['Nueva feature', 'Bug', 'Incorporar repo', 'Diagnosticar repo dormido']) assert.ok(h.includes(`<b>${t}</b>`), t)
    assert.deepEqual([...h.matchAll(/data-flujo="([^"]+)"/g)].map(m => m[1]), ['feature', 'bug', 'incorporar', 'diagnosticar'])
  })
  for (const [boton, n, flujo] of [['Empezar', 0, 'feature'], ['Empezar', 1, 'bug'], ['Incorporar', 0, 'incorporar'], ['Diagnosticar', 0, 'diagnosticar']]) {
    it(`«${flujo}» abre chat nuevo con «/fabrica ${flujo} » sin enviarlo`, async () => {
      const { Lanzar } = await cargar('inicio/lanzar')
      const arbol = montar(Lanzar)
      const b = arbol.root.findAll(x => x.type === 'button' && x.props.children === boton)[n]
      await act(async () => b.props.onClick())
      assert.deepEqual(llamadas('host.newChat'), [[]])
      assert.deepEqual(llamadas('host.composer.setDraft'), [['new', `/fabrica ${flujo} `]])
      assert.deepEqual(llamadas('host.composer.submit'), [])
      assert.doesNotMatch(texto(arbol), /No se pudo abrir el chat/)
    })
  }
  it('reintenta setDraft mientras monta el composer y avisa si no llega', async () => {
    const { host } = await cargar('_sdk_falso')
    const { abrirChatCon } = await cargar('inicio/lanzar')
    const original = host.composer.setDraft
    try {
      let n = 0
      host.composer.setDraft = async () => ++n === 3
      assert.equal(await abrirChatCon('/fabrica bug ', { intentos: 5, esperaMs: 0 }), true)
      assert.equal(n, 3)
      host.composer.setDraft = async () => false
      assert.equal(await abrirChatCon('/fabrica bug ', { intentos: 4, esperaMs: 0 }), false)
      assert.equal(llamadas('host.newChat').length, 2)
    } finally {
      host.composer.setDraft = original
    }
  })
  it('si el host lanza al abrir el chat, devuelve false y Lanzar avisa', async () => {
    const { host } = await cargar('_sdk_falso')
    const { abrirChatCon, Lanzar } = await cargar('inicio/lanzar')
    const original = host.composer.setDraft
    try {
      host.composer.setDraft = async () => {
        throw new Error('composer roto')
      }
      assert.equal(await abrirChatCon('/fabrica bug ', { intentos: 2, esperaMs: 0 }), false)
      const arbol = montar(Lanzar)
      const b = arbol.root.findAll(x => x.type === 'button' && x.props.children === 'Incorporar')[0]
      await act(async () => b.props.onClick())
      assert.match(texto(arbol), /No se pudo abrir el chat: escribe «\/fabrica incorporar»/)
    } finally {
      host.composer.setDraft = original
    }
  })
})
