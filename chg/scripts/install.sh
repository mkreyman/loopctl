#!/usr/bin/env bash
# Install the chg binary for this machine.
#
#   scripts/install.sh [--dest DIR] [--release TAG]
#
# --release TAG  download the release artifact (Linux x86_64 only; needs `gh` with access
#                to mkreyman/chg) and check its sha256; without it, build from this checkout.
# --dest DIR     where `chg` goes (default: ~/.local/bin).
#
# On Linux x86_64 both paths give the static musl binary, so a CI job running in a container
# with an older glibc than the build host (node:22-bookworm has 2.36) can run the mounted
# /usr/local/bin/chg. The source build adds the musl target to the pinned toolchain; it links
# with musl's self-contained CRT through the host cc, so no musl-tools package is needed.
#
# Idempotent: an identical binary already at DEST is left alone. The new binary is written
# beside the old one and renamed over it, so a running `chg` never sees a half-written file.
set -euo pipefail

dest="$HOME/.local/bin"
tag=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) dest=$2; shift 2 ;;
    --release) tag=$2; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) target=aarch64-apple-darwin ;;
  Linux/x86_64) target=x86_64-unknown-linux-musl ;;
  *) echo "install.sh: no chg build for $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Releases carry no macOS artifact (release.yml has no macOS runner): Macs build from source.
if [ -n "$tag" ] && [ "$target" != x86_64-unknown-linux-musl ]; then
  echo "install.sh: releases carry no $target build; run without --release to build it" >&2
  exit 1
fi
if [ -n "$tag" ]; then
  gh release download "$tag" -R mkreyman/chg -D "$work" \
    -p "chg-$target" -p "chg-$target.sha256"
  (cd "$work" && shasum -a 256 -c "chg-$target.sha256" >/dev/null)
  bin="$work/chg-$target"
else
  root=$(cd "$(dirname "$0")/.." >/dev/null && pwd -P)
  if [ "$target" = x86_64-unknown-linux-musl ]; then
    (cd "$root" && rustup target add "$target" >&2)
    (cd "$root" && cargo build --release --locked -p chg --target "$target" >&2)
    bin="${CARGO_TARGET_DIR:-$root/target}/$target/release/chg"
  else
    cargo build --release --locked -p chg --manifest-path "$root/Cargo.toml" >&2
    bin="${CARGO_TARGET_DIR:-$root/target}/release/chg"
  fi
fi

chmod +x "$bin"
"$bin" --version >/dev/null
mkdir -p "$dest"
if [ -f "$dest/chg" ] && cmp -s "$bin" "$dest/chg"; then
  echo "unchanged: $dest/chg ($("$dest/chg" --version))"
  exit 0
fi
cp "$bin" "$dest/.chg.new.$$"
mv -f "$dest/.chg.new.$$" "$dest/chg"
echo "installed: $dest/chg ($("$dest/chg" --version))"
