// Pestaña «Cupos y costes» (AC-4c): histórico de bolsas (7 días), rate_limited por día y $ de los proveedores de pago.
// Las suscripciones se ven en % y tokens, nunca en dinero. Gráficos SVG con variables del tema.
import { EmptyState } from '@hermes/plugin-sdk'
import { jsx, jsxs } from 'react/jsx-runtime'
import { useFx } from '../api.js'
import { Tarjeta } from '../ui.js'

const ANCHO = 160
const ALTO = 32
const pct = n => `${Number(n.toFixed(1))} %`
const num = n => n.toLocaleString('es-ES')
const sesiones = n => `${n} ${n === 1 ? 'sesión' : 'sesiones'}`
const nota = texto => jsx('p', { className: 'text-(--ui-text-tertiary)', children: texto })

/** Línea de 0 a 100 % entre la primera y la última foto; con un solo punto, una marca. */
export function Sparkline({ puntos }) {
  const t0 = puntos[0][0]
  const dt = puntos[puntos.length - 1][0] - t0 || 1
  const x = t => ((t - t0) / dt) * ANCHO
  const y = v => ALTO - (Math.min(Math.max(v, 0), 100) / 100) * ALTO
  return jsxs('svg', {
    width: ANCHO,
    height: ALTO,
    viewBox: `0 0 ${ANCHO} ${ALTO}`,
    role: 'img',
    'aria-label': 'histórico de la bolsa',
    children: [
      jsx('line', { x1: 0, x2: ANCHO, y1: ALTO, y2: ALTO, stroke: 'var(--ui-stroke-secondary)', strokeWidth: 1 }),
      puntos.length === 1
        ? jsx('circle', { cx: ANCHO - 2, cy: y(puntos[0][1]), r: 2, fill: 'var(--ui-accent)' })
        : jsx('polyline', {
            fill: 'none',
            stroke: 'var(--ui-accent)',
            strokeWidth: 1.5,
            points: puntos.map(([t, v]) => `${x(t).toFixed(1)},${y(v).toFixed(1)}`).join(' ')
          })
    ]
  })
}

function Bolsas({ bolsas }) {
  if (bolsas.length === 0) return jsx(EmptyState, { title: 'Sin histórico', description: 'No hay fotos de cupos en los últimos 7 días.' })
  return jsx('div', {
    className: 'grid grid-cols-1 gap-2 sm:grid-cols-2',
    children: bolsas.map(b =>
      jsxs(
        'div',
        {
          className: 'flex items-center justify-between gap-2',
          children: [
            jsx('span', { className: 'truncate', children: b.bolsa }),
            jsx(Sparkline, { puntos: b.puntos }),
            jsx('span', { className: 'w-14 text-right tabular-nums', children: pct(b.puntos[b.puntos.length - 1][1]) })
          ]
        },
        b.bolsa
      )
    )
  })
}

function RateLimited({ dias }) {
  const max = Math.max(0, ...dias.map(d => d.n))
  return jsx('div', {
    className: 'flex flex-col gap-1',
    children: dias.map(d =>
      jsxs(
        'div',
        {
          className: 'flex items-center gap-2',
          children: [
            jsx('span', { className: 'w-24 tabular-nums', children: d.dia }),
            jsx('div', {
              className: 'h-2 flex-1 rounded bg-(--ui-fill-secondary)',
              children: jsx('div', {
                className: 'h-2 rounded',
                style: { width: `${max ? Math.round((d.n / max) * 100) : 0}%`, background: 'var(--ui-accent)' }
              })
            }),
            jsx('span', {
              className: 'w-40 text-right text-xs tabular-nums text-(--ui-text-tertiary)',
              children: `${d.n} rate_limited · ${d.esperas} esperas`
            })
          ]
        },
        d.dia
      )
    )
  })
}

function Fila({ izq, der }) {
  return jsxs('div', {
    className: 'flex justify-between gap-2',
    children: [jsx('span', { children: izq }), jsx('span', { className: 'tabular-nums', children: der })]
  })
}

export function Costes() {
  const { data, error } = useFx('/costes', { cadaMs: 30000 })
  if (error) return jsx(EmptyState, { title: 'Cupos y costes no disponible', description: 'El backend de The Factory no responde.' })
  if (!data) return nota('Cargando cupos y costes…')
  const pago = data.pago ?? []
  const tokens = data.tokens ?? []
  const dias = data.rate_limited ?? []
  return jsxs('div', {
    className: 'flex flex-col gap-3',
    children: [
      jsx(Tarjeta, { titulo: 'Bolsas · últimos 7 días', children: jsx(Bolsas, { bolsas: data.bolsas_historico ?? [] }) }),
      jsx(Tarjeta, {
        titulo: 'rate_limited por día',
        children: dias.length ? jsx(RateLimited, { dias }) : nota('Sin datos de rate_limited.')
      }),
      jsxs(Tarjeta, {
        titulo: 'Proveedores de pago · 7 días',
        children: [
          pago.length === 0
            ? nota('Sin proveedores de pago en el pool.')
            : pago.map(p =>
                jsx(
                  Fila,
                  {
                    izq: p.permitido ? p.proveedor : `${p.proveedor} (no permitido)`,
                    der: `$${p.usd.toFixed(2)} · ${sesiones(p.sesiones)}`
                  },
                  p.proveedor
                )
              ),
          jsx('p', {
            className: 'mt-2 text-xs text-(--ui-text-tertiary)',
            children: 'Las suscripciones se miden en % de bolsa y tokens, no en dinero.'
          })
        ]
      }),
      tokens.length
        ? jsx(Tarjeta, {
            titulo: 'Tokens de las suscripciones (acumulado)',
            children: tokens.map(t =>
              jsx(Fila, { izq: t.familia, der: `entrada ${num(t.entrada)} · salida ${num(t.salida)} · caché ${num(t.cache)}` }, t.familia)
            )
          })
        : null,
      ...(data.avisos ?? []).map(a => jsx('p', { className: 'text-xs text-(--ui-text-tertiary)', children: a }, a))
    ]
  })
}
