//! The fleet outbox (design §5, loopctl Epic 50): every machine delivers its ledger rows and
//! its change events to loopctl, which hosts the ledger. There is no chg-server.
//!
//! - **Off the push path.** Writers only append to local files. `kick` starts a detached
//!   `chg outbox send`, and a cron line runs the same command, so loopctl being slow or down
//!   costs freshness and never a push.
//! - **The queue is the files.** A ledger source is an append-only JSON-lines file: the shadow
//!   log `~/.chg/shadow/<key>.jsonl`, and `~/.chg/outbox/<key>.<kind>.jsonl` for rows chg
//!   derives (review rounds, flaky tests). The sender keeps one byte offset per file, past the
//!   last line loopctl answered for. A first send from offset 0 is the backfill.
//! - **Bounded.** One send reads at most `MAX_BATCHES` batches of `MAX_ROWS` rows and
//!   `MAX_BODY` bytes per file. What is left waits for the next run; `status` and `chg doctor`
//!   report its depth and oldest age.
//! - **At least once, idempotent.** loopctl keys a row on `(source, host, sha256 of the row)`,
//!   so a resend after a crash between the answer and the saved offset counts as duplicates.
//!   A failure backs off per repo: 30 s doubling to an hour.
//!
//! Every request is signed as loopctl's `Loopctl.Changes.Signature` judges it:
//! `X-Chg-Signature: sha256=<hex HMAC-SHA256>` over `"<ts>.<raw body>"` (POST) or
//! `"<ts>.GET.<path>?<query>"` (GET), keyed by the source's `change_events_secret`. HTTP goes
//! through `curl`; the secret never leaves this process.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::Sha256;

use crate::{events, gh, git, shadow};

/// loopctl's own cap is 500 rows (`Ledger.max_batch`).
pub const MAX_ROWS: usize = 500;
/// loopctl refuses a body over 1 MiB (`Ledger.max_body_bytes`); stay well under it.
pub const MAX_BODY: usize = 900_000;
/// Batches per file per run; the rest waits for the next run.
pub const MAX_BATCHES: usize = 40;
/// loopctl's `Loopctl.Changes.Ledger` `@max_row_bytes`: one row, canonically encoded.
pub const MAX_ROW_BYTES: usize = 16_384;
/// loopctl's `Loopctl.Changes.Findings` `@max_failure_names`.
pub const MAX_FAILURE_NAMES: usize = 50;
/// loopctl's `Loopctl.Changes.Findings` `@evidence_value_chars`.
const MAX_FAILURE_CHARS: usize = 200;
/// A row unsent for longer than this fails `chg doctor`.
pub const STALE_MS: u64 = 24 * 3600 * 1000;
const BACKOFF_BASE_MS: u64 = 30_000;
const BACKOFF_MAX_MS: u64 = 3_600_000;
const LOG_CAP: u64 = 1 << 20;
const REJECTED_CAP: u64 = 10 << 20;
pub const DEFAULT_URL: &str = "https://loopctl.com";

/// `~/.chg/loopctl.toml`.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default, rename = "source")]
    pub sources: Vec<Source>,
}

/// One enrolled `:chg` intake source: the repository it speaks for, its id, and the file
/// holding its `change_events_secret` (mode 0600).
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Source {
    /// `owner/name`, as loopctl's source names it.
    pub repo: String,
    pub source_id: String,
    pub secret_file: PathBuf,
}

impl Source {
    /// The key the repo's local files are named by (`git::repo_key`).
    pub fn key(&self) -> String {
        Self::key_of_repo(&self.repo)
    }

    /// The local key of `owner/name`.
    pub fn key_of_repo(repo: &str) -> String {
        git::key_of(repo.rsplit('/').next().unwrap_or(repo))
    }
}

impl Config {
    pub fn url(&self) -> String {
        std::env::var("CHG_LOOPCTL_URL")
            .ok()
            .filter(|u| !u.is_empty())
            .or_else(|| self.url.clone())
            .unwrap_or_else(|| DEFAULT_URL.into())
            .trim_end_matches('/')
            .to_string()
    }

    /// The source for `repo` (`owner/name`, any case).
    pub fn source(&self, repo: &str) -> Option<&Source> {
        self.sources
            .iter()
            .find(|s| s.repo.eq_ignore_ascii_case(repo))
    }
}

pub fn config_path() -> PathBuf {
    shadow::home().join("loopctl.toml")
}

pub fn dir() -> PathBuf {
    shadow::home().join("outbox")
}

/// The configuration, or `None` when this machine has none (nothing is sent).
pub fn load() -> Result<Option<Config>, String> {
    let path = config_path();
    let text = match fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("reading {}: {e}", path.display())),
    };
    let cfg: Config =
        toml::from_str(&text).map_err(|e| format!("parsing {}: {e}", path.display()))?;
    for s in &cfg.sources {
        if git::slug_of(&s.repo).as_deref() != Some(s.repo.as_str()) || s.repo.contains(':') {
            return Err(format!(
                "{}: repo {:?} is not owner/name",
                path.display(),
                s.repo
            ));
        }
        if s.source_id.is_empty()
            || !s
                .source_id
                .chars()
                .all(|c| c.is_ascii_hexdigit() || c == '-')
        {
            return Err(format!(
                "{}: source_id {:?} is not a UUID",
                path.display(),
                s.source_id
            ));
        }
    }
    Ok(Some(cfg))
}

/// The source's secret. Refused when the file is readable by anyone but its owner.
pub fn read_secret(src: &Source) -> Result<Vec<u8>, String> {
    let p = &src.secret_file;
    let meta = fs::metadata(p).map_err(|e| format!("secret file {}: {e}", p.display()))?;
    if meta.permissions().mode() & 0o077 != 0 {
        return Err(format!(
            "secret file {} is readable by others: chmod 600 it",
            p.display()
        ));
    }
    let text = fs::read_to_string(p).map_err(|e| format!("reading {}: {e}", p.display()))?;
    let secret = text.trim();
    if secret.is_empty() {
        return Err(format!("secret file {} is empty", p.display()));
    }
    Ok(secret.as_bytes().to_vec())
}

/// Lowercase hex HMAC-SHA256 of `signed` under `secret`.
pub fn sign(secret: &[u8], signed: &[u8]) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret).expect("HMAC takes any key length");
    mac.update(signed);
    mac.finalize()
        .into_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// An HTTP answer: status and body.
#[derive(Debug)]
pub struct Reply {
    pub status: u16,
    pub body: String,
}

impl Reply {
    pub fn json(&self) -> Value {
        serde_json::from_str(&self.body).unwrap_or(Value::Null)
    }

    /// `error.code` of a loopctl error body.
    pub fn code(&self) -> String {
        self.json()["error"]["code"]
            .as_str()
            .unwrap_or("")
            .to_string()
    }

    fn brief(&self) -> String {
        let b: String = self.body.chars().take(300).collect();
        format!("HTTP {} {}", self.status, b.trim())
    }
}

/// A signed POST of `body` to `<url><path>`.
pub fn post_signed(url: &str, path: &str, secret: &[u8], body: &[u8]) -> Result<Reply, String> {
    let ts = (now_ms() / 1000).to_string();
    let mut signed = Vec::with_capacity(ts.len() + 1 + body.len());
    signed.extend_from_slice(ts.as_bytes());
    signed.push(b'.');
    signed.extend_from_slice(body);
    curl(
        "POST",
        &format!("{url}{path}"),
        &ts,
        &sign(secret, &signed),
        Some(body),
    )
}

/// A signed GET of `<url><path>?<query>`. `query` must already be in its sent form.
pub fn get_signed(url: &str, path: &str, query: &str, secret: &[u8]) -> Result<Reply, String> {
    let ts = (now_ms() / 1000).to_string();
    let signed = format!("{ts}.GET.{path}?{query}");
    curl(
        "GET",
        &format!("{url}{path}?{query}"),
        &ts,
        &sign(secret, signed.as_bytes()),
        None,
    )
}

fn curl(
    method: &str,
    url: &str,
    ts: &str,
    sig: &str,
    body: Option<&[u8]>,
) -> Result<Reply, String> {
    let mut c = Command::new("curl");
    c.args([
        "-sS",
        "--max-time",
        "30",
        "--connect-timeout",
        "10",
        "-X",
        method,
        "-H",
        "Accept: application/json",
        "-H",
        &format!("X-Chg-Timestamp: {ts}"),
        "-H",
        &format!("X-Chg-Signature: sha256={sig}"),
        "-w",
        "\n%{http_code}",
    ]);
    if body.is_some() {
        c.args([
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            "@-",
        ]);
    }
    c.arg("--").arg(url);
    c.stdin(if body.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    })
    .stdout(Stdio::piped())
    .stderr(Stdio::piped());
    let mut child = c.spawn().map_err(|e| format!("starting curl: {e}"))?;
    if let Some(b) = body {
        let mut stdin = child.stdin.take().expect("piped stdin");
        // A curl that dies early closes the pipe; its exit status says why.
        let _ = stdin.write_all(b);
    }
    let out = child
        .wait_with_output()
        .map_err(|e| format!("waiting for curl: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "curl {method} {url}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let (body, code) = text.rsplit_once('\n').unwrap_or(("", &text));
    let status = code
        .trim()
        .parse()
        .map_err(|_| format!("curl {method} {url}: no status in its output"))?;
    Ok(Reply {
        status,
        body: body.to_string(),
    })
}

/// A POST of `body` to `<url><path>` with `Authorization: Bearer <key>`. The key goes to
/// curl as a config line on stdin, never on its command line, where `ps` would show it.
pub fn post_bearer(url: &str, path: &str, key: &str, body: &[u8]) -> Result<Reply, String> {
    if key.is_empty() || key.contains(['"', '\\', '\n', '\r']) {
        return Err("the review key is not a bearer token".to_string());
    }
    let target = format!("{url}{path}");
    let mut c = Command::new("curl");
    c.args([
        "-sS",
        "--max-time",
        "30",
        "--connect-timeout",
        "10",
        "-X",
        "POST",
        "-K",
        "-",
        "-H",
        "Accept: application/json",
        "-H",
        "Content-Type: application/json",
        "-w",
        "\n%{http_code}",
        "--data-binary",
    ])
    .arg(String::from_utf8_lossy(body).as_ref())
    .arg("--")
    .arg(&target)
    .stdin(Stdio::piped())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped());
    let mut child = c.spawn().map_err(|e| format!("starting curl: {e}"))?;
    {
        let mut stdin = child.stdin.take().expect("piped stdin");
        let _ = stdin.write_all(format!("header = \"Authorization: Bearer {key}\"\n").as_bytes());
    }
    let out = child
        .wait_with_output()
        .map_err(|e| format!("waiting for curl: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "curl POST {target}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let (body, code) = text.rsplit_once('\n').unwrap_or(("", &text));
    let status = code
        .trim()
        .parse()
        .map_err(|_| format!("curl POST {target}: no status in its output"))?;
    Ok(Reply {
        status,
        body: body.to_string(),
    })
}

// ---------------------------------------------------------------------------------------
// State: one byte offset per ledger file, and one backoff per repo.

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct State {
    #[serde(default)]
    pub files: BTreeMap<String, u64>,
    #[serde(default)]
    pub backoff: BTreeMap<String, Backoff>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Backoff {
    pub failures: u32,
    pub next_at_ms: u64,
    pub last_error: String,
}

fn state_path() -> PathBuf {
    dir().join("state.json")
}

pub fn read_state() -> State {
    fs::read_to_string(state_path())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn write_state(state: &State) -> Result<(), String> {
    let path = state_path();
    let tmp = path.with_extension("json.tmp");
    let text = serde_json::to_string_pretty(state).expect("state serializes");
    fs::write(&tmp, text)
        .and_then(|_| fs::rename(&tmp, &path))
        .map_err(|e| format!("writing {}: {e}", path.display()))
}

fn record_failure(state: &mut State, repo: &str, error: &str) {
    let failures = state.backoff.get(repo).map_or(0, |b| b.failures) + 1;
    let delay = BACKOFF_BASE_MS
        .saturating_mul(1u64 << (failures - 1).min(20))
        .min(BACKOFF_MAX_MS);
    state.backoff.insert(
        repo.to_string(),
        Backoff {
            failures,
            next_at_ms: now_ms() + delay,
            last_error: error.chars().take(500).collect(),
        },
    );
}

// ---------------------------------------------------------------------------------------
// Ledger files.

/// The kinds chg writes to a derived ledger file of its own.
pub const DERIVED_KINDS: [&str; 2] = ["flaky", "review_round"];

/// `outbox/<key>.<kind>.jsonl`, the one name a derived ledger file has. Files are named
/// exactly, never matched by prefix: repo `foo`'s prefix `foo.` would also match repo
/// `foo.bar`'s files.
pub fn derived_path(key: &str, kind: &str) -> PathBuf {
    debug_assert!(DERIVED_KINDS.contains(&kind));
    dir().join(format!("{key}.{kind}.jsonl"))
}

/// The ledger files of `src` that exist: its shadow log and its derived files.
pub fn ledger_files(src: &Source) -> Vec<PathBuf> {
    let key = src.key();
    let mut files = vec![shadow::log_path(&key)];
    files.extend(DERIVED_KINDS.iter().map(|k| derived_path(&key, k)));
    files.retain(|p| p.is_file());
    files
}

/// One complete line after an offset, and the offset just past it.
struct Line {
    end: u64,
    text: String,
}

/// The complete lines of `path` from `offset`, at most `max` of them. A last line with no
/// newline is being written and is left for the next run.
fn lines_from(path: &Path, offset: u64, max: usize) -> Result<Vec<Line>, String> {
    let mut f = File::open(path).map_err(|e| format!("opening {}: {e}", path.display()))?;
    f.seek(SeekFrom::Start(offset))
        .map_err(|e| format!("seeking {}: {e}", path.display()))?;
    let mut r = BufReader::new(f);
    let mut out = Vec::new();
    let mut pos = offset;
    let mut buf = Vec::new();
    while out.len() < max {
        buf.clear();
        let n = r
            .read_until(b'\n', &mut buf)
            .map_err(|e| format!("reading {}: {e}", path.display()))?;
        if n == 0 || buf.last() != Some(&b'\n') {
            break;
        }
        pos += n as u64;
        out.push(Line {
            end: pos,
            text: String::from_utf8_lossy(&buf[..n - 1]).into_owned(),
        });
    }
    Ok(out)
}

/// The row a line becomes on the wire: its JSON object with `repo` set to the source's
/// `owner/name` (the shadow log names the repo by its key). Deterministic, so a resend
/// hashes the same.
///
/// A row over loopctl's `MAX_ROW_BYTES` is refused there as `invalid_row`. Two fields grow
/// that large, and the shadow log keeps both in full for `chg shadow report`:
/// - a `chg` row's `selected` test list (thousands of files), which loopctl does not read; on
///   the wire it becomes `selected_count`;
/// - then, if still too large, `failures` (a run where thousands of tests failed). The wire
///   keeps the names loopctl keeps (`Loopctl.Changes.Findings.failure_names/1`: a string or an
///   object's `id`, non-empty, at most 200 characters, unique, sorted, the first 50), plus
///   `failures_count` and `failures_sha256`, the sha256 of the full list in the form loopctl's
///   `failures_digest/1` hashes, so runs that differ only past the 50th stay distinguishable.
pub fn wire_row(line: &str, repo: &str) -> Option<Value> {
    let mut v: Value = serde_json::from_str(line.trim()).ok()?;
    v.as_object_mut()?
        .insert("repo".into(), Value::String(repo.to_string()));
    let too_big = |v: &Value| serde_json::to_vec(v).is_ok_and(|b| b.len() > MAX_ROW_BYTES);
    if too_big(&v) {
        let obj = v.as_object_mut()?;
        if let Some(n) = obj.get("selected").and_then(Value::as_array).map(Vec::len) {
            obj.remove("selected");
            obj.insert("selected_count".into(), Value::from(n));
        }
    }
    if too_big(&v) {
        let obj = v.as_object_mut()?;
        if let Some(Value::Array(all)) = obj.remove("failures") {
            let count = all.len();
            let digest = failures_sha256(&all);
            obj.insert("failures".into(), Value::from(failure_names(&all)));
            obj.insert("failures_count".into(), Value::from(count));
            obj.insert("failures_sha256".into(), Value::from(digest));
        }
    }
    Some(v)
}

/// What loopctl's `Findings.failure_names/1` keeps of a failures list.
fn failure_names(all: &[Value]) -> Vec<String> {
    let mut names: Vec<String> = all
        .iter()
        .filter_map(|f| match f {
            Value::String(s) => Some(s.as_str()),
            Value::Object(o) => o.get("id").and_then(Value::as_str),
            _ => None,
        })
        .filter(|s| !s.is_empty())
        .map(|s| s.chars().take(MAX_FAILURE_CHARS).collect())
        .collect();
    names.sort();
    names.dedup();
    names.truncate(MAX_FAILURE_NAMES);
    names
}

/// sha256 hex over the list as loopctl's `Findings.failures_digest/1` hashes it: each failure
/// JSON-encoded, sorted, joined by newlines.
fn failures_sha256(all: &[Value]) -> String {
    let mut encoded: Vec<String> = all.iter().map(Value::to_string).collect();
    encoded.sort();
    let digest = <Sha256 as sha2::Digest>::digest(encoded.join("\n").as_bytes());
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

fn reject_locally(src: &Source, file: &Path, reason: &str, row: &str) {
    let path = dir().join("rejected.jsonl");
    if fs::metadata(&path).is_ok_and(|m| m.len() > REJECTED_CAP) {
        let _ = fs::rename(&path, path.with_extension("jsonl.1"));
    }
    let line = json!({
        "at_ms": now_ms(),
        "repo": src.repo,
        "file": file.display().to_string(),
        "reason": reason,
        "row": row.chars().take(4000).collect::<String>(),
    });
    if let Ok(mut f) = File::options().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{line}");
    }
}

/// What one file's send did.
#[derive(Debug, Default, Clone, Serialize)]
pub struct Sent {
    pub inserted: u64,
    pub duplicates: u64,
    pub rejected: u64,
}

enum Failure {
    /// Configuration is wrong (401): retrying will not help until someone fixes it.
    Refused(String),
    /// Transient (network, 5xx, 429, busy).
    Retry(String),
}

impl Failure {
    fn text(&self) -> &str {
        match self {
            Failure::Refused(s) | Failure::Retry(s) => s,
        }
    }
}

const REFUSED: &str = "401 invalid_signature: check source_id and the secret in ~/.chg/loopctl.toml, \
                       that the source is enrolled in chg mode with a live chg root, and this \
                       machine's clock";

fn send_file(
    url: &str,
    src: &Source,
    secret: &[u8],
    file: &Path,
    state: &mut State,
    from_start: bool,
) -> Result<Sent, Failure> {
    let key = file.display().to_string();
    let len = fs::metadata(file).map(|m| m.len()).unwrap_or(0);
    let saved = state.files.get(&key).copied().unwrap_or(0);
    // `--from-start` replays from byte 0 but never saves below `mark`, the offset loopctl had
    // already answered for, so a replay cut short leaves no delivered row counted as unsent.
    let mark = if from_start && saved <= len { saved } else { 0 };
    let mut offset = saved;
    if offset > len || from_start {
        // Rewritten or truncated, or `--from-start`: send it again from the start; loopctl
        // drops duplicates.
        offset = 0;
    }
    let path = format!("/api/v1/chg_ledger/{}", src.source_id);
    let mut sent = Sent::default();
    let mut max_rows = MAX_ROWS;
    let mut batches = 0;
    // A from-start pass covers the whole file in one run; it is manual and one-off.
    while from_start || batches < MAX_BATCHES {
        let lines = lines_from(file, offset, max_rows).map_err(Failure::Retry)?;
        if lines.is_empty() {
            break;
        }
        // Lines in this batch, as (end offset, row text); the body stays under MAX_BODY.
        let mut rows: Vec<(u64, String, Value)> = Vec::new();
        let mut body_len = 10;
        let mut through = offset;
        for l in &lines {
            let Some(row) = wire_row(&l.text, &src.repo) else {
                if rows.is_empty() {
                    reject_locally(src, file, "unparseable", &l.text);
                    sent.rejected += 1;
                    through = l.end;
                    continue;
                }
                break;
            };
            let n = row.to_string().len() + 1;
            if n + 10 > MAX_BODY {
                if rows.is_empty() {
                    reject_locally(src, file, "too_large", &l.text);
                    sent.rejected += 1;
                    through = l.end;
                    continue;
                }
                break;
            }
            if body_len + n > MAX_BODY {
                break;
            }
            body_len += n;
            through = l.end;
            rows.push((l.end, l.text.clone(), row));
        }
        if rows.is_empty() {
            offset = through;
            state.files.insert(key.clone(), offset.max(mark));
            write_state(state).map_err(Failure::Retry)?;
            continue;
        }
        let body = json!({ "rows": rows.iter().map(|r| &r.2).collect::<Vec<_>>() }).to_string();
        let reply = post_signed(url, &path, secret, body.as_bytes()).map_err(Failure::Retry)?;
        match reply.status {
            200 => {
                let v = reply.json();
                sent.inserted += v["inserted"].as_u64().unwrap_or(0);
                sent.duplicates += v["duplicates"].as_u64().unwrap_or(0);
                for r in v["rejected"].as_array().into_iter().flatten() {
                    let i = r["index"].as_u64().unwrap_or(u64::MAX) as usize;
                    let reason = r["reason"].as_str().unwrap_or("rejected");
                    let text = rows.get(i).map_or("", |x| x.1.as_str());
                    reject_locally(src, file, reason, text);
                    sent.rejected += 1;
                }
                offset = through;
                max_rows = MAX_ROWS;
                batches += 1;
            }
            413 if rows.len() > 1 => {
                max_rows = (rows.len() / 2).max(1);
                continue;
            }
            413 => {
                reject_locally(src, file, "payload_too_large", &rows[0].1);
                sent.rejected += 1;
                offset = rows[0].0;
            }
            401 => return Err(Failure::Refused(REFUSED.into())),
            _ => return Err(Failure::Retry(reply.brief())),
        }
        state.files.insert(key.clone(), offset.max(mark));
        write_state(state).map_err(Failure::Retry)?;
    }
    Ok(sent)
}

// ---------------------------------------------------------------------------------------
// The send run.

/// One repo's part of a send.
#[derive(Debug, Default, Serialize)]
pub struct RepoSent {
    pub repo: String,
    pub sent: Sent,
    pub events: events::Delivered,
    /// Why this repo sent nothing, or stopped early.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub problem: Option<String>,
}

#[derive(Debug, Default, Serialize)]
pub struct Summary {
    /// Another send held the lock: this run did nothing.
    pub busy: bool,
    pub configured: bool,
    pub repos: Vec<RepoSent>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
}

/// Takes the sender's lock without waiting: `None` when another send holds it.
fn try_lock() -> Result<Option<File>, String> {
    fs::create_dir_all(dir()).map_err(|e| format!("creating {}: {e}", dir().display()))?;
    let path = dir().join("send.lock");
    let f = File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .map_err(|e| format!("opening {}: {e}", path.display()))?;
    // SAFETY: flock on an fd we own; released when `f` closes.
    if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        let e = std::io::Error::last_os_error();
        if e.raw_os_error() == Some(libc::EWOULDBLOCK) {
            return Ok(None);
        }
        return Err(format!("locking {}: {e}", path.display()));
    }
    Ok(Some(f))
}

/// Sends every configured repo's unsent ledger rows and pending change events. `force`
/// ignores the backoff.
/// `from_start` sends every file again from its first byte, once (after a sender fix, so the
/// rows loopctl refused before are offered again). loopctl counts the rest as duplicates.
pub fn send(force: bool, from_start: bool) -> Result<Summary, String> {
    let Some(cfg) = load()? else {
        return Ok(Summary::default());
    };
    let Some(_lock) = try_lock()? else {
        return Ok(Summary {
            busy: true,
            configured: true,
            ..Summary::default()
        });
    };
    let mut summary = Summary {
        configured: true,
        ..Summary::default()
    };
    match harvest_reviews(&cfg) {
        Ok(_) => {}
        Err(e) => summary.warnings.push(format!("review rounds: {e}")),
    }
    let url = cfg.url();
    let mut state = read_state();
    for src in &cfg.sources {
        let mut out = RepoSent {
            repo: src.repo.clone(),
            ..RepoSent::default()
        };
        if let Some(b) = state.backoff.get(&src.repo)
            && !force
            && now_ms() < b.next_at_ms
        {
            out.problem = Some(format!(
                "backing off until {} after {} failure(s): {}",
                rfc3339(b.next_at_ms),
                b.failures,
                b.last_error
            ));
            summary.repos.push(out);
            continue;
        }
        let secret = match read_secret(src) {
            Ok(s) => s,
            Err(e) => {
                out.problem = Some(e);
                summary.repos.push(out);
                continue;
            }
        };
        let mut failed: Option<Failure> = None;
        for file in ledger_files(src) {
            match send_file(&url, src, &secret, &file, &mut state, from_start) {
                Ok(s) => {
                    out.sent.inserted += s.inserted;
                    out.sent.duplicates += s.duplicates;
                    out.sent.rejected += s.rejected;
                }
                Err(f) => {
                    failed = Some(f);
                    break;
                }
            }
        }
        if failed.is_none() {
            match events::deliver_pending(&url, src, &secret) {
                Ok(d) => out.events = d,
                Err(e) => failed = Some(Failure::Retry(e)),
            }
        }
        match failed {
            None => {
                state.backoff.remove(&src.repo);
            }
            Some(f) => {
                record_failure(&mut state, &src.repo, f.text());
                out.problem = Some(f.text().to_string());
            }
        }
        write_state(&state)?;
        summary.repos.push(out);
    }
    Ok(summary)
}

/// Starts `chg outbox send` detached, when this machine is configured. Never fails the
/// caller: a writer's append is done whether or not the send starts.
pub fn kick() {
    if std::env::var_os("CHG_OUTBOX_NO_KICK").is_some() || !config_path().is_file() {
        return;
    }
    let _ = spawn_send();
}

fn spawn_send() -> Result<(), String> {
    fs::create_dir_all(dir()).map_err(|e| e.to_string())?;
    let log = dir().join("send.log");
    if fs::metadata(&log).is_ok_and(|m| m.len() > LOG_CAP) {
        let _ = fs::rename(&log, log.with_extension("log.1"));
    }
    let out = File::options()
        .create(true)
        .append(true)
        .open(&log)
        .map_err(|e| e.to_string())?;
    let err = out.try_clone().map_err(|e| e.to_string())?;
    let mut c = shadow::chg_command()?;
    c.args(["outbox", "send", "--quiet"])
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(out)
        .stderr(err);
    for v in git::HOOK_ENV {
        c.env_remove(v);
    }
    // SAFETY: setsid in the forked child before exec; it touches no shared state. A new
    // session keeps a ^C to the caller, or the caller's exit, from reaching the send.
    unsafe {
        c.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    c.spawn().map(|_| ()).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------------------
// Status.

/// One ledger file's unsent rows.
#[derive(Debug, Serialize)]
pub struct Depth {
    pub file: String,
    pub rows: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oldest_at_ms: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct RepoStatus {
    pub repo: String,
    pub files: Vec<Depth>,
    /// Changes with events loopctl has not acknowledged.
    pub pending_changes: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backoff: Option<Backoff>,
}

impl RepoStatus {
    pub fn rows(&self) -> u64 {
        self.files.iter().map(|d| d.rows).sum()
    }

    pub fn oldest_at_ms(&self) -> Option<u64> {
        self.files.iter().filter_map(|d| d.oldest_at_ms).min()
    }

    /// One line: depth, age, backoff.
    pub fn line(&self, now: u64) -> String {
        let mut s = format!(
            "{}: {} row(s) unsent, {} change(s) with undelivered events",
            self.repo,
            self.rows(),
            self.pending_changes
        );
        if let Some(at) = self.oldest_at_ms() {
            s.push_str(&format!(
                ", oldest {} old",
                shadow::fmt_ms(now.saturating_sub(at))
            ));
        }
        if let Some(b) = &self.backoff {
            s.push_str(&format!(
                "; {} failure(s), last: {}",
                b.failures, b.last_error
            ));
        }
        s
    }

    /// Whether this repo's outbox is healthy: nothing unsent older than `STALE_MS`.
    pub fn healthy(&self, now: u64) -> bool {
        self.oldest_at_ms()
            .is_none_or(|at| now.saturating_sub(at) <= STALE_MS)
    }
}

fn depth(file: &Path, offset: u64) -> Depth {
    let mut rows = 0;
    let mut oldest = None;
    let mut off = offset;
    if fs::metadata(file).is_ok_and(|m| m.len() < off) {
        off = 0;
    }
    while let Ok(lines) = lines_from(file, off, 10_000) {
        if lines.is_empty() {
            break;
        }
        for l in &lines {
            rows += 1;
            if oldest.is_none() {
                oldest = serde_json::from_str::<Value>(&l.text)
                    .ok()
                    .and_then(|v| v["at_ms"].as_u64());
            }
        }
        off = lines.last().map_or(off, |l| l.end);
    }
    Depth {
        file: file.display().to_string(),
        rows,
        oldest_at_ms: oldest,
    }
}

/// The outbox of every configured repo (empty when unconfigured).
pub fn status(cfg: &Config) -> Vec<RepoStatus> {
    let state = read_state();
    cfg.sources
        .iter()
        .map(|src| RepoStatus {
            repo: src.repo.clone(),
            files: ledger_files(src)
                .iter()
                .map(|f| {
                    depth(
                        f,
                        state
                            .files
                            .get(&f.display().to_string())
                            .copied()
                            .unwrap_or(0),
                    )
                })
                .collect(),
            pending_changes: events::pending(src).len(),
            backoff: state.backoff.get(&src.repo).cloned(),
        })
        .collect()
}

/// `chg doctor`'s outbox line for the repo at `repo`: `(ok, text)`.
pub fn doctor(repo: &Path) -> (bool, String) {
    let cfg = match load() {
        Ok(Some(c)) => c,
        Ok(None) => {
            return (
                true,
                format!(
                    "outbox: {} is absent, so nothing is sent to loopctl",
                    config_path().display()
                ),
            );
        }
        Err(e) => return (false, format!("outbox: {e}")),
    };
    let Some(slug) = git::origin_slug(repo) else {
        return (true, "outbox: the repo has no origin to name it".into());
    };
    let Some(src) = cfg.source(&slug) else {
        return (
            true,
            format!(
                "outbox: {slug} has no source in {}",
                config_path().display()
            ),
        );
    };
    if let Err(e) = read_secret(src) {
        return (false, format!("outbox: {e}"));
    }
    let now = now_ms();
    let one = Config {
        url: cfg.url.clone(),
        sources: vec![src.clone()],
    };
    let st = status(&one).pop().expect("one source");
    (st.healthy(now), format!("outbox: {}", st.line(now)))
}

// ---------------------------------------------------------------------------------------
// Review rounds, read from review-round-counter's store.

/// The review-round-counter store files: `CHG_RRC_STORE` when set, else every
/// `~/.claude/plugins/store/review-round-counter_*.json`.
fn rrc_stores() -> Vec<PathBuf> {
    if let Some(p) = std::env::var_os("CHG_RRC_STORE") {
        return vec![PathBuf::from(p)];
    }
    let Some(home) = std::env::var_os("HOME") else {
        return vec![];
    };
    let d = PathBuf::from(home).join(".claude/plugins/store");
    let mut out: Vec<PathBuf> = fs::read_dir(&d)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("review-round-counter_") && n.ends_with(".json"))
        })
        .collect();
    out.sort();
    out
}

/// `<common>:<branch>:<last>` split into its parts. The common dir is an absolute path and
/// a branch cannot contain `:`, so the first and last colons are the separators.
fn split_rec(rest: &str) -> Option<(&str, &str, &str)> {
    let (head, last) = rest.rsplit_once(':')?;
    let (common, branch) = head.split_once(':')?;
    (!common.is_empty() && !branch.is_empty() && !last.is_empty()).then_some((common, branch, last))
}

/// The ledger rows a store holds for `repos` (lowercase `owner/name` keyed by common dir):
/// a `review_round` row for every launch whose branch is linked to a PR, and a
/// `review_round_void` row for each of those later voided (a refund or an `uncount`).
/// `wanted` resolves a common dir to `owner/name`.
///
/// review-round-counter writes `rec:link` only when a round runs while the PR already
/// exists. The delivery loop reviews BEFORE `gh pr create`, so a usual PR's round has no
/// link. For a round with none, `ask(repo, branch, at_ms)` names the PRs whose head is that
/// branch. A round whose branch has no PR yet, by either route, waits for a later harvest.
pub fn review_rows(
    store: &Map<String, Value>,
    host: &str,
    wanted: &dyn Fn(&str) -> Option<String>,
    ask: &mut dyn FnMut(&str, &str, u64) -> Vec<u64>,
) -> Vec<Value> {
    let mut links: HashMap<(&str, &str), Vec<u64>> = HashMap::new();
    let mut voids: HashMap<(&str, &str, &str), &Value> = HashMap::new();
    for (k, v) in store {
        if let Some(rest) = k.strip_prefix("rec:link:") {
            if let Some((c, b, n)) = split_rec(rest)
                && let Ok(n) = n.parse::<u64>()
            {
                links.entry((c, b)).or_default().push(n);
            }
        } else if let Some(rest) = k.strip_prefix("rec:void:")
            && let Some((c, b, id)) = split_rec(rest)
        {
            voids.insert((c, b, id), v);
        }
    }
    let mut repo_of: HashMap<&str, Option<String>> = HashMap::new();
    // Newest first, so a limited `ask` spends itself on the rounds most likely to matter.
    let mut rounds: Vec<(&str, &str, &str, u64, &Value)> = store
        .iter()
        .filter_map(|(k, v)| {
            let (common, branch, id) = split_rec(k.strip_prefix("rec:round:")?)?;
            let at_ms = id.split('-').next()?.parse::<u64>().ok()?;
            Some((common, branch, id, at_ms, v))
        })
        .collect();
    rounds.sort_by_key(|r| std::cmp::Reverse(r.3));
    let mut rows = Vec::new();
    for (common, branch, id, at_ms, v) in rounds {
        let Some(repo) = repo_of
            .entry(common)
            .or_insert_with(|| wanted(common))
            .clone()
        else {
            continue;
        };
        let mut prs = match links.get(&(common, branch)) {
            Some(prs) => prs.clone(),
            None => ask(&repo, branch, at_ms),
        };
        if prs.is_empty() {
            continue;
        }
        prs.sort_unstable();
        prs.dedup();
        let pr = *prs.last().expect("checked non-empty");
        let mut row = json!({
            "v": 1,
            "kind": "review_round",
            "repo": repo,
            "host": host,
            "at_ms": at_ms,
            "pr": pr,
            "branch": branch,
            "round_id": id,
        });
        let o = row.as_object_mut().expect("object");
        for (from, to) in [
            ("via", "via"),
            ("name", "name"),
            ("kind", "review_kind"),
            ("head", "head"),
        ] {
            if let Some(s) = v.get(from).and_then(Value::as_str) {
                o.insert(to.into(), Value::String(s.to_string()));
            }
        }
        if prs.len() > 1 {
            o.insert("prs".into(), json!(prs));
        }
        rows.push(row.clone());
        if let Some(void) = voids.get(&(common, branch, id)) {
            let mut vr = row;
            let o = vr.as_object_mut().expect("object");
            o.insert("kind".into(), json!("review_round_void"));
            o.insert(
                "at_ms".into(),
                json!(void.get("at").and_then(Value::as_u64).unwrap_or(at_ms)),
            );
            if let Some(why) = void.get("why").and_then(Value::as_str) {
                o.insert(
                    "why".into(),
                    json!(why.chars().take(500).collect::<String>()),
                );
            }
            rows.push(vr);
        }
    }
    rows.sort_by_key(|r| r["at_ms"].as_u64().unwrap_or(0));
    rows
}

/// The `(kind, round_id)` of every row already in a derived file.
fn seen_rounds(path: &Path) -> BTreeSet<(String, String)> {
    let mut seen = BTreeSet::new();
    if let Ok(text) = fs::read_to_string(path) {
        for l in text.lines() {
            if let Ok(v) = serde_json::from_str::<Value>(l) {
                seen.insert((
                    v["kind"].as_str().unwrap_or("").to_string(),
                    v["round_id"].as_str().unwrap_or("").to_string(),
                ));
            }
        }
    }
    seen
}

/// Appends lines to a derived ledger file under an exclusive flock.
pub fn append_rows(path: &Path, rows: &[Value]) -> Result<(), String> {
    if rows.is_empty() {
        return Ok(());
    }
    if let Some(d) = path.parent() {
        fs::create_dir_all(d).map_err(|e| format!("creating {}: {e}", d.display()))?;
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
    let mut text = String::new();
    for r in rows {
        text.push_str(&r.to_string());
        text.push('\n');
    }
    f.write_all(text.as_bytes())
        .and_then(|_| f.sync_data())
        .map_err(|e| format!("writing {}: {e}", path.display()))
}

/// Appends the review rounds this machine's review-round-counter store holds for the
/// configured repos to `outbox/<key>.review_round.jsonl`, each once. Returns how many.
pub fn harvest_reviews(cfg: &Config) -> Result<usize, String> {
    let host = shadow::hostname();
    let wanted = |common: &str| -> Option<String> {
        let p = Path::new(common);
        if !p.is_dir() {
            return None;
        }
        let slug = git::origin_slug(p)?;
        cfg.source(&slug).map(|s| s.repo.clone())
    };
    let cache_path = dir().join("review_links.json");
    let mut lookup = PrLookup::load(&cache_path, now_ms());
    let mut ask = |repo: &str, branch: &str, at_ms: u64| -> Vec<u64> {
        lookup.ask(repo, branch, at_ms, &mut prs_for_branch)
    };
    let mut fresh: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    let mut seen: HashMap<String, BTreeSet<(String, String)>> = HashMap::new();
    for store in rrc_stores() {
        let mut text = String::new();
        File::open(&store)
            .and_then(|mut f| f.read_to_string(&mut text))
            .map_err(|e| format!("reading {}: {e}", store.display()))?;
        let map: Map<String, Value> =
            serde_json::from_str(&text).map_err(|e| format!("parsing {}: {e}", store.display()))?;
        for row in review_rows(&map, &host, &wanted, &mut ask) {
            let repo = row["repo"].as_str().unwrap_or("").to_string();
            let Some(src) = cfg.source(&repo) else {
                continue;
            };
            let path = derived_path(&src.key(), "review_round");
            let s = seen
                .entry(path.display().to_string())
                .or_insert_with(|| seen_rounds(&path));
            let id = (
                row["kind"].as_str().unwrap_or("").to_string(),
                row["round_id"].as_str().unwrap_or("").to_string(),
            );
            if s.insert(id) {
                fresh
                    .entry(path.display().to_string())
                    .or_default()
                    .push(row);
            }
        }
    }
    // The cache only saves gh calls: failing to write it must not cost the rows.
    if let Err(e) = lookup.save(&cache_path) {
        eprintln!("chg outbox: {e} (review rounds are still sent)");
    }
    let mut n = 0;
    for (path, rows) in fresh {
        append_rows(Path::new(&path), &rows)?;
        n += rows.len();
    }
    Ok(n)
}

/// How far back an unlinked round is looked up on GitHub, and how many branches one run asks about.
const ASK_WINDOW_MS: u64 = 30 * 24 * 3600 * 1000;
const ASK_BUDGET: usize = 60;
/// How long "this branch has no PR" is believed before gh is asked again.
const MISS_TTL_MS: u64 = 3600 * 1000;
/// The longest one gh lookup may take.
const GH_LOOKUP_SECS: u64 = 15;

/// What gh last said about a branch's PRs, and when. An empty `prs` is "no PR yet".
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
struct Lookup {
    prs: Vec<u64>,
    asked_ms: u64,
}

/// An unlinked round's PR, from gh, through `~/.chg/outbox/review_links.json`.
/// - A found PR is believed for every round up to the time it was asked. A newer round on
///   the branch asks again once, so a reused branch name moves to its newer PR.
/// - "No PR yet" is believed for MISS_TTL_MS.
/// - Only rounds from the last ASK_WINDOW_MS are asked about, at most ASK_BUDGET per run.
/// - A failed gh call changes nothing.
struct PrLookup {
    cache: BTreeMap<String, Lookup>,
    now: u64,
    budget: usize,
    changed: bool,
}

impl PrLookup {
    fn load(path: &Path, now: u64) -> PrLookup {
        PrLookup {
            cache: fs::read_to_string(path)
                .ok()
                .and_then(|t| serde_json::from_str(&t).ok())
                .unwrap_or_default(),
            now,
            budget: ASK_BUDGET,
            changed: false,
        }
    }

    fn ask(
        &mut self,
        repo: &str,
        branch: &str,
        at_ms: u64,
        gh: &mut dyn FnMut(&str, &str) -> Option<Vec<u64>>,
    ) -> Vec<u64> {
        let key = format!("{repo}:{branch}");
        let known = self.cache.get(&key).cloned();
        if let Some(k) = &known {
            let hit = !k.prs.is_empty() && at_ms <= k.asked_ms;
            let miss = k.prs.is_empty() && self.now.saturating_sub(k.asked_ms) < MISS_TTL_MS;
            if hit || miss {
                return k.prs.clone();
            }
        }
        let stale = known.map(|k| k.prs).unwrap_or_default();
        if at_ms < self.now.saturating_sub(ASK_WINDOW_MS) || self.budget == 0 {
            return stale;
        }
        self.budget -= 1;
        match gh(repo, branch) {
            Some(prs) => {
                self.cache.insert(
                    key,
                    Lookup {
                        prs: prs.clone(),
                        asked_ms: self.now,
                    },
                );
                self.changed = true;
                prs
            }
            None => stale,
        }
    }

    /// Writes the cache if it changed, dropping entries older than the lookup window.
    fn save(&mut self, path: &Path) -> Result<(), String> {
        if !self.changed {
            return Ok(());
        }
        let since = self.now.saturating_sub(ASK_WINDOW_MS);
        self.cache.retain(|_, l| l.asked_ms >= since);
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec(&self.cache).unwrap_or_default())
            .and_then(|_| fs::rename(&tmp, path))
            .map_err(|e| format!("writing {}: {e}", path.display()))
    }
}

/// The PRs (any state) whose head is `branch` in `repo`, by gh within GH_LOOKUP_SECS.
/// None when gh fails or is too slow: the round waits instead of being credited to a guess.
fn prs_for_branch(repo: &str, branch: &str) -> Option<Vec<u64>> {
    let t = gh::text_within(
        &[
            "pr", "list", "-R", repo, "--head", branch, "--state", "all", "--json", "number",
            "--limit", "20",
        ],
        std::time::Duration::from_secs(GH_LOOKUP_SECS),
    )
    .ok()?;
    let v: Value = serde_json::from_str(&t).ok()?;
    Some(
        v.as_array()?
            .iter()
            .filter_map(|p| p["number"].as_u64())
            .collect(),
    )
}

/// Unix milliseconds as RFC 3339 UTC (`2026-11-18T21:33:01.140Z`).
pub fn rfc3339(ms: u64) -> String {
    let secs = ms / 1000;
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{:03}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60,
        ms % 1000
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// RFC 4231 test case 2.
    #[test]
    fn hmac_matches_rfc_4231() {
        assert_eq!(
            sign(b"Jefe", b"what do ya want for nothing?"),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn rfc3339_formats_utc() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(rfc3339(1_795_037_581_140), "2026-11-18T21:33:01.140Z");
        assert_eq!(rfc3339(951_782_400_000), "2000-02-29T00:00:00.000Z");
    }

    #[test]
    fn wire_row_names_the_source_repo() {
        let r = wire_row(
            r#"{"v":1,"kind":"chg","repo":"home_care_billing"}"#,
            "mkreyman/home_care_billing",
        )
        .unwrap();
        assert_eq!(r["repo"], "mkreyman/home_care_billing");
        assert!(wire_row("not json", "a/b").is_none());
        assert!(wire_row("[1]", "a/b").is_none());
    }

    #[test]
    fn wire_row_keeps_the_first_failures_loopctl_would_keep() {
        let failures: Vec<String> = (0..2700)
            .rev()
            .map(|i| format!("test/archetype/case_{i:04}_test.exs:{i}"))
            .collect();
        let line = serde_json::json!({"v":1,"kind":"chg","repo":"r","sha":"s","verdict":"fail",
                                      "ms":1,"failures":failures,"selected":["test/a_test.exs"]})
        .to_string();
        let r = wire_row(&line, "a/r").unwrap();
        assert!(serde_json::to_vec(&r).unwrap().len() <= MAX_ROW_BYTES);
        assert_eq!(r["failures_count"], 2700);
        let kept = r["failures"].as_array().unwrap();
        assert_eq!(kept.len(), MAX_FAILURE_NAMES);
        assert_eq!(
            kept[0], "test/archetype/case_0000_test.exs:0",
            "sorted, lowest first"
        );
        assert!(r.get("selected").is_none(), "selected goes first");
        assert_eq!(r["failures_sha256"].as_str().unwrap().len(), 64);
        assert_eq!(wire_row(&line, "a/r"), Some(r.clone()), "deterministic");

        // Two runs with the same first 50 but different tails keep distinct digests.
        let mut other = failures.clone();
        other[0] = "test/zzz_test.exs:1".into();
        let line2 = serde_json::json!({"v":1,"kind":"gate","sha":"s","verdict":"fail","ms":1,
                                       "failures":other})
        .to_string();
        let r2 = wire_row(&line2, "a/r").unwrap();
        assert_eq!(r2["failures"], r["failures"]);
        assert_ne!(r2["failures_sha256"], r["failures_sha256"]);

        // The names loopctl keeps: empty and non-name entries dropped, `id` objects read.
        let mut odd: Vec<Value> = vec![
            Value::from(""),
            Value::from(7),
            json!({"id": "test/0_id_test.exs:1"}),
        ];
        odd.extend(failures.iter().map(|f| Value::from(f.as_str())));
        let names = failure_names(&odd);
        assert_eq!(names[0], "test/0_id_test.exs:1");
        assert_eq!(names.len(), MAX_FAILURE_NAMES);
        assert!(!names.iter().any(String::is_empty));
        let long = "t".repeat(250);
        assert_eq!(
            failure_names(&[Value::from(long.as_str()), Value::from(long.as_str())]).len(),
            1
        );
        assert_eq!(
            failure_names(&[Value::from(long.as_str())])[0].len(),
            MAX_FAILURE_CHARS
        );

        let small = r#"{"v":1,"kind":"gate","failures":["test/b_test.exs:1","test/a_test.exs:2"]}"#;
        let s = wire_row(small, "a/r").unwrap();
        assert_eq!(
            s["failures"][0], "test/b_test.exs:1",
            "a row under the cap is untouched"
        );
        assert!(s.get("failures_count").is_none());
    }

    #[test]
    fn wire_row_fits_a_large_selection_under_loopctls_row_cap() {
        let tests: Vec<String> = (0..3000)
            .map(|i| format!("test/x/y_{i}_test.exs"))
            .collect();
        let line = serde_json::json!({"v":1,"kind":"chg","repo":"r","sha":"s","verdict":"pass",
                                      "ms":1,"mode":"subset","selected":tests})
        .to_string();
        assert!(line.len() > MAX_ROW_BYTES);
        let r = wire_row(&line, "a/r").unwrap();
        assert_eq!(r["selected_count"], 3000);
        assert!(r.get("selected").is_none());
        assert!(serde_json::to_vec(&r).unwrap().len() <= MAX_ROW_BYTES);
        assert_eq!(
            wire_row(&line, "a/r"),
            Some(r),
            "deterministic, so a resend hashes the same"
        );

        let small = r#"{"v":1,"kind":"chg","selected":["test/a_test.exs"]}"#;
        assert_eq!(
            wire_row(small, "a/r").unwrap()["selected"][0],
            "test/a_test.exs"
        );
    }

    #[test]
    fn lines_from_leaves_a_torn_last_line() {
        let t = tempfile::tempdir().unwrap();
        let p = t.path().join("f.jsonl");
        fs::write(&p, "{\"a\":1}\n{\"a\":2}\n{\"a\":").unwrap();
        let l = lines_from(&p, 0, 10).unwrap();
        assert_eq!(l.len(), 2);
        assert_eq!(l[1].end, 16);
        assert!(lines_from(&p, 16, 10).unwrap().is_empty());
        assert_eq!(lines_from(&p, 0, 1).unwrap().len(), 1);
    }

    #[test]
    fn split_rec_takes_the_first_and_last_colon() {
        assert_eq!(
            split_rec("/w/hcb/.git:story/a/b:1791467428341-10481f4d"),
            Some(("/w/hcb/.git", "story/a/b", "1791467428341-10481f4d"))
        );
        assert_eq!(split_rec("/w/x/.git:b"), None);
    }

    #[test]
    fn review_rows_link_rounds_to_prs_and_carry_voids() {
        let store: Map<String, Value> = serde_json::from_value(json!({
            "rec:round:/w/hcb/.git:feat/x:1000-aaaaaaaa": {"via":"Skill","name":"lean-review","kind":"code","head":"abc"},
            "rec:round:/w/hcb/.git:feat/x:2000-bbbbbbbb": {"via":"Skill","name":"lean-review","kind":"code"},
            "rec:void:/w/hcb/.git:feat/x:2000-bbbbbbbb": {"at": 2500, "why":"refund","evidence":"long"},
            "rec:link:/w/hcb/.git:feat/x:42": {},
            "rec:round:/w/hcb/.git:feat/unlinked:3000-cccccccc": {"via":"Skill","name":"lean-review","kind":"code"},
            "rec:round:/w/other/.git:feat/y:4000-dddddddd": {"via":"Skill","name":"lean-review","kind":"code"},
            "rec:link:/w/other/.git:feat/y:7": {},
            "rounds:/w/hcb:legacy": {"count": 1}
        }))
        .unwrap();
        let wanted =
            |c: &str| (c == "/w/hcb/.git").then(|| "mkreyman/home_care_billing".to_string());
        let mut asked = Vec::new();
        let mut ask = |repo: &str, branch: &str, at: u64| {
            asked.push((repo.to_string(), branch.to_string(), at));
            Vec::new()
        };
        let rows = review_rows(&store, "minis", &wanted, &mut ask);
        assert_eq!(
            asked,
            vec![(
                "mkreyman/home_care_billing".to_string(),
                "feat/unlinked".to_string(),
                3000
            )],
            "only the unlinked round of a wanted repo is asked about"
        );
        let kinds: Vec<(&str, u64)> = rows
            .iter()
            .map(|r| (r["kind"].as_str().unwrap(), r["at_ms"].as_u64().unwrap()))
            .collect();
        assert_eq!(
            kinds,
            vec![
                ("review_round", 1000),
                ("review_round", 2000),
                ("review_round_void", 2500)
            ]
        );
        assert_eq!(rows[0]["pr"], 42);
        assert_eq!(rows[0]["head"], "abc");
        assert_eq!(rows[0]["review_kind"], "code");
        assert_eq!(rows[0]["host"], "minis");
        assert_eq!(rows[0]["repo"], "mkreyman/home_care_billing");
        assert_eq!(rows[2]["round_id"], "2000-bbbbbbbb");
        assert_eq!(rows[2]["why"], "refund");
        assert!(rows[2].get("evidence").is_none());
    }

    #[test]
    fn review_rows_take_the_pr_gh_names_for_an_unlinked_round() {
        let store: Map<String, Value> = serde_json::from_value(json!({
            "rec:round:/w/l/.git:fix/a:5000-eeeeeeee": {"via":"Skill","name":"lean-review","kind":"code"},
            "rec:round:/w/l/.git:fix/a:6000-ffffffff": {"via":"Skill","name":"lean-review","kind":"code"},
            "rec:round:/w/l/.git:fix/none:7000-gggggggg": {"via":"Skill","name":"lean-review","kind":"code"}
        }))
        .unwrap();
        let wanted = |_: &str| Some("mkreyman/loopctl".to_string());
        let mut ask = |_: &str, b: &str, _: u64| match b {
            "fix/a" => vec![1055, 1040],
            _ => vec![],
        };
        let rows = review_rows(&store, "minis", &wanted, &mut ask);
        assert_eq!(rows.len(), 2, "fix/none has no PR yet and waits");
        assert!(
            rows.iter().all(|r| r["pr"] == 1055),
            "the highest PR is credited"
        );
        assert_eq!(rows[0]["prs"], json!([1040, 1055]));
    }

    #[test]
    fn pr_lookup_caches_hits_rechecks_newer_rounds_and_expires_misses() {
        let now = 100 * 24 * 3600 * 1000;
        let mut l = PrLookup {
            cache: BTreeMap::new(),
            now,
            budget: 3,
            changed: false,
        };
        let calls = std::cell::Cell::new(0);
        let mut gh = |_: &str, b: &str| {
            calls.set(calls.get() + 1);
            match b {
                "fix/a" => Some(vec![7]),
                "down" => None,
                _ => Some(vec![]),
            }
        };
        assert_eq!(l.ask("o/r", "fix/a", now - 10, &mut gh), vec![7]);
        assert_eq!(
            l.ask("o/r", "fix/a", now - 20, &mut gh),
            vec![7],
            "an older round hits"
        );
        assert_eq!(l.ask("o/r", "none", now - 10, &mut gh), Vec::<u64>::new());
        assert_eq!(
            l.ask("o/r", "none", now - 5, &mut gh),
            Vec::<u64>::new(),
            "a fresh miss holds"
        );
        assert_eq!(calls.get(), 2);
        assert_eq!(
            l.ask("o/r", "old", now - ASK_WINDOW_MS - 1, &mut gh),
            Vec::<u64>::new(),
            "outside the window: not asked"
        );
        assert_eq!(l.ask("o/r", "down", now, &mut gh), Vec::<u64>::new());
        assert_eq!(calls.get(), 3, "budget of 3 spent");
        assert!(
            !l.cache.contains_key("o/r:down"),
            "a failed gh call caches nothing"
        );
        assert_eq!(
            l.ask("o/r", "other", now, &mut gh),
            Vec::<u64>::new(),
            "no budget left"
        );
        assert_eq!(calls.get(), 3);

        // The next run: a round newer than the cached ask re-asks once; a miss past its TTL re-asks.
        let mut l2 = PrLookup {
            cache: l.cache.clone(),
            now: now + MISS_TTL_MS,
            budget: 5,
            changed: false,
        };
        let mut calls2 = 0;
        let mut gh2 = |_: &str, b: &str| {
            calls2 += 1;
            Some(if b == "fix/a" { vec![7, 9] } else { vec![] })
        };
        assert_eq!(l2.ask("o/r", "fix/a", now + 1, &mut gh2), vec![7, 9]);
        assert_eq!(l2.ask("o/r", "fix/a", now + 2, &mut gh2), vec![7, 9]);
        assert_eq!(l2.ask("o/r", "none", now, &mut gh2), Vec::<u64>::new());
        assert_eq!(calls2, 2);

        let t = tempfile::tempdir().unwrap();
        let p = t.path().join("review_links.json");
        l2.cache.insert(
            "o/r:ancient".into(),
            Lookup {
                prs: vec![1],
                asked_ms: 0,
            },
        );
        l2.save(&p).unwrap();
        let saved: BTreeMap<String, Lookup> =
            serde_json::from_str(&fs::read_to_string(&p).unwrap()).unwrap();
        assert!(!saved.contains_key("o/r:ancient"), "pruned past the window");
        assert_eq!(saved["o/r:fix/a"].prs, vec![7, 9]);
    }

    #[test]
    fn review_rows_ask_newest_rounds_first() {
        let store: Map<String, Value> = serde_json::from_value(json!({
            "rec:round:/w/l/.git:a:1000-aaaaaaaa": {},
            "rec:round:/w/l/.git:b:3000-bbbbbbbb": {},
            "rec:round:/w/l/.git:c:2000-cccccccc": {}
        }))
        .unwrap();
        let wanted = |_: &str| Some("o/r".to_string());
        let mut order = Vec::new();
        let mut ask = |_: &str, b: &str, _: u64| {
            order.push(b.to_string());
            vec![1]
        };
        let rows = review_rows(&store, "h", &wanted, &mut ask);
        assert_eq!(order, ["b", "c", "a"]);
        let at: Vec<u64> = rows.iter().map(|r| r["at_ms"].as_u64().unwrap()).collect();
        assert_eq!(at, [1000, 2000, 3000], "rows still come out oldest first");
    }

    #[test]
    fn backoff_doubles_to_an_hour() {
        let mut s = State::default();
        let before = now_ms();
        record_failure(&mut s, "a/b", "x");
        let first = s.backoff["a/b"].next_at_ms - before;
        assert!(
            (BACKOFF_BASE_MS..BACKOFF_BASE_MS + 5000).contains(&first),
            "{first}"
        );
        for _ in 0..30 {
            record_failure(&mut s, "a/b", "x");
        }
        assert!(s.backoff["a/b"].next_at_ms - before <= BACKOFF_MAX_MS + 5000);
        assert_eq!(s.backoff["a/b"].failures, 31);
    }
}
