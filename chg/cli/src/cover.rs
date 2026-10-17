//! Coverage records (story S2b): what a verifier's full run learned about which tests
//! execute which code, and how long each test file takes, for coverage selection and
//! time-balanced shards.
//!
//! The format is the adapter's; chg only stores, moves and picks the files. The verifier's
//! run gets the file to write as `CHG_RECORD`, kept at `<store>/<repo>/history/<sha>.cover`.
//! `affected` gets the record to judge by as `CHG_COVER`, chosen by `nearest`.
//!
//! The verifier runs on one machine and a gate on another, so records travel through the
//! remote: `publish` pushes each as a parentless commit holding one file at
//! `refs/chg/cover/<sha>`, and `fetch` mirrors those refs. A record is unpacked into the
//! history only when it is used, so the history is a cache of `KEEP_LOCAL` files. A record
//! more than `MAX_AGE` first-parent commits behind the newest one on its line is deleted
//! from the remote when the newer one is published.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use crate::git;
use crate::store::Store;

pub const REF_PREFIX: &str = "refs/chg/cover/";
/// No record more first-parent commits behind the base than this is used, and publishing
/// deletes the ones further behind (`CHG_COVER_MAX_AGE` overrides it).
pub const MAX_AGE: usize = 100;
/// Unpacked records kept on this machine.
pub const KEEP_LOCAL: usize = 30;
const FILE: &str = "record.cover";

/// `CHG_COVER_MAX_AGE`, else `MAX_AGE`: how far back a gate looks for a record, and so how
/// far back a publish keeps them.
fn max_age() -> usize {
    std::env::var("CHG_COVER_MAX_AGE")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(MAX_AGE)
}

pub fn history_dir(store: &Store) -> PathBuf {
    store.dir.join("history")
}

pub fn record_path(store: &Store, sha: &str) -> PathBuf {
    history_dir(store).join(format!("{sha}.cover"))
}

/// Pushes the record of `sha` to `remote`, then deletes the remote's records that no gate
/// can use any more. Re-publishing a sha replaces its record.
pub fn publish(repo: &Path, remote: &str, sha: &str, record: &Path) -> Result<(), String> {
    let path = record
        .to_str()
        .ok_or_else(|| format!("{} is not UTF-8", record.display()))?;
    let blob = git::text(repo, &["hash-object", "-w", "--", path])?;

    // A tree of one file, built in a private index so the repo's own index is untouched.
    // git wants a missing index here, not an empty file.
    let tmp = tempfile::tempdir().map_err(|e| format!("temp index: {e}"))?;
    let index = tmp.path().join("index");
    let with_index = |args: &[&str]| -> Result<String, String> {
        let mut c = git::cmd(repo);
        c.env("GIT_INDEX_FILE", &index).args(args);
        Ok(String::from_utf8_lossy(&git::run(c)?.stdout)
            .trim()
            .to_string())
    };
    with_index(&[
        "update-index",
        "--add",
        "--cacheinfo",
        &format!("100644,{blob},{FILE}"),
    ])?;
    let tree = with_index(&["write-tree"])?;
    let commit = git::text(
        repo,
        &[
            "-c",
            "user.name=chg",
            "-c",
            "user.email=chg@localhost",
            "commit-tree",
            &tree,
            "-m",
            &format!("chg coverage record for {sha}"),
        ],
    )?;

    let mut push = git::cmd(repo);
    push.args(["-c", "core.hooksPath=/dev/null", "push", "-q", remote])
        .arg(format!("+{commit}:{REF_PREFIX}{sha}"));
    git::run(push).map_err(|e| format!("publishing the coverage record: {e}"))?;

    let reach: Vec<String> = git::text(
        repo,
        &[
            "rev-list",
            "--first-parent",
            "-n",
            &(max_age() + 1).to_string(),
            sha,
        ],
    )?
    .lines()
    .map(String::from)
    .collect();
    // Only this line's: a record that is not an ancestor of `sha` (another verified line,
    // or a commit this clone has never seen) belongs to a line whose own publishes prune it.
    let stale: Vec<String> = remote_records(repo, remote)?
        .into_iter()
        .filter(|s| !reach.contains(s) && git::is_ancestor(repo, s, sha))
        .map(|s| format!(":{REF_PREFIX}{s}"))
        .collect();
    if !stale.is_empty() {
        let mut del = git::cmd(repo);
        del.args(["-c", "core.hooksPath=/dev/null", "push", "-q", remote])
            .args(&stale);
        // Pruning is housekeeping: the record is out, and a later publish retries this.
        if let Err(e) = git::run(del) {
            eprintln!("chg: pruning old coverage records: {e}");
        }
    }
    Ok(())
}

fn remote_records(repo: &Path, remote: &str) -> Result<Vec<String>, String> {
    Ok(git::text(
        repo,
        &["ls-remote", "--refs", remote, &format!("{REF_PREFIX}*")],
    )?
    .lines()
    .filter_map(|l| l.split('\t').nth(1))
    .filter_map(|r| r.strip_prefix(REF_PREFIX))
    .map(String::from)
    .collect())
}

/// Mirrors the remote's record refs. Returns how many are new here.
pub fn fetch(repo: &Path, remote: &str) -> Result<usize, String> {
    let before = local_records(repo)?;
    git::text(
        repo,
        &[
            "fetch",
            "-q",
            "--no-tags",
            "--prune",
            remote,
            &format!("+{REF_PREFIX}*:{REF_PREFIX}*"),
        ],
    )?;
    Ok(local_records(repo)?
        .iter()
        .filter(|s| !before.contains(*s))
        .count())
}

fn local_records(repo: &Path) -> Result<Vec<String>, String> {
    Ok(
        git::text(repo, &["for-each-ref", "--format=%(refname)", REF_PREFIX])?
            .lines()
            .filter_map(|r| r.strip_prefix(REF_PREFIX))
            .filter(|s| is_sha(s))
            .map(String::from)
            .collect(),
    )
}

/// The record of `sha` as a file: the history's, or unpacked from a fetched ref.
pub fn materialize(repo: &Path, store: &Store, sha: &str) -> Result<Option<PathBuf>, String> {
    let dest = record_path(store, sha);
    if dest.exists() {
        return Ok(Some(dest));
    }
    let r = format!("{REF_PREFIX}{sha}");
    if git::text(repo, &["for-each-ref", "--format=%(refname)", &r])?.is_empty() {
        return Ok(None);
    }
    let mut c = git::cmd(repo);
    c.args(["cat-file", "blob", &format!("{r}:{FILE}")])
        .stdout(Stdio::piped());
    write_atomic(&dest, &git::run(c)?.stdout)?;
    prune_local(store);
    Ok(Some(dest))
}

/// The record to judge a change on `base` by: the nearest on `base`'s first-parent line,
/// at most `max_age()` commits behind it. Returns its sha and file, or None.
pub fn nearest(repo: &Path, base: &str) -> Result<Option<(String, PathBuf)>, String> {
    let store = Store::for_repo(repo)?;
    let max = max_age();
    let known = local_records(repo)?;
    let line = git::text(
        repo,
        &[
            "rev-list",
            "--first-parent",
            "-n",
            &(max + 1).to_string(),
            base,
        ],
    )?;
    for sha in line.lines() {
        if (record_path(&store, sha).exists() || known.iter().any(|k| k == sha))
            && let Some(path) = materialize(repo, &store, sha)?
        {
            return Ok(Some((sha.to_string(), path)));
        }
    }
    Ok(None)
}

fn is_sha(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

pub fn write_atomic(dest: &Path, bytes: &[u8]) -> Result<(), String> {
    let dir = dest.parent().expect("a record path has a parent");
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let tmp = tempfile::NamedTempFile::new_in(dir).map_err(|e| format!("{e}"))?;
    fs::write(tmp.path(), bytes).map_err(|e| format!("{e}"))?;
    tmp.persist(dest)
        .map(|_| ())
        .map_err(|e| format!("{}: {e}", dest.display()))
}

/// Keeps the newest `KEEP_LOCAL` records on this machine.
pub fn prune_local(store: &Store) {
    let Ok(entries) = fs::read_dir(history_dir(store)) else {
        return;
    };
    let mut records: Vec<(std::time::SystemTime, PathBuf)> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "cover"))
        .filter_map(|p| Some((fs::metadata(&p).ok()?.modified().ok()?, p)))
        .collect();
    records.sort_by_key(|r| std::cmp::Reverse(r.0));
    for (_, p) in records.into_iter().skip(KEEP_LOCAL) {
        let _ = fs::remove_file(p);
    }
}
