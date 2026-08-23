# 80-launcher-verify.sh
# Sourced by install.sh. Step 10-11 (verify half): launch_and_verify() walks
# a classic-mode user through launching llama-server and smoke-tests the proxy
# end to end; launch_and_verify_kilo() runs the kilo start-local-model.sh with
# --profile as the install-time end-to-end test; run_launcher_step() is the
# wrapper that dispatches on install mode and reproduces the original single
# big "if LLAMA_SERVER_BIN and LLAMA_MODEL_PATH are both set" guard. The
# generated-script half (build_start_script) lives in 80-launcher-build.sh
# and the desktop-icon half (build_desktop_launcher, build_kilo_launcher) in
# 80-launcher-desktop.sh.

launch_and_verify() {
  echo
  echo "llama-server is ready to launch, but not started automatically."
  echo "Open another terminal and run this (the wrapper script does the same thing,"
  echo "printed here in full so you don't have to go find it):"
  echo
  echo "  distrobox enter \"$CONTAINER_NAME\" -- \"$LLAMA_SERVER_BIN\" \\"
  echo "    -m \"$LLAMA_MODEL_PATH\"$NGL_FLAG \\"
  echo "    -c $LLAMA_CTX_SIZE -b $LLAMA_BATCH_SIZE -n $LLAMA_N_PREDICT \\"
  echo "    -fa on --cache-type-k $CACHE_TYPE_K --cache-type-v $CACHE_TYPE_V \\"
  echo "    $FIT_FLAG \\"
  echo "    --no-webui \\"
  echo "    --port $LLAMA_PORT --host 127.0.0.1$EXTRA_FLAGS"
  echo
  echo "Or just: $BIN_DIR/start-local-llama.sh"
  echo "(add LLAMA_ENABLE_WEBUI=yes before that to also enable llama.cpp's own"
  echo "browser chat UI at http://127.0.0.1:$LLAMA_PORT - same server, same model,"
  echo "just serves the extra static UI alongside the API)"
  echo "Or use the 'Start Local Model' desktop icon (if installed) to open this"
  echo "in its own terminal window automatically from now on."
  read -rp "Press Enter here once it's running (or Ctrl+C to skip this check)... " _

  if curl -s -o /dev/null "http://localhost:$LLAMA_PORT/health"; then
    echo "llama-server is up at http://localhost:$LLAMA_PORT"
    if command -v nvidia-smi >/dev/null 2>&1; then
      echo "VRAM after loading:"
      nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
    fi

    if [ "$KV_MODEL" = "probe" ]; then
      echo
      echo "KV_MODEL=probe for this profile: the real context size llama.cpp"
      echo "fit (--fit on) should be in its own log. Grepping for it now - this"
      echo "pattern (n_ctx) is a best-effort guess at llama.cpp's log format,"
      echo "NOT confirmed against a real run (see gemma4-support-spec.md"
      echo "section 5); if nothing useful prints below, check"
      echo "$HOME/.local/state/llama-server.log yourself for the actual figure."
      grep -i "n_ctx" "$HOME/.local/state/llama-server.log" 2>/dev/null || \
        echo "  (no n_ctx line found - check the log file directly)"
    fi

    # --- The LiteLLM proxy is on-demand now - make sure it's up before the
    # smoke test, which routes through it (this is what claude-local-toggle.sh
    # on also does).
    if [ -x "$BIN_DIR/start-litellm-proxy.sh" ]; then
      "$BIN_DIR/start-litellm-proxy.sh" || \
        echo "WARNING: could not start the LiteLLM proxy on demand." >&2
    else
      echo "WARNING: $BIN_DIR/start-litellm-proxy.sh not found - install.sh" >&2
      echo "didn't generate it, or BIN_DIR changed. The smoke test below will fail." >&2
    fi

    # --- Smoke test: a real completion through the PROXY, using the exact
    # model string Claude Code sends (see litellm_config.yaml), not just a
    # /health 200. /health only proves the process is listening; it does not
    # prove the model routing is correct or that a request actually returns
    # text - both of which have separately broken silently in the past.
    echo
    echo "Smoke-testing a real completion through the proxy (this is what Claude Code will see)..."
    local SMOKE_RESPONSE SMOKE_CONTENT
    SMOKE_RESPONSE="$(curl -s -X POST "http://localhost:$PROXY_PORT/v1/chat/completions" \
      -H "Authorization: Bearer $PROXY_MASTER_KEY" \
      -H "Content-Type: application/json" \
      -d '{"model":"claude-haiku-4-5-20251001","messages":[{"role":"user","content":"reply with the word: ok"}],"max_tokens":10}')"
    SMOKE_CONTENT="$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    msg = data['choices'][0]['message']
    print((msg.get('content') or msg.get('reasoning_content') or '').strip())
except Exception:
    sys.exit(1)
" "$SMOKE_RESPONSE" 2>/dev/null)"
    if [ -n "$SMOKE_CONTENT" ]; then
      echo "Smoke test OK - proxy returned real model output: \"$SMOKE_CONTENT\""
    else
      echo "WARNING: smoke test through the proxy did not return usable content." >&2
      echo "Raw response: $SMOKE_RESPONSE" >&2
      echo "Claude Code will likely hang or error in local mode until this is fixed." >&2
      echo "Check: $PROXY_LOG_FILE (proxy log) and verify llama-server is still up." >&2
    fi
  else
    echo "WARNING: llama-server did not respond at http://localhost:$LLAMA_PORT/health." >&2
    echo "Check the terminal window it's running in for the actual error." >&2
  fi
}

# Kilo mode's install-time test flow: launch the selected profile's model via
# the same generated start-local-model.sh the desktop icon uses (--profile
# skips the menu), which starts the runtime, waits on health, smoke-tests, and
# syncs the Kilo provider config. Nothing for the user to do - a papercut-free
# end-to-end run, same helpers as the icon.
launch_and_verify_kilo() {
  if [ ! -x "$BIN_DIR/start-local-model.sh" ]; then
    echo "Skipping kilo launch+sync: $BIN_DIR/start-local-model.sh wasn't generated." >&2
    echo "Re-run install.sh once the runtime and model are ready." >&2
    return
  fi
  echo "Launching $PROFILE_NAME ($MODEL_PROFILE) and syncing the Kilo provider..."
  "$BIN_DIR/start-local-model.sh" --profile "$MODEL_PROFILE"
}

# Orchestrates the launcher step, dispatching on install mode. Classic mode
# generates the llama.cpp start script + desktop icon + OpenHands/browser-webui
# offers, then smoke-tests through the on-demand proxy. Kilo mode generates
# start-local-model.sh + its desktop icon, then runs the same script with
# --profile to start/test/sync the selected model end to end.
run_launcher_step() {
  if [ "$INSTALL_MODE" = "kilo" ]; then
    build_kilo_launcher
    if [ "$INSTALL_DESKTOP_SHORTCUT" != "yes" ]; then
      echo "Note: no desktop icon requested - the launcher is at"
      echo "  $BIN_DIR/start-local-model.sh (double-click wrapper skipped)."
    fi
    launch_and_verify_kilo
    return
  fi

  # classic
  if [ -n "$LLAMA_SERVER_BIN" ] && [ -n "$LLAMA_MODEL_PATH" ]; then
    build_start_script
    build_desktop_launcher
    launch_and_verify
  else
    echo "Skipping start-local-llama.sh generation: missing llama-server binary or model path."
    echo "Re-run install.sh once both the build and the download have succeeded."
  fi
}