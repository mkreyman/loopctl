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
//! `refs/chg/cover/<sha>`, `fetch` mirrors those refs, and `fetch_nearest` fetches the one
//! a gate's selection needs. A record is unpacked into the
//! history only when it is used, so the history is a cache of `KEEP_LOCAL` files. A record
//! more than `MAX_AGE` first-parent commits behind the newest one on its line is deleted
//! from the remote when the newer one is published, unless another verified line of the
//! same family (`chg/verified/master` beside `chg/verified/epic/<name>`) still reaches it.
//! A line protects its reach for as long as its ref exists, merged or not.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

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
/// `line` is the verified ref `sha` was verified for (`chg verify --ref`): records that
/// another verified line of the same family still reaches are never pruned by this one.
pub fn publish(
    repo: &Path,
    remote: &str,
    sha: &str,
    record: &Path,
    line: &str,
) -> Result<(), String> {
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
    git::run_bounded(push, transfer_timeout())
        .map_err(|e| format!("publishing the coverage record: {e}"))?;

    // Pruning is housekeeping: the record is out, so a failure here (choosing the stale
    // records or deleting them) never makes the publish fail, and a later one retries it.
    if let Err(e) = prune(repo, remote, sha, line) {
        eprintln!("chg: pruning old coverage records: {e}");
    }
    Ok(())
}

/// Deletes the remote's records behind `sha` that no live verified line of `line`'s family
/// can still be judged from: each line (this one at `sha`, every other at its tip) protects
/// its own first-parent commits, `max_age()` deep. Ancestry says nothing about whether a
/// line is finished (an epic merges master in, master merges a still-used epic), so a line
/// protects its reach for as long as its ref exists.
fn prune(repo: &Path, remote: &str, sha: &str, line: &str) -> Result<(), String> {
    let mut reach = first_parent_line(repo, sha)?;
    for (tip, name) in other_lines(repo, remote, line)? {
        let here = git::text(
            repo,
            &[
                "rev-parse",
                "--verify",
                "--quiet",
                &format!("{tip}^{{commit}}"),
            ],
        );
        // A tip this clone lacks cannot be judged, so nothing is pruned this time.
        if here.is_err() {
            eprintln!(
                "chg: not pruning coverage records: {name} is at {tip}, which this clone lacks"
            );
            return Ok(());
        }
        reach.extend(first_parent_line(repo, &tip)?);
    }
    // Only this line's: a record that is not an ancestor of `sha` (another verified line,
    // or a commit this clone has never seen) belongs to a line whose own publishes prune it.
    let mut stale = Vec::new();
    for s in remote_records(repo, remote, fetch_timeout())? {
        if !reach.contains(&s) && git::is_ancestor_if_present(repo, &s, sha)? {
            stale.push(format!(":{REF_PREFIX}{s}"));
        }
    }
    if !stale.is_empty() {
        let mut del = git::cmd(repo);
        del.args(["-c", "core.hooksPath=/dev/null", "push", "-q", remote])
            .args(&stale);
        git::run_bounded(del, transfer_timeout())?;
    }
    Ok(())
}

/// The family a verified ref belongs to: everything up to and including `verified/`
/// (`chg/verified/master` and `chg/verified/epic/billing` are one family), or the ref's
/// directory when it has no `verified/`.
fn family(line: &str) -> &str {
    match line.find("verified/") {
        Some(i) => &line[..i + "verified/".len()],
        None => line.rfind('/').map_or("", |i| &line[..=i]),
    }
}

/// The tips of the remote's other verified lines of `line`'s family, with their names.
fn other_lines(repo: &Path, remote: &str, line: &str) -> Result<Vec<(String, String)>, String> {
    let family = family(line);
    if family.is_empty() {
        return Ok(Vec::new());
    }
    let mut ls = git::cmd(repo);
    ls.args([
        "ls-remote",
        "--heads",
        remote,
        &format!("refs/heads/{family}*"),
    ]);
    let listing =
        String::from_utf8_lossy(&git::run_bounded(ls, fetch_timeout())?.stdout).into_owned();
    Ok(listing
        .lines()
        .filter_map(|l| l.split_once('\t'))
        .filter_map(|(tip, r)| Some((tip.to_string(), r.strip_prefix("refs/heads/")?.to_string())))
        .filter(|(_, name)| name != line && name.starts_with(family))
        .collect())
}

fn remote_records(repo: &Path, remote: &str, timeout: Duration) -> Result<Vec<String>, String> {
    let mut ls = git::cmd(repo);
    ls.args(["ls-remote", "--refs", remote, &format!("{REF_PREFIX}*")]);
    Ok(record_shas(&String::from_utf8_lossy(
        &git::run_bounded(ls, timeout)?.stdout,
    )))
}

/// The shas of `ls-remote`'s record refs.
fn record_shas(listing: &str) -> Vec<String> {
    listing
        .lines()
        .filter_map(|l| l.split('\t').nth(1))
        .filter_map(|r| r.strip_prefix(REF_PREFIX))
        .map(String::from)
        .collect()
}

/// How long a listing of the remote's records, or the fetch of one record, may take
/// (`CHG_COVER_FETCH_SECS` overrides it).
pub const FETCH_SECS: u64 = 30;
/// How long a push or a mirror of every record may take (`CHG_COVER_TRANSFER_SECS`).
pub const TRANSFER_SECS: u64 = 600;

pub fn fetch_timeout() -> Duration {
    secs_from_env("CHG_COVER_FETCH_SECS", FETCH_SECS)
}

fn transfer_timeout() -> Duration {
    secs_from_env("CHG_COVER_TRANSFER_SECS", TRANSFER_SECS)
}

fn secs_from_env(var: &str, default: u64) -> Duration {
    Duration::from_secs(
        std::env::var(var)
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(default),
    )
}

/// Makes sure the record `nearest` would choose for `base` is in this clone. A gate runs
/// this before selecting: records are published by the verifier, on another machine, and
/// a clone that never fetched them selects without coverage. It lists the remote's
/// records and fetches only the nearest one on `base`'s first-parent line, when the clone
/// lacks it and has no nearer one (a record is megabytes; mirroring every one cost
/// HCB's first fetch 19 s). Each remote call is stopped after `timeout` (`git::run_bounded`
/// lets git remove its locks first). Returns the sha fetched, or None when nothing was
/// needed. On a failure selection uses the records already here, and with none, selects
/// without coverage.
pub fn fetch_nearest(
    repo: &Path,
    remote: &str,
    base: &str,
    timeout: Duration,
) -> Result<Option<String>, String> {
    let store = Store::for_repo(repo)?;
    let known = local_records(repo)?;
    let line = first_parent_line(repo, base)?;
    let here = |sha: &String| record_path(&store, sha).exists() || known.contains(sha);
    // The base's own record is here: none can be nearer, so the remote need not be asked.
    if line.first().is_some_and(here) {
        return Ok(None);
    }
    let published = remote_records(repo, remote, timeout)?;
    for sha in &line {
        if here(sha) {
            return Ok(None);
        }
        if published.contains(sha) {
            let mut f = git::cmd(repo);
            f.args(["fetch", "-q", "--no-tags", remote])
                .arg(format!("+{REF_PREFIX}{sha}:{REF_PREFIX}{sha}"));
            git::run_bounded(f, timeout)?;
            return Ok(Some(sha.clone()));
        }
    }
    Ok(None)
}

/// `base` and the first-parent commits behind it that a record may be judged from.
fn first_parent_line(repo: &Path, base: &str) -> Result<Vec<String>, String> {
    Ok(git::text(
        repo,
        &[
            "rev-list",
            "--first-parent",
            "-n",
            &(max_age() + 1).to_string(),
            base,
        ],
    )?
    .lines()
    .map(String::from)
    .collect())
}

/// Mirrors the remote's record refs. Returns how many are new here.
pub fn fetch(repo: &Path, remote: &str) -> Result<usize, String> {
    let before = local_records(repo)?;
    let mut f = git::cmd(repo);
    f.args(["fetch", "-q", "--no-tags", "--prune", remote])
        .arg(format!("+{REF_PREFIX}*:{REF_PREFIX}*"));
    git::run_bounded(f, transfer_timeout())?;
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
    let known = local_records(repo)?;
    for sha in first_parent_line(repo, base)? {
        if (record_path(&store, &sha).exists() || known.contains(&sha))
            && let Some(path) = materialize(repo, &store, &sha)?
        {
            return Ok(Some((sha, path)));
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
