# 00-config.sh
# Sourced by install.sh. Config defaults (from a prior run's CONF_FILE if
# present, else built-in fallbacks) and the small helper functions the rest
# of install.d/*.sh relies on: log(), backup_config(), save_config(), ask().

# --- Debug logging toggle for THIS script's own output ---
# Defaults come from the saved config if present, else these fallbacks.
INSTALL_VERBOSE="${INSTALL_VERBOSE:-no}"
INSTALL_LOG_DEST="${INSTALL_LOG_DEST:-console}"   # console or disk
INSTALL_LOG_FILE="${INSTALL_LOG_FILE:-$HOME/claude-local-install.log}"

# --- Config values this script manages, with prior-run or built-in defaults ---
# Which harness is being installed in this run. classic = the Claude Code +
# LiteLLM switcher (proxy, toggle, desktop icons). kilo = a single custom
# Kilo Code provider ("local-model") pointed at whatever local model/runtime
# is running. Re-running with a different mode offers to clean the other
# mode's artifacts (see install.sh's main()).
INSTALL_MODE="${INSTALL_MODE:-classic}"                    # classic | kilo
# Where the model server runs: "distrobox" (current CUDA-in-container flow,
# recommended on Fedora/Bazzite hosts) or "native" (no distrobox - packaged
# or source-built llama-server on the host, for Debian-ish boxes like
# vscodium-for-immutable's Debian 12 container).
PACKAGING="${PACKAGING:-distrobox}"                        # distrobox | native
# Directory containing a private presets repo hosting extra model-profiles/
# *.sh files (e.g. ~/github/8gb-immutable-fedora-presets). Discovered from a
# fixed list if not set; never auto-cloned (the presets repo is private).
# Empty means "only the shipped example profile is available".
PRESETS_DIR="${PRESETS_DIR:-}"
# Space-joined list of profile directories (shipped + presets), persisted at
# profile-pick time so the generated start-local-model.sh can resolve profile
# files at runtime straight from CONF_FILE.
PROFILE_DIRS_CONF="${PROFILE_DIRS_CONF:-}"
# Single Kilo Code provider name the sync script manages. Kept in config so
# uninstall.sh/summary can reference it and future renames are one edit.
KILO_PROVIDER="${KILO_PROVIDER:-local-model}"
# Kilo config file to sync the provider into. Detected at install time from
# the first existing of ~/.config/kilo/{kilo.json,kilo.jsonc}; if neither
# exists, sync-local-model.sh creates kilo.jsonc. Running inside
# vscodium-box, $HOME is the box's bind-mounted private home, so this
# resolves to the config Kilo Code reads there.
KILO_CONFIG="${KILO_CONFIG:-}"
# API key baked into the sync script. llama-server has no auth, so any token
# works; this matches the classic mode's sk-local-dev-key convention and just
# needs to be a non-empty value the OpenAI-compatible client sends as Bearer.
KILO_API_KEY="${KILO_API_KEY:-sk-local-dev-key}"
# State dir for kilo-mode artifacts that need to survive across
# start-local-model.sh runs (the "active model" record start-local-model.sh
# writes after a successful start+sync, so a later click that finds a healthy
# server re-syncs without restarting).
KILO_STATE_DIR="${KILO_STATE_DIR:-$HOME/.local/state/llm-harness-switcher}"
# Top-level directory models are downloaded into. Every profile gets its own
# subdirectory: $MODEL_ROOT/<profile-stem>/. Default is ~/models (same
# layout the download step always used); changing it is a "move your files"
# event, so it's intentionally not a prompt - edit the conf file if you
# really need a different root.
MODEL_ROOT="${MODEL_ROOT:-$HOME/models}"
# Which runtime serves the selected model: llama.cpp | ollama | vllm. The
# model profile sets this; the value is persisted here so later steps (and
# start-local-model.sh) know which runtime + default port to use even when a
# profile isn't sourced this run. Default port per runtime: 8080/11434/8000
# (a profile may override with RUNTIME_PORT).
MODEL_RUNTIME="${MODEL_RUNTIME:-llama.cpp}"
RUNTIME_PORT="${RUNTIME_PORT:-}"
# Reasoning/"thinking" mode for the selected profile: off | on | effort.
# Profiles default to off (the measured tool-calling stance - see
# ENABLE_THINKING's comment below). REASONING_EFFORT (low|medium|high) is
# used when the mode is "effort" and lands in the kilo model entry's options.
REASONING_MODE="${REASONING_MODE:-off}"
REASONING_EFFORT="${REASONING_EFFORT:-low}"
# Whether to download the multimodal projector (mmproj) file when the chosen
# profile declares MMPROJ_REPO/MMPROJ_PATTERN. Off by default: downloading a
# multi-hundred-MB projector nobody asked for, on the off chance the profile
# supports images, is the wrong default.
DOWNLOAD_MMPROJ="${DOWNLOAD_MMPROJ:-no}"
CONTAINER_NAME="${CONTAINER_NAME:-ollama-box}"
CONFIG_HOME="${CONFIG_HOME:-$HOME}"                        # where litellm_config.yaml lives
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"                     # where claude-local-toggle.sh goes
PROXY_PORT="${PROXY_PORT:-4000}"
PROXY_MASTER_KEY="${PROXY_MASTER_KEY:-sk-local-dev-key}"
ENABLE_LINGER="${ENABLE_LINGER:-no}"
DOWNLOAD_MODEL_NOW="${DOWNLOAD_MODEL_NOW:-yes}"
MODEL_PROFILE="${MODEL_PROFILE:-gemma4-e2b}"    # which model-profiles/*.sh to load (the shipped example profile default; presets-dir profiles are added to the menu)
LAST_MODEL_PROFILE="${LAST_MODEL_PROFILE:-}"               # profile in effect last run, so we know to reset
                                                            # HF_REPO/GGUF_PATTERN/etc to the new profile's
                                                            # defaults when this run switches profiles
GGUF_PATTERN="${GGUF_PATTERN:-}"                           # quant fragment, matched as a glob (profile default if empty)
QUANT_WEIGHT_MIB="${QUANT_WEIGHT_MIB:-}"                   # weight file size, MiB, feeds the context math
HF_REPO="${HF_REPO:-}"                                     # Hugging Face repo (profile default if empty)
QUANT_CHOICE="${QUANT_CHOICE:-}"
GPU_VRAM_MIB="${GPU_VRAM_MIB:-7885}"                       # usable VRAM, MiB (~7.7 GiB), feeds the context math
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-16384}"
LLAMA_BATCH_SIZE="${LLAMA_BATCH_SIZE:-512}"
LLAMA_CPU_FFN_LAYERS="${LLAMA_CPU_FFN_LAYERS:-2}"          # last N layers' FFN weights forced to CPU, frees VRAM
                                                            # (light default: dense FFN offload costs more per
                                                            # layer than the equivalent MoE trick, see prompt below)
LLAMA_NO_KV_OFFLOAD="${LLAMA_NO_KV_OFFLOAD:-no}"           # whole KV cache in system RAM instead of VRAM
KEEP_PLE_ON_CPU="${KEEP_PLE_ON_CPU:-yes}"                  # Per-Layer Embedding tables in system RAM (Gemma only)
LLAMA_SPEC_DRAFT_N="${LLAMA_SPEC_DRAFT_N:-2}"
LLAMA_N_PREDICT="${LLAMA_N_PREDICT:-4096}"                 # safety cap on tokens per response (llama-server -n);
                                                            # neither llama-server nor Zoo Code's own client
                                                            # settings (maxTokens: -1, includeMaxTokens: false)
                                                            # cap output otherwise, so a degenerate/repeating
                                                            # generation would run until it fills the whole
                                                            # context instead of stopping on its own
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-}"                   # resolved during Step 7, cached here
PROXY_DEBUG_LOG="${PROXY_DEBUG_LOG:-no}"
PROXY_LOG_DEST="${PROXY_LOG_DEST:-console}"                # console or disk
PROXY_LOG_FILE="${PROXY_LOG_FILE:-$HOME/.local/state/litellm-proxy.log}"  # a systemd --user unit usually can't write /var/log
INSTALL_DESKTOP_SHORTCUT="${INSTALL_DESKTOP_SHORTCUT:-yes}"
DESKTOP_DIR="${DESKTOP_DIR:-$HOME/Desktop}"
# Whether systemd lingering was already on before install.sh ever touched
# it, recorded once on first install so uninstall.sh knows whether turning
# it off again is safe (i.e. we turned it on) or would undo something the
# user had set up themselves for unrelated reasons.
LINGER_PRE_INSTALL_STATE="${LINGER_PRE_INSTALL_STATE:-}"
# Classic mode, optional: install the shipped distrobox-reminder.service
# (a login notification to stop the container before gaming). Off by default
# - this project auto-starts nothing, and the reminder is a nicety, not part
# of the switch.
INSTALL_GAME_REMINDER="${INSTALL_GAME_REMINDER:-no}"

# CLI-only override of REASONING_MODE, set via install.sh's
# --enable-thinking / --disable-thinking flags rather than the interactive
# prompt flow (the flags are applied after prompts, so a deliberate
# command-line choice always wins; a saved REASONING_MODE is just the
# prompt's default). Keeping this a flag - not a prompt - is what stops
# thinking from getting left on by an "Enter to keep previous answer"
# re-run. See README.md "Thinking mode".
ENABLE_THINKING="${ENABLE_THINKING:-no}"

# Default port per model runtime (llama.cpp 8080, ollama 11434, vllm 8000).
# A profile overrides with RUNTIME_PORT; without one, this is the port the
# kilo provider baseURL and the launcher use.
runtime_default_port() {
  case "$1" in
    ollama) echo "11434" ;;
    vllm)   echo "8000" ;;
    *)      echo "8080" ;;
  esac
}

# Fills RUNTIME_PORT from the runtime default when a profile didn't set one.
# Must run after the profile is sourced (20-prompts-model.sh).
resolve_runtime_port() {
  if [ -z "$RUNTIME_PORT" ]; then
    RUNTIME_PORT="$(runtime_default_port "$MODEL_RUNTIME")"
  fi
}

log() {
  if [ "$INSTALL_VERBOSE" = "yes" ]; then
    if [ "$INSTALL_LOG_DEST" = "disk" ]; then
      echo "[install] $*" | tee -a "$INSTALL_LOG_FILE" >&2
    else
      echo "[install] $*" >&2
    fi
  fi
}

# Backs up a pre-existing file the first time we're about to overwrite it,
# so uninstall.sh can put back whatever was there before install.sh ever
# ran. Only fires once - re-running install.sh on top of its own previous
# output must not clobber the original backup with our own generated file.
backup_config() {
  local target="$1" bak="$1.pre-install.bak"
  if [ -f "$target" ] && [ ! -f "$bak" ]; then
    cp "$target" "$bak"
    log "Backed up pre-existing $target to $bak"
  fi
}

save_config() {
  cat > "$CONF_FILE" << EOF
INSTALL_VERBOSE="$INSTALL_VERBOSE"
INSTALL_LOG_DEST="$INSTALL_LOG_DEST"
INSTALL_LOG_FILE="$INSTALL_LOG_FILE"
INSTALL_MODE="$INSTALL_MODE"
PACKAGING="$PACKAGING"
PRESETS_DIR="$PRESETS_DIR"
PROFILE_DIRS_CONF="$PROFILE_DIRS_CONF"
KILO_PROVIDER="$KILO_PROVIDER"
KILO_CONFIG="$KILO_CONFIG"
KILO_API_KEY="$KILO_API_KEY"
KILO_STATE_DIR="$KILO_STATE_DIR"
MODEL_ROOT="$MODEL_ROOT"
MODEL_RUNTIME="$MODEL_RUNTIME"
RUNTIME_PORT="$RUNTIME_PORT"
REASONING_MODE="$REASONING_MODE"
REASONING_EFFORT="$REASONING_EFFORT"
DOWNLOAD_MMPROJ="$DOWNLOAD_MMPROJ"
CONTAINER_NAME="$CONTAINER_NAME"
CONFIG_HOME="$CONFIG_HOME"
BIN_DIR="$BIN_DIR"
PROXY_PORT="$PROXY_PORT"
PROXY_MASTER_KEY="$PROXY_MASTER_KEY"
ENABLE_LINGER="$ENABLE_LINGER"
DOWNLOAD_MODEL_NOW="$DOWNLOAD_MODEL_NOW"
MODEL_PROFILE="$MODEL_PROFILE"
LAST_MODEL_PROFILE="$LAST_MODEL_PROFILE"
GGUF_PATTERN="$GGUF_PATTERN"
QUANT_WEIGHT_MIB="$QUANT_WEIGHT_MIB"
HF_REPO="$HF_REPO"
QUANT_CHOICE="$QUANT_CHOICE"
GPU_VRAM_MIB="$GPU_VRAM_MIB"
LLAMA_PORT="$LLAMA_PORT"
LLAMA_CTX_SIZE="$LLAMA_CTX_SIZE"
LLAMA_BATCH_SIZE="$LLAMA_BATCH_SIZE"
LLAMA_CPU_FFN_LAYERS="$LLAMA_CPU_FFN_LAYERS"
LLAMA_NO_KV_OFFLOAD="$LLAMA_NO_KV_OFFLOAD"
KEEP_PLE_ON_CPU="$KEEP_PLE_ON_CPU"
LLAMA_SPEC_DRAFT_N="$LLAMA_SPEC_DRAFT_N"
LLAMA_N_PREDICT="$LLAMA_N_PREDICT"
LLAMA_SERVER_BIN="$LLAMA_SERVER_BIN"
PROXY_DEBUG_LOG="$PROXY_DEBUG_LOG"
PROXY_LOG_DEST="$PROXY_LOG_DEST"
PROXY_LOG_FILE="$PROXY_LOG_FILE"
INSTALL_DESKTOP_SHORTCUT="$INSTALL_DESKTOP_SHORTCUT"
DESKTOP_DIR="$DESKTOP_DIR"
LINGER_PRE_INSTALL_STATE="$LINGER_PRE_INSTALL_STATE"
INSTALL_GAME_REMINDER="$INSTALL_GAME_REMINDER"
ENABLE_THINKING="$ENABLE_THINKING"
EOF
}

# install.sh's --enable-thinking/--disable-thinking flag overrides the
# profile's REASONING_MODE for this run. Applied AFTER the prompts (in
# install.sh's main()) so a deliberate command-line choice beats whatever the
# prompts/saved config resolved to, but a plain re-run with no flag leaves the
# prompted value alone.
apply_thinking_override() {
  [ "${THINKING_FLAG:-no}" = "yes" ] || return 0
  if [ "$ENABLE_THINKING" = "yes" ]; then
    REASONING_MODE="on"
  else
    REASONING_MODE="off"
  fi
}

ask() {
  # ask VAR_NAME "question text"
  local varname="$1" question="$2" current="${!1}" answer
  read -rp "$question [$current]: " answer
  if [ -n "$answer" ]; then
    printf -v "$varname" '%s' "$answer"
  fi
}

# ask_confirm_override VAR_NAME "question text" "recommended value" "why"
# Same as ask(), but for a setting a model profile has actually benchmarked
# (not guessed) a good value for: if the user types something OTHER than
# that recommended value, they have to explicitly type "yes" to confirm the
# override, with the reason printed first. Pressing Enter to accept the
# recommended value (already the shown default) is unaffected - this only
# adds friction to changing away from a tested-good number, not to keeping
# it. Profiles that don't set a recommendation should keep using plain ask().
ask_confirm_override() {
  local varname="$1" question="$2" recommended="$3" reason="$4" current="${!1}" answer confirm
  read -rp "$question [$current]: " answer
  if [ -n "$answer" ] && [ "$answer" != "$recommended" ]; then
    echo "NOTE: $recommended is the tested value for this profile - $reason"
    read -rp "Override it with '$answer' anyway? (yes/no) [no]: " confirm
    if [ "$confirm" != "yes" ]; then
      echo "Keeping the tested value: $recommended"
      answer="$recommended"
    fi
  fi
  if [ -n "$answer" ]; then
    printf -v "$varname" '%s' "$answer"
  fi
}
