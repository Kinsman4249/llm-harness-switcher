#!/usr/bin/env bash
# start-local-model-lib.sh
# Sourced by start-local-model.sh (both are copied into $BIN_DIR together by
# install.d/80-launcher.sh). Holds every function the launcher uses, so the
# main script is a thin orchestration of config defaults, arg parsing, and the
# step sequence below. Kept as a separate file purely to keep
# start-local-model.sh under a comfortable size; the two must always be
# shipped and installed together.

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

pick_mode() {
  # $1 = preselect mode. Prompts from the global MODES array (built before the
  # call by splitting a profile's REASONING_MODES); writes into global PICK_MODE.
  # Bare Enter accepts the preselect; invalid input re-prompts.
  local preselect="$1" i
  echo
  echo "Reasoning/thinking mode?"
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
}

stop_llama_server() {
  # $1 = port. Kills only a llama-server bound to that port, then waits for its
  # health endpoint to go dark (so a following start_llama_server starts a real
  # process instead of "reusing" the dying one).
  local port="$1"
  if [ "$PACKAGING" = "distrobox" ]; then
    distrobox enter "$CONTAINER_NAME" -- pkill -f "llama-server.* --port $port" 2>/dev/null || true
  else
    pkill -f "llama-server.* --port $port" 2>/dev/null || true
  fi
  for _ in $(seq 1 10); do
    runtime_healthy "$port" llama.cpp || return 0
    sleep 1
  done
}

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

  # YaRN past the model's n_ctx_train, from a profile's ROPE_YARN_* fields.
  # Without these, -c > n_ctx_train on rope-scalable arches is capped/rejected;
  # the --override-kv raises the GGUF's context_length so the window is accepted.
  if [ -n "${ROPE_YARN_FACTOR:-}" ] && [ -n "${ROPE_YARN_ORIG_CTX:-}" ]; then
    args+=( --rope-scaling yarn --rope-scale "$ROPE_YARN_FACTOR" --yarn-orig-ctx "$ROPE_YARN_ORIG_CTX" )
  fi
  if [ -n "${ROPE_YARN_OVERRIDE_KV:-}" ]; then
    args+=( --override-kv "$ROPE_YARN_OVERRIDE_KV" )
  fi

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