//! `chg doctor`'s check that the repo's worktrees and its snapshot store share a
//! filesystem that can clone (design §3.5). Without it every hydrate copies the snapshot
//! byte by byte: slow, never wrong, so nothing else reports it.

use std::fs;
use std::path::{Path, PathBuf};

use crate::clone::{clone_tree, no_reflink};
use crate::git;
use crate::store::Store;

/// One check's outcome: `ok` and what was found, or not ok with what to do.
pub struct Finding {
    pub ok: bool,
    pub text: String,
}

fn ok(text: String) -> Finding {
    Finding { ok: true, text }
}

fn problem(text: String) -> Finding {
    Finding { ok: false, text }
}

/// The nearest existing directory at or above `p`.
fn existing(p: &Path) -> PathBuf {
    p.ancestors()
        .find(|a| a.is_dir())
        .unwrap_or(Path::new("/"))
        .to_path_buf()
}

/// Whether the worktrees of `repo` (its main checkout's `.claude/worktrees`) can be
/// hydrated by cloning from its snapshot store. A repo whose adapter names no
/// `artifacts` hydrates nothing, so it passes.
pub fn worktrees_and_store(repo: &Path, artifacts: &[String]) -> Result<Finding, String> {
    if artifacts.is_empty() {
        return Ok(ok(
            "the adapter names no artifacts: hydrate has nothing to clone".to_string(),
        ));
    }
    let common = git::common_dir(repo)?;
    let common = fs::canonicalize(&common).unwrap_or(common);
    let main = common
        .parent()
        .ok_or_else(|| format!("{} has no parent", common.display()))?;
    let link = main.join(".claude/worktrees");
    let Ok(worktrees) = fs::canonicalize(&link) else {
        return Ok(ok(format!(
            "{} does not exist; worktrees elsewhere are not checked",
            link.display()
        )));
    };
    let store = Store::for_repo(repo)?;
    let store_dir = existing(&store.dir);
    let fix = "point .claude/worktrees at the store's volume: bin/chg-volume-setup.sh --enroll \
               <repo> makes it a symlink into /srv/chg/ws/<repo>";

    // Whether the two can clone is a fact only a clone shows: two device numbers may still
    // clone (btrfs subvolumes), and one may not (ext4).
    let probe = tempfile::Builder::new()
        .prefix(".chg-doctor-")
        .tempfile_in(&store_dir)
        .map_err(|e| format!("a probe file in {}: {e}", store_dir.display()))?;
    fs::write(probe.path(), b"chg doctor\n").map_err(|e| format!("writing the probe: {e}"))?;
    let target = worktrees.join(format!(".chg-doctor-{}", std::process::id()));
    let _ = fs::remove_file(&target);
    let cloned = clone_tree(probe.path(), &target);
    let _ = fs::remove_file(&target);
    match cloned {
        Ok(()) => Ok(ok(format!(
            "{} and the snapshot store {} share a filesystem that clones",
            link.display(),
            store_dir.display()
        ))),
        Err(e) if no_reflink(&e) => Ok(problem(format!(
            "{} ({}) cannot be cloned into from the snapshot store {} ({e}): every \
             hydrate copies byte by byte. Fix: {fix}",
            link.display(),
            worktrees.display(),
            store_dir.display()
        ))),
        Err(e) => Err(format!(
            "cloning a probe file into {}: {e}",
            worktrees.display()
        )),
    }
}

#[cfg(test)]
mod tests {
    /// A repo whose adapter names no artifacts (the generic adapter) hydrates nothing, so
    /// where its worktrees live cannot fail doctor.
    #[test]
    fn no_artifacts_passes_without_looking() {
        let t = tempfile::tempdir().unwrap();
        let f = super::worktrees_and_store(t.path(), &[]).unwrap();
        assert!(f.ok, "{}", f.text);
        assert!(f.text.contains("no artifacts"), "{}", f.text);
    }
}
