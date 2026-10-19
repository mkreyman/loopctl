#!/usr/bin/env bash
# Points this repository's core.hooksPath at a small dispatcher directory in its
# git COMMON dir (#985). `mix setup` runs it; running it again changes nothing.
#
# WHY A DISPATCHER. core.hooksPath lives in the shared .git/config, so it applies
# to every linked worktree at once. Pointed at a WORKING TREE's .githooks (any
# worktree's, the main one's included), it follows that tree's checkout: a
# bisect or an old tag there, or a branch cut before .githooks existed, would
# leave git a directory with no hooks in it, and every worktree would then run
# none, the fleet's pre-commit gate (`mix precommit`) included, silently. The
# dispatcher sits in the git common dir, which no checkout touches. Each of its
# hooks runs the main worktree's .githooks/<hook> when that is executable, else
# the fleet's ~/.git-hooks/<hook>, else nothing, as git does with no hook. So the
# hooks are master's whenever the main worktree is on master, and the fleet's
# whenever it is on a commit older than .githooks/.
#
# WHICH HOOKS. A dispatcher for every hook name either side has now: this
# directory's, the main worktree's .githooks and the fleet's. Not every name git
# knows, because some hooks change git's behaviour by merely existing
# (push-to-checkout, reference-transaction's cost on every ref update). A hook
# added on either side later needs this run again (`mix setup`).
#
# WHY ONLY ON THE FLEET. These hooks hand back to the fleet's ~/.git-hooks. A
# checkout on a machine without them (an outside contributor's) ran no hooks
# before, and still runs none: pointing git here would only print a warning on
# every commit.
#
# Undo: `git config --unset core.hooksPath` (the fleet's global setting then
# applies again), and remove the dispatcher directory it names.
set -uo pipefail

if [ ! -x "$HOME/.git-hooks/pre-commit" ]; then
  echo "core.hooksPath unchanged: no fleet hooks in $HOME/.git-hooks on this machine"
  exit 0
fi

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
  echo "core.hooksPath unchanged: not inside a git checkout"
  exit 0
}
common=$(cd "$common" 2>/dev/null && pwd -P) || {
  echo "core.hooksPath unchanged: cannot resolve $common"
  exit 0
}
main=$(cd "$common/.." 2>/dev/null && pwd -P) || {
  echo "core.hooksPath unchanged: cannot resolve the main worktree from $common"
  exit 0
}
dispatch="$common/githooks-dispatch"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

mkdir -p "$dispatch" || {
  echo "core.hooksPath unchanged: cannot create $dispatch"
  exit 1
}
for dir in "$here" "$main/.githooks" "$HOME/.git-hooks"; do
  for path in "$dir"/*; do
    name=${path##*/}
    # Only hooks: a regular executable file, not lib/ nor this script.
    [ -f "$path" ] && [ -x "$path" ] && [ "$name" != install.sh ] || continue
    # The main worktree is found from the dispatcher's own path at run time
    # (<common>/githooks-dispatch/<hook>), so a moved checkout still resolves.
    cat >"$dispatch/$name.tmp" <<'EOF' || exit 1
#!/bin/sh
# Written by .githooks/install.sh (#985); see its header. Runs the main
# worktree's .githooks/<hook>, else the fleet's ~/.git-hooks/<hook>, else
# nothing. exec keeps each hook's own path in $0.
hook=${0##*/}
common=$(cd "$(dirname "$0")/.." && pwd -P) || exit 0
for h in "$common/../.githooks/$hook" "$HOME/.git-hooks/$hook"; do
  if [ -f "$h" ] && [ -x "$h" ]; then exec "$h" "$@"; fi
done
exit 0
EOF
    chmod 755 "$dispatch/$name.tmp" && mv -f "$dispatch/$name.tmp" "$dispatch/$name" || exit 1
  done
done

if [ "$(git config --get core.hooksPath 2>/dev/null)" = "$dispatch" ]; then
  echo "core.hooksPath already $dispatch"
  exit 0
fi

git config core.hooksPath "$dispatch" || {
  echo "core.hooksPath unchanged: git config failed"
  exit 1
}
echo "core.hooksPath -> $dispatch"
