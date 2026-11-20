#!/usr/bin/env python3
"""Tests for bin/chg-loop.py on fixture data; nothing reaches GitHub.
Run: python3 tests/loop-test.py"""
import importlib.util
import json
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "loop", Path(__file__).resolve().parent.parent / "bin" / "chg-loop.py")
lp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lp)

HCB, CC, CHG = "mkreyman/home_care_billing", "mkreyman/claude-config", "mkreyman/loopctl"
assert lp.CHG == CHG, "chg's own causes are filed on the loopctl repository (US-52.5)"
cfg = lp.config(None)


def fresh():
    return {"fingerprints": {}, "filed": {}}


def run_once(state, occs, issues, today, fail=()):
    """One real run with a fake GitHub: returns (new state, actions, what was written)."""
    work = json.loads(json.dumps(state))
    actions = lp.plan(work, occs, issues, cfg, today)
    wrote = []

    def take(act):
        if act["fp"] in fail:
            return None, "boom"
        wrote.append(act)
        if act["do"] in ("file", "escalate"):
            n = sum(len(v) for v in issues.values()) + len(wrote)
            url = f"https://github.com/{act['owner']}/issues/{n}"
            issues.setdefault(act["owner"], []).append(
                {"number": n, "url": url, "state": "OPEN", "closedAt": None,
                 "body": lp.issue_body(act, cfg),
                 "labels": [{"name": act["label"]}]})
            return url, None
        return None, None

    persist, failed = lp.settle(state, work, actions, take, today)
    return persist, actions, wrote, failed


# -- routing ----------------------------------------------------------------------------
assert lp.route(HCB, "lib/hcb/billing/claim.ex") == HCB
assert lp.route(HCB, "/home/m/workspace/claude-config/hooks/gate.sh") == CC
assert lp.route(HCB, "~/workspace/claude-config/docs/x.md") == HCB, "only harness dirs route"
assert lp.route(CC, "hooks/block-complex-bash.sh") == CC
assert lp.route(CC, "skills/handoff/SKILL.md") == CC
assert lp.route(HCB, "/home/m/workspace/chg/cli/src/main.rs") == CHG
assert lp.route(CHG, "chg/cli/src/main.rs") == CHG
assert lp.route(HCB, "/home/m/workspace/loopctl/chg/cli/src/main.rs") == CHG, "the new checkout routes"
assert lp.route(HCB, "~/workspace/loopctl/chg/cli/src/shadow.rs") == CHG
assert lp.route(CHG, "/home/m/workspace/loopctl/chg/cli/src/main.rs") == CHG
assert lp.route(CC, "/home/m/workspace/loopctl/chg/bin/chg-loop.py") == CHG
assert lp.route(HCB, "/x/workspace/loopctl/lib/foo.ex") == HCB, "loopctl server code is not chg"
assert lp.route(HCB, "/x/workspace/loopctl/chgx/foo.rs") == HCB
assert lp.route(HCB, "/x/workspace/loopctl-old/chg/cli/x.rs") == HCB
assert lp.route(HCB) == HCB

# -- fingerprints -----------------------------------------------------------------------
fp = lp.fingerprint("flaky", HCB, "test/a_test.exs:12")
assert fp == lp.fingerprint("flaky", HCB, "test/a_test.exs:12") and len(fp) == 16
assert fp != lp.fingerprint("flaky", CC, "test/a_test.exs:12")
assert fp != lp.fingerprint("review", HCB, "test/a_test.exs:12")

# -- sensors ----------------------------------------------------------------------------
flake_issue = {
    "url": "https://github.com/x/i/5", "createdAt": "2026-11-10T01:00:00Z",
    "body": "x <!-- chg-flaky:test/a_test.exs:12 -->\n<!-- chg-flaky-run:101:test/a_test.exs:12 -->",
    "comments": [{"createdAt": "2026-11-12T01:00:00Z",
                  "body": "again <!-- chg-flaky-run:102:test/a_test.exs:12 -->"},
                 {"createdAt": "2026-11-12T02:00:00Z", "body": "a person's comment"}],
}
fl = lp.flaky_occurrences(HCB, [flake_issue])
assert [(o["url"], o["date"]) for o in fl] == [
    ("https://github.com/x/i/5#run-101", "2026-11-10"),
    ("https://github.com/x/i/5#run-102", "2026-11-12")], fl
assert {o["fp"] for o in fl} == {fp}

revert_pr = {"number": 9, "url": "https://github.com/x/pull/9", "mergedAt": "2026-11-11T00:00:00Z",
             "body": "Revert. <!-- chg-revert:0123456789abcdef -->"}
rv = lp.revert_occurrences(HCB, [revert_pr, {"url": "u", "mergedAt": "x", "body": "no marker"}],
                           lambda sha: ["lib/b/x.ex", "lib/a/y.ex", "lib/a/z.ex"])
assert len(rv) == 1 and rv[0]["key"] == "lib/a,lib/b", rv


def parse(body):
    return {"findings": [json.loads(line) for line in body.splitlines() if line.startswith("{")]}


def pr(n, day, *files):
    return {"number": n, "url": f"https://github.com/x/pull/{n}", "mergedAt": f"{day}T00:00:00Z",
            "body": "\n".join(json.dumps({"file": f, "summary": f"s{n}", "disposition": "fixed"})
                              for f in files)}


rw = lp.review_occurrences(HCB, [pr(1, "2026-11-01", "lib/a.ex", "lib/a.ex",
                                    "/w/claude-config/hooks/h.sh")], parse)
assert [(o["key"], o["owner"]) for o in rw] == [("lib/a.ex", HCB),
                                                ("/w/claude-config/hooks/h.sh", CC)], rw

hl = lp.harness_occurrences([
    json.dumps({"at": "2026-11-12T03:00:00Z", "source": "harness-selftest", "check": "mcp",
                "host": "minis", "detail": "loopctl down"}), "not json"])
assert len(hl) == 1 and hl[0]["owner"] == CC and hl[0]["key"] == "harness-selftest:mcp"

# -- threshold: flaky needs 2 occurrences --------------------------------------------------
_, actions, _, _ = run_once(fresh(), fl[:1], {}, "2026-11-12")
assert actions == [], actions
state, actions, wrote, _ = run_once(fresh(), fl, {}, "2026-11-12")
assert [a["do"] for a in actions] == ["file"] and wrote[0]["owner"] == HCB
assert len(wrote[0]["occurrences"]) == 2
issue_url = state["fingerprints"][fp]["issue"]
assert issue_url.startswith("https://github.com/" + HCB)
assert lp.marker(fp) in lp.issue_body(wrote[0], cfg)

# -- two dry runs print the same list; a real run then files nothing new ----------------
issues = {}
occs = fl + rv + hl
plans = []
for _ in range(2):
    work = json.loads(json.dumps(fresh()))
    plans.append([lp.describe(a) for a in lp.plan(work, occs, issues, cfg, "2026-11-12")])
assert plans[0] == plans[1] and len(plans[0]) == 3, plans
state, actions, wrote, _ = run_once(fresh(), occs, issues, "2026-11-12")
assert sorted(a["do"] for a in actions) == ["file"] * 3
state2, actions2, wrote2, _ = run_once(state, occs, issues, "2026-11-12")
assert actions2 == [] and wrote2 == [], actions2
# A lost state file finds the issues by their markers instead of filing again.
_, actions3, _, _ = run_once(fresh(), occs, issues, "2026-11-12")
assert actions3 == [], actions3

# -- a new occurrence of an open issue is a comment --------------------------------------
more = lp.flaky_occurrences(HCB, [{**flake_issue, "comments": flake_issue["comments"] + [
    {"createdAt": "2026-11-13T00:00:00Z", "body": "<!-- chg-flaky-run:103:test/a_test.exs:12 -->"}]}])
state3, actions, _, _ = run_once(state, more + rv + hl, issues, "2026-11-13")
assert [(a["do"], len(a["occurrences"])) for a in actions] == [("comment", 1)], actions

# -- the daily cap: K+1 eligible fingerprints file K, the rest wait ----------------------
cap = cfg["guards"]["daily_cap"]
reverts = [{"number": n, "url": f"https://github.com/x/pull/{n}", "mergedAt": "2026-11-12T00:00:00Z",
            "body": f"<!-- chg-revert:{n:040x} -->"} for n in range(cap + 1)]
many = lp.revert_occurrences(HCB, reverts, lambda sha: [f"lib/m{int(sha, 16)}/x.ex"])
issues = {}
state, actions, wrote, _ = run_once(fresh(), many, issues, "2026-11-12")
assert [a["do"] for a in actions].count("file") == cap and len(wrote) == cap, actions
assert [a["do"] for a in actions].count("wait") == 1
state, actions, wrote, _ = run_once(state, many, issues, "2026-11-12")
assert [a["do"] for a in actions] == ["wait"], "the cap holds for the rest of the day"
state, actions, wrote, _ = run_once(state, many, issues, "2026-11-13")
assert [a["do"] for a in actions] == ["file"], "and the next day it files"
# Another repo's cap is its own.
other = lp.revert_occurrences(CC, reverts[:1], lambda sha: ["hooks"])
_, actions, _, _ = run_once(state, many + other, issues, "2026-11-13")
assert [(a["do"], a["owner"]) for a in actions] == [("file", CC)], actions

# -- a failed write is planned again, never recorded as done -----------------------------
issues = {}
state, actions, wrote, failed = run_once(fresh(), rv, issues, "2026-11-12", fail={rv[0]["fp"]})
assert failed == 1 and state["fingerprints"] == {} and state["filed"] == {}
_, actions, wrote, _ = run_once(state, rv, issues, "2026-11-12")
assert [a["do"] for a in actions] == ["file"]

# -- closure: reopen within 14 days, escalate after two closes ---------------------------
issues = {}
first = lp.revert_occurrences(HCB, [revert_pr], lambda sha: ["lib/a/x.ex"])
state, _, _, _ = run_once(fresh(), first, issues, "2026-11-11")
rec_fp = first[0]["fp"]
issue = issues[HCB][0]


def again(n, day):
    return lp.revert_occurrences(HCB, [{**revert_pr, "url": f"https://github.com/x/pull/{n}",
                                        "mergedAt": f"{day}T00:00:00Z"}], lambda sha: ["lib/a/x.ex"])


issue.update(state="CLOSED", closedAt="2026-11-12T00:00:00Z")
state, actions, _, _ = run_once(state, first + again(20, "2026-11-20"), issues, "2026-11-20")
assert [a["do"] for a in actions] == ["reopen"], actions
assert state["fingerprints"][rec_fp]["closes"] == 1
issue.update(state="OPEN")
issue.update(state="CLOSED", closedAt="2026-11-21T00:00:00Z")
occ = first + again(20, "2026-11-20") + again(30, "2026-11-25")
state, actions, wrote, _ = run_once(state, occ, issues, "2026-11-25")
assert [a["do"] for a in actions] == ["escalate"], actions
assert wrote[0]["label"] == "chg-loop-escalated"
assert state["fingerprints"][rec_fp]["escalated"].startswith("https://")
# Further recurrences go to the escalated issue, never reopen the loop's.
state, actions, _, _ = run_once(state, occ + again(40, "2026-11-26"), issues, "2026-11-26")
assert [(a["do"], a["issue"]) for a in actions] == [
    ("comment", state["fingerprints"][rec_fp]["escalated"])], actions

# -- a recurrence long after the close needs the threshold again -------------------------
cfg2 = json.loads(json.dumps(cfg))
issues = {}
state, _, _, _ = run_once(fresh(), first, issues, "2026-11-11")
issues[HCB][0].update(state="CLOSED", closedAt="2026-11-12T00:00:00Z")
cfg["sensor"]["revert"]["threshold"] = 2
cfg["sensor"]["revert"]["window_days"] = 60
state, actions, _, _ = run_once(state, first + again(50, "2026-12-30"), issues, "2026-12-30")
assert actions == [], "one occurrence after 14 quiet days is below the threshold of 2"
state, actions, _, _ = run_once(state, first + again(50, "2026-12-30") + again(51, "2026-12-31"),
                                issues, "2026-12-31")
assert [a["do"] for a in actions] == ["reopen"], actions
cfg.clear()
cfg.update(cfg2)

# -- review noise does not count ---------------------------------------------------------
noisy = [{**pr(n, "2026-11-10", "lib/n.ex"),
          "body": json.dumps({"file": "lib/n.ex", "summary": "s", "disposition": d})}
         for n, d in [(60, "wrong"), (61, "didnt-matter"), (62, "fixed"), (63, "fixed")]]
assert [o["url"][-2:] for o in lp.review_occurrences(HCB, noisy, parse)] == ["62", "63"]

# -- evidence dated before a close is not a recurrence -----------------------------------
issues = {}
state, _, _, _ = run_once(fresh(), first, issues, "2026-11-11")
issues[HCB][0].update(state="CLOSED", closedAt="2026-11-12T00:00:00Z")
state, actions, _, _ = run_once(state, first + again(70, "2026-11-11"), issues, "2026-11-14")
assert actions == [], "an occurrence the run saw late, dated before the close, reopens nothing"
state, actions, _, _ = run_once(state, first + again(70, "2026-11-11") + again(71, "2026-11-13"),
                                issues, "2026-11-14")
assert [a["do"] for a in actions] == ["reopen"], actions

# -- an escalation is a new issue: the daily cap counts it -------------------------------
issues = {}
state, _, _, _ = run_once(fresh(), first, issues, "2026-11-11")
issues[HCB][0].update(state="CLOSED", closedAt="2026-11-12T00:00:00Z")
state["fingerprints"][rec_fp]["closes"] = 2
state["fingerprints"][rec_fp]["last_closed_at"] = "2026-11-12T00:00:00Z"
state["filed"] = {HCB: {"2026-11-20": cap}}
occ = first + again(80, "2026-11-20")
state, actions, wrote, _ = run_once(state, occ, issues, "2026-11-20")
assert [a["do"] for a in actions] == ["wait"] and wrote == [], actions
state, actions, wrote, _ = run_once(state, occ, issues, "2026-11-21")
assert [a["do"] for a in actions] == ["escalate"], "the waiting escalation goes the next day"
assert state["filed"][HCB]["2026-11-21"] == 1

# -- one run at a time holds the state ---------------------------------------------------
with tempfile.TemporaryDirectory() as d:
    held = lp.lock(Path(d) / "state.json")
    probe = ("import fcntl,sys; f=open(sys.argv[1],'a')\n"
             "try:\n fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)\nexcept OSError:\n sys.exit(3)")
    r = __import__("subprocess").run([__import__("sys").executable, "-c", probe,
                                      str(Path(d) / "state.lock")])
    assert r.returncode == 3, "a second run cannot take the lock while the first holds it"
    held.close()

# -- config ------------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as d:
    p = Path(d) / "loop.toml"
    p.write_text("[sensor.review]\nthreshold = 5\n[guards]\ndaily_cap = 1\n")
    c = lp.config(str(p))
    assert c["sensor"]["review"] == {"threshold": 5, "window_days": 14}
    assert c["guards"]["daily_cap"] == 1 and c["sensor"]["flaky"]["threshold"] == 2
    p.write_text("[sensor.nope]\nthreshold = 1\n")
    try:
        lp.config(str(p))
        raise AssertionError("an unknown sensor is refused")
    except lp.Fatal:
        pass

print("ok: chg-loop")
