#!/usr/bin/env python3
"""Writes what a repo's verifier learned to the loopctl KB (story S13, #21, phase-1 form).

    chg-kb-sync.py --repo owner/name --project-id <loopctl project> [--days 7] [--dry-run]

Phase 1 has no chg-server, so there is no outbox: this runs on a timer, reads the lessons
the master verifier (S8) already records on GitHub, and writes one `finding` per lesson.

  * a merged `auto-revert` PR: the culprit, why it was reverted, the revert;
  * a `test-flakiness` issue: the test and the rerun evidence.

It is off the merge path by construction: it only reads GitHub and writes the KB, so a KB
or GitHub outage delays articles and changes nothing else. A retry writes nothing twice:
each lesson carries a capture tag (`idem-chgsync-<digest of its URL>`), so the client
sends a server-enforced idempotency key, and `skip_low_novelty` drops near-duplicates.
~/.chg/kb-sync/<repo>.json records each lesson as it is written, and keeps a lesson whose
write failed until a later run writes it, however old it gets.
Exit 0 when every lesson was written or already known, 1 when any write failed (the next
run retries it), 2 on bad arguments, a missing KB client, an unreadable state file or a
GitHub that did not answer.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

CLIENT_DIR = Path.home() / "workspace/claude-config/skills/_shared"
CHG_HOME = Path(os.environ.get("CHG_HOME", Path.home() / ".chg"))
BODY_CAP = 6000


class Fatal(Exception):
    """A setup or input problem: exit 2."""


def ensure_requests():
    """The KB client needs `requests`; without it, re-run under a venv of chg's own,
    made on first use and repaired when an earlier install did not finish."""
    try:
        import requests  # noqa: F401
        return
    except ImportError:
        pass
    venv = CHG_HOME / "kb-venv"
    py = venv / "bin" / "python3"
    if sys.executable == str(py):
        raise Fatal("requests is missing from chg's own venv, and installing it failed")
    try:
        if not py.exists():
            subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
        if subprocess.run([str(py), "-c", "import requests"], capture_output=True).returncode:
            subprocess.run([str(py), "-m", "pip", "install", "-q", "requests"], check=True)
    except (subprocess.CalledProcessError, OSError) as e:
        raise Fatal(f"could not make {venv}: {e}")
    os.execv(str(py), [str(py), *sys.argv])


def gh(args):
    try:
        out = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=120,
                             env={k: v for k, v in os.environ.items() if k != "GH_TOKEN"})
    except subprocess.TimeoutExpired:
        raise Fatal(f"gh {' '.join(args[:2])}: no answer in 120 s")
    if out.returncode != 0:
        raise Fatal(f"gh {' '.join(args[:2])}: {out.stderr.strip()[-300:]}")
    try:
        return json.loads(out.stdout or "[]")
    except json.JSONDecodeError:
        raise Fatal(f"gh {' '.join(args[:2])}: not JSON: {out.stdout[:200]!r}")


def lessons(repo, reverts, flakes, since):
    """The articles for `reverts` (merged auto-revert PRs) and `flakes` (test-flakiness
    issues) newer than `since`, each keyed by its URL."""
    name = repo.split("/")[-1]

    def lesson(url, title, body, kind):
        tag = "idem-chgsync-" + hashlib.sha1(url.encode()).hexdigest()[:12]
        return {"key": url, "title": title, "body": body[:BODY_CAP], "tags": ["chg", name, kind, tag]}

    out = []
    for pr in reverts:
        if pr.get("mergedAt") and pr["mergedAt"] >= since:
            out.append(lesson(
                pr["url"],
                f"{name} auto-revert: {pr['title'].removeprefix('Auto-revert: ')}",
                f"chg's master verifier reverted a commit on {repo} ({pr['url']}, "
                f"merged {pr['mergedAt']}). Its record:\n\n{pr.get('body') or ''}",
                "auto-revert"))
    for issue in flakes:
        if issue["createdAt"] >= since:
            out.append(lesson(
                issue["url"],
                f"{name} flaky test: {issue['title'].removeprefix('Flaky: ').removeprefix('Flaky test: ')}",
                f"chg's master verifier found a flaky test on {repo} ({issue['url']}, "
                f"{issue['state'].lower()}). Its record:\n\n{issue.get('body') or ''}",
                "flaky-test"))
    return out


def load_state(path):
    """{"done": [keys], "pending": {key: lesson}}; the original form was a bare key list."""
    if not path.exists():
        return {"done": [], "pending": {}}
    try:
        s = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as e:
        raise Fatal(f"{path} unreadable ({e}): fix or remove it")
    return {"done": s, "pending": {}} if isinstance(s, list) else s


def save_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps({"done": sorted(state["done"]), "pending": state["pending"]}))
    tmp.replace(path)


def run(a):
    since = (datetime.now(timezone.utc) - timedelta(days=a.days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    if not a.dry_run:
        if not (CLIENT_DIR / "loopctl_client_core.py").exists():
            raise Fatal(f"no KB client at {CLIENT_DIR} (claude-config checkout missing)")
        ensure_requests()
        sys.path.insert(0, str(CLIENT_DIR))
    reverts = gh(["pr", "list", "--repo", a.repo, "--label", "auto-revert", "--state", "merged",
                  "--limit", "50", "--json", "url,title,body,mergedAt"])
    flakes = gh(["issue", "list", "--repo", a.repo, "--label", "test-flakiness", "--state", "all",
                 "--limit", "50", "--json", "url,title,body,createdAt,state"])

    path = CHG_HOME / "kb-sync" / f"{a.repo.replace('/', '_')}.json"
    state = load_state(path)
    done = set(state["done"])
    todo = {l["key"]: l for l in lessons(a.repo, reverts, flakes, since) if l["key"] not in done}
    todo.update({k: l for k, l in state["pending"].items() if k not in done})
    if a.dry_run or not todo:
        for l in todo.values():
            print(f"would write: {l['title']}")
        print(f"chg-kb-sync: {len(todo)} new lesson(s) for {a.repo}")
        return 0

    import loopctl_client_core as kb
    failed = 0
    for key, l in todo.items():
        try:
            _, outcome = kb.create_article_ex(l["title"], l["body"], a.project_id, category="finding",
                                              tags=l["tags"], skip_low_novelty=True)
            done.add(key)
            state["pending"].pop(key, None)
            print(f"{outcome}: {l['title']}")
        except Exception as e:  # kept pending; the next run retries it
            failed += 1
            state["pending"][key] = l
            print(f"not written ({e}): {l['title']}", file=sys.stderr)
        state["done"] = done
        save_state(path, state)
    return 1 if failed else 0


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--repo", required=True)
    p.add_argument("--project-id", required=True, help="the repo's loopctl project (its channel)")
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--dry-run", action="store_true")
    try:
        return run(p.parse_args(argv))
    except Fatal as e:
        print(f"chg-kb-sync: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
