#!/usr/bin/env bash
# stop-litellm-proxy.sh
# Classic-mode template, copied into $BIN_DIR by install.sh (install.d/40-
# litellm-and-services.sh). Reads packaging/container from
# ~/.config/claude-local-setup.conf at runtime. Stops the on-demand LiteLLM
# proxy, killing only the litellm process - never distrobox stop on the
# container, so a running llama-server is left alone.

set -uo pipefail

CONF_FILE="$HOME/.config/claude-local-setup.conf"

PACKAGING="distrobox"
CONTAINER_NAME="ollama-box"

if [ -f "$CONF_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  PACKAGING="${PACKAGING:-distrobox}"
  CONTAINER_NAME="${CONTAINER_NAME:-ollama-box}"
fi

if [ "$PACKAGING" = "distrobox" ]; then
  STOP_CMD="distrobox enter \"$CONTAINER_NAME\" -- pkill -f \"litellm --config\""
else
  STOP_CMD="pkill -f \"litellm --config\""
fi

echo "Stopping litellm proxy (if running)..."
if eval "$STOP_CMD" 2>/dev/null; then
  echo "Stopped."
else
  echo "No litellm --config process was running."
fi