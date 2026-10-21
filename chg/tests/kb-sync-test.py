#!/usr/bin/env python3
"""Tests for bin/chg-kb-sync.py's lesson selection. Run: python3 tests/kb-sync-test.py"""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "kbsync", Path(__file__).resolve().parent.parent / "bin" / "chg-kb-sync.py")
kbsync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kbsync)

reverts = [
    {"url": "u/pr/1", "title": "Auto-revert: X broke Y", "body": "b", "mergedAt": "2026-10-10T00:00:00Z"},
    {"url": "u/pr/2", "title": "Auto-revert: old", "body": "b", "mergedAt": "2026-09-01T00:00:00Z"},
    {"url": "u/pr/3", "title": "Auto-revert: open", "body": "b", "mergedAt": None},
]
flakes = [
    {"url": "u/i/4", "title": "Flaky: t_test races", "body": "x" * 9000, "createdAt": "2026-10-11T00:00:00Z", "state": "OPEN"},
    {"url": "u/i/5", "title": "Flaky test: old", "body": "", "createdAt": "2026-09-01T00:00:00Z", "state": "CLOSED"},
]

got = kbsync.lessons("o/repo", reverts, flakes, "2026-10-01T00:00:00Z")
assert [l["key"] for l in got] == ["u/pr/1", "u/i/4"], got
assert got[0]["title"] == "repo auto-revert: X broke Y"
assert got[0]["tags"][:3] == ["chg", "repo", "auto-revert"]
assert got[0]["tags"][3].startswith("idem-chgsync-") and len(got[0]["tags"][3]) == len("idem-chgsync-") + 12
assert got[0]["tags"][3] != got[1]["tags"][3]

import json, tempfile
d = Path(tempfile.mkdtemp())
(d / "old.json").write_text('["u/pr/1"]')
assert kbsync.load_state(d / "old.json") == {"done": ["u/pr/1"], "pending": {}}
kbsync.save_state(d / "s.json", {"done": {"b", "a"}, "pending": {"c": {"key": "c"}}})
assert kbsync.load_state(d / "s.json") == {"done": ["a", "b"], "pending": {"c": {"key": "c"}}}
(d / "bad.json").write_text("{")
try:
    kbsync.load_state(d / "bad.json")
    raise AssertionError("corrupt state accepted")
except kbsync.Fatal:
    pass
assert got[1]["title"] == "repo flaky test: t_test races"
assert len(got[1]["body"]) == kbsync.BODY_CAP
print("kb-sync-test: ok")
