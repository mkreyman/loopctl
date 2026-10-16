use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use clap::{Parser, Subcommand};

use chg::adapter::{self, Invoked};
use chg::check::{self, Outcome, Verdict};
use chg::contract::{self, CommandName};
use chg::exec;
use chg::gate::{self, Mode};
use chg::git;
use chg::output::{Affected, Document};
use chg::shadow;
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
    /// Static checks plus the affected tests of the working tree against its base.
    /// Exit 0 pass, 1 fail, 2 no verdict (the adapter broke the contract), 3 the gate is
    /// off (`CHG_GATE=off` or `.chg/policy.toml`): run the repo's old gate instead.
    /// Prints the verdict as one JSON line.
    Check {
        #[arg(long)]
        repo: Option<PathBuf>,
        /// The commit to diff against (default: merge-base with origin's default branch).
        #[arg(long)]
        base: Option<String>,
        /// Skip selection and run the whole suite.
        #[arg(long)]
        all: bool,
        /// Run beside the repo's gate without blocking it: start a detached check of
        /// --sha in a throwaway worktree, log its verdict to ~/.chg/shadow/<repo>.jsonl,
        /// and exit 0 at once, whatever happens.
        #[arg(long, conflicts_with = "all")]
        shadow: bool,
        /// The commit to judge (default HEAD). Without --shadow the check runs in the
        /// live tree, so that tree must be exactly this commit, with nothing uncommitted,
        /// before and after the run.
        #[arg(long)]
        sha: Option<String>,
        /// With --shadow: run in this process instead of detaching (tests, debugging).
        #[arg(long, requires = "shadow")]
        foreground: bool,
    },
    /// Which gate judges a push: prints `on`, `shadow` or `off` and where that came from
    /// (`CHG_GATE` beats `.chg/policy.toml` `[gate] mode`; default `shadow`). Always exit 0;
    /// anything unreadable prints `off`, so a hook falls back to the old gate.
    Gate {
        #[arg(long)]
        repo: Option<PathBuf>,
    },
    /// The shadow phase's log and report (story S10).
    Shadow {
        #[command(subcommand)]
        command: ShadowCmd,
    },
}

#[derive(Subcommand)]
enum ShadowCmd {
    /// Record the authoritative gate's verdict for a commit (the pre-push hook calls this
    /// after its own gate). Exit 0 recorded, 1 not.
    Record {
        #[arg(long)]
        repo: Option<PathBuf>,
        /// Default HEAD.
        #[arg(long)]
        sha: Option<String>,
        /// pass | fail
        #[arg(long)]
        verdict: String,
        /// How long the gate took.
        #[arg(long, default_value_t = 0)]
        ms: u64,
        /// The gate's name, e.g. "mix precommit".
        #[arg(long, default_value = "gate")]
        gate: String,
        /// A file listing the gate's failing test ids (`path:line`), one per line.
        #[arg(long)]
        failures_file: Option<PathBuf>,
    },
    /// Pair chg's verdicts with the gate's by commit: disagreements, time saved, and the
    /// cutover criteria. Exit 0 when every criterion is met, 1 when not.
    Report {
        #[arg(long)]
        repo: Option<PathBuf>,
        /// More logs to read (copied from other machines).
        #[arg(long = "file")]
        files: Vec<PathBuf>,
        /// Read each host's log over ssh, comma-separated (`minis,nuc,x1`).
        #[arg(long, value_delimiter = ',')]
        hosts: Vec<String>,
        /// For commits no local gate judged, take this GitHub check run's conclusion
        /// (e.g. "Tests") and record it.
        #[arg(long)]
        ci_check: Option<String>,
        #[arg(long)]
        json: bool,
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
        Top::Check {
            repo,
            base,
            all,
            shadow,
            sha,
            foreground,
        } => {
            let root = repo_root(repo);
            if shadow {
                shadow_check(&root, base, sha, foreground)
            } else {
                check_cmd(&root, base, sha, all)
            }
        }
        Top::Gate { repo } => {
            let r = gate::resolve(&repo_root(repo));
            println!("{}", r.mode);
            eprintln!("chg: gate {} ({})", r.mode, r.source);
            ExitCode::SUCCESS
        }
        Top::Shadow { command } => match command {
            ShadowCmd::Record {
                repo,
                sha,
                verdict,
                ms,
                gate,
                failures_file,
            } => shadow_record(&repo_root(repo), sha, &verdict, ms, &gate, failures_file),
            ShadowCmd::Report {
                repo,
                files,
                hosts,
                ci_check,
                json,
            } => shadow_report(&repo_root(repo), &files, &hosts, ci_check, json),
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

fn base_for(repo: &Path, base: Option<String>, rev: &str) -> Result<String, String> {
    match base {
        Some(b) => git::resolve(repo, &b),
        None => git::default_base(repo, rev),
    }
}

fn check_cmd(repo: &Path, base: Option<String>, sha: Option<String>, all: bool) -> ExitCode {
    let mode = gate::resolve(repo);
    if mode.mode == Mode::Off {
        eprintln!(
            "chg: the chg gate is off ({}); run the repo's own gate",
            mode.source
        );
        return ExitCode::from(3);
    }
    let pinned = match sha.as_deref().map(|s| git::resolve(repo, s)).transpose() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("chg: {e}");
            return ExitCode::from(2);
        }
    };
    let base = match base_for(repo, base, pinned.as_deref().unwrap_or("HEAD")) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("chg: {e}");
            return ExitCode::from(2);
        }
    };
    // A gate asked to judge a commit must judge that commit, not whatever the tree holds.
    if let Some(sha) = &pinned
        && let Err(e) = git::is_exactly(repo, sha)
    {
        eprintln!("chg: no verdict for {sha}: {e}");
        return ExitCode::from(2);
    }
    let mut v = check::run(repo, &base, all);
    if let Some(sha) = &pinned
        && let Err(e) = git::is_exactly(repo, sha)
    {
        v = Verdict {
            ms: v.ms,
            ..Verdict::error(format!("the tree moved while the check ran: {e}"))
        };
    }
    println!("{}", serde_json::to_string(&v).expect("verdicts serialize"));
    let selected = match v.mode.as_deref() {
        Some("all") => "the whole suite".to_string(),
        Some(_) => format!("{} test file(s)", v.selected.len()),
        None => "no tests".to_string(),
    };
    eprintln!(
        "chg: check {} in {} ({selected}): {}",
        v.verdict.as_str(),
        shadow::fmt_ms(v.ms),
        v.reason
    );
    for f in v.failures.iter().take(20) {
        eprintln!("  {f}");
    }
    match v.verdict {
        Outcome::Pass => ExitCode::SUCCESS,
        Outcome::Fail => ExitCode::from(1),
        Outcome::Error | Outcome::Skipped => ExitCode::from(2),
    }
}

/// Never fails: a shadow that cannot start says why on stderr and exits 0, because the
/// push it rides on must not notice it.
fn shadow_check(
    repo: &Path,
    base: Option<String>,
    sha: Option<String>,
    foreground: bool,
) -> ExitCode {
    let mode = gate::resolve(repo);
    if mode.mode == Mode::Off {
        eprintln!("chg: shadow skipped, the chg gate is off ({})", mode.source);
        return ExitCode::SUCCESS;
    }
    let resolved = git::resolve(repo, sha.as_deref().unwrap_or("HEAD"))
        .and_then(|sha| base_for(repo, base, &sha).map(|base| (sha, base)));
    let (sha, base) = match resolved {
        Ok(p) => p,
        Err(e) => {
            eprintln!("chg: shadow skipped: {e}");
            return ExitCode::SUCCESS;
        }
    };
    if foreground {
        match shadow::run_foreground(repo, &sha, &base) {
            Ok(row) => eprintln!(
                "chg: shadow {} {} in {}: {}",
                &sha[..12.min(sha.len())],
                row.verdict.as_str(),
                shadow::fmt_ms(row.ms),
                row.reason
            ),
            Err(e) => eprintln!("chg: shadow: {e}"),
        }
        return ExitCode::SUCCESS;
    }
    match shadow::spawn(repo, &git::repo_key(repo), &sha, &base) {
        Ok(log) => eprintln!(
            "chg: shadow check of {} started in the background (log {})",
            &sha[..12.min(sha.len())],
            log.display()
        ),
        Err(e) => eprintln!("chg: shadow skipped: {e}"),
    }
    ExitCode::SUCCESS
}

fn shadow_record(
    repo: &Path,
    sha: Option<String>,
    verdict: &str,
    ms: u64,
    gate_name: &str,
    failures_file: Option<PathBuf>,
) -> ExitCode {
    let verdict = match verdict {
        "pass" => Outcome::Pass,
        "fail" => Outcome::Fail,
        other => {
            eprintln!("chg: --verdict must be pass or fail, got `{other}`");
            return ExitCode::from(1);
        }
    };
    let sha = match git::resolve(repo, sha.as_deref().unwrap_or("HEAD")) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("chg: {e}");
            return ExitCode::from(1);
        }
    };
    let failures = match failures_file.map(std::fs::read_to_string).transpose() {
        Ok(text) => text
            .unwrap_or_default()
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .map(String::from)
            .collect(),
        Err(e) => {
            eprintln!("chg: --failures-file: {e}");
            return ExitCode::from(1);
        }
    };
    let key = git::repo_key(repo);
    let row = shadow::Row::gate(&key, &sha, verdict, ms, gate_name, "local", failures);
    match shadow::append(&shadow::log_path(&key), &row) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("chg: {e}");
            ExitCode::from(1)
        }
    }
}

fn shadow_report(
    repo: &Path,
    files: &[PathBuf],
    hosts: &[String],
    ci_check: Option<String>,
    json: bool,
) -> ExitCode {
    let key = git::repo_key(repo);
    let local = shadow::log_path(&key);
    let mut texts = Vec::new();
    for f in std::iter::once(&local).chain(files) {
        match std::fs::read_to_string(f) {
            Ok(t) => texts.push(t),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && f == &local => {}
            Err(e) => eprintln!("chg: {}: {e}", f.display()),
        }
    }
    for h in hosts {
        texts.extend(shadow::fetch_remote(h, &key));
    }
    let mut rows = Vec::new();
    let mut bad = 0;
    for t in &texts {
        let (r, b) = shadow::parse(t);
        rows.extend(r);
        bad += b;
    }
    if bad > 0 {
        eprintln!("chg: skipped {bad} unreadable log line(s)");
    }
    let mut rows = shadow::dedup(rows);
    if let Some(check) = ci_check {
        let added = shadow::resolve_ci(repo, &key, &rows, &check, &local);
        rows.extend(added);
    }
    let report = shadow::report(&key, &rows);
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&report).expect("reports serialize")
        );
    } else {
        print!("{}", report.render());
    }
    if report.ready {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}
