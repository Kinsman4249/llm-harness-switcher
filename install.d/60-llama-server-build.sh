# 60-llama-server-build.sh
# Sourced by install.sh. The runtime-install stage: makes sure the runtime the
# selected profile needs is installed. dispatch via ensure_runtime():
#   - llama.cpp: builds llama-server from source (CUDA build inside the
#     distrobox container, or a native build with backend auto-detect:
#     CUDA > Vulkan > CPU, in $HOME/llama.cpp).
#   - ollama:    dnf package inside the container (distrobox), or the official
#     install script on the host (native).
#   - vllm:      pip into the container (distrobox), or a venv under
#     $HOME/.local (native).
# Sets LLAMA_SERVER_BIN as a side effect (only for llama.cpp), cached in
# CONF_FILE so re-runs skip straight past it.

# --- llama.cpp runtime ---
ensure_llama_server_binary() {
  if [ -n "$LLAMA_SERVER_BIN" ]; then
    log "Using cached llama-server path: $LLAMA_SERVER_BIN"
    return
  fi

  if [ "$PACKAGING" = "distrobox" ]; then
    ensure_llama_server_binary_distrobox
  else
    ensure_llama_server_binary_native
  fi
}

# CUDA-in-container build (the long-standing flow, recommended on
# Fedora/Bazzite hosts). One-time cost per container - once LLAMA_SERVER_BIN
# is cached in CONF_FILE, re-runs skip straight past it.
ensure_llama_server_binary_distrobox() {
  if [ -z "$CONTAINER_NAME" ] || ! distrobox list 2>/dev/null | tail -n +2 | grep -qi "$CONTAINER_NAME"; then
    echo "ERROR: PACKAGING=distrobox but container '$CONTAINER_NAME' was not found" >&2
    echo "by distrobox list. Re-run install.sh with PACKAGING=native (or create" >&2
    echo "the container first)." >&2
    exit 1
  fi
  echo "Checking for an existing llama-server build inside $CONTAINER_NAME..."
  local FOUND_BIN
  FOUND_BIN="$(distrobox enter "$CONTAINER_NAME" -- bash -lc '
    if command -v llama-server >/dev/null 2>&1; then
      command -v llama-server
    elif [ -x "$HOME/llama.cpp/build/bin/llama-server" ]; then
      echo "$HOME/llama.cpp/build/bin/llama-server"
    fi
  ' 2>/dev/null)"

  if [ -n "$FOUND_BIN" ]; then
    LLAMA_SERVER_BIN="$FOUND_BIN"
    save_config
    echo "Found existing llama-server at $LLAMA_SERVER_BIN"
  else
    echo "llama-server not found inside $CONTAINER_NAME, building it from source"
    echo "(clone + cmake + CUDA compile, takes several minutes)..."
    local BUILD_LOG BUILD_STATUS
    BUILD_LOG="$(distrobox enter "$CONTAINER_NAME" -- bash -lc '
      set -e
      # cuda-toolkit installs nvcc under /usr/local/cuda/bin, but does not add
      # it to PATH itself (that normally happens via a fresh shell login after
      # the alternatives symlink is set up) - add it here so nvcc is usable in
      # this same subshell immediately after installing below, without needing
      # a new distrobox enter.
      export PATH="/usr/local/cuda/bin:$PATH"
      command -v cmake  >/dev/null 2>&1 || sudo dnf install -y cmake
      command -v git    >/dev/null 2>&1 || sudo dnf install -y git
      command -v g++    >/dev/null 2>&1 || sudo dnf install -y gcc-c++
      if ! command -v nvcc >/dev/null 2>&1; then
        echo "nvcc not found, attempting to install the CUDA toolkit..."
        # Fedora'\''s own repos do not carry "cuda-toolkit" at all - it only exists
        # once NVIDIA'\''s own repo is added, matched to the container'\''s Fedora
        # version (confirmed empty on a stock Fedora 41 container: the plain
        # "sudo dnf install -y cuda-toolkit" 404s with "No match for argument").
        # See https://developer.download.nvidia.com/compute/cuda/repos/ for the
        # list of repo files NVIDIA publishes per distro version.
        if ! dnf list available cuda-toolkit >/dev/null 2>&1; then
          FEDORA_VER="$(. /etc/os-release && echo "$VERSION_ID")"
          REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/fedora${FEDORA_VER}/x86_64/cuda-fedora${FEDORA_VER}.repo"
          if curl -fsI "$REPO_URL" >/dev/null 2>&1; then
            echo "Adding NVIDIA'\''s CUDA repo for Fedora $FEDORA_VER ($REPO_URL)..."
            sudo dnf config-manager addrepo --from-repofile="$REPO_URL"
            sudo dnf makecache
          else
            echo "NVIDIA has no published CUDA repo for Fedora $FEDORA_VER yet" >&2
            echo "($REPO_URL 404s). Check developer.nvidia.com/cuda-downloads for" >&2
            echo "a supported release, or add a matching repo manually." >&2
          fi
        fi
        sudo dnf install -y cuda-toolkit || true
      fi
      if ! command -v nvcc >/dev/null 2>&1; then
        echo "ERROR: nvcc still not available after attempting install." >&2
        echo "Install a CUDA toolkit matching your driver manually (e.g. from" >&2
        echo "developer.nvidia.com/cuda-downloads or your distro repos), then" >&2
        echo "re-run install.sh." >&2
        exit 1
      fi

      if [ -d "$HOME/llama.cpp/.git" ]; then
        git -C "$HOME/llama.cpp" pull
      else
        # A directory may already exist from a failed or partial clone; a stale
        # non-repo dir makes `git pull` fail with "not a git repository", so
        # clear it and clone fresh.
        [ -d "$HOME/llama.cpp" ] && rm -rf "$HOME/llama.cpp"
        git clone https://github.com/ggml-org/llama.cpp "$HOME/llama.cpp"
      fi
      cd "$HOME/llama.cpp"
      cmake -B build -DGGML_CUDA=ON
      cmake --build build --config Release -j"$(nproc)" --target llama-server
    ' 2>&1)"
    BUILD_STATUS=$?

    if [ "$INSTALL_VERBOSE" = "yes" ]; then
      log "llama-server build output:"
      log "$BUILD_LOG"
    fi

    if [ $BUILD_STATUS -ne 0 ]; then
      echo "WARNING: llama-server build failed. Last part of the build output:" >&2
      echo "$BUILD_LOG" | tail -n 20 >&2
      echo "Fix the issue above (often a missing CUDA toolkit) and re-run install.sh." >&2
    else
      LLAMA_SERVER_BIN="$HOME/llama.cpp/build/bin/llama-server"
      # $HOME here is the host's, but distrobox mounts the host home into the
      # container at the same path, so this resolves correctly inside it too.
      save_config
      echo "Built llama-server at $LLAMA_SERVER_BIN"
    fi
  fi
}

# Native build (no distrobox). Prefer the distro's packaged llama-server when
# it exists (Ubuntu 24.04+ / Debian trixie ship a llama-cpp package), else
# source-build in $HOME/llama.cpp with backend auto-detect: CUDA (nvcc
# present) > Vulkan (an ICD is installed) > CPU. On a Debian 12 box like
# vscodium-for-immutable's vscodium-box this lands on CPU (only /dev/dri
# passed through) - which is exactly what the plan's picture assumes.
ensure_llama_server_binary_native() {
  echo "Checking for an existing llama-server on the host..."
  local FOUND_BIN
  FOUND_BIN="$(command -v llama-server 2>/dev/null || true)"
  if [ -n "$FOUND_BIN" ]; then
    LLAMA_SERVER_BIN="$FOUND_BIN"
    save_config
    echo "Found packaged llama-server at $LLAMA_SERVER_BIN"
    return
  fi

  # apt-packaged llama-cpp (Debian trixie / Ubuntu 24.04+) provides
  # llama-server. Only install it when the package actually resolves in this
  # distro's repos - on Debian 12 bookworm it does not exist.
  if command -v apt-get >/dev/null 2>&1 && apt-cache policy llama-cpp 2>/dev/null | grep -q "Candidate:"; then
    echo "Installing llama-cpp from your distro's repos (provides llama-server)..."
    if sudo apt-get update -qq && sudo apt-get install -y -qq llama-cpp; then
      FOUND_BIN="$(command -v llama-server 2>/dev/null || true)"
      if [ -n "$FOUND_BIN" ]; then
        LLAMA_SERVER_BIN="$FOUND_BIN"
        save_config
        echo "Installed llama-server at $LLAMA_SERVER_BIN"
        return
      fi
    fi
    echo "WARNING: apt install of llama-cpp didn't yield a usable llama-server -" >&2
    echo "falling back to a source build below." >&2
  fi

  echo "llama-server not found on the host, building it from source in"
  echo "$HOME/llama.cpp with backend auto-detect (CUDA > Vulkan > CPU, takes"
  echo "several minutes on a CPU-only box)..."
  local BUILD_LOG BUILD_STATUS
  BUILD_LOG="$(bash -c '
    set -e
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -qq || true
      sudo apt-get install -y -qq build-essential cmake git || {
        echo "ERROR: could not install build-essential/cmake/git via apt." >&2
        exit 1
      }
    elif command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y cmake git gcc-c++ make 2>/dev/null || true
    else
      command -v cmake >/dev/null 2>&1 || { echo "ERROR: cmake missing (install it for your distro)." >&2; exit 1; }
      command -v git   >/dev/null 2>&1 || { echo "ERROR: git missing." >&2; exit 1; }
      command -v g++   >/dev/null 2>&1 || { echo "ERROR: a C++ compiler missing." >&2; exit 1; }
    fi

    if [ -d "$HOME/llama.cpp/.git" ]; then
      git -C "$HOME/llama.cpp" pull
    else
      # A directory may already exist from a failed or partial clone; a stale
      # non-repo dir makes `git pull` fail with "not a git repository", so
      # clear it and clone fresh.
      [ -d "$HOME/llama.cpp" ] && rm -rf "$HOME/llama.cpp"
      git clone https://github.com/ggml-org/llama.cpp "$HOME/llama.cpp"
    fi
    cd "$HOME/llama.cpp"
    if command -v nvcc >/dev/null 2>&1; then
      CMAKE_BACKEND="-DGGML_CUDA=ON"
    elif [ -d /usr/share/vulkan/icd.d ] || command -v vulkaninfo >/dev/null 2>&1; then
      CMAKE_BACKEND="-DGGML_VULKAN=ON"
    else
      CMAKE_BACKEND=""
    fi
    echo "Backend detection flags: ${CMAKE_BACKEND:-<CPU>}"
    cmake -B build $CMAKE_BACKEND
    cmake --build build --config Release -j"$(nproc)" --target llama-server
  ')"
  BUILD_STATUS=$?

  if [ "$INSTALL_VERBOSE" = "yes" ]; then
    log "llama-server build output:"
    log "$BUILD_LOG"
  fi

  if [ $BUILD_STATUS -ne 0 ]; then
    echo "WARNING: llama-server source build failed. Last part of the output:" >&2
    echo "$BUILD_LOG" | tail -n 20 >&2
    echo "Fix the issue above and re-run install.sh." >&2
  else
    LLAMA_SERVER_BIN="$HOME/llama.cpp/build/bin/llama-server"
    save_config
    echo "Built llama-server at $LLAMA_SERVER_BIN"
  fi
}

# --- ollama runtime ---
ensure_ollama() {
  if [ "$PACKAGING" = "distrobox" ]; then
    if [ -z "$CONTAINER_NAME" ] || ! distrobox list 2>/dev/null | tail -n +2 | grep -qi "$CONTAINER_NAME"; then
      echo "ERROR: PACKAGING=distrobox but container '$CONTAINER_NAME' was not found." >&2
      exit 1
    fi
    echo "Ensuring ollama is installed inside $CONTAINER_NAME..."
    distrobox enter "$CONTAINER_NAME" -- bash -lc '
      command -v ollama >/dev/null 2>&1 || sudo dnf install -y ollama
      command -v ollama
    '
  else
    if command -v ollama >/dev/null 2>&1; then
      echo "ollama already installed on the host: $(command -v ollama)"
      return
    fi
    echo
    echo "ollama is not installed on the host. Installing it means running"
    echo "the official install script, which curls from https://ollama.com/"
    echo "and wants a terminal session (it uses a TTY for progress). It runs"
    echo "server-side as root, the standard upstream model."
    local DO_OLLAMA_INSTALL="no"
    ask DO_OLLAMA_INSTALL "Install ollama via its official script now? (yes/no)"
    if [ "$DO_OLLAMA_INSTALL" = "yes" ]; then
      curl -fsSL https://ollama.com/install.sh | sh
    else
      echo "Skipping ollama install. The profile needs 'ollama' on PATH to run." >&2
      echo "Install it yourself, then re-run install.sh." >&2
    fi
  fi
}

# --- vllm runtime (best-effort, heavy) ---
ensure_vllm() {
  local PYTHON_VENV="$HOME/.local/llm-harness-switcher-vllm"
  if [ "$PACKAGING" = "distrobox" ]; then
    echo "Ensuring vllm is installed inside $CONTAINER_NAME (best-effort: vllm is"
    echo "heavy and CUDA-dependent on 8GB cards; a CPU-only box runs it slowly)..."
    distrobox enter "$CONTAINER_NAME" -- bash -lc '
      command -v python3 >/dev/null 2>&1 || sudo dnf install -y python3
      python3 -m pip --version >/dev/null 2>&1 || sudo dnf install -y python3-pip
      python3 -m pip show vllm >/dev/null 2>&1 || sudo python3 -m pip install --break-system-packages -q vllm
      command -v vllm || echo "$HOME/.local/bin/vllm"
    '
  else
    if command -v vllm >/dev/null 2>&1; then
      echo "vllm already on PATH: $(command -v vllm)"
      return
    fi
    if [ -x "$PYTHON_VENV/bin/vllm" ]; then
      echo "vllm already installed in its venv: $PYTHON_VENV/bin/vllm"
      mkdir -p "$HOME/.local/bin"
      [ -e "$HOME/.local/bin/vllm" ] || ln -s "$PYTHON_VENV/bin/vllm" "$HOME/.local/bin/vllm" 2>/dev/null || true
      return
    fi
    echo "Installing vllm into a dedicated venv at $PYTHON_VENV (best-effort:"
    echo "heavy, CUDA-hungry; on a CPU-only box it runs but slowly)..."
    if command -v python3 >/dev/null 2>&1; then
      python3 -m venv "$PYTHON_VENV" && "$PYTHON_VENV/bin/pip" install -q "vllm" \
        && mkdir -p "$HOME/.local/bin" \
        && ln -s "$PYTHON_VENV/bin/vllm" "$HOME/.local/bin/vllm"
    else
      echo "ERROR: python3 not found, can't create the vllm venv." >&2
    fi
  fi
}

# Dispatch on the active profile's runtime.
ensure_runtime() {
  case "$MODEL_RUNTIME" in
    llama.cpp) ensure_llama_server_binary ;;
    ollama)    ensure_ollama ;;
    vllm)      ensure_vllm ;;
    *) ensure_llama_server_binary ;;
  esac
}