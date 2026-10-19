#!/usr/bin/env bash
# Usage: nearest-base.sh <remote> <commit>
#
# Prints the merge-base of <commit> with the NEAREST branch it can target on
# <remote>: the remote's default branch, master or any epic/* branch. A story
# branch cut from epic/<name> shares only the epic's cut point with master, so
# measuring from master would count every earlier story's changes as its own.
# Nearest = fewest commits from the merge-base to <commit>; ties keep the default
# branch. Exits 1, printing nothing, when no candidate has a merge-base.
#
# Ported from home_care_billing's .githooks/lib/nearest-base.sh (#985). Its one
# caller here is .githooks/pre-push: the base its chg shadow check diffs from.
set -uo pipefail
remote=${1:?remote}
commit=${2:?commit}

# Each candidate is tried independently: one that does not resolve (origin/HEAD
# pointing at a deleted branch) is skipped, never a reason to drop the
# others.
candidates() {
  git symbolic-ref -q "refs/remotes/$remote/HEAD" 2>/dev/null
  echo "refs/remotes/$remote/master"
  git for-each-ref --format='%(refname)' "refs/remotes/$remote/epic/" 2>/dev/null
}

# A ref whose commit was already scored (origin/HEAD and origin/master, or an
# epic still at its cut point) is skipped. Stale epic/* refs for branches already
# deleted on GitHub stay until `git fetch --prune`; they cost a merge-base each
# and never win, since a merged epic's squash commit is not in any branch's past.
best="" best_n="" seen=" "
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  tip=$(git rev-parse -q --verify "$ref^{commit}" 2>/dev/null) || continue
  case "$seen" in *" $tip "*) continue ;; esac
  seen="$seen$tip "
  mb=$(git merge-base "$commit" "$tip" 2>/dev/null) || continue
  n=$(git rev-list --count "$mb..$commit" 2>/dev/null) || continue
  if [ -z "$best_n" ] || [ "$n" -lt "$best_n" ]; then best=$mb; best_n=$n; fi
done < <(candidates)

[ -n "$best" ] || exit 1
echo "$best"
