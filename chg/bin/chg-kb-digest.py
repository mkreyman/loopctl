#!/usr/bin/env python3
"""Writes a repo's daily digest to the loopctl KB, the /debrief analogue of story S13 (#21).

    chg-kb-digest.py --repo owner/name --project-id <loopctl project>
                     [--lookback 7] [--catch-up 7] [--dry-run]

chg-kb-sync.py writes one article per lesson (an auto-revert, a flaky test). Some lessons
live in no single event: a file that review keeps flagging, a reviewer whose findings are
mostly wrong. This writes one `finding` per repo per UTC day that saw a merge or a flaky
test, read from GitHub alone:

  * merged PRs, auto-reverts among them, and flaky-test issues opened that day;
  * the `## Review findings` sections of the day's merged PRs, parsed by claude-config's
    bin/review-dispositions.py: counts by disposition and severity, the noise share
    (wrong + didnt-matter), and sections that did not parse;
  * recurring review patterns: a file flagged in two or more PRs, or a directory flagged
    in three or more, within the `--lookback` days ending that day.

Like chg-kb-sync it is off the merge path (reads GitHub, writes the KB, from cron). A day's
digest carries the tag `idem-chgdigest-<digest of repo and day>`; a day already carrying it
is not posted again, and the post's idempotency key is seeded on it, so a rerun writes
nothing twice even when the day renders differently. ~/.chg/kb-digest/<repo>.json holds
the last day written; a run writes every day after it up to yesterday, at most
`--catch-up` days back, and stops at the first day not stored so the next run starts there
(write() says why digests bypass the novelty gate).
Exit 0 when every due day was written or had nothing to report, 1 when a write failed,
2 on bad arguments, a missing claude-config checkout, an unreadable state file or a GitHub
that did not answer.
"""
import argparse
import hashlib
import importlib.util
import json
import sys
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

BIN = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sync = load("chg_kb_sync", BIN / "chg-kb-sync.py")
Fatal = sync.Fatal
DISPOSITIONS_PY = Path.home() / "workspace/claude-config/bin/review-dispositions.py"
FILE_MIN, DIR_MIN = 2, 3
DIR_DEPTH = 3  # `lib/app` is flagged in nearly every PR, so a directory counts from `lib/app/area`
FILE_CAP, PR_CAP, SUMMARY_CAP = 10, 5, 140
BODY_CAP = 6000


def dispositions():
    if not DISPOSITIONS_PY.exists():
        raise Fatal(f"no {DISPOSITIONS_PY} (claude-config checkout missing)")
    return load("review_dispositions", DISPOSITIONS_PY)


def day_of(ts):
    return ts[:10]


def findings_of(prs, parse):
    """{pr number: (parsed findings, section errors or None when the body has no section)}."""
    out = {}
    for pr in prs:
        r = parse(pr.get("body") or "")
        out[pr["number"]] = (r["findings"], r["errors"] if r["section"] else None)
    return out


def recurring(day, prs, parsed, lookback):
    """Files flagged in FILE_MIN+ distinct PRs, and directories in DIR_MIN+, within the
    lookback window ending on `day`, keeping only those a PR merged on `day` flagged."""
    first = (date.fromisoformat(day) - timedelta(days=lookback - 1)).isoformat()
    files, dirs = defaultdict(dict), defaultdict(set)
    today = set()
    for pr in prs:
        d = day_of(pr["mergedAt"])
        if not first <= d <= day:
            continue
        for f in parsed[pr["number"]][0]:
            path = f["file"]
            files[path].setdefault(pr["number"], f["summary"])
            dirs[str(Path(path).parent)].add(pr["number"])
            if d == day:
                today.add(path)
    hot_files = sorted(((p, files[p]) for p in today if len(files[p]) >= FILE_MIN),
                       key=lambda x: (-len(x[1]), x[0]))
    today_dirs = {str(Path(p).parent) for p in today}
    hot_dirs = sorted(((d, dirs[d]) for d in today_dirs
                       if len(Path(d).parts) >= DIR_DEPTH and len(dirs[d]) >= DIR_MIN),
                      key=lambda x: (-len(x[1]), x[0]))
    return hot_files, hot_dirs


def digest(repo, day, prs, flakes, parsed, lookback):
    """The article for `day`, or None when nothing merged and no flaky test was filed."""
    name = repo.split("/")[-1]
    merged = [p for p in prs if day_of(p["mergedAt"]) == day]
    new_flakes = [i for i in flakes if day_of(i["createdAt"]) == day]
    if not merged and not new_flakes:
        return None
    reverts = [p for p in merged if any(l["name"] == "auto-revert" for l in p.get("labels", []))]
    found, malformed, absent = [], [], 0
    for p in merged:
        fs, errors = parsed[p["number"]]
        if errors is None:
            absent += 1
        elif errors:
            malformed.append(p["number"])
        found.extend(fs)
    by_disp = Counter(f["disposition"] for f in found)
    by_sev = Counter(f["severity"] for f in found)
    noise = by_disp["wrong"] + by_disp["didnt-matter"]
    hot_files, hot_dirs = recurring(day, prs, parsed, lookback)

    lines = [f"chg's daily digest for {repo}, {day} (UTC), from GitHub.", "",
             f"- Merged PRs: {len(merged)}, auto-reverts among them: {len(reverts)}"
             + "".join(f" #{p['number']}" for p in reverts),
             f"- Flaky-test issues opened: {len(new_flakes)}"
             + "".join(f" {i['url']}" for i in new_flakes),
             f"- Review findings: {len(found)} in {len(merged) - absent} reviewed PR(s); "
             f"{absent} PR(s) carry no Review findings section"]
    if found:
        lines.append("  - by disposition: " + ", ".join(f"{k} {v}" for k, v in sorted(by_disp.items())))
        lines.append("  - by severity: " + ", ".join(f"{k} {v}" for k, v in sorted(by_sev.items())))
        lines.append(f"  - noise (wrong + didnt-matter): {noise} of {len(found)} ({100 * noise // len(found)}%)")
    if malformed:
        lines.append("- Sections that did not parse: " + " ".join(f"#{n}" for n in malformed))
    lines += ["", f"## Recurring review patterns (last {lookback} days)", ""]
    if not hot_files and not hot_dirs:
        lines.append("None: no file flagged today was flagged in another PR in the window.")
    for d, nums in hot_dirs:
        lines.append(f"- `{d}/` flagged in {len(nums)} PRs: " + " ".join(f"#{n}" for n in sorted(nums)))
    for path, hits in hot_files[:FILE_CAP]:
        lines.append(f"- `{path}` flagged in {len(hits)} PRs:")
        newest = sorted(hits.items())[-PR_CAP:]
        lines += [f"  - #{n}: {clip(s, SUMMARY_CAP)}" for n, s in newest]
    if len(hot_files) > FILE_CAP:
        lines.append(f"- and {len(hot_files) - FILE_CAP} more file(s) flagged in {FILE_MIN}+ PRs")
    tag = "idem-chgdigest-" + hashlib.sha1(f"{repo}|{day}".encode()).hexdigest()[:12]
    text = "\n".join(lines)
    if len(text) > BODY_CAP:
        text = text[:BODY_CAP - 14].rsplit("\n", 1)[0] + "\n(truncated)"
    return {"title": f"{name} chg daily digest {day}", "body": text,
            "tags": ["chg", name, "daily-digest", tag]}


def clip(s, n):
    return s if len(s) <= n else s[:n - 3].rstrip() + "..."


def write(kb, art, project_id):
    """(done, outcome) for one day's article; done advances the day, and only when the KB
    holds an article for that day.

    A digest is a keyed record, one per repo and day, not a lesson to dedup, so it is
    posted with `force: true`, which bypasses the server's semantic novelty gate. Through
    the gate, consecutive digests share a template (11-09 scored 0.93 against 11-08,
    2026-11-10), so a quiet day could be answered `duplicate` onto another article and
    stored nowhere, and a rerun of a stored day came back `deduplicated` (similarity 1.0)
    before its idempotency key was looked at (measured 2026-11-10, KB affc45a3). Identity is kept by
    the two things the gate never touches: the day's tag, checked first on the lag-free
    list endpoint, and an idempotency key seeded on that tag and the project, which the
    ungated create also honours, for a race between the check and the post."""
    tag = art["tags"][3]
    try:
        if kb.tag_seen(project_id, tag):
            return True, "already stored"
        res = kb.api("POST", "/api/v1/articles", "AGENT", "USER", body={
            "title": art["title"], "body": art["body"], "category": "finding",
            "project_id": project_id, "tags": art["tags"], "force": True,
            "idempotency_key": f"{tag}-{hashlib.sha1(project_id.encode()).hexdigest()[:12]}"})
    except Exception as e:
        return False, f"error: {e}"
    data = res.get("data") if isinstance(res.get("data"), dict) else {}
    if not data.get("id"):
        return False, f"no article in the answer: {json.dumps(res)[:300]}"
    return True, "replayed" if res.get("deduplicated") else "created"


def due_days(last_done, today, catch_up):
    """Every day after `last_done` up to yesterday, never more than `catch_up` days back."""
    start = date.fromisoformat(today) - timedelta(days=catch_up)
    if last_done:
        start = max(start, date.fromisoformat(last_done) + timedelta(days=1))
    end = date.fromisoformat(today) - timedelta(days=1)
    return [(start + timedelta(days=i)).isoformat() for i in range((end - start).days + 1)]


def load_state(path):
    if not path.exists():
        return {"last_done": None}
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as e:
        raise Fatal(f"{path} unreadable ({e}): fix or remove it")


def save_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state))
    tmp.replace(path)


def run(a):
    if a.lookback < 1 or a.catch_up < 1:
        raise Fatal("--lookback and --catch-up must be at least 1")
    path = sync.CHG_HOME / "kb-digest" / f"{a.repo.replace('/', '_')}.json"
    state = load_state(path)
    today = datetime.now(timezone.utc).date().isoformat()
    days = due_days(state.get("last_done"), today, a.catch_up)
    if not days:
        print(f"chg-kb-digest: {a.repo} is up to date")
        return 0
    parse = dispositions().parse
    if not a.dry_run:
        if not (sync.CLIENT_DIR / "loopctl_client_core.py").exists():
            raise Fatal(f"no KB client at {sync.CLIENT_DIR} (claude-config checkout missing)")
        sync.ensure_requests()
        sys.path.insert(0, str(sync.CLIENT_DIR))
    since = (date.fromisoformat(days[0]) - timedelta(days=a.lookback - 1)).isoformat()
    prs = sync.gh(["pr", "list", "--repo", a.repo, "--state", "merged", "--search", f"merged:>={since}",
                   "--limit", "1000", "--json", "number,url,body,mergedAt,labels"])
    flakes = sync.gh(["issue", "list", "--repo", a.repo, "--label", "test-flakiness", "--state", "all",
                      "--search", f"created:>={days[0]}", "--limit", "200", "--json", "url,createdAt"])
    parsed = findings_of(prs, parse)

    kb = None
    for day in days:
        art = digest(a.repo, day, prs, flakes, parsed, a.lookback)
        if art is None:
            print(f"{day}: nothing merged, nothing to write")
        elif a.dry_run:
            print(f"would write: {art['title']}\n{art['body']}\n")
            continue
        else:
            if kb is None:
                import loopctl_client_core as kb
            stored, outcome = write(kb, art, a.project_id)
            if not stored:  # the next run starts from this day
                print(f"not written ({outcome}): {art['title']}", file=sys.stderr)
                return 1
            print(f"{outcome}: {art['title']}")
        if not a.dry_run:
            state["last_done"] = day
            save_state(path, state)
    return 0


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--repo", required=True)
    p.add_argument("--project-id", required=True, help="the repo's loopctl project (its channel)")
    p.add_argument("--lookback", type=int, default=7, help="days a recurring pattern is counted over")
    p.add_argument("--catch-up", type=int, default=7, help="most days back a run will write")
    p.add_argument("--dry-run", action="store_true")
    try:
        return run(p.parse_args(argv))
    except Fatal as e:
        print(f"chg-kb-digest: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
