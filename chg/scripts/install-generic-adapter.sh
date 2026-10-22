#!/usr/bin/env bash
# Install the generic adapter (adapters/generic/chg-adapter.py).
#
#   scripts/install-generic-adapter.sh [<dir>]
#
# Copies it to <dir>, default $HOME/.local/share/chg/generic, where a generic repo's
# manifest commands run it. It is one stdlib Python script: the repo supplies its own
# selector and runner. Built in a sibling directory and swapped in by two renames, so a
# chg run never loads a half-copied adapter. Re-running is idempotent.
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then sed -n '2,9p' "$0"; exit 0; fi
root=$(cd "$(dirname "$0")/.." >/dev/null && pwd -P)
dest=${1:-$HOME/.local/share/chg/generic}
parent=$(dirname "$dest")
mkdir -p "$parent"
work=$(mktemp -d "$parent/.generic.XXXXXX")
old="$work.old"
trap 'rm -rf "$work" "$old"' EXIT

cp "$root/adapters/generic/chg-adapter.py" "$work/"
# Readable by every user whatever the umask (a CI runner user reads a copy root installed).
chmod 755 "$work"
chmod 644 "$work/chg-adapter.py"

if [ -e "$dest" ]; then mv "$dest" "$old"; fi
mv "$work" "$dest"
echo "installed: chg generic adapter in $dest"
