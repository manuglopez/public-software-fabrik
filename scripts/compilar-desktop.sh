#!/usr/bin/env bash
# Compila la app de escritorio de Hermes con los parches de fabrik (patches/) en release-fabrik/,
# haciendo hueco antes para no congelar la máquina (ya pasó 2 veces con 8 agentes + Hindsight):
#   1) pausa Hindsight (fabrica-memoria, ~3,5 GB) y baja kanban.max_in_progress a 4 (no entran agentes nuevos)
#   2) espera hasta 20 min a que queden ≤4 agentes en marcha
#   3) compila con prioridad baja; 4) restaura todo y avisa por Telegram al privado.
# Uso: compilar-desktop.sh   (programado con systemd-run --on-calendar)
set -uo pipefail
[[ -f "$HOME/.config/fabrica/avisos.env" ]] && . "$HOME/.config/fabrica/avisos.env"
. "$HOME/Code/software-fabrik/config/agent-shell.sh" 2>/dev/null || true
LOG="$HOME/.hermes/factory/logs/compilar-desktop.log"; exec >>"$LOG" 2>&1
D="$HOME/.hermes/hermes-agent/apps/desktop"; CFG="$HOME/.hermes/config.yaml"
AVISO="${FABRIK_AVISO:-telegram}"   # destino privado (p. ej. telegram:<tu_id>) en ~/.config/fabrica/avisos.env
log(){ echo "$(date '+%F %T') $*"; }
corriendo(){ local n=0; for db in "$HOME"/.hermes/kanban/boards/*/kanban.db; do n=$((n + $(sqlite3 "$db" "select count(*) from tasks where status='running'"))); done; echo $n; }
restaurar(){ sed -i 's/^  max_in_progress: 4$/  max_in_progress: 8/' "$CFG"; systemctl --user start fabrica-memoria; log "restaurado (8 agentes, Hindsight en marcha)"; }
trap restaurar EXIT

log "== inicio"; sed -i 's/^  max_in_progress: 8$/  max_in_progress: 4/' "$CFG"
systemctl --user stop fabrica-memoria; log "Hindsight pausado, límite 4"
for i in $(seq 1 40); do n=$(corriendo); [[ $n -le 4 ]] && break; log "esperando: $n agentes en marcha"; sleep 30; done
log "compilando con $(corriendo) agentes en marcha · $(free -g | awk '/Mem/{print $7}') GB libres"
rm -rf "$D/release-fabrik"; cd "$D"
if nice -n 19 ionice -c3 sh -c 'npm run build && npm run builder -- --dir --publish never -c.directories.output=release-fabrik' && [[ -x "$D/release-fabrik/linux-unpacked/Hermes" ]]; then
  log "OK"; hermes send -t "$AVISO" "🏭 App de Hermes compilada (proyecto en el título de los avisos + 20 s). Para instalarla: cierra Hermes y ejecuta ~/Code/software-fabrik/bin/fabrik-desktop-actualizar" >/dev/null 2>&1
else
  log "FALLO"; hermes send -t "$AVISO" "⚠️ La compilación de la app de Hermes ha fallado. Log: ~/.hermes/factory/logs/compilar-desktop.log" >/dev/null 2>&1
fi
