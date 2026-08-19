# 20-prompts-model.sh
# Sourced by install.sh. Everything about picking a model and sizing it to
# fit the GPU: which model-profiles/*.sh fragment to load (from the shipped
# directory plus the presets dir), which quant to download, VRAM/context
# sizing, the optional VRAM-headroom tradeoffs, speculative-decoding draft
# length, and the new kilo-mode fields (multimodal mmproj download offer,
# reasoning mode/effort). Sets PROFILE_FILE, PROFILE_NAME, MODEL_RUNTIME,
# RUNTIME_PORT, and the other model-profile globals (N_LAYERS, KV_MODEL,
# SPEC_MODE, etc) as a side effect of sourcing the chosen profile - later
# install.d/*.sh files rely on those being set here first.
#
# The llama.cpp-specific sizing machinery (quant menu, VRAM/context math,
# headroom, spec decoding) only runs when MODEL_RUNTIME=llama.cpp; ollama and
# vllm profiles skip it and get a plain context prompt instead.

# --- Model profile: which model-profiles/*.sh fragment to load ---
# Profiles come from two places: this repo's shipped directory (the example,
# gemma4-e2b.sh) and the presets dir (PRESETS_DIR, typically a private
# 8gb-immutable-fedora-presets checkout). On a stem conflict the presets copy
# wins - it's the newer/private one. This changes every model-specific default
# below it (repo, quant sizes, layer count, KV sizing behaviour, spec-decoding
# wiring), so it's asked before any of those questions.
prompt_model_profile() {
  PROFILE_DIR="$SCRIPT_DIR/model-profiles"
  PROFILE_DIRS=("$PROFILE_DIR")
  if [ -n "$PRESETS_DIR" ] && [ -d "$PRESETS_DIR/model-profiles" ]; then
    PROFILE_DIRS+=("$PRESETS_DIR/model-profiles")
  fi
  # Space-joined list of profile dirs, persisted so the generated
  # start-local-model.sh can find profiles at runtime from CONF_FILE.
  PROFILE_DIRS_CONF="${PROFILE_DIRS[*]}"

  # Numbered menu built fresh from every profile found, same style as
  # prompt_quant_choice() below - plugs into this project's usual
  # ask()/CONF_FILE "Enter to keep your last answer" convention instead of a
  # bash `select` loop. Each profile's PROFILE_NAME (human-readable label),
  # MODEL_RUNTIME, and a READY/needs-download tag are read out of its file
  # with grep/sed rather than sourcing it - sourcing every profile just to
  # list them would run whichever one happens to load last, overwriting the
  # others' variables for no reason; only the one actually chosen gets
  # sourced, same as before.
  echo
  echo "Which model profile?"
  PICK_NUM=1
  DEFAULT_PICK=""
  PROFILE_LIST=()
  PROFILE_FILE_LIST=()
  declare -A PROFILE_FILE_MAP=()   # stem -> file path, presets win
  for DIR in "${PROFILE_DIRS[@]}"; do
    while IFS= read -r PROF_SH; do
      [ -z "$PROF_SH" ] && continue
      STEM="${PROF_SH%.sh}"
      PROFILE_FILE_MAP["$STEM"]="$DIR/$PROF_SH"
    done <<< "$(cd "$DIR" && ls -1 ./*.sh 2>/dev/null | sed 's|^\./||')"
  done

  # Deterministic menu order: bash hash-map iteration order is unspecified, so
  # a sorted list here means the same run never presents a shuffled menu.
  local ALL_STEMS=()
  for STEM in "${!PROFILE_FILE_MAP[@]}"; do ALL_STEMS+=("$STEM"); done
  local SORTED
  mapfile -t SORTED <<< "$(printf '%s\n' "${ALL_STEMS[@]}" | sort)"

  for STEM in "${SORTED[@]}"; do
    local FILE="${PROFILE_FILE_MAP[$STEM]}"
    local LABEL="$(sed -n 's/^PROFILE_NAME="\(.*\)"$/\1/p' "$FILE" | head -n1)"
    local RUNTIME="$(sed -n 's/^MODEL_RUNTIME="\(.*\)"$/\1/p' "$FILE" | head -n1)"
    [ -z "$RUNTIME" ] && RUNTIME="llama.cpp"
    if [ "$RUNTIME" = "ollama" ]; then
      local OM="$(sed -n 's/^OLLAMA_MODEL="\(.*\)"$/\1/p' "$FILE" | head -n1)"
      if command -v ollama >/dev/null 2>&1 && [ -n "$OM" ] && ollama list 2>/dev/null | grep -qwF "$OM"; then
        TAG="READY"
      else
        TAG="needs download"
      fi
    elif [ "$RUNTIME" = "vllm" ]; then
      TAG="READY"   # vllm pulls its model on first serve, nothing to predownload
    else
      if [ -n "$(find "$MODEL_ROOT/$STEM" -maxdepth 1 -iname '*.gguf' 2>/dev/null | grep -viE 'mtp-|assistant|mmproj' | head -n1)" ]; then
        TAG="READY"
      else
        TAG="needs download"
      fi
    fi
    printf "  %d) %-24s %-24s [%s]\n" "$PICK_NUM" "$STEM" "$LABEL" "$TAG"
    PROFILE_LIST+=("$STEM")
    PROFILE_FILE_LIST+=("$FILE")
    if [ "$STEM" = "$MODEL_PROFILE" ]; then
      DEFAULT_PICK="$PICK_NUM"
    fi
    PICK_NUM=$((PICK_NUM + 1))
  done

  if [ "${#PROFILE_LIST[@]}" -eq 0 ]; then
    echo "ERROR: no model profiles found in:" >&2
    printf '  %s\n' "${PROFILE_DIRS[@]}" >&2
    echo "If you deleted the shipped example profile, restore model-profiles/gemma4-e2b.sh" >&2
    echo "or point --presets-dir at a directory whose model-profiles/ has .sh files." >&2
    exit 1
  fi

  MODEL_PROFILE_CHOICE="$DEFAULT_PICK"
  ask MODEL_PROFILE_CHOICE "Pick a number"

  if [ "$MODEL_PROFILE_CHOICE" -ge 1 ] 2>/dev/null && [ "$MODEL_PROFILE_CHOICE" -le "${#PROFILE_LIST[@]}" ] 2>/dev/null; then
    MODEL_PROFILE="${PROFILE_LIST[$((MODEL_PROFILE_CHOICE - 1))]}"
  elif [[ "$MODEL_PROFILE_CHOICE" =~ ^[a-z0-9_-]+$ ]] && [ -n "${PROFILE_FILE_MAP[$MODEL_PROFILE_CHOICE]:-}" ]; then
    # Not advertised above, but kept working: typing the exact filename stem
    # directly still resolves, so a scripted/non-interactive re-run that
    # already pipes in a profile name by that name doesn't break.
    MODEL_PROFILE="$MODEL_PROFILE_CHOICE"
  else
    echo "Didn't recognize '$MODEL_PROFILE_CHOICE'. Available profiles:" >&2
    printf '  %s\n' "${PROFILE_LIST[@]}" >&2
    exit 1
  fi

  PROFILE_FILE="${PROFILE_FILE_MAP[$MODEL_PROFILE]}"
  if [ ! -f "$PROFILE_FILE" ]; then
    echo "ERROR: no model-profiles/$MODEL_PROFILE.sh found. Available profiles:" >&2
    printf '  %s\n' "${PROFILE_LIST[@]}" >&2
    exit 1
  fi

  # stash persisted runtime/reasoning answers before sourcing so the profile's
  # declared defaults can lose to a user's saved choice on re-runs of the same
  # profile (see the reset block below).
  local saved_reasoning_mode="$REASONING_MODE"
  local saved_reasoning_effort="$REASONING_EFFORT"
  # shellcheck source=/dev/null
  source "$PROFILE_FILE"
  log "Loaded model profile: $PROFILE_NAME ($PROFILE_FILE)"

  # Runtime defaults: MODEL_RUNTIME falls back to llama.cpp when a profile
  # doesn't set it; RUNTIME_PORT defaults from the runtime table unless the
  # profile declares an override.
  MODEL_RUNTIME="${MODEL_RUNTIME:-llama.cpp}"
  resolve_runtime_port

  # Switching profiles from a previous run makes the old run's saved answers
  # stale (they belonged to a different model) - reset them to this profile's
  # defaults. Re-running the same profile leaves them alone, which is what
  # keeps re-runs idempotent.
  if [ "$MODEL_PROFILE" != "$LAST_MODEL_PROFILE" ]; then
    HF_REPO="$HF_REPO_DEFAULT"
    GGUF_PATTERN=""
    QUANT_WEIGHT_MIB=""
    QUANT_CHOICE=""
    RUNTIME_PORT=""
    REASONING_MODE="${REASONING_MODE:-off}"
    REASONING_EFFORT="${REASONING_EFFORT:-low}"
    DOWNLOAD_MMPROJ="no"
    # LLAMA_CPU_FFN_LAYERS is NOT reset here (unlike the fields above) - see
    # prompt_vram_headroom() below, where it's unconditionally reset to
    # LLAMA_CPU_FFN_LAYERS_RECOMMENDED (when a profile sets one) right
    # before that prompt is shown, every run, not just on a profile switch.
    # An earlier version of this reset only fired on profile switch, which
    # meant a stale saved answer from before this profile had a tested
    # recommendation (or from before this feature existed at all) kept
    # showing as the prompt's default forever, directly contradicting the
    # "N is pre-filled below" text above the prompt - caught live 2026-07-25.
    LAST_MODEL_PROFILE="$MODEL_PROFILE"
  else
    # Same profile as last run: a saved REASONING_MODE/REASONING_EFFORT is a
    # user's deliberate prior answer, so it must win over the profile's baked
    # default (which was only the first-run default). Only applied when the
    # answer actually came from a saved config, not when this is the very
    # first run.
    if [ "${CONF_HAD_REASONING:-no}" = "yes" ]; then
      REASONING_MODE="$saved_reasoning_mode"
      REASONING_EFFORT="$saved_reasoning_effort"
    fi
  fi
  resolve_runtime_port   # again after reset: fills RUNTIME_PORT from the runtime default
  [ -z "$HF_REPO" ] && HF_REPO="$HF_REPO_DEFAULT"
}

prompt_quant_choice() {
  echo
  echo "Which quantization? $(eval "echo \"$QUANT_MENU_INTRO\"")"
  PICK_NUM=1
  for ENTRY in "${QUANT_MENU[@]}"; do
    IFS='|' read -r FRAG SIZE_MIB DESC <<< "$ENTRY"
    if [ -n "$SIZE_MIB" ]; then
      SIZE_GB="$(awk -v m="$SIZE_MIB" 'BEGIN { printf "%.2f", m/1024 }')"
      SIZE_TXT="${SIZE_GB} GB"
    else
      SIZE_TXT="size UNVERIFIED"
    fi
    if [ -n "$DESC" ]; then
      printf "  %d) %-12s %-14s (%s)\n" "$PICK_NUM" "$FRAG" "$SIZE_TXT" "$DESC"
    else
      printf "  %d) %-12s %s\n" "$PICK_NUM" "$FRAG" "$SIZE_TXT"
    fi
    PICK_NUM=$((PICK_NUM + 1))
  done
  CUSTOM_CHOICE="$PICK_NUM"
  echo "  $CUSTOM_CHOICE) custom      (type your own quant fragment, e.g. 'IQ4_XS')"
  ask QUANT_CHOICE "Pick a number"
  # QUANT_WEIGHT_MIB feeds the context-length recommendation below.
  if [ -z "$QUANT_CHOICE" ]; then
    :  # empty input keeps whatever GGUF_PATTERN/QUANT_WEIGHT_MIB already was (saved default)
  elif [ "$QUANT_CHOICE" = "$CUSTOM_CHOICE" ]; then
    ask GGUF_PATTERN "Exact quant fragment (check the repo's file listing if unsure)"
    ask QUANT_WEIGHT_MIB "Approximate file size of that quant, in MiB (check the repo's file listing; leave blank to skip the context recommendation below)"
  elif [ "$QUANT_CHOICE" -ge 1 ] 2>/dev/null && [ "$QUANT_CHOICE" -le "${#QUANT_MENU[@]}" ] 2>/dev/null; then
    IFS='|' read -r GGUF_PATTERN QUANT_WEIGHT_MIB _ <<< "${QUANT_MENU[$((QUANT_CHOICE - 1))]}"
  else
    echo "Didn't recognize that, keeping $GGUF_PATTERN"
  fi
  ask HF_REPO "Hugging Face repo"
}

prompt_vram_and_context() {
  echo
  echo "How much usable VRAM does your card have for this? Check 'nvidia-smi'"
  echo "for total VRAM, then subtract a few hundred MiB the desktop compositor"
  echo "and driver keep for themselves. 7885 MiB (~7.7 GiB) was measured on an"
  echo "8 GB card previously used with this project."
  ask GPU_VRAM_MIB "Usable VRAM in MiB"

  echo
  echo "Batch size (-b / --batch-size). llama.cpp's own default is 512. Larger"
  echo "values (e.g. 2048) speed up prompt processing but the compute buffer"
  echo "they require eats directly into the VRAM left over for context - on a"
  echo "~8 GB card with a Q5-class quant, batch 2048 can leave close to zero"
  echo "room for KV cache, which is the 'ran out of context' symptom. 512 is"
  echo "the recommended default here; raise it only if the numbers below show"
  echo "you have real headroom to spare."
  ask LLAMA_BATCH_SIZE "Batch size"

  # --- Context-length recommendation ---
  # KV_MODEL=manual (Qwen only): the bytes/token formula is fully worked out
  # from the model's published config, so compute a recommendation directly.
  # KV_MODEL=probe (Gemma): Gemma 4's hybrid local/global attention with
  # unified K/V on global layers has no simple closed-form bytes/token - see
  # model-profiles/gemma4-e*b.sh. Don't hand-roll a formula for it. Instead
  # let llama.cpp fit the context itself (--fit on, set below in Step 10)
  # and read the measured number back from the log after first start.
  if [ "$KV_MODEL" = "manual" ] && [ -n "${RECOMMENDED_CTX_8GB:-}" ] && [ -n "${LLAMA_CPU_FFN_LAYERS_RECOMMENDED:-}" ] && [ "$GPU_VRAM_MIB" -le 9000 ] 2>/dev/null; then
    # This profile has an actual live-tested number for this card (see the
    # SPEED SWEEP comment in model-profiles/$MODEL_PROFILE.sh), not just a
    # formula guess - use it directly instead of the naive estimate below.
    # The naive formula assumes the ENTIRE quant sits on GPU (as if
    # --override-tensor is never used), so for a profile whose tested
    # config deliberately offloads several FFN layers to system RAM to fund
    # a bigger KV cache, it drastically undercounts what actually fits -
    # this was a real reported bug: it recommended ~56K tokens for a config
    # confirmed to hold 131072 fine. That confirmed number came from a real
    # server that actually loaded and passed a quality check, so trust it
    # over the formula below.
    echo
    echo "Estimate skipped: this profile has a live-tested context ceiling for"
    echo "an 8GB card (see model-profiles/$MODEL_PROFILE.sh) that already"
    echo "accounts for the CPU-FFN-offload trade the next prompt sets up -"
    echo "the formula below would undercount it, since it assumes no offload"
    echo "at all. Confirmed working: $RECOMMENDED_CTX_8GB tokens."
    LLAMA_CTX_SIZE="$RECOMMENDED_CTX_8GB"
    echo
    echo "Context window (-c / --ctx-size). Larger lets Claude Code's full prompt fit"
    echo "without truncation, but costs more VRAM on top of the quant above."
    ask LLAMA_CTX_SIZE "Context length in tokens"
  elif [ "$KV_MODEL" = "manual" ]; then
    # Qwen3.5-9B is a hybrid dense model: 32 layers total, but only every 4th
    # layer (8 of 32) is full quadratic attention - the other 24 are
    # linear/DeltaNet attention with a small fixed-size recurrent state that
    # does NOT grow with context length. Only the 8 full-attention layers
    # matter for KV cache sizing (confirmed from Qwen/Qwen3.5-9B's
    # config.json: full_attention_interval=4, num_key_value_heads=4,
    # head_dim=256; the model has no MoE layers at all - mlp_only_layers is
    # empty and there's no num_experts field, so --n-cpu-moe would be a
    # no-op here and isn't used).
    #
    # bytes/token = 2(K+V) x num_kv_heads(4) x head_dim(256) x attn_layers(8)
    #             x bytes_per_element(1 for q8_0, always on in this project)
    #             = 16384 bytes/token = 16 KiB/token
    # (BYTES_PER_TOKEN itself comes from the profile - see model-profiles/
    # qwen35-9b.sh - this comment documents where that number came from.)

    # Compute buffer scales roughly with batch size; ~1508 MiB was measured at
    # batch 2048 in community reports, scaled linearly here as an estimate.
    COMPUTE_BUF_MIB=$(( LLAMA_BATCH_SIZE * 1508 / 2048 ))
    # CUDA context, desktop compositor, and the linear-attention layers' small
    # fixed recurrent state, bundled into one conservative fixed reserve.
    FIXED_OVERHEAD_MIB=350

    if [ -n "${QUANT_WEIGHT_MIB:-}" ]; then
      AVAILABLE_KV_MIB=$(( GPU_VRAM_MIB - QUANT_WEIGHT_MIB - COMPUTE_BUF_MIB - FIXED_OVERHEAD_MIB ))
      echo
      echo "Estimate: ${GPU_VRAM_MIB} MiB VRAM - ${QUANT_WEIGHT_MIB} MiB weights"
      echo "  - ${COMPUTE_BUF_MIB} MiB compute buffer - ${FIXED_OVERHEAD_MIB} MiB fixed"
      echo "  overhead = ${AVAILABLE_KV_MIB} MiB left for KV cache."
      if [ "$AVAILABLE_KV_MIB" -gt 0 ]; then
        MAX_TOKENS=$(( AVAILABLE_KV_MIB * 1024 * 1024 / BYTES_PER_TOKEN ))
        REC_CTX=$(( MAX_TOKENS * 85 / 100 / 1024 * 1024 ))
        if [ "$REC_CTX" -lt 1024 ]; then REC_CTX=1024; fi
        echo "  That's roughly ${MAX_TOKENS} tokens of KV cache at this quant/batch"
        echo "  size; recommending $REC_CTX tokens of context (15% safety margin,"
        echo "  rounded down), press Enter below to accept it."
        LLAMA_CTX_SIZE="$REC_CTX"
      else
        echo "  WARNING: that's negative - this quant doesn't fit at this batch"
        echo "  size and VRAM budget with any context at all. Lower the batch"
        echo "  size above, or pick a smaller quant, and re-run this script."
        LLAMA_CTX_SIZE=4096
      fi
    else
      echo
      echo "No quant size given, can't estimate a safe context length. Falling"
      echo "back to a conservative default; watch the VRAM check after you"
      echo "start llama-server and reduce this if it's too much."
    fi

    echo
    echo "Context window (-c / --ctx-size). Larger lets Claude Code's full prompt fit"
    echo "without truncation, but costs more VRAM on top of the quant above."
    echo "20480 truncated on real Claude Code requests in earlier testing"
    echo "(system prompt + tool schemas alone can be tens of thousands of tokens)."
    ask LLAMA_CTX_SIZE "Context length in tokens"
  else
    echo
    echo "This profile's KV cache sizing is measured, not estimated (Gemma 4's"
    echo "hybrid attention has no simple closed-form bytes/token - see"
    echo "model-profiles/$MODEL_PROFILE.sh). llama.cpp will size the context"
    echo "itself (--fit on) the first time the server starts, up to the ceiling"
    echo "you give it below; the REAL number it lands on gets read back from"
    echo "$HOME/.local/state/llama-server.log and printed after that first"
    echo "start, not estimated ahead of time."
    echo
    echo "Context window ceiling (-c / --ctx-size). Larger lets Claude Code's"
    echo "full prompt fit without truncation, but --fit on will refuse to"
    echo "exceed available VRAM, so this is a cap, not a guarantee."
    if [ -n "${RECOMMENDED_CTX_8GB:-}" ] && [ "$GPU_VRAM_MIB" -le 9000 ] 2>/dev/null; then
      echo "Confirmed on an 8GB card (see model-profiles/$MODEL_PROFILE.sh): this"
      echo "profile's own max context (the model won't go higher regardless) fits"
      echo "with room to spare for the desktop and VSCode/Claude Code, so that's"
      echo "the suggested default below - lower it only if --fit refuses to start."
      LLAMA_CTX_SIZE="$RECOMMENDED_CTX_8GB"
    fi
    ask LLAMA_CTX_SIZE "Context length ceiling in tokens"
  fi
}

prompt_vram_headroom() {
  echo
  echo "Need more headroom than the above gives you? Nothing overflows to RAM"
  echo "automatically - if a setting doesn't fit VRAM, llama-server just fails"
  echo "to allocate it. Two ways to deliberately trade speed for more room:"
  echo
  if [ "${NGL_MODE:-fixed}" = "fit" ]; then
    echo "1) Force the last N layers' FFN weights onto CPU RAM instead of GPU"
    echo "   (via --override-tensor) - SKIPPED for $PROFILE_NAME. This"
    echo "   profile's only FFN-shaped tensors are its MoE experts"
    echo "   (ffn_*_exps), not the dense ffn_(gate|up|down).weight tensors"
    echo "   this flag targets, so the regex would match nothing - but"
    echo "   passing --override-tensor AT ALL still sets llama.cpp's"
    echo "   tensor_buft_overrides internally, which makes --fit (see"
    echo "   NGL_MODE=fit above) abort its entire automatic layer/expert"
    echo "   placement pass and fall back to loading everything onto GPU -"
    echo "   confirmed live 2026-07-25: OOM on an 8GB card trying to allocate"
    echo "   the full IQ4_XS file. --fit already handles MoE expert"
    echo "   CPU/GPU placement on its own for this profile; there is no safe"
    echo "   way to combine that with this flag, so it's forced off here."
    LLAMA_CPU_FFN_LAYERS=0
  elif [ -n "${LLAMA_CPU_FFN_LAYERS_RECOMMENDED:-}" ]; then
    echo "1) Force the last N layers' FFN weights onto CPU RAM instead of GPU"
    echo "   (via --override-tensor). This profile has an actual measured"
    echo "   answer for this, not a guess: bench/qwen-bench.sh swept KV cache"
    echo "   quant type and binary-searched the minimum CPU-resident layer"
    echo "   count on real hardware (see the SPEED SWEEP comment in"
    echo "   model-profiles/$MODEL_PROFILE.sh for the numbers and methodology)."
    echo "   $LLAMA_CPU_FFN_LAYERS_RECOMMENDED is the tested-fastest value that"
    echo "   still fits RECOMMENDED_CTX_8GB and passes a real quality check -"
    echo "   pre-filled below. Only raise it if you need to free more VRAM than"
    echo "   that leaves and can accept slower generation; only lower it if"
    echo "   you've confirmed on your own card it still fits."
    # Unconditional, every run - NOT just on a profile switch (see the
    # comment above the reset block earlier in this file for why: a stale
    # saved value must never be shown as this prompt's default, since the
    # text above just told you a specific number is "pre-filled below").
    # ask_confirm_override still requires typing "yes" to move away from
    # this, so a real prior override just costs one re-confirmation per
    # run rather than silently vanishing.
    LLAMA_CPU_FFN_LAYERS="$LLAMA_CPU_FFN_LAYERS_RECOMMENDED"
    ask_confirm_override LLAMA_CPU_FFN_LAYERS "Layers to force onto CPU (0-$((N_LAYERS - 1)), 0 to disable)" \
      "$LLAMA_CPU_FFN_LAYERS_RECOMMENDED" "measured fastest value that still fits and passes the quality check for this profile's quant/KV settings, see model-profiles/$MODEL_PROFILE.sh"
  else
    echo "1) Force the last N layers' FFN weights onto CPU RAM instead of GPU"
    echo "   (via --override-tensor). IMPORTANT DIFFERENCE FROM --n-cpu-moe ON"
    echo "   MoE MODELS: a community guide to this technique"
    echo "   (github.com/DocShotgun's llama.cpp offload gist) explicitly"
    echo "   recommends AGAINST offloading dense FFN tensors, only MoE expert"
    echo "   tensors - on a MoE model, only a couple of experts activate per"
    echo "   token, so CPU only does a little work. Qwen3.5-9B has no experts;"
    echo "   every offloaded layer's FULL FFN matrix (4096x12288, three of"
    echo "   them) gets read from RAM on every single token, every time. Rough"
    echo "   math: at ~40 GB/s of RAM bandwidth, that's ballpark 2-3ms added"
    echo "   per offloaded layer per token - noticeable, unlike the MoE case."
    echo "   Defaulting to a light touch (2 layers) for this reason: enough to"
    echo "   free a little VRAM without a big hit, not the aggressive default"
    echo "   you might reach for on a MoE model. Raise it only if you actually"
    echo "   need the extra room and can accept slower generation; 0 disables"
    echo "   this entirely (everything on GPU, fastest, and arguably the"
    echo "   better choice for a Haiku-replacement workload where a smaller"
    echo "   quant is usually the better way to free VRAM instead)."
    ask LLAMA_CPU_FFN_LAYERS "Layers to force onto CPU (0-$((N_LAYERS - 1)), 0 to disable)"
  fi

  echo
  echo "2) Keep the ENTIRE KV cache in system RAM instead of VRAM"
  echo "   (--no-kv-offload). This decouples context length from VRAM"
  echo "   almost completely (bound by system RAM instead)."
  echo "   WARNING: every attention step now has to move cache data over"
  echo "   PCIe to system RAM and back, on every token, for the entire"
  echo "   conversation - this is a real, ongoing latency cost for the whole"
  echo "   session, not a one-time hit, and it's not yet confirmed clean on"
  echo "   every backend/model combination (some Vulkan/model pairings have"
  echo "   reported broken output with this flag). Default is 'no' for this"
  echo "   reason; only turn it on if you specifically need more context"
  echo "   than VRAM can hold and can live with slower responses."
  ask LLAMA_NO_KV_OFFLOAD "Move the whole KV cache to system RAM? (yes/no)"

  if [ -n "${PLE_TENSOR_REGEX:-}" ]; then
    echo
    echo "3) Keep Per-Layer Embedding (PLE) tables in system RAM instead of VRAM"
    echo "   (--override-tensor on the PLE tensors specifically). This is the"
    echo "   OPPOSITE tradeoff from option 1 above, not the same trick again:"
    echo "   PLE tables are pure per-token lookups, no matrix multiply, so"
    echo "   moving them to system RAM costs one small host-memory read per"
    echo "   token instead of a full GEMM's worth of PCIe/RAM bandwidth. That"
    echo "   makes this a large-VRAM-for-little-speed trade, unlike the dense"
    echo "   FFN offload above, which this project deliberately defaults light"
    echo "   on for the opposite reason. Defaulting to 'yes' for this profile."
    ask KEEP_PLE_ON_CPU "Keep Per-Layer Embedding tables in system RAM? (yes/no)"
  else
    KEEP_PLE_ON_CPU="no"
  fi

  echo
  echo "Note: none of the VRAM-headroom options above feed back into the"
  echo "context recommendation above - it was computed assuming everything"
  echo "stays on GPU. If you turn any on, check the real VRAM reading after"
  echo "starting the server (see below), then re-run this script and raise"
  echo "the context/quant if there's more room than the recommendation assumed."
}

prompt_spec_decoding() {
  if [ "$SPEC_MODE" = "self-mtp" ]; then
    echo
    echo "Speculative decoding draft length (--spec-draft-n-max), via the"
    echo "MTP head baked into the $HF_REPO build. Community guidance is"
    echo "around 2 for dense-leaning models, higher for MoE-heavy ones."
    ask LLAMA_SPEC_DRAFT_N "Max draft tokens per step"
  elif [ "$SPEC_MODE" = "draft-model" ]; then
    echo
    echo "Speculative decoding draft length (--spec-draft-n-max), via a"
    echo "separate drafter model (not baked into the main GGUF for this"
    echo "profile - the drafter is downloaded separately below, and this"
    echo "flag only takes effect if that download resolves to a file)."
    ask LLAMA_SPEC_DRAFT_N "Max draft tokens per step"
  fi
  # SPEC_MODE=none: no draft-length prompt, no spec flags emitted below.
}

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
# pipeline; ollama/vllm get a plain context prompt plus the cross-runtime
# reasoning + mmproj prompts.
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