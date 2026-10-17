//! `chg verify`, `chg culprit` and `chg revert` (story S8) against a stand-in adapter, a
//! local bare remote and a stand-in `gh`.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command as Std, Output};

use assert_cmd::Command;
use serde_json::Value;
use tempfile::TempDir;

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

/// A stand-in adapter. A test fails where the commit's `.chg/broken` lists its entry; the
/// test named by `$FLAKY` fails the first time it runs and passes after. `$TS_IDS` reports
/// ids the TypeScript adapter's way (`file > name`). A commit with `.chg/break-run` breaks
/// the contract on `run`; one with `.chg/static-red` fails static checks. Each call is
/// logged to `$CALLS` with the directory it ran in.
const ADAPTER: &str = r#"#!/bin/sh
cmd=$1; shift
echo "$cmd $(pwd)" >> "$CALLS"
results() {
  out=""; bad=0
  while read -r id; do
    [ -z "$id" ] && continue
    st=pass
    if [ -f .chg/broken ] && grep -qxF "$id" .chg/broken; then st=fail; fi
    if [ -n "$FLAKY" ] && [ "$id" = "$FLAKY" ] && [ ! -f "$FLAKY_SEEN" ]; then
      st=fail; : > "$FLAKY_SEEN"
    fi
    [ "$st" = fail ] && bad=1
    [ -n "$TS_IDS" ] && id="$id > works"
    out="$out${out:+,}{\"id\":\"$id\",\"status\":\"$st\",\"ms\":1}"
  done
  echo "{\"results\":[$out]}"
  exit $bad
}
case "$cmd" in
  snapshot) mkdir -p _build; echo built > _build/marker; echo '{"work":"full","ms":1}' ;;
  static)   if [ -f .chg/static-red ]; then
              echo '{"ok":false,"failures":[{"check":"credo","file":"lib/a.ex","line":3,"message":"x"}]}'; exit 1
            fi
            echo '{"ok":true,"failures":[]}' ;;
  affected) echo '{"mode":"all","reason":"stand-in"}' ;;
  run)      [ -f .chg/break-run ] && exit 3
            results < "$1" ;;
  shard)    ls test/*_test.exs | sed 's/$/:1/' | results ;;
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

/// A stand-in `gh`: logs every call to `$GH_LOG` and keeps the PRs, issues and comments
/// it "created" in `$GH_STATE`, so a second run sees them. A call whose first two words
/// are `$GH_FAIL` fails.
const GH: &str = r#"#!/bin/sh
echo "$*" >> "$GH_LOG"
[ -n "$GH_FAIL" ] && [ "$1 $2" = "$GH_FAIL" ] && { echo "HTTP 502" >&2; exit 1; }
marks() { printf '%s\n' "$@" | grep -o '<!-- chg-[^>]*-->' | tr '\n' ' '; }
case "$1 $2" in
  api\ *)         echo '[7]' ;;
  "pr list")      cat "$GH_STATE/prs" 2>/dev/null || echo '[]' ;;
  "pr create")    printf '[{"url":"https://github.com/o/r/pull/9","body":"%s"}]' "$(marks "$@")" > "$GH_STATE/prs"
                  echo https://github.com/o/r/pull/9 ;;
  "pr view")      cat "$GH_STATE/pr-comments" 2>/dev/null || true ;;
  "pr comment")   printf '%s\n' "$@" >> "$GH_STATE/pr-comments" ;;
  "issue list")   cat "$GH_STATE/issues" 2>/dev/null || echo '[]' ;;
  "issue view")   cat "$GH_STATE/comments" 2>/dev/null || true ;;
  "issue comment") printf '%s\n' "$@" >> "$GH_STATE/comments" ;;
  "issue create") printf '[{"url":"https://github.com/o/r/issues/10","body":"%s"}]' "$(marks "$@")" > "$GH_STATE/issues"
                  echo https://github.com/o/r/issues/10 ;;
  *)              : ;;
esac
"#;

struct Env {
    _t: TempDir,
    root: PathBuf,
    repo: PathBuf,
    remote: PathBuf,
    calls: PathBuf,
}

impl Env {
    fn new(dir: TempDir) -> Env {
        let root = fs::canonicalize(dir.path()).unwrap();
        let repo = root.join("product");
        fs::create_dir_all(repo.join(".chg")).unwrap();
        fs::create_dir_all(repo.join("test")).unwrap();
        fs::create_dir_all(repo.join("lib")).unwrap();
        fs::create_dir_all(root.join("gh")).unwrap();
        fs::write(repo.join(".chg/adapter.toml"), MANIFEST).unwrap();
        fs::write(repo.join(".chg/adapter.sh"), ADAPTER).unwrap();
        fs::write(repo.join(".gitignore"), "_build/\n").unwrap();
        fs::write(repo.join("lib/a.ex"), "one\n").unwrap();
        fs::write(repo.join("test/a_test.exs"), "a\n").unwrap();
        fs::write(repo.join("test/b_test.exs"), "b\n").unwrap();
        fs::write(root.join("gh.sh"), GH).unwrap();
        fs::set_permissions(root.join("gh.sh"), fs::Permissions::from_mode(0o755)).unwrap();
        let remote = root.join("remote.git");
        let env = Env {
            calls: root.join("calls"),
            remote,
            repo,
            root,
            _t: dir,
        };
        Std::new("git")
            .args(["init", "-q", "--bare", "-b", "master"])
            .arg(&env.remote)
            .status()
            .unwrap();
        env.git(&["init", "-q", "-b", "master"]);
        // The URL names a GitHub repo; insteadOf sends git to the local bare one.
        env.git(&["remote", "add", "origin", "git@github.com:o/r.git"]);
        env.git(&[
            "config",
            &format!("url.{}.insteadOf", env.remote.display()),
            "git@github.com:o/r.git",
        ]);
        env.git(&["add", "-A"]);
        env.git(&["commit", "-q", "-m", "one"]);
        env
    }

    fn git(&self, args: &[&str]) -> String {
        let out = Std::new("git")
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
        let p = self.repo.join(file);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
        self.git(&["add", "-A"]);
        self.git(&["commit", "-q", "-m", file]);
        self.head()
    }

    fn remote_ref(&self, name: &str) -> Option<String> {
        let out = Std::new("git")
            .arg("--git-dir")
            .arg(&self.remote)
            .args(["rev-parse", "-q", "--verify", &format!("refs/heads/{name}")])
            .output()
            .unwrap();
        out.status
            .success()
            .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    fn chg(&self) -> Command {
        let mut c = Command::cargo_bin("chg").unwrap();
        c.current_dir(&self.repo)
            .env("CHG_HOME", self.root.join("chg-home"))
            .env("CHG_STORE", self.root.join("store"))
            .env("CHG_GH", self.root.join("gh.sh"))
            .env("GH_LOG", self.root.join("gh.log"))
            .env("GH_STATE", self.root.join("gh"))
            .env("CALLS", &self.calls)
            .env("FLAKY_SEEN", self.root.join("flaky-seen"))
            .env_remove("FLAKY")
            .env_remove("TS_IDS")
            .env_remove("GH_FAIL")
            .env_remove("CHG_GATE");
        c
    }

    fn calls(&self) -> String {
        fs::read_to_string(&self.calls).unwrap_or_default()
    }

    fn gh_log(&self) -> String {
        fs::read_to_string(self.root.join("gh.log")).unwrap_or_default()
    }

    fn worktrees(&self) -> usize {
        self.git(&["worktree", "list", "--porcelain"])
            .lines()
            .filter(|l| l.starts_with("worktree "))
            .count()
    }
}

fn json(out: &Output) -> Value {
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "{e}: stdout {} stderr {}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        )
    })
}

#[test]
fn verify_moves_the_ref_forward_on_green_and_never_back() {
    let env = Env::new(tempfile::tempdir().unwrap());
    let c1 = env.head();
    let verify = |extra: &[&str]| {
        let out = env.chg().arg("verify").args(extra).output().unwrap();
        (out.status.code(), json(&out))
    };

    let (code, r) = verify(&[]);
    assert_eq!(code, Some(0), "{r}");
    assert_eq!(r["outcome"], "advanced");
    assert_eq!(r["verdict"]["mode"], "all", "the whole suite ran");
    assert_eq!(env.remote_ref("verified/master"), Some(c1.clone()));

    // Already there: nothing runs.
    fs::remove_file(&env.calls).unwrap();
    let (code, r) = verify(&[]);
    assert_eq!((code, r["outcome"].as_str()), (Some(0), Some("already")));
    assert_eq!(env.calls(), "");

    let c2 = env.commit("lib/a.ex", "two\n");
    let (code, r) = verify(&[]);
    assert_eq!((code, r["outcome"].as_str()), (Some(0), Some("advanced")));
    assert_eq!(r["before"], c1.as_str());
    assert_eq!(env.remote_ref("verified/master"), Some(c2.clone()));

    // An older commit, verified late, cannot move the ref back, and does not run.
    env.git(&["checkout", "-q", "--detach", &c1]);
    fs::remove_file(&env.calls).unwrap();
    let (code, r) = verify(&[]);
    assert_eq!((code, r["outcome"].as_str()), (Some(0), Some("superseded")));
    assert_eq!(env.calls(), "");
    assert_eq!(env.remote_ref("verified/master"), Some(c2.clone()));
    env.git(&["checkout", "-q", "master"]);

    // Red: the ref stays, and the failing ids are written for `chg culprit --tests`.
    env.commit(".chg/broken", "test/a_test.exs:1\n");
    let failures = env.root.join("failures.txt");
    let (code, r) = verify(&["--failures-out", failures.to_str().unwrap()]);
    assert_eq!(
        (code, r["outcome"].as_str()),
        (Some(1), Some("held")),
        "{r}"
    );
    assert_eq!(env.remote_ref("verified/master"), Some(c2.clone()));
    assert_eq!(
        fs::read_to_string(&failures).unwrap(),
        "test/a_test.exs:1\n"
    );

    // A tree that is not exactly the commit gets no verdict.
    let c4 = env.commit(".chg/broken", "");
    fs::write(env.repo.join("lib/a.ex"), "dirty\n").unwrap();
    let out = env.chg().arg("verify").output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(env.remote_ref("verified/master"), Some(c2));

    // --no-run trusts a suite that passed elsewhere, and only advances.
    fs::remove_file(&env.calls).unwrap();
    let (code, r) = verify(&["--no-run", "--sha", &c4]);
    assert_eq!(
        (code, r["outcome"].as_str()),
        (Some(0), Some("advanced")),
        "{r}"
    );
    assert_eq!(env.calls(), "");
    assert_eq!(env.remote_ref("verified/master"), Some(c4));
}

/// good -> c1 -> merge of a side branch whose commit breaks test/c_test.exs (a test it
/// adds) -> c3 -> c4 (bad).
fn history(env: &Env) -> (String, String, String, String) {
    history_breaking(env, "test/c_test.exs:1")
}

/// The same history, with `.chg/broken` listing `entry`.
fn history_breaking(env: &Env, entry: &str) -> (String, String, String, String) {
    let good = env.head();
    env.commit("lib/a.ex", "c1\n");
    env.git(&["checkout", "-q", "-b", "side"]);
    let side = env.commit("test/c_test.exs", "c\n");
    env.commit(".chg/broken", &format!("{entry}\n"));
    env.git(&["checkout", "-q", "master"]);
    env.git(&["merge", "-q", "--no-ff", "-m", "Merge side", "side"]);
    let merge = env.head();
    env.commit("lib/b.ex", "c3\n");
    let bad = env.commit("lib/c.ex", "c4\n");
    (good, side, merge, bad)
}

#[test]
fn culprit_names_the_first_parent_merge_and_leaves_flaky_tests_out() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let (good, side, merge, bad) = history(&env);
    fs::write(env.repo.join("lib/a.ex"), "uncommitted\n").unwrap();

    // No --tests: the whole suite runs on bad. b fails there once and passes on rerun.
    let out = env
        .chg()
        .args(["culprit", &good, &bad])
        .env("FLAKY", "test/b_test.exs:1")
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let f = json(&out);
    assert_eq!(f["culprit"], merge.as_str(), "the merge, not {side}: {f}");
    assert_eq!(f["subject"], "Merge side");
    assert_eq!(f["failing"], serde_json::json!(["test/c_test.exs:1"]));
    assert_eq!(f["flaky"], serde_json::json!(["test/b_test.exs:1"]));
    // The whole suite once, two reruns, `good`, then log2 of 4 candidates.
    assert!(f["probes"].as_array().unwrap().len() <= 6, "{f}");

    // Nothing ran in the live tree, and the throwaway worktree is gone.
    let live = format!(" {}", env.repo.display());
    for l in env.calls().lines().filter(|l| !l.starts_with("snapshot")) {
        assert!(!l.ends_with(&live), "ran in the live tree: {l}");
    }
    assert_eq!(env.worktrees(), 1);
    assert_eq!(
        fs::read_to_string(env.repo.join("lib/a.ex")).unwrap(),
        "uncommitted\n"
    );

    // Only flaky failures: no culprit.
    let tests = env.root.join("tests.txt");
    fs::write(&tests, "test/b_test.exs:1\n").unwrap();
    let _ = fs::remove_file(env.root.join("flaky-seen"));
    let out = env
        .chg()
        .args(["culprit", &good, &bad, "--tests", tests.to_str().unwrap()])
        .env("FLAKY", "test/b_test.exs:1")
        .output()
        .unwrap();
    // The flaky test failed in CI (the --tests list), so on the first rerun it is seen
    // for the first time here and fails once more; the second rerun passes it.
    let f = json(&out);
    assert_eq!(f["culprit"], Value::Null, "{f}");
    assert_eq!(f["flaky"], serde_json::json!(["test/b_test.exs:1"]));
}

#[test]
fn revert_opens_one_pr_per_culprit_however_often_trunk_runs_red() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let (_good, _side, merge, _bad) = history(&env);
    env.git(&["push", "-q", "origin", "master"]);
    let tests = env.root.join("tests.txt");
    fs::write(&tests, "test/c_test.exs:1\n").unwrap();
    let revert = |run: &str, fail: Option<&str>| {
        let mut c = env.chg();
        c.args(["revert", &merge, "--run-id", run])
            .args(["--tests", tests.to_str().unwrap()]);
        if let Some(f) = fail {
            c.env("GH_FAIL", f);
        }
        c.output().unwrap()
    };

    // The first attempt dies before it tells the culprit's PR.
    let out = revert("42", Some("pr comment"));
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let r = json(&out);
    let branch = format!("auto-revert/{}", &merge[..12]);
    assert_eq!(r["branch"], branch.as_str());
    assert_eq!(r["created"], true);
    assert_eq!(r["auto_merge"], true);
    assert_eq!(r["culprit_pr"], 7);
    assert_eq!(r["revert_pr"], "https://github.com/o/r/pull/9");
    assert_eq!(r["fix_issue"], "https://github.com/o/r/issues/10");

    // The branch is master with the merge's side undone.
    let tip = env
        .remote_ref(&branch)
        .expect("the revert branch is pushed");
    env.git(&["fetch", "-q", "origin"]);
    assert_eq!(env.git(&["rev-parse", &format!("{tip}^")]), env.head());
    let files = env.git(&["ls-tree", "-r", "--name-only", &tip]);
    assert!(!files.contains("test/c_test.exs"), "{files}");
    assert!(!files.contains(".chg/broken"), "{files}");
    assert_eq!(env.worktrees(), 1);

    let log = env.gh_log();
    assert!(log.contains("--label auto-revert"), "{log}");
    assert!(log.contains("pr merge https://github.com/o/r/pull/9 --auto --squash"));
    assert!(log.contains("test/c_test.exs:1"));
    assert!(
        r["warnings"][0]
            .as_str()
            .unwrap()
            .contains("commenting on #7"),
        "{r}"
    );

    // The retry tells it, and makes nothing else.
    let out = revert("42", None);
    assert_eq!(out.status.code(), Some(0));
    let r = json(&out);
    assert_eq!(r["created"], false);
    assert_eq!(r["fix_issue"], "https://github.com/o/r/issues/10");
    let retry = env.gh_log()[log.len()..].to_string();
    assert!(!retry.contains("pr create"), "{retry}");
    assert!(!retry.contains("issue create"), "{retry}");
    assert_eq!(retry.matches("pr comment 7").count(), 1, "{retry}");

    // A later red run naming the same culprit opens nothing new and tells nobody twice.
    let before = env.gh_log().len();
    let out = revert("43", None);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(json(&out)["revert_pr"], "https://github.com/o/r/pull/9");
    let later = env.gh_log()[before..].to_string();
    assert!(!later.contains("pr create"), "{later}");
    assert!(!later.contains("issue create"), "{later}");
    assert!(!later.contains("pr comment"), "{later}");

    // A lookup that fails is an error, never "none yet": that would file a duplicate.
    let before = env.gh_log().len();
    let out = revert("44", Some("issue list"));
    assert_eq!(out.status.code(), Some(2));
    assert!(!env.gh_log()[before..].contains("issue create"));
}

#[test]
fn a_revert_that_does_not_apply_files_the_story_and_says_so() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let culprit = env.commit("lib/a.ex", "culprit\n");
    env.commit("lib/a.ex", "built on the culprit\n");
    env.git(&["push", "-q", "origin", "master"]);
    let out = env
        .chg()
        .args(["revert", &culprit, "--run-id", "7"])
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let r = json(&out);
    assert_eq!(r["revert_pr"], Value::Null);
    assert_eq!(r["fix_issue"], "https://github.com/o/r/issues/10");
    assert!(
        r["warnings"][0]
            .as_str()
            .unwrap()
            .contains("does not apply cleanly"),
        "{r}"
    );
    let log = env.gh_log();
    assert!(!log.contains("pr create"), "{log}");
    assert!(log.contains("does not apply cleanly"), "{log}");
    assert_eq!(
        env.remote_ref(&format!("auto-revert/{}-7", &culprit[..12])),
        None
    );
    assert_eq!(env.worktrees(), 1);
}

#[test]
fn flaky_tests_get_one_open_issue_and_one_comment_per_run() {
    let env = Env::new(tempfile::tempdir().unwrap());
    let tests = env.root.join("flaky.txt");
    fs::write(&tests, "test/b_test.exs:1\n").unwrap();
    let flaky = |run: &str| {
        env.chg()
            .args(["flaky", "--tests", tests.to_str().unwrap(), "--run-id", run])
            .assert()
            .success()
            .get_output()
            .stdout
            .clone()
    };
    assert_eq!(flaky("1"), b"https://github.com/o/r/issues/10\n");
    let log = env.gh_log();
    assert_eq!(log.matches("issue create").count(), 1, "{log}");
    assert!(log.contains("--label flaky"), "{log}");

    // The same run again adds nothing; a later run comments once.
    flaky("1");
    assert_eq!(env.gh_log().matches("issue create").count(), 1);
    assert_eq!(env.gh_log().matches("issue comment").count(), 0);
    flaky("2");
    flaky("2");
    let log = env.gh_log();
    assert_eq!(log.matches("issue create").count(), 1, "{log}");
    assert_eq!(log.matches("issue comment").count(), 1, "{log}");
}

#[test]
fn a_static_failure_writes_no_test_ids() {
    let env = Env::new(tempfile::tempdir().unwrap());
    env.commit(".chg/static-red", "x\n");
    let failures = env.root.join("failures.txt");
    let out = env
        .chg()
        .args(["verify", "--failures-out", failures.to_str().unwrap()])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(json(&out)["verdict"]["failures"][0], "credo lib/a.ex:3 x");
    assert_eq!(fs::read_to_string(&failures).unwrap(), "");
}

#[test]
fn culprit_takes_typescript_ids_and_the_worktree_head() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let (good, _side, merge, bad) = history_breaking(&env, "test/c_test.exs");
    // The search runs from a linked worktree at `bad` while the main one is at `good`.
    let linked = env.root.join("linked");
    env.git(&[
        "worktree",
        "add",
        "-q",
        "--detach",
        linked.to_str().unwrap(),
        &bad,
    ]);
    env.git(&["checkout", "-q", "--detach", &good]);
    let tests = env.root.join("tests.txt");
    fs::write(&tests, "test/c_test.exs > works\n").unwrap();
    let out = env
        .chg()
        .current_dir(&linked)
        .args(["culprit", &good, "HEAD", "--tests", tests.to_str().unwrap()])
        .env("TS_IDS", "1")
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let f = json(&out);
    assert_eq!(f["bad"], bad.as_str(), "HEAD is the linked worktree's");
    assert_eq!(f["culprit"], merge.as_str(), "{f}");
    assert_eq!(f["failing"], serde_json::json!(["test/c_test.exs > works"]));
    assert_eq!(f["flaky"], serde_json::json!([]));
}

#[test]
fn culprit_stops_when_a_probe_cannot_run_and_blames_nothing_red_at_good() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let good = env.head();
    env.commit(".chg/break-run", "x\n");
    env.git(&["rm", "-q", ".chg/break-run"]);
    env.git(&["commit", "-qm", "unbreak"]);
    let bad = env.commit(".chg/broken", "test/a_test.exs:1\n");
    let tests = env.root.join("tests.txt");
    fs::write(&tests, "test/a_test.exs:1\n").unwrap();
    // The first candidate cannot run its tests: no guess, no culprit.
    let out = env
        .chg()
        .args(["culprit", &good, &bad, "--tests", tests.to_str().unwrap()])
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    assert!(String::from_utf8_lossy(&out.stderr).contains("could not run"));

    // Red at `good` as well: nothing after it broke the test.
    let next = env.commit("lib/z.ex", "z\n");
    let out = env
        .chg()
        .args(["culprit", &bad, &next, "--tests", tests.to_str().unwrap()])
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let f = json(&out);
    assert_eq!(f["culprit"], Value::Null, "{f}");
    assert!(f["reason"].as_str().unwrap().contains("as well"), "{f}");
}
