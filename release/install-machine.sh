#!/usr/bin/env bash
# Moves THIS machine to factory set <set> (US-52.10): one checkout of mkreyman/loopctl at tag
# factory-<set>, the runner and chg built from it, and proof the runner joined loopctl at it.
#
#   release/install-machine.sh <set>
#
# Prints one JSON line {host, set, status, runner_version, chg_version} and exits 0 for
# status ok or unchanged, 75 for busy (another install holds the lock), 1 otherwise.
#
#   ok           the set is installed, chg reports its version and commit, and the runner
#                joined loopctl after the restart naming release_set <set>
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

# beelink and nuc need asdf sourced in a non-interactive ssh (USER.md).
[ -f "$HOME/.asdf/asdf.sh" ] && . "$HOME/.asdf/asdf.sh"

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
host=$(hostname -s 2>/dev/null || hostname)
runner_bin="$runner_prefix/current/bin/loopctl_runner"
set_dir="$home/sets/$set_id"

runner_version=null
chg_version=null

# report <status> [detail] [exit]: the one JSON line, then exit.
report() {
  python3 - "$host" "$set_id" "$1" "$runner_version" "$chg_version" "${2:-}" <<'PY'
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

mkdir -p "$home/sets" || fail "cannot create $home"

# One install at a time; a lock whose owner is gone is taken over.
lock="$home/.install.lock"
if ! mkdir "$lock" 2>/dev/null; then
  owner=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    report busy "another install is running (pid $owner)" 75
  fi
  rm -rf "$lock"
  mkdir "$lock" 2>/dev/null || report busy "could not take $lock" 75
fi
echo "$$" >"$lock/pid"
trap 'rm -rf "$lock"' EXIT

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
  python3 - "$runner_config" <<'PY'
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
  python3 - "$1" "$2" "$3" <<'PY'
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

# US-52.11: a retired repo's chg sources go, once their queued rows are sent. Run on every
# path that reports success, so a machine already at the set is cleaned too. A failed send
# leaves the sources in place and fails the run; the next run retries.
drop_retired_sources() {
  local tree=$1 state
  [ -f "$chg_config" ] || return 0
  state=$(python3 "$here/lib/drop_retired_sources.py" --check "$chg_config" "$tree/release/manifest.toml") ||
    fail "cannot read $chg_config or the set's [retired] list"
  [ "$state" = pending ] || return 0
  "$chg_dest" outbox send >&2 ||
    fail "chg outbox send failed; the retired repos' sources stay in $chg_config until it succeeds"
  python3 "$here/lib/drop_retired_sources.py" "$chg_config" "$tree/release/manifest.toml" >/dev/null ||
    fail "cannot rewrite $chg_config"
}

manifest_version() {
  # manifest_version <tree> <component>
  python3 - "$1/release/manifest.toml" "$2" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(tomllib.load(f)["components"][sys.argv[2]]["version"])
PY
}

# --- already there? ---

if [ -L "$home/current" ] && [ "$(readlink "$home/current")" = "sets/$set_id" ] && [ -d "$set_dir" ]; then
  want_chg=$(manifest_version "$set_dir" chg) || fail "cannot read the set's manifest"
  sha=$(git -C "$set_dir" rev-parse --short=12 HEAD) || fail "cannot read the set's commit"
  jf=$(joined_file) || fail "cannot read runs_dir from $runner_config"
  if chg_matches "$want_chg" "$sha" && rv=$(joined_at_set "$jf" "$server_set" 0); then
    runner_version=$rv
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
  rpc 'LoopctlRunner.Control.set_draining(LoopctlRunner.Control, true)' >/dev/null
  waited=0
  while :; do
    n=$(in_flight | tail -1)
    [ "$n" = 0 ] && break
    if [ "$waited" -ge "$drain_s" ]; then
      rpc 'LoopctlRunner.Control.set_draining(LoopctlRunner.Control, false)' >/dev/null
      report runner_busy "${n:-?} dispatch(es) still in flight after ${drain_s}s" 1
    fi
    sleep "$poll_s"
    waited=$((waited + poll_s))
  done
fi

# --- install ---

if [ -f "$runner_config" ]; then
  python3 "$here/lib/rewrite_runner_config.py" "$runner_config" "$checkout" >/dev/null ||
    fail "cannot rewrite $runner_config"
fi

restart=$(date +%s)

(cd "$set_dir/runner" && LOOPCTL_RUNNER_PREFIX="$runner_prefix" rel/install.sh) >&2 ||
  fail "the runner install failed (runner/rel/install.sh)"

(cd "$set_dir/chg" && scripts/install.sh --dest "$(dirname "$chg_dest")") >&2 ||
  fail "chg's install failed (chg/scripts/install.sh)"
if [ -x "$chg_system" ]; then
  (cd "$set_dir/chg" && scripts/install-system.sh) >&2 ||
    fail "chg's system install failed (chg/scripts/install-system.sh)"
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

jf=$(joined_file) || fail "cannot read runs_dir from $runner_config"
waited=0
until rv=$(joined_at_set "$jf" "$server_set" "$restart"); do
  if [ "$waited" -ge "$join_s" ]; then
    fail "the runner did not join loopctl at release_set $server_set within ${join_s}s ($jf)"
  fi
  sleep "$poll_s"
  waited=$((waited + poll_s))
done
runner_version=$rv

drop_retired_sources "$set_dir"
report ok "" 0
