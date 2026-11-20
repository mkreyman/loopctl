#!/usr/bin/env python3
"""bin/chg-replay-selection.py against a throwaway product repo and two fake chg builds.

The fakes stand in for `chg adapter exec affected`: each maps a changed `lib/<x>.ex` to
`test/<x>_test.exs`. The head build also selects `test/extra_test.exs` on every commit
(a widening), and a NARROW build drops the mapping for `lib/b.ex`. No network, no cargo.
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "bin" / "chg-replay-selection.py"
FAILS = []

FAKE = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
a = sys.argv[1:]
if a[:3] == ["adapter", "exec", "snapshot"]:
    repo = a[a.index("--repo") + 1]
    head = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True,
                          text=True, check=True).stdout.strip()
    with open(os.environ["SNAPSHOT_LOG"], "a") as f:
        f.write(head + "\n")
    with open(os.environ["SNAPSHOT_LOG"] + ".elixir", "a") as f:
        f.write(os.environ.get("ASDF_ELIXIR_VERSION", "-") + "\n")
    if MODE == "slow":
        import time; time.sleep(60)
    print(json.dumps({"work": "none", "ms": 0})); sys.exit(0)
if MODE == "array":
    print("[1, 2]"); sys.exit(0)
repo, base = a[a.index("--repo") + 1], a[a.index("--base") + 1]
assert os.environ.get("GIT_ALLOW_PROTOCOL") == "file", "network not blocked"
assert os.environ.get("MIX_ARCHIVES"), "no MIX_ARCHIVES"
changed = subprocess.run(["git", "-C", repo, "diff", "--name-only", base],
                         capture_output=True, text=True, check=True).stdout.split()
if "mix.exs" in changed:
    print(json.dumps({"mode": "all", "reason": "mix.exs changed"})); sys.exit(0)
tests = set()
for p in changed:
    if p.startswith("lib/") and p.endswith(".ex"):
        name = p[4:-3]
        if not (MODE == "narrow" and name == "b"):
            tests.add(f"test/{name}_test.exs")
if MODE == "wide":
    tests.add("test/extra_test.exs")
print(json.dumps({"mode": "subset", "reason": "fake", "tests": sorted(tests)}))
'''


def check(name, got, want):
    if got == want:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: got {got!r} want {want!r}")
        FAILS.append(name)


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                          check=True).stdout.strip()


def commit(repo, files, msg):
    for path, text in files.items():
        p = repo / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        git(repo, "add", path)
    git(repo, "commit", "-q", "-m", msg)
    return git(repo, "rev-parse", "HEAD")


def fake(tmp, mode):
    d = tmp / f"build-{mode}"
    (d / "archives").mkdir(parents=True)
    b = d / "chg"
    b.write_text(FAKE.replace("MODE", repr(mode)))
    b.chmod(0o755)
    return b, d / "archives"


def replay(product, home, base, head, *extra):
    cmd = [sys.executable, str(TOOL), "--base", "b", "--head", "h", "--repo", str(product),
           "--base-bin", str(base[0]), "--base-archives", str(base[1]),
           "--head-bin", str(head[0]), "--head-archives", str(head[1]), *extra]
    env = dict(os.environ, CHG_REPLAY_HOME=str(home), SNAPSHOT_LOG=str(home / "snapshots"))
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def main():
    tmp = Path(tempfile.mkdtemp())
    os.environ.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                      GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    product = tmp / "product"
    product.mkdir()
    git(product, "init", "-q", "-b", "master")
    tests = {f"test/{n}_test.exs": "" for n in ("a", "b", "c", "extra")}
    commit(product, {".chg/adapter.toml": '[adapter]\nkind = "elixir"\n', "mix.exs": "1",
                     ".tool-versions": "elixir 9.0\n",
                     "lib/a.ex": "0", "lib/b.ex": "0", "lib/c.ex": "0", **tests}, "root")
    shas = [commit(product, {f"lib/{n}.ex": str(i)}, f"touch {n}")
            for i, n in enumerate(["a", "b", "c", "a", "b"], 1)]
    # The newest commit bumps Elixir: every replayed commit must still run HEAD's, the one
    # the adapter archive was built for.
    shas.append(commit(product, {"mix.exs": "2", ".tool-versions": "elixir 10.0\n"},
                       "mix change"))
    # A product hook that would make `deps` in every new checkout (home_care_billing's
    # post-checkout links it): the replay runs with hooks off, so it never fires.
    marker = tmp / "hook-ran"
    hook = product / ".git" / "hooks" / "post-checkout"
    hook.write_text(f"#!/bin/sh\ntouch {marker}\nmkdir -p deps\n")
    hook.chmod(0o755)
    (product / "deps").mkdir()
    home = tmp / "home"
    same, wide, narrow = fake(tmp, "same"), fake(tmp, "wide"), fake(tmp, "narrow")

    print("chg-replay-selection.py")
    p = replay(product, home, same, wide, "--corpus", "5")
    check("exit 0", p.returncode, 0)
    doc = json.loads(p.stdout)
    corpus = doc["corpus"]
    check("five commits, newest first, all with a parent", [c["sha"] for c in corpus],
          list(reversed(shas))[:5])
    check("mode all counts every test file at that commit",
          (corpus[0]["base_count"], corpus[0]["head_count"], corpus[0]["dropped"]), (4, 4, []))
    check("a widening: head selects one more, drops nothing",
          [(c["base_count"], c["head_count"], c["dropped"]) for c in corpus[1:]],
          [(1, 2, [])] * 4)
    check("no miss without --miss", "miss" in doc, False)
    snaps = (home / "snapshots").read_text().split()
    parents = [git(product, "rev-parse", c["sha"] + "^") for c in corpus]
    check("each side snapshots each commit's parent before selecting",
          sorted(snaps), sorted(parents * 2))
    check("every commit runs HEAD's Elixir, the archive's",
          set((home / "snapshots.elixir").read_text().split()), {"10.0"})

    p = replay(product, home, same, narrow, "--corpus", "5")
    doc = json.loads(p.stdout)
    narrowed = [c for c in doc["corpus"] if c["dropped"]]
    check("a narrowing names the dropped test on each commit that loses it",
          [(c["sha"], c["base_count"], c["head_count"], c["dropped"]) for c in narrowed],
          [(shas[4], 1, 0, ["test/b_test.exs"]), (shas[1], 1, 0, ["test/b_test.exs"])])

    p = replay(product, home, same, wide, "--corpus", "1", "--miss", shas[1],
               "--failure", "test/b_test.exs:12", "--failure", "test/c_test.exs:3")
    miss = json.loads(p.stdout)["miss"]
    check("--miss: the head's selection there covers only the failures whose file it selects",
          miss, {"sha": shas[1], "covered": ["test/b_test.exs:12"]})
    p = replay(product, home, same, narrow, "--corpus", "1", "--miss", shas[1][:10],
               "--failure", "test/b_test.exs:12")
    check("--miss under a narrowing head covers nothing; the sha is resolved in full",
          json.loads(p.stdout)["miss"], {"sha": shas[1], "covered": []})
    p = replay(product, home, same, wide, "--corpus", "1", "--miss", shas[5],
               "--failure", "test/z_test.exs:1")
    check("--miss at a mode-all commit covers every failure",
          json.loads(p.stdout)["miss"]["covered"], ["test/z_test.exs:1"])
    p = replay(product, home, same, wide, "--corpus", "1", "--miss", shas[0])
    check("--miss without --failure lists the selected files",
          json.loads(p.stdout)["miss"]["covered"], ["test/a_test.exs", "test/extra_test.exs"])

    check("worktrees are removed", git(product, "worktree", "list").count("\n"), 0)
    check("the product's git hooks never ran", marker.exists(), False)
    check("the product checkout is untouched", git(product, "status", "--porcelain"), "")

    p = replay(product, home, same, wide, "--corpus", "31")
    check("--corpus past 30 refused", p.returncode, 2)
    p = replay(product, home, same, wide, "--failure", "x")
    check("--failure without --miss refused", p.returncode, 2)
    p = subprocess.run([sys.executable, str(TOOL), "--base", "b", "--head", "h",
                        "--repo", str(product)], capture_output=True, text=True)
    check("no build and no --chg refused", p.returncode, 2)
    p = replay(product, home, same, wide, "--miss", shas[0], "--failure", "t" * 201)
    check("a --failure loopctl would have to truncate is refused", p.returncode, 2)
    many = [x for i in range(51) for x in ("--failure", f"test/x{i}_test.exs:1")]
    p = replay(product, home, same, wide, "--miss", shas[0], *many)
    check("more than 50 distinct --failure names refused", p.returncode, 2)

    p = replay(product, home, same, (tmp / "no-such-chg", wide[1]), "--corpus", "1")
    check("a missing chg binary is a setup failure: exit 2, no traceback",
          (p.returncode, "Traceback" in p.stderr), (2, False))
    p = replay(product, home, same, fake(tmp, "array"), "--corpus", "1")
    check("affected printing a non-object is a setup failure: exit 2",
          (p.returncode, "Traceback" in p.stderr), (2, False))
    check("worktrees are removed after a setup failure",
          git(product, "worktree", "list").count("\n"), 0)

    slow = fake(tmp, "slow")
    log = home / "snapshots"
    before = log.read_text().count("\n")
    cmd = [sys.executable, str(TOOL), "--base", "b", "--head", "h", "--repo", str(product),
           "--base-bin", str(slow[0]), "--base-archives", str(slow[1]),
           "--head-bin", str(slow[0]), "--head-archives", str(slow[1]), "--corpus", "1"]
    proc = subprocess.Popen(cmd, env=dict(os.environ, CHG_REPLAY_HOME=str(home),
                                          SNAPSHOT_LOG=str(log)),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 30
    while log.read_text().count("\n") == before and time.monotonic() < deadline:
        time.sleep(0.1)
    proc.send_signal(signal.SIGTERM)
    check("SIGTERM mid-snapshot exits", proc.wait(timeout=30), 128 + signal.SIGTERM)
    check("SIGTERM still removes the worktrees", git(product, "worktree", "list").count("\n"), 0)
    check("SIGTERM leaves no replay trees behind",
          sorted(p.name for p in home.glob("replay-*")), [])

    other = tmp / "ts"
    other.mkdir()
    git(other, "init", "-q", "-b", "master")
    commit(other, {".chg/adapter.toml": '[adapter]\nkind = "typescript"\n'}, "root")
    commit(other, {"x": "1"}, "x")
    p = replay(other, home, same, wide)
    check("a non-Elixir adapter: exit 2, said", (p.returncode, "only Elixir" in p.stderr),
          (2, True))

    if FAILS:
        print(f"replay-selection-test: {len(FAILS)} FAILED")
        return 1
    print("replay-selection-test: all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
