#!/usr/bin/env bash
# Builds a release on THIS machine and installs it as a user service (design §14).
#
#   rel/install.sh            build, install, (re)start
#   rel/install.sh --render   print the unit or plist that would be installed, and stop
#   rel/install.sh --prune    remove old releases (as every install does), and stop
#
# Built on the target: BEAM releases are not portable across OS or architecture, and
# every enrolled machine has the asdf toolchain. Each build lands in its own directory
# and `current` is repointed, so the previous release stays on disk for a rollback. Every
# release that becomes current, and the one it replaces, is recorded in `history`; pruning
# keeps the one `current` points to and the LOOPCTL_RUNNER_KEEP_RELEASES (default 3) most
# recently current, and removes the rest, failed builds first among them. A release is about
# 90 MB, and every install used to leave one more behind.

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
prefix="${LOOPCTL_RUNNER_PREFIX:-$HOME/.local/share/loopctl-runner}"
# The prefix is rendered into the unit and plist too, so it takes the config path's checks.
case "$prefix" in
    /*) ;;
    *) echo "LOOPCTL_RUNNER_PREFIX must be an absolute path: $prefix" >&2; exit 1 ;;
esac
case "$prefix" in
    *[[:space:]%\\\&\|\<\>\"\']*) echo "install prefix contains characters the unit cannot carry: $prefix" >&2; exit 1 ;;
esac
keep="${LOOPCTL_RUNNER_KEEP_RELEASES:-3}"
case "$keep" in
    ''|*[!0-9]*) echo "LOOPCTL_RUNNER_KEEP_RELEASES must be a positive integer" >&2; exit 1 ;;
esac
keep=$((10#$keep))
[ "$keep" -ge 1 ] || { echo "LOOPCTL_RUNNER_KEEP_RELEASES must be a positive integer" >&2; exit 1; }

# One install or prune at a time: a prune while another install builds would delete the release
# being built, which is in neither `current` nor `history` yet. mkdir is atomic on every OS
# here, where flock is not on macOS. A lock whose owner is gone is taken over.
lock="$prefix/.install.lock"
take_lock() {
    mkdir -p "$prefix"
    if ! mkdir "$lock" 2>/dev/null; then
        local owner
        owner=$(cat "$lock/pid" 2>/dev/null || true)
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            echo "another install or prune is running (pid $owner); try again when it has finished" >&2
            exit 1
        fi
        rm -rf "$lock"
        mkdir "$lock" || { echo "could not take the install lock at $lock" >&2; exit 1; }
    fi
    echo "$$" > "$lock/pid"
    trap 'rm -rf "$lock"' EXIT
}

current_release() {
    if [ -L "$prefix/current" ]; then basename "$(readlink "$prefix/current")"; fi
}

# The releases to keep: the current one, then the most recently current ones from `history`,
# then newest by name, until there are `keep`. Name order fills in for a history shorter
# than `keep` (a machine installed before it existed, whose older releases were all current
# once); it never displaces a release the history names.
kept_releases() {
    local current name
    current=$(current_release)
    {
        [ -n "$current" ] && echo "$current"
        if [ -s "$prefix/history" ]; then
            tail -r "$prefix/history" 2>/dev/null || tac "$prefix/history"
        fi
        ls -1 "$prefix/releases" | sort -r
    } | while read -r name; do
        # An if, not &&: a failed test as the loop's last command would fail the pipeline, and
        # under pipefail and set -e end the script silently at the first release gone from disk.
        if [ -n "$name" ] && [ -d "$prefix/releases/$name" ]; then echo "$name"; fi
    done | awk -v keep="$keep" '!seen[$0]++ && n < keep + 0 { print; n++ }'
    # The current release is always printed first, so `keep` counts it.
}

prune_releases() {
    [ -d "$prefix/releases" ] || return 0
    local kept name
    kept=$(kept_releases)
    for name in $(ls -1 "$prefix/releases"); do
        if ! printf '%s\n' "$kept" | grep -qx "$name"; then
            rm -rf "${prefix:?}/releases/${name:?}"
            echo "pruned release $name"
        fi
    done
}
# Passed through to the unit or agent, so the service reads the config this script checked.
# Resolved to an absolute path first — the service does not run from this directory — and
# only then checked, because resolving can add the very characters the check refuses: the
# unit and plist cannot carry whitespace (unquoted Environment=), % (a systemd specifier),
# \ & | (the sed replacement) or < > " ' (XML).
config="${LOOPCTL_RUNNER_CONFIG:-$HOME/.config/loopctl-runner/runner.json}"
if [ -d "$(dirname "$config")" ]; then
    config="$(cd "$(dirname "$config")" && pwd)/$(basename "$config")"
fi
case "$config" in
    /*) ;;
    *) echo "config directory does not exist: $config" >&2; exit 1 ;;
esac
case "$config" in
    *[[:space:]%\\\&\|\<\>\"\']*) echo "config path contains characters the unit cannot carry: $config" >&2; exit 1 ;;
esac
# /usr/sbin and /sbin too: a service manager's PATH is not a login shell's, and macOS keeps
# sysctl there.
path_value="$HOME/.asdf/shims:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

render() {
    sed -e "s|@RELEASE@|$prefix/current|g" -e "s|@PATH@|$path_value|g" \
        -e "s|@CONFIG@|$config|g" -e "s|@LOG@|$HOME/Library/Logs/loopctl-runner.log|g" "$1"
}

case "$(uname -s)" in
    Linux) template="$repo/rel/systemd/loopctl-runner.service" ;;
    Darwin) template="$repo/rel/launchd/com.loopctl.runner.plist" ;;
    *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

if [ "${1:-}" = "--prune" ]; then
    take_lock
    prune_releases
    exit 0
fi

if [ "${1:-}" = "--render" ]; then
    render "$template"
    exit 0
fi

[ -f "$config" ] || { echo "no runner config at $config; copy config/runner.example.json and add a control section" >&2; exit 1; }

take_lock
stamp=$(date -u +%Y%m%dT%H%M%SZ)
(cd "$repo" && MIX_ENV=prod mix deps.get --only prod && MIX_ENV=prod mix release --overwrite --path "$prefix/releases/$stamp")
# The new release checks the config and token before it becomes current.
LOOPCTL_RUNNER_CONFIG="$config" "$prefix/releases/$stamp/bin/loopctl_runner" eval "LoopctlRunner.Application.preflight()"
previous=$(current_release)
[ -n "$previous" ] && echo "$previous" >> "$prefix/history"
ln -sfn "$prefix/releases/$stamp" "$prefix/current"
echo "$stamp" >> "$prefix/history"

case "$(uname -s)" in
    Linux)
        unit_dir="$HOME/.config/systemd/user"
        mkdir -p "$unit_dir"
        render "$template" > "$unit_dir/loopctl-runner.service"
        systemctl --user daemon-reload
        systemctl --user enable loopctl-runner.service
        systemctl --user restart loopctl-runner.service
        # A user service stops at logout and does not start at boot without lingering.
        if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
            echo "note: run 'loginctl enable-linger $USER' so the runner survives logout and starts at boot"
        fi
        ;;
    Darwin)
        agent="$HOME/Library/LaunchAgents/com.loopctl.runner.plist"
        mkdir -p "$(dirname "$agent")" "$HOME/Library/Logs"
        render "$template" > "$agent"
        domain="gui/$(id -u)"
        launchctl bootout "$domain/com.loopctl.runner" 2>/dev/null || true
        # bootout returns before the agent has unloaded; bootstrapping into that window fails
        # "Bootstrap failed: 5: Input/output error".
        for _ in $(seq 1 40); do
            launchctl print "$domain/com.loopctl.runner" >/dev/null 2>&1 || break
            sleep 0.25
        done
        launchctl bootstrap "$domain" "$agent" || { sleep 2; launchctl bootstrap "$domain" "$agent"; }
        ;;
esac

echo "installed $prefix/releases/$stamp"
prune_releases
