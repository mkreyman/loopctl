#!/usr/bin/env bash
# session-launcher.sh — the process the runner's Port actually spawns.
#
#   LOOP_SESSION_ID=<uuid> session-launcher.sh <stderr-log> <claude-headless.sh> [claude args...]
#
# It exists because spawning the CLI straight from a Port goes wrong three ways (design §8):
#
# 1. CLOSING A PORT DOES NOT KILL A PROCESS TREE, AND NEITHER DOES A GROUP KILL. This
#    script makes itself a session leader so the CLI shares its process group. On
#    OTP 28 / Linux the Port child already is one (measured: pid = pgid = sid), where a
#    bare setsid(2) fails with EPERM, so leadership is CHECKED and perl's POSIX::setsid is
#    used only when it is missing (perl ships on Linux and macOS; macOS has no setsid(1)).
#    But the group is not the whole tree: Claude Code's Bash tool runs each command in a
#    NEW session, and a group KILL leaves it running, reparented to init (measured on
#    2.1.270). Every descendant does inherit LOOP_SESSION_ID, so kill_session signals the
#    group AND every process whose environment carries that marker.
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
# Exit code: the CLI's own, or 128+signal when it was killed.

set -u

stderr_log=${1:?stderr log path required}
headless=${2:?claude-headless.sh path required}
shift 2
: "${LOOP_SESSION_ID:?LOOP_SESSION_ID required}"
grace=${LOOP_KILL_GRACE_S:-5}
launcher=$$
marker="LOOP_SESSION_ID=$LOOP_SESSION_ID"
ps_snapshot="$stderr_log.ps"

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

# Signals every process carrying the marker, then the group. The caller ($BASHPID) and
# the ps it spawns are excluded; ps output goes to a file and is read without a subshell,
# because a command substitution would fork a copy of this shell that also matches.
# The group comes last: for KILL it includes the caller.
kill_session() {
    local sig=$1 self=$BASHPID pid ppid rest targets=""
    ps axeww -o pid=,ppid=,command= > "$ps_snapshot" 2>/dev/null
    while read -r pid ppid rest; do
        [ "$pid" = "$self" ] && continue
        [ "$ppid" = "$self" ] && continue
        case " $rest " in *" $marker "*) targets="$targets $pid" ;; esac
    done < "$ps_snapshot"
    rm -f "$ps_snapshot"
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
    while IFS= read -r _ <&3; do :; done
    # Only now deaf to TERM: the group signal it is about to send includes itself.
    trap '' TERM
    kill_session TERM
    sleep "$grace"
    kill_session KILL
) &
watchdog=$!
exec 3<&-

wait "$child"
code=$?

# The CLI is gone. Anything it left behind — a detached Bash-tool command, an MCP server —
# would hold the Port's stdout open or simply outlive the run. TERM it all before
# reporting, without taking this script with it; the runner escalates to KILL.
{ kill -KILL "$watchdog" && wait "$watchdog"; } 2>/dev/null
trap '' TERM
kill_session TERM
exit "$code"
