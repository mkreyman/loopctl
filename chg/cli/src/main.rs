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
use chg::scratch::{self, AtBuild};
use chg::shadow;
use chg::snapshot::{self, Built, Refresh};
use chg::store::Store;
use chg::ws::{self, Hydrated};
use chg::{culprit, revert, verify};

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
    /// Static checks plus the affected tests of a commit against its base, run where the
    /// repo's snapshots are built (under its build lock), else in the live tree. When chg
    /// is the gate (`chg gate` says `on`), the verdict is also appended to
    /// ~/.chg/shadow/<repo>.jsonl with `source: gate`, for `chg shadow report`. Exit 0 pass, 1 fail, 2 no verdict (the adapter broke the contract), 3 the gate is
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
        /// The commit to judge (default HEAD). It is checked out where snapshots are built,
        /// so what the live tree holds beyond it is not judged. When that path cannot be
        /// used (no store, the path busy, no snapshot, a failed worktree or hydrate), the
        /// check runs in the live tree instead, which must then be exactly this commit, with
        /// nothing uncommitted, before and after the run.
        #[arg(long)]
        sha: Option<String>,
        /// With --shadow: run in this process instead of detaching (tests, debugging).
        #[arg(long, requires = "shadow")]
        foreground: bool,
        /// With --shadow --foreground: mark the row as a replay of a past commit, not a
        /// push. The report counts it like a push and shows how many were replays.
        #[arg(long, requires = "foreground")]
        replay: bool,
    },
    /// Check that this machine can run the repo's gate: the adapter manifest loads, for
    /// an Elixir repo the `mix chg.*` tasks are installed for the Elixir it runs, and the
    /// repo's `.claude/worktrees` shares a filesystem that clones with its snapshot store
    /// (else every hydrate copies byte by byte). Prints one line per check. Exit 0 when
    /// every check passes, 1 when one does not.
    Doctor {
        #[arg(long)]
        repo: Option<PathBuf>,
    },
    /// Which gate judges a push: prints `on`, `shadow` or `off` and where that came from
    /// (`CHG_GATE` beats `.chg/policy.toml` `[gate] mode`; default `shadow`). Always exit 0;
    /// anything unreadable prints `off`, so a hook falls back to the old gate.
    Gate {
        #[arg(long)]
        repo: Option<PathBuf>,
    },
    /// Coverage records (story S2b): `chg verify` publishes one per green trunk commit to
    /// the remote, and coverage selection and time-balanced shards read them.
    Cover {
        #[command(subcommand)]
        command: CoverCmd,
    },
    /// The shadow phase's log and report (story S10).
    Shadow {
        #[command(subcommand)]
        command: ShadowCmd,
    },
    /// This machine's outbox to loopctl's ledger (design §5).
    Outbox {
        #[command(subcommand)]
        command: OutboxCmd,
    },
    /// Change events: the per-change log loopctl applies in `event_seq` order.
    Event {
        #[command(subcommand)]
        command: EventCmd,
    },
    /// Submit HEAD as the branch's next revision: push it to `refs/chg/<change>/<n>`, emit
    /// `submitted` (with `story_id`, which binds the change to that loopctl story), deliver
    /// it, and keep the revision's review key in `<git dir>/chg/review/` (mode 0600). Prints
    /// `{change_id, revision, sha, story_id, already, review_key}`. Idempotent. Exit 0; 1
    /// refused; 2 failed; 3 submitted, but no review key (run `chg review-dispatch`).
    Submit {
        #[arg(long)]
        repo: Option<PathBuf>,
        #[arg(long, default_value = "origin")]
        remote: String,
        /// The loopctl story this change implements.
        #[arg(long)]
        story: Option<String>,
        /// Skip asking loopctl for a review key.
        #[arg(long)]
        no_review_key: bool,
    },
    /// Record the review of the branch's last revision (HEAD must be it). `--findings` is
    /// the reviewer's JSON array: `[]` emits `review_approved {by: "model"}`, anything else
    /// `review_findings`. Exit 0; 1 refused; 2 failed.
    Review {
        #[arg(long)]
        repo: Option<PathBuf>,
        #[arg(long, default_value = "origin")]
        remote: String,
        #[arg(long)]
        findings: PathBuf,
    },
    /// After `gh pr merge`: check that the branch's PR merged with its last revision as
    /// head and the merge commit is on the base, then emit `check_passed` (from the PR's
    /// required checks) and `landed {merge_sha}`. Idempotent. Exit 0; 1 refused (not merged
    /// yet, checks not green, no clean review); 2 failed.
    Land {
        #[arg(long)]
        repo: Option<PathBuf>,
        #[arg(long, default_value = "origin")]
        remote: String,
        /// The change's branch (default: the current one; it may be deleted by now).
        #[arg(long)]
        branch: Option<String>,
    },
    /// Ask loopctl for the review key of one (change, revision) under the source's chg
    /// root (loopctl US-50.3). Prints loopctl's answer: `{dispatch_id, api_key,
    /// expires_at}`, and keeps it (0600) in `<git dir>/chg/review/`, where `chg review`
    /// reads it. The key is shown once; hand it to the review job only. A repeat
    /// before a verdict revokes the earlier key and mints afresh. Exit 0 minted, 1 refused
    /// (409 `review_already_recorded`, 422 `revision_not_submitted`; loopctl's error on
    /// stderr), 2 could not ask.
    ReviewDispatch {
        #[arg(long)]
        repo: Option<PathBuf>,
        #[arg(long)]
        change: String,
        #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
        revision: u64,
    },
    /// Run the whole suite (static checks included, unless --no-static) on a trunk commit
    /// in this tree, and on green fast-forward `verified/<branch>` on the remote to it;
    /// never backwards, and never forced (story S8). Prints a JSON report. Exit 0 green (or nothing to do: the
    /// ref is already there, or a newer commit is verified), 1 red, 2 no verdict.
    Verify {
        #[arg(long)]
        repo: Option<PathBuf>,
        /// The commit to verify (default HEAD). The tree must be exactly this commit.
        #[arg(long)]
        sha: Option<String>,
        #[arg(long, default_value = "origin")]
        remote: String,
        /// The ref to advance, under refs/heads/.
        #[arg(long = "ref", default_value = "verified/master")]
        ref_name: String,
        /// Do not run the suite: it already passed on this commit (a CI job). Only advance.
        #[arg(long)]
        no_run: bool,
        /// Skip the static checks (format, lint, types): a CI job on the same push gates
        /// them on this commit. Run verify only after that job PASSED (`needs:` on it), or
        /// a static failure reaches the ref unchecked. The suite, its coverage record and
        /// the ref advance run as usual; a test failure still holds the ref.
        #[arg(long, conflicts_with = "no_run")]
        no_static: bool,
        /// Run the suite but leave the ref alone.
        #[arg(long)]
        no_push: bool,
        /// Write the failing test ids here, one per line (for `chg culprit --tests`). Empty
        /// when static checks failed: those are not tests to search with.
        #[arg(long)]
        failures_out: Option<PathBuf>,
        /// The wall-clock cap of the whole-suite run.
        #[arg(long, default_value_t = exec::SUITE_TIMEOUT_SECS,
              value_parser = clap::value_parser!(u64).range(1..))]
        tests_timeout_secs: u64,
    },
    /// Find the first commit on <bad>'s first-parent line after <good> at which the tests
    /// failing on <bad> fail (story S8). Each failing test is rerun on <bad> first, and
    /// one that passes there is reported flaky and left out. Runs in a throwaway worktree.
    /// Prints a JSON report (`culprit` is null when nothing fails for real). Exit 0 with
    /// an answer, 2 when the search could not run.
    Culprit {
        good: String,
        bad: String,
        #[arg(long)]
        repo: Option<PathBuf>,
        /// The failing test ids, one per line (`chg verify --failures-out`); default: run
        /// the whole suite on <bad> to find them.
        #[arg(long)]
        tests: Option<PathBuf>,
        /// Reruns on <bad> before a failing test counts as real.
        #[arg(long, default_value_t = 2)]
        reruns: u32,
        /// Overrides the wall-clock cap of the snapshot build a search runs when no
        /// snapshot exists yet.
        #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
        snapshot_timeout_secs: Option<u64>,
        /// The wall-clock cap of the whole-suite run on <bad> when no --tests is given.
        #[arg(long, default_value_t = exec::SUITE_TIMEOUT_SECS,
              value_parser = clap::value_parser!(u64).range(1..))]
        tests_timeout_secs: u64,
    },
    /// File one open issue per flaky test (`chg culprit`'s `flaky`), or comment on the
    /// one already open; idempotent per run id (story S8). Prints the issue URLs.
    Flaky {
        /// The flaky test ids, one per line.
        #[arg(long)]
        tests: PathBuf,
        #[arg(long)]
        run_id: String,
        #[arg(long)]
        repo: Option<PathBuf>,
        #[arg(long, default_value = "origin")]
        remote: String,
        #[arg(long, default_value = "flaky")]
        label: String,
    },
    /// Open a PR reverting <culprit> on the trunk, arm auto-merge, file the story to
    /// re-land it, and tell the culprit's PR (story S8). Idempotent on the culprit: a
    /// retry, or a later red run naming it again, finishes what was started and opens
    /// nothing twice. Prints a JSON report. Exit 0
    /// when a revert PR exists, 1 when the revert does not apply (the story says so), 2
    /// on error.
    Revert {
        culprit: String,
        /// The verifier's run id, named in the PR and the story.
        #[arg(long)]
        run_id: String,
        #[arg(long)]
        repo: Option<PathBuf>,
        #[arg(long, default_value = "origin")]
        remote: String,
        /// The trunk branch.
        #[arg(long, default_value = "master")]
        base: String,
        /// The failing test ids, one per line, for the PR and the story.
        #[arg(long)]
        tests: Option<PathBuf>,
        #[arg(long, default_value = "auto-revert")]
        label: String,
        #[arg(long, default_value = "reland")]
        fix_label: String,
    },
}

#[derive(Subcommand)]
enum OutboxCmd {
    /// Deliver this machine's unsent ledger rows (shadow log, review rounds, flaky tests)
    /// and change events to loopctl, for every repo in ~/.chg/loopctl.toml. Each file is
    /// sent from the offset loopctl last answered for; the first send is the backfill.
    /// Never on a push: writers start it detached, and a cron line repeats it. A failure
    /// backs the repo off (30 s doubling to 1 h). Exit 0 sent or nothing to do (also when
    /// unconfigured or another send is running), 1 when a repo failed.
    Send {
        /// Ignore the backoff.
        #[arg(long)]
        force: bool,
        /// Send every file again from its start, this once: after a sender fix, so rows
        /// loopctl refused before are offered again. The rest count as duplicates.
        #[arg(long)]
        from_start: bool,
        /// Print nothing unless something failed.
        #[arg(long)]
        quiet: bool,
        #[arg(long)]
        json: bool,
    },
    /// Per configured repo: unsent rows, the oldest one's age, changes with undelivered
    /// events, and the backoff. Exit 0 healthy, 1 when a row has waited over 24 h.
    Status {
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand)]
enum EventCmd {
    /// Append one event to a change's chain (`refs/chg/<change>/events` on the remote).
    /// Its `event_seq` is the next after the remote's tip: the push is a fast-forward, so
    /// two machines racing never share or skip a seq. Delivery to loopctl follows in the
    /// background. Prints `{change_id, event_seq, commit, repo}`. Exit 0 or 2.
    Emit {
        #[arg(long)]
        repo: Option<PathBuf>,
        #[arg(long, default_value = "origin")]
        remote: String,
        #[arg(long)]
        change: String,
        /// The event kind, e.g. `submitted`, `landed` (loopctl US-47.4 maps them).
        #[arg(long)]
        kind: String,
        #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
        revision: u64,
        /// The revision's full commit sha.
        #[arg(long)]
        sha: String,
        /// A JSON object (default `{}`).
        #[arg(long, default_value = "{}")]
        data: String,
    },
    /// Deliver a change's events from this clone: loopctl's cursor says what it lacks, and
    /// the chain on the remote supplies it. The answer to a gap alert. Exit 0 or 2.
    Sync {
        #[arg(long)]
        repo: Option<PathBuf>,
        #[arg(long, default_value = "origin")]
        remote: String,
        #[arg(long)]
        change: String,
    },
}

#[derive(Subcommand)]
enum CoverCmd {
    /// Mirror the remote's coverage records (`refs/chg/cover/*`); each is unpacked into
    /// this machine's store when it is first used. Run it before balanced shards; `chg
    /// check` fetches the one record it selects by itself. Prints how many were new. Exit
    /// 0, or 2 when the fetch failed (selection then uses whatever records are already here).
    Fetch {
        #[arg(long)]
        repo: Option<PathBuf>,
        #[arg(long, default_value = "origin")]
        remote: String,
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
        /// pass | fail, and with `--source hook` also error.
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
        /// `local` (a gate this machine ran) or `ci` (a CI check run's verdict, which has no
        /// gate time, so `--ms` is refused, and stays out of the gate-time figures). A replay
        /// of a commit with chg's enrollment overlaid records the original commit's CI
        /// verdict this way, for the synthetic commit it judged.
        /// `hook`: the pre-push hook's final decision on a gate-mode push. With
        /// `--gate "chg check"` it overrides the verdict of the gate-mode check of that
        /// commit it followed (within 15 minutes); with any other gate (the hook's own,
        /// after exit 3) it is a check of its own. It never pairs with a shadow check.
        #[arg(long, default_value = shadow::LOCAL_SOURCE, value_parser = [shadow::LOCAL_SOURCE, shadow::CI_SOURCE, shadow::HOOK_SOURCE])]
        source: String,
        /// Why the gate decided as it did; with `--source hook`, why it overrode chg.
        #[arg(long)]
        reason: Option<String>,
    },
    /// Pair chg's verdicts with the gate's by commit: disagreements, time saved, and the
    /// cutover criteria. Gate-mode `chg check` verdicts (logged with `source: gate` once
    /// `chg check` is the gate), as the hook's `source: hook` rows decided them, are
    /// summarised per host: count, pass/fail, the subset share, median and p90 time, the
    /// top reasons the whole suite ran, and how many verdicts the hook overrode and why.
    /// Exit 0 when every criterion is met, 1 when not.
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
    Build {
        repo: PathBuf,
        sha: String,
        /// Overrides the snapshot command's wall-clock cap, for a first full build on a
        /// slow machine.
        #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
        timeout_secs: Option<u64>,
    },
    /// Build the snapshot of <sha> only from an older snapshot of its history, skipping
    /// when another build is running, then GC. Never builds cold. <repo> may be a git dir.
    /// Exit 0 built, present or skipped (the JSON line says which), 1 failed.
    Refresh {
        repo: PathBuf,
        sha: String,
        #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
        timeout_secs: Option<u64>,
    },
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
        /// With `shard`: split by the recorded per-file time of the coverage record of
        /// this commit, which must be in this machine's store (`chg cover fetch`). Give
        /// every shard of one run the same sha.
        #[arg(long)]
        balance_by: Option<String>,
        /// Overrides the per-command wall-clock cap.
        #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
        timeout_secs: Option<u64>,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.command {
        Top::Snapshot { command } => match command {
            SnapshotCmd::Build {
                repo,
                sha,
                timeout_secs,
            } => {
                let timeout = exec::cap(CommandName::Snapshot, timeout_secs);
                with_worktree(Some(repo), |r| snapshot_build(r, &sha, timeout))
            }
            SnapshotCmd::Refresh {
                repo,
                sha,
                timeout_secs,
            } => snapshot_refresh(&repo, &sha, exec::cap(CommandName::Snapshot, timeout_secs)),
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
            replay,
        } => {
            let root = repo_root(repo);
            if shadow {
                shadow_check(&root, base, sha, foreground, replay)
            } else {
                check_cmd(&root, base, sha, all)
            }
        }
        Top::Doctor { repo } => doctor(&repo_root(repo)),
        Top::Outbox { command } => match command {
            OutboxCmd::Send {
                force,
                from_start,
                quiet,
                json,
            } => outbox_send(force, from_start, quiet, json),
            OutboxCmd::Status { json } => outbox_status(json),
        },
        Top::Event { command } => match command {
            EventCmd::Emit {
                repo,
                remote,
                change,
                kind,
                revision,
                sha,
                data,
            } => with_worktree(repo, |r| {
                let data = match serde_json::from_str(&data) {
                    Ok(d) => d,
                    Err(e) => {
                        eprintln!("chg: event emit: --data is not JSON: {e}");
                        return ExitCode::from(2);
                    }
                };
                let ev = chg::events::NewEvent {
                    change_id: &change,
                    kind: &kind,
                    revision,
                    sha: &sha,
                    data,
                };
                match chg::events::emit(r, &remote, &ev) {
                    Ok(e) => {
                        println!("{}", serde_json::to_string(&e).expect("serializes"));
                        ExitCode::SUCCESS
                    }
                    Err(e) => {
                        eprintln!("chg: event emit: {e}");
                        ExitCode::from(2)
                    }
                }
            }),
            EventCmd::Sync {
                repo,
                remote,
                change,
            } => with_worktree(repo, |r| match chg::events::sync(r, &remote, &change) {
                Ok(slug) => {
                    eprintln!("chg: {change} of {slug} is queued; `chg outbox status` shows it");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("chg: event sync: {e}");
                    ExitCode::from(2)
                }
            }),
        },
        Top::Submit {
            repo,
            remote,
            story,
            no_review_key,
        } => with_worktree(repo, |r| {
            submit_cmd(r, &remote, story.as_deref(), !no_review_key)
        }),
        Top::Review {
            repo,
            remote,
            findings,
        } => with_worktree(repo, |r| {
            let v = match std::fs::read_to_string(&findings)
                .map_err(|e| e.to_string())
                .and_then(|t| serde_json::from_str(&t).map_err(|e| e.to_string()))
            {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("chg: review: {}: {e}", findings.display());
                    return ExitCode::from(2);
                }
            };
            change_out("review", chg::change::review(r, &remote, &v))
        }),
        Top::Land {
            repo,
            remote,
            branch,
        } => with_worktree(repo, |r| {
            change_out("land", chg::change::land(r, &remote, branch.as_deref()))
        }),
        Top::ReviewDispatch {
            repo,
            change,
            revision,
        } => with_worktree(repo, |r| review_dispatch_cmd(r, &change, revision)),
        Top::Gate { repo } => {
            let r = gate::resolve(&repo_root(repo));
            println!("{}", r.mode);
            eprintln!("chg: gate {} ({})", r.mode, r.source);
            ExitCode::SUCCESS
        }
        Top::Cover { command } => match command {
            CoverCmd::Fetch { repo, remote } => {
                with_worktree(repo, |r| match chg::cover::fetch(r, &remote) {
                    Ok(n) => {
                        println!("{n}");
                        ExitCode::SUCCESS
                    }
                    Err(e) => {
                        eprintln!("chg: cover fetch: {e}");
                        ExitCode::from(2)
                    }
                })
            }
        },
        Top::Shadow { command } => match command {
            ShadowCmd::Record {
                repo,
                sha,
                verdict,
                ms,
                gate,
                failures_file,
                source,
                reason,
            } => shadow_record(
                &repo_root(repo),
                sha,
                &verdict,
                ms,
                GateArgs {
                    name: &gate,
                    source: &source,
                    reason,
                },
                failures_file,
            ),
            ShadowCmd::Report {
                repo,
                files,
                hosts,
                ci_check,
                json,
            } => shadow_report(&repo_root(repo), &files, &hosts, ci_check, json),
        },
        Top::Verify {
            repo,
            sha,
            remote,
            ref_name,
            no_run,
            no_static,
            no_push,
            failures_out,
            tests_timeout_secs,
        } => verify_cmd(
            &repo_root(repo),
            sha.as_deref().unwrap_or("HEAD"),
            &verify::Options {
                remote: &remote,
                ref_name: &ref_name,
                no_run,
                no_static,
                push: !no_push,
                tests_timeout: Duration::from_secs(tests_timeout_secs),
            },
            failures_out,
        ),
        Top::Culprit {
            good,
            bad,
            repo,
            tests,
            reruns,
            snapshot_timeout_secs,
            tests_timeout_secs,
        } => culprit_cmd(
            &repo_root(repo),
            &good,
            &bad,
            tests,
            reruns,
            exec::cap(CommandName::Snapshot, snapshot_timeout_secs),
            Duration::from_secs(tests_timeout_secs),
        ),
        Top::Flaky {
            tests,
            run_id,
            repo,
            remote,
            label,
        } => {
            let root = repo_root(repo);
            let result = read_ids(&tests).and_then(|ids| {
                let urls = revert::file_flaky(&root, &remote, &ids, &run_id, &label)?;
                ledger_flaky(&root, &ids, &run_id);
                Ok(urls)
            });
            match result {
                Ok(urls) => {
                    for u in urls {
                        println!("{u}");
                    }
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("chg: flaky: {e}");
                    ExitCode::from(2)
                }
            }
        }
        Top::Revert {
            culprit,
            run_id,
            repo,
            remote,
            base,
            tests,
            label,
            fix_label,
        } => {
            let failing = match tests.map(|t| read_ids(&t)).transpose() {
                Ok(f) => f.unwrap_or_default(),
                Err(e) => {
                    eprintln!("chg: {e}");
                    return ExitCode::from(2);
                }
            };
            revert_cmd(
                &repo_root(repo),
                &culprit,
                &revert::Options {
                    remote: &remote,
                    base: &base,
                    run_id: &run_id,
                    failing,
                    label: &label,
                    fix_label: &fix_label,
                },
            )
        }
        Top::Adapter { command } => match command {
            AdapterCmd::Validate { repo } => validate(&repo_root(repo)),
            AdapterCmd::Exec {
                command,
                repo,
                base,
                file,
                n,
                i,
                balance_by,
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
                let timeout = exec::cap(name, timeout_secs);
                let root = repo_root(repo);
                if let Some(sha) = balance_by {
                    match balance_record(&root, name, &sha) {
                        Ok(path) => {
                            values.insert("shard_by", path);
                        }
                        Err(e) => {
                            eprintln!("chg: --balance-by: {e}");
                            return ExitCode::from(2);
                        }
                    }
                }
                exec_cmd(&root, name, values, timeout)
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

fn doctor(repo: &Path) -> ExitCode {
    println!("ok: chg {}", chg::VERSION);
    let manifest = match contract::load(repo) {
        Ok(m) => m,
        Err(e) => {
            println!("FAIL: adapter manifest: {}", e.to_string().trim_end());
            return ExitCode::from(1);
        }
    };
    println!(
        "ok: {} adapter, contract {}",
        manifest.kind.as_str(),
        manifest.version
    );
    if manifest.kind == contract::Kind::Elixir {
        match adapter::elixir_tasks(repo) {
            Ok(at) => println!("ok: mix chg.* tasks installed in {at}"),
            Err(e) => {
                println!("FAIL: {e}");
                return ExitCode::from(1);
            }
        }
    }
    match chg::doctor::worktrees_and_store(repo, &manifest.artifacts) {
        Ok(f) if f.ok => println!("ok: {}", f.text),
        Ok(f) => {
            println!("FAIL: {}", f.text);
            return ExitCode::from(1);
        }
        Err(e) => {
            println!("FAIL: worktrees and the snapshot store: {e}");
            return ExitCode::from(1);
        }
    }
    match chg::outbox::doctor(repo) {
        (true, text) => println!("ok: {text}"),
        (false, text) => {
            println!("FAIL: {text}");
            return ExitCode::from(1);
        }
    }
    ExitCode::SUCCESS
}

/// One `flaky` ledger row per test, for loopctl (design §5). A failure to write is reported
/// and never fails the filing.
fn ledger_flaky(repo: &Path, ids: &[String], run_id: &str) {
    let Some(slug) = git::origin_slug(repo) else {
        return;
    };
    let host = shadow::hostname();
    let at = chg::outbox::now_ms();
    let rows: Vec<serde_json::Value> = ids
        .iter()
        .map(|t| {
            serde_json::json!({
                "v": 1, "kind": "flaky", "repo": slug, "host": host, "at_ms": at,
                "test": t, "run_id": run_id,
            })
        })
        .collect();
    let path = chg::outbox::derived_path(&git::repo_key(repo), "flaky");
    match chg::outbox::append_rows(&path, &rows) {
        Ok(()) => chg::outbox::kick(),
        Err(e) => eprintln!("chg: flaky: the ledger row was not written: {e}"),
    }
}

fn outbox_send(force: bool, from_start: bool, quiet: bool, json: bool) -> ExitCode {
    let s = match chg::outbox::send(force, from_start) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("chg: outbox send: {e}");
            return ExitCode::from(1);
        }
    };
    let failed = s.repos.iter().any(|r| r.problem.is_some());
    if json {
        println!("{}", serde_json::to_string(&s).expect("serializes"));
    } else if !quiet || failed || !s.warnings.is_empty() {
        let at = chg::outbox::rfc3339(chg::outbox::now_ms());
        if !s.configured {
            println!(
                "{at} nothing to send: {} is absent",
                chg::outbox::config_path().display()
            );
        } else if s.busy {
            println!("{at} another send is running");
        }
        for r in &s.repos {
            let mut line = format!(
                "{at} {}: {} inserted, {} duplicate(s), {} rejected; events: {} posted, {} change(s) complete",
                r.repo,
                r.sent.inserted,
                r.sent.duplicates,
                r.sent.rejected,
                r.events.posted,
                r.events.completed
            );
            for p in &r.events.problems {
                line.push_str(&format!("; {p}"));
            }
            if let Some(p) = &r.problem {
                line.push_str(&format!("; STOPPED: {p}"));
            }
            println!("{line}");
        }
        for w in &s.warnings {
            println!("{at} warning: {w}");
        }
    }
    if failed {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}

fn outbox_status(json: bool) -> ExitCode {
    let cfg = match chg::outbox::load() {
        Ok(Some(c)) => c,
        Ok(None) => {
            println!(
                "not configured: {} is absent",
                chg::outbox::config_path().display()
            );
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("chg: outbox status: {e}");
            return ExitCode::from(1);
        }
    };
    let now = chg::outbox::now_ms();
    let st = chg::outbox::status(&cfg);
    if json {
        println!("{}", serde_json::to_string(&st).expect("serializes"));
    } else {
        for r in &st {
            println!("{}", r.line(now));
        }
    }
    if st.iter().all(|r| r.healthy(now)) {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

fn change_out<T: serde::Serialize>(verb: &str, r: Result<T, chg::change::Refusal>) -> ExitCode {
    match r {
        Ok(v) => {
            println!("{}", serde_json::to_string(&v).expect("serializes"));
            ExitCode::SUCCESS
        }
        Err(chg::change::Refusal::Refused(e)) => {
            eprintln!("chg: {verb}: {e}");
            ExitCode::from(1)
        }
        Err(chg::change::Refusal::Failed(e)) => {
            eprintln!("chg: {verb}: {e}");
            ExitCode::from(2)
        }
    }
}

fn submit_cmd(repo: &Path, remote: &str, story: Option<&str>, want_key: bool) -> ExitCode {
    let s = match chg::change::submit(repo, remote, story) {
        Ok(s) => s,
        Err(e) => return change_out::<()>("submit", Err(e)),
    };
    let mut out = serde_json::to_value(&s).expect("serializes");
    let key = if want_key {
        review_key(repo, &s)
    } else {
        Ok(None)
    };
    let code = match key {
        Ok(p) => {
            out["review_key"] = serde_json::json!(p.map(|p| p.display().to_string()));
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!(
                "chg: submit: submitted, but no review key: {e}; run `chg review-dispatch --change {} --revision {}`",
                s.change_id, s.revision
            );
            out["review_key"] = serde_json::Value::Null;
            ExitCode::from(3)
        }
    };
    println!("{out}");
    code
}

/// Delivers `submitted`, then asks for the revision's review key and keeps it (0600).
/// `Ok(None)`: loopctl already holds a review of this revision.
fn review_key(repo: &Path, s: &chg::change::Submitted) -> Result<Option<PathBuf>, String> {
    let cfg = chg::outbox::load()?
        .ok_or_else(|| format!("{} is absent", chg::outbox::config_path().display()))?;
    let slug = git::origin_slug(repo).ok_or("the repo has no origin to name it")?;
    let path = chg::change::review_key_path(repo, &s.change_id, s.revision)?;
    if s.already && path.exists() {
        return Ok(Some(path));
    }
    let mut last = String::new();
    for attempt in 0..4 {
        if attempt > 0 {
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
        if let Err(e) = chg::change::deliver_now(&cfg, &slug, &s.change_id) {
            last = e;
            continue;
        }
        match chg::events::review_dispatch(&cfg, &slug, &s.change_id, s.revision)? {
            r if r.status == 201 || r.status == 200 => {
                chg::change::keep_review_key(&path, r.body.trim())?;
                return Ok(Some(path));
            }
            r if r.status == 409 => return Ok(None),
            // `revision_not_submitted`: loopctl has not applied `submitted` yet.
            r if r.status == 422 => last = format!("HTTP 422 {}", r.code()),
            r => return Err(format!("HTTP {} {}", r.status, r.code())),
        }
    }
    Err(last)
}

fn review_dispatch_cmd(repo: &Path, change: &str, revision: u64) -> ExitCode {
    let cfg = match chg::outbox::load() {
        Ok(Some(c)) => c,
        Ok(None) => {
            eprintln!(
                "chg: review-dispatch: {} is absent",
                chg::outbox::config_path().display()
            );
            return ExitCode::from(2);
        }
        Err(e) => {
            eprintln!("chg: review-dispatch: {e}");
            return ExitCode::from(2);
        }
    };
    let Some(slug) = git::origin_slug(repo) else {
        eprintln!("chg: review-dispatch: the repo has no origin to name it");
        return ExitCode::from(2);
    };
    match chg::events::review_dispatch(&cfg, &slug, change, revision) {
        Ok(r) if r.status == 201 || r.status == 200 => {
            // Kept where `chg review` reads it, so a key minted here is the one it records with.
            let kept = chg::change::review_key_path(repo, change, revision)
                .and_then(|p| chg::change::keep_review_key(&p, r.body.trim()));
            if let Err(e) = kept {
                eprintln!("chg: review-dispatch: keeping the key: {e}");
                return ExitCode::from(2);
            }
            println!("{}", r.body.trim());
            ExitCode::SUCCESS
        }
        Ok(r) if matches!(r.status, 409 | 422) => {
            eprintln!("chg: review-dispatch: HTTP {} {}", r.status, r.code());
            ExitCode::from(1)
        }
        Ok(r) => {
            eprintln!("chg: review-dispatch: HTTP {} {}", r.status, r.code());
            ExitCode::from(2)
        }
        Err(e) => {
            eprintln!("chg: review-dispatch: {e}");
            ExitCode::from(2)
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

/// The coverage record a balanced shard splits by. A missing record is an error, never a
/// quiet fallback: a sibling shard that has it would split differently, and between them
/// some files would run twice and others never.
fn balance_record(repo: &Path, name: CommandName, rev: &str) -> Result<String, String> {
    if name != CommandName::Shard {
        return Err("only `shard` takes it".into());
    }
    let sha = git::resolve(repo, rev)?;
    match chg::cover::materialize(repo, &Store::for_repo(repo)?, &sha)? {
        Some(path) => Ok(path.to_string_lossy().into_owned()),
        None => Err(format!(
            "no coverage record of {sha} here; run `chg cover fetch`"
        )),
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

fn snapshot_build(repo: &Path, sha: &str, timeout: Duration) -> ExitCode {
    let r = snapshot::build(repo, sha, timeout);
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

fn snapshot_refresh(repo: &Path, sha: &str, timeout: Duration) -> ExitCode {
    let status = match snapshot::refresh(repo, sha, timeout) {
        Ok(Refresh::Done(Built::Exists(m))) => {
            serde_json::json!({"snapshot": m.sha, "status": "exists"})
        }
        Ok(Refresh::Done(Built::Built(m))) => {
            serde_json::json!({"snapshot": m.sha, "status": "built", "from": m.from, "work": m.work, "ms": m.ms})
        }
        Ok(Refresh::Busy) => serde_json::json!({"sha": sha, "status": "busy"}),
        Ok(Refresh::NoAncestor) => serde_json::json!({"sha": sha, "status": "no-ancestor"}),
        Err(e) => {
            eprintln!("chg: snapshot refresh failed: {e}");
            return ExitCode::from(1);
        }
    };
    println!("{status}");
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
    let started = std::time::Instant::now();
    // Every outcome, a commit or base that cannot be resolved included, ends in one
    // verdict, so the one exit path below logs every push this gate judged or blocked.
    let (sha, base, mut v) = gate_verdict(repo, base, sha, all);
    // What the push waited for: the worktree and hydrate of a check at the build path,
    // or what was spent there before falling back to the live tree.
    v.ms = started.elapsed().as_millis() as u64;
    // chg is the gate here, so the check logs its own verdict. The hook then records its
    // final decision on it (`chg shadow record --source hook --gate "chg check"`), which
    // the report takes over this row's verdict. A log that cannot be written never changes
    // the verdict.
    if mode.mode == Mode::On {
        let key = git::repo_key(repo);
        let row = shadow::Row::from_gate_check(&key, &sha, &base, v.clone());
        if let Err(e) = shadow::append(&shadow::log_path(&key), &row) {
            eprintln!("chg: the verdict was not logged: {e}");
        }
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

/// The commit a gate judges, its base, and the verdict. A commit or base that cannot be
/// resolved, or a pinned commit the live tree does not hold, is an error verdict with
/// whatever of the two is known (empty when not).
fn gate_verdict(
    repo: &Path,
    base: Option<String>,
    sha: Option<String>,
    all: bool,
) -> (String, String, Verdict) {
    let pinned = match sha.as_deref().map(|s| git::resolve(repo, s)).transpose() {
        Ok(p) => p,
        Err(e) => return (sha.unwrap_or_default(), String::new(), Verdict::error(e)),
    };
    let sha = match pinned
        .clone()
        .map_or_else(|| git::resolve(repo, "HEAD"), Ok)
    {
        Ok(s) => s,
        Err(e) => return (String::new(), String::new(), Verdict::error(e)),
    };
    let base = match base_for(repo, base, &sha) {
        Ok(b) => b,
        Err(e) => return (sha, String::new(), Verdict::error(e)),
    };
    let v = match gate_at_build(repo, &sha, &base, all) {
        Some(v) => v,
        None => {
            // A gate asked to judge a commit must judge that commit, not whatever the
            // tree holds.
            if pinned.is_some()
                && let Err(e) = git::is_exactly(repo, &sha)
            {
                let why = format!("no verdict for {sha}: {e}");
                return (sha, base, Verdict::error(why));
            }
            let mut v = check::run(repo, &base, all);
            if pinned.is_some()
                && let Err(e) = git::is_exactly(repo, &sha)
            {
                v = Verdict {
                    ms: v.ms,
                    ..Verdict::error(format!("the tree moved while the check ran: {e}"))
                };
            }
            v
        }
    };
    (sha, base, v)
}

/// Checks the commit `sha` where snapshots are built, under the build lock, as a shadow
/// check does: a check in the pushing worktree recompiles what the snapshot baked in at
/// another path (on HCB, 933 of 945 files). `None` when that cannot run, and the caller
/// checks the live tree instead, as before. That happens when there is no store, the build
/// path is busy, there is no snapshot to hydrate from, or the worktree or its hydrate
/// fails. A busy path never makes the gate wait: a snapshot build there can take as long
/// as a PLT build, and another worktree's gate holds it for a whole check.
fn gate_at_build(repo: &Path, sha: &str, base: &str, all: bool) -> Option<Verdict> {
    let fallback = |why: String| {
        eprintln!("chg: checking the live tree: {why}");
        None
    };
    let git_dir = match git::common_dir(repo) {
        Ok(d) => d,
        Err(e) => return fallback(format!("no git dir: {e}")),
    };
    let store = match Store::for_repo(&git_dir) {
        Ok(s) => s,
        Err(e) => return fallback(format!("no snapshot store: {e}")),
    };
    base_snapshot_first(repo, &store, sha, base);
    let lock = match store.try_lock_build() {
        Ok(Some(l)) => l,
        Ok(None) => {
            return fallback("a snapshot build or another check holds the build path".into());
        }
        Err(e) => return fallback(format!("build lock: {e}")),
    };
    let v = match scratch::check_at_build(&git_dir, &store, sha, base, all) {
        AtBuild::Checked { verdict, .. } => verdict,
        AtBuild::NoSnapshot { .. } => {
            return fallback(format!("no snapshot is an ancestor of {sha}"));
        }
        AtBuild::Failed { why, .. } => return fallback(why),
    };
    drop(lock);
    // As after a shadow check: the next push starts from a snapshot of this base.
    shadow::refresh(repo, base, true);
    Some(v)
}

/// Builds the snapshot of `base` before a gate-mode check when the snapshot the check
/// would hydrate from is older than `base` across an `always_all` path (config, the
/// dependency lock, the build file): hydrated from that one, the check's static step would
/// recompile everything inside its own budget (on HCB, 2757 files and a dialyzer PLT,
/// past static's 900 s). The build runs under the snapshot budget, as `chg snapshot
/// refresh` does (never waiting for the build lock), and says so; a busy path or a failed
/// build leaves the check to run as before.
fn base_snapshot_first(repo: &Path, store: &Store, sha: &str, base: &str) {
    let here = store.resolved_build_dir();
    let stale = (|| -> Result<Option<(String, String, String)>, String> {
        if store
            .list()
            .iter()
            .any(|m| m.sha == base && m.is_built_at(&here))
        {
            return Ok(None);
        }
        let Some((near, _)) = store.nearest_ancestor(repo, sha, Some(&here))? else {
            return Ok(None);
        };
        // Hydrate picks an ancestor of `sha`: a base that is not one (a rebased or
        // diverged branch's remote tip) could never be hydrated from, so building it would
        // only make the push wait.
        if near.sha == base
            || !git::is_ancestor(repo, base, sha)?
            || !git::is_ancestor(repo, &near.sha, base)?
        {
            return Ok(None);
        }
        let manifest = contract::load(repo).map_err(|e| e.to_string())?;
        let changed: Vec<String> = git::text(repo, &["diff", "--name-only", &near.sha, base])?
            .lines()
            .map(String::from)
            .collect();
        Ok(chg::glob::first_hit(&manifest.always_all, &changed)
            .map(|(p, g)| (near.sha.clone(), p.to_string(), g.to_string())))
    })();
    let (near, path, pattern) = match stale {
        Ok(Some(s)) => s,
        Ok(None) => return,
        Err(e) => {
            eprintln!("chg: not checking whether the base's snapshot is needed first: {e}");
            return;
        }
    };
    let budget = exec::default_timeout(CommandName::Snapshot);
    eprintln!(
        "chg: the nearest snapshot ({}) is behind the base {} across {path} (always_all `{pattern}`), \
         so the check would rebuild everything in static's budget; building the base's \
         snapshot first, under its own {} s budget",
        &near[..12.min(near.len())],
        &base[..12.min(base.len())],
        budget.as_secs()
    );
    let started = std::time::Instant::now();
    // A refresh never waits for the build lock, as the gate never does.
    match snapshot::refresh(repo, base, budget) {
        Ok(Refresh::Done(_)) => eprintln!(
            "chg: built the snapshot of {} in {}",
            &base[..12.min(base.len())],
            shadow::fmt_ms(started.elapsed().as_millis() as u64)
        ),
        Ok(Refresh::Busy) => {
            eprintln!(
                "chg: another build holds the build path; checking without the base's snapshot"
            )
        }
        Ok(Refresh::NoAncestor) => {
            eprintln!("chg: no snapshot to build the base's from; checking as before")
        }
        Err(e) => eprintln!("chg: building the base's snapshot failed ({e}); checking as before"),
    }
}

/// Never fails: a shadow that cannot start says why on stderr and exits 0, because the
/// push it rides on must not notice it.
fn shadow_check(
    repo: &Path,
    base: Option<String>,
    sha: Option<String>,
    foreground: bool,
    replay: bool,
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
        match shadow::run_foreground(repo, &sha, &base, replay) {
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

/// Which gate `chg shadow record` records, from where, and why it decided so.
struct GateArgs<'a> {
    name: &'a str,
    source: &'a str,
    reason: Option<String>,
}

fn shadow_record(
    repo: &Path,
    sha: Option<String>,
    verdict: &str,
    ms: u64,
    gate: GateArgs,
    failures_file: Option<PathBuf>,
) -> ExitCode {
    let verdict = match verdict {
        "pass" => Outcome::Pass,
        "fail" => Outcome::Fail,
        "error" if gate.source == shadow::HOOK_SOURCE => Outcome::Error,
        other => {
            eprintln!(
                "chg: --verdict must be pass or fail (or error with --source hook), got `{other}`"
            );
            return ExitCode::from(1);
        }
    };
    if gate.source == shadow::CI_SOURCE && ms != 0 {
        eprintln!("chg: --ms has no meaning with --source ci: a CI verdict has no gate time");
        return ExitCode::from(1);
    }
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
    let row = shadow::Row {
        reason: gate.reason.unwrap_or_default(),
        ..shadow::Row::gate(&key, &sha, verdict, ms, gate.name, gate.source, failures)
    };
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

/// Test ids from a file, one per line; blank lines are skipped.
fn read_ids(path: &Path) -> Result<Vec<String>, String> {
    let text =
        std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
    Ok(text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect())
}

fn verify_cmd(
    repo: &Path,
    rev: &str,
    o: &verify::Options,
    failures_out: Option<PathBuf>,
) -> ExitCode {
    let r = match verify::run(repo, rev, o) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("chg: verify: {e}");
            return ExitCode::from(2);
        }
    };
    println!("{}", serde_json::to_string(&r).expect("reports serialize"));
    eprintln!(
        "chg: verify {} {} in {}: {} ({})",
        &r.sha[..12.min(r.sha.len())],
        r.verdict.verdict.as_str(),
        shadow::fmt_ms(r.verdict.ms),
        r.verdict.reason,
        serde_json::to_value(r.outcome).expect("serializes")
    );
    if let Some(path) = failures_out {
        // Test ids only: a static failure (no `mode`: it stopped before the tests) lists
        // check messages, which no test run can find, so the file stays empty and the
        // red static check is left to a person.
        let ids: &[String] = match r.verdict.mode {
            Some(_) => &r.verdict.failures,
            None => &[],
        };
        let body: String = ids.iter().map(|f| format!("{f}\n")).collect();
        if let Err(e) = std::fs::write(&path, body) {
            eprintln!("chg: writing {}: {e}", path.display());
            return ExitCode::from(2);
        }
    }
    match r.verdict.verdict {
        Outcome::Pass | Outcome::Skipped => ExitCode::SUCCESS,
        Outcome::Fail => ExitCode::from(1),
        Outcome::Error => ExitCode::from(2),
    }
}

fn culprit_cmd(
    repo: &Path,
    good: &str,
    bad: &str,
    tests: Option<PathBuf>,
    reruns: u32,
    snapshot_timeout: Duration,
    tests_timeout: Duration,
) -> ExitCode {
    let tests = match tests.map(|t| read_ids(&t)).transpose() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("chg: {e}");
            return ExitCode::from(2);
        }
    };
    match culprit::find(
        repo,
        good,
        bad,
        tests,
        reruns,
        snapshot_timeout,
        tests_timeout,
    ) {
        Ok(f) => {
            println!("{}", serde_json::to_string(&f).expect("reports serialize"));
            eprintln!("chg: culprit: {}", f.reason);
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("chg: culprit: {e}");
            ExitCode::from(2)
        }
    }
}

fn revert_cmd(repo: &Path, culprit: &str, o: &revert::Options) -> ExitCode {
    match revert::open(repo, culprit, o) {
        Ok(r) => {
            println!("{}", serde_json::to_string(&r).expect("reports serialize"));
            for w in &r.warnings {
                eprintln!("chg: revert: {w}");
            }
            match &r.revert_pr {
                Some(u) => {
                    eprintln!("chg: revert PR {u}");
                    ExitCode::SUCCESS
                }
                None => ExitCode::from(1),
            }
        }
        Err(e) => {
            eprintln!("chg: revert: {e}");
            ExitCode::from(2)
        }
    }
}
