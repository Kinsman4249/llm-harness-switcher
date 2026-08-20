#!/usr/bin/env python3
"""Build a token-depth-targeted needle-in-haystack + coding prompt for Nemotron 3 Nano 30B-A3B.

Same structure as build_haystack.py (three marker functions with random sentinel
return values at ~10/50/90% depth, then a coding task asking for a
combine_sentinels() Python function) but targets a specific TOKEN depth for the
served request, because the plan's long-context gate for Nemotron is at 131K and
200K tokens (the Qwen haystacks used a char target and a different tokenizer).

ORDER MATTERS: filler is trimmed to the token target FIRST, then the needle
markers are inserted at 10/50/90% of the FINAL text - so trimming can never
remove a needle (the earlier buggy version inserted needles before trimming,
which chopped the 90%-depth needle out and faked a 2/3 retrieval failure).

Token depth is calibrated live against the running server's /tokenize endpoint.

Usage:
  build_haystack_nemo.py <token_target> [--port 8080] [--host 127.0.0.1]
"""
import glob
import json
import os
import random
import sys
import urllib.request

random.seed(1234)

TOKEN_TARGET = int(sys.argv[1])
PORT = "8080"
HOST = "127.0.0.1"
TOLERANCE = int(TOKEN_TARGET * 0.02)        # +/-2%
OUT_DIR = os.path.dirname(os.path.abspath(__file__))

SRC_ROOT = os.path.expanduser("~/llama.cpp")
files = []
for ext in ("*.cpp", "*.h", "*.hpp", "*.c"):
    files.extend(glob.glob(os.path.join(SRC_ROOT, "**", ext), recursive=True))
files = [f for f in files if "/build/" not in f and "/.git/" not in f]
random.shuffle(files)


def tokenize(text):
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}/tokenize",
        data=json.dumps({"content": text}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return len(json.loads(resp.read())["tokens"])


sentinels = [random.randint(100000, 999999) for _ in range(3)]
names = ["get_partition_flux_a1b2", "get_partition_flux_c3d4", "get_partition_flux_e5f6"]

needles = []
for name, val in zip(names, sentinels):
    needles.append(
        f"\n// ---- injected marker function, do not remove ----\n"
        f"static int {name}(void) {{\n    return {val}; // sentinel\n}}\n"
        f"// ---- end marker ----\n"
    )

question = """

===== END OF CODE DUMP =====

Task: search the code dump above for three marker functions named
get_partition_flux_a1b2, get_partition_flux_c3d4, and get_partition_flux_e5f6.
Each returns a fixed integer sentinel value.

1. State the three integers each function returns, in order.
2. Write a single Python function `combine_sentinels()` that takes no
   arguments, hardcodes the three integers you found as local variables, and
   returns their sum as an int. Output ONLY valid Python for this function
   (a def block), nothing else executable.

Be precise: do not guess the sentinel values, they must be read exactly
from the marker functions above.
"""

# Step 1: trim the filler so `filler + question` tokenizes to the target.
chunks = []
total = 0
for f in files:
    try:
        with open(f, "r", errors="ignore") as fh:
            content = fh.read()
    except OSError:
        continue
    if not content.strip():
        continue
    chunks.append("// ---- file: " + os.path.relpath(f, SRC_ROOT) + " ----\n" + content)
    total += len(content)
    if total > TOKEN_TARGET * 8:
        break

filler = "\n".join(chunks)
prompt = filler + question
tokens = tokenize(prompt)
loops = 0
while tokens > TOKEN_TARGET + TOLERANCE and loops < 80:
    cut = int(len(filler) * 0.96)          # trim only filler (never the question)
    filler = filler[:cut]
    prompt = filler + question
    tokens = tokenize(prompt)
    loops += 1

# Step 2: NOW insert the three needles at 10/50/90% of the final filler.
n = len(filler)
positions = [int(n * 0.10), int(n * 0.50), int(n * 0.90)]
text = filler
for pos, needle in sorted(zip(positions, needles), key=lambda x: -x[0]):
    text = text[:pos] + needle + text[pos:]

full_prompt = text + question
tokens = tokenize(full_prompt)

out = {
    "prompt": full_prompt,
    "sentinels": sentinels,
    "expected_sum": sum(sentinels),
    "char_len": len(full_prompt),
    "token_target": TOKEN_TARGET,
    "measured_tokens": tokens,
}
outfile = os.path.join(OUT_DIR, f"haystack_nemo_{TOKEN_TARGET}.json")
with open(outfile, "w") as fh:
    json.dump(out, fh)
print(outfile)
print(f"token_target={TOKEN_TARGET} measured={tokens} chars={len(full_prompt)} expected_sum={sum(sentinels)} sentinels={sentinels}")