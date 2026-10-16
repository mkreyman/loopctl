use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use clap::{Parser, Subcommand};

use chg::contract::{self, CommandName};
use chg::exec::{self, Outcome};
use chg::output::{self, Affected, Document, Status};

#[derive(Parser)]
#[command(name = "chg", version = chg::VERSION, about = "Agent-first change system client")]
struct Cli {
    #[command(subcommand)]
    command: Top,
}

#[derive(Subcommand)]
enum Top {
    /// Work with the repo's adapter (`.chg/adapter.toml`).
    Adapter {
        #[command(subcommand)]
        command: AdapterCmd,
    },
}

#[derive(Subcommand)]
enum AdapterCmd {
    /// Check `.chg/adapter.toml`: unknown keys, missing commands, empty `always_all`,
    /// placeholders and the contract version. Exit 0 valid, 1 invalid.
    Validate {
        #[arg(long)]
        repo: Option<PathBuf>,
    },
    /// Run one adapter command and print its schema-checked JSON document.
    /// Exit 0 success, 1 the document reports failure, 2 the adapter broke the contract.
    /// `affected` never exits 2: a broken adapter fails closed to `{"mode":"all"}`.
    Exec {
        /// snapshot | static | affected | run | shard
        command: String,
        #[arg(long)]
        repo: Option<PathBuf>,
        #[arg(long)]
        base: Option<String>,
        #[arg(long)]
        file: Option<String>,
        #[arg(long)]
        n: Option<u32>,
        #[arg(long)]
        i: Option<u32>,
        /// Overrides the per-command wall-clock cap.
        #[arg(long)]
        timeout_secs: Option<u64>,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.command {
        Top::Adapter { command } => match command {
            AdapterCmd::Validate { repo } => validate(&repo_root(repo)),
            AdapterCmd::Exec {
                command,
                repo,
                base,
                file,
                n,
                i,
                timeout_secs,
            } => {
                let Some(name) = CommandName::parse(&command) else {
                    eprintln!(
                        "chg: unknown adapter command `{command}`; expected one of snapshot, static, affected, run, shard"
                    );
                    return ExitCode::from(2);
                };
                let mut values: BTreeMap<&str, String> = BTreeMap::new();
                for (k, v) in [
                    ("base", base),
                    ("file", file),
                    ("n", n.map(|x| x.to_string())),
                    ("i", i.map(|x| x.to_string())),
                ] {
                    if let Some(v) = v {
                        values.insert(k, v);
                    }
                }
                let timeout = timeout_secs
                    .map(Duration::from_secs)
                    .unwrap_or_else(|| exec::default_timeout(name));
                exec_cmd(&repo_root(repo), name, values, timeout)
            }
        },
    }
}

/// `--repo`, else the git toplevel of the cwd, else the cwd; always canonical, because
/// the workspace slot is derived from this path and `.`, `/w/a/` and a symlink must not
/// give one tree several slots or several trees one slot.
fn repo_root(arg: Option<PathBuf>) -> PathBuf {
    let raw = arg.unwrap_or_else(|| {
        std::process::Command::new("git")
            .args(["rev-parse", "--show-toplevel"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()))
            .unwrap_or_else(|| PathBuf::from("."))
    });
    // A path that does not exist stays as given; loading the manifest then reports it.
    std::fs::canonicalize(&raw).unwrap_or(raw)
}

fn validate(repo: &Path) -> ExitCode {
    match contract::load(repo) {
        Ok(m) => {
            println!(
                "ok: {} adapter, contract {}, {} always_all path(s)",
                m.kind.as_str(),
                m.version,
                m.always_all.len()
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprint!("chg: {e}");
            if !e.to_string().ends_with('\n') {
                eprintln!();
            }
            ExitCode::from(1)
        }
    }
}

fn exec_cmd(
    repo: &Path,
    name: CommandName,
    mut values: BTreeMap<&str, String>,
    timeout: Duration,
) -> ExitCode {
    // Any failure on the way to a valid document. `affected` turns it into "run all".
    let broken = |why: String| -> ExitCode {
        if name == CommandName::Affected {
            eprintln!("chg: affected {why}; failing closed to the full suite");
            println!(
                "{}",
                Document::Affected(Affected::fail_closed(&why)).to_json()
            );
            ExitCode::SUCCESS
        } else {
            eprintln!("chg: {name} {why}");
            ExitCode::from(2)
        }
    };

    let manifest = match contract::load(repo) {
        Ok(m) => m,
        Err(e) => return broken(format!("cannot use the adapter: {e}")),
    };
    for p in name.required_placeholders() {
        if !values.contains_key(p) {
            return broken(format!("needs --{p}"));
        }
    }
    if name == CommandName::Shard {
        // Shards are 1-based (`mix test --partitions`, `vitest --shard i/n`).
        let n: u32 = values["n"].parse().unwrap_or(0);
        let i: u32 = values["i"].parse().unwrap_or(0);
        if n == 0 || i == 0 || i > n {
            return broken(format!("needs 1 <= --i <= --n (got --i {i} --n {n})"));
        }
    }
    values.insert("workspace_slot", exec::workspace_slot(repo));

    let (code, document) = match exec::run(&manifest, repo, name, &values, timeout) {
        Err(e) => return broken(e),
        Ok(Outcome::TimedOut { after }) => {
            return broken(format!("timed out after {}s", after.as_secs()));
        }
        Ok(Outcome::Exited { code, document }) => (code, document),
    };

    let doc = match document.map(|l| output::check(name, &l)) {
        None => return broken(format!("printed no JSON document (exit {code:?})")),
        Some(Err(e)) => return broken(e),
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
        return broken(format!("exited {code:?} but its document reports {says}"));
    }
    println!("{}", doc.to_json());
    if failed {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}
