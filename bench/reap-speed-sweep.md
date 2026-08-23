# REAP-40B-A3B speed sweep (plan 1787507364914 Track B)

What the plan called "Track B": at the profile's **native 262144 (256K) window,
thinking off, new build `c060ca974` (build 10603)**, find the fastest KV-cache
type and quantization at `--fit`, then gate the winner for tool-call
reliability. The lever that would give the native window the biggest free
speed win was decode throughput, so that is what got measured.

Driver: `bench/reap-speed-sweep.sh` (build 2026-08-23.1) - each candidate is
measured through the same `ctx-ceiling.sh` harness (`fits` records
VRAM/RSS/fitted, `timing` measures decode t/s) so every row carries the same
build stamp and lands in `ctx-ceiling-results.md`, not an ad-hoc log.

## L2 - KV cache type (Q4_K_M fixed)

| KV cache | avg decode t/s | VRAM | RSS | verdict |
| --- | --- | --- | --- | --- |
| `q8_0/q8_0` (old default) | 28.13 | 6490 MiB | 24.1 GiB | baseline |
| `q4_0/q4_0` (symmetric) | **31.78** | 6476 MiB | 23.9 GiB | faster, keep |

Symmetric `q4_0/q4_0` only - never mix K/V types (the asymmetric-combo
landmine). Both fit at 262144.

## L3 - Quantization (KV q4_0/q4_0 fixed = L2 winner)

| Quant | file (GiB) | avg decode t/s | VRAM | RSS | verdict |
| --- | --- | --- | --- | --- | --- |
| `Q4_K_M` | 23.27 | 26.28 | 6476 MiB | 23.9 GiB | former primary, accuracy fallback |
| `IQ4_XS` | 20.46 | 27.57 | 6534 MiB | 21.0 GiB | max headroom (smallest RSS) |
| `Q4_K_S` | 21.83 | **28.26** | 6552 MiB | 22.5 GiB | **winner** |

Q4_K_S is the fastest standard K-quant (full 4-bit quality, no imatrix
tradeoff), fits comfortably, and its 21.83 GiB file beats Q4_K_M's headroom.
IQ4_XS is a close speed second with the best RSS - the documented headroom
pick.

## Confirmation head-to-head (winner vs old default, same session)

Run-to-run variance showed up between sweep phases (Q4_K_M@q4_0 measured
31.78 in L2 but 26.28 re-measured in L3), so the two actual shipped defaults
were re-run together at 7 reps:

| Config | avg decode t/s | VRAM | RSS |
| --- | --- | --- | --- |
| **Q4_K_S + q4_0/q4_0 (new default)** | **27.41** | 6552 MiB | 22.5 GiB |
| Q4_K_M + q8_0/q8_0 (old default) | 23.64 | 6490 MiB | 24.0 GiB |

New default is **+3.8 t/s (~+16%)** and **-1.5 GiB RSS** at near-equal VRAM.

## Tool gate (winner at 262144)

`tool_gate.py` over /v1/chat/completions, thinking off (`enable_thinking:false`):

```
rep 1-5: well_formed=True tools=['grep', 'read_file'] finish=tool_calls leaked=False
RESULT [reap-...Q4_K_S] 5/5 well-formed tool calls
PASS
```

## Outcome

`qwen3-coder-next-reap-40b.sh` now sets:

- `CACHE_TYPE_K="q4_0"`, `CACHE_TYPE_V="q4_0"`
- `QUANT_MENU` primary = `Q4_K_S` (21.83 GiB); Q4_K_M demoted to accuracy
  fallback, IQ4_XS documented as the headroom pick
- `RECOMMENDED_CTX_8GB=262144` unchanged (native window still the default)

Also fixed a stale measurement while there: the old profile's "RSS ~6 GiB"
was wrong on the new build - L2/L3/confirm all read **~22-24 GiB RSS** (RAM,
not VRAM; the MoE experts park in RAM under `NGL_MODE=fit`, which is the
premise, but it is ~24 GiB of the 32GB box, not ~6). The profile's confirmed
block now records the real numbers with the build stamp.