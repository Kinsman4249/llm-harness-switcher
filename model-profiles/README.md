# model-profiles/

One `.sh` file per supported model. Each is a shell fragment sourced by
`install.sh` (and, in kilo mode, by the generated `start-local-model.sh`)
after `MODEL_PROFILE` is chosen - it sets every model-specific default the
installer and launcher need. Only the example profile (`gemma4-e2b.sh`) is
committed here; git (this folder's `.gitignore`) deliberately ignores every
other `*.sh` so you can keep private profiles in the same place without
committing them. This project's other, live-tested profiles live in the
private presets repo `8gb-immutable-fedora-presets` (see install.sh's
`--presets-dir`), discovered but never auto-cloned.

## Authoring a profile

Copy `gemma4-e2b.sh` (or an existing profile from the presets repo) and edit
it. The filename stem becomes the profile id (`MODEL_PROFILE`, the folder
name under `$MODEL_ROOT`), so make it short and dash-lowercase, e.g.
`my-model-3b.sh`.

Field reference (all optional unless marked required):

| Field | Meaning / default |
| --- | --- |
| `PROFILE_NAME` (required) | Human-readable label shown in the install menu, e.g. "Qwen3.5-9B-MTP". |
| `HF_REPO_DEFAULT` | Hugging Face repo with this model's GGUF (llama.cpp runtime). |
| `GGUF_PATTERN_DEFAULT` | Quant fragment the menu rows are built from (see `QUANT_MENU`). |
| `MODEL_RUNTIME` | `llama.cpp` (default), `ollama`, or `vllm`. Everything llama.cpp-specific below is ignored for the other two. |
| `RUNTIME_PORT` | Override the per-runtime default port (llama.cpp 8080, ollama 11434, vllm 8000). |
| `OLLAMA_MODEL` | `"namespace/model"` for the ollama runtime; replaces the HF download entirely. |
| `VLLM_MODEL_ID` | HF id or local GGUF path for the vllm runtime; model files download on first `vllm serve`. |
| `MMPROJ_REPO` / `MMPROJ_PATTERN` | Multimodal projector: repo + filename fragment (`mmproj-F16` matches `mmproj-F16.gguf`). When both are set, install.sh downloads the projector and the launcher passes `--mmproj`, and the kilo model entry gets real image input (`attachment` + `modalities.input`). Leave both empty for text-only. |
| `REASONING_MODE` | `off` (default), `on`, or `effort`. `effort` uses `REASONING_EFFORT`. Off preserves a tool-calling workload's measured token/latency budget. |
| `REASONING_EFFORT` | `low` / `medium` / `high`, used when `REASONING_MODE=effort`. |
| `KILO_TOOL_CALL` / `KILO_TEMPERATURE` | `yes` (default) / `no` - whether the kilo model entry advertises tool calling / temperature support. |
| `KILO_MODEL_ID` | Optional kilo model id; defaults to the profile stem. |
| `KILO_MODEL_NAME` | Optional display name in Kilo; defaults to `PROFILE_NAME`. |
| `QUANT_MENU` | `"fragment|size_mib|description"` rows for the quant picker. `size_mib` feeds the context-length estimate (blank = "size UNVERIFIED"); llama.cpp-only. |
| `QUANT_MENU_INTRO` | Header line for the quant menu (may contain `\$HF_REPO`). |
| `N_LAYERS` | Layer count; used for the `--override-tensor` FFN-offload range. |
| `KV_MODEL` | `manual` (closed-form bytes/token, set `BYTES_PER_TOKEN`) or `probe` (let `--fit` size the KV cache, read the real number from the log). |
| `BYTES_PER_TOKEN` | KV bytes/token for `KV_MODEL=manual`. |
| `RECOMMENDED_CTX_8GB` | Live-tested context ceiling on an 8GB card; pre-fills the context prompt default. |
| `LLAMA_CPU_FFN_LAYERS_RECOMMENDED` | Live-tested CPU-FFN-offload count; pre-fills the headroom prompt (with `ask_confirm_override` friction to move away). |
| `DRAFT_REPO` / `DRAFT_PATTERN` | Separate drafter for `SPEC_MODE=draft-model` speculative decoding. |
| `SPEC_MODE` | `none` (default) / `self-mtp` / `draft-model`. `self-mtp` needs an MTP build (see `qwen35-9b`); `draft-model` needs `DRAFT_REPO`/`DRAFT_PATTERN`. |
| `CACHE_TYPE_K` / `CACHE_TYPE_V` | KV cache quant (default `q8_0`/`q8_0`; see the Qwen speed sweep in the main README before changing - mismatched pairs can silently collapse onto a slow path). |
| `NGL_MODE` | `fixed` (default, `-ngl 99`) or `fit` (leave `-ngl` unset so `--fit` places MoE experts itself - required for MoE models like Nemotron 3 Nano 30B-A3B). |
| `PLE_TENSOR_REGEX` | Regex for Per-Layer-Embedding tensors (Gemma); enables the cheap PLE-offload prompt. |
| `DEFAULT_TEMP` / `DEFAULT_TOP_P` / `DEFAULT_TOP_K` | Sampling defaults set on the server (empty = don't override). |
| `THINKING_KWARG_KEY` | Chat-template kwarg the model uses to toggle reasoning; every supported model uses `enable_thinking`. |
| `ARCH_NOTES` | One line explained in the generated start-script header. |

llama.cpp-only fields (`N_LAYERS`, KV sizing, `QUANT_MENU`, spec decoding,
sampling) are skipped entirely for `MODEL_RUNTIME=ollama|vllm` - the other
runtimes only use the runtime/port/context/reasoning/kilo-capability fields.

## Sizing and testing

Every number in the shipped `gemma4-e2b.sh` that is not live-tested carries
a `UNVERIFIED` comment on purpose - this project's rule is to fail loudly
(feature skipped, warning printed) rather than invent a llama-server flag or
filename it hasn't confirmed. Numbers like `RECOMMENDED_CTX_8GB`,
`LLAMA_CPU_FFN_LAYERS_RECOMMENDED`, `CACHE_TYPE_K/V`, and the `QUANT_MENU`
sizes should be measured (not extrapolated) on real hardware before you trust
them - see `bench/` for the methodology (e.g. `bench/qwen-bench.sh` and its
results notes), and the main README's "Manual verification" section for how
the shipped profiles were validated end-to-end.

## Runtime notes

- **llama.cpp** (default): install.sh builds `llama-server` (CUDA in
  distrobox, backend auto-detect native) and downloads the GGUF
  (`hf download --include '*<GGUF_PATTERN>*.gguf'`). The server serves the
  OpenAI-compatible API at `http://localhost:<port>/v1`.
- **ollama**: no HF download happens; `install.sh` (via the runtime-install
  stage) installs ollama and the profile's `OLLAMA_MODEL` is pulled with
  `ollama pull`. `ollama serve` runs in the background; `ollama run`
  loads the model on demand. API at `http://localhost:11434/v1`.
- **vllm**: not installed by default (heavy, CUDA-hungry). `vllm serve
  <VLLM_MODEL_ID> --port 8000 --max-model-len <ctx>` downloads on first
  serve. Best-effort on an 8GB card - document vllm profiles as such.

## Kilo model entry

The generated `sync-local-model.sh` builds the Kilo Code provider model entry
from the profile: `reasoning` from `REASONING_MODE`, `options.reasoningEffort`
from `REASONING_EFFORT`, `attachment`/`modalities` from `MMPROJ_*`, and
`limit.context` from `RECOMMENDED_CTX_8GB` / `LLAMA_CTX_SIZE` (output from
`LLAMA_N_PREDICT`).