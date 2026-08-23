#!/usr/bin/env bash
# start-local-model-desktop.sh
# Kilo-mode template, copied into $BIN_DIR by install.sh (install.d/80-
# launcher.sh). Double-click target for the "Start Local Model (Kilo)"
# desktop icon: opens start-local-model.sh in its own terminal window
# (konsole/gnome-terminal/xterm fallback), so the menu, the server's own log
# output, and the sync summary are visible.

set -uo pipefail

CONF_FILE="$HOME/.config/claude-local-setup.conf"
BIN_DIR="$HOME/.local/bin"
if [ -f "$CONF_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
fi

TERMINAL_CMD=""
if command -v konsole >/dev/null 2>&1; then
  TERMINAL_CMD="konsole -e"
elif command -v gnome-terminal >/dev/null 2>&1; then
  TERMINAL_CMD="gnome-terminal --"
elif command -v xterm >/dev/null 2>&1; then
  TERMINAL_CMD="xterm -e"
fi

if [ -z "$TERMINAL_CMD" ]; then
  notify-send -u critical "Local model: no terminal emulator found" \
    "Paste this into a terminal yourself: $BIN_DIR/start-local-model.sh"
  exit 1
fi

"$TERMINAL_CMD" bash -c "$BIN_DIR/start-local-model.sh; echo; read -rp 'Press Enter to close this window. ' _"