// Acceso al backend (/api/plugins/fabrica) con la capa de datos del SDK. Nunca un bucle propio (AC-3).
import { queryClient, useQuery } from '@hermes/plugin-sdk'

const CLAVE = 'fabrica'
let rest = null
let ctx = null

/** Lo llama `register(ctx)`: guarda el `ctx.rest` de este plugin. */
export function fijarRest(fn) {
  rest = fn
}

/** Lo llama `register(ctx)`: guarda el ctx completo (storage, os, socket, runAction…) y conecta su `rest`. */
export function fijarCtx(nuevo) {
  ctx = nuevo
  fijarRest(nuevo?.rest ?? null)
}

/** El ctx del plugin (D-9 R-3): `ctxPlugin().os.notify(…)`, `ctxPlugin().socket(…)`… null antes de `register`. */
export const ctxPlugin = () => ctx

const llamar = (ruta, opciones) => {
  if (!rest) return Promise.reject(new Error('fabrica: backend sin inicializar'))
  return rest(ruta, opciones)
}

/** Lectura con refresco opcional: `useFx('/inicio/te-toca', { cadaMs: 15000 })` → resultado de useQuery. */
export function useFx(ruta, { cadaMs = false } = {}) {
  return useQuery({
    queryKey: [CLAVE, ruta],
    queryFn: () => llamar(ruta),
    refetchInterval: cadaMs,
    retry: false
  })
}

/** Escritura (POST) y, al terminar, invalida todo lo del panel para que se refresque. */
export async function accion(ruta, cuerpo = {}) {
  try {
    return await llamar(ruta, { method: 'POST', body: cuerpo })
  } finally {
    queryClient.invalidateQueries({ queryKey: [CLAVE] })
  }
}
