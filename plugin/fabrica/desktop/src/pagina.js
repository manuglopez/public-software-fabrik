// Página /the-factory: cabecera con el logo + pestañas. Cada sección vive en su fichero (D-4).
import { useState } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'
import { Logo } from './logo.js'
import { Consola } from './consola.js'
import { Atascadas } from './inicio/atascadas.js'
import { Cadena } from './inicio/cadena.js'
import { Cupos } from './inicio/cupos.js'
import { EnMarcha } from './inicio/en_marcha.js'
import { Lanzar } from './inicio/lanzar.js'
import { Maquina } from './inicio/maquina.js'
import { Memoria } from './inicio/memoria.js'
import { TeToca } from './inicio/te_toca.js'
import { Agentes } from './pestanas/agentes.js'
import { Costes } from './pestanas/costes.js'
import { PestanaMemoria } from './pestanas/memoria.js'
import { Proyectos } from './pestanas/proyectos.js'

function Inicio() {
  const columna = hijos => jsx('div', { className: 'flex min-w-0 flex-col gap-3', children: hijos })
  return jsxs('div', {
    className: 'flex flex-col gap-3',
    children: [
      jsxs('div', {
        className: 'grid grid-cols-1 gap-3 lg:grid-cols-2',
        children: [
          columna([jsx(TeToca, {}, 'te-toca'), jsx(Atascadas, {}, 'atascadas'), jsx(Cadena, {}, 'cadena'), jsx(EnMarcha, {}, 'en-marcha')]),
          columna([jsx(Cupos, {}, 'cupos'), jsx(Maquina, {}, 'maquina'), jsx(Memoria, {}, 'memoria'), jsx(Lanzar, {}, 'lanzar')])
        ]
      }),
      jsx(Consola, {})
    ]
  })
}

export const PESTANAS = [
  { id: 'inicio', titulo: 'Inicio', vista: Inicio },
  { id: 'proyectos', titulo: 'Proyectos', vista: Proyectos },
  { id: 'agentes', titulo: 'Agentes', vista: Agentes },
  { id: 'costes', titulo: 'Cupos y costes', vista: Costes },
  { id: 'memoria', titulo: 'Memoria', vista: PestanaMemoria }
]

export function Pagina() {
  const [activa, setActiva] = useState('inicio')
  const Vista = (PESTANAS.find(p => p.id === activa) ?? PESTANAS[0]).vista
  return jsxs('div', {
    className: 'flex h-full flex-col gap-3 overflow-auto p-4 text-sm',
    children: [
      jsxs('h2', {
        className: 'flex items-center gap-2 text-base font-semibold',
        children: [jsx(Logo, {}), jsx('span', { children: 'The Factory' })]
      }),
      jsx('div', {
        role: 'tablist',
        className: 'flex gap-1 border-b border-(--ui-stroke-secondary)',
        children: PESTANAS.map(p =>
          jsx('button', {
            type: 'button',
            role: 'tab',
            'aria-selected': p.id === activa,
            className:
              'px-3 py-1.5 -mb-px border-b-2 ' +
              (p.id === activa
                ? 'border-(--ui-accent) font-medium'
                : 'border-transparent text-(--ui-text-tertiary) hover:text-(--ui-text-secondary)'),
            onClick: () => setActiva(p.id),
            children: p.titulo
          }, p.id)
        )
      }),
      jsx(Vista, {})
    ]
  })
}
