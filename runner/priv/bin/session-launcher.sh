#!/usr/bin/env bash
# session-launcher.sh — the process the runner's Port actually spawns.
#
#   LOOP_SESSION_ID=<uuid> session-launcher.sh <stderr-log> <claude-headless.sh> [claude args...]
#
# It exists because spawning the CLI straight from a Port goes wrong three ways (design §8):
#
# 1. CLOSING A PORT DOES NOT KILL A PROCESS TREE, AND NEITHER DOES A GROUP KILL. This
#    script makes itself a session leader so the CLI shares its process group. A Port
#    child already is one on OTP 28 (measured on Linux and macOS), where a bare setsid(2)
#    fails with EPERM, so leadership is CHECKED and perl's POSIX::setsid is used only when
#    it is missing. But the group is not the whole tree: Claude Code's Bash tool runs each
#    command in a NEW session, and a group KILL leaves it running, reparented to init.
#    Three things reach it, and kill_session uses all three:
#      - the group itself;
#      - the LOOP_SESSION_ID marker every descendant inherits — visible to `ps` for every
#        process on Linux, but on macOS only for non-Apple binaries (node, beam), since
#        `ps -E` cannot read a platform binary's environment (measured, macOS on arm64);
#      - the TREE FILE: while the CLI runs, a recorder snapshots this launcher's
#        descendants every LOOP_TREE_POLL_S seconds as "pid start" lines (a tagged start,
#        see sid() below), so a process orphaned later is still known. A recorded pid is
#        signalled only if its start still matches, so a recycled pid is never hit.
#    KNOWN BOUND, macOS only: a process orphaned before any snapshot sees it — a
#    `nohup ... &` from a wrapper shell that exits within the poll interval — is an Apple
#    binary the marker cannot see and a pid no snapshot recorded. Nothing here reaches it.
#    Closing that needs OS process tracking (an EndpointSecurity client, which needs an
#    entitlement and root), not a shell. On Linux the marker covers it.
#
# 2. THE BEAM CAN DIE WITHOUT RUNNING TEARDOWN. A kill -9 of the runner, an aborted break
#    menu, an OOM: none reaches Elixir code. What always happens is that the Port's pipe
#    closes, so a watchdog reads this script's stdin and ends the session on EOF — TERM,
#    a grace period, then KILL. The runner's boot-time reaper is the line behind it.
#
# 3. STDIN AND STDERR MUST NOT BE THE PORT. `claude -p` gets /dev/null on stdin, so it
#    never waits on input the Port will not send, and stderr goes to a file, so stdout
#    stays pure stream-json.
#
# Portable to macOS's /bin/bash 3.2: no $BASHPID, no associative arrays, no GNU-only flags.
#
# Exit code: the CLI's own, or 128+signal when it was killed.

set -u

stderr_log=${1:?stderr log path required}
headless=${2:?claude-headless.sh path required}
shift 2
: "${LOOP_SESSION_ID:?LOOP_SESSION_ID required}"
grace=${LOOP_KILL_GRACE_S:-5}
poll=${LOOP_TREE_POLL_S:-1}
tree_file=${LOOP_TREE_FILE:-$stderr_log.tree}
launcher=$$
marker="LOOP_SESSION_ID=$LOOP_SESSION_ID"

pgid=$(ps -o pgid= -p $$ | tr -d ' ')
if [ "$pgid" != "$$" ]; then
    if [ -n "${LOOPCTL_LAUNCHER_SETSID:-}" ]; then
        echo "session-launcher: still not a process group leader after setsid" >&2
        exit 70
    fi
    export LOOPCTL_LAUNCHER_SETSID=1
    exec perl -MPOSIX -e 'POSIX::setsid() != -1 or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"' \
        -- "$0" "$stderr_log" "$headless" "$@"
fi
unset LOOPCTL_LAUNCHER_SETSID

# One row per process: pid, ppid, pgid, the five-word start time, then command and (where
# ps can read it) environment.
case "$(uname -s)" in
    Darwin) ps_args="-A -E -ww -o pid=,ppid=,pgid=,lstart=,command=" ;;
    *) ps_args="axeww -o pid=,ppid=,pgid=,lstart=,command=" ;;
esac

# Each process is recorded by a start no timezone moves, tagged with its form, as
# LoopctlRunner.ProcessGroup compares it: a start printed in the reader's own zone mismatched
# whenever the daemon and a reaper differ in theirs, or the zone changed while a session ran, and
# a live session's processes read as strangers (#66). On Linux that is the kernel's start,
# "boot:<boot id>:<ticks>" (LoopctlRunner.Owner.start_id/1), since procps derives lstart from the
# wall clock and a clock step moves it. Elsewhere, or with no boot id, it is "utc:<lstart>" from
# the snapshot, read under UTC and the C locale (LoopctlRunner.Owner.start_time/1).
boot_id=
[ -r /proc/sys/kernel/random/boot_id ] && boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)

snapshot() {
    # shellcheck disable=SC2086
    TZ=UTC LC_ALL=C ps $ps_args > "$1" 2>/dev/null
}

# sid(pid, lstart): the start to record or compare, or "" when it cannot be read. On Linux, field
# 22 of /proc/<pid>/stat, the 20th after the LAST ")" (a command name can hold one), parsed as
# LoopctlRunner.Owner.start_ticks/1 parses it: change one and change the other, or every boot:
# line stops matching (session_launcher_test compares the two). It is read a
# moment after the snapshot; a pid reused in that moment would need the whole pid space to wrap,
# while a parent or group changing in it (a setsid, a reparent) is normal, so neither is checked.
AWK_SID='
function sid(p, lstart,   f, line, a) {
    if (bootid == "") return "utc:" lstart
    f = "/proc/" p "/stat"
    if ((getline line < f) <= 0) { close(f); return "" }
    close(f)
    sub(/^.*\)/, "", line)
    split(line, a, " ")
    if (a[20] !~ /^[0-9]+$/) return ""
    return "boot:" bootid ":" a[20]
}'

# Descendants of the launcher, and marked processes, as "pid start" lines.
AWK_RECORD="$AWK_SID"'
{ pid = $1; parent[pid] = $2; start[pid] = $4 " " $5 " " $6 " " $7 " " $8; row[pid] = " " $0 " " }
function emit(p,   s) { s = sid(p, start[p]); if (s != "") print p, s }
END {
    inset[root] = 1
    changed = 1
    while (changed) {
        changed = 0
        for (p in parent) if (!(p in inset) && (parent[p] in inset)) { inset[p] = 1; changed = 1 }
    }
    for (p in inset) if (p != root) emit(p)
    for (p in row) if (!(p in inset) && index(row[p], " " marker " ")) emit(p)
}'

# Recorded pids whose start still matches ANY line recorded for that pid (a pid reused during the
# session has one per process it named), minus everything still in this launcher's own group:
# the group signal, sent last, ends those, and signalling the watchdog's own `sleep` by pid would
# cut its grace period short. Excluded by group, never by name — a detached command that merely
# mentions this script must still be ended.
AWK_LIVE="$AWK_SID"'
FNR == NR { rec[$1, substr($0, index($0, " ") + 1)] = 1; seen[$1] = 1; next }
($1 in seen) && $3 != group && (($1, sid($1, $4 " " $5 " " $6 " " $7 " " $8)) in rec) { print $1 }'

# Silent on failure: the run directory can disappear under a dying run, and a recorder
# that cannot write simply records nothing more.
record_tree() {
    local snap="$tree_file.snap.$1"
    {
        snapshot "$snap" &&
            { [ -f "$tree_file" ] && cat "$tree_file"; awk -v root="$launcher" -v marker="$marker" -v bootid="$boot_id" "$AWK_RECORD" "$snap"; } \
                | sort -u > "$tree_file.tmp.$1" && mv "$tree_file.tmp.$1" "$tree_file"
        rm -f "$snap"
    } 2>/dev/null
}

# Signals every recorded or marked process still alive, then the group. $1 is a signal,
# $2 a tag unique to the caller so concurrent callers never share temp files.
kill_session() {
    local sig=$1 tag=$2 targets snap
    record_tree "$tag"
    snap="$tree_file.live.$tag"
    targets=$({ snapshot "$snap" && awk -v group="$launcher" -v bootid="$boot_id" "$AWK_LIVE" "$tree_file" "$snap"; } 2>/dev/null)
    rm -f "$snap" 2>/dev/null
    # shellcheck disable=SC2086
    [ -n "$targets" ] && kill "-$sig" $targets 2>/dev/null
    kill "-$sig" -- "-$launcher" 2>/dev/null
}

# Keep the Port's stdin on fd 3 for the watchdog: without job control, bash gives a
# background command /dev/null as stdin unless it is redirected explicitly.
exec 3<&0

"$headless" "$@" </dev/null 3<&- 2>>"$stderr_log" &
child=$!

(
    exec 3<&-
    while kill -0 "$child" 2>/dev/null; do
        record_tree recorder
        sleep "$poll"
    done
) &
recorder=$!

(
    while IFS= read -r _ <&3; do :; done
    # Only now deaf to TERM: the group signal it is about to send includes itself.
    trap '' TERM
    kill_session TERM watchdog
    sleep "$grace"
    kill_session KILL watchdog
) &
watchdog=$!
exec 3<&-

wait "$child"
code=$?

# The CLI is gone. Anything it left behind — a detached Bash-tool command, an MCP server —
# would hold the Port's stdout open or simply outlive the run. TERM it all before
# reporting, without taking this script with it; the runner escalates to KILL.
{ kill -KILL "$watchdog" "$recorder" && wait "$watchdog" "$recorder"; } 2>/dev/null
trap '' TERM
kill_session TERM exit
exit "$code"
