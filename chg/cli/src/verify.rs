//! `chg verify` (story S8): the whole suite on a trunk commit, then `verified/<branch>`
//! moved to it on green, forward only.
//!
//! The ref is the trunk's last known-good commit: deploys and new worktrees start from
//! it. It moves only by a plain (never forced) push of a commit that descends from where
//! it is, so a slow verifier finishing after a newer one cannot move it back, and two
//! verifiers racing cannot both win.
//!
//! A green run also writes a coverage record of the commit (story S2b, `cover.rs`), which
//! gates on other machines select tests by, and publishes it to the remote. A red run's
//! record is discarded: selection skips a test whose executed code is unchanged since the
//! record, which is sound only if the test passed there.

use std::path::Path;
use std::time::Duration;

use serde::Serialize;

use crate::check::{self, Outcome, Verdict};
use crate::cover;
use crate::git;
use crate::store::Store;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RefOutcome {
    /// The ref now points at the verified commit.
    Advanced,
    /// The ref was already there; nothing ran.
    Already,
    /// The ref is at a commit this one does not descend from (a newer verified tip, or
    /// another line): nothing ran, or the push lost a race to a newer verifier.
    Superseded,
    /// Green, but `--no-push`.
    NotPushed,
    /// Red or no verdict: the ref stays where it is.
    Held,
}

#[derive(Debug, Clone, Serialize)]
pub struct Report {
    pub sha: String,
    #[serde(rename = "ref")]
    pub ref_name: String,
    /// Where the ref was before.
    pub before: Option<String>,
    pub outcome: RefOutcome,
    pub verdict: Verdict,
    /// What became of this run's coverage record: `published`, `recorded` (`--no-push`),
    /// or why there is none. Absent when the suite did not run.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
}

pub struct Options<'a> {
    pub remote: &'a str,
    /// The branch under `refs/heads/`, e.g. `verified/master`.
    pub ref_name: &'a str,
    /// Advance only: the suite already passed on this commit elsewhere (a CI job).
    pub no_run: bool,
    /// Skip the static checks: they ran on this commit elsewhere (a CI job). The suite and
    /// its coverage record still run.
    pub no_static: bool,
    pub push: bool,
    /// Wall-clock cap of the whole-suite run (`--tests-timeout-secs`).
    pub tests_timeout: Duration,
}

/// The commit `refs/heads/<name>` points at on `remote`, if the ref exists.
pub fn remote_ref(dir: &Path, remote: &str, name: &str) -> Result<Option<String>, String> {
    let out = git::text(
        dir,
        &["ls-remote", "--refs", remote, &format!("refs/heads/{name}")],
    )?;
    Ok(out
        .lines()
        .find_map(|l| l.split_whitespace().next())
        .map(String::from))
}

/// Makes `sha` (the remote ref's commit) available locally, to test ancestry against.
fn fetch_ref(dir: &Path, remote: &str, name: &str, sha: &str) -> Result<(), String> {
    if git::resolve(dir, &format!("{sha}^{{commit}}")).is_ok() {
        return Ok(());
    }
    git::text(
        dir,
        &[
            "fetch",
            "-q",
            "--no-tags",
            remote,
            &format!("refs/heads/{name}"),
        ],
    )
    .map(|_| ())
}

pub fn run(repo: &Path, rev: &str, o: &Options) -> Result<Report, String> {
    let sha = git::resolve(repo, rev)?;
    let before = remote_ref(repo, o.remote, o.ref_name)?;
    let mut cover_note: Option<String> = None;
    let report = |outcome, verdict, cover: &Option<String>| Report {
        sha: sha.clone(),
        ref_name: o.ref_name.to_string(),
        before: before.clone(),
        outcome,
        verdict,
        cover: cover.clone(),
    };
    if let Some(b) = &before {
        if *b == sha {
            return Ok(report(
                RefOutcome::Already,
                Verdict::skipped(format!("{} is already at {sha}", o.ref_name)),
                &None,
            ));
        }
        fetch_ref(repo, o.remote, o.ref_name, b)?;
        if !git::is_ancestor(repo, b, &sha)? {
            return Ok(report(
                RefOutcome::Superseded,
                Verdict::skipped(format!(
                    "{} is at {b}, which {sha} does not descend from: a newer commit is verified, or this is another line",
                    o.ref_name
                )),
                &None,
            ));
        }
    }

    let verdict = if o.no_run {
        Verdict {
            verdict: Outcome::Pass,
            ..Verdict::skipped("--no-run: the suite passed on this commit elsewhere")
        }
    } else {
        // The suite runs in this tree, so it must be exactly the commit being verified.
        git::is_exactly(repo, &sha)?;
        let base = before
            .clone()
            .or_else(|| git::resolve(repo, &format!("{sha}^")).ok())
            .unwrap_or_else(|| sha.clone());
        let record = Store::for_repo(repo).and_then(|s| {
            let dir = cover::history_dir(&s);
            std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
            Ok(cover::record_path(&s, &sha))
        });
        let stat = if o.no_static {
            check::Static::Skip
        } else {
            check::Static::Run
        };
        let v = check::run_recording(
            repo,
            &base,
            true,
            record.as_deref().ok(),
            o.tests_timeout,
            stat,
        );
        let v = match git::is_exactly(repo, &sha) {
            Ok(()) => v,
            Err(e) => Verdict {
                ms: v.ms,
                ..Verdict::error(format!("the tree moved while the suite ran: {e}"))
            },
        };
        cover_note = Some(match (&record, v.verdict) {
            (Err(e), _) => format!("no record: {e}"),
            // A tree that moved mid-run recorded a mix of two commits.
            (Ok(r), Outcome::Error) => {
                let _ = std::fs::remove_file(r);
                "no record: the run gave no verdict".into()
            }
            // Coverage selection skips a test whose executed code is as the record has
            // it, which is sound only if that test passed there.
            (Ok(r), Outcome::Fail) => {
                let _ = std::fs::remove_file(r);
                "no record: the suite failed".into()
            }
            (Ok(r), _) if !r.exists() => {
                "no record: the adapter wrote none (see its stderr)".into()
            }
            (Ok(_), _) if !o.push => "recorded".into(),
            (Ok(r), _) => match cover::publish(repo, o.remote, &sha, r, o.ref_name) {
                Ok(()) => "published".into(),
                Err(e) => format!("recorded, not published: {e}"),
            },
        });
        v
    };
    if verdict.verdict != Outcome::Pass {
        return Ok(report(RefOutcome::Held, verdict, &cover_note));
    }
    if !o.push {
        return Ok(report(RefOutcome::NotPushed, verdict, &cover_note));
    }

    // Never forced: the remote refuses a push that is not a fast-forward, so a commit
    // that is not ahead of the ref (another verifier moved it on meanwhile) cannot win.
    // No hooks: a product's pre-push gate has no business with a ref update.
    let mut c = git::cmd(repo);
    c.args(["-c", "core.hooksPath=/dev/null", "push", "-q", o.remote])
        .arg(format!("{sha}:refs/heads/{}", o.ref_name));
    match git::run(c) {
        Ok(_) => Ok(report(RefOutcome::Advanced, verdict, &cover_note)),
        Err(e) => {
            // Lost a race: another verifier moved the ref on while the suite ran.
            let now = remote_ref(repo, o.remote, o.ref_name)?;
            if now.is_some() && now != before {
                Ok(report(RefOutcome::Superseded, verdict, &cover_note))
            } else {
                Err(format!("pushing {}: {e}", o.ref_name))
            }
        }
    }
}
