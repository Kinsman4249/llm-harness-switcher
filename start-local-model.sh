#!/usr/bin/env bash
# start-local-model.sh
# Kilo-mode template, copied into $BIN_DIR by install.sh (install.d/80-
# launcher.sh). Reads install-time config from ~/.config/claude-local-setup.conf
# at runtime, so re-running install.sh is all that's needed to change it. The
# whole kilo desktop flow in one script:
#
#   1. If a server is already healthy on the active runtime's port, skip to
#      step 6 (a click just re-syncs the Kilo provider config without
#      restarting anything).
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
#                     or a mode a profile's REASONING_MODES offers); ignored
#                     (with a warning) if a mode switch would need a restart
#                     of an already-running server

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
    --help|-h|help)
      echo "Usage: $0 [--profile <stem>] [--mode <name>]"
      echo "Without --profile, scans for local models and shows a menu."
      echo "Without --mode and when the profile's REASONING_MODES offers more"
      echo "than one mode, an interactive menu lets you pick one."
      echo "--mode <name> forces the reasoning mode directly. Valid names are"
      echo "the profile's REASONING_MODES (typically off|on|budgeted|max), or"
      echo "the legacy off|on|effort when the profile sets none."
      exit 0
      ;;
    *) shift ;;
  esac
done

logf() { printf '%s\n' "$*"; }

notify_kilo() {
  local title="$1" body="$2"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$body"
  else
    logf "[kilo] $title: $body"
  fi
}

runtime_healthy() {
  # $1=port $2=runtime. llama.cpp has /health; ollama's closest is /api/tags;
  # vllm has /v1/models (its /health returns 200 too, but /v1/models also
  # proves the model loaded rather than just the server).
  local port="$1" runtime="$2"
  case "$runtime" in
    ollama) curl -s -o /dev/null "http://127.0.0.1:$port/api/tags" ;;
    vllm)   curl -s -o /dev/null "http://127.0.0.1:$port/v1/models" ;;
    *)      curl -s -o /dev/null "http://127.0.0.1:$port/health" ;;
  esac
  return $?
}

runtime_default_port() {
  local runtime="$1"
  case "$runtime" in
    ollama) echo "11434" ;;
    vllm)   echo "8000" ;;
    *)      echo "8080" ;;
  esac
}

run_in_model_env() {
  # Runs a shell command string in the same environment the model runtime
  # lives in (inside the distrobox container when PACKAGING=distrobox).
  if [ "$PACKAGING" = "distrobox" ]; then
    distrobox enter "$CONTAINER_NAME" -- bash -lc "$1"
  else
    bash -lc "$1"
  fi
}

find_profile_file() {
  # $1 = profile stem (or a substring to search for). Prints the profile file
  # path if found in any PROFILE_DIRS entry, else nothing.
  local want="$1" dir f base
  for dir in $PROFILE_DIRS; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.sh; do
      [ -f "$f" ] || continue
      base="$(basename "$f" .sh)"
      if [ "$base" = "$want" ]; then
        echo "$f"
        return
      fi
    done
  done
}

mode_to_sync() {
  # Translate a runtime reasoning mode to the off|on|effort vocabulary
  # sync-local-model.sh / kilo-jsonc-edit.py understand. off/effort pass
  # through; on and the sub-modes that emit --reasoning on (budgeted/max)
  # both become plain "on" for the kilo entry.
  case "${1:-off}" in
    on|budgeted|max) echo "on" ;;
    effort)          echo "effort" ;;
    *)               echo "off" ;;
  esac
}

mode_desc() {
  # One-line menu description for a reasoning mode (flag effect + output
  # window). Runs after the profile is sourced, so the REASONING_* fields
  # that dry it up are available.
  case "$1" in
    off)      echo "thinking off - tool-calling default, min tokens/latency" ;;
    on)       echo "thinking on - template default; unbounded within the output window" ;;
    budgeted) echo "thinking on, budget ${REASONING_BUDGET_DEFAULT:-8192} tokens; output capped ${REASONING_OUTPUT_MAX:-$DEFAULT_OUTPUT}" ;;
    max)      echo "thinking on, unlimited budget; output capped ${REASONING_OUTPUT_MAX:-$DEFAULT_OUTPUT}" ;;
    effort)   echo "thinking on with effort ${REASONING_EFFORT:-$DEFAULT_EFFORT} (legacy)" ;;
    *)        echo "$1" ;;
  esac
}

# --- Step 1: already running on the active port? Re-sync only. ---
if [ -f "$ACTIVE_STATE" ]; then
  # shellcheck source=/dev/null
  source "$ACTIVE_STATE"
  if [ -n "${ACTIVE_PORT:-}" ] && [ -n "${ACTIVE_RUNTIME:-}" ] && runtime_healthy "$ACTIVE_PORT" "$ACTIVE_RUNTIME"; then
    logf "A model server is already running at ${ACTIVE_BASE_URL:-http://127.0.0.1:$ACTIVE_PORT/v1}."
    logf "  running mode: ${ACTIVE_MODE:-$(mode_to_sync "${ACTIVE_REASONING:-off}")}"
    if [ -n "$CLI_MODE" ] && [ "$CLI_MODE" != "${ACTIVE_MODE:-${ACTIVE_REASONING:-off}}" ]; then
      logf "--mode $CLI_MODE differs from the running mode; switching the reasoning"
      logf "mode requires restarting llama-server. Stop the running server first "
      logf "(the menu / --mode flags apply at a fresh start). Re-syncing the current server."
    fi
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
  CTX="${LLAMA_CTX_SIZE:-${RECOMMENDED_CTX_8GB:-$DEFAULT_CTX}}"
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
  CTX="${LLAMA_CTX_SIZE:-${RECOMMENDED_CTX_8GB:-$DEFAULT_CTX}}"
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
  echo
  echo "Reasoning/thinking mode for this run?"
  for i in "${!MODES[@]}"; do
    printf '  %d) %s - %s\n' "$((i+1))" "${MODES[$i]}" "$(mode_desc "${MODES[$i]}")"
  done
  echo "  (Enter) $preselect"
  PICK_MODE=""
  while [ -z "$PICK_MODE" ]; do
    read -rp "Pick a mode: " PICK_MODE
    if [ -z "$PICK_MODE" ]; then
      PICK_MODE="$preselect"
    elif [[ "$PICK_MODE" =~ ^[0-9]+$ ]] && [ "$PICK_MODE" -ge 1 ] && [ "$PICK_MODE" -le "${#MODES[@]}" ]; then
      PICK_MODE="${MODES[$((PICK_MODE-1))]}"
    else
      logf "Invalid choice '$PICK_MODE' - enter 1-${#MODES[@]} or Enter for $preselect." >&2
      PICK_MODE=""
    fi
  done
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

# --- Step 4/5: start the runtime and flags ---
LOG_FILE="$HOME/.local/state/llama-server.log"
mkdir -p "$(dirname "$LOG_FILE")"

start_llama_server() {
  # Flags are rebuilt here at runtime by sourcing the matched profile - the
  # same generator install.d/80-launcher.sh uses for the classic-mode script,
  # so a profile's tested values (NGL_MODE, CACHE_TYPE_K/V, FFN offload, spec
  # decoding, sampling, reasoning, mmproj) apply unchanged in kilo mode.
  local args=()
  if [ "$PACKAGING" = "distrobox" ]; then
    args+=( distrobox enter "$CONTAINER_NAME" -- "$LLAMA_SERVER_BIN" )
  else
    args+=( "$LLAMA_SERVER_BIN" )
  fi
  args+=( -m "$MODEL_GGUF" )
  args+=( -c "$CTX" -b "$DEFAULT_BATCH" -n "$OUTPUT" )
  args+=( -fa on --cache-type-k "${CACHE_TYPE_K:-q8_0}" --cache-type-v "${CACHE_TYPE_V:-q8_0}" )

  if [ "${KV_MODEL:-manual}" = "manual" ]; then
    args+=( --fit off )
  else
    args+=( --fit on )
  fi

  if [ "${NGL_MODE:-fixed}" != "fit" ]; then
    args+=( -ngl 99 )
  fi

  if [ "${LLAMA_CPU_FFN_LAYERS:-0}" -gt 0 ] 2>/dev/null && [ -n "${N_LAYERS:-}" ]; then
    FIRST_OFFLOAD=$(( N_LAYERS - LLAMA_CPU_FFN_LAYERS ))
    [ "$FIRST_OFFLOAD" -lt 0 ] && FIRST_OFFLOAD=0
    LAYER_RANGE="$(seq -s'|' "$FIRST_OFFLOAD" "$((N_LAYERS - 1))")"
    args+=( --override-tensor "blk\\.($LAYER_RANGE)\\.ffn_(gate|up|down)\\.weight=CPU" )
  fi
  if [ "${LLAMA_NO_KV_OFFLOAD:-no}" = "yes" ]; then
    args+=( --no-kv-offload )
  fi
  if [ -n "${PLE_TENSOR_REGEX:-}" ] && [ "${KEEP_PLE_ON_CPU:-no}" = "yes" ]; then
    args+=( --override-tensor "${PLE_TENSOR_REGEX}=CPU" )
  fi

  case "${SPEC_MODE:-none}" in
    self-mtp)
      args+=( --spec-type draft-mtp --spec-draft-n-max "${LLAMA_SPEC_DRAFT_N:-2}" ) ;;
    draft-model)
      DRAFT_PATH="$(find "$MODEL_ROOT/$(basename "$(dirname "$MODEL_GGUF")")" \
        -maxdepth 1 -iname '*${DRAFT_PATTERN:-}*.gguf' 2>/dev/null | head -n1)"
      if [ -n "$DRAFT_PATH" ]; then
        args+=( -md "$DRAFT_PATH" --spec-type draft-mtp --spec-draft-n-max "${LLAMA_SPEC_DRAFT_N:-2}" -ngld 0 )
      fi ;;
  esac

  [ -n "${DEFAULT_TEMP:-}" ]  && args+=( --temp "$DEFAULT_TEMP" )
  [ -n "${DEFAULT_TOP_P:-}" ] && args+=( --top-p "$DEFAULT_TOP_P" )
  [ -n "${DEFAULT_TOP_K:-}" ] && args+=( --top-k "$DEFAULT_TOP_K" )

  case "${MODE:-${REASONING_MODE:-$DEFAULT_REASONING}}" in
    on)       args+=( --reasoning on ) ;;
    budgeted) args+=( --reasoning on --reasoning-budget "${REASONING_BUDGET_DEFAULT:-8192}" ) ;;
    max)      args+=( --reasoning on --reasoning-budget -1 ) ;;
    effort)   args+=( --reasoning effort "${REASONING_EFFORT:-$DEFAULT_EFFORT}" ) ;;
    *)        args+=( --reasoning off ) ;;
  esac

  MMPROJ="$(find "$MODEL_ROOT/$(basename "$(dirname "$MODEL_GGUF")")" \
    -maxdepth 1 -iname 'mmproj-*.gguf' 2>/dev/null | head -n1)"
  [ -n "$MMPROJ" ] && args+=( --mmproj "$MMPROJ" )

  args+=( --port "$PORT" --host 127.0.0.1 )

  if runtime_healthy "$PORT" llama.cpp; then
    logf "llama-server is already running on port $PORT - reusing it."
    return 0
  fi

  local CMD
  printf -v CMD '%q ' "${args[@]}"
  logf "Starting: $CMD"
  nohup bash -lc "$CMD" >> "$LOG_FILE" 2>&1 &
  disown 2>/dev/null || true
}

start_ollama() {
  if ! runtime_healthy "$PORT" ollama; then
    if [ "$PACKAGING" = "distrobox" ]; then
      OLLAMA_SERVE_CMD="distrobox enter $CONTAINER_NAME -- bash -lc 'exec ollama serve'"
    else
      OLLAMA_SERVE_CMD="ollama serve"
    fi
    logf "Starting ollama serve on port $PORT..."
    nohup bash -lc "$OLLAMA_SERVE_CMD" >> "$LOG_FILE" 2>&1 &
    disown 2>/dev/null || true
    for _ in $(seq 1 15); do
      runtime_healthy "$PORT" ollama && break
      sleep 1
    done
  fi
  logf "Loading $MODEL_ID on demand (ollama run)..."
  run_in_model_env "ollama run '$MODEL_ID' 'reply with the word: ok' >/dev/null 2>&1 || true"
}

start_vllm() {
  if runtime_healthy "$PORT" vllm; then
    logf "vllm is already serving on port $PORT - reusing it."
    return 0
  fi
  if [ "$PACKAGING" = "distrobox" ]; then
    VLLM_CMD="distrobox enter $CONTAINER_NAME -- bash -lc 'exec vllm serve \"$MODEL_ID\" --port \"$PORT\" --max-model-len \"$CTX\"'"
  else
    VLLM_CMD="vllm serve \"$MODEL_ID\" --port \"$PORT\" --max-model-len \"$CTX\""
  fi
  logf "Starting vllm on port $PORT (model $MODEL_ID, ctx $CTX)..."
  nohup bash -lc "$VLLM_CMD" >> "$LOG_FILE" 2>&1 &
  disown 2>/dev/null || true
}

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