// Empaqueta src/index.js → plugin.js (ESM). Uso: node build.mjs [--watch]
// @hermes/plugin-sdk, react y react/jsx-runtime quedan externos: son los únicos especificadores que resuelve el
// cargador de Hermes Desktop. El resto (xterm, su CSS como texto) se empaqueta dentro.
import { build, context } from 'esbuild'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const aqui = dirname(fileURLToPath(import.meta.url))

const opciones = {
  entryPoints: [join(aqui, 'src', 'index.js')],
  outfile: join(aqui, 'plugin.js'),
  bundle: true,
  format: 'esm',
  target: 'es2022',
  charset: 'utf8',
  legalComments: 'none',
  logLevel: 'warning',
  loader: { '.css': 'text' },
  external: ['@hermes/plugin-sdk', 'react', 'react/jsx-runtime'],
  banner: {
    js: [
      '/*',
      ' * The Factory — mitad de escritorio (ARTEFACTO GENERADO).',
      ' * Fuentes: desktop/src/. Se regenera con scripts/plugin-desktop.sh build.',
      ' */'
    ].join('\n')
  }
}

if (process.argv.includes('--watch')) {
  const ctx = await context(opciones)
  await ctx.watch()
  console.log('watch: reconstruyendo plugin.js en cada guardado')
} else {
  await build(opciones)
}
