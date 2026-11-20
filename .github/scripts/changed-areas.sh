#!/usr/bin/env bash
# The areas a change touches (US-52.6), one per line, sorted:
#
#   .github/scripts/changed-areas.sh <base> <head>
#
#   runner  runner/** or priv/runner_contract/** (the contract the runner compiles in)
#   chg     chg/**
#   e2e     e2e/**
#   server  every other path, priv/runner_contract/** included (the server exports it)
#
# release/** and .github/** count as every area: they decide how every area is built and
# shipped. So does a base that cannot be read (a branch's first push, whose before-sha is all
# zeros, or a base outside this clone): judging nothing would skip every check.
#
# The diff is <base>...<head>, from their merge base, so a pull request is judged on its own
# commits and not on what master gained since it branched.
set -euo pipefail

all() {
  printf '%s\n' chg e2e runner server
  exit 0
}

[[ $# -eq 2 ]] || { echo "usage: changed-areas.sh <base> <head>" >&2; exit 2; }
base=$1
head=$2

[[ $base =~ ^0+$ ]] && all
git cat-file -e "$base^{commit}" 2>/dev/null || all
git cat-file -e "$head^{commit}" 2>/dev/null || all
git merge-base "$base" "$head" >/dev/null 2>&1 || all

areas=()
while IFS= read -r -d '' path; do
  case $path in
    release/* | .github/*) all ;;
    runner/*) areas+=(runner) ;;
    priv/runner_contract/*) areas+=(runner server) ;;
    chg/*) areas+=(chg) ;;
    e2e/*) areas+=(e2e) ;;
    *) areas+=(server) ;;
  esac
done < <(git diff --name-only -z --no-renames "$base...$head")

((${#areas[@]})) || exit 0
printf '%s\n' "${areas[@]}" | sort -u
