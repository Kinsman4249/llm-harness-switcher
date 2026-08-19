# 90-summary.sh
# Sourced by install.sh. Final "what to do next" message, printed regardless
# of whether the launcher step above actually ran. Mode-aware.

print_summary() {
  echo
  echo "== Done =="
  if [ "$INSTALL_MODE" = "kilo" ]; then
    echo "Kilo mode installed. Your single custom provider is '$KILO_PROVIDER'."
    echo
    echo "To run a local model and point the provider at it:"
    echo "  $BIN_DIR/start-local-model.sh"
    echo "  (or double-click the 'Start Local Model (Kilo)' desktop icon,"
    echo "   if you installed one - it opens the same script in a terminal.)"
    echo
    echo "The desktop flow: scan GGUFs / ollama models -> pick one -> start it ->"
    echo "smoke-test -> sync-local-model.sh rewrites the provider config to point"
    echo "at it. Every time you switch models, re-run start-local-model.sh (or"
    echo "use the icon again) to re-point the provider."
    echo
    echo "IMPORTANT: after the script syncs the provider, reload the VSCodium/"
    echo "Kilo Code window or restart Kilo so it re-reads the config (Kilo caches"
    echo "provider config on session start)."
    echo
    echo "Rationale for the sync approach: Kilo Code cannot query llama-server/"
    echo "ollama/vllm for context limit or reasoning capability, so they're baked"
    echo "into the provider entry - a stale context/output limit silently truncates"
    echo "or misjudges conversation length, so it's re-derived on every model change."
    echo "No systemd units or linger were installed - nothing starts at boot."
  else
    echo "Classic mode installed. LiteLLM proxy is on-demand (nothing auto-starts):"
    echo "  $BIN_DIR/start-litellm-proxy.sh   start the proxy when you need it"
    echo "  $BIN_DIR/stop-litellm-proxy.sh    stop it (kills litellm only, not the container)"
    echo
    echo "To switch Claude Code to local mode: $BIN_DIR/claude-local-toggle.sh on"
    if [ "$INSTALL_DESKTOP_SHORTCUT" = "yes" ]; then
      echo "Or just double-click the Claude Local Toggle icon on your desktop."
    fi
    echo "Then reload the VS Code/VSCodium window."
    echo "To start the model itself (not loaded by default):"
    echo "  $BIN_DIR/start-local-llama.sh"
    echo
    echo "Nothing was installed as a systemd unit and lingering is off - no"
    echo "proxy or model starts at boot. claude-local-toggle.sh on starts the"
    echo "proxy on demand before flipping the switch."
  fi
}