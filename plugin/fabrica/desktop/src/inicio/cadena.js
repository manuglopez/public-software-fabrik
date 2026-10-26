// «Cadena» (AC-3c): las tarjetas en marcha con sus dependencias, en columnas por nivel (los padres a la izquierda).
// Clic en un nodo → abrirTarjeta; «Abrir consola aquí» solo en los nodos con worktree (AC-5, solo emite el evento).
import { Button, EmptyState } from '@hermes/plugin-sdk'
import { jsx, jsxs } from 'react/jsx-runtime'
import { useFx } from '../api.js'
import { Tarjeta, abrirConsola, abrirTarjeta } from '../ui.js'

const ESTADOS = {
  hecho: { marca: '✓', texto: 'hecho', clase: 'text-(--ui-text-tertiary)' },
  en_marcha: { marca: '●', texto: 'en marcha', clase: 'text-(--ui-text-primary)' },
  pendiente: { marca: '○', texto: 'pendiente', clase: 'text-(--ui-text-secondary)' }
}

/** Nivel de cada nodo = camino más largo desde una raíz. Tolera ciclos (no deberían existir) sin colgarse. */
export function niveles(nodos, aristas) {
  const padres = new Map(nodos.map(n => [n.task_id, []]))
  for (const [p, h] of aristas) if (padres.has(p) && padres.has(h)) padres.get(h).push(p)
  const nivel = new Map()
  const calcular = (id, visitando) => {
    if (nivel.has(id)) return nivel.get(id)
    if (visitando.has(id)) return 0
    visitando.add(id)
    const n = Math.max(-1, ...padres.get(id).map(p => calcular(p, visitando))) + 1
    visitando.delete(id)
    nivel.set(id, n)
    return n
  }
  nodos.forEach(n => calcular(n.task_id, new Set()))
  const columnas = []
  for (const n of nodos) (columnas[nivel.get(n.task_id)] ??= []).push(n)
  return columnas.filter(Boolean)
}

function Nodo({ nodo, board }) {
  const e = ESTADOS[nodo.estado] ?? ESTADOS.pendiente
  const id = { board, task_id: nodo.task_id }
  const minutos = nodo.minutos != null ? ` · ${nodo.minutos} min` : ''
  return jsxs('div', {
    className: 'flex flex-col items-start gap-0.5',
    children: [
      jsx(Button, {
        size: 'xs',
        variant: nodo.estado === 'en_marcha' ? 'default' : 'outline',
        title: `${nodo.task_id} · ${e.texto}${minutos}`,
        'aria-label': `${nodo.etiqueta}: ${e.texto}${minutos}`,
        onClick: () => abrirTarjeta(id),
        children: `${e.marca} ${nodo.etiqueta}${minutos}`
      }),
      nodo.worktree
        ? jsx(Button, { size: 'xs', variant: 'ghost', onClick: () => abrirConsola(id), children: 'Abrir consola aquí' })
        : null
    ]
  })
}

function Flujo({ cadena }) {
  const columnas = niveles(cadena.nodos, cadena.aristas ?? [])
  return jsxs('li', {
    className: 'flex flex-col gap-1 border-t border-(--ui-stroke-secondary) py-2 first:border-t-0',
    children: [
      jsxs('div', {
        className: 'flex items-baseline justify-between gap-2',
        children: [
          jsx('span', { className: 'font-medium', children: cadena.titulo }),
          jsx('span', { className: 'text-xs text-(--ui-text-tertiary)', children: `${cadena.hechas}/${cadena.total} hechas · ${cadena.board}` })
        ]
      }),
      jsx('div', {
        className: 'flex flex-wrap items-start gap-2',
        children: columnas.flatMap((nodos, i) => [
          i > 0 ? jsx('span', { 'aria-hidden': true, className: 'pt-0.5 text-xs text-(--ui-text-tertiary)', children: '→' }, `f${i}`) : null,
          jsx('div', { className: 'flex flex-col gap-1', children: nodos.map(n => jsx(Nodo, { nodo: n, board: cadena.board }, n.task_id)) }, `c${i}`)
        ])
      })
    ]
  })
}

export function Cadena() {
  const { data, error } = useFx('/inicio/cadena', { cadaMs: 15000 })
  let cuerpo
  if (error) cuerpo = jsx(EmptyState, { title: 'No se pudo cargar', description: String(error?.message ?? error) })
  else if (!data) cuerpo = jsx('p', { className: 'text-xs text-(--ui-text-tertiary)', children: 'Cargando…' })
  else if (data.disponible === false) cuerpo = jsx(EmptyState, { title: 'No disponible', description: data.motivo })
  else if (!data.cadenas?.length) cuerpo = jsx(EmptyState, { title: 'Sin cadenas en marcha', description: 'Ninguna tarjeta en marcha tiene dependencias.' })
  else cuerpo = jsx('ul', { children: data.cadenas.map(c => jsx(Flujo, { cadena: c }, `${c.board}/${c.nodos[0]?.task_id}`)) })
  return jsx(Tarjeta, { titulo: 'Cadena', children: cuerpo })
}
