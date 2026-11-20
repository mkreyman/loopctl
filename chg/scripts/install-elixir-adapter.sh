#!/usr/bin/env bash
# Install the Elixir adapter (the `mix chg.*` tasks) as a Mix archive.
#
#   scripts/install-elixir-adapter.sh                  the Elixir adapters/elixir selects
#   scripts/install-elixir-adapter.sh --repo DIR ...   the Elixir each DIR/.tool-versions names
#   scripts/install-elixir-adapter.sh --all-installed  every asdf Elixir that can run it
#   ASDF_ELIXIR_VERSION=1.19.5-otp-28 scripts/install-elixir-adapter.sh
#   scripts/install-elixir-adapter.sh --all-installed --out DIR   build only
#
# Archives are per Elixir install (asdf gives each version its own MIX_HOME), so a product
# whose .tool-versions names an Elixir without the archive has no `mix chg.*` tasks, and
# its gate fails with `The task "chg.static" could not be found` (ryzen, 2026-10-26, on
# Elixir 1.20.4). --repo installs for the Elixir and Erlang a product's .tool-versions
# names; --all-installed for every asdf-installed Elixir of 1.19.5 or later, each built
# with the newest installed Erlang of its OTP (`1.20.4-otp-28` -> the newest 28.x).
# --repo and --all-installed may be combined; each Elixir is built once. Without either,
# it installs for the Elixir adapters/elixir/.tool-versions selects, or the one
# ASDF_ELIXIR_VERSION names. The adapter needs Elixir 1.19.5 or later.
#
# --out DIR builds only: each archive goes to DIR/<elixir>-otp-<otp>/chg_adapter.ez, with
# the Elixir and OTP that built it in chg_adapter.ez.toolchain beside it, and no MIX_HOME
# is touched (install-system.sh shares them with CI runners this way).
#
# Re-running replaces each archive with a fresh build, so it is idempotent. It also
# installs Hex when missing: chg runs the tasks with stdin closed, where Mix's "Shall I
# install Hex?" prompt would replace the JSON document. Exits non-zero when any requested
# Elixir could not be installed for, after trying the rest.
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then sed -n '2,27p' "$0"; exit 0; fi
root=$(cd "$(dirname "$0")/.." >/dev/null && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repos=()
all=false
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || { echo "install-elixir-adapter.sh: --repo needs a directory" >&2; exit 2; }
      repos+=("$2"); shift 2 ;;
    --all-installed) all=true; shift ;;
    --out)
      [ $# -ge 2 ] || { echo "install-elixir-adapter.sh: --out needs a directory" >&2; exit 2; }
      mkdir -p "$2"; out=$(cd "$2" && pwd -P); shift 2 ;;
    *) echo "install-elixir-adapter.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

# `<tool> <version>` from a .tool-versions file; empty when it names none.
tool_version() { awk -v t="$1" '$1 == t { print $2; exit }' "$2"; }

# The newest asdf-installed Erlang whose major is $1 (any, when $1 is empty).
erlang_for() {
  asdf list erlang 2>/dev/null | tr -d ' *' | grep -E "^${1:-[0-9]+}(\.|$)" | sort -V | tail -1
}

# Builds the archive under Elixir $1 with Erlang $2 (asdf versions; empty = whatever
# adapters/elixir selects) and installs it into that Elixir's MIX_HOME. Every step says
# `|| exit 1`: a caller's `install_for ... ||` turns errexit off inside it.
install_for() {
  local elixir=$1 erlang=$2 build="$work/build-${1:-default}"
  (
    cd "$root/adapters/elixir" || exit 1
    if [ -n "$elixir" ]; then export ASDF_ELIXIR_VERSION=$elixir; fi
    if [ -n "$erlang" ]; then export ASDF_ERLANG_VERSION=$erlang; fi
    # ASDF_*_VERSION is asdf's: under another version manager it is silently ignored.
    got=$(elixir -e 'IO.write(System.version())') || exit 1
    if [ -n "$elixir" ] && [ "$got" != "${elixir%%-*}" ]; then
      echo "install-elixir-adapter.sh: asked for Elixir ${elixir%%-*}, got $got" >&2
      exit 1
    fi
    # Keyed by Elixir and OTP, as asdf names an install (1.20.4-otp-28): one Elixir built
    # on two OTPs is two archives. One build dir each, so none recompiles over another.
    key=$(elixir -e 'IO.write("#{System.version()}-otp-#{System.otp_release()}")') || exit 1
    # The file's name is the archive's name: it must stay chg_adapter.ez.
    mkdir -p "$work/$key" || exit 1
    MIX_BUILD_ROOT="$build" MIX_ENV=prod mix archive.build -o "$work/$key/chg_adapter.ez" >&2 || exit 1
    if [ -n "$out" ]; then
      mkdir -p "$out/$key" || exit 1
      cp "$work/$key/chg_adapter.ez" "$out/$key/chg_adapter.ez" || exit 1
      elixir -e 'IO.write("Elixir #{System.version()} / OTP #{System.otp_release()}\n")' \
        > "$out/$key/chg_adapter.ez.toolchain" || exit 1
      echo "built: $out/$key/chg_adapter.ez"
      exit 0
    fi
    mix archive.install "$work/$key/chg_adapter.ez" --force >&2 || exit 1
    mix local.hex --if-missing --force >&2 || exit 1
    echo "installed: chg_adapter for Elixir $got in $(elixir -e 'IO.write(Mix.path_for(:archives))' 2>/dev/null || echo 'its MIX_HOME')"
  )
}

# The (elixir, erlang) pairs to build for, one line each, tab-separated.
pairs="$work/pairs"
: > "$pairs"
# ${a[@]+"${a[@]}"}: macOS bash 3.2 calls an empty array unbound under set -u.
for r in ${repos[@]+"${repos[@]}"}; do
  tv="$r/.tool-versions"
  if [ ! -f "$tv" ]; then
    echo "install-elixir-adapter.sh: $tv not found" >&2; exit 2
  fi
  ex=$(tool_version elixir "$tv")
  [ -n "$ex" ] || { echo "install-elixir-adapter.sh: $tv names no elixir" >&2; exit 2; }
  printf '%s\t%s\n' "$ex" "$(tool_version erlang "$tv")" >> "$pairs"
done
if $all; then
  command -v asdf >/dev/null || { echo "install-elixir-adapter.sh: --all-installed needs asdf" >&2; exit 2; }
  for ex in $(asdf list elixir 2>/dev/null | tr -d ' *'); do
    v=${ex%%-*}
    # The adapter needs 1.19.5 or later.
    [ "$(printf '%s\n1.19.5\n' "$v" | sort -V | head -1)" = 1.19.5 ] || continue
    otp=""
    case "$ex" in *-otp-*) otp=${ex##*-otp-} ;; esac
    printf '%s\t%s\n' "$ex" "$(erlang_for "$otp")" >> "$pairs"
  done
fi
if ! $all && [ -z "${repos[*]+set}" ]; then
  install_for "${ASDF_ELIXIR_VERSION:-}" ""
  exit 0
fi

failed=""
while IFS=$'\t' read -r ex er; do
  install_for "$ex" "$er" || failed="$failed $ex"
done < <(sort -u -t "$(printf '\t')" -k1,1 "$pairs")
if [ -n "$failed" ]; then
  echo "install-elixir-adapter.sh: not installed for Elixir$failed (is it installed? \`asdf install elixir <version>\`)" >&2
  exit 1
fi
