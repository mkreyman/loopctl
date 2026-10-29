#!/usr/bin/env python3
"""prune.py TARGET: remove the workspace's own artifacts from a Cargo target dir before
it is cached. They change with every commit, so caching them only grows the upload.

The names come from `cargo metadata`: every workspace package and each of its targets
(lib, bins, integration tests). Every profile dir is pruned, including a cross target's
(TARGET/<triple>/<profile>), and `incremental` and `examples` go whole.
"""
import json
import os
import shutil
import subprocess
import sys

target = sys.argv[1]
meta = json.loads(
    subprocess.run(
        ["cargo", "metadata", "--no-deps", "--format-version", "1", "--offline"],
        check=True, capture_output=True, text=True,
    ).stdout
)
packages = {p["name"] for p in meta["packages"]}
crates = {t["name"].replace("-", "_") for p in meta["packages"] for t in p["targets"]}
bins = {t["name"] for p in meta["packages"] for t in p["targets"] if "bin" in t["kind"]}


def remove(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.remove(path)
    print("pruned", path)


def owned(name, stems):
    return any(name.startswith(s + "-") or name.startswith(s + ".") for s in stems)


profiles = [root for root, dirs, _ in os.walk(target) if "deps" in dirs and ".fingerprint" in dirs]
for prof in profiles:
    for name in ("incremental", "examples"):
        if os.path.exists(os.path.join(prof, name)):
            remove(os.path.join(prof, name))
    for sub, stems in (
        ("deps", crates | {"lib" + c for c in crates}),
        (".fingerprint", packages),
        ("build", packages),
    ):
        d = os.path.join(prof, sub)
        for entry in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if owned(entry, stems):
                remove(os.path.join(d, entry))
    for entry in sorted(os.listdir(prof)):
        if entry in bins or owned(entry, bins | crates | {"lib" + c for c in crates}):
            remove(os.path.join(prof, entry))
