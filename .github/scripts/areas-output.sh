#!/usr/bin/env bash
# Writes the changes job's outputs (server, runner, chg, e2e: true or false) to $GITHUB_OUTPUT
# from the event being judged (US-52.6). A push is judged from its before-sha, a pull request
# from its base; a schedule, a manual run or anything else counts as every area, so a nightly
# run tests everything.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
case ${GITHUB_EVENT_NAME:-} in
  push) areas=$("$here/changed-areas.sh" "${EVENT_BEFORE:?}" "${GITHUB_SHA:?}") ;;
  pull_request) areas=$("$here/changed-areas.sh" "${PR_BASE_SHA:?}" "${PR_HEAD_SHA:?}") ;;
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
