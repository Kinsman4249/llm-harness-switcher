# model-profiles/ornith-1.5-35b-a3b.sh
# Public showcase profile - tracked in llm-harness-switcher so people
# browsing the repo can see a live-tested, feature-complete profile: it
# exercises CTX_MODES (native + opt-in YaRN windows), a REASONING_MODES menu,
# speculative-decoding A/B results, multimodal input (MMPROJ_REPO), NGL_MODE=fit,
# and the full Kilo/llama.cpp field set. The field reference for this file lives
# in this repo's own model-profiles/README.md. Feeds llm-harness-switcher's
# install.sh.
#
# Profile for Ornith-1.5-35B-A3B (DeepReinforce AI, released 2026-08-18) - the
# agentic-coding MoE in the Ornith-1.5 family (post-trained on Qwen 3.5, MIT
# license). qwen3_5_moe hybrid arch: 40 layers in a 10 x
# (3 x (Gated DeltaNet -> MoE) -> 1 x (Gated Attention -> MoE)) layout, 35B
# total / 3B active, 256 routed experts (8 active), 262144 native ctx. Note the
# config.json carries BOTH a qwen3_5_moe_text and a qwen3_5_moe_vision sub-block
# and the official GGUF repo ships an 861 MiB mmproj - so unlike Qwen3-Coder-
# Next, this model IS vision-capable (the DGX-Spark forum "text-only" comment
# appears to describe a different sibling; the official repo's mmproj says
# otherwise).
#
# This profile is BY ORNITH'S OWN MODEL CARD a "reasoning model": by default the
# assistant turn opens with a <think>...</think> block, the card says to run a
# reasoning parser (qwen3) so the chain-of-thought lands in reasoning_content,
# and a tool-call parser (qwen3_xml / qwen3_coder) so <tool_call> blocks surface
# as OpenAI-style tool_calls. So unlike Qwen3-Coder-Next, THIS profile has a
# reasoning-mode menu - the nemotron3-nano-30b approach of toggling thinking on
# the same arch applies here. DEFAULT is "budgeted" reasoning (the card also
# cites temp 1.0 / top_p 0.95 for the agentic coding benches, set below):
# `REASONING_MODES="off,on,budgeted,max"`.

PROFILE_NAME="Ornith-1.5-35B-A3B"
HF_REPO_DEFAULT="ornith-ai/Ornith-1.5-35B-A3B-GGUF"

# Runtime that serves this model (llama.cpp | ollama | vllm); RUNTIME_PORT
# defaults per runtime (8080/11434/8000) unless overridden here. This build
# (d59d455fd) predates Ornith-1.5 by a week, but it carries the qwen35 / moe
# arch support (the qwen35-9b profile already runs on it) - if the first load
# rejects the arch, the CUDA build needs a rebuild first.
MODEL_RUNTIME="llama.cpp"

# Reasoning: this is a thinking model (differs from the non-thinking Coder-Next
# profiles). Modes are toggled server-side via the qwen-style chat-template
# kwarg (THINKING_KWARG_KEY=enable_thinking below), switched by
# start-local-model.sh --mode, requires a llama-server restart. "budgeted" is
# the default - user-observed preference for a small bounded reasoning budget,
# matching the nemotron35-lightning-30b stance on this box.
REASONING_MODE="budgeted"
REASONING_EFFORT="low"
REASONING_MODES="off,on,budgeted,max"
REASONING_BUDGET_DEFAULT="8192"
REASONING_OUTPUT_MAX="16384"

# Kilo Code provider entry flags / identity (KILO_MODEL_ID defaults to this
# file's stem, KILO_MODEL_NAME defaults to PROFILE_NAME).
KILO_TOOL_CALL="yes"
KILO_TEMPERATURE="yes"
KILO_MODEL_ID=""
KILO_MODEL_NAME=""

# Multimodal: Ornith-1.5 is vision-capable - the official GGUF repo ships an
# mmproj. With these set, install.sh offers to download the projector and the
# generated Kilo provider entry advertises real image input (the launcher
# auto-attaches any mmproj-*.gguf it finds in the model dir and marks the
# entry attachment-capable). Filename CONFIRMED 2026-08-23 from the repo
# listing; whether llama-server loads this projector on the box's llama.cpp
# build needs the same live check every multimodal profile does. The DGX-Spark
# forum "text-only" comment is a sibling variant, not this one.
MMPROJ_REPO="ornith-ai/Ornith-1.5-35B-A3B-GGUF"
MMPROJ_PATTERN="mmproj-Ornith-1.5-35B-BF16"

# Speculative decoding: A/B'd 2026-08-23 on the live box (llama.cpp d59d455fd,
# RTX 3080 8GB / 32GB) and DID NOT WIN - so it stays OFF (SPEC_MODE=none).
# A ready GGUF drafter for stock Ornith GGUFs now exists (EryriLabs/Ornith-1.5-
# 35B-A3B-BigBang-MTP-GGUF, `mtpdraft-Q8_0.gguf`, 1,990,649,440 B ~ 1.85 GiB, the
# profile comment predates it - when written only safetensors existed). Loads
# cleanly on the current build (`-md <path> --spec-type draft-mtp`, ~66% draft
# accepted), but decode t/s measurements (200-token, temp 0, N=3-5, idle box)
# are all BELOW the no-draft baseline at every draft length and window:
#   baseline (no draft):   native 262144 = 34.2 t/s | YaRN 524288 = 20.5 t/s
#   -md n-max 1  -ngld 0:  21.9* t/s (native)             17.1 t/s (524288)
#   -md n-max 1  -ngld 99: 24.1 t/s (native)
#   -md n-max 2  -ngld 99: 21.9 t/s (native)
#   -md n-max 3  -ngld 99: 18.9 t/s (native)
#   -md n-max 4  -ngld 99: 18.5 t/s (native)              15.3 t/s (524288)
#   -md n-max 6  -ngld 99: 14.3 t/s (native)
#   (* -ngld 0 CPU draft measured slower than the GPU draft, as expected on an
#     Ampere + RAM-bound MoE; even the best draft config is -30% vs baseline.)
# The MTP head is on the stock GGUF is random-init anyway (~13% accepted, per
# the card), so none of this is surprising; this profile remains spec-decoding-
# off, and stays that way until a config measures >=5% faster than its own
# no-draft baseline. The drafter GGUF is kept in the model dir (DRAFT_PATTERN
# below) purely so the A/B is reproducible and re-runnable - enabling it means
# SPEC_MODE=draft-model, which trades away vision (llama.cpp won't serve mmproj
# and spec decode together).
DRAFT_REPO="EryriLabs/Ornith-1.5-35B-A3B-BigBang-MTP-GGUF"
DRAFT_PATTERN="mtpdraft-Q8_0"
SPEC_MODE="none"                                # none | self-mtp | draft-model

N_LAYERS=40

# Hybrid Gated DeltaNet/MoE/Gated Attention, same class as the Coder-Next /
# nemotron hybrids: KV grows with context across only the gated-attention
# layers (10 of 40, i.e. the "1 in each 4-block"), so probe a live server
# rather than trust a closed form. For reference the KV math is fully worked
# out here - see RECOMMENDED_CTX_8GB below (10 attn layers x 2 KV heads x 256
# head_dim x 2 tensors x 1 byte q8_0 = 10240 bytes/token, i.e. ~2.5 GiB for the
# whole native 262144 window).
KV_MODEL="probe"                                # manual | probe
BYTES_PER_TOKEN=                                # unused when KV_MODEL=probe

# NGL_MODE="fit": 256-expert MoE, same requirement as the other MoE profiles -
# leave -ngl unset so --fit places as many of the routed experts as 8GB VRAM
# allows and parks the rest in system RAM. Forcing -ngl 99 would push all 256
# expert tensors onto an 8GB card at any quant.
NGL_MODE="fit"                                  # fixed | fit

# CONFIRMED 2026-08-23 (RTX 3080 8GB / 32GB, llama.cpp d59d455fd): the native
# 262144 window fits and serves cleanly (PASS fitted=262144, VRAM 6526 MiB, RSS
# 20.3 GiB, normal completions with reasoning off, ~34 t/s decode, ~35.7 t/s
# budgeted on short single-shot prompts). "Fast and smart at native" is why this
# profile now DEFAULTs to native 256k (RECOMMENDED_CTX_8GB=262144) instead of
# the older YaRN-x2-524288 stance - re-ran as an opt-in context mode. The
# YaRN x2 (524288) rung itself is still fit-verified (PASS fitted=524288, VRAM
# 6403 MiB, RSS 23.2 GiB) but the harness's reasoning-off needle gate at that
# window returns an EMPTY completion (prefill ok, eval 1 token / 0.00 ms) - so
# 524288 stays an explicit opt-in (CTX_MODES 'yarn2' below), never the default.
# Static YaRN also measurably degrades sub-256K prompts (Qwen's guidance), which
# is the second reason native is the default here. YaRN x3 (786432) stays the
# physical ceiling; x4/1M does not fit a 32GB box.
RECOMMENDED_CTX_8GB=262144

# Context-window modes (YaRN opt-in, alongside the reasoning menu). Native 256k
# is the default; 'yarn2' extends to 524288 via YaRN x2. The arch key that
# llama-server needs to accept -c past native is qwen35moe.context_length (this
# is what ROPE_YARN_OVERRIDE_KV was doing before CTX_MODES took over); the
# launcher builds the --override-kv from the entry's arch key. Note that this
# profile is vision-capable (mmproj), and YaRN/rope modes coexist with the
# projector - only speculative decoding conflicts with it.
CTX_MODES=(
  "native|262144|"
  "yarn2|524288|2|qwen35moe.context_length"
)

# Not a Per-Layer-Embeddings model - nothing to offload here.
PLE_TENSOR_REGEX=""

# KV cache quant type follows the hybrid profiles' stance: this project's
# default q8_0/q8_0. The KV is small enough that saving ~1.25 GiB with q4_0/q4_0
# is not worth re-opening the quant-combo landmine the Qwen3.5-9B SPEED SWEEP
# documented. If a future rebuild turns GGML_CUDA_FA_ALL_QUANTS on, revisit
# q4_0/q4_0 as a KV-frugality option.

# The Ornith model card's own sampling for its agentic/coding benches: temp 1.0
# / top_p 0.95 (the qwen3-coder-next.yml card and tools examples also use 0.6
# for chat, but its headline Terminal-Bench / MCP-Atlas / ClawEval runs are all
# 1.0/0.95; the card's warnings only about rope scaling having static-factor
# quality costs, not about sampling). We keep 1.0/0.95 here to match the
# benchmarks this model is being evaluated against.
DEFAULT_TEMP="1.0"
DEFAULT_TOP_P="0.95"
DEFAULT_TOP_K="40"

# qwen-style reasoning toggle on this arch (same as qwen35-9b.sh).
THINKING_KWARG_KEY="enable_thinking"

# HEADROOM MATH on this 32GB-RAM box (Q4_K_M, ~20.36 GiB, ~28 GiB realistic
# ceiling for model + KV + runtime overhead), KV per context mode:
#   native 262144               KV 2.50 GiB -> model+KV 22.86 GiB  FITS
#   yarn2  524288               KV 5.00 GiB -> model+KV 25.36 GiB  FITS
#   yarn3  786432               KV 7.50 GiB -> model+KV 27.86 GiB  FITS (border)
#   1M (1048576)                KV 10.0 GiB -> model+KV 30.36 GiB  OVER ceiling
#
# WIRING: when this profile's CTX_MODES array offers more than one window, the
# launcher's context-mode resolution sets CTR + the rope vars from the chosen
# entry - overriding the static ROPE_YARN_* a standalone YaRN profile used to
# carry (removed here because CTX_MODES now owns YaRN). For 'yarn2' it emits:
#   --rope-scaling yarn --rope-scale 2 --yarn-orig-ctx 262144
#   --override-kv qwen35moe.context_length=int:524288
# The --override-kv raises the GGUF's qwen35moe.context_length so llama-server
# accepts -c past the native 262144 (without it llama.cpp rejects/warns on
# -c 524288). Static YaRN slightly hurts shorter inputs (a real cost, one
# reason native is this profile's default), so the yarn rung is sized to a
# genuinely-long workload, never the every-day window.

# "fragment|size_mib|description" - fragment matches the GGUF filename,
# size_mib feeds the context-length estimate, description is shown in the
# picker (blank is fine). Sizes exact from ornith-ai/Ornith-1.5-35B-A3B-GGUF
# file listing (bytes -> MiB, rounded up). The QUANT_MENU stops at 4-bit class:
# Q5_K_M (23.61 GiB) and Q6_K (27.20 GiB) fit a 32GB box only at reduced context
# and the profile's default is already YaRN-space-sensitive, so Q4_K_M is the
# accuracy ceiling for the full native window; Q5_K_M appears as a
# shorter-context premium option. Q8_0/BF16 (35.21/66.19 GiB) are 48GB+-only.
QUANT_MENU=(
  "Q4_K_M|20708|PRIMARY/DEFAULT: 4-bit (20.22 GiB) - precision ceiling at native 262144 and the YaRN x2 rung (524288) on 32GB RAM, comfortable headroom"
  "Q5_K_M|24173|4-bit/5-bit (23.61 GiB) - premium fidelity at reduced context; YaRN x2 tightens but is the realistic cap"
  "Q4_K_M|20708|(official repo carries only Q4/Q5/Q6/Q8/BF16 - for an IQ3/IQ4_XS ladder with more context headroom see bartowski/Ornith-1.5-35B-A3B-GGUF)"
)
QUANT_MENU_INTRO="Ornith-1.5-35B-A3B from \$HF_REPO. MIT-licensed agentic-coding MoE,
reasoning model (thinking on - use the reasoning-mode menu), vision-capable (the
official repo ships mmproj-Ornith-1.5-35B-BF16.gguf, wired into the Kilo entry).
Native 256K (262144) is the default window - Q4_K_M is the precision ceiling there and
at the opt-in YaRN x2 (524288) rung on 32GB RAM. YaRN x3 (786432) is the physical
ceiling but quality drops past ~500K and x4/1M does not fit (see the context-mode block
above). For a denser quant ladder (IQ4_XS/IQ3_M...) use bartowski's repo instead."

# Printed inside the generated start-local-llama.sh header. Kept to one line
# here - the generator wraps it to fit the comment column.
ARCH_NOTES="NGL_MODE=fit (qwen3_5_moe 256-expert MoE): leaving -ngl unset so --fit places experts across GPU/RAM; --override-tensor/--n-cpu-moe redundant for the same reasons as the other MoE profiles"