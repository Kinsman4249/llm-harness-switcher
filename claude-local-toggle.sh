#!/usr/bin/env bash
# claude-local-toggle.sh
# On/off switch for routing Claude Code (CLI and VS Code/VSCodium extension)
# through the local-only LiteLLM proxy instead of your normal Pro
# subscription auth.
#
# ON:  edits ~/.claude/settings.json to add the proxy env block. Every
#      Claude Code request, main session and sub-agents, goes to local Qwen.
#      No API key involved anywhere, nothing bills. Sonnet/Opus are not
#      available while this is on, use it for small tasks only.
# OFF: removes that env block. Claude Code goes back to fully normal
#      behavior, Pro subscription auth, Sonnet/Opus available, as if this
#      setup didn't exist.
#
# Usage:
#   ./claude-local-toggle.sh on
#   ./claude-local-toggle.sh on --force   # turn on even if llama-server isn't reachable
#   ./claude-local-toggle.sh off
#   ./claude-local-toggle.sh status
#
# "on" refuses to flip the switch unless llama-server itself (not just the
# LiteLLM proxy) is actually answering, since the proxy is only around because
# YOU started it (it's on-demand now, not a systemd unit) and it will happily
# report itself healthy while pointed at a backend nobody started yet. So "on"
# first starts the proxy on demand (via start-litellm-proxy.sh) if it isn't
# up, THEN health-checks llama-server. --force skips the llama-server check,
# for deliberately testing the clean-failure path (see README's Manual
# verification section).
#
# After toggling, reload the VS Code/VSCodium window (Ctrl+Shift+P >
# "Reload Window") so the extension re-reads settings.json. The extension
# does not pick up changes to this file live.

set -euo pipefail

SETTINGS_FILE="$HOME/.claude/settings.json"
BACKUP_FILE="$HOME/.claude/settings.json.pre-local-toggle.bak"
PROXY_URL="http://localhost:4000"
PROXY_TOKEN="sk-local-dev-key"   # must match master_key in litellm_config.yaml
LLAMA_URL="http://localhost:8080"   # must match the port start-local-llama.sh serves on
BIN_DIR="$HOME/.local/bin"

ACTION="${1:-}"
FORCE="${2:-}"

mkdir -p "$(dirname "$SETTINGS_FILE")"
[ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"

case "$ACTION" in
  on)
    # Proxy is on-demand: start it if it isn't already healthy, BEFORE the
    # llama-server check (the old flow assumed a systemd proxy that was
    # always up; that assumption is gone).
    if ! curl -s -o /dev/null -H "Authorization: Bearer $PROXY_TOKEN" "$PROXY_URL/health" | grep -q "200"; then
      echo "LiteLLM proxy isn't running - starting it on demand..."
      if [ -x "$BIN_DIR/start-litellm-proxy.sh" ]; then
        "$BIN_DIR/start-litellm-proxy.sh" || {
          echo "ERROR: failed to start the LiteLLM proxy." >&2
          [ "$FORCE" != "--force" ] && { echo "Not touching settings.json." >&2; exit 1; }
          echo "(--force given, continuing anyway - Claude Code will fail until the proxy is up.)" >&2
        }
      else
        echo "WARNING: $BIN_DIR/start-litellm-proxy.sh not found (install not run, or BIN_DIR moved)." >&2
      fi
    fi

    if [ "$FORCE" != "--force" ] && ! curl -s -o /dev/null -w "%{http_code}" "$LLAMA_URL/health" | grep -q "200"; then
      echo "ERROR: llama-server isn't responding at $LLAMA_URL." >&2
      echo "Start it first: $BIN_DIR/start-local-llama.sh" >&2
      echo "Not touching settings.json. Re-run with 'on --force' to switch on anyway" >&2
      echo "(useful only for deliberately testing the clean-failure path)." >&2
      exit 1
    fi

    if ! curl -s -o /dev/null -H "Authorization: Bearer $PROXY_TOKEN" "$PROXY_URL/health" | grep -q "200"; then
      echo "Warning: proxy not responding at $PROXY_URL." >&2
      echo "Check: $BIN_DIR/start-litellm-proxy.sh (or the proxy log)" >&2
      if [ "$FORCE" != "--force" ]; then
        echo "Not touching settings.json. Re-run with 'on --force' to switch on anyway." >&2
        exit 1
      fi
      echo "Turning local mode on anyway (--force), but Claude Code will fail until the proxy is up." >&2
    fi

    # Back up whatever's there now, once, so "off" can always get back to a
    # known-good state even if this script is run repeatedly.
    if [ ! -f "$BACKUP_FILE" ]; then
      cp "$SETTINGS_FILE" "$BACKUP_FILE"
    fi

    python3 - "$SETTINGS_FILE" "$PROXY_URL" "$PROXY_TOKEN" << 'PYEOF'
import json, sys
path, proxy_url, proxy_token = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
data["env"] = {
    "ANTHROPIC_BASE_URL": proxy_url,
    "ANTHROPIC_AUTH_TOKEN": proxy_token,
    "ANTHROPIC_API_KEY": ""
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

    echo "Local mode ON. Reload the VS Code/VSCodium window to apply."
    echo "Reminder: Sonnet/Opus are not reachable until you switch this off."
    ;;

  off)
    python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data.pop("env", None)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

    echo "Local mode OFF. Reload the VS Code/VSCodium window to apply."
    echo "Claude Code is back on normal Pro subscription auth."

    # The proxy is on-demand: stop it once nobody's using it.
    if [ -x "$BIN_DIR/stop-litellm-proxy.sh" ]; then
      echo "Stopping the on-demand LiteLLM proxy..."
      "$BIN_DIR/stop-litellm-proxy.sh"
    fi
    ;;

  status)
    python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
env = data.get("env", {})
if env.get("ANTHROPIC_BASE_URL"):
    print(f"Local mode is ON, pointed at {env['ANTHROPIC_BASE_URL']}")
else:
    print("Local mode is OFF, using normal Pro subscription auth.")
PYEOF
    if curl -s -o /dev/null -w "%{http_code}" "$LLAMA_URL/health" | grep -q "200"; then
      echo "llama-server: reachable at $LLAMA_URL"
    else
      echo "llama-server: NOT reachable at $LLAMA_URL (start-local-llama.sh not running?)"
    fi
    ;;

  *)
    echo "Usage: $0 {on|off|status}" >&2
    exit 1
    ;;
esac
