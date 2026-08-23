# 20-model-profile.sh
# Sourced by install.sh. Which model-profiles/*.sh fragment to load (from the
# shipped directory plus the presets dir), which quant to download, VRAM/context
# sizing, the optional VRAM-headroom tradeoffs, speculative-decoding draft
# length, and the new kilo-mode fields (multimodal mmproj download offer,
# reasoning mode/effort). This file holds ONLY prompt_model_profile() - the
# model picker. The model-specific sizing prompts live in the sibling
# 20-model-sizing.sh and 20-model-download-opts.sh files.
#
# Sets PROFILE_FILE, PROFILE_NAME, MODEL_RUNTIME, RUNTIME_PORT, and the other
# model-profile globals (N_LAYERS, KV_MODEL, SPEC_MODE, etc) as a side effect
# of sourcing the chosen profile - later install.d/*.sh files rely on those
# being set here first.
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