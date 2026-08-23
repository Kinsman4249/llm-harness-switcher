#!/usr/bin/env python3
"""Grade a Nemotron haystack via llama-server's /v1/chat/completions endpoint
(thinking off), not the raw /completion endpoint - the plan's long-context gate
for this profile is the OpenAI-compatible chat path Claude Code uses.

Usage: query_and_grade_nemo.py <haystack_json> <label> [port]
Reads sentinels / expected values from the haystack JSON, POSTs the dump as a
single user message, and grades 3/3 sentinel retrieval + a combine_sentinels
def, mirroring bench/query_and_grade.py but on the chat endpoint.
"""
import json
import re
import subprocess
import sys
import time
import urllib.request

haystack_file = sys.argv[1]
label = sys.argv[2]
port = sys.argv[3] if len(sys.argv) > 3 else "8080"

with open(haystack_file) as fh:
    data = json.load(fh)

prompt = data["prompt"]
expected_sum = data["expected_sum"]
sentinels = data["sentinels"]
measured_tokens = data.get("measured_tokens", 0)

payload = {
    "messages": [{"role": "user", "content": prompt}],
    "temperature": 0.0,
    "max_tokens": 400,
    "chat_template_kwargs": {"enable_thinking": False},
}
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/v1/chat/completions",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
)

t0 = time.time()
with urllib.request.urlopen(req, timeout=3600) as resp:
    result = json.loads(resp.read())
elapsed = time.time() - t0

msg = result["choices"][0]["message"]
content = msg.get("content", "")
usage = result.get("usage", {})
prompt_tokens = usage.get("prompt_tokens", measured_tokens)

found = [str(s) in content for s in sentinels]
n_found = sum(found)
def_present = "def combine_sentinels" in content
# valid generated code: the def block plus a return of some integer
return_int_present = bool(re.search(r"return\s+\d+", content))

grade = {
    "label": label,
    "prompt_tokens": prompt_tokens,
    "elapsed_s": round(elapsed, 1),
    "sentinels_found": n_found,
    "sentinels_total": len(sentinels),
    "def_combine_sentinels_present": def_present,
    "return_int_present": return_int_present,
    "expected_sum": expected_sum,
    "thinking_off": True,
}
print(json.dumps(grade, indent=2))
print("---RAW RESPONSE---")
print(content)

resultfile = haystack_file.replace(".json", f".result.{label}.json")
with open(resultfile, "w") as fh:
    json.dump({"grade": grade, "raw": content}, fh, indent=2)
print(f"saved: {resultfile}")