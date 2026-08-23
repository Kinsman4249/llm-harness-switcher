# llm-harness-switcher

An on/off switch for routing Claude Code through a local model instead of
your Anthropic Pro/Max subscription, with no API key anywhere and no cloud
fallback. When it's off, Claude Code behaves exactly as if this project
didn't exist, normal subscription auth, Sonnet and Opus available. When it's
on, every model Claude Code might call, main session or sub-agent, routes to
a local model (Qwen3.5-9B, Gemma 4, or Nemotron 3 Nano, your choice - see
[Choosing a model](docs/models.md#choosing-a-model)) running under
llama-server (llama.cpp's own server), meant for small, cheap tasks where you
don't want to spend Pro usage at all.

(Previously released as `claude-code-proxy-switcher`; the project now lives
at `Kinsman4249/llm-harness-switcher`.)

## Why this exists

Claude Code is agentic: a lot of what it does per session is mechanical (file
search, `grep`, listing directories, small reads) rather than reasoning-heavy.
Running that mechanical work through a frontier model is more capability than
the task needs. This project gives you a deliberate, visible switch to route
that kind of work to a local model instead, without touching your subscription
usage or ever requiring a billed API key.

It does not try to be a hybrid router that transparently falls back to cloud
when llama-server isn't running. Anthropic's April 2026 policy change blocking
subscription OAuth tokens in third-party proxies ruled out a fallback that
draws from Pro/Max usage instead of billed API usage. Rather than accept
surprise direct billing on the fallback path, this project has no cloud path
in its proxy config at all: local mode either uses your local model, or it
fails cleanly with a connection error. No middle ground, no accidental charges.

## Quickstart

```bash
mkdir -p ~/llm-harness-switcher && cd ~/llm-harness-switcher
curl -fsSL https://github.com/Kinsman4249/llm-harness-switcher/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1
chmod +x install.sh uninstall.sh
./install.sh
```

See [docs/installation.md](docs/installation.md) for what the installer asks,
the two install modes (`classic` and `kilo`), and how to update later.

## Documentation

The manual is split into chapters; start with the ones relevant to you.

- [docs/installation.md](docs/installation.md) - requirements, what the
  installer asks, `classic` vs `kilo` mode, updating, repo contents, no
  auto-start.
- [docs/models.md](docs/models.md) - choosing a model profile, the supported
  models, per-layer embeddings and other architecture notes, thinking mode,
  benchmarks, and recommended client-side settings.
- [docs/usage.md](docs/usage.md) - how the on/off switch works, using this
  with Zoo Code and Kilo Code (both modes), and starting/stopping the model
  itself.
- [docs/context-sizing.md](docs/context-sizing.md) - how VRAM, context length
  and batch size interact, and the opt-in ways to trade speed for more
  headroom.
- [docs/troubleshooting.md](docs/troubleshooting.md) - enabling debug logging,
  how changes are verified manually, and known limitations.

## License

GNU General Public License v3.0 - see `LICENSE`.