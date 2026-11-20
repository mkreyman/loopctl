#!/usr/bin/env bash
# The workspace clean for a runner-ci or chg-ci job checked out with `clean: false` (US-52.6).
#
# All three workflows of this repository share one workspace per fleet-ci slot. A job left at
# the checkout default (`clean: true`, `git clean -ffdx`) deletes the root `_build` and `deps`
# that ci.yml's jobs keep warm on purpose (KEEPING THE COMPILED TREE, top of ci.yml), so every
# chg or runner job would cost the next server job a cold compile. This is ci.yml's clean,
# with the same exceptions: each project's compiled tree survives, everything else untracked
# goes. Patterns are anchored, so a fixture directory named `deps` is still cleaned.
set -uo pipefail

git clean -ffdx -e /_build -e /deps -e /runner/_build -e /runner/deps || {
  echo "clean failed; wiping the workspace so the next run re-clones"
  find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + || true
}
git reset --hard HEAD
