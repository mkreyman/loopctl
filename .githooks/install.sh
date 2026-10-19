#!/usr/bin/env bash
# Points this repository's core.hooksPath at the MAIN worktree's .githooks, by
# absolute path (#985). `mix setup` runs it; running it again changes nothing.
#
# WHY ABSOLUTE. core.hooksPath lives in the shared .git/config, so it applies to
# every linked worktree at once. The relative `.githooks` home_care_billing uses
# is resolved in each worktree, and a worktree on a branch cut before this
# directory existed would then have no hooks at all: its commit gate silently
# off. Every worktree here runs the main worktree's hooks instead, which are
# master's whenever the main worktree is on master.
#
# WHY IT MAY DECLINE. Until the main worktree has .githooks/pre-push, pointing
# git there would switch off every hook in every worktree, so it leaves the
# setting alone and says so. The fleet's global ~/.git-hooks keeps running.
#
# WHY ONLY ON THE FLEET. These hooks hand back to the fleet's ~/.git-hooks. A
# checkout on a machine without them (an outside contributor's) ran no hooks
# before, and still runs none: pointing git here would only print a warning on
# every commit.
#
# Undo: `git config --unset core.hooksPath` (the fleet's global setting then
# applies again).
set -uo pipefail

if [ ! -x "$HOME/.git-hooks/pre-commit" ]; then
  echo "core.hooksPath unchanged: no fleet hooks in $HOME/.git-hooks on this machine"
  exit 0
fi

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
  echo "core.hooksPath unchanged: not inside a git checkout"
  exit 0
}
main=$(cd "$common/.." 2>/dev/null && pwd -P) || {
  echo "core.hooksPath unchanged: cannot resolve the main worktree from $common"
  exit 0
}
hooks="$main/.githooks"

if [ ! -x "$hooks/pre-push" ] || [ ! -x "$hooks/pre-commit" ]; then
  echo "core.hooksPath unchanged: $hooks has no executable pre-push and pre-commit yet"
  echo "(the main worktree is on a commit older than .githooks/; run this again once it is not)"
  exit 0
fi

if [ "$(git config --get core.hooksPath 2>/dev/null)" = "$hooks" ]; then
  echo "core.hooksPath already $hooks"
  exit 0
fi

git config core.hooksPath "$hooks" || {
  echo "core.hooksPath unchanged: git config failed"
  exit 1
}
echo "core.hooksPath -> $hooks"
