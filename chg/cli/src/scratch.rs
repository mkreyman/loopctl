//! Throwaway worktrees for checks that must not touch a live tree: the shadow check, the
//! gate-mode check, culprit finding and the revert builder. Each caller owns one fixed
//! path per repo under a lock, so its workspace slot (and test database) is the same on
//! every run.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Instant;

use crate::check::{self, Verdict};
use crate::git;
use crate::store::Store;
use crate::ws::{self, Hydrated};

/// What a check at the build path came to.
pub enum AtBuild {
    Checked {
        verdict: Verdict,
        hydrate_ms: u64,
    },
    /// No snapshot is an ancestor of the commit, so the build path has nothing warm.
    NoSnapshot {
        hydrate_ms: u64,
    },
    /// The worktree or its hydrate failed; that says nothing about the commit.
    Failed {
        why: String,
        hydrate_ms: u64,
    },
}

/// Checks `sha` against `base` in a worktree at the store's build path, hydrated from the
/// nearest snapshot. Snapshots are built at that path, so nothing they baked in differs and
/// only the delta compiles. The caller holds the build lock, which makes the path its own.
pub fn check_at_build(git_dir: &Path, store: &Store, sha: &str, base: &str, all: bool) -> AtBuild {
    let scratch = match Scratch::at(git_dir, &store.build_dir(), sha) {
        Ok(s) => s,
        Err(why) => return AtBuild::Failed { why, hydrate_ms: 0 },
    };
    let t = Instant::now();
    let hydrated = ws::hydrate(&scratch.path);
    let hydrate_ms = t.elapsed().as_millis() as u64;
    match hydrated {
        Ok(Hydrated::Done { .. }) => AtBuild::Checked {
            verdict: check::run(&scratch.path, base, all),
            hydrate_ms,
        },
        Ok(Hydrated::NoSnapshot) => AtBuild::NoSnapshot { hydrate_ms },
        Err(e) => AtBuild::Failed {
            why: format!("hydrate: {e}"),
            hydrate_ms,
        },
    }
}

/// A worktree at a fixed path, removed on drop however the work ended. Git is run against
/// the shared git dir, never a live worktree, which may be removed while this one exists.
pub struct Scratch {
    git_dir: PathBuf,
    pub path: PathBuf,
}

impl Scratch {
    /// Checks `rev` out at `path`, detached and with no hooks, after clearing whatever a
    /// killed run left there. The repo's post-checkout would hydrate (callers do that
    /// themselves, and need its result), and no other hook belongs in a throwaway tree.
    pub fn at(git_dir: &Path, path: &Path, rev: &str) -> Result<Scratch, String> {
        clear(git_dir, path);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("creating {}: {e}", parent.display()))?;
        }
        let mut c = git::cmd(git_dir);
        c.args([
            "-c",
            "core.hooksPath=/dev/null",
            "worktree",
            "add",
            "--detach",
            "--force",
        ])
        .arg(path)
        .arg(rev)
        .env("CHG_SKIP_HYDRATE", "1");
        if let Err(e) = git::run(c) {
            clear(git_dir, path);
            return Err(format!("worktree add: {e}"));
        }
        Ok(Scratch {
            git_dir: git_dir.to_path_buf(),
            path: fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf()),
        })
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        clear(&self.git_dir, &self.path);
    }
}

/// Unregisters and deletes the worktree at `path`, if any.
pub fn clear(git_dir: &Path, path: &Path) {
    let mut c = git::cmd(git_dir);
    c.args(["worktree", "remove", "--force"])
        .arg(path)
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let _ = c.status();
    let _ = fs::remove_dir_all(path);
    let mut c = git::cmd(git_dir);
    c.args(["worktree", "prune"])
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let _ = c.status();
}
