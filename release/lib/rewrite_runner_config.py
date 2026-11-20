#!/usr/bin/env python3
"""Moves a runner.json from the retired mkreyman/chg repository to mkreyman/loopctl (US-52.10).

    rewrite_runner_config.py <runner.json> <loopctl checkout path>

chg now lives under chg/ in loopctl (US-52.5), so on a machine whose config still names chg:

- a selection_replay entry keyed "chg" or "mkreyman/chg" moves to "loopctl", each of its
  paths prefixed with "chg/";
- "mkreyman/chg" in control.repos becomes "mkreyman/loopctl" (kept once);
- the repos map gains "loopctl" -> the checkout path when it lacks one.

Anything else is left as it is. The file is replaced atomically (write, fsync, rename) and
only when something changed. Prints "changed" or "unchanged"; exits 1 on a file it cannot
read as a JSON object.
"""

import json
import os
import sys
import tempfile


def rewrite(config, checkout):
    changed = False

    replay = config.get("selection_replay")
    if isinstance(replay, dict):
        for old in ("chg", "mkreyman/chg"):
            entry = replay.get(old)
            if isinstance(entry, dict) and "loopctl" not in replay:
                moved = dict(entry)
                moved["paths"] = [
                    p if p.startswith("chg/") else "chg/" + p for p in entry.get("paths", [])
                ]
                replay["loopctl"] = moved
                del replay[old]
                changed = True

    control = config.get("control")
    if isinstance(control, dict) and isinstance(control.get("repos"), list):
        repos = control["repos"]
        if "mkreyman/chg" in repos:
            rewritten = []
            for r in repos:
                r = "mkreyman/loopctl" if r == "mkreyman/chg" else r
                if r not in rewritten:
                    rewritten.append(r)
            control["repos"] = rewritten
            changed = True

    local = config.get("repos")
    if changed and isinstance(local, dict) and "loopctl" not in local:
        local["loopctl"] = checkout
        changed = True

    return changed


def main(argv):
    if len(argv) != 3:
        print("usage: rewrite_runner_config.py <runner.json> <loopctl checkout>", file=sys.stderr)
        return 2

    path, checkout = argv[1], argv[2]
    try:
        with open(path) as f:
            config = json.load(f)
    except (OSError, ValueError) as e:
        print(f"cannot read {path}: {e}", file=sys.stderr)
        return 1
    if not isinstance(config, dict):
        print(f"{path} is not a JSON object", file=sys.stderr)
        return 1

    if not rewrite(config, checkout):
        print("unchanged")
        return 0

    directory = os.path.dirname(os.path.abspath(path))
    mode = os.stat(path).st_mode & 0o777
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".runner.json.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(config, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise
    print("changed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
