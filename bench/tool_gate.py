#!/usr/bin/env python3
"""Task-7 gate: tool-call reliability for Nemotron 3 Nano 30B-A3B.

Sends a grep + read_file tool-call prompt (the mechanical prompt that matters
for Claude Code) via /v1/chat/completions, thinking off, 500-token budget,
and checks the model returns a well-formed OpenAI-style tool call with ZERO
leaked prose, N times.

Pass criteria (per the plan): N/N well-formed tool calls, no leaked narrative
text outside the tool call.

Usage: tool_gate.py <label> <reps> [port]
  label   e.g. "nemotron-30b-q8_0"
  reps    how many independent tool-call requests to run (default 5)
  port    llama-server port (default 8080)

Server must already be running with --temp 0.6 --top-p 0.95 --reasoning off
(the flags the profile's start script sets); the request sends temp/top-p
explicitly too and chat_template_kwargs enable_thinking:false to match the plan.
"""
import json
import sys
import urllib.request

label = sys.argv[1]
reps = int(sys.argv[2]) if len(sys.argv) > 2 else 5
port = sys.argv[3] if len(sys.argv) > 3 else "8080"

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

PROMPT = (
    "Use the grep tool to find every occurrence of the string 'flag_enable_all' "
    "in the file /repo/src/config.cpp, then use read_file to read the first "
    "10 lines of that file. Show the grep results first, then the file contents."
)

def request():
    payload = {
        "model": "nemotron3-nano-30b",
        "messages": [{"role": "user", "content": PROMPT}],
        "tools": TOOLS,
        "temperature": 0.6,
        "top_p": 0.95,
        "max_tokens": 500,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.loads(resp.read())

def grade_response(result):
    choice = result["choices"][0]
    msg = choice.get("message", {})
    content = msg.get("content", "") or ""
    tool_calls = msg.get("tool_calls") or []
    finish = choice.get("finish_reason", "")
    # well-formed: at least one tool_call with name+args, and no leaked prose
    # in content (content should be empty for a pure tool call)
    names = [tc["function"]["name"] for tc in tool_calls if tc.get("function")]
    args_ok = all(
        "arguments" in tc["function"] and tc["function"]["arguments"]
        for tc in tool_calls if tc.get("function")
    )
    leaked = bool(content.strip())
    return {
        "tool_call_names": names,
        "well_formed": bool(names) and args_ok and not leaked,
        "finish": finish,
        "leaked_prose": content.strip(),
    }

passed = 0
results = []
for i in range(1, reps + 1):
    try:
        r = request()
        g = grade_response(r)
    except Exception as e:  # noqa: BLE001 - report network/server failures as 'failed'
        g = {"tool_call_names": [], "well_formed": False, "finish": "ERROR", "leaked_prose": str(e)}
    results.append(g)
    if g["well_formed"]:
        passed += 1
    print(f"rep {i}: well_formed={g['well_formed']} tools={g['tool_call_names']} "
          f"finish={g['finish']} leaked={bool(g['leaked_prose'])}")
    if g["leaked_prose"]:
        print(f"  LEAKED PROSE: {g['leaked_prose'][:200]!r}")

print(f"\nRESULT [{label}] {passed}/{reps} well-formed tool calls")
for g in results:
    if not g["well_formed"]:
        print(f"  FAIL details: finish={g['finish']} tools={g['tool_call_names']}")

ok = passed == reps and reps > 0
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)