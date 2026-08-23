#!/usr/bin/env bash
# uninstall.sh
# Reverses what install.sh did, mode-aware. By default it asks what to remove
# (one prompt per group); flags skip the prompts:
#   --classic   remove the classic-mode artifacts (storage: litellm config,
#               on-demand proxy scripts, toggle, desktop icons, settings.json
#               restore, optional systemd units/reminder)
#   --kilo      remove the kilo-mode artifacts (the "local-model" provider
#               block from the Kilo config, sync-local-model.sh,
#               start-local-model.sh + its desktop entry + state dir)
#   --models    remove downloaded model files + runtime builds (per container
#               or native path)
#   --all       everything above, then delete $CONF_FILE too
#
# Always restores files install.sh backed up before overwriting them
# (*.pre-install.bak), regardless of mode, and always removes the generated
# desktop entries. Run from anywhere; it only reads $HOME/.config/
# claude-local-setup.conf, it doesn't need the repo clone.

set -uo pipefail

CONF_FILE="$HOME/.config/claude-local-setup.conf"

DO_CLASSIC="ask"
DO_KILO="ask"
DO_MODELS="ask"
DO_ALL=no

for arg in "$@"; do
  case "$arg" in
    --classic) DO_CLASSIC=yes ;;
    --kilo)    DO_KILO=yes ;;
    --models)  DO_MODELS=yes ;;
    --all)     DO_ALL=yes; DO_CLASSIC=yes; DO_KILO=yes; DO_MODELS=yes ;;
    -h|--help)
      echo "Usage: uninstall.sh [--classic] [--kilo] [--models] [--all]"
      echo "  No flags: interactive - one yes/no prompt per artifact group."
      echo "  --classic  remove classic (Claude Code + LiteLLM) artifacts"
      echo "  --kilo     remove kilo (Kilo Code provider + launcher) artifacts"
      echo "  --models   remove downloaded model files + runtime builds"
      echo "  --all      everything above, then delete the install config file"
      exit 0
      ;;
  esac
done

if [ ! -f "$CONF_FILE" ]; then
  echo "No $CONF_FILE found - install.sh doesn't appear to have run, nothing to undo."
  echo "(If you set it up by hand, there is no config or generated-script record to"
  echo "reverse, but the Kilo provider and desktop entries below can still be removed.)"
  CONF_EXISTS=no
else
  CONF_EXISTS=yes
  # shellcheck disable=SC1090
  source "$CONF_FILE"
fi

INSTALL_MODE="${INSTALL_MODE:-}"
PACKAGING="${PACKAGING:-distrobox}"
CONTAINER_NAME="${CONTAINER_NAME:-}"
CONFIG_HOME="${CONFIG_HOME:-$HOME}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DESKTOP_DIR="${DESKTOP_DIR:-$HOME/Desktop}"
INSTALL_DESKTOP_SHORTCUT="${INSTALL_DESKTOP_SHORTCUT:-no}"
MODEL_ROOT="${MODEL_ROOT:-$HOME/models}"
MODEL_RUNTIME="${MODEL_RUNTIME:-llama.cpp}"
KILO_PROVIDER="${KILO_PROVIDER:-local-model}"
KILO_STATE_DIR="${KILO_STATE_DIR:-$HOME/.local/state/llm-harness-switcher}"
GGUF_PATTERN="${GGUF_PATTERN:-}"

echo "== Reversing the local model harness install =="
echo

restore_or_remove() {
  local target="$1" bak="$1.pre-install.bak"
  if [ -f "$bak" ]; then
    mv -f "$bak" "$target"
    echo "Restored $target from its pre-install backup."
  elif [ -f "$target" ]; then
    rm -f "$target"
    echo "Removed $target (install.sh created it, nothing to restore)."
  fi
}

arm_yn() {
  # arm_yn VAR "question": if VAR=ask, read yes/no into DO; else use it as-is.
  local varname="$1" question="$2" ans
  if [ "${!varname}" = "ask" ]; then
    read -rp "$question [y/N]: " ans
    case "$ans" in
      [yY]|[yY][eE][sS]) eval "$varname=yes" ;;
      *) eval "$varname=no" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# Group A: classic artifacts
# ---------------------------------------------------------------------------
remove_classic() {
  echo
  echo "--- Classic (Claude Code + LiteLLM) artifacts ---"

  # systemd units, if a previous install (or the optional reminder) created
  # them. These are only ever touched when they exist.
  if systemctl --user list-unit-files litellm-ollama-box.service >/dev/null 2>&1; then
    systemctl --user disable --now litellm-ollama-box.service 2>/dev/null
  fi
  if systemctl --user list-unit-files distrobox-reminder.service >/dev/null 2>&1; then
    systemctl --user disable --now distrobox-reminder.service 2>/dev/null
  fi
  restore_or_remove "$HOME/.config/systemd/user/litellm-ollama-box.service"
  restore_or_remove "$HOME/.config/systemd/user/distrobox-reminder.service"
  systemctl --user daemon-reload 2>/dev/null || true

  # litellm config
  restore_or_remove "$CONFIG_HOME/litellm_config.yaml"

  # ~/.claude/settings.json - undo claude-local-toggle.sh's edits
  SETTINGS_FILE="$HOME/.claude/settings.json"
  TOGGLE_BACKUP="$HOME/.claude/settings.json.pre-local-toggle.bak"
  if [ -f "$TOGGLE_BACKUP" ]; then
    mv -f "$TOGGLE_BACKUP" "$SETTINGS_FILE"
    echo "Restored $SETTINGS_FILE to its state from before local mode was ever switched on."
  elif [ -f "$SETTINGS_FILE" ]; then
    echo "$SETTINGS_FILE was never modified by local mode (or already restored), leaving it alone."
  fi

  # generated scripts in BIN_DIR
  for f in claude-local-toggle.sh claude-local-desktop-toggle.sh \
           start-litellm-proxy.sh stop-litellm-proxy.sh \
           start-local-llama.sh start-local-llama-desktop.sh model-session.sh \
           start-openhands.sh; do
    if [ -f "$BIN_DIR/$f" ]; then
      rm -f "$BIN_DIR/$f"
      echo "Removed $BIN_DIR/$f"
    fi
  done

  # desktop icons
  for f in claude-local-toggle.desktop claude-local-start-model.desktop; do
    if [ -f "$DESKTOP_DIR/$f" ]; then
      rm -f "$DESKTOP_DIR/$f"
      echo "Removed $DESKTOP_DIR/$f"
    fi
  done

  # Linger: only turn it off if install.sh was the one who turned it on.
  if [ "${ENABLE_LINGER:-no}" = "yes" ] && [ "${LINGER_PRE_INSTALL_STATE:-}" = "no" ]; then
loginctl disable-linger "$USER" 2>/dev/null
    echo "Disabled systemd lingering (install.sh had turned it on)."
  fi
}

# ---------------------------------------------------------------------------
# Group B: kilo artifacts
# ---------------------------------------------------------------------------
# Remove the "local-model" provider block (and the top-level model pointer if
# it points back at local-model) from whatever kilo config exists.
remove_kilo_config() {
  local config
  for config in "$HOME/.config/kilo/kilo.json" "$HOME/.config/kilo/kilo.jsonc"; do
    [ -f "$config" ] || continue
    if command -v jq >/dev/null 2>&1; then
      TMP="$(mktemp "${config}.XXXXXX")"
      if jq --arg p "$KILO_PROVIDER" '
          ( .provider | has($p) ) as $had |
          ( .provider |= if $had then del(.[$p]) else . end ) |
          ( .model = if .model != null and ( .model | startswith($p + "/") ) then null else .model end )
        ' "$config" > "$TMP"; then
        mv -f "$TMP" "$config"
        echo "Removed the '$KILO_PROVIDER' provider block from $config"
      else
        rm -f "$TMP"
        echo "WARNING: could not jq-remove the provider block from $config" >&2
      fi
    else
      echo "WARNING: jq not found - cannot edit $config automatically." >&2
      echo "Manually delete the \"$KILO_PROVIDER\" block from $config." >&2
    fi
  done
}

remove_kilo() {
  echo
  echo "--- Kilo (Kilo Code provider + launcher) artifacts ---"
  remove_kilo_config

  for f in sync-local-model.sh start-local-model.sh start-local-model-lib.sh start-local-model-desktop.sh; do
    if [ -f "$BIN_DIR/$f" ]; then
      rm -f "$BIN_DIR/$f"
      echo "Removed $BIN_DIR/$f"
    fi
  done
  if [ -f "$DESKTOP_DIR/local-model.desktop" ]; then
    rm -f "$DESKTOP_DIR/local-model.desktop"
    echo "Removed $DESKTOP_DIR/local-model.desktop"
  fi
  if [ -d "$KILO_STATE_DIR" ]; then
    rm -rf "$KILO_STATE_DIR"
    echo "Removed the kilo active-model state dir $KILO_STATE_DIR"
  fi
}

# ---------------------------------------------------------------------------
# Group C: model files + runtime builds
# ---------------------------------------------------------------------------
remove_models() {
  echo
  echo "--- Model files + runtime builds ---"
  if [ "$CONF_EXISTS" != "yes" ] || [ -z "$CONTAINER_NAME" ] || [ "$PACKAGING" != "distrobox" ] \
     || ! distrobox list 2>/dev/null | tail -n +2 | grep -qi "$CONTAINER_NAME"; then
    # Native path (or no recorded container): delete under MODEL_ROOT directly.
    if [ -d "$MODEL_ROOT" ]; then
      echo "Removing downloaded model files under $MODEL_ROOT..."
      rm -rf "$MODEL_ROOT"
      echo "Removed $MODEL_ROOT."
    fi
    if [ -d "$HOME/llama.cpp" ]; then
      echo "Removing the native llama.cpp build at $HOME/llama.cpp..."
      rm -rf "$HOME/llama.cpp"
      echo "Removed $HOME/llama.cpp."
    fi
    if [ -x "$HOME/.local/llm-harness-switcher-vllm/bin/vllm" ]; then
      echo "Removing the vllm venv at $HOME/.local/llm-harness-switcher-vllm..."
      rm -rf "$HOME/.local/llm-harness-switcher-vllm"
      echo "Removed it."
    fi
    [ -e "$HOME/.local/bin/vllm" ] && { rm -f "$HOME/.local/bin/vllm"; echo "Removed $HOME/.local/bin/vllm symlink."; }
  else
    FOUND_GGUF="$(distrobox enter "$CONTAINER_NAME" -- bash -lc "find ~ -maxdepth 3 -iname '*.gguf' 2>/dev/null")"
    HAVE_LLAMACPP="$(distrobox enter "$CONTAINER_NAME" -- bash -lc '[ -d "$HOME/llama.cpp" ] && echo yes' 2>/dev/null)"
    if [ -n "$FOUND_GGUF" ] || [ "$HAVE_LLAMACPP" = "yes" ]; then
      echo "Found leftovers inside container '$CONTAINER_NAME':"
      [ -n "$FOUND_GGUF" ] && echo "$FOUND_GGUF" | sed 's/^/  /'
      [ "$HAVE_LLAMACPP" = "yes" ] && echo "  ~/llama.cpp (source + compiled llama-server)"
      distrobox enter "$CONTAINER_NAME" -- bash -lc "find ~ -maxdepth 3 -iname '*.gguf' -delete; rm -rf ~/llama.cpp"
      echo "Deleted model file(s) and ~/llama.cpp inside '$CONTAINER_NAME'."
    else
      echo "No downloaded model files or llama.cpp build found inside container '$CONTAINER_NAME'."
    fi
  fi
}

# --- Interactive selection (default) ---
arm_yn DO_CLASSIC "Remove classic artifacts (Claude Code + LiteLLM switcher)?"
arm_yn DO_KILO "Remove kilo artifacts (Kilo Code provider + launcher)?"
arm_yn DO_MODELS "Remove downloaded model files + runtime builds? (multi-GB, slow to re-fetch)"

# --- Execute ---
if [ "$DO_CLASSIC" = "yes" ]; then remove_classic; fi
if [ "$DO_KILO" = "yes" ]; then remove_kilo; fi
if [ "$DO_MODELS" = "yes" ]; then remove_models; fi

# --- The install config itself: only on --all, or when nothing else remains ---
if [ "$DO_ALL" = "yes" ] && [ "$CONF_EXISTS" = "yes" ]; then
  rm -f "$CONF_FILE"
  echo
  echo "Removed $CONF_FILE."
fi

echo
echo "== Done =="
echo "The requested artifacts are gone."
if [ "$CONF_EXISTS" = "yes" ] && [ "$DO_ALL" != "yes" ]; then
  echo "$CONF_FILE is still in place - install.sh will re-use its saved answers on next install."
  echo "Run 'uninstall.sh --all' to remove it (and everything else) entirely."
fi