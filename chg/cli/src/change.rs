//! `chg submit`, `chg review` and `chg land`: the thin v0 of phase 2's change lifecycle
//! (design §5), for the loopctl US-47.8 pilot. Landing itself stays `gh pr merge`, behind
//! the harness's gates; these verbs only publish what happened, as change events loopctl
//! maps onto the story's stage:
//!
//! | verb | events, all with `sha` = the revision commit |
//! |---|---|
//! | `submit --story S` | `submitted {story_id, branch}` (binds the change to S), then a review key |
//! | `review --findings F` | `review_approved {by: "model"}` for `[]`, else `review_findings {findings, round, dispatch_key}` |
//! | `land` | `check_passed {checks, ms}` from the merged PR's required checks, then `landed {merge_sha, pr, base}` |
//!
//! A change is one branch. Its state lives in `<git common dir>/chg/changes/<branch>.json`,
//! so v0 continues a change only on the machine that submitted it. Every verb is
//! idempotent: an event already emitted for a revision is not emitted again.

use crate::{events, gh, git, outbox};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

const REMOTE_TIMEOUT: Duration = Duration::from_secs(60);
const GH_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Revision {
    pub n: u64,
    pub sha: String,
    /// `submitted` is on the chain.
    #[serde(default)]
    pub submitted: bool,
    /// `approved` or `findings`, once `chg review` emitted it.
    #[serde(default)]
    pub review: Option<String>,
    #[serde(default)]
    pub check_passed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Landed {
    pub merge_sha: String,
    pub pr: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Change {
    pub branch: String,
    pub change_id: String,
    #[serde(default)]
    pub story_id: Option<String>,
    #[serde(default)]
    pub revisions: Vec<Revision>,
    /// Review rounds recorded so far (each `chg review` is one).
    #[serde(default)]
    pub rounds: u64,
    #[serde(default)]
    pub landed: Option<Landed>,
}

impl Change {
    pub fn last(&self) -> Option<&Revision> {
        self.revisions.last()
    }
    fn last_mut(&mut self) -> Option<&mut Revision> {
        self.revisions.last_mut()
    }
}

/// What a verb tells its caller.
#[derive(Debug)]
pub enum Refusal {
    /// The request is wrong as asked (exit 1).
    Refused(String),
    /// Something failed (exit 2).
    Failed(String),
}

impl From<String> for Refusal {
    fn from(s: String) -> Self {
        Refusal::Failed(s)
    }
}

fn refused<T>(s: impl Into<String>) -> Result<T, Refusal> {
    Err(Refusal::Refused(s.into()))
}

fn file_key(branch: &str) -> String {
    branch
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '-'
            }
        })
        .collect()
}

fn state_dir(repo: &Path) -> Result<PathBuf, String> {
    Ok(git::common_dir(repo)?.join("chg").join("changes"))
}

pub fn state_path(repo: &Path, branch: &str) -> Result<PathBuf, String> {
    Ok(state_dir(repo)?.join(format!("{}.json", file_key(branch))))
}

pub fn load(repo: &Path, branch: &str) -> Result<Option<Change>, String> {
    let p = state_path(repo, branch)?;
    match fs::read_to_string(&p) {
        Ok(t) => {
            let c: Change =
                serde_json::from_str(&t).map_err(|e| format!("{}: {e}", p.display()))?;
            // Two branch names can share a file key; the file says whose it is.
            if c.branch != branch {
                return Err(format!(
                    "{} belongs to branch {:?}, not {branch:?}",
                    p.display(),
                    c.branch
                ));
            }
            Ok(Some(c))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("{}: {e}", p.display())),
    }
}

pub fn save(repo: &Path, c: &Change) -> Result<(), String> {
    let p = state_path(repo, &c.branch)?;
    let dir = p.parent().expect("has a parent");
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let tmp = p.with_extension(format!("json.{}.tmp", std::process::id()));
    let text = serde_json::to_string_pretty(c).expect("serializes");
    fs::write(&tmp, text).map_err(|e| format!("{}: {e}", tmp.display()))?;
    fs::rename(&tmp, &p).map_err(|e| format!("{}: {e}", p.display()))
}

/// A fresh change id: `<UTC yyyymmddHHMMSS>-<16 hex>`, valid as a ref component.
pub fn new_change_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let stamp: String = outbox::rfc3339(outbox::now_ms())
        .chars()
        .take(19)
        .filter(|c| c.is_ascii_digit())
        .collect();
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0),
    );
    h.write_u32(std::process::id());
    format!("{stamp}-{:016x}", h.finish())
}

fn current_branch(repo: &Path) -> Result<String, Refusal> {
    let b = git::text(repo, &["rev-parse", "--abbrev-ref", "HEAD"])?;
    if b == "HEAD" {
        return refused("HEAD is detached: submit from the change's branch");
    }
    Ok(b)
}

fn is_trunk(repo: &Path, branch: &str) -> bool {
    if matches!(branch, "master" | "main") {
        return true;
    }
    git::text(
        repo,
        &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
    )
    .map(|h| h.strip_prefix("origin/") == Some(branch))
    .unwrap_or(false)
}

/// Emits `kind` for `rev` unless the chain already has it. The local flag is written only
/// after the push, so a kill or a failed save in between leaves the flag false while the
/// event exists; the chain, not the flag, decides.
fn emit(
    repo: &Path,
    remote: &str,
    c: &Change,
    kind: &str,
    rev: &Revision,
    data: Value,
) -> Result<(), String> {
    if events::on_chain(repo, remote, &c.change_id, kind, rev.n)? {
        return Ok(());
    }
    events::emit(
        repo,
        remote,
        &events::NewEvent {
            change_id: &c.change_id,
            kind,
            revision: rev.n,
            sha: &rev.sha,
            data,
        },
    )
    .map(|_| ())
}

/// Pushes `sha` to `refs/chg/<change>/<n>`, never forced. A ref already at `sha` (a retry)
/// is success; one at another commit is refused.
fn push_revision(
    repo: &Path,
    remote: &str,
    change: &str,
    n: u64,
    sha: &str,
) -> Result<(), Refusal> {
    let r = format!("refs/chg/{change}/{n}");
    let mut c = git::cmd(repo);
    c.args([
        "-c",
        "core.hooksPath=/dev/null",
        "push",
        "--porcelain",
        remote,
        &format!("{sha}:{r}"),
    ]);
    let out = git::run_bounded_output(c, REMOTE_TIMEOUT)?;
    if out.status.success() {
        return Ok(());
    }
    let there = git::text(repo, &["ls-remote", remote, &r])?;
    match there.split_whitespace().next() {
        Some(s) if s == sha => Ok(()),
        Some(s) => refused(format!("{r} on {remote} is {s}, not {sha}")),
        None => Err(Refusal::Failed(format!(
            "pushing {r}: {}{}",
            String::from_utf8_lossy(&out.stdout).trim(),
            String::from_utf8_lossy(&out.stderr).trim()
        ))),
    }
}

#[derive(Debug, Serialize)]
pub struct Submitted {
    pub change_id: String,
    pub revision: u64,
    pub sha: String,
    pub story_id: Option<String>,
    /// Nothing new was pushed or emitted: this revision was already submitted.
    pub already: bool,
}

/// Submits HEAD as the branch's next revision.
pub fn submit(repo: &Path, remote: &str, story: Option<&str>) -> Result<Submitted, Refusal> {
    let branch = current_branch(repo)?;
    if is_trunk(repo, &branch) {
        return refused(format!("{branch} is trunk: submit from a change branch"));
    }
    let dirty = git::text(repo, &["status", "--porcelain", "--untracked-files=no"])?;
    if !dirty.is_empty() {
        return refused("the tree has uncommitted changes to tracked files: commit them first");
    }
    if story.is_some_and(|s| s.is_empty() || s.len() > 128) {
        return refused("--story must be a loopctl story id");
    }
    let sha = git::resolve(repo, "HEAD")?;
    let mut c = match load(repo, &branch)? {
        Some(c) => c,
        None => Change {
            branch: branch.clone(),
            change_id: new_change_id(),
            story_id: None,
            revisions: vec![],
            rounds: 0,
            landed: None,
        },
    };
    if c.landed.is_some() {
        return refused(format!(
            "change {} on {branch} has landed: start a new branch",
            c.change_id
        ));
    }
    let already = c.last().map(|r| r.sha == sha && r.submitted) == Some(true);
    match (&c.story_id, story) {
        (Some(have), Some(want)) if have != want => {
            return refused(format!(
                "change {} is bound to story {have}, not {want}",
                c.change_id
            ));
        }
        // The story binds through `submitted`, and this revision's has gone out without it.
        (None, Some(want)) if already => {
            return refused(format!(
                "revision {} was submitted without a story: --story {want} binds with the next revision",
                c.last().expect("already").n
            ));
        }
        (None, Some(want)) => c.story_id = Some(want.to_string()),
        _ => {}
    }
    if !already {
        // A pushed revision whose `submitted` never went out is announced before HEAD
        // becomes the next one, so no revision number is skipped on the chain.
        if let Some(prev) = c.last().filter(|r| !r.submitted && r.sha != sha).cloned() {
            let data = json!({ "story_id": c.story_id, "branch": c.branch });
            emit(repo, remote, &c, "submitted", &prev, data)?;
            c.last_mut().expect("has one").submitted = true;
            save(repo, &c)?;
        }
        if c.last().map(|r| r.sha != sha) != Some(false) {
            let n = c.last().map(|r| r.n + 1).unwrap_or(1);
            c.revisions.push(Revision {
                n,
                sha: sha.clone(),
                ..Revision::default()
            });
        }
        let rev = c.last().expect("pushed").clone();
        push_revision(repo, remote, &c.change_id, rev.n, &rev.sha)?;
        save(repo, &c)?;
        let data = json!({ "story_id": c.story_id, "branch": c.branch });
        emit(repo, remote, &c, "submitted", &rev, data)?;
        c.last_mut().expect("pushed").submitted = true;
        save(repo, &c)?;
    }
    let rev = c.last().expect("has one");
    Ok(Submitted {
        change_id: c.change_id.clone(),
        revision: rev.n,
        sha: rev.sha.clone(),
        story_id: c.story_id.clone(),
        already,
    })
}

/// Delivers the repo's pending events now, so loopctl has `submitted` before the review
/// key is asked for. Only `change`'s own problems count: another change's stale marker or
/// held event must not keep this one from its key.
pub fn deliver_now(cfg: &outbox::Config, slug: &str, change: &str) -> Result<(), String> {
    let src = cfg.source(slug).ok_or_else(|| {
        format!(
            "{slug} has no source in {}",
            outbox::config_path().display()
        )
    })?;
    let secret = outbox::read_secret(src)?;
    let d = events::deliver_pending(&cfg.url(), src, &secret)?;
    match own_problem(&d.problems, change) {
        Some(p) => Err(p.to_string()),
        None => Ok(()),
    }
}

/// The first of `deliver_pending`'s problems that is `change`'s (each starts `<change>: `).
pub fn own_problem<'a>(problems: &'a [String], change: &str) -> Option<&'a str> {
    let prefix = format!("{change}: ");
    problems
        .iter()
        .find(|p| p.starts_with(&prefix))
        .map(String::as_str)
}

/// Where the review key of `(change, n)` is kept, mode 0600.
pub fn review_key_path(repo: &Path, change: &str, n: u64) -> Result<PathBuf, String> {
    Ok(git::common_dir(repo)?
        .join("chg")
        .join("review")
        .join(format!("{change}-{n}.json")))
}

/// Writes loopctl's review-dispatch answer where only this user can read it.
pub fn keep_review_key(path: &Path, body: &str) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let dir = path.parent().expect("has a parent");
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    f.write_all(body.as_bytes())
        .map_err(|e| format!("{}: {e}", path.display()))
}

#[derive(Debug, Serialize)]
pub struct Reviewed {
    pub change_id: String,
    pub revision: u64,
    pub outcome: String,
    pub round: u64,
    pub already: bool,
}

/// Records the review of the last submitted revision: `findings` is the reviewer's JSON
/// array (lean-review's output). `[]` is `review_approved {by: "model"}`; anything else is
/// `review_findings`, which sends the story back to implementing.
pub fn review(repo: &Path, remote: &str, findings: &Value) -> Result<Reviewed, Refusal> {
    let Some(list) = findings.as_array() else {
        return refused("--findings must hold a JSON array");
    };
    let branch = current_branch(repo)?;
    let Some(mut c) = load(repo, &branch)? else {
        return refused(format!("{branch} has no submitted change: run chg submit"));
    };
    if c.landed.is_some() {
        return refused(format!("change {} has landed", c.change_id));
    }
    let rev = match c.last() {
        Some(r) if r.submitted => r.clone(),
        _ => return refused("the last revision was not submitted: run chg submit"),
    };
    let head = git::resolve(repo, "HEAD")?;
    if head != rev.sha {
        return refused(format!(
            "HEAD {head} is not revision {} ({}): chg submit it before recording its review",
            rev.n, rev.sha
        ));
    }
    if let Some(done) = &rev.review {
        return Ok(Reviewed {
            change_id: c.change_id.clone(),
            revision: rev.n,
            outcome: done.clone(),
            round: c.rounds,
            already: true,
        });
    }
    let round = c.rounds + 1;
    let outcome = if list.is_empty() {
        emit(
            repo,
            remote,
            &c,
            "review_approved",
            &rev,
            json!({ "by": "model" }),
        )?;
        "approved"
    } else {
        let key = review_key_path(repo, &c.change_id, rev.n)?;
        let dispatch_key = fs::read_to_string(&key)
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            .and_then(|v| v["dispatch_id"].as_str().map(str::to_string));
        let data = json!({ "findings": list, "round": round, "dispatch_key": dispatch_key });
        emit(repo, remote, &c, "review_findings", &rev, data)?;
        "findings"
    };
    c.rounds = round;
    c.last_mut().expect("has one").review = Some(outcome.to_string());
    save(repo, &c)?;
    Ok(Reviewed {
        change_id: c.change_id.clone(),
        revision: rev.n,
        outcome: outcome.to_string(),
        round,
        already: false,
    })
}

#[derive(Debug, Serialize)]
pub struct LandedOut {
    pub change_id: String,
    pub revision: u64,
    pub sha: String,
    pub merge_sha: String,
    pub pr: u64,
    pub already: bool,
}

/// The merged PR whose head is `sha`, from `gh pr list --json` output.
pub fn merged_pr_for(list: &Value, sha: &str) -> Option<(u64, String, String)> {
    list.as_array()?.iter().find_map(|p| {
        if p["headRefOid"].as_str() != Some(sha) {
            return None;
        }
        Some((
            p["number"].as_u64()?,
            p["mergeCommit"]["oid"].as_str()?.to_string(),
            p["baseRefName"].as_str()?.to_string(),
        ))
    })
}

/// `check_passed`'s data from `gh pr checks --required --json name,bucket,startedAt,completedAt`:
/// `None` unless every required check passed or was skipped, and at least one passed. A
/// skipped required check satisfies branch protection, so it does not hold the landing;
/// none at all, or only skipped ones, is not a pass.
pub fn checks_passed(checks: &Value) -> Option<Value> {
    let list = checks.as_array()?;
    let bucket = |c: &Value| c["bucket"].as_str().unwrap_or("").to_string();
    if list
        .iter()
        .any(|c| !matches!(bucket(c).as_str(), "pass" | "skipping"))
        || !list.iter().any(|c| bucket(c) == "pass")
    {
        return None;
    }
    let names: Vec<&str> = list.iter().filter_map(|c| c["name"].as_str()).collect();
    let ms = |k: &str| -> Vec<i64> {
        list.iter()
            .filter_map(|c| c[k].as_str())
            .filter_map(chrono_ms)
            .collect()
    };
    let (starts, ends) = (ms("startedAt"), ms("completedAt"));
    let span = match (starts.iter().min(), ends.iter().max()) {
        (Some(s), Some(e)) if e >= s => (e - s) as u64,
        _ => 0,
    };
    Some(json!({ "checks": names, "ms": span }))
}

/// Milliseconds since the epoch of an RFC 3339 UTC time (`2026-11-19T03:05:09Z`).
fn chrono_ms(t: &str) -> Option<i64> {
    let b = t.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[10] != b'T' {
        return None;
    }
    let n = |a: usize, z: usize| t.get(a..z)?.parse::<i64>().ok();
    let (y, mo, d) = (n(0, 4)?, n(5, 7)?, n(8, 10)?);
    let (h, mi, s) = (n(11, 13)?, n(14, 16)?, n(17, 19)?);
    // Days from the civil date (Howard Hinnant's algorithm).
    let y2 = if mo <= 2 { y - 1 } else { y };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(((days * 24 + h) * 60 + mi) * 60_000 + s * 1000)
}

/// Records that the branch's last revision landed: its PR merged with that revision as
/// head, the merge commit is on the base branch, and the required checks passed. Run it
/// after `gh pr merge`.
pub fn land(repo: &Path, remote: &str, branch: Option<&str>) -> Result<LandedOut, Refusal> {
    let branch = match branch {
        Some(b) => b.to_string(),
        None => current_branch(repo)?,
    };
    let Some(mut c) = load(repo, &branch)? else {
        return refused(format!("{branch} has no submitted change"));
    };
    let rev = match c.last() {
        Some(r) if r.submitted => r.clone(),
        _ => return refused("the last revision was not submitted: run chg submit"),
    };
    if let Some(l) = &c.landed {
        return Ok(LandedOut {
            change_id: c.change_id.clone(),
            revision: rev.n,
            sha: rev.sha.clone(),
            merge_sha: l.merge_sha.clone(),
            pr: l.pr,
            already: true,
        });
    }
    if rev.review.as_deref() != Some("approved") {
        return refused(format!(
            "revision {} has no clean review: record it with chg review --findings",
            rev.n
        ));
    }
    let slug =
        git::origin_slug(repo).ok_or_else(|| "the repo has no origin to name it".to_string())?;
    let list = gh_json(&[
        "pr",
        "list",
        "-R",
        &slug,
        "--head",
        &branch,
        "--state",
        "merged",
        "--json",
        "number,headRefOid,mergeCommit,baseRefName",
        "--limit",
        "20",
    ])?;
    let Some((pr, merge_sha, base)) = merged_pr_for(&list, &rev.sha) else {
        return refused(format!(
            "no merged PR of {branch} has revision {} ({}) as its head: merge it first, or chg submit the merged head",
            rev.n, rev.sha
        ));
    };
    let mut f = git::cmd(repo);
    f.args(["fetch", "-q", remote, &base]);
    git::run_bounded(f, REMOTE_TIMEOUT)?;
    if !git::is_ancestor(repo, &merge_sha, "FETCH_HEAD")? {
        return refused(format!("{merge_sha} is not on {remote}/{base} yet"));
    }
    if !rev.check_passed {
        // `gh pr checks` reports a state through its exit status (1 a failure, 8 pending,
        // an error when nothing is required) and may still print the JSON, so the
        // printed list decides and gh's own words are the refusal when there is none.
        let pr_s = pr.to_string();
        let args = [
            "pr",
            "checks",
            pr_s.as_str(),
            "-R",
            &slug,
            "--required",
            "--json",
            "name,bucket,startedAt,completedAt",
        ];
        let ran = gh::ran_within(&args, GH_TIMEOUT)?;
        let Ok(checks) = serde_json::from_str::<Value>(&ran.stdout) else {
            return refused(format!(
                "PR #{pr}'s required checks: gh exited {}: {}",
                ran.status, ran.stderr
            ));
        };
        let Some(data) = checks_passed(&checks) else {
            return refused(format!(
                "PR #{pr}'s required checks did not all pass (or none is required)"
            ));
        };
        emit(repo, remote, &c, "check_passed", &rev, data)?;
        c.last_mut().expect("has one").check_passed = true;
        save(repo, &c)?;
    }
    let data = json!({ "merge_sha": merge_sha, "pr": pr, "base": base });
    emit(repo, remote, &c, "landed", &rev, data)?;
    c.landed = Some(Landed {
        merge_sha: merge_sha.clone(),
        pr,
    });
    save(repo, &c)?;
    Ok(LandedOut {
        change_id: c.change_id.clone(),
        revision: rev.n,
        sha: rev.sha,
        merge_sha,
        pr,
        already: false,
    })
}

fn gh_json(args: &[&str]) -> Result<Value, String> {
    let t = gh::text_within(args, GH_TIMEOUT)?;
    serde_json::from_str(&t).map_err(|e| format!("gh {}: not JSON ({e})", args.join(" ")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn change_ids_are_valid_and_distinct() {
        let a = new_change_id();
        let b = new_change_id();
        assert!(events::valid_change_id(&a), "{a}");
        assert_ne!(a, b);
        assert_eq!(a.len(), 14 + 1 + 16, "{a}");
    }

    #[test]
    fn branch_file_keys_are_flat() {
        assert_eq!(file_key("feat/x y"), "feat-x-y");
    }

    #[test]
    fn the_merged_pr_is_the_one_with_the_revision_as_head() {
        let list = json!([
            {"number": 4, "headRefOid": "aa", "mergeCommit": {"oid": "m4"}, "baseRefName": "master"},
            {"number": 5, "headRefOid": "bb", "mergeCommit": {"oid": "m5"}, "baseRefName": "master"}
        ]);
        assert_eq!(
            merged_pr_for(&list, "bb"),
            Some((5, "m5".into(), "master".into()))
        );
        assert_eq!(merged_pr_for(&list, "cc"), None);
    }

    #[test]
    fn checks_pass_only_when_every_required_check_passed() {
        let ok = json!([
            {"name": "test", "bucket": "pass", "startedAt": "2026-11-19T03:00:00Z", "completedAt": "2026-11-19T03:04:00Z"},
            {"name": "lint", "bucket": "pass", "startedAt": "2026-11-19T03:01:00Z", "completedAt": "2026-11-19T03:02:30Z"}
        ]);
        assert_eq!(
            checks_passed(&ok),
            Some(json!({"checks": ["test", "lint"], "ms": 240_000}))
        );
        let red = json!([{"name": "test", "bucket": "fail"}, {"name": "lint", "bucket": "pass"}]);
        assert_eq!(checks_passed(&red), None);
        assert_eq!(
            checks_passed(&json!([])),
            None,
            "no required checks is not a pass"
        );
        let skipped =
            json!([{"name": "test", "bucket": "pass"}, {"name": "e2e", "bucket": "skipping"}]);
        assert_eq!(
            checks_passed(&skipped).map(|v| v["checks"].clone()),
            Some(json!(["test", "e2e"])),
            "a skipped required check does not hold the landing"
        );
        let only_skipped = json!([{"name": "e2e", "bucket": "skipping"}]);
        assert_eq!(checks_passed(&only_skipped), None);
        let pending = json!([{"name": "test", "bucket": "pending"}]);
        assert_eq!(checks_passed(&pending), None);
    }

    #[test]
    fn only_the_changes_own_delivery_problem_counts() {
        let p = vec![
            "OTHER: is gone".to_string(),
            "CH1-x: held 3".to_string(),
            "CH1: held 2".to_string(),
        ];
        assert_eq!(own_problem(&p, "CH1"), Some("CH1: held 2"));
        assert_eq!(own_problem(&p, "CH2"), None);
    }

    #[test]
    fn rfc3339_to_ms() {
        assert_eq!(chrono_ms("1970-01-01T00:00:01Z"), Some(1000));
        assert_eq!(chrono_ms("2026-11-19T03:05:09Z"), Some(1_795_057_509_000));
        assert_eq!(chrono_ms("nope"), None);
    }
}
