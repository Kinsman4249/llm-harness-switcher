# model-profiles/gemma4-e2b.sh
# The SHIPPED EXAMPLE profile and the field reference every other profile
# follows - see model-profiles/README.md for the full authoring guide.
# Profile for Gemma 4 E2B. See the private presets repo's gemma4-e4b.sh for
# the fuller comments - the two profiles only differ in size/layer numbers
# and repo names. E2B is the weaker tool-use model of the pair (Tau2 tool-use
# average 24.5% vs E4B's 42.2%, per the Google model card) - offered for
# completeness, but the presets repo's gemma4-e4b.sh is the recommended Gemma
# choice for a Claude Code workload.
#
# UNVERIFIED VALUES: a few fields below are placeholders, not confirmed
# facts, because confirming them needs a live llama-server build with this
# model's actual GGUF loaded (see gemma4-support-spec.md sections 3 and 4).
# install.sh is written to fail loudly (skip the feature, print a warning)
# rather than guess, per this project's "no invented flags" rule. Fill these
# in only after running the verification steps in gemma4-support-spec.md
# against a real build, then remove this warning block. The multimodal and
# reasoning fields above ARE set to confirmed-on-the-Hub values on purpose -
# they're the example of those features working, not placeholders.

PROFILE_NAME="Gemma 4 E2B"
HF_REPO_DEFAULT="unsloth/gemma-4-E2B-it-GGUF"   # google/gemma-4-E2B-GGUF does not exist (404) - Google never
                                                 # published a GGUF for this model; unsloth's quant repo confirmed
                                                 # to exist on the Hub. Quant filenames/sizes still UNVERIFIED below.

# Runtime that serves this model. llama.cpp builds llama-server and downloads
# the GGUF; "ollama" would use OLLAMA_MODEL instead; "vllm" uses VLLM_MODEL_ID.
# Leave at llama.cpp unless you've added one of the other runtimes.
MODEL_RUNTIME="llama.cpp"                        # llama.cpp | ollama | vllm
# RUNTIME_PORT is per-runtime (llama.cpp 8080, ollama 11434, vllm 8000);
# only set it here to override that default.

# Multimodal: real image input. Gemma 4 is multimodal upstream, and this
# example profile wires it up so every image path install.sh exposes gets a
# real value (mirroring how the presets repo's gemma4-e4b.sh does it). The
# unsloth repo ships mmproj-*.gguf files (mmproj-BF16/F16/F32.gguf, confirmed
# in the repo listing 2026-08-18); F16 is the standard llama.cpp pick. With
# both set, install.d/70-model-download.sh offers to download the projector
# and install.d/80-launcher-build.sh passes --mmproj on the llama-server command
# line, and the kilo model entry advertises attachment + image input. Note:
# whether llama-server actually loads this specific projector still needs one
# live check against a real build (see the UNVERIFIED caveat at the top) -
# but the value itself is real and confirmed to exist on the Hub, not a guess.
MMPROJ_REPO="unsloth/gemma-4-E2B-it-GGUF"
MMPROJ_PATTERN="mmproj-F16"

# Reasoning/"thinking" mode for this model. All three modes are supported and
# wired end to end - install.sh's prompt offers them, install.d/80-launcher-build.sh
# maps them to the right llama.cpp flag (--reasoning on/off/effort, or the
# chat-template-kwargs fallback), and sync-local-model.sh copies them into the
# kilo model entry (reasoning + options.reasoningEffort for "effort"):
#   "off"    (the default) - preserves the measured tool-calling stance:
#            thinking cost ~13x tokens / ~11x latency for no tool-call gain on
#            this project's live tests (see README "Thinking mode")
#   "on"     - force reasoning always on
#   "effort" - reasoning on, with a selectable effort level
# REASONING_EFFORT only matters when REASONING_MODE=effort.
REASONING_MODE="off"                             # off | on | effort
REASONING_EFFORT="low"                           # low | medium | high (used when REASONING_MODE=effort)

# Reasoning-mode switcher (kilo mode only). When REASONING_MODES lists more
# than one mode, start-local-model.sh lets each launch pick a mode and shows an
# interactive menu (or `--profile <stem> --mode <name>` forces one
# non-interactively). This is the ONLY place a Gemma/Nemotron thinking mode is
# switched - it is NOT exposed via Kilo's Shift+Tab.
#
# Kilo's Shift+Tab reasoning-effort variants only cycle per-request effort for
# models whose chat template advertises a client-side effort level (and only
# when the model advertises supportsReasoningEffort). Gemma 4 and Nemotron (and
# this project's other profiles) toggle reasoning server-side via the
# enable_thinking chat-template kwarg, which `--reasoning` sets once at server
# start - there is no per-request knob, so Shift+Tab cannot drive it. See
# model-profiles/README.md "Kilo model entry" for the full mechanism.
#
# Mode switches therefore require a llama-server RESTART: the resolved mode is
# baked into the server's --reasoning flag at load. With a server already
# healthy, start-local-model.sh re-syncs the running config and refuses a
# conflicting --mode (it prints "switching the reasoning mode requires
# restarting llama-server") rather than silently restarting an in-use server.
#
# A profile that sets none of the REASONING_* menu fields keeps the legacy
# single-mode behavior above (off|on|effort, no menu). This shipped example
# shows the fields as the reference; Gemma's template also honors the legacy
# "effort" level, so it is offered here alongside off/on.
REASONING_MODES="off,on,effort"
# budgeted/max (as Nemotron's profile uses): "budgeted" is `--reasoning on
# --reasoning-budget <REASONING_BUDGET_DEFAULT>`, "max" is `--reasoning on
# --reasoning-budget -1`; both raise -n / Kilo limit.output to
# REASONING_OUTPUT_MAX (a budget larger than the output window can never be
# spent). A profile that wants to offer them sets these two fields too.
# REASONING_BUDGET_DEFAULT="8192"
# REASONING_OUTPUT_MAX="16384"

# Kilo Code provider entry capability flags and identity (see the generated
# start-local-model.sh / sync-local-model.sh). KILO_MODEL_ID defaults to this
# file's stem, KILO_MODEL_NAME defaults to PROFILE_NAME if left empty.
KILO_TOOL_CALL="yes"                             # yes | no
KILO_TEMPERATURE="yes"                           # yes | no
KILO_MODEL_ID=""
KILO_MODEL_NAME=""

DRAFT_REPO="unsloth/gemma-4-E2B-it-GGUF"        # confirmed on the Hub: top-level mtp-gemma-4-E2B-it.gguf
                                                 # (97817664 bytes, Q8_0 only, single file - not baked into the
                                                 # main GGUF above, despite living in the same repo). There's also
                                                 # an MTP/ subfolder with BF16/F16/Q8_0 duplicates of this same
                                                 # head - the pattern below is scoped to avoid grabbing those too.
DRAFT_PATTERN="mtp-gemma-4-E2B-it"               # STILL UNVERIFIED: repo/file existence is confirmed, but whether
                                                 # llama.cpp's -md speculative decoding actually loads this
                                                 # MTP-specific GGUF (vs. erroring on an unrecognized draft
                                                 # architecture) needs a live server test, not just a Hub listing.
SPEC_MODE="draft-model"                         # none | self-mtp | draft-model

N_LAYERS=35

# Gemma 4's hybrid local/global attention with unified K/V on global layers
# has no simple closed-form bytes/token the way Qwen3.5-9B's does (see
# gemma4-support-spec.md section 5) - probe a live server instead of
# hand-rolling the arithmetic.
KV_MODEL="probe"                                # manual | probe
BYTES_PER_TOKEN=                                # unused when KV_MODEL=probe

# UNVERIFIED: exact GGUF tensor name for Per-Layer Embeddings. On Gemma 3n it
# was per_layer_token_embd.weight; do not assume Gemma 4 matches without
# checking `gguf_dump.py` or llama-server's own startup tensor listing against
# the real file. Left empty so install.sh skips the PLE-offload prompt instead
# of guessing a regex that silently matches nothing (or the wrong tensor).
PLE_TENSOR_REGEX=""

# Recommended sampling from the Google model card.
DEFAULT_TEMP="1.0"
DEFAULT_TOP_P="0.95"
DEFAULT_TOP_K="64"

# Sizes confirmed from unsloth/gemma-4-E2B-it-GGUF's own file listing
# (bytes -> MiB, rounded up): Q4_K_M 3106738272, Q5_K_M 3356037216,
# Q8_0 5048352864. KV_MODEL=probe means these don't feed the context
# formula directly (that's Qwen-only, see prompt_vram_and_context in
# install.d/20-model-sizing.sh) but they're accurate for display now.
QUANT_MENU=(
  "Q4_K_M|2963|confirmed from the repo's file listing"
  "Q5_K_M|3201|confirmed from the repo's file listing"
  "Q8_0|4814|confirmed from the repo's file listing"
)
QUANT_MENU_INTRO="Gemma 4 E2B from \$HF_REPO."

# Printed inside the generated start-local-llama.sh header, next to -ngl 99.
# Kept to one line here - the generator wraps it to fit the comment column.
ARCH_NOTES="no --n-cpu-moe: Gemma 4 E2B has no MoE layers (dense model), so that flag would be a no-op. PLE tables are the offload lever for this model instead, see PLE_TENSOR_REGEX above"
