# 80-launcher-build.sh
# Sourced by install.sh. Step 10 (build half): build_start_script() generates
# start-local-llama.sh with every tuning flag baked in. The desktop-icon half
# (build_desktop_launcher, build_kilo_launcher) lives in 80-launcher-desktop.sh
# and the launch-and-verify half (launch_and_verify, launch_and_verify_kilo,
# run_launcher_step) in 80-launcher-verify.sh. The run_launcher_step() wrapper
# in that file reproduces the original single big "if LLAMA_SERVER_BIN and
# LLAMA_MODEL_PATH are both set" guard around the classic callers.

# --- Step 10: generate start-local-llama.sh with all the tuning flags baked in ---
build_start_script() {
  # KV cache quant type: q8_0/q8_0 unless a model profile sets its own
  # (CACHE_TYPE_K/CACHE_TYPE_V are new, optional profile fields - a profile
  # that doesn't set them gets byte-identical output to before this existed).
  # Not exposed as an install.sh prompt: the space of viable combos is
  # build- and model-specific (see model-profiles/qwen35-9b.sh's comment on
  # this - mismatched K/V quant types silently fell onto a catastrophically
  # slow non-fused CUDA path on this project's 2026-07-23 llama.cpp build,
  # not a quality problem, just no fast kernel for that combo), so this is a
  # profile-author decision made after actually benchmarking it, not
  # something to ask a user blind.
  CACHE_TYPE_K="${CACHE_TYPE_K:-q8_0}"
  CACHE_TYPE_V="${CACHE_TYPE_V:-q8_0}"

  # Optional VRAM-headroom flags (see the prompts above): neither is on by
  # default, both trade some speed for more room when the quant/context
  # combination above doesn't fit.
  OT_ARGS=""
  if [ "${LLAMA_CPU_FFN_LAYERS:-0}" -gt 0 ] 2>/dev/null; then
    FIRST_OFFLOAD=$(( N_LAYERS - LLAMA_CPU_FFN_LAYERS ))
    if [ "$FIRST_OFFLOAD" -lt 0 ]; then FIRST_OFFLOAD=0; fi
    LAYER_RANGE="$(seq -s'|' "$FIRST_OFFLOAD" "$((N_LAYERS - 1))")"
    OT_ARGS=" --override-tensor \"blk\\.(${LAYER_RANGE})\\.ffn_(gate|up|down)\\.weight=CPU\""
  fi
  KVOFFLOAD_ARGS=""
  if [ "$LLAMA_NO_KV_OFFLOAD" = "yes" ]; then
    KVOFFLOAD_ARGS=" --no-kv-offload"
  fi
  # Kept separate from OT_ARGS on purpose (see the prompt above): this is the
  # opposite tradeoff from the dense-FFN offload, not the same knob again.
  PLE_OFFLOAD_ARGS=""
  if [ -n "${PLE_TENSOR_REGEX:-}" ] && [ "$KEEP_PLE_ON_CPU" = "yes" ]; then
    PLE_OFFLOAD_ARGS=" --override-tensor \"${PLE_TENSOR_REGEX}=CPU\""
  fi

  # Sampling defaults from the model profile, set on the server so they
  # apply regardless of what the client sends. Empty in a profile (Qwen)
  # means "don't override the server/client default" - no flags emitted.
  SAMPLING_ARGS=""
  [ -n "${DEFAULT_TEMP:-}" ]  && SAMPLING_ARGS="$SAMPLING_ARGS --temp $DEFAULT_TEMP"
  [ -n "${DEFAULT_TOP_P:-}" ] && SAMPLING_ARGS="$SAMPLING_ARGS --top-p $DEFAULT_TOP_P"
  [ -n "${DEFAULT_TOP_K:-}" ] && SAMPLING_ARGS="$SAMPLING_ARGS --top-k $DEFAULT_TOP_K"

  # THINKING_KWARG_KEY (profile field, empty unless a profile sets it): the
  # chat-template-kwargs key this model's template uses to toggle reasoning
  # (every profile that sets it so far uses "enable_thinking" - see the
  # CONFIRMED note next to THINKING_KWARG_KEY in whichever model-profiles/
  # *.sh set it). Always emitted explicitly - on/off/effort - rather than
  # leaving it to the GGUF's baked-in chat-template default, in either
  # direction. REASONING_MODE (profile default "off", overridable at the
  # prompt and by install.sh's --enable-thinking/--disable-thinking flags)
  # decides how.
  #
  # CONFIRMED by reading common/arg.cpp on this project's 2026-07-23 llama.cpp
  # checkout: "enable_thinking" via --chat-template-kwargs is deprecated
  # ("Use --reasoning on / --reasoning off instead" warning, still functional
  # but noisy) in favor of -rea/--reasoning [on|off|auto], which internally
  # sets that same default_template_kwargs["enable_thinking"] key (plus
  # params.enable_reasoning) without the warning. --reasoning only ever
  # writes the literal "enable_thinking" key, so it's only a safe substitute
  # when THINKING_KWARG_KEY is exactly that (true for every profile so far) -
  # falls back to the old flag (deprecation warning and all, still correct)
  # if a future profile ever uses a different key. Newer llama.cpp builds also
  # accept "--reasoning effort <level>" (low/medium/high) for effort-based
  # reasoning; a profile's REASONING_MODE=effort maps to that.
  CTK_ARGS=""
  if [ "${THINKING_KWARG_KEY:-}" = "enable_thinking" ]; then
    case "${REASONING_MODE:-off}" in
      on)
        CTK_ARGS=" --reasoning on"
        ;;
      effort)
        CTK_ARGS=" --reasoning effort ${REASONING_EFFORT:-low}"
        ;;
      *)
        CTK_ARGS=" --reasoning off"
        ;;
    esac
  elif [ -n "${THINKING_KWARG_KEY:-}" ]; then
    case "${REASONING_MODE:-off}" in
      on|effort)
        CTK_ARGS=" --chat-template-kwargs '{\"${THINKING_KWARG_KEY}\":true}'"
        ;;
      *)
        CTK_ARGS=" --chat-template-kwargs '{\"${THINKING_KWARG_KEY}\":false}'"
        ;;
    esac
  fi

  # ARCH_NOTES comes from the model profile (model-profiles/*.sh) as one long
  # line; wrap it here to match the comment column the rest of this header
  # uses, first line after "offload all layers to GPU (", continuation lines
  # under it, closing paren appended to the last line.
  ARCH_NOTES_WRAPPED="$(echo "${ARCH_NOTES})" | fold -s -w 51 | sed '2,$s/^/#                          /')"

  # NGL_MODE (profile field, defaults to "fixed" when a profile doesn't set
  # it - true for every profile except MoE ones): whether to pin -ngl 99 or
  # leave it unset so --fit can choose it itself.
  #
  # CONFIRMED by reading llama.cpp's --fit implementation (common/fit.cpp,
  # checked against this project's 2026-07-23 llama.cpp checkout):
  # common_params_fit_impl() throws (caught, logged as a warning, otherwise
  # harmless) and skips its entire layer-placement/MoE-expert-offload pass
  # the moment n_gpu_layers is already explicit - see the
  # "n_gpu_layers already set by user ... abort" check in that file. The
  # ctx-size auto-fit (what KV_MODEL=probe profiles were already documented
  # as relying on --fit for) happens earlier in the same function and is
  # unaffected either way. In other words: this project's longstanding
  # "-ngl 99, always" convention silently disables --fit's automatic MoE
  # CPU/GPU expert placement for any MoE model - harmless for Qwen/Gemma
  # (neither has MoE layers, so that pass would have been a no-op anyway),
  # but load-bearing for a MoE profile like Nemotron 3 Nano 30B-A3B, which
  # depends on it to fit an 8GB card at all (see model-profiles/
  # nemotron3-nano-30b.sh ARCH_NOTES). NGL_MODE="fit" leaves -ngl unset so
  # that whole pass can run instead.
  NGL_FLAG=" -ngl 99"
  NGL_COMMENT="# -ngl 99                 offload all layers to GPU ($ARCH_NOTES_WRAPPED"
  if [ "${NGL_MODE:-fixed}" = "fit" ]; then
    NGL_FLAG=""
    NGL_COMMENT="# (no -ngl: how many layers, and how many of this MoE model's experts
#                          specifically, end up on GPU vs CPU RAM, is left
#                          entirely to --fit below - an explicit -ngl would
#                          disable that, see the comment above
#                          build_start_script() in install.d/80-launcher-build.sh
#                          ($ARCH_NOTES_WRAPPED"
  fi

  # Speculative-decoding flags depend on the profile's SPEC_MODE. Never emit
  # --spec-type draft-mtp without a resolved -md for draft-model profiles -
  # if LLAMA_DRAFT_PATH didn't resolve (Step 9c warned about this already),
  # fall back to no speculative decoding at all rather than a broken flag.
  SPEC_ARGS=""
  case "$SPEC_MODE" in
    self-mtp)
      SPEC_ARGS=" --spec-type draft-mtp --spec-draft-n-max $LLAMA_SPEC_DRAFT_N"
      SPEC_COMMENT="# --spec-type draft-mtp   self-speculative decoding via the model's MTP head"
      ;;
    draft-model)
      if [ -n "$LLAMA_DRAFT_PATH" ]; then
        SPEC_ARGS=" -md \"$LLAMA_DRAFT_PATH\" --spec-type draft-mtp --spec-draft-n-max $LLAMA_SPEC_DRAFT_N -ngld 0"
        SPEC_COMMENT="# -md / --spec-type       speculative decoding via a separate drafter model
#                          (-ngld 0 keeps the drafter on CPU rather than
#                          eating into the main model's VRAM budget - see
#                          gemma4-support-spec.md section 4)"
      else
        SPEC_COMMENT="# (speculative decoding skipped: no drafter model resolved for this profile)"
      fi
      ;;
    *)
      SPEC_COMMENT="# (no speculative decoding for this profile)"
      ;;
  esac

  # Multimodal projector: pass --mmproj when the profile's projector was
  # downloaded (DOWNLOAD_MMPROJ=yes and MMPROJ_REPO/MMPROJ_PATTERN set). This
  # is what makes image input real - without it, a multimodal GGUF still only
  # serves text (see README "Multimodal weights").
  MMPROJ_ARGS=""
  [ -n "${LLAMA_MMPROJ_PATH:-}" ] && MMPROJ_ARGS=" --mmproj \"$LLAMA_MMPROJ_PATH\""

  # Everything optional gets folded into one trailing flag string, appended
  # directly to the --host line below rather than given its own backslash-
  # continued line - a conditionally-empty line in the middle of a `\`
  # continuation chain silently breaks the command in two (the shell treats
  # the blank line as ending it), so nothing optional may sit on its own
  # line here even when guarded by [ -n ... ].
  EXTRA_FLAGS="$OT_ARGS$KVOFFLOAD_ARGS$PLE_OFFLOAD_ARGS$SPEC_ARGS$SAMPLING_ARGS$CTK_ARGS$MMPROJ_ARGS"

  # --fit off (manual KV sizing, Qwen): the context/VRAM budget above was
  # computed by hand, and --fit on would fight that manual -ngl/--override-
  # tensor budget - see the discussion linked below.
  # --fit on (probe KV sizing, Gemma): no hand-rolled budget exists for this
  # profile, so let llama.cpp size the context itself, up to the ceiling
  # you gave it, and read back what it actually picked (see Step 11 below).
  if [ "$KV_MODEL" = "manual" ]; then
    FIT_FLAG="--fit off"
    FIT_COMMENT="# --fit off               disable llama.cpp's automatic VRAM-fitting pass: it
#                          can't override the manual -ngl/--override-tensor
#                          budget below, so left on it only produces a
#                          harmless but alarming-looking \"common_fit_params:
#                          ... abort\" warning on every startup (see
#                          https://github.com/ggml-org/llama.cpp/discussions/18049)"
  else
    FIT_FLAG="--fit on"
    FIT_COMMENT="# --fit on                let llama.cpp size the KV cache itself, up to -c
#                          below as a ceiling - this profile has no manual
#                          KV-sizing formula (see model-profiles/$MODEL_PROFILE.sh)"
  fi

  cat > "$BIN_DIR/start-local-llama.sh" << EOF
#!/usr/bin/env bash
# start-local-llama.sh
# Generated by install.sh - re-run install.sh to change any of these flags,
# don't hand-edit (your edits won't survive the next install.sh run).
#
$NGL_COMMENT
# -fa on                  flash attention (required for KV cache quant below)
# --cache-type-k/v $CACHE_TYPE_K/$CACHE_TYPE_V   KV cache quantization (see model-profiles/$MODEL_PROFILE.sh if not q8_0/q8_0)
$SPEC_COMMENT
$FIT_COMMENT
# --no-webui (conditional) llama.cpp's built-in browser chat UI is off by
#                          default (you normally only talk to this server
#                          through Claude Code / the API), but
#                          LLAMA_ENABLE_WEBUI=yes ./start-local-llama.sh
#                          leaves it on instead - see model-session.sh's
#                          "browser chat UI" prompt, which sets this for you.
#                          Same process, same port, same model already in
#                          VRAM either way: --no-webui only toggles whether
#                          static chat-UI assets are served alongside the
#                          API on that one listener, so this never loads a
#                          second copy of the model.
# (sliding-window attention: llama.cpp only allocates the local-attention
#  window's worth of KV cache by default, not the full context, on models
#  that use it - this is the default and stays on; --swa-full is never
#  passed here, which would disable that saving)
# -b $LLAMA_BATCH_SIZE               batch size (llama.cpp's own default is 512)
# -n $LLAMA_N_PREDICT              safety cap on tokens per response - neither
#                          llama-server nor Zoo Code's own client settings cap
#                          output otherwise, so a degenerate/repeating
#                          generation would run until it fills the whole
#                          context instead of stopping on its own
$([ -n "$OT_ARGS" ] && echo "# --override-tensor          last $LLAMA_CPU_FFN_LAYERS layers' FFN weights forced to CPU RAM")
$([ -n "$KVOFFLOAD_ARGS" ] && echo "# --no-kv-offload            whole KV cache kept in system RAM instead of VRAM")
$([ -n "$PLE_OFFLOAD_ARGS" ] && echo "# --override-tensor          Per-Layer Embedding tables kept in system RAM (lookup-only, cheap to offload)")
$([ -n "$SAMPLING_ARGS" ] && echo "# --temp/--top-p/--top-k     sampling defaults from the $PROFILE_NAME model card")
$([ -n "$CTK_ARGS" ] && echo "# ${CTK_ARGS# }                reasoning explicitly forced ${REASONING_MODE:-off} (profile default / prompt answer; --enable-thinking and --disable-thinking override)")
# LOG_FILE            every run's output also goes here (overwritten each
#                      start, not appended) so a crash is diagnosable even if
#                      it happened in a terminal window that already closed.
#
# Runs in the foreground so you can watch its own log output. Ctrl+C to stop.
LOG_FILE="\$HOME/.local/state/llama-server.log"
mkdir -p "\$(dirname "\$LOG_FILE")"

if curl -s -o /dev/null "http://127.0.0.1:$LLAMA_PORT/health"; then
  echo "llama-server is already running at http://127.0.0.1:$LLAMA_PORT - not starting a second one."
  echo "(If you meant to restart it, stop the running one first: Ctrl+C in its terminal, or"
  echo "pkill -f llama-server inside the $CONTAINER_NAME container.)"
  exit 0
fi

WEBUI_FLAG="--no-webui"
if [ "\${LLAMA_ENABLE_WEBUI:-no}" = "yes" ]; then
  WEBUI_FLAG=""
  echo "Browser chat UI enabled - once healthy, open http://127.0.0.1:$LLAMA_PORT in a browser."
fi

distrobox enter "$CONTAINER_NAME" -- "$LLAMA_SERVER_BIN" \\
  -m "$LLAMA_MODEL_PATH"$NGL_FLAG \\
  -c $LLAMA_CTX_SIZE \\
  -b $LLAMA_BATCH_SIZE \\
  -n $LLAMA_N_PREDICT \\
  -fa on \\
  --cache-type-k $CACHE_TYPE_K --cache-type-v $CACHE_TYPE_V \\
  $FIT_FLAG \\
  \$WEBUI_FLAG \\
  --port $LLAMA_PORT --host 127.0.0.1$EXTRA_FLAGS \\
  2>&1 | tee "\$LOG_FILE"
EOF
  chmod +x "$BIN_DIR/start-local-llama.sh"
  log "Generated $BIN_DIR/start-local-llama.sh"
}