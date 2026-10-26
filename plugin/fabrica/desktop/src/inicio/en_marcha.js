// «En marcha» (AC-3d): por tablero, las tarjetas `running` con rol · modelo, minutos y llamadas al modelo/herramientas
// de su sesión; «activos / máximo» y los tableros en pausa nocturna. «Abrir consola aquí» en las que tienen worktree
// (AC-5: solo emite el evento; la consola la monta su sección).
import { Badge, Button, EmptyState } from '@hermes/plugin-sdk'
import { jsx, jsxs } from 'react/jsx-runtime'
import { useFx } from '../api.js'
import { abrirConsola, abrirTarjeta } from '../ui.js'

const minutos = desde => (Number.isFinite(desde) ? `${Math.max(0, Math.floor((Date.now() / 1000 - desde) / 60))} min` : '')
const tenue = 'text-xs text-(--ui-text-tertiary)'

function Fila({ board, item }) {
  const sesion =
    item.llamadas != null && item.herramientas != null
      ? jsx('div', { className: tenue, children: `${item.llamadas} llamadas al modelo · ${item.herramientas} herramientas` })
      : null
  return jsxs('div', {
    className: 'flex items-center gap-2 border-t border-(--ui-stroke-secondary) py-1.5 first:border-t-0',
    children: [
      jsx(Badge, { children: [item.rol, item.modelo].filter(Boolean).join(' · ') }),
      jsxs('div', { className: 'min-w-0 flex-1', children: [jsx('div', { className: 'truncate', children: item.titulo }), sesion] }),
      jsx('span', { className: `${tenue} tabular-nums`, children: minutos(item.desde) }),
      item.worktree
        ? jsx(Button, {
            variant: 'outline',
            size: 'sm',
            onClick: () => abrirConsola({ board, task_id: item.task_id }),
            children: 'Abrir consola aquí'
          })
        : null,
      jsx(Button, { variant: 'ghost', size: 'sm', onClick: () => abrirTarjeta({ board, task_id: item.task_id }), children: 'Ver' })
    ]
  })
}

function Grupo({ grupo }) {
  const { board, pausa, items = [] } = grupo
  return jsxs('div', {
    className: 'mt-1',
    children: [
      jsxs('div', {
        className: 'mt-1 flex items-center gap-2 font-semibold',
        children: [board, pausa ? jsx(Badge, { children: '⏸ pausa nocturna' }) : null]
      }),
      pausa
        ? jsx('div', {
            className: tenue,
            children: `${pausa.aparcadas} tarjetas aparcadas${pausa.hasta ? ` hasta las ${pausa.hasta}` : ''}`
          })
        : null,
      ...items.map(i => jsx(Fila, { board, item: i }, i.task_id))
    ]
  })
}

export function EnMarcha() {
  const { data } = useFx('/inicio/en-marcha', { cadaMs: 15000 })
  const grupos = Array.isArray(data?.grupos) ? data.grupos : null

  let cuerpo = null
  if (data?.disponible === false) cuerpo = jsx(EmptyState, { title: 'No disponible', description: data.motivo || '' })
  else if (grupos && !grupos.length) cuerpo = jsx(EmptyState, { title: 'Nada en marcha', description: 'Ninguna tarjeta corriendo ahora.' })
  else if (grupos) cuerpo = grupos.map(g => jsx(Grupo, { grupo: g }, g.board))

  const cupo = grupos ? (data.maximo != null ? `${data.activos ?? 0} / ${data.maximo}` : String(data.activos ?? 0)) : null
  return jsxs('section', {
    className: 'rounded-lg border border-(--ui-stroke-secondary) p-3',
    children: [
      jsxs('div', {
        className: 'mb-2 flex items-center justify-between',
        children: [jsx('h3', { className: 'text-sm font-medium', children: 'En marcha' }), cupo ? jsx(Badge, { children: cupo }) : null]
      }),
      cuerpo
    ]
  })
}
