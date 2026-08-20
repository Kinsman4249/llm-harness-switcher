# llm-harness-switcher

An on/off switch for routing Claude Code through a local model instead of your Anthropic Pro/Max subscription, with no API key anywhere and no cloud fallback. When it's off, Claude Code behaves exactly as if this project didn't exist, normal subscription auth, Sonnet and Opus available. When it's on, every model Claude Code might call, main session or sub-agent, routes to a local model (Qwen3.5-9B, Gemma 4, or Nemotron 3 Nano, your choice - see "Choosing a model" below) running under llama-server (llama.cpp's own server), meant for small, cheap tasks where you don't want to spend Pro usage at all.

## Why this exists

Claude Code is agentic: a lot of what it does per session is mechanical (file search, `grep`, listing directories, small reads) rather than reasoning-heavy. Running that mechanical work through a frontier model is more capability than the task needs. This project gives you a deliberate, visible switch to route that kind of work to a local model instead, without touching your subscription usage or ever requiring a billed API key.

It does not try to be a hybrid router that transparently falls back to cloud when llama-server isn't running. Anthropic's April 2026 policy change blocking subscription OAuth tokens in third-party proxies ruled out a fallback that draws from Pro/Max usage instead of billed API usage. Rather than accept surprise direct billing on the fallback path, this project has no cloud path in its proxy config at all: local mode either uses your local model, or it fails cleanly with a connection error. No middle ground, no accidental charges.

## Requirements

- A Linux host with [Distrobox](https://github.com/89luca89/distrobox) and an NVIDIA-capable container (GPU passthrough already working). Built and tested on Bazzite (KDE Plasma), but the mechanism (systemd `--user` units calling into `distrobox enter`) has no Bazzite-specific dependency and should work on any distro with Distrobox and systemd.
- `llama-server` from [llama.cpp](https://github.com/ggml-org/llama.cpp) built inside that container. `install.sh` builds it automatically (clones the repo, builds with CUDA) if it isn't already on `$PATH` there.
- [LiteLLM](https://docs.litellm.ai) (`pip install 'litellm[proxy]'`) installed inside that container.
- Claude Code, used either via the CLI or the VS Code/VSCodium extension.
- Roughly 8 GB of VRAM headroom to run any of the supported models at a reasonable quant and context length.

## Choosing a model

`install.sh` asks for a "model profile" - see `model-profiles/*.sh` - which sets every model-specific default below it (repo, quant sizes, layer count, KV-cache sizing behaviour, speculative-decoding wiring). Only the example profile, `gemma4-e2b.sh`, is committed to this repo; the other, live-tested profiles live in the private presets repo (`8gb-immutable-fedora-presets`, pointed at via `install.sh --presets-dir`) and are discovered there, never auto-cloned. Details of every profile field are in `model-profiles/README.md`. Together the shipped example and the presets repo cover six models:

| | Qwen3.5-9B-MTP | Qwen3.5-9B-Defiant-Fable-MTP | Gemma 4 E2B | Gemma 4 E4B | Nemotron 3 Nano 4B | Nemotron 3 Nano 30B-A3B |
| --- | --- | --- | --- | --- | --- | --- |
| Effective params | 9B | 9B | 2.3B | 4.5B | 4B | 3B active / token (30B total, MoE) |
| Params incl. embeddings | 9B | 9B | 5.1B | 8B | 4B | 30B |
| Layers | 32 | 32 | 35 | 42 | 42 | 52 (23 Mamba-2 + 23 MoE + 6 attention) |
| Max context tested on an 8GB card | 131072 (Q4_K_M, needs heavier CPU offload than default - see below) | 131072 (Q4_K_M, needs heavier CPU offload than default - see below; NOT yet live-benchmarked, see `model-profiles/qwen35-9b-defiant-fable.sh`) | 128K | 128K | 131072 | 262144 |
| Tau2 tool-use average | - | - | 24.5% | 42.2% | - | - |
| LiveCodeBench v6 | - | - | 44.0% | 52.0% | - | - |
| Speculative decoding | self-contained MTP head | self-contained MTP head | separate drafter (UNVERIFIED filenames) | separate drafter (UNVERIFIED filenames) | none | none |

Tau2/LiveCodeBench figures are from Google's Gemma 4 model card ([huggingface.co/google/gemma-4-E4B](https://huggingface.co/google/gemma-4-E4B)); Qwen3.5-9B (both profiles) and the two Nemotron profiles weren't benchmarked against that same suite by this project, hence the blanks. NVIDIA's own technical report puts Nemotron 3 Nano 30B-A3B at BFCL v4 53.76 vs Qwen3-30B-A3B-Thinking-2507's 46.40 (source: the Nemotron 3 Nano technical report on research.nvidia.com / its arXiv preprint - corroborated by a secondary summary, not independently re-verified against the primary PDF table) - a different benchmark suite than the Tau2/LiveCodeBench row above, so it isn't included in the table itself to avoid implying a direct comparison.

**E2B is a poor fit for Claude Code's tool-calling loop** - less than a third the Tau2 tool-use score of E4B - and is offered mainly for completeness on tighter VRAM budgets. If you're picking a Gemma profile, default to E4B.

**The Gemma profiles are not fully wired up yet, and `qwen35-9b-defiant-fable` hasn't been live-tested at all.** `model-profiles/gemma4-e2b.sh` and `model-profiles/gemma4-e4b.sh` ship with several UNVERIFIED placeholders (drafter model repo/filenames, the Per-Layer-Embedding tensor name, exact quant file sizes) left empty on purpose rather than guessed, per this project's policy of never inventing a `llama-server` flag or filename it hasn't confirmed. `install.sh` treats each empty placeholder as "feature not available yet" and skips it with a warning rather than emit something broken. `model-profiles/qwen35-9b-defiant-fable.sh` (DavidAU's uncensored "Defiant Fable" fine-tune of the same base model) inherits every architecture-derived number from `qwen35-9b.sh` since the base model is unchanged, but its `LLAMA_CPU_FFN_LAYERS_RECOMMENDED` is an extrapolated estimate, not a live measurement (this checkpoint's quants run heavier than the Unsloth build `qwen35-9b.sh` was tuned against) - see that file's own comments for the derivation and for what to re-check on first use. Qwen3.5-9B-MTP and both Nemotron 3 Nano profiles have been run end-to-end and live-tested on real hardware (RTX 3080 8GB); the Gemma and Defiant Fable profiles have not.

### Per-Layer Embeddings: the opposite VRAM trade from dense-FFN offload

Gemma 4's Per-Layer Embeddings (PLE) are large lookup tables (one small embedding table per decoder layer, per token) that account for most of the gap between "effective" and "with embeddings" params in the table above. Because they're pure lookups with no matrix multiply, offloading them to system RAM (`--override-tensor` on the PLE tensor, prompted by `install.sh` when a profile's `PLE_TENSOR_REGEX` is set) costs one small host-memory read per token - cheap.

This is the **opposite** tradeoff from the dense-FFN offload option covered below in "Getting more headroom than that": offloading a full FFN matrix costs a real GEMM's worth of PCIe/RAM bandwidth per token, which is why this project defaults that option light. PLE offload has no such cost, so it defaults to **on** whenever it's available. Don't confuse the two just because both use `--override-tensor` under the hood.

PLE weights are also reported to be sensitive to quantization noise, and an now-closed llama.cpp issue ([#22243](https://github.com/ggml-org/llama.cpp/issues/22243)) questioned whether llama.cpp's forward graph implements the PLE injection pipeline correctly at all - the issue shows no linked PR or stated resolution, so treat PLE correctness in whatever `llama-server` build you're running as unverified until you've eyeballed a coherence check yourself (deterministic prompt, temp 0, compared against the same prompt through Ollama or `transformers`). Prefer Google's own QAT Q4_0 GGUF or an Unsloth UD dynamic quant over a plain `llama-quantize` output for this reason.

### Multimodal weights

Gemma 4 E2B/E4B are multimodal (text, image, audio) upstream. This project only ever talks to the model through a text-only OpenAI-compatible chat endpoint - `install.sh` never passes `--mmproj`, and excludes any `mmproj-*.gguf` file from both the download filter and the main-model file search, so a multimodal projector file that happens to ship in the same repo doesn't get pulled in or mistaken for the main weights.

### Thinking mode

All three model families here support a reasoning/"thinking" mode, toggled via `--chat-template-kwargs '{"enable_thinking":<true|false>}'` on `llama-server` - not a `<|think|>` system-prompt token as an earlier version of this section claimed (that claim didn't hold up against a live test of the actual unsloth GGUF this project downloads: it emits `reasoning_content` by default with zero flags passed).

**Off by default, on purpose - not a VRAM/context limitation.** Every downloaded model (Gemma 4 E4B, Nemotron 3 Nano 4B, Nemotron 3 Nano 30B-A3B) has comfortable VRAM headroom (1.7-2.6 GB) to run with thinking on at its full recommended context. The reason it's off anyway is a live tool-calling test against Nemotron 3 Nano 30B-A3B (2026-07-25, RTX 3080 8GB, a grep+read_file tool-call prompt):

| | thinking ON (default template) | thinking OFF |
| --- | --- | --- |
| Tool call at a realistic 500-token budget | **Never emitted** - burned the whole budget on `reasoning_content`, `finish_reason: "length"` | Correct tool call, 50 completion tokens, 1.3s |
| Tool call with budget raised to 2000 tokens | Eventually correct-ish, but 643 completion tokens and 14.6s | (same as above) |

Reasoning cost roughly 13x the tokens and 11x the latency for a tool call that was no more correct than the non-reasoning one - and at token budgets closer to what a real Claude Code sub-agent call uses, it can consume the entire budget and never produce a tool call at all. That's the opposite of what you want for a mechanical, tool-calling-heavy workload, so `ENABLE_THINKING` defaults to `no`.

Turn it on with `install.sh --enable-thinking` (turn it back off with `--disable-thinking`) - deliberately a command-line flag, not part of the interactive prompt flow, so it can't get left on by an "Enter to keep previous answer" re-run. `model-profiles/gemma4-e4b.sh`, `nemotron3-nano-4b.sh`, and `nemotron3-nano-30b.sh` each declare `THINKING_KWARG_KEY="enable_thinking"` (a capability marker - which chat-template kwarg this model's template uses), and `install.d/80-launcher.sh` emits `--chat-template-kwargs` with that key set to whatever `ENABLE_THINKING` resolved to, explicitly true or false either way, so the deployed script never depends on a GGUF's undocumented baked-in default.

**Correction, 2026-07-25:** this section previously claimed `qwen35-9b.sh` didn't need `THINKING_KWARG_KEY` because Qwen3.5-9B "already defaults to reasoning off." That was wrong for the path that actually matters - a real `/v1/chat/completions` request (the OpenAI-compatible path Roo Code/Claude Code use, not the raw `/completion` endpoint the original check used) with zero flags sent came back with `reasoning_content` populated: 13.5s and 277 completion tokens spent thinking before a tool call that a forced-off request produces in ~1.7s/50 tokens. The earlier raw-`/completion` check (a bare `</think>` token with no flags sent) was a weaker signal than it looked - it showed the raw model's own completion bias on a plain string, not the real chat-template-driven request path a client actually sends. `qwen35-9b.sh` now sets `THINKING_KWARG_KEY="enable_thinking"` like the other three profiles, closing this gap.

Qwen/Qwen3.5-9B's own model card and Unsloth's docs also disagree on which sampling recipe applies once thinking is forced off for tool-calling/agentic use - the card has no dedicated "tool calling" bucket (only general/reasoning/precise-coding), and even its "reasoning" bucket is internally inconsistent across the card ([discussion #51](https://huggingface.co/Qwen/Qwen3.5-9B/discussions/51)). Rather than guess, both candidates were tested head-to-head with a live grep+read_file tool-call prompt (5 reps each, `enable_thinking:false` held constant, 500-token budget): the card's own "Non-Thinking/Instruct, General" recipe (temp 0.7/top_p 0.8/top_k 20) got 5/5 correct tool calls but leaked stray prose alongside the tool call in 3/5 runs, averaging 64.8 completion tokens and 2.90s; Unsloth's own example recipe (temp 0.6/top_p 0.95/top_k 20 - technically the card's "Thinking/Precise-coding" numbers, run by Unsloth alongside `enable_thinking:false` anyway) got 5/5 correct tool calls, zero leaked prose, averaging 49.6 tokens and 1.72s. `model-profiles/qwen35-9b.sh` now sets `DEFAULT_TEMP="0.6"`, `DEFAULT_TOP_P="0.95"`, `DEFAULT_TOP_K="20"` on that basis - see the profile file for the full methodology in comment form.

### Qwen3.5-9B-MTP long-context coding benchmark (2026-07-25, RTX 3080 8GB)

The user asked whether any Qwen3.5-9B-MTP quant could hit a genuine 128K context window and stay accurate enough to code with, on this project's reference 8GB card. Method: a needle-in-haystack + code-generation probe, not a standard suite (no LiveCodeBench/Tau2/HumanEval numbers exist for this profile - don't compare the pass/fail results below against the Tau2/LiveCodeBench columns in the table above, they aren't the same kind of measurement). Haystack = real llama.cpp C/C++ source concatenated to the target size, with three uniquely-named marker functions (`get_partition_flux_*`) returning random sentinel integers spliced in at roughly 10%/50%/90% depth; the prompt then asks the model to state all three integers and write a small Python function summing them - checks both long-range retrieval and basic code correctness in one shot. Every run used `-fa on --cache-type-k q8_0 --cache-type-v q8_0 --spec-type draft-mtp --spec-draft-n-max 2`, temperature 0, via the raw `/completion` endpoint (see the caveat above - this is not the same code path as a real chat request through the proxy).

| Quant | Context tried | Real VRAM used | Sentinels found | Valid generated code | Time |
| --- | --- | --- | --- | --- | --- |
| Q5_K_M | 14123 tokens (of `-c 16384`) | 7235 MiB | 3/3 | yes | 8.5s |
| UD-Q4_K_XL | 36516 tokens (of `-c 49152`) | 7609 MiB | 3/3 | yes | 21.2s |
| Q4_K_M | 49944 tokens (of `-c 65536`, default `--override-tensor` N=2) | 7787 MiB | 3/3 | yes | 30.2s |
| Q4_K_M | 105306 tokens (of `-c 131072`, `--override-tensor` raised to N=24 - see below) | 7819 MiB | 3/3 | yes | 107.2s |

All four passed cleanly - no accuracy drop observed across roughly an 8x range of context sizes or across quants. But **128K only fits on this card at all with a much heavier CPU-FFN-offload setting than this project's light default**: an attempt at `-c 131072` with the light default (`--override-tensor` N=2, i.e. only the last 2 of 32 layers' FFN weights on CPU) OOM'd outright (`cudaMalloc failed: out of memory` allocating the KV cache buffer). Getting 131072 to fit at all required moving 24 of 32 layers' dense FFN weights to CPU RAM (`--override-tensor 'blk\.([8-9]|1[0-9]|2[0-9]|3[01])\.ffn_(gate|up|down)\.weight=CPU'`) - a much heavier trade than the 2-layer default this project otherwise recommends (see "Getting more headroom than that" below), and one that costs real per-token latency since Qwen3.5-9B has no MoE layers to make CPU-offloaded FFN cheap (every offloaded layer's full dense FFN matrix reads from RAM on every token). The 107s for the 105K-token run includes both prompt processing and generation, not prompt processing alone, so don't read it as a per-token generation-speed number on its own.

Bottom line: **yes, Qwen3.5-9B-MTP quants stayed accurate on this single-probe test all the way out to ~105K tokens**, including at the 131072-ctx/heavy-offload configuration - but reaching a true 128K window on an 8GB card means deliberately trading generation speed for it (N=24 offload, not this project's N=2 default), not something that fits "for free" the way Nemotron 3 Nano's MoE-based offload does. If you want 128K without that tradeoff, you need more than 8GB of VRAM. See `model-profiles/qwen35-9b.sh` for the same finding in comment form next to `RECOMMENDED_CTX_8GB`. **Superseded by the speed sweep below**: N=24 was the correct minimum for the KV cache type used above (q8_0/q8_0), but not for the KV cache type this profile now defaults to.

### Qwen3.5-9B-UD-Q4_K_XL speed sweep (2026-07-25, RTX 3080 8GB)

The 128K-context config above works, but it's the slowest one this project could produce for this model: 24 of 32 dense FFN layers on CPU RAM is a heavy, deliberate tradeoff, not a light default. `bench/qwen-bench.sh` (committed, rerunnable - see the script header for usage) swept the free variables at fixed `-c 131072` to find a faster config that passes the same quality gate, rather than just accepting that tradeoff. Full raw results: `bench/qwen-results.md`.

**KV cache quant type mattered more than expected, and not in the "quality vs VRAM" way you'd expect.** Every combo loaded and passed a quick smoke test, but a real ~36.5K-token `/completion` on `q8_0/q5_1`, `q8_0/q4_0`, or `q5_1/q5_1` fell onto a catastrophically slow path (30+ minutes for a request that should take under a minute - confirmed via a short cache-hit follow-up alone taking 100+ seconds instead of ~600ms). Only symmetric `q8_0/q8_0` (the old default) and symmetric `q4_0/q4_0` stayed fast. Root cause not confirmed by reading llama.cpp source, but the pattern matches this project's llama.cpp build having `GGML_CUDA_FA_ALL_QUANTS=OFF` - plausibly no fused flash-attention CUDA kernel for those combos on this build, forcing a much slower fallback rather than any quality problem. Worth retrying if a future rebuild turns that flag on.

`q4_0/q4_0` uses about 1 GB less VRAM than `q8_0/q8_0` at the same layer count, with no quality difference (still 3/3 sentinels + correct generated code at both ~36.5K and ~99870-token depth). That freed GB is what actually buys the speedup: bisecting on VRAM headroom (not on raw decode speed at a fixed layer count, which barely differs between KV types since CPU-offloaded layers dominate either way) found `--override-tensor` N=11 is enough for `q4_0/q4_0`, not N=24.

Measured at ~99870 tokens (99.9% of the way to `-c 131072`, the most representative depth for this project's context ceiling), old vs new:

| | Old (`q8_0/q8_0`, N=24) | New (`q4_0/q4_0`, N=11) | Change |
| --- | --- | --- | --- |
| Prefill | 1019.2 tok/s | 1233.5 tok/s | **+21.0%** |
| Decode | 24.57 tok/s | 39.26 tok/s | **+59.8%** |
| VRAM | 7668 MiB | 7799 MiB | fits, ~393 MiB headroom |
| Quality (3/3 sentinels + code) | PASS | PASS | no regression |

Thread count (`-t 6/8/16` vs unset) made no measurable difference once CPU-resident layers dropped to 11 - the spread (39.9-47.3 tok/s across all four) was within run-to-run noise, so `-t` is intentionally still not passed anywhere in this project.

`model-profiles/qwen35-9b.sh` now sets `CACHE_TYPE_K`/`CACHE_TYPE_V="q4_0"` and `LLAMA_CPU_FFN_LAYERS_RECOMMENDED=11` as this profile's tested defaults - `install.sh` pre-fills the CPU-offload-layers prompt with 11 instead of the generic light-touch default of 2, and asks for explicit confirmation if you type something else (see `ask_confirm_override()` in `install.d/00-config.sh`). KV cache type itself isn't an interactive prompt at all - the failure mode above (a config that loads fine and only reveals itself as broken on a real long request) is exactly why that's a profile-author decision made after benchmarking, not something to ask a user blind.

### TurboQuant: considered, not adopted

Not adopted, revisit later. TurboQuant is a Google DeepMind KV-cache quantization technique (not weight quantization - some third-party pages describe it as ternary 1.58-bit weight quantization, which is a conflation with BitNet-style TQ formats and is wrong). The upstream llama.cpp integration ([PR #21089](https://github.com/ggml-org/llama.cpp/pull/21089), adding `tbq3_0`/`tbq4_0` KV cache types) was still open, not merged, and explicitly CPU-only as of this writing - using it on this project's CUDA setup would mean keeping the KV cache off the GPU (`--no-kv-offload`), which is the same slow path this project already documents and defaults off. Community CUDA forks exist but pinning to one breaks the "build llama.cpp from master" install path. Revisit if/when that PR (or a successor with CUDA kernels) merges to master. This project's default is `--cache-type-k q8_0 --cache-type-v q8_0` unless a model profile overrides it after its own benchmarking (see the Qwen speed sweep above for why that override isn't a safe thing to guess at blind).

## Quickstart

```bash
mkdir -p ~/llm-harness-switcher && cd ~/llm-harness-switcher
curl -fsSL https://github.com/Kinsman4249/llm-harness-switcher/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1
chmod +x install.sh uninstall.sh
./install.sh
```

This pulls a fresh tarball of the repo and overwrites everything in the directory unconditionally - no git working tree, so there's nothing to conflict with local edits. If you'd rather track history and use `git pull`, cloning with git works the same way, but then it's on you to keep that checkout clean (commit or stash any local edits before pulling) since a normal `git pull` refuses to overwrite files you've changed.

The installer is interactive: it asks about your container name, proxy port and token, which install mode you want (`classic` for the LiteLLM proxy path used by Claude Code/Zoo Code, or `kilo` for the single-provider Kilo Code flow, see below), which quantization to use, your card's usable VRAM and batch size (used to compute a recommended context length, see below), and whether to install desktop icons (one to toggle Claude Code routing, one to start the model itself). Every answer is saved to `~/.config/claude-local-setup.conf` and shown as the default on the next run, so re-running the installer is mostly pressing Enter.

If the container name you type doesn't match exactly one container, `install.sh` lists everything `distrobox list` actually sees and asks you to pick a number instead of guessing or failing outright - this also covers typing something ambiguous that matches more than one container. Whatever you pick is saved as the new default.

Changing quant, context length, or any of the tuning flags later doesn't require editing any file: re-run `install.sh`, pick different answers at the model-related prompts, and it regenerates `start-local-llama.sh` with your new choices, skipping the download if that quant is already on disk. You then start the server yourself and confirm it's up; the script prints real VRAM usage from `nvidia-smi` afterward, so you know immediately whether a given quant/context combination actually fits, rather than finding out from a truncated prompt mid-session.

## Updating

```bash
cd ~/llm-harness-switcher
curl -fsSL https://github.com/Kinsman4249/llm-harness-switcher/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1
```

Same command as the Quickstart - it just re-downloads and overwrites every file in the directory with whatever is on `main` now. Re-run `install.sh` afterward if the update touched anything you'd want re-applied (new prompts, changed defaults) - it's always safe to re-run, see above. Any local hand-edits to files in this directory get silently overwritten by this command, since it isn't a merge - if you've customized anything here, save a copy first.

## What's in this repo

```
.
|-- litellm_config.yaml            - LiteLLM proxy config template, local-only, no API key, no cloud entries
|-- claude-local-toggle.sh          - the switch: on/off/status; on starts the proxy on demand, edits ~/.claude/settings.json
|-- claude-local-desktop-toggle.sh  - wrapper for the desktop icon: flips state, confirms via notification
|-- claude-local-toggle.desktop     - desktop launcher entry
|-- start-litellm-proxy.sh          - on-demand proxy starter (classic mode), copied to $BIN_DIR by install.sh
|-- stop-litellm-proxy.sh           - on-demand proxy stopper (classic mode), called by claude-local-toggle.sh off
|-- start-local-model.sh            - kilo-mode launcher template: pick a model, start it, sync the Kilo provider
|-- start-local-model-desktop.sh    - kilo-mode desktop icon wrapper
|-- sync-local-model.sh             - kilo-mode: rewrites the single Kilo provider entry to the running model
|-- local-model.desktop            - kilo-mode desktop launcher entry
|-- distrobox-reminder.service      - optional systemd --user unit, login notification reminding you to stop the container before gaming. Not installed by default.
|-- install.sh                      - thin orchestrator: sources install.d/*.sh in order, then runs each step (--mode classic|kilo)
|-- install.d/                      - one function per install step (00-config.sh .. 90-summary.sh), see install.sh's header comment
`-- uninstall.sh                    - reverses install.sh: restores backed-up configs, removes generated files and desktop entries
```

`start-local-llama.sh` plus, if you installed the desktop icons, `model-session.sh`, `start-local-llama-desktop.sh`, and a `claude-local-start-model.desktop` launcher entry are all generated by `install.sh` into your `$BIN_DIR`/`$DESKTOP_DIR`; the kilo-mode templates above (`start-local-model.sh`, `sync-local-model.sh`, their desktop wrappers) are copied from this repo the same way. None of them are checked into the repo in final form, don't hand-edit them, re-run `install.sh` to change any of their flags. `local-model.Modelfile` (the old Ollama build recipe) has been removed: it's no longer read by anything now that the local runtime is `llama-server` instead of Ollama, and its quant/context reasoning lives on in `CHANGELOG.md`'s history if you want it. The classic-mode service units shipped in this repo (`litellm-ollama-box.service` and, optionally, `distrobox-reminder.service`) are a documented manual option only - `install.sh` installs neither of them and **auto-starts nothing** (see "No auto-start" below).

## How the switch works

`~/.claude/settings.json` supports an `env` block that both the Claude Code CLI and the VS Code/VSCodium extension read at startup. `claude-local-toggle.sh` adds or removes `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and an empty `ANTHROPIC_API_KEY` from that block:

```bash
claude-local-toggle.sh on       # route everything through the local proxy
claude-local-toggle.sh off      # back to normal Pro/Max subscription auth
claude-local-toggle.sh status   # check which state you're in
```

`on` starts the LiteLLM proxy on demand first (`start-litellm-proxy.sh`, if it isn't already up) and then refuses to flip the switch unless `llama-server` itself is also answering at its `/health` endpoint, not just the proxy (a proxy-only check would happily report success while pointed at a backend nobody started). If llama-server isn't reachable, `on` prints a reminder to run `start-local-llama.sh` and exits without touching `settings.json`. To deliberately test the clean-failure path described below, override with `claude-local-toggle.sh on --force`. `off` returns Claude Code to normal subscription auth and, since nothing else is using the proxy, stops it again (`stop-litellm-proxy.sh`).

After toggling, reload the VS Code/VSCodium window (`Ctrl+Shift+P` > "Reload Window"), the extension only reads `settings.json` at startup, not live.

If you installed the desktop icon, double-clicking it does the same thing without a terminal: it checks the current state, flips it, and confirms the new state with a desktop notification - including a critical notification instead of silent failure if it tried to turn on but `llama-server` wasn't reachable.

## No auto-start

Nothing starts at login anymore: `install.sh` no longer installs a systemd `--user` unit for the proxy and doesn't enable linger. Both the LiteLLM proxy and `llama-server` are launched on demand - the proxy when you run `claude-local-toggle.sh on` (or the starter script directly), the model when you run the launcher - and the proxy is torn down again by `claude-local-toggle.sh off`. The `.service` files shipped in this repo (`litellm-ollama-box.service` for the proxy, `distrobox-reminder.service` for a login reminder to stop the container before gaming) are kept as a documented manual option for people who want proxy-at-login, but neither is installed by default, so a fresh install has zero background processes until you actually use something.

## Using this with other VS Code AI extensions

Nothing above is actually Claude-Code-specific under the hood - `litellm_config.yaml` exposes a plain OpenAI-compatible endpoint at `http://localhost:$PROXY_PORT/v1` (port 4000 by default), authenticated with `Authorization: Bearer $PROXY_MASTER_KEY` (`sk-local-dev-key` by default - both saved in `~/.config/claude-local-setup.conf`), and a wildcard `model_name: "*"` entry that routes any model name a client sends to the same local backend. `claude-local-toggle.sh` exists only to work around Claude Code's own OAuth-vs-proxy conflict (see above); any other OpenAI-compatible client can just point at that URL directly, no toggle needed.

[Zoo Code](https://docs.zoocode.dev/providers/openai-compatible) is one such client (the community-maintained successor to Roo Code, which is no longer supported - same settings structure, so a prior Roo Code config carries over with minimal changes). In its settings, add a new API configuration profile: Provider "OpenAI Compatible", Base URL `http://localhost:4000/v1` (or your `$PROXY_PORT`), API Key your `$PROXY_MASTER_KEY`, Model any string you like (e.g. `local-llm` - the wildcard route ignores it). Zoo Code keeps this as one of several named profiles you switch between from its own dropdown, so this is a one-time setup, not something you redo per session.

To get `$PROXY_MASTER_KEY`'s actual value, read it back out of the config `install.sh` already saved it to:

```bash
grep PROXY_MASTER_KEY ~/.config/claude-local-setup.conf
```

That's `sk-local-dev-key` unless you set something else at the "Proxy auth token" prompt during `install.sh`. It's a local-only token gating access to your own machine's proxy port, not a real API key - the default is fine to keep unless something else on the host could reach that port.

That configuration is also stable across model changes: the port and key come from `~/.config/claude-local-setup.conf`, not from whichever `model-profiles/*.sh` is active, so re-running `install.sh` and picking a different numbered profile never requires touching Zoo Code's settings again - only `install.sh`'s own model-download step changes. (This is the same one-stable-endpoint-many-models pattern tools like [Continue](https://github.com/continuedev/continue) use for the same reason.)

Git operations (commit, push, tags) aren't a proxy concern at all - Zoo Code runs against your normal host workspace and uses whatever git identity/credentials are already configured there, same as any other tool. What controls whether it can run `git push`/`git tag` without a manual click each time is Zoo Code's own auto-approve setting for executing shell commands, not anything in this repo.

**Use the "OpenAI Compatible" provider type, not "LiteLLM"** if Zoo Code offers both - "LiteLLM" mode calls LiteLLM's own management API (e.g. `/v1/model/group/info`) to populate its model dropdown, a different endpoint than the plain `/v1/models` OpenAI-Compatible mode uses, and that management endpoint can 404 depending on your LiteLLM version even when the proxy itself is healthy and reachable.

### Kilo Code CLI

[Kilo Code](https://kilo.ai/docs/code-with-ai/platforms/cli) is a separate terminal-based client, not a VS Code extension - `claude-local-toggle.sh` never touches it (that script only ever edits `~/.claude/settings.json`, which Kilo does not read). How you point Kilo at your local model depends on which install mode you chose.

#### Kilo mode (`install.sh --mode kilo`) - single auto-synced provider

`--mode kilo` installs a self-contained alternative to the classic LiteLLM switcher: instead of routing many models through one proxy endpoint with a model dropdown, it manages a **single** Kilo provider (`local-model`) and rewrites that provider's one model entry to whatever is currently running. This matches how Kilo's own schema is shaped - a `provider.<id>.models` map with per-model `tool_call`, `reasoning`/`modalities`, `limit`, and `options` fields - and avoids the "OpenAI Compatible vs LiteLLM" endpoint mismatch below entirely, because Kilo talks straight to the runtime's native OpenAI-compatible endpoint (`/v1`).

The whole flow is one script, installed to `~/.local/bin/start-local-model.sh` (also reachable via the "Start Local Model (Kilo)" desktop icon):

1. If a server is already healthy on the active runtime's port, it skips straight to re-syncing the provider config - a second click never restarts anything.
2. Otherwise it scans `MODEL_ROOT` (`~/models` by default) for GGUFs plus any `ollama list` entries, shows a numbered menu, and starts the chosen model on its runtime: llama.cpp (port 8080, profile flags built at runtime by sourcing the matched profile), ollama (11434), or vllm (8000). `start-local-model.sh --profile <stem>` skips the menu - this is also what the install step itself runs to test the installation end to end.
3. It waits on the runtime's health endpoint, smoke-tests one tiny completion through `/v1`, then runs **`sync-local-model.sh`**, which rewrites the single provider entry to point at exactly this running model (context, output, reasoning/effort, and - for multimodal models like `gemma4-e2b.sh` - image attachment modalities).

"Single provider, one model at a time" is a deliberate constraint that keeps the config honest: there is exactly one `model: "local-model/<id>"` in `kilo.json`/`kilo.jsonc`, so Kilo always sees only what is really booted. No stale dropdown entries, no hand-edited `limit` numbers - every sync sets `limit.context`/`limit.output` from the profile's real `LLAMA_CTX_SIZE`/`LLAMA_N_PREDICT`. To switch models you re-run `start-local-model.sh`; to change defaults you re-run `install.sh`.

**Kilo-mode reasoning modes.** In kilo mode the Nemotron profiles (profiles that set `REASONING_MODES`) offer a reasoning-mode menu at launch, or `start-local-model.sh --profile <stem> --mode <name>` picks one non-interactively. The offered modes: `off` (thinking off - this project's tool-calling default), `on` (template default; unbounded thinking inside the output window), `budgeted` (thinking on with a `REASONING_BUDGET_DEFAULT`-token budget, e.g. 8192), `max` (thinking on, unlimited budget), and the legacy `effort`. Because a budget larger than the output window can never be spent, `budgeted`/`max` also raise the window to `REASONING_OUTPUT_MAX` (Kilo `limit.output`, e.g. 16384) - the sync writes `reasoning:true` for `on`/`budgeted`/`max`. Thinking ON is genuinely costly for a mechanical tool-calling loop (measured ~13x tokens / ~11x latency with no tool-call gain; see "Thinking mode"), so treat `max` as for dedicated reasoning tasks, not the default tool loop - `off` is the project default and a per-launch choice either way. Switching modes needs a llama-server restart: with a healthy server already running, `start-local-model.sh` refuses a conflicting `--mode` (it re-syncs the running server instead) - stop the server first, or use the desktop icon / `--profile` path at a fresh start. Note Kilo's Shift+Tab reasoning-effort variants cannot drive Nemotron: `--reasoning` is server-side, and Nemotron's chat template only exposes `enable_thinking` (on/off) plus a reasoning budget, not an effort level.

**Kilo caches provider config in its sqlite store and only re-reads this file on session start.** After any model change, reload/restart the Kilo Code window (the sync script prints this reminder). The whole target `~/.config/kilo/kilo.jsonc` is rewritten atomically (temp file + rename), and only the `provider.local-model` block and the top-level `model` pointer - your other settings and any `$schema` are preserved (that repo's `kilo.jsonc` is a symlink; the scripts write through it at the path Kilo reads).

#### Classic mode - point Kilo at the LiteLLM proxy

In `--mode classic` (the default), Kilo reads `~/.config/claude-local-setup.conf`-driven config too - but through the same proxy endpoint as the other clients, so the model dropdown comes from LiteLLM and `limit`/`reasoning` are hand-maintained. A minimal provider block:

```jsonc
{
  "model": "litellm/local-llm",
  "provider": {
    "litellm": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://localhost:4000/v1",
        "apiKey": "sk-local-dev-key"
      },
      "models": {
        "local-llm": {
          "name": "Local LLM (LiteLLM)",
          "tool_call": true,
          "limit": {
            "context": 131072,
            "output": 4096
          }
        }
      }
    }
  }
}
```

Two things about this config are easy to get wrong and fail silently or confusingly:

- **The API key.** Kilo's config format supports `{env:PROXY_MASTER_KEY}`-style env var references, but nothing in this project exports `PROXY_MASTER_KEY` (or any of `~/.config/claude-local-setup.conf`'s other values) into your shell environment - it is a config file, not sourced by anything. A `{env:...}` reference to a variable that is not actually set resolves to empty, so Kilo sends no `Authorization` header at all. Worse, LiteLLM's own auth-failure error path throws an unrelated `ModuleNotFoundError: No module named 'prisma'` (an optional dependency this project's master-key-only setup does not install) instead of a clean 401 when a request arrives with no key, so the symptom is a confusing 500 in the proxy's log (`~/.local/state/litellm-proxy.log`, or `journalctl --user -u litellm-ollama-box.service` if you installed the optional manual unit) - not an obviously auth-shaped error. Simplest fix: put the literal key value in the config directly, as above, rather than an `{env:...}` reference - safe for a global, non-repo config file, and this is a local-only token gating your own machine's proxy port anyway (see above), not a real API key. If you do want the `{env:...}` form, you have to export the variable yourself (e.g. in `.bashrc`) - this project will not do it for you.
- **`limit.context`/`limit.output`.** Same as Zoo Code's client-side settings above - Kilo cannot query `llama-server` for these, so they have to be kept in sync by hand with the active profile's real values (`LLAMA_CTX_SIZE` and `LLAMA_N_PREDICT` in `~/.config/claude-local-setup.conf`, or just read them straight out of the generated `~/.local/bin/start-local-llama.sh`'s `-c`/`-n` flags). They go stale silently - nothing errors if `kilo.jsonc` still says `32768` after you have re-run `install.sh` with a larger context, it just means Kilo may truncate or misjudge conversation length well before the model's real limit. (Kilo mode's `sync-local-model.sh` fixes exactly this staleness bug as a side effect of rewriting the provider on every model change.)

### Recommended client-side model settings per profile

Zoo Code's "OpenAI Compatible" provider asks you to describe the model's capabilities yourself (context window, image support, etc.) since it can't query an arbitrary OpenAI-compatible backend for them. These fields don't affect `llama-server` itself - they just tell Zoo Code (or another client) what to expect, so setting them wrong doesn't break inference, but it can cause premature truncation (window set too low) or a client sending image content the model can't use (image support set true on a text-only model).

Values below come straight from the matching `model-profiles/*.sh` `RECOMMENDED_CTX_8GB` (all measured/confirmed at 8GB VRAM, see that file's comments for the live test this number is from). "Not yet tested" means this project hasn't run that profile end-to-end yet (see "Known limitations") - don't trust a number that isn't listed until it's been updated here.

| Profile | Context Window Size | Image Support | Thinking default | Notes |
| --- | --- | --- | --- | --- |
| Nemotron 3 Nano 30B-A3B | `262144` | unchecked | off (`--disable-thinking`, the project default) | Text-only. Confirmed live 2026-07-25 (RTX 3080 8GB, UD-Q4_K_XL) and re-verified 2026-08-20 on a fresh CUDA `llama-server` build (commit `d59d455fd`) at the full 262144-token context: needle-in-haystack retrieval 3/3 at 131K and 200K depth via `/v1/chat/completions` (thinking off), tool-call gate 5/5 single-turn + 20/20 multi-turn with no VRAM drift. Note the MoE `--fit` offload holds most of the 30B model in **system RAM (~21 GiB RSS, peak ~22 GiB, ~1.3 GiB swap hit at 200K worst case)** so a long 256K session is tight on a 32 GB box - see `model-profiles/nemotron3-nano-30b.sh`. Thinking ON burned an entire 500-token budget on `reasoning_content` and never emitted a tool call at all; leave thinking off for Claude Code's tool-calling workload. |
| Nemotron 3 Nano 4B | `131072` | unchecked | off (`--disable-thinking`, the project default) | Text-only. Confirmed live on an RTX 3080 8GB - see `model-profiles/nemotron3-nano-4b.sh`. |
| Gemma 4 E4B | `131072` | leave unchecked anyway | off (project never sends the `<|think|>` trigger) | Model is multimodal upstream (text/image/audio), but this project only ever talks to it over a text-only endpoint (see "Multimodal weights" above) - `install.sh` never passes `--mmproj`, so there's no working image path even though the model card supports one. Not yet live-tested end-to-end (see "Known limitations") - treat the context number as the profile's stated target, not a confirmed measurement. |
| Gemma 4 E2B | not yet tested | leave unchecked anyway | off | Several profile values are UNVERIFIED placeholders (see "Choosing a model") - don't configure a client against this profile yet. |
| Qwen3.5-9B-MTP | `131072` | unchecked | off (`--chat-template-kwargs '{"enable_thinking":false}'`, forced explicitly - see "Thinking mode" above) | Confirmed live 2026-07-25 on an RTX 3080 8GB with UD-Q4_K_XL - see "Qwen3.5-9B-UD-Q4_K_XL speed sweep" above and `model-profiles/qwen35-9b.sh`. Reaching this context on 8GB still needs `--override-tensor` raised past this project's light default, but the profile's own tested value (N=11 with `q4_0/q4_0` KV cache, pre-filled by `install.sh`) is much lighter than the N=24 first measured with the old `q8_0/q8_0` default - about 60% faster decode at the same context, no accuracy drop. |
| Qwen3.5-9B-Defiant-Fable-MTP | `131072` | unchecked | off (`--reasoning off`, forced explicitly, same mechanism as Qwen3.5-9B-MTP above) | Same base model as Qwen3.5-9B-MTP, uncensored/de-refusal fine-tune (DavidAU) - not yet live-tested end-to-end (see "Choosing a model" above), don't trust the context number as confirmed until `model-profiles/qwen35-9b-defiant-fable.sh`'s `LLAMA_CPU_FFN_LAYERS_RECOMMENDED` has actually been run on real hardware. |

Leave **Enable R1 model parameters** unchecked for every profile above (that's for QwQ/R1-style models that 400 without it, not applicable here), **Enable Reasoning Effort** unchecked (thinking mode here is controlled by `install.sh --enable-thinking`/`--disable-thinking`, not a per-request client field - see "Thinking mode" above), and **Input/Output Price** at `0` (it's local, nothing is billed).

## Starting and stopping the model itself

The proxy running is not the same as the model being loaded. Nothing loads automatically at boot:

```bash
~/.local/bin/start-local-llama.sh
```

This launches `llama-server` inside the container with the flags `install.sh` generated it with (`-ngl 99`, flash attention, Q8 KV cache, speculative decoding via the MTP head, your chosen context/batch size). It runs in the foreground in whatever terminal you started it in, so you can watch its own log output directly.

`install.sh` itself pauses right before this step and prints the exact command (not just the script path) so you don't have to go find it, then waits for you to press Enter once the server's actually up before it checks `/health` and prints VRAM usage.

If you installed the desktop icons, "Start Local Model" does the same thing for you: double-click it and it opens `start-local-llama.sh` in its own terminal window (`konsole`, falling back to `gnome-terminal` or `xterm`), so starting the model day to day is one click instead of typing a command. If it's already running, it just tells you so instead of opening a second instance. If no terminal emulator can be found on your desktop session, it falls back to a notification containing the exact command to paste into a terminal yourself - this fallback path hasn't been exercised in practice since it depends on your specific desktop setup, so treat it as best-effort until you've confirmed the double-click actually opens a window.

That same icon also asks (in the terminal it opens, before starting `llama-server`) whether to install/launch [OpenHands](https://docs.openhands.dev/) - a dockerless, pip-installed AI coding agent CLI - inside the same container. Answer `n` (or just press Enter) to skip it and get the old model-only behavior. Answering `y` installs OpenHands the first time it's needed (needs Python 3.12 inside the container; `install.sh` doesn't install it up front, `start-openhands.sh` installs it on demand via `dnf` if missing) and opens it in its own terminal window, pre-pointed at this project's local proxy (`http://localhost:$PROXY_PORT/v1`, same wildcard `openai/local-llm` model string documented for Zoo Code above) via OpenHands' own `LLM_BASE_URL`/`LLM_API_KEY`/`LLM_MODEL` + `--override-with-envs` environment-variable config path, so it talks to your local model with no manual setup. Since this runs inside the same Distrobox container as `llama-server` rather than a separate Docker daemon, it works on an immutable host without needing Docker at all. Not yet exercised end-to-end on a real desktop session - if the install step fails, check `~/.local/state/openhands-install.log` for the full `pip`/`dnf` output.

The same pre-launch terminal also asks **"Also enable llama.cpp's browser chat UI on this server? [y/N]"** - a web chat UI at `http://localhost:$LLAMA_PORT` served by llama.cpp itself, so you can talk to the model in a browser without any other client. The launcher normally passes `--no-webui`; answering yes sets `LLAMA_ENABLE_WEBUI=yes`, which omits it for that run. This is the same server process, same port, same model already resident in VRAM either way - `--no-webui` only toggles whether llama.cpp serves its small static chat-UI assets alongside the OpenAI-compatible API on that one HTTP listener, so it never loads a second copy of the model or starts a second server. If you run `start-local-llama.sh` directly instead of through the desktop icon, prefix it with the env var: `LLAMA_ENABLE_WEBUI=yes ~/.local/bin/start-local-llama.sh`.

Model profiles that specify sampling defaults (`--temp`/`--top-p`/`--top-k`) get them set on the server itself, from the model card, rather than relying on whatever the client sends - see `model-profiles/*.sh`. Where a model card gives separate recipes for reasoning vs. tool-calling use (Nemotron 3 Nano 30B-A3B does: temp 1.0/top_p 1.0 for reasoning, temp 0.6/top_p 0.95 for tool calling), the profile uses whichever recipe matches how this project actually runs it - tool-calling, since thinking is off by default (see below) - not just whichever numbers appear first on the card. Gemma 4's "thinking mode" is deliberately left off: it's triggered by putting a `<|think|>` token at the start of the system prompt, not a CLI flag, and this project never injects it, since for a mechanical Claude Code tool-calling workload thinking output is pure added latency and token cost. Add the token to a system prompt yourself if you want it.

`start-local-llama.sh` also passes `-n $LLAMA_N_PREDICT` (default 4096, see `install.d/00-config.sh`), a hard cap on tokens per response. Neither `llama-server` nor Zoo Code's own client settings cap output length otherwise (Zoo Code is a same-settings-structure fork of Roo Code, which shipped `maxTokens: -1` and `includeMaxTokens: false`, i.e. no client-side cap sent - not independently re-confirmed against Zoo Code itself), so without this a degenerate or repeating generation - the token-repetition kind, not the identical-tool-call kind Zoo Code's own `consecutiveMistakeLimit` (default 3) already catches - would otherwise run until it filled the entire context instead of stopping on its own.

### Sizing your context window

`llama-server`'s VRAM use breaks down into three pieces: the model weights (fixed by your quant choice), a compute buffer (scales with batch size), and the KV cache (scales with context length). Running out of either of the first two before the third gets its share is the "out of context" symptom.

Qwen3.5-9B is a **hybrid** model, not a plain dense transformer and not MoE: of its 32 layers, only every 4th one (8 of 32) is full quadratic attention; the other 24 are linear/DeltaNet attention with a small fixed-size recurrent state that does not grow with context length (confirmed from [`Qwen/Qwen3.5-9B`'s `config.json`](https://huggingface.co/Qwen/Qwen3.5-9B/raw/main/config.json): `full_attention_interval: 4`, `num_key_value_heads: 4`, `head_dim: 256`). It also has **no MoE layers at all** - no `num_experts` field, `mlp_only_layers` is empty, dense `intermediate_size` throughout - so `--n-cpu-moe` would be a no-op on this model and isn't used. (An earlier draft of this project's docs incorrectly called it a hybrid dense+MoE model; that was wrong, corrected here.)

Because only 8 of 32 layers carry a real KV cache, the per-token cost is:

```
bytes/token = 2 (K+V) x num_kv_heads(4) x head_dim(256) x full_attention_layers(8) x bytes_per_element
            = 16384 x bytes_per_element
            = 16 KiB/token at q8_0 (1 byte/element, what this project always enables)
```

`install.sh` uses this formula to recommend a context length right after you pick a quant and batch size: `usable VRAM - quant weight size - estimated compute buffer - a fixed overhead reserve`, converted to tokens via the formula above, with a 15% safety margin. The compute-buffer estimate scales from a community-reported ~1508 MiB at batch 2048, which is also why **batch size matters more than it looks**: at batch 2048, that compute buffer alone can eat nearly all the room a ~7-8 GB card has left after a Q5-class quant, leaving next to nothing for KV cache - which reproduces exactly the "keep running out of KV cache" symptom. `install.sh` now defaults to batch 512 (llama.cpp's own default) for this reason; raise it only if the printed numbers show you have real headroom.

This is an estimate, not a guarantee - the compute-buffer figure is a rough scale-up from one reported measurement, not measured on your exact card/driver, and file sizes reported in "GB" are treated as already being GiB (`* 1024` to convert to MiB), the usual llama.cpp/HF convention. Treat the number `install.sh` proposes as a good starting point, then use the real VRAM reading it prints after you actually start the server (see above) to correct it if needed.

### Getting more headroom than that

Nothing overflows to RAM automatically: if a quant/context/batch combination doesn't fit VRAM, `llama-server` just fails to allocate it rather than spilling over on its own. Two real, opt-in ways to deliberately trade some speed for more room, both asked about right after the context-length prompt:

- **`--override-tensor` to force the last N layers' FFN weights onto CPU RAM (on by default, N=2).** This is the same underlying mechanism as `--n-cpu-moe` on MoE models, but with an important difference that changes how aggressive the default should be: on a MoE model, only one or two experts activate per token, so the CPU only does a little work per offloaded layer. Qwen3.5-9B has **no experts at all** (see above) - every offloaded layer's *entire* dense FFN matrix (three `4096x12288` matrices) gets read from RAM on every single token, every time. A [community guide to this exact technique](https://gist.github.com/DocShotgun/a02a4c0c0a57e43ff4f038b46ca66ae0) explicitly recommends *against* offloading dense FFN tensors for this reason, reserving the trick for MoE expert tensors only. Rough math at ~40 GB/s of typical dual-channel RAM bandwidth: each offloaded layer adds on the order of 2-3 ms per generated token, which is noticeable rather than free, unlike the MoE case (this is an estimate, not a measurement of your specific CPU/RAM). Because of that, `install.sh` defaults to a light touch - just 2 layers, enough to claw back a little VRAM without a real speed hit - rather than the more aggressive value you'd reach for on a MoE model. `install.sh` builds the `-ot` regex for you, e.g. for N=8: `--override-tensor "blk\.(24|25|26|27|28|29|30|31)\.ffn_(gate|up|down)\.weight=CPU"`. Raise it only if you genuinely need the room and can accept slower generation; 0 disables it entirely. **For a fast, Haiku-replacement-style workload, a smaller quant is usually the better way to free VRAM** - it keeps 100% of computation on GPU rather than trading per-token latency for headroom.
- **`--no-kv-offload` to keep the whole KV cache in system RAM instead of VRAM (off by default).** This decouples context length from VRAM almost entirely (bound by system RAM instead), but it's a real, ongoing cost for the *entire session*, not a one-time hit: every attention step now moves cache data over PCIe to system RAM and back, on every token. It's also not yet confirmed clean on every backend/model combination - there are [reported issues](https://github.com/ggml-org/llama.cpp/issues/24519) with some Vulkan/model pairings producing broken output. `install.sh` prompts for this with an explicit performance warning; only turn it on if you specifically need more context than VRAM can hold and can live with slower responses.

Neither option feeds back into the context-length recommendation above (that math assumes everything stays on GPU) - if you turn either on, check the real VRAM/behavior after starting the server, then re-run `install.sh` and raise the context or quant if there's more room than the recommendation assumed.

Before a GPU-heavy task like gaming:

```bash
distrobox stop ollama-box
```

This stops the whole container, proxy included. If local mode is toggled on when you do this, Claude Code will fail until you either restart the container or toggle back off.

## Debug logging

`litellm_config.yaml` in this repo is a *template*; `install.sh` copies it to `$CONFIG_HOME/litellm_config.yaml` (default `~/litellm_config.yaml`) with your master key patched in - edit the deployed copy, not the one in the repo, or your changes will be overwritten next time you re-run `install.sh`.

The template ships with two lines commented out at the bottom, under `general_settings`:

```yaml
general_settings:
  master_key: sk-local-dev-key
  # log_level: DEBUG
  # log_file: /var/log/litellm-proxy.log
```

Easiest path: answer "yes" to `install.sh`'s "Enable verbose LiteLLM proxy logging?" prompt, it uncomments `log_level: DEBUG` (and `log_file` too, if you also ask for disk logging) in the deployed config for you.

To do it by hand instead: uncomment `log_level: DEBUG` in the deployed file, restart the proxy (with the proxy on-demand, stop and start it again: `$BIN_DIR/stop-litellm-proxy.sh && $BIN_DIR/start-litellm-proxy.sh`), then watch the proxy's own log - `$HOME/.local/state/litellm-proxy.log` (disk logging, the named `log_file`) or, if you installed the optional manual `litellm-ollama-box.service` unit, `journalctl --user -u litellm-ollama-box.service -f`. This is what shows you the exact model-name string Claude Code sent, useful when a request fails to match any `model_name` entry.

## Manual verification

There's no automated test suite (this is glue between existing tools, not a library), so changes are verified manually:

1. `claude-local-toggle.sh status` reports the expected state after `on` and `off`.
2. With the proxy up and llama-server serving, a Claude Code session in local mode successfully completes a simple tool-calling task (file search, small edit) using the local model, confirmed via `log_level: DEBUG` in `litellm_config.yaml` showing the request routed to the local backend.
3. With llama-server stopped and local mode on, a request fails with a clean connection error rather than silently reaching a billed cloud endpoint.
4. With local mode off, Claude Code behaves identically to a machine that never installed this project.
5. `install.sh` re-run a second time with saved answers completes without prompting for anything already answered, and does not duplicate or corrupt existing systemd units or `settings.json` content.

Gemma-profile-specific, not yet performed (needs a live `llama-server` build and downloaded Gemma weights, neither present as of this refactor):

6. `install.sh` run with profile `qwen35-9b` produces a `start-local-llama.sh` with the same effective flags as before the model-profile refactor, given the same answers - the regression gate for that refactor.
7. `install.sh` run with profile `gemma4-e4b` downloads to `~/models/gemma4-e4b/`, resolves exactly one main GGUF, and either resolves a drafter or cleanly omits the spec flags.
8. Generated command contains no `--swa-full`, no `--mmproj`, and no `--spec-type` without a matching `-md` for Gemma profiles.
9. Server starts, `/health` returns 200, `nvidia-smi` shows measured VRAM.
10. PLE offload on vs off: record both VRAM figures here once measured.
11. Coherence check per "Per-Layer Embeddings" above passes.
12. Proxy smoke test returns real text.
13. A real Claude Code session in local mode completes a file-search and a small edit using tool calls, on a Gemma profile.

## Known limitations

- Whether `notify-send` on your specific desktop session honors `urgency=critical` and stays up until clicked, rather than timing out, isn't confirmed against every notification daemon.
- `litellm_config.yaml` uses a wildcard `model_name: "*"` entry (confirmed working against LiteLLM 1.93.0), so any model string Claude Code sends routes to the local backend - a future Claude Code release using a new dated ID no longer breaks this. Enable `log_level: DEBUG` in the config if you want to see what's actually arriving.
- This project assumes an existing Distrobox container with working GPU passthrough. `install.sh` checks that the container exists and exits with an error if it doesn't, it does not attempt to create or configure one, since getting GPU passthrough right on container creation isn't something worth guessing at silently. It does build `llama-server` itself inside the container if missing, but assumes CUDA/driver access already works there (e.g. Ollama or another GPU workload has run in it before).
- Starting the model server is still a manual step (open a terminal, run `start-local-llama.sh`) rather than systemd-managed; backgrounding a long-running process inside a `distrobox enter -- bash -lc` exec session is unreliable (the container runtime can tear it down when that session exits), see `todo.md`.
- The Gemma 4 profiles are not verified end-to-end - see "Choosing a model" above. Several values in `model-profiles/gemma4-e2b.sh` and `model-profiles/gemma4-e4b.sh` are placeholders pending a live-build check, and `install.sh` treats them as "unavailable" rather than guessing.
- The Gemma KV-cache probe (`KV_MODEL=probe`, `--fit on`) greps the server's own log for its measured context size using an `n_ctx` pattern that hasn't been confirmed against a real `llama-server` log format - if it prints nothing useful, check `~/.local/state/llama-server.log` directly.

## License

GNU General Public License v3.0 - see `LICENSE`.
