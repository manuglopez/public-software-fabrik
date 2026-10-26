// Tests de la mitad de escritorio de The Factory (D-8): registro, página, chip, api.js y colores fijos (AC-1, AC-1b, AC-1c).
// Congelado tras BASE (D-9 R-1): no depende del contenido de ninguna sección. Cada zona prueba lo suyo en
// `tests/panel/desktop_<zona>.test.mjs` con `construir('<zona>')` de comun.mjs (ver allí el patrón).
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { describe, it, beforeEach } from 'node:test'
import { SDK, SRC, coloresFijos, construir, ficheros, fixture } from './comun.mjs'

const { cargar, html, montar, act, sdk } = await construir('desktop')

describe('AC-1 registro (register(ctx))', () => {
  let ctx
  beforeEach(async () => { // register de nuevo en cada test: el ctx es estado del módulo y otros tests lo cambian
    const { default: plugin } = await cargar('index')
    ctx = (await cargar(SDK)).ctxFalso()
    plugin.register(ctx)
  })
  const de = area => sdk().contribuciones.filter(c => c.area === area)

  it('id fabrica y nombre The Factory', async () => {
    const { default: plugin } = await cargar('index')
    assert.equal(plugin.id, 'fabrica')
    assert.equal(plugin.name, 'The Factory')
  })
  it('ruta /the-factory que renderiza la página', () => {
    const [ruta] = de('routes')
    assert.equal(ruta.data.path, '/the-factory')
    assert.match(html(() => ruta.render()), /The Factory/)
  })
  it('entrada lateral «The Factory» con codicon tools', () => {
    const [nav] = de('sidebar.nav')
    assert.deepEqual(nav.data, { path: '/the-factory', label: 'The Factory', codicon: 'tools' })
  })
  it('⌘K «The Factory» navega a la página', () => {
    const [pal] = de('palette')
    assert.equal(pal.data.label, 'The Factory')
    assert.equal(pal.data.id, 'the-factory.open')
    for (const palabra of ['fábrica', 'fabrica', 'factory', 'kanban', 'agentes']) assert.ok(pal.data.keywords.includes(palabra), palabra)
    pal.data.run()
    assert.deepEqual(sdk().navegaciones, ['/the-factory'])
  })
  it('chip en la barra de estado derecha, con orden 125', () => {
    const chips = de('statusBar.right')
    assert.equal(chips.length, 1)
    assert.equal(chips[0].order, 125)
  })
  it('el chip registrado abre /the-factory al pulsarlo', () => {
    const arbol = montar(() => de('statusBar.right')[0].render())
    arbol.root.findByType('button').props.onClick()
    assert.deepEqual(sdk().navegaciones, ['/the-factory'])
  })
  it('register fija el ctx: las consultas de la página llaman al backend de este plugin y ctxPlugin() es ese ctx', async () => {
    sdk().datos['/inicio/te-toca'] = { ok: true }
    montar(() => de('statusBar.right')[0].render())
    const [consulta] = sdk().consultas
    assert.deepEqual(await consulta.queryFn(), { ok: true })
    assert.deepEqual(sdk().llamadas.filter(l => l.que === 'ctx.rest').map(l => l.args), [['/inicio/te-toca', undefined]])
    assert.equal((await cargar('api')).ctxPlugin(), ctx)
  })
})

describe('AC-1 página', () => {
  it('cabecera con el logo (var(--accent) + currentColor) y las 5 pestañas en orden', async () => {
    const { Pagina } = await cargar('pagina')
    const salida = html(Pagina)
    assert.match(salida, /<svg[^>]*aria-label="The Factory"/)
    assert.ok(salida.includes('stroke="var(--accent)"') && salida.includes('stroke="currentColor"'))
    const tabs = [...salida.matchAll(/role="tab"[^>]*>([^<]+)</g)].map(m => m[1])
    assert.deepEqual(tabs, ['Inicio', 'Proyectos', 'Agentes', 'Cupos y costes', 'Memoria'])
  })
  it('Inicio monta sus 9 secciones (por su <h3>)', async () => {
    const { Pagina } = await cargar('pagina')
    const titulos = [...html(Pagina).matchAll(/<h3[^>]*>([^<]+)<\/h3>/g)].map(m => m[1])
    for (const t of ['Atascadas', 'Cadena', 'Consola', 'Cupos', 'En marcha', 'Lanzar trabajo', 'Memoria', 'Máquina', 'Te toca a ti']) {
      assert.ok(titulos.includes(t), `falta la sección «${t}» en Inicio`)
    }
  })
  it('cada pestaña tiene vista propia y renderiza sin lanzar', async () => {
    const { PESTANAS } = await cargar('pagina')
    assert.deepEqual(PESTANAS.map(p => p.id), ['inicio', 'proyectos', 'agentes', 'costes', 'memoria'])
    assert.equal(new Set(PESTANAS.map(p => p.vista)).size, PESTANAS.length)
    for (const p of PESTANAS) assert.doesNotThrow(() => html(p.vista), p.id)
  })
  it('la pestaña activa (Inicio al abrir) es la única con aria-selected=true', async () => {
    const { Pagina } = await cargar('pagina')
    const estados = [...html(Pagina).matchAll(/role="tab"[^>]*aria-selected="(\w+)"/g)].map(m => m[1])
    assert.deepEqual(estados, ['true', 'false', 'false', 'false', 'false'])
  })
  it('pulsar una pestaña la activa y monta su vista (y no la de Inicio)', async () => {
    const { Pagina, PESTANAS } = await cargar('pagina')
    const arbol = montar(Pagina)
    const tabs = () => arbol.root.findAllByProps({ role: 'tab' })
    act(() => tabs()[2].props.onClick())
    assert.deepEqual(tabs().map(t => t.props['aria-selected']), [false, false, true, false, false])
    assert.equal(arbol.root.findAllByType(PESTANAS[2].vista).length, 1)
    assert.equal(arbol.root.findAllByType(PESTANAS[0].vista).length, 0)
  })
})

describe('AC-1b chip «The Factory · N»', () => {
  const chip = async () => (await cargar('chip')).Chip
  it('sin /inicio/te-toca no lleva número', async () => {
    const salida = html(await chip(), { abrir() {} })
    assert.match(salida, /<span>The Factory<\/span>/)
    assert.doesNotMatch(salida, /·/)
  })
  it('con datos muestra N = nº de elementos', async () => {
    sdk().datos = { '/inicio/te-toca': fixture('te_toca') }
    assert.match(html(await chip(), { abrir() {} }), /The Factory · 2/)
  })
  it('con 0 elementos muestra «· 0»', async () => {
    sdk().datos = { '/inicio/te-toca': { items: [] } }
    assert.match(html(await chip(), { abrir() {} }), /The Factory · 0/)
  })
  it('refresca /inicio/te-toca cada 15 s', async () => {
    html(await chip(), { abrir() {} })
    const [consulta] = sdk().consultas
    assert.deepEqual(consulta.queryKey, ['fabrica', '/inicio/te-toca'])
    assert.equal(consulta.refetchInterval, 15000)
  })
  it('pulsarlo llama a abrir', async () => {
    let abierto = 0
    const arbol = montar(await chip(), { abrir: () => abierto++ })
    arbol.root.findByType('button').props.onClick()
    assert.equal(abierto, 1)
  })
})

describe('api.js', () => {
  it('useFx: clave [fabrica, ruta], sin reintentos, refresco opcional y queryFn por ctx.rest', async () => {
    const { fijarRest, useFx } = await cargar('api')
    const llamadas = []
    fijarRest(async (...args) => (llamadas.push(args), { ok: 1 }))
    const Prueba = ({ opciones }) => (useFx('/inicio/x', opciones), null)
    montar(Prueba, {})
    montar(Prueba, { opciones: { cadaMs: 5000 } })
    const [sinRefresco, conRefresco] = sdk().consultas
    for (const c of [sinRefresco, conRefresco]) {
      assert.deepEqual(c.queryKey, ['fabrica', '/inicio/x'])
      assert.equal(c.retry, false)
    }
    assert.equal(sinRefresco.refetchInterval, false)
    assert.equal(conRefresco.refetchInterval, 5000)
    assert.deepEqual(await conRefresco.queryFn(), { ok: 1 })
    assert.deepEqual(llamadas, [['/inicio/x', undefined]])
  })
  it('accion() hace POST por ctx.rest e invalida las consultas del panel aunque falle', async () => {
    const { fijarRest, accion } = await cargar('api')
    const llamadas = []
    fijarRest(async (ruta, opciones) => {
      llamadas.push([ruta, opciones])
      if (ruta === '/falla') throw new Error('x')
      return { ok: true }
    })
    assert.deepEqual(await accion('/acciones/x', { a: 1 }), { ok: true })
    assert.deepEqual(llamadas[0], ['/acciones/x', { method: 'POST', body: { a: 1 } }])
    await assert.rejects(accion('/falla'))
    assert.equal(sdk().invalidadas.length, 2)
    assert.deepEqual(sdk().invalidadas[0], { queryKey: ['fabrica'] })
  })
})

describe('AC-1c sin colores fijos', () => {
  it('desktop/src no contiene #hex, rgb(, hsl( ni nombres de color fuera de var(...)', () => {
    const fuentes = ficheros(SRC)
    assert.ok(fuentes.length >= 15, 'debería haber fuentes que revisar')
    const malos = fuentes.flatMap(f => coloresFijos(readFileSync(f, 'utf8')).map(r => `${f}: ${r}`))
    assert.deepEqual(malos, [])
  })
  it('el detector muerde: mutantes con color fijo se detectan, var()/currentColor no', () => {
    for (const mal of ["a = '#fff'", "s = 'rgb(1,2,3)'", "s = 'hsl(1 2% 3%)'", "s = 'color: red'", "c = 'text-red-500'", "x = '#1a2b3c'", "s = 'var(--a) red'"]) {
      assert.notDeepEqual(coloresFijos(mal), [], mal)
    }
    for (const bien of ["s = 'var(--accent)'", "s = 'var(--a, var(--b))'", "s = 'currentColor'", "s = 'none'", "// red #fff rgb(1)", "/* blue */ x = 1", "s = 'transparent'", "u = 'https://x.test/a'"]) {
      assert.deepEqual(coloresFijos(bien), [], bien)
    }
  })
})
