//! Shelling out to `git` (design §5: git is the merge engine and object store; wrapping it
//! beats re-implementing it).

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

/// The variables git exports to a hook. Anything started from a hook that runs git in
/// another directory must drop them, or its git calls act on the hook's repository.
pub const HOOK_ENV: [&str; 6] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_COMMON_DIR",
    "GIT_PREFIX",
    "GIT_OBJECT_DIRECTORY",
];

/// A `git -C dir` command with the hook-time variables removed: inside a hook git exports
/// `GIT_DIR`/`GIT_INDEX_FILE`, which would silently redirect every call we make.
pub fn cmd(dir: &Path) -> Command {
    let mut c = Command::new("git");
    c.arg("-C").arg(dir);
    for v in HOOK_ENV {
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

/// Whether `ancestor` is an ancestor of (or equal to) `of`. git answers with its exit
/// status, 0 yes and 1 no; anything else is git failing (an unknown revision, a repo it
/// refuses to open), which is an error, never a "no".
pub fn is_ancestor(dir: &Path, ancestor: &str, of: &str) -> Result<bool, String> {
    let mut c = cmd(dir);
    c.args(["merge-base", "--is-ancestor", ancestor, of]);
    yes_or_no(c)
}

/// Whether this clone holds the commit `rev`. A record or snapshot of a commit it never
/// fetched is not an error, only not one of its ancestors. `rev-parse --verify --quiet`
/// exits 1, silently, for a name that is not a commit here; any other failure is git's
/// own (a repo it refuses to open) and an error.
pub fn has_commit(dir: &Path, rev: &str) -> Result<bool, String> {
    let mut c = cmd(dir);
    c.args([
        "rev-parse",
        "--verify",
        "--quiet",
        &format!("{rev}^{{commit}}"),
    ])
    .stdout(Stdio::null());
    yes_or_no(c)
}

/// `is_ancestor`, where an `ancestor` this clone never fetched (a record or snapshot of
/// another line) is a "no" and not an error. One git call in the usual case: only when
/// `merge-base` fails is the commit's presence asked about, and any other failure stays
/// an error.
pub fn is_ancestor_if_present(dir: &Path, ancestor: &str, of: &str) -> Result<bool, String> {
    match is_ancestor(dir, ancestor, of) {
        Err(_) if !has_commit(dir, ancestor)? => Ok(false),
        r => r,
    }
}

/// A git command that answers with its status: 0 yes, 1 no, anything else an error
/// carrying git's stderr, in `run`'s form.
fn yes_or_no(mut c: Command) -> Result<bool, String> {
    let shown = format!("{c:?}");
    let out = c.output().map_err(|e| format!("cannot run {shown}: {e}"))?;
    match out.status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => Err(format!(
            "{shown} failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )),
    }
}

/// Commits in `to` not in `from`.
pub fn distance(dir: &Path, from: &str, to: &str) -> Result<u64, String> {
    text(dir, &["rev-list", "--count", &format!("{from}..{to}")])?
        .parse()
        .map_err(|e| format!("rev-list --count: {e}"))
}

/// Paths that differ between `base` and the working tree, tracked or untracked, so an
/// uncommitted edit counts. Renames are split into the deleted and the added path. Paths
/// are relative to `dir` and limited to it, as the manifest's globs are, also when `dir`
/// is below the git toplevel: `diff --relative`, and `ls-files` is relative already.
pub fn changed_paths(dir: &Path, base: &str) -> Result<Vec<String>, String> {
    let base = resolve(dir, base)?;
    let mut paths = Vec::new();
    for args in [
        &[
            "diff",
            "--relative",
            "--no-renames",
            "--name-only",
            "-z",
            base.as_str(),
        ][..],
        &["ls-files", "--others", "--exclude-standard", "-z"][..],
    ] {
        let mut c = cmd(dir);
        c.args(args);
        let out = run(c)?.stdout;
        paths.extend(
            out.split(|&b| b == 0)
                .filter(|p| !p.is_empty())
                .map(|p| String::from_utf8_lossy(p).into_owned()),
        );
    }
    Ok(paths)
}

/// `Ok` when the worktree at `dir` is exactly commit `sha`: HEAD is `sha`, and no
/// tracked file differs and no untracked, unignored file exists. A check run on anything
/// else would judge content the commit does not carry.
pub fn is_exactly(dir: &Path, sha: &str) -> Result<(), String> {
    let head = resolve(dir, "HEAD")?;
    if head != sha {
        return Err(format!("HEAD is {head}, not {sha}"));
    }
    let status = text(dir, &["status", "--porcelain", "--untracked-files=normal"])?;
    if status.is_empty() {
        return Ok(());
    }
    let shown: Vec<&str> = status.lines().take(10).collect();
    Err(format!(
        "the worktree differs from {sha}:\n  {}",
        shown.join("\n  ")
    ))
}

/// The base a branch is judged against when none is given: its merge-base with the
/// remote's default branch (`origin/HEAD`, else `origin/master`, else `origin/main`).
pub fn default_base(dir: &Path, rev: &str) -> Result<String, String> {
    let target = text(
        dir,
        &["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
    )
    .ok()
    .or_else(|| {
        ["refs/remotes/origin/master", "refs/remotes/origin/main"]
            .into_iter()
            .find(|r| resolve(dir, r).is_ok())
            .map(String::from)
    })
    .ok_or_else(|| {
        format!(
            "no origin/HEAD, origin/master or origin/main in {}; pass --base",
            dir.display()
        )
    })?;
    text(dir, &["merge-base", rev, &target])
}

/// `owner/name` of the `origin` remote, for any URL form git accepts
/// (`git@host:owner/name.git`, `https://host/owner/name`, an ssh host alias).
pub fn origin_slug(dir: &Path) -> Option<String> {
    let url = text(dir, &["remote", "get-url", "origin"]).ok()?;
    slug_of(&url)
}

pub fn slug_of(url: &str) -> Option<String> {
    let path = url.trim().trim_end_matches('/').trim_end_matches(".git");
    let mut parts = path.rsplit(['/', ':']);
    let name = parts.next().filter(|s| !s.is_empty())?;
    let owner = parts.next().filter(|s| !s.is_empty())?;
    Some(format!("{owner}/{name}"))
}

/// The name of the repo whose shared git dir is `common`: the main worktree's directory
/// for a `.git` dir, else the git dir's own name (a bare repo).
pub fn common_dir_name(common: &Path) -> String {
    let named = if common.file_name().is_some_and(|n| n == ".git") {
        common.parent().unwrap_or(common)
    } else {
        common
    };
    named
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "repo".into())
}

/// A short, filesystem-safe name for the repo `dir` belongs to: the origin's name, else
/// the main worktree's directory name. Every worktree of a repo gets the same one.
pub fn repo_key(dir: &Path) -> String {
    let raw = origin_slug(dir)
        .and_then(|s| s.rsplit('/').next().map(String::from))
        .or_else(|| common_dir(dir).ok().map(|c| common_dir_name(&c)))
        .unwrap_or_else(|| "repo".into());
    raw.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || "._-".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{has_commit, is_ancestor, is_ancestor_if_present, slug_of, text};
    use std::path::Path;
    use std::process::Command;

    fn repo() -> tempfile::TempDir {
        let t = tempfile::tempdir().unwrap();
        for args in [
            &["init", "-q"][..],
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "one",
            ][..],
        ] {
            let ok = Command::new("git")
                .arg("-C")
                .arg(t.path())
                .args(args)
                .status()
                .unwrap()
                .success();
            assert!(ok, "git {args:?}");
        }
        t
    }

    #[test]
    fn a_git_failure_is_an_error_never_a_no() {
        let t = repo();
        let dir: &Path = t.path();
        let head = text(dir, &["rev-parse", "HEAD"]).unwrap();
        assert_eq!(is_ancestor(dir, &head, &head), Ok(true));
        assert_eq!(has_commit(dir, &head), Ok(true));
        let unknown = "1".repeat(40);
        assert_eq!(has_commit(dir, &unknown), Ok(false));
        assert!(is_ancestor(dir, &unknown, &head).is_err());
        // A directory that is no repo at all: git's message, not an answer. (A repo git
        // refuses to open is `verify_cli`'s culprit case, which can set the environment.)
        let none = tempfile::tempdir().unwrap();
        assert!(is_ancestor(none.path(), &head, &head).is_err());
        // A commit this clone lacks is a "no" there; a failing git still is not.
        assert_eq!(is_ancestor_if_present(dir, &unknown, &head), Ok(false));
        assert_eq!(is_ancestor_if_present(dir, &head, &head), Ok(true));
        assert!(is_ancestor_if_present(none.path(), &head, &head).is_err());
        assert!(has_commit(none.path(), &head).is_err());
    }

    #[test]
    fn slugs() {
        for url in [
            "git@github.com:mkreyman/home_care_billing.git",
            "git@github-centerfield:mkreyman/home_care_billing.git",
            "https://github.com/mkreyman/home_care_billing",
            "https://github.com/mkreyman/home_care_billing.git/",
            "ssh://git@github.com/mkreyman/home_care_billing.git",
        ] {
            assert_eq!(
                slug_of(url).as_deref(),
                Some("mkreyman/home_care_billing"),
                "{url}"
            );
        }
        assert_eq!(slug_of("repo"), None);
    }
}
