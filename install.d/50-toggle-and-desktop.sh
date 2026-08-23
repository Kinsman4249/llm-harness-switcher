# 50-toggle-and-desktop.sh
# Sourced by install.sh. Classic mode only (the kilo mode's desktop icon is
# generated in 80-launcher.sh). Step 7/7b: installs claude-local-toggle.sh
# (the on/off switch for Claude Code local mode) and, if requested, a desktop
# icon wrapper for it.

# --- Step 7: install the toggle script, patched with port/token ---
install_toggle_script() {
  if [ "$INSTALL_MODE" != "classic" ]; then
    log "Skipping classic toggle script (mode is $INSTALL_MODE)"
    return
  fi
  mkdir -p "$BIN_DIR"
  sed -e "s|http://localhost:4000|http://localhost:$PROXY_PORT|g" \
      -e "s|http://localhost:8080|http://localhost:$LLAMA_PORT|g" \
      -e "s|BIN_DIR=\"\$HOME/.local/bin\"|BIN_DIR=\"$BIN_DIR\"|" \
      -e "s/sk-local-dev-key/$PROXY_MASTER_KEY/g" \
      "$SCRIPT_DIR/templates/bin/claude-local-toggle.sh" > "$BIN_DIR/claude-local-toggle.sh"
  chmod +x "$BIN_DIR/claude-local-toggle.sh"
  log "Installed toggle script to $BIN_DIR/claude-local-toggle.sh"

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Note: $BIN_DIR is not on your PATH. Add it to ~/.bashrc if you want to run" \
            "claude-local-toggle.sh by name instead of full path." ;;
  esac
}

# --- Step 7b: desktop shortcut, if requested ---
install_desktop_shortcut() {
  if [ "$INSTALL_MODE" != "classic" ]; then
    log "Skipping classic desktop shortcut (mode is $INSTALL_MODE)"
    return
  fi
  if [ "$INSTALL_DESKTOP_SHORTCUT" = "yes" ]; then
    # This wrapper flips whatever state you're currently in and confirms via
    # notify-send, since a desktop icon has no terminal to print to. It reads
    # TOGGLE_SCRIPT's path, patched here to match wherever BIN_DIR actually is.
    sed -e "s|\$HOME/.local/bin/claude-local-toggle.sh|$BIN_DIR/claude-local-toggle.sh|" \
        "$SCRIPT_DIR/templates/bin/claude-local-desktop-toggle.sh" > "$BIN_DIR/claude-local-desktop-toggle.sh"
    chmod +x "$BIN_DIR/claude-local-desktop-toggle.sh"

    mkdir -p "$DESKTOP_DIR"
    sed -e "s|/home/YOUR_USERNAME/.local/bin/claude-local-desktop-toggle.sh|$BIN_DIR/claude-local-desktop-toggle.sh|" \
        "$SCRIPT_DIR/templates/desktop/claude-local-toggle.desktop" > "$DESKTOP_DIR/claude-local-toggle.desktop"
    chmod +x "$DESKTOP_DIR/claude-local-toggle.desktop"

    log "Installed desktop shortcut to $DESKTOP_DIR/claude-local-toggle.desktop"
    echo "Desktop icon installed. On KDE Plasma (Bazzite default), the first"
    echo "double-click may prompt to trust/execute it, click through it once"
    echo "and it won't ask again."
  fi
}
