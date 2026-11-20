//! Records the commit `chg` is built from, so `chg --version` names it: a Mac builds from
//! source (releases carry no macOS binary), and a hand-built binary was otherwise
//! anonymous. `CHG_BUILD_SHA` set at build time wins; outside a git checkout it is
//! `unknown`, and a tree with uncommitted changes to tracked files adds `-dirty`.

use std::path::{Path, PathBuf};
use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).output().ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn main() {
    println!("cargo:rerun-if-env-changed=CHG_BUILD_SHA");
    let sha = match std::env::var("CHG_BUILD_SHA") {
        Ok(s) if !s.is_empty() => s,
        _ => {
            // A new commit, checkout or staged change moves the git files; an edit to the
            // source or a manifest reruns the build script through its own path. Only paths
            // that exist: cargo counts a missing one as always changed, which would rebuild
            // chg on every run (a repo with no packed-refs, or with reftable).
            let mut watch: Vec<PathBuf> = ["src", "Cargo.toml", "../Cargo.toml", "../Cargo.lock"]
                .into_iter()
                .map(PathBuf::from)
                .collect();
            if let Some(dir) = git(&["rev-parse", "--absolute-git-dir"]) {
                watch.extend(["HEAD", "index"].map(|f| Path::new(&dir).join(f)));
            }
            if let Some(common) = git(&["rev-parse", "--path-format=absolute", "--git-common-dir"])
            {
                watch.extend(["refs", "packed-refs"].map(|f| Path::new(&common).join(f)));
            }
            for p in watch.iter().filter(|p| p.exists()) {
                println!("cargo:rerun-if-changed={}", p.display());
            }
            match git(&["rev-parse", "--short=12", "HEAD"]) {
                Some(head) => {
                    let dirty = git(&["status", "--porcelain", "--untracked-files=no"])
                        .is_some_and(|s| !s.is_empty());
                    if dirty { format!("{head}-dirty") } else { head }
                }
                None => "unknown".into(),
            }
        }
    };
    println!("cargo:rustc-env=CHG_BUILD_SHA={sha}");
}
