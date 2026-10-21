#!/bin/bash
# pr-body-sections.sh — a PR body (on stdin) must carry Testing, Risk and How to revert sections,
# each with real content. Exit 0 when all three do, 1 naming the ones that don't, 2 on usage error.
#
# Why (#918, item 1): Anthropic's PR template asks how the change was tested and how to undo it,
# and our measurement says only a CHECKED field gets filled. Across HCB's last 50 merged PRs
# (2026-10-20) the CI-checked "Domain model reference" was filled 50/50, the advisory Testing
# section 6/50, a revert path 1/50. Agents open PRs with --body-file, which skips the template.
#
# A section is a markdown heading of any level whose text starts with the name (case-insensitive),
# e.g. `## Testing`, `### Risk: low`, `## How to revert`. Its content is everything up to the next
# heading (ATX `#`, indented up to 3 spaces, or setext text underlined with = or -). Fenced code
# counts as content and never opens a heading; inline code and HTML comments are blanked. After
# placeholders (N/A, none, TBD, todo, not applicable) are dropped, at least 10 letters or digits must
# remain, so "N/A" or "None. None." fails while "N/A: docs only, nothing executes" passes.
set -u
[ $# -eq 0 ] || { echo "usage: pr-body-sections.sh < body.md" >&2; exit 2; }

body=$(cat)
missing=""
for name in "Testing" "Risk" "How to revert"; do
  n=$(printf '%s\n' "$body" | awk -v want="$name" '
    function heading(t,   h) {  # does heading text t open the wanted section? sets rest
      h = tolower(t); sub(/^[ \t]*#*[ \t]*/, "", h)
      if (index(h, want) != 1) return 0
      rest = substr(h, length(want) + 1); return 1
    }
    function atx_level(t) { match(t, /#+/); return RLENGTH }
    BEGIN { want = tolower(want); in_c = 0; fence = ""; on = 0; lvl = 0; acc = ""; prev_on = 0; prev_len = -1; prev = "" }
    {
      line = $0
      # Fenced code: its lines are content, never headings or comments.
      if (fence != "") {
        if (line ~ ("^( |  |   )?" fence)) fence = ""
        else if (on) acc = acc " " line
        prev_len = -1; next
      }
      if (match(line, /^( |  |   )?(```|~~~)/)) { fence = substr(line, RSTART + RLENGTH - 3, 3); prev_len = -1; next }
      # Inline code spans are blanked, so a quoted comment marker opens nothing and an empty
      # span adds nothing to the count.
      gsub(/`[^`]*`/, " ", line)
      out = ""
      while (length(line) > 0) {
        if (in_c) {
          e = index(line, "-->"); if (e == 0) { line = ""; break }
          line = substr(line, e + 3); in_c = 0
        } else {
          s = index(line, "<!--"); if (s == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, s - 1); line = substr(line, s + 4); in_c = 1
        }
      }
      # Setext heading: an underline of = or - turns the previous text line into a heading.
      # A heading deeper than the wanted one is part of its section, and its text is content.
      if (out ~ /^( |  |   )?(=+|-+)[ \t]*$/ && prev_len >= 0) {
        lv = (out ~ /=/) ? 1 : 2
        if (prev_on && lv > lvl) { prev_len = -1; next }
        if (prev_on) acc = substr(acc, 1, prev_len)
        on = heading(prev); if (on) { acc = acc " " rest; lvl = lv }
        prev_len = -1; next
      }
      if (out ~ /^( |  |   )?#+([ \t]|$)/) {
        lv = atx_level(out)
        if (on && lv > lvl) { acc = acc " " out; prev_len = -1; next }
        on = heading(out); if (on) { acc = acc " " rest; lvl = lv }
        prev_len = -1; next
      }
      if (out ~ /^[ \t]*$/) { prev_len = -1; next }
      prev = out; prev_on = on; prev_len = length(acc)
      if (on) acc = acc " " out
    }
    END {
      # Placeholders say nothing: drop them, then count the letters and digits left.
      t = tolower(acc)
      # Whole words only, so "Nonetheless" keeps its letters; repeated until none is left.
      ph = "(^|[^[:alnum:]])(n/a|not applicable|none|tbd|todo|nothing to (test|add|say))([^[:alnum:]]|$)"
      while (gsub(ph, " ", t)) ;
      gsub(/[^[:alnum:]]/, "", t); print length(t)
    }')
  [ "$n" -ge 10 ] || missing="$missing${missing:+, }$name"
done

if [ -n "$missing" ]; then
  echo "PR body is missing real content under: $missing"
  echo "Add a markdown heading for each (## Testing, ## Risk, ## How to revert) with what was run and"
  echo "what it showed, what could break and for whom, and the exact undo (usually: revert the squash"
  echo "commit; name any migration, data or deploy step a revert does not undo). N/A needs a reason."
  exit 1
fi
echo "Testing, Risk and How to revert all present"
