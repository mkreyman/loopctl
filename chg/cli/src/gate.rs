//! Which gate judges a push (story S10): chg's, the repo's old one with chg in shadow
//! beside it, or the old one alone.
//!
//! `CHG_GATE` (env) wins over `[gate] mode` in `.chg/policy.toml`; with neither, the mode
//! is `shadow`. An unreadable policy or an unknown value resolves to `off`: when chg cannot
//! tell what was asked, the old gate runs, never nothing.

use std::env::VarError;
use std::fmt;
use std::io;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// `chg check` is the gate.
    On,
    /// The old gate is authoritative; `chg check --shadow` runs beside it.
    Shadow,
    /// The old gate alone; chg does nothing, shadow included.
    Off,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::On => "on",
            Mode::Shadow => "shadow",
            Mode::Off => "off",
        }
    }

    fn parse(s: &str) -> Option<Mode> {
        match s.trim().to_ascii_lowercase().as_str() {
            "on" => Some(Mode::On),
            "shadow" => Some(Mode::Shadow),
            "off" => Some(Mode::Off),
            _ => None,
        }
    }
}

impl fmt::Display for Mode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub mode: Mode,
    /// Where the mode came from: `env`, `policy`, `default`, or the fallback's reason.
    pub source: String,
}

pub const POLICY: &str = ".chg/policy.toml";

/// The mode for `repo`, from the process environment and the repo's policy file. A
/// policy that exists but cannot be read, like a `CHG_GATE` that is not Unicode, is
/// unreadable and resolves to `off`; only a missing policy means the default.
pub fn resolve(repo: &Path) -> Resolved {
    let env = match std::env::var("CHG_GATE") {
        Ok(v) => Some(v),
        Err(VarError::NotPresent) => None,
        Err(VarError::NotUnicode(v)) => {
            return off(format!("env CHG_GATE={v:?} is not Unicode"));
        }
    };
    if env.as_deref().is_some_and(|v| !v.trim().is_empty()) {
        return resolve_with(env.as_deref(), None);
    }
    match std::fs::read_to_string(repo.join(POLICY)) {
        Ok(text) => resolve_with(None, Some(&text)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => resolve_with(None, None),
        Err(e) => off(format!("{POLICY} cannot be read ({e})")),
    }
}

fn off(why: String) -> Resolved {
    Resolved {
        mode: Mode::Off,
        source: format!("{why}; falling back to off"),
    }
}

pub fn resolve_with(env: Option<&str>, policy: Option<&str>) -> Resolved {
    if let Some(v) = env.filter(|v| !v.trim().is_empty()) {
        return match Mode::parse(v) {
            Some(mode) => Resolved {
                mode,
                source: "env CHG_GATE".into(),
            },
            None => off(format!("env CHG_GATE={v:?} is not on, shadow or off")),
        };
    }
    let Some(text) = policy else {
        return Resolved {
            mode: Mode::Shadow,
            source: "default".into(),
        };
    };
    let table: toml::Table = match text.parse() {
        Ok(t) => t,
        Err(e) => return off(format!("{POLICY} does not parse ({e})")),
    };
    match table.get("gate").and_then(|g| g.get("mode")) {
        None => Resolved {
            mode: Mode::Shadow,
            source: "default".into(),
        },
        Some(v) => match v.as_str().and_then(Mode::parse) {
            Some(mode) => Resolved {
                mode,
                source: POLICY.into(),
            },
            None => off(format!(
                "{POLICY} [gate] mode = {v} is not \"on\", \"shadow\" or \"off\""
            )),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn env_wins_over_policy() {
        let on = "[gate]\nmode = \"on\"\n";
        assert_eq!(resolve_with(Some("off"), Some(on)).mode, Mode::Off);
        assert_eq!(resolve_with(Some("OFF"), Some(on)).mode, Mode::Off);
        assert_eq!(resolve_with(Some("shadow"), None).mode, Mode::Shadow);
        assert_eq!(resolve_with(None, Some(on)).mode, Mode::On);
        // An empty variable is unset, as in `CHG_GATE= git push`.
        assert_eq!(resolve_with(Some(""), Some(on)).mode, Mode::On);
    }

    #[test]
    fn default_is_shadow() {
        assert_eq!(resolve_with(None, None).mode, Mode::Shadow);
        assert_eq!(
            resolve_with(None, Some("[class.docs]\nreview = false\n")).mode,
            Mode::Shadow
        );
    }

    #[test]
    fn anything_unreadable_falls_back_to_off() {
        for (env, policy) in [
            (Some("yes"), None),
            (None, Some("[gate\nmode=")),
            (None, Some("[gate]\nmode = \"maybe\"\n")),
            (None, Some("[gate]\nmode = 1\n")),
        ] {
            let r = resolve_with(env, policy);
            assert_eq!(r.mode, Mode::Off, "{env:?} {policy:?}");
            assert!(r.source.contains("falling back to off"), "{}", r.source);
        }
    }
}
