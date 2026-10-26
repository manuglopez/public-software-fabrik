"""The Factory — paquete unificado de Hermes.

La mitad de escritorio vive en `desktop/` (fuentes en `desktop/src`, `desktop/plugin.js` generado por
`scripts/plugin-desktop.sh build`) y el backend en `dashboard/` (router montado en `/api/plugins/fabrica/`).
Ninguna de las dos registra herramientas, hooks ni middleware del agente; la skill `/fabrica` se enlaza
aparte con `install.sh`.
"""


def register(ctx) -> None:
    """Registro vacío para la sonda de capacidades."""
    return None
