#!/usr/bin/env python3
"""chg's generic adapter (contract v1, docs/adapter-contract.md) for a repo with no build.

The repo supplies the two things only it knows, as shell commands in .chg/adapter.toml:
  --select  prints which test suites a change can reach: the word ALL, or suite names one per
            line. It runs with CHG_CHANGED naming a file of the changed paths and CHG_BASE set.
  --runner  runs the suites named in CHG_SUITES (space-separated names) and prints one line
            per suite that --result matches (default `PASS|FAIL|SKIP <name>`). PASS/OK pass; a word
            --skip names is `skip`, which fails no verdict, even when every suite skipped: the
            manifest names a word only when the repo's gate accepts it. Any other word fails.
A suite is a file under --suite-dir; its id is that repo-relative path.

  snapshot [--cmd SH]
  static   --base B [--check NAME=SH]...
  affected --base B --select SH --suite-dir D
  run      --tests FILE --runner SH --suite-dir D [--result RE] [--skip WORD]...
  shard    --of N --index I --runner SH --suite-dir D --suite-glob G [--result RE] [--skip WORD]...

Every command prints its JSON document as the last line of stdout; everything else goes to
stderr. `affected` never fails: any doubt prints {"mode":"all"} with the reason (fails closed).
Python 3.8+, stdlib only, so it runs wherever the repo's own scripts run.
"""
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

# The words a runner's status may take: PASS/OK pass, anything else fails unless --skip names it.
PASS_WORDS = {"PASS": "pass", "OK": "pass"}
# The seconds are the LAST `<N>s` in the parentheses, a whole number not the tail of a word:
# `(12s)`, `(rc=1, 3s)`, `(1s, nothing else in it ran)`, `(TIMED OUT after 600s, ...=600s)`.
DEFAULT_RESULT = r"^(?P<status>PASS|FAIL|SKIP)\s+(?P<name>\S+)(?:\s+\((?:[^)]*[^\w.])?(?P<secs>\d+(?:\.\d+)?)s\b[^)]*\))?"
TAIL_LINES = 40


def emit(doc, code=0):
    sys.stdout.flush()
    print(json.dumps(doc, separators=(",", ":")))
    sys.exit(code)


def ms_since(t0):
    return int((time.monotonic() - t0) * 1000)


def git(*args):
    r = subprocess.run(["git", *args], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if r.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), (r.stderr or r.stdout).strip()[:300]))
    return r.stdout


def shell(cmd, env, capture=True):
    """Runs `cmd` under sh -c from the repo root; its stdout is echoed to stderr as it arrives
    and returned, so the last-line document stays the only thing on our stdout."""
    p = subprocess.Popen(["sh", "-c", cmd], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, env=env, text=True, errors="replace")
    out = []
    for line in p.stdout:
        sys.stderr.write(line)
        if capture:
            out.append(line)
    p.wait()
    return p.returncode, "".join(out)


def env_with(**kw):
    e = dict(os.environ)
    e.update({k: v for k, v in kw.items() if v is not None})
    return e


def snapshot(a):
    t0 = time.monotonic()
    if a.cmd:
        rc, _ = shell(a.cmd, env_with(), capture=False)
        if rc != 0:
            print("snapshot command exited %d" % rc, file=sys.stderr)
            sys.exit(1)
    emit({"work": "full" if a.cmd else "none", "ms": ms_since(t0)})


def static(a):
    head = git("rev-parse", "HEAD").strip()
    checks = []
    for spec in a.check or []:
        name, sep, cmd = spec.partition("=")
        if not sep or not name or not cmd:
            emit({"ok": False, "failures": [{"check": "adapter", "message": "--check %r is not NAME=SH" % spec}]}, 1)
        checks.append((name, cmd))
    results = {}

    def one(name, cmd):
        rc, out = shell(cmd, env_with(CHG_BASE=a.base, CHG_HEAD=head))
        results[name] = (rc, out)

    threads = [threading.Thread(target=one, args=c) for c in checks]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    failures = []
    for name, _ in checks:
        rc, out = results[name]
        if rc != 0:
            tail = "\n".join(out.rstrip("\n").split("\n")[-TAIL_LINES:])
            failures.append({"check": name, "message": "exited %d\n%s" % (rc, tail)})
    emit({"ok": not failures, "failures": failures}, 1 if failures else 0)


def suite_path(suite_dir, name):
    name = name.strip()
    rel = name if name.startswith(suite_dir.rstrip("/") + "/") else os.path.join(suite_dir, name)
    return os.path.normpath(rel)


def affected(a):
    def all_(why):
        print("chg generic adapter: " + why, file=sys.stderr)
        emit({"mode": "all", "reason": why})

    try:
        git("rev-parse", "--verify", "-q", a.base + "^{commit}")
        # NUL-separated: a path with a space, or one git would quote, arrives whole.
        changed = sorted((set(git("diff", "-z", "--no-renames", "--name-only", a.base).split("\0"))
                          | set(git("ls-files", "-z", "--others", "--exclude-standard").split("\0"))) - {""})
    except RuntimeError as e:
        all_("failed closed: %s" % e)
    if os.environ.get("CHG_READ"):
        all_("failed closed: this adapter records no reads, and a changed path matches read_at_runtime")
    with tempfile.NamedTemporaryFile("w", prefix="chg-changed-", suffix=".txt", delete=False) as fh:
        fh.write("".join(p + "\n" for p in changed))
        changed_file = fh.name
    try:
        r = subprocess.run(["sh", "-c", a.select], capture_output=True, text=True, stdin=subprocess.DEVNULL,
                           env=env_with(CHG_CHANGED=changed_file, CHG_BASE=a.base), errors="replace")
    finally:
        os.unlink(changed_file)
    sys.stderr.write(r.stderr)
    if r.returncode != 0:
        all_("failed closed: the select command exited %d" % r.returncode)
    names = [l.strip() for l in r.stdout.splitlines() if l.strip()]
    if not names:
        all_("failed closed: the select command selected nothing")
    if "ALL" in names:
        all_("the select command selected ALL")
    tests = []
    for n in names:
        p = suite_path(a.suite_dir, n)
        if os.path.dirname(p) != os.path.normpath(a.suite_dir):
            all_("failed closed: the select command named %r, which is not a suite directly under %s" % (n, a.suite_dir))
        if not os.path.isfile(p):
            all_("failed closed: the select command named %r, which is no suite under %s" % (n, a.suite_dir))
        if p not in tests:
            tests.append(p)
    emit({"mode": "subset", "reason": "%d of the suites under %s, by --select for %d changed path(s)"
          % (len(tests), a.suite_dir, len(changed)), "tests": sorted(tests)})


def run_suites(a, ids):
    """Runs the runner over `ids` (repo-relative suite paths) and returns one result per id."""
    if not ids:
        return []
    # A suite is a file directly under --suite-dir (affected and shard only produce those), so
    # its file name is unique and is what the runner is given.
    names = [os.path.basename(i) for i in ids]
    by_name = dict(zip(names, ids))
    t0 = time.monotonic()
    rc, out = shell(a.runner, env_with(CHG_SUITES=" ".join(names)))
    pat = re.compile(a.result)
    # `skip` fails no verdict, so only the manifest may say which status word means it: a runner's
    # SKIP is "passed with an allowed skipped layer" for run-canaries.sh, and "never started" for others.
    # A named word is one the repo's gate accepts, so a run of nothing but skips is judged as the gate
    # judges it (run-canaries.sh passes one on purpose), not as an error.
    skips = {w.upper() for w in (a.skip or [])}
    seen = {}
    for line in out.splitlines():
        m = pat.search(line)
        if not m or m.group("name") not in by_name:
            continue
        secs = m.groupdict().get("secs")
        word = m.group("status").upper()
        status = dict(PASS_WORDS, **{w: "skip" for w in skips}).get(word, "fail")
        seen[m.group("name")] = (status, int(float(secs) * 1000) if secs else 0)
    results = []
    for n in names:
        status, ms = seen.get(n, ("error", 0))
        results.append({"id": by_name[n], "status": status, "ms": ms})
    if rc != 0 and all(r["status"] in ("pass", "skip") for r in results):
        # Attached to a real suite, so the id starts with a test file as the contract requires
        # and `chg culprit` can rerun it.
        results.append({"id": "%s > runner exited %d" % (ids[-1], rc), "status": "error", "ms": ms_since(t0)})
    return results


def finish(results, need_one):
    if need_one and not results:
        emit({"results": [{"id": "adapter", "status": "error", "ms": 0}]}, 1)
    bad = any(r["status"] in ("fail", "error") for r in results)
    emit({"results": results}, 1 if bad else 0)


def run(a):
    try:
        with open(a.tests, encoding="utf-8") as fh:
            entries = [l.strip() for l in fh if l.strip()]
    except OSError as e:
        print("chg generic adapter: %s" % e, file=sys.stderr)
        emit({"results": [{"id": "adapter", "status": "error", "ms": 0}]}, 1)
    # A `path:line` entry names the whole suite: a suite is one script.
    ids, bad = [], []
    for e in entries:
        p = suite_path(a.suite_dir, e.split(":", 1)[0])
        if os.path.dirname(p) != os.path.normpath(a.suite_dir):
            bad.append({"id": p, "status": "error", "ms": 0})
        elif p not in ids:
            ids.append(p)
    for b in bad:
        print("chg generic adapter: %s is not a suite directly under %s" % (b["id"], a.suite_dir), file=sys.stderr)
    finish(run_suites(a, ids) + bad, need_one=True)


def shard(a):
    if not (1 <= a.index <= a.of):
        emit({"results": [{"id": "adapter", "status": "error", "ms": 0}]}, 1)
    try:
        names = sorted(n for n in os.listdir(a.suite_dir)
                       if fnmatch.fnmatchcase(n, a.suite_glob) and os.path.isfile(os.path.join(a.suite_dir, n)))
    except OSError as e:
        print("chg generic adapter: %s" % e, file=sys.stderr)
        emit({"results": [{"id": "adapter", "status": "error", "ms": 0}]}, 1)
    mine = [os.path.normpath(os.path.join(a.suite_dir, n)) for n in names[a.index - 1::a.of]]
    finish(run_suites(a, mine), need_one=False)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("snapshot")
    p.add_argument("--cmd")
    p = sub.add_parser("static")
    p.add_argument("--base", required=True)
    p.add_argument("--check", action="append")
    p = sub.add_parser("affected")
    p.add_argument("--base", required=True)
    p.add_argument("--select", required=True)
    p.add_argument("--suite-dir", required=True)
    for name in ("run", "shard"):
        p = sub.add_parser(name)
        p.add_argument("--runner", required=True)
        p.add_argument("--suite-dir", required=True)
        p.add_argument("--result", default=DEFAULT_RESULT)
        p.add_argument("--skip", action="append")
        if name == "run":
            p.add_argument("--tests", required=True)
        else:
            p.add_argument("--of", type=int, required=True)
            p.add_argument("--index", type=int, required=True)
            p.add_argument("--suite-glob", required=True)
    if sys.argv[1:2] == ["affected"]:
        # `affected` never exits 2 (contract): a bad argument line fails closed like any doubt.
        def fail_closed(msg):
            print("chg generic adapter: " + msg, file=sys.stderr)
            emit({"mode": "all", "reason": "failed closed: " + msg})
        sub.choices["affected"].error = fail_closed
        ap.error = fail_closed
        # Leftover arguments are reported by the top-level parser, after the subparser.
        a, extra = ap.parse_known_args()
        if extra:
            fail_closed("unrecognized arguments: %s" % " ".join(extra))
    else:
        a = ap.parse_args()
    if a.command == "affected":
        try:
            affected(a)
        except SystemExit:
            raise
        except Exception as e:  # any doubt selects everything
            print("chg generic adapter: %r" % e, file=sys.stderr)
            emit({"mode": "all", "reason": "failed closed: %s" % type(e).__name__})
        return
    {"snapshot": snapshot, "static": static, "affected": affected, "run": run, "shard": shard}[a.command](a)


if __name__ == "__main__":
    main()
