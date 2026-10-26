// Zona «proyectos» del front (D-9 R-2): pestañas Proyectos (AC-4a), Cupos y costes (AC-4c) y Memoria (AC-4d, AC-6).
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { describe, it, mock } from 'node:test'
import { SDK, SRC, coloresFijos, construir, fixture } from './comun.mjs'

const { cargar, html, montar, act, sdk } = await construir('proyectos')

const texto = n => (typeof n === 'string' ? n : n.children.map(texto).join(''))
const botones = (arbol, re) => arbol.root.findAll(n => n.type === 'button' && re.test(texto(n)))
/** Conecta `ctx.rest`/`ctx.os` del SDK falso a api.js y fija las respuestas por ruta. */
const ver = async rutas => {
  const { ctxFalso } = await cargar(SDK)
  ;(await cargar('api')).fijarCtx(ctxFalso())
  Object.assign(sdk().datos, rutas)
}

describe('AC-4a Proyectos', () => {
  it('AC-4a pide /proyectos con refresco y pinta productos, repos, ritmo, tarjetas y PRs', async () => {
    sdk().datos['/proyectos'] = fixture('proyectos_catalogo')
    const { Proyectos } = await cargar('pestanas/proyectos')
    const salida = html(Proyectos)
    assert.equal(sdk().consultas[0].queryKey[1], '/proyectos')
    assert.ok(sdk().consultas[0].refetchInterval > 0)
    assert.ok(salida.indexOf('tienda') < salida.indexOf('Sin producto'))
    for (const re of [/Tienda online multimarca/, /web-tienda/, /api-tienda/, /diario/, /IMPL carrito/, /#12/, /feat: carrito persistente/])
      assert.match(salida, re)
    assert.match(salida, /href="https:\/\/github\.com\/acme\/web-tienda\/pull\/12"/)
    assert.match(salida, /2 tarjetas/)
    assert.match(salida, /gh acme\/blog: HTTP 502/) // los avisos del backend se ven
  })

  const llamadasDe = que => sdk().llamadas.filter(l => l.que === que).map(l => l.args)

  it('AC-4a «Nueva feature aquí» abre un chat nuevo con «/fabrica feature <repo> » en el borrador, sin enviarlo', async () => {
    sdk().datos['/proyectos'] = fixture('proyectos_catalogo')
    const { Proyectos } = await cargar('pestanas/proyectos')
    const arbol = montar(Proyectos)
    const nuevas = botones(arbol, /Nueva feature aquí/)
    assert.equal(nuevas.length, 3) // una por repo
    await act(async () => {
      await nuevas[0].props.onClick()
    })
    assert.deepEqual(llamadasDe('host.newChat'), [[]]) // sin chat nuevo montado, setDraft es fail-closed
    assert.deepEqual(llamadasDe('host.composer.setDraft'), [['new', '/fabrica feature web-tienda ']])
    assert.deepEqual(llamadasDe('host.composer.submit'), [])
    assert.doesNotMatch(texto(arbol.root), /No se pudo abrir el chat/)
  })

  it('AC-4a reintenta setDraft mientras monta el composer y, si no llega, avisa con el texto a escribir', async () => {
    sdk().datos['/proyectos'] = fixture('proyectos_catalogo')
    const { host } = await cargar(SDK)
    const { Proyectos } = await cargar('pestanas/proyectos')
    const original = host.composer.setDraft
    mock.timers.enable({ apis: ['setTimeout'] }) // las esperas entre reintentos, sin tiempo real
    try {
      let n = 0
      host.composer.setDraft = async () => ++n === 2
      const arbol = montar(Proyectos)
      const pulsar = async () => {
        let fin = false
        act(() => {
          botones(arbol, /Nueva feature aquí/)[1].props.onClick().then(() => (fin = true))
        })
        for (let i = 0; i < 50 && !fin; i++) {
          await act(async () => {
            await new Promise(r => setImmediate(r))
            mock.timers.tick(100)
          })
        }
        assert.ok(fin, 'el clic termina')
      }
      await pulsar()
      assert.equal(n, 2)
      assert.doesNotMatch(texto(arbol.root), /No se pudo abrir el chat/)
      host.composer.setDraft = async () => false
      await pulsar()
      assert.equal(llamadasDe('host.newChat').length, 2)
      assert.match(texto(arbol.root), /No se pudo abrir el chat: escribe «\/fabrica feature api-tienda» en un chat nuevo/)
    } finally {
      host.composer.setDraft = original
      mock.timers.reset()
    }
  })

  it('AC-4a clic en una tarjeta = abrirTarjeta({board, task_id})', async () => {
    sdk().datos['/proyectos'] = fixture('proyectos_catalogo')
    const { Proyectos } = await cargar('pestanas/proyectos')
    const arbol = montar(Proyectos)
    act(() => {
      botones(arbol, /IMPL precios/)[0].props.onClick()
    })
    assert.deepEqual(sdk().navegaciones, ['/kanban?board=tienda&task=t_aaaa0002'])
  })

  it('AC-4a el enlace de un PR se abre fuera con ctx.os.openExternal', async () => {
    await ver({ '/proyectos': fixture('proyectos_catalogo') })
    const { Proyectos } = await cargar('pestanas/proyectos')
    const arbol = montar(Proyectos)
    const enlace = arbol.root.findAll(n => n.type === 'a' && /#12/.test(texto(n)))[0]
    let evitado = false
    act(() => {
      enlace.props.onClick({ preventDefault: () => (evitado = true) })
    })
    assert.ok(evitado)
    assert.deepEqual(sdk().llamadas.find(l => l.que === 'ctx.os.openExternal').args, ['https://github.com/acme/web-tienda/pull/12'])
  })

  it('AC-4a con un ctx sin `os` el enlace de un PR no rompe', async () => {
    await ver({ '/proyectos': fixture('proyectos_catalogo') })
    const { Proyectos } = await cargar('pestanas/proyectos')
    const arbol = montar(Proyectos)
    ;(await cargar('api')).fijarCtx({ rest: async () => ({}) })
    const enlace = arbol.root.findAll(n => n.type === 'a' && /#12/.test(texto(n)))[0]
    assert.doesNotThrow(() => act(() => enlace.props.onClick({ preventDefault() {} })))
  })

  it('AC-4a sin datos todavía dice que carga; no disponible enseña el motivo; sin productos lo dice', async () => {
    const { Proyectos } = await cargar('pestanas/proyectos')
    assert.match(html(Proyectos), /Cargando/)
    sdk().datos['/proyectos'] = { disponible: false, motivo: 'sin portfolio.yaml (/x)', productos: [] }
    assert.match(html(Proyectos), /sin portfolio\.yaml/)
    sdk().datos['/proyectos'] = { disponible: true, productos: [], avisos: [] }
    assert.match(html(Proyectos), /Sin proyectos/)
  })
})

describe('AC-4c Cupos y costes', () => {
  it('AC-4c pide /costes y dibuja una sparkline SVG por bolsa con su último valor', async () => {
    sdk().datos['/costes'] = fixture('proyectos_costes')
    const { Costes } = await cargar('pestanas/costes')
    const salida = html(Costes)
    assert.equal(sdk().consultas[0].queryKey[1], '/costes')
    assert.match(salida, /kimi_5h/)
    assert.match(salida, /25[.,]5 ?%/)
    assert.equal((salida.match(/<polyline/g) ?? []).length, 1) // solo_uno tiene un punto: marca, no línea
    assert.match(salida, /<circle/)
    assert.match(salida, /stroke="var\(--/)
  })

  it('AC-4c rate_limited por día en barras proporcionales, con las esperas', async () => {
    sdk().datos['/costes'] = fixture('proyectos_costes')
    const { Costes } = await cargar('pestanas/costes')
    const salida = html(Costes)
    for (const dia of ['2026-10-22', '2026-10-23', '2026-10-24']) assert.match(salida, new RegExp(dia))
    assert.match(salida, /width:100%/) // el día con más (8) llena la barra
    assert.match(salida, /width:25%/) // 2 de 8
  })

  it('AC-4c los proveedores de pago van en $ y las suscripciones en tokens, nunca en $', async () => {
    sdk().datos['/costes'] = fixture('proyectos_costes')
    const { Costes } = await cargar('pestanas/costes')
    const salida = html(Costes)
    assert.match(salida, /deepseek/)
    assert.match(salida, /\$1[.,]75/)
    assert.match(salida, /kimi/)
    assert.match(salida, /3000|3\.000/) // tokens de caché
    assert.equal((salida.match(/\$/g) ?? []).length, 1) // un solo importe en $: el de pago
  })

  it('AC-4c sin pago ni histórico dice por qué, y los avisos del backend se ven', async () => {
    sdk().datos['/costes'] = { disponible: true, bolsas_historico: [], rate_limited: [], pago: [], tokens: [], avisos: ['sin cupos.jsonl (/x)'] }
    const { Costes } = await cargar('pestanas/costes')
    const salida = html(Costes)
    assert.match(salida, /sin cupos\.jsonl/)
    assert.match(salida, /Sin histórico/)
    assert.match(salida, /Sin proveedores de pago/)
  })

  it('AC-4c sin datos todavía dice que carga', async () => {
    const { Costes } = await cargar('pestanas/costes')
    assert.match(html(Costes), /Cargando/)
  })
})

describe('AC-4d Memoria (pestaña) y AC-6', () => {
  const escribir = (arbol, q) => act(() => arbol.root.findByType('input').props.onChange({ target: { value: q } }))
  const buscar = async arbol => {
    await act(async () => {
      await arbol.root.findByType('form').props.onSubmit({ preventDefault() {} })
    })
  }

  it('AC-4d mientras busca dice «Buscando…», desactiva Buscar y no lanza otro recall', async () => {
    let responder
    await ver({ '/memoria/buscar': () => new Promise(r => (responder = r)) })
    const { PestanaMemoria } = await cargar('pestanas/memoria')
    const arbol = montar(PestanaMemoria)
    escribir(arbol, 'worker colgado')
    let pendiente
    act(() => {
      pendiente = arbol.root.findByType('form').props.onSubmit({ preventDefault() {} })
    })
    assert.match(texto(arbol.root), /Buscando…/)
    assert.equal(botones(arbol, /^Buscar$/)[0].props.disabled, true)
    act(() => {
      arbol.root.findByType('form').props.onSubmit({ preventDefault() {} })
    })
    assert.equal(sdk().llamadas.filter(l => l.que === 'ctx.rest').length, 1)
    await act(async () => {
      responder({ disponible: true, texto: 'hecho' })
      await pendiente
    })
    assert.doesNotMatch(texto(arbol.root), /Buscando…/)
    assert.match(texto(arbol.root), /hecho/)
  })

  it('AC-4d si /memoria/lecciones falla lo dice (no se queda en «Cargando…»)', async () => {
    const { cuerpoLecciones } = await cargar('pestanas/memoria')
    const salida = html(() => cuerpoLecciones({ data: undefined, error: new Error('HTTP 500') }))
    assert.match(salida, /Lecciones no disponible/)
    assert.match(salida, /HTTP 500/)
    assert.doesNotMatch(salida, /Cargando/)
  })

  it('AC-4d lecciones con el mismo archivo en dos sitios no chocan (key repo/archivo)', async () => {
    const [a] = fixture('proyectos_lecciones').lecciones
    sdk().datos['/memoria/lecciones'] = { lecciones: [a, { ...a, repo: 'otro', sintoma: 'Otra lección' }] }
    const { PestanaMemoria } = await cargar('pestanas/memoria')
    const errores = mock.method(console, 'error', () => {})
    try {
      assert.match(texto(montar(PestanaMemoria).root), /Otra lección/)
      const avisos = errores.mock.calls.map(c => c.arguments.join(' ')).filter(t => /same key/.test(t))
      assert.deepEqual(avisos, [])
    } finally {
      errores.mock.restore()
    }
  })

  it('AC-4d muestra las últimas lecciones', async () => {
    sdk().datos['/memoria/lecciones'] = fixture('proyectos_lecciones')
    const { PestanaMemoria } = await cargar('pestanas/memoria')
    const salida = html(PestanaMemoria)
    assert.equal(sdk().consultas[0].queryKey[1], '/memoria/lecciones')
    for (const re of [/El build falla en CI/, /Falta la variable X/, /Declararla en el workflow/, /ci\.yml/, /2026-10-20/, /Imágenes rotas/])
      assert.match(salida, re)
  })

  it('AC-4d buscar hace POST /memoria/buscar {q} y enseña el texto devuelto', async () => {
    await ver({ '/memoria/buscar': () => ({ disponible: true, texto: 'Recuerdo: reiniciar el worker' }) })
    const { PestanaMemoria } = await cargar('pestanas/memoria')
    const arbol = montar(PestanaMemoria)
    escribir(arbol, 'worker colgado')
    await buscar(arbol)
    const llamada = sdk().llamadas.find(l => l.que === 'ctx.rest')
    assert.deepEqual(llamada.args, ['/memoria/buscar', { method: 'POST', body: { q: 'worker colgado' } }])
    assert.match(texto(arbol.root), /Recuerdo: reiniciar el worker/)
    assert.equal(sdk().invalidadas.length, 0, 'buscar no refresca el resto del panel')
  })

  it('AC-4d con el contrato real de IMPL-4: texto vacío = «Sin resultados»', async () => {
    await ver({ '/memoria/buscar': { disponible: true, texto: '' } })
    const { PestanaMemoria } = await cargar('pestanas/memoria')
    const arbol = montar(PestanaMemoria)
    escribir(arbol, 'nada')
    await buscar(arbol)
    assert.match(texto(arbol.root), /Sin resultados\./)
  })

  it('AC-4d el buscador no deja pasar del máximo del backend (500)', async () => {
    await ver({})
    const { PestanaMemoria } = await cargar('pestanas/memoria')
    assert.equal(montar(PestanaMemoria).root.findByType('input').props.maxLength, 500)
  })

  it('AC-4d con la búsqueda vacía no llama al backend', async () => {
    await ver({})
    const { PestanaMemoria } = await cargar('pestanas/memoria')
    const arbol = montar(PestanaMemoria)
    escribir(arbol, '   ')
    await buscar(arbol)
    assert.equal(sdk().llamadas.filter(l => l.que === 'ctx.rest').length, 0)
  })

  it('AC-6 memoria caída: «no disponible», sin romper y sin bloquear las lecciones', async () => {
    // Respuesta real de fx_memoria.buscar con la memoria caída (comprobación previa < 2 s).
    await ver({ '/memoria/buscar': { disponible: false, motivo: 'timeout tras 1.5s', texto: '' }, '/memoria/lecciones': fixture('proyectos_lecciones') })
    const { PestanaMemoria } = await cargar('pestanas/memoria')
    const arbol = montar(PestanaMemoria)
    escribir(arbol, 'algo')
    await buscar(arbol)
    const t = texto(arbol.root)
    assert.match(t, /Memoria no disponible: timeout tras 1\.5s/)
    assert.match(t, /El build falla en CI/)
  })

  it('AC-6 ruta aún sin desplegar (404) o backend caído: «no disponible»', async () => {
    await ver({ '/memoria/buscar': new Error('404 Not Found') })
    const { PestanaMemoria } = await cargar('pestanas/memoria')
    const arbol = montar(PestanaMemoria)
    escribir(arbol, 'algo')
    await buscar(arbol)
    assert.match(texto(arbol.root), /Memoria no disponible: 404 Not Found/)
  })

  it('AC-4d sin lecciones lo dice', async () => {
    sdk().datos['/memoria/lecciones'] = { lecciones: [] }
    const { PestanaMemoria } = await cargar('pestanas/memoria')
    assert.match(html(PestanaMemoria), /Sin lecciones/)
  })
})

describe('AC-1c sin colores fijos en mis pestañas', () => {
  for (const f of ['proyectos', 'costes', 'memoria'])
    it(`pestanas/${f}.js`, () => assert.deepEqual(coloresFijos(readFileSync(`${SRC}/pestanas/${f}.js`, 'utf8')), []))
})
