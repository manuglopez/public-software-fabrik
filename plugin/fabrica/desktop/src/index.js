// Registro del plugin de escritorio «fabrica»: ruta, entrada lateral, ⌘K y chip de estado.
import { PALETTE_AREA, ROUTES_AREA, SIDEBAR_NAV_AREA, STATUSBAR_AREAS, host } from '@hermes/plugin-sdk'
import { jsx } from 'react/jsx-runtime'
import { fijarCtx } from './api.js'
import { Chip } from './chip.js'
import { Pagina } from './pagina.js'

const RUTA = '/the-factory'

export default {
  id: 'fabrica',
  name: 'The Factory',
  register(ctx) {
    fijarCtx(ctx)
    const abrir = () => host.navigate(RUTA)
    ctx.registerMany([
      { id: 'pagina', area: ROUTES_AREA, data: { path: RUTA }, render: () => jsx(Pagina, {}) },
      { id: 'nav', area: SIDEBAR_NAV_AREA, data: { path: RUTA, label: 'The Factory', codicon: 'tools' } },
      {
        id: 'abrir',
        area: PALETTE_AREA,
        data: { id: 'the-factory.open', label: 'The Factory', keywords: ['fábrica', 'fabrica', 'factory', 'kanban', 'agentes'], run: abrir }
      },
      { id: 'chip', area: STATUSBAR_AREAS.right, order: 125, render: () => jsx(Chip, { abrir }) }
    ])
  }
}
