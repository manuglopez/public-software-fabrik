// SDK falso de Hermes Desktop para los tests del panel (D-8, D-9): sustituye a `@hermes/plugin-sdk` en el bundle de prueba.
// Exporta los mismos nombres que el SDK real (lista en fixtures/comun_sdk_exports.json; desktop_comun.test.mjs la vigila)
// y además `ctxFalso()`. Estado observable en `globalThis.__sdkFalso`:
//   datos[ruta]     lo que devuelven useQuery (queryKey[1]) y ctx.rest (valor; Error → rechaza; función(opciones) → valor)
//   consultas       opciones de cada useQuery          llamadas      [{que: 'host.navigate' | 'ctx.rest' | …, args}]
//   navegaciones    rutas de host.navigate             invalidadas   filtros de queryClient.invalidateQueries
//   sockets[ruta]   receptor de ctx.socket (empuja frames llamándolo)  contribuciones  lo registrado con ctx.register*
// `reiniciar()` lo limpia todo (comun.mjs lo llama antes de cada test).
import { createElement } from 'react'

const estado = (globalThis.__sdkFalso ??= {
  datos: {},
  consultas: [],
  navegaciones: [],
  invalidadas: [],
  llamadas: [],
  sockets: {},
  contribuciones: [],
  reiniciar() {
    this.datos = {}
    this.sockets = {}
    for (const k of ['consultas', 'navegaciones', 'invalidadas', 'llamadas', 'contribuciones']) this[k].length = 0
  }
})
// `window` para los eventos del panel (abrirConsola); en Node no existe.
globalThis.window ??= new EventTarget()

const anota = (que, args) => estado.llamadas.push({ que, args })
/** Función que apunta sus llamadas como `que` y devuelve `devuelve(...args)`. */
const registra = (que, devuelve = () => undefined) => (...args) => (anota(que, args), devuelve(...args))
/** Objeto en que cualquier método no definido apunta su llamada como `<prefijo>.<método>`. No es thenable. */
const espacio = (prefijo, fijos = {}) =>
  new Proxy(fijos, {
    get(obj, prop) {
      if (prop in obj || typeof prop === 'symbol' || prop === 'then' || prop === 'toJSON') return obj[prop]
      return (obj[prop] = registra(`${prefijo}.${prop}`))
    }
  })

// ---- componentes: <div data-sdk="Nombre"> con sus hijos (title/description en <b>/<p>, para EmptyState y similares) ----
const componente = nombre => {
  const C = ({ children, title, description }) =>
    createElement(
      'div',
      { 'data-sdk': nombre },
      typeof title === 'string' ? createElement('b', null, title) : null,
      typeof description === 'string' ? createElement('p', null, description) : null,
      children
    )
  C.displayName = nombre
  return C
}
const NOMBRES_COMPONENTES = [
  'Badge', 'Blobatar', 'Button', 'CapabilitiesView', 'Checkbox', 'Codicon', 'ColorSwatches', 'ConfirmDialog', 'ConnectionGlyph',
  'ConnectorsTab', 'ContextMenu', 'ContextMenuCheckboxItem', 'ContextMenuContent', 'ContextMenuItem', 'ContextMenuSeparator',
  'ContextMenuSub', 'ContextMenuSubContent', 'ContextMenuSubTrigger', 'ContextMenuTrigger', 'Contribute', 'CopyButton', 'DecodeText',
  'Dialog', 'DialogContent', 'DialogDescription', 'DialogFooter', 'DialogHeader', 'DialogTitle', 'DialogTrigger', 'DisclosureCaret',
  'DropdownMenu', 'DropdownMenuContent', 'DropdownMenuItem', 'DropdownMenuSeparator', 'DropdownMenuTrigger', 'EmptyState',
  'ErrorState', 'FadeScroll', 'GlyphSpinner', 'Input', 'KanbanCardBadges', 'Kbd', 'KbdGroup', 'ListRow', 'Loader', 'LocalizedTabTitle', 'LogView',
  'MessageTextContent', 'ModelCatalogMenu', 'PanelAction', 'PanelAddButton', 'PanelBlock', 'PanelBody', 'PanelDetail', 'PanelEmpty',
  'PanelHeader', 'PanelList', 'PanelListRow', 'PanelMeta', 'PanelPill', 'PanelRowMenu', 'PanelSectionLabel', 'Popover', 'PopoverContent',
  'PopoverTrigger', 'RowButton', 'SandboxedFrame', 'ScrollArea', 'SearchField', 'SegmentedControl', 'Select', 'SelectContent',
  'SelectItem', 'SelectTrigger', 'SelectValue', 'Separator', 'SessionStatusDot', 'SidebarRowLead', 'Skeleton', 'StatusDot', 'Streamdown',
  'Switch', 'Tabs', 'TabsList', 'TabsTrigger', 'Textarea', 'Tip', 'ToggleRow', 'ToolsetConfigPanel', 'Tooltip', 'TooltipContent',
  'TooltipProvider', 'TooltipTrigger', 'Wordmark', 'WorkspacePageHeaderControl'
]
const C = Object.fromEntries(NOMBRES_COMPONENTES.map(n => [n, componente(n)]))
export const {
  Badge, Blobatar, Button, CapabilitiesView, Checkbox, Codicon, ColorSwatches, ConfirmDialog, ConnectionGlyph, ConnectorsTab,
  ContextMenu, ContextMenuCheckboxItem, ContextMenuContent, ContextMenuItem, ContextMenuSeparator, ContextMenuSub,
  ContextMenuSubContent, ContextMenuSubTrigger, ContextMenuTrigger, Contribute, CopyButton, DecodeText, Dialog, DialogContent,
  DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger, DisclosureCaret, DropdownMenu, DropdownMenuContent,
  DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger, EmptyState, ErrorState, FadeScroll, GlyphSpinner, Input, KanbanCardBadges, Kbd,
  KbdGroup, ListRow, Loader, LocalizedTabTitle, LogView, MessageTextContent, ModelCatalogMenu, PanelAction, PanelAddButton,
  PanelBlock, PanelBody, PanelDetail, PanelEmpty, PanelHeader, PanelList, PanelListRow, PanelMeta, PanelPill, PanelRowMenu,
  PanelSectionLabel, Popover, PopoverContent, PopoverTrigger, RowButton, SandboxedFrame, ScrollArea, SearchField, SegmentedControl,
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue, Separator, SessionStatusDot, SidebarRowLead, Skeleton, StatusDot,
  Streamdown, Switch, Tabs, TabsList, TabsTrigger, Textarea, Tip, ToggleRow, ToolsetConfigPanel, Tooltip, TooltipContent,
  TooltipProvider, TooltipTrigger, Wordmark, WorkspacePageHeaderControl
} = C
/** `icons.RefreshCw` y cualquier otro icono: componente `<div data-sdk="icons.<Nombre>">`. */
export const icons = new Proxy({}, { get: (obj, n) => (typeof n === 'symbol' ? undefined : (obj[n] ??= componente(`icons.${n}`))) })
export const ModelMenuCloseContext = { Provider: componente('ModelMenuCloseContext.Provider'), displayName: 'ModelMenuCloseContext' }

// ---- áreas (valores reales del SDK) y constantes ----
export const ROUTES_AREA = 'routes'
export const SIDEBAR_NAV_AREA = 'sidebar.nav'
export const PALETTE_AREA = 'palette'
export const PANES_AREA = 'panes'
export const STATUSBAR_AREAS = { left: 'statusBar.left', right: 'statusBar.right' }
export const TITLEBAR_AREAS = { center: 'titleBar.center', left: 'titleBar.left', right: 'titleBar.right' }
export const KANBAN_CARD_AREAS = { badges: 'kanban.card.badges' }
export const KANBAN_CARD_BADGE_HUES = ['red', 'orange', 'yellow', 'lime', 'green', 'mint', 'cyan', 'sky', 'blue', 'violet', 'magenta', 'pink']
export const KANBAN_CARD_BADGE_LIMITS = { labelChars: 24, perPlugin: 2, tooltipChars: 160 }
export const TOOL_MEDIA_RENDERER_AREA = 'transcript.toolMedia'
export const APPEARANCE_AREAS = { extra: 'appearance.extra' }
export const COMPOSER_AREAS = {
  top: 'composer.top', bottom: 'composer.bottom', underside: 'composer.underside', leading: 'composer.leading',
  actions: 'composer.actions', middleware: 'composer.middleware', attachments: 'composer.attachments', microActions: 'composer.microActions'
}
export const SESSION_ROW_AREAS = { leading: 'sessionRow.leading', trailing: 'sessionRow.trailing' }
export const CHAT_EMPTY_AREA = 'chat.empty'
export const KEYBINDS_AREA = 'keybinds'
export const MODEL_MENU_ROW_AREA = 'modelMenu.row'
export const SETTINGS_PLUGINS_AREA = 'settings.plugins'
export const SIDEBAR_NAV_PREFS_AREA = 'sidebarNav.prefs'
export const SIDEBAR_PROFILE_GROUP_HEADER_AREA = 'sidebar.profileGroup.header'
export const THEMES_AREA = 'themes'
export const TRANSCRIPT_DIRECTIVE_AREA = 'transcript.directives'
export const WORKSPACE_PAGE_HEADER_AREA = 'workspace.pageHeader'
export const PLUGIN_APP_ACTIONS = []
export const PROFILE_SWATCHES = []
export const SIDEBAR_ROW_LEAD = ''
export const SIDEBAR_TRUNCATED_LEADING = ''
export const DEFAULT_REASONING_EFFORT = 'medium'
export const REASONING_EFFORTS = ['low', 'medium', 'high']
export const REASONING_EFFORT_VALUES = REASONING_EFFORTS
export const APPROVAL_RESPOND_TIMEOUT_MS = 30_000
export const DEFAULT_SESSION_HYDRATION_TIMEOUT_MS = 20_000
export const BOT_CHAT_SESSION_HYDRATION_TIMEOUT_MS = 60_000
export const HYDRATION_SYNC_BADGE_TIMEOUT_MS = 30_000

// ---- nanostores mínimos ----
export const atom = inicial => {
  let valor = inicial
  const oyentes = new Set()
  return {
    get: () => valor,
    set(v) {
      valor = v
      for (const f of oyentes) f(v)
    },
    listen: f => (oyentes.add(f), () => oyentes.delete(f)),
    subscribe: f => (oyentes.add(f), f(valor), () => oyentes.delete(f))
  }
}
export const computed = (fuentes, fn) => {
  const lista = Array.isArray(fuentes) ? fuentes : [fuentes]
  return { get: () => fn(...lista.map(a => a.get())), listen: () => () => {}, subscribe: () => () => {} }
}
export const useValue = a => a.get()
export const $accentOverride = atom(null)

// ---- host: navigate, request y composer explícitos; cualquier otro verbo apunta su llamada ----
export const host = espacio('host', {
  navigate: ruta => (anota('host.navigate', [ruta]), estado.navegaciones.push(ruta), undefined),
  request: registra('host.request', async () => undefined),
  composer: espacio('host.composer', {
    getDraft: registra('host.composer.getDraft', async () => null),
    setDraft: registra('host.composer.setDraft', async () => true),
    insertText: registra('host.composer.insertText', async () => true),
    submit: registra('host.composer.submit', () => true),
    focus: registra('host.composer.focus')
  }),
  state: espacio('host.state', {
    activeSessionId: atom(null), busy: atom(false), cwd: atom(''), focusedSessionId: atom(null), connectionId: atom(null)
  }),
  settings: espacio('host.settings'),
  sessions: espacio('host.sessions'),
  skills: espacio('host.skills'),
  toolsets: espacio('host.toolsets'),
  profiles: espacio('host.profiles'),
  pluginDecisions: espacio('host.pluginDecisions'),
  i18n: espacio('host.i18n')
})

// ---- react-query ----
export const queryClient = espacio('queryClient', {
  invalidateQueries: filtro => (estado.invalidadas.push(filtro), Promise.resolve())
})
export const useQueryClient = () => queryClient
/** Responde con `estado.datos[<ruta>]` (la ruta es el 2.º elemento de la queryKey); sin dato, `data` queda undefined. */
export const useQuery = opciones => {
  estado.consultas.push(opciones)
  return { data: estado.datos[opciones.queryKey?.[1]], isLoading: false, error: null, refetch: async () => undefined }
}
export const useMutation = opciones => {
  const mutateAsync = async v => opciones?.mutationFn?.(v)
  return { mutate: v => void mutateAsync(v).catch(() => {}), mutateAsync, isPending: false, error: null }
}

// ---- hooks y utilidades (deterministas: sin reloj ni locale de la máquina) ----
export const cn = (...clases) => clases.flat(Infinity).filter(Boolean).join(' ')
export const useTheme = () => ({ theme: { name: 'falso' }, mode: 'dark', setTheme: registra('useTheme.setTheme'), setMode: registra('useTheme.setMode') })
export const useI18n = () => ({ t: clave => clave, locale: 'es' })
export const usePluginI18n = useI18n
export const translateNow = clave => (typeof clave === 'function' ? '' : clave)
export const useGrabScroll = () => ({ ref: { current: null }, grabbing: false })
export const compactNumber = n => String(n)
export const fmtDateTime = d => new Date(d).toISOString()
export const fmtDayTime = fmtDateTime
export const formatAgo = d => `ago:${new Date(d).toISOString()}`
export const coarseElapsed = ms => `${Math.round(ms / 1000)}s`
export const relativeTime = d => `rel:${new Date(d).toISOString()}`
export const isSubmitEnter = e => e?.key === 'Enter' && !e?.shiftKey && !e?.isComposing
export const formatModifierToken = t => t
export const nextRunOverdueMs = () => null
export const reasoningEffortLabel = e => e
export const profileColor = () => 'var(--accent)'
export const profileColorSoft = profileColor
export const normalizeHex = h => h
export const contrastRatio = () => null
export const pluginSettingsHref = id => `/settings/plugins/${id}`
export const blobatarSvg = () => '<svg></svg>'
export class LruCache extends Map {}
export const createBudgetedLoop = registra('createBudgetedLoop', () => ({ start() {}, stop() {}, dispose() {} }))

export const ackStoredSessionId = registra('ackStoredSessionId')
export const captureGatewayFileDownload = registra('captureGatewayFileDownload')
export const catalogProviderMatches = registra('catalogProviderMatches', () => false)
export const evaluateRuntimeReadiness = registra('evaluateRuntimeReadiness', () => ({ ready: true }))
export const forgetSessionUnread = registra('forgetSessionUnread')
export const gatewayActivationEpoch = registra('gatewayActivationEpoch', () => 0)
export const haptic = registra('haptic')
export const hexToOklch = registra('hexToOklch')
export const hueDelta = registra('hueDelta', () => 0)
export const markSessionUnreadFinished = registra('markSessionUnreadFinished')
export const maxChroma = registra('maxChroma', () => 0)
export const mixOklab = registra('mixOklab')
export const oklchToHex = registra('oklchToHex')
export const oklchToSrgb255 = registra('oklchToSrgb255')
export const readableOn = registra('readableOn')
export const requestTheme = registra('requestTheme')
export const resolveSiblingWsUrl = registra('resolveSiblingWsUrl', () => null)
export const retintTheme = registra('retintTheme')
export const setAccentOverride = registra('setAccentOverride')
export const surfaceModelSwitchConfirm = registra('surfaceModelSwitchConfirm', async () => ({ confirmed: false }))
export const themeHue = registra('themeHue', () => 0)

/**
 * ctx de plugin falso, para `register(ctx)` y `fijarCtx(ctx)`. Cada puerta apunta su llamada en `llamadas`:
 * - `rest(ruta, opciones)` responde con `datos[ruta]` (Error → rechaza; función → la llama con `opciones`).
 * - `socket(ruta, alMensaje)` guarda el receptor en `sockets[ruta]`; la función de baja apunta `ctx.socket.cerrar`.
 * - `storage` en memoria (propio de cada ctx); `os.*` y `runAction` apuntan y devuelven lo que devolvería Hermes.
 * - `register`/`registerMany` guardan en `contribuciones`.
 */
export function ctxFalso() {
  const almacen = new Map()
  return {
    source: 'falso',
    rest: async (ruta, opciones) => {
      anota('ctx.rest', [ruta, opciones])
      const r = estado.datos[ruta]
      if (r instanceof Error) throw r
      return typeof r === 'function' ? r(opciones) : r
    },
    socket: (ruta, alMensaje) => {
      anota('ctx.socket', [ruta])
      estado.sockets[ruta] = alMensaje
      return () => (anota('ctx.socket.cerrar', [ruta]), delete estado.sockets[ruta], undefined)
    },
    storage: {
      get: (clave, porDefecto) => (anota('ctx.storage.get', [clave]), almacen.has(clave) ? almacen.get(clave) : porDefecto),
      set: (clave, valor) => (anota('ctx.storage.set', [clave, valor]), almacen.set(clave, valor), undefined),
      remove: clave => (anota('ctx.storage.remove', [clave]), almacen.delete(clave), undefined)
    },
    os: {
      notify: registra('ctx.os.notify'),
      openExternal: registra('ctx.os.openExternal', async () => true),
      revealPath: registra('ctx.os.revealPath', async () => true),
      pickSavePath: registra('ctx.os.pickSavePath', async () => null),
      pickOpenPath: registra('ctx.os.pickOpenPath', async () => null),
      writeClipboard: registra('ctx.os.writeClipboard', async () => true)
    },
    runAction: registra('ctx.runAction', () => ({ ok: true })),
    listActions: () => [],
    register: c => (estado.contribuciones.push(c), () => {}),
    registerMany: cs => (estado.contribuciones.push(...cs), () => {}),
    registerSettingsPage: () => () => {},
    onDispose: () => {},
    onEvent: () => () => {},
    setTimeout: () => () => {},
    setInterval: () => () => {},
    addEventListener: () => () => {},
    i18n: { register: () => {}, t: clave => clave },
    pet: { say: () => () => {}, clear: () => {}, visible: atom(false) }
  }
}
