//! Integration tests for S4: `chg snapshot build`, `chg ws hydrate` and the post-checkout
//! hook, against a real git repo on a clone-capable filesystem.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command as Std;

use assert_cmd::Command;
use predicates::prelude::*;
use serde_json::Value;
use tempfile::TempDir;

/// A temp dir that supports cloning: APFS on macOS; on Linux only where
/// `CHG_TEST_REFLINK_DIR` points (CI mounts an XFS loop image there).
fn cow_tempdir() -> Option<TempDir> {
    if cfg!(target_os = "macos") {
        return Some(tempfile::tempdir().unwrap());
    }
    match std::env::var_os("CHG_TEST_REFLINK_DIR") {
        Some(d) => Some(tempfile::tempdir_in(d).unwrap()),
        // CI must exercise the reflink path; a silent skip would merge a broken one green.
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

const SNAP: &str = r#"#!/bin/sh
# Stand-in snapshot command: builds the artifacts once, then only what src/version changed.
echo "$(pwd)" >> "$SNAP_LOG"
[ -n "${SNAP_SLEEP:-}" ] && sleep "$SNAP_SLEEP"
# The tree has no .git; chg names its commit.
mkdir -p _build; printf %s "$CHG_SHA" > _build/sha
if [ -f _build/version ] && cmp -s src/version _build/version; then
  echo '{"work":"none","ms":1}'; exit 0
fi
work=full; [ -d deps ] && work=incremental
mkdir -p deps/lib _build apps/api/node_modules apps/web/node_modules
echo dep > deps/lib/dep.txt
cp src/version _build/version
echo mod > apps/api/node_modules/m.js
echo mod > apps/web/node_modules/m.js
echo "{\"work\":\"$work\",\"ms\":2}"
"#;

const MANIFEST: &str = r#"[adapter]
kind = "pnpm"
version = "1"
artifacts = ["deps", "_build", "apps/*/node_modules"]
inputs = ["src/**"]
always_all = [".chg/**"]

[commands]
snapshot = "sh .chg/snap.sh"
static   = "true {base}"
affected = "true {base}"
run      = "true {file}"
shard    = "true {n} {i}"
"#;

struct Env {
    _t: TempDir,
    repo: PathBuf,
    store: PathBuf,
    log: PathBuf,
    root: PathBuf,
}

impl Env {
    fn new() -> Option<Env> {
        let t = cow_tempdir()?;
        let root = fs::canonicalize(t.path()).unwrap();
        let repo = root.join("repo");
        fs::create_dir_all(repo.join(".chg")).unwrap();
        fs::create_dir_all(repo.join("src")).unwrap();
        fs::create_dir_all(repo.join("apps/api")).unwrap();
        fs::create_dir_all(repo.join("apps/web")).unwrap();
        fs::write(repo.join(".chg/adapter.toml"), MANIFEST).unwrap();
        fs::write(repo.join(".chg/snap.sh"), SNAP).unwrap();
        fs::write(repo.join(".gitignore"), "deps/\n_build/\nnode_modules/\n").unwrap();
        fs::write(repo.join("src/version"), "1\n").unwrap();
        fs::write(repo.join("src/keep.ex"), "unchanged\n").unwrap();
        fs::write(repo.join("src/gone.ex"), "deleted later\n").unwrap();
        fs::write(repo.join("apps/api/index.ts"), "x\n").unwrap();
        fs::write(repo.join("apps/web/index.ts"), "x\n").unwrap();
        let hooks = root.join("hooks");
        fs::create_dir_all(&hooks).unwrap();
        let chg = assert_cmd::cargo::cargo_bin("chg");
        fs::write(
            hooks.join("post-checkout"),
            format!(
                "#!/bin/sh\nexec \"{}\" hook post-checkout \"$@\"\n",
                chg.display()
            ),
        )
        .unwrap();
        Std::new("chmod")
            .arg("+x")
            .arg(hooks.join("post-checkout"))
            .status()
            .unwrap();
        let env = Env {
            store: root.join("store"),
            log: root.join("snap.log"),
            repo,
            root: root.clone(),
            _t: t,
        };
        env.git(&["init", "-q", "-b", "master"]);
        env.git(&["config", "core.hooksPath", hooks.to_str().unwrap()]);
        env.git(&["add", "-A"]);
        env.git(&["commit", "-q", "-m", "one"]);
        Some(env)
    }

    fn git(&self, args: &[&str]) -> String {
        let out = Std::new("git")
            .arg("-C")
            .arg(&self.repo)
            .args(["-c", "user.name=t", "-c", "user.email=t@t"])
            .args(args)
            .env("CHG_STORE", &self.store)
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

    fn commit(&self, msg: &str, edit: impl FnOnce(&Path)) -> String {
        edit(&self.repo);
        self.git(&["add", "-A"]);
        self.git(&["commit", "-q", "-m", msg]);
        self.head()
    }

    fn chg(&self) -> Command {
        let mut c = Command::cargo_bin("chg").unwrap();
        c.env("CHG_STORE", &self.store).env("SNAP_LOG", &self.log);
        c
    }

    fn build(&self, sha: &str) -> Value {
        let out = self
            .chg()
            .args(["snapshot", "build"])
            .arg(&self.repo)
            .arg(sha)
            .assert()
            .success()
            .get_output()
            .stdout
            .clone();
        serde_json::from_slice(&out).unwrap()
    }

    fn snap_dir(&self, sha: &str) -> PathBuf {
        let mut keys = fs::read_dir(&self.store).unwrap().flatten();
        let key = keys.next().unwrap().path();
        key.join("snapshots").join(sha)
    }

    fn builds(&self) -> usize {
        fs::read_to_string(&self.log)
            .map(|s| s.lines().count())
            .unwrap_or(0)
    }

    /// `git worktree add` with the hook (and CHG_STORE) in force.
    fn worktree(&self, name: &str, rev: &str) -> PathBuf {
        let path = self.root.join(name);
        self.git(&[
            "worktree",
            "add",
            "-q",
            "--detach",
            path.to_str().unwrap(),
            rev,
        ]);
        path
    }

    /// `git worktree add` without the hook.
    fn cold_worktree(&self, name: &str, rev: &str) -> PathBuf {
        let path = self.root.join(name);
        let st = Std::new("git")
            .arg("-C")
            .arg(&self.repo)
            .args(["worktree", "add", "-q", "--detach"])
            .arg(&path)
            .arg(rev)
            .env("CHG_SKIP_HYDRATE", "1")
            .status()
            .unwrap();
        assert!(st.success());
        path
    }

    fn git_in(&self, dir: &Path, args: &[&str]) -> String {
        let out = Std::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}");
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    fn hydrate(&self, dir: &Path) -> Value {
        let out = self
            .chg()
            .args(["ws", "hydrate", "--repo"])
            .arg(dir)
            .assert()
            .success()
            .get_output()
            .stdout
            .clone();
        serde_json::from_slice(&out).unwrap()
    }

    fn snapshots(&self) -> Vec<String> {
        let out = self
            .chg()
            .args(["snapshot", "list", "--repo"])
            .arg(&self.repo)
            .assert()
            .success()
            .get_output()
            .stdout
            .clone();
        String::from_utf8(out)
            .unwrap()
            .lines()
            .map(|l| {
                serde_json::from_str::<Value>(l).unwrap()["sha"]
                    .as_str()
                    .unwrap()
                    .to_string()
            })
            .collect()
    }
}

#[test]
fn build_is_idempotent_and_incremental_from_the_previous_snapshot() {
    let Some(e) = Env::new() else { return };
    let one = e.head();
    let b = e.build(&one);
    assert_eq!(b["status"], "built");
    assert_eq!(b["from"], Value::Null);
    assert_eq!(b["work"], "full");
    let snap1 = e.snap_dir(&one);
    assert!(snap1.join("deps/lib/dep.txt").exists());
    assert!(snap1.join("src/keep.ex").exists());
    assert!(
        !snap1.join(".git").exists(),
        "a snapshot holds no git metadata"
    );
    assert_eq!(fs::read_to_string(snap1.join("_build/sha")).unwrap(), one);

    // Same revision again: no adapter run at all.
    assert_eq!(e.build(&one)["status"], "exists");
    assert_eq!(e.builds(), 1);

    let two = e.commit("two", |r| {
        fs::write(r.join("src/version"), "2\n").unwrap();
        fs::remove_file(r.join("src/gone.ex")).unwrap();
        fs::write(r.join("src/new.ex"), "new\n").unwrap();
    });
    let b = e.build(&two);
    assert_eq!(b["status"], "built");
    assert_eq!(b["from"], one.as_str());
    assert_eq!(b["work"], "incremental");
    let snap2 = e.snap_dir(&two);
    assert_eq!(
        fs::read_to_string(snap2.join("src/version")).unwrap(),
        "2\n"
    );
    assert!(!snap2.join("src/gone.ex").exists());
    assert!(snap2.join("src/new.ex").exists());
    assert_eq!(
        fs::read_to_string(snap2.join("_build/sha")).unwrap(),
        two,
        "the adapter is told the new commit, not the one its cloned base was built at"
    );
    assert!(
        snap2.join("deps/lib/dep.txt").exists(),
        "artifacts carried over by the clone"
    );
    // An unchanged file keeps its mtime, so an incremental build sees no change there.
    let mtime = |p: PathBuf| fs::metadata(p).unwrap().modified().unwrap();
    assert_eq!(
        mtime(snap1.join("src/keep.ex")),
        mtime(snap2.join("src/keep.ex"))
    );
    // The first snapshot is untouched by the second's build.
    assert_eq!(
        fs::read_to_string(snap1.join("src/version")).unwrap(),
        "1\n"
    );
}

#[test]
fn worktree_add_hydrates_from_the_nearest_ancestor_snapshot() {
    let Some(e) = Env::new() else { return };
    let one = e.head();
    e.build(&one);
    let two = e.commit("two", |r| fs::write(r.join("src/version"), "2\n").unwrap());
    e.build(&two);
    let three = e.commit("three", |r| {
        fs::write(r.join("src/other.ex"), "o\n").unwrap()
    });

    let ws = e.worktree("ws3", &three);
    for p in [
        "deps/lib/dep.txt",
        "_build/version",
        "apps/api/node_modules/m.js",
        "apps/web/node_modules/m.js",
    ] {
        assert!(ws.join(p).exists(), "{p} not hydrated");
    }
    assert_eq!(
        fs::read_to_string(ws.join("_build/version")).unwrap(),
        "2\n",
        "nearest is two, not one"
    );
    assert!(!ws.join(".chg-hydrate.tmp").exists());
    // Unchanged sources carry the snapshot's mtime, so the build sees them as built;
    // a file the snapshot lacks keeps its checkout time.
    let mtime = |p: PathBuf| fs::metadata(p).unwrap().modified().unwrap();
    let snap2 = e.snap_dir(&two);
    assert_eq!(
        mtime(ws.join("src/keep.ex")),
        mtime(snap2.join("src/keep.ex"))
    );
    assert!(mtime(ws.join("src/other.ex")) > mtime(snap2.join("src/keep.ex")));
    // A directory with the snapshot's entries carries its mtime; `src` gained one.
    assert_eq!(mtime(ws.join("apps/api")), mtime(snap2.join("apps/api")));
    assert_ne!(mtime(ws.join("src")), mtime(snap2.join("src")));

    // The hook already hydrated ws1; a second hydrate finds nothing missing.
    let ws1 = e.worktree("ws1", &one);
    let again = e.hydrate(&ws1);
    assert_eq!(again["paths"], serde_json::json!([]));
}

#[test]
fn hydrate_fills_in_around_tracked_files_and_resolves_the_worktree_root() {
    let Some(e) = Env::new() else { return };
    let one = e.head();
    e.build(&one);
    // A tracked file inside an artifact dir, like `priv/plts/.gitkeep`.
    fs::create_dir_all(e.repo.join("deps")).unwrap();
    fs::write(e.repo.join("deps/.gitkeep"), "").unwrap();
    e.git(&["add", "-f", "deps/.gitkeep"]);
    e.git(&["commit", "-q", "-m", "keep"]);
    let two = e.head();
    let ws = e.cold_worktree("ws", &two);
    assert!(ws.join("deps/.gitkeep").exists());

    // `--repo` names a subdirectory; artifacts still land at the worktree root.
    let out = e.hydrate(&ws.join("src"));
    assert_eq!(out["paths"][0], "_build");
    assert!(ws.join("deps/lib/dep.txt").exists(), "deps filled in");
    assert!(ws.join("deps/.gitkeep").exists(), "tracked file kept");
    assert!(ws.join("_build/version").exists());
    assert!(!ws.join("src/deps").exists() && !ws.join("src/_build").exists());
    assert_eq!(e.git_in(&ws, &["status", "--porcelain"]), "");
}

#[test]
fn a_hydrate_killed_between_renames_is_undone_by_the_next() {
    let Some(e) = Env::new() else { return };
    let one = e.head();
    e.build(&one);
    let ws = e.cold_worktree("ws", &one);
    // What a hydrate killed after moving `_build` (and before `deps`) leaves: a partial
    // `_build` and the journal naming it.
    fs::create_dir_all(ws.join("_build/partial")).unwrap();
    let git_dir = PathBuf::from(e.git_in(&ws, &["rev-parse", "--absolute-git-dir"]));
    let mut journal = b"M".to_vec();
    journal.extend_from_slice(ws.join("_build").to_str().unwrap().as_bytes());
    journal.push(0);
    fs::write(git_dir.join("chg-hydrate.journal"), journal).unwrap();

    e.hydrate(&ws);
    assert!(
        !ws.join("_build/partial").exists(),
        "the partial move was undone"
    );
    assert!(ws.join("_build/version").exists() && ws.join("deps/lib/dep.txt").exists());
    assert!(!git_dir.join("chg-hydrate.journal").exists());
}

#[test]
fn a_tracked_file_the_base_snapshot_modified_is_reset() {
    let Some(e) = Env::new() else { return };
    // The first snapshot's command rewrites a tracked file, as `deps.get` may rewrite a
    // lockfile; the next commit leaves that file alone.
    let one = e.commit("dirty", |r| {
        let snap = fs::read_to_string(r.join(".chg/snap.sh")).unwrap();
        fs::write(
            r.join(".chg/snap.sh"),
            snap.replace(
                "echo \"$(pwd)\"",
                "echo rewritten > src/keep.ex\necho \"$(pwd)\"",
            ),
        )
        .unwrap();
    });
    e.build(&one);
    assert_eq!(
        fs::read_to_string(e.snap_dir(&one).join("src/keep.ex")).unwrap(),
        "rewritten\n"
    );
    let two = e.commit("clean", |r| {
        let snap = fs::read_to_string(r.join(".chg/snap.sh")).unwrap();
        fs::write(
            r.join(".chg/snap.sh"),
            snap.replace(
                "echo rewritten > src/keep.ex\n",
                "cp src/keep.ex \"$SNAP_LOG.seen\"\n",
            ),
        )
        .unwrap();
    });
    e.build(&two);
    assert_eq!(
        fs::read_to_string(e.root.join("snap.log.seen")).unwrap(),
        "unchanged\n",
        "the snapshot command saw the committed file"
    );
}

#[test]
fn concurrent_builds_take_turns() {
    let Some(e) = Env::new() else { return };
    let one = e.commit("slow", |r| {
        let snap = fs::read_to_string(r.join(".chg/snap.sh")).unwrap();
        let guarded = snap.replacen(
            "echo \"$(pwd)\" >> \"$SNAP_LOG\"",
            "mkdir \"$SNAP_LOG.busy\" || { echo overlap >&2; exit 1; }\nsleep 1\nrmdir \"$SNAP_LOG.busy\"\necho \"$(pwd)\" >> \"$SNAP_LOG\"",
            1,
        );
        fs::write(r.join(".chg/snap.sh"), guarded).unwrap();
    });
    let two = e.commit("two", |r| fs::write(r.join("src/version"), "2\n").unwrap());
    let spawn = |sha: &str| {
        Std::new(assert_cmd::cargo::cargo_bin("chg"))
            .args(["snapshot", "build"])
            .arg(&e.repo)
            .arg(sha)
            .env("CHG_STORE", &e.store)
            .env("SNAP_LOG", &e.log)
            .output()
    };
    let (a, b) = std::thread::scope(|s| {
        let a = s.spawn(|| spawn(&one));
        let b = s.spawn(|| spawn(&two));
        (a.join().unwrap().unwrap(), b.join().unwrap().unwrap())
    });
    for o in [&a, &b] {
        assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    }
    assert_eq!(e.builds(), 2);
}

#[test]
fn a_snapshot_dir_without_readable_meta_is_rebuilt_and_collected() {
    let Some(e) = Env::new() else { return };
    let one = e.head();
    e.build(&one);
    fs::write(e.snap_dir(&one).join(".chg-snapshot.json"), "{").unwrap();
    assert!(e.snapshots().is_empty());
    assert_eq!(e.build(&one)["status"], "built");
    assert_eq!(e.snapshots(), vec![one.clone()]);

    let junk = e
        .snap_dir(&one)
        .with_file_name("0000000000000000000000000000000000000000");
    fs::create_dir_all(junk.join("deps")).unwrap();
    e.chg()
        .args(["snapshot", "gc", "--repo"])
        .arg(&e.repo)
        .assert()
        .success();
    assert!(!junk.exists());
    assert_eq!(e.snapshots(), vec![one]);
}

#[test]
fn build_from_a_subdirectory_uses_the_repo_root() {
    let Some(e) = Env::new() else { return };
    let one = e.head();
    e.build(&one);
    let two = e.commit("two", |r| fs::write(r.join("src/version"), "2\n").unwrap());
    e.chg()
        .args(["snapshot", "build"])
        .arg(e.repo.join("src"))
        .arg(&two)
        .assert()
        .success();
    assert_eq!(
        fs::read_to_string(e.snap_dir(&two).join("src/version")).unwrap(),
        "2\n"
    );
}

#[test]
fn no_snapshot_exits_3_and_leaves_the_worktree_cold() {
    let Some(e) = Env::new() else { return };
    let ws = e.worktree("cold", &e.head());
    assert!(!ws.join("deps").exists());
    e.chg()
        .args(["ws", "hydrate", "--repo"])
        .arg(&ws)
        .assert()
        .code(3)
        .stderr(predicate::str::contains(
            "no snapshot is an ancestor of HEAD",
        ));
    let entries: Vec<_> = fs::read_dir(&ws)
        .unwrap()
        .flatten()
        .map(|d| d.file_name())
        .collect();
    assert!(
        !entries
            .iter()
            .any(|n| n == "deps" || n == "_build" || n == ".chg-hydrate.tmp")
    );
}

#[test]
fn a_failed_move_rolls_back_every_artifact() {
    let Some(e) = Env::new() else { return };
    let one = e.head();
    e.build(&one);
    // At HEAD `apps/api` is a file, so `apps/api/node_modules` cannot be placed after
    // `_build` already was.
    let two = e.commit("two", |r| {
        fs::remove_dir_all(r.join("apps/api")).unwrap();
        fs::write(r.join("apps/api"), "now a file\n").unwrap();
    });
    let ws = e.root.join("ws");
    Std::new("git")
        .arg("-C")
        .arg(&e.repo)
        .args([
            "worktree",
            "add",
            "-q",
            "--detach",
            ws.to_str().unwrap(),
            &two,
        ])
        .env("CHG_SKIP_HYDRATE", "1")
        .status()
        .unwrap();
    e.chg()
        .args(["ws", "hydrate", "--repo"])
        .arg(&ws)
        .assert()
        .code(1)
        .stderr(predicate::str::contains("restored to its unhydrated state"));
    for p in [
        "_build",
        "deps",
        "apps/web/node_modules",
        ".chg-hydrate.tmp",
    ] {
        assert!(!ws.join(p).exists(), "{p} left behind");
    }
    assert_eq!(
        fs::read_to_string(ws.join("apps/api")).unwrap(),
        "now a file\n"
    );
}

#[test]
fn gc_keeps_the_newest_three_and_any_live_lease() {
    let Some(e) = Env::new() else { return };
    let mut shas = vec![e.head()];
    e.build(&shas[0]);
    let leased = e.worktree("leased", &shas[0]);
    assert!(leased.join("deps").exists());
    for i in 2..=5 {
        shas.push(e.commit(&format!("c{i}"), |r| {
            fs::write(r.join("src/version"), format!("{i}\n")).unwrap()
        }));
        e.build(shas.last().unwrap());
    }
    let kept = e.snapshots();
    assert_eq!(
        kept,
        vec![
            shas[4].clone(),
            shas[3].clone(),
            shas[2].clone(),
            shas[0].clone()
        ]
    );

    // Once the workspace is gone its lease is dead, and the snapshot goes too.
    e.git(&["worktree", "remove", "--force", leased.to_str().unwrap()]);
    e.chg()
        .args(["snapshot", "gc", "--repo"])
        .arg(&e.repo)
        .assert()
        .success();
    assert_eq!(
        e.snapshots(),
        vec![shas[4].clone(), shas[3].clone(), shas[2].clone()]
    );
}

#[test]
fn a_failed_snapshot_command_leaves_no_snapshot() {
    let Some(e) = Env::new() else { return };
    let sha = e.commit("broken", |r| {
        fs::write(r.join(".chg/snap.sh"), "echo nope\n").unwrap()
    });
    e.chg()
        .args(["snapshot", "build"])
        .arg(&e.repo)
        .arg(&sha)
        .assert()
        .code(1)
        .stderr(predicate::str::contains("snapshot build failed"));
    assert!(e.snapshots().is_empty());
    let snaps = fs::read_dir(&e.store)
        .unwrap()
        .flatten()
        .next()
        .unwrap()
        .path()
        .join("snapshots");
    assert_eq!(
        fs::read_dir(snaps).unwrap().count(),
        0,
        "temp dir left behind"
    );
}

#[test]
fn timeout_secs_overrides_the_snapshot_cap() {
    let Some(e) = Env::new() else { return };
    let sha = e.head();
    e.chg()
        .env("SNAP_SLEEP", "30")
        .args(["snapshot", "build", "--timeout-secs", "1"])
        .arg(&e.repo)
        .arg(&sha)
        .assert()
        .code(1)
        .stderr(predicate::str::contains("timed out after 1s"));
    assert!(
        e.snapshots().is_empty(),
        "a timed-out build leaves no snapshot"
    );
}

#[test]
fn a_zero_timeout_is_refused_before_any_work() {
    let Some(e) = Env::new() else { return };
    let sha = e.head();
    e.chg()
        .args(["snapshot", "build", "--timeout-secs", "0"])
        .arg(&e.repo)
        .arg(&sha)
        .assert()
        .code(2)
        .stderr(predicate::str::contains("--timeout-secs"));
    assert_eq!(e.builds(), 0, "no adapter run");
}

#[test]
fn refresh_builds_only_from_an_ancestor_and_never_waits_for_another_build() {
    use std::os::unix::io::AsRawFd;
    let Some(e) = Env::new() else { return };
    // Through the git dir, as the detached shadow check calls it.
    let git_dir = e.repo.join(".git");
    let refresh = |sha: &str| -> Value {
        let out = e
            .chg()
            .args(["snapshot", "refresh"])
            .arg(&git_dir)
            .arg(sha)
            .assert()
            .success()
            .get_output()
            .stdout
            .clone();
        serde_json::from_slice(&out).unwrap()
    };
    let one = e.head();
    assert_eq!(refresh(&one)["status"], "no-ancestor", "never cold");
    assert_eq!(e.builds(), 0);

    e.build(&one);
    let two = e.commit("two", |r| fs::write(r.join("src/version"), "2\n").unwrap());
    let key = e
        .snap_dir(&one)
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();
    let held = fs::File::create(key.join("build.lock")).unwrap();
    // SAFETY: flock on a file this test owns; released when it closes.
    assert_eq!(unsafe { libc::flock(held.as_raw_fd(), libc::LOCK_EX) }, 0);
    assert_eq!(refresh(&two)["status"], "busy", "skipped, not queued");
    drop(held);
    assert_eq!(e.builds(), 1);

    let built = refresh(&two);
    assert_eq!(built["status"], "built", "{built}");
    assert_eq!(built["from"], one.as_str());
    assert_eq!(e.snapshots(), vec![two.clone(), one]);
    assert_eq!(refresh(&two)["status"], "exists");
}
