# 20-model-download-opts.sh
# Sourced by install.sh. The non-llama.cpp download/setting prompts plus the
# wrapper that orders the whole "download the local model?" flow. Holds:
#   prompt_runtime_context() - plain context prompt for ollama/vllm runtimes
#   prompt_mmproj()          - multimodal projector download offer
#   prompt_reasoning()       - reasoning mode/effort (applies to every runtime)
#   prompt_model_download_settings() - the wrapper that calls the others in
#                                      order (and hands llama.cpp profiles off
#                                      to 20-model-sizing.sh)
#
# Depends on globals set by prompt_model_profile() in 20-model-profile.sh and
# the sizing functions in 20-model-sizing.sh (llama.cpp path).

# Plain context prompt for non-llama.cpp runtimes (ollama/vllm): no quant or
# KV math applies, but the kilo provider entry still needs the context limit.
prompt_runtime_context() {
  if [ -z "$LLAMA_CTX_SIZE" ] || [ "$LLAMA_CTX_SIZE" = "16384" ]; then
    if [ -n "${RECOMMENDED_CTX_8GB:-}" ]; then
      LLAMA_CTX_SIZE="$RECOMMENDED_CTX_8GB"
    fi
  fi
  echo
  echo "Context window for this runtime. Kilo Code truncates conversations at"
  echo "this limit, and it's what vllm's --max-model-len passes to the server;"
  echo "the model's own real ceiling is authoritative if it's lower."
  ask LLAMA_CTX_SIZE "Context length in tokens"
}

# Multimodal projector (mmproj) offer - only when the chosen profile declares
# MMPROJ_REPO + MMPROJ_PATTERN AND runs llama.cpp (the only runtime whose
# --mmproj flag this project wires up).
prompt_mmproj() {
  if [ "$MODEL_RUNTIME" = "llama.cpp" ] && [ -n "${MMPROJ_REPO:-}" ] && [ -n "${MMPROJ_PATTERN:-}" ]; then
    echo
    echo "$PROFILE_NAME supports image input via llama-server's --mmproj flag"
    echo "($MMPROJ_REPO, pattern '$MMPROJ_PATTERN'). Downloading the projector"
    echo "file is a one-time cost; with it, the kilo provider entry advertises"
    echo "real image attachment support."
    ask DOWNLOAD_MMPROJ "Download the multimodal projector? (yes/no)"
  fi
  [ "$DOWNLOAD_MMPROJ" = "yes" ] || DOWNLOAD_MMPROJ="no"
}

# Reasoning mode/effort - applies to every runtime, since the kilo provider
# entry carries reasoning regardless of which server runs the model.
prompt_reasoning() {
  echo
  echo "Reasoning/\"thinking\" mode for $PROFILE_NAME:"
  echo "  off     (default) - thinking is measured ~13x tokens / ~11x latency"
  echo "                      for no tool-call gain on this project's tests"
  echo "                      (see README \"Thinking mode\"); install.sh's"
  echo "                      --enable-thinking/--disable-thinking flags always win"
  echo "  on      - force reasoning on"
  echo "  effort  - reasoning on with a configurable effort level"
  ask REASONING_MODE "Reasoning mode (off/on/effort)"
  case "$REASONING_MODE" in
    off|on|effort) ;;
    *) echo "Didn't recognize '$REASONING_MODE', keeping 'off'." >&2; REASONING_MODE="off" ;;
  esac
  if [ "$REASONING_MODE" = "effort" ]; then
    ask REASONING_EFFORT "Reasoning effort (low/medium/high)"
  fi
}

# Wrapper: everything asked only when a download/re-check of the model is
# wanted this run. Ordered so each later prompt can rely on earlier answers.
# llama.cpp profiles get the full quant -> VRAM/context -> headroom -> spec
# pipeline (20-model-sizing.sh); ollama/vllm get a plain context prompt plus
# the cross-runtime reasoning + mmproj prompts.
prompt_model_download_settings() {
  ask DOWNLOAD_MODEL_NOW "Download the local model now? (yes/no, big download if not already cached)"
  if [ "$DOWNLOAD_MODEL_NOW" = "yes" ]; then
    if [ "$MODEL_RUNTIME" = "llama.cpp" ]; then
      prompt_quant_choice
      prompt_vram_and_context
      prompt_vram_headroom
      prompt_spec_decoding
      prompt_mmproj
    else
      prompt_runtime_context
    fi
    prompt_reasoning
  fi
}