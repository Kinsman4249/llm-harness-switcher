#!/usr/bin/env python3
"""Comment-preserving JSONC editor for the Kilo config.

sync-local-model.sh hands this a path plus the provider/model fields; this
adds or updates ONE provider (default "local-model") and the top-level
"model" value in a JSONC file (JSON with // and /* */ comments) without
touching any comment or property other than the targeted ones. The provider's
whole value object is replaced by a fresh one that carries exactly the
current model, so re-syncs REPLACE the single entry and never accumulate
duplicates or grow the file. Everything outside the two replaced spans
(comments, other providers, permissions, agents, formatting) is preserved
byte-for-byte.

Atomic: the result is written to a temp file in the same directory and
os.replace()d over the original, so a crash never leaves a half-written
config and a symlinked ~/.config/kilo/kilo.jsonc keeps pointing at its real
(tracked) target.
"""

import argparse
import json
import os
import tempfile


def skip_ws_comments(s, i):
    """Advance over whitespace and // or /* */ comments; return new index."""
    n = len(s)
    while i < n:
        c = s[i]
        if c in " \t\r\n":
            i += 1
        elif s.startswith("//", i):
            j = s.find("\n", i)
            i = n if j < 0 else j
        elif s.startswith("/*", i):
            j = s.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            break
    return i


def skip_string(s, i):
    """Return index just past the string whose opening quote is at i."""
    i += 1
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            return i + 1
        i += 1
    return n


def find_close(s, open_i):
    """Index of the matching close bracket for the { or [ at open_i."""
    opener = s[open_i]
    closer = "}" if opener == "{" else "]"
    depth = 0
    n = len(s)
    i = open_i
    while i < n:
        c = s[i]
        if c == '"':
            i = skip_string(s, i)
            continue
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("unbalanced brackets")


def skip_value(s, i):
    """Index just past the JSON value beginning at i (object/array/str/scalar)."""
    n = len(s)
    i = skip_ws_comments(s, i)
    if i >= n:
        return i
    c = s[i]
    if c in "{[":
        return find_close(s, i) + 1
    if c == '"':
        return skip_string(s, i)
    if c in "\"'":
        raise ValueError("single quotes not supported")
    while i < n and s[i] not in ",}] \t\r\n":
        i += 1
    return i


def find_member(s, obj_open, obj_close, key):
    """Span (k_start,k_end,v_start,v_end) of a member of obj_open..obj_close."""
    i = obj_open + 1
    while i < obj_close:
        i = skip_ws_comments(s, i)
        if i >= obj_close or s[i] != '"':
            i += 1
            continue
        k_start = i
        k_end = skip_string(s, i)
        j = skip_ws_comments(s, k_end)
        if j < obj_close and s[j] == ":":
            v_start = skip_ws_comments(s, j + 1)
            v_end = skip_value(s, v_start)
            try:
                name = json.loads(s[k_start:k_end])
            except ValueError:
                name = s[k_start:k_end]
            if name == key:
                return (k_start, k_end, v_start, v_end)
            i = v_end
        else:
            i = k_end
    return None


def last_member_end(s, obj_open, obj_close):
    """v_end of the lexically last (key: value) member in obj_open..obj_close."""
    prev_end = None
    i = obj_open + 1
    while i < obj_close:
        i = skip_ws_comments(s, i)
        if i >= obj_close or s[i] != '"':
            i += 1
            continue
        k_end = skip_string(s, i)
        j = skip_ws_comments(s, k_end)
        if j < obj_close and s[j] == ":":
            v_start = skip_ws_comments(s, j + 1)
            v_end = skip_value(s, v_start)
            prev_end = v_end
            i = v_end
        else:
            i = k_end
    return prev_end


def find_top_object(s):
    i = skip_ws_comments(s, 0)
    if i >= len(s) or s[i] != "{":
        raise ValueError("config is not a JSON object")
    return i, find_close(s, i)


def has_content_before(s, obj_open, boundary):
    """True if any non-ws/non-comment token sits between obj_open and boundary."""
    return skip_ws_comments(s, obj_open) < boundary


def build_provider_value(args):
    model = {
        "name": args.model_name,
        "tool_call": True,
        "temperature": True,
        "reasoning": args.reasoning != "off",
        "limit": {"context": args.context, "output": args.output},
    }
    if args.reasoning == "effort":
        model["options"] = {"reasoningEffort": args.effort}
    if args.attachment == "yes":
        if args.image_only == "yes":
            model["attachment"] = True
            model["modalities"] = {"input": ["image"], "output": ["text"]}
        else:
            model["attachment"] = True
            model["modalities"] = {"input": ["text", "image"], "output": ["text"]}
    return {
        "name": args.provider,
        "npm": "@ai-sdk/openai-compatible",
        "options": {"baseURL": args.base_url, "apiKey": args.api_key},
        "models": {args.model_id: model},
    }


def edit(s, args):
    top_open, top_close = find_top_object(s)
    new_prov = build_provider_value(args)
    model_str = json.dumps(args.provider + "/" + args.model_id)

    segments = []
    pos = 0

    # 1) provider member: add/update the single local-model key INSIDE the
    #    existing ".provider" object, preserving any other providers (runpod-
    #    helper) and their comments. A repeated run REPLACES the one value,
    #    so the file never accumulates duplicate local-model entries.
    prov = find_member(s, top_open, top_close, "provider")
    if prov is not None:
        _, _, v_start, v_end = prov
        prov_obj_open = v_start
        prov_obj_close = v_end - 1
        new_val = json.dumps(new_prov)
        lm = find_member(s, prov_obj_open, prov_obj_close, args.provider)
        if lm is not None:
            _, _, lv_start, lv_end = lm
            segments.append(s[pos:lv_start])
            segments.append(new_val)
            pos = lv_end
        else:
            prev_end = last_member_end(s, prov_obj_open, prov_obj_close)
            if prev_end is not None:
                tail = skip_ws_comments(s, prev_end)
                has_trailing_comma = tail < prov_obj_close and s[tail] == ","
                sep = ",\n    " if not has_trailing_comma else "\n    "
                segments.append(s[pos:prev_end] + sep + json.dumps(args.provider) + ": " + new_val)
                pos = prev_end
            else:
                segments.append(s[pos:prov_obj_open + 1])
                segments.append("\n    " + json.dumps(args.provider) + ": " + new_val)
                pos = prov_obj_open + 1
    else:
        segments.append(s[pos:top_close])
        sep = ",\n    " if has_content_before(s, top_open, top_close) else "\n    "
        segments.append(sep + json.dumps(args.provider) + ": " + json.dumps(new_prov))
        pos = top_close

    # 2) model member: replace the top-level default model value.
    model = find_member(s, top_open, top_close, "model")
    if model is not None:
        _, _, mv_start, mv_end = model
        segments.append(s[pos:mv_start])
        segments.append(model_str)
        pos = mv_end
    else:
        segments.append(s[pos:top_close])
        sep = ",\n  " if has_content_before(s, top_open, top_close) else "\n  "
        segments.append(sep + '"model": ' + model_str)
        pos = top_close

    segments.append(s[pos:])
    return "".join(segments)


def main():
    p = argparse.ArgumentParser(description="JSONC Kilo config editor")
    p.add_argument("config")
    p.add_argument("--provider", required=True)
    p.add_argument("--api-key", required=True)
    p.add_argument("--base-url", required=True)
    p.add_argument("--model-id", required=True)
    p.add_argument("--model-name", required=True)
    p.add_argument("--context", type=int, required=True)
    p.add_argument("--output", type=int, required=True)
    p.add_argument("--reasoning", default="off")
    p.add_argument("--effort", default="low")
    p.add_argument("--attachment", default="no")
    p.add_argument("--image-only", default="no")
    args = p.parse_args()

    with open(args.config, "r", encoding="utf-8") as fh:
        s = fh.read()

    new_text = edit(s, args)

    d = os.path.dirname(os.path.abspath(args.config))
    fd, tmp = tempfile.mkstemp(prefix=".kilo.jsonc.", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(new_text)
        try:
            os.chmod(tmp, os.stat(args.config).st_mode)
        except OSError:
            os.chmod(tmp, 0o600)
        os.replace(tmp, args.config)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


if __name__ == "__main__":
    main()