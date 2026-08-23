#!/usr/bin/env bash
# ctx-ceiling.sh - all-preset maximum-KV-context ceiling sweep (past 256K hypothesis).
#
# Measures, per model profile/quant, the largest real KV context window that
# fits an RTX 3080 8GB card and serves valid completions, mirroring the arg
# recipe start_llama_server() in start-local-model.sh builds for the profil
# (flags stay profile-driven; -c and reasoning are controlled by the harness).
#
# Per profile/quant the harness:
#   1. stops any server, starts the profile's exact flag recipe at candidate -c
#      with thinking forced off (reasoning tokens would otherwise eat the window
#      under test) and the plan's temp 0 on the grading request.
#   2. reads the fitted n_ctx from the startup log (confirms == requested -c,
#      i.e. NOT capped / not an OOM).
#   3. smoke-tests one real completion.
#   4. records loaded VRAM (nvidia-smi), RSS (ps -o rss=), fitted n_ctx, PASS/FAIL.
#   5. binary-searches the first failed context to +/-512 (geometric ladder first).
# The deep quality gate (-c*0.95 haystack) is run ONCE at the adopted ceiling,
# not per ladder step (deep prefill at 300-500K is slow on an 8GB card).
#
# Usage:
#   ./ctx-ceiling.sh fits  <profile> <gguf-path> <ctx> [extra_llama_args...]
#       One candidate: start at ctx, record fitted/VRAM/RSS, PASS/FAIL. Returns 0 on fit.
#   ./ctx-ceiling.sh ramp  <profile> <gguf-path> [start_ctx]
#       Geometric ladder up from start_ctx (or 32768), bisect the first FAIL; logs each.
#   ./ctx-ceiling.sh gate  <profile> <gguf-path> <ctx> <label>
#       Deep haystack quality gate at ~0.95*ctx (build_haystack_nemo.py for Nemotron,
#       build_haystack.py otherwise), then query_and_grade*.py. PASS = 3/3 sentinels + def.
#
# BUILD_STAMP: which build of the harness + the llama.cpp binary produced results.
set -uo pipefail

BUILD_STAMP="ctx-ceiling.sh build 2026-08-23.2"
DEBUG="${DEBUG:-1}"

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$BENCH_DIR/logs"
RESULTS_MD="$BENCH_DIR/ctx-ceiling-results.md"
mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"
SERVER_LOG="$LOG_DIR/server-current.log"

# --- machine/model facts (this reference box: RTX 3080 8GB, native build) ---
GPU_TOTAL_MIB=8192
VRAM_FLOOR_MIB=1500
PORT=8080
DEFAULT_BATCH=512
DEFAULT_OUTPUT=4096
LLAMA_BIN="${LLAMA_SERVER_BIN:-$HOME/llama.cpp/build/bin/llama-server}"
MODEL_ROOT="${MODEL_ROOT:-$HOME/models}"
CONF_FILE="$HOME/.config/claude-local-setup.conf"
PROFILE_DIRS=""
[ -f "$CONF_FILE" ] && PROFILE_DIRS="$(sed -n 's/^PROFILE_DIRS_CONF="\(.*\)"$/\1/p' "$CONF_FILE")"
[ -z "$PROFILE_DIRS" ] && PROFILE_DIRS="$BENCH_DIR/../model-profiles /var/home/someone/github/8gb-immutable-fedora-presets/model-profiles"

LLAMA_BUILD="$("$LLAMA_BIN" --version 2>&1 | head -1)"
# short build token recorded in every result row (e.g. "d59d455fd")
BLD="$(echo "$LLAMA_BUILD" | grep -oE 'commit [0-9a-f]+' | awk '{print $2}')"
[ -z "$BLD" ] && BLD="unknown"

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }
debug(){ [ "$DEBUG" = "1" ] && echo "[DEBUG $(date +%H:%M:%S)] $*" >> "$RUN_LOG"; }

log "$BUILD_STAMP (DEBUG=$DEBUG, run log: $RUN_LOG)"
log "llama-server: $LLAMA_BUILD"

find_profile_file() {
  local want="$1" dir f base
  for dir in $PROFILE_DIRS; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.sh; do
      [ -f "$f" ] || continue
      base="$(basename "$f" .sh)"
      if [ "$base" = "$want" ]; then echo "$f"; return; fi
    done
  done
}

stop_server() {
  if pgrep -f "bin/llama-server" > /dev/null 2>&1; then
    log "stopping running llama-server..."
    pkill -f "bin/llama-server" 2>/dev/null
    for _ in $(seq 1 15); do
      pgrep -f "bin/llama-server" > /dev/null 2>&1 || break
      sleep 1
    done
    if pgrep -f "bin/llama-server" > /dev/null 2>&1; then
      log "server did not stop gracefully, sending SIGKILL"
      pkill -9 -f "bin/llama-server" 2>/dev/null
      sleep 2
    fi
  fi
}

wait_for_health() {
  local timeout_s="${1:-300}" waited=0 healthy=0
  while [ "$waited" -lt "$timeout_s" ]; do
    if curl -s -o /dev/null -m 3 "http://127.0.0.1:$PORT/health"; then
      healthy=$((healthy + 1))
      [ "$healthy" -ge 2 ] && break
    else
      healthy=0
      if [ "$waited" -ge 10 ] && ! pgrep -f "bin/llama-server" > /dev/null 2>&1; then
        log "llama-server process exited early (crash/OOM) - see $SERVER_LOG"
        return 1
      fi
    fi
    sleep 2
    waited=$((waited + 2))
  done
  [ "$healthy" -ge 2 ] || return 1
  # /health returns 200 as soon as the server binds, BEFORE the model finishes
  # loading, so health alone is not proof of a working model (a /completion
  # smoke 503s during model load - this exact race invalidated an earlier
  # Nemotron sweep). Retry the smoke until it returns real content, a generous
  # model-load window elapses, or the process dies.
  local resp
  while [ "$waited" -lt "$(( timeout_s + 240 ))" ]; do
    if ! pgrep -f "bin/llama-server" > /dev/null 2>&1; then
      log "llama-server died during model load"
      return 1
    fi
    resp=$(curl -s -m 60 "http://127.0.0.1:$PORT/completion" \
      -H "Content-Type: application/json" \
      -d '{"prompt":"The capital of France is","n_predict":8}')
    if echo "$resp" | grep -q '"content"' && ! echo "$resp" | grep -q '"error"'; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  debug "model never became loadable for smoke: test timed out"
  return 1
}

read_vram_mib() {
  local v=0
  for _ in 1 2 3; do
    v=$(nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits 2>/dev/null | paste -sd+ - | bc 2>/dev/null)
    [ -z "$v" ] && v=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')
    [ "${v:-0}" -ge "$VRAM_FLOOR_MIB" ] 2>/dev/null && { echo "$v"; return 0; }
    sleep 2
  done
  echo "$v"
  return 1
}

read_rss_gib() {
  local pid
  pid=$(pgrep -f "bin/llama-server" | head -1)
  [ -n "$pid" ] || { echo "n/a"; return; }
  python3 -c "import sys; print(round(int(open('/proc/$pid/statm').read().split()[1])*4096/1024**3,1))" 2>/dev/null || echo "n/a"
}

fitted_ctx() {
  # Authoritative effective context: llama-server reports what it ACTUALLY
  # allocated. When a requested -c exceeds n_ctx_train, llama-server caps the
  # slot context and /props reflects the cap (fitted < requested = the capping
  # evidence, llama.cpp issue #17459). The startup log would show the literal
  # "capping" line, but llama-server buffers that log internally (fd stays at
  # pos 0 on a redirected file) so /props is the reliable source.
  curl -s -m 5 "http://127.0.0.1:$PORT/props" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['default_generation_settings']['n_ctx'])" 2>/dev/null \
    || echo ""
}

# Build the llama-server arg list for a profile exactly as start_llama_server()
# does in start-local-model.sh, but with the harness's $CTX and thinking off.
# Extra profile-independent args can pass via $@ (this function's trailing args).
build_llama_args() {
  local profile_file="$1" gguf="$2" ctx="$3"; shift 3
  # shellcheck source=/dev/null
  source "$profile_file"
  LLAMA_CPU_FFN_LAYERS="${LLAMA_CPU_FFN_LAYERS:-${LLAMA_CPU_FFN_LAYERS_RECOMMENDED:-0}}"
  # Context extension mode selection: when the profile declares CTX_MODES
  # (`name|ctx|yarn_factor|arch_key` rows), honor the harness's optional
  # CTX_MODE env (default 'native' = no rope). This lets the harness exercise
  # a YaRN rung for the profiles that moved their YaRN recipe into CTX_MODES
  # (ornith, qwen3-coder-next, reap) while keeping the native window default.
  local _extmode="" _extmyarn="" _extmkey=""
  if [ "${CTX_MODES+x}" = "x" ] && [ "${#CTX_MODES[@]}" -gt 0 ]; then
    local _wanted="${CTX_MODE:-native}" _cm
    for _cm in "${CTX_MODES[@]}"; do
      if [ "${_cm%%|*}" = "$_wanted" ]; then
        ctx="$(echo "$_cm" | cut -d'|' -f2)"
        _extmyarn="$(echo "$_cm" | cut -d'|' -f3)"
        _extmkey="$(echo "$_cm" | cut -d'|' -f4)"
        break
      fi
    done
  fi
  local -a args=()
  args+=( "$LLAMA_BIN" -m "$gguf" -c "$ctx" -b "$DEFAULT_BATCH" -n "$DEFAULT_OUTPUT" )
  args+=( -fa on --cache-type-k "${CACHE_TYPE_K:-q8_0}" --cache-type-v "${CACHE_TYPE_V:-q8_0}" )
  if [ "${KV_MODEL:-manual}" = "manual" ]; then
    args+=( --fit off )
  else
    args+=( --fit on )
  fi
  if [ "${NGL_MODE:-fixed}" != "fit" ]; then
    args+=( -ngl 99 )
  fi
  if [ "${LLAMA_CPU_FFN_LAYERS:-0}" -gt 0 ] 2>/dev/null && [ -n "${N_LAYERS:-}" ]; then
    local first=$(( N_LAYERS - LLAMA_CPU_FFN_LAYERS ))
    [ "$first" -lt 0 ] && first=0
    local range
    range="$(seq -s'|' "$first" "$((N_LAYERS - 1))")"
    args+=( --override-tensor "blk\\.($range)\\.ffn_(gate|up|down)\\.weight=CPU" )
  fi
  if [ "${LLAMA_NO_KV_OFFLOAD:-no}" = "yes" ]; then
    args+=( --no-kv-offload )
  fi
  if [ -n "${PLE_TENSOR_REGEX:-}" ] && [ "${KEEP_PLE_ON_CPU:-no}" = "yes" ]; then
    args+=( --override-tensor "${PLE_TENSOR_REGEX}=CPU" )
  fi
  case "${SPEC_MODE:-none}" in
    self-mtp)
      args+=( --spec-type draft-mtp --spec-draft-n-max "${LLAMA_SPEC_DRAFT_N:-2}" ) ;;
    draft-model)
      local draft
      draft="$(find "$MODEL_ROOT/$(basename "$(dirname "$gguf")")" \
        -maxdepth 1 -iname "*${DRAFT_PATTERN:-}*.gguf" 2>/dev/null | head -n1)"
      if [ -n "$draft" ]; then
        args+=( -md "$draft" --spec-type draft-mtp --spec-draft-n-max "${LLAMA_SPEC_DRAFT_N:-2}" -ngld "${LLAMA_SPEC_DRAFT_NGLD:-0}" )
        [ -n "${LLAMA_SPEC_DRAFT_N_MIN:-}" ] && args+=( --spec-draft-n-min "$LLAMA_SPEC_DRAFT_N_MIN" )
      fi ;;
  esac
  [ -n "${DEFAULT_TEMP:-}" ]  && args+=( --temp "$DEFAULT_TEMP" )
  [ -n "${DEFAULT_TOP_P:-}" ] && args+=( --top-p "$DEFAULT_TOP_P" )
  [ -n "${DEFAULT_TOP_K:-}" ] && args+=( --top-k "$DEFAULT_TOP_K" )
  # Context extension (rope/YaRN): CTX_MODE-selected row (from CTX_MODES) or
  # legacy static ROPE_YARN_* fields. The CTX_MODE path already set $ctx to the
  # mode's targeted window and recorded _extmyarn/_extmkey at the top; native
  # mode emits no rope. Legacy fields still win for profiles that set them.
  if [ -n "$_extmyarn" ] && [ -n "$_extmkey" ]; then
    # yarn-orig-ctx = native window = targeted ctx / factor (e.g. 524288/2).
    local _orig=$(( ctx / _extmyarn ))
    args+=( --rope-scaling yarn --rope-scale "$_extmyarn" --yarn-orig-ctx "$_orig" )
    args+=( --override-kv "$_extmkey=int:$ctx" )
  elif [ -n "${ROPE_YARN_FACTOR:-}" ] && [ -n "${ROPE_YARN_ORIG_CTX:-}" ]; then
    args+=( --rope-scaling yarn --rope-scale "$ROPE_YARN_FACTOR" --yarn-orig-ctx "$ROPE_YARN_ORIG_CTX" )
  fi
  [ -n "${ROPE_YARN_OVERRIDE_KV:-}" ] && args+=( --override-kv "$ROPE_YARN_OVERRIDE_KV" )
  args+=( --reasoning off )
  # extra harness args (beyond-256K experiments) go last, after --port is set
  # so they can't collide with the recipe.
  args+=( --no-webui --port "$PORT" --host 127.0.0.1 )
  args+=( "$@" )
  printf '%q ' "${args[@]}"
}

# start_server: stop any server then launch the profile recipe at $CTX with
# optional extra args. Returns 0 only after health + real-completion smoke.
start_server() {
  local profile="$1" gguf="$2" ctx="$3"; shift 3
  stop_server
  local cmd args
  local ok=0
  for attempt in 1 2 3 4; do
    log "launch attempt $attempt/4: $profile ctx=$ctx $*"
    cmd="$(build_llama_args "$(find_profile_file "$profile")" "$gguf" "$ctx" "$@")"
    debug "cmd: $cmd"
    # stdbuf: stdout to a file is block-buffered, so llama.cpp's periodic log
    # lines (incl. the n_ctx_slot / capping evidence we read for a ceiling) sit
    # in the buffer instead of hitting $SERVER_LOG. Force line buffering.
    nohup stdbuf -oL -eL bash -lc "$cmd" > "$SERVER_LOG" 2>&1 &
    disown
    if wait_for_health 300; then
      ok=1
      break
    fi
    log "attempt $attempt did not come up healthy, retrying..."
    stop_server
  done
  [ "$ok" = "1" ]
}

# One candidate at a given ctx: record fitted/VRAM/RSS and PASS/FAIL-FIT.
# PASS means: fitted n_ctx == requested ctx (no cap) AND a real completion.
fits() {
  local profile="$1" gguf="$2" ctx="$3"; shift 3
  local vram rss fitted
  if ! start_server "$profile" "$gguf" "$ctx" "$@"; then
    log "[$profile $gguf ctx=$ctx] FAIL-FIT (load/smoke failed - OOM or crash)"
    echo "| $profile | $(basename "$gguf") | $BLD | $ctx | FAIL | n/a | n/a | n/a | n/a |" >> "$RESULTS_MD"
    return 1
  fi
  fitted="$(fitted_ctx)"
  vram="$(read_vram_mib)"; [ -z "$vram" ] || vram="${vram}MiB"
  rss="$(read_rss_gib)"
  if [ "$fitted" != "$ctx" ]; then
    log "[$profile ctx=$ctx] FAIL-FIT: fitted n_ctx_slot=$fitted != requested $ctx (capped)"
    echo "| $profile | $(basename "$gguf") | $BLD | $ctx | FAIL(cap:$fitted) | $vram | $rss | n/a | n/a |" >> "$RESULTS_MD"
    return 1
  fi
  log "[$profile ctx=$ctx] PASS-FIT fitted=$fitted vram=$vram rss=$rss"
  echo "| $profile | $(basename "$gguf") | $BLD | $ctx | PASS | $fitted | $vram | $rss | n/a | n/a |" >> "$RESULTS_MD"
  return 0
}

# Geometric ladder then bisect the first FAIL. start at 32768 (or arg).
LADDER=(32768 65536 98304 131072 196608 262144 294912 327680 393216 524288 786432 1048576)
ramp() {
  local profile="$1" gguf="$2" start="${3:-32768}"; shift 3
  ensure_header
  log "=== ramp $profile $(basename "$gguf") start=$start ${*:-(no extra)} ==="
  local best=""
  for c in "${LADDER[@]}"; do
    [ "$c" -lt "$start" ] && continue
    if fits "$profile" "$gguf" "$c" "$@"; then
      best="$c"
    else
      log "ctx=$c FAIL - bisecting between ${best:-0} and $c"
      local lo="${best:-0}" hi="$c"
      while [ $(( lo + 512 )) -lt "$hi" ]; do
        local mid=$(( (lo + hi) / 2 / 512 * 512 ))
        if fits "$profile" "$gguf" "$mid" "$@"; then lo="$mid"; else hi="$mid"; fi
      done
      best="$lo"
      break
    fi
  done
  log "=== ramp done: $profile $(basename "$gguf") ceiling (fits) = ${best:-0} ==="
  echo "$best"
}

ISTHERE_HAYSTACK_NEMO="$BENCH_DIR/build_haystack_nemo.py"
ISTHERE_HAYSTACK_GEN="$BENCH_DIR/build_haystack.py"
gate() {
  local profile="$1" gguf="$2" ctx="$3" label="$4"
  ensure_header
  local profile_file nemo vram rss fitted pass
  profile_file="$(find_profile_file "$profile")"
  nemo="yes"
  grep -q "Nemotron\|nemotron_h" "$profile_file" 2>/dev/null || nemo="no"
  local depth=$(( ctx * 95 / 100 ))
  log "=== gate $profile $(basename "$gguf") ctx=$ctx label='$label' depth=$depth ==="
  if ! start_server "$profile" "$gguf" "$ctx"; then
    log "gate: server failed to start at $ctx"; return 1
  fi
  fitted="$(fitted_ctx)"
  vram="$(read_vram_mib)"; rss="$(read_rss_gib)"
  local hfile
  if [ "$nemo" = "yes" ]; then
    hfile="$(python3 "$ISTHERE_HAYSTACK_NEMO" "$depth" --port "$PORT" 2>&1 | head -1)"
  else
    hfile="$(python3 "$ISTHERE_HAYSTACK_GEN" $((depth / 3)) 2>&1 | head -1)"
  fi
  [ -f "$hfile" ] || { log "gate: haystack build failed ($hfile)"; return 1; }
  local grade out
  if [ "$nemo" = "yes" ]; then
    out="$(python3 "$BENCH_DIR/query_and_grade_nemo.py" "$hfile" "$label" "$PORT" 2>&1)"
  else
    out="$(python3 "$BENCH_DIR/query_and_grade.py" "$hfile" "$label" "$PORT" 2>&1)"
  fi
  # grade JSON is the lines before the "---RAW RESPONSE---" separator.
  local grade_json sentinel nval
  grade_json="$(printf '%s\n' "$out" | sed -n '1,/---RAW RESPONSE---/p' | head -n -1)"
  sentinel="$(printf '%s' "$grade_json" | python3 -c "import json,sys;print(json.load(sys.stdin)['sentinels_found'])" 2>/dev/null)"
  nval="$(printf '%s' "$grade_json" | python3 -c "import json,sys;print(json.load(sys.stdin)['def_combine_sentinels_present'])" 2>/dev/null)"
  if [ "${sentinel:-0}" = "3" ] && [ "${nval,,}" = "true" ]; then pass="PASS"; else pass="FAIL-Q"; fi
  vram="$(read_vram_mib)"; rss="$(read_rss_gib)"
  log "[gate] $label ctx=$ctx fitted=$fitted vram=$vram rss=$rss quality=$pass ($sentinel/3, def=$nval)"
  echo "| $label | $profile | $(basename "$gguf") | $BLD | $ctx | $pass | $fitted | $vram | $rss | $sentinel/3 |" >> "$RESULTS_MD"
  log "--- raw grade ---"; echo "$out" >> "$RUN_LOG"
}

# timing: against an already-running server (started by `fits` so the flag
# recipe + fit/VRAM/RSS are already recorded), send N short non-thinking
# single-shot completions at temp 0 and report decode t/s (avg over the reps)
# plus, when speculative decoding is active, the mean accepted-draft length
# from llama-server's `timings`. This is the qwen-bench-style decode timing the
# Ornith spec A/B and REAP speed sweep use; the plan windows on decode t/s over
# the no-draft baseline. Extra llama args are not allowed here -- pass them to
# the `fits`/`gate` call that starts the server instead.
timing() {
  local label="$1" gguf="$2" reps="${3:-5}" n_pred="${4:-200}"
  log "=== timing $label $(basename "$gguf") reps=$reps n_pred=$n_pred ==="
  local i total=0 pred_per_s accept done accept run accept_sum=0 draft_sum=0
  local resp debug_payload
  for i in $(seq 1 "$reps"); do
    resp=$(curl -s -m 120 "http://127.0.0.1:$PORT/completion" \
      -H "Content-Type: application/json" \
      -d "{\"prompt\":\"Write a short function that returns the median of a numeric list, in Python.\",\"n_predict\":$n_pred,\"temperature\":0,\"seed\":42,\"cache_prompt\":false}")
    pred_per_s=$(echo "$resp" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('timings',{}).get('predicted_per_second',0))" 2>/dev/null || echo "0")
    accept=$(echo "$resp" | python3 -c "import json,sys;d=json.load(sys.stdin);t=d.get('timings',{});print(t.get('n_draft_accepted',0)+t.get('draft_n_accepted',0))" 2>/dev/null || echo "0")
    done=$(echo "$resp" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('timings',{}).get('predicted_n',0))" 2>/dev/null || echo "0")
    debug_payload=$(echo "$resp" | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin).get('timings',{})))" 2>/dev/null)
    debug "rep $i timings: $debug_payload"
    log "  rep $i: predicted_n=$done decode_tok_s=$pred_per_s n_draft_accepted=${accept:-0}"
    total=$(awk -v a="$total" -v b="$pred_per_s" 'BEGIN{printf "%.3f", a+b}')
    draft_sum=$(awk -v a="$draft_sum" -v b="${accept:-0}" 'BEGIN{printf "%.3f", a+b}')
  done
  local avg
  avg=$(awk -v t="$total" -v n="$reps" 'BEGIN{printf "%.2f", t/n}')
  local avg_acc
  avg_acc=$(awk -v t="$draft_sum" -v n="$reps" 'BEGIN{printf "%.2f", t/n}')
  log "[timing $label] avg_decode_tok_s=$avg avg_draft_accepted=${avg_acc}"
  echo "| $label | $(basename "$gguf") | $BLD | n/a | $avg | n/a | n/a | n/a | n/a | n/a |" >> "$RESULTS_MD"
}

ensure_header() {
  [ -f "$RESULTS_MD" ] && return
  {
    echo "# All-preset maximum-KV-context ceiling sweep results"
    echo
    echo "Generated by bench/ctx-ceiling.sh (BUILD_STAMP $BUILD_STAMP)."
    echo "Reference card: RTX 3080 8GB ($GPU_TOTAL_MIB MiB). llama-server: $LLAMA_BUILD."
    echo "Thinking forced off on every row (window is the context, not reasoning)."
    echo "Quality gate (gate subcommand): 3/3 sentinels + combine_sentinels def at ~0.95*ctx."
    echo
    echo "| label | profile | quant | build | ctx | verdict | fitted n_ctx | VRAM | RSS GiB | quality |"
    echo "|---|---|---|---|---|---|---|---|---|---|"
  } >> "$RESULTS_MD"
}

cmd_fits()  { ensure_header; fits "$@"; }
cmd_ramp()  { ramp "$@"; }
cmd_gate()  { gate "$@"; }
cmd_timing() { ensure_header; timing "$@"; }

case "${1:-}" in
  fits) shift; cmd_fits "$@" ;;
  ramp) shift; cmd_ramp "$@" ;;
  gate) shift; cmd_gate "$@" ;;
  timing) shift; cmd_timing "$@" ;;
  *)
    echo "Usage: $0 {fits PROFILE GGUF CTX [extra...] | ramp PROFILE GGUF [start] [extra...] | gate PROFILE GGUF CTX LABEL | timing LABEL GGUF [REPS] [N_PRED]}"
    exit 1
    ;;
esac