//! Integration tests for S10: `chg check`, `chg gate` (the `CHG_GATE` switch), and the
//! shadow phase (`chg check --shadow`, `chg shadow record`, `chg shadow report`), against
//! a git repo driven by a stand-in adapter.

use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::process::Command as Std;
use std::time::{Duration, Instant};

use assert_cmd::Command;
use predicates::prelude::*;
use serde_json::Value;
use tempfile::TempDir;

/// The machine's git config stays out of the fixture repos, for the tests' own git calls
/// and every git `chg` runs: a global `core.hooksPath` would run the developer's hooks on
/// the fixtures' commits and pushes.
const GIT_ISOLATED: [(&str, &str); 2] = [
    ("GIT_CONFIG_GLOBAL", "/dev/null"),
    ("GIT_CONFIG_NOSYSTEM", "1"),
];

/// Clone-capable on macOS (APFS); on Linux only under `CHG_TEST_REFLINK_DIR`.
fn cow_tempdir() -> Option<TempDir> {
    if cfg!(target_os = "macos") {
        return Some(tempfile::tempdir().unwrap());
    }
    match std::env::var_os("CHG_TEST_REFLINK_DIR") {
        Some(d) => Some(tempfile::tempdir_in(d).unwrap()),
        None if std::env::var_os("CI").is_some() => {
            panic!(
                "CHG_TEST_REFLINK_DIR is unset in CI; mount a reflink-capable dir for the clone tests"
            )
        }
        None => {
            eprintln!("skipped: set CHG_TEST_REFLINK_DIR to a reflink-capable dir");
            None
        }
    }
}

/// A stand-in adapter. `FAIL_TESTS=1` in the repo's `.chg/fail` makes `run` fail; each
/// call is logged to `.chg/calls` in the directory it ran in.
const ADAPTER: &str = r#"#!/bin/sh
cmd=$1; shift
echo "$cmd $(pwd)" >> "$CALLS"
case "$cmd" in
  snapshot) [ -n "$SNAP_SLEEP" ] && sleep "$SNAP_SLEEP"
            mkdir -p _build; echo built > _build/marker; printf %s "$CHG_SHA" > _build/sha
            echo '{"work":"full","ms":1}' ;;
  static)   cat _build/sha > "$CALLS.hydrated-from" 2>/dev/null
            if ! git rev-parse --verify --quiet "$1^{commit}" >/dev/null; then
              echo '{"ok":false,"failures":[{"check":"git","message":"base not in this repo"}]}'; exit 1
            fi
            echo '{"ok":true,"failures":[]}' ;;
  affected) echo '{"mode":"subset","reason":"two files","tests":["test/a_test.exs","test/b_test.exs"]}' ;;
  run)      if [ -f .chg/fail ]; then
              echo '{"results":[{"id":"test/a_test.exs:3","status":"fail","ms":5}]}'; exit 1
            fi
            echo '{"results":[{"id":"test/a_test.exs:3","status":"pass","ms":5}]}' ;;
  shard)    echo '{"results":[]}' ;;
esac
"#;

const MANIFEST: &str = r#"[adapter]
kind = "elixir"
version = "1"
artifacts = ["_build"]
inputs = ["lib/**"]
always_all = ["mix.exs"]
isolation_env = { MIX_TEST_PARTITION = "{workspace_slot}" }

[commands]
snapshot = "sh .chg/adapter.sh snapshot"
static   = "sh .chg/adapter.sh static {base}"
affected = "sh .chg/adapter.sh affected {base}"
run      = "sh .chg/adapter.sh run {file}"
shard    = "sh .chg/adapter.sh shard {n} {i}"
"#;

struct Env {
    _t: TempDir,
    repo: PathBuf,
    home: PathBuf,
    store: PathBuf,
    calls: PathBuf,
}

impl Env {
    fn new(dir: TempDir) -> Env {
        let root = fs::canonicalize(dir.path()).unwrap();
        let repo = root.join("product");
        fs::create_dir_all(repo.join(".chg")).unwrap();
        fs::create_dir_all(repo.join("lib")).unwrap();
        fs::write(repo.join(".chg/adapter.toml"), MANIFEST).unwrap();
        fs::write(repo.join(".chg/adapter.sh"), ADAPTER).unwrap();
        fs::write(repo.join(".gitignore"), "_build/\n").unwrap();
        fs::write(repo.join("lib/a.ex"), "one\n").unwrap();
        let env = Env {
            home: root.join("chg-home"),
            store: root.join("store"),
            calls: root.join("calls"),
            repo,
            _t: dir,
        };
        env.git(&["init", "-q", "-b", "master"]);
        env.git(&["add", "-A"]);
        env.git(&["commit", "-q", "-m", "one"]);
        env
    }

    fn plain() -> Env {
        Env::new(tempfile::tempdir().unwrap())
    }

    fn git(&self, args: &[&str]) -> String {
        let out = Std::new("git")
            .envs(GIT_ISOLATED)
            .arg("-C")
            .arg(&self.repo)
            .args(["-c", "user.name=t", "-c", "user.email=t@t"])
            .args(["-c", "commit.gpgsign=false"])
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    fn head(&self) -> String {
        self.git(&["rev-parse", "HEAD"])
    }

    fn commit(&self, file: &str, text: &str) -> String {
        fs::write(self.repo.join(file), text).unwrap();
        self.git(&["add", "-A"]);
        self.git(&["commit", "-q", "-m", file]);
        self.head()
    }

    fn chg(&self) -> Command {
        let mut c = Command::cargo_bin("chg").unwrap();
        c.envs(GIT_ISOLATED)
            .current_dir(&self.repo)
            .env("CHG_HOME", &self.home)
            .env("CHG_STORE", &self.store)
            .env("CALLS", &self.calls)
            .env_remove("CHG_GATE");
        c
    }

    fn log(&self) -> PathBuf {
        self.home.join("shadow/product.jsonl")
    }

    fn rows(&self) -> Vec<Value> {
        fs::read_to_string(self.log())
            .unwrap_or_default()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    fn calls(&self) -> String {
        fs::read_to_string(&self.calls).unwrap_or_default()
    }

    fn worktrees(&self) -> usize {
        self.git(&["worktree", "list", "--porcelain"])
            .lines()
            .filter(|l| l.starts_with("worktree "))
            .count()
    }
}

#[test]
fn gate_mode_switch_env_beats_policy_and_off_is_the_fallback() {
    let env = Env::plain();
    let mode = |set: Option<&str>| {
        let mut c = env.chg();
        c.arg("gate");
        if let Some(v) = set {
            c.env("CHG_GATE", v);
        }
        let out = c.assert().success().get_output().stdout.clone();
        String::from_utf8(out).unwrap().trim().to_string()
    };
    assert_eq!(mode(None), "shadow");
    assert_eq!(mode(Some("off")), "off");

    fs::write(env.repo.join(".chg/policy.toml"), "[gate]\nmode = \"on\"\n").unwrap();
    assert_eq!(mode(None), "on");
    // The rollback: CHG_GATE=off restores the old gate with no code change.
    assert_eq!(mode(Some("off")), "off");
    assert_eq!(mode(Some("bogus")), "off");

    fs::write(
        env.repo.join(".chg/policy.toml"),
        "[gate]\nmode = \"off\"\n",
    )
    .unwrap();
    assert_eq!(mode(None), "off");

    // A policy that exists but cannot be read is unreadable, not absent: off, not the
    // shadow default.
    fs::remove_file(env.repo.join(".chg/policy.toml")).unwrap();
    fs::create_dir(env.repo.join(".chg/policy.toml")).unwrap();
    assert_eq!(mode(None), "off");
    let out = env
        .chg()
        .arg("gate")
        .env("CHG_GATE", std::ffi::OsStr::from_bytes(b"\xff"))
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    assert_eq!(String::from_utf8(out).unwrap().trim(), "off");
}

#[test]
fn check_runs_static_then_the_affected_tests() {
    let env = Env::plain();
    let base = env.head();
    env.commit("lib/a.ex", "two\n");
    let out = env
        .chg()
        .args(["check", "--base", &base])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let v: Value = serde_json::from_slice(&out).unwrap();
    assert_eq!(v["verdict"], "pass");
    assert_eq!(v["mode"], "subset");
    assert_eq!(v["selected"].as_array().unwrap().len(), 2);
    let calls = env.calls();
    let order: Vec<&str> = calls
        .lines()
        .map(|l| l.split(' ').next().unwrap())
        .collect();
    assert_eq!(order, ["static", "affected", "run"]);

    fs::write(env.repo.join(".chg/fail"), "").unwrap();
    env.chg()
        .args(["check", "--base", &base])
        .assert()
        .code(1)
        .stdout(predicate::str::contains("\"verdict\":\"fail\""))
        .stdout(predicate::str::contains("test/a_test.exs:3"));
}

/// After cutover no `chg shadow record` follows a push, so HCB recorded nothing for 34
/// gated pushes on mac-mini. A gate-mode check logs its own verdict; a check run while
/// chg only shadows the gate does not.
#[test]
fn a_gate_mode_check_logs_its_verdict_and_selection() {
    let env = Env::plain();
    let base = env.head();
    let sha = env.commit("lib/a.ex", "two\n");
    env.chg()
        .args(["check", "--base", &base])
        .assert()
        .success();
    assert!(env.rows().is_empty(), "{:?}", env.rows());

    env.chg()
        .args(["check", "--base", &base])
        .env("CHG_GATE", "on")
        .assert()
        .success();
    fs::write(env.repo.join(".chg/fail"), "").unwrap();
    env.chg()
        .args(["check", "--base", &base])
        .env("CHG_GATE", "on")
        .assert()
        .code(1);
    let rows = env.rows();
    assert_eq!(rows.len(), 2, "{rows:?}");
    for r in &rows {
        assert_eq!(r["kind"], "chg");
        assert_eq!(r["source"], "gate");
        assert_eq!(r["sha"], sha.as_str());
        assert_eq!(r["base"], base.as_str());
        assert_eq!(r["mode"], "subset");
        assert!(
            r["selection"].as_str().is_some_and(|s| !s.is_empty()),
            "{r}"
        );
        assert!(r["host"].as_str().is_some_and(|h| !h.is_empty()));
    }
    assert_eq!(rows[0]["verdict"], "pass");
    assert_eq!(rows[1]["verdict"], "fail");
    assert_eq!(rows[1]["reason"], "1 test(s) failed");

    // The report summarises them apart from the shadow pairing.
    let out = env
        .chg()
        .args(["shadow", "report", "--json"])
        .output()
        .unwrap();
    let r: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(r["pushes"], 0, "{r}");
    assert_eq!(r["unpaired"], 0, "{r}");
    let g = &r["gate_mode"][0];
    assert_eq!(g["checks"], 2, "{r}");
    assert_eq!(g["pass"], 1);
    assert_eq!(g["fail"], 1);
    assert_eq!(g["subset"], 2);
    let text = env.chg().args(["shadow", "report"]).output().unwrap();
    assert!(
        String::from_utf8_lossy(&text.stdout).contains("gate-mode checks"),
        "{}",
        String::from_utf8_lossy(&text.stdout)
    );

    // A push the gate blocks without judging is logged too: a base that does not resolve,
    // and a pinned commit the live tree does not hold.
    env.chg()
        .args(["check", "--base", "no-such-ref"])
        .env("CHG_GATE", "on")
        .assert()
        .code(2);
    env.chg()
        .args(["check", "--base", &base, "--sha", &base])
        .env("CHG_GATE", "on")
        .assert()
        .code(2);
    let rows = env.rows();
    assert_eq!(rows.len(), 4, "{rows:?}");
    assert_eq!(rows[2]["verdict"], "error", "{}", rows[2]);
    assert_eq!(rows[2]["sha"], sha.as_str());
    assert_eq!(rows[2]["base"], "");
    assert_eq!(rows[3]["verdict"], "error", "{}", rows[3]);
    assert_eq!(rows[3]["sha"], base.as_str());
    assert!(
        rows[3]["reason"]
            .as_str()
            .is_some_and(|r| r.starts_with(&format!("no verdict for {base}"))),
        "{}",
        rows[3]
    );
}

#[test]
fn a_gate_mode_check_judges_the_commit_where_snapshots_are_built() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let old = env.head();
    env.chg()
        .args(["snapshot", "build"])
        .arg(&env.repo)
        .arg(&old)
        .assert()
        .success();
    // The base has no snapshot yet, so the refresh after the check really builds one.
    let base = env.commit("lib/b.ex", "b\n");
    env.commit("lib/a.ex", "two\n");
    fs::write(env.repo.join("lib/a.ex"), "uncommitted\n").unwrap();
    let built_at = env
        .calls()
        .lines()
        .find_map(|l| l.strip_prefix("snapshot ").map(String::from))
        .unwrap();
    fs::remove_file(&env.calls).unwrap();

    // A slow refresh: the check must return without waiting for it, with only its
    // verdict on stdout.
    let started = Instant::now();
    let out = env
        .chg()
        .args(["check", "--base", &base])
        .env("SNAP_SLEEP", "15")
        .assert()
        .success()
        .get_output()
        .clone();
    assert!(
        started.elapsed() < Duration::from_secs(4),
        "waited for the refresh"
    );
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["verdict"], "pass", "{v}");
    assert!(
        !String::from_utf8_lossy(&out.stderr).contains("checking the live tree"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    // Every adapter call ran at the build path, none in the live tree, whose uncommitted
    // change is neither judged nor touched.
    let calls = env.calls();
    let ran: Vec<&str> = calls
        .lines()
        .filter(|l| {
            ["static ", "affected ", "run "]
                .iter()
                .any(|p| l.starts_with(p))
        })
        .map(|l| l.split_once(' ').unwrap().1)
        .collect();
    assert!(!ran.is_empty(), "{calls}");
    assert!(ran.iter().all(|d| *d == built_at), "{calls}");
    assert_eq!(
        fs::read_to_string(env.repo.join("lib/a.ex")).unwrap(),
        "uncommitted\n"
    );
    assert_eq!(env.worktrees(), 1, "the build-path worktree is removed");
    // The refresh builds the base's snapshot, its output in a log of its own.
    let log = env
        .home
        .join(format!("shadow/logs/product-refresh-{}.log", &base[..12]));
    let deadline = Instant::now() + Duration::from_secs(60);
    let snaps = || {
        let out = env
            .chg()
            .args(["snapshot", "list"])
            .output()
            .unwrap()
            .stdout;
        String::from_utf8_lossy(&out).contains(&base)
    };
    while !snaps() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
    }
    assert!(snaps(), "the base's snapshot was built");
    let logged = || fs::read_to_string(&log).unwrap_or_default();
    while !logged().contains("\"status\":\"built\"") && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
    }
    assert!(logged().contains("\"status\":\"built\""), "{}", logged());

    // While a snapshot build holds the build path, the gate does not wait for it: it
    // checks the live tree at once.
    let next = env.commit("lib/c.ex", "c\n");
    fs::remove_file(&env.calls).unwrap();
    let mut build = Std::new(assert_cmd::cargo::cargo_bin("chg"))
        .envs(GIT_ISOLATED)
        .current_dir(&env.repo)
        .env("CHG_HOME", &env.home)
        .env("CHG_STORE", &env.store)
        .env("CALLS", &env.calls)
        .env("SNAP_SLEEP", "15")
        .args(["snapshot", "build"])
        .arg(&env.repo)
        .arg(&next)
        .spawn()
        .unwrap();
    while !env.calls().starts_with("snapshot ") && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(100));
    }
    let started = Instant::now();
    env.chg()
        .args(["check", "--base", &base])
        .assert()
        .success()
        .stderr(predicate::str::contains("holds the build path"));
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "waited for the build"
    );
    let live = format!(" {}", env.repo.display());
    assert!(
        env.calls()
            .lines()
            .any(|l| l.starts_with("run ") && l.ends_with(&live)),
        "{}",
        env.calls()
    );
    build.wait().unwrap();

    // With no snapshot to start from, the live tree is checked, as before.
    let cold = Env::plain();
    cold.chg()
        .args(["check", "--base", "HEAD"])
        .assert()
        .success()
        .stderr(predicate::str::contains("checking the live tree"));
    let live = format!(" {}", cold.repo.display());
    assert!(
        cold.calls().lines().all(|l| l.ends_with(&live)),
        "{}",
        cold.calls()
    );
}

/// A base past the nearest snapshot across an always_all path (here mix.exs) would make
/// the check's static step rebuild everything inside its own budget: the base's snapshot
/// is built first, under the snapshot budget, and the check hydrates from it.
#[test]
fn a_gate_mode_check_builds_the_bases_snapshot_first_across_an_always_all_change() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let old = env.head();
    env.chg()
        .args(["snapshot", "build"])
        .arg(&env.repo)
        .arg(&old)
        .assert()
        .success();
    let base = env.commit("mix.exs", "deps changed\n");
    env.commit("lib/a.ex", "two\n");
    fs::remove_file(&env.calls).unwrap();

    let out = env
        .chg()
        .args(["check", "--base", &base])
        .assert()
        .success()
        .get_output()
        .clone();
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains(&format!(
            "is behind the base {} across mix.exs (always_all `mix.exs`)",
            &base[..12]
        )) && err.contains("building the base's snapshot first, under its own 1800 s budget"),
        "{err}"
    );
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["verdict"], "pass", "{v}");
    assert!(!err.contains("checking the live tree"), "{err}");
    // The snapshot was built before static ran, at the build path, and the check hydrated
    // from it: static ran there and found the base's build.
    let calls = env.calls();
    let order: Vec<&str> = calls
        .lines()
        .filter_map(|l| l.split(' ').next())
        .filter(|c| ["snapshot", "static"].contains(c))
        .collect();
    assert_eq!(order.first(), Some(&"snapshot"), "{calls}");
    let at = |cmd: &str| {
        calls
            .lines()
            .find_map(|l| l.strip_prefix(&format!("{cmd} ")).map(String::from))
            .unwrap_or_else(|| panic!("no {cmd} call: {calls}"))
    };
    assert_eq!(at("static"), at("snapshot"), "{calls}");
    assert_eq!(
        fs::read_to_string(env.calls.with_extension("hydrated-from")).unwrap(),
        base,
        "{calls}"
    );
    let list = env
        .chg()
        .args(["snapshot", "list", "--repo"])
        .arg(&env.repo)
        .output()
        .unwrap();
    assert!(
        String::from_utf8_lossy(&list.stdout).contains(&base[..12]),
        "{}",
        String::from_utf8_lossy(&list.stdout)
    );
}

/// A base that is not an ancestor of the commit (the remote tip of a rebased branch) is
/// never built first: the check could not hydrate from it, so the push would only wait.
#[test]
fn a_gate_mode_check_never_builds_a_base_it_cannot_hydrate_from() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let old = env.head();
    env.chg()
        .args(["snapshot", "build"])
        .arg(&env.repo)
        .arg(&old)
        .assert()
        .success();
    env.git(&["checkout", "-q", "-b", "side"]);
    let side = env.commit("mix.exs", "deps changed\n");
    env.git(&["checkout", "-q", "master"]);
    env.commit("lib/a.ex", "two\n");
    fs::remove_file(&env.calls).unwrap();

    let out = env
        .chg()
        .args(["check", "--base", &side])
        .env("SNAP_SLEEP", "15")
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(!err.contains("snapshot first"), "{err}");
    let calls = env.calls();
    assert_eq!(
        calls.lines().find_map(|l| l.split(' ').next()),
        Some("static"),
        "no snapshot build before the check: {calls}"
    );
}

#[test]
fn check_with_the_gate_off_exits_3_without_running_anything() {
    let env = Env::plain();
    env.chg()
        .args(["check", "--base", "HEAD"])
        .env("CHG_GATE", "off")
        .assert()
        .code(3)
        .stderr(predicate::str::contains("run the repo's own gate"));
    assert_eq!(env.calls(), "");
}

#[test]
fn shadow_with_the_gate_off_does_nothing() {
    let env = Env::plain();
    env.chg()
        .args(["check", "--shadow", "--foreground", "--base", "HEAD"])
        .env("CHG_GATE", "off")
        .assert()
        .success()
        .stderr(predicate::str::contains("shadow skipped"));
    assert!(env.rows().is_empty());
    assert_eq!(env.calls(), "");
}

#[test]
fn shadow_never_fails_the_push() {
    let dir = tempfile::tempdir().unwrap();
    Command::cargo_bin("chg")
        .unwrap()
        .envs(GIT_ISOLATED)
        .current_dir(dir.path())
        .env("CHG_HOME", dir.path().join("h"))
        .args(["check", "--shadow"])
        .assert()
        .success()
        .stderr(predicate::str::contains("shadow skipped"));
}

#[test]
fn shadow_without_a_snapshot_is_skipped_not_cold_built() {
    let env = Env::plain();
    env.chg()
        .args(["check", "--shadow", "--foreground", "--base", "HEAD"])
        .assert()
        .success();
    let rows = env.rows();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["kind"], "chg");
    assert_eq!(rows[0]["verdict"], "skipped");
    assert!(rows[0]["reason"].as_str().unwrap().contains("no snapshot"));
    assert_eq!(env.worktrees(), 1, "the throwaway worktree is removed");
}

#[test]
fn a_replay_is_marked_and_only_with_a_foreground_shadow() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let base = env.head();
    env.chg()
        .args(["snapshot", "build"])
        .arg(&env.repo)
        .arg(&base)
        .assert()
        .success();
    let sha = env.commit("lib/a.ex", "two\n");
    env.chg()
        .args([
            "check",
            "--shadow",
            "--foreground",
            "--replay",
            "--sha",
            &sha,
        ])
        .args(["--base", &base])
        .assert()
        .success();
    let rows = env.rows();
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!(rows[0]["source"], "replay");
    assert_eq!(rows[0]["sha"], sha.as_str());
    assert_eq!(rows[0]["verdict"], "pass");
    env.chg()
        .args(["check", "--shadow", "--replay"])
        .assert()
        .failure();
}

#[test]
fn shadow_judges_the_commit_in_a_throwaway_worktree() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let base = env.head();
    env.chg()
        .args(["snapshot", "build"])
        .arg(&env.repo)
        .arg(&base)
        .assert()
        .success();
    let sha = env.commit("lib/a.ex", "two\n");
    // The live tree moves on after the push; the shadow must judge the pushed commit.
    fs::write(env.repo.join("lib/a.ex"), "uncommitted\n").unwrap();

    env.chg()
        .args(["check", "--shadow", "--foreground", "--base", &base])
        .assert()
        .success();
    let rows = env.rows();
    assert_eq!(rows.len(), 1, "{rows:?}");
    let r = &rows[0];
    assert_eq!(r["verdict"], "pass", "{r}");
    assert_eq!(r["sha"], sha.as_str());
    assert_eq!(r["base"], base.as_str());
    assert_eq!(r["mode"], "subset");
    assert_eq!(r["selected"].as_array().unwrap().len(), 2);
    assert!(r["host"].as_str().is_some_and(|h| !h.is_empty()));
    assert!(r["hydrate_ms"].is_u64());
    assert!(
        r.get("source").is_none(),
        "a push's row is not a replay: {r}"
    );

    // Every adapter call ran outside the live tree.
    let calls = env.calls();
    let live = format!(" {}", env.repo.display());
    for l in calls.lines().filter(|l| !l.starts_with("snapshot")) {
        assert!(!l.ends_with(&live), "ran in the live tree: {l}");
    }
    assert_eq!(env.worktrees(), 1, "the throwaway worktree is removed");
    assert_eq!(
        fs::read_to_string(env.repo.join("lib/a.ex")).unwrap(),
        "uncommitted\n"
    );

    // A check killed mid-run leaves its worktree registered; the next one clears it and
    // runs at the same path, so in the same workspace slot and test database.
    let store = fs::read_dir(&env.store)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .find(|p| p.is_dir())
        .unwrap();
    let ws = store.join("build");
    let first_dirs: Vec<String> = calls
        .lines()
        .filter(|l| l.starts_with("run "))
        .map(|l| l["run ".len()..].to_string())
        .collect();
    assert_eq!(first_dirs.len(), 1, "{calls}");
    // The snapshot was built where the check ran, so nothing it baked in differs.
    let built_at: Vec<&str> = calls
        .lines()
        .filter(|l| l.starts_with("snapshot "))
        .map(|l| &l["snapshot ".len()..])
        .collect();
    assert_eq!(built_at, vec![first_dirs[0].as_str()], "{calls}");
    env.git(&[
        "worktree",
        "add",
        "-q",
        "--detach",
        ws.to_str().unwrap(),
        &base,
    ]);
    fs::write(ws.join("left-behind"), "x").unwrap();
    assert_eq!(env.worktrees(), 2);
    fs::remove_file(&env.calls).unwrap();
    env.chg()
        .args(["check", "--shadow", "--foreground", "--base", &base])
        .assert()
        .success();
    let rows = env.rows();
    assert_eq!(rows[1]["verdict"], "pass", "{}", rows[1]);
    let calls = env.calls();
    let again: Vec<&str> = calls
        .lines()
        .filter(|l| l.starts_with("run "))
        .map(|l| &l["run ".len()..])
        .collect();
    assert_eq!(again, vec![first_dirs[0].as_str()], "same path, same slot");
    assert_eq!(env.worktrees(), 1, "the leftover is gone too");
    assert!(!ws.exists());

    // A snapshot build clears a killed check's worktree there the same way, its git
    // registration included.
    env.git(&[
        "worktree",
        "add",
        "-q",
        "--detach",
        ws.to_str().unwrap(),
        &base,
    ]);
    assert_eq!(env.worktrees(), 2);
    env.chg()
        .args(["snapshot", "build"])
        .arg(&env.repo)
        .arg(&sha)
        .assert()
        .success();
    assert_eq!(env.worktrees(), 1, "the build unregistered the leftover");
    assert!(!ws.exists(), "and renamed its own build away");
}

#[test]
fn after_its_row_a_shadow_builds_the_snapshot_of_its_base_from_an_older_one() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let old = env.head();
    env.chg()
        .args(["snapshot", "build"])
        .arg(&env.repo)
        .arg(&old)
        .assert()
        .success();
    let base = env.commit("lib/a.ex", "two\n");
    env.commit("lib/a.ex", "three\n");

    // As the hook runs it: holding the gate lock, which the refresh must not inherit.
    let gate_lock = env.repo.join("gate.lock");
    fs::write(&gate_lock, "").unwrap();
    let has_flock = Std::new("flock").arg("-V").output().is_ok();
    let chg = assert_cmd::cargo::cargo_bin("chg");
    let mut c = if has_flock {
        let mut c = Std::new("flock");
        c.arg(&gate_lock).arg(chg);
        c
    } else {
        Std::new(chg)
    };
    // Output to null, not captured: a captured pipe would be held open by the detached
    // refresh, and reading it to EOF would wait for the refresh to finish.
    let status = c
        .envs(GIT_ISOLATED)
        .current_dir(&env.repo)
        .env("CHG_HOME", &env.home)
        .env("CHG_STORE", &env.store)
        .env("CALLS", &env.calls)
        .env_remove("CHG_GATE")
        .env("SNAP_SLEEP", "3")
        .args(["check", "--shadow", "--foreground", "--base", &base])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
    assert_eq!(env.rows()[0]["verdict"], "pass", "{:?}", env.rows());
    if has_flock {
        let free = Std::new("flock")
            .args(["-n"])
            .arg(&gate_lock)
            .arg("true")
            .status()
            .unwrap();
        assert!(free.success(), "the running refresh holds the gate lock");
        let out = env
            .chg()
            .args(["snapshot", "list"])
            .output()
            .unwrap()
            .stdout;
        assert_eq!(
            String::from_utf8(out).unwrap().lines().count(),
            1,
            "the refresh had already finished, so the lock check proves nothing"
        );
    }
    // The refresh runs detached: wait for its snapshot.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    let listed = loop {
        let out = env
            .chg()
            .args(["snapshot", "list"])
            .output()
            .unwrap()
            .stdout;
        let metas: Vec<Value> = String::from_utf8(out)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        if metas.len() == 2 || std::time::Instant::now() > deadline {
            break metas;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    };
    let shas: Vec<&str> = listed.iter().map(|m| m["sha"].as_str().unwrap()).collect();
    assert_eq!(shas, vec![base.as_str(), old.as_str()], "{listed:?}");
    assert_eq!(
        listed[0]["from"],
        old.as_str(),
        "warm, from the older snapshot"
    );

    // The same base again: already built, so no second snapshot build runs.
    fs::remove_file(&env.calls).unwrap();
    env.chg()
        .args(["check", "--shadow", "--foreground", "--base", &base])
        .assert()
        .success();
    assert!(
        !env.calls().lines().any(|l| l.starts_with("snapshot")),
        "{}",
        env.calls()
    );
}

#[test]
fn check_with_a_sha_judges_only_that_exact_clean_tree() {
    let env = Env::plain();
    let base = env.head();
    let sha = env.commit("lib/a.ex", "two\n");
    let check = |extra: &[(&str, &str)]| {
        let mut c = env.chg();
        c.args(["check", "--sha", &sha, "--base", &base]);
        for (k, v) in extra {
            c.env(k, v);
        }
        c.output().unwrap()
    };
    assert_eq!(check(&[]).status.code(), Some(0));

    // Uncommitted edits: refused before anything runs.
    fs::write(env.repo.join("lib/a.ex"), "dirty\n").unwrap();
    fs::remove_file(&env.calls).unwrap();
    let out = check(&[]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("differs from"));
    assert_eq!(env.calls(), "", "nothing ran");
    env.git(&["checkout", "-q", "--", "lib/a.ex"]);

    // HEAD is not the commit asked about.
    let later = env.commit("lib/a.ex", "three\n");
    assert_ne!(later, sha);
    let out = check(&[]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("not"));

    // The tree changed while the tests ran: no verdict, whatever the tests said.
    env.git(&["reset", "-q", "--hard", &sha]);
    let marker = env.repo.join("lib/written-during-run.ex");
    let touching = ADAPTER.replace(
        "  run)      if",
        "  run)      [ -n \"$TOUCH\" ] && echo x > \"$TOUCH\"\n            if",
    );
    fs::write(env.repo.join(".chg/adapter.sh"), touching).unwrap();
    env.git(&["commit", "-qam", "touching adapter"]);
    let sha = env.head();
    let out = env
        .chg()
        .args(["check", "--sha", &sha, "--base", &base])
        .env("TOUCH", &marker)
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let v: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(v["verdict"], "error");
    assert!(v["reason"].as_str().unwrap().contains("tree moved"), "{v}");
}

#[test]
fn shadow_detaches_and_returns_at_once() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let base = env.head();
    env.chg()
        .args(["snapshot", "build"])
        .arg(&env.repo)
        .arg(&base)
        .assert()
        .success();
    env.commit("lib/a.ex", "two\n");
    // The adapter takes 2 s per call; the push must not wait for it.
    let slow = ADAPTER.replace("cmd=$1; shift", "cmd=$1; shift\nsleep 2");
    fs::write(env.repo.join(".chg/adapter.sh"), slow).unwrap();
    env.git(&["commit", "-qam", "slow adapter"]);

    let started = Instant::now();
    env.chg()
        .args(["check", "--shadow", "--base", &base])
        .assert()
        .success()
        .stderr(predicate::str::contains("started in the background"));
    assert!(started.elapsed() < Duration::from_secs(2));

    let deadline = Instant::now() + Duration::from_secs(60);
    while env.rows().is_empty() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
    }
    let rows = env.rows();
    assert_eq!(rows.len(), 1, "no row within 60 s");
    assert_eq!(rows[0]["verdict"], "pass", "{}", rows[0]);
}

#[test]
fn record_and_report_pair_verdicts_by_commit() {
    let env = Env::plain();
    let sha = env.head();
    let chg_row = serde_json::json!({
        "v": 1, "kind": "chg", "repo": "product", "host": "m1", "sha": sha,
        "at_ms": 1, "verdict": "pass", "ms": 60000, "mode": "subset",
        "selected": ["test/a_test.exs"]
    });
    fs::create_dir_all(env.home.join("shadow")).unwrap();
    fs::write(env.log(), format!("{chg_row}\n")).unwrap();

    let failures = env.home.join("failures.txt");
    fs::write(&failures, "test/z_test.exs:9\n").unwrap();
    env.chg()
        .args(["shadow", "record", "--verdict", "fail", "--ms", "540000"])
        .args(["--gate", "mix precommit", "--failures-file"])
        .arg(&failures)
        .assert()
        .success();
    let rows = env.rows();
    assert_eq!(rows[1]["kind"], "gate");
    assert_eq!(rows[1]["sha"], sha.as_str());
    assert_eq!(rows[1]["source"], "local");

    env.chg()
        .args(["shadow", "report"])
        .assert()
        .code(1)
        .stdout(predicate::str::contains(
            "pushes 1 (0 replayed, 1 distinct commits) on 1 machine(s) [m1]",
        ))
        .stdout(predicate::str::contains("MISS"))
        .stdout(predicate::str::contains(
            "not selected, failed in the gate: test/z_test.exs:9",
        ))
        .stdout(predicate::str::contains("not ready to cut over"));

    let out = env
        .chg()
        .args(["shadow", "report", "--json"])
        .assert()
        .code(1)
        .get_output()
        .stdout
        .clone();
    let r: Value = serde_json::from_slice(&out).unwrap();
    assert_eq!(r["misses"], 1);
    assert_eq!(r["criteria"].as_array().unwrap().len(), 3);
    assert_eq!(r["replayed"], 0);

    env.chg()
        .args(["shadow", "record", "--verdict", "maybe"])
        .assert()
        .code(1);

    // A CI verdict recorded by hand is a CI row: no gate time, so the gate-time figures
    // stay as they were, and `--ms` is refused with it.
    env.chg()
        .args(["shadow", "record", "--verdict", "pass", "--source", "ci"])
        .args(["--gate", "Tests (CI on abc)"])
        .assert()
        .success();
    let rows = env.rows();
    assert_eq!(rows.last().unwrap()["source"], "ci");
    assert_eq!(rows.last().unwrap()["ms"], 0);
    let out = env
        .chg()
        .args(["shadow", "report", "--json"])
        .assert()
        .get_output()
        .stdout
        .clone();
    let after: Value = serde_json::from_slice(&out).unwrap();
    assert_eq!(after["timed"], r["timed"]);
    assert_eq!(after["median_gate_ms"], r["median_gate_ms"]);
    env.chg()
        .args([
            "shadow",
            "record",
            "--verdict",
            "pass",
            "--source",
            "ci",
            "--ms",
            "5",
        ])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "--ms has no meaning with --source ci",
        ));
    env.chg()
        .args(["shadow", "record", "--verdict", "pass", "--source", "other"])
        .assert()
        .failure();

    // The hook's final decision on a gate-mode push: error is allowed there and only
    // there, and the reason is kept.
    env.chg()
        .args(["shadow", "record", "--verdict", "error", "--source", "hook"])
        .args([
            "--gate",
            "chg check",
            "--ms",
            "7",
            "--reason",
            "core.bare flipped",
        ])
        .assert()
        .success();
    let rows = env.rows();
    let last = rows.last().unwrap();
    assert_eq!(last["source"], "hook");
    assert_eq!(last["verdict"], "error");
    assert_eq!(last["reason"], "core.bare flipped");
    assert_eq!(last["ms"], 7);
    env.chg()
        .args(["shadow", "record", "--verdict", "error"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains("or error with --source hook"));
}

#[test]
fn report_reads_extra_logs_and_dedups_them() {
    let env = Env::plain();
    fs::create_dir_all(&env.home).unwrap();
    let other = env.home.join("other.jsonl");
    let mut lines = String::new();
    for (i, host) in ["m1", "m2", "m3"].iter().enumerate() {
        let sha = format!("{i:040}");
        lines += &format!(
            "{}\n{}\n",
            serde_json::json!({"v":1,"kind":"chg","repo":"product","host":host,"sha":sha,"at_ms":1,"verdict":"pass","ms":1000}),
            serde_json::json!({"v":1,"kind":"gate","repo":"product","host":host,"sha":sha,"at_ms":2,"verdict":"pass","ms":9000,"gate":"g","source":"local"})
        );
    }
    fs::write(&other, &lines).unwrap();
    env.chg()
        .args(["shadow", "report", "--file"])
        .arg(&other)
        .arg("--file")
        .arg(&other)
        .assert()
        .code(1)
        .stdout(predicate::str::contains(
            "pushes 3 (0 replayed, 3 distinct commits) on 3 machine(s)",
        ))
        .stdout(predicate::str::contains("[x] machines: 3"))
        .stdout(predicate::str::contains(
            "[ ] shadow pushes with both verdicts: 3",
        ));
}

#[test]
fn the_hook_variables_do_not_leak_into_the_adapter() {
    // From a pre-push hook git exports GIT_DIR. The adapter's git calls (here, static
    // resolving the base) must still see the repo they run in, not the hook's.
    let env = Env::plain();
    let other = Env::plain();
    let base = env.head();
    env.commit("lib/a.ex", "two\n");
    env.chg()
        .args(["check", "--base", &base])
        .env("GIT_DIR", other.repo.join(".git"))
        .assert()
        .success();
}
