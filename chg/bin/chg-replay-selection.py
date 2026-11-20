#!/usr/bin/env python3
"""Replays test selection under two chg builds, to show a selection fix only widens (#104).

    chg-replay-selection.py --chg DIR --base SHA --head SHA --repo DIR [--corpus N]
                            [--miss SHA [--failure NAME ...]]
                            [--base-bin PATH --base-archives DIR --head-bin PATH --head-archives DIR]

loopctl merges a change to chg's selection code without a person only when its verifier
measures that selection widened (loopctl US-51.5, `Loopctl.Changes.SelectionProof`). This
prints that measurement: the `selection_replay` object of loopctl's runner contract
(`verify@1`), as one JSON document on stdout:

    {"corpus": [{"sha": C, "base_count": 12, "head_count": 14, "dropped": [...]}, ...],
     "miss": {"sha": M, "covered": [...]}}

THE TWO SIDES. --base and --head are commits of chg (the --chg checkout): the rules being
compared. Each is built once (cargo, and the Elixir adapter archive for the product's
Elixir) into ~/.chg/replay/builds/<sha>/ and reused. --base-bin/--base-archives (and the
head's) use an existing build instead, which is how the test drives it.

THE CORPUS AND THE MISS are commits of the PRODUCT (--repo, e.g. home_care_billing): the
last --corpus first-parent commits of its default branch that have a parent (default 5,
at most 30), newest first. For each commit C, each side does what the gate does, in its
own throwaway worktree of the product, so neither side's compiled state reaches the other:
`chg adapter exec snapshot` at C^ (the compiled tree and the test reference cache the
module graph selects by), then `chg adapter exec affected --base C^` at C. A selection of `mode: all` counts as every test
file at C. `dropped` lists up to 3 test files the base selected and the head did not.

--miss runs the head's selection at that product commit. `covered` lists each --failure
name (a gate failure, `test/x_test.exs:12`) whose file the head selected, all of them for
`mode: all`. Without --failure it lists the selected files. At most 50 names, each at most
200 characters, which is what loopctl accepts.

READ-ONLY AND OFFLINE. No gate run, no ledger rows, no network: the adapter runs with
GIT_ALLOW_PROTOCOL=file, so chg's coverage fetch fails and both sides select from the same
local coverage records. The product's `deps` and `_build` are copied into each worktree
(reflinked where the filesystem can), never linked, so the replay needs a product checkout
whose deps are fetched and never writes into it. Its git hooks do not run. Worktrees are
removed on exit, on SIGTERM and SIGHUP too. Every commit runs under the Elixir the product's
HEAD names, the one each side's adapter archive was built for. Builds take a host-wide lock,
since they share one cargo target dir.

Elixir adapters only: the adapter's selection code is half the rules, and only the Elixir
adapter is built per side. Exit 0 with the document, 2 on bad arguments or a setup failure
(a build, a worktree, an unsupported adapter); the reason is on stderr.
"""
import argparse
import fcntl
import fnmatch
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

MAX_CORPUS = 30
MAX_DROPPED = 3
MAX_NAMES = 50
MAX_NAME_CHARS = 200
TEST_GLOB = "test/**_test.exs"
AFFECTED_TIMEOUT = 1800
BUILD_TIMEOUT = 3600
SNAPSHOT_TIMEOUT = 3600
NO_HOOKS = ("-c", "core.hooksPath=/dev/null")


class Fatal(Exception):
    pass


def run(cmd, cwd=None, env=None, timeout=600, check=True):
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True,
                           timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise Fatal(f"{' '.join(map(str, cmd))} did not finish in {timeout}s")
    if check and p.returncode != 0:
        raise Fatal(f"{' '.join(map(str, cmd))} exited {p.returncode}: {p.stderr.strip()[-2000:]}")
    return p


def git(repo, *args, **kw):
    return run(["git", "-C", str(repo), *args], **kw)


def default_branch(repo):
    p = git(repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD", check=False)
    if p.returncode == 0 and p.stdout.strip():
        return p.stdout.strip()
    for b in ("origin/master", "origin/main", "master", "main"):
        if git(repo, "rev-parse", "--verify", "--quiet", b + "^{commit}", check=False).returncode == 0:
            return b
    raise Fatal(f"{repo} has no default branch (origin/HEAD, master or main)")


def corpus_commits(repo, n):
    """The newest n first-parent commits of the default branch that have a parent."""
    out = git(repo, "rev-list", "--first-parent", "--parents", "-n", str(n + 1),
              default_branch(repo)).stdout.split("\n")
    shas = [line.split()[0] for line in out if len(line.split()) >= 2]
    return shas[:n]


def resolve(repo, rev):
    return git(repo, "rev-parse", "--verify", rev + "^{commit}").stdout.strip()


def test_files(repo, sha):
    names = git(repo, "ls-tree", "-r", "--name-only", sha).stdout.splitlines()
    return {n for n in names if fnmatch.fnmatch(n, TEST_GLOB)}


def tool_versions(repo, sha):
    """asdf's per-tool env for the .tool-versions at sha. The whole replay runs on HEAD's,
    the Elixir each side's adapter archive (and Hex) was built for."""
    p = git(repo, "show", f"{sha}:.tool-versions", check=False)
    env = {}
    for line in p.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] in ("elixir", "erlang"):
            env[f"ASDF_{parts[0].upper()}_VERSION"] = parts[1]
    return env


def adapter_kind(repo, sha):
    p = git(repo, "show", f"{sha}:.chg/adapter.toml", check=False)
    if p.returncode != 0:
        raise Fatal(f"{repo} has no .chg/adapter.toml at {sha[:12]}")
    try:
        return tomllib.loads(p.stdout).get("adapter", {}).get("kind")
    except tomllib.TOMLDecodeError as e:
        raise Fatal(f"{repo} .chg/adapter.toml at {sha[:12]} does not parse: {e}")


# -- builds -------------------------------------------------------------------------------

def default_archives_dir(product):
    p = run(["elixir", "-e", "IO.write(Mix.path_for(:archives))"], cwd=product, check=False)
    return Path(p.stdout.strip()) if p.returncode == 0 and p.stdout.strip() else None


def build(chg, sha, product, root):
    """(chg binary, MIX_ARCHIVES dir) for chg at sha, built once per sha and Elixir.

    One build at a time per host: every build shares CARGO_TARGET_DIR, so without the lock
    a concurrent build of another sha could overwrite target/release/chg before this one
    copies it, and its `done` would cache the wrong rules for good."""
    with open(root / "build.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return build_locked(chg, sha, product, root)


def build_locked(chg, sha, product, root):
    tv = tool_versions(product, "HEAD")
    key = f"{sha}-{tv.get('ASDF_ELIXIR_VERSION', 'default')}"
    out = root / "builds" / key
    binary, archives = out / "chg", out / "archives"
    # `done` is written last, so a build killed half way is rebuilt, never reused.
    if (out / "done").is_file():
        return binary, archives
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    src = Path(tempfile.mkdtemp(prefix=f"chg-src-{sha[:12]}-", dir=root))
    try:
        git(chg, "worktree", "add", "--detach", "-q", str(src), sha)
        env = dict(os.environ, CARGO_TARGET_DIR=str(root / "target"))
        run(["cargo", "build", "--release", "--locked", "--manifest-path",
             str(src / "cli" / "Cargo.toml")], env=env, timeout=BUILD_TIMEOUT)
        shutil.copy2(root / "target" / "release" / "chg", binary)
        built = out / "ez"
        run(["bash", str(src / "scripts" / "install-elixir-adapter.sh"), "--repo", str(product),
             "--out", str(built)], timeout=BUILD_TIMEOUT)
        ez = sorted(built.glob("*/chg_adapter.ez"))
        if len(ez) != 1:
            raise Fatal(f"the adapter build at {sha[:12]} made {len(ez)} archives, not one")
        # A private archives dir: the product's own archives (Hex) without any chg adapter,
        # then this side's adapter. MIX_ARCHIVES replaces the whole dir, Hex included.
        archives.mkdir()
        default = default_archives_dir(product)
        if default and default.is_dir():
            for entry in default.iterdir():
                if not entry.name.startswith("chg_adapter"):
                    dest = archives / entry.name
                    (shutil.copytree if entry.is_dir() else shutil.copy2)(entry, dest)
        run(["mix", "archive.install", str(ez[0]), "--force"], cwd=product,
            env=dict(os.environ, MIX_ARCHIVES=str(archives)))
        (out / "done").write_text(sha + "\n")
        return binary, archives
    finally:
        git(chg, "worktree", "remove", "--force", str(src), check=False)
        shutil.rmtree(src, ignore_errors=True)


# -- replay -------------------------------------------------------------------------------

class Side:
    """One build's throwaway worktree of the product, moved from commit to commit."""

    def __init__(self, name, binary, archives, product, root):
        self.name, self.binary, self.archives, self.product = name, binary, archives, product
        self.wt = Path(tempfile.mkdtemp(prefix=f"replay-{name}-", dir=root)) / "tree"
        self.added = False
        self.tools = tool_versions(product, "HEAD")

    def __enter__(self):
        try:
            # No hooks: the product's own post-checkout (home_care_billing's links deps and
            # boots databases) is not part of a read-only replay.
            git(self.product, *NO_HOOKS, "worktree", "add", "--detach", "-q", str(self.wt),
                "HEAD")
            self.added = True
            # Copies, never links: the snapshot step may refresh deps, and must not write
            # into the live checkout.
            for name in ("deps", "_build"):
                src = self.product / name
                if src.is_dir() and not os.path.lexists(self.wt / name):
                    run(["cp", "-a", "--reflink=auto", str(src), str(self.wt / name)],
                        timeout=1800, check=False)
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *exc):
        if self.added:
            git(self.product, "worktree", "remove", "--force", str(self.wt), check=False)
        shutil.rmtree(self.wt.parent, ignore_errors=True)

    def checkout(self, sha):
        git(self.wt, *NO_HOOKS, "checkout", "--detach", "-q", "--force", sha)
        git(self.wt, "clean", "-fdq", "-e", "deps", "-e", "_build")

    def env(self, sha):
        return dict(os.environ, MIX_ARCHIVES=str(self.archives), GIT_ALLOW_PROTOCOL="file",
                    CHG_OUTBOX_NO_KICK="1", **self.tools)

    def select(self, sha):
        """('all', reason) or ('subset', set of test files) at product commit sha.

        As the gate does: this side's snapshot of the parent first (the compiled tree and
        the test reference cache the module graph selects by), then this side's `affected`
        at sha against the parent."""
        parent = resolve(self.product, sha + "^")
        self.checkout(parent)
        p = run([str(self.binary), "adapter", "exec", "snapshot", "--repo", str(self.wt)],
                env=self.env(parent), timeout=SNAPSHOT_TIMEOUT, check=False)
        if p.returncode != 0:
            print(f"chg-replay-selection: {self.name} snapshot at {parent[:12]} exited "
                  f"{p.returncode}: {p.stderr.strip()[-500:]}", file=sys.stderr)
        self.checkout(sha)
        env = self.env(sha)
        p = run([str(self.binary), "adapter", "exec", "affected", "--repo", str(self.wt),
                 "--base", sha + "^"], env=env, timeout=AFFECTED_TIMEOUT, check=False)
        line = p.stdout.strip().splitlines()[-1] if p.stdout.strip() else ""
        try:
            doc = json.loads(line)
        except json.JSONDecodeError:
            raise Fatal(f"{self.name} build's affected at {sha[:12]} printed no JSON "
                        f"(exit {p.returncode}): {p.stderr.strip()[-1000:]}")
        if not isinstance(doc, dict):
            raise Fatal(f"{self.name} build's affected at {sha[:12]} printed {line[:200]!r}, "
                        "not a JSON object")
        if doc.get("mode") == "subset" and isinstance(doc.get("tests"), list):
            return "subset", set(doc["tests"])
        print(f"chg-replay-selection: {self.name} selects all at {sha[:12]}: "
              f"{doc.get('reason', '?')}", file=sys.stderr)
        return "all", doc.get("reason", "")


def as_set(selection, repo, sha):
    mode, value = selection
    return test_files(repo, sha) if mode == "all" else value


def bounded(names):
    return [n[:MAX_NAME_CHARS] for n in names][:MAX_NAMES]


def replay(args, base, head, product):
    corpus = []
    for sha in corpus_commits(product, args.corpus):
        b = as_set(base.select(sha), product, sha)
        h = as_set(head.select(sha), product, sha)
        corpus.append({"sha": sha, "base_count": len(b), "head_count": len(h),
                       "dropped": sorted(b - h)[:MAX_DROPPED]})
    doc = {"corpus": corpus}
    if args.miss:
        miss = resolve(product, args.miss)
        mode, value = head.select(miss)
        if args.failure:
            covered = sorted({f for f in args.failure
                              if mode == "all" or f.split(":")[0] in value})
        else:
            covered = sorted(test_files(product, miss) if mode == "all" else value)
        doc["miss"] = {"sha": miss, "covered": bounded(covered)}
    return doc


def parse(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--chg", type=Path, help="the chg checkout --base and --head are commits of")
    ap.add_argument("--base", required=True)
    ap.add_argument("--head", required=True)
    ap.add_argument("--repo", type=Path, required=True, help="the product checkout")
    ap.add_argument("--corpus", type=int, default=5)
    ap.add_argument("--miss")
    ap.add_argument("--failure", action="append", default=[])
    for side in ("base", "head"):
        ap.add_argument(f"--{side}-bin", type=Path)
        ap.add_argument(f"--{side}-archives", type=Path)
    a = ap.parse_args(argv)
    if not 1 <= a.corpus <= MAX_CORPUS:
        ap.error(f"--corpus must be 1..{MAX_CORPUS}")
    if a.failure and not a.miss:
        ap.error("--failure needs --miss")
    # loopctl compares `covered` exactly against the finding's failures, so a name it would
    # have to cut is refused here rather than truncated into one that never matches.
    if len(set(a.failure)) > MAX_NAMES:
        ap.error(f"at most {MAX_NAMES} distinct --failure names (loopctl's limit)")
    too_long = [f for f in a.failure if len(f) > MAX_NAME_CHARS]
    if too_long:
        ap.error(f"--failure longer than {MAX_NAME_CHARS} characters: {too_long[0][:80]}...")
    for side in ("base", "head"):
        given = [getattr(a, f"{side}_bin"), getattr(a, f"{side}_archives")]
        if any(given) and not all(given):
            ap.error(f"--{side}-bin and --{side}-archives go together")
        if not all(given) and not a.chg:
            ap.error(f"--chg is needed to build the {side}")
    return a


def terminate(signum, _frame):
    # The default action ends the process without running `finally` or `__exit__`, which
    # would leave the product's worktrees registered and the copied trees on disk.
    raise SystemExit(128 + signum)


def main(argv):
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, terminate)
    args = parse(argv)
    product = args.repo.resolve()
    root = Path(os.environ.get("CHG_REPLAY_HOME", Path.home() / ".chg" / "replay"))
    root.mkdir(parents=True, exist_ok=True)
    try:
        kind = adapter_kind(product, resolve(product, default_branch(product)))
        if kind != "elixir":
            raise Fatal(f"only Elixir adapters replay (this repo's is {kind!r})")
        sides = {}
        for side in ("base", "head"):
            if getattr(args, f"{side}_bin"):
                sides[side] = (getattr(args, f"{side}_bin").resolve(),
                               getattr(args, f"{side}_archives").resolve())
            else:
                chg = args.chg.resolve()
                sides[side] = build(chg, resolve(chg, getattr(args, side)), product, root)
        with Side("base", *sides["base"], product, root) as base, \
                Side("head", *sides["head"], product, root) as head:
            doc = replay(args, base, head, product)
    except (Fatal, OSError) as e:
        # OSError: a missing cargo/elixir/mix, or a copy that failed. Setup, not a crash.
        print(f"chg-replay-selection: {e}", file=sys.stderr)
        return 2
    print(json.dumps(doc, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
