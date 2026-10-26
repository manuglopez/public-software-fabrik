// «Cupos» (AC-3e): última foto de las bolsas (GET /cupos) con barra, % y cuándo renueva; avisos > 75 % arriba.
import { EmptyState } from '@hermes/plugin-sdk'
import { jsx, jsxs } from 'react/jsx-runtime'
import { useFx } from '../api.js'
import { Tarjeta } from '../ui.js'

const PROVEEDOR = { claude: 'Claude', kimi: 'Kimi', gemini: 'Gemini', argon: 'Argon', agy_claude: 'Antigravity-Claude', fable: 'Fable', openai: 'OpenAI' }
const VENTANA = { sem: 'semana', '5h': '5 h', '7d': '7 días', '30d': '30 días' }
const DIAS = ['dom', 'lun', 'mar', 'mié', 'jue', 'vie', 'sáb']
const DIA_MS = 86400000
const dos = n => String(n).padStart(2, '0')

/** `claude_sem@info` → «Claude semana · info»; lo que no conoce lo deja tal cual. */
export function nombreBolsa(bolsa) {
  const [base, cuenta] = String(bolsa).split('@')
  const m = /^(.*)_([^_]+)$/.exec(base)
  const nombre = m && PROVEEDOR[m[1]] ? `${PROVEEDOR[m[1]]} ${VENTANA[m[2]] ?? m[2]}` : base
  return cuenta ? `${nombre} · ${cuenta}` : nombre
}

/** Hora local `HH:MM` de una fecha ISO ('' si no es fecha). */
export const hora = iso => {
  const d = new Date(iso)
  return !iso || Number.isNaN(d.getTime()) ? '' : `${dos(d.getHours())}:${dos(d.getMinutes())}`
}

/** Cuándo renueva, como la maqueta: hoy «05:00», en los próximos 6 días «lun 00:27», si no «31/10». */
export function fmtRenueva(iso, ahoraMs = Date.now()) {
  const d = new Date(iso)
  if (!iso || Number.isNaN(d.getTime())) return ''
  if (d.toDateString() === new Date(ahoraMs).toDateString()) return hora(iso)
  if (d.getTime() > ahoraMs && d.getTime() - ahoraMs < 6 * DIA_MS) return `${DIAS[d.getDay()]} ${hora(iso)}`
  return `${dos(d.getDate())}/${dos(d.getMonth() + 1)}`
}

/** Barra de uso 0–100 % (la usa también Máquina). Llena = atenuada, como en la maqueta. */
export function Barra({ pct }) {
  const ancho = Math.max(0, Math.min(100, Number(pct) || 0))
  return jsx('div', {
    className: 'h-1.5 min-w-0 flex-1 overflow-hidden rounded-full bg-(--ui-stroke-secondary)',
    role: 'progressbar',
    'aria-valuenow': Math.round(ancho),
    'aria-valuemin': 0,
    'aria-valuemax': 100,
    children: jsx('i', { className: 'block h-full bg-(--ui-accent)' + (ancho >= 100 ? ' opacity-45' : ''), style: { width: `${ancho}%` } })
  })
}

/** Fila «etiqueta · barra · texto» (Cupos y Máquina). */
export function FilaBarra({ etiqueta, pct, texto, ancho = 'w-36' }) {
  return jsxs('div', {
    className: 'flex items-center gap-2 py-0.5',
    children: [
      jsx('span', { className: `${ancho} shrink-0 truncate text-(--ui-text-tertiary)`, title: etiqueta, children: etiqueta }),
      jsx(Barra, { pct }),
      jsx('span', { className: 'shrink-0 text-right tabular-nums text-(--ui-text-tertiary)', children: texto })
    ]
  })
}

/** Cuerpo común de error / cargando; null si hay datos. */
export function estadoCarga({ data, error }, titulo) {
  if (error || data?.disponible === false) {
    return jsx(EmptyState, { title: `${titulo} no disponible`, description: data?.motivo ?? String(error?.message ?? error) })
  }
  return data ? null : jsx('p', { className: 'text-(--ui-text-tertiary)', children: 'Cargando…' })
}

export function Cupos() {
  const q = useFx('/cupos', { cadaMs: 30000 })
  const data = q.data
  const ahora = Date.now()
  const cuerpo = estadoCarga(q, 'Cupos') ?? [
    jsx('p', { className: 'mb-1 text-xs text-(--ui-text-tertiary)', children: `foto ${hora(data.foto)}` }, 'foto'),
    ...(data.avisos ?? []).map((a, i) => jsx('p', { role: 'alert', className: 'mb-1 text-xs text-[color:var(--ui-red)]', children: `⚠ ${a}` }, `aviso-${i}`)),
    ...(data.bolsas ?? []).map(b => {
      const renueva = fmtRenueva(b.renueva, ahora)
      return jsx(FilaBarra, { etiqueta: nombreBolsa(b.bolsa), pct: b.usado, texto: `${Math.round(b.usado)} %${renueva ? ` · ${renueva}` : ''}` }, b.bolsa)
    })
  ]
  return jsx(Tarjeta, { titulo: 'Cupos', children: cuerpo })
}
