# Troubleshooting

Enabling debug logging, how changes are verified manually, and known
limitations.

- Up: [README](../README.md) | Prev: [Context sizing](context-sizing.md) |
  See also: [Models](models.md), [Usage](usage.md)

## Debug logging

`litellm_config.yaml` in this repo is a *template*; `install.sh` copies it to
`$CONFIG_HOME/litellm_config.yaml` (default `~/litellm_config.yaml`) with your
master key patched in - edit the deployed copy, not the one in the repo, or
your changes will be overwritten next time you re-run `install.sh`.

The template ships with two lines commented out at the bottom, under
`general_settings`:

```yaml
general_settings:
  master_key: sk-local-dev-key
  # log_level: DEBUG
  # log_file: /var/log/litellm-proxy.log
```

Easiest path: answer "yes" to `install.sh`'s "Enable verbose LiteLLM proxy
logging?" prompt, it uncomments `log_level: DEBUG` (and `log_file` too, if you
also ask for disk logging) in the deployed config for you.

To do it by hand instead: uncomment `log_level: DEBUG` in the deployed file,
restart the proxy (with the proxy on-demand, stop and start it again:
`$BIN_DIR/stop-litellm-proxy.sh && $BIN_DIR/start-litellm-proxy.sh`), then
watch the proxy's own log - `$HOME/.local/state/litellm-proxy.log` (disk
logging, the named `log_file`) or, if you installed the optional manual
`litellm-ollama-box.service` unit, `journalctl --user -u
litellm-ollama-box.service -f`. This is what shows you the exact model-name
string Claude Code sent, useful when a request fails to match any `model_name`
entry.

## Manual verification

There's no automated test suite (this is glue between existing tools, not a
library), so changes are verified manually:

1. `claude-local-toggle.sh status` reports the expected state after `on` and
   `off`.
2. With the proxy up and llama-server serving, a Claude Code session in local
   mode successfully completes a simple tool-calling task (file search, small
   edit) using the local model, confirmed via `log_level: DEBUG` in
   `litellm_config.yaml` showing the request routed to the local backend.
3. With llama-server stopped and local mode on, a request fails with a clean
   connection error rather than silently reaching a billed cloud endpoint.
4. With local mode off, Claude Code behaves identically to a machine that never
   installed this project.
5. `install.sh` re-run a second time with saved answers completes without
   prompting for anything already answered, and does not duplicate or corrupt
   existing systemd units or `settings.json` content.

On top of this, new model profiles are validated end-to-end against the
rerunnable harnesses under `bench/` (tool-call gates, needle-in-haystack probes,
context-ceiling sweeps) before their numbers are trusted - see
[Models: benchmarks](models.md#benchmarks).

## Known limitations

- Whether `notify-send` on your specific desktop session honors
  `urgency=critical` and stays up until clicked, rather than timing out, isn't
  confirmed against every notification daemon.
- `litellm_config.yaml` uses a wildcard `model_name: "*"` entry (confirmed
  working against LiteLLM 1.93.0), so any model string Claude Code sends routes
  to the local backend - a future Claude Code release using a new dated ID no
  longer breaks this. Enable `log_level: DEBUG` in the config if you want to see
  what's actually arriving.
- This project assumes an existing Distrobox container with working GPU
  passthrough. `install.sh` checks that the container exists and exits with an
  error if it doesn't, it does not attempt to create or configure one, since
  getting GPU passthrough right on container creation isn't something worth
  guessing at silently. It does build `llama-server` itself inside the container
  if missing, but assumes CUDA/driver access already works there (e.g. Ollama or
  another GPU workload has run in it before).
- Starting the model server is still a manual step (open a terminal, run
  `start-local-llama.sh`) rather than systemd-managed; backgrounding a
  long-running process inside a `distrobox enter -- bash -lc` exec session is
  unreliable (the container runtime can tear it down when that session exits).
- The Gemma 4 profiles are not verified end-to-end - see
  [Models: choosing a model](models.md#choosing-a-model). Several values in
  `model-profiles/gemma4-e2b.sh` and `model-profiles/gemma4-e4b.sh` are
  placeholders pending a live-build check, and `install.sh` treats them as
  "unavailable" rather than guessing.
- The Gemma KV-cache probe (`KV_MODEL=probe`, `--fit on`) greps the server's own
  log for its measured context size using an `n_ctx` pattern that hasn't been
  confirmed against a real `llama-server` log format - if it prints nothing
  useful, check `~/.local/state/llama-server.log` directly.