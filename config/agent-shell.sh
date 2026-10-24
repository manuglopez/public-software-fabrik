# Entorno de shell de los agentes de la fábrica (lo carga Hermes vía terminal.shell_init_files).
# Portátil: no lleva rutas personales fijas.
export FABRIK_HOME="${FABRIK_HOME:-$HOME/Code/software-fabrik}"
export FABRIK_DATA="${FABRIK_DATA:-$HOME/.hermes/factory}"

# Herramientas de la fábrica primero (factory-test, factory-prep, …)
case ":$PATH:" in *":$FABRIK_HOME/bin:"*) ;; *) PATH="$FABRIK_HOME/bin:$PATH" ;; esac

# Node de nvm (greptile CLI, npm de proyectos front) sin cargar nvm entero: la versión más alta instalada.
if [ -d "$HOME/.nvm/versions/node" ]; then
  _fx_node_bin="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
  [ -n "$_fx_node_bin" ] && case ":$PATH:" in *":$_fx_node_bin:"*) ;; *) PATH="$_fx_node_bin:$PATH" ;; esac
  unset _fx_node_bin
fi
export PATH

# GitHub por HTTPS con la sesión de `gh` (no depende del agente SSH del escritorio, que puede no firmar
# con la pantalla bloqueada). Solo afecta a las shells de los agentes.
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0="url.https://github.com/.insteadOf" GIT_CONFIG_VALUE_0="git@github.com:"
export GIT_CONFIG_KEY_1="credential.https://github.com.helper" GIT_CONFIG_VALUE_1=""
export GIT_CONFIG_KEY_2="credential.https://github.com.helper" GIT_CONFIG_VALUE_2="!gh auth git-credential"
export GIT_TERMINAL_PROMPT=0

# Los agentes nunca usan el paginador ni editores interactivos
export GIT_PAGER=cat PAGER=cat GIT_EDITOR=true EDITOR=true
