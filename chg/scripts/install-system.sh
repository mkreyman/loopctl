#!/usr/bin/env bash
# Make chg usable by every local user, for CI runners that run as their own user (a
# `github-runner` cannot read ~/.local/bin of the account that installed chg).
#
#   scripts/install-system.sh [--bin FILE]
#
# Installs, through sudo:
#   /usr/local/bin/chg                      FILE (default: ~/.local/bin/chg, as
#                                           scripts/install.sh leaves it), mode 755
#   /usr/local/share/chg/chg_adapter.ez     the Elixir adapter archive, built here, mode 644
#   /usr/local/share/chg/chg_adapter.ez.toolchain   the Elixir and OTP that built it
#   /usr/local/share/chg/elixir/<elixir>-otp-<otp>/chg_adapter.ez(.toolchain)
#                                           the same, built by each asdf-installed Elixir
#                                           that can run it (install-elixir-adapter.sh
#                                           --all-installed --out), so a job on another
#                                           Elixir than adapters/elixir's has its archive
#   /usr/local/share/chg/typescript/        the TypeScript adapter (chg-adapter.mjs and lib/),
#                                           files 644 in 755 dirs, through
#                                           scripts/install-typescript-adapter.sh
#   /usr/local/share/chg/generic/           the generic adapter (chg-adapter.py), file 644 in a
#                                           755 dir, through scripts/install-generic-adapter.sh
#
# A job then installs the archive into its own MIX_HOME:
#   mix archive.install /usr/local/share/chg/chg_adapter.ez --force
#   mix local.hex --if-missing --force
# The archive is compiled by the Elixir adapters/elixir/.tool-versions selects here; the
# job must run the same Elixir and OTP, which the last line printed (and
# chg_adapter.ez.toolchain beside it) names. A job on another Elixir installs
# /usr/local/share/chg/elixir/$(elixir -e 'IO.write("#{System.version()}-otp-#{System.otp_release()}")')/chg_adapter.ez
# instead, when this machine's asdf has that Elixir. Both files are staged first, then renamed
# over the old ones one after the other, so a failure leaves both as they were and a
# running job never reads a half-written file. The TypeScript adapter is copied beside its
# old directory and swapped in by rename before those, so a failed copy changes nothing.
# Idempotent: re-running replaces all three.
#
# On Linux, install.sh leaves a static binary, which a containerised job can run whatever
# its glibc. A --bin built any other way needs glibc >= the build host's in the container.
set -euo pipefail

bin="$HOME/.local/bin/chg"
while [ $# -gt 0 ]; do
  case "$1" in
    --bin)
      [ $# -ge 2 ] || { echo "install-system.sh: --bin needs a file" >&2; exit 2; }
      bin=$2; shift 2 ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "install-system.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

# Absolute, so the file checked here is the file installed below.
bin=$(realpath "$bin")
"$bin" --version >/dev/null
root=$(cd "$(dirname "$0")/.." >/dev/null && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$root/adapters/elixir"
MIX_ENV=prod mix archive.build -o "$work/chg_adapter.ez" >&2
toolchain=$(elixir -e 'IO.write("Elixir #{System.version()} / OTP #{System.otp_release()}")')
printf '%s\n' "$toolchain" > "$work/toolchain"

if command -v asdf >/dev/null 2>&1 && [ -n "$(asdf list elixir 2>/dev/null)" ]; then
  # One Elixir that fails to build must not cost the rest, or chg itself: the script
  # builds every other version before it exits non-zero, and below only versions with
  # both files are installed.
  "$root/scripts/install-elixir-adapter.sh" --all-installed --out "$work/elixir" >&2 ||
    echo "install-system.sh: some Elixir versions got no archive (above); installing the rest" >&2
fi

share=/usr/local/share/chg
sudo install -d -m 755 "$share"
# Each version's pair is staged beside the old one and renamed over it, as below.
for d in "$work"/elixir/*/; do
  [ -f "$d/chg_adapter.ez" ] && [ -f "$d/chg_adapter.ez.toolchain" ] || continue
  v=$(basename "$d")
  sudo install -d -m 755 "$share/elixir/$v"
  for f in chg_adapter.ez chg_adapter.ez.toolchain; do
    sudo install -m 644 "$d/$f" "$share/elixir/$v/.$f.new.$$"
  done
  for f in chg_adapter.ez chg_adapter.ez.toolchain; do
    sudo mv -f "$share/elixir/$v/.$f.new.$$" "$share/elixir/$v/$f"
  done
done
sudo "$root/scripts/install-typescript-adapter.sh" "$share/typescript" >&2
sudo "$root/scripts/install-generic-adapter.sh" "$share/generic" >&2
sudo install -m 755 "$bin" "/usr/local/bin/.chg.new.$$"
sudo install -m 644 "$work/chg_adapter.ez" "$share/.chg_adapter.ez.new.$$"
sudo install -m 644 "$work/toolchain" "$share/.chg_adapter.ez.toolchain.new.$$"
sudo mv -f "$share/.chg_adapter.ez.new.$$" "$share/chg_adapter.ez"
sudo mv -f "$share/.chg_adapter.ez.toolchain.new.$$" "$share/chg_adapter.ez.toolchain"
sudo mv -f "/usr/local/bin/.chg.new.$$" /usr/local/bin/chg
echo "installed: /usr/local/bin/chg ($(/usr/local/bin/chg --version)), $share/chg_adapter.ez (built with $toolchain), $share/typescript/chg-adapter.mjs, $share/generic/chg-adapter.py"
