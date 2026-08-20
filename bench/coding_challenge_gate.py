#!/usr/bin/env python3
"""Coding-challenge agentic gate: run one hard cross-file coding task against a
live local model over its /v1/chat/completions tool path and record the model's
proposed solution for the grader.

This harness mirrors benchmark/tool_gate.py's tool schemas and request shape and
bench/multiturn_gate.py's agentic loop / VRAM+RSS drift helpers, but the job is
different: it feeds the model a single deliberately ambiguous, multi-file coding
spec, lets it explore a hermetic repo snapshot with grep/read_file, and captures
the first turn that returns clean text as the model's proposed solution. It never
applies or runs that solution - grading happens in coding_challenge_grade.py on
the saved transcript.

The tools read from <repo_root>, a hermetic snapshot the wrapper prepares under
bench/_challenge_repo/ so the model sees a stable tree. Nothing here writes to or
mutates the real working tree.

Usage: coding_challenge_gate.py <label> <repo_root> [port]
  label        e.g. "nemotron-30b-effort-challenge"
  repo_root    hermetic snapshot the tools read from (must contain _snapshot_head)
  port         llama-server port (default 8080)

Server must already be running on the profile's port (the wrapper enforces that).
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

label = sys.argv[1]
repo_root = sys.argv[2]
port = sys.argv[3] if len(sys.argv) > 3 else "8080"

MAX_TURNS = 12
MAX_TOOLS = 25
MAX_TOKENS = 4000  # matches the challenge spec; gives room for a proposed diff
MAX_TOOL_CHARS = 20000  # bound one tool result so a broad grep cannot blow context

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "grep",
            "description": "Search a file or directory for a regex pattern and return matching lines.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "regex to match"},
                    "path": {"type": "string", "description": "file or dir to search"},
                },
                "required": ["pattern", "path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a file and return its contents.",
            "parameters": {
                "type": "object",
                "properties": {
                    "filename": {"type": "string"},
                },
                "required": ["filename"],
            },
        },
    },
]

SYSTEM = ("You are an automated code agent. You have grep and read_file tools. "
          "When asked to find or inspect code, always call the appropriate tool. "
          "Your reply should be exactly one tool call - no prose.")

CHALLENGE_SPEC = """Feature: "effort" reasoning-mode override for the Kilo provider path.

Background: start-local-model.sh resolves the reasoning mode as
--mode > interactive menu > saved REASONING_MODE. A profile's
REASONING_MODES lists the modes it offers (e.g. off,on,budgeted,max).
Mode resolution is runtime-only; REASONING_MODE in the sourced profile
is the pre-selected default and is never rewritten by a session choice.
A mode change ALWAYS requires a llama-server restart on the same port.

Task: add support for a new mode name "effort:<N>". When the user
passes --mode effort:<N>:
  1. start-local-model.sh must accept it and validate that the profile's
     REASONING_MODES actually contains "effort" (a bare token; the <N> is a
     per-call budget, not a distinct mode). Reject unlisted names with an
     error, exactly like the existing unknown --mode path.
  2. The resolved mode must map to llama-server as
     "--reasoning on --reasoning-effort <N>" for this run, and must raise
     the output window to REASONING_OUTPUT_MAX (same as budgeted/max).
  3. sync-local-model.sh must set the Kilo provider's "reasoning" field to
     encode this mode so Kilo's own effort selector matches (mirror how the
     existing budgeted/max modes encode a budget there).

Constraint: do NOT change any other behavior. In particular, a mode change
still requires a restart on the same port, and the profile's REASONING_MODE
default field must still never be rewritten by a session choice.
"""

messages = [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": CHALLENGE_SPEC}]
usage = {"prompt_tokens": 0}


def gpu_mem():
    """nvidia-smi used/total MiB, or (None, None) if nvidia-smi is unavailable."""
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total",
                              "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=10).stdout.strip()
        used, total = out.replace(" ", "").split(",")
        return int(used), int(total)
    except Exception:  # noqa: BLE001 - headless/absent GPU must not abort a run
        return None, None


def server_rss_mib():
    """llama-server VmRSS MiB, or None if no llama-server process is found."""
    try:
        out = subprocess.run(["pgrep", "-f", "bin/llama-server"], capture_output=True, text=True, timeout=10).stdout.split()
        if not out:
            return None
        for line in open(f"/proc/{out[0]}/status"):
            if line.startswith("VmRSS"):
                return int(line.split()[1]) // 1024
    except Exception:  # noqa: BLE001
        return None
    return None


def chat(messages_list):
    payload = {
        "model": label, "messages": messages_list, "tools": TOOLS,
        "max_tokens": MAX_TOKENS, "temperature": 0.6, "top_p": 0.95,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.loads(resp.read())


def resolve_tool(name, args):
    """Resolve a single tool call against the hermetic repo_root snapshot.
    Returns ("ok", content_text) or ("error", message).

    Tool results are BOUNDED so a pathological grep (e.g. matching most of the
    tree with a broad regex) cannot balloon the context and overflow the
    server's window on the next turn. Real agentic harnesses truncate tool
    output for the same reason."""
    def bounded(text):
        if len(text) > MAX_TOOL_CHARS:
            return (text[:MAX_TOOL_CHARS] +
                    f"\n...[truncated {len(text) - MAX_TOOL_CHARS} more chars]")
        return text

    base = os.path.abspath(repo_root)
    try:
        if name == "grep":
            pattern = args.get("pattern", "")
            path = args.get("path", ".")
            target = os.path.join(base, path.strip("/")) if not os.path.isabs(path) else os.path.join(base, path.strip("/"))
            # Keep the target under the snapshot; refuse escapes.
            target = os.path.normpath(target)
            if not (target == base or target.startswith(base + os.sep)):
                return "error", "path outside snapshot"
            if os.path.isdir(target):
                hay = []
                for root, _dirs, files in os.walk(target):
                    for f in files:
                        hay.append(os.path.join(root, f))
            elif os.path.isfile(target):
                hay = [target]
            else:
                return "ok", "no matches"
            out = []
            for p in hay:
                try:
                    with open(p, "r", errors="replace") as fh:
                        for i, line in enumerate(fh, 1):
                            if re.search(pattern, line):
                                out.append(f"{os.path.relpath(p, base)}:{i}:{line.rstrip()}")
                except OSError:
                    continue
            return ("ok", bounded("\n".join(out) if out else "no matches"))
        elif name == "read_file":
            filename = args.get("filename", "")
            target = filename if os.path.isabs(filename) else os.path.join(base, filename)
            target = os.path.normpath(target)
            if not (target == base or target.startswith(base + os.sep)):
                return "error", "path outside snapshot"
            with open(target, "r", errors="replace") as fh:
                return "ok", bounded(fh.read())
        else:
            return "error", f"unknown tool {name!r}"
    except OSError as e:
        return "error", f"{e}"
    except Exception as e:  # noqa: BLE001 - never crash the loop on a bad tool arg
        return "error", str(e)


def run(_label, _repo_root):
    vram0, tot = gpu_mem()
    rss0 = server_rss_mib()
    t0 = time.time()
    tools_used = 0
    turns_used = 0
    usage = {"prompt_tokens": 0}
    stop_error = None
    solution = None
    emitted_tool_then_text = False
    transcript = []

    for turn in range(1, MAX_TURNS + 1):
        turns_used = turn
        try:
            r = chat(messages)
        except Exception as e:  # noqa: BLE001 - a bad turn must not crash the harness
            transcript.append({"role": "error", "content": str(e)})
            stop_error = str(e)
            print(f"turn {turn}: REQUEST ERROR {e}")
            break
        choice = r["choices"][0]
        msg = choice.get("message", {})
        content = msg.get("content", "") or ""
        tool_calls = msg.get("tool_calls") or []
        usage = r.get("usage", usage)
        names = [tc["function"]["name"] for tc in tool_calls if tc.get("function")]
        finish = choice.get("finish_reason", "")
        has_call = bool(names) and finish == "tool_calls"

        # Record the raw assistant message in the transcript before resolving.
        transcript.append({"role": "assistant", "content": content,
                           "tool_calls": tool_calls, "finish_reason": finish})

        if has_call:
            tools_used += len(tool_calls)
            result_msgs = [{"role": "assistant", "content": content, "tool_calls": tool_calls}]
            for idx, tc in enumerate(tool_calls):
                # llama-server requires a non-null tool_call_id on the result
                # message; synthesize one if the model omitted it.
                call_id = tc.get("id") or f"call_{turn}_{idx}"
                try:
                    raw = tc["function"]["arguments"]
                    fn_args = json.loads(raw) if raw else {}
                except Exception:  # noqa: BLE001
                    fn_args = {}
                status, result = resolve_tool(tc["function"]["name"], fn_args)
                result_msgs.append({"role": "tool", "tool_call_id": call_id,
                                    "content": json.dumps({"result": result})})
                transcript.append({"role": "tool", "tool_call_id": call_id,
                                   "name": tc["function"]["name"], "status": status,
                                   "result": result})
            messages.extend(result_msgs)
            print(f"turn {turn}: tool_call tools={names} prompt_tokens={usage.get('prompt_tokens')}")
            # A turn that ends in a tool call but ALSO carries prose surfaced as
            # text: we flag emitted_tool_then_text and, if the prose is later
            # seen as a solution, note the flag. We do NOT take this prose as
            # the solution yet - the loop continues while tools are still being
            # issued. This mirrors multiturn_gate.py's clean-content rule.
            if tools_used >= MAX_TOOLS:
                print(f"tool-call budget exhausted after {tools_used} calls")
                break
            if content.strip():
                emitted_tool_then_text = True
            continue

        if content.strip():
            solution = content
            print(f"turn {turn}: clean_solution prompt_tokens={usage.get('prompt_tokens')}")
            break

        # No tool call and no clean content: degenerate turn (leaked prose
        # already handled above as a tool call; here it is empty).
        print(f"turn {turn}: BAD (no tool call, no content) finish={finish}")
        break

    vram1, _ = gpu_mem()
    rss1 = server_rss_mib()
    elapsed = time.time() - t0

    head = ""
    head_file = os.path.join(repo_root, "_snapshot_head")
    if os.path.isfile(head_file):
        with open(head_file) as fh:
            head = fh.read().strip()

    record = {
        "label": label,
        "repo_head": head,
        "repo_root": repo_root,
        "spec": CHALLENGE_SPEC,
        "max_tokens": MAX_TOKENS,
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens", 0),
        "elapsed_s": round(elapsed, 1),
        "turns_used": turns_used,
        "tools_used": tools_used,
        "emitted_tool_then_text": emitted_tool_then_text,
        "stop_error": stop_error,
        "has_solution": solution is not None,
        "solution": solution,
        "vram_start_mib": vram0,
        "vram_end_mib": vram1,
        "vram_total_mib": tot,
        "rss_start_mib": rss0,
        "rss_end_mib": rss1,
        "transcript": transcript,
    }

    resultfile = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              f"coding_challenge_{label}.run.json")
    with open(resultfile, "w") as fh:
        json.dump(record, fh, indent=2)
    print(f"\nRESULT [{label}] turns={turns_used} tools={tools_used} "
          f"solution={'yes' if solution else 'NO'}")
    print(f"final prompt_tokens={usage.get('prompt_tokens')} elapsed={record['elapsed_s']}s")
    print(f"VRAM start={vram0}MiB end={vram1}MiB (total {tot}MiB)")
    print(f"RSS start={rss0}MiB end={rss1}MiB")
    print(f"saved: {resultfile}")
    print("PASS-TRANSCRIPT" if solution else "NO-SOLUTION")
    sys.exit(0 if solution else 1)


if __name__ == "__main__":
    run(label, repo_root)