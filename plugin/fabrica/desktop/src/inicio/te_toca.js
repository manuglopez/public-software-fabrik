// «Te toca a ti» (AC-3a): PLAN por aprobar, PRs listos para merge y tarjetas bloqueadas que esperan a una persona.
// Botones: Ver (Kanban nativo), Aprobar (PLAN, con confirmación → POST /acciones/aprobar) y Abrir PR.
// Aviso del SO solo con elementos nuevos; los ya vistos se guardan en ctx.storage (única preferencia, AC-6).
import { Badge, Button, ConfirmDialog, EmptyState } from '@hermes/plugin-sdk'
import { useEffect, useState } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'
import { accion, ctxPlugin, useFx } from '../api.js'
import { abrirTarjeta } from '../ui.js'

const VISTOS = 'te-toca.vistos'
const clave = i => `${i.tipo}:${i.board}:${i.task_id}`

/** Avisa con `ctx.os.notify` de los elementos que no estaban en `te-toca.vistos`. La primera vez solo los apunta. */
function useAvisoNuevos(items) {
  const claves = items ? items.map(clave).join('\n') : null
  useEffect(() => {
    const ctx = ctxPlugin()
    if (!ctx || claves === null) return
    const vistos = ctx.storage.get(VISTOS, null)
    const nuevos = Array.isArray(vistos) ? items.filter(i => !vistos.includes(clave(i))) : []
    if (nuevos.length) {
      ctx.os.notify({
        title: nuevos.length === 1 ? 'The Factory · Te toca a ti' : `The Factory · Te toca a ti (${nuevos.length})`,
        body: nuevos.map(i => i.titulo).join('\n'),
        activate: '/the-factory'
      })
    }
    const actuales = items.map(clave)
    if (!Array.isArray(vistos) || vistos.join('\n') !== claves) ctx.storage.set(VISTOS, actuales)
  }, [claves])
}

function Fila({ item, alAprobar }) {
  const botones = [jsx(Button, { variant: 'outline', size: 'sm', onClick: () => abrirTarjeta(item), children: 'Ver' }, 'ver')]
  if (item.tipo === 'plan') {
    botones.push(jsx(Button, { size: 'sm', onClick: () => alAprobar(item), children: 'Aprobar' }, 'aprobar'))
  }
  if (item.tipo === 'merge' && item.pr_url) {
    botones.push(
      jsx(Button, { size: 'sm', onClick: () => ctxPlugin()?.os.openExternal(item.pr_url), children: 'Abrir PR' }, 'pr')
    )
  }
  return jsxs('div', {
    className: 'flex items-center gap-2 border-t border-(--ui-stroke-secondary) py-1.5 first:border-t-0',
    children: [
      jsx('span', { className: 'size-2 flex-none rounded-full bg-(--accent)' }),
      jsxs('div', {
        className: 'min-w-0 flex-1',
        children: [
          jsxs('div', { className: 'truncate', children: [jsx('b', { children: item.titulo }), ` · ${item.board}`] }),
          jsx('div', { className: 'text-xs text-(--ui-text-tertiary)', children: item.pregunta || item.detalle })
        ]
      }),
      ...botones
    ]
  })
}

export function TeToca() {
  const { data } = useFx('/inicio/te-toca', { cadaMs: 15000 })
  const items = Array.isArray(data?.items) ? data.items : null
  const [aprobando, setAprobando] = useState(null)
  useAvisoNuevos(items)

  let cuerpo = null
  if (data?.disponible === false) cuerpo = jsx(EmptyState, { title: 'No disponible', description: data.motivo || '' })
  else if (items && !items.length) cuerpo = jsx(EmptyState, { title: 'Nada pendiente', description: 'No hay nada esperándote.' })
  else if (items) cuerpo = items.map(i => jsx(Fila, { item: i, alAprobar: setAprobando }, clave(i)))

  return jsxs('section', {
    className: 'rounded-lg border border-(--ui-stroke-secondary) p-3',
    children: [
      jsxs('div', {
        className: 'mb-2 flex items-center justify-between',
        children: [
          jsx('h3', { className: 'text-sm font-medium', children: 'Te toca a ti' }),
          items?.length ? jsx(Badge, { children: String(items.length) }) : null
        ]
      }),
      cuerpo,
      aprobando
        ? jsx(ConfirmDialog, {
            open: true,
            onClose: () => setAprobando(null),
            title: 'Aprobar plan',
            description: `${aprobando.titulo} · ${aprobando.board}`,
            confirmLabel: 'Aprobar',
            children: aprobando.pregunta ? jsx('p', { className: 'text-sm', children: aprobando.pregunta }) : null,
            onConfirm: async () => {
              const r = await accion('/acciones/aprobar', { board: aprobando.board, task_id: aprobando.task_id })
              if (!r?.ok) throw new Error(r?.salida || 'No se pudo aprobar')
            }
          })
        : null
    ]
  })
}
