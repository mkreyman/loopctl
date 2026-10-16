//! The per-machine snapshot store (design §3.5).
//!
//! ```text
//! <root>/<repo-key>/
//!   lock                       flock: shared while hydrating, exclusive for GC
//!   build.lock                 flock: one snapshot build per repo at a time
//!   snapshots/<sha>/           a source checkout plus the adapter's artifacts
//!   snapshots/<sha>/.chg-snapshot.json
//!   snapshots/.tmp-<sha>-<pid> a build in progress; renamed into place when done
//!   leases/<sha>/<slot>        one per workspace hydrated from <sha>
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
    /// The snapshot this one was cloned from, if any.
    pub from: Option<String>,
    pub work: String,
    pub ms: u64,
}

/// The store root: `CHG_STORE`, else the platform default. Linux prefers the chg XFS
/// volume, because cloning only works when the store and the workspaces share it. Its
/// `store` dir exists only on the mounted volume, so an unmounted `/srv/chg` (an empty
/// root-owned dir) is not mistaken for it.
pub fn root() -> PathBuf {
    if let Some(r) = std::env::var_os("CHG_STORE") {
        return PathBuf::from(r);
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
        fs::create_dir_all(&self.dir)?;
        let f = File::options()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.dir.join(name))?;
        let op = if exclusive {
            libc::LOCK_EX
        } else {
            libc::LOCK_SH
        };
        // SAFETY: flock on an fd we own; released when the File closes.
        if unsafe { libc::flock(f.as_raw_fd(), op) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Lock(f))
    }

    /// Held while a workspace takes its lease and clones; GC waits for it.
    pub fn lock_shared(&self) -> io::Result<Lock> {
        self.lock("lock", false)
    }

    pub fn lock_exclusive(&self) -> io::Result<Lock> {
        self.lock("lock", true)
    }

    /// Held for a whole snapshot build. Builds share one workspace slot (one test
    /// database), so two at once would run their adapters against the same database.
    pub fn lock_build(&self) -> io::Result<Lock> {
        self.lock("build.lock", true)
    }

    /// Held for a whole shadow check. It lives at the store root, not in this repo's
    /// dir, so pushes in quick succession queue across every repo and clone on this
    /// machine instead of running their suites at once beside the real gate. `None` once
    /// `wait` has passed with the lock still held elsewhere.
    pub fn lock_shadow(&self, wait: Duration) -> io::Result<Option<Lock>> {
        let root = root();
        fs::create_dir_all(&root)?;
        let f = File::options()
            .create(true)
            .truncate(false)
            .write(true)
            .open(root.join("shadow.lock"))?;
        let deadline = std::time::Instant::now() + wait;
        loop {
            // SAFETY: flock on an fd we own; released when the File closes.
            if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                return Ok(Some(Lock(f)));
            }
            let e = io::Error::last_os_error();
            if e.raw_os_error() != Some(libc::EWOULDBLOCK) {
                return Err(e);
            }
            if std::time::Instant::now() >= deadline {
                return Ok(None);
            }
            std::thread::sleep(Duration::from_millis(500));
        }
    }

    /// Where shadow checks put their throwaway worktrees: inside the store, so they sit
    /// on the snapshots' filesystem and hydrate by cloning.
    pub fn shadow_dir(&self) -> PathBuf {
        self.dir.join("shadow")
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
    /// fewest commits between them.
    pub fn nearest_ancestor(&self, repo: &Path, head: &str) -> Option<(Meta, u64)> {
        self.list()
            .into_iter()
            .filter(|m| git::is_ancestor(repo, &m.sha, head))
            .filter_map(|m| git::distance(repo, &m.sha, head).ok().map(|d| (m, d)))
            .min_by_key(|(_, d)| *d)
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
    /// abandoned builds older than a day. Returns the removed shas.
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
                if (n.starts_with(".tmp-") || n.starts_with(".trash-")) && old {
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
