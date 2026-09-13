#!/usr/bin/env bash
# Builds a release on THIS machine and installs it as a user service (design §14).
#
#   rel/install.sh            build, install, (re)start
#   rel/install.sh --render   print the unit or plist that would be installed, and stop
#
# Built on the target: BEAM releases are not portable across OS or architecture, and
# every enrolled machine has the asdf toolchain. Each build lands in its own directory
# and `current` is repointed, so the previous release stays on disk for a rollback.

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
prefix="$HOME/.local/share/loopctl-runner"
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
path_value="$HOME/.asdf/shims:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

render() {
    sed -e "s|@RELEASE@|$prefix/current|g" -e "s|@PATH@|$path_value|g" \
        -e "s|@CONFIG@|$config|g" -e "s|@LOG@|$HOME/Library/Logs/loopctl-runner.log|g" "$1"
}

case "$(uname -s)" in
    Linux) template="$repo/rel/systemd/loopctl-runner.service" ;;
    Darwin) template="$repo/rel/launchd/com.loopctl.runner.plist" ;;
    *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

if [ "${1:-}" = "--render" ]; then
    render "$template"
    exit 0
fi

[ -f "$config" ] || { echo "no runner config at $config; copy config/runner.example.json and add a control section" >&2; exit 1; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
(cd "$repo" && MIX_ENV=prod mix deps.get --only prod && MIX_ENV=prod mix release --overwrite --path "$prefix/releases/$stamp")
# The new release checks the config and token before it becomes current.
LOOPCTL_RUNNER_CONFIG="$config" "$prefix/releases/$stamp/bin/loopctl_runner" eval "LoopctlRunner.Application.preflight()"
ln -sfn "$prefix/releases/$stamp" "$prefix/current"

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
