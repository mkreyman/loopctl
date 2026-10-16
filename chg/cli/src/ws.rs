//! `chg ws hydrate` (design §3.5, story S4): clone the adapter's artifact paths from the
//! nearest-ancestor snapshot into a fresh worktree.
//!
//! Only what the worktree lacks is cloned: a file it already has wins, and an artifact
//! dir it already has (`priv/plts` holding a tracked `.gitkeep`) is filled in around
//! what is there.
//!
//! All or nothing. Every missing path is cloned into a staging dir inside the worktree
//! (same filesystem, so the clone and the renames work), then renamed into place. Each
//! change to the worktree is journaled in its git dir before it is made: a failure undoes
//! them at once, and a hydrate killed between renames is undone by the next one. A
//! worktree is either fully hydrated or exactly as `git worktree add` left it, which is
//! today's cold path.
//!
//! Then every tracked file whose content equals the snapshot's copy gets the snapshot's
//! mtime, and so does every directory whose entries are the same. `git worktree add`
//! stamps everything with the checkout time, and mix checks `@external_resource` paths
//! (files and directories) by mtime alone: in HCB that recompiled 870 of 2216 modules
//! whose sources had not changed. Only identical content is re-stamped, so a changed
//! file or a directory that gained or lost an entry still looks changed.

use std::fs::{self, File};
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::Instant;

use crate::clone::clone_tree;
use crate::contract;
use crate::exec;
use crate::git;
use crate::store::Store;

pub const STAGING: &str = ".chg-hydrate.tmp";
/// In the worktree's own git dir, so it never shows up as an untracked file.
pub const JOURNAL: &str = "chg-hydrate.journal";

#[derive(Debug)]
pub enum Hydrated {
    Done {
        snapshot: String,
        behind: u64,
        paths: Vec<String>,
        ms: u128,
    },
    /// No snapshot is an ancestor of HEAD (exit 3).
    NoSnapshot,
}

pub fn hydrate(ws: &Path) -> Result<Hydrated, String> {
    let started = Instant::now();
    let head = git::resolve(ws, "HEAD")?;
    let store = Store::for_repo(ws)?;
    let journal = git::git_dir(ws)?.join(JOURNAL);
    recover(&journal).map_err(|e| format!("undoing an interrupted hydrate: {e}"))?;

    // The shared lock covers choosing the snapshot, taking the lease and cloning, so GC
    // cannot delete the snapshot in between.
    let lock = store
        .lock_shared()
        .map_err(|e| format!("store lock: {e}"))?;
    let Some((snap, behind)) = store.nearest_ancestor(ws, &head) else {
        return Ok(Hydrated::NoSnapshot);
    };
    let snap_dir = store.snapshot(&snap.sha);
    // The snapshot's own manifest says what it built.
    let manifest = contract::load(&snap_dir).map_err(|e| format!("snapshot {}: {e}", snap.sha))?;

    let mut roots = Vec::new();
    for pattern in &manifest.artifacts {
        roots.extend(expand(&snap_dir, pattern)?);
    }
    roots.sort();
    roots.dedup();
    // A path inside another artifact arrives with its parent's clone.
    let all = roots.clone();
    roots.retain(|p| !all.iter().any(|q| p.starts_with(&format!("{q}/"))));
    let mut paths = Vec::new();
    for r in &roots {
        missing(&snap_dir, ws, r, &mut paths)?;
    }

    store
        .lease(&snap.sha, &exec::workspace_slot(ws), ws)
        .map_err(|e| format!("taking a lease: {e}"))?;

    let staging = ws.join(STAGING);
    let _ = fs::remove_dir_all(&staging); // left by a crashed hydrate
    let result = stage_and_move(&snap_dir, ws, &staging, &paths, lock, &journal);
    let _ = fs::remove_dir_all(&staging);
    result?;
    // The lease keeps the snapshot from GC without the lock. A failure here costs a
    // larger first compile, never correctness, so it warns instead of undoing.
    if let Err(e) = align_mtimes(ws, &snap_dir) {
        eprintln!(
            "chg: hydrated, but source mtimes were not aligned ({e}); the first build may recompile more"
        );
    }

    Ok(Hydrated::Done {
        snapshot: snap.sha,
        behind,
        paths,
        ms: started.elapsed().as_millis(),
    })
}

/// Gives each tracked file of `ws` that is byte-identical to the snapshot's copy, and
/// each directory holding tracked files whose entries match the snapshot's, the
/// snapshot's mtime: the mtime its artifacts were built against.
fn align_mtimes(ws: &Path, snap: &Path) -> Result<(), String> {
    let mut c = git::cmd(ws);
    c.args(["ls-files", "-z"]);
    let out = git::run(c)?;
    let mut dirs = std::collections::BTreeSet::new();
    for f in out.stdout.split(|b| *b == 0).filter(|f| !f.is_empty()) {
        let rel = Path::new(std::ffi::OsStr::from_bytes(f));
        dirs.extend(
            rel.ancestors()
                .skip(1)
                .filter(|d| !d.as_os_str().is_empty()),
        );
        let (here, there) = (ws.join(rel), snap.join(rel));
        let (Ok(a), Ok(b)) = (here.symlink_metadata(), there.symlink_metadata()) else {
            continue;
        };
        if !a.is_file()
            || !b.is_file()
            || a.len() != b.len()
            || a.modified().ok() == b.modified().ok()
        {
            continue;
        }
        if fs::read(&here).ok() != fs::read(&there).ok() {
            continue;
        }
        let m = b
            .modified()
            .map_err(|e| format!("{}: {e}", there.display()))?;
        File::open(&here)
            .and_then(|f| f.set_modified(m))
            .map_err(|e| format!("{}: {e}", here.display()))?;
    }
    // After the files: re-stamping a file never changes its directory's mtime.
    let names = |d: &Path| -> Option<Vec<std::ffi::OsString>> {
        let mut v: Vec<_> = fs::read_dir(d)
            .ok()?
            .flatten()
            .map(|e| e.file_name())
            .collect();
        v.sort();
        Some(v)
    };
    for rel in dirs {
        let (here, there) = (ws.join(rel), snap.join(rel));
        let Ok(m) = there.metadata().and_then(|m| m.modified()) else {
            continue;
        };
        if names(&here).is_some() && names(&here) == names(&there) {
            File::open(&here)
                .and_then(|f| f.set_modified(m))
                .map_err(|e| format!("{}: {e}", here.display()))?;
        }
    }
    Ok(())
}

/// Adds to `out` the parts of the snapshot's `rel` that the worktree lacks: `rel`
/// itself when absent, else, where both sides are directories, the missing entries
/// below it.
fn missing(snap: &Path, ws: &Path, rel: &str, out: &mut Vec<String>) -> Result<(), String> {
    let Ok(here) = ws.join(rel).symlink_metadata() else {
        out.push(rel.to_string());
        return Ok(());
    };
    let src = snap.join(rel);
    if !here.is_dir() || !src.symlink_metadata().is_ok_and(|m| m.is_dir()) {
        return Ok(());
    }
    let mut names: Vec<String> = fs::read_dir(&src)
        .map_err(|e| format!("reading {}: {e}", src.display()))?
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    for n in names {
        missing(snap, ws, &join(rel, &n), out)?;
    }
    Ok(())
}

/// One change hydrate makes to the worktree: a dir it created or a path it moved in.
enum Change {
    Created(PathBuf),
    Moved(PathBuf),
}

impl Change {
    fn undo(&self) {
        match self {
            Change::Moved(p) => {
                let _ = fs::remove_dir_all(p).or_else(|_| fs::remove_file(p));
            }
            Change::Created(d) => {
                let _ = fs::remove_dir(d);
            }
        }
    }
}

/// Appends `c` to the journal and syncs it, before the change is made.
fn record(journal: &mut File, c: &Change) -> Result<(), String> {
    let (tag, p) = match c {
        Change::Created(p) => (b'D', p),
        Change::Moved(p) => (b'M', p),
    };
    let mut line = vec![tag];
    line.extend_from_slice(p.as_os_str().as_bytes());
    line.push(0);
    journal
        .write_all(&line)
        .and_then(|_| journal.sync_data())
        .map_err(|e| format!("writing the hydrate journal: {e}"))
}

/// Undoes, newest first, every change in a journal a killed hydrate left behind.
fn recover(journal: &Path) -> std::io::Result<()> {
    let bytes = match fs::read(journal) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    let changes: Vec<Change> = bytes
        .split(|b| *b == 0)
        .filter_map(|e| {
            let (tag, p) = e.split_first()?;
            let p = PathBuf::from(std::ffi::OsStr::from_bytes(p));
            match tag {
                b'D' => Some(Change::Created(p)),
                b'M' => Some(Change::Moved(p)),
                _ => None,
            }
        })
        .collect();
    for c in changes.iter().rev() {
        c.undo();
    }
    fs::remove_file(journal)
}

fn stage_and_move(
    snap: &Path,
    ws: &Path,
    staging: &Path,
    paths: &[String],
    lock: crate::store::Lock,
    journal_path: &Path,
) -> Result<(), String> {
    for p in paths {
        let to = staging.join(p);
        fs::create_dir_all(to.parent().expect("staged path has a parent"))
            .map_err(|e| format!("staging {p}: {e}"))?;
        clone_tree(&snap.join(p), &to).map_err(|e| format!("cloning {p}: {e}"))?;
    }
    drop(lock); // the clones are ours now; GC may proceed

    let mut journal = File::create(journal_path)
        .map_err(|e| format!("creating {}: {e}", journal_path.display()))?;
    let mut done: Vec<Change> = Vec::new();
    let mut result = Ok(());
    for p in paths {
        let to = ws.join(p);
        result = ensure_parent(ws, &to, &mut journal, &mut done).and_then(|_| {
            let c = Change::Moved(to.clone());
            record(&mut journal, &c)?;
            fs::rename(staging.join(p), &to).map_err(|e| format!("moving {p} into place: {e}"))?;
            done.push(c);
            Ok(())
        });
        if result.is_err() {
            break;
        }
    }
    // A failure undoes only what was done; the journal also names a change that was
    // recorded but failed, which must not be removed (the path may be someone else's).
    if let Err(e) = result {
        for c in done.iter().rev() {
            c.undo();
        }
        let _ = fs::remove_file(journal_path);
        return Err(format!(
            "{e}; the worktree was restored to its unhydrated state"
        ));
    }
    fs::remove_file(journal_path).map_err(|e| format!("removing the hydrate journal: {e}"))
}

/// Creates the missing parents of `path` under `ws`, journaling each for rollback.
fn ensure_parent(
    ws: &Path,
    path: &Path,
    journal: &mut File,
    done: &mut Vec<Change>,
) -> Result<(), String> {
    let parent = path.parent().expect("artifact path has a parent");
    let mut missing = Vec::new();
    let mut cur = parent;
    while cur != ws && cur.symlink_metadata().is_err() {
        missing.push(cur.to_path_buf());
        cur = cur.parent().expect("inside the worktree");
    }
    for d in missing.into_iter().rev() {
        let c = Change::Created(d.clone());
        record(journal, &c)?;
        fs::create_dir(&d).map_err(|e| format!("creating {}: {e}", d.display()))?;
        done.push(c);
    }
    Ok(())
}

/// Expands an artifact pattern against the snapshot. `*` and `?` match within one path
/// component; patterns that match nothing yield nothing (the adapter may not have built
/// every artifact).
pub fn expand(root: &Path, pattern: &str) -> Result<Vec<String>, String> {
    if pattern.contains("**") {
        return Err(format!(
            "artifact pattern \"{pattern}\" uses `**`; artifacts name directories, use `*`"
        ));
    }
    let mut found = vec![String::new()];
    for comp in pattern.split('/').filter(|c| !c.is_empty() && *c != ".") {
        let mut next = Vec::new();
        for base in &found {
            let dir = root.join(base);
            if comp.contains(['*', '?']) {
                let mut names: Vec<String> = fs::read_dir(&dir)
                    .into_iter()
                    .flatten()
                    .flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .filter(|n| wildcard(comp, n))
                    .collect();
                names.sort();
                next.extend(names.into_iter().map(|n| join(base, &n)));
            } else if dir.join(comp).symlink_metadata().is_ok() {
                next.push(join(base, comp));
            }
        }
        found = next;
    }
    Ok(found.into_iter().filter(|p| !p.is_empty()).collect())
}

fn join(base: &str, name: &str) -> String {
    if base.is_empty() {
        name.to_string()
    } else {
        format!("{base}/{name}")
    }
}

/// `*` any run of characters, `?` one character; a leading `.` must be matched literally.
/// One path segment against a `*`/`?` pattern (`glob`'s matcher). Unlike a manifest glob,
/// a pattern not starting with `.` skips hidden names, as a shell would.
fn wildcard(pattern: &str, name: &str) -> bool {
    if name.starts_with('.') && !pattern.starts_with('.') {
        return false;
    }
    crate::glob::segment(pattern, name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wildcards() {
        assert!(wildcard("*", "api"));
        assert!(!wildcard("*", ".hidden"));
        assert!(wildcard("a?i", "api"));
        assert!(wildcard("*-web", "fleet-web"));
        assert!(!wildcard("*-web", "fleet-api"));
    }

    #[test]
    fn expands_patterns_against_the_snapshot() {
        let t = tempfile::tempdir().unwrap();
        for d in [
            "deps",
            "apps/api/node_modules",
            "apps/web/node_modules",
            "apps/docs",
            "_build",
        ] {
            fs::create_dir_all(t.path().join(d)).unwrap();
        }
        assert_eq!(expand(t.path(), "deps").unwrap(), vec!["deps"]);
        assert_eq!(
            expand(t.path(), "apps/*/node_modules").unwrap(),
            vec!["apps/api/node_modules", "apps/web/node_modules"]
        );
        assert!(expand(t.path(), "priv/plts").unwrap().is_empty());
        assert!(expand(t.path(), "**/dist").is_err());
    }
}
