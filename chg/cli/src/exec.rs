//! Running an adapter command: placeholder substitution, isolation env, a wall-clock cap,
//! and a process-group kill so neither a timed-out `mix` nor a helper an adapter left
//! behind outlives the command.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

use crate::contract::{CommandName, Manifest, Segment, segments};

/// Per-kind wall-clock caps (design §4, "Slow, not down").
pub fn default_timeout(name: CommandName) -> Duration {
    Duration::from_secs(match name {
        CommandName::Snapshot => 30 * 60,
        CommandName::Static => 15 * 60,
        CommandName::Affected => 5 * 60,
        CommandName::Run => 15 * 60,
        CommandName::Shard => 20 * 60,
    })
}

/// The cap a command runs under: `override_secs` when given (`--timeout-secs`), else the
/// per-kind default. Every caller resolves its cap here.
pub fn cap(name: CommandName, override_secs: Option<u64>) -> Duration {
    override_secs
        .map(Duration::from_secs)
        .unwrap_or_else(|| default_timeout(name))
}

/// How long to wait for stdout EOF once the group is dead. Only a process that escaped
/// the group (setsid) can hold the pipe that long, and the document is already in hand.
const EOF_GRACE: Duration = Duration::from_secs(5);

#[derive(Debug)]
pub enum Outcome {
    /// The command exited; `code` is None when a signal killed it. `document` is the last
    /// non-empty stdout line; every earlier line was already relayed to stderr.
    Exited {
        code: Option<i32>,
        document: Option<String>,
    },
    TimedOut {
        after: Duration,
    },
}

/// Quotes a value for `sh`, so a path with spaces or quotes is one argument.
pub fn shell_quote(s: &str) -> String {
    if !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_./=:,@+".contains(&b))
    {
        return s.to_string();
    }
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// Fills `{name}` placeholders in one pass over the template; substituted text is never
/// re-scanned, so a value that itself contains `{file}` stays inert inside its quotes.
pub fn substitute(
    template: &str,
    values: &BTreeMap<&str, String>,
    quote: bool,
) -> Result<String, String> {
    let mut out = String::with_capacity(template.len());
    for seg in segments(template) {
        match seg {
            Segment::Literal(l) => out.push_str(l),
            Segment::Placeholder(p) => {
                let v = values
                    .get(p)
                    .ok_or_else(|| format!("no value for placeholder `{{{p}}}`"))?;
                if quote {
                    out.push_str(&shell_quote(v));
                } else {
                    out.push_str(v);
                }
            }
        }
    }
    Ok(out)
}

pub fn run(
    manifest: &Manifest,
    repo: &Path,
    name: CommandName,
    values: &BTreeMap<&str, String>,
    extra_env: &[(String, String)],
    timeout: Duration,
) -> Result<Outcome, String> {
    let cmd = substitute(manifest.command(name), values, true)?;
    let mut env = extra_env.to_vec();
    for (k, tmpl) in &manifest.isolation_env {
        env.push((k.clone(), substitute(tmpl, values, false)?));
    }

    let mut command = Command::new("sh");
    // From a git hook, GIT_DIR and friends point at the pushing worktree; an adapter that
    // runs git (every `--base` diff does) must see the repo it runs in.
    for v in crate::git::HOOK_ENV {
        command.env_remove(v);
    }
    // Only chg decides what these say for this command: one inherited from a shell or a
    // parent snapshot build would name the wrong commit or record.
    for v in crate::adapter::ADAPTER_ENV {
        command.env_remove(v);
    }
    let mut child = command
        .arg("-c")
        .arg(&cmd)
        .current_dir(repo)
        .envs(env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .process_group(0)
        .spawn()
        .map_err(|e| format!("cannot start `{cmd}`: {e}"))?;

    // Relay stdout to stderr as it arrives, holding back only the newest non-empty line:
    // the document is the last one, and a hung command still shows its progress.
    let stdout = child.stdout.take().expect("piped");
    let last: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let (eof_tx, eof_rx) = mpsc::channel::<()>();
    {
        let last = Arc::clone(&last);
        std::thread::spawn(move || {
            let mut r = BufReader::new(stdout);
            let mut buf = Vec::new();
            while matches!(r.read_until(b'\n', &mut buf), Ok(n) if n > 0) {
                let line = String::from_utf8_lossy(&buf)
                    .trim_end_matches(['\n', '\r'])
                    .to_string();
                buf.clear();
                if line.trim().is_empty() {
                    continue;
                }
                if let Some(prev) = last.lock().expect("reader lock").replace(line) {
                    eprintln!("{prev}");
                }
            }
            let _ = eof_tx.send(());
        });
    }

    let start = Instant::now();
    let pid = child.id();
    loop {
        match exited_unreaped(pid) {
            Ok(true) => {
                // The leader is a zombie, so its group id cannot be reused yet: kill
                // whatever it left running, then reap it.
                kill_group(pid);
                let status = child.wait().map_err(|e| format!("reaping `{cmd}`: {e}"))?;
                let _ = eof_rx.recv_timeout(EOF_GRACE);
                let document = last.lock().expect("reader lock").take();
                return Ok(Outcome::Exited {
                    code: status.code(),
                    document,
                });
            }
            Ok(false) if start.elapsed() >= timeout => {
                kill_group(pid);
                let _ = child.wait();
                let _ = eof_rx.recv_timeout(EOF_GRACE);
                if let Some(l) = last.lock().expect("reader lock").take() {
                    eprintln!("{l}");
                }
                return Ok(Outcome::TimedOut { after: timeout });
            }
            Ok(false) => std::thread::sleep(Duration::from_millis(20)),
            Err(e) => {
                kill_group(pid);
                let _ = child.wait();
                return Err(format!("waiting on `{cmd}`: {e}"));
            }
        }
    }
}

fn kill_group(pid: u32) {
    // SAFETY: kill(2) on the process group our own child leads; no memory is touched.
    unsafe {
        libc::kill(-(pid as libc::pid_t), libc::SIGKILL);
    }
}

/// True once `pid` has exited, without reaping it (`WNOWAIT`).
fn exited_unreaped(pid: u32) -> std::io::Result<bool> {
    // SAFETY: siginfo_t is plain data; waitid fills it or leaves it zeroed under WNOHANG.
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    let r = unsafe {
        libc::waitid(
            libc::P_PID,
            pid as libc::id_t,
            &mut info,
            libc::WEXITED | libc::WNOWAIT | libc::WNOHANG,
        )
    };
    if r != 0 {
        return Err(std::io::Error::last_os_error());
    }
    #[cfg(target_os = "linux")]
    // SAFETY: waitid succeeded, so si_pid is initialised (0 when nothing has exited).
    let reported = unsafe { info.si_pid() };
    #[cfg(not(target_os = "linux"))]
    let reported = info.si_pid;
    Ok(reported != 0)
}

/// A stable per-workspace slot for `isolation_env`, derived from the workspace path, so
/// two workspaces on one machine never share a test database.
pub fn workspace_slot(repo: &Path) -> String {
    format!(
        "ws{}",
        crate::store::fnv8(repo.as_os_str().as_encoded_bytes())
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_override_replaces_the_cap_in_either_direction() {
        assert_eq!(
            cap(CommandName::Snapshot, None),
            default_timeout(CommandName::Snapshot)
        );
        assert_eq!(
            cap(CommandName::Snapshot, Some(7200)),
            Duration::from_secs(7200)
        );
        assert_eq!(cap(CommandName::Snapshot, Some(1)), Duration::from_secs(1));
    }

    #[test]
    fn quoting() {
        assert_eq!(shell_quote("abc123"), "abc123");
        assert_eq!(shell_quote("test/a b.exs"), "'test/a b.exs'");
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
        assert_eq!(shell_quote("$(rm -rf /)"), "'$(rm -rf /)'");
        assert_eq!(shell_quote(""), "''");
    }

    #[test]
    fn substitution_quotes_values_and_requires_all() {
        let mut v = BTreeMap::new();
        v.insert("file", "a b".to_string());
        assert_eq!(substitute("run {file}", &v, true).unwrap(), "run 'a b'");
        assert_eq!(substitute("run {file}", &v, false).unwrap(), "run a b");
        assert!(substitute("run {base}", &v, true).is_err());
    }

    #[test]
    fn substitution_never_rescans_a_value() {
        let mut v = BTreeMap::new();
        v.insert("file", "$(touch /tmp/pwn){file}".to_string());
        v.insert("base", "{workspace_slot}".to_string());
        v.insert("workspace_slot", "ws1".to_string());
        assert_eq!(
            substitute("t {file} && e {file}", &v, true).unwrap(),
            "t '$(touch /tmp/pwn){file}' && e '$(touch /tmp/pwn){file}'"
        );
        assert_eq!(
            substitute("b {base} {workspace_slot}", &v, true).unwrap(),
            "b '{workspace_slot}' ws1"
        );
        assert_eq!(
            substitute("x ${HOME} {{y}", &v, true).unwrap(),
            "x ${HOME} {y}"
        );
    }

    #[test]
    fn slot_is_stable_and_distinct() {
        let a = workspace_slot(Path::new("/w/a"));
        assert_eq!(a, workspace_slot(Path::new("/w/a")));
        assert_ne!(a, workspace_slot(Path::new("/w/b")));
        assert!(a.starts_with("ws") && a.len() == 10);
    }
}
