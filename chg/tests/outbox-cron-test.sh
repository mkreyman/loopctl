#!/usr/bin/env bash
# bin/chg-outbox-cron.sh against a fake crontab: install is idempotent, keeps other lines,
# and remove takes only its own line.

set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd -P)
script="$here/bin/chg-outbox-cron.sh"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# A crontab that keeps its table in $t/tab.
cat >"$t/crontab" <<EOF
#!/usr/bin/env bash
case "\$1" in
  -l) [ -f "$t/tab" ] && cat "$t/tab" || exit 1 ;;
  -) cat > "$t/tab" ;;
esac
EOF
chmod +x "$t/crontab"
printf '#!/bin/sh\n' >"$t/chg"
chmod +x "$t/chg"
export CRONTAB="$t/crontab" CHG_HOME="$t/home"

printf '0 3 * * * other-job\n' >"$t/tab"
"$script" --install --chg "$t/chg" >/dev/null
"$script" --install --chg "$t/chg" >/dev/null
[ "$(grep -c 'chg-outbox-send' "$t/tab")" = 1 ] || fail "not idempotent: $(cat "$t/tab")"
grep -q '^0 3 \* \* \* other-job$' "$t/tab" || fail "lost another line: $(cat "$t/tab")"
grep -qF "CHG_HOME='$t/home' nice -n 10 '$t/chg' outbox send --quiet >> '$t/home/outbox/send.log' 2>&1" "$t/tab" || fail "wrong line: $(cat "$t/tab")"
[ -d "$t/home/outbox" ] || fail "install did not create the log directory"
# The installed line runs under sh: the log is written and chg starts.
printf '#!/bin/sh\necho ran\n' >"$t/chg"
grep chg-outbox-send "$t/tab" | sed 's/^[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* //' | sh
grep -q '^ran$' "$t/home/outbox/send.log" || fail "the cron command did not run chg"

"$script" --remove >/dev/null
grep -q chg-outbox-send "$t/tab" && fail "not removed: $(cat "$t/tab")"
grep -q other-job "$t/tab" || fail "remove took another line"

if "$script" --install --chg "$t/missing" 2>/dev/null; then fail "installed a missing chg"; fi
echo "ok: outbox cron"
