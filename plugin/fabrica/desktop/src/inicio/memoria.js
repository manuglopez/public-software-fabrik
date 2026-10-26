// Bloque «Memoria» de Inicio (AC-3g, AC-6): banco, documentos, nodos, última entrada, lo de hoy por fuente, Buscar
// (POST /memoria/buscar, aquí mismo) y Abrir grafo. El SDK no deja abrir el navegador interno en una URL
// (`runAction('view.showBrowser')` no lleva URL): el grafo se abre con `ctx.os.openExternal`.
import { relativeTime } from '@hermes/plugin-sdk'
import { useRef, useState } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'
import { ctxPlugin, useFx } from '../api.js'
import { Tarjeta } from '../ui.js'
import { estadoCarga } from './cupos.js'

const FUENTE = { tarjeta: 'tarjetas', leccion: 'lecciones', pr: 'PRs', docs: 'docs', 'claude-memory': 'notas de Claude Code', otra: 'otras' }
const num = n => (typeof n === 'number' ? n.toLocaleString('es-ES') : '—')
const boton = 'rounded-md border border-(--ui-stroke-secondary) px-2 py-0.5 text-xs hover:bg-(--ui-row-hover-background) disabled:opacity-50'
const botonPri = 'rounded-md bg-(--ui-accent) px-2 py-0.5 text-xs text-(--ui-base) disabled:opacity-50'

/** {tarjeta: 12, leccion: 5} → «12 tarjetas · 5 lecciones» (de más a menos). */
export function textoHoy(hoy = {}) {
  const partes = Object.entries(hoy)
    .sort((a, b) => b[1] - a[1])
    .map(([f, n]) => `${n} ${FUENTE[f] ?? f}`)
  return partes.length ? partes.join(' · ') : 'nada todavía'
}

/** POST /memoria/buscar con el `rest` del plugin; nunca lanza: `{disponible:false, motivo}` si falla. */
export async function buscarMemoria(q) {
  try {
    const r = await ctxPlugin().rest('/memoria/buscar', { method: 'POST', body: { q } })
    return r ?? { disponible: false, motivo: 'sin respuesta' }
  } catch (e) {
    return { disponible: false, motivo: String(e?.message ?? e) }
  }
}

/**
 * Estado de una búsqueda (Inicio y pestaña Memoria): `{q, setQ, buscando, r, lanzar}`. `lanzar` es el onSubmit del form.
 * El recall tarda hasta 60 s: el ref corta un segundo Enter aunque el render aún no vea `buscando`.
 */
export function useBuscarMemoria() {
  const [q, setQ] = useState('')
  const [buscando, setBuscando] = useState(false)
  const [r, setR] = useState(null)
  const enCurso = useRef(false)
  const lanzar = async e => {
    e?.preventDefault?.()
    const consulta = q.trim()
    if (!consulta || enCurso.current) return
    enCurso.current = true
    setR(null)
    setBuscando(true)
    try {
      setR(await buscarMemoria(consulta))
    } finally {
      enCurso.current = false
      setBuscando(false)
    }
  }
  return { q, setQ, buscando, r, lanzar }
}

function Buscador() {
  const { q, setQ, buscando, r, lanzar } = useBuscarMemoria()
  return jsxs('form', {
    className: 'mt-2 flex flex-col gap-1',
    onSubmit: lanzar,
    children: [
      jsxs('div', {
        className: 'flex gap-1',
        children: [
          jsx('input', {
            type: 'search',
            'aria-label': 'Buscar en la memoria',
            placeholder: 'p. ej. flakes con fechas',
            maxLength: 500,
            className: 'min-w-0 flex-1 rounded-md border border-(--ui-stroke-secondary) bg-transparent px-2 py-0.5 text-xs',
            value: q,
            onChange: e => setQ(e.target.value)
          }),
          jsx('button', { type: 'submit', className: botonPri, disabled: !q.trim() || buscando, children: 'Buscar' })
        ]
      }),
      buscando && jsx('p', { className: 'text-xs text-(--ui-text-tertiary)', children: 'Buscando… (puede tardar medio minuto)' }),
      r && r.disponible === false && jsx('p', { className: 'text-xs text-[color:var(--ui-red)]', children: `Memoria no disponible: ${r.motivo ?? ''}` }),
      r && r.disponible !== false &&
        jsx('pre', {
          className: 'max-h-64 overflow-auto whitespace-pre-wrap rounded-md bg-(--ui-bg-tertiary) p-2 text-xs',
          children: r.texto || 'Sin resultados.'
        })
    ]
  })
}

export function Memoria() {
  const q = useFx('/memoria', { cadaMs: 30000 })
  const [abierto, setAbierto] = useState(false)
  const d = q.data
  const cuerpo = estadoCarga(q, 'Memoria') ?? [
    jsxs('div', {
      className: 'flex items-center gap-2 py-0.5',
      children: [
        jsxs('div', {
          className: 'min-w-0 flex-1',
          children: [d.banco, ' · ', jsx('b', { className: 'tabular-nums', children: num(d.documentos) }), ' documentos · ', jsx('b', { className: 'tabular-nums', children: num(d.nodos) }), ' nodos']
        }),
        d.ultima_entrada?.fecha &&
          jsx('span', {
            className: 'shrink-0 text-(--ui-text-tertiary)',
            title: d.ultima_entrada.id,
            children: `última entrada ${relativeTime(new Date(d.ultima_entrada.fecha).getTime())}`
          })
      ]
    }, 'resumen'),
    jsxs('div', {
      className: 'flex items-center gap-2 py-0.5',
      children: [
        jsx('div', { className: 'min-w-0 flex-1 text-(--ui-text-tertiary)', children: `Hoy: ${textoHoy(d.hoy)}` }),
        jsx('button', { type: 'button', className: boton, 'aria-expanded': abierto, onClick: () => setAbierto(!abierto), children: 'Buscar' }),
        jsx('button', {
          type: 'button',
          className: botonPri,
          disabled: !d.grafo_url,
          title: d.grafo_url ? d.grafo_url : 'Configura memoria.grafo_url (Control Plane de Hindsight)',
          onClick: () => ctxPlugin()?.os?.openExternal(d.grafo_url),
          children: 'Abrir grafo'
        })
      ]
    }, 'hoy'),
    abierto && jsx(Buscador, {}, 'buscador')
  ]
  return jsx(Tarjeta, { titulo: 'Memoria', children: cuerpo })
}
