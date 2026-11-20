# pick_python: prints the path of the first Python that has tomllib (3.11+), or returns 1.
# The release scripts read manifest.toml with tomllib, and macOS's /usr/bin/python3 is 3.9,
# first on PATH in a non-interactive ssh (mac-mini, 2026-11-20); Homebrew's sits beside it.
pick_python() {
  local c
  for c in python3 python3.14 python3.13 python3.12 python3.11 \
    /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    command -v "$c" >/dev/null 2>&1 || continue
    "$c" -c 'import tomllib' >/dev/null 2>&1 || continue
    command -v "$c"
    return 0
  done
  return 1
}
