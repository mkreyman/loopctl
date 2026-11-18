//! Change events (loopctl US-47.3, US-50.2) and review dispatches (US-50.3).
//!
//! **The sequencer.** loopctl applies a change's events in `event_seq` order, from 1 with no
//! gaps, and never invents a seq; a change's events can originate on different machines. So
//! the seq is allocated where every machine already agrees on order: the change's event
//! chain, the git ref `refs/chg/<change_id>/events` on the remote. Each event is one commit
//! holding `event.json` (the exact body loopctl receives), whose parent is the previous
//! event. Emitting is: read the remote tip, write the next commit, push it without force.
//! A push is accepted only as a fast-forward, so it is a compare-and-swap: of two machines
//! racing for seq N one push is rejected, and the loser re-reads and takes N+1. An
//! allocated seq is therefore always a published event, never a hole a crash can leave.
//!
//! **Delivery.** Emitting leaves a marker in `~/.chg/outbox/events/<key>/`. The sender reads
//! the change's cursor from loopctl and posts every event above `applied_through`, read from
//! the chain, until loopctl has applied the tip. Any machine holding a clone can fill a gap
//! (`chg event sync`), because the events live on the remote, not in one machine's outbox.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::git;
use crate::outbox::{self, Config, Source};

/// Pushes lost to a racing machine before emit gives up.
const ATTEMPTS: u32 = 8;

/// The most a git call that reaches the remote may take (design §4: git push 60 s).
const REMOTE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

/// What a delivery run did for one repo.
#[derive(Debug, Default, Clone, Serialize)]
pub struct Delivered {
    pub posted: u64,
    pub completed: u64,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub problems: Vec<String>,
}

/// A change with events loopctl has not acknowledged.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Marker {
    pub change_id: String,
    /// The shared git dir of a clone that can read the chain.
    pub git_dir: PathBuf,
    pub remote: String,
    #[serde(default)]
    pub applied_through: u64,
    /// Changed by every `mark`, so the sender can tell that an emit marked the change again
    /// while it was delivering (the marker then stands for events it has not read).
    #[serde(default)]
    pub stamp: u64,
}

fn ref_name(change: &str) -> String {
    format!("refs/chg/{change}/events")
}

/// A change id is a ref component and a file name: `[A-Za-z0-9._-]`, 1-128 bytes, not
/// starting with `.` and not ending in `.lock`.
pub fn valid_change_id(c: &str) -> bool {
    !c.is_empty()
        && c.len() <= 128
        && !c.starts_with('.')
        && !c.ends_with(".lock")
        && !c.contains("..")
        && c.chars()
            .all(|ch| ch.is_ascii_alphanumeric() || "._-".contains(ch))
}

fn valid_sha(s: &str) -> bool {
    (s.len() == 40 || s.len() == 64)
        && s.chars()
            .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
}

fn valid_kind(k: &str) -> bool {
    !k.is_empty() && k.len() <= 64 && k.chars().all(|c| c.is_ascii_lowercase() || c == '_')
}

fn marker_dir(src_key: &str) -> PathBuf {
    outbox::dir().join("events").join(src_key)
}

fn marker_path(src_key: &str, change: &str) -> PathBuf {
    marker_dir(src_key).join(format!("{change}.json"))
}

/// The changes of `src` with undelivered events.
pub fn pending(src: &Source) -> Vec<Marker> {
    let mut out: Vec<Marker> = fs::read_dir(marker_dir(&src.key()))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .filter_map(|p| fs::read_to_string(p).ok())
        .filter_map(|t| serde_json::from_str(&t).ok())
        .collect();
    out.sort_by(|a: &Marker, b| a.change_id.cmp(&b.change_id));
    out
}

/// Holds the exclusive lock over `src_key`'s markers while `f` runs. Every read-modify-write
/// of a marker (`mark`, the sender's settle) goes through it, so an emit cannot slip
/// between the sender's read of a marker and its removal.
fn with_markers<T>(src_key: &str, f: impl FnOnce() -> T) -> Result<T, String> {
    let d = marker_dir(src_key);
    fs::create_dir_all(&d).map_err(|e| format!("creating {}: {e}", d.display()))?;
    let path = outbox::dir().join("events").join(format!("{src_key}.lock"));
    let lock = fs::File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .map_err(|e| format!("opening {}: {e}", path.display()))?;
    use std::os::fd::AsRawFd;
    // SAFETY: flock on an fd we own; released when `lock` closes.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(format!(
            "locking {}: {}",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    let out = f();
    drop(lock);
    Ok(out)
}

fn read_marker(src_key: &str, change: &str) -> Option<Marker> {
    fs::read_to_string(marker_path(src_key, change))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
}

/// Writes `m` atomically. Callers hold `with_markers`; the tmp name is per process anyway.
fn write_marker(src_key: &str, m: &Marker) -> Result<(), String> {
    let p = marker_path(src_key, &m.change_id);
    let tmp = p.with_extension(format!("json.tmp.{}", std::process::id()));
    fs::write(&tmp, serde_json::to_string(m).expect("marker serializes"))
        .and_then(|_| fs::rename(&tmp, &p))
        .map_err(|e| format!("writing {}: {e}", p.display()))
}

fn fresh_stamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos() as u64)
        ^ u64::from(std::process::id())
}

/// Records that `change`'s events in the clone at `git_dir` need delivering, keeping the
/// progress of a marker already there and giving it a new stamp.
pub fn mark(src_key: &str, change: &str, git_dir: &Path, remote: &str) -> Result<(), String> {
    with_markers(src_key, || {
        let applied_through = read_marker(src_key, change).map_or(0, |m| m.applied_through);
        write_marker(
            src_key,
            &Marker {
                change_id: change.to_string(),
                git_dir: git_dir.to_path_buf(),
                remote: remote.to_string(),
                applied_through,
                stamp: fresh_stamp(),
            },
        )
    })?
}

/// After delivering `m`: remove its marker when loopctl applied the whole chain and no
/// emit has marked the change since `m` was read; otherwise keep the marker as it now is,
/// recording the progress made.
fn settle(src_key: &str, m: &Marker, done: bool, applied: u64) -> Result<(), String> {
    with_markers(src_key, || {
        let Some(now) = read_marker(src_key, &m.change_id) else {
            return Ok(());
        };
        if now.stamp == m.stamp && done {
            return fs::remove_file(marker_path(src_key, &m.change_id))
                .map_err(|e| format!("removing the marker of {}: {e}", m.change_id));
        }
        if applied > now.applied_through {
            write_marker(
                src_key,
                &Marker {
                    applied_through: applied,
                    ..now
                },
            )?;
        }
        Ok(())
    })?
}

/// `git` in `dir` with `input` on stdin.
fn git_stdin(dir: &Path, args: &[&str], input: &[u8]) -> Result<String, String> {
    let mut c = git::cmd(dir);
    c.args(args)
        .env("GIT_AUTHOR_NAME", "chg")
        .env("GIT_AUTHOR_EMAIL", "chg@localhost")
        .env("GIT_COMMITTER_NAME", "chg")
        .env("GIT_COMMITTER_EMAIL", "chg@localhost")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let shown = format!("{c:?}");
    let mut child = c.spawn().map_err(|e| format!("cannot run {shown}: {e}"))?;
    let _ = child.stdin.take().expect("piped").write_all(input);
    let out = child
        .wait_with_output()
        .map_err(|e| format!("waiting for {shown}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{shown} failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Trimmed stdout of a git call that reaches the remote, stopped after `REMOTE_TIMEOUT`.
/// The sender holds its lock across these, so an unbounded one (a stalled network, an ssh
/// prompt nobody answers) would stop every repo's sends.
fn remote_text(dir: &Path, args: &[&str]) -> Result<String, String> {
    let mut c = git::cmd(dir);
    c.args(args);
    let out = git::run_bounded(c, REMOTE_TIMEOUT)?;
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// The remote's tip of the chain, or `None` when the change has no events yet.
fn remote_tip(dir: &Path, remote: &str, change: &str) -> Result<Option<String>, String> {
    let r = ref_name(change);
    let out = remote_text(dir, &["ls-remote", remote, &r])?;
    Ok(out.lines().find_map(|l| {
        l.split_once('\t')
            .filter(|(_, n)| *n == r)
            .map(|(s, _)| s.to_string())
    }))
}

/// Fetches the chain to its local ref and returns the tip, or `None`.
fn fetch_chain(dir: &Path, remote: &str, change: &str) -> Result<Option<String>, String> {
    let Some(tip) = remote_tip(dir, remote, change)? else {
        return Ok(None);
    };
    let r = ref_name(change);
    remote_text(
        dir,
        &[
            "fetch",
            "--quiet",
            "--no-tags",
            remote,
            &format!("+{r}:{r}"),
        ],
    )?;
    Ok(Some(tip))
}

/// The raw `event.json` of commit `rev`.
fn event_at(dir: &Path, rev: &str) -> Result<String, String> {
    let mut c = git::cmd(dir);
    c.args(["cat-file", "blob", &format!("{rev}:event.json")]);
    let out = git::run(c)?;
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn seq_of(event: &str) -> Result<u64, String> {
    serde_json::from_str::<Value>(event)
        .ok()
        .and_then(|v| v["event_seq"].as_u64())
        .ok_or_else(|| "an event in the chain has no event_seq".to_string())
}

/// What `emit` asks for.
pub struct NewEvent<'a> {
    pub change_id: &'a str,
    pub kind: &'a str,
    pub revision: u64,
    pub sha: &'a str,
    pub data: Value,
}

#[derive(Debug, Serialize)]
pub struct Emitted {
    pub change_id: String,
    pub event_seq: u64,
    pub commit: String,
    /// The repo's `owner/name`.
    pub repo: String,
}

/// Appends one event to the change's chain on `remote` (see the module doc) and marks the
/// change for delivery.
pub fn emit(repo: &Path, remote: &str, ev: &NewEvent) -> Result<Emitted, String> {
    if !valid_change_id(ev.change_id) {
        return Err(format!(
            "change id {:?}: use [A-Za-z0-9._-], 1-128 bytes",
            ev.change_id
        ));
    }
    if !valid_kind(ev.kind) {
        return Err(format!("event kind {:?}: use [a-z_], 1-64 bytes", ev.kind));
    }
    if ev.revision == 0 {
        return Err("revision starts at 1".into());
    }
    if !valid_sha(ev.sha) {
        return Err(format!(
            "sha {:?} is not a full lowercase commit id",
            ev.sha
        ));
    }
    if !ev.data.is_object() {
        return Err("data must be a JSON object".into());
    }
    let slug = git::origin_slug(repo).ok_or("the repo has no origin to name it")?;
    let git_dir = git::common_dir(repo)?;
    let git_dir = fs::canonicalize(&git_dir).unwrap_or(git_dir);
    let r = ref_name(ev.change_id);
    let mut last = String::new();
    for _ in 0..ATTEMPTS {
        let parent = fetch_chain(&git_dir, remote, ev.change_id)?;
        let seq = match &parent {
            Some(p) => seq_of(&event_at(&git_dir, p)?)? + 1,
            None => 1,
        };
        let body = json!({
            "v": 1,
            "repo": slug,
            "change_id": ev.change_id,
            "event_seq": seq,
            "kind": ev.kind,
            "revision": ev.revision,
            "sha": ev.sha,
            "occurred_at": outbox::rfc3339(outbox::now_ms()),
            "data": ev.data,
        })
        .to_string();
        let blob = git_stdin(&git_dir, &["hash-object", "-w", "--stdin"], body.as_bytes())?;
        let tree = git_stdin(
            &git_dir,
            &["mktree"],
            format!("100644 blob {blob}\tevent.json\n").as_bytes(),
        )?;
        let msg = format!("chg event {} #{seq} {}", ev.change_id, ev.kind);
        let mut args = vec!["commit-tree", tree.as_str(), "-m", msg.as_str()];
        if let Some(p) = &parent {
            args.extend(["-p", p.as_str()]);
        }
        let commit = git_stdin(&git_dir, &args, b"")?;
        // No force: the remote accepts only a fast-forward of the tip we read, so a
        // racing emit makes this push fail and we take the next seq. The pre-push hook is
        // skipped: this ref carries an event record, never code, and the repo's gate
        // would judge nothing but cost minutes.
        let mut c = git::cmd(&git_dir);
        c.args([
            "-c",
            "core.hooksPath=/dev/null",
            "push",
            "--porcelain",
            remote,
            &format!("{commit}:{r}"),
        ]);
        let out = git::run_bounded_output(c, REMOTE_TIMEOUT)?;
        if out.status.success() {
            // The event is published from here on: a failure below is local bookkeeping,
            // reported but never an emit failure, or a caller retrying on the error would
            // publish the same event again at the next seq. Without the marker, the
            // event reaches loopctl through `chg event sync` or the gap alert.
            if let Err(e) = git::text(&git_dir, &["update-ref", &r, &commit]) {
                eprintln!("chg event: emitted, but the local ref was not updated: {e}");
            }
            if let Err(e) = mark(
                &outbox::Source::key_of_repo(&slug),
                ev.change_id,
                &git_dir,
                remote,
            ) {
                eprintln!(
                    "chg event: emitted, but not queued for delivery ({e}); run `chg event sync --change {}`",
                    ev.change_id
                );
            }
            outbox::kick();
            return Ok(Emitted {
                change_id: ev.change_id.to_string(),
                event_seq: seq,
                commit,
                repo: slug,
            });
        }
        let said = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        if !(said.contains("[rejected]")
            || said.contains("non-fast-forward")
            || said.contains("fetch first"))
        {
            return Err(format!("pushing {r}: {}", said.trim()));
        }
        last = said.trim().to_string();
    }
    Err(format!(
        "pushing {r}: lost the race {ATTEMPTS} times; last answer: {last}"
    ))
}

/// The change's cursor: `(applied_through, held)`.
fn cursor(url: &str, src: &Source, secret: &[u8], change: &str) -> Result<(u64, Vec<u64>), String> {
    let path = format!("/api/v1/change_events/{}/cursor", src.source_id);
    let reply = outbox::get_signed(url, &path, &format!("change_id={change}"), secret)?;
    if reply.status != 200 {
        return Err(format!(
            "cursor of {change}: HTTP {} {}",
            reply.status,
            reply.code()
        ));
    }
    Ok(parse_cursor(&reply.json()))
}

fn parse_cursor(v: &Value) -> (u64, Vec<u64>) {
    (
        v["applied_through"].as_u64().unwrap_or(0),
        v["held"]
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_u64).collect())
            .unwrap_or_default(),
    )
}

/// Delivers every pending change of `src`. A problem with one change (its clone gone, a
/// conflicting event) is reported and skipped; an HTTP failure stops the repo, so the
/// caller backs off.
pub fn deliver_pending(url: &str, src: &Source, secret: &[u8]) -> Result<Delivered, String> {
    let mut d = Delivered::default();
    for m in pending(src) {
        match deliver(url, src, secret, &m) {
            Ok(Step::Done(posted, applied)) => {
                d.posted += posted;
                d.completed += 1;
                if let Err(e) = settle(&src.key(), &m, true, applied) {
                    d.problems.push(format!("{}: {e}", m.change_id));
                }
            }
            Ok(Step::Partial(posted, applied, why)) => {
                d.posted += posted;
                if let Err(e) = settle(&src.key(), &m, false, applied) {
                    d.problems.push(format!("{}: {e}", m.change_id));
                }
                if let Some(w) = why {
                    d.problems.push(format!("{}: {w}", m.change_id));
                }
            }
            Err(Halt::Skip(why)) => d.problems.push(format!("{}: {why}", m.change_id)),
            Err(Halt::Stop(why)) => return Err(why),
        }
    }
    Ok(d)
}

enum Step {
    /// Posted this many; loopctl has applied the whole chain, through this seq.
    Done(u64, u64),
    /// Posted this many, applied through this seq, and why it stopped short.
    Partial(u64, u64, Option<String>),
}

enum Halt {
    /// This change only.
    Skip(String),
    /// The whole repo (HTTP trouble).
    Stop(String),
}

fn deliver(url: &str, src: &Source, secret: &[u8], m: &Marker) -> Result<Step, Halt> {
    let dir = &m.git_dir;
    if !dir.is_dir() {
        return Err(Halt::Skip(format!(
            "{} is gone; run `chg event sync` from another clone",
            dir.display()
        )));
    }
    let tip = fetch_chain(dir, &m.remote, &m.change_id)
        .map_err(Halt::Skip)?
        .ok_or_else(|| Halt::Skip(format!("{} has no events on {}", m.change_id, m.remote)))?;
    let top = seq_of(&event_at(dir, &tip).map_err(Halt::Skip)?).map_err(Halt::Skip)?;
    let (mut applied, mut held) = cursor(url, src, secret, &m.change_id).map_err(Halt::Stop)?;
    let path = format!("/api/v1/change_events/{}", src.source_id);
    let mut posted = 0;
    while applied < top {
        let seq = applied + 1;
        let rev = format!("{tip}~{}", top - seq);
        let body = event_at(dir, &rev).map_err(Halt::Skip)?;
        let reply = outbox::post_signed(url, &path, secret, body.as_bytes()).map_err(Halt::Stop)?;
        match reply.status {
            200 => {
                posted += 1;
                let (a, h) = parse_cursor(&reply.json()["cursor"]);
                if a < seq {
                    // loopctl held it: an earlier seq is missing there although it answered
                    // applied_through below it. Resend from its cursor next run.
                    return Ok(Step::Partial(
                        posted,
                        a,
                        Some(format!("seq {seq} held at applied_through {a}")),
                    ));
                }
                applied = a;
                held = h;
            }
            409 => {
                return Ok(Step::Partial(
                    posted,
                    applied,
                    Some(format!("seq {seq}: 409 {}", reply.code())),
                ));
            }
            401 => return Err(Halt::Stop("401 invalid_signature on an event post".into())),
            s => return Err(Halt::Stop(format!("event post: HTTP {s} {}", reply.code()))),
        }
    }
    if held.iter().any(|&h| h > top) {
        // Another machine pushed past the tip we read; the next run reads the new tip.
        return Ok(Step::Partial(posted, applied, None));
    }
    Ok(Step::Done(posted, applied))
}

/// Marks `change` for delivery from the clone at `repo`, so this machine fills whatever
/// loopctl is missing of it.
pub fn sync(repo: &Path, remote: &str, change: &str) -> Result<String, String> {
    if !valid_change_id(change) {
        return Err(format!("change id {change:?} is not valid"));
    }
    let slug = git::origin_slug(repo).ok_or("the repo has no origin to name it")?;
    let git_dir = git::common_dir(repo)?;
    let git_dir = fs::canonicalize(&git_dir).unwrap_or(git_dir);
    mark(
        &outbox::Source::key_of_repo(&slug),
        change,
        &git_dir,
        remote,
    )?;
    outbox::kick();
    Ok(slug)
}

/// Asks loopctl for the review key of `(change, revision)` (US-50.3). The answer holds
/// `api_key`, shown once: the caller hands it to the review job and nowhere else.
pub fn review_dispatch(
    cfg: &Config,
    repo: &str,
    change: &str,
    revision: u64,
) -> Result<outbox::Reply, String> {
    if !valid_change_id(change) {
        return Err(format!("change id {change:?} is not valid"));
    }
    let src = cfg.source(repo).ok_or_else(|| {
        format!(
            "{repo} has no source in {}",
            outbox::config_path().display()
        )
    })?;
    let secret = outbox::read_secret(src)?;
    let body = json!({ "change_id": change, "revision": revision }).to_string();
    outbox::post_signed(
        &cfg.url(),
        &format!("/api/v1/change_events/{}/review_dispatch", src.source_id),
        &secret,
        body.as_bytes(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn change_ids_are_safe_ref_components() {
        assert!(valid_change_id("01JD3ZQ8X9K2M4N6P8R0T2V4W6"));
        assert!(valid_change_id("a.b-c_d"));
        for bad in ["", ".x", "x.lock", "a..b", "a/b", "a b", &"x".repeat(129)] {
            assert!(!valid_change_id(bad), "{bad}");
        }
    }

    #[test]
    fn cursor_parses_held() {
        let (a, h) = parse_cursor(&json!({"applied_through": 1, "held": [3, 4]}));
        assert_eq!((a, h), (1, vec![3, 4]));
        assert_eq!(parse_cursor(&Value::Null), (0, vec![]));
    }
}
