#!/usr/bin/env bash
# Makes the e2e sandbox repository match e2e/sandbox/template/ (US-52.9, AC-52.9.6).
#
#   GH_TOKEN=<token> e2e/sandbox/provision.sh
#
# Creates the repository (private) and the intake label when either is missing, then copies
# the template over a clone and pushes one commit to master when anything differs. A second
# run changes nothing and says so. It never deletes: each run's lib/sandbox/runs/ file stays.
#
# Environment:
#   SANDBOX_REPO     owner/name               (default mkreyman/loopctl-e2e-sandbox)
#   SANDBOX_LABEL    the label the intake source watches (default loopctl)
#   SANDBOX_REMOTE   git URL to clone and push (default: gh's clone of SANDBOX_REPO); the
#                    test points it at a local bare repository
#
# Exit: 0 matched or updated, 1 a step failed, 2 no token.
set -euo pipefail

repo=${SANDBOX_REPO:-mkreyman/loopctl-e2e-sandbox}
label=${SANDBOX_LABEL:-loopctl}
here=$(cd "$(dirname "$0")" && pwd)
template="$here/template"

if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "provision: set GH_TOKEN to a token that can administer $repo" >&2
  exit 2
fi

changed=0

if ! gh repo view "$repo" --json name >/dev/null 2>&1; then
  gh repo create "$repo" --private --description "loopctl e2e sandbox (US-52.9)" >/dev/null
  echo "provision: created $repo"
  changed=1
fi

if ! gh label list --repo "$repo" --limit 200 --json name --jq '.[].name' | grep -qx "$label"; then
  gh label create "$label" --repo "$repo" --color 5319e7 \
    --description "loopctl intake: the e2e sandbox source watches this label" >/dev/null
  echo "provision: created label $label"
  changed=1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -n "${SANDBOX_REMOTE:-}" ]; then
  git clone --quiet "$SANDBOX_REMOTE" "$work/sandbox" 2>/dev/null
else
  gh repo clone "$repo" "$work/sandbox" -- --quiet 2>/dev/null
fi

cd "$work/sandbox"
git checkout --quiet -B master 2>/dev/null

cp -R "$template/." .

# Name the template's files, never everything: a run's own file is the factory's to commit.
(cd "$template" && find . -type f -print0) | xargs -0 git add --

if git diff --cached --quiet; then
  if [ "$changed" = 0 ]; then
    echo "provision: $repo already matches the template; sandbox up to date"
  else
    echo "provision: files already match the template"
  fi
  exit 0
fi

git -c user.name="loopctl e2e" -c user.email="e2e@loopctl.invalid" \
  commit --quiet -m "Provision the sandbox from loopctl's e2e/sandbox/template"
git push --quiet origin HEAD:master
echo "provision: pushed the template to $repo master"

if [ -z "${SANDBOX_REMOTE:-}" ]; then
  gh api -X PATCH "repos/$repo" -f default_branch=master >/dev/null
fi
