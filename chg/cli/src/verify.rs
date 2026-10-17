//! `chg verify` (story S8): the whole suite on a trunk commit, then `verified/<branch>`
//! moved to it on green, forward only.
//!
//! The ref is the trunk's last known-good commit: deploys and new worktrees start from
//! it. It moves only by a plain (never forced) push of a commit that descends from where
//! it is, so a slow verifier finishing after a newer one cannot move it back, and two
//! verifiers racing cannot both win.

use std::path::Path;

use serde::Serialize;

use crate::check::{self, Outcome, Verdict};
use crate::git;

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
}

pub struct Options<'a> {
    pub remote: &'a str,
    /// The branch under `refs/heads/`, e.g. `verified/master`.
    pub ref_name: &'a str,
    /// Advance only: the suite already passed on this commit elsewhere (a CI job).
    pub no_run: bool,
    pub push: bool,
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
    let report = |outcome, verdict| Report {
        sha: sha.clone(),
        ref_name: o.ref_name.to_string(),
        before: before.clone(),
        outcome,
        verdict,
    };
    if let Some(b) = &before {
        if *b == sha {
            return Ok(report(
                RefOutcome::Already,
                Verdict::skipped(format!("{} is already at {sha}", o.ref_name)),
            ));
        }
        fetch_ref(repo, o.remote, o.ref_name, b)?;
        if !git::is_ancestor(repo, b, &sha) {
            return Ok(report(
                RefOutcome::Superseded,
                Verdict::skipped(format!(
                    "{} is at {b}, which {sha} does not descend from: a newer commit is verified, or this is another line",
                    o.ref_name
                )),
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
        let v = check::run(repo, &base, true);
        match git::is_exactly(repo, &sha) {
            Ok(()) => v,
            Err(e) => Verdict {
                ms: v.ms,
                ..Verdict::error(format!("the tree moved while the suite ran: {e}"))
            },
        }
    };
    if verdict.verdict != Outcome::Pass {
        return Ok(report(RefOutcome::Held, verdict));
    }
    if !o.push {
        return Ok(report(RefOutcome::NotPushed, verdict));
    }

    // Never forced: the remote refuses a push that is not a fast-forward, so a commit
    // that is not ahead of the ref (another verifier moved it on meanwhile) cannot win.
    // No hooks: a product's pre-push gate has no business with a ref update.
    let mut c = git::cmd(repo);
    c.args(["-c", "core.hooksPath=/dev/null", "push", "-q", o.remote])
        .arg(format!("{sha}:refs/heads/{}", o.ref_name));
    match git::run(c) {
        Ok(_) => Ok(report(RefOutcome::Advanced, verdict)),
        Err(e) => {
            // Lost a race: another verifier moved the ref on while the suite ran.
            let now = remote_ref(repo, o.remote, o.ref_name)?;
            if now.is_some() && now != before {
                Ok(report(RefOutcome::Superseded, verdict))
            } else {
                Err(format!("pushing {}: {e}", o.ref_name))
            }
        }
    }
}
