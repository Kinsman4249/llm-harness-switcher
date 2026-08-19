# 80-launcher.sh
# Sourced by install.sh. Step 10: generates start-local-llama.sh with every
# tuning flag baked in (and, if requested, a desktop icon for it), then
# walks you through starting it once and smoke-tests the proxy end to end.
# Split into build_start_script() / build_desktop_launcher() /
# launch_and_verify(), called in order by run_launcher_step() - that
# wrapper reproduces the original single big "if LLAMA_SERVER_BIN and
# LLAMA_MODEL_PATH are both set" guard around all three.

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
#                          build_start_script() in install.d/80-launcher.sh
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

# --- Step 9b: desktop icon that opens start-local-llama.sh in its own ---
# --- terminal window, so starting the model is a single double-click. ---
# Also offers, every time the icon is used to actually start the server (not
# on the "already running" fast path), to install/launch OpenHands - a
# dockerless pip-based AI coding agent CLI (https://docs.openhands.dev/) -
# inside the same $CONTAINER_NAME, pointed at this project's local litellm
# proxy, AND to enable llama.cpp's own browser chat UI on the server it's
# about to start. Both kept out of the model-only fast path (the "already
# running, exit 0" branch below) on purpose: that path is for "I just need
# the server up", not "open/enable something extra" - and if the server is
# already running, its --no-webui choice was already locked in when it
# started, so there's nothing left to toggle without a restart.
build_desktop_launcher() {
  if [ "$INSTALL_MODE" != "classic" ]; then
    log "Skipping classic OpenHands/browser-chat-ui launcher (mode is $INSTALL_MODE)"
    return
  fi
  if [ "$INSTALL_DESKTOP_SHORTCUT" = "yes" ]; then
    # start-openhands.sh: install (first run only) + launch OpenHands inside
    # $CONTAINER_NAME, auto-pointed at this project's proxy - same endpoint
    # (http://localhost:$PROXY_PORT/v1) and wildcard "openai/local-llm"
    # model string README.md documents for Zoo Code/Continue/other OpenAI-
    # Compatible clients, so re-running install.sh and switching model
    # profiles never requires touching this either.
    #
    # Dockerless CLI (`pip install openhands`, command `openhands`), not the
    # Docker-based web UI variant - keeps everything inside the one
    # container this project already uses, no nested container/daemon on an
    # immutable host. Requires Python 3.12 specifically (OpenHands' own
    # requirement, confirmed against its PyPI metadata 2026-08-03, not this
    # project's choice) - installed via dnf if the container doesn't have it.
    # LLM_* env vars + --override-with-envs is OpenHands' own documented
    # non-interactive LLM config path, so this never needs its interactive
    # first-run setup wizard.
    cat > "$BIN_DIR/start-openhands.sh" << EOF
#!/usr/bin/env bash
# start-openhands.sh
# Generated by install.sh - re-run install.sh to change any of these
# settings, don't hand-edit (your edits won't survive the next install.sh
# run). Installs OpenHands (https://docs.openhands.dev/, the dockerless pip
# CLI, not the Docker-based web UI) inside $CONTAINER_NAME the first time
# it's needed - skipped on every later run once \`command -v openhands\`
# succeeds - then launches it pointed at this project's local proxy at
# http://localhost:$PROXY_PORT/v1 so it talks to your local model with no
# manual setup, same one-stable-endpoint pattern README.md documents for
# Zoo Code/Continue.

LOG_FILE="\$HOME/.local/state/openhands-install.log"
mkdir -p "\$(dirname "\$LOG_FILE")"

if ! distrobox enter "$CONTAINER_NAME" -- bash -lc 'command -v openhands' >/dev/null 2>&1; then
  echo "OpenHands not found inside $CONTAINER_NAME - installing (needs Python 3.12, can take a few minutes)..."
  distrobox enter "$CONTAINER_NAME" -- bash -lc '
    set -e
    if command -v python3.12 >/dev/null 2>&1; then
      PY=python3.12
    elif python3 --version 2>&1 | grep -q "3\.12"; then
      PY=python3
    else
      echo "Python 3.12 not found - installing via dnf..." >&2
      sudo dnf install -y python3.12
      PY=python3.12
    fi
    if ! "\$PY" -m pip --version >/dev/null 2>&1; then
      # Fedora does not ship a per-minor-version "python3.12-pip" dnf
      # package (confirmed against this project'"'"'s own Fedora Distrobox
      # image, which errored "No match for argument: python3.12-pip"), and
      # the version dnf'"'"'s plain "python3-pip" happens to target won'"'"'t
      # necessarily match \$PY. ensurepip is a stdlib module bundled with
      # every CPython 3.4+ build, so it installs pip for this exact
      # interpreter regardless of distro packaging.
      echo "pip module not found for \$PY - bootstrapping via ensurepip..." >&2
      sudo "\$PY" -m ensurepip --upgrade
    fi
    # Plain pip cannot resolve openhands'"'"' dependency tree (confirmed:
    # pip backtracks through hundreds of browser-use/opentelemetry/
    # huggingface-hub versions and still fails with ResolutionImpossible on
    # openhands-sdk vs lmnr, even though a valid resolution exists). openhands'"'"'
    # own PyPI page recommends uv for exactly this reason - its resolver
    # handles the same dependency set cleanly (verified: uv pip install
    # openhands resolves and runs with no changes needed on either side).
    if ! "\$PY" -m uv --version >/dev/null 2>&1; then
      sudo "\$PY" -m pip install --break-system-packages -q uv
    fi
    sudo "\$PY" -m uv pip install --python "\$PY" --break-system-packages -q openhands
  ' 2>&1 | tee -a "\$LOG_FILE"
  # \$PIPESTATUS[0] is the distrobox/install command's own exit code - tee
  # itself always succeeds, so testing the pipeline's own \$? would silently
  # hide a failed install (this bit OpenHands before: python3.12 lacked its
  # pip module, the install died, but tee'"'"'s success made the script claim
  # "OpenHands installed." anyway).
  if [ "\${PIPESTATUS[0]}" -ne 0 ]; then
    echo "OpenHands install failed - see \$LOG_FILE for the full log. Not launching it." >&2
    exit 1
  fi
  echo "OpenHands installed."
fi

echo "Launching OpenHands against http://localhost:$PROXY_PORT/v1 (this project's local proxy)..."
distrobox enter "$CONTAINER_NAME" -- bash -lc "LLM_MODEL='openai/local-llm' LLM_BASE_URL='http://localhost:$PROXY_PORT/v1' LLM_API_KEY='$PROXY_MASTER_KEY' openhands --override-with-envs"
EOF
    chmod +x "$BIN_DIR/start-openhands.sh"

    # model-session.sh: runs inside the terminal window the desktop icon
    # opens. A plain script file rather than more inline shell packed into
    # the icon's own bash -c string below - once that string has to both
    # prompt for OpenHands AND conditionally open a second terminal for it,
    # the quoting nests too deeply to keep readable/correct inline.
    cat > "$BIN_DIR/model-session.sh" << EOF
#!/usr/bin/env bash
# model-session.sh
# Generated by install.sh - re-run install.sh to change any of these
# settings, don't hand-edit (your edits won't survive the next install.sh
# run). Runs inside the terminal window the "Start Local Model" desktop icon
# opens: offers to also install/launch OpenHands (in a second terminal
# window, so both stay visible) and/or enable llama.cpp's own browser chat
# UI, then runs start-local-llama.sh in this one so its own log output stays
# visible.

TERMINAL_CMD=""
if command -v konsole >/dev/null 2>&1; then
  TERMINAL_CMD="konsole -e"
elif command -v gnome-terminal >/dev/null 2>&1; then
  TERMINAL_CMD="gnome-terminal --"
elif command -v xterm >/dev/null 2>&1; then
  TERMINAL_CMD="xterm -e"
fi

read -rp "Also install/launch OpenHands (AI coding agent) in $CONTAINER_NAME? [y/N] " OH_ANS
if [[ "\$OH_ANS" =~ ^[Yy] ]]; then
  if [ -n "\$TERMINAL_CMD" ]; then
    \$TERMINAL_CMD bash -c "$BIN_DIR/start-openhands.sh; echo; echo 'OpenHands exited.'; read -p 'Press Enter to close this window.'" &
    disown
  else
    echo "No terminal emulator found to open OpenHands in its own window - running it here instead, before llama-server."
    "$BIN_DIR/start-openhands.sh"
  fi
fi

# Same server process, same port, same model already in VRAM either way -
# this just toggles whether llama.cpp also serves its own browser chat UI
# alongside the API, so it never loads a second copy of the model.
read -rp "Also enable llama.cpp's browser chat UI on this server (http://127.0.0.1:$LLAMA_PORT)? [y/N] " WEBUI_ANS
if [[ "\$WEBUI_ANS" =~ ^[Yy] ]]; then
  export LLAMA_ENABLE_WEBUI=yes
fi

"$BIN_DIR/start-local-llama.sh"
echo
echo "llama-server exited."
read -rp "Press Enter to close this window. " _
EOF
    chmod +x "$BIN_DIR/model-session.sh"

    cat > "$BIN_DIR/start-local-llama-desktop.sh" << EOF
#!/usr/bin/env bash
# start-local-llama-desktop.sh
# Generated by install.sh. Double-click target for the "Start Local Model"
# desktop icon: opens model-session.sh (offers OpenHands, then runs
# start-local-llama.sh) in its own terminal window so you can watch it while
# you work, without typing anything by hand. Falls back to a copy-paste
# notification if no terminal emulator can be found.

if curl -s -o /dev/null "http://localhost:$LLAMA_PORT/health"; then
  notify-send "Local model" "llama-server is already running at http://localhost:$LLAMA_PORT"
  exit 0
fi

TERMINAL_CMD=""
if command -v konsole >/dev/null 2>&1; then
  TERMINAL_CMD="konsole -e"
elif command -v gnome-terminal >/dev/null 2>&1; then
  TERMINAL_CMD="gnome-terminal --"
elif command -v xterm >/dev/null 2>&1; then
  TERMINAL_CMD="xterm -e"
fi

if [ -z "\$TERMINAL_CMD" ]; then
  notify-send -u critical "Local model: no terminal emulator found" \\
    "Paste this into a terminal yourself: $BIN_DIR/model-session.sh"
  exit 1
fi

\$TERMINAL_CMD bash -c "$BIN_DIR/model-session.sh" &
disown
notify-send "Local model" "Starting llama-server in a new terminal window..."
EOF
    chmod +x "$BIN_DIR/start-local-llama-desktop.sh"

    cat > "$DESKTOP_DIR/claude-local-start-model.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Start Local Model
Comment=Launch llama-server for Claude Code local mode (offers OpenHands too) in its own terminal window
Exec=$BIN_DIR/start-local-llama-desktop.sh
Icon=media-playback-start
Terminal=false
Categories=Utility;
EOF
    chmod +x "$DESKTOP_DIR/claude-local-start-model.desktop"
    log "Generated $BIN_DIR/start-openhands.sh, $BIN_DIR/model-session.sh, $BIN_DIR/start-local-llama-desktop.sh and its desktop icon"
    echo "Desktop icon 'Start Local Model' installed - double-click it to launch"
    echo "llama-server in its own terminal window (falls back to a copy-paste"
    echo "notification if no terminal emulator is found; not yet verified on"
    echo "your specific desktop session, check that it actually pops a window)."
    echo "It also now asks whether to install/launch OpenHands (an AI coding"
    echo "agent CLI) inside $CONTAINER_NAME, pointed at this project's local"
    echo "proxy, and whether to enable llama.cpp's own browser chat UI on the"
    echo "server - answer 'n' (or just press Enter) to skip either and get the"
    echo "old model-only behavior."
  fi
}

# --- Kilo mode: start-local-model.sh + its desktop icon ---
# The desktop-icon flow for kilo mode. Installs the checked-in start-local-
# model.sh template (which reads its config from CONF_FILE at runtime) plus a
# terminal wrapper and desktop entry. The template does the whole
# scan-offer-start-test-sync loop the Kilo Code provider needs, and doubles as
# the install-time test flow (run with --profile <stem>). Every runtime is
# handled: llama.cpp (flags built at runtime by sourcing the matched profile -
# the same profile generator install.d uses), ollama (serve + run), vllm
# (serve). The model entry in the KILO config is rewritten by
# sync-local-model.sh (installed by install.d/85-kilo-sync.sh) after every
# successful start, so Kilo Code always sees only the currently-running model.
build_kilo_launcher() {
  if [ "$INSTALL_MODE" != "kilo" ]; then
    log "Skipping kilo launcher installation (mode is $INSTALL_MODE)"
    return
  fi
  mkdir -p "$BIN_DIR" "$KILO_STATE_DIR"
  cp "$SCRIPT_DIR/start-local-model.sh" "$BIN_DIR/start-local-model.sh"
  chmod +x "$BIN_DIR/start-local-model.sh"
  log "Installed $BIN_DIR/start-local-model.sh (from repo template)"

  if [ "$INSTALL_DESKTOP_SHORTCUT" = "yes" ]; then
    cp "$SCRIPT_DIR/start-local-model-desktop.sh" "$BIN_DIR/start-local-model-desktop.sh"
    chmod +x "$BIN_DIR/start-local-model-desktop.sh"
    mkdir -p "$DESKTOP_DIR"
    # The .desktop Exec line needs the concrete path (desktop launchers can't
    # read the config), so the __BIN_DIR__ token is sed-baked here.
    sed "s|__BIN_DIR__|$BIN_DIR|g" "$SCRIPT_DIR/local-model.desktop" > "$DESKTOP_DIR/local-model.desktop"
    chmod +x "$DESKTOP_DIR/local-model.desktop"
    log "Installed $BIN_DIR/start-local-model-desktop.sh and $DESKTOP_DIR/local-model.desktop"
    echo "Desktop icon 'Start Local Model (Kilo)' installed - double-click it to"
    echo "open the model picker in a terminal window. On KDE Plasma (Bazzite"
    echo "default), the first double-click may prompt to trust/execute it."
  fi
}

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
