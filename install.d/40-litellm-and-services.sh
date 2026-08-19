# 40-litellm-and-services.sh
# Sourced by install.sh. Classic mode only - every function here belongs to
# the Claude Code + LiteLLM switcher path. Writes litellm_config.yaml, makes
# sure litellm is installed inside the container, and generates the on-demand
# start/stop proxy scripts. Nothing is auto-started: no systemd units are
# installed by default and nothing enables lingering - the proxy launches on
# demand via $BIN_DIR/start-litellm-proxy.sh (called by claude-local-toggle.sh
# and the launcher's smoke test), and claude-local-toggle.sh off stops it.
# The shipped .service files stay in-repo as a documented manual option only.

# --- Step 1: place litellm_config.yaml, with master_key and port patched in ---
install_litellm_config() {
  mkdir -p "$CONFIG_HOME"
  CONFIG_DEST="$CONFIG_HOME/litellm_config.yaml"
  backup_config "$CONFIG_DEST"
  sed -e "s/sk-local-dev-key/$PROXY_MASTER_KEY/g" \
      -e "s|http://localhost:8080|http://localhost:$LLAMA_PORT|g" \
      "$SCRIPT_DIR/litellm_config.yaml" > "$CONFIG_DEST"

  if [ "$PROXY_DEBUG_LOG" = "yes" ]; then
    sed -i \
      -e "s/^  # log_level: DEBUG/  log_level: DEBUG/" \
      "$CONFIG_DEST"
    if [ "$PROXY_LOG_DEST" = "disk" ]; then
      mkdir -p "$(dirname "$PROXY_LOG_FILE")"
      sed -i \
        -e "s|^  # log_file: ~/.local/state/litellm-proxy.log|  log_file: $PROXY_LOG_FILE|" \
        "$CONFIG_DEST"
    fi
  fi
  log "Wrote $CONFIG_DEST"
}

# --- Step 2: make sure litellm itself is installed ---
# Must happen before the on-demand start script below can ever work: on a
# fresh target, starting the proxy before litellm exists just crash-loops it.
# Branches on packaging: inside the distrobox container (classic flow) or
# directly on the host (native).
#
# Two gotchas found the hard way (2026-08-03, live debug of a container with
# both python3.12 and python3.13 installed):
#
# 1. Some containers end up with more than one Python (e.g. one pulled in by
#    an unrelated tool), each with its own site-packages. The "litellm"
#    command on PATH is a shebang script pinned to one specific interpreter,
#    but a bare "python3 -c 'import litellm'" check can silently resolve to
#    a *different* interpreter that happens to have litellm fully installed
#    (proxy extras and all). The check then reports success while the proxy
#    keeps crash-looping on startup. So: resolve the exact interpreter the
#    "litellm" binary itself runs under (its shebang line), and use that same
#    interpreter for both the check and the install, not whatever "python3"
#    happens to be first on PATH.
#
# 2. "import litellm" alone is too weak a check anyway: the base package
#    imports fine without the proxy extras (apscheduler, uvicorn, etc.), so
#    it has to import litellm.proxy.proxy_server specifically - the same
#    module "litellm --config ..." (what the start script runs) imports on
#    startup, and the thing that actually fails with a bare `pip install
#    litellm` (no [proxy] extra).
install_litellm_in_container() {
  if [ "$PACKAGING" = "distrobox" ]; then
    install_litellm_distrobox
  else
    install_litellm_native
  fi
}

# The litellm install/check logic, parameterized by how it's invoked (inside
# a distrobox container or directly on the host). The shell body is shared;
# only the privilege wrapper differs.
install_litellm_distrobox() {
  distrobox enter "$CONTAINER_NAME" -- bash -lc '
    LITELLM_BIN="$(command -v litellm || true)"
    if [ -n "$LITELLM_BIN" ]; then
      PYBIN="$(head -1 "$LITELLM_BIN" | sed "s/^#!//")"
      [ -x "$PYBIN" ] || PYBIN=python3
    else
      PYBIN=python3
    fi

    "$PYBIN" -c "import litellm.proxy.proxy_server" 2>/dev/null || {
      "$PYBIN" -m pip --version >/dev/null 2>&1 || sudo dnf install -y python3-pip
      sudo "$PYBIN" -m pip install "litellm[proxy]" "fastapi<0.140" --break-system-packages -q
    }
  '
  log "Confirmed litellm is installed inside $CONTAINER_NAME"
}

install_litellm_native() {
  if ! python3 -c "import litellm.proxy.proxy_server" 2>/dev/null; then
    if ! python3 -m pip --version >/dev/null 2>&1; then
      echo "ERROR: python3/pip not found on the host for a native litellm install." >&2
      echo "Install Python + pip for your distro, then re-run install.sh." >&2
      return
    fi
    python3 -m pip install --user "litellm[proxy]" "fastapi<0.140" -q
    log "Installed litellm under the host user (--user)."
  else
    log "Confirmed litellm is installed on the host."
  fi
}

# --- Step 3: install the on-demand proxy start/stop scripts ---
# The proxy is deliberately NOT a systemd unit anymore (no auto-start, see
# README "No auto-start"): claude-local-toggle.sh on calls start-litellm-proxy.sh
# (nohup, log to ~/.local/state/litellm-proxy.log), off calls
# stop-litellm-proxy.sh (pkill litellm only - never the container, so a
# running llama-server survives a proxy stop). Both are checked-in templates
# that read their settings from CONF_FILE at runtime - nothing to bake here,
# so there's no heredoc to generate or escape.
install_proxy_scripts() {
  if [ "$INSTALL_MODE" != "classic" ]; then
    log "Skipping classic proxy scripts (mode is $INSTALL_MODE)"
    return
  fi
  mkdir -p "$BIN_DIR"
  cp "$SCRIPT_DIR/start-litellm-proxy.sh" "$BIN_DIR/start-litellm-proxy.sh"
  cp "$SCRIPT_DIR/stop-litellm-proxy.sh" "$BIN_DIR/stop-litellm-proxy.sh"
  chmod +x "$BIN_DIR/start-litellm-proxy.sh" "$BIN_DIR/stop-litellm-proxy.sh"
  log "Installed $BIN_DIR/start-litellm-proxy.sh and $BIN_DIR/stop-litellm-proxy.sh"
}

# --- Step 4 (optional): the "stop the container before gaming" reminder ---
# Offered as an explicit yes/no (default no), classic mode only. When yes,
# installs the shipped distrobox-reminder.service with YOUR container name
# baked in, enabled for the graphical session. It only notifies - it never
# starts or stops anything (this project still auto-starts nothing).
install_optional_reminder() {
  if [ "$INSTALL_GAME_REMINDER" = "yes" ]; then
    mkdir -p "$HOME/.config/systemd/user"
    backup_config "$HOME/.config/systemd/user/distrobox-reminder.service"
    sed "s/distrobox stop ollama-box/distrobox stop $CONTAINER_NAME/g" \
        "$SCRIPT_DIR/distrobox-reminder.service" > "$HOME/.config/systemd/user/distrobox-reminder.service"
    systemctl --user daemon-reload
    systemctl --user enable --now distrobox-reminder.service
    echo "Installed and enabled the 'stop the container before gaming' reminder."
    echo "Disable anytime: systemctl --user disable --now distrobox-reminder.service"
  else
    echo "Skipping the optional gaming reminder (default). The shipped"
    echo "distrobox-reminder.service stays in-repo as a documented manual option."
  fi
}