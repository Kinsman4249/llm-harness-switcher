#!/usr/bin/env bash
# coding-challenge.sh - one-command nemotron coding-challenge runner.
#
# Poses the "effort:<N>" reasoning-mode cross-file coding task to a live local
# model through its Claude-Code-style tool path (grep/read_file), then objectively
# grades the model's proposed solution. The harness is hermetic: it only reads a
# gitignored snapshot of the repo, never mutates the working tree, and never runs
# the model's output (grading is text/diff-level).
#
# Steps:
#   1. Prepare a hermetic snapshot under bench/_challenge_repo/ (gitignored),
#      excluding .git and the snapshot dir itself, and record git HEAD.
#   2. Require a live llama-server on the resolved port; else print how to start
#      one and exit 2.
#   3. Run the driver (coding_challenge_gate.py), which talks to the server and
#      saves bench/coding_challenge_<label>.run.json.
#   4. Run the grader (coding_challenge_grade.py), which writes the
#      bench/coding_challenge_<label>.result.json and prints PASS or FAIL-Q.
#
# Usage:
#   ./coding-challenge.sh [--profile nemotron3-nano-30b] [--mode off]
#                         [--snapshot DIR] [--label NAME]
# BUILD_STAMP: which build of the harness produced results.
set -uo pipefail

BUILD_STAMP="coding-challenge.sh build 2026-08-20.1"
DEBUG="${DEBUG:-1}"

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$BENCH_DIR/coding_challenge_gate.py"
GRADER="$BENCH_DIR/coding_challenge_grade.py"

# --- defaults from the same config keys the other templates use ---
MODEL_ROOT="${MODEL_ROOT:-$HOME/models}"
RUNTIME_PORT="${RUNTIME_PORT:-8080}"
STATE_DIR="${KILO_STATE_DIR:-$HOME/.local/state/llm-harness-switcher}"
ACTIVE_STATE="$STATE_DIR/active.conf"
CONF_FILE="$HOME/.config/claude-local-setup.conf"
PROFILE_DIRS=""
if [ -f "$CONF_FILE" ]; then
  PROFILE_DIRS="$(sed -n 's/^PROFILE_DIRS_CONF="\(.*\)"$/\1/p' "$CONF_FILE")"
fi
[ -z "$PROFILE_DIRS" ] && PROFILE_DIRS="$BENCH_DIR/../model-profiles"

SNAPSHOT_ROOT="$BENCH_DIR/_challenge_repo"
CHALLENGE_PROFILE="nemotron3-nano-30b"
CHALLENGE_MODE="off"
LABEL="nemotron-30b-effort-challenge"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)   shift; CHALLENGE_PROFILE="${1:-}"; shift || true ;;
    --mode)      shift; CHALLENGE_MODE="${1:-}"; shift || true ;;
    --snapshot)  shift; SNAPSHOT_ROOT="${1:-}"; shift || true ;;
    --label)     shift; LABEL="${1:-}"; shift || true ;;
    --help|-h)
      echo "Usage: $0 [--profile <stem>] [--mode <name>] [--snapshot DIR] [--label NAME]"
      exit 0 ;;
    *) shift ;;
  esac
done

log()  { echo "[$(date +%H:%M:%S)] $*"; }
debug(){ [ "$DEBUG" = "1" ] && echo "[DEBUG $(date +%H:%M:%S)] $*"; }

log "$BUILD_STAMP (profile=$CHALLENGE_PROFILE mode=$CHALLENGE_MODE label=$LABEL)"

# --- resolve the port from the active state record written by start-local-model.sh
# (its ACTIVE_PORT), falling back to RUNTIME_PORT, and the active profile stem. ---
PORT="$RUNTIME_PORT"
ACTIVE_PROFILE_STEM=""
if [ -f "$ACTIVE_STATE" ]; then
  PORTFILE="$(sed -n 's/^ACTIVE_PORT="\(.*\)"$/\1/p' "$ACTIVE_STATE")"
  [ -n "$PORTFILE" ] && PORT="$PORTFILE"
  ACTIVE_PROFILE_STEM="$(sed -n 's/^ACTIVE_PROFILE="\(.*\)"$/\1/p' "$ACTIVE_STATE")"
fi
if [ -z "$ACTIVE_PROFILE_STEM" ]; then
  ACTIVE_PROFILE_STEM="$CHALLENGE_PROFILE"
fi
debug "resolved port=$PORT active profile=$ACTIVE_PROFILE_STEM"

# --- 1. hermetic snapshot (stdlib Python copy - no external deps) ---
REPO_ROOT="$(cd "$BENCH_DIR/../" && pwd)"
python3 "$BENCH_DIR/build_challenge_snapshot.py" "$REPO_ROOT" "$SNAPSHOT_ROOT"
log "snapshot: $SNAPSHOT_ROOT (HEAD $(<"$SNAPSHOT_ROOT/_snapshot_head"))"

# --- 2. live server required ---
if ! curl -s -o /dev/null -m 3 "http://127.0.0.1:$PORT/health"; then
  cat >&2 <<EOF
ERROR: no llama-server healthy on port $PORT.
Start it first, e.g.:
  bash start-local-model.sh --profile $CHALLENGE_PROFILE --mode $CHALLENGE_MODE
(which restarts on the same port if a server is already up), then re-run this.
EOF
  exit 2
fi
log "server healthy on port $PORT"

# --- 3. driver: agentic loop against the live server ---
log "running driver..."
python3 "$DRIVER" "$LABEL" "$SNAPSHOT_ROOT" "$PORT" || {
  log "driver returned non-zero (NO-SOLUTION is expected for a stump); grading what we have"
}

RUN_FILE="$BENCH_DIR/coding_challenge_${LABEL}.run.json"

# --- 4. grader: objective rubric on the saved transcript ---
log "running grader..."
if [ ! -f "$RUN_FILE" ]; then
  log "no run transcript produced - recording an empty no_solution run for the grader"
  python3 - "$RUN_FILE" "$SNAPSHOT_ROOT/_snapshot_head" "$LABEL" <<'PY'
import json, os, sys
run_file, head_file, label = sys.argv[1], sys.argv[2], sys.argv[3]
head = ""
if os.path.isfile(head_file):
    with open(head_file) as fh:
        head = fh.read().strip()
json.dump({
    "label": label,
    "repo_head": head,
    "has_solution": False,
    "solution": None,
    "transcript": [{"role": "error", "content": "driver produced no run file"}],
}, open(run_file, "w"), indent=2)
PY
fi
if ! python3 "$GRADER" "$RUN_FILE"; then
  VERDICT="FAIL-Q"
else
  VERDICT="PASS"
fi
RESULT_FILE="$BENCH_DIR/coding_challenge_${LABEL}.result.json"
log "verdict: $VERDICT   result file: $RESULT_FILE"
echo "$VERDICT"
exit 0