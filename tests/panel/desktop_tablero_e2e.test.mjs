// E2E de «Aprobar» (CIERRE-2, AC-3a completo + AC-2b): el botón de te_toca.js (IMPL-2) contra el backend real
// GET /inicio/te-toca (fx_tablero) y POST /acciones/aprobar (fx_acciones, IMPL-3). `ctx.rest` lanza el backend con
// tests/panel/tablero_e2e_servidor.py sobre un tablero SQLite de fixture; `hermes kanban` simulado, sin red ni HOME real.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach, beforeEach, describe, it } from 'node:test'
import { fileURLToPath } from 'node:url'
import { SDK, construir } from './comun.mjs'

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const UV = ['run', '--with', 'fastapi', '--with', 'httpx', '--with', 'pyyaml', 'python', '-m', 'tests.panel.tablero_e2e_servidor']
const sinUv = spawnSync('uv', ['--version']).status === 0 ? false : 'sin uv no se puede lanzar el backend'

const { act, cargar, montar, sdk } = await construir('tablero_e2e')
const S = await cargar(SDK)
const { fijarCtx } = await cargar('api')
const { TeToca } = await cargar('inicio/te_toca')

const texto = nodo => (typeof nodo === 'string' ? nodo : (nodo.children ?? []).map(texto).join(''))
const boton = (arbol, etiqueta) => arbol.root.findAll(n => n.type === S.Button && texto(n) === etiqueta)
const ORDEN = id => [
  ['hermes', 'kanban', '--board', 'default', 'comment', id, 'adelante (desde The Factory)'],
  ['hermes', 'kanban', '--board', 'default', 'unblock', id],
  ['hermes', 'kanban', '--board', 'default', 'comment', id, '🏭 The Factory: aprobar']
]

let dir, posts
/** Una petición al backend real; devuelve la última línea JSON que imprime. */
function backend(...args) {
  const r = spawnSync('uv', [...UV, dir, ...args], { cwd: RAIZ, encoding: 'utf8', timeout: 120_000 })
  assert.equal(r.status, 0, `el backend falló:\n${r.stderr}`)
  return JSON.parse(r.stdout.trim().split('\n').pop())
}
/** `ctx.rest` real: GET de te-toca ya cargado en el SDK falso; POST de aprobar contra el backend (como hace Hermes). */
function conectar(fallaVerbo) {
  sdk().datos['/inicio/te-toca'] = backend('get')
  sdk().datos['/acciones/aprobar'] = opciones => {
    assert.equal(opciones.method, 'POST')
    const r = backend('post', JSON.stringify(opciones.body), ...(fallaVerbo ? [fallaVerbo] : []))
    posts.push(r)
    if (r.status !== 200) throw new Error(JSON.stringify(r.respuesta.detail))
    return r.respuesta
  }
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'fx-e2e-aprobar-'))
  posts = []
  fijarCtx(S.ctxFalso())
})
afterEach(() => rmSync(dir, { recursive: true, force: true }))

describe('AC-3a E2E Aprobar: te_toca.js → POST /acciones/aprobar real', { skip: sinUv }, () => {
  it('el PLAN que da el backend se aprueba con comment «adelante» + unblock + comentario 🏭, sin tocar SQLite', async () => {
    conectar()
    const arbol = montar(TeToca)
    assert.equal(boton(arbol, 'Aprobar').length, 1, 'solo el PLAN bloqueado needs_input lleva Aprobar')
    act(() => { boton(arbol, 'Aprobar')[0].props.onClick() })
    const dialogo = arbol.root.findByType(S.ConfirmDialog)
    assert.match(texto(dialogo), /¿Apruebas el plan de pagos\?/, 'la pregunta es la primera línea del motivo')
    assert.equal(posts.length, 0, 'nada se ejecuta antes de confirmar')
    await act(() => dialogo.props.onConfirm())
    assert.equal(posts.length, 1)
    assert.equal(posts[0].status, 200)
    assert.equal(posts[0].respuesta.ok, true)
    assert.deepEqual(posts[0].ejecutadas, ORDEN('t_0000aaaa'))
    assert.equal(posts[0].sqlite_igual, true, 'el tablero no se escribe: todo va por hermes kanban')
  })

  it('si unblock falla, el backend se para sin el comentario 🏭 y el diálogo muestra el error', async () => {
    conectar('unblock')
    const arbol = montar(TeToca)
    act(() => { boton(arbol, 'Aprobar')[0].props.onClick() })
    await assert.rejects(() => arbol.root.findByType(S.ConfirmDialog).props.onConfirm(), /unblock.*error simulado/s)
    assert.deepEqual(posts[0].ejecutadas, ORDEN('t_0000aaaa').slice(0, 2))
    assert.equal(posts[0].sqlite_igual, true)
  })

  it('el backend rechaza aprobar algo que no es un PLAN needs_input (409) sin ejecutar nada', async () => {
    conectar()
    await assert.rejects(
      () => S.ctxFalso().rest('/acciones/aprobar', { method: 'POST', body: { board: 'default', task_id: 't_0000eeee' } }),
      /solo se aprueba un PLAN/
    )
    assert.equal(posts[0].status, 409)
    assert.deepEqual(posts[0].ejecutadas, [])
  })
})
