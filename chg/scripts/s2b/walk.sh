#!/bin/bash
# Compiles a Mix project at each listed commit, oldest first, in MIX_ENV=test, and writes
# each commit's module digests (digests.exs) to <out>/<sha>.etf.
#
#   walk.sh <scratch clone> <app name> <shas file, oldest first> <out dir>
#
# The clone is checked out at every commit, so give it one nobody works in.
set -u
clone=$1 app=$2 shas=$3 out=$4
here=$(cd "$(dirname "$0")" && pwd)
cd "$clone" || exit 2
export MIX_ENV=test
mkdir -p "$out"
prev_lock=""
while read -r sha; do
  [ -f "$out/$sha.etf" ] && continue
  git checkout -q --detach -f "$sha" || { echo "CHECKOUT_FAIL $sha"; continue; }
  lock=$(git rev-parse HEAD:mix.lock)
  if [ "$lock" != "$prev_lock" ]; then mix deps.get >/dev/null 2>&1 || echo "DEPS_FAIL $sha"; prev_lock=$lock; fi
  s=$(date +%s)
  if mix compile > "$out/compile.log" 2>&1; then
    elixir "$here/digests.exs" "_build/test/lib/$app/ebin" "$clone" "$out/$sha.etf" > /dev/null
    echo "OK $sha $(( $(date +%s) - s ))s"
  else
    echo "COMPILE_FAIL $sha"; tail -5 "$out/compile.log"
  fi
done < "$shas"
