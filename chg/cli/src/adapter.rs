//! Invoking one adapter command end to end: load the manifest, check arguments, run it,
//! and judge its document against its exit status.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

use crate::contract::{self, CommandName};
use crate::exec::{self, Outcome};
use crate::output::{self, Document, Status};

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
    values.insert(
        "workspace_slot",
        slot.unwrap_or_else(|| exec::workspace_slot(repo)),
    );

    let (code, document) = match exec::run(&manifest, repo, name, &values, timeout) {
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
    if failed {
        Invoked::Failed(doc)
    } else {
        Invoked::Ok(doc)
    }
}
