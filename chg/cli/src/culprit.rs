//! `chg culprit <good> <bad>` (story S8): which trunk merge broke the tests that fail on
//! `bad`.
//!
//! The failing tests are rerun on `bad` first; one that passes on a rerun is flaky and
//! takes no part in the search. The rest are run, and only they, at commits on `bad`'s
//! first-parent line after `good`, by binary search: the culprit is the first commit at
//! which they fail. Every run is in a throwaway worktree at one fixed path per repo,
//! hydrated from a snapshot, so the live tree is never touched and the search has one
//! test database of its own.

use std::collections::BTreeSet;
use std::path::Path;
use std::time::Instant;

use serde::Serialize;

use crate::adapter::{self, Invoked};
use crate::check::Outcome;
use crate::contract::CommandName;
use crate::output::{Document, Status};
use crate::scratch::Scratch;
use crate::store::Store;
use crate::ws::{self, Hydrated};
use crate::{exec, git, snapshot};

#[derive(Debug, Clone, Serialize)]
pub struct Probe {
    pub sha: String,
    /// `pass` or `fail` for the tests asked about.
    pub verdict: Outcome,
    pub failing: Vec<String>,
    pub reason: String,
    pub ms: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Found {
    pub good: String,
    pub bad: String,
    /// The first commit at which `failing` fail; none when nothing fails for real.
    pub culprit: Option<String>,
    pub subject: Option<String>,
    /// The tests that failed on `bad` and on every rerun there.
    pub failing: Vec<String>,
    /// The tests that failed on `bad` and passed on a rerun.
    pub flaky: Vec<String>,
    pub reason: String,
    pub probes: Vec<Probe>,
}

pub struct Searcher<'a> {
    git_dir: &'a Path,
    store: Store,
    built: bool,
    pub probes: Vec<Probe>,
}

impl<'a> Searcher<'a> {
    fn scratch(&mut self, sha: &str, good: &str) -> Result<Scratch, String> {
        let s = Scratch::at(self.git_dir, &self.store.job_dir("culprit").join("ws"), sha)?;
        match ws::hydrate(&s.path)? {
            Hydrated::Done { .. } => Ok(s),
            // Unlike the shadow, nothing here competes with a gate: build the snapshot of
            // `good` once, and every candidate after it hydrates from it.
            Hydrated::NoSnapshot if !self.built => {
                // Built through this worktree: a snapshot checks out with a work tree.
                snapshot::build(&s.path, good)?;
                drop(s);
                self.built = true;
                self.scratch(sha, good)
            }
            Hydrated::NoSnapshot => Err(format!("no snapshot is an ancestor of {sha}")),
        }
    }

    /// Runs `ids` at `sha`. Tests whose file does not exist there pass: the commit that
    /// added them is where they start to fail. An Err is a run that says nothing about
    /// the commit (a worktree, hydrate or snapshot that failed, or an adapter that broke
    /// the contract, as a timeout does): the search stops rather than guess, because a
    /// guess here reverts somebody's merge.
    fn probe(&mut self, sha: &str, good: &str, ids: &[String]) -> Result<Probe, String> {
        let started = Instant::now();
        let mut p = self.run(sha, good, ids)?;
        p.ms = started.elapsed().as_millis() as u64;
        self.probes.push(p.clone());
        Ok(p)
    }

    fn run(&mut self, sha: &str, good: &str, ids: &[String]) -> Result<Probe, String> {
        let probe = |verdict, failing, reason: &str| Probe {
            sha: sha.to_string(),
            verdict,
            failing,
            reason: reason.to_string(),
            ms: 0,
        };
        let entries: BTreeSet<&str> = ids
            .iter()
            .map(|id| entry(id))
            .filter(|e| {
                let at = format!("{sha}:{}", file(e));
                git::text(self.git_dir, &["cat-file", "-e", &at]).is_ok()
            })
            .collect();
        if entries.is_empty() {
            return Ok(probe(Outcome::Pass, vec![], "none of the tests exist here"));
        }
        let scratch = self.scratch(sha, good)?;
        let list = tempfile::NamedTempFile::new()
            .and_then(|f| {
                let text: String = entries.iter().map(|e| format!("{e}\n")).collect();
                std::fs::write(f.path(), text).map(|_| f)
            })
            .map_err(|e| format!("the test list: {e}"))?;
        let invoked = adapter::invoke(
            &scratch.path,
            CommandName::Run,
            [("file", list.path().to_string_lossy().into_owned())]
                .into_iter()
                .collect(),
            None,
            exec::default_timeout(CommandName::Run),
        );
        match invoked {
            Invoked::Ok(_) => Ok(probe(Outcome::Pass, vec![], "")),
            Invoked::Failed(Document::Results(r)) => {
                let failed = failed_ids(&r.results);
                let ours: Vec<String> = ids
                    .iter()
                    .filter(|id| covers(&failed, id))
                    .cloned()
                    .collect();
                let verdict = if ours.is_empty() {
                    Outcome::Pass
                } else {
                    Outcome::Fail
                };
                Ok(probe(verdict, ours, ""))
            }
            Invoked::Failed(_) => unreachable!("run only returns results"),
            Invoked::Broken(why) => Err(format!("the tests could not run at {sha}: {why}")),
        }
    }
}

fn failed_ids(results: &[crate::output::TestResult]) -> Vec<String> {
    results
        .iter()
        .filter(|t| matches!(t.status, Status::Fail | Status::Error))
        .map(|t| t.id.clone())
        .collect()
}

/// The `run` list entry for a result id. The contract's ids start with the test's
/// repo-relative file, then `:<line>` or ` > <name>`; `run` takes `path` or `path:line`.
fn entry(id: &str) -> &str {
    id.split(" > ").next().unwrap_or(id)
}

/// The file a result id names.
fn file(id: &str) -> &str {
    let e = entry(id);
    match e.rsplit_once(':') {
        Some((f, line)) if !line.is_empty() && line.bytes().all(|b| b.is_ascii_digit()) => f,
        _ => e,
    }
}

/// Whether a run's failed ids cover test `id`: the same id, or its whole file failing (a
/// file that does not load reports only the file), or, for an id that is a whole file,
/// any test in it.
fn covers(failed: &[String], id: &str) -> bool {
    failed
        .iter()
        .any(|f| f == id || f == file(id) || (id == file(id) && file(f) == id))
}

/// Finds the commit after `good` on `bad`'s first-parent line that broke the tests
/// failing on `bad`. `tests` are those tests if known (the ids a CI run reported); else
/// the whole suite runs on `bad` to find them. `reruns` is how many times each failing
/// test is rerun on `bad` before it counts as a real failure.
pub fn find(
    repo: &Path,
    good: &str,
    bad: &str,
    tests: Option<Vec<String>>,
    reruns: u32,
) -> Result<Found, String> {
    // Revisions as the caller's worktree sees them (its HEAD); shared state by git dir.
    let good = git::resolve(repo, good)?;
    let bad = git::resolve(repo, bad)?;
    let git_dir = git::common_dir(repo)?;
    if !git::is_ancestor(&git_dir, &good, &bad) {
        return Err(format!("{good} is not an ancestor of {bad}"));
    }
    let candidates: Vec<String> = git::text(
        &git_dir,
        &[
            "rev-list",
            "--first-parent",
            "--reverse",
            &format!("{good}..{bad}"),
        ],
    )?
    .lines()
    .map(String::from)
    .collect();
    if candidates.is_empty() {
        return Err(format!("no commits between {good} and {bad}"));
    }
    let store = Store::for_repo(&git_dir)?;
    let _lock = store
        .lock_job("culprit")
        .map_err(|e| format!("culprit lock: {e}"))?;
    let mut s = Searcher {
        git_dir: &git_dir,
        store,
        built: false,
        probes: vec![],
    };
    let found = |s: Searcher, culprit: Option<String>, failing, flaky, reason: String| {
        let subject = culprit
            .as_deref()
            .and_then(|c| git::text(&git_dir, &["log", "-1", "--format=%s", c]).ok());
        Found {
            good: good.clone(),
            bad: bad.clone(),
            culprit,
            subject,
            failing,
            flaky,
            reason,
            probes: s.probes,
        }
    };

    let failing = match tests {
        Some(t) => t,
        None => {
            let scratch = s.scratch(&bad, &good)?;
            let started = Instant::now();
            let invoked = adapter::invoke(
                &scratch.path,
                CommandName::Shard,
                [("n", "1".to_string()), ("i", "1".to_string())]
                    .into_iter()
                    .collect(),
                None,
                exec::default_timeout(CommandName::Shard),
            );
            drop(scratch);
            let (verdict, failing, reason) = match invoked {
                Invoked::Ok(_) => (Outcome::Pass, vec![], "the whole suite".to_string()),
                Invoked::Failed(Document::Results(r)) => (
                    Outcome::Fail,
                    failed_ids(&r.results),
                    "the whole suite".into(),
                ),
                Invoked::Failed(_) => unreachable!("shard only returns results"),
                Invoked::Broken(why) => return Err(format!("the whole suite on {bad}: {why}")),
            };
            s.probes.push(Probe {
                sha: bad.clone(),
                verdict,
                failing: failing.clone(),
                reason,
                ms: started.elapsed().as_millis() as u64,
            });
            failing
        }
    };
    let failing: Vec<String> = failing
        .into_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if failing.is_empty() {
        return Ok(found(
            s,
            None,
            vec![],
            vec![],
            format!("nothing fails on {bad}"),
        ));
    }

    let mut real = failing.clone();
    for _ in 0..reruns {
        let p = s.probe(&bad, &good, &real)?;
        real.retain(|id| p.failing.contains(id));
        if real.is_empty() {
            break;
        }
    }
    let flaky: Vec<String> = failing
        .iter()
        .filter(|t| !real.contains(t))
        .cloned()
        .collect();
    if real.is_empty() {
        return Ok(found(
            s,
            None,
            vec![],
            flaky,
            format!("every failing test passed on a rerun on {bad}: flaky, nothing to revert"),
        ));
    }

    // The search assumes they pass at `good`. If they fail there too, no merge since
    // broke them (a date, an outside service): reverting one would be a guess.
    let at_good = s.probe(&good, &good, &real)?;
    if at_good.verdict == Outcome::Fail {
        let reason = format!(
            "{} test(s) fail at {good} as well: no merge after it broke them",
            at_good.failing.len()
        );
        return Ok(found(s, None, real, flaky, reason));
    }

    // Invariant: the tests pass at `good` (index -1) and fail at candidates[hi].
    let (mut lo, mut hi) = (-1i64, candidates.len() as i64 - 1);
    while hi - lo > 1 {
        let mid = lo + (hi - lo) / 2;
        match s.probe(&candidates[mid as usize], &good, &real)?.verdict {
            Outcome::Pass => lo = mid,
            _ => hi = mid,
        }
    }
    let culprit = candidates[hi as usize].clone();
    let reason = format!(
        "{} test(s) fail from {culprit} on, after {} probe(s) over {} commit(s)",
        real.len(),
        s.probes.len(),
        candidates.len()
    );
    Ok(found(s, Some(culprit), real, flaky, reason))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_of_every_adapter_map_to_run_entries_and_files() {
        assert_eq!(entry("test/a_test.exs:3"), "test/a_test.exs:3");
        assert_eq!(file("test/a_test.exs:3"), "test/a_test.exs");
        assert_eq!(entry("pkg/a.test.ts > adds > two"), "pkg/a.test.ts");
        assert_eq!(file("pkg/a.test.ts > adds > two"), "pkg/a.test.ts");
        assert_eq!(file("pkg/a.test.ts"), "pkg/a.test.ts");
        assert_eq!(file("C:odd"), "C:odd");
    }

    #[test]
    fn a_typescript_failure_covers_its_own_id_or_a_whole_file() {
        let f = vec![
            "pkg/a.test.ts > adds".to_string(),
            "pkg/b.test.ts".to_string(),
        ];
        assert!(covers(&f, "pkg/a.test.ts > adds"));
        assert!(!covers(&f, "pkg/a.test.ts > subtracts"));
        assert!(covers(&f, "pkg/a.test.ts"));
        assert!(covers(&f, "pkg/b.test.ts > anything"));
    }

    #[test]
    fn a_reported_failure_covers_its_file_or_line() {
        let f = vec![
            "test/a_test.exs:3".to_string(),
            "test/b_test.exs".to_string(),
        ];
        assert!(covers(&f, "test/a_test.exs:3"));
        assert!(covers(&f, "test/a_test.exs"));
        assert!(covers(&f, "test/b_test.exs:9"));
        assert!(!covers(&f, "test/c_test.exs:3"));
    }
}
