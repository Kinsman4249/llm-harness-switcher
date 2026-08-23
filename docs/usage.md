# Usage

How the on/off switch works, using this with Zoo Code and Kilo Code (both
install modes), and starting/stopping the model itself.

- Up: [README](../README.md) | Prev: [Models](models.md) | Next:
  [Context sizing](context-sizing.md) | See also:
  [Installation](installation.md), [Troubleshooting](troubleshooting.md)

## Install modes

There are two ways to install, chosen interactively (and via `--mode`):

- **`classic` (default)** - the LiteLLM proxy path used by Claude Code and Zoo
  Code. The switch below flips Claude Code onto a proxy endpoint.
- **`kilo`** - a single auto-synced Kilo Code provider, described under
  [Kilo mode](#kilo-mode) below.

Full details of what each mode installs are in
[Installation: install modes](installation.md#install-modes).

## The switch

`~/.claude/settings.json` supports an `env` block that both the Claude Code CLI
and the VS Code/VSCodium extension read at startup. `claude-local-toggle.sh`
adds or removes `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and an empty
`ANTHROPIC_API_KEY` from that block:

```bash
claude-local-toggle.sh on       # route everything through the local proxy
claude-local-toggle.sh off      # back to normal Pro/Max subscription auth
claude-local-toggle.sh status   # check which state you're in
```

`on` starts the LiteLLM proxy on demand first (`start-litellm-proxy.sh`, if it
isn't already up) and then refuses to flip the switch unless `llama-server`
itself is also answering at its `/health` endpoint, not just the proxy (a
proxy-only check would happily report success while pointed at a backend
nobody started). If llama-server isn't reachable, `on` prints a reminder to
run `start-local-llama.sh` and exits without touching `settings.json`. To
deliberately test the clean-failure path, override with
`claude-local-toggle.sh on --force`. `off` returns Claude Code to normal
subscription auth and, since nothing else is using the proxy, stops it again
(`stop-litellm-proxy.sh`).

After toggling, reload the VS Code/VSCodium window (`Ctrl+Shift+P` > "Reload
Window"), the extension only reads `settings.json` at startup, not live.

If you installed the desktop icon, double-clicking it does the same thing
without a terminal: it checks the current state, flips it, and confirms the new
state with a desktop notification - including a critical notification instead
of silent failure if it tried to turn on but `llama-server` wasn't reachable.

## Using this with other VS Code AI extensions

Nothing above is actually Claude-Code-specific under the hood -
`litellm_config.yaml` exposes a plain OpenAI-compatible endpoint at
`http://localhost:$PROXY_PORT/v1` (port 4000 by default), authenticated with
`Authorization: Bearer $PROXY_MASTER_KEY` (`sk-local-dev-key` by default - both
saved in `~/.config/claude-local-setup.conf`), and a wildcard
`model_name: "*"` entry that routes any model name a client sends to the same
local backend. `claude-local-toggle.sh` exists only to work around Claude
Code's own OAuth-vs-proxy conflict; any other OpenAI-compatible client can
just point at that URL directly, no toggle needed.

### Zoo Code

[Zoo Code](https://docs.zoocode.dev/providers/openai-compatible) is one such
client (the community-maintained successor to Roo Code, which is no longer
supported - same settings structure, so a prior Roo Code config carries over
with minimal changes). In its settings, add a new API configuration profile:
Provider "OpenAI Compatible", Base URL `http://localhost:4000/v1` (or your
`$PROXY_PORT`), API Key your `$PROXY_MASTER_KEY`, Model any string you like
(e.g. `local-llm` - the wildcard route ignores it). Zoo Code keeps this as one
of several named profiles you switch between from its own dropdown, so this is
a one-time setup, not something you redo per session.

To get `$PROXY_MASTER_KEY`'s actual value, read it back out of the config
`install.sh` already saved it to:

```bash
grep PROXY_MASTER_KEY ~/.config/claude-local-setup.conf
```

That's `sk-local-dev-key` unless you set something else at the "Proxy auth
token" prompt during `install.sh`. It's a local-only token gating access to
your own machine's proxy port, not a real API key - the default is fine to
keep unless something else on the host could reach that port.

That configuration is also stable across model changes: the port and key come
from `~/.config/claude-local-setup.conf`, not from whichever
`model-profiles/*.sh` is active, so re-running `install.sh` and picking a
different numbered profile never requires touching Zoo Code's settings again -
only `install.sh`'s own model-download step changes.

Git operations (commit, push, tags) aren't a proxy concern at all - Zoo Code
runs against your normal host workspace and uses whatever git
identity/credentials are already configured there, same as any other tool.
What controls whether it can run `git push`/`git tag` without a manual click
each time is Zoo Code's own auto-approve setting for executing shell commands,
not anything in this repo.

**Use the "OpenAI Compatible" provider type, not "LiteLLM"** if Zoo Code offers
both - "LiteLLM" mode calls LiteLLM's own management API (e.g.
`/v1/model/group/info`) to populate its model dropdown, a different endpoint
than the plain `/v1/models` OpenAI-Compatible mode uses, and that management
endpoint can 404 depending on your LiteLLM version even when the proxy itself
is healthy and reachable.

See [Models: client-side settings](models.md#recommended-client-side-model-settings-per-profile)
for the capability fields to enter per profile.

### Kilo Code CLI

[Kilo Code](https://kilo.ai/docs/code-with-ai/platforms/cli) is a separate
terminal-based client, not a VS Code extension - `claude-local-toggle.sh` never
touches it (that script only ever edits `~/.claude/settings.json`, which Kilo
does not read). How you point Kilo at your local model depends on which install
mode you chose.

#### Kilo mode (`install.sh --mode kilo`) - single auto-synced provider

`--mode kilo` installs a self-contained alternative to the classic LiteLLM
switcher: instead of routing many models through one proxy endpoint with a
model dropdown, it manages a **single** Kilo provider (`local-model`) and
rewrites that provider's one model entry to whatever is currently running. This
matches how Kilo's own schema is shaped - a `provider.<id>.models` map with
per-model `tool_call`, `reasoning`/`modalities`, `limit`, and `options` fields
- and avoids the "OpenAI Compatible vs LiteLLM" endpoint mismatch entirely,
because Kilo talks straight to the runtime's native OpenAI-compatible endpoint
(`/v1`).

The whole flow is one script, installed to
`~/.local/bin/start-local-model.sh` (also reachable via the "Start Local Model
(Kilo)" desktop icon):

1. If a server is already healthy on the active runtime's port, it skips
   straight to re-syncing the provider config - a second click never restarts
   anything.
2. Otherwise it scans `MODEL_ROOT` (`~/models` by default) for GGUFs plus any
   `ollama list` entries, shows a numbered menu, and starts the chosen model on
   its runtime: llama.cpp (port 8080, profile flags built at runtime by
   sourcing the matched profile), ollama (11434), or vllm (8000).
   `start-local-model.sh --profile <stem>` skips the menu - this is also what
   the install step itself runs to test the installation end to end.
3. It waits on the runtime's health endpoint, smoke-tests one tiny completion
   through `/v1`, then runs **`sync-local-model.sh`**, which rewrites the single
   provider entry to point at exactly this running model (context, output,
   reasoning/effort, and - for multimodal models like `gemma4-e2b.sh` - image
   attachment modalities).

"Single provider, one model at a time" is a deliberate constraint that keeps
the config honest: there is exactly one `model: "local-model/<id>"` in
`kilo.json`/`kilo.jsonc`, so Kilo always sees only what is really booted. No
stale dropdown entries, no hand-edited `limit` numbers - every sync sets
`limit.context`/`limit.output` from the profile's real
`LLAMA_CTX_SIZE`/`LLAMA_N_PREDICT`. To switch models you re-run
`start-local-model.sh`; to change defaults you re-run `install.sh`.

**Kilo-mode reasoning modes.** In kilo mode the Nemotron-style profiles (those
that set `REASONING_MODES`) offer a reasoning-mode menu at launch, or
`start-local-model.sh --profile <stem> --mode <name>` picks one
non-interactively. The offered modes: `off` (thinking off - this project's
tool-calling default), `on` (template default; unbounded thinking inside the
output window), `budgeted` (thinking on with a `REASONING_BUDGET_DEFAULT`-token
budget, e.g. 8192), `max` (thinking on, unlimited budget), and the legacy
`effort`. Because a budget larger than the output window can never be spent,
`budgeted`/`max` also raise the window to `REASONING_OUTPUT_MAX` (Kilo
`limit.output`, e.g. 16384) - the sync writes `reasoning:true` for
`on`/`budgeted`/`max`. Thinking ON is genuinely costly for a mechanical
tool-calling loop (measured ~13x tokens / ~11x latency with no tool-call gain;
see [Thinking mode](models.md#thinking-mode)), so treat `max` as for dedicated
reasoning tasks, not the default tool loop - `off` is the project default and a
per-launch choice either way. Switching modes needs a llama-server restart:
with a healthy server already running, `start-local-model.sh` refuses a
conflicting `--mode` (it re-syncs the running server instead) - stop the server
first, or use the desktop icon / `--profile` path at a fresh start. Note Kilo's
Shift+Tab reasoning-effort variants cannot drive these models: `--reasoning` is
server-side, and the chat templates only expose `enable_thinking` (on/off) plus
a reasoning budget, not an effort level.

**Kilo caches provider config in its sqlite store and only re-reads this file
on session start.** After any model change, reload/restart the Kilo Code window
(the sync script prints this reminder). The whole target
`~/.config/kilo/kilo.jsonc` is rewritten atomically (temp file + rename), and
only the `provider.local-model` block and the top-level `model` pointer - your
other settings and any `$schema` are preserved (that repo's `kilo.jsonc` is a
symlink; the scripts write through it at the path Kilo reads).

#### Classic mode - point Kilo at the LiteLLM proxy

In `--mode classic` (the default), Kilo reads `~/.config/claude-local-setup.conf`-driven
config too - but through the same proxy endpoint as the other clients, so the
model dropdown comes from LiteLLM and `limit`/`reasoning` are hand-maintained.
A minimal provider block:

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

Two things about this config are easy to get wrong and fail silently or
confusingly:

- **The API key.** Kilo's config format supports `{env:PROXY_MASTER_KEY}`-style
  env var references, but nothing in this project exports `PROXY_MASTER_KEY`
  (or any of `~/.config/claude-local-setup.conf`'s other values) into your
  shell environment - it is a config file, not sourced by anything. An
  `{env:...}` reference to a variable that is not actually set resolves to
  empty, so Kilo sends no `Authorization` header at all. Worse, LiteLLM's own
  auth-failure error path throws an unrelated `ModuleNotFoundError: No module
  named 'prisma'` (an optional dependency this project's master-key-only setup
  does not install) instead of a clean 401 when a request arrives with no key,
  so the symptom is a confusing 500 in the proxy's log
  (`~/.local/state/litellm-proxy.log`) - not an obviously auth-shaped error.
  Simplest fix: put the literal key value in the config directly, as above,
  rather than an `{env:...}` reference - safe for a global, non-repo config
  file, and this is a local-only token gating your own machine's proxy port
  anyway, not a real API key. If you do want the `{env:...}` form, you have to
  export the variable yourself (e.g. in `.bashrc`) - this project will not do
  it for you.
- **`limit.context`/`limit.output`.** Same as Zoo Code's client-side settings -
  Kilo cannot query `llama-server` for these, so they have to be kept in sync
  by hand with the active profile's real values (`LLAMA_CTX_SIZE` and
  `LLAMA_N_PREDICT` in `~/.config/claude-local-setup.conf`, or just read them
  straight out of the generated `~/.local/bin/start-local-llama.sh`'s `-c`/`-n`
  flags). They go stale silently - nothing errors if `kilo.jsonc` still says
  `32768` after you have re-run `install.sh` with a larger context, it just
  means Kilo may truncate or misjudge conversation length well before the
  model's real limit. (Kilo mode's `sync-local-model.sh` fixes exactly this
  staleness bug as a side effect of rewriting the provider on every model
  change.)

## Starting and stopping the model itself

The proxy running is not the same as the model being loaded. Nothing loads
automatically at boot:

```bash
~/.local/bin/start-local-llama.sh
```

This launches `llama-server` inside the container with the flags `install.sh`
generated it with (`-ngl 99`, flash attention, Q8 KV cache, speculative
decoding via the MTP head, your chosen context/batch size). It runs in the
foreground in whatever terminal you started it in, so you can watch its own log
output directly.

`install.sh` itself pauses right before this step and prints the exact command
(not just the script path) so you don't have to go find it, then waits for you
to press Enter once the server's actually up before it checks `/health` and
prints VRAM usage.

If you installed the desktop icons, "Start Local Model" does the same thing for
you: double-click it and it opens `start-local-llama.sh` in its own terminal
window (`konsole`, falling back to `gnome-terminal` or `xterm`), so starting
the model day to day is one click instead of typing a command. If it's already
running, it just tells you so instead of opening a second instance. If no
terminal emulator can be found on your desktop session, it falls back to a
notification containing the exact command to paste into a terminal yourself.

That same icon also asks (in the terminal it opens, before starting
`llama-server`) whether to install/launch
[OpenHands](https://docs.openhands.dev/) - a dockerless, pip-installed AI
coding agent CLI - inside the same container. Answer `n` (or just press Enter)
to skip it and get the old model-only behavior. Answering `y` installs
OpenHands the first time it's needed (needs Python 3.12 inside the container;
`install.sh` doesn't install it up front, `start-openhands.sh` installs it on
demand via `dnf` if missing) and opens it in its own terminal window,
pre-pointed at this project's local proxy (`http://localhost:$PROXY_PORT/v1`,
same wildcard `openai/local-llm` model string documented for Zoo Code above) via
OpenHands' own `LLM_BASE_URL`/`LLM_API_KEY`/`LLM_MODEL` + `--override-with-envs`
environment-variable config path, so it talks to your local model with no
manual setup. Since this runs inside the same Distrobox container as
`llama-server` rather than a separate Docker daemon, it works on an immutable
host without needing Docker at all.

The same pre-launch terminal also asks **"Also enable llama.cpp's browser chat
UI on this server? [y/N]"** - a web chat UI at `http://localhost:$LLAMA_PORT`
served by llama.cpp itself, so you can talk to the model in a browser without
any other client. The launcher normally passes `--no-webui`; answering yes sets
`LLAMA_ENABLE_WEBUI=yes`, which omits it for that run. This is the same server
process, same port, same model already resident in VRAM either way - `--no-webui`
only toggles whether llama.cpp serves its small static chat-UI assets alongside
the OpenAI-compatible API on that one HTTP listener, so it never loads a second
copy of the model or starts a second server. If you run `start-local-llama.sh`
directly instead of through the desktop icon, prefix it with the env var:
`LLAMA_ENABLE_WEBUI=yes ~/.local/bin/start-local-llama.sh`.

Model profiles that specify sampling defaults (`--temp`/`--top-p`/`--top-k`)
get them set on the server itself, from the model card, rather than relying on
whatever the client sends - see `model-profiles/*.sh`. Where a model card gives
separate recipes for reasoning vs. tool-calling use (Nemotron 3 Nano 30B-A3B
does: temp 1.0/top_p 1.0 for reasoning, temp 0.6/top_p 0.95 for tool calling),
the profile uses whichever recipe matches how this project actually runs it -
tool-calling, since thinking is off by default - not just whichever numbers
appear first on the card.

`start-local-llama.sh` also passes `-n $LLAMA_N_PREDICT` (default 4096, see
`install.d/00-config.sh`), a hard cap on tokens per response. Neither
`llama-server` nor Zoo Code's own client settings cap output length otherwise
(Zoo Code is a same-settings-structure fork of Roo Code, which shipped
`maxTokens: -1` and `includeMaxTokens: false`, i.e. no client-side cap sent),
so without this a degenerate or repeating generation - the token-repetition
kind, not the identical-tool-call kind Zoo Code's own `consecutiveMistakeLimit`
(default 3) already catches - would otherwise run until it filled the entire
context instead of stopping on its own.

For the VRAM and context-length math behind choosing a quant/context, and the
opt-in ways to trade speed for more headroom, see
[Context sizing](context-sizing.md).