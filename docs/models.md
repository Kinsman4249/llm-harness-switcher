# Models

How to choose a model, the supported model profile table, architecture notes
(per-layer embeddings, multimodal weights, thinking mode), benchmark context,
and the recommended client-side settings per profile.

- Up: [README](../README.md) | Prev: [Installation](installation.md) | Next:
  [Usage](usage.md) | See also: [Context sizing](context-sizing.md)

## Choosing a model

`install.sh` asks for a "model profile" - see `model-profiles/*.sh` - which
sets every model-specific default (repo, quant sizes, layer count, KV-cache
sizing behaviour, speculative-decoding wiring). Only the example profile,
`gemma4-e2b.sh`, is committed to this repo; the other, live-tested profiles
live in the private presets repo (`8gb-immutable-fedora-presets`, pointed at
via `install.sh --presets-dir`) and are discovered there, never auto-cloned.
Details of every profile field are in `model-profiles/README.md`. Which models
are on offer therefore grows over time; the table below covers the set
available at the time of writing.

| | Qwen3.5-9B-MTP | Qwen3.5-9B-Defiant-Fable-MTP | Gemma 4 E2B | Gemma 4 E4B | Nemotron 3 Nano 4B | Nemotron 3 Nano 30B-A3B |
| --- | --- | --- | --- | --- | --- | --- |
| Effective params | 9B | 9B | 2.3B | 4.5B | 4B | 3B active / token (30B total, MoE) |
| Params incl. embeddings | 9B | 9B | 5.1B | 8B | 4B | 30B |
| Layers | 32 | 32 | 35 | 42 | 42 | 52 (23 Mamba-2 + 23 MoE + 6 attention) |
| Max context tested on an 8GB card | 131072 (Q4_K_M, needs heavier CPU offload than default - see below) | 131072 (Q4_K_M, needs heavier CPU offload than default - see below; NOT yet live-benchmarked, see `model-profiles/qwen35-9b-defiant-fable.sh`) | 128K | 128K | 131072 | 262144 (fits to 1M on build d59d455fd, but kept at 262144 - quality gate fails past the 256K training window; see `bench/ctx-ceiling-results.md`) |
| Tau2 tool-use average | - | - | 24.5% | 42.2% | - | - |
| LiveCodeBench v6 | - | - | 44.0% | 52.0% | - | - |
| Speculative decoding | self-contained MTP head | self-contained MTP head | separate drafter (UNVERIFIED filenames) | separate drafter (UNVERIFIED filenames) | none | none |

Tau2/LiveCodeBench figures are from Google's Gemma 4 model card
([huggingface.co/google/gemma-4-E4B](https://huggingface.co/google/gemma-4-E4B));
Qwen3.5-9B (both profiles) and the two Nemotron profiles weren't benchmarked
against that same suite by this project, hence the blanks. NVIDIA's own
technical report puts Nemotron 3 Nano 30B-A3B at BFCL v4 53.76 vs
Qwen3-30B-A3B-Thinking-2507's 46.40 (source: the Nemotron 3 Nano technical
report on research.nvidia.com / its arXiv preprint - corroborated by a
secondary summary, not independently re-verified against the primary PDF
table) - a different benchmark suite than the Tau2/LiveCodeBench row above, so
it isn't included in the table itself to avoid implying a direct comparison.

**E2B is a poor fit for Claude Code's tool-calling loop** - less than a third
the Tau2 tool-use score of E4B - and is offered mainly for completeness on
tighter VRAM budgets. If you're picking a Gemma profile, default to E4B.

**The Gemma profiles are not fully wired up yet, and `qwen35-9b-defiant-fable`
hasn't been live-tested at all.** `model-profiles/gemma4-e2b.sh` and
`model-profiles/gemma4-e4b.sh` ship with several UNVERIFIED placeholders
(drafter model repo/filenames, the Per-Layer-Embedding tensor name, exact
quant file sizes) left empty on purpose rather than guessed, per this project's
policy of never inventing a `llama-server` flag or filename it hasn't
confirmed. `install.sh` treats each empty placeholder as "feature not available
yet" and skips it with a warning rather than emit something broken.
`model-profiles/qwen35-9b-defiant-fable.sh` (DavidAU's uncensored "Defiant
Fable" fine-tune of the same base model) inherits every architecture-derived
number from `qwen35-9b.sh` since the base model is unchanged, but its
`LLAMA_CPU_FFN_LAYERS_RECOMMENDED` is an extrapolated estimate, not a live
measurement - see that file's own comments for the derivation. Qwen3.5-9B-MTP
and both Nemotron 3 Nano profiles have been run end-to-end and live-tested on
real hardware (RTX 3080 8GB); the Gemma and Defiant Fable profiles have not.

## Per-Layer Embeddings: the opposite VRAM trade from dense-FFN offload

Gemma 4's Per-Layer Embeddings (PLE) are large lookup tables (one small
embedding table per decoder layer, per token) that account for most of the gap
between "effective" and "with embeddings" params in the table above. Because
they're pure lookups with no matrix multiply, offloading them to system RAM
(`--override-tensor` on the PLE tensor, prompted by `install.sh` when a
profile's `PLE_TENSOR_REGEX` is set) costs one small host-memory read per
token - cheap.

This is the **opposite** tradeoff from the dense-FFN offload option covered in
[Context sizing](context-sizing.md#getting-more-headroom-than-that): offloading
a full FFN matrix costs a real GEMM's worth of PCIe/RAM bandwidth per token,
which is why this project defaults that option light. PLE offload has no such
cost, so it defaults to **on** whenever it's available. Don't confuse the two
just because both use `--override-tensor` under the hood.

PLE weights are also reported to be sensitive to quantization noise, and an
now-closed llama.cpp issue
([#22243](https://github.com/ggml-org/llama.cpp/issues/22243)) questioned
whether llama.cpp's forward graph implements the PLE injection pipeline
correctly at all - the issue shows no linked PR or stated resolution, so treat
PLE correctness in whatever `llama-server` build you're running as unverified
until you've eyeballed a coherence check yourself (deterministic prompt, temp
0, compared against the same prompt through Ollama or `transformers`). Prefer
Google's own QAT Q4_0 GGUF or an Unsloth UD dynamic quant over a plain
`llama-quantize` output for this reason.

## Multimodal weights

Gemma 4 E2B/E4B are multimodal (text, image, audio) upstream. This project
only ever talks to the model through a text-only OpenAI-compatible chat
endpoint - `install.sh` never passes `--mmproj`, and excludes any
`mmproj-*.gguf` file from both the download filter and the main-model file
search, so a multimodal projector file that happens to ship in the same repo
doesn't get pulled in or mistaken for the main weights.

## Thinking mode

All the model families here support a reasoning/"thinking" mode, toggled via
`--chat-template-kwargs '{"enable_thinking":<true|false>}'` on `llama-server` -
not a `<|think|>` system-prompt token.

**Off by default, on purpose - not a VRAM/context limitation.** Every
downloaded model (Gemma 4 E4B, Nemotron 3 Nano 4B, Nemotron 3 Nano 30B-A3B) has
comfortable VRAM headroom (1.7-2.6 GB) to run with thinking on at its full
recommended context. The reason it's off anyway is a live tool-calling test
against Nemotron 3 Nano 30B-A3B (2026-07-25, RTX 3080 8GB, a grep+read_file
tool-call prompt):

| | thinking ON (default template) | thinking OFF |
| --- | --- | --- |
| Tool call at a realistic 500-token budget | **Never emitted** - burned the whole budget on `reasoning_content`, `finish_reason: "length"` | Correct tool call, 50 completion tokens, 1.3s |
| Tool call with budget raised to 2000 tokens | Eventually correct-ish, but 643 completion tokens and 14.6s | (same as above) |

Reasoning cost roughly 13x the tokens and 11x the latency for a tool call that
was no more correct than the non-reasoning one - and at token budgets closer to
what a real Claude Code sub-agent call uses, it can consume the entire budget
and never produce a tool call at all. That's the opposite of what you want for
a mechanical, tool-calling-heavy workload, so thinking defaults to off.

Turn thinking on with `install.sh --enable-thinking` (back off with
`--disable-thinking`) - deliberately a command-line flag, not part of the
interactive prompt flow, so it can't get left on by an "Enter to keep previous
answer" re-run. Each profile declares `THINKING_KWARG_KEY="enable_thinking"`
(a capability marker - which chat-template kwarg this model's template uses),
and `install.d/80-launcher.sh` emits `--chat-template-kwargs` with that key set
to whatever `ENABLE_THINKING` resolved to, explicitly true or false either way,
so the deployed script never depends on a GGUF's undocumented baked-in default.

When thinking is off, the model's tool-calling path doesn't map cleanly to a
documented sampling recipe (the model card and Unsloth's docs disagree), so
this project tested both candidates head-to-head and set the profile's
`DEFAULT_TEMP`/`DEFAULT_TOP_P`/`DEFAULT_TOP_K` from the winner - see the
`qwen35-9b.sh` profile for the full methodology in comment form.

In **kilo mode** there's also a reasoning-mode menu (`off`/`on`/`budgeted`/`max`
plus legacy `effort`) - see [Kilo mode](usage.md#kilo-mode).

## Benchmarks

The detailed per-model benchmark narratives live in `bench/` alongside the
rerunnable scripts (e.g. `bench/qwen-bench.sh` with results in
`bench/qwen-results.md`, and `bench/ctx-ceiling-results.md` for the Nemotron
context ceiling). The key findings behind the current profile defaults:

- **Qwen3.5-9B-MTP long context.** A needle-in-haystack + code-generation probe
  stayed accurate out to ~105K tokens of real source context on an RTX 3080
  8GB. Reaching a true 128K window on that card needs a much heavier
  CPU-FFN-offload setting than the project's light default - a deliberate
  speed-for-room trade, not something that fits "for free". If you want 128K
  without that tradeoff, you need more than 8GB of VRAM.
- **Qwen3.5-9B speed sweep.** Sweeping at fixed `-c 131072` found that a
  `q4_0`/`q4_0` KV cache plus `--override-tensor` N=11 (instead of the old
  `q8_0`/`q8_0` with N=24) gave ~59.8% faster decode and ~1 GB less VRAM with
  no quality regression. `model-profiles/qwen35-9b.sh` now sets
  `CACHE_TYPE_K`/`CACHE_TYPE_V="q4_0"` and
  `LLAMA_CPU_FFN_LAYERS_RECOMMENDED=11` as its tested defaults. Asymmetric KV
  cache pairs (e.g. `q8_0/q5_1`) are avoided because they collapsed onto a
  catastrophically slow path in this project's llama.cpp build - which is why
  KV cache type is a profile-author decision made after benchmarking, not an
  interactive prompt.

## Recommended client-side model settings per profile

Zoo Code's "OpenAI Compatible" provider asks you to describe the model's
capabilities yourself (context window, image support, etc.) since it can't
query an arbitrary OpenAI-compatible backend for them. These fields don't
affect `llama-server` itself - they just tell Zoo Code (or another client) what
to expect, so setting them wrong doesn't break inference, but it can cause
premature truncation (window set too low) or a client sending image content the
model can't use (image support set true on a text-only model).

Values below come straight from the matching `model-profiles/*.sh`
`RECOMMENDED_CTX_8GB` (all measured/confirmed at 8GB VRAM, see that file's
comments for the live test this number is from). "Not yet tested" means this
project hasn't run that profile end-to-end yet (see
[Troubleshooting: known limitations](troubleshooting.md#known-limitations)) -
don't trust a number that isn't listed until it's been updated here.

| Profile | Context Window Size | Image Support | Thinking default | Notes |
| --- | --- | --- | --- | --- |
| Nemotron 3 Nano 30B-A3B | `262144` | unchecked | off (`--disable-thinking`, the project default) | Text-only. Confirmed live 2026-07-25 (RTX 3080 8GB, UD-Q4_K_XL) and re-verified 2026-08-20 on a fresh CUDA `llama-server` build (commit `d59d455fd`) at the full 262144-token context: needle-in-haystack retrieval 3/3 at 131K and 200K depth via `/v1/chat/completions` (thinking off), tool-call gate 5/5 single-turn + 20/20 multi-turn with no VRAM drift. Note the MoE `--fit` offload holds most of the 30B model in **system RAM (~21 GiB RSS, peak ~22 GiB, ~1.3 GiB swap hit at 200K worst case)** so a long 256K session is tight on a 32 GB box - see `model-profiles/nemotron3-nano-30b.sh`. Thinking ON burned an entire 500-token budget on `reasoning_content` and never emitted a tool call at all; leave thinking off for Claude Code's tool-calling workload. |
| Nemotron 3 Nano 4B | `131072` | unchecked | off (`--disable-thinking`, the project default) | Text-only. Confirmed live on an RTX 3080 8GB - see `model-profiles/nemotron3-nano-4b.sh`. |
| Gemma 4 E4B | `131072` | leave unchecked anyway | off (project never sends the `<|think|>` trigger) | Model is multimodal upstream (text/image/audio), but this project only ever talks to it over a text-only endpoint (see [Multimodal weights](#multimodal-weights)) - `install.sh` never passes `--mmproj`, so there's no working image path even though the model card supports one. Not yet live-tested end-to-end (see [Troubleshooting](troubleshooting.md#known-limitations)) - treat the context number as the profile's stated target, not a confirmed measurement. |
| Gemma 4 E2B | not yet tested | leave unchecked anyway | off | Several profile values are UNVERIFIED placeholders (see [Choosing a model](#choosing-a-model)) - don't configure a client against this profile yet. |
| Qwen3.5-9B-MTP | `131072` | unchecked | off (`--chat-template-kwargs '{"enable_thinking":false}'`, forced explicitly - see [Thinking mode](#thinking-mode)) | Confirmed live 2026-07-25 on an RTX 3080 8GB with UD-Q4_K_XL - see [Benchmarks](#benchmarks) and `model-profiles/qwen35-9b.sh`. Reaching this context on 8GB still needs `--override-tensor` raised past this project's light default, but the profile's own tested value (N=11 with `q4_0/q4_0` KV cache, pre-filled by `install.sh`) is much lighter than the N=24 first measured with the old `q8_0/q8_0` default - about 60% faster decode at the same context, no accuracy drop. |
| Qwen3.5-9B-Defiant-Fable-MTP | `131072` | unchecked | off (`--reasoning off`, forced explicitly, same mechanism as Qwen3.5-9B-MTP above) | Same base model as Qwen3.5-9B-MTP, uncensored/de-refusal fine-tune (DavidAU) - not yet live-tested end-to-end (see [Choosing a model](#choosing-a-model)), don't trust the context number as confirmed until `model-profiles/qwen35-9b-defiant-fable.sh`'s `LLAMA_CPU_FFN_LAYERS_RECOMMENDED` has actually been run on real hardware. |

Leave **Enable R1 model parameters** unchecked for every profile above (that's
for QwQ/R1-style models that 400 without it, not applicable here), **Enable
Reasoning Effort** unchecked (thinking mode here is controlled by
`install.sh --enable-thinking`/`--disable-thinking`, not a per-request client
field - see [Thinking mode](#thinking-mode)), and **Input/Output Price** at `0`
(it's local, nothing is billed).