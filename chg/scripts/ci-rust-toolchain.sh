#!/usr/bin/env bash
# ci-rust-toolchain.sh [--component C]... [--target T]... — pins the Rust toolchain named
# in .tool-versions for one CI job: RUSTUP_TOOLCHAIN in $GITHUB_ENV, never `rustup default`,
# which is per-user state shared by every job on a persistent runner.
#
# chg's CI runs on the fleet-ci runner pool (infra runbooks/ci-runner-setup.md), whose account
# carries no Rust, so the first job installs rustup into that account's home and later jobs
# reuse it. Pool jobs run concurrently under that one account, so installs take a lock there.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
ver=$(awk '$1=="rust"{print $2}' "$root/.tool-versions")
[ -n "$ver" ] || { echo "::error::no rust line in .tool-versions"; exit 1; }

components=()
targets=()
while [ $# -gt 0 ]; do
  if { [ "$1" = --component ] || [ "$1" = --target ]; } && [ $# -lt 2 ]; then
    echo "ci-rust-toolchain.sh: $1 needs a value" >&2
    exit 2
  fi
  case $1 in
    --component) components+=("$2"); shift 2 ;;
    --target) targets+=("$2"); shift 2 ;;
    *) echo "usage: ci-rust-toolchain.sh [--component C]... [--target T]..." >&2; exit 2 ;;
  esac
done

export PATH="$HOME/.cargo/bin:$PATH"
# macOS ships no flock(1); a Mac runner is one registration, so one job at a time there.
exec 9>"$HOME/.ci-rustup.lock"
if command -v flock >/dev/null; then flock 9; fi
if ! command -v rustup >/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
    sh -s -- -y --no-modify-path --profile minimal --default-toolchain none
fi
rustup toolchain install "$ver" --profile minimal
[ ${#components[@]} -eq 0 ] || rustup component add --toolchain "$ver" "${components[@]}"
[ ${#targets[@]} -eq 0 ] || rustup target add --toolchain "$ver" "${targets[@]}"
exec 9>&-

echo "$HOME/.cargo/bin" >>"$GITHUB_PATH"
echo "RUSTUP_TOOLCHAIN=$ver" >>"$GITHUB_ENV"
# A CARGO_HOME per job, never the shared ~/.cargo, where concurrent jobs would change the
# registry under each other's builds. It lives in the workspace so the cache actions
# (.github/actions/cargo-cache-*) name it by a relative path, the same on every slot.
echo "CARGO_HOME=${GITHUB_WORKSPACE:?}/.ci-cargo-home" >>"$GITHUB_ENV"
