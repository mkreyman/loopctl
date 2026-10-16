//! Shadow mode (story S10): `chg check` runs beside a repo's existing gate on every push,
//! never blocking it, and both verdicts land in one log per repo and machine:
//! `~/.chg/shadow/<repo>.jsonl` (`CHG_HOME` moves `~/.chg`).
//!
//! - `chg check --shadow` (from the pre-push hook) resolves the pushed commit and its
//!   base, starts a detached copy of itself, and returns at once with exit 0.
//! - That copy waits for this machine's shadow lock, checks the commit out into a
//!   throwaway worktree inside the snapshot store, hydrates it, runs `chg check` there and
//!   appends a `chg` row. The live tree is never touched: the real gate may be compiling
//!   and testing it at the same moment, and the throwaway worktree has its own workspace
//!   slot, so its own test database.
//! - `chg shadow record` (from the same hook, after the real gate) appends a `gate` row.
//!   `chg shadow report --ci-check <name>` fills in a commit no local gate judged (a push
//!   the hook let CI judge) from that check run on GitHub.
//! - `chg shadow report` pairs the rows by commit and prints the disagreements and the
//!   cutover criteria.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::Write;
use std::os::unix::io::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::check::{self, Outcome, Verdict};
use crate::git;
use crate::store::{Store, now_ms};
use crate::ws::{self, Hydrated};

pub const ROW_VERSION: u32 = 1;
/// How long a shadow check waits for an earlier one on this machine before skipping.
pub const LOCK_WAIT: Duration = Duration::from_secs(30 * 60);
/// Logs of detached runs older than this are removed when a new one starts.
const LOG_TTL: Duration = Duration::from_secs(14 * 24 * 3600);

/// Cutover criteria (issue #18).
pub const MIN_PUSHES: usize = 200;
pub const MIN_MACHINES: usize = 3;
pub const MAX_MEDIAN_MS: u64 = 3 * 60 * 1000;

/// One line of the shadow log.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub v: u32,
    /// `chg` (the shadow check) or `gate` (the authoritative gate).
    pub kind: String,
    pub repo: String,
    pub host: String,
    pub sha: String,
    pub at_ms: u64,
    /// pass | fail | error | skipped
    pub verdict: Outcome,
    #[serde(default)]
    pub ms: u64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub reason: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failures: Vec<String>,
    // chg rows
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hydrate_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub static_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub affected_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tests_ms: Option<u64>,
    // gate rows
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gate: Option<String>,
    /// `local` (the hook ran it) or `ci` (read from a GitHub check run).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

impl Row {
    fn new(kind: &str, repo: &str, sha: &str, verdict: Outcome) -> Row {
        Row {
            v: ROW_VERSION,
            kind: kind.into(),
            repo: repo.into(),
            host: hostname(),
            sha: sha.into(),
            at_ms: now_ms(),
            verdict,
            ms: 0,
            reason: String::new(),
            failures: vec![],
            base: None,
            mode: None,
            selected: None,
            hydrate_ms: None,
            static_ms: None,
            affected_ms: None,
            tests_ms: None,
            gate: None,
            source: None,
        }
    }

    pub fn from_check(repo: &str, sha: &str, base: &str, hydrate_ms: u64, v: Verdict) -> Row {
        Row {
            ms: v.ms,
            reason: v.reason,
            failures: v.failures,
            base: Some(base.into()),
            selected: v.mode.as_deref().map(|_| v.selected),
            mode: v.mode,
            hydrate_ms: Some(hydrate_ms),
            static_ms: Some(v.static_ms),
            affected_ms: Some(v.affected_ms),
            tests_ms: Some(v.tests_ms),
            ..Row::new("chg", repo, sha, v.verdict)
        }
    }

    pub fn gate(
        repo: &str,
        sha: &str,
        verdict: Outcome,
        ms: u64,
        gate: &str,
        source: &str,
        failures: Vec<String>,
    ) -> Row {
        Row {
            ms,
            failures,
            gate: Some(gate.into()),
            source: Some(source.into()),
            ..Row::new("gate", repo, sha, verdict)
        }
    }
}

pub fn hostname() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: gethostname writes at most buf.len() bytes into a buffer we own.
    let ok = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0;
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    let name = if ok {
        String::from_utf8_lossy(&buf[..end]).into_owned()
    } else {
        String::new()
    };
    // `Marks-Mac-mini.local` and `Marks-Mac-mini` are one machine.
    let short = name.split('.').next().unwrap_or("").to_string();
    if short.is_empty() {
        "unknown".into()
    } else {
        short
    }
}

pub fn home() -> PathBuf {
    if let Some(h) = std::env::var_os("CHG_HOME") {
        return PathBuf::from(h);
    }
    PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| "/".into())).join(".chg")
}

pub fn log_path(repo_key: &str) -> PathBuf {
    home().join("shadow").join(format!("{repo_key}.jsonl"))
}

/// Appends one row under an exclusive flock on the log, so concurrent writers (the
/// detached check and the hook's `record`) never interleave a line.
pub fn append(path: &Path, row: &Row) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("creating {}: {e}", dir.display()))?;
    }
    let mut f = File::options()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| format!("opening {}: {e}", path.display()))?;
    // SAFETY: flock on an fd we own; released when `f` closes.
    if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(format!(
            "locking {}: {}",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    let mut line = serde_json::to_string(row).expect("rows serialize");
    line.push('\n');
    f.write_all(line.as_bytes())
        .and_then(|_| f.sync_data())
        .map_err(|e| format!("writing {}: {e}", path.display()))
}

/// Parses a log; a line that does not parse (a torn write, a newer row version's
/// unknown verdict) is counted and skipped.
pub fn parse(text: &str) -> (Vec<Row>, usize) {
    let mut rows = Vec::new();
    let mut bad = 0;
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        match serde_json::from_str::<Row>(line) {
            Ok(r) => rows.push(r),
            Err(_) => bad += 1,
        }
    }
    (rows, bad)
}

/// Starts `chg check --shadow --foreground` for `sha` in a new session with its output
/// in a log file, and returns without waiting for it.
pub fn spawn(repo: &Path, key: &str, sha: &str, base: &str) -> Result<PathBuf, String> {
    let logs = home().join("shadow").join("logs");
    fs::create_dir_all(&logs).map_err(|e| format!("creating {}: {e}", logs.display()))?;
    prune_logs(&logs);
    let log = logs.join(format!("{key}-{}.log", &sha[..sha.len().min(12)]));
    let out = File::create(&log).map_err(|e| format!("creating {}: {e}", log.display()))?;
    let err = out
        .try_clone()
        .map_err(|e| format!("{}: {e}", log.display()))?;
    let exe = std::env::current_exe().map_err(|e| format!("locating chg: {e}"))?;
    // The shared git dir, not this worktree: the pushing worktree may be removed before
    // the detached check is done with it.
    let git_dir = git::common_dir(repo)?;
    let mut c = Command::new(exe);
    c.arg("check")
        .arg("--shadow")
        .arg("--foreground")
        .arg("--repo")
        .arg(&git_dir)
        .args(["--sha", sha, "--base", base])
        .current_dir(&git_dir)
        .stdin(Stdio::null())
        .stdout(out)
        .stderr(err);
    for v in git::HOOK_ENV {
        c.env_remove(v);
    }
    // SAFETY: setsid in the forked child before exec; it touches no shared state. A new
    // session detaches it from the hook's process group and terminal, so neither git
    // finishing the push nor a ^C to it reaches the check.
    unsafe {
        c.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    c.spawn()
        .map_err(|e| format!("starting the shadow check: {e}"))?;
    Ok(log)
}

fn prune_logs(dir: &Path) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let old = e
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .is_some_and(|age| age > LOG_TTL);
        if old {
            let _ = fs::remove_file(e.path());
        }
    }
}

/// The throwaway worktree, removed on drop however the check ended. Git is run against
/// the shared git dir, never the pushing worktree, which may be removed (merged and
/// cleaned up) while the shadow waits or runs.
struct Scratch {
    git_dir: PathBuf,
    path: PathBuf,
}

impl Drop for Scratch {
    fn drop(&mut self) {
        clear(&self.git_dir, &self.path);
    }
}

/// Unregisters and deletes the worktree at `path`, if any: a finished check's, or one a
/// killed check left behind.
fn clear(git_dir: &Path, path: &Path) {
    let mut c = git::cmd(git_dir);
    c.args(["worktree", "remove", "--force"])
        .arg(path)
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let _ = c.status();
    let _ = fs::remove_dir_all(path);
    let mut c = git::cmd(git_dir);
    c.args(["worktree", "prune"])
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let _ = c.status();
}

/// The shadow check itself (`--foreground`): judge `sha` against `base` in a throwaway
/// worktree and append a `chg` row. Returns the row it wrote.
pub fn run_foreground(repo: &Path, sha: &str, base: &str) -> Result<Row, String> {
    let key = git::repo_key(repo);
    let row = judge(repo, &key, sha, base);
    append(&log_path(&key), &row)?;
    Ok(row)
}

fn judge(repo: &Path, key: &str, sha: &str, base: &str) -> Row {
    let skipped = |why: String| Row::from_check(key, sha, base, 0, Verdict::skipped(why));
    let failed =
        |hydrate_ms, why: String| Row::from_check(key, sha, base, hydrate_ms, Verdict::error(why));
    // Below the sessions working on this machine: the shadow is the one job here that
    // nobody is waiting on.
    // SAFETY: nice(2) on this process only.
    unsafe {
        libc::nice(10);
    }
    let git_dir = match git::common_dir(repo) {
        Ok(d) => d,
        Err(e) => return skipped(format!("no git dir: {e}")),
    };
    let store = match Store::for_repo(&git_dir) {
        Ok(s) => s,
        Err(e) => return skipped(format!("no snapshot store: {e}")),
    };
    let _lock = match store.lock_shadow(LOCK_WAIT) {
        Ok(Some(l)) => l,
        Ok(None) => {
            return skipped(format!(
                "another shadow check held this machine for {} min",
                LOCK_WAIT.as_secs() / 60
            ));
        }
        Err(e) => return skipped(format!("shadow lock: {e}")),
    };

    // One fixed path per repo: its workspace slot, so its test database, is the same on
    // every run (as snapshot builds share one), and the lock makes it ours alone. A
    // worktree a killed check left there is cleared first.
    let path = store.shadow_dir().join("ws");
    clear(&git_dir, &path);
    if let Err(e) = fs::create_dir_all(store.shadow_dir()) {
        return skipped(format!("creating {}: {e}", store.shadow_dir().display()));
    }
    // No hooks: the repo's post-checkout would hydrate (we do that below, and need its
    // result), and any other hook of the repo has no business in a throwaway tree.
    let mut c = git::cmd(&git_dir);
    c.args([
        "-c",
        "core.hooksPath=/dev/null",
        "worktree",
        "add",
        "--detach",
        "--force",
    ])
    .arg(&path)
    .arg(sha)
    .env("CHG_SKIP_HYDRATE", "1");
    if let Err(e) = git::run(c) {
        clear(&git_dir, &path);
        return failed(0, format!("worktree add: {e}"));
    }
    let scratch = Scratch {
        git_dir,
        path: fs::canonicalize(&path).unwrap_or(path),
    };

    let t = Instant::now();
    let hydrated = ws::hydrate(&scratch.path);
    let hydrate_ms = t.elapsed().as_millis() as u64;
    match hydrated {
        Ok(Hydrated::Done { .. }) => {}
        Ok(Hydrated::NoSnapshot) => {
            return Row::from_check(
                key,
                sha,
                base,
                hydrate_ms,
                Verdict::skipped(format!(
                    "no snapshot is an ancestor of {sha}; a cold build would compete with the real gate (build one with `chg snapshot build`)"
                )),
            );
        }
        Err(e) => return failed(hydrate_ms, format!("hydrate: {e}")),
    }
    let v = check::run(&scratch.path, base, false);
    drop(scratch);
    Row::from_check(key, sha, base, hydrate_ms, v)
}

// ---------------------------------------------------------------------------------------
// The report

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Class {
    /// Both passed, or both failed.
    Agree,
    /// chg green, gate red: a test chg did not select. Blocks cutover.
    Miss,
    /// chg red, gate green: a flake in chg's run, or an environment difference.
    ChgRed,
    /// The gate itself gave both verdicts for this commit; it cannot judge chg.
    GateFlaky,
}

#[derive(Debug, Clone, Serialize)]
pub struct Pair {
    pub sha: String,
    pub host: String,
    pub chg: Outcome,
    pub gate: Outcome,
    pub class: Class,
    pub mode: Option<String>,
    pub selected: Option<usize>,
    pub chg_ms: u64,
    pub gate_ms: u64,
    /// For a miss: the gate's failures that chg did select (it ran them and they passed,
    /// so likely a flake), and those it did not (a real miss).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub failing_selected: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub failing_unselected: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Criterion {
    pub name: String,
    pub want: String,
    pub got: String,
    pub met: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct Report {
    pub repo: String,
    pub pushes: usize,
    pub machines: Vec<String>,
    pub agree: usize,
    pub misses: usize,
    pub chg_red: usize,
    pub gate_flaky: usize,
    /// chg rows with a verdict but no gate verdict for their commit yet.
    pub unpaired: usize,
    pub skipped: usize,
    pub errors: usize,
    pub median_chg_ms: Option<u64>,
    pub median_gate_ms: Option<u64>,
    pub median_saved_ms: Option<i64>,
    pub total_saved_ms: i64,
    pub disagreements: Vec<Pair>,
    pub criteria: Vec<Criterion>,
    pub ready: bool,
}

fn median(mut v: Vec<i64>) -> Option<i64> {
    if v.is_empty() {
        return None;
    }
    v.sort();
    let n = v.len();
    if n % 2 == 1 {
        return Some(v[n / 2]);
    }
    // The mean of the two middle values, rounded up: the 3-minute criterion must not
    // pass on the faster half of an even sample.
    let (a, b) = (v[n / 2 - 1], v[n / 2]);
    Some(a + (b - a + 1) / 2)
}

fn median_ms(ms: impl Iterator<Item = u64>) -> Option<u64> {
    median(ms.map(|m| m as i64).collect()).map(|m| m as u64)
}

/// Removes exact duplicates, which appear when the same log is read twice (the local
/// file and an `--hosts` entry for this machine).
pub fn dedup(rows: Vec<Row>) -> Vec<Row> {
    let mut seen = BTreeSet::new();
    rows.into_iter()
        .filter(|r| seen.insert(serde_json::to_string(r).expect("rows serialize")))
        .collect()
}

pub fn report(repo: &str, rows: &[Row]) -> Report {
    let mut gates: BTreeMap<&str, Vec<&Row>> = BTreeMap::new();
    for r in rows.iter().filter(|r| r.kind == "gate" && r.repo == repo) {
        if matches!(r.verdict, Outcome::Pass | Outcome::Fail) {
            gates.entry(r.sha.as_str()).or_default().push(r);
        }
    }
    let chg: Vec<&Row> = rows
        .iter()
        .filter(|r| r.kind == "chg" && r.repo == repo)
        .collect();

    let mut pairs = Vec::new();
    let (mut unpaired, mut skipped, mut errors) = (0, 0, 0);
    for c in &chg {
        match c.verdict {
            Outcome::Skipped => {
                skipped += 1;
                continue;
            }
            Outcome::Error => {
                errors += 1;
                continue;
            }
            Outcome::Pass | Outcome::Fail => {}
        }
        let Some(g) = gates.get(c.sha.as_str()) else {
            unpaired += 1;
            continue;
        };
        let verdicts: BTreeSet<&str> = g.iter().map(|r| r.verdict.as_str()).collect();
        let latest = g.iter().max_by_key(|r| r.at_ms).expect("non-empty");
        let class = if verdicts.len() > 1 {
            Class::GateFlaky
        } else if c.verdict == latest.verdict {
            Class::Agree
        } else if c.verdict == Outcome::Pass {
            Class::Miss
        } else {
            Class::ChgRed
        };
        let selected: Option<BTreeSet<&str>> = c
            .selected
            .as_ref()
            .map(|s| s.iter().map(String::as_str).collect());
        let (mut failing_selected, mut failing_unselected) = (vec![], vec![]);
        if class == Class::Miss {
            for f in g.iter().flat_map(|r| r.failures.iter()) {
                let file = f.split(':').next().unwrap_or(f);
                let ran = c.mode.as_deref() == Some("all")
                    || selected.as_ref().is_some_and(|s| s.contains(file));
                if ran {
                    failing_selected.push(f.clone());
                } else {
                    failing_unselected.push(f.clone());
                }
            }
        }
        pairs.push(Pair {
            sha: c.sha.clone(),
            host: c.host.clone(),
            chg: c.verdict,
            gate: latest.verdict,
            class,
            mode: c.mode.clone(),
            selected: c.selected.as_ref().map(Vec::len),
            chg_ms: c.ms,
            gate_ms: latest.ms,
            failing_selected,
            failing_unselected,
        });
    }

    let count = |k: Class| pairs.iter().filter(|p| p.class == k).count();
    let machines: Vec<String> = pairs
        .iter()
        .map(|p| p.host.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let median_chg_ms = median_ms(pairs.iter().map(|p| p.chg_ms));
    let timed: Vec<&Pair> = pairs.iter().filter(|p| p.gate_ms > 0).collect();
    let median_gate_ms = median_ms(timed.iter().map(|p| p.gate_ms));
    let saved: Vec<i64> = timed
        .iter()
        .map(|p| p.gate_ms as i64 - p.chg_ms as i64)
        .collect();
    let misses = count(Class::Miss);

    let criteria = vec![
        Criterion {
            name: "shadow pushes with both verdicts".into(),
            want: format!(">= {MIN_PUSHES}"),
            got: pairs.len().to_string(),
            met: pairs.len() >= MIN_PUSHES,
        },
        Criterion {
            name: "machines".into(),
            want: format!(">= {MIN_MACHINES}"),
            got: machines.len().to_string(),
            met: machines.len() >= MIN_MACHINES,
        },
        Criterion {
            name: "chg green while the gate is red".into(),
            want: "0".into(),
            got: misses.to_string(),
            met: misses == 0,
        },
        Criterion {
            name: "median chg check time".into(),
            want: format!("<= {}", fmt_ms(MAX_MEDIAN_MS)),
            got: median_chg_ms.map(fmt_ms).unwrap_or_else(|| "-".into()),
            met: median_chg_ms.is_some_and(|m| m <= MAX_MEDIAN_MS),
        },
    ];
    let ready = criteria.iter().all(|c| c.met);

    Report {
        repo: repo.into(),
        pushes: pairs.len(),
        machines,
        agree: count(Class::Agree),
        misses,
        chg_red: count(Class::ChgRed),
        gate_flaky: count(Class::GateFlaky),
        unpaired,
        skipped,
        errors,
        median_chg_ms,
        median_gate_ms,
        median_saved_ms: median(saved.clone()),
        total_saved_ms: saved.iter().sum(),
        disagreements: pairs
            .into_iter()
            .filter(|p| p.class != Class::Agree)
            .collect(),
        criteria,
        ready,
    }
}

pub fn fmt_ms(ms: u64) -> String {
    let s = ms / 1000;
    if s >= 60 {
        format!("{}m{:02}s", s / 60, s % 60)
    } else {
        format!("{}.{}s", s, (ms % 1000) / 100)
    }
}

fn fmt_signed(ms: i64) -> String {
    if ms < 0 {
        format!("-{}", fmt_ms(ms.unsigned_abs()))
    } else {
        fmt_ms(ms as u64)
    }
}

impl Report {
    pub fn render(&self) -> String {
        let mut o = String::new();
        let line = |o: &mut String, s: String| {
            o.push_str(&s);
            o.push('\n');
        };
        line(&mut o, format!("chg shadow report: {}", self.repo));
        line(
            &mut o,
            format!(
                "pushes {} on {} machine(s) [{}]: agree {}, chg green/gate red {}, chg red/gate green {}, gate flaky {}",
                self.pushes,
                self.machines.len(),
                self.machines.join(", "),
                self.agree,
                self.misses,
                self.chg_red,
                self.gate_flaky
            ),
        );
        line(
            &mut o,
            format!(
                "not counted: {} awaiting a gate verdict, {} skipped, {} errored",
                self.unpaired, self.skipped, self.errors
            ),
        );
        let opt = |m: Option<u64>| m.map(fmt_ms).unwrap_or_else(|| "-".into());
        line(
            &mut o,
            format!(
                "time: median chg {}, median gate {}, median saved {}, total saved {}",
                opt(self.median_chg_ms),
                opt(self.median_gate_ms),
                self.median_saved_ms
                    .map(fmt_signed)
                    .unwrap_or_else(|| "-".into()),
                fmt_signed(self.total_saved_ms)
            ),
        );
        if !self.disagreements.is_empty() {
            line(&mut o, String::new());
            line(
                &mut o,
                format!(
                    "{:<12}  {:<14}  {:<4}  {:<4}  {:<10}  {:>9}  {:>8}  {:>8}",
                    "sha", "host", "chg", "gate", "class", "selected", "chg", "gate"
                ),
            );
            for p in &self.disagreements {
                let sel = match (&p.mode, p.selected) {
                    (Some(m), _) if m == "all" => "all".to_string(),
                    (_, Some(n)) => n.to_string(),
                    _ => "-".into(),
                };
                let class = match p.class {
                    Class::Agree => "agree",
                    Class::Miss => "MISS",
                    Class::ChgRed => "chg-red",
                    Class::GateFlaky => "gate-flaky",
                };
                line(
                    &mut o,
                    format!(
                        "{:<12}  {:<14}  {:<4}  {:<4}  {:<10}  {:>9}  {:>8}  {:>8}",
                        &p.sha[..p.sha.len().min(12)],
                        p.host,
                        p.chg.as_str(),
                        p.gate.as_str(),
                        class,
                        sel,
                        fmt_ms(p.chg_ms),
                        fmt_ms(p.gate_ms)
                    ),
                );
                for f in &p.failing_unselected {
                    line(&mut o, format!("    not selected, failed in the gate: {f}"));
                }
                for f in &p.failing_selected {
                    line(
                        &mut o,
                        format!("    selected and passed in chg, failed in the gate: {f}"),
                    );
                }
            }
        }
        line(&mut o, String::new());
        line(&mut o, "cutover criteria (issue #18):".into());
        for c in &self.criteria {
            line(
                &mut o,
                format!(
                    "  [{}] {}: {} (want {})",
                    if c.met { "x" } else { " " },
                    c.name,
                    c.got,
                    c.want
                ),
            );
        }
        line(
            &mut o,
            if self.ready {
                "ready to cut over".into()
            } else {
                "not ready to cut over".into()
            },
        );
        o
    }
}

/// Reads another machine's log over ssh. `None` (with a warning) when unreachable.
pub fn fetch_remote(host: &str, key: &str) -> Option<String> {
    let remote =
        format!("cat \"${{CHG_HOME:-$HOME/.chg}}/shadow/{key}.jsonl\" 2>/dev/null || true");
    let out = Command::new("ssh")
        .args([
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=5",
            host,
            &remote,
        ])
        .stdin(Stdio::null())
        .output();
    match out {
        Ok(o) if o.status.success() => Some(String::from_utf8_lossy(&o.stdout).into_owned()),
        Ok(o) => {
            eprintln!(
                "chg: {host}: ssh failed ({}); its pushes are not in this report",
                String::from_utf8_lossy(&o.stderr).trim()
            );
            None
        }
        Err(e) => {
            eprintln!("chg: {host}: cannot run ssh ({e}); its pushes are not in this report");
            None
        }
    }
}

/// How long after its last CI verdict a commit is still asked about: a rerun inside this
/// window (a flake retried) adds a second verdict, and the pair makes it gate-flaky.
pub const CI_RECHECK: Duration = Duration::from_secs(72 * 3600);

/// For every chg row whose commit no local gate judged, reads GitHub check run `check`
/// on that commit. Each completed run not recorded yet becomes a `gate` row (source `ci`,
/// at its completion time), appended to `log`. A commit whose newest CI verdict is older
/// than `CI_RECHECK` is not asked again.
pub fn resolve_ci(repo: &Path, key: &str, rows: &[Row], check: &str, log: &Path) -> Vec<Row> {
    let Some(slug) = git::origin_slug(repo) else {
        eprintln!("chg: no origin remote to read check runs from; --ci-check ignored");
        return vec![];
    };
    let recorded = ci_recorded(rows);
    let mut added = Vec::new();
    for sha in ci_wanted(key, rows, now_ms()) {
        // -X GET -f puts the fields in the query string, encoded: a check name may hold
        // spaces, `&` or `#`.
        let out = Command::new("gh")
            .args(["api", "-X", "GET"])
            .arg(format!("repos/{slug}/commits/{sha}/check-runs"))
            .args(["-f", &format!("check_name={check}"), "-f", "per_page=100"])
            .args([
                "--jq",
                "[.check_runs[] | {status, conclusion, started_at, completed_at}]",
            ])
            .stdin(Stdio::null())
            .output();
        let runs: Vec<serde_json::Value> = match out {
            Ok(o) if o.status.success() => serde_json::from_slice(&o.stdout).unwrap_or_default(),
            Ok(o) => {
                eprintln!(
                    "chg: gh api for {sha}: {}",
                    String::from_utf8_lossy(&o.stderr).trim()
                );
                continue;
            }
            Err(e) => {
                eprintln!("chg: cannot run gh ({e}); --ci-check stopped");
                break;
            }
        };
        for row in ci_rows(key, sha, check, &runs) {
            if recorded.contains(&(sha, row.at_ms)) {
                continue;
            }
            if let Err(e) = append(log, &row) {
                eprintln!("chg: {e}");
            }
            added.push(row);
        }
    }
    added
}

/// The (sha, completion time) of every CI verdict already recorded.
fn ci_recorded(rows: &[Row]) -> BTreeSet<(&str, u64)> {
    rows.iter()
        .filter(|r| r.kind == "gate" && r.source.as_deref() == Some("ci"))
        .map(|r| (r.sha.as_str(), r.at_ms))
        .collect()
}

/// The commits to ask CI about at `now`: judged by chg, not by a local gate, and either
/// without a CI verdict or with one younger than `CI_RECHECK`.
fn ci_wanted<'a>(key: &str, rows: &'a [Row], now: u64) -> BTreeSet<&'a str> {
    let judged_locally: BTreeSet<&str> = rows
        .iter()
        .filter(|r| r.kind == "gate" && r.source.as_deref() != Some("ci"))
        .filter(|r| matches!(r.verdict, Outcome::Pass | Outcome::Fail))
        .map(|r| r.sha.as_str())
        .collect();
    let recorded = ci_recorded(rows);
    let stale_before = now.saturating_sub(CI_RECHECK.as_millis() as u64);
    let settled = |sha: &str| {
        recorded
            .iter()
            .filter(|(s, _)| *s == sha)
            .map(|(_, at)| *at)
            .max()
            .is_some_and(|at| at < stale_before)
    };
    rows.iter()
        .filter(|r| r.kind == "chg" && r.repo == key)
        .filter(|r| matches!(r.verdict, Outcome::Pass | Outcome::Fail))
        .map(|r| r.sha.as_str())
        .filter(|sha| !judged_locally.contains(sha) && !settled(sha))
        .collect()
}

/// The gate rows for one commit's check runs named `check`: one per completed run that
/// passed or failed, at its completion time, so a rerun's verdict sits beside the
/// first. Cancelled, skipped or still-running runs give no verdict.
pub fn ci_rows(key: &str, sha: &str, check: &str, runs: &[serde_json::Value]) -> Vec<Row> {
    runs.iter()
        .filter(|r| r["status"] == "completed")
        .filter_map(|r| {
            let verdict = match r["conclusion"].as_str()? {
                "success" => Outcome::Pass,
                "failure" | "timed_out" => Outcome::Fail,
                _ => return None,
            };
            let done = parse_rfc3339_s(r["completed_at"].as_str().unwrap_or(""))?;
            let ms = match parse_rfc3339_s(r["started_at"].as_str().unwrap_or("")) {
                Some(a) if done >= a => (done - a) * 1000,
                _ => 0,
            };
            Some(Row {
                at_ms: done * 1000,
                ..Row::gate(key, sha, verdict, ms, check, "ci", vec![])
            })
        })
        .collect()
}

/// Seconds since the epoch for GitHub's `YYYY-MM-DDTHH:MM:SSZ`.
fn parse_rfc3339_s(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[10] != b'T' {
        return None;
    }
    let n = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, m, d) = (n(0..4)?, n(5..7)?, n(8..10)?);
    let (hh, mm, ss) = (n(11..13)?, n(14..16)?, n(17..19)?);
    // Days from civil (Howard Hinnant's algorithm).
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    u64::try_from(days * 86400 + hh * 3600 + mm * 60 + ss).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chg(sha: &str, host: &str, v: Outcome, ms: u64, selected: &[&str]) -> Row {
        Row {
            host: host.into(),
            ms,
            mode: Some("subset".into()),
            selected: Some(selected.iter().map(|s| s.to_string()).collect()),
            ..Row::new("chg", "r", sha, v)
        }
    }

    fn gate(sha: &str, v: Outcome, ms: u64, failures: &[&str]) -> Row {
        Row::gate(
            "r",
            sha,
            v,
            ms,
            "mix precommit",
            "local",
            failures.iter().map(|s| s.to_string()).collect(),
        )
    }

    #[test]
    fn classifies_every_disagreement() {
        let rows = vec![
            chg("a", "m1", Outcome::Pass, 60_000, &["test/a_test.exs"]),
            gate("a", Outcome::Pass, 500_000, &[]),
            chg("b", "m2", Outcome::Pass, 60_000, &["test/a_test.exs"]),
            gate(
                "b",
                Outcome::Fail,
                500_000,
                &["test/a_test.exs:3", "test/z_test.exs:9"],
            ),
            chg("c", "m3", Outcome::Fail, 60_000, &[]),
            gate("c", Outcome::Pass, 500_000, &[]),
            chg("d", "m1", Outcome::Pass, 60_000, &[]),
            gate("d", Outcome::Fail, 500_000, &[]),
            gate("d", Outcome::Pass, 500_000, &[]),
            chg("e", "m1", Outcome::Pass, 60_000, &[]),
            Row::from_check("r", "f", "base", 0, Verdict::skipped("no snapshot")),
        ];
        let r = report("r", &rows);
        assert_eq!(
            (r.pushes, r.agree, r.misses, r.chg_red, r.gate_flaky),
            (4, 1, 1, 1, 1)
        );
        assert_eq!((r.unpaired, r.skipped, r.errors), (1, 1, 0));
        assert_eq!(r.machines, vec!["m1", "m2", "m3"]);
        let miss = r
            .disagreements
            .iter()
            .find(|p| p.class == Class::Miss)
            .unwrap();
        assert_eq!(miss.failing_selected, vec!["test/a_test.exs:3"]);
        assert_eq!(miss.failing_unselected, vec!["test/z_test.exs:9"]);
        assert_eq!(r.median_saved_ms, Some(440_000));
        assert!(!r.ready);
        let text = r.render();
        assert!(text.contains("MISS"), "{text}");
        assert!(text.contains("not selected, failed in the gate: test/z_test.exs:9"));
        assert!(text.contains("not ready to cut over"));
    }

    #[test]
    fn ready_needs_every_criterion() {
        let mut rows = Vec::new();
        for i in 0..MIN_PUSHES {
            let sha = format!("{i:040}");
            rows.push(chg(
                &sha,
                ["m1", "m2", "m3"][i % 3],
                Outcome::Pass,
                90_000,
                &[],
            ));
            rows.push(gate(&sha, Outcome::Pass, 540_000, &[]));
        }
        let r = report("r", &rows);
        assert!(r.ready, "{}", r.render());

        // One miss blocks it.
        let mut with_miss = rows.clone();
        with_miss.push(chg("x", "m1", Outcome::Pass, 1, &[]));
        with_miss.push(gate("x", Outcome::Fail, 1, &[]));
        assert!(!report("r", &with_miss).ready);

        // Two machines block it.
        let two: Vec<Row> = rows
            .iter()
            .cloned()
            .map(|mut r| {
                if r.host == "m3" {
                    r.host = "m1".into();
                }
                r
            })
            .collect();
        assert!(!report("r", &two).ready);

        // A slow median blocks it.
        let slow: Vec<Row> = rows
            .iter()
            .cloned()
            .map(|mut r| {
                if r.kind == "chg" {
                    r.ms = MAX_MEDIAN_MS + 1;
                }
                r
            })
            .collect();
        assert!(!report("r", &slow).ready);
    }

    #[test]
    fn rows_round_trip_and_bad_lines_are_counted() {
        let row = chg("a", "m1", Outcome::Pass, 5, &["t.exs"]);
        let text = format!(
            "{}\n{{\"torn\n\n{}\n",
            serde_json::to_string(&row).unwrap(),
            serde_json::to_string(&gate("a", Outcome::Fail, 1, &[])).unwrap()
        );
        let (rows, bad) = parse(&text);
        assert_eq!((rows.len(), bad), (2, 1));
        assert_eq!(rows[0], row);
        assert_eq!(dedup(vec![row.clone(), row.clone()]).len(), 1);
    }

    #[test]
    fn ci_verdicts_keep_reruns_until_they_settle() {
        let runs: Vec<serde_json::Value> = serde_json::from_str(
            r#"[{"status":"completed","conclusion":"failure","started_at":"2026-10-16T10:00:00Z","completed_at":"2026-10-16T10:09:30Z"},
                {"status":"completed","conclusion":"success","started_at":"2026-10-16T11:00:00Z","completed_at":"2026-10-16T11:08:00Z"},
                {"status":"in_progress","conclusion":null,"started_at":"2026-10-16T12:00:00Z","completed_at":null}]"#,
        )
        .unwrap();
        // A failure and its passing rerun: both are kept, so the report sees gate-flaky.
        let r = ci_rows("r", "s", "Tests", &runs);
        let got: Vec<_> = r.iter().map(|r| (r.verdict, r.ms, r.at_ms)).collect();
        assert_eq!(
            got,
            vec![
                (Outcome::Fail, 570_000, 1_792_145_370_000),
                (Outcome::Pass, 480_000, 1_792_148_880_000)
            ]
        );
        assert!(r.iter().all(|r| r.source.as_deref() == Some("ci")));
        let rows = [r, vec![chg("s", "h", Outcome::Pass, 1_000, &[])]].concat();
        assert_eq!(report("r", &rows).gate_flaky, 1);
        // Asked again while the newest CI verdict is recent; settled after CI_RECHECK; never
        // when a local gate judged the commit.
        let newest = 1_792_148_880_000;
        assert!(ci_wanted("r", &rows, newest + 3_600_000).contains("s"));
        let later = newest + CI_RECHECK.as_millis() as u64 + 1;
        assert!(ci_wanted("r", &rows, later).is_empty());
        let local = [rows.clone(), vec![gate("s", Outcome::Pass, 1, &[])]].concat();
        assert!(ci_wanted("r", &local, newest).is_empty());
        let cancelled: Vec<serde_json::Value> =
            serde_json::from_str(r#"[{"status":"completed","conclusion":"cancelled"}]"#).unwrap();
        assert!(ci_rows("r", "s", "Tests", &cancelled).is_empty());
        assert_eq!(parse_rfc3339_s("1970-01-01T00:01:00Z"), Some(60));
        assert_eq!(parse_rfc3339_s("2026-10-16T00:00:00Z"), Some(1_792_108_800));
    }

    #[test]
    fn median_of_an_even_sample_is_the_mean_of_the_middle_two_rounded_up() {
        assert_eq!(median(vec![1, 4]), Some(3));
        assert_eq!(
            median_ms([170_000, 1, 190_000, 999_999].into_iter()),
            Some(180_000)
        );
        assert_eq!(median(vec![5, 1, 3]), Some(3));
        assert_eq!(median(vec![-4, -1]), Some(-2));
        assert_eq!(median(vec![]), None);
    }

    #[test]
    fn formats_durations() {
        assert_eq!(fmt_ms(180_000), "3m00s");
        assert_eq!(fmt_ms(4_250), "4.2s");
        assert_eq!(fmt_signed(-61_000), "-1m01s");
    }
}
