#!/usr/bin/env bash
# sync-local-model.sh
# Kilo-mode template, copied into $BIN_DIR by install.sh (install.d/85-kilo-
# sync.sh). Reads install-time defaults from ~/.config/claude-local-setup.conf
# at runtime, so re-running install.sh is all that's needed to change them -
# there is no baked config to drift. Don't hand-edit the copy in $BIN_DIR.
#
# Rewrites the single Kilo Code provider (default "local-model") to point at
# a local OpenAI-compatible model server. The provider's model map is replaced
# entirely, so Kilo Code always sees exactly the current model as the only
# option for this provider, with its reasoning/multimodal/context capabilities
# baked in. Writes the detected kilo config atomically (temp file + mv), the
# same pattern runpod-helper's sync-runpod-endpoint.sh uses.
#
# Usage:
#   sync-local-model.sh [--base-url URL] [--api-key KEY]
#     [--model-id ID] [--model-name NAME]
#     [--context N] [--output N]
#     [--reasoning off|on|effort] [--effort low|medium|high]
#     [--attachment yes|no] [--image-only]
#     [--debug] [--help]
# With no args, uses the saved install-time defaults from the config file.

set -uo pipefail

CONF_FILE="$HOME/.config/claude-local-setup.conf"

DEFAULT_API_KEY="sk-local-dev-key"
DEFAULT_PROVIDER="local-model"
DEFAULT_RUNTIME_PORT="8080"
DEFAULT_CONTEXT="16384"
DEFAULT_OUTPUT="4096"
DEFAULT_REASONING="off"
DEFAULT_EFFORT="low"
DEFAULT_MODEL_ID="local-model"
DEFAULT_MODEL_NAME="Local Model"

if [ -f "$CONF_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  DEFAULT_KILO_PROVIDER="${KILO_PROVIDER:-$DEFAULT_PROVIDER}"
  DEFAULT_API_KEY="${KILO_API_KEY:-$DEFAULT_API_KEY}"
  DEFAULT_RUNTIME_PORT="${RUNTIME_PORT:-$DEFAULT_RUNTIME_PORT}"
  DEFAULT_CONTEXT="${LLAMA_CTX_SIZE:-$DEFAULT_CONTEXT}"
  DEFAULT_OUTPUT="${LLAMA_N_PREDICT:-$DEFAULT_OUTPUT}"
  DEFAULT_REASONING="${REASONING_MODE:-$DEFAULT_REASONING}"
  DEFAULT_EFFORT="${REASONING_EFFORT:-$DEFAULT_EFFORT}"
  DEFAULT_MODEL_ID="${KILO_MODEL_ID:-${MODEL_PROFILE:-$DEFAULT_MODEL_ID}}"
  DEFAULT_MODEL_NAME="${KILO_MODEL_NAME:-$DEFAULT_MODEL_NAME}"
else
  DEFAULT_KILO_PROVIDER="$DEFAULT_PROVIDER"
fi

DEBUG="no"

usage() {
  sed -n '2,8p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url)  shift; BASE_URL="${1:-}"; shift || true ;;
    --api-key)   shift; API_KEY="${1:-}"; shift || true ;;
    --model-id)  shift; MODEL_ID="${1:-}"; shift || true ;;
    --model-name) shift; MODEL_NAME="${1:-}"; shift || true ;;
    --context)   shift; CONTEXT="${1:-}"; shift || true ;;
    --output)    shift; OUTPUT="${1:-}"; shift || true ;;
    --reasoning) shift; REASONING="${1:-}"; shift || true ;;
    --effort)    shift; EFFORT="${1:-}"; shift || true ;;
    --attachment) shift; ATTACHMENT="${1:-}"; shift || true ;;
    --image-only) IMAGE_ONLY="yes"; shift ;;
    --debug)     DEBUG="yes"; shift ;;
    --help|-h)   usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

BASE_URL="${BASE_URL:-http://127.0.0.1:${DEFAULT_RUNTIME_PORT}/v1}"
API_KEY="${API_KEY:-$DEFAULT_API_KEY}"
MODEL_ID="${MODEL_ID:-$DEFAULT_MODEL_ID}"
MODEL_NAME="${MODEL_NAME:-$MODEL_ID}"
CONTEXT="${CONTEXT:-$DEFAULT_CONTEXT}"
OUTPUT="${OUTPUT:-$DEFAULT_OUTPUT}"
REASONING="${REASONING:-$DEFAULT_REASONING}"
EFFORT="${EFFORT:-$DEFAULT_EFFORT}"
ATTACHMENT="${ATTACHMENT:-no}"
IMAGE_ONLY="${IMAGE_ONLY:-no}"
PROVIDER="${PROVIDER:-$DEFAULT_KILO_PROVIDER}"

case "$REASONING" in
  off|on|effort) ;;
  *) echo "WARNING: --reasoning must be off|on|effort, got '$REASONING' - forcing off." >&2; REASONING="off" ;;
esac
case "$ATTACHMENT" in
  yes|no) ;;
  *) echo "WARNING: --attachment must be yes|no, got '$ATTACHMENT' - forcing no." >&2; ATTACHMENT="no" ;;
esac

# --- Determine the kilo config file (re-detect from $HOME every run) ---
KILO_CONFIG="$HOME/.config/kilo/kilo.json"
if [ ! -f "$KILO_CONFIG" ]; then
  KILO_CONFIG="$HOME/.config/kilo/kilo.jsonc"
fi
mkdir -p "$(dirname "$KILO_CONFIG")"
if [ ! -f "$KILO_CONFIG" ]; then
  printf '{\n  "$schema": "https://app.kilo.ai/config.json",\n  "provider": {}\n}\n' > "$KILO_CONFIG"
  echo "Created $KILO_CONFIG (didn't exist)."
fi

# Resolve a symlinked config to its real file so the atomic mv below updates
# the tracked target (e.g. ~/.config/kilo/kilo.jsonc can be a symlink to a
# git-tracked kilo.jsonc) instead of unlinking the symlink and replacing it
# with a plain file. Creating the temp file next to the real target also
# keeps the rename atomic on the target's filesystem.
if [ -L "$KILO_CONFIG" ]; then
  _real="$(readlink -f "$KILO_CONFIG")"
  if [ -n "$_real" ]; then
    [ "$DEBUG" = "yes" ] && printf '[sync] Resolved %s symlink -> %s\n' "$KILO_CONFIG" "$_real"
    KILO_CONFIG="$_real"
  fi
  unset _real
fi

# Comment-preserving JSONC edit: the helper replaces the single local-model
# provider value (and the top-level .model), so re-syncs never grow the file.
# It resolves the config symlink to its tracked target, so the write lands in
# the git-tracked kilo.jsonc and the ~/.config/kilo link stays intact.
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HELPER_DIR/kilo-jsonc-edit.py"
if [ ! -f "$HELPER" ]; then
  echo "ERROR: $HELPER not found - re-run install.sh to ship it." >&2
  exit 1
fi
[ "$DEBUG" = "yes" ] && printf '[sync] Writing %s: provider=%s model=%s url=%s\n' "$KILO_CONFIG" "$PROVIDER" "$MODEL_ID" "$BASE_URL"
python3 "$HELPER" "$KILO_CONFIG" \
  --provider "$PROVIDER" \
  --api-key "$API_KEY" \
  --base-url "$BASE_URL" \
  --model-id "$MODEL_ID" \
  --model-name "$MODEL_NAME" \
  --context "$CONTEXT" \
  --output "$OUTPUT" \
  --reasoning "$REASONING" \
  --effort "$EFFORT" \
  --attachment "$ATTACHMENT" \
  --image-only "$IMAGE_ONLY" || {
  echo "ERROR: failed to edit $KILO_CONFIG." >&2
  exit 1
}

echo
echo "Synced Kilo provider '$PROVIDER' to: $MODEL_NAME ($MODEL_ID)"
echo "  base URL: $BASE_URL"
echo "  context:  $CONTEXT   output: $OUTPUT"
echo "  reasoning: $REASONING   effort: $EFFORT   attachment: $ATTACHMENT"
echo "  config written to: $KILO_CONFIG"
echo
echo ">>> IMPORTANT: Kilo Code caches provider config in its sqlite store and"
echo ">>> only re-reads this file on session start. Reload the VSCodium/Kilo"
echo ">>> Code window, or fully restart Kilo, for this provider change to take"
echo ">>> effect. <<<"