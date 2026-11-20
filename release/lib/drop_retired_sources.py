#!/usr/bin/env python3
"""Removes a retired repository's [[source]] blocks from chg's ~/.chg/loopctl.toml (US-52.11).

    drop_retired_sources.py [--check] <loopctl.toml> <release/manifest.toml>

--check writes nothing and prints "pending" when a retired block is present.

The retired repos are the manifest's [retired] repos. Each [[source]] block naming one is cut
by its line range: from its header to the line before the next table header, with the blank
lines after it, so every other block, comment and line stays byte-identical. A comment line
directly above the next header is inside that range and goes with the block. The
file is read with tomllib first, so a file that is not TOML is refused rather than edited.
Replaced atomically and only when a block went. Prints "changed" or "unchanged"; exit 1 on a
file it cannot read.

The caller drains chg's outbox (`chg outbox send`) first: a row queued for a source that is
removed here would never be sent.
"""

import os
import re
import sys
import tempfile
import tomllib

HEADER = re.compile(r"^\s*\[")
REPO = re.compile(r'^\s*repo\s*=\s*"([^"]*)"\s*(#.*)?$')


def retired(manifest):
    with open(manifest, "rb") as f:
        return set(tomllib.load(f).get("retired", {}).get("repos", []))


def drop(text, repos):
    lines = text.splitlines(keepends=True)
    blocks, start = [], None
    for i, line in enumerate(lines):
        if HEADER.match(line):
            if start is not None:
                blocks.append((start, i))
            start = i if line.strip() == "[[source]]" else None
    if start is not None:
        blocks.append((start, len(lines)))

    cut = set()
    for a, b in blocks:
        names = [m.group(1) for m in (REPO.match(l) for l in lines[a:b]) if m]
        if names and names[0] in repos:
            # Through the line before the next header, so the blank lines after the block go
            # with it and every other line is untouched.
            cut.update(range(a, b))
    if not cut:
        return text

    return "".join(l for i, l in enumerate(lines) if i not in cut)


def main(argv):
    check = "--check" in argv
    argv = [a for a in argv if a != "--check"]
    if len(argv) != 3:
        print("usage: drop_retired_sources.py [--check] <loopctl.toml> <manifest.toml>", file=sys.stderr)
        return 2
    path, manifest = argv[1], argv[2]
    try:
        repos = retired(manifest)
        with open(path, "rb") as f:
            raw = f.read()
        tomllib.loads(raw.decode())
    except (OSError, ValueError) as e:
        print(f"cannot read: {e}", file=sys.stderr)
        return 1

    text = raw.decode()
    new = drop(text, repos)
    if check:
        print("unchanged" if new == text else "pending")
        return 0
    if new == text:
        print("unchanged")
        return 0

    mode = os.stat(path).st_mode & 0o777
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix=".loopctl.toml.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(new)
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
