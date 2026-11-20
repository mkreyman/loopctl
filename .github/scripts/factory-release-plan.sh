#!/usr/bin/env bash
# The factory-release plan for one master commit (US-52.7): reads release/manifest.toml's set
# and writes `tag` and `action` to $GITHUB_OUTPUT (stdout without it):
#
#   create   no tag factory-<set> exists: tag $SHA and publish the release
#   upload   factory-<set> already points at $SHA: a re-run, re-upload with --clobber
#   none     factory-<set> points at another commit: this commit did not move the set
#
# Tags are read from origin, so a tag another run pushed is seen.
set -euo pipefail

: "${SHA:?}"
set_n=$(python3 -I -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb"))["set"])' release/manifest.toml)
[[ $set_n =~ ^[1-9][0-9]*$ ]] || { echo "release/manifest.toml: set is not a positive integer: $set_n" >&2; exit 1; }
tag="factory-$set_n"

# The peeled line (^{}) of an annotated tag names the commit; a lightweight tag has only one.
tagged=$(git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}" | awk '{print $1}' | tail -1)
if [ -z "$tagged" ]; then
  action=create
elif [ "$tagged" = "$SHA" ]; then
  action=upload
else
  action=none
fi

echo "set $set_n: $tag is ${tagged:-absent}; action $action"
printf 'tag=%s\naction=%s\n' "$tag" "$action" >>"${GITHUB_OUTPUT:-/dev/stdout}"
