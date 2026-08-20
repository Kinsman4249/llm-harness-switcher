#!/usr/bin/env python3
"""Objective grader for the coding-challenge gate.

Reads the driver's saved transcript (a coding_challenge_<label>.run.json file or
a hand-written fixture with the same shape) and runs AST-free, text/diff-level
checks on the model's proposed solution. It NEVER executes, applies, or runs the
model's output - it only inspects the solution text for the invariants the
challenge rubric requires. All pass = PASS; any required check failing (or no
solution) = FAIL-Q.

Usage: coding_challenge_grade.py <run.json>
Emits bench/coding_challenge_<label>.result.json matching the *result.*.json
gitignore convention.
"""
import json
import os
import re
import sys

run_file = sys.argv[1]

if not os.path.isfile(run_file):
    print(f"ERROR: run file not found: {run_file}")
    sys.exit(2)

with open(run_file) as fh:
    run = json.load(fh)

label = run.get("label", "unknown")


def check_restart_mentioned(text):
    """The solution states a mode/effort change requires a llama-server restart
    on the same port."""
    if not re.search(r"restart", text, re.IGNORECASE):
        return False
    return bool(re.search(r"same port|port", text, re.IGNORECASE))


def check_mode_validation(text):
    """The solution shows start-local-model.sh validating effort:<N> against the
    profile's REASONING_MODES bare 'effort' token and rejecting unlisted names."""
    if "REASONING_MODES" not in text:
        return False
    if not re.search(r"\beffort\b", text, re.IGNORECASE):
        return False
    # An error/rejection of unlisted names, tolerating the real error wording.
    return bool(re.search(r"error|reject|not one of|not offered|not in", text, re.IGNORECASE))


def check_flag_mapping(text):
    """The solution maps effort:<N> -> --reasoning on + an effort flag carrying N,
    and raises the output window to REASONING_OUTPUT_MAX."""
    # --reasoning on (the resolved mode enables reasoning)
    if not re.search(r"--reasoning\s+on\b", text, re.IGNORECASE):
        return False
    # Tolerate the plausible effort-flag spellings for the per-call budget N.
    if not re.search(r"--reasoning-effort|--reasoning-budget", text, re.IGNORECASE):
        return False
    if "REASONING_OUTPUT_MAX" not in text:
        return False
    return True


def check_sync_reasoning(text):
    """The solution sets the Kilo provider's 'reasoning' field for the effort mode
    consistently with how budgeted/max encode the effort/budget there. Tolerates the
    plausible spellings (reasoningEffort, options, --effort, a budget value <N>)."""
    if "reasoning" not in text.lower():
        return False
    if not re.search(r"\beffort\b", text, re.IGNORECASE):
        return False
    # Effort/budget encoding into the sync reasoning field. Plausible variants:
    # the JSONC-backed reasoningEffort/options shape, the sync CLI --effort,
    # an explicit effort budget <N>, or any explicit reasoning-budget mention.
    return bool(re.search(r"reasoningEffort|allowReasoning|reasoning:\s*true|options|--effort|<\s*N\s*>",
                          text, re.IGNORECASE))


def check_no_default_mutation(text):
    """The solution must NOT rewrite the profile's REASONING_MODE default from a
    session choice. This is the sharpest discriminator and is graded strictly:
    any assignment/write-back to REASONING_MODE counts as a mutation (= fail).
    Returns True (pass) when the solution does NOT mutate the default."""
    if re.search(r"REASONING_MODE\s*=\s*[\"']?\s*[^\"'\s]", text):
        return False
    return True


def check_spec_conflict_resolved(text):
    """The solution reconciles the bare-token 'effort' capability in REASONING_MODES
    with the budget-scoped 'effort:<N>' mode - it must handle BOTH, not just echo
    the contradiction or claim only 'effort' without the <N>."""
    # The budget-scoped form from the task (effort:<N>), showing the <N> is being
    # handled as a per-call budget rather than ignored.
    has_mode_form = bool(re.search(r"effort\s*:\s*<", text, re.IGNORECASE))
    # The bare 'effort' capability referenced in the REASONING_MODES list context,
    # on either side of the list name within the same line-adjacent span.
    has_bare_token = bool(re.search(
        r"REASONING_MODES[^\n]*\beffort\b|\beffort\b[^\n]*REASONING_MODES",
        text, re.IGNORECASE))
    return has_mode_form and has_bare_token


def run_checks(solution):
    return {
        "restart_mentioned": check_restart_mentioned(solution),
        "mode_validation": check_mode_validation(solution),
        "flag_mapping": check_flag_mapping(solution),
        "sync_reasoning": check_sync_reasoning(solution),
        "no_default_mutation": check_no_default_mutation(solution),
        "spec_conflict_resolved": check_spec_conflict_resolved(solution),
    }


# ORDER of the required checks; the first failure ends grading (others still
# recorded for review, but the verdict is determined by the ordered scan).
CHECK_ORDER = ["restart_mentioned", "mode_validation", "flag_mapping",
               "sync_reasoning", "no_default_mutation", "spec_conflict_resolved"]

if not run.get("has_solution") or not run.get("solution"):
    checks = {k: False for k in CHECK_ORDER}
    verdict = "FAIL-Q"
    fail_reason = "no_solution"
else:
    solution = run["solution"]
    checks = run_checks(solution)
    fail_reason = None
    for name in CHECK_ORDER:
        if not checks[name]:
            fail_reason = f"failed:{name}"
            break
    verdict = "PASS" if fail_reason is None else "FAIL-Q"

result = {
    "label": label,
    "verdict": verdict,
    "fail_reason": fail_reason,
    "checks": checks,
    "repo_head": run.get("repo_head", ""),
    "max_tokens": run.get("max_tokens"),
    "prompt_tokens": run.get("prompt_tokens"),
    "completion_tokens": run.get("completion_tokens", 0),
    "elapsed_s": run.get("elapsed_s"),
    "turns_used": run.get("turns_used"),
    "tools_used": run.get("tools_used"),
    "emitted_tool_then_text": run.get("emitted_tool_then_text"),
    "vram_start_mib": run.get("vram_start_mib"),
    "vram_end_mib": run.get("vram_end_mib"),
    "vram_total_mib": run.get("vram_total_mib"),
    "rss_start_mib": run.get("rss_start_mib"),
    "rss_end_mib": run.get("rss_end_mib"),
    "has_solution": run.get("has_solution"),
    "transcript": run.get("transcript", []),
}

resultfile = os.path.join(os.path.dirname(os.path.abspath(run_file)),
                          f"coding_challenge_{label}.result.json")
with open(resultfile, "w") as fh:
    json.dump(result, fh, indent=2)

print(json.dumps({"label": label, "verdict": verdict, "fail_reason": fail_reason,
                  "checks": checks}, indent=2))
print(f"saved: {resultfile}")
print(verdict)
sys.exit(0 if verdict == "PASS" else 1)