// «Atascadas» (AC-3b): tarjetas con motivo detectado y una acción. Cada acción pide confirmación antes de escribir
// (`POST /acciones/*`, AC-2b). «Ver» abre la tarjeta en el Kanban nativo; «Abrir consola aquí» solo emite el evento (AC-5).
import { Button, ConfirmDialog, EmptyState } from '@hermes/plugin-sdk'
import { useState } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'
import { accion, ctxPlugin, useFx } from '../api.js'
import { Tarjeta, abrirConsola, abrirTarjeta } from '../ui.js'

const MOTIVOS = {
  error_cupo_revision: 'Error viejo de cupo en revisión',
  sin_cupo: 'Sin cupo',
  esperando_merge: 'Esperando merge'
}

/** Lo que hace el botón principal de una acción del contrato: etiqueta, ruta, cuerpo y texto de confirmación. */
export function describirAccion(item) {
  const a = item.accion
  const id = { board: item.board, task_id: item.task_id }
  if (a?.tipo === 'desatascar') {
    return {
      etiqueta: 'Desatascar',
      ruta: '/acciones/desatascar',
      cuerpo: id,
      titulo: `Desatascar ${item.task_id}`,
      descripcion: 'Se quita y se vuelve a poner el perfil de la tarjeta para borrar el error viejo de cupo y que se revise de nuevo.'
    }
  }
  if (a?.tipo === 'set_model') {
    const modelo = `${a.proveedor}/${a.modelo}`
    return {
      etiqueta: `Pasar a ${a.modelo}`,
      ruta: '/acciones/set-model',
      cuerpo: { ...id, modelo: a.modelo, proveedor: a.proveedor },
      titulo: `Pasar ${item.task_id} a ${modelo}`,
      descripcion: `La tarjeta usará ${modelo} en su próximo arranque.`
    }
  }
  return null
}

function Pr({ pr }) {
  const abrir = () => ctxPlugin()?.os?.openExternal?.(pr.url)
  return jsxs('span', {
    className: 'inline-flex items-center gap-1',
    children: [
      jsx(Button, { size: 'xs', variant: 'outline', onClick: abrir, children: `Abrir PR #${pr.numero}` }),
      pr.apilado_sobre ? jsx('span', { className: 'text-xs text-(--ui-text-tertiary)', children: `apilado sobre ${pr.apilado_sobre}` }) : null
    ]
  })
}

function Fila({ item, pedir }) {
  const accionable = describirAccion(item)
  return jsxs('li', {
    className: 'flex flex-col gap-1 border-t border-(--ui-stroke-secondary) py-2 first:border-t-0',
    children: [
      jsxs('div', {
        className: 'flex items-baseline justify-between gap-2',
        children: [
          jsx('span', { className: 'min-w-0 truncate font-medium', title: item.titulo, children: item.titulo }),
          jsx('span', { className: 'shrink-0 text-xs text-(--ui-text-tertiary)', children: MOTIVOS[item.motivo] ?? item.motivo })
        ]
      }),
      jsx('p', { className: 'text-xs text-(--ui-text-secondary)', children: item.detalle }),
      jsxs('div', {
        className: 'flex flex-wrap items-center gap-1',
        children: [
          jsx(Button, { size: 'xs', variant: 'outline', onClick: () => abrirTarjeta(item), children: 'Ver' }),
          accionable ? jsx(Button, { size: 'xs', onClick: () => pedir(accionable), children: accionable.etiqueta }) : null,
          ...(item.accion?.tipo === 'ver_prs' ? item.accion.prs.map(pr => jsx(Pr, { pr }, pr.url)) : []),
          item.worktree
            ? jsx(Button, { size: 'xs', variant: 'ghost', onClick: () => abrirConsola(item), children: 'Abrir consola aquí' })
            : null
        ]
      })
    ]
  })
}

export function Atascadas() {
  const { data, error } = useFx('/inicio/atascadas', { cadaMs: 15000 })
  const [pendiente, setPendiente] = useState(null)

  let cuerpo
  if (error) cuerpo = jsx(EmptyState, { title: 'No se pudo cargar', description: String(error?.message ?? error) })
  else if (!data) cuerpo = jsx('p', { className: 'text-xs text-(--ui-text-tertiary)', children: 'Cargando…' })
  else if (data.disponible === false) cuerpo = jsx(EmptyState, { title: 'No disponible', description: data.motivo })
  else if (!data.items?.length) cuerpo = jsx(EmptyState, { title: 'Nada atascado', description: 'Ninguna tarjeta está parada por cupo o por un merge.' })
  else cuerpo = jsx('ul', { children: data.items.map(i => jsx(Fila, { item: i, pedir: setPendiente }, `${i.board}/${i.task_id}/${i.motivo}`)) })

  return jsxs(Tarjeta, {
    titulo: 'Atascadas',
    children: [
      cuerpo,
      jsx(ConfirmDialog, {
        open: pendiente !== null,
        onClose: () => setPendiente(null),
        title: pendiente?.titulo ?? '',
        description: pendiente?.descripcion,
        confirmLabel: pendiente?.etiqueta,
        onConfirm: async () => {
          const res = await accion(pendiente.ruta, pendiente.cuerpo)
          if (res?.ok === false) throw new Error(res.salida || 'La acción falló')
        }
      })
    ]
  })
}
