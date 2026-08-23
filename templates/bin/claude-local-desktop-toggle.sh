#!/usr/bin/env bash
# claude-local-desktop-toggle.sh
# Wrapper around claude-local-toggle.sh for double-clicking from the
# desktop. Flips whatever state you're currently in and confirms with a
# notification, since a desktop icon has no terminal to print to.
#
# Not using 'set -e' here on purpose: claude-local-toggle.sh's "on" now
# deliberately exits non-zero when llama-server isn't reachable, and that
# failure needs to reach notify-send, not just kill this script silently
# with no terminal around to show why.

set -uo pipefail

TOGGLE_SCRIPT="$HOME/.local/bin/claude-local-toggle.sh"
# If you installed the toggle script somewhere else, change the path above
# to match. install.sh's default is ~/.local/bin.

if [ ! -x "$TOGGLE_SCRIPT" ]; then
  notify-send -u critical "Claude local toggle" "Script not found at $TOGGLE_SCRIPT"
  exit 1
fi

CURRENT="$("$TOGGLE_SCRIPT" status)"

if echo "$CURRENT" | grep -q "ON"; then
  "$TOGGLE_SCRIPT" off
  notify-send "Claude Code: local mode OFF" "Back on Pro subscription; proxy stopped. Reload the VS Code/VSCodium window."
else
  ON_ERR="$("$TOGGLE_SCRIPT" on 2>&1 >/dev/null)"
  if [ $? -eq 0 ]; then
    notify-send "Claude Code: local mode ON" "Routing through the local model. Sonnet/Opus unavailable. Reload the VS Code/VSCodium window."
  else
    # Show the toggle script's own first error line instead of guessing which
    # of its checks (llama-server vs. the LiteLLM proxy) actually failed.
    REASON="$(echo "$ON_ERR" | head -n1)"
    notify-send -u critical "Claude Code: local mode NOT switched on" "$REASON"
  fi
fi
