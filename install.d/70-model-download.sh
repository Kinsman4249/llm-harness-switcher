# 70-model-download.sh
# Sourced by install.sh. Step 9/9c: downloads the main model (and, for
# profiles that use a separate drafter for speculative decoding, the drafter
# too; and, for multimodal profiles that opted in, the mmproj projector) into
# $MODEL_ROOT/$MODEL_PROFILE. Ollama profiles pull from Ollama's registry
# instead; vllm profiles download nothing here (vllm fetches on first serve).
# Sets MODEL_DIR, LLAMA_MODEL_PATH, LLAMA_DRAFT_PATH, LLAMA_MMPROJ_PATH as
# side effects - 80-launcher.sh reads them.

# Runs a command string either inside the distrobox container or directly on
# the host, depending on PACKAGING. The string is single-quote-scoped around
# every path interpolation, exactly like the historical code did inside
# distrobox: $MODEL_DIR etc. expand here (outer shell, at call time), then a
# `bash -lc` re-parses the quoted command with those paths intact.
run_in_target() {
  local cmd="$1"
  if [ "$PACKAGING" = "distrobox" ]; then
    distrobox enter "$CONTAINER_NAME" -- bash -lc "$cmd"
  else
    bash -lc "$cmd"
  fi
}

# --- Hugging Face authentication: optional but strongly recommended ---
# Anonymous (unauthenticated) requests share a much lower rate limit than
# authenticated ones. This isn't theoretical - confirmed firsthand while
# testing the Nemotron 3 Nano profiles below: an 18GB anonymous download's
# transfer concurrency got throttled down to a crawl (effectively stalled
# for minutes at a time) after sustained use in one session, and picked
# back up immediately once the container was authenticated. A free,
# read-only token avoids that entirely.
#
# This function never sees or stores the token itself - it always delegates
# to `hf auth login`'s own interactive flow, which prompts for the token
# with input hidden (not echoed to the terminal or shell history) and
# writes it to a permission-restricted file (chmod 600) inside the target.
# Deliberately NOT added to save_config()/$CONF_FILE: that file is plaintext
# with no permission restriction (see PROXY_MASTER_KEY in
# install.d/00-config.sh for an existing example of what it already stores
# in the clear) - a token deserves better than that, so this project never
# lets it touch that file, or any bash variable of ours, at all.
ensure_hf_auth() {
  # A completely fresh target may not have the `hf` CLI yet - the regular
  # download path below only installs it once a download actually starts, but
  # this function can run before that, so it needs its own install-if-missing
  # check rather than assuming `hf` is already on PATH.
  run_in_target '
    command -v hf >/dev/null 2>&1 || {
      python3 -m pip --version >/dev/null 2>&1 || {
        if command -v sudo >/dev/null 2>&1; then
          if command -v dnf >/dev/null 2>&1; then sudo dnf install -y python3-pip; else sudo apt-get install -y -qq python3-pip; fi
        else
          echo "WARNING: no sudo available to install python3-pip; hf CLI will be missing." >&2
        fi
      }
      sudo python3 -m pip install -U huggingface_hub --break-system-packages -q
    }
  '

  local HF_WHOAMI
  HF_WHOAMI="$(run_in_target 'hf auth whoami 2>/dev/null')"
  if [ -n "$HF_WHOAMI" ]; then
    log "Already authenticated to Hugging Face ($HF_WHOAMI)"
    return
  fi

  echo
  echo "Hugging Face downloads work fine without an account, but anonymous"
  echo "requests share a much lower rate limit - on a large model this can mean"
  echo "a download's transfer speed gets throttled down until it looks stalled"
  echo "for minutes at a time. A free, read-only access token removes that limit."
  echo
  echo "Generate one (the 'read' role is enough, no need for 'write') at:"
  echo "  https://huggingface.co/settings/tokens"
  local SETUP_HF_AUTH="yes"
  ask SETUP_HF_AUTH "Set up Hugging Face authentication now? (yes/no)"
  if [ "$SETUP_HF_AUTH" != "yes" ]; then
    echo "Skipping - downloads will use the slower anonymous rate limit."
    return
  fi

  echo "Paste your token at the prompt below (input is hidden). This runs hf's"
  echo "own login flow directly on the target - this script never sees or"
  echo "stores the token itself."
  if [ "$PACKAGING" = "distrobox" ]; then
    distrobox enter "$CONTAINER_NAME" -- hf auth login
  else
    hf auth login
  fi
}

# --- Step 9: download the model ---
# Each profile gets its own directory ($MODEL_ROOT/$MODEL_PROFILE/) rather
# than a shared search across the whole home directory - with more than one
# model family downloaded, a bare "find ~" glob can match the wrong family's
# file, or pick up a drafter/mmproj file that happens to share the quant
# fragment. The main-model search also excludes drafter ("mtp-*"/
# "*assistant*") and multimodal-projector ("mmproj-*") files explicitly,
# since those are real GGUF files that would otherwise satisfy the same
# *.gguf glob.
download_main_model() {
  # $MODEL_ROOT here is expanded by THIS shell at call time - MODEL_DIR is
  # embedded single-quoted into every command string run_in_target executes,
  # so a path with spaces still arrives intact (and $HOME expansion happens
  # before the single quotes, not after).
  MODEL_DIR="$MODEL_ROOT/$MODEL_PROFILE"
  MAIN_MODEL_FIND="find '$MODEL_DIR' -maxdepth 1 -iname '*$GGUF_PATTERN*.gguf' \
    -not -iname 'mtp-*' -not -iname '*assistant*' -not -iname 'mmproj-*' 2>/dev/null"

  # vllm serves from the id/GGUF path directly; ollama pulls its own registry.
  case "$MODEL_RUNTIME" in
    ollama)
      LLAMA_MODEL_PATH=""
      LLAMA_DRAFT_PATH=""
      if [ "$DOWNLOAD_MODEL_NOW" = "yes" ]; then
        if [ -z "${OLLAMA_MODEL:-}" ]; then
          echo "WARNING: MODEL_RUNTIME=ollama but this profile doesn't set" >&2
          echo "OLLAMA_MODEL (namespace/model). Add it to $PROFILE_FILE." >&2
          return
        fi
        run_in_target "if command -v ollama >/dev/null 2>&1; then :; else echo 'WARNING: ollama not installed - re-run install.sh after the runtime-install stage succeeds.' >&2; fi"
        echo "Pulling $OLLAMA_MODEL from the Ollama registry (large download)..."
        local PULL_RC
        run_in_target "ollama pull '$OLLAMA_MODEL'"
        PULL_RC=$?
        if [ "$PULL_RC" -ne 0 ] && ! run_in_target "ollama list 2>/dev/null | grep -qwF '$OLLAMA_MODEL'"; then
          echo "WARNING: 'ollama pull $OLLAMA_MODEL' failed (exit $PULL_RC)." >&2
          echo "Run it yourself: $([ "$PACKAGING" = "distrobox" ] && echo "distrobox enter $CONTAINER_NAME --") ollama pull $OLLAMA_MODEL" >&2
          echo "Then re-run install.sh." >&2
        else
          echo "ollama model $OLLAMA_MODEL is pulled."
        fi
      else
        echo "Skipped ollama pull (DOWNLOAD_MODEL_NOW=no)."
      fi
      return
      ;;

    vllm)
      LLAMA_MODEL_PATH=""
      LLAMA_DRAFT_PATH=""
      if [ -z "${VLLM_MODEL_ID:-}" ]; then
        echo "WARNING: MODEL_RUNTIME=vllm but this profile doesn't set" >&2
        echo "VLLM_MODEL_ID. Add it to $PROFILE_FILE." >&2
      else
        echo "vllm downloads '$VLLM_MODEL_ID' on first 'vllm serve' (this project"
        echo "never predownloads it - the runtime does, automatically)."
      fi
      return
      ;;

    llama.cpp) : ;;   # real download logic below
    *) echo "WARNING: unknown MODEL_RUNTIME '$MODEL_RUNTIME', treating as llama.cpp." >&2 ;;
  esac

  LLAMA_MODEL_PATH=""
  if [ "$DOWNLOAD_MODEL_NOW" = "yes" ]; then
    ensure_hf_auth
    echo "Checking whether a *$GGUF_PATTERN*.gguf file is already downloaded in $MODEL_DIR..."
    local MATCHES MATCH_COUNT_MODEL
    MATCHES="$(run_in_target "mkdir -p '$MODEL_DIR'; $MAIN_MODEL_FIND")"
    MATCH_COUNT_MODEL="$(echo "$MATCHES" | grep -c . || true)"

    if [ "$MATCH_COUNT_MODEL" = "1" ]; then
      LLAMA_MODEL_PATH="$MATCHES"
      echo "Already have it at $LLAMA_MODEL_PATH, skipping download."
    elif [ "$MATCH_COUNT_MODEL" -gt 1 ] 2>/dev/null; then
      echo "More than one matching GGUF already in $MODEL_DIR - pick the one to use:"
      echo "$MATCHES"
      read -rp "Paste the full path to use: " LLAMA_MODEL_PATH
    else
      local MAIN_DOWNLOAD_CMD="hf download '$HF_REPO' --include '*$GGUF_PATTERN*.gguf' --exclude 'mmproj-*' --local-dir '$MODEL_DIR'"
      local attempt=1
      while :; do
        echo "Downloading a *$GGUF_PATTERN*.gguf file from $HF_REPO, this is a multi-GB download (attempt $attempt)..."
        run_in_target "
          mkdir -p '$MODEL_DIR' &&
          (python3 -m pip --version >/dev/null 2>&1 || {
            if command -v dnf >/dev/null 2>&1; then sudo dnf install -y python3-pip
            elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y -qq python3-pip
            fi
          }) &&
          sudo python3 -m pip install -U huggingface_hub --break-system-packages -q &&
          $MAIN_DOWNLOAD_CMD
        "
        local download_rc=$?
        LLAMA_MODEL_PATH="$(run_in_target "$MAIN_MODEL_FIND" | head -n1)"
        if [ -n "$LLAMA_MODEL_PATH" ]; then
          log "Downloaded to $LLAMA_MODEL_PATH"
          break
        fi
        # Either hf download itself failed (download_rc != 0), or it exited 0
        # but no matching *.gguf turned up - e.g. a resumed/interrupted
        # transfer that left only a .incomplete file behind. Same recovery
        # either way: offer a retry (hf download resumes partial transfers by
        # default) before giving up and handing back the exact command to run
        # by hand.
        if [ "$download_rc" -ne 0 ]; then
          echo "WARNING: model download failed (exit $download_rc)." >&2
        else
          echo "WARNING: hf download reported success, but no *$GGUF_PATTERN*.gguf" >&2
          echo "file was found in $MODEL_DIR afterward - the transfer likely got" >&2
          echo "interrupted partway. Check for a *.incomplete file inside $MODEL_DIR." >&2
        fi
        local RETRY_DOWNLOAD="yes"
        ask RETRY_DOWNLOAD "Retry the download? (yes/no)"
        if [ "$RETRY_DOWNLOAD" != "yes" ]; then
          echo "Giving up on the main model download. Check the exact quant fragment" >&2
          echo "on the repo's file listing, then run this yourself:" >&2
          echo "  $([ "$PACKAGING" = "distrobox" ] && echo "distrobox enter \"$CONTAINER_NAME\" --") $MAIN_DOWNLOAD_CMD" >&2
          echo "Re-run install.sh once that file exists in $MODEL_DIR." >&2
          break
        fi
        attempt=$((attempt + 1))
      done
    fi
  else
    # Re-runs with DOWNLOAD_MODEL_NOW=no still need a path if one was found before.
    LLAMA_MODEL_PATH="$(run_in_target "$MAIN_MODEL_FIND" | head -n1)"
    echo "Skipped model download. Run this script again with 'yes' when ready."
  fi
}

# --- Step 9b: download the multimodal projector (mmproj), if this profile ---
# --- declared one and the user opted in. ---
# With both MMPROJ_REPO/MMPROJ_PATTERN set and DOWNLOAD_MMPROJ=yes, the
# projector lands in the same $MODEL_DIR as the main GGUF and 80-launcher.sh
# passes --mmproj so llama-server genuinely serves image inputs (the kilo
# model entry then advertises attachment + image input). Skipped silently for
# text-only profiles or when the user answered no.
download_mmproj() {
  LLAMA_MMPROJ_PATH=""
  if [ "$MODEL_RUNTIME" != "llama.cpp" ]; then
    return
  fi
  if [ -z "${MMPROJ_REPO:-}" ] || [ -z "${MMPROJ_PATTERN:-}" ]; then
    return
  fi

  local MMPROJ_FIND="find '$MODEL_DIR' -maxdepth 1 -iname '*$MMPROJ_PATTERN*.gguf' 2>/dev/null | head -n1"
  LLAMA_MMPROJ_PATH="$(run_in_target "$MMPROJ_FIND")"

  if [ "$DOWNLOAD_MMPROJ" = "yes" ]; then
    if [ -n "$LLAMA_MMPROJ_PATH" ]; then
      echo "Already have the projector at $LLAMA_MMPROJ_PATH, skipping download."
      return
    fi
    ensure_hf_auth
    local MMPROJ_DOWNLOAD_CMD="hf download '$MMPROJ_REPO' --include '*$MMPROJ_PATTERN*.gguf' --local-dir '$MODEL_DIR'"
    echo "Downloading the multimodal projector ($MMPROJ_PATTERN from $MMPROJ_REPO)..."
    run_in_target "mkdir -p '$MODEL_DIR' && $MMPROJ_DOWNLOAD_CMD"
    LLAMA_MMPROJ_PATH="$(run_in_target "$MMPROJ_FIND")"
    if [ -n "$LLAMA_MMPROJ_PATH" ]; then
      log "Downloaded projector to $LLAMA_MMPROJ_PATH"
    else
      echo "WARNING: projector download didn't produce $MODEL_DIR/*$MMPROJ_PATTERN*.gguf." >&2
      echo "Run it yourself: $([ "$PACKAGING" = "distrobox" ] && echo "distrobox enter \"$CONTAINER_NAME\" --") $MMPROJ_DOWNLOAD_CMD" >&2
      echo "(Or fix MMPROJ_REPO/MMPROJ_PATTERN in $PROFILE_FILE.)" >&2
    fi
  else
    LLAMA_MMPROJ_PATH="$(run_in_target "$MMPROJ_FIND")"
  fi
}

# --- Step 9c: download the drafter model, if this profile uses one ---
# Only SPEC_MODE=draft-model needs a separate file (Qwen's self-mtp mode
# uses the MTP head already baked into the main GGUF above). If the profile
# hasn't got a confirmed drafter repo/pattern yet (both empty - true for
# both Gemma profiles as shipped, see model-profiles/gemma4-e*b.sh), this
# is skipped entirely and the generation step below omits --spec-type
# rather than emit it without a resolvable -md path.
download_drafter_model() {
  LLAMA_DRAFT_PATH=""
  if [ "$MODEL_RUNTIME" != "llama.cpp" ]; then
    return
  fi
  if [ "$SPEC_MODE" = "draft-model" ]; then
    if [ -n "${DRAFT_REPO:-}" ] && [ -n "${DRAFT_PATTERN:-}" ]; then
      local DRAFT_FIND EXISTING_DRAFT
      DRAFT_FIND="find '$MODEL_DIR' -maxdepth 1 -iname '*$DRAFT_PATTERN*.gguf' 2>/dev/null"
      if [ "$DOWNLOAD_MODEL_NOW" = "yes" ]; then
        EXISTING_DRAFT="$(run_in_target "$DRAFT_FIND" | head -n1)"
        if [ -n "$EXISTING_DRAFT" ]; then
          LLAMA_DRAFT_PATH="$EXISTING_DRAFT"
          echo "Already have the drafter model at $LLAMA_DRAFT_PATH, skipping download."
        else
          # --exclude 'MTP/*': unsloth's Gemma 4 repos duplicate the top-level
          # drafter file inside an MTP/ subfolder (BF16/F16/Q8_0 variants) -
          # without this, the glob below matches those too and downloads an
          # extra ~340 MiB that never gets used (maxdepth 1 finds only the
          # top-level file when picking LLAMA_DRAFT_PATH below).
          local DRAFT_DOWNLOAD_CMD="hf download '$DRAFT_REPO' --include '*$DRAFT_PATTERN*.gguf' --exclude 'MTP/*' --local-dir '$MODEL_DIR'"
          local draft_attempt=1
          while :; do
            echo "Downloading a *$DRAFT_PATTERN*.gguf drafter from $DRAFT_REPO (attempt $draft_attempt)..."
            run_in_target "$DRAFT_DOWNLOAD_CMD"
            local draft_rc=$?
            LLAMA_DRAFT_PATH="$(run_in_target "$DRAFT_FIND" | head -n1)"
            if [ -n "$LLAMA_DRAFT_PATH" ]; then
              log "Downloaded drafter to $LLAMA_DRAFT_PATH"
              break
            fi
            # Same failure mode as the main-model download above: a report of
            # success with no matching file usually means an interrupted
            # transfer left only a .incomplete file behind - but this is also
            # the path that silently ate the whole download once already (see
            # handoff.md 2026-07-24: file never appeared, no .incomplete
            # either, root cause not pinned down), so don't just warn and move
            # on - offer a retry before falling back to a manual command.
            if [ "$draft_rc" -ne 0 ]; then
              echo "WARNING: drafter download failed (exit $draft_rc)." >&2
            else
              echo "WARNING: hf download reported success, but no *$DRAFT_PATTERN*.gguf" >&2
              echo "drafter file was found in $MODEL_DIR afterward - the transfer likely" >&2
              echo "got interrupted partway. Check for a *.incomplete file inside $MODEL_DIR." >&2
            fi
            local RETRY_DRAFT="yes"
            ask RETRY_DRAFT "Retry the drafter download? (yes/no)"
            if [ "$RETRY_DRAFT" != "yes" ]; then
              echo "Giving up on the drafter download. Check the exact filename fragment" >&2
              echo "on the repo's file listing, then run this yourself:" >&2
              echo "  $([ "$PACKAGING" = "distrobox" ] && echo "distrobox enter \"$CONTAINER_NAME\" --") $DRAFT_DOWNLOAD_CMD" >&2
              echo "Re-run install.sh once that file exists in $MODEL_DIR, or start" >&2
              echo "llama-server without it (slower, no speculative decoding)." >&2
              break
            fi
            draft_attempt=$((draft_attempt + 1))
          done
        fi
      else
        LLAMA_DRAFT_PATH="$(run_in_target "$DRAFT_FIND" | head -n1)"
      fi
    fi
    if [ -z "$LLAMA_DRAFT_PATH" ]; then
      echo "WARNING: this profile uses a separate drafter model for speculative" >&2
      echo "decoding, but none is configured/resolved (DRAFT_REPO/DRAFT_PATTERN" >&2
      echo "empty, or the download/search above found nothing). Starting without" >&2
      echo "speculative decoding - slower, but correct, rather than guessing a" >&2
      echo "drafter file. Fill in DRAFT_REPO/DRAFT_PATTERN in $PROFILE_FILE once" >&2
      echo "you've confirmed the real filenames, then re-run install.sh." >&2
    fi
  fi
}