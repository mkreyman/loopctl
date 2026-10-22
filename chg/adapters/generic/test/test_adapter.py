#!/usr/bin/env python3
"""Tests for adapters/generic/chg-adapter.py, in a throwaway git repo with a fake selector and
runner. With CHG_BIN set they also drive the adapter through `chg adapter validate` and
`chg adapter exec`, where the contract's document checks and always_all apply.

    python3 adapters/generic/test/test_adapter.py
    CHG_BIN=target/debug/chg python3 adapters/generic/test/test_adapter.py
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ADAPTER = os.path.join(os.path.dirname(HERE), "chg-adapter.py")
CHG_BIN = os.environ.get("CHG_BIN")

# The runner reports `PASS <name> (Ns)` or `FAIL <name> ...` for each suite in CHG_SUITES; a suite
# passes unless its script exits non-zero. FAKE_RC makes the runner itself exit non-zero.
RUNNER = """#!/bin/sh
rc=0
for s in $CHG_SUITES; do
  if sh "tests/$s" >/dev/null 2>&1; then echo "PASS $s (2s)"; else echo "FAIL $s (rc=1, 1s)"; rc=1; fi
done
[ -n "$FAKE_RC" ] && exit "$FAKE_RC"
exit $rc
"""
# The selector maps a changed path under src/<x>/ to tests/<x>-canary.sh, and anything else to ALL.
SELECT = """#!/bin/sh
out=
while read -r p; do
  case "$p" in
    src/*/*) n=${p#src/}; n=${n%%/*}; out="$out
$n-canary.sh" ;;
    *) echo ALL; exit 0 ;;
  esac
done < "$CHG_CHANGED"
printf '%s\\n' "$out" | sort -u
"""
MANIFEST = """[adapter]
kind = "generic"
version = "1"
inputs = ["src/**", "tests/**", "bin/**"]
always_all = ["bin/**", ".chg/**"]

[commands]
snapshot = "python3 {adapter} snapshot"
static   = "python3 {adapter} static --base {{base}} --check 'lint=test ! -e src/BAD'"
affected = "python3 {adapter} affected --base {{base}} --select 'sh bin/select.sh' --suite-dir tests"
run      = "python3 {adapter} run --tests {{file}} --runner 'sh bin/runner.sh' --suite-dir tests"
shard    = "python3 {adapter} shard --of {{n}} --index {{i}} --runner 'sh bin/runner.sh' --suite-dir tests --suite-glob '*-canary.sh'"
"""


class GenericAdapter(unittest.TestCase):
    def setUp(self):
        self.repo = tempfile.mkdtemp(prefix="chg-generic-")
        self.addCleanup(shutil.rmtree, self.repo)
        for d in ("src/a", "src/b", "tests", "bin", ".chg"):
            os.makedirs(os.path.join(self.repo, d))
        self.write("src/a/x.sh", "echo a\n")
        self.write("src/b/y.sh", "echo b\n")
        self.write("tests/a-canary.sh", "exit 0\n")
        self.write("tests/b-canary.sh", "exit 0\n")
        self.write("tests/c-canary.sh", "exit 0\n")
        self.write("bin/runner.sh", RUNNER)
        self.write("bin/select.sh", SELECT)
        self.write(".chg/adapter.toml", MANIFEST.format(adapter=ADAPTER))
        self.git("init", "-q", "-b", "master")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "base")
        self.base = self.git("rev-parse", "HEAD").strip()

    def write(self, rel, text):
        with open(os.path.join(self.repo, rel), "w") as fh:
            fh.write(text)

    def git(self, *a):
        return subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", *a], cwd=self.repo,
                              check=True, capture_output=True, text=True).stdout

    def adapter(self, *args, **env):
        r = subprocess.run([sys.executable, ADAPTER, *args], cwd=self.repo, capture_output=True, text=True,
                           env=dict(os.environ, **env))
        return r.returncode, json.loads(r.stdout.strip().splitlines()[-1]), r

    def list_file(self, *lines):
        path = os.path.join(self.repo, ".git", "chg-tests.txt")
        with open(path, "w") as fh:
            fh.write("".join(l + "\n" for l in lines))
        return path

    def test_snapshot_does_no_work(self):
        code, doc, _ = self.adapter("snapshot")
        self.assertEqual((code, doc["work"]), (0, "none"))

    def test_affected_selects_the_suites_the_selector_names(self):
        self.write("src/a/x.sh", "echo changed\n")
        self.write("src/b/new.sh", "echo untracked\n")
        code, doc, _ = self.adapter("affected", "--base", self.base, "--select", "sh bin/select.sh", "--suite-dir", "tests")
        self.assertEqual(code, 0)
        self.assertEqual((doc["mode"], doc["tests"]), ("subset", ["tests/a-canary.sh", "tests/b-canary.sh"]))

    def test_affected_fails_closed(self):
        self.write("README.md", "x\n")
        cases = [
            ("ALL from the selector", self.base, "sh bin/select.sh", "selected ALL"),
            ("a failing selector", self.base, "exit 3", "exited 3"),
            ("an empty selection", self.base, "true", "selected nothing"),
            ("a name that is no suite", self.base, "echo nope.sh", "no suite"),
            ("an unknown base", "deadbeef", "sh bin/select.sh", "failed closed"),
        ]
        for what, base, select, why in cases:
            with self.subTest(what):
                code, doc, _ = self.adapter("affected", "--base", base, "--select", select, "--suite-dir", "tests")
                self.assertEqual((code, doc["mode"]), (0, "all"))
                self.assertIn(why, doc["reason"])
        code, doc, _ = self.adapter("affected", "--base", self.base)
        self.assertEqual((code, doc["mode"]), (0, "all"), "a missing argument fails closed, never exit 2")
        code, doc, _ = self.adapter("affected", "--base", self.base, "--select", "true", "--suite-dir", "tests", "--bogus")
        self.assertEqual((code, doc["mode"]), (0, "all"), "an unknown argument fails closed, never exit 2")
        os.makedirs(os.path.join(self.repo, "tests", "sub"))
        self.write("tests/sub/a-canary.sh", "exit 0\n")
        code, doc, _ = self.adapter("affected", "--base", self.base, "--select", "echo sub/a-canary.sh",
                                    "--suite-dir", "tests")
        self.assertEqual(doc["mode"], "all", "a suite below the suite dir is not one the runner can name")
        code, doc, _ = self.adapter("affected", "--base", self.base, "--select", "echo a-canary.sh",
                                    "--suite-dir", "tests", CHG_READ="docs/x.md")
        self.assertEqual(doc["mode"], "all", "a changed read_at_runtime path selects everything")

    def test_a_path_with_a_space_reaches_the_selector_whole(self):
        self.write("src/a/my file.sh", "x\n")
        code, doc, _ = self.adapter("affected", "--base", self.base, "--select",
                                    "grep -qx 'src/a/my file.sh' \"$CHG_CHANGED\" && echo a-canary.sh",
                                    "--suite-dir", "tests")
        self.assertEqual(doc.get("tests"), ["tests/a-canary.sh"], doc)

    def test_run_reports_one_result_per_suite(self):
        self.write("tests/b-canary.sh", "exit 1\n")
        code, doc, _ = self.adapter("run", "--tests", self.list_file("tests/a-canary.sh", "tests/b-canary.sh:3"),
                                    "--runner", "sh bin/runner.sh", "--suite-dir", "tests")
        self.assertEqual(code, 1)
        self.assertEqual(doc["results"], [{"id": "tests/a-canary.sh", "status": "pass", "ms": 2000},
                                          {"id": "tests/b-canary.sh", "status": "fail", "ms": 1000}])

    def test_run_errors_on_what_the_runner_did_not_report(self):
        code, doc, _ = self.adapter("run", "--tests", self.list_file("tests/a-canary.sh"),
                                    "--runner", "echo nothing", "--suite-dir", "tests")
        self.assertEqual((code, doc["results"][0]["status"]), (1, "error"))
        code, doc, _ = self.adapter("run", "--tests", self.list_file("tests/a-canary.sh"),
                                    "--runner", "sh bin/runner.sh", "--suite-dir", "tests", FAKE_RC="4")
        self.assertEqual(code, 1)
        self.assertEqual([r["status"] for r in doc["results"]], ["pass", "error"],
                         "a runner that exits non-zero with every suite passing is an error")
        self.assertTrue(doc["results"][1]["id"].startswith("tests/a-canary.sh > "),
                        "its id starts with a suite file, so chg culprit can rerun it")
        code, doc, _ = self.adapter("run", "--tests", self.list_file("tests/sub/x.sh"),
                                    "--runner", "sh bin/runner.sh", "--suite-dir", "tests")
        self.assertEqual((code, doc["results"]), (1, [{"id": "tests/sub/x.sh", "status": "error", "ms": 0}]))

    def test_shards_cover_every_suite_once(self):
        seen = []
        for i in (1, 2):
            code, doc, _ = self.adapter("shard", "--of", "2", "--index", str(i), "--runner", "sh bin/runner.sh",
                                        "--suite-dir", "tests", "--suite-glob", "*-canary.sh")
            self.assertEqual(code, 0)
            seen += [r["id"] for r in doc["results"]]
        self.assertEqual(sorted(seen), ["tests/a-canary.sh", "tests/b-canary.sh", "tests/c-canary.sh"])
        code, doc, _ = self.adapter("shard", "--of", "4", "--index", "4", "--runner", "sh bin/runner.sh",
                                    "--suite-dir", "tests", "--suite-glob", "*-canary.sh")
        self.assertEqual((code, doc["results"]), (0, []), "an empty shard is valid")

    def test_static_runs_each_check_with_base_and_head(self):
        code, doc, _ = self.adapter("static", "--base", self.base, "--check", 'env=test -n "$CHG_BASE" -a -n "$CHG_HEAD"')
        self.assertEqual((code, doc), (0, {"ok": True, "failures": []}))
        code, doc, _ = self.adapter("static", "--base", self.base, "--check", "boom=echo broke; exit 2")
        self.assertEqual((code, doc["ok"], doc["failures"][0]["check"]), (1, False, "boom"))
        self.assertIn("broke", doc["failures"][0]["message"])

    @unittest.skipUnless(CHG_BIN, "CHG_BIN not set")
    def test_through_chg(self):
        def chg(*a):
            return subprocess.run([CHG_BIN, *a, "--repo", self.repo], cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(chg("adapter", "validate").returncode, 0, chg("adapter", "validate").stderr)
        self.write("src/a/x.sh", "echo changed\n")
        r = chg("adapter", "exec", "affected", "--base", self.base)
        self.assertEqual(json.loads(r.stdout.strip().splitlines()[-1])["tests"], ["tests/a-canary.sh"], r.stderr)
        self.write("bin/runner.sh", RUNNER + "\n")
        r = chg("adapter", "exec", "affected", "--base", self.base)
        self.assertEqual(json.loads(r.stdout.strip().splitlines()[-1])["mode"], "all", "always_all applies")
        r = chg("adapter", "exec", "shard", "--n", "1", "--i", "1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(json.loads(r.stdout.strip().splitlines()[-1])["results"]), 3)


if __name__ == "__main__":
    unittest.main()
