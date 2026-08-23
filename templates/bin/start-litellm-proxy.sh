#!/usr/bin/env bash
# start-litellm-proxy.sh
# Classic-mode template, copied into $BIN_DIR by install.sh (install.d/40-
# litellm-and-services.sh). Reads port/packaging/container/config from
# ~/.config/claude-local-setup.conf at runtime. Starts the LiteLLM proxy on
# demand (nohup + log file), unless it's already healthy. Only the proxy is
# started - llama-server stays a separate, manual step, exactly as before.

set -uo pipefail

CONF_FILE="$HOME/.config/claude-local-setup.conf"

PROXY_PORT="4000"
PROXY_MASTER_KEY="sk-local-dev-key"
PROXY_LOG_FILE="$HOME/.local/state/litellm-proxy.log"
PACKAGING="distrobox"
CONTAINER_NAME="ollama-box"
CONFIG_HOME="$HOME"

if [ -f "$CONF_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  PROXY_PORT="${PROXY_PORT:-4000}"
  PROXY_MASTER_KEY="${PROXY_MASTER_KEY:-sk-local-dev-key}"
  PROXY_LOG_FILE="${PROXY_LOG_FILE:-$HOME/.local/state/litellm-proxy.log}"
  PACKAGING="${PACKAGING:-distrobox}"
  CONTAINER_NAME="${CONTAINER_NAME:-ollama-box}"
  CONFIG_HOME="${CONFIG_HOME:-$HOME}"
fi
CONFIG_DEST="$CONFIG_HOME/litellm_config.yaml"

mkdir -p "$(dirname "$PROXY_LOG_FILE")"

if curl -s -o /dev/null "http://localhost:$PROXY_PORT/health"; then
  echo "litellm proxy is already running at http://localhost:$PROXY_PORT - not starting a second one."
  exit 0
fi

if [ "$PACKAGING" = "distrobox" ]; then
  START_CMD="distrobox enter \"$CONTAINER_NAME\" -- bash -lc \"exec litellm --config $CONFIG_DEST --port $PROXY_PORT\""
else
  START_CMD="litellm --config $CONFIG_DEST --port $PROXY_PORT"
fi

echo "Starting litellm proxy on port $PROXY_PORT (log: $PROXY_LOG_FILE)..."
nohup bash -lc "$START_CMD" >> "$PROXY_LOG_FILE" 2>&1 &
disown

# Wait for it to come up before claiming success.
for i in $(seq 1 10); do
  if curl -s -o /dev/null -H "Authorization: Bearer $PROXY_MASTER_KEY" "http://localhost:$PROXY_PORT/health" | grep -q "200"; then
    echo "litellm proxy is up at http://localhost:$PROXY_PORT"
    exit 0
  fi
  sleep 1
done
echo "WARNING: proxy did not respond at http://localhost:$PROXY_PORT/health after 10s." >&2
echo "Check $PROXY_LOG_FILE (or run install.sh again with verbose proxy logging on)." >&2
exit 1