//! Shelling out to `git` (design §5: git is the merge engine and object store; wrapping it
//! beats re-implementing it).

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

/// A `git -C dir` command with the hook-time variables removed: inside a hook git exports
/// `GIT_DIR`/`GIT_INDEX_FILE`, which would silently redirect every call we make.
pub fn cmd(dir: &Path) -> Command {
    let mut c = Command::new("git");
    c.arg("-C").arg(dir);
    for v in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_COMMON_DIR",
        "GIT_PREFIX",
        "GIT_OBJECT_DIRECTORY",
    ] {
        c.env_remove(v);
    }
    c.stdin(Stdio::null());
    c
}

pub fn run(mut c: Command) -> Result<Output, String> {
    let shown = format!("{c:?}");
    let out = c.output().map_err(|e| format!("cannot run {shown}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{shown} failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(out)
}

/// Trimmed stdout of a git command that must succeed.
pub fn text(dir: &Path, args: &[&str]) -> Result<String, String> {
    let mut c = cmd(dir);
    c.args(args);
    Ok(String::from_utf8_lossy(&run(c)?.stdout).trim().to_string())
}

/// Full sha of a commit-ish.
pub fn resolve(dir: &Path, rev: &str) -> Result<String, String> {
    text(
        dir,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("{rev}^{{commit}}"),
        ],
    )
    .map_err(|_| format!("`{rev}` is not a commit in {}", dir.display()))
}

/// The root of the worktree `dir` is in.
pub fn toplevel(dir: &Path) -> Result<PathBuf, String> {
    text(dir, &["rev-parse", "--show-toplevel"]).map(PathBuf::from)
}

/// This worktree's own git dir (`.git`, or `.git/worktrees/<name>` for a linked one).
pub fn git_dir(dir: &Path) -> Result<PathBuf, String> {
    text(dir, &["rev-parse", "--absolute-git-dir"]).map(PathBuf::from)
}

/// The shared `.git` of a repo and all its worktrees.
pub fn common_dir(dir: &Path) -> Result<PathBuf, String> {
    text(
        dir,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )
    .map(PathBuf::from)
}

pub fn is_ancestor(dir: &Path, ancestor: &str, of: &str) -> bool {
    cmd(dir)
        .args(["merge-base", "--is-ancestor", ancestor, of])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Commits in `to` not in `from`.
pub fn distance(dir: &Path, from: &str, to: &str) -> Result<u64, String> {
    text(dir, &["rev-list", "--count", &format!("{from}..{to}")])?
        .parse()
        .map_err(|e| format!("rev-list --count: {e}"))
}
