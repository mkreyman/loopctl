//! Schema checks for the JSON document each adapter command emits (contract version 1).
//!
//! The document is the LAST non-empty line of the command's stdout. Earlier lines are
//! build noise (`mix` prints `Compiling …` on stdout); `exec` relays them to stderr.
//! Every schema rejects unknown fields: a typo in an adapter is an error, not a silent
//! default.

use serde::{Deserialize, Serialize};

use crate::contract::{CommandName, is_repo_relative};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "lowercase", deny_unknown_fields)]
pub enum Affected {
    /// Run only these test files (repo-relative). An empty list means nothing to run.
    /// `read` says the selection accounts for the paths `chg` named in `CHG_READ`.
    Subset {
        reason: String,
        tests: Vec<String>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        read: bool,
    },
    /// Run the whole suite.
    All { reason: String },
}

impl Affected {
    pub fn fail_closed(why: &str) -> Affected {
        Affected::All {
            reason: format!("failed closed: {why}"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Work {
    None,
    Incremental,
    Full,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub work: Work,
    pub ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StaticFailure {
    pub check: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u64>,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Static {
    pub ok: bool,
    pub failures: Vec<StaticFailure>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Pass,
    Fail,
    Skip,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TestResult {
    pub id: String,
    pub status: Status,
    pub ms: u64,
}

/// Output of both `run` and `shard`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Results {
    pub results: Vec<TestResult>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub junit: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Document {
    Snapshot(Snapshot),
    Static(Static),
    Affected(Affected),
    Results(Results),
}

impl Document {
    pub fn to_json(&self) -> String {
        match self {
            Document::Snapshot(d) => serde_json::to_string(d),
            Document::Static(d) => serde_json::to_string(d),
            Document::Affected(d) => serde_json::to_string(d),
            Document::Results(d) => serde_json::to_string(d),
        }
        .expect("documents always serialize")
    }
}

/// Parses and schema-checks one command's document.
pub fn check(name: CommandName, line: &str) -> Result<Document, String> {
    let line = line.trim();
    let doc = match name {
        CommandName::Snapshot => serde_json::from_str(line).map(Document::Snapshot),
        CommandName::Static => serde_json::from_str(line).map(Document::Static),
        CommandName::Affected => serde_json::from_str(line).map(Document::Affected),
        CommandName::Run | CommandName::Shard => serde_json::from_str(line).map(Document::Results),
    }
    .map_err(|e| format!("`{name}` output does not match the contract: {e}"))?;
    semantic(name, &doc)
        .map_err(|e| format!("`{name}` output does not match the contract: {e}"))?;
    Ok(doc)
}

/// Rules serde cannot express.
fn semantic(name: CommandName, doc: &Document) -> Result<(), String> {
    match doc {
        Document::Affected(Affected::Subset { tests, .. }) => {
            for t in tests {
                if t.is_empty() || !is_repo_relative(t) {
                    return Err(format!(
                        "test path \"{t}\" must be relative to the repo root with no `..`"
                    ));
                }
            }
            Ok(())
        }
        Document::Static(s) if s.ok && !s.failures.is_empty() => {
            Err("`ok` is true but `failures` is not empty".into())
        }
        Document::Static(s) if !s.ok && s.failures.is_empty() => {
            Err("`ok` is false but `failures` is empty".into())
        }
        Document::Results(r) => {
            // `run` got a file to test; zero results means nothing ran, which must not read
            // as green. A `shard` may be empty when the suite has fewer files than shards.
            if name == CommandName::Run && r.results.is_empty() {
                return Err("`results` is empty: the file ran no tests".into());
            }
            if r.results.iter().any(|t| t.id.is_empty()) {
                return Err("a result has an empty `id`".into());
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_subset_may_say_it_accounted_for_chg_read() {
        let d = check(
            CommandName::Affected,
            r#"{"mode":"subset","reason":"x","tests":[],"read":true}"#,
        )
        .unwrap();
        assert!(matches!(
            d,
            Document::Affected(Affected::Subset { read: true, .. })
        ));
        assert_eq!(
            d.to_json(),
            r#"{"mode":"subset","reason":"x","tests":[],"read":true}"#
        );
    }

    #[test]
    fn affected_subset_and_all() {
        let d = check(
            CommandName::Affected,
            r#"{"mode":"subset","reason":"stale","tests":["test/a_test.exs"]}"#,
        )
        .unwrap();
        assert_eq!(
            d,
            Document::Affected(Affected::Subset {
                read: false,
                reason: "stale".into(),
                tests: vec!["test/a_test.exs".into()]
            })
        );
        let d = check(
            CommandName::Affected,
            r#"{"mode":"all","reason":"mix.lock"}"#,
        )
        .unwrap();
        assert_eq!(d.to_json(), r#"{"mode":"all","reason":"mix.lock"}"#);
    }

    #[test]
    fn affected_rejects_malformed_documents() {
        for bad in [
            "not json",
            r#"{"mode":"some","reason":"x"}"#,
            r#"{"mode":"subset","reason":"x"}"#,
            r#"{"mode":"all"}"#,
            r#"{"mode":"all","reason":"x","extra":1}"#,
            r#"{"mode":"subset","reason":"x","tests":["../escape.exs"]}"#,
            r#"{"mode":"subset","reason":"x","tests":["/abs.exs"]}"#,
            r#"{"mode":"subset","reason":"x","tests":"test/a.exs"}"#,
        ] {
            assert!(check(CommandName::Affected, bad).is_err(), "accepted {bad}");
        }
    }

    #[test]
    fn snapshot_schema() {
        assert!(check(CommandName::Snapshot, r#"{"work":"none","ms":12}"#).is_ok());
        assert!(check(CommandName::Snapshot, r#"{"work":"some","ms":12}"#).is_err());
        assert!(check(CommandName::Snapshot, r#"{"work":"none","ms":-1}"#).is_err());
    }

    #[test]
    fn static_schema_requires_ok_to_agree_with_failures() {
        assert!(check(CommandName::Static, r#"{"ok":true,"failures":[]}"#).is_ok());
        let fail = r#"{"ok":false,"failures":[{"check":"credo","file":"lib/a.ex","line":3,"message":"x"}]}"#;
        assert!(check(CommandName::Static, fail).is_ok());
        assert!(check(CommandName::Static, r#"{"ok":false,"failures":[]}"#).is_err());
        let contradiction = r#"{"ok":true,"failures":[{"check":"fmt","message":"x"}]}"#;
        assert!(check(CommandName::Static, contradiction).is_err());
    }

    #[test]
    fn results_schema_for_run_and_shard() {
        let ok = r#"{"results":[{"id":"test/a_test.exs:12","status":"pass","ms":4}],"junit":"_build/junit.xml"}"#;
        assert!(check(CommandName::Run, ok).is_ok());
        assert!(check(CommandName::Shard, r#"{"results":[]}"#).is_ok());
        assert!(check(CommandName::Run, r#"{"results":[]}"#).is_err());
        assert!(
            check(
                CommandName::Run,
                r#"{"results":[{"id":"","status":"pass","ms":1}]}"#
            )
            .is_err()
        );
        assert!(
            check(
                CommandName::Run,
                r#"{"results":[{"id":"a","status":"flaky","ms":1}]}"#
            )
            .is_err()
        );
    }

    #[test]
    fn fail_closed_is_mode_all() {
        assert_eq!(
            Document::Affected(Affected::fail_closed("exit 2")).to_json(),
            r#"{"mode":"all","reason":"failed closed: exit 2"}"#
        );
    }
}
