// Ejemplo mínimo de fichero de zona (D-9 R-2): copia este patrón en `desktop_<zona>.test.mjs`. Corre en paralelo con
// los demás porque construye en su propia carpeta (desktop/.prueba/prueba/).
import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { construir, fixture, h } from './comun.mjs'

const { cargar, html, montar, sdk } = await construir('prueba')

describe('zona de ejemplo', () => {
  it('pinta el chip con los datos de un fixture', async () => {
    sdk().datos['/inicio/te-toca'] = fixture('te_toca')
    const { Chip } = await cargar('chip')
    assert.match(html(Chip, { abrir() {} }), /The Factory · 2/)
  })
  it('un botón que usa abrirTarjeta deja la navegación en el SDK falso', async () => {
    const { abrirTarjeta } = await cargar('ui')
    const Boton = () => h('button', { onClick: () => abrirTarjeta({ board: 'ejemplo', task_id: 't_0000aaaa' }) })
    montar(Boton).root.findByType('button').props.onClick()
    assert.deepEqual(sdk().navegaciones, ['/kanban?board=ejemplo&task=t_0000aaaa'])
  })
})
