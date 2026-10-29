//! Copy-on-write cloning of a directory tree (design §3.5).
//!
//! One interface, two mechanisms:
//! - macOS: `clonefile(2)` on the directory, which clones the whole tree in one call on
//!   APFS (the mechanism behind `cp -c`).
//! - Linux: a walk that clones each regular file with the `FICLONE` ioctl in parallel
//!   (`cp --reflink=always`), recreating directories and symlinks and keeping modes and
//!   mtimes, which `mix` reads.
//!
//! Neither ever falls back to a byte copy on its own: a tree too big to copy is exactly
//! the case cloning exists for, so an unsupported filesystem is an error naming the fix,
//! marked `NoReflink` so a caller that must work anyway (`chg ws hydrate`) can copy with
//! `copy_tree` and say what it cost.

use std::fs::{self, File, FileTimes};
use std::io;
use std::path::Path;

/// The payload of a clone error that only a byte copy can get past: source and target on
/// different filesystems, or a filesystem that cannot clone.
#[derive(Debug)]
pub struct NoReflink(pub String);

impl std::fmt::Display for NoReflink {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for NoReflink {}

/// Whether `e` is a clone that failed because cloning is impossible there.
pub fn no_reflink(e: &io::Error) -> bool {
    e.get_ref().is_some_and(|i| i.is::<NoReflink>())
}

/// Copies `src` (a directory, file or symlink) to `dst` byte by byte, keeping modes and
/// mtimes as `clone_tree` does. Returns the bytes copied. `dst` must not exist.
pub fn copy_tree(src: &Path, dst: &Path) -> io::Result<u64> {
    let meta = fs::symlink_metadata(src)?;
    let t = meta.file_type();
    if t.is_symlink() {
        std::os::unix::fs::symlink(fs::read_link(src)?, dst)?;
        return Ok(0);
    }
    if t.is_file() {
        let n = fs::copy(src, dst)?;
        // Read-only: the copy has the source's mode, which may forbid writing (0444).
        File::open(dst)?.set_times(
            FileTimes::new()
                .set_accessed(meta.accessed()?)
                .set_modified(meta.modified()?),
        )?;
        return Ok(n);
    }
    if !t.is_dir() {
        return Ok(0); // sockets, fifos and devices are not build artifacts
    }
    fs::create_dir(dst)?;
    let mut n = 0;
    for e in fs::read_dir(src)? {
        let e = e?;
        n += copy_tree(&e.path(), &dst.join(e.file_name()))?;
    }
    // Last: writing the entries changed the directory's mtime, and a read-only mode would
    // have blocked them.
    File::open(dst)?.set_times(
        FileTimes::new()
            .set_accessed(meta.accessed()?)
            .set_modified(meta.modified()?),
    )?;
    fs::set_permissions(dst, meta.permissions())?;
    Ok(n)
}

/// Clones `src` (a directory, file or symlink) to `dst`, which must not exist and whose
/// parent must exist on the same filesystem. On error `dst` may be partly written; the
/// caller clones into a staging path and removes it on failure.
pub fn clone_tree(src: &Path, dst: &Path) -> io::Result<()> {
    if dst.symlink_metadata().is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("clone target {} already exists", dst.display()),
        ));
    }
    imp::clone_tree(src, dst)
}

#[cfg(target_os = "macos")]
mod imp {
    use std::ffi::CString;
    use std::io;
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;

    /// `CLONE_NOFOLLOW` from sys/clonefile.h: clone a symlink itself, not its target.
    const CLONE_NOFOLLOW: u32 = 0x0001;

    fn cstr(p: &Path) -> io::Result<CString> {
        CString::new(p.as_os_str().as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path holds a NUL byte"))
    }

    pub fn clone_tree(src: &Path, dst: &Path) -> io::Result<()> {
        let (s, d) = (cstr(src)?, cstr(dst)?);
        // SAFETY: both pointers are valid NUL-terminated strings for the call's duration.
        let r = unsafe { libc::clonefile(s.as_ptr(), d.as_ptr(), CLONE_NOFOLLOW) };
        if r == 0 {
            return Ok(());
        }
        let e = io::Error::last_os_error();
        let hint = match e.raw_os_error() {
            Some(libc::EXDEV) => " (source and target are on different volumes)",
            Some(libc::ENOTSUP) => " (the volume is not APFS)",
            _ => "",
        };
        let msg = format!(
            "clonefile {} -> {}: {e}{hint}",
            src.display(),
            dst.display()
        );
        match e.raw_os_error() {
            Some(libc::EXDEV) | Some(libc::ENOTSUP) => {
                Err(io::Error::new(e.kind(), super::NoReflink(msg)))
            }
            _ => Err(io::Error::new(e.kind(), msg)),
        }
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use std::fs::{self, File, FileTimes, OpenOptions};
    use std::io;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt, symlink};
    use std::os::unix::io::AsRawFd;
    use std::path::{Path, PathBuf};

    use rayon::prelude::*;

    /// `_IOW(0x94, 9, int)` from linux/fs.h.
    const FICLONE: libc::c_ulong = 0x4004_9409;

    enum Entry {
        Dir(PathBuf),
        File(PathBuf),
        Link(PathBuf),
    }

    fn walk(root: &Path, rel: &Path, out: &mut Vec<Entry>) -> io::Result<()> {
        for e in fs::read_dir(root.join(rel))? {
            let e = e?;
            let r = rel.join(e.file_name());
            let t = e.file_type()?;
            if t.is_dir() {
                out.push(Entry::Dir(r.clone()));
                walk(root, &r, out)?;
            } else if t.is_symlink() {
                out.push(Entry::Link(r));
            } else if t.is_file() {
                out.push(Entry::File(r));
            }
            // Sockets, fifos and devices are not build artifacts; they are skipped.
        }
        Ok(())
    }

    fn times(m: &fs::Metadata) -> io::Result<FileTimes> {
        Ok(FileTimes::new()
            .set_accessed(m.accessed()?)
            .set_modified(m.modified()?))
    }

    fn clone_file(src: &Path, dst: &Path) -> io::Result<()> {
        let from = File::open(src)?;
        let meta = from.metadata()?;
        let to = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(meta.permissions().mode())
            .open(dst)?;
        // SAFETY: both fds are open for the duration of the call; FICLONE reads no memory.
        let r = unsafe { libc::ioctl(to.as_raw_fd(), FICLONE as _, from.as_raw_fd()) };
        if r != 0 {
            let e = io::Error::last_os_error();
            let hint = match e.raw_os_error() {
                Some(libc::EXDEV) => " (source and target are on different filesystems)",
                Some(libc::EOPNOTSUPP) | Some(libc::EINVAL) => {
                    " (the filesystem has no reflink support; put the store and workspaces on the chg XFS volume, bin/chg-volume-setup.sh)"
                }
                _ => "",
            };
            let msg = format!("FICLONE {} -> {}: {e}{hint}", src.display(), dst.display());
            return Err(match e.raw_os_error() {
                Some(libc::EXDEV) | Some(libc::EOPNOTSUPP) | Some(libc::EINVAL) => {
                    io::Error::new(e.kind(), super::NoReflink(msg))
                }
                _ => io::Error::new(e.kind(), msg),
            });
        }
        to.set_permissions(meta.permissions())?;
        to.set_times(times(&meta)?)
    }

    pub fn clone_tree(src: &Path, dst: &Path) -> io::Result<()> {
        let meta = fs::symlink_metadata(src)?;
        if meta.file_type().is_symlink() {
            return symlink(fs::read_link(src)?, dst);
        }
        if meta.is_file() {
            return clone_file(src, dst);
        }

        let mut entries = Vec::new();
        walk(src, Path::new(""), &mut entries)?;

        fs::create_dir(dst)?;
        for e in &entries {
            if let Entry::Dir(r) = e {
                fs::create_dir(dst.join(r))?;
            }
        }
        entries.par_iter().try_for_each(|e| match e {
            Entry::File(r) => clone_file(&src.join(r), &dst.join(r)),
            Entry::Link(r) => symlink(fs::read_link(src.join(r))?, dst.join(r)),
            Entry::Dir(_) => Ok(()),
        })?;

        // Directory modes and times last, deepest first: writing a child changes its
        // parent's mtime, and a read-only mode would block the writes.
        let mut dirs: Vec<&PathBuf> = entries
            .iter()
            .filter_map(|e| match e {
                Entry::Dir(r) => Some(r),
                _ => None,
            })
            .collect();
        dirs.sort_by_key(|r| std::cmp::Reverse(r.components().count()));
        for r in dirs.into_iter().map(|r| r.as_path()).chain([Path::new("")]) {
            let m = fs::metadata(src.join(r))?;
            let d = dst.join(r);
            File::open(&d)?.set_times(times(&m)?)?;
            fs::set_permissions(&d, m.permissions())?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::time::{Duration, SystemTime};

    /// A temp dir on a filesystem that supports cloning, or None (Linux without
    /// `CHG_TEST_REFLINK_DIR`, which CI points at an XFS loop mount).
    pub fn cow_tempdir() -> Option<tempfile::TempDir> {
        if cfg!(target_os = "macos") {
            return Some(tempfile::tempdir().unwrap());
        }
        match std::env::var_os("CHG_TEST_REFLINK_DIR") {
            Some(d) => Some(tempfile::tempdir_in(d).unwrap()),
            // CI must exercise the reflink path; a silent skip would merge a broken one green.
            None if std::env::var_os("CI").is_some() => {
                panic!(
                    "CHG_TEST_REFLINK_DIR is unset in CI; mount a reflink-capable dir for the clone tests"
                )
            }
            None => {
                eprintln!("skipped: set CHG_TEST_REFLINK_DIR to a reflink-capable dir");
                None
            }
        }
    }

    #[test]
    fn clones_files_dirs_symlinks_modes_and_mtimes() {
        let Some(t) = cow_tempdir() else { return };
        let src = t.path().join("src");
        fs::create_dir_all(src.join("a/b")).unwrap();
        fs::write(src.join("a/b/f.beam"), b"beam").unwrap();
        fs::write(src.join("run.sh"), b"#!/bin/sh\n").unwrap();
        fs::set_permissions(src.join("run.sh"), fs::Permissions::from_mode(0o755)).unwrap();
        symlink("a/b/f.beam", src.join("link")).unwrap();
        let old = SystemTime::now() - Duration::from_secs(86_400 * 30);
        fs::File::options()
            .write(true)
            .open(src.join("a/b/f.beam"))
            .unwrap()
            .set_modified(old)
            .unwrap();

        let dst = t.path().join("dst");
        clone_tree(&src, &dst).unwrap();

        assert_eq!(fs::read(dst.join("a/b/f.beam")).unwrap(), b"beam");
        assert_eq!(
            fs::metadata(dst.join("run.sh"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o755
        );
        assert_eq!(
            fs::read_link(dst.join("link")).unwrap(),
            Path::new("a/b/f.beam")
        );
        assert_eq!(
            fs::metadata(dst.join("a/b/f.beam"))
                .unwrap()
                .modified()
                .unwrap(),
            old
        );
        // Copy-on-write: writing the clone leaves the source alone.
        fs::write(dst.join("a/b/f.beam"), b"changed").unwrap();
        assert_eq!(fs::read(src.join("a/b/f.beam")).unwrap(), b"beam");
    }

    /// A read-only file (0444, as `deps` holds) copies with its mode and mtime: setting the
    /// times must not need write access to the copy.
    #[test]
    fn copies_a_read_only_file_with_its_mtime() {
        let t = tempfile::tempdir().unwrap();
        let src = t.path().join("src");
        fs::create_dir(&src).unwrap();
        fs::write(src.join("ro.beam"), b"beam").unwrap();
        let old = SystemTime::now() - Duration::from_secs(86_400 * 30);
        fs::File::options()
            .write(true)
            .open(src.join("ro.beam"))
            .unwrap()
            .set_modified(old)
            .unwrap();
        fs::set_permissions(src.join("ro.beam"), fs::Permissions::from_mode(0o444)).unwrap();

        let dst = t.path().join("dst");
        assert_eq!(copy_tree(&src, &dst).unwrap(), 4);
        let m = fs::metadata(dst.join("ro.beam")).unwrap();
        assert_eq!(m.permissions().mode() & 0o777, 0o444);
        assert_eq!(m.modified().unwrap(), old);
    }

    #[test]
    fn clones_a_single_file() {
        let Some(t) = cow_tempdir() else { return };
        fs::write(t.path().join("f"), b"x").unwrap();
        clone_tree(&t.path().join("f"), &t.path().join("g")).unwrap();
        assert_eq!(fs::read(t.path().join("g")).unwrap(), b"x");
    }

    #[test]
    fn refuses_an_existing_target() {
        let t = tempfile::tempdir().unwrap();
        fs::create_dir(t.path().join("src")).unwrap();
        fs::create_dir(t.path().join("dst")).unwrap();
        let e = clone_tree(&t.path().join("src"), &t.path().join("dst")).unwrap_err();
        assert_eq!(e.kind(), std::io::ErrorKind::AlreadyExists);
    }
}
