// Piezas comunes. `Pendiente` es lo que pintan los stubs hasta que su tarjeta los rellena.
// Botones compartidos (D-9 R-3): abrir una tarjeta en el Kanban nativo y abrirla en la consola de Inicio.
import { EmptyState, host } from '@hermes/plugin-sdk'
import { useEffect, useRef } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'

export const EVENTO_CONSOLA = 'fabrica:consola'

/**
 * Lleva la tarjeta al Kanban nativo (D-7). El Kanban de Hermes vive en `#/kanban` y hoy no lee tablero ni tarjeta de la
 * ruta (el tablero activo lo guarda en su propio storage): van en la query para cuando lo haga; hoy abre el Kanban.
 */
export function abrirTarjeta({ board, task_id } = {}) {
  const q = new URLSearchParams()
  if (board) q.set('board', board)
  if (task_id) q.set('task', task_id)
  const query = q.toString().replace(/\+/g, '%20')
  host.navigate(query ? `/kanban?${query}` : '/kanban')
}

/** Pide a la consola de Inicio que se abra con esta tarjeta: `CustomEvent('fabrica:consola', {detail: {board, task_id}})`. */
export function abrirConsola({ board, task_id } = {}) {
  window.dispatchEvent(new CustomEvent(EVENTO_CONSOLA, { detail: { board, task_id } }))
}

/** Escucha `abrirConsola` mientras el componente está montado: `cb({board, task_id})`. Se da de baja al desmontar. */
export function useAbrirConsola(cb) {
  const actual = useRef(cb)
  actual.current = cb
  useEffect(() => {
    const oir = e => actual.current?.(e.detail)
    window.addEventListener(EVENTO_CONSOLA, oir)
    return () => window.removeEventListener(EVENTO_CONSOLA, oir)
  }, [])
}

/** Tarjeta con título (el marco de cada sección de Inicio). */
export function Tarjeta({ titulo, children }) {
  return jsxs('section', {
    className: 'rounded-lg border border-(--ui-stroke-secondary) p-3',
    children: [jsx('h3', { className: 'mb-2 text-sm font-medium', children: titulo }), children]
  })
}

export function Pendiente({ titulo }) {
  return jsx(Tarjeta, {
    titulo,
    children: jsx(EmptyState, { title: 'Pendiente', description: 'Esta sección llega en una tarjeta posterior.' })
  })
}
