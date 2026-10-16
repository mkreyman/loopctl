#!/usr/bin/env bash
# chg-volume-setup.sh: the Linux reflink volume for chg (design §3.5, story S5).
#
# minis, nuc and beelink are ext4 on LVM with no free extents, so ext4 gives no reflink
# and there is no room for a new logical volume. This script puts a sparse image file on
# the existing ext4, formats it XFS with reflink, loop-mounts it at /srv/chg from fstab,
# and points each enrolled repo's .claude/worktrees at /srv/chg/ws/<repo>. The snapshot
# store (/srv/chg/store) and every workspace then share one reflink filesystem, which is
# what FICLONE needs.
#
# Usage:
#   sudo bin/chg-volume-setup.sh [--dry-run] [--size SIZE] [--owner USER]
#                                [--enroll REPO_DIR]... [--image PATH] [--mount DIR]
#                                [--fstab PATH]
#
#   --size    sparse image size; defaults by host: minis and beelink 300G, nuc 120G
#   --owner   who owns /srv/chg, its store and workspaces (default: $SUDO_USER)
#   --enroll  a repo whose .claude/worktrees becomes a symlink into the volume
#   --image, --mount, --fstab   for tests (defaults /var/lib/chg/chg.img, /srv/chg,
#                               /etc/fstab)
#
# Idempotent: every check runs before the first change, so a refusal leaves the box as
# it was; then each step prints `ok:` (already so) or `change:` (done now, or "would"
# under --dry-run). A second run prints no `change:`. Refused:
#   - an image that is not an XFS volume labelled chg;
#   - a non-empty mount dir that is not this volume, or a mount of something else;
#   - an fstab entry for the mount dir that differs from ours;
#   - a new image larger than the free space under it (XFS shuts down when the
#     disk under a loop image fills, taking every workspace with it);
#   - an enrolled .claude/worktrees that holds worktrees or points elsewhere;
#   - two repos with the same directory name (they would share /srv/chg/ws/<name>).
#
# Layout on the volume: store/ and ws/ owned by --owner; ci-tmp/ mode 1777 for a CI
# runner account's tests; `enrolled` lists "<name> TAB <repo path>". Each enrolled repo
# also gets `/.claude/worktrees` in its own .git/info/exclude, because a directory-only
# ignore rule (`.claude/worktrees/`) does not match the symlink.
#
# Exit codes: 0 done (or nothing to do, or --help), 1 refused or failed, 2 usage.
#
# Rollback (destroys every snapshot and workspace on the volume; rebuildable caches):
#   1. For each enrolled repo, remove its worktrees (`git worktree remove`), then:
#        rm REPO/.claude/worktrees && mkdir REPO/.claude/worktrees
#      and delete the `/.claude/worktrees` line from REPO/.git/info/exclude.
#   2. sudo umount /srv/chg
#   3. sudo sed -i '\#^/var/lib/chg/chg.img /srv/chg #d' /etc/fstab
#      (or restore the /etc/fstab.chg-backup-* this script wrote), then
#      sudo systemctl daemon-reload
#   4. sudo rm /var/lib/chg/chg.img && sudo rmdir /srv/chg /var/lib/chg
#
# Space: the image is sparse, so it costs what is written. Deleted snapshots return
# their blocks to ext4 when the volume is trimmed (Ubuntu's weekly fstrim.timer).

set -euo pipefail

LABEL=chg
image=/var/lib/chg/chg.img
mount_dir=/srv/chg
fstab=/etc/fstab
size=
owner=${SUDO_USER:-}
dry=0
enroll=()

usage() {
  sed -n '/^# Usage:/,/^# Idempotent/p' "$0" | sed '$d' | sed -E 's/^# ?//'
  exit "$1"
}

while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry=1 ;;
    --size | --owner | --enroll | --image | --mount | --fstab)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "$1 needs a value" >&2
        usage 2 >&2
      fi
      case $1 in
        --size) size=$2 ;;
        --owner) owner=$2 ;;
        --enroll) enroll+=("$2") ;;
        --image) image=$2 ;;
        --mount) mount_dir=$2 ;;
        --fstab) fstab=$2 ;;
      esac
      shift
      ;;
    -h | --help) usage 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage 2 >&2
      ;;
  esac
  shift
done

ok() { echo "ok: $*"; }
change() { if [ "$dry" = 1 ]; then echo "change (would): $*"; else echo "change: $*"; fi; }
refuse() {
  echo "refused: $*" >&2
  exit 1
}
# Runs a mutating command unless --dry-run.
act() { if [ "$dry" = 0 ]; then "$@"; fi; }
# Git refuses a repo owned by another user, so repo commands run as its owner.
as_owner() { if [ "$(id -u)" = 0 ] && [ "$owner" != root ]; then sudo -u "$owner" "$@"; else "$@"; fi; }
# Appends one line, first ending the file's last line if it lacks a newline: otherwise
# the new line would be glued onto it (a joined fstab line breaks boot).
append_line() {
  if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]; then printf '\n' >>"$1"; fi
  printf '%s\n' "$2" >>"$1"
}

[ "$(uname -s)" = Linux ] || refuse "Linux only; macOS uses APFS clonefile and needs no volume"
[ "$(id -u)" = 0 ] || [ "$dry" = 1 ] || refuse "run as root (sudo); --dry-run needs no root"
for t in mkfs.xfs blkid findmnt losetup xfs_info numfmt; do
  command -v "$t" >/dev/null || refuse "$t is missing (apt-get install xfsprogs util-linux coreutils)"
done
[ -n "$owner" ] || refuse "no owner: pass --owner USER or run through sudo"
id "$owner" >/dev/null 2>&1 || refuse "owner $owner does not exist"
group=$(id -gn "$owner")

if [ -z "$size" ]; then
  case $(hostname -s) in
    minis | beelink) size=300G ;;
    nuc) size=120G ;;
    *) refuse "no default size for $(hostname -s); pass --size" ;;
  esac
fi

fstab_line="$image $mount_dir xfs loop,nofail 0 0"
registry="$mount_dir/enrolled"

mounted_here() {
  local src
  src=$(findmnt -n -o SOURCE --mountpoint "$mount_dir" 2>/dev/null) || return 1
  # A loop mount reports /dev/loopN; it is ours when that device is backed by $image.
  [ "$src" = "$image" ] || losetup -n -O BACK-FILE "$src" 2>/dev/null | grep -qxF "$(readlink -f "$image")"
}

# ---- Checks. Nothing below changes anything until the last of them has passed. ----

new_image=0
if [ -e "$image" ]; then
  [ -f "$image" ] || refuse "$image exists and is not a regular file"
  if [ "$(blkid -o value -s TYPE "$image" 2>/dev/null)" != xfs ] ||
    [ "$(blkid -o value -s LABEL "$image" 2>/dev/null)" != "$LABEL" ]; then
    refuse "$image exists but is not a chg volume (XFS labelled $LABEL)"
  fi
else
  new_image=1
  bytes=$(numfmt --from=iec "$size" 2>/dev/null) || refuse "--size $size is not a size like 300G"
  probe=$(dirname "$image")
  while [ ! -d "$probe" ]; do probe=$(dirname "$probe"); done
  avail=$(($(df --output=avail -k "$probe" | tail -1) * 1024))
  [ "$avail" -ge "$bytes" ] ||
    refuse "a $size image needs that much free under $probe, which has $(numfmt --to=iec "$avail"); pass a smaller --size"
fi

mount_state=absent
if mounted_here; then
  mount_state=ours
elif findmnt -n --mountpoint "$mount_dir" >/dev/null 2>&1; then
  refuse "$mount_dir is a mount of something else"
elif [ -d "$mount_dir" ]; then
  [ -z "$(ls -A "$mount_dir")" ] || refuse "$mount_dir holds data that is not this volume"
  mount_state=empty
elif [ -e "$mount_dir" ]; then
  refuse "$mount_dir exists and is not a directory"
fi

existing=$(awk -v m="$mount_dir" '$1 !~ /^#/ && $2 == m' "$fstab" 2>/dev/null || true)
if [ -n "$existing" ] && [ "$existing" != "$fstab_line" ]; then
  refuse "$fstab already mounts $mount_dir differently: $existing"
fi

names=()
reals=()
for repo in "${enroll[@]}"; do
  [ -e "$repo/.git" ] || refuse "$repo is not a git repo"
  real=$(readlink -f "$repo")
  name=$(basename "$real")
  target="$mount_dir/ws/$name"
  link="$repo/.claude/worktrees"
  claimed=$(awk -F '\t' -v n="$name" '$1 == n { print $2 }' "$registry" 2>/dev/null || true)
  for i in "${!names[@]}"; do
    if [ "${names[$i]}" = "$name" ] && [ "${reals[$i]}" != "$real" ]; then claimed=${reals[$i]}; fi
  done
  if [ -n "$claimed" ] && [ "$claimed" != "$real" ]; then
    refuse "$real and $claimed are both named $name and would share $target"
  fi
  names+=("$name")
  reals+=("$real")
  if [ -L "$link" ]; then
    [ "$(readlink "$link")" = "$target" ] || refuse "$link points to $(readlink "$link"), not $target"
  elif [ -d "$link" ]; then
    [ -z "$(ls -A "$link")" ] || refuse "$link holds worktrees; remove or move them first (git worktree remove)"
  elif [ -e "$link" ]; then
    refuse "$link exists and is not a directory"
  fi
done

# ---- Changes. ----

# 1. The image: formatted under a temporary name and renamed into place, so an
# interrupted run leaves nothing a later run would refuse as foreign. Mode 600: the raw
# image would otherwise expose every file on the volume to any local user.
if [ "$new_image" = 1 ]; then
  change "create sparse $size image $image (mode 600), mkfs.xfs -m reflink=1 -L $LABEL"
  if [ "$dry" = 0 ]; then
    if [ ! -d "$(dirname "$image")" ]; then install -d -m 700 "$(dirname "$image")"; fi
    tmp="$image.tmp.$$"
    trap 'rm -f "$tmp"' EXIT
    (umask 077 && truncate -s "$size" "$tmp")
    mkfs.xfs -q -m reflink=1 -L "$LABEL" "$tmp"
    mv "$tmp" "$image"
    trap - EXIT
  fi
else
  ok "image $image ($(du -h --apparent-size "$image" | cut -f1) sparse, $(du -h "$image" | cut -f1) used)"
  if [ "$(stat -c %a "$image")" != 600 ]; then
    change "chmod 600 $image"
    act chmod 600 "$image"
  fi
fi

# 2. The mount dir.
case $mount_state in
  ours) ok "$mount_dir is mounted from $image" ;;
  empty) ok "$mount_dir exists and is empty" ;;
  absent)
    change "create $mount_dir"
    act mkdir -p "$mount_dir"
    ;;
esac

# 3. fstab, so the mount survives a reboot. nofail: a missing image must not stop boot.
if [ -n "$existing" ]; then
  ok "$fstab has the entry"
else
  backup="$fstab.chg-backup-$(date +%Y%m%d%H%M%S)"
  change "append to $fstab (backup $backup): $fstab_line"
  if [ -e "$fstab" ]; then act cp -p "$fstab" "$backup"; fi
  act append_line "$fstab" "$fstab_line"
  if [ "$fstab" = /etc/fstab ] && command -v systemctl >/dev/null; then
    act systemctl daemon-reload
  fi
fi

# 4. Mounted now.
if [ "$mount_state" != ours ]; then
  change "mount $image at $mount_dir"
  act mount -t xfs -o loop "$image" "$mount_dir"
fi

# 5. Reflink really on (a reused image could predate it).
if [ "$dry" = 0 ] || mounted_here; then
  xfs_info "$mount_dir" | grep -q 'reflink=1' || refuse "$mount_dir has no reflink support"
  ok "reflink=1 on $mount_dir"
fi

# 6. Layout, owned by the user who runs chg; ci-tmp is shared like /tmp.
for d in "$mount_dir" "$mount_dir/store" "$mount_dir/ws"; do
  if [ -d "$d" ] && [ "$(stat -c %U "$d")" = "$owner" ]; then
    ok "$d owned by $owner"
  else
    change "create/chown $d to $owner"
    act mkdir -p "$d"
    act chown "$owner:$group" "$d"
  fi
done
if [ -d "$mount_dir/ci-tmp" ] && [ "$(stat -c %a "$mount_dir/ci-tmp")" = 1777 ]; then
  ok "$mount_dir/ci-tmp is 1777"
else
  change "create $mount_dir/ci-tmp mode 1777"
  act install -d -m 1777 "$mount_dir/ci-tmp"
fi

# 7. Enrolled repos: .claude/worktrees -> /srv/chg/ws/<repo>, so worktrees land on the
# volume and the worktree convention is unchanged.
for repo in "${enroll[@]}"; do
  real=$(readlink -f "$repo")
  name=$(basename "$real")
  target="$mount_dir/ws/$name"
  link="$repo/.claude/worktrees"
  if [ -d "$target" ]; then
    ok "$target exists"
  else
    change "create $target"
    act install -d -o "$owner" -g "$group" "$target"
  fi
  if [ -L "$link" ]; then
    ok "$link -> $target"
  else
    change "link $link -> $target"
    if [ -d "$link" ]; then act rmdir "$link"; fi
    # An existing .claude is the repo's own; only a missing one is created.
    if [ ! -d "$repo/.claude" ]; then act install -d -o "$owner" -g "$group" "$repo/.claude"; fi
    act ln -s "$target" "$link"
    act chown -h "$owner:$group" "$link"
  fi
  if grep -qxF "$name	$real" "$registry" 2>/dev/null; then
    ok "$name enrolled in $registry"
  else
    change "record $name -> $real in $registry"
    act append_line "$registry" "$name	$real"
  fi
  exclude="$(as_owner git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  if grep -qxF '/.claude/worktrees' "$exclude" 2>/dev/null; then
    ok "$exclude ignores /.claude/worktrees"
  else
    change "add /.claude/worktrees to $exclude"
    # shellcheck disable=SC2016 # expanded by the inner bash, which receives $1
    act as_owner bash -c "$(declare -f append_line)"'; mkdir -p "$(dirname "$1")" && append_line "$1" /.claude/worktrees' _ "$exclude"
  fi
done

if [ "$dry" = 1 ]; then echo "dry run: nothing changed"; fi
