//! The GitHub CLI, as chg calls it. `CHG_GH` names another binary (the tests' stand-in).

use std::process::{Command, Stdio};

pub fn cmd() -> Command {
    let mut c = Command::new(std::env::var_os("CHG_GH").unwrap_or_else(|| "gh".into()));
    c.stdin(Stdio::null());
    c
}

/// Runs `gh <args>` and returns its trimmed stdout, or why it failed.
pub fn text(args: &[&str]) -> Result<String, String> {
    let out = cmd()
        .args(args)
        .output()
        .map_err(|e| format!("cannot run gh: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "gh {}: {}",
            args.first().copied().unwrap_or(""),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// `text`, but gh is killed and an error returned once `limit` passes. For short answers
/// only: stdout is read after exit, so output past the pipe buffer would block gh.
pub fn text_within(args: &[&str], limit: std::time::Duration) -> Result<String, String> {
    let r = ran_within(args, limit)?;
    if !r.ok {
        return Err(format!(
            "gh {}: exited {}: {}",
            args.join(" "),
            r.status,
            r.stderr
        ));
    }
    Ok(r.stdout)
}

/// What a gh run said, whatever its exit status: some gh commands (`pr checks`) report a
/// state through the status and still print their JSON.
#[derive(Debug)]
pub struct Ran {
    pub ok: bool,
    pub status: String,
    pub stdout: String,
    pub stderr: String,
}

/// Runs `gh <args>` like `text_within`, but returns its output for any exit status. `Err`
/// only when gh could not run or gave no answer within `limit`.
pub fn ran_within(args: &[&str], limit: std::time::Duration) -> Result<Ran, String> {
    let mut c = cmd();
    c.args(args);
    run_within(c, &args.join(" "), limit)
}

fn run_within(mut c: Command, what: &str, limit: std::time::Duration) -> Result<Ran, String> {
    use std::io::Read;
    let mut child = c
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot run gh: {e}"))?;
    let deadline = std::time::Instant::now() + limit;
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(50))
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("gh {what}: no answer in {limit:?}"));
            }
            Err(e) => return Err(format!("waiting for gh: {e}")),
        }
    };
    let (mut out, mut err) = (String::new(), String::new());
    if let Some(mut o) = child.stdout.take() {
        let _ = o.read_to_string(&mut out);
    }
    if let Some(mut e) = child.stderr.take() {
        let _ = e.read_to_string(&mut err);
    }
    Ok(Ran {
        ok: status.success(),
        status: status.to_string(),
        stdout: out.trim().to_string(),
        stderr: err.trim().to_string(),
    })
}

/// `gh <args>` whose stdout is JSON.
pub fn json(args: &[&str]) -> Result<serde_json::Value, String> {
    let t = text(args)?;
    serde_json::from_str(&t).map_err(|e| format!("gh {}: not JSON ({e}): {t}", args.join(" ")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn run_within_kills_a_slow_command_and_reads_a_fast_one() {
        let mut slow = Command::new("sleep");
        slow.arg("5");
        let t0 = Instant::now();
        let e = run_within(slow, "slow", Duration::from_millis(200)).unwrap_err();
        assert!(e.contains("no answer"), "{e}");
        assert!(
            t0.elapsed() < Duration::from_secs(2),
            "killed, not waited out"
        );

        let mut fast = Command::new("echo");
        fast.arg("[1]");
        let r = run_within(fast, "fast", Duration::from_secs(5)).unwrap();
        assert!(r.ok);
        assert_eq!(r.stdout, "[1]");

        // A non-zero exit still returns what was printed, on both streams.
        let mut fail = Command::new("sh");
        fail.args(["-c", "echo '[]'; echo why >&2; exit 8"]);
        let r = run_within(fail, "fail", Duration::from_secs(5)).unwrap();
        assert!(!r.ok);
        assert_eq!((r.stdout.as_str(), r.stderr.as_str()), ("[]", "why"));
    }
}
