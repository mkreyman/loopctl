//! `chg snapshot build <repo> <sha> [--timeout-secs N]` (design §3.5, story S4). The
//! flag replaces the 30 min cap on the adapter's `snapshot` command, for a first full
//! build on a slow machine; `chg culprit --snapshot-timeout-secs` does the same for the
//! snapshot a search builds.
//!
//! 1. CoW-clone the nearest existing snapshot (else start from an empty dir).
//! 2. Bring its source files to `<sha>`: only the tracked files that differ from `<sha>`
//!    are rewritten, so every unchanged file keeps its mtime and the adapter's
//!    incremental build sees only the delta.
//! 3. Run the adapter's `snapshot` command in it.
//! 4. Rename it into place atomically, then GC.
//!
//! Every build runs at the store's one build path, where shadow checks also run, so the
//! paths a build bakes in are the checks' own (`Store::build_dir`). A crash at any step
//! leaves that dir behind; the next build or check under the build lock clears it, and it
//! is never mistaken for a snapshot, because only a renamed dir with its meta file counts.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use crate::adapter::{self, Invoked};
use crate::clone::clone_tree;
use crate::contract::CommandName;
use crate::git;
use crate::output::Document;
use crate::store::{self, META, Meta, Store};

pub enum Built {
    /// The snapshot already existed; nothing was done.
    Exists(Meta),
    Built(Meta),
}

/// Removes the temp dir on drop unless disarmed.
struct TempGuard(Option<PathBuf>);

impl Drop for TempGuard {
    fn drop(&mut self) {
        if let Some(p) = self.0.take() {
            let _ = fs::remove_dir_all(p);
        }
    }
}

/// What `refresh` did.
pub enum Refresh {
    Done(Built),
    /// Another build held the build lock.
    Busy,
    /// No snapshot is an ancestor of the commit; a refresh never builds cold.
    NoAncestor,
}

pub fn build(repo: &Path, rev: &str, timeout: Duration) -> Result<Built, String> {
    match build_inner(repo, rev, timeout, false)? {
        Refresh::Done(b) => Ok(b),
        Refresh::Busy | Refresh::NoAncestor => unreachable!("only a refresh skips"),
    }
}

/// Build the snapshot of `rev` from an older snapshot of its own history, then GC. Unlike
/// `build` it never waits for another build and never builds cold: it is the background
/// job after a shadow check, and the next push refreshes again.
pub fn refresh(repo: &Path, rev: &str, timeout: Duration) -> Result<Refresh, String> {
    let r = build_inner(repo, rev, timeout, true)?;
    if let Refresh::Done(Built::Built(_)) = r {
        Store::for_repo(repo)?
            .gc()
            .map_err(|e| format!("gc: {e}"))?;
    }
    Ok(r)
}

fn build_inner(
    repo: &Path,
    rev: &str,
    timeout: Duration,
    refresh: bool,
) -> Result<Refresh, String> {
    let started = Instant::now();
    let sha = git::resolve(repo, rev)?;
    let store = Store::for_repo(repo)?;
    if let Some(m) = store.list().into_iter().find(|m| m.sha == sha) {
        return Ok(Refresh::Done(Built::Exists(m)));
    }
    fs::create_dir_all(store.snapshots()).map_err(|e| format!("creating the store: {e}"))?;
    let _build = if refresh {
        match store
            .try_lock_build()
            .map_err(|e| format!("build lock: {e}"))?
        {
            Some(l) => l,
            None => return Ok(Refresh::Busy),
        }
    } else {
        store.lock_build().map_err(|e| format!("build lock: {e}"))?
    };
    // Another build may have finished this one while we waited for the lock.
    if let Some(m) = store.list().into_iter().find(|m| m.sha == sha) {
        return Ok(Refresh::Done(Built::Exists(m)));
    }

    // Whatever a killed build or check left here is ours to clear under the build lock.
    let tmp = store.build_dir();
    crate::scratch::clear(&git::common_dir(repo)?, &tmp);
    let mut guard = TempGuard(Some(tmp.clone()));

    // Chosen and cloned under the store lock, so GC cannot remove it in between. Prefer
    // an ancestor (smallest diff); any snapshot beats none.
    let base = {
        let _lock = store
            .lock_shared()
            .map_err(|e| format!("store lock: {e}"))?;
        let ancestor = store.nearest_ancestor(repo, &sha).map(|(m, _)| m);
        if refresh && ancestor.is_none() {
            return Ok(Refresh::NoAncestor);
        }
        let base = ancestor.or_else(|| store.list().into_iter().next());
        if let Some(b) = &base {
            clone_tree(&store.snapshot(&b.sha), &tmp)
                .map_err(|e| format!("cloning snapshot {}: {e}", b.sha))?;
        }
        base
    };

    match &base {
        Some(b) => {
            let _ = fs::remove_file(tmp.join(META));
            apply_diff(repo, &b.sha, &sha, &tmp)?;
        }
        None => {
            fs::create_dir(&tmp).map_err(|e| format!("creating {}: {e}", tmp.display()))?;
            checkout(repo, &sha, &tmp, None)?;
        }
    }

    // By its resolved path, as a check's worktree is: the slot (so the test database)
    // and every path the build bakes in are then the same ones a check here sees.
    let at = fs::canonicalize(&tmp).unwrap_or_else(|_| tmp.clone());
    // The build dir is a plain tree with no `.git`, so the adapter cannot ask git which
    // commit it is: it gets the sha as `CHG_SHA`.
    let doc = match adapter::invoke(
        &at,
        CommandName::Snapshot,
        BTreeMap::from([("sha", sha.clone())]),
        None,
        timeout,
    ) {
        Invoked::Ok(Document::Snapshot(s)) => s,
        Invoked::Ok(_) | Invoked::Failed(_) => unreachable!("snapshot documents never fail"),
        Invoked::Broken(why) => return Err(format!("adapter snapshot {why}")),
    };

    let meta = Meta {
        sha: sha.clone(),
        built_at_ms: store::now_ms(),
        from: base.map(|b| b.sha),
        work: serde_json::to_value(doc.work)
            .ok()
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_default(),
        ms: started.elapsed().as_millis() as u64,
    };
    let mut f = fs::File::create(tmp.join(META)).map_err(|e| format!("writing meta: {e}"))?;
    f.write_all(&serde_json::to_vec(&meta).expect("meta serializes"))
        .and_then(|_| f.sync_all())
        .map_err(|e| format!("writing meta: {e}"))?;

    let target = store.snapshot(&sha);
    // Under the build lock nothing else renames into `target`, and the check above found
    // no snapshot there, so whatever is there has no readable meta: move it aside.
    if target.symlink_metadata().is_ok() {
        let trash = store.trash_path(&sha);
        match fs::rename(&target, &trash) {
            Ok(()) => {
                let _ = fs::remove_dir_all(trash);
            }
            // A concurrent GC got there first.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(format!(
                    "moving aside the unreadable {}: {e}",
                    target.display()
                ));
            }
        }
    }
    fs::rename(&tmp, &target).map_err(|e| format!("renaming the snapshot into place: {e}"))?;
    guard.0 = None;
    Ok(Refresh::Done(Built::Built(meta)))
}

/// Brings `dir`, a clone of the snapshot of `from`, to commit `to`. The paths that
/// changed between the commits are removed first, which covers deletions and type
/// changes; then every tracked file that differs from `to` is written. That second step
/// also resets any tracked file the base's snapshot command modified (a rewritten
/// lockfile, generated code), which a `from..to` diff cannot see.
fn apply_diff(repo: &Path, from: &str, to: &str, dir: &Path) -> Result<(), String> {
    let mut c = git::cmd(repo);
    c.args(["diff", "--no-renames", "--name-status", "-z", from, to]);
    let out = git::run(c)?;
    let mut fields = out.stdout.split(|b| *b == 0).filter(|f| !f.is_empty());
    while let (Some(_status), Some(path)) = (fields.next(), fields.next()) {
        let p = dir.join(String::from_utf8_lossy(path).as_ref());
        if p.is_dir() && !p.is_symlink() {
            let _ = fs::remove_dir_all(&p);
        } else {
            let _ = fs::remove_file(&p);
        }
    }
    let stale = differing(repo, to, dir)?;
    if stale.is_empty() {
        return Ok(());
    }
    checkout(repo, to, dir, Some(&stale))
}

/// The tracked files of `sha` that are missing from `dir` or differ from it in content.
/// `update-index --refresh` records the stat data of each file that matches, so
/// `diff-files` then lists only the rest; matching files are read, never written.
fn differing(repo: &Path, sha: &str, dir: &Path) -> Result<Vec<String>, String> {
    let index_dir = tempfile::tempdir().map_err(|e| format!("temp index: {e}"))?;
    let index = index_dir.path().join("index");
    let git_dir = git::common_dir(repo)?;
    let in_dir = || {
        let mut c = git::cmd(dir);
        c.env("GIT_DIR", &git_dir)
            .env("GIT_WORK_TREE", dir)
            .env("GIT_INDEX_FILE", &index);
        c
    };
    let mut rt = in_dir();
    rt.args(["read-tree", sha]);
    git::run(rt)?;
    // Exits 1 when some file needs updating, which is exactly what diff-files reports.
    let _ = in_dir()
        .args(["update-index", "-q", "--refresh"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let mut df = in_dir();
    df.args(["diff-files", "--name-only", "-z"]);
    let out = git::run(df)?;
    Ok(out
        .stdout
        .split(|b| *b == 0)
        .filter(|f| !f.is_empty())
        .map(|f| String::from_utf8_lossy(f).into_owned())
        .collect())
}

/// Writes the files of commit `sha` (all, or only `paths`) into `dir`, which must be
/// absolute, with
/// `checkout-index`, which applies the same filters as a worktree checkout and, unlike
/// `git archive`, ignores `export-ignore`.
fn checkout(repo: &Path, sha: &str, dir: &Path, paths: Option<&[String]>) -> Result<(), String> {
    let index_dir = tempfile::tempdir().map_err(|e| format!("temp index: {e}"))?;
    let index_path = index_dir.path().join("index");

    let mut rt = git::cmd(repo);
    rt.env("GIT_INDEX_FILE", &index_path)
        .args(["read-tree", sha]);
    git::run(rt)?;

    // `dir` as the work tree rather than a `--prefix`: checkout-index refuses to run
    // without one, and the detached shadow check reaches the repo by its git dir.
    let mut co = git::cmd(repo);
    co.env("GIT_INDEX_FILE", &index_path)
        .env("GIT_WORK_TREE", dir)
        .args(["checkout-index", "-f"]);
    match paths {
        None => {
            co.arg("-a");
            git::run(co)?;
        }
        Some(paths) => {
            co.args(["--stdin", "-z"])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());
            let mut child = co.spawn().map_err(|e| format!("checkout-index: {e}"))?;
            let mut input = Vec::new();
            for p in paths {
                input.extend_from_slice(p.as_bytes());
                input.push(0);
            }
            let mut stdin = child.stdin.take().expect("piped");
            let writer = std::thread::spawn(move || stdin.write_all(&input));
            let out = child
                .wait_with_output()
                .map_err(|e| format!("checkout-index: {e}"))?;
            let _ = writer.join();
            if !out.status.success() {
                return Err(format!(
                    "checkout-index failed: {}",
                    String::from_utf8_lossy(&out.stderr).trim()
                ));
            }
        }
    }
    Ok(())
}
