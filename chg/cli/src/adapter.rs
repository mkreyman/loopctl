//! Invoking one adapter command end to end: load the manifest, check arguments, run it,
//! and judge its document against its exit status.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

use crate::contract::{self, CommandName};
use crate::exec::{self, Outcome};
use crate::output::{self, Affected, Document, Status};
use crate::{cover, git, glob};

#[derive(Debug)]
pub enum Invoked {
    /// A valid document reporting success.
    Ok(Document),
    /// A valid document reporting failure, from an adapter that exited non-zero.
    Failed(Document),
    /// The adapter broke the contract; the string says how.
    Broken(String),
}

/// Runs `name` in `repo`. `slot` overrides the workspace slot derived from `repo`
/// (a snapshot build passes one stable slot per repo, not one per temp dir).
/// Every variable chg sets for an adapter command; `exec::run` removes inherited ones.
pub const ADAPTER_ENV: [&str; 6] = [
    "CHG_COVER",
    "CHG_NOT_READ_BY",
    "CHG_READ",
    "CHG_RECORD",
    "CHG_SHARD_BY",
    "CHG_SHA",
];

pub fn invoke(
    repo: &Path,
    name: CommandName,
    mut values: BTreeMap<&str, String>,
    slot: Option<String>,
    timeout: Duration,
) -> Invoked {
    let manifest = match contract::load(repo) {
        Ok(m) => m,
        Err(e) => return Invoked::Broken(format!("cannot use the adapter: {e}")),
    };
    for p in name.required_placeholders() {
        if !values.contains_key(p) {
            return Invoked::Broken(format!("needs --{p}"));
        }
    }
    if name == CommandName::Shard {
        // Shards are 1-based (`mix test --partitions`, `vitest --shard i/n`).
        let n: u32 = values["n"].parse().unwrap_or(0);
        let i: u32 = values["i"].parse().unwrap_or(0);
        if n == 0 || i == 0 || i > n {
            return Invoked::Broken(format!("needs 1 <= --i <= --n (got --i {i} --n {n})"));
        }
    }
    // `always_all` is applied here, once for every adapter kind: a hit selects the whole
    // suite without asking the adapter. An unusable base fails closed like any breakage.
    let mut changed = Vec::new();
    if name == CommandName::Affected {
        match git::changed_paths(repo, &values["base"]) {
            Err(e) => return Invoked::Broken(format!("cannot diff against the base: {e}")),
            Ok(paths) => {
                if let Some((path, pattern)) = glob::first_hit(&manifest.always_all, &paths) {
                    return Invoked::Ok(Document::Affected(Affected::All {
                        reason: format!("{path} matches always_all `{pattern}`"),
                    }));
                }
                changed = paths;
            }
        }
    }
    values.insert(
        "workspace_slot",
        slot.unwrap_or_else(|| exec::workspace_slot(repo)),
    );

    // Values chg hands the adapter as environment, not placeholders: the coverage files
    // (`cover.rs`), with `affected` getting the record to judge by, and `sha`, the commit a
    // snapshot build's tree holds, which has no `.git` to ask.
    // `CHG_READ` names the changed paths matching `read_at_runtime`, since the base and,
    // when a record is handed over, since the record: the adapter selects their readers by
    // the record, or the whole suite without one. `CHG_NOT_READ_BY` goes with it: the
    // commands whose subprocesses the adapter need not count as reading them.
    let mut env = Vec::new();
    let mut reads = false;
    if name == CommandName::Affected {
        match coverage_record(repo, &manifest.always_all, &values["base"]) {
            Ok((path, since)) => {
                env.push(("CHG_COVER".to_string(), path));
                changed.extend(since);
            }
            Err(why) => eprintln!("chg: not selecting by coverage: {why}"),
        }
        let mut read: Vec<&String> = changed
            .iter()
            .filter(|p| manifest.read_at_runtime.iter().any(|g| glob::matches(g, p)))
            .collect();
        read.sort();
        read.dedup();
        if let Some(p) = read.iter().find(|p| p.contains('\n')) {
            return Invoked::Ok(Document::Affected(Affected::fail_closed(&format!(
                "{p:?} matches read_at_runtime and cannot be named on a line"
            ))));
        }
        reads = !read.is_empty();
        if reads {
            let lines: Vec<&str> = read.iter().map(|p| p.as_str()).collect();
            env.push(("CHG_READ".to_string(), lines.join("\n")));
            if !manifest.not_read_by.is_empty() {
                env.push((
                    "CHG_NOT_READ_BY".to_string(),
                    manifest.not_read_by.join("\n"),
                ));
            }
        }
    }
    for (key, var) in [
        ("record", "CHG_RECORD"),
        ("shard_by", "CHG_SHARD_BY"),
        ("sha", "CHG_SHA"),
    ] {
        if let Some(v) = values.remove(key) {
            env.push((var.to_string(), v));
        }
    }

    let (code, document) = match exec::run(&manifest, repo, name, &values, &env, timeout) {
        Err(e) => return Invoked::Broken(e),
        Ok(Outcome::TimedOut { after }) => {
            return Invoked::Broken(format!("timed out after {}s", after.as_secs()));
        }
        Ok(Outcome::Exited { code, document }) => (code, document),
    };

    let doc = match document.map(|l| output::check(name, &l)) {
        None => return Invoked::Broken(format!("printed no JSON document (exit {code:?})")),
        Some(Err(e)) => return Invoked::Broken(e),
        Some(Ok(doc)) => doc,
    };

    let failed = match &doc {
        Document::Snapshot(_) | Document::Affected(_) => false,
        Document::Static(s) => !s.ok,
        Document::Results(r) => r
            .results
            .iter()
            .any(|t| matches!(t.status, Status::Fail | Status::Error)),
    };
    // The exit status and the document must agree: a crash that still printed a
    // success-shaped line is not trusted, nor is a failure report from a clean exit.
    let exit_failed = code != Some(0);
    if exit_failed != failed {
        let says = if failed { "failure" } else { "success" };
        return Invoked::Broken(format!("exited {code:?} but its document reports {says}"));
    }
    // A subset that does not say it accounted for `CHG_READ` (an adapter written before
    // `read_at_runtime`) could leave out every test that reads a changed path.
    if reads
        && matches!(
            doc,
            Document::Affected(Affected::Subset { read: false, .. })
        )
    {
        return Invoked::Ok(Document::Affected(Affected::fail_closed(
            "the adapter's subset does not account for the changed read_at_runtime paths (no \"read\":true)",
        )));
    }
    if failed {
        Invoked::Failed(doc)
    } else {
        Invoked::Ok(doc)
    }
}

/// The record `affected` may judge by, and the paths changed since it. Selection by
/// coverage compares with the record, not the base, so an `always_all` path changed since
/// the record rules it out: the adapter then selects from the base, where chg has already
/// applied `always_all`.
fn coverage_record(
    repo: &Path,
    always_all: &[String],
    base: &str,
) -> Result<(String, Vec<String>), String> {
    let (sha, path) = cover::nearest(repo, base)?.ok_or_else(|| {
        "no coverage record on the base's first-parent line within reach".to_string()
    })?;
    let since = git::changed_paths(repo, &sha)?;
    if let Some((p, pattern)) = glob::first_hit(always_all, &since) {
        return Err(format!(
            "{p} changed since the record of {} and matches always_all `{pattern}`",
            &sha[..12]
        ));
    }
    Ok((path.to_string_lossy().into_owned(), since))
}
