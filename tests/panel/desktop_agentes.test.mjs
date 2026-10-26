// AC-4b / AC-2b (plan The Factory D-5): pestaña Agentes — muestra y edita el reparto dinámico de fabrik-modelos.
// GET /agentes con el fixture `agentes_estado` (salida de `fabrik-modelos estado --json`) + reglas y avisos.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { beforeEach, describe, it } from 'node:test'
import { SDK, SRC, coloresFijos, construir, fixture } from './comun.mjs'

const { act, cargar, html, montar, sdk } = await construir('agentes')
const { Agentes } = await cargar('pestanas/agentes')
const { fijarCtx } = await cargar('api')
const { ctxFalso } = await cargar(SDK)

const AVISO = 'docs: «gemini-med» (gemini-3.8-flash-medium) tiene que acabar en «-high»'
const datosAgentes = () => ({ ...fixture('agentes_estado'), reglas: { revisor_otra_familia: true }, avisos: [AVISO] })

beforeEach(() => {
  fijarCtx(ctxFalso())
  sdk().datos['/agentes'] = datosAgentes()
  sdk().datos['/agentes/informe?dias=14'] = fixture('agentes_informe')
})

const texto = arbol => JSON.stringify(arbol.toJSON())
const textoDe = n => (typeof n === 'string' ? n : n.children.map(textoDe).join(' '))
const por = (arbol, etiqueta) => arbol.root.find(n => n.props['aria-label'] === etiqueta)
const pulsar = async (arbol, etiqueta) => act(async () => por(arbol, etiqueta).props.onClick())
const cambiar = async (arbol, etiqueta, value) => act(async () => por(arbol, etiqueta).props.onChange({ target: { value } }))
const candidatos = (arbol, rol) =>
  arbol.root.findAll(n => n.props['data-rol'] === rol && n.props['data-ruta'] && n.type === 'li').map(n => n.props['data-ruta'])
const posts = ruta => sdk().llamadas.filter(l => l.que === 'ctx.rest' && l.args[0] === ruta).map(l => l.args[1])
const validaciones = () => sdk().consultas.filter(c => c.queryKey?.[1] === '/agentes/validar').map(c => c.queryKey[2])

describe('AC-4b Agentes: muestra el reparto', () => {
  it('candidatos por rol en orden, con disponibilidad por ruta y cuenta, modelo actual y brazos de 7 días', () => {
    const arbol = montar(Agentes)
    assert.deepEqual(candidatos(arbol, 'programador'), ['opus', 'kimi', 'agy-opus', 'sonnet'])
    assert.deepEqual(candidatos(arbol, 'docs'), ['gemini-med', 'gemini-high'])
    const t = html(Agentes)
    assert.match(t, /ahora: claude-opus-5-5/) // perfil programador
    assert.match(t, /ahora: kimi-for-coding/) // perfil tester
    const li = (rol, ruta) => arbol.root.find(n => n.type === 'li' && n.props['data-rol'] === rol && n.props['data-ruta'] === ruta)
    assert.match(textoDe(li('programador', 'kimi')), /2 en 7 d/)
    assert.match(textoDe(li('programador', 'opus')), /1 en 7 d/)
    assert.match(textoDe(li('programador', 'opus')), /✅ a: claude_5h@a 40%.*✅ b: claude_5h@b 20%/)
    assert.match(textoDe(li('programador', 'agy-opus')), /⛔ agy_claude_5h 95% ≥ tope 92%/)
    assert.doesNotMatch(textoDe(li('programador', 'sonnet')), /en 7 d/)
  })

  it('cuentas de Claude con % semanal, topes por bolsa, último recurso, avisos e informe', () => {
    const t = html(Agentes)
    assert.match(t, /Cuentas de Claude/)
    assert.match(t, /93%/)
    assert.match(t, /Topes por bolsa/)
    assert.match(t, /Último recurso/)
    assert.ok(t.includes(AVISO))
    assert.match(t, /Informe de calidad/)
    assert.match(t, /programador.*kimi/s)
  })

  it('backend no disponible: lo dice y no pinta el editor', () => {
    sdk().datos['/agentes'] = { disponible: false, motivo: 'fabrik-modelos estado falló: sin foto' }
    const t = html(Agentes)
    assert.match(t, /sin foto/)
    assert.doesNotMatch(t, /Guardar/)
  })

  it('sin colores fijos', () => {
    assert.deepEqual(coloresFijos(readFileSync(join(SRC, 'pestanas', 'agentes.js'), 'utf8')), [])
  })
})

describe('AC-4b Agentes: edita el reparto', () => {
  it('subir, bajar, quitar y añadir candidatos entre las rutas existentes', async () => {
    const arbol = montar(Agentes)
    await pulsar(arbol, 'bajar opus (programador)')
    assert.deepEqual(candidatos(arbol, 'programador'), ['kimi', 'opus', 'agy-opus', 'sonnet'])
    await pulsar(arbol, 'subir sonnet (programador)')
    assert.deepEqual(candidatos(arbol, 'programador'), ['kimi', 'opus', 'sonnet', 'agy-opus'])
    await pulsar(arbol, 'quitar agy-opus (programador)')
    assert.deepEqual(candidatos(arbol, 'programador'), ['kimi', 'opus', 'sonnet'])
    const opciones = por(arbol, 'añadir a programador').findAllByType('option').map(o => o.props.value)
    assert.deepEqual(opciones.filter(Boolean), ['fable', 'agy-opus', 'agy-sonnet', 'gemini-high', 'gemini-med'])
    await cambiar(arbol, 'añadir a programador', 'fable')
    assert.deepEqual(candidatos(arbol, 'programador'), ['kimi', 'opus', 'sonnet', 'fable'])
    // valida en el backend solo lo cambiado
    assert.deepEqual(JSON.parse(validaciones().at(-1)), { roles: { programador: ['kimi', 'opus', 'sonnet', 'fable'] } })
  })

  it('topes por bolsa, tope semanal por cuenta y último recurso editables', async () => {
    const arbol = montar(Agentes)
    await cambiar(arbol, 'tope 5h', '80')
    await cambiar(arbol, 'tope semanal de la cuenta a', '90')
    await cambiar(arbol, 'último recurso', 'gemini-med')
    assert.deepEqual(JSON.parse(validaciones().at(-1)), {
      ultimo_recurso: 'gemini-med',
      topes: { '5h': 80 },
      topes_cuenta: { a: 90 }
    })
  })

  it('los errores de validación bloquean Guardar', async () => {
    sdk().datos['/agentes/validar'] = { errores: ['tester: «gemini-high» no puede ser candidato de un rol de código'] }
    const arbol = montar(Agentes)
    assert.equal(por(arbol, 'guardar reparto').props.disabled, true) // sin cambios tampoco se guarda
    await cambiar(arbol, 'añadir a tester', 'gemini-high')
    assert.equal(por(arbol, 'guardar reparto').props.disabled, true)
    assert.match(texto(arbol), /no puede ser candidato de un rol de código/)
  })

  it('Guardar envía solo lo cambiado y muestra la salida; Descartar vuelve al vigente', async () => {
    sdk().datos['/agentes/validar'] = { errores: [] }
    sdk().datos['/agentes/guardar'] = { ok: true, errores: [], salida: 'Guardado en /tmp/fabrik.yaml.' }
    const arbol = montar(Agentes)
    await pulsar(arbol, 'bajar opus (programador)')
    assert.equal(por(arbol, 'guardar reparto').props.disabled, false)
    await pulsar(arbol, 'guardar reparto')
    assert.deepEqual(posts('/agentes/guardar'), [
      { method: 'POST', body: { reparto: { roles: { programador: ['kimi', 'opus', 'agy-opus', 'sonnet'] } } } }
    ])
    assert.match(texto(arbol), /Guardado en \/tmp\/fabrik.yaml/)
    assert.deepEqual(candidatos(arbol, 'programador'), ['opus', 'kimi', 'agy-opus', 'sonnet']) // vuelve a leer el vigente
    await pulsar(arbol, 'bajar opus (programador)')
    await pulsar(arbol, 'descartar cambios')
    assert.deepEqual(candidatos(arbol, 'programador'), ['opus', 'kimi', 'agy-opus', 'sonnet'])
  })

  it('Guardar con errores del backend los enseña y no pierde el borrador', async () => {
    sdk().datos['/agentes/validar'] = { errores: [] }
    sdk().datos['/agentes/guardar'] = { ok: false, errores: ['no se pudo guardar: permiso denegado'], salida: '' }
    const arbol = montar(Agentes)
    await pulsar(arbol, 'bajar opus (programador)')
    await pulsar(arbol, 'guardar reparto')
    assert.match(texto(arbol), /permiso denegado/)
    assert.deepEqual(candidatos(arbol, 'programador'), ['kimi', 'opus', 'agy-opus', 'sonnet'])
  })
})

describe('AC-2b Agentes: Aplicar ahora e informe', () => {
  it('«Aplicar ahora» lanza POST /agentes/aplicar y enseña la salida', async () => {
    sdk().datos['/agentes/aplicar'] = { ok: true, salida: 'programador  → opus@b' }
    const arbol = montar(Agentes)
    await pulsar(arbol, 'aplicar ahora')
    assert.deepEqual(posts('/agentes/aplicar'), [{ method: 'POST', body: {} }])
    assert.match(texto(arbol), /programador {2}→ opus@b/)
  })

  it('el informe cambia entre 7, 14 y 30 días', async () => {
    const arbol = montar(Agentes)
    await pulsar(arbol, 'informe de 30 días')
    assert.ok(sdk().consultas.some(c => c.queryKey?.[1] === '/agentes/informe?dias=30'))
    await pulsar(arbol, 'informe de 7 días')
    assert.ok(sdk().consultas.some(c => c.queryKey?.[1] === '/agentes/informe?dias=7'))
  })
})
