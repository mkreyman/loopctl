#!/usr/bin/env bash
# Import another repository into this one under <prefix>/, keeping its history (US-52.4).
#
#   release/import-history.sh <source_url> <prefix>
#
# The source's master is cloned into a temporary directory and rewritten there with
# `git filter-repo --to-subdirectory-filter <prefix>`, so every old commit's paths move under
# <prefix>/ and `git log` / `git blame` on <prefix>/... walk the old history without --follow.
# The rewrite is deterministic, so a re-run produces the same rewritten SHAs for commits
# already imported and the merge brings in only the new ones.
#
# release/imports.toml records, per prefix, the source commit it holds:
#
#   [[import]]
#   repo = "owner/source"
#   prefix = "runner"
#   imported_sha = "<40 hex>"
#
# Exit codes: 0 imported or up to date; 2 refused, with the branch head and imports.toml
# untouched (dirty tree, <prefix>/ present with no record, a failed fetch or rewrite, or a
# merge that does not apply cleanly).
set -euo pipefail

usage() {
  echo "usage: release/import-history.sh <source_url> <prefix>" >&2
  exit 2
}

refuse() {
  echo "import-history: $*" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
source_url=$1
prefix=${2%/}
[[ $prefix =~ ^[A-Za-z0-9._-]+$ ]] || refuse "prefix must be one path segment: $prefix"

root=$(git rev-parse --show-toplevel 2>/dev/null) || refuse "not inside a git work tree"
cd "$root"
manifest="release/imports.toml"

# owner/repo from any URL shape: git@host:owner/repo.git, https://host/owner/repo, a path.
repo_name() {
  local url=${1%/}
  url=${url%.git}
  url=${url//://}
  local repo=${url##*/}
  local rest=${url%/*}
  echo "${rest##*/}/$repo"
}
repo=$(repo_name "$source_url")

# The imported_sha recorded for this prefix, or nothing.
recorded_sha() {
  [[ -f $manifest ]] || return 0
  awk -v want="$prefix" '
    /^\[\[import\]\]/ { p = ""; s = "" }
    /^prefix = / { p = $3; gsub(/"/, "", p) }
    /^imported_sha = / { s = $3; gsub(/"/, "", s) }
    p == want && s != "" { print s; exit }
  ' "$manifest"
}

# Whether this prefix's entry is marked `archived = true` (US-52.11, release/retire-repo.sh):
# the source repository is archived at the recorded commit, so there is nothing to import.
archived_entry() {
  [[ -f $manifest ]] || return 1
  awk -v want="$prefix" '
    /^\[\[import\]\]/ { if (p == want && a) found = 1; p = ""; a = 0 }
    /^prefix = / { p = $3; gsub(/"/, "", p) }
    /^archived = true/ { a = 1 }
    END { if (p == want && a) found = 1; exit found ? 0 : 1 }
  ' "$manifest"
}

archived_entry && refuse "$prefix/ is imported from $repo, which is archived (release/imports.toml); nothing to import"

[[ -z $(git status --porcelain) ]] || refuse "the working tree is dirty; commit or remove the changes first"

recorded=$(recorded_sha)
if [[ -e $prefix && -z $recorded ]]; then
  refuse "$prefix/ exists but $manifest has no import for it"
fi

tip=$(git ls-remote "$source_url" refs/heads/master | awk '{print $1}') ||
  refuse "could not read master from $source_url"
[[ $tip =~ ^[0-9a-f]{40}$ ]] || refuse "could not read master from $source_url"

if [[ $tip == "$recorded" ]]; then
  echo "up to date: $repo at ${tip:0:12}"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone --quiet --no-local --single-branch --branch master "$source_url" "$work/src" ||
  refuse "could not clone $source_url"
cloned=$(git -C "$work/src" rev-parse HEAD)
git -C "$work/src" filter-repo --quiet --force --to-subdirectory-filter "$prefix" ||
  refuse "git filter-repo failed on $source_url"

git fetch --quiet --no-tags "$work/src" master || refuse "could not fetch the rewritten history"
rewritten=$(git rev-parse FETCH_HEAD)

head_before=$(git rev-parse HEAD)
if ! git merge --quiet --no-commit --no-ff --allow-unrelated-histories "$rewritten" >/dev/null; then
  git merge --abort 2>/dev/null || git reset --quiet --hard "$head_before"
  refuse "the rewritten history of $repo does not merge cleanly"
fi

# Rewrite the manifest: replace this prefix's block, or append one.
mkdir -p release
tmp_manifest="$work/imports.toml"
if [[ -f $manifest ]]; then
  awk -v want="$prefix" '
    function flush() { if (block != "" && !skip) printf "%s", block; block = ""; skip = 0 }
    /^\[\[import\]\]/ { flush(); block = $0 "\n"; next }
    block != "" {
      block = block $0 "\n"
      if ($0 ~ /^prefix = /) { p = $3; gsub(/"/, "", p); if (p == want) skip = 1 }
      next
    }
    { print }
    END { flush() }
  ' "$manifest" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' >"$tmp_manifest"
else
  printf '# Which source commit each imported prefix holds (release/import-history.sh).\n' >"$tmp_manifest"
fi
{
  printf '\n[[import]]\n'
  printf 'repo = "%s"\n' "$repo"
  printf 'prefix = "%s"\n' "$prefix"
  printf 'imported_sha = "%s"\n' "$cloned"
} >>"$tmp_manifest"
cp "$tmp_manifest" "$manifest"
git add "$manifest"

if ! git commit --quiet -m "Import $repo into $prefix/ at ${cloned:0:12}"; then
  git merge --abort 2>/dev/null || git reset --quiet --hard "$head_before"
  refuse "the import commit failed"
fi
echo "imported: $repo into $prefix/ at ${cloned:0:12}"
