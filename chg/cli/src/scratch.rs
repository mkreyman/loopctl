//! Throwaway worktrees for checks that must not touch a live tree: the shadow check,
//! culprit finding and the revert builder. Each caller owns one fixed path per repo
//! under a lock, so its workspace slot (and test database) is the same on every run.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use crate::git;

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
