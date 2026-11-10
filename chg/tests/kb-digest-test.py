#!/usr/bin/env python3
"""Tests for bin/chg-kb-digest.py. Run: python3 tests/kb-digest-test.py
Needs claude-config's bin/review-dispositions.py, which parses the PR bodies."""
import importlib.util
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "digest", Path(__file__).resolve().parent.parent / "bin" / "chg-kb-digest.py")
dg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dg)
parse = dg.dispositions().parse


def body(*lines):
    return "Intro.\n\n## Review findings\n\n" + "\n".join(lines) + "\n\n## How to revert\n\nRevert."


prs = [
    {"number": 10, "url": "u/10", "mergedAt": "2026-11-05T10:00:00Z", "labels": [],
     "body": body("1. fixed medium lib/app/a/x.ex:3 — x leaks a handle")},
    {"number": 11, "url": "u/11", "mergedAt": "2026-11-08T10:00:00Z", "labels": [],
     "body": body("1. wrong low lib/app/a/y.ex:9 — y races — wrong because it holds the lock")},
    {"number": 12, "url": "u/12", "mergedAt": "2026-11-09T09:00:00Z", "labels": [],
     "body": body("1. fixed high lib/app/a/x.ex:40 — x drops the error",
                  "2. didnt-matter low lib/app/a/z.ex:1 — z name — no caller sees it")},
    {"number": 13, "url": "u/13", "mergedAt": "2026-11-09T12:00:00Z",
     "labels": [{"name": "auto-revert"}], "body": "Reverts abc."},
    {"number": 14, "url": "u/14", "mergedAt": "2026-11-09T13:00:00Z", "labels": [],
     "body": "## Review findings\n\n- a bullet, not a finding"},
    {"number": 1, "url": "u/1", "mergedAt": "2026-10-01T00:00:00Z", "labels": [],
     "body": body("1. fixed low lib/app/a/x.ex:1 — outside the window")},
]
flakes = [{"url": "u/i/7", "createdAt": "2026-11-09T05:00:00Z"}]
parsed = dg.findings_of(prs, parse)
assert parsed[13] == ([], None), parsed[13]
assert parsed[14][1], "a malformed section reports errors"

# recurring: x.ex in #10 and #12 (window 7 days), not #1 (too old); lib/a in #10, #11, #12
files, dirs = dg.recurring("2026-11-09", prs, parsed, 7)
assert [(p, sorted(h)) for p, h in files] == [("lib/app/a/x.ex", [10, 12])], files
assert [(d, sorted(n)) for d, n in dirs] == [("lib/app/a", [10, 11, 12])], dirs
# a window too short to reach #10 finds no recurring file
files, _ = dg.recurring("2026-11-09", prs, parsed, 2)
assert files == [], files

art = dg.digest("o/repo", "2026-11-09", prs, flakes, parsed, 7)
b = art["body"]
assert art["title"] == "repo chg daily digest 2026-11-09"
assert art["tags"][:3] == ["chg", "repo", "daily-digest"]
assert art["tags"][3].startswith("idem-chgdigest-")
assert art["tags"][3] != dg.digest("o/repo", "2026-11-08", prs, [], parsed, 7)["tags"][3]
assert "Merged PRs: 3, auto-reverts among them: 1 #13" in b, b
assert "Flaky-test issues opened: 1 u/i/7" in b, b
assert "Review findings: 2 in 2 reviewed PR(s); 1 PR(s) carry no Review findings section" in b, b
assert "by disposition: didnt-matter 1, fixed 1" in b, b
assert "noise (wrong + didnt-matter): 1 of 2 (50%)" in b, b
assert "Sections that did not parse: #14" in b, b
assert "`lib/app/a/x.ex` flagged in 2 PRs" in b and "#10: x leaks a handle" in b, b
assert "`lib/app/a/` flagged in 3 PRs: #10 #11 #12" in b, b

assert dg.digest("o/repo", "2026-11-07", prs, flakes, parsed, 7) is None

# a two-level directory (lib/app) never counts as a recurring area
shallow = [{"number": n, "url": f"u/{n}", "mergedAt": "2026-11-09T01:00:00Z", "labels": [],
            "body": body(f"1. fixed low lib/app/f{n}.ex:1 — s")} for n in (20, 21, 22)]
_, dirs = dg.recurring("2026-11-09", shallow, dg.findings_of(shallow, parse), 7)
assert dirs == [], dirs

# a long digest is cut at a line boundary and says so
many = [{"number": n, "url": f"u/{n}", "mergedAt": "2026-11-09T01:00:00Z", "labels": [],
         "body": body(*[f"{i}. fixed low lib/app/m/f{i}.ex:1 — " + "w" * 300 for i in range(1, 30)])}
        for n in range(30, 36)]
big = dg.digest("o/repo", "2026-11-09", many, [], dg.findings_of(many, parse), 7)
assert len(big["body"]) <= dg.BODY_CAP and big["body"].endswith("\n(truncated)"), big["body"][-200:]
assert "`lib/app/m/` flagged in 6 PRs" in big["body"]
assert dg.clip("abcdef", 5) == "ab..." and dg.clip("abc", 5) == "abc"

assert dg.due_days(None, "2026-11-10", 3) == ["2026-11-07", "2026-11-08", "2026-11-09"]
assert dg.due_days("2026-11-08", "2026-11-10", 7) == ["2026-11-09"]
assert dg.due_days("2026-11-09", "2026-11-10", 7) == []
assert dg.due_days("2026-01-01", "2026-11-10", 2) == ["2026-11-08", "2026-11-09"]

# write(): an already-tagged day is skipped; otherwise a forced create keyed on the day's tag
class FakeKB:
    def __init__(self, answer, seen=False):
        self.answer, self.seen, self.posts, self.seen_calls = answer, seen, [], []

    def tag_seen(self, project_id, tag):
        self.seen_calls.append((project_id, tag))
        if isinstance(self.seen, Exception):
            raise self.seen
        return self.seen

    def api(self, method, path, *roles, body=None):
        self.posts.append((method, path, body))
        if isinstance(self.answer, Exception):
            raise self.answer
        return self.answer

tag = art["tags"][3]
kb = FakeKB({"data": {"id": "a1"}})
assert dg.write(kb, art, "p") == (True, "created")
assert kb.seen_calls == [("p", tag)]
method, path, sent = kb.posts[0]
assert (method, path) == ("POST", "/api/v1/articles")
# the gate is bypassed, never asked to skip, and the key is the tag's, not the body's
assert sent["force"] is True and "skip_low_novelty" not in sent
assert sent["idempotency_key"].startswith(tag + "-") and sent["tags"] == art["tags"]
assert sent["category"] == "finding" and sent["project_id"] == "p"
k2 = FakeKB({"data": {"id": "a1"}})
dg.write(k2, dict(art, body="rendered differently"), "p")
assert k2.posts[0][2]["idempotency_key"] == sent["idempotency_key"]
k3 = FakeKB({"data": {"id": "a1"}})
dg.write(k3, art, "q")
assert k3.posts[0][2]["idempotency_key"] != sent["idempotency_key"]
# a key replay (a race with another run) holds the day's article: it advances
assert dg.write(FakeKB({"deduplicated": True, "data": {"id": "a1"}}), art, "p") == (True, "replayed")
# an already-tagged day posts nothing
kb = FakeKB({"data": {"id": "a1"}}, seen=True)
assert dg.write(kb, art, "p") == (True, "already stored") and kb.posts == []
# no article in the answer, a post error or a list error leaves the day for the next run
for kb, needle in ((FakeKB({"data": None, "skipped": True}), "no article"),
                   (FakeKB(RuntimeError("503")), "503"),
                   (FakeKB({"data": {"id": "a1"}}, seen=RuntimeError("list 503")), "503")):
    done, outcome = dg.write(kb, art, "p")
    assert not done and needle in outcome, outcome

# the real client has the two calls write() makes, with the shapes it uses
import inspect, sys as _sys
_sys.path.insert(0, str(dg.sync.CLIENT_DIR))
try:
    import loopctl_client_core as core
    assert list(inspect.signature(core.tag_seen).parameters)[:2] == ["project_id", "tag"]
    assert "body" in inspect.signature(core.api).parameters
except ImportError as e:  # the client needs requests, which chg's venv supplies
    print(f"kb-digest-test: client signatures not checked ({e})")

d = Path(tempfile.mkdtemp())
assert dg.load_state(d / "none.json") == {"last_done": None}
dg.save_state(d / "s.json", {"last_done": "2026-11-09"})
assert dg.load_state(d / "s.json") == {"last_done": "2026-11-09"}
(d / "bad.json").write_text("{")
try:
    dg.load_state(d / "bad.json")
    raise AssertionError("corrupt state accepted")
except dg.Fatal:
    pass
print("kb-digest-test: ok")
