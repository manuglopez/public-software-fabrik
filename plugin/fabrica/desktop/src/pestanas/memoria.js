// Pestaña «Memoria» (AC-4d, AC-6): buscador sobre `POST /memoria/buscar` y últimas lecciones.
// La búsqueda es la de Inicio (`useBuscarMemoria`, nunca lanza ni refresca el panel): si la memoria está caída o la
// ruta falla, dice «no disponible» con el motivo y las lecciones siguen.
import { EmptyState } from '@hermes/plugin-sdk'
import { jsx, jsxs } from 'react/jsx-runtime'
import { useFx } from '../api.js'
import { estadoCarga } from '../inicio/cupos.js'
import { useBuscarMemoria } from '../inicio/memoria.js'
import { Tarjeta } from '../ui.js'

const BOTON = 'rounded border border-(--ui-stroke-secondary) px-2 py-0.5 text-xs hover:bg-(--ui-fill-secondary)'

function Buscador() {
  const { q, setQ, buscando, r, lanzar: buscar } = useBuscarMemoria()
  const resultado = r === null ? null : r.disponible === false ? `Memoria no disponible: ${r.motivo ?? ''}` : r.texto || 'Sin resultados.'
  return jsxs(Tarjeta, {
    titulo: 'Buscar en la memoria',
    children: [
      jsxs('form', {
        className: 'flex gap-2',
        onSubmit: buscar,
        children: [
          jsx('input', {
            type: 'search',
            value: q,
            maxLength: 500, // como MAX_Q de fx_memoria (más largo → 400)
            placeholder: 'síntoma, error, tema…',
            'aria-label': 'Buscar en la memoria',
            className: 'flex-1 rounded border border-(--ui-stroke-secondary) bg-transparent px-2 py-1',
            onChange: e => setQ(e.target.value)
          }),
          jsx('button', { type: 'submit', className: `${BOTON} disabled:opacity-50`, disabled: buscando || !q.trim(), children: 'Buscar' })
        ]
      }, 'form'),
      buscando
        ? jsx('p', { className: 'mt-2 text-xs text-(--ui-text-tertiary)', children: 'Buscando… (puede tardar medio minuto)' }, 'buscando')
        : resultado !== null
          ? jsx('pre', { className: 'mt-2 whitespace-pre-wrap text-xs', children: resultado }, 'resultado')
          : null
    ]
  })
}

function Leccion({ l }) {
  return jsxs('div', {
    className: 'flex flex-col gap-0.5 border-t border-(--ui-stroke-secondary) py-2 first:border-t-0',
    children: [
      jsxs('div', {
        className: 'flex gap-2 text-xs text-(--ui-text-tertiary)',
        children: [jsx('span', { children: l.fecha }), jsx('span', { children: l.repo })]
      }),
      jsx('span', { className: 'font-medium', children: l.sintoma }),
      l.causa ? jsx('span', { className: 'text-xs', children: `Causa: ${l.causa}` }) : null,
      l.solucion ? jsx('span', { className: 'text-xs', children: `Solución: ${l.solucion}` }) : null,
      l.donde ? jsx('span', { className: 'text-xs text-(--ui-text-tertiary)', children: `Dónde: ${l.donde}` }) : null
    ]
  })
}

/** Cuerpo de «Últimas lecciones» según la consulta: error con su motivo, cargando, vacío o la lista. */
export function cuerpoLecciones(q) {
  const lecciones = q.data?.lecciones
  if (q.error && !lecciones) return estadoCarga(q, 'Lecciones')
  if (!lecciones) return jsx('p', { className: 'text-(--ui-text-tertiary)', children: 'Cargando lecciones…' })
  if (lecciones.length === 0) return jsx(EmptyState, { title: 'Sin lecciones', description: 'Aún no hay lecciones guardadas.' })
  // El mismo nombre de archivo puede venir de dos repos o del pack: la key lleva repo, archivo y posición.
  return lecciones.map((l, i) => jsx(Leccion, { l }, `${l.repo}/${l.archivo}/${i}`))
}

function Lecciones() {
  return jsx(Tarjeta, { titulo: 'Últimas lecciones', children: cuerpoLecciones(useFx('/memoria/lecciones', { cadaMs: 60000 })) })
}

export function PestanaMemoria() {
  return jsxs('div', { className: 'flex flex-col gap-3', children: [jsx(Buscador, {}), jsx(Lecciones, {})] })
}
