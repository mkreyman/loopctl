use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use clap::{Parser, Subcommand};

use chg::adapter::{self, Invoked};
use chg::contract::{self, CommandName};
use chg::exec;
use chg::git;
use chg::output::{Affected, Document};
use chg::snapshot::{self, Built};
use chg::store::Store;
use chg::ws::{self, Hydrated};

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
    /// The per-machine snapshot store.
    Snapshot {
        #[command(subcommand)]
        command: SnapshotCmd,
    },
    /// Workspaces.
    Ws {
        #[command(subcommand)]
        command: WsCmd,
    },
    /// Entry points for git hooks.
    Hook {
        #[command(subcommand)]
        command: HookCmd,
    },
}

#[derive(Subcommand)]
enum SnapshotCmd {
    /// Build the snapshot of <sha>, cloned from the nearest existing one, then GC.
    /// Exit 0 built or already present, 1 failed (nothing is left half-built).
    Build { repo: PathBuf, sha: String },
    /// List this repo's snapshots, newest first, as JSON lines.
    List {
        #[arg(long)]
        repo: Option<PathBuf>,
    },
    /// Keep the newest 3 and any with a live lease; remove the rest.
    Gc {
        #[arg(long)]
        repo: Option<PathBuf>,
    },
}

#[derive(Subcommand)]
enum WsCmd {
    /// Clone the artifact paths from the nearest-ancestor snapshot into this worktree.
    /// Exit 0 hydrated, 1 failed (worktree unchanged), 3 no snapshot (worktree unchanged).
    Hydrate {
        #[arg(long)]
        repo: Option<PathBuf>,
    },
}

#[derive(Subcommand)]
enum HookCmd {
    /// `post-checkout <prev> <new> <flag>`: hydrates a worktree that `git worktree add`
    /// just created (prev = all zeros, branch checkout). Never fails the checkout.
    PostCheckout {
        prev: String,
        new: String,
        flag: String,
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
        Top::Snapshot { command } => match command {
            SnapshotCmd::Build { repo, sha } => {
                with_worktree(Some(repo), |r| snapshot_build(r, &sha))
            }
            SnapshotCmd::List { repo } => with_worktree(repo, snapshot_list),
            SnapshotCmd::Gc { repo } => with_worktree(repo, snapshot_gc),
        },
        Top::Ws { command } => match command {
            WsCmd::Hydrate { repo } => with_worktree(repo, hydrate),
        },
        Top::Hook { command } => match command {
            HookCmd::PostCheckout { prev, new: _, flag } => {
                let created = flag == "1" && !prev.is_empty() && prev.bytes().all(|b| b == b'0');
                if created && std::env::var_os("CHG_SKIP_HYDRATE").is_none() {
                    let code = with_worktree(None, hydrate);
                    if code != ExitCode::SUCCESS {
                        eprintln!(
                            "chg: the worktree is unhydrated; use the cold path (deps.get / install) as before"
                        );
                    }
                }
                ExitCode::SUCCESS
            }
        },
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

/// The adapter's root: `--repo` as given (the dir holding `.chg/`), else the git toplevel
/// of the cwd, else the cwd. Always canonical, because the workspace slot is derived from
/// this path and `.`, `/w/a/` and a symlink must not give one tree several slots or
/// several trees one slot.
fn repo_root(arg: Option<PathBuf>) -> PathBuf {
    let raw = arg.unwrap_or_else(|| git::toplevel(Path::new(".")).unwrap_or_else(|_| ".".into()));
    // A path that does not exist stays as given; loading the manifest then reports it.
    std::fs::canonicalize(&raw).unwrap_or(raw)
}

/// Runs `f` on the canonical root of the worktree holding `arg` (default the cwd), so a
/// subdirectory never stands in for the worktree: artifacts, leases and git paths are
/// all relative to the root.
fn with_worktree(arg: Option<PathBuf>, f: impl FnOnce(&Path) -> ExitCode) -> ExitCode {
    let dir = arg.unwrap_or_else(|| ".".into());
    match git::toplevel(&dir) {
        Ok(root) => f(&std::fs::canonicalize(&root).unwrap_or(root)),
        Err(e) => {
            eprintln!("chg: {} is not in a git worktree: {e}", dir.display());
            ExitCode::from(1)
        }
    }
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
    values: BTreeMap<&str, String>,
    timeout: Duration,
) -> ExitCode {
    match adapter::invoke(repo, name, values, None, timeout) {
        Invoked::Ok(doc) => {
            println!("{}", doc.to_json());
            ExitCode::SUCCESS
        }
        Invoked::Failed(doc) => {
            println!("{}", doc.to_json());
            ExitCode::from(1)
        }
        // `affected` turns any broken output into "run all".
        Invoked::Broken(why) if name == CommandName::Affected => {
            eprintln!("chg: affected {why}; failing closed to the full suite");
            println!(
                "{}",
                Document::Affected(Affected::fail_closed(&why)).to_json()
            );
            ExitCode::SUCCESS
        }
        Invoked::Broken(why) => {
            eprintln!("chg: {name} {why}");
            ExitCode::from(2)
        }
    }
}

fn snapshot_build(repo: &Path, sha: &str) -> ExitCode {
    let r = snapshot::build(repo, sha);
    let store = Store::for_repo(repo);
    let gc = store.map(|s| s.gc());
    match r {
        Ok(Built::Exists(m)) => {
            println!(
                "{}",
                serde_json::json!({"snapshot": m.sha, "status": "exists"})
            );
        }
        Ok(Built::Built(m)) => {
            println!(
                "{}",
                serde_json::json!({"snapshot": m.sha, "status": "built", "from": m.from, "work": m.work, "ms": m.ms})
            );
        }
        Err(e) => {
            eprintln!("chg: snapshot build failed: {e}");
            return ExitCode::from(1);
        }
    }
    if let Ok(Ok(removed)) = gc
        && !removed.is_empty()
    {
        eprintln!("chg: gc removed {}", removed.join(", "));
    }
    ExitCode::SUCCESS
}

fn snapshot_list(repo: &Path) -> ExitCode {
    match Store::for_repo(repo) {
        Ok(s) => {
            for m in s.list() {
                println!("{}", serde_json::to_string(&m).expect("meta serializes"));
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("chg: {e}");
            ExitCode::from(1)
        }
    }
}

fn snapshot_gc(repo: &Path) -> ExitCode {
    match Store::for_repo(repo).map(|s| s.gc()) {
        Ok(Ok(removed)) => {
            println!("{}", serde_json::json!({ "removed": removed }));
            ExitCode::SUCCESS
        }
        Ok(Err(e)) => {
            eprintln!("chg: gc: {e}");
            ExitCode::from(1)
        }
        Err(e) => {
            eprintln!("chg: {e}");
            ExitCode::from(1)
        }
    }
}

fn hydrate(ws_dir: &Path) -> ExitCode {
    match ws::hydrate(ws_dir) {
        Ok(Hydrated::Done {
            snapshot,
            behind,
            paths,
            ms,
        }) => {
            println!(
                "{}",
                serde_json::json!({"snapshot": snapshot, "behind": behind, "paths": paths, "ms": ms})
            );
            ExitCode::SUCCESS
        }
        Ok(Hydrated::NoSnapshot) => {
            eprintln!(
                "chg: no snapshot is an ancestor of HEAD in {}; build one with `chg snapshot build <repo> <sha>`",
                ws_dir.display()
            );
            ExitCode::from(3)
        }
        Err(e) => {
            eprintln!("chg: hydrate failed: {e}");
            ExitCode::from(1)
        }
    }
}
