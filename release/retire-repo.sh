#!/usr/bin/env bash
# Retires a repository folded into this one (US-52.11): its open issues move to
# mkreyman/loopctl, the repo is archived, its history is imported a last time, and
# release/imports.toml marks the entry archived.
#
#   release/retire-repo.sh <owner/name> <stories.json>
#
# <stories.json> is the repo's loopctl project as `list_stories` returns it ({"data": [...]}),
# saved by the session that runs this: loopctl is reached through its MCP tools, never from a
# script (claude-config's orchestrator guardrail). A story is in flight while its agent_status
# is contracted, assigned or implementing, or it is reported_done and not yet verified.
#
# Exit: 0 retired (or already retired, printing 'retired: <owner/name>' and writing nothing);
# 1 a GitHub step failed (re-run: every step checks before it writes); 2 refused, naming each
# blocker (an open pull request, a story in flight, no imports.toml entry, a dirty tree).
#
# Order, and why: each open issue is labelled from:<name> in the OLD repo, then transferred;
# a transfer keeps a label the target also has, so an interrupted run never leaves a moved
# issue unlabelled. The repo is archived only once no open issue remains. The final import
# runs after the archive, so imported_sha is the archived tip and nothing can land after it.
#
# Inputs a test varies (never a global it edits): RETIRE_GH (gh), RETIRE_TARGET
# (mkreyman/loopctl), RETIRE_IMPORT (release/import-history.sh), RETIRE_SOURCE_URL
# (git@github.com:<owner/name>.git).
set -uo pipefail
unset CDPATH

repo=${1:-}
stories=${2:-}
case $repo in
  */*) ;;
  *) echo "usage: release/retire-repo.sh <owner/name> <stories.json>" >&2; exit 2 ;;
esac
[ -f "$stories" ] || { echo "retire: $stories not found (save list_stories for the repo's project)" >&2; exit 2; }

gh=${RETIRE_GH:-gh}
target=${RETIRE_TARGET:-mkreyman/loopctl}
root=$(git rev-parse --show-toplevel) || exit 2
import=${RETIRE_IMPORT:-$root/release/import-history.sh}
source_url=${RETIRE_SOURCE_URL:-git@github.com:$repo.git}
manifest="$root/release/imports.toml"
name=${repo#*/}
label="from:$name"

# entry <toml text> <field>: the [[import]] entry for this repo: its prefix, or "true" when
# archived.
entry() {
  python3 - "$1" "$repo" "$2" <<'PY'
import sys, tomllib
imports = tomllib.loads(sys.argv[1]).get("import", [])
for e in imports:
    if e.get("repo") == sys.argv[2]:
        v = e.get(sys.argv[3])
        print(str(v).lower() if isinstance(v, bool) else (v or ""))
        sys.exit(0)
sys.exit(1)
PY
}

on_disk=$(cat "$manifest" 2>/dev/null) || { echo "retire: cannot read $manifest" >&2; exit 2; }
prefix=$(entry "$on_disk" prefix) || { echo "retire: release/imports.toml has no entry for $repo" >&2; exit 2; }
# The marker in the working tree, and the one HEAD holds. Only a COMMITTED marker means
# retired: a marker written by a run whose commit then failed is still to be committed, and
# that run already did the final import (import-history.sh refuses an archived entry anyway).
marked=$(entry "$on_disk" archived)
committed=$(entry "$(git -C "$root" show HEAD:release/imports.toml 2>/dev/null)" archived) || committed=""
pending_commit=false
[ "$marked" = true ] && [ "$committed" != true ] && pending_commit=true

open_issues() {
  $gh issue list -R "$repo" --state open --limit 1000 --json number --jq '.[].number'
}

issues=$(open_issues) || { echo "retire: cannot list $repo's open issues" >&2; exit 1; }
is_archived=$($gh repo view "$repo" --json isArchived --jq .isArchived) ||
  { echo "retire: cannot read $repo" >&2; exit 1; }

if [ "$committed" = true ] && [ "$is_archived" = true ] && [ -z "$issues" ]; then
  echo "retired: $repo"
  exit 0
fi

# --- blockers ---

blockers=()
if [ "$is_archived" != true ]; then
  prs=$($gh pr list -R "$repo" --state open --json number --jq '.[].number') ||
    { echo "retire: cannot list $repo's pull requests" >&2; exit 1; }
  for n in $prs; do blockers+=("open pull request #$n"); done
fi
while IFS= read -r line; do
  [ -n "$line" ] && blockers+=("story in flight: $line")
done < <(python3 - "$stories" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
rows = data.get("data", data) if isinstance(data, dict) else data
for s in rows:
    a, v = s.get("agent_status"), s.get("verified_status")
    if a in ("contracted", "assigned", "implementing") or (a == "reported_done" and v == "unverified"):
        print(f'{s.get("number")} {s.get("id")} ({a})')
PY
)
# Exactly what import-history.sh refuses (`git status --porcelain`, untracked files included),
# checked here because the import runs only after the irreversible archive. The one change
# allowed is our own uncommitted marker, which this run commits without importing again.
dirty=$(git -C "$root" status --porcelain) || { echo "retire: cannot read git status" >&2; exit 1; }
if [ "$pending_commit" = true ]; then
  dirty=$(printf '%s\n' "$dirty" | grep -vE '^.. release/imports\.toml$')
fi
if [ -n "$dirty" ]; then
  blockers+=("the working tree has uncommitted changes (the final import commits)")
fi
if [ "${#blockers[@]}" -gt 0 ]; then
  echo "retire: $repo is not retired:" >&2
  printf '  - %s\n' "${blockers[@]}" >&2
  exit 2
fi

# --- issues ---

if [ -n "$issues" ]; then
  for r in "$repo" "$target"; do
    $gh label create "$label" -R "$r" --color BFD4F2 \
      --description "transferred from $repo" --force >/dev/null ||
      { echo "retire: cannot create label $label in $r" >&2; exit 1; }
  done
  failed=0
  for n in $issues; do
    if $gh issue edit "$n" -R "$repo" --add-label "$label" >/dev/null &&
      $gh issue transfer "$n" "$target" -R "$repo" >/dev/null; then
      echo "retire: $repo#$n moved to $target"
    else
      echo "retire: $repo#$n did not move; re-run to retry" >&2
      failed=1
    fi
  done
  [ "$failed" = 0 ] || exit 1
  issues=$(open_issues) || exit 1
  [ -z "$issues" ] || { echo "retire: $repo still has open issues: $issues" >&2; exit 1; }
fi

# --- archive, last import, marker ---

if [ "$is_archived" != true ]; then
  $gh repo archive "$repo" --yes >/dev/null || { echo "retire: cannot archive $repo" >&2; exit 1; }
  echo "retire: $repo archived"
fi

if [ "$committed" != true ]; then
  if [ "$marked" != true ]; then
    (cd "$root" && "$import" "$source_url" "$prefix") || { echo "retire: the final import failed" >&2; exit 1; }
    python3 - "$manifest" "$repo" <<'PY' || exit 1
import sys
path, repo = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
out, in_entry = [], False
for i, line in enumerate(lines):
    if line.strip() == "[[import]]":
        in_entry = False
    if line.strip() == f'repo = "{repo}"':
        in_entry = True
    out.append(line)
    if in_entry and line.startswith("imported_sha = "):
        out.append("archived = true")
        in_entry = False
open(path, "w").write("\n".join(out))
PY
  fi
  git -C "$root" add release/imports.toml
  git -C "$root" commit -q -m "Retire $repo: archived at its imported tip" -- release/imports.toml ||
    { echo "retire: could not commit the archived marker" >&2; exit 1; }
fi

echo "retired: $repo"
