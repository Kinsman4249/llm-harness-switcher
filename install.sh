#!/usr/bin/env bash
# install.sh
# Runs every step described in README.md. Run this from the same
# directory as the other files (install.d/*.sh and the repo configs).
#
# Two install modes, chosen interactively (and via --mode):
#   classic - the Claude Code + LiteLLM switcher: on-demand LiteLLM proxy,
#             claude-local-toggle.sh, desktop icons, ~/.claude/settings.json
#             env block. The shipped .service files stay in-repo as a
#             documented manual option; nothing auto-starts.
#   kilo    - a single custom Kilo Code provider ("local-model") pointed at
#             whatever local model/runtime is running, re-synced every time
#             you change models via start-local-model.sh / the desktop icon.
# Both modes run the selected model under one of three runtimes
# (llama.cpp / ollama / vllm) chosen by the model profile, and may use either
# distrobox packaging (CUDA-in-container) or a native build.
#
# Interactive: prompts for anything that needs a decision, shows your
# previous answer as the default so re-running is just hitting Enter
# through it. Answers are saved to CONF_FILE and reloaded automatically.
# Safe to re-run. Steps that are already done are skipped or re-applied
# harmlessly. Re-running with a different mode offers to clean the other
# mode's artifacts.
#
# This file only wires the steps together. The steps themselves - one
# function each - live in install.d/*.sh, numbered in the order they run:
#   00  config defaults + log/backup_config/save_config/ask helpers
#   10  install mode / packaging / presets + general prompts
#   20  model-profile and model-sizing prompts (20-model-profile.sh,
#       20-model-sizing.sh, 20-model-download-opts.sh)
#   30  distrobox container name resolution (distrobox packaging only)
#   40  classic: litellm_config.yaml + on-demand proxy scripts
#   50  classic: claude-local-toggle.sh + its desktop icon
#   60  runtime install (llama.cpp build / ollama / vllm, distrobox or native)
#   70  model download (GGUF / drafter / mmproj / ollama pull)
#   80  launcher: start-local-llama.sh (classic) / start-local-model.sh (kilo)
#       split across 80-launcher-build.sh / -desktop.sh / -verify.sh
#   85  kilo: sync-local-model.sh generation + install-time sync
#   90  mode-aware final summary
#
# All of them run in the same shell (sourced, not executed), so plain bash
# globals are how state - config answers, resolved paths - passes between
# them, same as when this was one file.

set -uo pipefail   # not -e: a failed step should be reported, not kill
                    # the whole interactive script mid-way

CONF_FILE="$HOME/.config/claude-local-setup.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_D="$SCRIPT_DIR/install.d"

mkdir -p "$(dirname "$CONF_FILE")"
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

# Flags, parsed before install.d is sourced so they can override saved
# answers:
#   --mode classic|kilo      force the mode (otherwise the interactive prompt)
#   --presets-dir DIR        directory with extra model profiles
#   --enable-thinking        turn reasoning on (overrides REASONING_MODE)
#   --disable-thinking       turn reasoning off (overrides REASONING_MODE)
# Flags take precedence over a saved CONF_FILE answer, and are persisted by
# save_config() whichever way this run left them.
THINKING_FLAG="no"
i=0
for arg in "$@"; do
  case "$arg" in
    --enable-thinking)
      ENABLE_THINKING="yes"; THINKING_FLAG="yes"
      ;;
    --disable-thinking)
      ENABLE_THINKING="no"; THINKING_FLAG="yes"
      ;;
    --mode)
      val="${!((i+1)):-}"
      if [ "$val" = "classic" ] || [ "$val" = "kilo" ]; then
        INSTALL_MODE="$val"
      else
        echo "WARNING: --mode needs 'classic' or 'kilo'; got '$val'. Using the prompt." >&2
      fi
      ;;
    --presets-dir)
      val="${!((i+1)):-}"
      if [ -n "$val" ]; then
        PRESETS_DIR="$val"
      else
        echo "WARNING: --presets-dir needs a directory argument." >&2
      fi
      ;;
    -h|--help)
      echo "Usage: install.sh [FLAGS]"
      echo
      echo "Flags:"
      echo "  --mode classic|kilo   Force the install mode (default: interactive prompt,"
      echo "                        saved answer shown as default). classic = Claude Code +"
      echo "                        LiteLLM switcher; kilo = single custom Kilo Code provider."
      echo "  --presets-dir DIR     Directory with extra model-profiles/*.sh (a private presets"
      echo "                        repo). Never auto-cloned. Default: discovered from a fixed"
      echo "                        list (~/github/8gb-immutable-fedora-presets, etc), else the"
      echo "                        shipped example alone."
      echo "  --enable-thinking     Turn on model reasoning/\"thinking\" mode. Overrides the"
      echo "                        profile's REASONING_MODE for this run. Off by default:"
      echo "                        measured live against Nemotron 3 Nano 30B-A3B on a tool-"
      echo "                        calling prompt, thinking cost ~13x the tokens and ~11x the"
      echo "                        latency for no gain in tool-call correctness, and at a"
      echo "                        realistic 500-token budget it burned the whole budget on"
      echo "                        reasoning and never emitted the tool call at all. See"
      echo "                        README.md \"Thinking mode\"."
      echo "  --disable-thinking  Explicitly turn it back off (undoes a previous"
      echo "                        --enable-thinking saved to $CONF_FILE)."
      exit 0
      ;;
  esac
  i=$((i + 1))
done

for step_file in "$INSTALL_D"/*.sh; do
  # shellcheck source=/dev/null
  source "$step_file"
done

main() {
  echo "== Local model harness setup =="
  echo "Answers from previous runs are shown as defaults, press Enter to keep them."
  echo

  prompt_general_settings
  prompt_model_profile
  prompt_model_download_settings
  prompt_misc_settings

  # A --enable-thinking/--disable-thinking flag overrides the profile's
  # REASONING_MODE for this run (see install.d/00-config.sh).
  apply_thinking_override

  save_config
  echo
  echo "Saved your answers to $CONF_FILE for next time."
  echo

  # Distrobox container name resolution: needed whenever the model runtime
  # (or, in classic mode, the LiteLLM proxy + llama-server) runs inside a
  # container - that's every distrobox path, for llama.cpp, ollama, and vllm
  # alike. The native path never needs it.
  if [ "$PACKAGING" = "distrobox" ]; then
    resolve_container_name
  fi

  if [ "$INSTALL_MODE" = "classic" ]; then
    install_litellm_config
    install_litellm_in_container
    install_proxy_scripts
    install_optional_reminder

    ensure_runtime
    download_main_model
    download_drafter_model

    install_toggle_script
    install_desktop_shortcut

    run_launcher_step
  else
    # kilo: detect the kilo config path up front so the sync layer has it.
    detect_kilo_config
    ensure_runtime
    download_main_model   # llama.cpp GGUF / ollama pull / vllm no-op
    download_mmproj
    download_drafter_model

    generate_kilo_sync_script
    run_launcher_step     # generates start-local-model.sh and runs it --profile
  fi

  print_summary
}

main