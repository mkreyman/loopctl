//! `chg verify`, `chg culprit` and `chg revert` (story S8) against a stand-in adapter, a
//! local bare remote and a stand-in `gh`.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command as Std, Output};

use assert_cmd::Command;
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

/// A stand-in adapter. A test fails where the commit's `.chg/broken` lists its entry; the
/// test named by `$FLAKY` fails the first time it runs and passes after. `$TS_IDS` reports
/// ids the TypeScript adapter's way (`file > name`). A commit with `.chg/break-run` breaks
/// the contract on `run`; one with `.chg/static-red` fails static checks; one with
/// `.chg/slow-shard` makes `shard` sleep 30 s. Each call is
/// logged to `$CALLS` with the directory it ran in, and to `$ENVLOG` with the coverage
/// variables chg gave it. `shard` writes a record to `$CHG_RECORD` when asked.
const ADAPTER: &str = r#"#!/bin/sh
cmd=$1; shift
echo "$cmd $(pwd)" >> "$CALLS"
echo "$cmd cover=$CHG_COVER record=$CHG_RECORD shard_by=$CHG_SHARD_BY" >> "$ENVLOG"
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
  shard)    [ -f .chg/slow-shard ] && sleep 30
            [ -n "$CHG_RECORD" ] && echo "record of $(git rev-parse HEAD)" > "$CHG_RECORD"
            ls test/*_test.exs | sed 's/$/:1/' | results ;;
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
            .envs(GIT_ISOLATED)
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
        let p = self.repo.join(file);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
        self.git(&["add", "-A"]);
        self.git(&["commit", "-q", "-m", file]);
        self.head()
    }

    fn remote_ref(&self, name: &str) -> Option<String> {
        let out = Std::new("git")
            .envs(GIT_ISOLATED)
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
        c.envs(GIT_ISOLATED)
            .current_dir(&self.repo)
            .env("CHG_HOME", self.root.join("chg-home"))
            .env("CHG_STORE", self.root.join("store"))
            .env("CHG_GH", self.root.join("gh.sh"))
            .env("GH_LOG", self.root.join("gh.log"))
            .env("GH_STATE", self.root.join("gh"))
            .env("CALLS", &self.calls)
            .env("ENVLOG", self.root.join("envlog"))
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
fn the_whole_suite_runs_under_the_tests_timeout() {
    let env = Env::new(tempfile::tempdir().unwrap());
    env.commit(".chg/slow-shard", "x\n");
    let started = std::time::Instant::now();
    let out = env
        .chg()
        .args(["verify", "--tests-timeout-secs", "1"])
        .output()
        .unwrap();
    assert!(
        started.elapsed().as_secs() < 20,
        "the cap did not stop the run"
    );
    let r = json(&out);
    assert_eq!(
        (out.status.code(), r["outcome"].as_str()),
        (Some(2), Some("held")),
        "{r}"
    );
    assert!(
        r["verdict"]["reason"]
            .as_str()
            .unwrap()
            .contains("timed out after 1s"),
        "{r}"
    );
    assert_eq!(env.remote_ref("verified/master"), None);
}

#[test]
fn the_ci_whole_suite_runs_default_to_2700_seconds() {
    for cmd in ["verify", "culprit"] {
        let out = Command::cargo_bin("chg")
            .unwrap()
            .args([cmd, "--help"])
            .output()
            .unwrap();
        let help = String::from_utf8_lossy(&out.stdout);
        assert!(
            help.contains("--tests-timeout-secs") && help.contains("[default: 2700]"),
            "{cmd}: {help}"
        );
    }
}

#[test]
fn culprit_runs_the_whole_suite_under_the_tests_timeout() {
    let Some(dir) = cow_tempdir() else { return };
    let env = Env::new(dir);
    let good = env.head();
    let bad = env.commit(".chg/slow-shard", "x\n");
    let started = std::time::Instant::now();
    let out = env
        .chg()
        .args(["culprit", &good, &bad, "--tests-timeout-secs", "1"])
        .output()
        .unwrap();
    assert!(
        started.elapsed().as_secs() < 20,
        "the cap did not stop the run"
    );
    assert_eq!(out.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("timed out after 1s"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
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

/// fleet-holding's culprit job (2026-10-21) trusted the worktree but not its `.git`, where
/// chg asks about ancestry. git refused to open it, and chg reported a true ancestor as
/// "not an ancestor". git's own refusal must come through instead.
#[test]
fn culprit_reports_git_refusing_the_git_dir_not_a_false_answer() {
    let env = Env::new(tempfile::tempdir().unwrap());
    let good = env.head();
    let bad = env.commit("lib/a.ex", "c1\n");
    let trusted = fs::canonicalize(&env.repo).unwrap();
    let out = env
        .chg()
        .args(["culprit", &good, &bad])
        // Every repo looks foreign; only the worktree is trusted, as in that job.
        .env("GIT_TEST_ASSUME_DIFFERENT_OWNER", "1")
        .env("GIT_CONFIG_COUNT", "1")
        .env("GIT_CONFIG_KEY_0", "safe.directory")
        .env("GIT_CONFIG_VALUE_0", &trusted)
        .output()
        .unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(2), "{err}");
    assert!(err.contains("dubious ownership"), "{err}");
    assert!(!err.contains("is not an ancestor"), "{err}");
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

#[test]
fn coverage_records_travel_from_the_verifier_to_other_machines() {
    let env = Env::new(tempfile::tempdir().unwrap());
    let c1 = env.head();
    let store = env.root.join("store");
    let records = |under: &std::path::Path| -> Vec<PathBuf> {
        let mut found = vec![];
        for e in fs::read_dir(under).into_iter().flatten().flatten() {
            let h = e.path().join("history");
            for r in fs::read_dir(h).into_iter().flatten().flatten() {
                found.push(r.path());
            }
        }
        found
    };

    // The verifier's green whole-suite run writes a record and publishes it.
    let out = env.chg().arg("verify").output().unwrap();
    let r = json(&out);
    assert_eq!(r["cover"], "published", "{r}");
    let mine = records(&store);
    assert_eq!(mine.len(), 1);
    assert!(mine[0].ends_with(format!("history/{c1}.cover")));
    assert_eq!(
        fs::read_to_string(&mine[0]).unwrap(),
        format!("record of {c1}\n")
    );
    let log = fs::read_to_string(env.root.join("envlog")).unwrap();
    let told = format!("record={}", mine[0].display());
    assert!(
        log.lines()
            .any(|l| l.starts_with("shard") && l.contains(&told)),
        "the whole-suite shard was told where to write: {log}"
    );

    // Another machine (another clone, so another store) fetches it, once.
    env.git(&["push", "-q", "origin", "master"]);
    let other = env.root.join("other");
    let st = Std::new("git")
        .envs(GIT_ISOLATED)
        .args(["clone", "-q"])
        .arg(&env.remote)
        .arg(&other)
        .status()
        .unwrap();
    assert!(st.success());
    let fetch = || {
        let out = env
            .chg()
            .current_dir(&other)
            .args(["cover", "fetch"])
            .output()
            .unwrap();
        assert_eq!(
            out.status.code(),
            Some(0),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    };
    assert_eq!(fetch(), "1");
    assert_eq!(fetch(), "0");

    // A balanced shard reads the record it is pinned to, and refuses one it lacks.
    fs::write(env.root.join("envlog"), "").unwrap();
    let out = env
        .chg()
        .current_dir(&other)
        .args([
            "adapter",
            "exec",
            "shard",
            "--n",
            "2",
            "--i",
            "1",
            "--balance-by",
            "HEAD",
        ])
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    // Fetched records are unpacked when first used.
    let theirs: Vec<PathBuf> = records(&store)
        .into_iter()
        .filter(|p| *p != mine[0])
        .collect();
    assert_eq!(theirs.len(), 1);
    assert_eq!(fs::read(&theirs[0]).unwrap(), fs::read(&mine[0]).unwrap());
    let log = fs::read_to_string(env.root.join("envlog")).unwrap();
    assert!(
        log.contains(&format!("shard_by={}", theirs[0].display())),
        "{log}"
    );

    // `affected` there is handed the record nearest behind its base.
    fs::write(env.root.join("envlog"), "").unwrap();
    let out = env
        .chg()
        .current_dir(&other)
        .args(["adapter", "exec", "affected", "--base", "HEAD"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0));
    let log = fs::read_to_string(env.root.join("envlog")).unwrap();
    assert!(
        log.contains(&format!("affected cover={} ", theirs[0].display())),
        "{log}"
    );

    let c2 = env.commit("lib/a.ex", "two\n");
    let out = env
        .chg()
        .args([
            "adapter",
            "exec",
            "shard",
            "--n",
            "2",
            "--i",
            "1",
            "--balance-by",
            &c2,
        ])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("chg cover fetch"));

    // --no-push keeps the record on this machine.
    let out = env.chg().args(["verify", "--no-push"]).output().unwrap();
    assert_eq!(json(&out)["cover"], "recorded");
    assert!(
        records(&store)
            .iter()
            .any(|p| p.ends_with(format!("{c2}.cover")))
    );
    let remote_refs = Std::new("git")
        .envs(GIT_ISOLATED)
        .arg("--git-dir")
        .arg(&env.remote)
        .args(["for-each-ref", "--format=%(refname)", "refs/chg/cover/"])
        .output()
        .unwrap();
    assert_eq!(
        String::from_utf8_lossy(&remote_refs.stdout).trim(),
        format!("refs/chg/cover/{c1}")
    );

    // An always_all path changed since the nearest record (c2's) rules coverage out.
    env.commit("mix.exs", "changed\n");
    fs::write(env.root.join("envlog"), "").unwrap();
    let out = env
        .chg()
        .args(["adapter", "exec", "affected", "--base", "HEAD"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("not selecting by coverage: mix.exs changed since the record of"),
        "{err}"
    );
    let log = fs::read_to_string(env.root.join("envlog")).unwrap();
    assert!(log.contains("affected cover= "), "{log}");

    // A red run keeps no record: selection trusts that what a record covered passed.
    let c3 = env.commit(".chg/broken", "test/a_test.exs:1\n");
    let out = env.chg().arg("verify").output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(json(&out)["cover"], "no record: the suite failed");
    assert!(
        !records(&store)
            .iter()
            .any(|p| p.ends_with(format!("{c3}.cover")))
    );
}

/// Dev machines never ran `chg cover fetch`, so every HCB gate selected without coverage
/// (0 of 92 published records in minis's clone, 2026-10-28). `chg check` fetches the one
/// record its selection needs, bounded, and a failed fetch costs only coverage.
#[test]
fn check_fetches_the_record_its_selection_needs_and_only_that_one() {
    let env = Env::new(tempfile::tempdir().unwrap());
    let c1 = env.head();
    assert_eq!(
        json(&env.chg().arg("verify").output().unwrap())["cover"],
        "published"
    );
    let c2 = env.commit("lib/a.ex", "two\n");
    assert_eq!(
        json(&env.chg().arg("verify").output().unwrap())["cover"],
        "published"
    );
    env.git(&["push", "-q", "origin", "master"]);

    let other = env.root.join("other");
    assert!(
        Std::new("git")
            .args(["clone", "-q"])
            .arg(&env.remote)
            .arg(&other)
            .status()
            .unwrap()
            .success()
    );
    let refs = || {
        let out = Std::new("git")
            .arg("-C")
            .arg(&other)
            .args(["for-each-ref", "--format=%(refname)", "refs/chg/cover/"])
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    };
    assert_eq!(refs(), "");
    let check = |extra: &[(&str, &str)]| {
        fs::write(env.root.join("envlog"), "").unwrap();
        let mut c = env.chg();
        c.current_dir(&other).args(["check", "--base", "HEAD"]);
        for (k, v) in extra {
            c.env(k, v);
        }
        let out = c.output().unwrap();
        let err = String::from_utf8_lossy(&out.stderr).into_owned();
        assert_eq!(out.status.code(), Some(0), "{err}");
        (err, fs::read_to_string(env.root.join("envlog")).unwrap())
    };

    // The nearest record (c2's) is fetched and handed to `affected`; c1's is not.
    let (err, log) = check(&[]);
    assert!(
        err.contains(&format!("fetched the coverage record of {}", &c2[..12])),
        "{err}"
    );
    assert_eq!(refs(), format!("refs/chg/cover/{c2}"));
    assert!(!refs().contains(&c1));
    assert!(
        log.lines()
            .any(|l| l.starts_with("affected cover=") && l.contains(&format!("{c2}.cover"))),
        "{log}"
    );
    // Already here: nothing more is fetched.
    let (err, _) = check(&[]);
    assert!(!err.contains("fetched the coverage record"), "{err}");

    // A base with no record of its own asks the remote. One that hangs is cut off at the
    // bound, and the check still judges, with the record already here.
    let git_other = |args: &[&str]| {
        assert!(
            Std::new("git")
                .arg("-C")
                .arg(&other)
                .args(["-c", "user.name=t", "-c", "user.email=t@t"])
                .args(args)
                .status()
                .unwrap()
                .success()
        );
    };
    git_other(&["commit", "-q", "--allow-empty", "-m", "c3"]);
    git_other(&["remote", "set-url", "origin", "ssh://chg.invalid/r.git"]);
    let started = std::time::Instant::now();
    let (err, log) = check(&[
        ("GIT_SSH_COMMAND", "sh -c 'sleep 30' --"),
        ("CHG_COVER_FETCH_SECS", "1"),
    ]);
    assert!(started.elapsed() < std::time::Duration::from_secs(20));
    assert!(err.contains("timed out after 1s"), "{err}");
    assert!(err.contains("coverage records not fetched"), "{err}");
    assert!(log.contains(&format!("{c2}.cover")), "{log}");

    // A change that already runs the whole suite (always_all) never asks the remote.
    fs::write(other.join("mix.exs"), "changed\n").unwrap();
    let started = std::time::Instant::now();
    let (err, _) = check(&[
        ("GIT_SSH_COMMAND", "sh -c 'sleep 30' --"),
        ("CHG_COVER_FETCH_SECS", "10"),
    ]);
    assert!(
        started.elapsed() < std::time::Duration::from_secs(10),
        "{err}"
    );
    assert!(!err.contains("coverage records not fetched"), "{err}");
    fs::remove_file(other.join("mix.exs")).ok();
    git_other(&["checkout", "-q", "--", "."]);

    // A signal to chg while the remote hangs stops the remote call too, not only chg.
    // SIGTERM, not SIGINT: a CI runner starts jobs with SIGINT ignored, and chg keeps that.
    let pidfile = env.root.join("ssh.pid");
    let mut c = std::process::Command::new(env!("CARGO_BIN_EXE_chg"));
    c.current_dir(&other)
        .args(["check", "--base", "HEAD"])
        .env(
            "GIT_SSH_COMMAND",
            format!("sh -c 'echo $$ > {}; exec sleep 30' --", pidfile.display()),
        )
        .env("CHG_COVER_FETCH_SECS", "60")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    // `env.chg()` is assert_cmd's, which cannot be signalled while it runs.
    for (k, v) in [
        ("CHG_HOME", "chg-home"),
        ("CHG_STORE", "store"),
        ("ENVLOG", "envlog"),
    ] {
        c.env(k, env.root.join(v));
    }
    c.env("CALLS", &env.calls).env_remove("CHG_GATE");
    let mut chg = c.spawn().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    let ssh_pid = loop {
        if let Ok(p) = fs::read_to_string(&pidfile)
            && !p.trim().is_empty()
        {
            break p.trim().to_string();
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the remote call never started"
        );
        std::thread::sleep(std::time::Duration::from_millis(50));
    };
    Std::new("kill")
        .args(["-TERM", &chg.id().to_string()])
        .status()
        .unwrap();
    let status = chg.wait().unwrap();
    assert_eq!(
        std::os::unix::process::ExitStatusExt::signal(&status),
        Some(15),
        "chg ends by the SIGTERM it was sent"
    );
    let alive = || {
        Std::new("kill")
            .args(["-0", &ssh_pid])
            .status()
            .unwrap()
            .success()
    };
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while alive() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    assert!(!alive(), "the remote's ssh outlived chg");
}

#[test]
fn publishing_prunes_only_this_lines_old_records() {
    let env = Env::new(tempfile::tempdir().unwrap());
    let verify = |args: &[&str]| {
        let out = env
            .chg()
            .env("CHG_COVER_MAX_AGE", "1")
            .arg("verify")
            .args(args)
            .output()
            .unwrap();
        assert_eq!(json(&out)["cover"], "published", "{}", json(&out));
    };
    let remote_records = || {
        let out = Std::new("git")
            .envs(GIT_ISOLATED)
            .arg("--git-dir")
            .arg(&env.remote)
            .args([
                "for-each-ref",
                "--format=%(refname:lstrip=3)",
                "refs/chg/cover/",
            ])
            .output()
            .unwrap();
        let mut v: Vec<String> = String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(String::from)
            .collect();
        v.sort();
        v
    };
    let sorted = |mut v: Vec<String>| {
        v.sort();
        v
    };

    let c1 = env.head();
    verify(&[]);
    env.git(&["checkout", "-q", "-b", "side"]);
    let s1 = env.commit("lib/side.ex", "side\n");
    verify(&["--ref", "verified/side"]);
    assert_eq!(remote_records(), sorted(vec![c1.clone(), s1.clone()]));

    env.git(&["checkout", "-q", "master"]);
    env.commit("lib/a.ex", "two\n");
    let c3 = env.commit("lib/a.ex", "three\n");
    verify(&[]);
    // c1 is two first-parent commits behind c3, past the reach of 1; s1 is another line's.
    assert_eq!(remote_records(), sorted(vec![s1, c3]));
}
