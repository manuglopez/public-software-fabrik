// Pestaña «Agentes» (plan The Factory D-5, AC-4b/AC-2b): muestra y edita el reparto dinámico de bin/fabrik-modelos.
// Por rol, candidatos ordenables con ✅/⛔ y motivo por ruta y cuenta, el modelo actual del perfil y las tarjetas por
// brazo en 7 días; cuentas de Claude con tope semanal; topes por bolsa; último recurso; informe de calidad 7/14/30.
// El borrador guarda solo lo cambiado (roles, ultimo_recurso, topes, topes_cuenta) y se valida en el backend en cada
// cambio: con errores no se guarda. «Aplicar ahora» lanza `fabrik-modelos tick`.
import { EmptyState, useQuery } from '@hermes/plugin-sdk'
import { useState } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'
import { accion, ctxPlugin, useFx } from '../api.js'
import { Tarjeta } from '../ui.js'

const DIAS = [7, 14, 30]
const BTN = 'rounded border border-(--ui-stroke-secondary) px-1.5 text-xs disabled:opacity-40'
const TENUE = 'text-xs text-(--ui-text-tertiary)'
const CAMPO = 'w-14 rounded border border-(--ui-stroke-secondary) bg-transparent px-1 text-xs'

// Validar no invalida consultas (accion() sí, y re-lanzaría esta misma validación en bucle).
const validarEnBackend = reparto => {
  const ctx = ctxPlugin()
  if (!ctx?.rest) return Promise.reject(new Error('fabrica: backend sin inicializar'))
  return ctx.rest('/agentes/validar', { method: 'POST', body: { reparto } })
}

// Lo que se teclea en un tope: entero si lo parece; si no, tal cual (el backend explica por qué no vale).
const aTope = v => (/^\d+$/.test(v) ? Number(v) : v)

function mover(lista, i, paso) {
  const j = i + paso
  if (j < 0 || j >= lista.length) return lista
  const nueva = [...lista]
  ;[nueva[i], nueva[j]] = [nueva[j], nueva[i]]
  return nueva
}

const boton = (etiqueta, texto, onClick, extra = {}, key = undefined) =>
  jsx('button', { type: 'button', className: BTN, 'aria-label': etiqueta, title: etiqueta, onClick, children: texto, ...extra }, key)

function Candidato({ rol, ruta, i, lista, rutas, estado, brazos, cambiar }) {
  const filas = estado.filter(f => f.ruta === ruta)
  const n = brazos.find(b => b.rol === rol && b.ruta === ruta)?.n
  return jsxs('li', {
    'data-rol': rol,
    'data-ruta': ruta,
    className: 'flex flex-wrap items-baseline gap-2 py-0.5',
    children: [
      jsx('span', { className: 'w-5 text-right ' + TENUE, children: `${i + 1}.` }),
      jsx('span', { className: 'font-medium', children: ruta }),
      jsx('span', { className: TENUE, children: rutas[ruta]?.modelo ?? 'ruta desconocida' }),
      n ? jsx('span', { className: TENUE, children: `· ${n} en 7 d` }) : null,
      jsx('span', {
        className: 'flex flex-col text-xs',
        children: filas.map(f =>
          jsx('span', { children: `${f.ok ? '✅' : '⛔'} ${f.cuenta ? `${f.cuenta}: ` : ''}${f.motivo}` }, f.cuenta ?? '-')
        )
      }),
      jsxs('span', {
        className: 'ml-auto flex gap-1',
        children: [
          boton(`subir ${ruta} (${rol})`, '↑', () => cambiar(mover(lista, i, -1)), { disabled: i === 0 }),
          boton(`bajar ${ruta} (${rol})`, '↓', () => cambiar(mover(lista, i, 1)), { disabled: i === lista.length - 1 }),
          boton(`quitar ${ruta} (${rol})`, '✕', () => cambiar(lista.filter((_, k) => k !== i)))
        ]
      })
    ]
  })
}

function Rol({ rol, lista, rutas, estado, brazos, perfil, cambiar }) {
  const libres = Object.keys(rutas).filter(r => !lista.includes(r))
  return jsxs('div', {
    className: 'border-t border-(--ui-stroke-secondary) py-2 first:border-t-0',
    children: [
      jsxs('div', {
        className: 'flex items-baseline gap-2',
        children: [
          jsx('span', { className: 'text-sm font-medium', children: rol }),
          jsx('span', { className: TENUE, title: perfil?.proveedor ?? '', children: `ahora: ${perfil?.modelo ?? '—'}` })
        ]
      }),
      jsx('ol', {
        children: lista.map((ruta, i) =>
          jsx(Candidato, { rol, ruta, i, lista, rutas, estado, brazos, cambiar }, `${ruta}-${i}`)
        )
      }),
      jsxs('select', {
        'aria-label': `añadir a ${rol}`,
        className: CAMPO + ' w-auto',
        value: '',
        onChange: e => e.target.value && cambiar([...lista, e.target.value]),
        children: [
          jsx('option', { value: '', children: '+ añadir ruta…' }),
          ...libres.map(r => jsx('option', { value: r, children: r }, r))
        ]
      })
    ]
  })
}

function Tope({ etiqueta, valor, cambiar }) {
  return jsx('input', {
    'aria-label': etiqueta,
    className: CAMPO,
    inputMode: 'numeric',
    placeholder: 'sin tope',
    value: valor ?? '',
    onChange: e => cambiar(aTope(e.target.value))
  })
}

function Lista({ titulo, items, clase = '' }) {
  if (!items?.length) return null
  return jsxs('div', {
    className: 'text-xs ' + clase,
    children: [jsx('div', { className: 'font-medium', children: titulo }), ...items.map((t, i) => jsx('div', { children: `• ${t}` }, i))]
  })
}

function Informe() {
  const [dias, setDias] = useState(14)
  const { data } = useFx(`/agentes/informe?dias=${dias}`)
  const filas = Array.isArray(data?.filas) ? data.filas : []
  const celdas = ['rol', 'ruta', 'tarjetas', 'hechas', 'a la 1.ª', 'rondas/tarjeta', 'fallos']
  return jsx(Tarjeta, {
    titulo: 'Informe de calidad',
    children: jsxs('div', {
      className: 'flex flex-col gap-2',
      children: [
        jsx('div', {
          className: 'flex gap-1',
          children: DIAS.map(d =>
            boton(`informe de ${d} días`, `${d} d`, () => setDias(d), { 'aria-pressed': d === dias }, d)
          )
        }),
        data?.disponible === false
          ? jsx('div', { className: TENUE, children: data.motivo })
          : filas.length === 0
            ? jsx('div', { className: TENUE, children: `Sin asignaciones en ${dias} días.` })
            : jsx('table', {
                className: 'text-xs',
                children: jsxs('tbody', {
                  children: [
                    jsx('tr', { className: TENUE, children: celdas.map(c => jsx('th', { className: 'pr-3 text-left', children: c }, c)) }),
                    ...filas.map(f =>
                      jsx('tr', {
                        children: [f.rol, f.ruta, f.tarjetas, f.hechas, f.primera_pct == null ? '—' : `${f.primera_pct}%`,
                          f.rondas_por_tarjeta, f.fallos].map((v, k) => jsx('td', { className: 'pr-3', children: String(v) }, k))
                      }, `${f.rol}-${f.ruta}`)
                    )
                  ]
                })
              })
      ]
    })
  })
}

export function Agentes() {
  const { data, error } = useFx('/agentes')
  const [borrador, setBorrador] = useState({})
  const [salida, setSalida] = useState(null)
  const [ocupado, setOcupado] = useState(false)
  const clave = JSON.stringify(borrador)
  const hayCambios = clave !== '{}'
  const validacion = useQuery({
    queryKey: ['fabrica', '/agentes/validar', clave],
    queryFn: () => validarEnBackend(borrador),
    enabled: hayCambios,
    retry: false
  })

  if (error) return jsx(Tarjeta, { titulo: 'Agentes', children: jsx(EmptyState, { title: 'Sin datos', description: String(error.message ?? error) }) })
  if (!data) return jsx(Tarjeta, { titulo: 'Agentes', children: jsx('div', { className: TENUE, children: 'Cargando…' }) })
  if (data.disponible === false)
    return jsx(Tarjeta, { titulo: 'Agentes', children: jsx(EmptyState, { title: 'fabrik-modelos no responde', description: data.motivo }) })

  const vigente = data.reparto ?? {}
  const rutas = vigente.rutas ?? {}
  // en los mapas, lo del borrador sustituye entrada a entrada (igual que el backend al guardar)
  const ver = k => (borrador[k] && typeof borrador[k] === 'object' ? { ...(vigente[k] ?? {}), ...borrador[k] } : borrador[k] ?? vigente[k])
  const roles = ver('roles') ?? {}
  const topes = ver('topes') ?? {}
  const topesCuenta = ver('topes_cuenta') ?? {}
  const editar = (k, sub, valor) =>
    setBorrador(b => (sub === null ? { ...b, [k]: valor } : { ...b, [k]: { ...(b[k] ?? {}), [sub]: valor } }))
  const errores = hayCambios ? (validacion.error ? [String(validacion.error.message ?? validacion.error)] : validacion.data?.errores) : []
  const puedeGuardar = hayCambios && Array.isArray(errores) && errores.length === 0 && !ocupado

  const enviar = async (ruta, cuerpo, alAcabar) => {
    setOcupado(true)
    try {
      alAcabar(await accion(ruta, cuerpo))
    } catch (e) {
      setSalida({ ok: false, texto: String(e?.message ?? e) })
    } finally {
      setOcupado(false)
    }
  }
  const guardar = () =>
    enviar('/agentes/guardar', { reparto: borrador }, r => {
      if (r?.ok) setBorrador({})
      setSalida({ ok: !!r?.ok, texto: r?.ok ? r.salida : (r?.errores ?? ['no se pudo guardar']).join('\n') })
    })
  const aplicar = () => enviar('/agentes/aplicar', {}, r => setSalida({ ok: !!r?.ok, texto: r?.salida ?? '' }))

  return jsxs('div', {
    className: 'flex flex-col gap-3',
    children: [
      jsxs(Tarjeta, {
        titulo: 'Candidatos por rol',
        children: [
          ...Object.entries(roles).map(([rol, lista]) =>
            jsx(Rol, {
              rol,
              lista: Array.isArray(lista) ? lista : [],
              rutas,
              estado: data.estado ?? [],
              brazos: data.brazos_7d ?? [],
              perfil: (data.perfiles ?? []).find(p => p.rol === rol),
              cambiar: nueva => editar('roles', rol, nueva)
            }, rol)
          ),
          jsxs('label', {
            className: 'mt-2 flex items-center gap-2 text-xs',
            children: [
              'Último recurso',
              jsx('select', {
                'aria-label': 'último recurso',
                className: CAMPO + ' w-auto',
                value: ver('ultimo_recurso') ?? '',
                onChange: e => editar('ultimo_recurso', null, e.target.value),
                children: Object.keys(rutas).map(r => jsx('option', { value: r, children: r }, r))
              })
            ]
          })
        ]
      }),
      jsx(Tarjeta, {
        titulo: 'Cuentas de Claude',
        children: jsx('table', {
          className: 'text-xs',
          children: jsx('tbody', {
            children: (data.cuentas ?? []).map(c =>
              jsxs('tr', {
                children: [
                  jsx('td', { className: 'pr-3 font-medium', children: c.cuenta }),
                  jsx('td', { className: 'pr-3', children: c.sem_pct == null ? 'sin dato' : `${c.sem_pct}% semanal` }),
                  jsx('td', { className: 'pr-3 ' + TENUE, children: c.renueva ? `renueva ${c.renueva}` : '' }),
                  jsx('td', {
                    children: jsx(Tope, {
                      etiqueta: `tope semanal de la cuenta ${c.cuenta}`,
                      valor: topesCuenta[c.cuenta],
                      cambiar: v => editar('topes_cuenta', c.cuenta, v)
                    })
                  })
                ]
              }, c.cuenta)
            )
          })
        })
      }),
      jsx(Tarjeta, {
        titulo: 'Topes por bolsa',
        children: jsx('div', {
          className: 'flex flex-wrap gap-3 text-xs',
          children: Object.keys(topes).map(k =>
            jsxs('label', {
              className: 'flex items-center gap-1',
              children: [k, jsx(Tope, { etiqueta: `tope ${k}`, valor: topes[k], cambiar: v => editar('topes', k, v) }), '%']
            }, k)
          )
        })
      }),
      jsx(Lista, { titulo: 'Avisos del reparto vigente', items: data.avisos }),
      jsx(Lista, { titulo: 'No se puede guardar', items: errores, clase: 'text-destructive' }),
      jsxs('div', {
        className: 'flex gap-2',
        children: [
          boton('guardar reparto', 'Guardar', guardar, { disabled: !puedeGuardar }),
          boton('descartar cambios', 'Descartar', () => setBorrador({}), { disabled: !hayCambios || ocupado }),
          boton('aplicar ahora', 'Aplicar ahora', aplicar, { disabled: ocupado })
        ]
      }),
      salida
        ? jsx('pre', { className: 'whitespace-pre-wrap text-xs' + (salida.ok ? '' : ' text-destructive'), children: salida.texto })
        : null,
      jsx(Informe, {})
    ]
  })
}
