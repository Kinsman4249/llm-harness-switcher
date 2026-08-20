# 85-kilo-sync.sh
# Sourced by install.sh. Kilo mode only. Installs $BIN_DIR/sync-local-model.sh
# - the script that rewrites the single Kilo Code provider ("local-model") to
# point at whatever local model/runtime is currently running - and provides
# the install-time immediate sync (sync_local_model_now) used after a
# successful start/test during install.
#
# The script itself is a checked-in template (sync-local-model.sh in this
# repo) that reads its defaults from CONF_FILE at runtime - no heredoc
# generation, so there is nothing to escape and no generated malformed code.
# It follows runpod-helper's sync-runpod-endpoint.sh pattern: find-or-create
# the kilo config, write via a temp file + atomic mv, chmod --reference
# fallback 0600, trap cleanup, and a jq filter that uses `//=` for
# fill-if-absent fields (a user's hand-edited provider name/npm survive) and
# `=` for always-refresh fields (baseURL, apiKey, and the whole model map -
# that last one is what makes the provider always have exactly the current
# model as the only option).

# --- Which kilo config file do we write? ---
# Running inside vscodium-box, $HOME is the box's bind-mounted private home,
# so this is the config Kilo Code actually reads there.
detect_kilo_config() {
  if [ -f "$HOME/.config/kilo/kilo.json" ]; then
    KILO_CONFIG="$HOME/.config/kilo/kilo.json"
  elif [ -f "$HOME/.config/kilo/kilo.jsonc" ]; then
    KILO_CONFIG="$HOME/.config/kilo/kilo.jsonc"
  else
    KILO_CONFIG="$HOME/.config/kilo/kilo.jsonc"
  fi
  log "Kilo config target: $KILO_CONFIG"
}

# --- Install $BIN_DIR/sync-local-model.sh (copy of the tracked template) ---
generate_kilo_sync_script() {
  if [ "$INSTALL_MODE" != "kilo" ]; then
    log "Skipping kilo sync script installation (mode is $INSTALL_MODE)"
    return
  fi
  mkdir -p "$BIN_DIR"
  cp "$SCRIPT_DIR/sync-local-model.sh" "$BIN_DIR/sync-local-model.sh"
  chmod +x "$BIN_DIR/sync-local-model.sh"
  # Comment-preserving JSONC editor the sync script calls at runtime (kept
  # next to the script in $BIN_DIR; resolves the config symlink to its
  # git-tracked target and replaces the single local-model provider).
  cp "$SCRIPT_DIR/kilo-jsonc-edit.py" "$BIN_DIR/kilo-jsonc-edit.py"
  chmod +x "$BIN_DIR/kilo-jsonc-edit.py"
  log "Installed $BIN_DIR/sync-local-model.sh + $BIN_DIR/kilo-jsonc-edit.py (from repo templates)"
}

# --- Install-time immediate sync, run after a successful start/test ---
# Called by 80-launcher.sh's kilo flow once the model is up and smoke-tested.
# Uses the same args start-local-model.sh passes on the desktop side.
sync_local_model_now() {
  local base_url="http://127.0.0.1:$RUNTIME_PORT/v1"
  local model_id="${KILO_MODEL_ID:-$MODEL_PROFILE}"
  local model_name="${KILO_MODEL_NAME:-$PROFILE_NAME}"
  local attach="no"
  if [ "$MODEL_RUNTIME" = "llama.cpp" ] && [ -n "${LLAMA_MMPROJ_PATH:-}" ]; then
    attach="yes"
  fi
  if [ -x "$BIN_DIR/sync-local-model.sh" ]; then
    "$BIN_DIR/sync-local-model.sh" \
      --base-url "$base_url" \
      --api-key "$KILO_API_KEY" \
      --model-id "$model_id" \
      --model-name "$model_name" \
      --context "$LLAMA_CTX_SIZE" \
      --output "$LLAMA_N_PREDICT" \
      --reasoning "$REASONING_MODE" \
      --effort "$REASONING_EFFORT" \
      --attachment "$attach"
  else
    echo "WARNING: $BIN_DIR/sync-local-model.sh missing - re-run install.sh." >&2
  fi
}