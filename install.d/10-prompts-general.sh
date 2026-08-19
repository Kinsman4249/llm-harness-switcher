# 10-prompts-general.sh
# Sourced by install.sh. The non-model-specific interactive prompts: the
# install mode (classic vs kilo), the packaging choice (distrobox vs native),
# and the small tail of settings asked after the model section. Mode is asked
# first because it gates which later prompts exist at all; classic-only
# prompts (container name, config/bin dirs, proxy port/key) are skipped in
# kilo mode, where nothing makes them meaningful.

prompt_general_settings() {
  # Capture the previously installed mode (if any) BEFORE the prompt mutates
  # INSTALL_MODE, so a mode switch can offer to clean the other mode's
  # artifacts (see below).
  local prev_mode="$INSTALL_MODE"

  echo
  echo "Which install would you like?"
  echo "  1) classic - Claude Code + LiteLLM switcher (toggle on/off, desktop"
  echo "              icons, ~/.claude/settings.json env block, local-only proxy)"
  echo "  2) kilo    - single custom Kilo Code provider (\"$KILO_PROVIDER\") pointed at"
  echo "              whatever local model/runtime is running; one desktop icon"
  echo "              to pick a model, start it, smoke-test it, and re-sync the"
  echo "              provider config every time you change models"
  local MODE_CHOICE=""
  read -rp "Pick a number or type the mode [${INSTALL_MODE}]: " MODE_CHOICE
  case "$MODE_CHOICE" in
    1) INSTALL_MODE="classic" ;;
    2) INSTALL_MODE="kilo" ;;
    classic|kilo) INSTALL_MODE="$MODE_CHOICE" ;;
    "") : ;;  # keep saved default
    *) echo "Didn't recognize '$MODE_CHOICE', keeping '$INSTALL_MODE'." >&2 ;;
  esac

  # Mode switch: the previous run installed the other mode's artifacts. Ask
  # before continuing whether to strip them, since they'd otherwise linger
  # (and in the classic->kilo direction a stale systemd proxy + toggle could
  # keep fighting over Claude Code's settings.json). uninstall.sh's explicit
  # --classic/--kilo flag selects the group regardless of what CONF_FILE says.
  if [ -n "$prev_mode" ] && [ "$INSTALL_MODE" != "$prev_mode" ]; then
    local CLEAN_OTHER="no"
    echo
    echo "You previously installed '$prev_mode' mode. Switching to '$INSTALL_MODE'."
    if [ "$INSTALL_MODE" = "kilo" ]; then
      echo "The classic install's proxy scripts, toggle, and systemd units (if"
      echo "still enabled) would keep their old behavior alongside the kilo setup."
    else
      echo "The kilo install's provider entry and sync script would linger in"
      echo "the Kilo config read on session start."
    fi
    ask CLEAN_OTHER "Run uninstall.sh to remove the previous '$prev_mode' install's artifacts? (yes/no)"
    if [ "$CLEAN_OTHER" = "yes" ]; then
      case "$prev_mode" in
        classic) echo "Cleaning the previous classic install's artifacts..."; "$SCRIPT_DIR/uninstall.sh" --classic ;;
        kilo)    echo "Cleaning the previous kilo install's artifacts..."; "$SCRIPT_DIR/uninstall.sh" --kilo ;;
      esac
      echo "Cleanup done - continuing with the '$INSTALL_MODE' install."
    fi
  fi

  # Packaging: where the model server process runs. Distrobox is the long-
  # standing CUDA-in-container flow (recommended on Fedora/Bazzite hosts for
  # GPU performance). Native runs no container at all - packaged llama-server
  # via apt when the distro ships it (Ubuntu 24.04+, Debian trixie), else a
  # source build with an auto-detected backend (CUDA > Vulkan > CPU), which on
  # a Debian 12 box like vscodium-for-immutable's vscodium-box yields a CPU
  # build. Kinda only distrobox offers GPU passthrough; native is for
  # headless/containerized homes.
  echo
  echo "How should the model server run?"
  echo "  1) distrobox - inside a Distrobox container (recommended on"
  echo "              Fedora/Bazzite hosts for NVIDIA GPU performance)"
  echo "  2) native   - directly on this host (packaged llama-server via apt,"
  echo "              or a source build; backend auto-detected CUDA > Vulkan >"
  echo "              CPU; ollama/vllm installed on the host)"
  local PACK_CHOICE=""
  read -rp "Pick a number or type the packaging [${PACKAGING}]: " PACK_CHOICE
  case "$PACK_CHOICE" in
    1) PACKAGING="distrobox" ;;
    2) PACKAGING="native" ;;
    distrobox|native) PACKAGING="$PACK_CHOICE" ;;
    "") : ;;
    *) echo "Didn't recognize '$PACK_CHOICE', keeping '$PACKAGING'." >&2 ;;
  esac

  # Presets directory: where extra model-profiles/*.sh live. Discovered from a
  # fixed list when left empty - the private presets repo (e.g.
  # ~/github/8gb-immutable-fedora-presets) is never auto-cloned, per the
  # project's rule. Skipping the prompt is fine; discovery runs below.
  if [ -z "$PRESETS_DIR" ]; then
    for candidate in "$SCRIPT_DIR/../8gb-immutable-fedora-presets" \
                     "$HOME/github/8gb-immutable-fedora-presets" \
                     "$HOME/.local/share/llm-harness-switcher/8gb-immutable-fedora-presets"; do
      if [ -d "$candidate" ]; then
        PRESETS_DIR="$candidate"
        log "Discovered presets dir: $PRESETS_DIR"
        break
      fi
    done
  fi
  ask PRESETS_DIR "Directory with extra model profiles (empty = shipped example only)"

  ask INSTALL_VERBOSE "Verbose output for this install script? (yes/no)"
  if [ "$INSTALL_VERBOSE" = "yes" ]; then
    ask INSTALL_LOG_DEST "Save that verbose output to disk or just show in console? (disk/console)"
    if [ "$INSTALL_LOG_DEST" = "disk" ]; then
      ask INSTALL_LOG_FILE "Log file path"
    fi
  fi

  if [ "$INSTALL_MODE" = "classic" ]; then
    # Classic-only prompts: the whole point of that mode is the Claude Code
    # switcher wired to a proxy inside a Distrobox container.
    ask CONTAINER_NAME "Distrobox container name (needs working NVIDIA GPU passthrough)"
    ask CONFIG_HOME "Directory to store litellm_config.yaml in"
    ask BIN_DIR "Directory to install claude-local-toggle.sh into"
    ask PROXY_PORT "LiteLLM proxy port"
    ask PROXY_MASTER_KEY "Proxy auth token (used as ANTHROPIC_AUTH_TOKEN)"
    # No ENABLE_LINGER prompt anymore: nothing auto-starts in this project now
    # (see README "No auto-start"), so lingering has nothing to enable.
    ENABLE_LINGER="no"
  else
    # Kilo mode: no proxy, no container name needed unless a llama.cpp profile
    # is chosen later (install.d/30-container.sh is only called then). BIN_DIR
    # is still where start-local-model.sh + sync-local-model.sh land.
    ask BIN_DIR "Directory to install the kilo launcher scripts into"
  fi
}

prompt_misc_settings() {
  if [ "$INSTALL_MODE" = "classic" ]; then
    ask LLAMA_PORT "llama-server port"
    ask PROXY_DEBUG_LOG "Enable verbose LiteLLM proxy logging? (yes/no)"
    if [ "$PROXY_DEBUG_LOG" = "yes" ]; then
      ask PROXY_LOG_DEST "Proxy logs to disk or console? (disk/console)"
      if [ "$PROXY_LOG_DEST" = "disk" ]; then
        ask PROXY_LOG_FILE "Proxy log file path"
      fi
    fi
    ask INSTALL_GAME_REMINDER "Install a login reminder to stop the container before gaming? (yes/no)"
  fi
  ask INSTALL_DESKTOP_SHORTCUT "Install a desktop icon for the local model? (yes/no)"
  if [ "$INSTALL_DESKTOP_SHORTCUT" = "yes" ]; then
    ask DESKTOP_DIR "Desktop directory"
  fi
}