#!/usr/bin/env python3
"""Build the hermetic coding-challenge snapshot.

Prepares bench/_challenge_repo/ as a stable, readable copy of the repo tree the
model will grep/read across, so the harness can read real source but is never
touching files that change mid-run. Excludes the .git dir (no VCS internals leak)
and the snapshot dir itself (so it cannot recurse into itself).

The model can read the real source but the harness never writes to or mutates
this snapshot during a run; the driver records git HEAD so results identify the
exact tree the model saw.

Usage: build_challenge_snapshot.py <src_repo> <snapshot_dir>
Writes <snapshot_dir>/_snapshot_head with `git rev-parse HEAD` of src_repo.
"""
import os
import shutil
import subprocess
import sys


def main():
    if len(sys.argv) != 3:
        print("usage: build_challenge_snapshot.py <src_repo> <snapshot_dir>")
        sys.exit(2)
    src = os.path.abspath(sys.argv[1])
    snap = os.path.abspath(sys.argv[2])
    if not os.path.isdir(src):
        print(f"error: source repo not found: {src}", file=sys.stderr)
        sys.exit(2)

    def ignore(directory, names):
        ignored = set()
        if directory == src:
            ignored.add(".git")
            if os.path.basename(snap) != os.path.basename(directory):
                ignored.add(os.path.basename(snap))
        return ignored

    os.makedirs(snap, exist_ok=True)
    shutil.copytree(src, snap, dirs_exist_ok=True, ignore=ignore,
                    symlinks=True)

    try:
        head = subprocess.run(["git", "-C", src, "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip() or "unknown"
    except OSError:
        head = "unknown"
    with open(os.path.join(snap, "_snapshot_head"), "w") as fh:
        fh.write(head + "\n")
    print(f"snapshot ready: {snap} (HEAD {head})")


if __name__ == "__main__":
    main()