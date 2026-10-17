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

/// `gh <args>` whose stdout is JSON.
pub fn json(args: &[&str]) -> Result<serde_json::Value, String> {
    let t = text(args)?;
    serde_json::from_str(&t).map_err(|e| format!("gh {}: not JSON ({e}): {t}", args.join(" ")))
}
