# 20-model-sizing.sh
# Sourced by install.sh. The llama.cpp-specific sizing prompts for the chosen
# model profile: which quant to download (prompt_quant_choice), the VRAM /
# context-length math and suggestion (prompt_vram_and_context), the optional
# VRAM-headroom tradeoffs (prompt_vram_headroom), and speculative-decoding
# draft length (prompt_spec_decoding). Only runs when MODEL_RUNTIME=llama.cpp
# - ollama/vllm profiles skip this file entirely (see
# 20-model-download-opts.sh's prompt_runtime_context for their plain prompt).
#
# Depends on globals set by prompt_model_profile() in 20-model-profile.sh
# (KV_MODEL, N_LAYERS, SPEC_MODE, RECOMMENDED_CTX_8GB, etc).

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