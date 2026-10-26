// Chip de la barra de estado: «The Factory · N». N sale de /inicio/te-toca cuando existe; hasta entonces, sin número.
import { jsx, jsxs } from 'react/jsx-runtime'
import { useFx } from './api.js'
import { Logo } from './logo.js'

export function Chip({ abrir }) {
  const { data } = useFx('/inicio/te-toca', { cadaMs: 15000 })
  const n = Array.isArray(data?.items) ? data.items.length : null
  return jsxs('button', {
    type: 'button',
    className: 'flex items-center gap-1 px-1.5 text-[0.6875rem] text-(--ui-text-tertiary) hover:text-(--ui-text-secondary)',
    title: 'Abrir The Factory',
    onClick: abrir,
    children: [jsx(Logo, { size: 12 }), jsx('span', { children: n === null ? 'The Factory' : `The Factory · ${n}` })]
  })
}
