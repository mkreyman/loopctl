//! Integration tests: `chg adapter …` against a fixture repo for each adapter kind.

use std::path::{Path, PathBuf};

use assert_cmd::Command;
use predicates::prelude::*;
use tempfile::TempDir;

const KINDS: [&str; 2] = ["elixir", "pnpm"];

/// Copies a fixture into a temp dir so tests can edit it freely.
fn fixture(kind: &str) -> TempDir {
    let src = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(kind);
    let dir = tempfile::tempdir().unwrap();
    copy_dir(&src, dir.path());
    dir
}

fn copy_dir(src: &Path, dst: &Path) {
    std::fs::create_dir_all(dst).unwrap();
    for e in std::fs::read_dir(src).unwrap() {
        let e = e.unwrap();
        let to: PathBuf = dst.join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            copy_dir(&e.path(), &to);
        } else {
            std::fs::copy(e.path(), &to).unwrap();
        }
    }
}

fn chg() -> Command {
    Command::cargo_bin("chg").unwrap()
}

fn exec(repo: &Path, args: &[&str]) -> Command {
    let mut c = chg();
    c.args(["adapter", "exec"])
        .args(args)
        .arg("--repo")
        .arg(repo);
    c
}

#[test]
fn version_prints_the_contract_version() {
    chg()
        .arg("--version")
        .assert()
        .success()
        .stdout(predicate::str::contains("(adapter contract 1)"));
}

#[test]
fn validate_accepts_each_fixture() {
    for kind in KINDS {
        let repo = fixture(kind);
        chg()
            .args(["adapter", "validate", "--repo"])
            .arg(repo.path())
            .assert()
            .success()
            .stdout(predicate::str::contains(format!(
                "ok: {kind} adapter, contract 1"
            )));
    }
}

#[test]
fn validate_rejects_unknown_key_missing_command_and_empty_always_all_together() {
    let repo = fixture("elixir");
    let path = repo.path().join(".chg/adapter.toml");
    let text = std::fs::read_to_string(&path).unwrap();
    let start = text.find("always_all = [").unwrap();
    let end = start + text[start..].find(']').unwrap() + 1;
    let text = format!("{}always_all = []{}", &text[..start], &text[end..])
        .replace("[commands]", "[commands]\nlint = \"x\"")
        .lines()
        .filter(|l| !l.starts_with("shard"))
        .collect::<Vec<_>>()
        .join("\n");
    std::fs::write(&path, text).unwrap();
    chg()
        .args(["adapter", "validate", "--repo"])
        .arg(repo.path())
        .assert()
        .code(1)
        .stderr(predicate::str::contains("3 problem(s)"))
        .stderr(predicate::str::contains("unknown key `commands.lint`"))
        .stderr(predicate::str::contains("missing command `commands.shard`"))
        .stderr(predicate::str::contains("`adapter.always_all` is empty"));
}

#[test]
fn validate_names_both_versions_on_mismatch() {
    let repo = fixture("pnpm");
    let path = repo.path().join(".chg/adapter.toml");
    let text = std::fs::read_to_string(&path)
        .unwrap()
        .replace("version = \"1\"", "version = \"7\"");
    std::fs::write(&path, text).unwrap();
    chg()
        .args(["adapter", "validate", "--repo"])
        .arg(repo.path())
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "adapter declares contract version \"7\" but this chg implements contract version \"1\"",
        ));
}

#[test]
fn validate_fails_when_the_manifest_is_missing() {
    let dir = tempfile::tempdir().unwrap();
    chg()
        .args(["adapter", "validate", "--repo"])
        .arg(dir.path())
        .assert()
        .code(1)
        .stderr(predicate::str::contains("cannot read"));
}

#[test]
fn affected_returns_the_adapter_subset_and_routes_noise_to_stderr() {
    for kind in KINDS {
        let repo = fixture(kind);
        exec(repo.path(), &["affected", "--base", "abc123"])
            .assert()
            .success()
            .stdout(
                "{\"mode\":\"subset\",\"reason\":\"changed since abc123\",\"tests\":[\"test/a_test.exs\",\"test/b c_test.exs\"]}\n",
            )
            .stderr(predicate::str::contains("Compiling 2 files"));
    }
}

#[test]
fn affected_fails_closed_on_every_kind_of_broken_output() {
    for mode in ["malformed", "garbage", "silent", "crash"] {
        for kind in KINDS {
            let repo = fixture(kind);
            exec(repo.path(), &["affected", "--base", "abc123"])
                .env("FAKE_MODE", mode)
                .assert()
                .success()
                .stdout(predicate::str::starts_with(
                    "{\"mode\":\"all\",\"reason\":\"failed closed: ",
                ))
                .stderr(predicate::str::contains("failing closed to the full suite"));
        }
    }
}

#[test]
fn affected_fails_closed_on_timeout_and_kills_the_adapter() {
    let repo = fixture("elixir");
    let started = std::time::Instant::now();
    exec(
        repo.path(),
        &["affected", "--base", "abc", "--timeout-secs", "1"],
    )
    .env("FAKE_MODE", "sleep")
    .assert()
    .success()
    .stdout(predicate::str::contains("timed out after 1s"));
    assert!(
        started.elapsed().as_secs() < 10,
        "the adapter was not killed"
    );
}

#[test]
fn affected_fails_closed_on_an_invalid_manifest() {
    let repo = fixture("elixir");
    std::fs::write(repo.path().join(".chg/adapter.toml"), "[adapter]\n").unwrap();
    exec(repo.path(), &["affected", "--base", "abc"])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"mode\":\"all\""));
}

#[test]
fn affected_requires_base() {
    let repo = fixture("elixir");
    exec(repo.path(), &["affected"])
        .assert()
        .success()
        .stdout(predicate::str::contains("needs --base"));
}

#[test]
fn run_exports_the_isolation_env_and_quotes_the_file() {
    let repo = fixture("elixir");
    let out = exec(repo.path(), &["run", "--file", "test/x y_test.exs"])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let out = String::from_utf8(out).unwrap();
    assert!(out.contains("test/x y_test.exs@ws"), "{out}");
}

#[test]
fn run_failure_exits_1_with_the_document() {
    let repo = fixture("pnpm");
    exec(repo.path(), &["run", "--file", "fail.txt"])
        .assert()
        .code(1)
        .stdout(predicate::str::contains("\"status\":\"fail\""));
}

#[test]
fn other_commands_exit_2_on_contract_violations() {
    let repo = fixture("pnpm");
    exec(repo.path(), &["snapshot"])
        .env("FAKE_MODE", "garbage")
        .assert()
        .code(2);
    // A crash that printed a success-shaped document is not trusted.
    exec(repo.path(), &["static", "--base", "abc"])
        .env("FAKE_MODE", "crash")
        .assert()
        .code(2);
    exec(repo.path(), &["shard", "--n", "2"])
        .assert()
        .code(2)
        .stderr(predicate::str::contains("needs --i"));
}

#[test]
fn snapshot_static_and_shard_succeed_on_good_output() {
    for kind in KINDS {
        let repo = fixture(kind);
        exec(repo.path(), &["snapshot"])
            .assert()
            .success()
            .stdout("{\"work\":\"none\",\"ms\":3}\n");
        exec(repo.path(), &["static", "--base", "abc"])
            .assert()
            .success();
        exec(repo.path(), &["shard", "--n", "4", "--i", "2"])
            .assert()
            .success()
            .stdout(predicate::str::contains("shard-2-of-4"));
    }
}

#[test]
fn unknown_command_is_rejected() {
    let repo = fixture("elixir");
    exec(repo.path(), &["lint"]).assert().code(2);
}

#[test]
fn a_failure_document_from_a_clean_exit_is_a_contract_violation() {
    let repo = fixture("elixir");
    exec(repo.path(), &["static", "--base", "abc"])
        .env("FAKE_MODE", "fail0")
        .assert()
        .code(2)
        .stderr(predicate::str::contains(
            "exited Some(0) but its document reports failure",
        ));
}

#[test]
fn a_helper_left_holding_stdout_neither_delays_nor_outlives_the_command() {
    let repo = fixture("pnpm");
    let started = std::time::Instant::now();
    exec(repo.path(), &["snapshot"])
        .env("FAKE_MODE", "orphan")
        .assert()
        .success()
        .stdout("{\"work\":\"none\",\"ms\":1}\n");
    assert!(started.elapsed().as_secs() < 4, "waited on the helper");
    let pid = std::fs::read_to_string(repo.path().join(".chg/orphan.pid")).unwrap();
    let alive = std::process::Command::new("kill")
        .args(["-0", pid.trim()])
        .status()
        .unwrap()
        .success();
    assert!(!alive, "helper {pid} outlived the command");
}

#[test]
fn a_timeout_still_relays_the_progress_printed_so_far() {
    let repo = fixture("elixir");
    exec(repo.path(), &["snapshot", "--timeout-secs", "1"])
        .env("FAKE_MODE", "hang")
        .assert()
        .code(2)
        .stderr(predicate::str::contains("Compiling 2 files"))
        .stderr(predicate::str::contains("Compiling step 7"))
        .stderr(predicate::str::contains("timed out after 1s"));
}

#[test]
fn shard_indexes_must_be_one_based_and_in_range() {
    let repo = fixture("elixir");
    for (n, i) in [("0", "0"), ("4", "0"), ("4", "5")] {
        exec(repo.path(), &["shard", "--n", n, "--i", i])
            .assert()
            .code(2)
            .stderr(predicate::str::contains("needs 1 <= --i <= --n"));
    }
    exec(repo.path(), &["shard", "--n", "4", "--i", "4"])
        .assert()
        .success();
}

fn slot_of(cmd: &mut Command) -> String {
    let out = cmd.assert().success().get_output().stdout.clone();
    let out = String::from_utf8(out).unwrap();
    let at = out.find("@ws").expect("slot in result id");
    out[at + 1..at + 11].to_string()
}

#[test]
fn the_workspace_slot_follows_the_tree_not_the_spelling_of_its_path() {
    let a = fixture("elixir");
    let b = fixture("elixir");
    let mut abs = chg();
    abs.args(["adapter", "exec", "run", "--file", "t.exs", "--repo"])
        .arg(a.path());
    let mut slash = chg();
    slash
        .args(["adapter", "exec", "run", "--file", "t.exs", "--repo"])
        .arg(format!("{}/", a.path().display()));
    let mut dot_a = chg();
    dot_a
        .current_dir(a.path())
        .args(["adapter", "exec", "run", "--file", "t.exs", "--repo", "."]);
    let mut dot_b = chg();
    dot_b
        .current_dir(b.path())
        .args(["adapter", "exec", "run", "--file", "t.exs", "--repo", "."]);
    let s = slot_of(&mut abs);
    assert_eq!(s, slot_of(&mut slash));
    assert_eq!(s, slot_of(&mut dot_a));
    assert_ne!(s, slot_of(&mut dot_b));
}
