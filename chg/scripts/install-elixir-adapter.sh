#!/usr/bin/env bash
# Install the Elixir adapter (the `mix chg.*` tasks) as a Mix archive.
#
#   scripts/install-elixir-adapter.sh
#   ASDF_ELIXIR_VERSION=1.19.5-otp-28 scripts/install-elixir-adapter.sh
#
# Archives are per Elixir install (asdf gives each version its own MIX_HOME), so this
# installs for the Elixir that adapters/elixir/.tool-versions selects, or the one
# ASDF_ELIXIR_VERSION names; a product on that version then has `mix chg.*` without a
# dependency in its mix.exs. The adapter needs Elixir 1.19.5 or later. Re-running replaces
# the archive with a fresh build, so it is idempotent. It also installs Hex when missing:
# chg runs the tasks with stdin closed, where Mix's "Shall I install Hex?" prompt would
# replace the JSON document.
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then sed -n '2,13p' "$0"; exit 0; fi
root=$(cd "$(dirname "$0")/.." >/dev/null && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$root/adapters/elixir"
# ASDF_ELIXIR_VERSION is asdf's: under another version manager it is silently ignored.
if [ -n "${ASDF_ELIXIR_VERSION:-}" ]; then
  got=$(elixir -e 'IO.write(System.version())')
  if [ "$got" != "${ASDF_ELIXIR_VERSION%%-*}" ]; then
    echo "install-elixir-adapter.sh: asked for Elixir ${ASDF_ELIXIR_VERSION%%-*}, got $got" >&2
    exit 1
  fi
fi
MIX_ENV=prod mix archive.build -o "$work/chg_adapter.ez" >&2
mix archive.install "$work/chg_adapter.ez" --force >&2
mix local.hex --if-missing --force >&2
echo "installed: chg_adapter for Elixir $(elixir -e 'IO.write(System.version())') in $(mix eval 'IO.write(Mix.path_for(:archives))' 2>/dev/null || echo 'its MIX_HOME')"
