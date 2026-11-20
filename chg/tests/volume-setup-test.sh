#!/usr/bin/env bash
# Idempotence and refusal test for bin/chg-volume-setup.sh. Linux, as root through sudo
# (CI runs it as root in a privileged container). Everything lives under a temp dir: its own image,
# mount dir, fstab and repos; /etc/fstab and /srv/chg are never touched.

set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd -P)
setup="$here/bin/chg-volume-setup.sh"
owner=${SUDO_USER:?run through sudo, so the volume has a non-root owner}
t=$(mktemp -d)
o=$(mktemp -d) # refused runs' output, kept out of $t so state() does not see it
chmod 755 "$t"
trap 'umount "$t/mnt" 2>/dev/null || true; rm -rf "$t" "$o"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
run() { "$setup" --size 1G --owner "$owner" --image "$t/img/chg.img" --mount "$t/mnt" --fstab "$t/fstab" "$@"; }
# A refused run: exits 1 with $1 in its message.
refused() {
  local why=$1
  shift
  if "$@" >"$o/out" 2>"$o/err"; then fail "not refused ($why): $(cat "$o/out")"; fi
  grep -q "$why" "$o/err" || fail "refused for the wrong reason, wanted '$why': $(cat "$o/err")"
}
# A repo owned by $owner whose .gitignore has the directory-only worktrees rule.
repo() {
  mkdir -p "$1"
  git init -q "$1"
  printf '/.claude/worktrees/\n' >"$1/.gitignore"
  git -C "$1" add .gitignore
  git -C "$1" -c user.name=t -c user.email=t@t commit -q -m init
  chown -R "$owner" "$1"
}
state() { find "$t" -path "$t/mnt" -prune -o -printf '%p %m %s\n' | sort | md5sum; }

# The root entry has no trailing newline: the chg entry must not be glued onto it.
printf 'UUID=x / ext4 defaults 0 1' >"$t/fstab"
repo "$t/repo"
mkdir -p "$t/repo/.claude/worktrees"
chown -R "$owner" "$t/repo/.claude"

"$setup" --help | grep -q -- '--enroll' || fail "--help does not show usage"
if "$setup" --size 2>/dev/null; then fail "a missing value was accepted"; else [ $? = 2 ] || fail "a missing value did not exit 2"; fi

# Dry run first: says what it would do, does nothing.
before=$(state)
out=$(run --dry-run --enroll "$t/repo")
grep -q '^change (would): create sparse' <<<"$out" || fail "dry run did not plan the image: $out"
[ "$(state)" = "$before" ] || fail "dry run changed something"

# First run: makes the volume.
out=$(run --enroll "$t/repo")
echo "$out"
grep -q '^change: ' <<<"$out" || fail "first run made no change"
findmnt -n --mountpoint "$t/mnt" >/dev/null || fail "not mounted"
[ "$(readlink "$t/repo/.claude/worktrees")" = "$t/mnt/ws/repo" ] || fail "worktrees not linked"
[ "$(sed -n 1p "$t/fstab")" = 'UUID=x / ext4 defaults 0 1' ] || fail "root fstab entry damaged: $(cat "$t/fstab")"
[ "$(grep -c "$t/mnt xfs" "$t/fstab")" = 1 ] || fail "chg fstab entry not on its own line once"
[ "$(stat -c %a "$t/img/chg.img")" = 600 ] || fail "image readable by others"
[ "$(stat -c %a "$t/mnt/ci-tmp")" = 1777 ] || fail "ci-tmp not shared"
[ -z "$(sudo -u "$owner" git -C "$t/repo" status --porcelain)" ] || fail "the worktrees link shows in git status"

# Second run: changes nothing.
before=$(state)
out=$(run --enroll "$t/repo")
if grep -q '^change' <<<"$out"; then fail "second run changed something: $out"; fi
[ "$(state)" = "$before" ] || fail "second run changed files"

# The volume clones: a 64 MB file cloned costs (close to) no space.
dd if=/dev/urandom of="$t/mnt/store/big" bs=1M count=64 status=none
used_before=$(df --output=used -k "$t/mnt" | tail -1)
cp --reflink=always "$t/mnt/store/big" "$t/mnt/ws/repo/big"
used_after=$(df --output=used -k "$t/mnt" | tail -1)
[ $((used_after - used_before)) -lt 1024 ] || fail "reflink copy used $((used_after - used_before)) KB"
rm "$t/mnt/ws/repo/big"

# Remounted from fstab alone (what a reboot does): still ours, still nothing to change.
umount "$t/mnt"
mount -T "$t/fstab" "$t/mnt"
out=$(run --enroll "$t/repo")
if grep -q '^change' <<<"$out"; then fail "after remount: $out"; fi

# A deleted workspace dir is recreated, not reported ok through a dangling link.
rm -rf "$t/mnt/ws/repo"
out=$(run --enroll "$t/repo")
grep -q "^change: create $t/mnt/ws/repo" <<<"$out" || fail "dangling link not repaired: $out"
[ -d "$t/repo/.claude/worktrees/" ] || fail "link still dangling"

# Refusals: each leaves everything as it was.
repo "$t/other"
mkdir -p "$t/other/.claude/worktrees/live"
before=$(state)
refused 'holds worktrees' run --enroll "$t/other"
[ "$(state)" = "$before" ] || fail "refusal (live worktrees) changed something"

repo "$t/third"
mkdir -p "$t/third/.claude"
ln -s /tmp/elsewhere "$t/third/.claude/worktrees"
before=$(state)
refused 'points to /tmp/elsewhere' run --enroll "$t/third"
[ "$(state)" = "$before" ] || fail "refusal (link elsewhere) changed something"

repo "$t/b/repo"
before=$(state)
refused 'both named repo' run --enroll "$t/b/repo"
[ "$(state)" = "$before" ] || fail "refusal (name clash) changed something"

# On a fresh image path, a refusal must not create the image first.
fresh() { "$setup" --size 1G --owner "$owner" --image "$t/img2/chg.img" --mount "$t/m2" --fstab "$t/fstab2" "$@"; }
mkdir -p "$t/m2" && echo data >"$t/m2/f"
before=$(state)
refused 'holds data' fresh
[ "$(state)" = "$before" ] || fail "refusal (busy mount dir) changed something"
rm -rf "$t/m2"
before=$(state)
refused 'is not a git repo' fresh --enroll "$t/nope"
refused 'needs that much free' fresh --size 100P
[ "$(state)" = "$before" ] || fail "refusal (typo / size) changed something"

mkdir -p "$t/img3" && truncate -s 10M "$t/img3/chg.img"
refused 'not a chg volume' "$setup" --size 1G --owner "$owner" --image "$t/img3/chg.img" --mount "$t/m3" --fstab "$t/fstab3"

printf '%s\n' "/dev/sdz1 $t/mnt ext4 defaults 0 0" >"$t/fstab4"
before=$(state)
refused 'differently' run --fstab "$t/fstab4"
[ "$(state)" = "$before" ] || fail "refusal (fstab) changed something"

echo "PASS: chg-volume-setup.sh is idempotent and refuses foreign state"
