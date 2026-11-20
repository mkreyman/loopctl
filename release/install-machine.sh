#!/usr/bin/env bash
# Moves THIS machine to factory set <set> (US-52.10): one checkout of mkreyman/loopctl at tag
# factory-<set>, the runner and chg built from it, and proof the runner joined loopctl at it.
# A machine with no runner.json (no runner, e.g. nuc) gets the checkout and chg only, and
# reports runner_version null.
#
#   release/install-machine.sh <set>
#
# Prints one JSON line {host, set, status, runner_version, chg_version} and exits 0 for
# status ok or unchanged, 75 for busy (another install holds the lock), 1 otherwise.
#
#   ok           the set is installed, chg reports its version and commit, and the runner
#                joined loopctl after the restart naming release_set <set>; on a machine
#                with no runner.json, only the set and chg (runner_version null)
#   unchanged    current already is <set> and verifies; nothing was restarted
#   runner_busy  the runner did not drain within LOOPCTL_FACTORY_DRAIN_S; it was undrained
#                and nothing changed
#   busy         another install is running
#   failed       a step failed; `detail` says which
#
# Layout (state lives here, swapped by rename):
#   ~/.local/share/loopctl-factory/sets/<set>   checkouts, the three newest kept
#   ~/.local/share/loopctl-factory/current      symlink to the set in use
#
# Everything a test varies is an environment input, never a global it edits:
#   LOOPCTL_FACTORY_HOME      the layout root          (~/.local/share/loopctl-factory)
#   LOOPCTL_FACTORY_REPO      the git URL to clone     (git@github.com:mkreyman/loopctl.git)
#   LOOPCTL_RUNNER_PREFIX     the runner's install prefix (~/.local/share/loopctl-runner)
#   LOOPCTL_RUNNER_CONFIG     runner.json              (~/.config/loopctl-runner/runner.json)
#   LOOPCTL_FACTORY_DRAIN_S   drain wait, seconds      (3600)
#   LOOPCTL_FACTORY_JOIN_S    join wait, seconds       (180)
#   LOOPCTL_FACTORY_POLL_S    poll interval, seconds   (15)
#   LOOPCTL_FACTORY_CHG_DEST  chg's user install       (~/.local/bin/chg)
#   LOOPCTL_FACTORY_CHG_SYSTEM chg's system install, refreshed only where it exists
#                             (/usr/local/bin/chg)
#   LOOPCTL_FACTORY_CHECKOUT  the loopctl working tree runner.json's repos map names
#                             (~/workspace/loopctl)
#   LOOPCTL_FACTORY_SERVER_SET the set loopctl answers a join with (the <set> argument)
#   LOOPCTL_FACTORY_CHG_CONFIG chg's loopctl sources, cleaned of [retired] repos
#                             (~/.chg/loopctl.toml)
set -uo pipefail
unset CDPATH

set_id=${1:-}
case $set_id in
  '' | *[!0-9]*) echo "usage: install-machine.sh <set>  (a positive integer)" >&2; exit 2 ;;
esac

# beelink and nuc need asdf sourced in a non-interactive ssh (USER.md). asdf 0.16+ is one
# binary with no asdf.sh, and a non-interactive ssh to a Mac has neither its shims nor
# Homebrew's bin on PATH, so mix was not found (mac-mini, 2026-11-20).
[ -f "$HOME/.asdf/asdf.sh" ] && . "$HOME/.asdf/asdf.sh"
for d in /usr/local/bin /opt/homebrew/bin "$HOME/.asdf/shims"; do
  case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$d:$PATH" ;; esac
done
export PATH

home=${LOOPCTL_FACTORY_HOME:-$HOME/.local/share/loopctl-factory}
repo_url=${LOOPCTL_FACTORY_REPO:-git@github.com:mkreyman/loopctl.git}
runner_prefix=${LOOPCTL_RUNNER_PREFIX:-$HOME/.local/share/loopctl-runner}
runner_config=${LOOPCTL_RUNNER_CONFIG:-$HOME/.config/loopctl-runner/runner.json}
drain_s=${LOOPCTL_FACTORY_DRAIN_S:-3600}
join_s=${LOOPCTL_FACTORY_JOIN_S:-180}
poll_s=${LOOPCTL_FACTORY_POLL_S:-15}
chg_dest=${LOOPCTL_FACTORY_CHG_DEST:-$HOME/.local/bin/chg}
chg_system=${LOOPCTL_FACTORY_CHG_SYSTEM:-/usr/local/bin/chg}
checkout=${LOOPCTL_FACTORY_CHECKOUT:-$HOME/workspace/loopctl}
chg_config=${LOOPCTL_FACTORY_CHG_CONFIG:-$HOME/.chg/loopctl.toml}
# The set loopctl answers a join with. It is the SERVER's set, so a rollback to an older set
# still joins naming the server's current one; rollout.sh passes it then.
server_set=${LOOPCTL_FACTORY_SERVER_SET:-$set_id}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/pick_python.sh"
py=$(pick_python) || py=""
host=$(hostname -s 2>/dev/null || hostname)
runner_bin="$runner_prefix/current/bin/loopctl_runner"
set_dir="$home/sets/$set_id"
# A machine with no runner.json runs no runner (nuc, beelink): it gets the set's checkout and
# chg, and nothing installs a runner there or waits for one to join.
has_runner=false
[ -f "$runner_config" ] && has_runner=true

runner_version=null
chg_version=null

# report <status> [detail] [exit]: the one JSON line, then exit.
report() {
  "${py:-python3}" - "$host" "$set_id" "$1" "$runner_version" "$chg_version" "${2:-}" <<'PY'
import json, sys
host, set_id, status, rv, cv, detail = sys.argv[1:7]
out = {"host": host, "set": int(set_id), "status": status,
       "runner_version": None if rv == "null" else rv,
       "chg_version": None if cv == "null" else cv}
if detail:
    out["detail"] = detail
print(json.dumps(out))
PY
  exit "${3:-1}"
}

fail() { report failed "$1" 1; }

[ -n "$py" ] || fail "no Python 3.11+ (tomllib) on PATH, /opt/homebrew/bin or /usr/local/bin"

mkdir -p "$home/sets" || fail "cannot create $home"

# Set once the running runner is told to drain, cleared once the new runner is installed (a
# restarted runner starts undrained: the flag lives only in its memory). While it is set, the
# EXIT trap undrains the runner, so every failure between the drain and the install, and
# runner_busy, leaves it taking work again. Best effort: the trap's own result never replaces
# the exit status of the report that ended the run.
drained=false

on_exit() {
  if [ "$drained" = true ]; then
    "$runner_bin" rpc 'LoopctlRunner.Control.set_draining(LoopctlRunner.Control, false)' \
      >/dev/null 2>&1 || true
  fi
  # Only our own lock: a run that took over a lock it judged stale must not lose it to us.
  if [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$lock"; fi
}

# One install at a time. The owner writes its pid to a temporary file inside the lock and
# renames it to `pid`, so `pid` is never seen half-written. A lock with no pid yet belongs to
# an owner between its mkdir and that rename, which is busy, not dead: it is taken over only
# once the lock directory is more than lock_grace_m minutes old, far longer than that window,
# so it covers only an owner killed inside it. A lock whose pid is not running is taken over.
lock="$home/.install.lock"
lock_grace_m=1
if ! mkdir "$lock" 2>/dev/null; then
  owner=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    report busy "another install is running (pid $owner)" 75
  fi
  if [ -z "$owner" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin +"$lock_grace_m" 2>/dev/null)" ]; then
    report busy "$lock has no owner pid yet (taken over after ${lock_grace_m}m)" 75
  fi
  # Take it over by RENAMING it aside, never by deleting it in place: a rename is atomic, so
  # of two runs that both judged it stale only one moves it. The mover then checks that what
  # it moved is still stale by the same test it judged: the same pid, and with no pid, still
  # older than the bound. A lock another run recreated in between has a new pid or is fresh,
  # so it is put back and this run is busy.
  aside="$lock.stale.$$"
  mv "$lock" "$aside" 2>/dev/null || report busy "could not take $lock" 75
  moved_owner=$(cat "$aside/pid" 2>/dev/null || true)
  if [ "$moved_owner" != "$owner" ] ||
    { [ -z "$owner" ] && [ -z "$(find "$aside" -maxdepth 0 -mmin +"$lock_grace_m" 2>/dev/null)" ]; }; then
    mv "$aside" "$lock" 2>/dev/null || true
    report busy "$lock was taken over by another install" 75
  fi
  rm -rf "$aside"
  mkdir "$lock" 2>/dev/null || report busy "could not take $lock" 75
fi
trap on_exit EXIT
{ echo "$$" >"$lock/pid.$$" && mv -f "$lock/pid.$$" "$lock/pid"; } || fail "cannot write $lock/pid"

# --- what is installed now ---

# The chg version line every install of chg on this machine prints, one per line.
chg_versions() {
  local bin
  for bin in "$chg_dest" "$chg_system"; do
    [ -x "$bin" ] && "$bin" --version 2>/dev/null | head -1
  done
}

# chg_matches <version> <sha12>: every install names the set's version and commit.
chg_matches() {
  local line seen=0
  while IFS= read -r line; do
    seen=1
    case $line in
      "chg $1 "*"commit $2"*) ;;
      *) return 1 ;;
    esac
  done < <(chg_versions)
  [ "$seen" = 1 ]
}

# The joined.json the runner writes beside its runs directory (US-52.8).
joined_file() {
  "$py" - "$runner_config" <<'PY'
import json, os, sys
try:
    runs = json.load(open(sys.argv[1]))["runs_dir"]
except Exception:
    sys.exit(1)
print(os.path.join(os.path.dirname(os.path.expanduser(runs).rstrip("/")), "joined.json"))
PY
}

# joined_at_set <file> <set> <after-epoch>: written after <after> and naming <set>; prints
# the runner version it names.
joined_at_set() {
  "$py" - "$1" "$2" "$3" <<'PY'
import json, os, sys
path, want, after = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
try:
    if os.path.getmtime(path) < after:
        sys.exit(1)
    j = json.load(open(path))
except Exception:
    sys.exit(1)
if j.get("release_set") != want:
    sys.exit(1)
print(j.get("runner_version") or "")
PY
}

# read_joined_file: where the runner writes joined.json; read only where it is needed, since
# the install rewrites runner.json.
read_joined_file() {
  [ "$has_runner" = true ] || return 0
  jf=$(joined_file) || fail "cannot read runs_dir from $runner_config"
}

# runner_joined <after-epoch>: the runner joined at the server's set after <after>; prints the
# version it names. A machine with no runner has nothing to join and passes.
runner_joined() {
  [ "$has_runner" = true ] || return 0
  joined_at_set "$jf" "$server_set" "$1"
}

# US-52.11: a retired repo's chg sources go, once their queued rows are sent. Run on every
# path that reports success, so a machine already at the set is cleaned too. A failed send
# leaves the sources in place and fails the run; the next run retries.
drop_retired_sources() {
  local tree=$1 state
  [ -f "$chg_config" ] || return 0
  state=$("$py" "$here/lib/drop_retired_sources.py" --check "$chg_config" "$tree/release/manifest.toml") ||
    fail "cannot read $chg_config or the set's [retired] list"
  [ "$state" = pending ] || return 0
  "$chg_dest" outbox send >&2 ||
    fail "chg outbox send failed; the retired repos' sources stay in $chg_config until it succeeds"
  "$py" "$here/lib/drop_retired_sources.py" "$chg_config" "$tree/release/manifest.toml" >/dev/null ||
    fail "cannot rewrite $chg_config"
}

manifest_version() {
  # manifest_version <tree> <component>
  "$py" - "$1/release/manifest.toml" "$2" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(tomllib.load(f)["components"][sys.argv[2]]["version"])
PY
}

# --- already there? ---

if [ -L "$home/current" ] && [ "$(readlink "$home/current")" = "sets/$set_id" ] && [ -d "$set_dir" ]; then
  want_chg=$(manifest_version "$set_dir" chg) || fail "cannot read the set's manifest"
  sha=$(git -C "$set_dir" rev-parse --short=12 HEAD) || fail "cannot read the set's commit"
  read_joined_file
  if chg_matches "$want_chg" "$sha" && rv=$(runner_joined 0); then
    [ "$has_runner" = true ] && runner_version=$rv
    chg_version=$want_chg
    drop_retired_sources "$set_dir"
    report unchanged "" 0
  fi
fi

# --- the set's tree ---

if [ -d "$set_dir/.git" ]; then
  git -C "$set_dir" fetch --quiet --tags origin || fail "git fetch failed in $set_dir"
else
  rm -rf "$set_dir.partial"
  git clone --quiet "$repo_url" "$set_dir.partial" || fail "git clone $repo_url failed"
  mv "$set_dir.partial" "$set_dir" || fail "cannot move the clone into $set_dir"
fi
git -C "$set_dir" checkout --quiet --detach "factory-$set_id" ||
  fail "tag factory-$set_id is not in $repo_url"

if [ -f "$set_dir/.tool-versions" ] && command -v asdf >/dev/null 2>&1; then
  (cd "$set_dir" && asdf install >/dev/null) || fail "asdf install failed for $set_dir/.tool-versions"
fi

want_chg=$(manifest_version "$set_dir" chg) || fail "cannot read the set's manifest"
sha=$(git -C "$set_dir" rev-parse --short=12 HEAD)

# --- drain the running runner ---

rpc() { "$runner_bin" rpc "$1" 2>/dev/null; }

in_flight() {
  rpc 'IO.puts(length(LoopctlRunner.Control.info(LoopctlRunner.Control).runs_in_flight))'
}

if [ -x "$runner_bin" ] && "$runner_bin" pid >/dev/null 2>&1; then
  # Set before the call: a run killed while the call is in flight still undrains.
  drained=true
  rpc 'LoopctlRunner.Control.set_draining(LoopctlRunner.Control, true)' >/dev/null
  waited=0
  while :; do
    n=$(in_flight | tail -1)
    [ "$n" = 0 ] && break
    if [ "$waited" -ge "$drain_s" ]; then
      # on_exit undrains it.
      report runner_busy "${n:-?} dispatch(es) still in flight after ${drain_s}s" 1
    fi
    sleep "$poll_s"
    waited=$((waited + poll_s))
  done
fi

# --- install ---

restart=$(date +%s)

if [ "$has_runner" = true ]; then
  "$py" "$here/lib/rewrite_runner_config.py" "$runner_config" "$checkout" >/dev/null ||
    fail "cannot rewrite $runner_config"
  # A runner that has run nothing has no state directory, and a set-2 runner cannot record its
  # join without one (blockit, 2026-11-20).
  read_joined_file
  mkdir -p "$(dirname "$jf")" || fail "cannot create $(dirname "$jf")"
  (cd "$set_dir/runner" && LOOPCTL_RUNNER_PREFIX="$runner_prefix" rel/install.sh) >&2 ||
    fail "the runner install failed (runner/rel/install.sh)"
  # The new runner is up and starts undrained; nothing is left to undo.
  drained=false
fi

(cd "$set_dir/chg" && scripts/install.sh --dest "$(dirname "$chg_dest")") >&2 ||
  fail "chg's install failed (chg/scripts/install.sh)"
if [ -x "$chg_system" ]; then
  (cd "$set_dir/chg" && scripts/install-system.sh) >&2 ||
    fail "chg's system install failed (chg/scripts/install-system.sh). It runs sudo, so where sudo asks for a password, run it once in a terminal: ssh -t <host> 'cd $set_dir/chg && scripts/install-system.sh'"
fi

# The swap: a new symlink renamed over the old one, so `current` is never missing.
ln -sfn "sets/$set_id" "$home/.current.new" && mv -T "$home/.current.new" "$home/current" 2>/dev/null ||
  { rm -f "$home/current" && mv "$home/.current.new" "$home/current"; } ||
  fail "cannot swap $home/current"

# Keep the three newest sets; the current one always stays.
# awk, not `head -n -3`, which macOS's head does not take.
ls -1 "$home/sets" | grep -E '^[0-9]+$' | sort -n |
  awk '{ s[NR] = $0 } END { for (i = 1; i <= NR - 3; i++) print s[i] }' | while read -r old; do
  [ "$old" = "$set_id" ] || rm -rf "${home:?}/sets/$old"
done

# --- verify ---

chg_matches "$want_chg" "$sha" ||
  fail "chg --version does not name $want_chg commit $sha: $(chg_versions | tr '\n' ';')"
chg_version=$want_chg

read_joined_file
waited=0
until rv=$(runner_joined "$restart"); do
  if [ "$waited" -ge "$join_s" ]; then
    fail "the runner did not join loopctl at release_set $server_set within ${join_s}s ($jf)"
  fi
  sleep "$poll_s"
  waited=$((waited + poll_s))
done
[ "$has_runner" = true ] && runner_version=$rv

drop_retired_sources "$set_dir"
report ok "" 0
