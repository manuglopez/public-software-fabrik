// Piezas comunes de los tests de escritorio de The Factory (D-8, D-9). Cada zona tiene su fichero
// `tests/panel/desktop_<zona>.test.mjs` y construye su propio bundle de prueba, así que los ficheros corren en paralelo:
//
//   import { construir, fixture } from './comun.mjs'
//   const { cargar, html, montar, sdk } = await construir('tablero')
//   const { EnMarcha } = await cargar('inicio/en_marcha')        // cualquier fichero de desktop/src, sin «.js»
//   sdk().datos['/inicio/en-marcha'] = fixture('tablero_en_marcha')
//   assert.match(html(EnMarcha), /…/)
//
// Importar este módulo ya reinicia el SDK falso antes de cada test (datos, consultas, llamadas…).
import { mkdirSync, readFileSync, readdirSync, rmSync, statSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, relative } from 'node:path'
import { beforeEach } from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'

const aqui = dirname(fileURLToPath(import.meta.url))
export const DESKTOP = join(aqui, '..', '..', 'plugin', 'fabrica', 'desktop')
export const SRC = join(DESKTOP, 'src')
const requerir = createRequire(join(DESKTOP, 'package.json')) // las dependencias viven en desktop/node_modules
const { build } = requerir('esbuild')
const { createElement } = requerir('react')
const { renderToStaticMarkup } = requerir('react-dom/server')
const TestRenderer = requerir('react-test-renderer')
globalThis.IS_REACT_ACT_ENVIRONMENT = true

/** `createElement` de React (resuelto desde desktop/node_modules), p. ej. para `arbol.update(h(C, props))`. */
export const h = createElement

/** Nombre con que se carga el propio SDK falso desde el bundle: `await cargar(SDK)`. */
export const SDK = '_sdk_falso'

beforeEach(() => globalThis.__sdkFalso?.reiniciar())

/** `tests/panel/fixtures/<nombre>.json` ya parseado (R-2: `<zona>_*.json`). */
export const fixture = nombre => JSON.parse(readFileSync(join(aqui, 'fixtures', `${nombre}.json`), 'utf8'))

/** Todos los .js bajo `dir` (rutas absolutas). */
export function ficheros(dir) {
  return readdirSync(dir).flatMap(n => {
    const ruta = join(dir, n)
    return statSync(ruta).isDirectory() ? ficheros(ruta) : ruta.endsWith('.js') ? [ruta] : []
  })
}

/**
 * Construye `desktop/src/**` con el SDK falso en `desktop/.prueba/<zona>/` (dentro de desktop/ para que `react`
 * resuelva a su node_modules) y borra solo esa carpeta, antes y al salir del proceso.
 * @returns {Promise<{cargar: (nombre: string) => Promise<object>, html: Function, montar: Function, act: Function, sdk: () => object, salida: string}>}
 */
export async function construir(zona) {
  if (!/^[a-z0-9_-]+$/.test(zona)) throw new Error(`zona no válida: ${zona}`)
  const salida = join(DESKTOP, '.prueba', zona)
  rmSync(salida, { recursive: true, force: true })
  mkdirSync(salida, { recursive: true })
  process.once('exit', () => rmSync(salida, { recursive: true, force: true }))
  const entradas = Object.fromEntries(ficheros(SRC).map(f => [relative(SRC, f).replace(/\.js$/, ''), f]))
  entradas[SDK] = join(aqui, 'sdk_falso.mjs')
  await build({
    entryPoints: entradas,
    outdir: salida,
    bundle: true,
    splitting: true, // un solo SDK falso y un solo estado de módulo (api.js, ui.js) para todas las entradas
    format: 'esm',
    target: 'es2022',
    logLevel: 'silent',
    loader: { '.css': 'text' },
    external: ['react', 'react/jsx-runtime'],
    alias: { '@hermes/plugin-sdk': entradas[SDK] }
  })
  const cargar = nombre => import(pathToFileURL(join(salida, `${nombre}.js`)).href)
  await cargar(SDK) // crea globalThis.__sdkFalso antes de cualquier test
  return {
    cargar,
    /** HTML estático (react-dom/server): sin efectos. */
    html: (Componente, props = {}) => renderToStaticMarkup(createElement(Componente, props)),
    /** Árbol de react-test-renderer (con efectos) para pulsar botones: `montar(C).root.findByType('button')`. */
    montar(Componente, props = {}) {
      let r
      TestRenderer.act(() => {
        r = TestRenderer.create(createElement(Componente, props))
      })
      return r
    },
    act: TestRenderer.act,
    sdk: () => globalThis.__sdkFalso,
    salida
  }
}

// ---- AC-1c: detector de colores fijos (cualquier zona puede pasarlo a sus fuentes) ----
const NOMBRES = 'red|green|blue|black|white|gray|grey|orange|yellow|purple|pink|brown|cyan|magenta|teal|navy|lime|maroon|olive|silver|gold|indigo|violet|crimson|salmon|coral|aqua|fuchsia|slate|zinc|stone|amber|emerald|sky|rose'
const CRUDOS = [
  /#[0-9a-fA-F]{3,8}\b/,
  /\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(/,
  new RegExp(`\\b(?:${NOMBRES})\\b`, 'i')
]
/** Patrones de color fijo que aparecen en `fuente` fuera de comentarios y de `var(...)`; [] si no hay. */
export function coloresFijos(fuente) {
  let t = fuente.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:\w])\/\/[^\n]*/g, '$1')
  // `var(--x)` y `var(--x, var(--y))` son válidos: se quitan, de dentro hacia fuera, antes de buscar.
  for (let previo = ''; previo !== t; ) {
    previo = t
    t = t.replace(/var\([^()]*\)/g, '')
  }
  return CRUDOS.filter(re => re.test(t)).map(String)
}

/**
 * Nombres de valor que exporta un fichero TS/JS (sin `export type`). Sirve para comparar el SDK falso con el real.
 * `leer(especificador)` devuelve la fuente de un `export * from '<especificador>'` (o null): sin él, esos se ignoran.
 */
export function exportsDeFuente(fuente, leer = null) {
  const t = fuente.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:\w'"])\/\/[^\n]*/g, '$1')
  const nombres = new Set()
  for (const m of t.matchAll(/export\s+(type\s+)?\{([^}]*)\}/g)) {
    if (m[1]) continue
    for (const trozo of m[2].split(',').map(s => s.trim()).filter(Boolean)) {
      if (/^type\s/.test(trozo)) continue
      const alias = trozo.match(/\bas\s+([\w$]+)$/)
      nombres.add(alias ? alias[1] : trozo)
    }
  }
  for (const m of t.matchAll(/export\s+\*\s+as\s+([\w$]+)/g)) nombres.add(m[1])
  for (const m of t.matchAll(/export\s+\*\s+from\s+['"]([^'"]+)['"]/g)) {
    const otra = leer?.(m[1])
    if (otra != null) for (const n of exportsDeFuente(otra, leer)) nombres.add(n)
  }
  for (const m of t.matchAll(/export\s+(?:async\s+)?(?:const|let|var|function\*?|class)\s+([\w$]+)/g)) nombres.add(m[1])
  return [...nombres].sort()
}
