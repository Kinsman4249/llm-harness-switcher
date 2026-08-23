# Installation

Covers requirements, the interactive installer, the two install modes, how to
update, what's in the repo, and the project's no-auto-start stance.

- Up: [README](../README.md) | Next: [Models](models.md) | See also:
  [Usage](usage.md), [Context sizing](context-sizing.md),
  [Troubleshooting](troubleshooting.md)

## Requirements

- A Linux host with [Distrobox](https://github.com/89luca89/distrobox) and an
  NVIDIA-capable container (GPU passthrough already working). Built and tested
  on Bazzite (KDE Plasma), but the mechanism (systemd `--user` units calling
  into `distrobox enter`) has no Bazzite-specific dependency and should work on
  any distro with Distrobox and systemd.
- `llama-server` from [llama.cpp](https://github.com/ggml-org/llama.cpp) built
  inside that container. `install.sh` builds it automatically (clones the repo,
  builds with CUDA) if it isn't already on `$PATH` there.
- [LiteLLM](https://docs.litellm.ai) (`pip install 'litellm[proxy]'`) installed
  inside that container.
- Claude Code, used either via the CLI or the VS Code/VSCodium extension.
- Roughly 8 GB of VRAM headroom to run any of the supported models at a
  reasonable quant and context length.

## Quickstart

```bash
mkdir -p ~/llm-harness-switcher && cd ~/llm-harness-switcher
curl -fsSL https://github.com/Kinsman4249/llm-harness-switcher/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1
chmod +x install.sh uninstall.sh
./install.sh
```

This pulls a fresh tarball of the repo and overwrites everything in the
directory unconditionally - no git working tree, so there's nothing to conflict
with local edits. If you'd rather track history and use `git pull`, cloning
with git works the same way, but then it's on you to keep that checkout clean
(commit or stash any local edits before pulling) since a normal `git pull`
refuses to overwrite files you've changed.

## What the installer asks

`install.sh` is interactive. It asks about:

- your container name,
- proxy port and token,
- which install mode you want (`classic` for the LiteLLM proxy path used by
  Claude Code/Zoo Code, or `kilo` for the single-provider Kilo Code flow - see
  [Usage: install modes](usage.md#install-modes)),
- which model profile and quantization to use ([Models](models.md)),
- your card's usable VRAM and batch size (used to compute a recommended
  context length - see [Context sizing](context-sizing.md)),
- whether to install desktop icons (one to toggle Claude Code routing, one to
  start the model itself).

Every answer is saved to `~/.config/claude-local-setup.conf` and shown as the
default on the next run, so re-running the installer is mostly pressing Enter.

If the container name you type doesn't match exactly one container, `install.sh`
lists everything `distrobox list` actually sees and asks you to pick a number
instead of guessing or failing outright - this also covers typing something
ambiguous that matches more than one container. Whatever you pick is saved as
the new default.

Changing quant, context length, or any of the tuning flags later doesn't
require editing any file: re-run `install.sh`, pick different answers at the
model-related prompts, and it regenerates `start-local-llama.sh` with your new
choices, skipping the download if that quant is already on disk. You then start
the server yourself and confirm it's up; the script prints real VRAM usage from
`nvidia-smi` afterward, so you know immediately whether a given quant/context
combination actually fits, rather than finding out from a truncated prompt
mid-session.

## Install modes

- **`classic` (default)** - the LiteLLM proxy path used by Claude Code and Zoo
  Code. A proxy exposes one OpenAI-compatible endpoint; `claude-local-toggle.sh`
  flips Claude Code onto it. See [Usage: the switch](usage.md#the-switch) and
  [Usage: Zoo Code](usage.md#zoo-code).
- **`kilo`** - a self-contained alternative: a **single** Kilo Code provider
  (`local-model`) whose one model entry is rewritten to whatever model is
  currently running. See [Usage: Kilo mode](usage.md#kilo-mode).

## Updating

```bash
cd ~/llm-harness-switcher
curl -fsSL https://github.com/Kinsman4249/llm-harness-switcher/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1
```

Same command as the Quickstart - it just re-downloads and overwrites every file
in the directory with whatever is on `main` now. Re-run `install.sh` afterward
if the update touched anything you'd want re-applied (new prompts, changed
defaults) - it's always safe to re-run, see above. Any local hand-edits to
files in this directory get silently overwritten by this command, since it
isn't a merge - if you've customized anything here, save a copy first.

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

`start-local-llama.sh` plus, if you installed the desktop icons,
`model-session.sh`, `start-local-llama-desktop.sh`, and a
`claude-local-start-model.desktop` launcher entry are all generated by
`install.sh` into your `$BIN_DIR`/`$DESKTOP_DIR`; the kilo-mode templates above
(`start-local-model.sh`, `sync-local-model.sh`, their desktop wrappers) are
copied from this repo the same way. None of them are checked into the repo in
final form, don't hand-edit them, re-run `install.sh` to change any of their
flags. The classic-mode service units shipped in this repo
(`litellm-ollama-box.service` and, optionally, `distrobox-reminder.service`)
are a documented manual option only - `install.sh` installs neither of them and
**auto-starts nothing** (see below).

## No auto-start

Nothing starts at login anymore: `install.sh` no longer installs a systemd
`--user` unit for the proxy and doesn't enable linger. Both the LiteLLM proxy
and `llama-server` are launched on demand - the proxy when you run
`claude-local-toggle.sh on` (or the starter script directly), the model when
you run the launcher - and the proxy is torn down again by
`claude-local-toggle.sh off`. The `.service` files shipped in this repo
(`litellm-ollama-box.service` for the proxy, `distrobox-reminder.service` for a
login reminder to stop the container before gaming) are kept as a documented
manual option for people who want proxy-at-login, but neither is installed by
default, so a fresh install has zero background processes until you actually
use something.