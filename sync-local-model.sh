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
    --image-only) IMAGE_ONLY="yes" ;;
    --debug)     DEBUG="yes" ;;
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

TMP_FILE="$(mktemp "${KILO_CONFIG}.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT

# Reference mode/permissions from the existing file if possible; fall back to
# 0600 (this may hold a local API key). chmod --reference is GNU-coreutils.
if chmod --reference="$KILO_CONFIG" "$TMP_FILE" 2>/dev/null; then
  :
else
  chmod 0600 "$TMP_FILE"
fi

dbg() { [ "$DEBUG" = "yes" ] && printf '[sync] %s\n' "$*"; }

# jq filter: single model entry, whole model map replaced so the provider
# always has exactly the current model as the only option. `//=` fills a
# missing provider name/npm without clobbering a hand-edited value; `=`
# always refreshes baseURL/apiKey/models (those must reflect reality).
# $provider etc. are passed via --arg (no string interpolation into jq).
dbg "Writing $KILO_CONFIG: provider=$PROVIDER model=$MODEL_ID url=$BASE_URL"
jq --arg provider "$PROVIDER" \
  --arg url "$BASE_URL" \
  --arg key "$API_KEY" \
  --arg model_id "$MODEL_ID" \
  --arg model_name "$MODEL_NAME" \
  --arg context "$CONTEXT" \
  --arg output "$OUTPUT" \
  --arg reasoning "$REASONING" \
  --arg effort "$EFFORT" \
  --arg attachment "$ATTACHMENT" \
  --arg image_only "$IMAGE_ONLY" '
  .provider[$provider].name //= "Local Model" |
  .provider[$provider].npm //= "@ai-sdk/openai-compatible" |
  .provider[$provider].options.baseURL = $url |
  .provider[$provider].options.apiKey = $key |
  .provider[$provider].models = (
    {($model_id): (
        {name: $model_name,
         tool_call: true,
         temperature: true,
         reasoning: ($reasoning != "off"),
         limit: {context: ($context|tonumber), output: ($output|tonumber)}}
        + (if $reasoning == "effort" then {options: {reasoningEffort: $effort}} else {} end)
        + (if $attachment == "yes" then
             (if $image_only == "yes"
              then {attachment: true, modalities: {input: ["image"], output: ["text"]}}
              else {attachment: true, modalities: {input: ["text","image"], output: ["text"]}}
              end)
           else {} end)
    )}
  ) |
  .model = ($provider + "/" + $model_id)
' "$KILO_CONFIG" > "$TMP_FILE" || {
  echo "ERROR: jq failed to build the new config." >&2
  exit 1
}

mv "$TMP_FILE" "$KILO_CONFIG"
trap - EXIT

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