#!/usr/bin/env python3
"""Task-7 multi-turn gate: a ~20-turn agentic loop against Nemotron 3 Nano 30B-A3B
via /v1/chat/completions, thinking off, watching for VRAM/RAM drift/OOM.

The loop mirrors Claude Code's mechanical pattern: each assistant turn must end
in a well-formed tool call (grep/read_file); we then synthesize a tool result
message and continue. Context accumulates across turns. We record cumulative
prompt tokens and VRAM/RAM at the start and end.

Pass criteria (per plan): every turn ends in a correct tool call or clean
content; no server OOM/crash; context reaches the low-50K+ range.

Usage: multiturn_gate.py <label> <turns> <port>
"""
import json
import subprocess
import sys
import time
import urllib.request

label = sys.argv[1]
turns = int(sys.argv[2]) if len(sys.argv) > 2 else 20
port = sys.argv[3] if len(sys.argv) > 3 else "8080"

TOOLS = [
    {"type": "function", "function": {
        "name": "grep", "description": "Search a file for a regex and return matching lines.",
        "parameters": {"type": "object", "properties": {
            "pattern": {"type": "string"}, "path": {"type": "string"}},
            "required": ["pattern", "path"]}}},
    {"type": "function", "function": {
        "name": "read_file", "description": "Read a file and return its contents.",
        "parameters": {"type": "object", "properties": {"filename": {"type": "string"}},
            "required": ["filename"]}}},
]

SYSTEM = ("You are an automated code agent. You have grep and read_file tools. "
          "When asked to find or inspect code, always call the appropriate tool. "
          "Your reply should be exactly one tool call - no prose.")

messages = [{"role": "system", "content": SYSTEM}]
usage = {"prompt_tokens": 0}

def gpu_mem():
    out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total",
                          "--format=csv,noheader,nounits"], capture_output=True, text=True).stdout.strip()
    used, total = out.replace(" ", "").split(",")
    return int(used), int(total)

def server_rss_mib():
    pid = subprocess.run(["pgrep", "-f", "bin/llama-server"], capture_output=True, text=True).stdout.split()[0]
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("VmRSS"):
            return int(line.split()[1]) // 1024
    return 0

def chat(messages_list):
    payload = {
        "model": label, "messages": messages_list, "tools": TOOLS,
        "max_tokens": 200, "temperature": 0.6, "top_p": 0.95,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.loads(resp.read())

vram0, tot = gpu_mem()
rss0 = server_rss_mib()
ok_turns = 0

# A realistic Claude-Code-shaped tool result carries file contents / grep lines,
# which is what actually drives context to the 50-80K the plan targets in ~20
# turns. Build a growing config-file content fragment (~4KB) so per-turn context
# growth is large, mirroring grep/read_file returning real code.
def fake_result_lines(turn):
    block = []
    for i in range(120):  # ~120 lines of plausible config/source
        block.append(f"config_option_{turn}_{i} = enabled;  // tie:{turn}:{i} stable")
    return block


for t in range(1, turns + 1):
    user = (f"Action {t}: determine whether 'flag_{t}' is enabled by grepping "
            f"src/config/config.h and reading the relevant section. Report in one "
            f"line whether it is enabled or disabled, then move on.")
    messages.append({"role": "user", "content": user})
    r = chat(messages)
    choice = r["choices"][0]
    msg = choice.get("message", {})
    content = msg.get("content", "") or ""
    tool_calls = msg.get("tool_calls") or []
    usage = r.get("usage", usage)
    names = [tc["function"]["name"] for tc in tool_calls if tc.get("function")]
    has_call = bool(names) and choice.get("finish_reason") == "tool_calls"
    clean = bool(content.strip()) and not has_call  # clean content, no tool call
    if has_call:
        ok_turns += 1
        result_msgs = [{"role": "assistant", "content": content, "tool_calls": tool_calls}]
        for tc, lines in zip(tool_calls, [fake_result_lines(t)] * len(tool_calls)):
            result_msgs.append({"role": "tool", "tool_call_id": tc["id"],
                                "content": json.dumps({
                                    "result": f"flag_{t} {'ENABLED' if t % 2 else 'disabled'}",
                                    "lines": lines})})
        messages.extend(result_msgs)
        verdict = "tool_call"
    elif clean:
        ok_turns += 1
        verdict = "clean_content"
    else:
        verdict = "BAD"
    print(f"turn {t}: {verdict} tools={names} prompt_tokens={usage.get('prompt_tokens')}")

vram1, _ = gpu_mem()
rss1 = server_rss_mib()
print(f"\nRESULT [{label}] {ok_turns}/{turns} turns ended in correct tool call or clean content")
print(f"final prompt_tokens={usage.get('prompt_tokens')}")
print(f"VRAM start={vram0}MiB end={vram1}MiB (total {tot}MiB)")
print(f"RSS start={rss0}MiB end={rss1}MiB")
print("PASS" if ok_turns == turns else "FAIL")
sys.exit(0 if ok_turns == turns else 1)