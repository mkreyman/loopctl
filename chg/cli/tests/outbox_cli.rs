//! Integration tests for the outbox to loopctl (design §5): `chg outbox send|status`, `chg
//! event emit|sync` and `chg review-dispatch`, against a fake loopctl that checks every
//! signature the way `Loopctl.Changes.Signature` does.

use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command as Std;
use std::sync::{Arc, Mutex};

use assert_cmd::Command;
use serde_json::{Value, json};
use tempfile::TempDir;

const GIT_ISOLATED: [(&str, &str); 2] = [
    ("GIT_CONFIG_GLOBAL", "/dev/null"),
    ("GIT_CONFIG_NOSYSTEM", "1"),
];
const SECRET: &str = "s3cret-for-tests";
const SOURCE: &str = "11111111-2222-3333-4444-555555555555";
/// A signed tree head as loopctl writes it: `<position>:<22 base64url chars>`.
const STH: &str = "7:AAAAAAAAAAAAAAAAAAAAAA";

#[derive(Debug, Clone)]
struct Req {
    method: String,
    target: String,
    headers: HashMap<String, String>,
    body: String,
}

impl Req {
    fn path(&self) -> &str {
        self.target.split('?').next().unwrap()
    }

    fn json(&self) -> Value {
        serde_json::from_str(&self.body).unwrap()
    }
}

type Handler = dyn Fn(&Req) -> (u16, String) + Send + Sync;

/// A fake loopctl on 127.0.0.1. Every request must carry a valid signature, or it is
/// answered 401 and recorded as `bad_signature`.
struct Fake {
    url: String,
    seen: Arc<Mutex<Vec<Req>>>,
    handler: Arc<Mutex<Box<Handler>>>,
}

impl Fake {
    fn start() -> Fake {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", l.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let handler: Arc<Mutex<Box<Handler>>> =
            Arc::new(Mutex::new(Box::new(|_| (500, "{}".to_string()))));
        let (s, h) = (seen.clone(), handler.clone());
        std::thread::spawn(move || {
            for stream in l.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut r = BufReader::new(stream.try_clone().unwrap());
                let mut first = String::new();
                if r.read_line(&mut first).is_err() {
                    continue;
                }
                let mut parts = first.split_whitespace();
                let method = parts.next().unwrap_or("").to_string();
                let target = parts.next().unwrap_or("").to_string();
                let mut headers = HashMap::new();
                loop {
                    let mut line = String::new();
                    r.read_line(&mut line).unwrap();
                    let line = line.trim_end();
                    if line.is_empty() {
                        break;
                    }
                    if let Some((k, v)) = line.split_once(':') {
                        headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
                    }
                }
                let len: usize = headers
                    .get("content-length")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0);
                let mut body = vec![0; len];
                r.read_exact(&mut body).unwrap();
                let req = Req {
                    method,
                    target,
                    headers,
                    body: String::from_utf8(body).unwrap(),
                };
                // A bearer call (review-complete) is the handler's to judge by its key.
                let bearer = req.headers.contains_key("authorization");
                let (status, text) = if bearer || signature_ok(&req) {
                    (h.lock().unwrap())(&req)
                } else {
                    (401, r#"{"error":{"code":"invalid_signature"}}"#.to_string())
                };
                s.lock().unwrap().push(req);
                // loopctl sends its current STH as a response header; a handler asks for it
                // by putting it at `error.current_sth` in the body.
                let sth = serde_json::from_str::<Value>(&text)
                    .ok()
                    .and_then(|v| v["error"]["current_sth"].as_str().map(str::to_string))
                    .map(|v| format!("x-loopctl-current-sth: {v}\r\n"))
                    .unwrap_or_default();
                let _ = write!(
                    stream,
                    "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\n{sth}Content-Length: {}\r\nConnection: close\r\n\r\n{text}",
                    text.len()
                );
            }
        });
        Fake { url, seen, handler }
    }

    fn answer(&self, f: impl Fn(&Req) -> (u16, String) + Send + Sync + 'static) {
        *self.handler.lock().unwrap() = Box::new(f);
    }

    fn take(&self) -> Vec<Req> {
        std::mem::take(&mut *self.seen.lock().unwrap())
    }
}

fn signature_ok(r: &Req) -> bool {
    let ts = r
        .headers
        .get("x-chg-timestamp")
        .cloned()
        .unwrap_or_default();
    let signed = if r.method == "GET" {
        format!("{ts}.GET.{}", r.target)
    } else {
        format!("{ts}.{}", r.body)
    };
    let want = format!(
        "sha256={}",
        chg::outbox::sign(SECRET.as_bytes(), signed.as_bytes())
    );
    r.headers.get("x-chg-signature") == Some(&want)
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Std::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .envs(GIT_ISOLATED)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

/// A temp CHG_HOME configured for `repo` against `fake`.
struct Machine {
    home: TempDir,
    url: String,
    store: PathBuf,
}

impl Machine {
    fn new(repo: &str, fake: &Fake) -> Machine {
        let home = tempfile::tempdir().unwrap();
        let secret = home.path().join("secret");
        fs::write(&secret, format!("{SECRET}\n")).unwrap();
        fs::set_permissions(&secret, fs::Permissions::from_mode(0o600)).unwrap();
        fs::write(
            home.path().join("loopctl.toml"),
            format!(
                "[[source]]\nrepo = \"{repo}\"\nsource_id = \"{SOURCE}\"\nsecret_file = \"{}\"\n",
                secret.display()
            ),
        )
        .unwrap();
        let store = home.path().join("rrc.json");
        fs::write(&store, "{}").unwrap();
        Machine {
            home,
            url: fake.url.clone(),
            store,
        }
    }

    fn chg(&self) -> Command {
        let mut c = Command::cargo_bin("chg").unwrap();
        c.env("CHG_HOME", self.home.path())
            .env("CHG_LOOPCTL_URL", &self.url)
            .env("CHG_OUTBOX_NO_KICK", "1")
            .env("CHG_RRC_STORE", &self.store)
            .envs(GIT_ISOLATED);
        c
    }

    fn shadow_log(&self, key: &str) -> PathBuf {
        self.home.path().join("shadow").join(format!("{key}.jsonl"))
    }
}

fn row(sha: &str, at: u64) -> String {
    format!(
        r#"{{"v":1,"kind":"chg","repo":"widget","host":"h1","sha":"{sha}","at_ms":{at},"verdict":"pass","ms":5}}"#
    )
}

fn ok_batch(r: &Req) -> (u16, String) {
    let n = r.json()["rows"].as_array().unwrap().len();
    (
        200,
        json!({"inserted": n, "duplicates": 0, "rejected": []}).to_string(),
    )
}

#[test]
fn send_delivers_each_row_once_and_keeps_a_torn_line() {
    let fake = Fake::start();
    let m = Machine::new("acme/widget", &fake);
    let log = m.shadow_log("widget");
    fs::create_dir_all(log.parent().unwrap()).unwrap();
    fs::write(
        &log,
        format!("{}\n{}\n{{\"v\":1,", row("a", 1), row("b", 2)),
    )
    .unwrap();
    fake.answer(ok_batch);

    m.chg().args(["outbox", "send"]).assert().success();
    let reqs = fake.take();
    assert_eq!(reqs.len(), 1, "{reqs:?}");
    assert_eq!(reqs[0].path(), format!("/api/v1/chg_ledger/{SOURCE}"));
    let rows = reqs[0].json()["rows"].as_array().unwrap().clone();
    assert_eq!(rows.len(), 2);
    assert!(rows.iter().all(|r| r["repo"] == "acme/widget"));

    // Nothing new: no request. The torn line completes: it alone goes.
    m.chg().args(["outbox", "send"]).assert().success();
    assert!(fake.take().is_empty());
    let mut f = fs::OpenOptions::new().append(true).open(&log).unwrap();
    writeln!(f, "\"kind\":\"gate\",\"repo\":\"widget\",\"host\":\"h1\",\"sha\":\"c\",\"at_ms\":3,\"verdict\":\"fail\",\"ms\":9}}").unwrap();
    m.chg().args(["outbox", "send"]).assert().success();
    let reqs = fake.take();
    assert_eq!(reqs.len(), 1);
    assert_eq!(reqs[0].json()["rows"][0]["sha"], "c");
}

#[test]
fn from_start_resends_everything_and_never_lowers_the_saved_offset() {
    let fake = Fake::start();
    let m = Machine::new("acme/widget", &fake);
    let log = m.shadow_log("widget");
    fs::create_dir_all(log.parent().unwrap()).unwrap();
    fs::write(&log, format!("{}\n{}\n", row("a", 1), row("b", 2))).unwrap();
    fake.answer(ok_batch);
    m.chg().args(["outbox", "send"]).assert().success();
    assert_eq!(fake.take().len(), 1);

    // A replay that fails part way leaves the delivered rows counted as delivered.
    fake.answer(|_| (503, r#"{"error":{"code":"busy"}}"#.into()));
    m.chg()
        .args(["outbox", "send", "--force", "--from-start"])
        .assert()
        .code(1);
    assert_eq!(fake.take().len(), 1);
    let out = m.chg().args(["outbox", "status"]).output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("0 row(s) unsent"), "{text}");

    // A replay that succeeds offers every row again; a plain send after it sends nothing.
    fake.answer(ok_batch);
    m.chg()
        .args(["outbox", "send", "--force", "--from-start"])
        .assert()
        .success();
    let reqs = fake.take();
    assert_eq!(reqs.len(), 1);
    assert_eq!(reqs[0].json()["rows"].as_array().unwrap().len(), 2);
    m.chg().args(["outbox", "send"]).assert().success();
    assert!(fake.take().is_empty());
}

#[test]
fn a_failure_backs_off_and_resends_the_same_rows() {
    let fake = Fake::start();
    let m = Machine::new("acme/widget", &fake);
    let log = m.shadow_log("widget");
    fs::create_dir_all(log.parent().unwrap()).unwrap();
    fs::write(&log, format!("{}\n", row("a", 1))).unwrap();
    fake.answer(|_| (503, r#"{"error":{"code":"busy"}}"#.into()));

    m.chg().args(["outbox", "send"]).assert().code(1);
    assert_eq!(fake.take().len(), 1);
    // Backing off: no request, and status says so.
    m.chg().args(["outbox", "send"]).assert().code(1);
    assert!(fake.take().is_empty());
    let out = m.chg().args(["outbox", "status"]).output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        text.contains("1 row(s) unsent") && text.contains("1 failure(s)"),
        "{text}"
    );

    fake.answer(ok_batch);
    m.chg()
        .args(["outbox", "send", "--force"])
        .assert()
        .success();
    let reqs = fake.take();
    assert_eq!(reqs.len(), 1);
    assert_eq!(reqs[0].json()["rows"][0]["sha"], "a");
    let out = m.chg().args(["outbox", "status"]).output().unwrap();
    assert!(String::from_utf8_lossy(&out.stdout).contains("0 row(s) unsent"));
}

/// TC-52.8.7 (US-52.8): every request names this chg; a 426 keeps the offset, says the
/// minimum once, and records no backoff, so the first send after the upgrade goes at once.
#[test]
fn an_old_chg_is_told_its_minimum_once_and_keeps_its_rows() {
    let fake = Fake::start();
    let m = Machine::new("acme/widget", &fake);
    let log = m.shadow_log("widget");
    fs::create_dir_all(log.parent().unwrap()).unwrap();
    fs::write(&log, format!("{}\n", row("a", 1))).unwrap();
    fake.answer(|_| {
        (
            426,
            r#"{"error":{"code":"incompatible_client_version","component":"chg","minimum":"9.0.0"}}"#
                .into(),
        )
    });

    let out = m.chg().args(["outbox", "send"]).output().unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(
        stderr.matches("needs chg 9.0.0 or later").count(),
        1,
        "{stderr}"
    );
    assert!(stderr.contains("run release/rollout.sh"), "{stderr}");

    let reqs = fake.take();
    assert_eq!(reqs.len(), 1, "{reqs:?}");
    let want = format!("chg/{}", env!("CARGO_PKG_VERSION"));
    assert!(
        reqs.iter()
            .all(|r| r.headers.get("x-loopctl-client") == Some(&want)),
        "{reqs:?}"
    );

    let status = m.chg().args(["outbox", "status"]).output().unwrap();
    assert!(String::from_utf8_lossy(&status.stdout).contains("1 row(s) unsent"));

    // No --force: a 426 left no backoff behind.
    fake.answer(ok_batch);
    m.chg().args(["outbox", "send"]).assert().success();
    let reqs = fake.take();
    assert_eq!(reqs.len(), 1);
    assert_eq!(reqs[0].json()["rows"][0]["sha"], "a");
}

#[test]
fn rejected_rows_are_kept_aside_and_never_block_the_rest() {
    let fake = Fake::start();
    let m = Machine::new("acme/widget", &fake);
    let log = m.shadow_log("widget");
    fs::create_dir_all(log.parent().unwrap()).unwrap();
    fs::write(
        &log,
        format!("not json\n{}\n{}\n", row("a", 1), row("b", 2)),
    )
    .unwrap();
    fake.answer(|_| {
        (
            200,
            json!({"inserted": 1, "duplicates": 0, "rejected": [{"index": 1, "reason": "invalid_row"}]})
                .to_string(),
        )
    });
    m.chg().args(["outbox", "send"]).assert().success();
    assert_eq!(fake.take()[0].json()["rows"].as_array().unwrap().len(), 2);
    let rejected = fs::read_to_string(m.home.path().join("outbox/rejected.jsonl")).unwrap();
    let reasons: Vec<String> = rejected
        .lines()
        .map(|l| {
            serde_json::from_str::<Value>(l).unwrap()["reason"]
                .as_str()
                .unwrap()
                .to_string()
        })
        .collect();
    assert_eq!(reasons, vec!["unparseable", "invalid_row"]);
}

#[test]
fn a_bad_secret_is_refused_without_sending() {
    let fake = Fake::start();
    let m = Machine::new("acme/widget", &fake);
    fs::set_permissions(
        m.home.path().join("secret"),
        fs::Permissions::from_mode(0o644),
    )
    .unwrap();
    fs::create_dir_all(m.shadow_log("widget").parent().unwrap()).unwrap();
    fs::write(m.shadow_log("widget"), format!("{}\n", row("a", 1))).unwrap();
    let out = m.chg().args(["outbox", "send"]).output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stdout).contains("chmod 600"));
    assert!(fake.take().is_empty());
}

#[test]
fn unconfigured_sends_nothing_and_succeeds() {
    let home = tempfile::tempdir().unwrap();
    Command::cargo_bin("chg")
        .unwrap()
        .env("CHG_HOME", home.path())
        .args(["outbox", "send"])
        .assert()
        .success()
        .stdout(predicates::str::contains("nothing to send"));
}

/// An origin whose URL ends in `acme/widget.git`, and a clone of it.
fn origin_and_clone(root: &Path) -> (PathBuf, PathBuf) {
    let origin = root.join("acme").join("widget.git");
    fs::create_dir_all(&origin).unwrap();
    git(&origin, &["init", "-q", "--bare"]);
    let seed = root.join("seed");
    fs::create_dir_all(&seed).unwrap();
    git(&seed, &["init", "-q", "-b", "master"]);
    fs::write(seed.join("f"), "x").unwrap();
    git(&seed, &["add", "f"]);
    git(
        &seed,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "init",
        ],
    );
    git(&seed, &["push", "-q", origin.to_str().unwrap(), "master"]);
    (origin, seed)
}

fn clone(origin: &Path, at: &Path) -> PathBuf {
    let out = Std::new("git")
        .args([
            "clone",
            "-q",
            origin.to_str().unwrap(),
            at.to_str().unwrap(),
        ])
        .envs(GIT_ISOLATED)
        .output()
        .unwrap();
    assert!(out.status.success());
    at.to_path_buf()
}

fn emit(m: &Machine, repo: &Path, change: &str, kind: &str, sha: &str) -> Value {
    let out = m
        .chg()
        .args(["event", "emit", "--repo"])
        .arg(repo)
        .args([
            "--change",
            change,
            "--kind",
            kind,
            "--revision",
            "1",
            "--sha",
            sha,
        ])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).unwrap()
}

#[test]
fn two_clones_emit_one_gap_free_sequence_and_delivery_follows_the_cursor() {
    let fake = Fake::start();
    let t = tempfile::tempdir().unwrap();
    let (origin, _seed) = origin_and_clone(t.path());
    let a = clone(&origin, &t.path().join("a"));
    let b = clone(&origin, &t.path().join("b"));
    let m = Machine::new("acme/widget", &fake);
    let sha = git(&a, &["rev-parse", "HEAD"]);

    let e1 = emit(&m, &a, "CH1", "submitted", &sha);
    let e2 = emit(&m, &b, "CH1", "check_passed", &sha);
    let e3 = emit(&m, &a, "CH1", "landed", &sha);
    assert_eq!(
        [&e1, &e2, &e3].map(|e| e["event_seq"].as_u64().unwrap()),
        [1, 2, 3]
    );
    assert_eq!(e1["repo"], "acme/widget");
    let tip = git(&origin, &["rev-parse", "refs/chg/CH1/events"]);
    assert_eq!(tip, e3["commit"].as_str().unwrap());

    // loopctl has applied 1 already; the sender sends 2 and 3, in order, from the chain.
    let applied = Arc::new(Mutex::new(1u64));
    let ap = applied.clone();
    fake.answer(move |r| {
        let mut a = ap.lock().unwrap();
        if r.method == "GET" {
            assert_eq!(r.target, format!("/api/v1/change_events/{SOURCE}/cursor?change_id=CH1"));
        } else {
            let seq = r.json()["event_seq"].as_u64().unwrap();
            if seq == *a + 1 {
                *a = seq;
            }
        }
        let cur = json!({"change_id": "CH1", "applied_through": *a, "held": []});
        if r.method == "GET" {
            (200, cur.to_string())
        } else {
            (200, json!({"status":"ok","outcome":"applied","duplicate":false,"applied_seq":*a,"cursor":cur}).to_string())
        }
    });
    let out = m.chg().args(["outbox", "status"]).output().unwrap();
    assert!(String::from_utf8_lossy(&out.stdout).contains("1 change(s) with undelivered events"));
    m.chg().args(["outbox", "send"]).assert().success();
    let reqs = fake.take();
    let posts: Vec<Value> = reqs
        .iter()
        .filter(|r| r.method == "POST")
        .map(Req::json)
        .collect();
    assert_eq!(
        posts
            .iter()
            .map(|p| p["event_seq"].as_u64().unwrap())
            .collect::<Vec<_>>(),
        vec![2, 3]
    );
    assert_eq!(posts[0]["kind"], "check_passed");
    assert_eq!(posts[1]["repo"], "acme/widget");
    assert_eq!(*applied.lock().unwrap(), 3);
    let out = m.chg().args(["outbox", "status"]).output().unwrap();
    assert!(String::from_utf8_lossy(&out.stdout).contains("0 change(s) with undelivered events"));
}

#[test]
fn an_event_emitted_during_a_send_stays_queued() {
    let fake = Fake::start();
    let t = tempfile::tempdir().unwrap();
    let (origin, _seed) = origin_and_clone(t.path());
    let a = clone(&origin, &t.path().join("a"));
    let m = Machine::new("acme/widget", &fake);
    let sha = git(&a, &["rev-parse", "HEAD"]);
    emit(&m, &a, "CH1", "submitted", &sha);

    // While the send posts seq 1 (the tip it read), another emit on this machine publishes
    // seq 2 and marks the change again. loopctl applies 1 and holds nothing, so the send
    // finishes the chain it read; the marker must survive for seq 2.
    let (home, url, store) = (m.home.path().to_path_buf(), m.url.clone(), m.store.clone());
    let (repo, sha2) = (a.clone(), sha.clone());
    let applied = Arc::new(Mutex::new(0u64));
    let ap = applied.clone();
    fake.answer(move |r| {
        let mut a = ap.lock().unwrap();
        if r.method == "POST" {
            let seq = r.json()["event_seq"].as_u64().unwrap();
            if seq == 1 {
                let out = Command::cargo_bin("chg")
                    .unwrap()
                    .env("CHG_HOME", &home)
                    .env("CHG_LOOPCTL_URL", &url)
                    .env("CHG_OUTBOX_NO_KICK", "1")
                    .env("CHG_RRC_STORE", &store)
                    .envs(GIT_ISOLATED)
                    .args(["event", "emit", "--repo"])
                    .arg(&repo)
                    .args([
                        "--change",
                        "CH1",
                        "--kind",
                        "landed",
                        "--revision",
                        "1",
                        "--sha",
                        &sha2,
                    ])
                    .output()
                    .unwrap();
                assert!(
                    out.status.success(),
                    "{}",
                    String::from_utf8_lossy(&out.stderr)
                );
            }
            if seq == *a + 1 {
                *a = seq;
            }
        }
        let cur = json!({"change_id": "CH1", "applied_through": *a, "held": []});
        if r.method == "GET" {
            (200, cur.to_string())
        } else {
            (200, json!({"status":"ok","cursor":cur}).to_string())
        }
    });
    m.chg().args(["outbox", "send"]).assert().success();
    assert_eq!(*applied.lock().unwrap(), 1);
    let out = m.chg().args(["outbox", "status"]).output().unwrap();
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("1 change(s) with undelivered events"),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    fake.take();
    m.chg().args(["outbox", "send"]).assert().success();
    let posts: Vec<u64> = fake
        .take()
        .iter()
        .filter(|r| r.method == "POST")
        .map(|r| r.json()["event_seq"].as_u64().unwrap())
        .collect();
    assert_eq!(posts, vec![2]);
    let out = m.chg().args(["outbox", "status"]).output().unwrap();
    assert!(String::from_utf8_lossy(&out.stdout).contains("0 change(s) with undelivered events"));
}

#[test]
fn only_the_sources_own_derived_files_are_sent() {
    let fake = Fake::start();
    let m = Machine::new("acme/foo", &fake);
    let outbox = m.home.path().join("outbox");
    fs::create_dir_all(&outbox).unwrap();
    let flaky = |test: &str| {
        format!(r#"{{"v":1,"kind":"flaky","repo":"foo","host":"h1","at_ms":1,"test":"{test}"}}"#)
    };
    fs::write(
        outbox.join("foo.flaky.jsonl"),
        format!("{}\n", flaky("mine")),
    )
    .unwrap();
    // Another repo whose name extends this one's, and the outbox's own reject file.
    fs::write(
        outbox.join("foo.bar.flaky.jsonl"),
        format!("{}\n", flaky("theirs")),
    )
    .unwrap();
    fs::write(
        outbox.join("foo.other.jsonl"),
        format!("{}\n", flaky("unknown kind")),
    )
    .unwrap();
    fs::write(
        outbox.join("rejected.jsonl"),
        format!("{}\n", flaky("rejected")),
    )
    .unwrap();
    fake.answer(ok_batch);

    m.chg().args(["outbox", "send"]).assert().success();
    let tests: Vec<Value> = fake
        .take()
        .iter()
        .flat_map(|r| r.json()["rows"].as_array().unwrap().clone())
        .map(|r| r["test"].clone())
        .collect();
    assert_eq!(tests, vec![json!("mine")]);
}

#[test]
fn emit_refuses_a_bad_change_id_or_sha() {
    let fake = Fake::start();
    let t = tempfile::tempdir().unwrap();
    let (origin, _seed) = origin_and_clone(t.path());
    let a = clone(&origin, &t.path().join("a"));
    let m = Machine::new("acme/widget", &fake);
    m.chg()
        .args(["event", "emit", "--repo"])
        .arg(&a)
        .args([
            "--change",
            "a/b",
            "--kind",
            "submitted",
            "--revision",
            "1",
            "--sha",
        ])
        .arg("0".repeat(40))
        .assert()
        .code(2);
    m.chg()
        .args(["event", "emit", "--repo"])
        .arg(&a)
        .args([
            "--change",
            "ok",
            "--kind",
            "submitted",
            "--revision",
            "1",
            "--sha",
            "abc",
        ])
        .assert()
        .code(2);
}

#[test]
fn review_rounds_are_harvested_once_and_sent() {
    let fake = Fake::start();
    let t = tempfile::tempdir().unwrap();
    let (origin, _seed) = origin_and_clone(t.path());
    let a = clone(&origin, &t.path().join("a"));
    let common = fs::canonicalize(a.join(".git")).unwrap();
    let m = Machine::new("acme/widget", &fake);
    let c = common.display();
    fs::write(
        &m.store,
        json!({
            format!("rec:round:{c}:feat/x:1000-aaaaaaaa"): {"via":"Skill","name":"lean-review","kind":"code"},
            format!("rec:link:{c}:feat/x:12"): {},
        })
        .to_string(),
    )
    .unwrap();
    fake.answer(ok_batch);
    m.chg().args(["outbox", "send"]).assert().success();
    m.chg().args(["outbox", "send"]).assert().success();
    let reqs = fake.take();
    assert_eq!(reqs.len(), 1, "{reqs:?}");
    let r = &reqs[0].json()["rows"][0];
    assert_eq!(r["kind"], "review_round");
    assert_eq!(r["pr"], 12);
    assert_eq!(r["repo"], "acme/widget");
}

#[test]
fn an_unlinked_round_takes_the_pr_gh_names_and_gh_is_asked_once() {
    let fake = Fake::start();
    let t = tempfile::tempdir().unwrap();
    let (origin, _seed) = origin_and_clone(t.path());
    let a = clone(&origin, &t.path().join("a"));
    let common = fs::canonicalize(a.join(".git")).unwrap();
    let m = Machine::new("acme/widget", &fake);
    let c = common.display();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis();
    fs::write(
        &m.store,
        json!({
            // Reviewed before its PR existed: no rec:link (the delivery loop's order).
            format!("rec:round:{c}:fix/a:{now}-aaaaaaaa"): {"via":"Skill","name":"lean-review","kind":"code"},
            // Outside the lookup window: never asked about.
            format!("rec:round:{c}:fix/old:1000-bbbbbbbb"): {"via":"Skill","name":"lean-review","kind":"code"},
        })
        .to_string(),
    )
    .unwrap();
    let calls = t.path().join("gh-calls");
    let gh = t.path().join("gh");
    fs::write(
        &gh,
        format!(
            "#!/bin/sh\necho \"$*\" >> {}\necho '[{{\"number\":77}}]'\n",
            calls.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&gh, fs::Permissions::from_mode(0o755)).unwrap();
    fake.answer(ok_batch);
    m.chg()
        .env("CHG_GH", &gh)
        .args(["outbox", "send"])
        .assert()
        .success();
    m.chg()
        .env("CHG_GH", &gh)
        .args(["outbox", "send"])
        .assert()
        .success();
    let asked = fs::read_to_string(&calls).unwrap();
    assert_eq!(
        asked.trim(),
        "pr list -R acme/widget --head fix/a --state all --json number --limit 20",
        "one gh call, for the recent unlinked branch only"
    );
    let reqs = fake.take();
    assert_eq!(reqs.len(), 1, "{reqs:?}");
    let rows = reqs[0].json()["rows"].as_array().unwrap().clone();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["pr"], 77);
    assert_eq!(rows[0]["branch"], "fix/a");
}

#[test]
fn a_failed_lookup_cache_write_still_sends_the_rounds() {
    let fake = Fake::start();
    let t = tempfile::tempdir().unwrap();
    let (origin, _seed) = origin_and_clone(t.path());
    let a = clone(&origin, &t.path().join("a"));
    let common = fs::canonicalize(a.join(".git")).unwrap();
    let m = Machine::new("acme/widget", &fake);
    let c = common.display();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis();
    fs::write(
        &m.store,
        json!({
            format!("rec:round:{c}:fix/a:{now}-aaaaaaaa"): {"via":"Skill","name":"lean-review","kind":"code"},
            format!("rec:round:{c}:feat/x:1000-bbbbbbbb"): {"via":"Skill","name":"lean-review","kind":"code"},
            format!("rec:link:{c}:feat/x:12"): {},
        })
        .to_string(),
    )
    .unwrap();
    // A directory where the cache's temp file goes: the cache write fails.
    fs::create_dir_all(m.home.path().join("outbox/review_links.json.tmp/x")).unwrap();
    let gh = t.path().join("gh");
    fs::write(&gh, "#!/bin/sh\necho '[{\"number\":77}]'\n").unwrap();
    fs::set_permissions(&gh, fs::Permissions::from_mode(0o755)).unwrap();
    fake.answer(ok_batch);
    m.chg()
        .env("CHG_GH", &gh)
        .args(["outbox", "send"])
        .assert()
        .success()
        .stderr(predicates::str::contains("review rounds are still sent"));
    let reqs = fake.take();
    let mut prs: Vec<u64> = reqs
        .iter()
        .flat_map(|r| r.json()["rows"].as_array().unwrap().clone())
        .map(|r| r["pr"].as_u64().unwrap())
        .collect();
    prs.sort_unstable();
    assert_eq!(
        prs,
        [12, 77],
        "both the linked and the looked-up round are sent"
    );
}

#[test]
fn review_dispatch_posts_exactly_change_and_revision() {
    let fake = Fake::start();
    let t = tempfile::tempdir().unwrap();
    let (origin, _seed) = origin_and_clone(t.path());
    let a = clone(&origin, &t.path().join("a"));
    let m = Machine::new("acme/widget", &fake);
    fake.answer(|r| {
        assert_eq!(r.json(), json!({"change_id": "CH1", "revision": 2}));
        (
            201,
            r#"{"dispatch_id":"d","api_key":"k","expires_at":"x"}"#.into(),
        )
    });
    m.chg()
        .args(["review-dispatch", "--repo"])
        .arg(&a)
        .args(["--change", "CH1", "--revision", "2"])
        .assert()
        .success()
        .stdout(predicates::str::contains("\"api_key\":\"k\""));
    assert_eq!(
        fake.take()[0].path(),
        format!("/api/v1/change_events/{SOURCE}/review_dispatch")
    );
    fake.answer(|_| {
        (
            409,
            r#"{"error":{"code":"review_already_recorded"}}"#.into(),
        )
    });
    m.chg()
        .args(["review-dispatch", "--repo"])
        .arg(&a)
        .args(["--change", "CH1", "--revision", "2"])
        .assert()
        .code(1)
        .stderr(predicates::str::contains("review_already_recorded"));
}

/// loopctl's 426 to a chg below the release set's minimum (US-52.8).
const UPGRADE: &str =
    r#"{"error":{"code":"incompatible_client_version","component":"chg","minimum":"9.0.0"}}"#;

/// The upgrade text a 426 is reported as, wherever it comes from (AC-52.8.6).
fn says_upgrade(stderr: &str) {
    assert!(stderr.contains("needs chg 9.0.0 or later"), "{stderr}");
    assert!(stderr.contains("run release/rollout.sh"), "{stderr}");
}

/// A fake loopctl that applies every event in order and answers every review-key mint
/// with `dispatch`.
fn applying_fake(fake: &Fake, dispatch: (u16, &'static str)) {
    let events = Arc::new(Mutex::new(Vec::<Value>::new()));
    fake.answer(move |r| {
        if r.path().ends_with("/review_dispatch") {
            return (dispatch.0, dispatch.1.to_string());
        }
        let mut e = events.lock().unwrap();
        if r.method == "POST" && r.json()["event_seq"].as_u64() == Some(e.len() as u64 + 1) {
            e.push(r.json());
        }
        let cur = json!({"applied_through": e.len(), "held": []});
        if r.method == "GET" {
            (200, cur.to_string())
        } else {
            (
                200,
                json!({"status":"ok","outcome":"applied","cursor":cur}).to_string(),
            )
        }
    });
}

/// AC-52.8.6: a 426 while `chg submit` delivers `submitted` is permanent for the run. It
/// is asked once, never retried after a sleep, and says the minimum and the remedy.
#[test]
fn a_426_on_delivery_stops_the_review_key_at_once() {
    let fake = Fake::start();
    let t = tempfile::tempdir().unwrap();
    let (origin, _seed) = origin_and_clone(t.path());
    let a = clone(&origin, &t.path().join("a"));
    let m = Machine::new("acme/widget", &fake);
    git(&a, &["checkout", "-q", "-b", "feat/x"]);
    commit(&a, "g", "1");
    fake.answer(|_| (426, UPGRADE.into()));

    let started = std::time::Instant::now();
    let out = m
        .chg()
        .args(["submit", "--story", "S-1", "--repo"])
        .arg(&a)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(3));
    says_upgrade(&String::from_utf8_lossy(&out.stderr));
    let reqs = fake.take();
    assert_eq!(reqs.len(), 1, "one cursor read, no retry: {reqs:?}");
    assert!(
        started.elapsed() < std::time::Duration::from_secs(2),
        "a 426 must not wait for a retry: {:?}",
        started.elapsed()
    );
}

/// AC-52.8.6: a 426 from the review-key mint itself, on all three paths that mint one.
#[test]
fn a_426_on_the_review_key_mint_says_the_minimum_and_the_remedy() {
    let fake = Fake::start();
    let t = tempfile::tempdir().unwrap();
    let (origin, _seed) = origin_and_clone(t.path());
    let a = clone(&origin, &t.path().join("a"));
    let m = Machine::new("acme/widget", &fake);
    git(&a, &["checkout", "-q", "-b", "feat/x"]);
    commit(&a, "g", "1");
    applying_fake(&fake, (426, UPGRADE));

    // `chg submit`: delivery succeeds, the mint is refused once and not asked again.
    let out = m
        .chg()
        .args(["submit", "--story", "S-1", "--repo"])
        .arg(&a)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(3));
    says_upgrade(&String::from_utf8_lossy(&out.stderr));
    let mints = fake
        .take()
        .iter()
        .filter(|r| r.path().ends_with("/review_dispatch"))
        .count();
    assert_eq!(mints, 1);

    // `chg review-dispatch`.
    let out = m
        .chg()
        .args(["review-dispatch", "--repo"])
        .arg(&a)
        .args(["--change", "CH1", "--revision", "1"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    says_upgrade(&String::from_utf8_lossy(&out.stderr));

    // `chg review` with no kept key mints one to record the clean review.
    let f = t.path().join("findings.json");
    fs::write(&f, "[]").unwrap();
    let out = m
        .chg()
        .args(["review", "--findings"])
        .arg(&f)
        .arg("--repo")
        .arg(&a)
        .output()
        .unwrap();
    assert!(!out.status.success());
    says_upgrade(&String::from_utf8_lossy(&out.stderr));
}

/// A fake loopctl that applies every event in order and mints a review key once the
/// revision's `submitted` is applied.
fn lifecycle_fake(fake: &Fake) -> Arc<Mutex<Vec<Value>>> {
    let events = Arc::new(Mutex::new(Vec::<Value>::new()));
    let ev = events.clone();
    fake.answer(move |r| {
        let mut e = ev.lock().unwrap();
        let change = r
            .target
            .split("change_id=")
            .nth(1)
            .map(str::to_string)
            .or_else(|| r.json()["change_id"].as_str().map(str::to_string))
            .unwrap_or_default();
        if r.path().ends_with("/review-complete") {
            // Like loopctl: a key's bootstrap grace is spent, so a bootstrap is refused
            // with the current STH, and the request carrying that STH is served.
            let bootstrap = r.headers.get("x-loopctl-sth-bootstrap").map(String::as_str);
            let known = r.headers.get("x-loopctl-last-known-sth").map(String::as_str);
            return match (r.headers.get("authorization").map(String::as_str), bootstrap, known) {
                (Some("Bearer k"), _, Some(STH)) => (201, r#"{"data":{}}"#.into()),
                (Some("Bearer k"), Some("true"), None) => (
                    412,
                    json!({"error":{"code":"witness_bootstrap_already_consumed","current_sth":STH}})
                        .to_string(),
                ),
                (Some("Bearer k"), _, _) => {
                    (412, r#"{"error":{"code":"witness_header_missing"}}"#.into())
                }
                _ => (401, r#"{"error":{"status":401}}"#.into()),
            };
        }
        if r.path().ends_with("/review_dispatch") {
            let rev = r.json()["revision"].as_u64().unwrap();
            let submitted = e
                .iter()
                .any(|x| x["kind"] == "submitted" && x["revision"] == rev);
            return if submitted {
                (201, r#"{"dispatch_id":"disp-1","api_key":"k","expires_at":"x"}"#.into())
            } else {
                (422, r#"{"error":{"code":"revision_not_submitted"}}"#.into())
            };
        }
        if r.method == "POST" {
            let v = r.json();
            if v["event_seq"].as_u64() == Some(e.len() as u64 + 1) {
                e.push(v);
            }
        }
        let cur = json!({"change_id": change, "applied_through": e.len(), "held": []});
        if r.method == "GET" {
            (200, cur.to_string())
        } else {
            (200, json!({"status":"ok","outcome":"applied","duplicate":false,"applied_seq":e.len(),"cursor":cur}).to_string())
        }
    });
    events
}

fn commit(dir: &Path, file: &str, text: &str) -> String {
    fs::write(dir.join(file), text).unwrap();
    git(dir, &["add", file]);
    git(
        dir,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            file,
        ],
    );
    git(dir, &["rev-parse", "HEAD"])
}

fn json_out(c: &mut Command) -> Value {
    let out = c.output().unwrap();
    assert!(
        out.status.success(),
        "exit {:?}: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).unwrap()
}

#[test]
fn submit_review_land_emit_the_story_lifecycle_once() {
    let fake = Fake::start();
    let events = lifecycle_fake(&fake);
    let t = tempfile::tempdir().unwrap();
    let (origin, _seed) = origin_and_clone(t.path());
    let a = clone(&origin, &t.path().join("a"));
    let m = Machine::new("acme/widget", &fake);
    git(&a, &["checkout", "-q", "-b", "feat/x"]);
    let r1 = commit(&a, "g", "1");

    let s = json_out(m.chg().args(["submit", "--story", "S-1", "--repo"]).arg(&a));
    let change = s["change_id"].as_str().unwrap().to_string();
    assert_eq!(
        (s["revision"].as_u64(), s["already"].as_bool()),
        (Some(1), Some(false))
    );
    assert_eq!(
        git(&origin, &["rev-parse", &format!("refs/chg/{change}/1")]),
        r1
    );
    let key = PathBuf::from(s["review_key"].as_str().unwrap());
    assert_eq!(
        fs::metadata(&key).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert!(fs::read_to_string(&key).unwrap().contains("disp-1"));

    // A repeat changes nothing.
    let again = json_out(m.chg().args(["submit", "--story", "S-1", "--repo"]).arg(&a));
    assert_eq!(again["already"], true);
    m.chg()
        .args(["submit", "--story", "S-2", "--repo"])
        .arg(&a)
        .assert()
        .code(1)
        .stderr(predicates::str::contains("bound to story S-1"));

    // Findings, then a fixed revision with a clean review.
    let f = t.path().join("findings.json");
    fs::write(&f, r#"[{"summary":"bug"}]"#).unwrap();
    let rv = json_out(
        m.chg()
            .args(["review", "--findings"])
            .arg(&f)
            .arg("--repo")
            .arg(&a),
    );
    assert_eq!(
        (rv["outcome"].as_str(), rv["round"].as_u64()),
        (Some("findings"), Some(1))
    );
    let r2 = commit(&a, "g", "2");
    let s2 = json_out(m.chg().args(["submit", "--repo"]).arg(&a));
    assert_eq!(s2["revision"], 2);
    // The kept key has expired: loopctl answers 401, chg mints afresh and records once.
    let key2 = PathBuf::from(s2["review_key"].as_str().unwrap());
    fs::write(&key2, r#"{"dispatch_id":"old","api_key":"stale"}"#).unwrap();
    fake.take();
    fs::write(&f, "[]").unwrap();
    let rv = json_out(
        m.chg()
            .args(["review", "--findings"])
            .arg(&f)
            .arg("--repo")
            .arg(&a),
    );
    assert_eq!(rv["outcome"], "approved");
    let records: Vec<Req> = fake
        .take()
        .into_iter()
        .filter(|r| r.path() == "/api/v1/stories/S-1/review-complete")
        .collect();
    let auth: Vec<&str> = records
        .iter()
        .map(|r| r.headers["authorization"].as_str())
        .collect();
    assert_eq!(auth, ["Bearer stale", "Bearer k", "Bearer k"]);
    // Every record carries a witness header: a bootstrap first, then the STH loopctl gave.
    let witness: Vec<(Option<&str>, Option<&str>)> = records
        .iter()
        .map(|r| {
            (
                r.headers.get("x-loopctl-sth-bootstrap").map(String::as_str),
                r.headers
                    .get("x-loopctl-last-known-sth")
                    .map(String::as_str),
            )
        })
        .collect();
    assert_eq!(
        witness,
        [
            (Some("true"), None),
            (Some("true"), None),
            (None, Some(STH))
        ]
    );
    assert_eq!(records[2].json()["commit_sha"], r2.as_str());
    assert_eq!(records[2].json()["findings_count"], 0);
    assert!(fs::read_to_string(&key2).unwrap().contains("disp-1"));

    // Not merged yet: land refuses and emits nothing.
    let gh = t.path().join("gh");
    fs::write(&gh, "#!/bin/sh\necho '[]'\n").unwrap();
    fs::set_permissions(&gh, fs::Permissions::from_mode(0o755)).unwrap();
    m.chg()
        .env("CHG_GH", &gh)
        .args(["land", "--repo"])
        .arg(&a)
        .assert()
        .code(1)
        .stderr(predicates::str::contains("no merged PR"));

    // "Merge": master fast-forwards to revision 2; gh names it as PR 9's merge.
    git(&a, &["push", "-q", "origin", "HEAD:master"]);
    fs::write(
        &gh,
        format!(
            "#!/bin/sh\ncase \"$2\" in\n list) echo '[{{\"number\":9,\"headRefOid\":\"{r2}\",\"mergeCommit\":{{\"oid\":\"{r2}\"}},\"baseRefName\":\"master\"}}]' ;;\n checks) echo '[{{\"name\":\"test\",\"bucket\":\"pass\",\"startedAt\":\"2026-11-19T03:00:00Z\",\"completedAt\":\"2026-11-19T03:00:05Z\"}}]' ;;\nesac\n"
        ),
    )
    .unwrap();
    let l = json_out(m.chg().env("CHG_GH", &gh).args(["land", "--repo"]).arg(&a));
    assert_eq!(
        (l["pr"].as_u64(), l["merge_sha"].as_str()),
        (Some(9), Some(r2.as_str()))
    );
    let l2 = json_out(m.chg().env("CHG_GH", &gh).args(["land", "--repo"]).arg(&a));
    assert_eq!(l2["already"], true);

    m.chg().args(["outbox", "send"]).assert().success();
    let e = events.lock().unwrap();
    let seen: Vec<(String, u64, String)> = e
        .iter()
        .map(|x| {
            (
                x["kind"].as_str().unwrap().to_string(),
                x["revision"].as_u64().unwrap(),
                x["sha"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    let want = [
        ("submitted", 1, &r1),
        ("review_findings", 1, &r1),
        ("submitted", 2, &r2),
        ("review_approved", 2, &r2),
        ("check_passed", 2, &r2),
        ("landed", 2, &r2),
    ]
    .map(|(k, n, s)| (k.to_string(), n, s.clone()));
    assert_eq!(seen, want);
    assert_eq!(e[0]["data"]["story_id"], "S-1");
    assert_eq!(e[1]["data"]["dispatch_key"], "disp-1");
    assert_eq!(e[3]["data"], json!({"by": "model"}));
    assert_eq!(e[4]["data"], json!({"checks": ["test"], "ms": 5000}));
    assert_eq!(
        e[5]["data"],
        json!({"merge_sha": r2, "pr": 9, "base": "master"})
    );
}

fn kinds_on_chain(origin: &Path, change: &str) -> Vec<String> {
    let tip = format!("refs/chg/{change}/events");
    git(origin, &["rev-list", "--reverse", &tip])
        .lines()
        .map(|c| {
            let v: Value = serde_json::from_str(&git(
                origin,
                &["cat-file", "blob", &format!("{c}:event.json")],
            ))
            .unwrap();
            format!("{}#{}", v["kind"].as_str().unwrap(), v["revision"])
        })
        .collect()
}

#[test]
fn a_lost_state_write_never_emits_twice_and_no_revision_is_skipped() {
    let fake = Fake::start();
    let _events = lifecycle_fake(&fake);
    let t = tempfile::tempdir().unwrap();
    let (origin, _seed) = origin_and_clone(t.path());
    let a = clone(&origin, &t.path().join("a"));
    let m = Machine::new("acme/widget", &fake);
    git(&a, &["checkout", "-q", "-b", "feat/y"]);
    commit(&a, "g", "1");
    let s = json_out(
        m.chg()
            .args(["submit", "--no-review-key", "--repo"])
            .arg(&a),
    );
    let change = s["change_id"].as_str().unwrap().to_string();

    // A story offered after revision 1 went out without one is refused, not dropped.
    m.chg()
        .args(["submit", "--story", "S-9", "--no-review-key", "--repo"])
        .arg(&a)
        .assert()
        .code(1)
        .stderr(predicates::str::contains("binds with the next revision"));

    // The emit happened but the flag was lost (a kill before the save).
    let state = a.join(".git/chg/changes/feat-y.json");
    let text = fs::read_to_string(&state).unwrap();
    fs::write(
        &state,
        text.replace("\"submitted\": true", "\"submitted\": false"),
    )
    .unwrap();
    let again = json_out(
        m.chg()
            .args(["submit", "--no-review-key", "--repo"])
            .arg(&a),
    );
    assert_eq!(again["revision"], 1);
    assert_eq!(kinds_on_chain(&origin, &change), ["submitted#1"]);

    // Lost again, and HEAD has moved: revision 1 is settled before revision 2 goes out.
    let text = fs::read_to_string(&state).unwrap();
    fs::write(
        &state,
        text.replace("\"submitted\": true", "\"submitted\": false"),
    )
    .unwrap();
    commit(&a, "g", "2");
    let s2 = json_out(
        m.chg()
            .args(["submit", "--story", "S-9", "--no-review-key", "--repo"])
            .arg(&a),
    );
    assert_eq!(
        (s2["revision"].as_u64(), s2["story_id"].as_str()),
        (Some(2), Some("S-9"))
    );
    assert_eq!(
        kinds_on_chain(&origin, &change),
        ["submitted#1", "submitted#2"]
    );
}

/// A granted bootstrap carries the current STH on whatever the operation answers, so only
/// the witness plug's own refusal is retried: an operation's 409 or 412 is sent once.
#[test]
fn only_a_spent_bootstrap_is_retried_with_the_head() {
    let fake = Fake::start();
    fake.answer(|r| match r.headers.get("x-loopctl-last-known-sth") {
        Some(_) => (201, r#"{"data":{}}"#.into()),
        None if r.path() == "/spent" => (
            412,
            json!({"error":{"code":"witness_bootstrap_already_consumed","current_sth":STH}})
                .to_string(),
        ),
        None if r.path() == "/conflict" => (
            409,
            json!({"error":{"code":"chg_review_already_recorded","current_sth":STH}}).to_string(),
        ),
        None => (
            412,
            json!({"error":{"code":"some_precondition","current_sth":STH}}).to_string(),
        ),
    });
    let post = |p: &str| chg::outbox::post_bearer(&fake.url, p, "k", b"{}").unwrap();

    assert_eq!(post("/spent").status, 201);
    assert_eq!(fake.take().len(), 2);
    for (path, status) in [("/conflict", 409), ("/other", 412)] {
        assert_eq!(post(path).status, status);
        let sent = fake.take();
        assert_eq!(sent.len(), 1, "{path} was retried");
        assert_eq!(sent[0].headers["x-loopctl-sth-bootstrap"], "true");
    }
}
