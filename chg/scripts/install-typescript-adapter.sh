#!/usr/bin/env bash
# Install the TypeScript adapter (adapters/typescript/chg-adapter.mjs and its lib/).
#
#   scripts/install-typescript-adapter.sh [<dir>]
#
# Copies it to <dir>, default $HOME/.local/share/chg/typescript, where the manifest
# template's commands run it. The adapter has no npm dependencies: it drives the
# product's own pnpm, vitest, playwright, eslint and tsc. The copy is built in a sibling
# directory and swapped in by two renames, so a chg run never loads a half-copied
# adapter. Re-running is idempotent.
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then sed -n '2,10p' "$0"; exit 0; fi
root=$(cd "$(dirname "$0")/.." >/dev/null && pwd -P)
dest=${1:-$HOME/.local/share/chg/typescript}
parent=$(dirname "$dest")
mkdir -p "$parent"
work=$(mktemp -d "$parent/.typescript.XXXXXX")
old="$work.old"
trap 'rm -rf "$work" "$old"' EXIT

src="$root/adapters/typescript"
cp "$src/chg-adapter.mjs" "$src/.tool-versions" "$work/"
cp -R "$src/lib" "$work/lib"
# Readable by every user whatever the umask (a CI runner user reads a copy root installed).
find "$work" -type d -exec chmod 755 {} +
find "$work" -type f -exec chmod 644 {} +

if [ -e "$dest" ]; then mv "$dest" "$old"; fi
mv "$work" "$dest"
echo "installed: chg TypeScript adapter in $dest"
