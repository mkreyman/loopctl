#!/usr/bin/env bash
# Moves every fleet machine to release/manifest.toml's set, verifies each, runs the e2e, and
# rolls the moved machines back to the previous set if the e2e fails (US-52.10).
#
#   release/rollout.sh
#
# 1. Preflight: loopctl's /.well-known/loopctl release.set equals the manifest's set (the
#    server deploys from master on its own), and npm has loopctl-mcp-server at the set's mcp
#    version (machines launch it through claude-config's bin/loopctl-mcp.sh).
# 2. Each host of FLEET_MACHINES in turn, niced, over ssh: release/install-machine.sh <set>
#    from that host's own factory checkout, bootstrapped from this tree's copy on first use.
#    An unreachable host is reported and skipped.
# 3. Every host ok or unchanged: dispatch .github/workflows/e2e.yml and wait for it. A failed
#    e2e reinstalls the previous set on every host this run moved, and exits 1.
#
# Exit: 0 every host at the set and e2e green; 1 otherwise; 2 a preflight failed.
#
# Inputs (each a value the test passes, never a global it edits):
#   LOOPCTL_SERVER        https://loopctl.com
#   ROLLOUT_HOSTS         the hosts, space separated (default: FLEET_MACHINES from claude-config)
#   ROLLOUT_LOCAL_HOST    the host installed here, without ssh (default: this machine's fleet
#                         name from claude-config's fleet-name.sh, else its hostname)
#   ROLLOUT_SSH           the ssh command (default: ssh -o BatchMode=yes -o ConnectTimeout=10)
#   ROLLOUT_GH            the gh command (default: gh)
#   ROLLOUT_NPM           the npm command (default: npm)
#   ROLLOUT_CURL          the curl command (default: curl)
#   ROLLOUT_RUN_WAIT_S    how long the dispatched e2e run may take to appear (default: 120)
set -uo pipefail
unset CDPATH

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
server=${LOOPCTL_SERVER:-https://loopctl.com}
ssh_cmd=${ROLLOUT_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=10}
gh_cmd=${ROLLOUT_GH:-gh}
npm_cmd=${ROLLOUT_NPM:-npm}
curl_cmd=${ROLLOUT_CURL:-curl}

fleet="$HOME/workspace/claude-config/hooks/lib/fleet-name.sh"
if [ -n "${ROLLOUT_HOSTS:-}" ]; then
  hosts=$ROLLOUT_HOSTS
else
  [ -f "$fleet" ] || { echo "rollout: $fleet not found; set ROLLOUT_HOSTS" >&2; exit 2; }
  hosts=$(bash -c ". '$fleet' >/dev/null 2>&1; echo \"\$FLEET_MACHINES\"")
fi

# The host this runs on installs in place, not over ssh: a machine is not set up to ssh to
# itself (minis, 2026-11-20).
if [ -n "${ROLLOUT_LOCAL_HOST+x}" ]; then
  local_host=$ROLLOUT_LOCAL_HOST
else
  me=$(hostname -s 2>/dev/null || hostname)
  local_host=$me
  [ -f "$fleet" ] && local_host=$(bash -c ". '$fleet' >/dev/null 2>&1; fleet_name_for_host '$me'")
fi

. "$here/lib/pick_python.sh"
py=$(pick_python) || { echo "rollout: no Python 3.11+ (tomllib) found" >&2; exit 2; }

read -r set_id mcp_version < <("$py" - "$root/release/manifest.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    m = tomllib.load(f)
print(m["set"], m["components"]["mcp"]["version"])
PY
) || { echo "rollout: cannot read release/manifest.toml" >&2; exit 2; }

# --- preflight ---

served=$($curl_cmd -fsS --max-time 30 "$server/.well-known/loopctl" |
  "$py" -c 'import json,sys; print(json.load(sys.stdin)["release"]["set"])' 2>/dev/null) ||
  { echo "rollout: cannot read release.set from $server/.well-known/loopctl" >&2; exit 2; }
if [ "$served" != "$set_id" ]; then
  echo "rollout: $server serves set $served, the manifest names $set_id; deploy first" >&2
  exit 2
fi
if ! $npm_cmd view "loopctl-mcp-server@$mcp_version" version >/dev/null 2>&1; then
  echo "rollout: npm has no loopctl-mcp-server@$mcp_version yet; wait for its publish" >&2
  exit 2
fi

# --- one host ---

# on_host <host> <command>: runs a shell command on <host>, here when it is this machine.
on_host() {
  if [ "$1" = "$local_host" ]; then
    bash -c "$2"
  else
    $ssh_cmd "$1" "$2"
  fi
}

# install_on <host> <set>: prints the host's JSON line (or an unreachable one). The runner
# joins naming the SERVER's set, so a rollback to <set> still waits for $set_id there.
install_on() {
  local host=$1 target=$2
  if ! on_host "$host" true >/dev/null 2>&1; then
    printf '{"host":"%s","set":%s,"status":"unreachable","runner_version":null,"chg_version":null}\n' \
      "$host" "$target"
    return
  fi
  # The machine runs install-machine.sh from this tree: its own factory checkout may not exist
  # yet, and the script fetches the set's tree itself. It runs helpers from "$here/lib/", so the
  # WHOLE lib directory goes with it, as one tar on ssh's stdin; a helper added there later
  # cannot be left behind. COPYFILE_DISABLE keeps macOS tar from adding ._ files.
  COPYFILE_DISABLE=1 tar -C "$here" --exclude=__pycache__ -cf - install-machine.sh lib |
    on_host "$host" "d=\$(mktemp -d) && tar -C \"\$d\" -xf - &&
LOOPCTL_FACTORY_SERVER_SET=$set_id nice -n 10 bash \"\$d/install-machine.sh\" $target; rc=\$?; rm -rf \"\$d\"; exit \$rc" |
    tail -1
}

status_of() { "$py" -c 'import json,sys; print(json.loads(sys.argv[1]).get("status",""))' "$1" 2>/dev/null; }

# as_host <line> <host> <set>: the line under the fleet name it was installed as (a Mac reports its
# Computer Name), or a failed line when the host printed no JSON.
as_host() {
  "$py" - "$1" "$2" "$3" <<'PY'
import json, sys
line, host, set_id = sys.argv[1:4]
try:
    j = json.loads(line)
except ValueError:
    j = {"set": int(set_id), "status": "failed", "runner_version": None, "chg_version": None,
         "detail": "no result line: " + line[:200]}
j["host"] = host
print(json.dumps(j))
PY
}

results=()
moved=()
all_good=true

for host in $hosts; do
  line=$(as_host "$(install_on "$host" "$set_id")" "$host" "$set_id")
  results+=("$line")
  case $(status_of "$line") in
    ok) moved+=("$host") ;;
    unchanged) ;;
    *) all_good=false ;;
  esac
done

summary() {
  printf '%-10s %-5s %-12s %-10s %s\n' HOST SET STATUS RUNNER CHG
  local l
  for l in "$@"; do
    "$py" -c '
import json, sys
j = json.loads(sys.argv[1])
print("%-10s %-5s %-12s %-10s %s" % (j["host"], j["set"], j["status"], j.get("runner_version") or "-", j.get("chg_version") or "-"))
if j.get("detail"):
    print("           " + j["detail"])
' "$l"
  done
}

summary "${results[@]}"

if ! $all_good; then
  echo "rollout: a host failed or was unreachable; e2e skipped" >&2
  exit 1
fi

# --- e2e ---

newest_run() {
  $gh_cmd run list -R mkreyman/loopctl --workflow e2e.yml --event workflow_dispatch \
    --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null
}

# The dispatch returns no run id, so the run is the first one newer than the newest before it.
before=$(newest_run)
$gh_cmd workflow run e2e.yml -R mkreyman/loopctl >/dev/null ||
  { echo "rollout: could not dispatch e2e.yml" >&2; exit 1; }
run_id=""
for _ in $(seq 1 "${ROLLOUT_RUN_WAIT_S:-120}"); do
  run_id=$(newest_run)
  [ -n "$run_id" ] && [ "$run_id" != "$before" ] && break
  run_id=""
  sleep 1
done
[ -n "$run_id" ] || { echo "rollout: the dispatched e2e run never appeared" >&2; exit 1; }
url="https://github.com/mkreyman/loopctl/actions/runs/$run_id"
echo "rollout: e2e $url"

if $gh_cmd run watch "$run_id" -R mkreyman/loopctl --exit-status >/dev/null; then
  echo "rollout: set $set_id is on every host and e2e passed"
  exit 0
fi

previous=$((set_id - 1))
echo "rollout: e2e failed ($url); rolling ${moved[*]:-no host} back to set $previous" >&2
back=()
for host in "${moved[@]}"; do
  back+=("$(as_host "$(install_on "$host" "$previous")" "$host" "$previous")")
done
[ "${#back[@]}" -gt 0 ] && summary "${back[@]}"
exit 1
