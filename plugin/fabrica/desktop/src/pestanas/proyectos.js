// Pestaña «Proyectos» (AC-4a): catálogo por producto con tarjetas activas, PRs de agentes y «Nueva feature aquí».
import { EmptyState } from '@hermes/plugin-sdk'
import { useState } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'
import { ctxPlugin, useFx } from '../api.js'
import { abrirChatCon } from '../inicio/lanzar.js'
import { Tarjeta, abrirTarjeta } from '../ui.js'

const plural = (n, uno, varios) => `${n} ${n === 1 ? uno : varios}`
const BOTON = 'rounded border border-(--ui-stroke-secondary) px-2 py-0.5 text-xs hover:bg-(--ui-fill-secondary)'

function abrirPr(e, url) {
  e.preventDefault?.()
  ctxPlugin()?.os?.openExternal(url)
}

function Repo({ repo }) {
  const [fallo, setFallo] = useState(null)
  // Mismo camino que «Lanzar trabajo»: setDraft('new') es fail-closed sin el composer del chat nuevo montado.
  const nuevaFeature = async () => {
    const texto = `/fabrica feature ${repo.repo} `
    setFallo((await abrirChatCon(texto)) ? null : texto)
  }
  return jsxs('div', {
    className: 'flex flex-col gap-1 border-t border-(--ui-stroke-secondary) py-2 first:border-t-0',
    children: [
      jsxs('div', {
        className: 'flex flex-wrap items-center gap-2',
        children: [
          jsx('span', { className: 'font-medium', children: repo.repo }),
          repo.ritmo
            ? jsx('span', {
                className: repo.ritmo === 'diario' ? 'text-xs text-(--ui-accent)' : 'text-xs text-(--ui-text-tertiary)',
                children: repo.ritmo
              })
            : null,
          jsx('span', { className: 'text-xs text-(--ui-text-tertiary)', children: plural(repo.tarjetas_activas, 'tarjeta', 'tarjetas') }),
          jsx('button', {
            type: 'button',
            className: `${BOTON} ml-auto`,
            onClick: nuevaFeature,
            children: 'Nueva feature aquí'
          })
        ]
      }),
      fallo
        ? jsx('p', { role: 'alert', className: 'text-xs text-[color:var(--ui-red)]', children: `No se pudo abrir el chat: escribe «${fallo.trim()}» en un chat nuevo.` })
        : null,
      ...repo.tarjetas.map(t =>
        jsx(
          'button',
          {
            type: 'button',
            className: 'truncate text-left text-xs hover:underline',
            title: `${t.task_id} · ${t.estado}`,
            onClick: () => abrirTarjeta({ board: t.board, task_id: t.task_id }),
            children: `${t.estado} · ${t.titulo}`
          },
          `${t.board}/${t.task_id}`
        )
      ),
      ...repo.prs.map(p =>
        jsx(
          'a',
          {
            href: p.url,
            className: 'truncate text-xs text-(--ui-accent) hover:underline',
            onClick: e => abrirPr(e, p.url),
            children: `#${p.numero} ${p.titulo}`
          },
          p.numero
        )
      )
    ]
  })
}

export function Proyectos() {
  const { data, error } = useFx('/proyectos', { cadaMs: 30000 })
  if (error) return jsx(EmptyState, { title: 'Proyectos no disponible', description: 'El backend de The Factory no responde.' })
  if (!data) return jsx('p', { className: 'text-(--ui-text-tertiary)', children: 'Cargando proyectos…' })
  if (data.disponible === false) return jsx(EmptyState, { title: 'Proyectos no disponible', description: data.motivo })
  const productos = data.productos ?? []
  return jsxs('div', {
    className: 'flex flex-col gap-3',
    children: [
      productos.length === 0
        ? jsx(EmptyState, { title: 'Sin proyectos', description: 'El portfolio no tiene proyectos activos ni asignados a un producto.' })
        : productos.map(p =>
            jsxs(
              Tarjeta,
              {
                titulo: p.nombre,
                children: [
                  p.nota ? jsx('p', { className: 'mb-1 text-xs text-(--ui-text-tertiary)', children: p.nota }) : null,
                  ...p.repos.map(r => jsx(Repo, { repo: r }, r.full_name))
                ]
              },
              p.nombre
            )
          ),
      ...(data.avisos ?? []).map(a => jsx('p', { className: 'text-xs text-(--ui-text-tertiary)', children: a }, a))
    ]
  })
}
