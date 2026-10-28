//! The per-machine snapshot store (design §3.5).
//!
//! ```text
//! <root>/<repo-key>/
//!   lock                       flock: shared while hydrating, exclusive for GC and for
//!                              a build's swap into snapshots/<sha>
//!   build.lock                 flock: held for a snapshot build or a shadow check, both
//!                              of which run at build/
//!   snapshots/<sha>/           a source checkout plus the adapter's artifacts
//!   snapshots/<sha>/.chg-snapshot.json
//!   build/                     where every snapshot is built and every shadow check runs;
//!                              a finished build is renamed to snapshots/<sha>
//!   leases/<sha>/<slot>        one per workspace hydrated from <sha>
//!   history/<sha>.cover        a coverage record (`cover.rs`)
//! ```
//!
//! The store is a cache: deleting any of it costs a rebuild, never correctness.

use std::fs::{self, File};
use std::io;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::git;

/// Snapshots kept regardless of leases.
pub const KEEP: usize = 3;
/// A lease protects its snapshot for this long after the workspace was cloned from it.
pub const LEASE_TTL: Duration = Duration::from_secs(24 * 3600);
pub const META: &str = ".chg-snapshot.json";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Meta {
    pub sha: String,
    /// Unix milliseconds; orders snapshots newest first.
    pub built_at_ms: u64,
    /// The snapshot this one was cloned from, if any. Its own sha when a snapshot built at
    /// another path was rebuilt from that old tree of the same commit.
    pub from: Option<String>,
    pub work: String,
    pub ms: u64,
    /// The resolved build path this snapshot was built at. A snapshot built elsewhere
    /// (before #46, or before the store moved) recompiles in full wherever it is used, so
    /// a build of its sha replaces it. Snapshots from before this field have none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub built_in: Option<String>,
}

impl Meta {
    /// Built at `dir` (a `Store::resolved_build_dir`), so reusing it there recompiles only
    /// the delta.
    pub fn is_built_at(&self, dir: &Path) -> bool {
        self.built_in.as_deref() == Some(&*dir.to_string_lossy())
    }
}

/// The store root: `CHG_STORE`, else the platform default. Linux prefers the chg XFS
/// volume, because cloning only works when the store and the workspaces share it. Its
/// `store` dir exists only on the mounted volume, so an unmounted `/srv/chg` (an empty
/// root-owned dir) is not mistaken for it.
pub fn root() -> PathBuf {
    if let Some(r) = std::env::var_os("CHG_STORE") {
        // Absolute, because git resolves GIT_WORK_TREE against its own `-C` dir.
        let r = PathBuf::from(r);
        return std::path::absolute(&r).unwrap_or(r);
    }
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| "/".into()));
    if cfg!(target_os = "macos") {
        return home.join("Library/Caches/chg");
    }
    let vol = Path::new("/srv/chg/store");
    if vol.is_dir() {
        return vol.to_path_buf();
    }
    std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".cache"))
        .join("chg")
}

pub fn fnv8(bytes: &[u8]) -> String {
    // FNV-1a: stable across Rust versions, unlike DefaultHasher.
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{:08x}", h as u32)
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub struct Store {
    pub dir: PathBuf,
}

/// An flock held until drop.
pub struct Lock(#[allow(dead_code)] File);

/// `op` on `dir/name`, creating both. With `LOCK_NB`: `Ok(None)` when another process
/// holds it.
fn flock(dir: &Path, name: &str, op: libc::c_int) -> io::Result<Option<Lock>> {
    fs::create_dir_all(dir)?;
    let f = File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join(name))?;
    // SAFETY: flock on an fd we own; released when the File closes.
    if unsafe { libc::flock(f.as_raw_fd(), op) } != 0 {
        let e = io::Error::last_os_error();
        if op & libc::LOCK_NB != 0 && e.raw_os_error() == Some(libc::EWOULDBLOCK) {
            return Ok(None);
        }
        return Err(e);
    }
    Ok(Some(Lock(f)))
}

/// `try_once` (a non-blocking flock) polled until it takes the lock or `wait` passes.
fn wait_lock(
    wait: Duration,
    try_once: impl Fn() -> io::Result<Option<Lock>>,
) -> io::Result<Option<Lock>> {
    let deadline = std::time::Instant::now() + wait;
    loop {
        if let Some(l) = try_once()? {
            return Ok(Some(l));
        }
        if std::time::Instant::now() >= deadline {
            return Ok(None);
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

impl Store {
    /// The store for the repo `path` belongs to; every worktree of a repo shares one.
    pub fn for_repo(path: &Path) -> Result<Store, String> {
        let common = git::common_dir(path)?;
        let common = fs::canonicalize(&common).unwrap_or(common);
        let key = format!(
            "{}-{}",
            git::common_dir_name(&common),
            fnv8(common.as_os_str().as_encoded_bytes())
        );
        Ok(Store {
            dir: root().join(key),
        })
    }

    pub fn snapshots(&self) -> PathBuf {
        self.dir.join("snapshots")
    }

    pub fn snapshot(&self, sha: &str) -> PathBuf {
        self.snapshots().join(sha)
    }

    /// Where a snapshot dir is renamed to before it is deleted outside the lock.
    pub fn trash_path(&self, sha: &str) -> PathBuf {
        self.snapshots()
            .join(format!(".trash-{sha}-{}-{}", std::process::id(), now_ms()))
    }

    fn leases(&self, sha: &str) -> PathBuf {
        self.dir.join("leases").join(sha)
    }

    fn lock(&self, name: &str, exclusive: bool) -> io::Result<Lock> {
        let op = if exclusive {
            libc::LOCK_EX
        } else {
            libc::LOCK_SH
        };
        self.flock(name, op)
            .map(|l| l.expect("a blocking flock always returns a lock"))
    }

    fn flock(&self, name: &str, op: libc::c_int) -> io::Result<Option<Lock>> {
        flock(&self.dir, name, op)
    }

    /// Held while a workspace takes its lease and clones; GC waits for it.
    pub fn lock_shared(&self) -> io::Result<Lock> {
        self.lock("lock", false)
    }

    pub fn lock_exclusive(&self) -> io::Result<Lock> {
        self.lock("lock", true)
    }

    /// Held for a whole snapshot build or shadow check: both run at `build_dir()`, in one
    /// workspace slot and test database, which this lock alone keeps from being shared.
    pub fn lock_build(&self) -> io::Result<Lock> {
        self.lock("build.lock", true)
    }

    /// The build lock if no build holds it now, else `None`.
    pub fn try_lock_build(&self) -> io::Result<Option<Lock>> {
        self.flock("build.lock", libc::LOCK_EX | libc::LOCK_NB)
    }

    /// The build lock, or `None` once `wait` has passed with it still held.
    pub fn lock_build_within(&self, wait: Duration) -> io::Result<Option<Lock>> {
        wait_lock(wait, || self.try_lock_build())
    }

    /// The one path where snapshots are built and shadow checks run. A build bakes its
    /// path into the artifacts: Phoenix's `embed_templates` hashes absolute template paths
    /// into `__mix_recompile__?`, and config may expand paths, so the same build reused
    /// at another path recompiles those modules and everything compiled against them.
    /// Building where the checks run makes a snapshot exact for them.
    pub fn build_dir(&self) -> PathBuf {
        self.dir.join("build")
    }

    /// `build_dir` with symlinks resolved, as the adapter sees it. Resolved through the
    /// repo's store dir, because the build dir itself exists only during a build or check.
    pub fn resolved_build_dir(&self) -> PathBuf {
        fs::canonicalize(&self.dir)
            .map(|d| d.join("build"))
            .unwrap_or_else(|_| self.build_dir())
    }

    /// Held for a whole job of `name` (`culprit`, `revert`) in this repo: each job owns one
    /// fixed worktree, `job_dir(name)/ws`, so one workspace slot and test database.
    pub fn lock_job(&self, name: &str) -> io::Result<Lock> {
        self.lock(&format!("{name}.lock"), true)
    }

    pub fn job_dir(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }

    /// Held for a whole shadow check. It lives at the store root, not in this repo's
    /// dir, so pushes in quick succession queue across every repo and clone on this
    /// machine instead of running their suites at once beside the real gate. `None` once
    /// `wait` has passed with the lock still held elsewhere.
    pub fn lock_shadow(&self, wait: Duration) -> io::Result<Option<Lock>> {
        let root = root();
        wait_lock(wait, || {
            flock(&root, "shadow.lock", libc::LOCK_EX | libc::LOCK_NB)
        })
    }

    /// Complete snapshots, newest first. A directory without readable meta is a
    /// build that never finished and is not a snapshot.
    pub fn list(&self) -> Vec<Meta> {
        let mut out: Vec<Meta> = fs::read_dir(self.snapshots())
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
            .filter_map(|e| fs::read(e.path().join(META)).ok())
            .filter_map(|b| serde_json::from_slice::<Meta>(&b).ok())
            .collect();
        out.sort_by(|a, b| b.built_at_ms.cmp(&a.built_at_ms).then(b.sha.cmp(&a.sha)));
        out
    }

    /// The snapshot nearest to `head` among those that are its ancestors (or equal):
    /// fewest commits between them. With `at`, the resolved build path, one built there
    /// ranks before any built elsewhere, which would recompile in full at that path.
    pub fn nearest_ancestor(
        &self,
        repo: &Path,
        head: &str,
        at: Option<&Path>,
    ) -> Result<Option<(Meta, u64)>, String> {
        // A snapshot of a commit this clone never fetched is not an ancestor; any other
        // git failure is an error, not "no snapshot".
        let mut ancestors = Vec::new();
        for m in self.list() {
            if git::is_ancestor_if_present(repo, &m.sha, head)? {
                let d = git::distance(repo, &m.sha, head)?;
                ancestors.push((m, d));
            }
        }
        Ok(ancestors
            .into_iter()
            .min_by_key(|(m, d)| (at.is_some_and(|a| !m.is_built_at(a)), *d)))
    }

    /// Records that the workspace `ws` (slot `slot`) was cloned from `sha`. Call with the
    /// shared lock held, before cloning.
    pub fn lease(&self, sha: &str, slot: &str, ws: &Path) -> io::Result<()> {
        let dir = self.leases(sha);
        fs::create_dir_all(&dir)?;
        fs::write(dir.join(slot), ws.as_os_str().as_encoded_bytes())
    }

    /// A lease is live while its workspace exists and is younger than the TTL.
    fn has_live_lease(&self, sha: &str, now: SystemTime) -> bool {
        fs::read_dir(self.leases(sha))
            .into_iter()
            .flatten()
            .flatten()
            .any(|e| {
                let fresh = e
                    .metadata()
                    .and_then(|m| m.modified())
                    .is_ok_and(|t| now.duration_since(t).unwrap_or_default() < LEASE_TTL);
                let ws = fs::read(e.path())
                    .ok()
                    .map(|b| PathBuf::from(String::from_utf8_lossy(&b).into_owned()));
                fresh && ws.is_some_and(|p| p.exists())
            })
    }

    /// Keeps the newest `KEEP` snapshots and every snapshot with a live lease; removes the
    /// rest, every directory that is not a snapshot (missing or unreadable meta), and
    /// trash older than a day. Returns the removed shas.
    pub fn gc(&self) -> io::Result<Vec<String>> {
        let now = SystemTime::now();
        let mut doomed = Vec::new();
        {
            let _lock = self.lock_exclusive()?;
            let listed = self.list();
            let mut drop: Vec<String> = listed
                .iter()
                .enumerate()
                .filter(|(i, m)| *i >= KEEP && !self.has_live_lease(&m.sha, now))
                .map(|(_, m)| m.sha.clone())
                .collect();
            // Hydrate never uses a dir without readable meta, so nothing else would ever
            // remove it.
            drop.extend(
                fs::read_dir(self.snapshots())
                    .into_iter()
                    .flatten()
                    .flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .filter(|n| !n.starts_with('.') && !listed.iter().any(|m| m.sha == *n)),
            );
            for sha in drop {
                let trash = self.trash_path(&sha);
                // One that cannot be moved is left for the next GC; the rest still go.
                if fs::rename(self.snapshot(&sha), &trash).is_ok() {
                    let _ = fs::remove_dir_all(self.leases(&sha));
                    doomed.push((sha, trash));
                }
            }
            for e in fs::read_dir(self.snapshots())
                .into_iter()
                .flatten()
                .flatten()
            {
                let n = e.file_name().to_string_lossy().into_owned();
                let old = e
                    .metadata()
                    .and_then(|m| m.modified())
                    .is_ok_and(|t| now.duration_since(t).unwrap_or_default() > LEASE_TTL);
                if n.starts_with(".trash-") && old {
                    doomed.push((String::new(), e.path()));
                }
            }
        }
        // Deleting a tree can take a while; nothing holds the lock for it.
        let mut removed = Vec::new();
        for (sha, path) in doomed {
            let _ = fs::remove_dir_all(&path);
            if !sha.is_empty() {
                removed.push(sha);
            }
        }
        Ok(removed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_timed_build_lock_gives_up_after_its_wait_and_takes_a_free_lock_at_once() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store {
            dir: dir.path().join("repo"),
        };
        let held = store.lock_build_within(Duration::ZERO).unwrap();
        assert!(held.is_some(), "free, so taken at once");
        let t = std::time::Instant::now();
        assert!(
            store
                .lock_build_within(Duration::from_millis(700))
                .unwrap()
                .is_none()
        );
        assert!(t.elapsed() >= Duration::from_millis(700));
        assert!(store.try_lock_build().unwrap().is_none(), "the same lock");
        drop(held);
        assert!(store.lock_build_within(Duration::ZERO).unwrap().is_some());
    }

    #[test]
    fn a_timed_build_lock_takes_the_lock_once_its_holder_lets_go() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store {
            dir: dir.path().join("repo"),
        };
        let held = store.lock_build_within(Duration::ZERO).unwrap().unwrap();
        let releaser = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(1_200));
            drop(held);
        });
        let t = std::time::Instant::now();
        let got = store.lock_build_within(Duration::from_secs(10)).unwrap();
        assert!(got.is_some(), "taken once the holder let go");
        assert!(t.elapsed() >= Duration::from_millis(1_200), "it waited");
        assert!(
            t.elapsed() < Duration::from_secs(5),
            "and did not wait out its deadline"
        );
        releaser.join().unwrap();
    }
}
