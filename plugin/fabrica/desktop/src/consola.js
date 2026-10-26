// Consola por tarjeta (AC-5): pestañas con un terminal xterm.js contra un PTY del backend (dashboard/fx_consola.py).
// Se abre con `abrirConsola({board, task_id})` (evento `fabrica:consola`, ui.js). Salida por `ctx.socket` y, si el socket
// no llega (remotos OAuth) o se calla, por sondeo de `/salida`; teclas y tamaño por `ctx.rest`. Sin colores fijos: el
// tema del terminal sale de los colores calculados de su contenedor.
import cssXterm from '@xterm/xterm/css/xterm.css'
import { Button, EmptyState } from '@hermes/plugin-sdk'
import { useEffect, useRef, useState } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'
import { ctxPlugin } from './api.js'
import { Tarjeta, useAbrirConsola } from './ui.js'

const SONDEO_MS = 1000
const SILENCIO_MS = 5000 // sin frames del socket (ni latidos, que llegan cada ~2 s) → se sondea /salida

const rest = (ruta, cuerpo) => {
  const ctx = ctxPlugin()
  if (!ctx?.rest) return Promise.reject(new Error('fabrica: backend sin inicializar'))
  return ctx.rest(ruta, cuerpo === undefined ? undefined : { method: 'POST', body: cuerpo })
}
const clave = ({ board, task_id }) => `${board}\n${task_id}`

/**
 * Lector de la salida por posiciones absolutas (bytes del anillo del backend): escribe cada trozo una sola vez aunque
 * llegue por el socket y por el sondeo, o el socket se reconecte y repita desde el principio.
 * `aplicar(frame)` → 'escrito' | 'repetido' | 'hueco' (falta o solapa algo: hay que pedir /salida desde `visto`).
 */
export function lectorSalida(escribir) {
  const lector = {
    visto: 0,
    viva: true,
    aplicar({ datos = '', desde = 0, hasta = desde, viva = true } = {}) {
      if (viva === false) lector.viva = false
      if (hasta <= lector.visto) return 'repetido'
      // El primer trozo puede empezar donde sea (el anillo ya rotó); después, solo justo donde se quedó.
      if (lector.visto > 0 && desde !== lector.visto) return 'hueco'
      if (datos) escribir(datos)
      lector.visto = hasta
      return 'escrito'
    }
  }
  return lector
}

/** Cola de teclas: un POST cada vez, en orden, juntando lo que se teclea mientras tanto. */
export function colaEntrada(enviar) {
  let pendiente = ''
  let enVuelo = null
  const vaciar = async () => {
    while (pendiente) {
      const datos = pendiente
      pendiente = ''
      try {
        await enviar(datos)
      } catch {
        // la consola ya no está (o el backend cayó): esas teclas se pierden, no se reintentan
      }
    }
    enVuelo = null
  }
  return {
    poner(datos) {
      pendiente += datos
      enVuelo ??= vaciar()
      return enVuelo
    }
  }
}

/** Programa `fn` cada `ms` con los temporizadores del ctx (se limpian al descargar el plugin) o, sin ctx, los globales. */
function cadaIntervalo(fn, ms) {
  const ctx = ctxPlugin()
  if (ctx?.setInterval) return ctx.setInterval(fn, ms)
  const id = setInterval(fn, ms)
  return () => clearInterval(id)
}

/** ¿El error de ctx.rest dice que la consola ya no existe? (`statusCode` o, si cruzó IPC, el prefijo «404: »). */
const consolaPerdida = e => [404, 410].includes(Number(e?.statusCode)) || /^(404|410):/.test(String(e?.message ?? ''))

/** Salida de la consola `id` hacia `escribir`: socket y, si calla, sondeo de respaldo. Devuelve la baja. */
export function seguirSalida(id, escribir, alTerminar) {
  const lector = lectorSalida(escribir)
  let ultimoFrame = 0
  let pidiendo = false
  let fin = false
  const terminar = () => {
    if (!fin && !lector.viva) {
      fin = true
      alTerminar?.()
    }
  }
  const sondear = async () => {
    if (pidiendo || fin) return
    pidiendo = true
    try {
      const r = await rest(`/consola/${id}/salida?desde=${lector.visto}`)
      // /salida empieza más allá de lo visto solo si el anillo ya rotó: eso se perdió, se sigue desde ahí
      if (r && r.desde > lector.visto) lector.visto = r.desde
      if (r) lector.aplicar(r)
      terminar()
    } catch (e) {
      // 404/410: el backend ya no la tiene (reinicio, inactividad); otro error: se reintenta en el siguiente tic
      if (consolaPerdida(e)) {
        lector.viva = false
        terminar()
      }
    } finally {
      pidiendo = false
    }
  }
  const bajaSocket = ctxPlugin()?.socket?.(`/consola/${id}?desde=0`, frame => {
    ultimoFrame = Date.now()
    if (lector.aplicar(frame ?? {}) === 'hueco') void sondear()
    terminar()
  })
  const bajaSondeo = cadaIntervalo(() => {
    if (Date.now() - ultimoFrame > SILENCIO_MS) void sondear()
  }, SONDEO_MS)
  void sondear()
  return () => {
    fin = true
    bajaSocket?.()
    bajaSondeo?.()
  }
}

/**
 * xterm y addon-fit, cargados la primera vez que se pinta un terminal. Son UMD que tocan `self`/`window` al evaluarse:
 * con `require` esbuild los empaqueta dentro de plugin.js pero solo los evalúa al llamar aquí (un `import` estático los
 * evaluaría al cargar el plugin, y un `import()` metería en el bundle algo que el cargador de la app puede rechazar).
 */
function xterm() {
  // eslint-disable-next-line no-undef
  return { Terminal: require('@xterm/xterm').Terminal, FitAddon: require('@xterm/addon-fit').FitAddon }
}

function inyectarCss() {
  if (document.getElementById('fabrica-xterm-css')) return
  const estilo = document.createElement('style')
  estilo.id = 'fabrica-xterm-css'
  estilo.textContent = cssXterm
  document.head.appendChild(estilo)
}

function Pantalla({ pestana, alTerminar }) {
  const caja = useRef(null)
  const term = useRef(null)
  const pendiente = useRef([]) // salida que llega antes de que haya terminal (o sin DOM)

  useEffect(() => {
    const el = caja.current
    if (!el || typeof document === 'undefined') return undefined // sin DOM (render de tests)
    const { Terminal, FitAddon } = xterm()
    inyectarCss()
    const cs = getComputedStyle(el)
    const t = new Terminal({
      cursorBlink: true,
      fontFamily: cs.fontFamily,
      fontSize: 13,
      scrollback: 5000,
      theme: { background: cs.backgroundColor, foreground: cs.color, cursor: cs.color }
    })
    const ajuste = new FitAddon()
    t.loadAddon(ajuste)
    t.open(el)
    const cola = colaEntrada(datos => rest(`/consola/${pestana.id}/entrada`, { datos }))
    const teclas = t.onData(d => void cola.poner(d))
    const avisarTamano = (cols, filas) => void rest(`/consola/${pestana.id}/tamano`, { cols, filas }).catch(() => {})
    const tamano = t.onResize(({ cols, rows }) => avisarTamano(cols, rows))
    const ajustar = () => {
      try {
        ajuste.fit()
      } catch {
        // contenedor oculto o aún sin tamaño
      }
    }
    ajustar()
    avisarTamano(t.cols, t.rows)
    const obs = typeof ResizeObserver === 'function' ? new ResizeObserver(ajustar) : null
    obs?.observe(el)
    for (const d of pendiente.current.splice(0)) t.write(d)
    term.current = t
    el.scrollIntoView?.({ block: 'nearest', behavior: 'smooth' }) // la Consola está al final de Inicio
    t.focus()
    return () => {
      term.current = null
      obs?.disconnect()
      teclas.dispose()
      tamano.dispose()
      t.dispose()
    }
  }, [pestana.id])

  useEffect(() => {
    const escribir = d => (term.current ? term.current.write(d) : pendiente.current.push(d))
    return seguirSalida(pestana.id, escribir, () => {
      escribir('\r\n[la consola ha terminado]\r\n')
      alTerminar?.(pestana.id)
    })
  }, [pestana.id])

  return jsx('div', {
    ref: caja,
    'data-consola': pestana.id,
    className: 'h-80 overflow-hidden rounded-md bg-(--ui-bg-editor) p-1 font-mono text-(--ui-text-primary)'
  })
}

// Las pestañas viven fuera del componente: al cambiar de pestaña del panel y volver siguen ahí (el backend las mantiene
// abiertas y, si se olvidan, las cierra tras 30 min sin uso).
let guardadas = []

export function Consola() {
  const [pestanas, setPestanas] = useState(guardadas)
  const [activa, setActiva] = useState(guardadas[0]?.clave ?? null)
  const [aviso, setAviso] = useState(null)
  const actuales = useRef(pestanas)
  actuales.current = pestanas
  useEffect(() => {
    guardadas = pestanas
  }, [pestanas])

  useAbrirConsola(async tarjeta => {
    if (!tarjeta?.board || !tarjeta?.task_id) return
    const k = clave(tarjeta)
    setAviso(null)
    const previa = actuales.current.find(p => p.clave === k)
    if (previa && !previa.terminada) return setActiva(k)
    try {
      const r = await rest('/consola/abrir', { board: tarjeta.board, task_id: tarjeta.task_id })
      const nueva = { ...r, clave: k, board: tarjeta.board, task_id: tarjeta.task_id }
      // una pestaña terminada se sustituye en su sitio por la consola nueva
      setPestanas(ps =>
        ps.some(p => p.clave === k) ? ps.map(p => (p.clave === k && p.terminada ? nueva : p)) : [...ps, nueva]
      )
      setActiva(k)
    } catch (e) {
      setAviso(`No se pudo abrir la consola: ${e?.message ?? e}`)
    }
  })

  const terminada = id => setPestanas(ps => ps.map(p => (p.id === id ? { ...p, terminada: true } : p)))

  const cerrar = p => {
    void rest(`/consola/${p.id}/cerrar`, {}).catch(() => {})
    const quedan = pestanas.filter(x => x.clave !== p.clave)
    setPestanas(quedan)
    if (activa === p.clave) setActiva(quedan[0]?.clave ?? null)
  }

  const sistema = async p => {
    setAviso(null)
    try {
      const r = await rest('/consola/sistema', { board: p.board, task_id: p.task_id })
      if (r?.ok) return
      throw new Error(r?.salida || 'fabrik-consola falló')
    } catch (e) {
      const revelado = await ctxPlugin()?.os?.revealPath?.(p.cwd)
      if (!revelado) setAviso(`No se pudo abrir la terminal del sistema: ${e?.message ?? e}`)
    }
  }

  const actual = pestanas.find(p => p.clave === activa) ?? null
  const lista = pestanas.map(p =>
    jsxs('div', {
      className: 'flex items-center',
      children: [
        jsx('button', {
          type: 'button',
          role: 'tab',
          'aria-selected': p.clave === activa,
          title: p.cwd,
          className:
            'px-2 py-1 -mb-px border-b-2 font-mono text-xs ' +
            (p.clave === activa ? 'border-(--ui-accent)' : 'border-transparent text-(--ui-text-tertiary)'),
          onClick: () => setActiva(p.clave),
          children: p.titulo
        }),
        jsx('button', {
          type: 'button',
          'aria-label': `Cerrar ${p.titulo}`,
          className: 'px-1 text-(--ui-text-tertiary) hover:text-(--ui-text-secondary)',
          onClick: () => cerrar(p),
          children: '×'
        })
      ]
    }, p.clave)
  )

  return jsx(Tarjeta, {
    titulo: 'Consola',
    children: jsxs('div', {
      className: 'flex flex-col gap-2',
      children: [
        aviso ? jsx('p', { role: 'alert', className: 'text-xs text-(--ui-text-secondary)', children: aviso }, 'aviso') : null,
        pestanas.length === 0
          ? jsx(EmptyState, {
              title: 'Sin consolas abiertas',
              description: 'Pulsa «Abrir consola aquí» en una tarjeta de En marcha, Atascadas o Cadena.'
            }, 'vacio')
          : jsx('div', { role: 'tablist', className: 'flex flex-wrap gap-1 border-b border-(--ui-stroke-secondary)', children: lista }, 'pestanas'),
        actual
          ? jsxs('div', {
              className: 'flex flex-col gap-2',
              children: [
                actual.en_marcha
                  ? jsx('p', {
                      role: 'note',
                      className: 'rounded-md border border-(--ui-stroke-secondary) px-2 py-1 text-xs',
                      children: 'La tarjeta está en marcha: mejor mándale un mensaje.'
                    }, 'en-marcha')
                  : null,
                jsxs('div', {
                  className: 'flex items-center justify-between gap-2 text-xs text-(--ui-text-tertiary)',
                  children: [
                    jsx('span', { className: 'truncate font-mono', children: actual.cwd }),
                    jsx(Button, { size: 'sm', variant: 'outline', onClick: () => sistema(actual), children: 'Abrir en terminal del sistema' })
                  ]
                }, 'barra'),
                jsx(Pantalla, { pestana: actual, alTerminar: terminada }, actual.id)
              ]
            }, 'actual')
          : null
      ]
    })
  })
}
