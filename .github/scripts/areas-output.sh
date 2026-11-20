#!/usr/bin/env bash
# Writes the changes job's outputs (server, runner, chg, e2e: true or false) to $GITHUB_OUTPUT
# from the event being judged (US-52.6). A schedule, a manual run or anything else counts as
# every area, so a nightly run tests everything.
#
# A push to master is judged from its before-sha. A push to any other branch is judged on the
# whole branch, from its merge base with origin/master (a new branch's first push, whose
# before-sha is all zeros, too): a later push on a branch cancels the earlier push's run
# (per-ref cancel-in-progress), so a run judged only on before..sha would leave the cancelled
# push's areas unchecked. The workflows run on push only, so a branch's newest push run is the
# one evidence of every area it touches. With no origin/master to measure from (the changes
# job checks out with fetch-depth 0, which fetches it), changed-areas.sh is handed an
# unreadable base and counts every area.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
zero=0000000000000000000000000000000000000000

case ${GITHUB_EVENT_NAME:-} in
  push)
    if [[ ${GITHUB_REF:?} == refs/heads/master ]]; then
      base=${EVENT_BEFORE:?}
    else
      base=$(git merge-base origin/master "${GITHUB_SHA:?}" 2>/dev/null) || base=$zero
    fi
    areas=$("$here/changed-areas.sh" "$base" "${GITHUB_SHA:?}")
    ;;
  *) areas=$(printf '%s\n' chg e2e runner server) ;;
esac

echo "areas: $(echo "$areas" | tr '\n' ' ')"
for area in server runner chg e2e; do
  if grep -qx "$area" <<<"$areas"; then
    echo "$area=true"
  else
    echo "$area=false"
  fi
done >>"${GITHUB_OUTPUT:?}"
