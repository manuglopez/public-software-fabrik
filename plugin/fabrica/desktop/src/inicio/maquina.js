// «Máquina» (AC-3f): RAM, carga de CPU y turno de tests (`factory-test`: quién lo tiene y cuántos esperan). GET /maquina.
import { jsx, jsxs } from 'react/jsx-runtime'
import { useFx } from '../api.js'
import { Tarjeta } from '../ui.js'
import { FilaBarra, estadoCarga } from './cupos.js'

const fmt = n => (Number.isInteger(n) ? String(n) : Number(n).toFixed(1)).replace('.', ',')
const sinDato = b => !b || b.disponible === false

/** Texto de la suite: «🔒 programador · software-fabrik [IMPL-4]» o «libre»; con su título = la línea completa. */
export function textoSuite(suite) {
  const t = suite?.titular
  if (!t) return { texto: 'libre', titulo: 'Nadie está pasando tests' }
  const quien = t.repo ? `${t.quien} · ${t.repo}${t.etiqueta ? ` [${t.etiqueta}]` : ''}` : t.texto
  return { texto: `🔒 ${quien}`, titulo: t.texto }
}

export function Maquina() {
  const q = useFx('/maquina', { cadaMs: 15000 })
  const { ram, cpu, suite } = q.data ?? {}
  const cola = suite?.cola ?? []
  const conPrio = cola.filter(c => c.prioridad).length
  const { texto, titulo } = textoSuite(suite)
  const cuerpo = estadoCarga(q, 'Máquina') ?? [
    sinDato(ram)
      ? jsx(FilaBarra, { etiqueta: 'RAM', ancho: 'w-16', pct: 0, texto: '—' }, 'ram')
      : jsx(FilaBarra, { etiqueta: 'RAM', ancho: 'w-16', pct: (100 * ram.usado_gb) / ram.total_gb, texto: `${fmt(ram.usado_gb)} / ${fmt(ram.total_gb)} GB` }, 'ram'),
    sinDato(cpu)
      ? jsx(FilaBarra, { etiqueta: 'CPU', ancho: 'w-16', pct: 0, texto: '—' }, 'cpu')
      : jsx(FilaBarra, { etiqueta: 'CPU', ancho: 'w-16', pct: (100 * cpu.carga) / cpu.nucleos, texto: `${fmt(cpu.carga)} / ${cpu.nucleos}` }, 'cpu'),
    jsxs('div', {
      className: 'flex items-center gap-2 py-0.5',
      children: [
        jsx('span', { className: 'w-16 shrink-0 text-(--ui-text-tertiary)', children: 'Suite' }),
        jsx('div', { className: 'min-w-0 flex-1 truncate', title: titulo, children: texto }),
        jsx('span', {
          className: 'shrink-0 text-(--ui-text-tertiary)',
          title: cola.map(c => `${c.prioridad ? '⏫ ' : ''}${c.repo}: ${c.cmd}`).join('\n') || undefined,
          children: `cola: ${cola.length}${conPrio ? ` (${conPrio} con prioridad)` : ''}`
        })
      ]
    }, 'suite')
  ]
  return jsx(Tarjeta, { titulo: 'Máquina', children: cuerpo })
}
