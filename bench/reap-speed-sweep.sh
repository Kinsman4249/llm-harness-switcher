#!/usr/bin/env bash
# reap-speed-sweep.sh - speed/quality sweep driver for Qwen3-Coder-Next
# REAP-40B-A3B at its native 262144 (256K) window. Mirrors qwen-bench.sh
# structure but drives the ctx-ceiling.sh harness (fits + timing) for each
# candidate so steps bear the same build stamp and VRAM/RSS/fitted records as
# the rest of the plan's measurements - NOT ad-hoc scripts.
#
# Levers tested one at a time at fixed -c 262144 (thinking off):
#   L2 KV cache: q8_0/q8_0 (current) vs q4_0/q4_0 (symmetric pairs only; the
#      KV-combo landmine means never mix K/V types).
#   L3 Quant:   Q4_K_M (23.27GiB, confirmed) vs IQ4_XS (20.46GiB) vs Q4_K_S
#      (21.83GiB). Smaller file = larger GPU-resident expert fraction at
#      fixed VRAM under --fit.
# Final winner is re-started and run through bench/tool_gate.py (tool-call
# reliability) at 262144 before the sweep is considered green.
#
# Usage:
#   ./reap-speed-sweep.sh baseline     Q4_K_M @ q8_0/q8_0 (re-confirm on new BLD)
#   ./reap-speed-sweep.sh kv-sweep     Q4_K_M @ q8_0/q8_0 vs q4_0/q4_0
#   ./reap-speed-sweep.sh quant-sweep  Q4_K_M vs IQ4_XS vs Q4_K_S @ q4_0/q4_0
#   ./reap-speed-sweep.sh toolgate GGUF  run tool_gate.py on the given gguf (x5)
#
# Every candidate's fits + timing rows land in ctx-ceiling-results.md (the
# machine-readable record) via the ctx-ceiling harness. The narrative summary
# bench/reap-speed-sweep.md is written by hand after the runs (see the sweep
# instructions in the plan) - this driver only logs.
set -uo pipefail

BUILD_STAMP="reap-speed-sweep.sh build 2026-08-23.1"
DEBUG="${DEBUG:-1}"

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEIL="$BENCH_DIR/ctx-ceiling.sh"
LOG_DIR="$BENCH_DIR/logs"
mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/reap-sweep-$(date +%Y%m%d-%H%M%S).log"
PORT=8080
CTX=262144

PROFILE="qwen3-coder-next-reap-40b"
MODEL_DIR="/var/home/someone/models/qwen3-coder-next-reap-40b"
Q4_K_S="$MODEL_DIR/Qwen3-Coder-Next-REAP-40B-A3B.i1-Q4_K_S.gguf"
Q4_K_M="$MODEL_DIR/Qwen3-Coder-Next-REAP-40B-A3B.i1-Q4_K_M.gguf"
IQ4_XS="$MODEL_DIR/Qwen3-Coder-Next-REAP-40B-A3B.i1-IQ4_XS.gguf"
TOOL_GATE="$BENCH_DIR/tool_gate.py"

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }
debug(){ [ "$DEBUG" = "1" ] && echo "[DEBUG $(date +%H:%M:%S)] $*" >> "$RUN_LOG"; }

log "$BUILD_STAMP (run log: $RUN_LOG)"

# one candidate: ctx-ceiling fits (starts server, records VRAM/RSS) then timing
# (decode t/s against the running server). Returns 0 only if it FIT at 262144.
# extra llama args pass through (e.g. CACHE_TYPE_K/V already on env).
measure() {
  local label="$1" gguf="$2"
  log "=== measure $label $(basename "$gguf") @$CTX ==="
  if ! bash "$CEIL" fits "$PROFILE" "$gguf" "$CTX" 2>&1 | tee -a "$RUN_LOG"; then
    log "FAIL-FIT $label - skipping timing"
    return 1
  fi
  bash "$CEIL" timing "$label" "$gguf" 5 200 2>&1 | tee -a "$RUN_LOG"
}

cmd_baseline() {
  measure "REAP baseline" "$Q4_K_M"
}

cmd_kv_sweep() {
  log "=== KV cache sweep (Q4_K_M fixed) ==="
  CACHE_TYPE_K=q8_0 CACHE_TYPE_V=q8_0 measure "REAP kv=q8_0/q8_0" "$Q4_K_M"
  CACHE_TYPE_K=q4_0 CACHE_TYPE_V=q4_0 measure "REAP kv=q4_0/q4_0" "$Q4_K_M"
}

cmd_quant_sweep() {
  log "=== Quant sweep (KV q4_0/q4_0 fixed = L2 winner) ==="
  CACHE_TYPE_K=q4_0 CACHE_TYPE_V=q4_0 measure "REAP quant=Q4_K_M" "$Q4_K_M"
  CACHE_TYPE_K=q4_0 CACHE_TYPE_V=q4_0 measure "REAP quant=IQ4_XS" "$IQ4_XS"
  CACHE_TYPE_K=q4_0 CACHE_TYPE_V=q4_0 measure "REAP quant=Q4_K_S" "$Q4_K_S"
}

cmd_toolgate() {
  local gguf="${1:-$Q4_K_M}"
  log "=== tool_gate $PROFILE $(basename "$gguf") @$CTX ==="
  bash "$CEIL" fits "$PROFILE" "$gguf" "$CTX" 2>&1 | tee -a "$RUN_LOG"
  log "running tool_gate.py..."
  python3 "$TOOL_GATE" "reap-$(basename "$gguf" .gguf)" 5 "$PORT" 2>&1 | tee -a "$RUN_LOG"
}

case "${1:-}" in
  baseline)    cmd_baseline ;;
  kv-sweep)    cmd_kv_sweep ;;
  quant-sweep) cmd_quant_sweep ;;
  toolgate)    shift; cmd_toolgate "$@" ;;
  *)
    echo "Usage: $0 {baseline|kv-sweep|quant-sweep|toolgate [GGUF]}"
    exit 1
    ;;
esac