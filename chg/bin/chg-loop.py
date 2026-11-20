#!/usr/bin/env python3
"""The improvement loop, phase 1 (story S14a, #97; the full design is S14, #22).

    chg-loop.py --repo owner/name [--repo ...] [--harness-log PATH]
                [--config .chg/loop.toml] [--dry-run]

Reads failures that are already recorded, gives each recurring cause a fingerprint, and
files one `chg-loop` GitHub issue per fingerprint in the repo that owns the cause. It
builds no executor: loopctl's delivery loop, or a person, works the issues.

Sensors (phase 1: only what GitHub or a log already holds):
  revert   a merged `auto-revert` PR; the key is the set of directories the culprit touched
  flaky    a `test-flakiness` issue; one occurrence per verifier run that saw it flake
  review   a file flagged in the `## Review findings` section of a merged PR (parsed by
           claude-config's bin/review-dispositions.py); one occurrence per PR
  harness  a line in --harness-log (JSON: at, source, check, host, detail) that
           harness-selftest.sh or fleet-sync.sh appends when it goes red

Pipeline: fingerprint = sha256(sensor, owning repo, natural key). ~/.chg/loop/state.json
keeps each fingerprint's occurrences, its issue and how often that issue was closed. A
fingerprint with no issue is filed once its occurrences within the sensor's window reach
the threshold, at most `daily_cap` new issues per owning repo per UTC day (the rest wait
for the next day). A new occurrence of an open issue's fingerprint is a comment. A closed
issue is reopened with the new evidence when its fingerprint fires within `reopen_days` of
the close, or reaches the threshold again later. One closed `escalate_after_closes` times
is not reopened: the recurrence is filed as `chg-loop-escalated`, for Mark, not the loop.

Each issue body carries `<!-- chg-loop:<fingerprint> -->`, so a lost state file finds the
issue again instead of filing a second one, and each comment names the occurrences it adds.
--dry-run prints the plan and writes nothing, and the plan is deterministic.
Exit 0 when every action was taken, 1 when a GitHub write failed (the next run retries
it), 2 on bad arguments, an unreadable state or config file, or a GitHub that did not
answer a read.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tomllib
from datetime import date, timedelta
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

LABEL, ESCALATED = "chg-loop", "chg-loop-escalated"
# chg's source lives under chg/ in the loopctl repository (US-52.5), so chg's own causes are
# filed there.
CLAUDE_CONFIG, CHG = "mkreyman/claude-config", "mkreyman/loopctl"
# A path under these claude-config directories is harness: its owner is claude-config.
HARNESS_DIRS = ("hooks", "skills", "agents", "bin")
BODY_CAP = 60000
NOISE = ("wrong", "didnt-matter")

DEFAULTS = {
    "sensor": {
        "revert": {"threshold": 1, "window_days": 14},
        "flaky": {"threshold": 2, "window_days": 30},
        "review": {"threshold": 4, "window_days": 14},
        "harness": {"threshold": 1, "window_days": 14},
    },
    "guards": {"daily_cap": 3, "reopen_days": 14, "escalate_after_closes": 2, "quiet_days": 14},
}


def config(path):
    """DEFAULTS, overridden by the TOML at `path` when it exists."""
    cfg = json.loads(json.dumps(DEFAULTS))
    if path and Path(path).exists():
        try:
            got = tomllib.loads(Path(path).read_text())
        except (OSError, tomllib.TOMLDecodeError) as e:
            raise Fatal(f"{path}: {e}")
        for name, over in got.get("sensor", {}).items():
            if name not in cfg["sensor"]:
                raise Fatal(f"{path}: unknown sensor {name!r}")
            cfg["sensor"][name].update(over)
        cfg["guards"].update(got.get("guards", {}))
    for name, s in cfg["sensor"].items():
        if s["threshold"] < 1 or s["window_days"] < 1:
            raise Fatal(f"sensor {name}: threshold and window_days must be at least 1")
    return cfg


# ---------------------------------------------------------------------------------------
# Routing and fingerprints.

def route(source_repo, path=None):
    """The repo that owns a cause seen in `source_repo`, at `path` when it is a file."""
    if path:
        p = path.lstrip("./")
        m = re.search(r"(?:^|/)claude-config/(.+)$", p)
        if m and m.group(1).split("/")[0] in HARNESS_DIRS:
            return CLAUDE_CONFIG
        # chg's checkout, seen from any source repo: workspace/loopctl/chg/ now, and the
        # retired workspace/chg/, which rows written before the import still name
        # (AC-52.5.7). A relative chg/ path under a loopctl source is loopctl's own below.
        if re.search(r"(?:^|/)workspace/(?:loopctl/)?chg/", p):
            return CHG
        if source_repo == CLAUDE_CONFIG and p.split("/")[0] in HARNESS_DIRS:
            return CLAUDE_CONFIG
    return source_repo


def fingerprint(sensor, owner, key):
    return hashlib.sha256(f"{sensor}\x00{owner}\x00{key}".encode()).hexdigest()[:16]


def occurrence(sensor, source, owner, key, url, day, note):
    return {"fp": fingerprint(sensor, owner, key), "sensor": sensor, "source": source,
            "owner": owner, "key": key, "url": url, "date": day, "note": note}


# ---------------------------------------------------------------------------------------
# Sensors: each turns already-fetched records into occurrences.

REVERT_MARK = re.compile(r"<!-- chg-revert:([0-9a-f]{7,64}) -->")
FLAKY_MARK = re.compile(r"<!-- chg-flaky:(.+?) -->")
FLAKY_RUN = re.compile(r"<!-- chg-flaky-run:([^:]+):(.+?) -->")


def modules(files):
    """The directories a commit touched, as one sorted key."""
    return ",".join(sorted({str(Path(f).parent) for f in files})) or "."


def revert_occurrences(repo, prs, files_of):
    """`prs`: merged auto-revert PRs; `files_of(sha)`: the culprit's changed files."""
    out = []
    for pr in prs:
        m = REVERT_MARK.search(pr.get("body") or "")
        if not m or not pr.get("mergedAt"):
            continue
        culprit = m.group(1)
        key = modules(files_of(culprit))
        out.append(occurrence("revert", repo, route(repo), key, pr["url"], pr["mergedAt"][:10],
                              f"reverted {culprit[:12]} ({pr['url']}); it touched {key}"))
    return out


def flaky_occurrences(repo, issues):
    """`issues`: test-flakiness issues with body and comments. Each verifier run that saw
    the test flake left a `chg-flaky-run` marker in the body (the first) or a comment."""
    out = []
    for i in issues:
        body = i.get("body") or ""
        m = FLAKY_MARK.search(body)
        if not m:
            continue
        test = m.group(1)
        texts = [(body, i["createdAt"])] + [(c.get("body") or "", c["createdAt"])
                                            for c in i.get("comments", [])]
        for text, at in texts:
            for run, tid in FLAKY_RUN.findall(text):
                if tid == test:
                    out.append(occurrence("flaky", repo, route(repo), test,
                                          f"{i['url']}#run-{run}", at[:10],
                                          f"`{test}` flaked in run {run} ({i['url']})"))
    return out


def review_occurrences(repo, prs, parse):
    """One occurrence per (flagged file, merged PR)."""
    out = []
    for pr in prs:
        if not pr.get("mergedAt"):
            continue
        seen = set()
        for f in parse(pr.get("body") or "")["findings"]:
            path = f["file"]
            # A finding the PR disproved, or one that changed nothing, is reviewer noise
            # about the file, not a defect it keeps producing.
            if f.get("disposition") in NOISE or path in seen:
                continue
            seen.add(path)
            out.append(occurrence("review", repo, route(repo, path), path, pr["url"],
                                  pr["mergedAt"][:10],
                                  f"#{pr['number']}: {f['summary'][:200]} ({f['disposition']})"))
    return out


def harness_occurrences(lines):
    out = []
    for line in lines:
        try:
            e = json.loads(line)
            key = f"{e['source']}:{e['check']}"
            at, host = e["at"], e.get("host", "?")
        except (json.JSONDecodeError, KeyError, TypeError):
            continue
        out.append(occurrence("harness", CLAUDE_CONFIG, CLAUDE_CONFIG, key,
                              f"harness:{host}:{at}:{key}", at[:10],
                              f"{key} red on {host} at {at}: {str(e.get('detail', ''))[:300]}"))
    return out


# ---------------------------------------------------------------------------------------
# State.

def load_state(path):
    if not path.exists():
        return {"fingerprints": {}, "filed": {}}
    try:
        s = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        raise Fatal(f"{path}: {e} (move it aside to start over; issues are found by marker)")
    s.setdefault("fingerprints", {})
    s.setdefault("filed", {})
    return s


def save_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(state, indent=1, sort_keys=True))
    tmp.replace(path)


def marker(fp):
    return f"<!-- chg-loop:{fp} -->"


# ---------------------------------------------------------------------------------------
# The plan: pure, so it is tested on fixtures and a dry run prints exactly what a run does.

def plan(state, occs, issues, cfg, today):
    """Returns the actions for `occs` (all occurrences the sensors see now), given `state`
    and `issues` ({owner: [{number, url, state, closedAt, body, labels}]}), and updates
    `state` in place as a run that takes every action would. Actions are dicts with `do`
    in file, comment, reopen, escalate, wait."""
    g = cfg["guards"]
    fps = state["fingerprints"]
    by_fp = {}
    for o in occs:
        by_fp.setdefault(o["fp"], []).append(o)
    # A fingerprint whose issue state forgot: find the issue by its marker.
    for fp, os_ in by_fp.items():
        rec = fps.setdefault(fp, {"sensor": os_[0]["sensor"], "owner": os_[0]["owner"],
                                  "key": os_[0]["key"], "seen": {}, "issue": None,
                                  "closes": 0, "last_closed_at": None, "escalated": None})
        if rec["issue"] is None and rec["escalated"] is None:
            found = False
            for i in issues.get(rec["owner"], []):
                if marker(fp) in (i.get("body") or ""):
                    found = True
                    if any(lb.get("name") == ESCALATED for lb in i.get("labels", [])):
                        rec["escalated"] = i["url"]
                    else:
                        rec["issue"] = i["url"]
            if found:
                # What the sensors see now is taken as already reported, so a lost state
                # file costs at most the comments for occurrences it had not yet recorded,
                # never a repeat of the whole evidence list.
                for o in os_:
                    rec["seen"].setdefault(o["url"], {"date": o["date"], "note": o["note"]})
    filed_today = {o: n.get(today, 0) for o, n in state["filed"].items()}
    actions = []
    # The most frequent cause first, so the daily cap spends itself on the loudest ones.
    def loudness(f):
        days = cfg["sensor"][fps[f]["sensor"]]["window_days"]
        first = (date.fromisoformat(today) - timedelta(days=days - 1)).isoformat()
        return -sum(1 for o in by_fp[f] if o["date"] >= first), f

    for fp in sorted(by_fp, key=loudness):
        rec = fps[fp]
        sensor = cfg["sensor"][rec["sensor"]]
        new = sorted((o for o in by_fp[fp] if o["url"] not in rec["seen"]),
                     key=lambda o: (o["date"], o["url"]))
        evidence = {o["url"]: o for o in by_fp[fp]}
        for o in new:
            rec["seen"][o["url"]] = {"date": o["date"], "note": o["note"]}
        first = (date.fromisoformat(today) - timedelta(days=sensor["window_days"] - 1)).isoformat()
        in_window = sorted((u for u, s in rec["seen"].items() if s["date"] >= first),
                           key=lambda u: (rec["seen"][u]["date"], u))
        issue = next((i for i in issues.get(rec["owner"], []) if i["url"] == rec["issue"]), None)
        if issue and issue["state"].upper() == "CLOSED" and issue.get("closedAt") != rec["last_closed_at"]:
            rec["closes"] += 1
            rec["last_closed_at"] = issue.get("closedAt")
        base = {"fp": fp, "owner": rec["owner"], "sensor": rec["sensor"], "key": rec["key"]}

        if rec["escalated"]:
            if new:
                actions.append({**base, "do": "comment", "issue": rec["escalated"],
                                "occurrences": [_ev(o) for o in new]})
            continue
        def capped():
            """Whether the owner's new issues today (filed and escalated) are at the cap;
            when not, counts this one."""
            if filed_today.get(rec["owner"], 0) >= g["daily_cap"]:
                actions.append({**base, "do": "wait",
                                "why": f"{rec['owner']} has filed {g['daily_cap']} today"})
                return True
            filed_today[rec["owner"]] = filed_today.get(rec["owner"], 0) + 1
            state["filed"].setdefault(rec["owner"], {})[today] = filed_today[rec["owner"]]
            return False

        if rec["issue"] is None:
            if len(in_window) < sensor["threshold"] or capped():
                continue
            actions.append({**base, "do": "file", "label": LABEL,
                            "occurrences": [_ev(evidence.get(u), rec, u) for u in in_window]})
            rec["issue"] = "(pending)"
            continue
        if not new:
            continue
        if issue is None or issue["state"].upper() != "CLOSED":
            actions.append({**base, "do": "comment", "issue": rec["issue"],
                            "occurrences": [_ev(o) for o in new]})
            continue
        if rec["closes"] >= g["escalate_after_closes"]:
            if capped():
                continue
            actions.append({**base, "do": "escalate", "label": ESCALATED, "issue": rec["issue"],
                            "closes": rec["closes"], "occurrences": [_ev(o) for o in new]})
            rec["escalated"] = "(pending)"
            continue
        closed_on = (issue.get("closedAt") or "")[:10]
        soon = (date.fromisoformat(closed_on) + timedelta(days=g["reopen_days"])).isoformat() \
            if closed_on else ""
        after = [u for u in in_window if rec["seen"][u]["date"] > closed_on]
        # Only what happened after the close is a recurrence: evidence dated before it was
        # what the fix answered, however late this run first sees it.
        if any(closed_on < o["date"] <= soon for o in new) or len(after) >= sensor["threshold"]:
            actions.append({**base, "do": "reopen", "issue": rec["issue"],
                            "occurrences": [_ev(o) for o in new]})
    return actions


def _ev(o, rec=None, url=None):
    if o is None:
        s = rec["seen"][url]
        return {"url": url, "date": s["date"], "note": s["note"]}
    return {"url": o["url"], "date": o["date"], "note": o["note"]}


# ---------------------------------------------------------------------------------------
# Rendering.

SENSOR_TITLE = {
    "revert": "trunk reverts touching {key}",
    "flaky": "flaky test {key}",
    "review": "review keeps flagging {key}",
    "harness": "harness check {key} goes red",
}


def title(a):
    return f"chg-loop: {SENSOR_TITLE[a['sensor']].format(key=a['key'])}"[:250]


def evidence_lines(occs):
    return "\n".join(f"- {o['date']}: {o['note']}" for o in occs)


def issue_body(a, cfg):
    g = cfg["guards"]
    s = cfg["sensor"][a["sensor"]]
    if a["do"] == "escalate":
        lead = (f"This cause recurred after its issue {a['issue']} was closed {a['closes']} "
                f"times, so chg-loop stops reopening it and asks Mark instead.")
    else:
        lead = (f"chg-loop saw this cause {len(a['occurrences'])} time(s) within "
                f"{s['window_days']} days (threshold {s['threshold']}, sensor `{a['sensor']}`).")
    body = (f"{lead}\n\nKey: `{a['key']}`\n\n## Evidence\n\n{evidence_lines(a['occurrences'])}\n\n"
            f"## Closure\n\nClose this when the cause is fixed. It counts as fixed once the "
            f"fingerprint stays silent for {g['quiet_days']} days. A recurrence within "
            f"{g['reopen_days']} days of closing reopens it, and a recurrence after it was "
            f"closed {g['escalate_after_closes']} times is filed as `{ESCALATED}` for Mark.\n\n"
            f"Fingerprint `{a['fp']}`\n{marker(a['fp'])}\n")
    return body[:BODY_CAP]


def comment_body(a):
    verb = "Reopened: it recurred" if a["do"] == "reopen" else "Seen again"
    return f"{verb}.\n\n{evidence_lines(a['occurrences'])}\n"


def describe(a):
    head = f"{a['do']:8} {a['owner']} {a['sensor']} {a['key']} [{a['fp']}]"
    if a["do"] == "wait":
        return f"{head}: {a['why']}"
    target = f" on {a['issue']}" if a.get("issue") else ""
    return f"{head}{target}: {len(a['occurrences'])} occurrence(s)"


# ---------------------------------------------------------------------------------------
# GitHub.

def gh_write(args):
    try:
        out = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=120,
                             env={k: v for k, v in os.environ.items()
                                  if k != "GH_TOKEN"})
    except subprocess.TimeoutExpired:
        return None, "no answer in 120 s"
    if out.returncode != 0:
        return None, out.stderr.strip()[-300:]
    return out.stdout.strip(), None


def ensure_label(repo, name, color, desc):
    gh_write(["label", "create", name, "--repo", repo, "--color", color,
              "--description", desc, "--force"])


def execute(a, cfg):
    """Takes action `a`. Returns (the new issue's URL or None, an error or None)."""
    if a["do"] in ("file", "escalate"):
        ensure_label(a["owner"], a["label"], "5319E7" if a["do"] == "file" else "B60205",
                     "Filed by chg's improvement loop" if a["do"] == "file"
                     else "A chg-loop cause that kept recurring: for Mark")
        out, err = gh_write(["issue", "create", "--repo", a["owner"], "--title", title(a),
                             "--body", issue_body(a, cfg), "--label", a["label"]])
        return (None, err) if err else (out.splitlines()[-1], None)
    if a["do"] == "reopen":
        _, err = gh_write(["issue", "reopen", a["issue"], "--comment", comment_body(a)])
        return None, err
    _, err = gh_write(["issue", "comment", a["issue"], "--body", comment_body(a)])
    return None, err


def fetch(repo, since, parse, need_reviews):
    """GitHub's records for `repo` since `since`, as occurrences."""
    reverts = sync.gh(["pr", "list", "--repo", repo, "--label", "auto-revert", "--state", "merged",
                       "--search", f"merged:>={since}", "--limit", "200",
                       "--json", "number,url,body,mergedAt"])

    def files_of(sha):
        got = sync.gh(["api", f"repos/{repo}/commits/{sha}", "--jq", "[.files[].filename]"])
        return got if isinstance(got, list) else []

    flakes = sync.gh(["issue", "list", "--repo", repo, "--label", "test-flakiness",
                      "--state", "all", "--search", f"updated:>={since}", "--limit", "500",
                      "--json", "url,body,comments,createdAt"])
    occs = revert_occurrences(repo, reverts, files_of) + flaky_occurrences(repo, flakes)
    if need_reviews:
        prs = sync.gh(["pr", "list", "--repo", repo, "--state", "merged",
                       "--search", f"merged:>={since}", "--limit", "1000",
                       "--json", "number,url,body,mergedAt"])
        occs += review_occurrences(repo, prs, parse)
    return occs


def loop_issues(owner):
    return sync.gh(["issue", "list", "--repo", owner, "--label", LABEL, "--state", "all",
                    "--limit", "1000", "--json", "number,url,state,closedAt,body,labels"]) + \
        sync.gh(["issue", "list", "--repo", owner, "--label", ESCALATED, "--state", "all",
                 "--limit", "1000", "--json", "number,url,state,closedAt,body,labels"])


def lock(path):
    """Holds the state's lock until the process exits. Every run shares one state file,
    whichever repos it reads, so two overlapping cron lines would each write back the
    whole file over the other's issues, cap counts and closes, and both could file the
    same harness cause. A second run waits for the first."""
    path.parent.mkdir(parents=True, exist_ok=True)
    f = open(path.with_suffix(".lock"), "a")
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def run(a):
    cfg = config(a.config)
    path = sync.CHG_HOME / "loop" / "state.json"
    held = None if a.dry_run else lock(path)  # noqa: F841 (released at exit)
    state = load_state(path)
    today = a.today or date.today().isoformat()
    span = max(s["window_days"] for s in cfg["sensor"].values())
    since = (date.fromisoformat(today) - timedelta(days=span)).isoformat()
    parse = None
    if a.repo:
        if not DISPOSITIONS_PY.exists():
            raise Fatal(f"no {DISPOSITIONS_PY} (claude-config checkout missing)")
        parse = load("review_dispositions", DISPOSITIONS_PY).parse
    occs = []
    for repo in a.repo:
        occs += fetch(repo, since, parse, True)
    if a.harness_log:
        try:
            lines = Path(a.harness_log).read_text().splitlines()
        except FileNotFoundError:
            lines = []
        except OSError as e:
            raise Fatal(f"{a.harness_log}: {e}")
        occs += [o for o in harness_occurrences(lines) if o["date"] >= since]
    owners = sorted({o["owner"] for o in occs})
    issues = {o: loop_issues(o) for o in owners}
    work = json.loads(json.dumps(state))
    actions = plan(work, occs, issues, cfg, today)
    if not actions:
        print("chg-loop: nothing to file")
    if a.dry_run:
        for act in actions:
            print("would " + describe(act))
        return 0
    persist, failed = settle(state, work, actions, lambda act: execute(act, cfg), today, path)
    save_state(path, persist)
    return 1 if failed else 0


def settle(state, work, actions, take, today, path=None):
    """Takes each action and returns (the state to keep, how many failed). A fingerprint
    with no action keeps what the plan recorded (its occurrences, a close it noticed). One
    with an action keeps its old record until the action succeeds, so a failed or
    interrupted write is planned again on the next run, never recorded as done; so does one
    waiting on the cap, whose escalation hangs on occurrences it must still see as new.
    The state is saved after each action when `path` is given."""
    acted = {act["fp"] for act in actions}
    persist = json.loads(json.dumps(state))
    for fp, rec in work["fingerprints"].items():
        if fp not in acted:
            persist["fingerprints"][fp] = rec
    failed = 0
    for act in actions:
        if act["do"] == "wait":
            print(describe(act))
            continue
        url, err = take(act)
        if err:
            failed += 1
            print(f"failed: {describe(act)}: {err}", file=sys.stderr)
            continue
        rec = json.loads(json.dumps(work["fingerprints"][act["fp"]]))
        if act["do"] in ("file", "escalate"):
            rec["issue" if act["do"] == "file" else "escalated"] = url
            day = persist["filed"].setdefault(act["owner"], {})
            day[today] = day.get(today, 0) + 1
        persist["fingerprints"][act["fp"]] = rec
        print(describe(act))
        if path:
            save_state(path, persist)
    return persist, failed


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--repo", action="append", default=[], help="owner/name; repeatable")
    p.add_argument("--harness-log", help="JSON lines of red harness checks")
    p.add_argument("--config", default=str(BIN.parent / ".chg" / "loop.toml"))
    p.add_argument("--today", help=argparse.SUPPRESS)
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)
    if not a.repo and not a.harness_log:
        p.error("give at least one --repo or --harness-log")
    try:
        return run(a)
    except Fatal as e:
        print(f"chg-loop: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
