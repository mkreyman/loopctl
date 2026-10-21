#!/usr/bin/env bash
# Tests for bin/pr-body-sections.sh. Run: bash tests/pr-body-sections-test.sh
set -u
check="$(cd "$(dirname "$0")/.." && pwd)/bin/pr-body-sections.sh"
fails=0
ok=$'## Risk\nLow: CI only reads the body.\n\n## How to revert\nRevert the squash commit.\n'

expect() { # expect <exit> <name> <body>
  printf '%s' "$3" | bash "$check" >/dev/null
  got=$?
  if [ "$got" -ne "$1" ]; then echo "FAIL $2: exit $got, want $1"; fails=$((fails + 1)); fi
}

expect 0 "all three" $'## Testing\nRan mix test, all pass\n'"$ok"
expect 1 "placeholder only" $'## Testing\nN/A\n'"$ok"
expect 0 "a deeper heading stays in the section" $'## Testing\n### Unit\nRan mix test, 312 pass\n'"$ok"
expect 0 "a same-level heading ends it" $'## Testing\nRan it all, passes\n## Other\nx\n'"$ok"
expect 1 "content after a same-level heading is not Testing's" $'## Testing\n## Other\nRan it all, passes\n'"$ok"
expect 1 "empty code spans add nothing" $'## Testing\n`a` `b` `c`\n'"$ok"
expect 1 "repeated placeholders" $'## Testing\nNone none N/A todo\n'"$ok"
expect 0 "a word containing a placeholder keeps its letters" $'## Testing\nNonetheless ok\n'"$ok"
expect 0 "setext headings" $'Testing\n-------\nRan it all, passes\n\nRisk\n----\nLow: CI only here\n\nHow to revert\n---\nRevert the commit\n'
expect 0 "fenced code is content" $'## Testing\n```\nmix test\n312 tests, 0 failures\n```\n'"$ok"

[ "$fails" -eq 0 ] && echo "pr-body-sections-test: ok" || { echo "pr-body-sections-test: $fails failure(s)"; exit 1; }
