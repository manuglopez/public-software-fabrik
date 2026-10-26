// Logo de The Factory (copiado de docs/mockups/panel-fabrica-v2.html): trazos con var(--accent) y currentColor.
import { jsx, jsxs } from 'react/jsx-runtime'

export function Logo({ size = 26 }) {
  return jsxs('svg', {
    className: 'shrink-0',
    viewBox: '0 0 32 32',
    width: size,
    height: size,
    'aria-label': 'The Factory',
    children: [
      jsx('path', {
        d: 'M3 28V14l7 4v-4l7 4v-4l7 4V5h5v23z',
        fill: 'none',
        stroke: 'var(--accent)',
        strokeWidth: 2,
        strokeLinejoin: 'round'
      }),
      jsx('path', {
        d: 'M11 21.5l-2.5 2.5 2.5 2.5M19 21.5l2.5 2.5-2.5 2.5M16.6 20.5l-2.2 7',
        fill: 'none',
        stroke: 'currentColor',
        strokeWidth: 1.6,
        strokeLinecap: 'round',
        strokeLinejoin: 'round'
      })
    ]
  })
}
