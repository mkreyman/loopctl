//! The adapter contract: `.chg/adapter.toml` (design §3.13).
//!
//! Validation collects every problem in one pass, so an agent fixing a manifest sees the
//! whole list at once instead of one error per run.

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Component, Path};

/// The contract version this `chg` implements. Adapters declare theirs in `adapter.version`.
pub const CONTRACT_VERSION: &str = "1";

pub const MANIFEST_PATH: &str = ".chg/adapter.toml";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Elixir,
    Pnpm,
}

impl Kind {
    fn parse(s: &str) -> Option<Kind> {
        match s {
            "elixir" => Some(Kind::Elixir),
            "pnpm" => Some(Kind::Pnpm),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Elixir => "elixir",
            Kind::Pnpm => "pnpm",
        }
    }
}

/// The five adapter commands, in manifest order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum CommandName {
    Snapshot,
    Static,
    Affected,
    Run,
    Shard,
}

impl CommandName {
    pub const ALL: [CommandName; 5] = [
        CommandName::Snapshot,
        CommandName::Static,
        CommandName::Affected,
        CommandName::Run,
        CommandName::Shard,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            CommandName::Snapshot => "snapshot",
            CommandName::Static => "static",
            CommandName::Affected => "affected",
            CommandName::Run => "run",
            CommandName::Shard => "shard",
        }
    }

    pub fn parse(s: &str) -> Option<CommandName> {
        CommandName::ALL.into_iter().find(|c| c.as_str() == s)
    }

    /// Placeholders the command must contain.
    pub fn required_placeholders(self) -> &'static [&'static str] {
        match self {
            CommandName::Snapshot => &[],
            CommandName::Static => &["base"],
            CommandName::Affected => &["base"],
            CommandName::Run => &["file"],
            CommandName::Shard => &["n", "i"],
        }
    }

    /// Placeholders the command may contain; anything else is a manifest error.
    pub fn allowed_placeholders(self) -> &'static [&'static str] {
        match self {
            CommandName::Snapshot => &["workspace_slot"],
            CommandName::Static => &["base", "workspace_slot"],
            CommandName::Affected => &["base", "workspace_slot"],
            CommandName::Run => &["file", "workspace_slot"],
            CommandName::Shard => &["n", "i", "workspace_slot"],
        }
    }
}

impl fmt::Display for CommandName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A validated manifest.
#[derive(Debug, Clone)]
pub struct Manifest {
    pub kind: Kind,
    pub version: String,
    pub artifacts: Vec<String>,
    pub inputs: Vec<String>,
    pub always_all: Vec<String>,
    pub isolation_env: BTreeMap<String, String>,
    pub commands: BTreeMap<CommandName, String>,
}

impl Manifest {
    pub fn command(&self, name: CommandName) -> &str {
        // Validation guarantees every command is present.
        &self.commands[&name]
    }
}

/// Every problem found in a manifest.
#[derive(Debug, PartialEq, Eq)]
pub struct Invalid(pub Vec<String>);

impl fmt::Display for Invalid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(
            f,
            "{MANIFEST_PATH} is invalid ({} problem(s)):",
            self.0.len()
        )?;
        for e in &self.0 {
            writeln!(f, "  - {e}")?;
        }
        Ok(())
    }
}

impl std::error::Error for Invalid {}

const ADAPTER_KEYS: [&str; 6] = [
    "kind",
    "version",
    "artifacts",
    "inputs",
    "always_all",
    "isolation_env",
];

pub fn parse(text: &str) -> Result<Manifest, Invalid> {
    let root: toml::Table = text
        .parse()
        .map_err(|e: toml::de::Error| Invalid(vec![format!("not valid TOML: {}", e.message())]))?;
    let mut errs = Vec::new();

    for key in root.keys() {
        if key != "adapter" && key != "commands" {
            errs.push(format!("unknown top-level key `{key}`"));
        }
    }

    let adapter = table(&root, "adapter", &mut errs);
    let commands = table(&root, "commands", &mut errs);

    if let Some(a) = adapter {
        for key in a.keys() {
            if !ADAPTER_KEYS.contains(&key.as_str()) {
                errs.push(format!("unknown key `adapter.{key}`"));
            }
        }
    }
    if let Some(c) = commands {
        for key in c.keys() {
            if CommandName::parse(key).is_none() {
                errs.push(format!("unknown key `commands.{key}`"));
            }
        }
    }

    let kind = adapter.and_then(|a| match a.get("kind") {
        None => {
            errs.push("missing `adapter.kind`".into());
            None
        }
        Some(toml::Value::String(s)) => Kind::parse(s).or_else(|| {
            errs.push(format!(
                "`adapter.kind` is \"{s}\"; expected \"elixir\" or \"pnpm\""
            ));
            None
        }),
        Some(_) => {
            errs.push("`adapter.kind` must be a string".into());
            None
        }
    });

    let version = adapter.and_then(|a| match a.get("version") {
        None => {
            errs.push("missing `adapter.version`".into());
            None
        }
        Some(toml::Value::String(s)) => Some(s.clone()),
        Some(_) => {
            errs.push("`adapter.version` must be a string".into());
            None
        }
    });
    if let Some(v) = &version
        && v != CONTRACT_VERSION
    {
        errs.push(version_mismatch(v));
    }

    let artifacts = adapter.and_then(|a| path_list(a, "artifacts", &mut errs));
    let inputs = adapter.and_then(|a| path_list(a, "inputs", &mut errs));
    let always_all = adapter.and_then(|a| path_list(a, "always_all", &mut errs));

    let isolation_env = adapter.and_then(|a| match a.get("isolation_env") {
        None => Some(BTreeMap::new()),
        Some(toml::Value::Table(t)) => {
            let mut env = BTreeMap::new();
            for (k, v) in t {
                match v {
                    toml::Value::String(s) => {
                        for p in placeholders(s) {
                            if p != "workspace_slot" {
                                errs.push(format!(
                                    "`adapter.isolation_env.{k}` uses unknown placeholder `{{{p}}}`; only `{{workspace_slot}}` is allowed"
                                ));
                            }
                        }
                        env.insert(k.clone(), s.clone());
                    }
                    _ => errs.push(format!("`adapter.isolation_env.{k}` must be a string")),
                }
            }
            Some(env)
        }
        Some(_) => {
            errs.push("`adapter.isolation_env` must be a table".into());
            None
        }
    });

    let mut cmds = BTreeMap::new();
    if let Some(c) = commands {
        for name in CommandName::ALL {
            match c.get(name.as_str()) {
                None => errs.push(format!("missing command `commands.{name}`")),
                Some(toml::Value::String(s)) if s.trim().is_empty() => {
                    errs.push(format!("command `commands.{name}` is empty"))
                }
                Some(toml::Value::String(s)) => {
                    let used = placeholders(s);
                    for p in &used {
                        if !name.allowed_placeholders().contains(&p.as_str()) {
                            errs.push(format!(
                                "`commands.{name}` uses unknown placeholder `{{{p}}}`"
                            ));
                        }
                    }
                    for req in name.required_placeholders() {
                        if !used.iter().any(|p| p == req) {
                            errs.push(format!("`commands.{name}` must contain `{{{req}}}`"));
                        }
                    }
                    cmds.insert(name, s.clone());
                }
                Some(_) => errs.push(format!("`commands.{name}` must be a string")),
            }
        }
    }

    if !errs.is_empty() {
        return Err(Invalid(errs));
    }
    Ok(Manifest {
        kind: kind.expect("checked"),
        version: version.expect("checked"),
        artifacts: artifacts.expect("checked"),
        inputs: inputs.expect("checked"),
        always_all: always_all.expect("checked"),
        isolation_env: isolation_env.expect("checked"),
        commands: cmds,
    })
}

pub fn version_mismatch(adapter_version: &str) -> String {
    format!(
        "adapter declares contract version \"{adapter_version}\" but this chg implements contract version \"{CONTRACT_VERSION}\""
    )
}

pub fn load(repo: &Path) -> anyhow::Result<Manifest> {
    let path = repo.join(MANIFEST_PATH);
    let text = std::fs::read_to_string(&path)
        .map_err(|e| anyhow::anyhow!("cannot read {}: {e}", path.display()))?;
    Ok(parse(&text)?)
}

fn table<'a>(root: &'a toml::Table, key: &str, errs: &mut Vec<String>) -> Option<&'a toml::Table> {
    match root.get(key) {
        None => {
            errs.push(format!("missing table `[{key}]`"));
            None
        }
        Some(toml::Value::Table(t)) => Some(t),
        Some(_) => {
            errs.push(format!("`{key}` must be a table"));
            None
        }
    }
}

/// A non-empty list of repo-relative paths or globs.
fn path_list(a: &toml::Table, key: &str, errs: &mut Vec<String>) -> Option<Vec<String>> {
    let Some(v) = a.get(key) else {
        errs.push(format!("missing `adapter.{key}`"));
        return None;
    };
    let Some(arr) = v.as_array() else {
        errs.push(format!("`adapter.{key}` must be an array of strings"));
        return None;
    };
    if arr.is_empty() {
        errs.push(format!("`adapter.{key}` is empty"));
        return None;
    }
    let mut out = Vec::new();
    for item in arr {
        match item.as_str() {
            Some("") => errs.push(format!("`adapter.{key}` holds an empty path")),
            Some(s) if !is_repo_relative(s) => errs.push(format!(
                "`adapter.{key}` entry \"{s}\" must be relative to the repo root with no `..`"
            )),
            Some(s) => out.push(s.to_string()),
            None => errs.push(format!("`adapter.{key}` must be an array of strings")),
        }
    }
    Some(out)
}

pub fn is_repo_relative(p: &str) -> bool {
    let path = Path::new(p);
    !p.starts_with('/')
        && path
            .components()
            .all(|c| matches!(c, Component::Normal(_) | Component::CurDir))
}

/// One piece of a command template.
#[derive(Debug, PartialEq, Eq)]
pub enum Segment<'a> {
    Literal(&'a str),
    Placeholder(&'a str),
}

/// Splits a template into literals and `{name}` placeholders in one left-to-right pass.
///
/// A placeholder is `{` + lowercase letters/underscores + `}`. Everything else is literal,
/// so shell syntax survives: `${HOME}` (a `$` before the brace), `awk '{print $1}'` (not
/// an identifier), and `{{`, which is an escaped literal `{`.
pub fn segments(s: &str) -> Vec<Segment<'_>> {
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    let mut lit_start = 0;
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'{' {
            i += 1;
            continue;
        }
        if bytes.get(i + 1) == Some(&b'{') {
            // `{{` -> literal `{`
            out.push(Segment::Literal(&s[lit_start..=i]));
            i += 2;
            lit_start = i;
            continue;
        }
        let after_dollar = i > 0 && bytes[i - 1] == b'$';
        let name_len = bytes[i + 1..]
            .iter()
            .take_while(|b| b.is_ascii_lowercase() || **b == b'_')
            .count();
        let closes = bytes.get(i + 1 + name_len) == Some(&b'}');
        if !after_dollar && name_len > 0 && closes {
            if lit_start < i {
                out.push(Segment::Literal(&s[lit_start..i]));
            }
            out.push(Segment::Placeholder(&s[i + 1..i + 1 + name_len]));
            i += name_len + 2;
            lit_start = i;
        } else {
            i += 1;
        }
    }
    if lit_start < bytes.len() {
        out.push(Segment::Literal(&s[lit_start..]));
    }
    out
}

/// Placeholder names used in a template.
pub fn placeholders(s: &str) -> Vec<String> {
    segments(s)
        .into_iter()
        .filter_map(|seg| match seg {
            Segment::Placeholder(p) => Some(p.to_string()),
            Segment::Literal(_) => None,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    pub const VALID: &str = r#"
[adapter]
kind = "elixir"
version = "1"
artifacts = ["deps", "_build", "priv/plts"]
inputs = ["lib/**", "test/**", "mix.exs"]
always_all = ["mix.exs", "mix.lock", "config/**"]
isolation_env = { MIX_TEST_PARTITION = "{workspace_slot}" }

[commands]
snapshot = "mix chg.snapshot"
static   = "mix chg.static --base {base}"
affected = "mix chg.affected --base {base}"
run      = "mix chg.run --tests {file}"
shard    = "mix chg.shard --of {n} --index {i}"
"#;

    fn errs(text: &str) -> Vec<String> {
        parse(text).expect_err("expected invalid").0
    }

    #[test]
    fn accepts_the_design_example() {
        let m = parse(VALID).unwrap();
        assert_eq!(m.kind, Kind::Elixir);
        assert_eq!(m.version, "1");
        assert_eq!(m.always_all.len(), 3);
        assert_eq!(
            m.command(CommandName::Affected),
            "mix chg.affected --base {base}"
        );
        assert_eq!(m.isolation_env["MIX_TEST_PARTITION"], "{workspace_slot}");
    }

    #[test]
    fn rejects_unknown_keys_at_every_level() {
        let text = VALID
            .replace("kind = \"elixir\"", "kind = \"elixir\"\ncolour = \"blue\"")
            .replace("[commands]", "[commands]\nlint = \"x\"")
            + "\n[extra]\na = 1\n";
        let e = errs(&text);
        assert!(
            e.contains(&"unknown key `adapter.colour`".to_string()),
            "{e:?}"
        );
        assert!(
            e.contains(&"unknown key `commands.lint`".to_string()),
            "{e:?}"
        );
        assert!(
            e.contains(&"unknown top-level key `extra`".to_string()),
            "{e:?}"
        );
    }

    #[test]
    fn rejects_a_missing_command() {
        let text = VALID.replace("shard    = \"mix chg.shard --of {n} --index {i}\"\n", "");
        assert_eq!(errs(&text), vec!["missing command `commands.shard`"]);
    }

    #[test]
    fn rejects_an_empty_command() {
        let text = VALID.replace("\"mix chg.snapshot\"", "\"  \"");
        assert_eq!(errs(&text), vec!["command `commands.snapshot` is empty"]);
    }

    #[test]
    fn rejects_empty_always_all() {
        let text = VALID.replace(
            "always_all = [\"mix.exs\", \"mix.lock\", \"config/**\"]",
            "always_all = []",
        );
        assert_eq!(errs(&text), vec!["`adapter.always_all` is empty"]);
    }

    #[test]
    fn rejects_a_version_mismatch_naming_both() {
        let text = VALID.replace("version = \"1\"", "version = \"2\"");
        let e = errs(&text);
        assert_eq!(e.len(), 1);
        assert!(e[0].contains("\"2\"") && e[0].contains("\"1\""), "{e:?}");
    }

    #[test]
    fn rejects_bad_placeholders() {
        let text = VALID
            .replace("--base {base}\"\nrun", "--since {base} {sha}\"\nrun")
            .replace("--tests {file}", "--tests");
        let e = errs(&text);
        assert!(
            e.contains(&"`commands.affected` uses unknown placeholder `{sha}`".to_string()),
            "{e:?}"
        );
        assert!(
            e.contains(&"`commands.run` must contain `{file}`".to_string()),
            "{e:?}"
        );
    }

    #[test]
    fn rejects_paths_that_escape_the_repo() {
        let text = VALID.replace("\"priv/plts\"", "\"../elsewhere\", \"/abs\"");
        let e = errs(&text);
        assert_eq!(e.len(), 2, "{e:?}");
    }

    #[test]
    fn collects_every_problem_in_one_pass() {
        let text = "[adapter]\nkind = \"cobol\"\n";
        let e = errs(text);
        // kind, version, artifacts, inputs, always_all, [commands]
        assert_eq!(e.len(), 6, "{e:?}");
    }

    #[test]
    fn shell_braces_are_not_placeholders() {
        assert_eq!(
            placeholders("x --out ${TMPDIR}/x --base {base}"),
            vec!["base"]
        );
        assert!(placeholders("awk '{print $1}' f").is_empty());
        assert!(placeholders("echo {{base}").is_empty());
        assert_eq!(
            segments("a {{b} {file}c"),
            vec![
                Segment::Literal("a {"),
                Segment::Literal("b} "),
                Segment::Placeholder("file"),
                Segment::Literal("c"),
            ]
        );
        let text = VALID
            .replace(
                "mix chg.static --base {base}",
                "mix chg.static --base {base} --out ${TMPDIR}/x",
            )
            .replace("mix chg.run --tests {file}", "awk '{print $1}' {file}")
            .replace(
                "\"{workspace_slot}\" }",
                "\"{workspace_slot}\", PATH = \"${HOME}/bin\" }",
            );
        assert!(parse(&text).is_ok(), "{:?}", parse(&text).err());
    }

    #[test]
    fn reports_toml_syntax_errors() {
        assert!(errs("[adapter")[0].starts_with("not valid TOML"));
    }
}
