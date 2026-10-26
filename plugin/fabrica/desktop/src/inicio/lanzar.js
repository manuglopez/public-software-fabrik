// «Lanzar trabajo» (AC-3h): abre un chat nuevo con `/fabrica <flujo> ` en el composer, sin enviarlo.
// `host.composer.setDraft('new', …)` solo escribe si el composer del chat nuevo está montado: desde /the-factory hay que
// abrirlo antes (`host.newChat()`) y reintentar mientras monta.
import { host } from '@hermes/plugin-sdk'
import { useState } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'
import { Tarjeta } from '../ui.js'

export const FLUJOS = [
  { id: 'feature', titulo: 'Nueva feature', detalle: 'Spec contigo → plan con modelo por tarjeta → tú apruebas', boton: 'Empezar', principal: true },
  { id: 'bug', titulo: 'Bug', detalle: 'Síntoma o issue → test que lo reproduce → fix → PR', boton: 'Empezar' },
  { id: 'incorporar', titulo: 'Incorporar repo', detalle: 'Diagnóstico y preparación de un repo para la fábrica', boton: 'Incorporar' },
  { id: 'diagnosticar', titulo: 'Diagnosticar repo dormido', detalle: 'Qué falta para volver a trabajar en él', boton: 'Diagnosticar' }
]

const espera = ms => new Promise(r => setTimeout(r, ms))

/** Chat nuevo con `texto` de borrador. true si el composer lo aceptó; no envía nunca ni lanza (false si el host falla). */
export async function abrirChatCon(texto, { intentos = 20, esperaMs = 100 } = {}) {
  try {
    host.newChat()
    for (let i = 0; i < intentos; i++) {
      if (await host.composer.setDraft('new', texto)) return true
      await espera(esperaMs)
    }
  } catch {
    // el host no deja abrir el chat: quien llama enseña el texto para escribirlo a mano
  }
  return false
}

export function Lanzar() {
  const [fallo, setFallo] = useState(null)
  const lanzar = async flujo => {
    const texto = `/fabrica ${flujo} `
    setFallo((await abrirChatCon(texto)) ? null : texto)
  }
  return jsx(Tarjeta, {
    titulo: 'Lanzar trabajo',
    children: [
      ...FLUJOS.map(f =>
        jsxs('div', {
          className: 'flex items-center gap-2 py-1',
          children: [
            jsxs('div', {
              className: 'min-w-0 flex-1',
              children: [jsx('b', { children: f.titulo }), jsx('div', { className: 'text-xs text-(--ui-text-tertiary)', children: f.detalle })]
            }),
            jsx('button', {
              type: 'button',
              className: f.principal
                ? 'rounded-md bg-(--ui-accent) px-2 py-0.5 text-xs text-(--ui-base)'
                : 'rounded-md border border-(--ui-stroke-secondary) px-2 py-0.5 text-xs hover:bg-(--ui-row-hover-background)',
              'data-flujo': f.id,
              onClick: () => lanzar(f.id),
              children: f.boton
            })
          ]
        }, f.id)
      ),
      fallo &&
        jsx('p', { role: 'alert', className: 'text-xs text-[color:var(--ui-red)]', children: `No se pudo abrir el chat: escribe «${fallo.trim()}» en un chat nuevo.` }, 'fallo')
    ]
  })
}
