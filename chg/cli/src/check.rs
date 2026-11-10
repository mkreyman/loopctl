//! `chg check` (design §3.7): the static checks, then the affected tests of a tree against
//! its base, through the repo's adapter. The tree is a worktree of the commit at the
//! snapshot build path (`scratch::check_at_build`), or the live tree when that path
//! cannot be used.
//!
//! Static runs first and a failure stops there, as the gate it replaces does, unless the
//! caller skips it because static passed on the commit elsewhere (`chg verify
//! --no-static`). `affected` that breaks the contract fails closed to the whole suite
//! (`chg adapter exec`'s rule), and the whole suite runs as shard 1 of 1. A `run` or
//! `shard` that breaks the contract is an `error`, never a pass.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::adapter::{self, Invoked};
use crate::contract::CommandName;
use crate::exec;
use crate::output::{Affected, Document, Status};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Outcome {
    Pass,
    Fail,
    /// The adapter broke the contract or a command could not run: no verdict.
    Error,
    /// The check did not run (shadow only: no snapshot, or the machine was busy).
    Skipped,
}

impl Outcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Outcome::Pass => "pass",
            Outcome::Fail => "fail",
            Outcome::Error => "error",
            Outcome::Skipped => "skipped",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Verdict {
    pub verdict: Outcome,
    /// Why it failed, errored or was skipped; for a pass, the selection's reason.
    pub reason: String,
    /// `subset` or `all`; absent when static failed before selection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    /// The test files run, for a `subset`.
    #[serde(default)]
    pub selected: Vec<String>,
    /// What selection said: the subset's reason, or why the whole suite ran. A failure's
    /// `reason` replaces the selection's, so it is kept here. Absent when static failed
    /// before selection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<String>,
    /// Failing static checks (`check file:line message`) or failing test ids.
    #[serde(default)]
    pub failures: Vec<String>,
    pub ms: u64,
    #[serde(default)]
    pub static_ms: u64,
    #[serde(default)]
    pub affected_ms: u64,
    #[serde(default)]
    pub tests_ms: u64,
}

impl Verdict {
    pub fn skipped(reason: impl Into<String>) -> Verdict {
        Verdict {
            verdict: Outcome::Skipped,
            reason: reason.into(),
            mode: None,
            selected: vec![],
            selection: None,
            failures: vec![],
            ms: 0,
            static_ms: 0,
            affected_ms: 0,
            tests_ms: 0,
        }
    }

    pub fn error(reason: impl Into<String>) -> Verdict {
        Verdict {
            verdict: Outcome::Error,
            ..Verdict::skipped(reason)
        }
    }
}

/// Runs the check in `repo` against `base` (a commit). `all` skips selection.
pub fn run(repo: &Path, base: &str, all: bool) -> Verdict {
    run_recording(
        repo,
        base,
        all,
        None,
        exec::default_timeout(CommandName::Shard),
        Static::Run,
    )
}

/// Whether the check runs the adapter's `static` command first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Static {
    Run,
    /// Static ran on this commit elsewhere (a CI job): skip it, and say so in the reason.
    Skip,
}

const STATIC_SKIPPED: &str = "static skipped: it ran on this commit elsewhere (--no-static)";

/// `run`, and when the whole suite runs, the adapter also writes a coverage record of it
/// to `record` (`cover.rs`). `shard_cap` bounds the whole-suite run.
pub fn run_recording(
    repo: &Path,
    base: &str,
    all: bool,
    record: Option<&Path>,
    shard_cap: Duration,
    stat: Static,
) -> Verdict {
    let started = Instant::now();
    let mut v = check(repo, base, all, record, shard_cap, stat);
    if stat == Static::Skip {
        v.reason = format!("{}; {STATIC_SKIPPED}", v.reason);
    }
    v.ms = started.elapsed().as_millis() as u64;
    v
}

fn check(
    repo: &Path,
    base: &str,
    all: bool,
    record: Option<&Path>,
    shard_cap: Duration,
    stat: Static,
) -> Verdict {
    let values = |pairs: &[(&'static str, String)]| -> BTreeMap<&'static str, String> {
        pairs.iter().cloned().collect()
    };

    let static_ms = match stat {
        Static::Skip => 0,
        Static::Run => match run_static(repo, base) {
            Ok(ms) => ms,
            Err(v) => return *v,
        },
    };

    let t = Instant::now();
    let affected = if all {
        Affected::All {
            reason: "--all".into(),
        }
    } else {
        match adapter::invoke(
            repo,
            CommandName::Affected,
            values(&[("base", base.to_string())]),
            None,
            exec::default_timeout(CommandName::Affected),
        ) {
            Invoked::Ok(Document::Affected(a)) => a,
            Invoked::Broken(why) => Affected::fail_closed(&why),
            other => Affected::fail_closed(&format!("unexpected affected outcome {other:?}")),
        }
    };
    let affected_ms = t.elapsed().as_millis() as u64;

    let t = Instant::now();
    let (mode, reason, selected, invoked) = match affected {
        Affected::Subset { reason, tests, .. } if tests.is_empty() => {
            return Verdict {
                verdict: Outcome::Pass,
                reason: format!("no tests affected ({reason})"),
                mode: Some("subset".into()),
                selection: Some(reason),
                static_ms,
                affected_ms,
                ..Verdict::skipped("")
            };
        }
        Affected::Subset { reason, tests, .. } => {
            let list = match tempfile::NamedTempFile::new() {
                Ok(f) => f,
                Err(e) => return Verdict::error(format!("cannot write the test list: {e}")),
            };
            if let Err(e) = std::fs::write(list.path(), tests.join("\n") + "\n") {
                return Verdict::error(format!("cannot write the test list: {e}"));
            }
            let invoked = adapter::invoke(
                repo,
                CommandName::Run,
                values(&[("file", list.path().to_string_lossy().into_owned())]),
                None,
                exec::default_timeout(CommandName::Run),
            );
            ("subset", reason, tests, invoked)
        }
        Affected::All { reason } => {
            let mut v = values(&[("n", "1".into()), ("i", "1".into())]);
            if let Some(r) = record {
                v.insert("record", r.to_string_lossy().into_owned());
            }
            let invoked = adapter::invoke(repo, CommandName::Shard, v, None, shard_cap);
            ("all", reason, vec![], invoked)
        }
    };
    let tests_ms = t.elapsed().as_millis() as u64;

    let base_verdict = Verdict {
        mode: Some(mode.into()),
        selected,
        selection: Some(reason.clone()),
        static_ms,
        affected_ms,
        tests_ms,
        ..Verdict::skipped("")
    };
    match invoked {
        Invoked::Ok(_) => Verdict {
            verdict: Outcome::Pass,
            reason,
            ..base_verdict
        },
        Invoked::Failed(Document::Results(r)) => {
            let failures: Vec<String> = r
                .results
                .iter()
                .filter(|t| matches!(t.status, Status::Fail | Status::Error))
                .map(|t| t.id.clone())
                .collect();
            Verdict {
                verdict: Outcome::Fail,
                reason: format!("{} test(s) failed", failures.len()),
                failures,
                ..base_verdict
            }
        }
        Invoked::Failed(_) => unreachable!("run and shard only return results"),
        Invoked::Broken(why) => Verdict {
            verdict: Outcome::Error,
            reason: format!("{mode} tests: {why}"),
            ..base_verdict
        },
    }
}

/// Runs the adapter's `static` command: its duration, or the verdict that ends the check.
fn run_static(repo: &Path, base: &str) -> Result<u64, Box<Verdict>> {
    let t = Instant::now();
    let st = adapter::invoke(
        repo,
        CommandName::Static,
        BTreeMap::from([("base", base.to_string())]),
        None,
        exec::default_timeout(CommandName::Static),
    );
    let static_ms = t.elapsed().as_millis() as u64;
    match st {
        Invoked::Ok(_) => Ok(static_ms),
        Invoked::Failed(Document::Static(s)) => Err(Box::new(Verdict {
            verdict: Outcome::Fail,
            reason: format!("{} static check(s) failed", s.failures.len()),
            failures: s
                .failures
                .iter()
                .map(|f| {
                    let at = match (&f.file, f.line) {
                        (Some(file), Some(line)) => format!(" {file}:{line}"),
                        (Some(file), None) => format!(" {file}"),
                        _ => String::new(),
                    };
                    format!("{}{at} {}", f.check, f.message)
                })
                .collect(),
            static_ms,
            ..Verdict::skipped("")
        })),
        Invoked::Failed(_) => unreachable!("static only returns a static document"),
        Invoked::Broken(why) => Err(Box::new(Verdict {
            static_ms,
            ..Verdict::error(format!("static {why}"))
        })),
    }
}
