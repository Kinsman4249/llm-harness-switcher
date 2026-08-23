# Context sizing

How VRAM, context length, and batch size interact, how `install.sh` computes a
recommended context, and the opt-in ways to trade speed for more headroom.

- Up: [README](../README.md) | Prev: [Usage](usage.md) | Next:
  [Troubleshooting](troubleshooting.md) | See also: [Models](models.md)

## Sizing your context window

`llama-server`'s VRAM use breaks down into three pieces: the model weights
(fixed by your quant choice), a compute buffer (scales with batch size), and
the KV cache (scales with context length). Running out of either of the first
two before the third gets its share is the "out of context" symptom.

Qwen3.5-9B is a **hybrid** model, not a plain dense transformer and not MoE: of
its 32 layers, only every 4th one (8 of 32) is full quadratic attention; the
other 24 are linear/DeltaNet attention with a small fixed-size recurrent state
that does not grow with context length (confirmed from
[`Qwen/Qwen3.5-9B`'s `config.json`](https://huggingface.co/Qwen/Qwen3.5-9B/raw/main/config.json):
`full_attention_interval: 4`, `num_key_value_heads: 4`, `head_dim: 256`). It
also has **no MoE layers at all** - no `num_experts` field, `mlp_only_layers`
is empty, dense `intermediate_size` throughout - so `--n-cpu-moe` would be a
no-op on this model and isn't used.

Because only 8 of 32 layers carry a real KV cache, the per-token cost is:

```
bytes/token = 2 (K+V) x num_kv_heads(4) x head_dim(256) x full_attention_layers(8) x bytes_per_element
            = 16384 x bytes_per_element
            = 16 KiB/token at q8_0 (1 byte/element, what this project always enables)
```

`install.sh` uses this formula to recommend a context length right after you
pick a quant and batch size: `usable VRAM - quant weight size - estimated
compute buffer - a fixed overhead reserve`, converted to tokens via the
formula above, with a 15% safety margin. The compute-buffer estimate scales
from a community-reported ~1508 MiB at batch 2048, which is also why **batch
size matters more than it looks**: at batch 2048, that compute buffer alone can
eat nearly all the room a ~7-8 GB card has left after a Q5-class quant, leaving
next to nothing for KV cache - which reproduces exactly the "keep running out
of KV cache" symptom. `install.sh` now defaults to batch 512 (llama.cpp's own
default) for this reason; raise it only if the printed numbers show you have
real headroom.

This is an estimate, not a guarantee - the compute-buffer figure is a rough
scale-up from one reported measurement, not measured on your exact
card/driver, and file sizes reported in "GB" are treated as already being GiB
(`* 1024` to convert to MiB), the usual llama.cpp/HF convention. Treat the
number `install.sh` proposes as a good starting point, then use the real VRAM
reading it prints after you actually start the server to correct it if needed.

## Getting more headroom than that

Nothing overflows to RAM automatically: if a quant/context/batch combination
doesn't fit VRAM, `llama-server` just fails to allocate it rather than spilling
over on its own. Two real, opt-in ways to deliberately trade some speed for
more room, both asked about right after the context-length prompt:

- **`--override-tensor` to force the last N layers' FFN weights onto CPU RAM
  (on by default, N=2).** This is the same underlying mechanism as `--n-cpu-moe`
  on MoE models, but with an important difference that changes how aggressive
  the default should be: on a MoE model, only one or two experts activate per
  token, so the CPU only does a little work per offloaded layer. Qwen3.5-9B has
  **no experts at all** - every offloaded layer's *entire* dense FFN matrix
  (three `4096x12288` matrices) gets read from RAM on every single token, every
  time. A
  [community guide to this exact technique](https://gist.github.com/DocShotgun/a02a4c0c0a57e43ff4f038b46ca66ae0)
  explicitly recommends *against* offloading dense FFN tensors for this reason,
  reserving the trick for MoE expert tensors only. Rough math at ~40 GB/s of
  typical dual-channel RAM bandwidth: each offloaded layer adds on the order of
  2-3 ms per generated token, which is noticeable rather than free, unlike the
  MoE case (this is an estimate, not a measurement of your specific CPU/RAM).
  Because of that, `install.sh` defaults to a light touch - just 2 layers,
  enough to claw back a little VRAM without a real speed hit - rather than the
  more aggressive value you'd reach for on a MoE model. `install.sh` builds the
  `-ot` regex for you, e.g. for N=8:
  `--override-tensor "blk\.(24|25|26|27|28|29|30|31)\.ffn_(gate|up|down)\.weight=CPU"`.
  Raise it only if you genuinely need the room and can accept slower
  generation; 0 disables it entirely. **For a fast, Haiku-replacement-style
  workload, a smaller quant is usually the better way to free VRAM** - it keeps
  100% of computation on GPU rather than trading per-token latency for
  headroom.
- **`--no-kv-offload` to keep the whole KV cache in system RAM instead of VRAM
  (off by default).** This decouples context length from VRAM almost entirely
  (bound by system RAM instead), but it's a real, ongoing cost for the *entire
  session*, not a one-time hit: every attention step now moves cache data over
  PCIe to system RAM and back, on every token. It's also not yet confirmed
  clean on every backend/model combination - there are
  [reported issues](https://github.com/ggml-org/llama.cpp/issues/24519) with
  some Vulkan/model pairings producing broken output. `install.sh` prompts for
  this with an explicit performance warning; only turn it on if you
  specifically need more context than VRAM can hold and can live with slower
  responses.

Neither option feeds back into the context-length recommendation above (that
math assumes everything stays on GPU) - if you turn either on, check the real
VRAM/behavior after starting the server, then re-run `install.sh` and raise the
context or quant if there's more room than the recommendation assumed.

The default KV cache type is `--cache-type-k q8_0 --cache-type-v q8_0` unless a
model profile overrides it after its own benchmarking - see
[Models: benchmarks](models.md#benchmarks) for why that override isn't a safe
thing to guess at blind.

Before a GPU-heavy task like gaming:

```bash
distrobox stop ollama-box
```

This stops the whole container, proxy included. If local mode is toggled on
when you do this, Claude Code will fail until you either restart the container
or toggle back off.