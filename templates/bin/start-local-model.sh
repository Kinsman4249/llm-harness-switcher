#!/usr/bin/env bash
# start-local-model.sh
# Kilo-mode template, copied into $BIN_DIR by install.sh (install.d/80-
# launcher.sh) alongside start-local-model-lib.sh, which it sources for every
# function it uses (the two must ship together). Reads install-time config
# from ~/.config/claude-local-setup.conf at runtime, so re-running install.sh
# is all that's needed to change it. The whole kilo desktop flow in one script:
#
#   1. If a server is already healthy on the active runtime's port, and its
#      profile lists a curated REASONING_MODES, offer that picker and restart
#      on the same port if the user picks a different mode; otherwise just
#      re-sync the Kilo provider config without starting anything.
#   2. Scan for local models: GGUFs under $MODEL_ROOT/** (excluding drafter
#      "mtp-*"/"*assistant*" and projector "mmproj-*" files), plus `ollama
#      list` entries when ollama is installed.
#   3. Show a numbered menu; pick one (or pass --profile <stem> to skip the
#      menu and start that profile directly - what install.sh uses for its own
#      end-to-end test).
#   4. Match the pick to a model profile (dir name == profile stem, else a
#      filename-fragment search); unmatched models get a runtime/port/context
#      prompt and continue with sane defaults.
#   5. Start the runtime for that model and wait for its health endpoint.
#   6. Smoke-test one tiny completion through the OpenAI-compatible endpoint.
#   7. Run sync-local-model.sh so the Kilo provider points at exactly this
#      running model, then notify + remind to restart Kilo.
#
# Usage: start-local-model.sh [--profile <stem>] [--mode <name>]
#   --profile <stem>  skip the model menu and start that profile directly
#   --mode <name>     force the reasoning mode (off|on|budgeted|max|effort,
#                     or a mode a profile's REASONING_MODES offers). When a
#                     server is already running and this differs from its
#                     current mode, it restarts on the same port.

set -uo pipefail

CONF_FILE="$HOME/.config/claude-local-setup.conf"

# --- install-time defaults (read at runtime so nothing to bake escape) ---
MODEL_ROOT="${MODEL_ROOT:-$HOME/models}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
STATE_DIR="${KILO_STATE_DIR:-$HOME/.local/state/llm-harness-switcher}"
ACTIVE_STATE="$STATE_DIR/active.conf"
KILO_PROVIDER="${KILO_PROVIDER:-local-model}"
KILO_API_KEY="${KILO_API_KEY:-sk-local-dev-key}"
PACKAGING="${PACKAGING:-distrobox}"
CONTAINER_NAME="${CONTAINER_NAME:-ollama-box}"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-}"
RUNTIME_PORT="${RUNTIME_PORT:-8080}"
DEFAULT_CTX="${LLAMA_CTX_SIZE:-16384}"
DEFAULT_OUTPUT="${LLAMA_N_PREDICT:-4096}"
DEFAULT_BATCH=512
DEFAULT_REASONING="${REASONING_MODE:-off}"
DEFAULT_EFFORT="${REASONING_EFFORT:-low}"
PROFILE_DIRS="${PROFILE_DIRS_CONF:-}"

if [ -f "$CONF_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  MODEL_ROOT="${MODEL_ROOT:-$HOME/models}"
  BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
  STATE_DIR="${KILO_STATE_DIR:-$HOME/.local/state/llm-harness-switcher}"
  ACTIVE_STATE="$STATE_DIR/active.conf"
  KILO_API_KEY="${KILO_API_KEY:-sk-local-dev-key}"
  PACKAGING="${PACKAGING:-distrobox}"
  CONTAINER_NAME="${CONTAINER_NAME:-ollama-box}"
  LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-}"
  RUNTIME_PORT="${RUNTIME_PORT:-8080}"
  DEFAULT_CTX="${LLAMA_CTX_SIZE:-16384}"
  DEFAULT_OUTPUT="${LLAMA_N_PREDICT:-4096}"
  DEFAULT_REASONING="${REASONING_MODE:-off}"
  DEFAULT_EFFORT="${REASONING_EFFORT:-low}"
  PROFILE_DIRS="${PROFILE_DIRS_CONF:-$PROFILE_DIRS}"
fi

PROFILE_ARG=""
CLI_MODE=""
CLI_CTX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      shift
      PROFILE_ARG="${1:-}"
      shift || true
      ;;
    --mode)
      shift
      CLI_MODE="${1:-}"
      shift || true
      ;;
    --context)
      shift
      CLI_CTX="${1:-}"
      shift || true
      ;;
    --help|-h|help)
      echo "Usage: $0 [--profile <stem>] [--mode <name>] [--context <name>]"
      echo "Without --profile, scans for local models and shows a menu."
      echo "Without --mode and when the profile's REASONING_MODES offers more"
      echo "than one mode, an interactive menu lets you pick one."
      echo "--mode <name> forces the reasoning mode directly. Valid names are"
      echo "the profile's REASONING_MODES (typically off|on|budgeted|max), or"
      echo "the legacy off|on|effort when the profile sets none. On an"
      echo "already-running server it restarts on the same port to apply it."
      echo "--context <name> forces the context-window mode. Valid names are"
      echo "the profile's CTX_MODES (typically native, and native plus one or"
      echo "more YaRN rungs like yarn2/yarn3). 'native' (the default) serves the"
      echo "model's native window; a YaRN rung emits rope-scaling to extend past"
      echo "it. On an already-running server it restarts on the same port to"
      echo "apply the new window."
      exit 0
      ;;
    *) shift ;;
  esac
done

# Every function this script uses lives in its sibling lib (shipped to the
# same $BIN_DIR by install.sh), so the orchestration below stays readable.
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/start-local-model-lib.sh"

# --- Step 1: already running? Offer a reasoning-mode switch / just re-sync. ---
if [ -f "$ACTIVE_STATE" ]; then
  # shellcheck source=/dev/null
  source "$ACTIVE_STATE"
  if [ -n "${ACTIVE_PORT:-}" ] && [ -n "${ACTIVE_RUNTIME:-}" ] && runtime_healthy "$ACTIVE_PORT" "$ACTIVE_RUNTIME"; then
    logf "A model server is already running at ${ACTIVE_BASE_URL:-http://127.0.0.1:$ACTIVE_PORT/v1}."
    logf "  running mode: ${ACTIVE_MODE:-$(mode_to_sync "${ACTIVE_REASONING:-off}")}"
    logf "  running context: ${ACTIVE_CTX_MODE:-native}"

    RESTART_MODE=""
    RESTART_CTX=""
    # Only llama.cpp profiles with a curated REASONING_MODES list can switch
    # thinking modes at all (the flags are emitted by start_llama_server).
    if [ "$ACTIVE_RUNTIME" = "llama.cpp" ] || [ "$ACTIVE_RUNTIME" = "llama" ]; then
      active_profile=""
      active_stem=""
      [ -n "${ACTIVE_PROFILE:-}" ] && { active_stem="$ACTIVE_PROFILE"; active_profile="$(find_profile_file "$ACTIVE_PROFILE")"; }
      # Fallback for state written before ACTIVE_PROFILE existed: the model id
      # is the profile stem for llama.cpp profiles.
      if [ -z "$active_profile" ] && [ -n "${ACTIVE_MODEL_ID:-}" ]; then
        active_profile="$(find_profile_file "$ACTIVE_MODEL_ID")"
        [ -n "$active_profile" ] && active_stem="$ACTIVE_MODEL_ID"
      fi
      if [ -n "$active_profile" ] && [ -f "$active_profile" ] && [ -n "${ACTIVE_PORT:-}" ]; then
        # shellcheck source=/dev/null
        source "$active_profile"
        if [ -n "${REASONING_MODES:-}" ]; then
          IFS=',' read -r -a MODES <<< "$REASONING_MODES"
          running_mode="${ACTIVE_MODE:-$(mode_to_sync "${ACTIVE_REASONING:-off}")}"
          preselect="$running_mode"; preselect_ok=no
          for m in "${MODES[@]}"; do [ "$m" = "$preselect" ] && preselect_ok=yes; done
          [ "$preselect_ok" = "no" ] && preselect="${MODES[0]}"
          if [ -z "$CLI_MODE" ] && [ "${#MODES[@]}" -gt 1 ]; then
            pick_mode "$preselect"; RESTART_MODE="$PICK_MODE"
          elif [ -n "$CLI_MODE" ]; then
            mode_ok=no; for m in "${MODES[@]}"; do [ "$m" = "$CLI_MODE" ] && mode_ok=yes; done
            if [ "$mode_ok" = "no" ]; then
              echo "ERROR: --mode '$CLI_MODE' is not offered by ${ACTIVE_PROFILE:-unknown} (${MODES[*]})" >&2
            else
              RESTART_MODE="$CLI_MODE"
            fi
          else
            RESTART_MODE="$preselect"
          fi
        fi
        # Context-window switch --context, parallel to reasoning: only for
        # profiles that declare a CTX_MODES array. The running path honors an
        # explicit --context (restart on a change); it does NOT auto-prompt the
        # context picker here (the reasoning picker already prompts on a plain
        # re-run, and queueing a second prompt is surprising). The fresh-start
        # path offers the interactive context picker instead.
        if [ -n "$CLI_CTX" ] && [ "${CTX_MODES+x}" = "x" ] && [ "${#CTX_MODES[@]}" -gt 0 ]; then
          _ctx_default="native" _ctxok=no
          for _cm in "${CTX_MODES[@]}"; do [ "${_cm%%|*}" = "$_ctx_default" ] && _ctxok=yes; done
          [ "$_ctxok" = "no" ] && _ctx_default="${CTX_MODES[0]%%|*}"
          RESTART_CTX="$CLI_CTX"
        fi
      fi
    fi

    want_restart=no
    if [ -n "$RESTART_MODE" ] && [ "$RESTART_MODE" != "${ACTIVE_MODE:-$(mode_to_sync "${ACTIVE_REASONING:-off}")}" ]; then
      want_restart=yes
    fi
    if [ -n "$RESTART_CTX" ] && [ "$RESTART_CTX" != "${ACTIVE_CTX_MODE:-native}" ]; then
      want_restart=yes
    fi

    if [ "$want_restart" = "yes" ]; then
      if [ -n "$RESTART_CTX" ]; then
        logf "Switching context window to '$RESTART_CTX' - restarting llama-server"
      fi
      if [ -n "$RESTART_MODE" ]; then
        logf "Switching reasoning mode to '$RESTART_MODE' - restarting llama-server"
      fi
      logf "on port $ACTIVE_PORT (same port, so the Kilo provider entry stays valid)."
      stop_llama_server "$ACTIVE_PORT"
      # Fall through to the fresh-start path with the active profile so the new
      # mode is applied from the profile's own flag recipe (line 218 re-pins
      # RUNTIME_PORT to the active port).
      PROFILE_ARG="$active_stem"
      CLI_MODE="${RESTART_MODE:-}"
      CLI_CTX="${RESTART_CTX:-}"
    else
      logf "Re-syncing the Kilo provider config for it (no restart)."
      if [ -x "$BIN_DIR/sync-local-model.sh" ]; then
        "$BIN_DIR/sync-local-model.sh" \
          --base-url "${ACTIVE_BASE_URL:-http://127.0.0.1:$ACTIVE_PORT/v1}" \
          --api-key "$KILO_API_KEY" \
          --model-id "${ACTIVE_MODEL_ID:-local}" \
          --model-name "${ACTIVE_MODEL_NAME:-Local Model}" \
          --context "${ACTIVE_CTX:-$DEFAULT_CTX}" \
          --output "${ACTIVE_OUTPUT:-$DEFAULT_OUTPUT}" \
          --reasoning "$(mode_to_sync "${ACTIVE_REASONING:-off}")" \
          --effort "${ACTIVE_EFFORT:-$DEFAULT_EFFORT}" \
          --attachment "${ACTIVE_ATTACHMENT:-no}"
      else
        logf "WARNING: $BIN_DIR/sync-local-model.sh not found - re-run install.sh." >&2
      fi
      notify_kilo "Local model" "Already running - Kilo provider config re-synced. Reload/restart Kilo Code to apply."
      exit 0
    fi
  fi
fi
[ -n "${ACTIVE_PORT:-}" ] && RUNTIME_PORT="${ACTIVE_PORT:-$RUNTIME_PORT}"

# --- Step 2: scan for models ---
MENU_LABELS=()
MENU_TYPES=()     # llama|ollama|vllm|raw
MENU_PATHS=()     # gguf path for llama; OLLAMA_MODEL id for ollama
MENU_PROFILES=()  # matched profile file (may be empty)

if [ -d "$MODEL_ROOT" ]; then
  while IFS= read -r -d '' gguf; do
    stem="$(basename "$(dirname "$gguf")")"
    profile="$(find_profile_file "$stem")"
    label="$stem/$(basename "$gguf")"
    if [ -n "$profile" ]; then
      pname="$(sed -n 's/^PROFILE_NAME="\(.*\)"$/\1/p' "$profile" | head -n1)"
      label="$label  (${pname:-$stem})"
    fi
    MENU_LABELS+=("$label")
    MENU_TYPES+=("llama")
    MENU_PATHS+=("$gguf")
    MENU_PROFILES+=("${profile:-}")
  done < <(find "$MODEL_ROOT" -maxdepth 2 -type f -iname '*.gguf' \
             -not -iname 'mtp-*' -not -iname '*assistant*' -not -iname 'mmproj-*' \
             -print0 2>/dev/null | sort -z)
fi

if command -v ollama >/dev/null 2>&1; then
  while IFS= read -r omodel; do
    [ -z "$omodel" ] && continue
    profile=""
    for dir in $PROFILE_DIRS; do
      [ -d "$dir" ] || continue
      for f in "$dir"/*.sh; do
        [ -f "$f" ] || continue
        if grep -q "OLLAMA_MODEL=\"$omodel\"" "$f"; then profile="$f"; break; fi
      done
      [ -n "$profile" ] && break
    done
    MENU_LABELS+=("ollama: $omodel")
    MENU_TYPES+=("ollama")
    MENU_PATHS+=("$omodel")
    MENU_PROFILES+=("${profile:-}")
  done <<< "$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')"
fi

if [ "${#MENU_TYPES[@]}" -eq 0 ] && [ -z "$PROFILE_ARG" ]; then
  echo
  echo "No local models found in $MODEL_ROOT (and no ollama models listed)."
  echo "Two ways to fix that:"
  echo "  - Re-run install.sh and answer yes at the 'Download the local model"
  echo "    now?' prompt - it downloads and configures a profile for you."
  echo "  - Drop a GGUF into $MODEL_ROOT/<profile-stem>/ yourself."
  echo "Aborting - there is nothing to start."
  exit 1
fi

# --- Step 3: choose the model (or use --profile) ---
MODEL_GGUF=""; MODEL_ID=""; MODEL_RUNTIME=""; CTX=""; OUTPUT=""; MODEL_NAME=""; PORT=""
if [ -n "$PROFILE_ARG" ]; then
  NEEDLE="$PROFILE_ARG"
  profile_file="$(find_profile_file "$NEEDLE")"
  if [ -z "$profile_file" ]; then
    echo "ERROR: no profile file matches '$NEEDLE' in: $PROFILE_DIRS" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$profile_file"
  if [ "${MODEL_RUNTIME:-llama.cpp}" = "ollama" ] && [ -n "${OLLAMA_MODEL:-}" ]; then
    MODEL_ID="$OLLAMA_MODEL"; MODEL_RUNTIME="ollama"
  elif [ "${MODEL_RUNTIME:-llama.cpp}" = "vllm" ] && [ -n "${VLLM_MODEL_ID:-}" ]; then
    MODEL_ID="$VLLM_MODEL_ID"; MODEL_RUNTIME="vllm"
  else
    if [ -n "${GGUF_PATTERN:-}" ]; then
      # Prefer the configured quant fragment (GGUF_PATTERN, set at install time
      # or in ~/.config/claude-local-setup.conf). find returns directory order,
      # NOT alphabetical, so a multi-quant model dir needs this to reliably pick
      # the primary quant at runtime (the old head -n1 could pick a fallback).
      MODEL_GGUF="$(find "$MODEL_ROOT/$NEEDLE" -maxdepth 1 -type f -iname "*${GGUF_PATTERN}*.gguf" \
                  -not -iname 'mtp-*' -not -iname '*assistant*' -not -iname 'mmproj-*' 2>/dev/null | head -n1)"
    fi
    [ -z "${MODEL_GGUF:-}" ] && \
      MODEL_GGUF="$(find "$MODEL_ROOT/$NEEDLE" -maxdepth 1 -type f -iname '*.gguf' \
                  -not -iname 'mtp-*' -not -iname '*assistant*' -not -iname 'mmproj-*' 2>/dev/null | head -n1)"
    if [ -z "$MODEL_GGUF" ]; then
      echo "ERROR: no GGUF found under $MODEL_ROOT/$NEEDLE/ - run install.sh's" >&2
      echo "download step first (or drop the file there)." >&2
      exit 1
    fi
    MODEL_ID="${KILO_MODEL_ID:-$NEEDLE}"
    MODEL_RUNTIME="llama.cpp"
  fi
  # Each profile's tested RECOMMENDED_CTX_8GB is the source of truth. Prefer it
  # over the global/cooked-in LLAMA_CTX_SIZE, which is set at install time to
  # whichever profile was installed first and would otherwise silently re-cap a
  # profile whose RECOMMENDED_CTX_8GB was raised later (nemotron 442368, ornith
  # YaRN 524288). LLAMA_CTX_SIZE still applies for unmatched/raw models that set
  # no RECOMMENDED_CTX_8GB.
  CTX="${RECOMMENDED_CTX_8GB:-${LLAMA_CTX_SIZE:-$DEFAULT_CTX}}"
  OUTPUT="${LLAMA_N_PREDICT:-$DEFAULT_OUTPUT}"
  MODEL_NAME="${KILO_MODEL_NAME:-${PROFILE_NAME:-Local Model}}"
  PORT="${RUNTIME_PORT:-$(runtime_default_port "$MODEL_RUNTIME")}"
else
  echo
  echo "Which model?"
  PICK_NUM=1
  local_ifs="$IFS"
  IFS=$'\n'
  for i in "${!MENU_TYPES[@]}"; do
    printf '  %d) %s\n' "$PICK_NUM" "${MENU_LABELS[$i]}"
    PICK_NUM=$(( PICK_NUM + 1 ))
  done
  read -rp "Pick a number: " PICK
  if ! [[ "$PICK" =~ ^[0-9]+$ ]] || [ "$PICK" -lt 1 ] || [ "$PICK" -gt "${#MENU_TYPES[@]}" ]; then
    echo "ERROR: '$PICK' isn't a valid choice." >&2
    exit 1
  fi
  IDX=$(( PICK - 1 ))
  MODEL_RUNTIME="${MENU_TYPES[$IDX]}"
  MODEL_PATH="${MENU_PATHS[$IDX]}"
  profile_file="${MENU_PROFILES[$IDX]}"
  MODEL_GGUF=""; MODEL_ID=""
  if [ -n "$profile_file" ]; then
    # shellcheck source=/dev/null
    source "$profile_file"
  else
    echo "No profile matched - prompting for basic settings (defaults below)."
    read -rp "Runtime (llama.cpp/ollama/vllm) [$MODEL_RUNTIME]: " ANSWER_RT
    [ -n "$ANSWER_RT" ] && MODEL_RUNTIME="$ANSWER_RT"
    case "$MODEL_RUNTIME" in
      llama.cpp|ollama|vllm) ;;
      *) echo "Unknown runtime '$MODEL_RUNTIME', assuming llama.cpp." >&2; MODEL_RUNTIME="llama.cpp" ;;
    esac
  fi
  PORT="$(runtime_default_port "$MODEL_RUNTIME")"
  if [ "$MODEL_RUNTIME" = "llama" ] || [ "$MODEL_RUNTIME" = "llama.cpp" ]; then
    MODEL_GGUF="$MODEL_PATH"
    MODEL_ID="${KILO_MODEL_ID:-$(basename "$(dirname "$MODEL_PATH")")}"
  elif [ "$MODEL_RUNTIME" = "ollama" ]; then
    MODEL_ID="$MODEL_PATH"
  elif [ "$MODEL_RUNTIME" = "vllm" ]; then
    MODEL_ID="${VLLM_MODEL_ID:-$MODEL_PATH}"
  fi
  CTX="${RECOMMENDED_CTX_8GB:-${LLAMA_CTX_SIZE:-$DEFAULT_CTX}}"
  OUTPUT="${LLAMA_N_PREDICT:-$DEFAULT_OUTPUT}"
  MODEL_NAME="${KILO_MODEL_NAME:-${PROFILE_NAME:-Local Model}}"
  if [ "$MODEL_RUNTIME" != "llama.cpp" ] && [ "$MODEL_RUNTIME" != "llama" ]; then
    read -rp "Context length in tokens [$CTX]: " ANSWER_CTX
    [ -n "$ANSWER_CTX" ] && CTX="$ANSWER_CTX"
  fi
  [ "$MODEL_RUNTIME" = "llama" ] && MODEL_RUNTIME="llama.cpp"
fi

# --- Resolve the reasoning mode: --mode > interactive menu > saved default ---
# The profile (sourced above) may offer a curated mode list (REASONING_MODES);
# without one, keep the legacy single-choice behavior (off|on|effort). The
# resolved value lives in a runtime-only var MODE - the persistent
# REASONING_MODE/CONF is never rewritten by a session choice.
if [ -n "${REASONING_MODES:-}" ]; then
  IFS=',' read -r -a MODES <<< "$REASONING_MODES"
else
  MODES=( off on effort )
fi

# Interactive reasoning-mode menu: only on the no-profile path, for a
# llama.cpp runtime with a matched profile, when the profile offers more than
# one mode, and the user did not pass --mode. Empty Enter keeps the
# pre-select; invalid input re-prompts (a mis-type should not kill a launch).
MODE=""
if [ -z "$CLI_MODE" ] && [ -z "$PROFILE_ARG" ] && \
   [ "$MODEL_RUNTIME" = "llama.cpp" ] && [ -n "$profile_file" ] && \
   [ "${#MODES[@]}" -gt 1 ]; then
  preselect="${REASONING_MODE:-${MODES[0]}}"
  preselect_ok=no
  for m in "${MODES[@]}"; do [ "$m" = "$preselect" ] && preselect_ok=yes; done
  [ "$preselect_ok" = "no" ] && preselect="${MODES[0]}"
  pick_mode "$preselect"
  MODE="$PICK_MODE"
elif [ -n "$CLI_MODE" ]; then
  MODE="$CLI_MODE"
else
  MODE="${REASONING_MODE:-${DEFAULT_REASONING:-off}}"
  if [ -n "${REASONING_MODES:-}" ]; then
    mode_ok=no
    for m in "${MODES[@]}"; do [ "$m" = "$MODE" ] && mode_ok=yes; done
    [ "$mode_ok" = "no" ] && MODE="${MODES[0]}"
  fi
fi

# Any resolved mode (menued, --mode, or saved) must be one the current runtime
# actually offers; error out with the allowed list otherwise.
mode_valid=no
for m in "${MODES[@]}"; do [ "$m" = "$MODE" ] && mode_valid=yes; done
if [ "$mode_valid" = "no" ]; then
  echo "ERROR: reasoning mode '$MODE' is not one of: ${MODES[*]}" >&2
  exit 1
fi

# Output window depends on the resolved mode: budgeted/max raise it so the
# reasoning budget is actually reachable (a budget larger than -n can never be
# spent). off|on|effort keep the default.
case "$MODE" in
  budgeted|max)
    if [ -n "${REASONING_OUTPUT_MAX:-}" ] && [ "${REASONING_OUTPUT_MAX:-0}" -gt "$DEFAULT_OUTPUT" ] 2>/dev/null; then
      OUTPUT="$REASONING_OUTPUT_MAX"
    else
      logf "WARNING: mode '$MODE' needs REASONING_OUTPUT_MAX > $DEFAULT_OUTPUT to raise the" >&2
      logf "output window; keeping the default of $DEFAULT_OUTPUT. The reasoning budget may" >&2
      logf "not be fully spendable inside it." >&2
    fi
    ;;
esac

# --- Resolve the context-window mode: --context > menu > native default. ---
# A profile that offers more than one context window declares them in the
# CTX_MODES array (the "name|ctx|yarn_factor|arch_ctx_key" entries pick_ctx
# lists). This is how YaRN extension is exposed as an option alongside the
# reasoning-mode menu: 'native' (the default) serves the model's native window
# with no rope scaling, and each yarn* entry says "extend to <ctx> via YaRN
# factor <f> with an override-kv on <arch_ctx_key>". Models without a CTX_MODES
# array (and unmatched/raw models) keep the plain RECOMMENDED_CTX_8GB single
# window and never emit rope flags.
CTX_MODE="native"
if [ "${CTX_MODES+x}" = "x" ] && [ "${#CTX_MODES[@]}" -gt 0 ]; then
  # Default to 'native' when it is offered, else the first declared entry.
  CTX_DEFAULT="native"; default_ok=no
  local_cm=""
  for _cm in "${CTX_MODES[@]}"; do [ "${_cm%%|*}" = "$CTX_DEFAULT" ] && default_ok=yes; done
  [ "$default_ok" = "no" ] && CTX_DEFAULT="${CTX_MODES[0]%%|*}"
  preselect_ctx="$CTX_DEFAULT"; ctx_ok=no
  for _cm in "${CTX_MODES[@]}"; do [ "${_cm%%|*}" = "$preselect_ctx" ] && ctx_ok=yes; done
  ctx_ok=yes  # preselect is guaranteed offered above

  if [ -n "$CLI_CTX" ]; then
    CTX_MODE="$CLI_CTX"
  elif [ -z "$PROFILE_ARG" ] && [ "${#CTX_MODES[@]}" -gt 1 ] && \
       [ "$MODEL_RUNTIME" = "llama.cpp" ] && [ -n "$profile_file" ]; then
    pick_ctx "$preselect_ctx"
    CTX_MODE="$PICK_CTX"
  else
    CTX_MODE="$preselect_ctx"
  fi

  # Validate the resolved mode against the declared list.
  ctx_matched=no
  for _cm in "${CTX_MODES[@]}"; do [ "${_cm%%|*}" = "$CTX_MODE" ] && ctx_matched=yes; done
  if [ "$ctx_matched" = "no" ]; then
    local _names=""
    for _cm in "${CTX_MODES[@]}"; do _names="$_names ${_cm%%|*}"; done
    echo "ERROR: context mode '$CTX_MODE' is not one of:${_names}" >&2
    exit 1
  fi

  # Apply the chosen mode: set CTX, and emit YaRN/override-kv ONLY for a yarn
  # rung. For native (or any entry with empty yarn_factor) clear the rope vars
  # so start_llama_server never emits them - this is what keeps YaRN opt-in.
  for _cm in "${CTX_MODES[@]}"; do
    _n="${_cm%%|*}"; _rest="${_cm#*|}"
    [ "$_n" != "$CTX_MODE" ] && continue
    _cctx="${_rest%%|*}"; _rest="${_rest#*|}"
    _yf="${_rest%%|*}"; _rest="${_rest#*|}"
    _ark="${_rest%%|*}"
    CTX="$_cctx"
    if [ -n "$_yf" ]; then
      ROPE_YARN_FACTOR="$_yf"
      ROPE_YARN_ORIG_CTX="${ROPE_YARN_ORIG_CTX:-262144}"
      ROPE_YARN_OVERRIDE_KV="${_ark:+$_ark=int:$_cctx}"
    else
      unset ROPE_YARN_FACTOR ROPE_YARN_ORIG_CTX ROPE_YARN_OVERRIDE_KV
    fi
    break
  done
  logf "context mode: $CTX_MODE (ctx $CTX${ROPE_YARN_FACTOR:+ via YaRN x$ROPE_YARN_FACTOR})"
else
  # No CTX_MODES array: keep the profile's single window and any explicit
  # ROPE_YARN_* it sets (legacy YaRN profiles like the pre-context-mode Ornith).
  CTX_MODE=""
fi

# --- Step 4/5: start the runtime and flags ---
LOG_FILE="$HOME/.local/state/llama-server.log"
mkdir -p "$(dirname "$LOG_FILE")"

case "$MODEL_RUNTIME" in
  llama.cpp|llama) start_llama_server ;;
  ollama)          start_ollama ;;
  vllm)            start_vllm ;;
  *) echo "ERROR: unknown runtime '$MODEL_RUNTIME'." >&2; exit 1 ;;
esac

# --- Step 6: wait for health, then a tiny smoke completion ---
UP=no
for _ in $(seq 1 30); do
  if runtime_healthy "$PORT" "$MODEL_RUNTIME"; then UP=yes; break; fi
  sleep 2
done
if [ "$UP" != "yes" ]; then
  echo "WARNING: server did not become healthy on port $PORT after 60s." >&2
  echo "Check $LOG_FILE for the actual error." >&2
  notify_kilo "Local model" "Server on port $PORT did not become healthy - see $LOG_FILE"
  exit 1
fi

BASE_URL="http://127.0.0.1:$PORT/v1"
SMOKE_RESPONSE="$(curl -s -X POST "$BASE_URL/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with the word: ok\"}],\"max_tokens\":10}")"
SMOKE_CONTENT="$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    msg = data['choices'][0]['message']
    print((msg.get('content') or msg.get('reasoning_content') or '').strip())
except Exception:
    sys.exit(1)
" "$SMOKE_RESPONSE" 2>/dev/null || true)"
if [ -n "$SMOKE_CONTENT" ]; then
  echo "Smoke test OK - returned: \"$SMOKE_CONTENT\""
else
  echo "WARNING: smoke test returned no usable content. Raw: $SMOKE_RESPONSE" >&2
fi

# --- Step 7: remember this as active + sync the Kilo provider ---
ATTACH="no"
case "$MODEL_RUNTIME" in
  llama.cpp)
    MMPROJ2="$(find "$MODEL_ROOT/$(basename "$(dirname "$MODEL_GGUF")")" \
      -maxdepth 1 -iname 'mmproj-*.gguf' 2>/dev/null | head -n1)"
    [ -n "$MMPROJ2" ] && ATTACH="yes" ;;
  ollama)
    if [ -n "${MMPROJ_REPO:-}" ] && [ -n "${MMPROJ_PATTERN:-}" ]; then ATTACH="yes"; fi ;;
  vllm) : ;;
esac

# Persist the active profile stem so a later fast-path run can re-source the
# profile (and re-offer the reasoning-mode picker / restart) without a scan.
ACTIVE_PROFILE_STEM=""
if [ -n "${PROFILE_ARG:-}" ]; then
  ACTIVE_PROFILE_STEM="$PROFILE_ARG"
elif [ "$MODEL_RUNTIME" = "llama.cpp" ] && [ -n "${MODEL_GGUF:-}" ]; then
  ACTIVE_PROFILE_STEM="$(basename "$(dirname "$MODEL_GGUF")")"
fi

mkdir -p "$STATE_DIR"
printf '%s\n' \
  "ACTIVE_PORT=\"$PORT\"" \
  "ACTIVE_RUNTIME=\"$MODEL_RUNTIME\"" \
  "ACTIVE_BASE_URL=\"$BASE_URL\"" \
  "ACTIVE_MODEL_ID=\"$MODEL_ID\"" \
  "ACTIVE_MODEL_NAME=\"$MODEL_NAME\"" \
  "ACTIVE_CTX=\"$CTX\"" \
  "ACTIVE_OUTPUT=\"$OUTPUT\"" \
  "ACTIVE_MODE=\"$MODE\"" \
  "ACTIVE_REASONING=\"$(mode_to_sync "$MODE")\"" \
  "ACTIVE_EFFORT=\"${REASONING_EFFORT:-$DEFAULT_EFFORT}\"" \
  "ACTIVE_ATTACHMENT=\"$ATTACH\"" \
  "ACTIVE_PROFILE=\"$ACTIVE_PROFILE_STEM\"" \
  "ACTIVE_CTX_MODE=\"${CTX_MODE:-}\"" \
  > "$ACTIVE_STATE"

if [ -x "$BIN_DIR/sync-local-model.sh" ]; then
  logf "Syncing Kilo provider '$KILO_PROVIDER' to $MODEL_ID at $BASE_URL..."
  "$BIN_DIR/sync-local-model.sh" \
    --base-url "$BASE_URL" \
    --api-key "$KILO_API_KEY" \
    --model-id "$MODEL_ID" \
    --model-name "$MODEL_NAME" \
    --context "$CTX" \
    --output "$OUTPUT" \
    --reasoning "$(mode_to_sync "$MODE")" \
    --effort "${REASONING_EFFORT:-$DEFAULT_EFFORT}" \
    --attachment "$ATTACH"
else
  echo "WARNING: $BIN_DIR/sync-local-model.sh not found - Kilo provider config" >&2
  echo "was NOT updated. Re-run install.sh to regenerate it." >&2
fi

notify_kilo "Local model" "$MODEL_NAME is running at $BASE_URL. Reload/restart Kilo Code so it re-reads the provider config."
logf "Done. Reload the VSCodium/Kilo Code window or restart Kilo to pick up the provider change."