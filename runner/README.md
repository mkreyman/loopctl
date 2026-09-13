# loopctl-runner

Dev-machine runner for the loopctl agent delivery loop.

A small Phoenix application that runs on each enrolled dev machine. It connects **outbound** to
the loopctl control plane over an authenticated Phoenix Channel, publishes the machine into the
availability pool via `Phoenix.Presence`, and supervises Claude Code sessions in git worktrees
through Ports.

It is deliberately a **client**, not a cluster peer: a dev machine never joins the production
BEAM cluster. See `docs/agent-delivery-loop.md` section 2 for why.

## Status

Build order steps **1a** and **1b** are implemented: hand-filed story runs (1a), and the daemon
that keeps this machine joined to loopctl's runner pool (1b). Dispatch handling and trace upload
follow loopctl#803, which emits `dispatch` and accepts `trace_event`; until then the daemon refuses
dispatches.

### The daemon

1. Enroll the machine (a human-anchored `user` key; the token is shown once):

   ```bash
   curl -sS -X POST https://loopctl.com/api/v1/runners \
     -H "Authorization: Bearer $LOOPCTL_USER_KEY" -H 'content-type: application/json' \
     -d '{"name": "minis"}'
   ```

2. Put the returned `token` in `~/.config/loopctl-runner/token` (`chmod 600`), and the returned
   `runner.id` in the `control` section of `~/.config/loopctl-runner/runner.json` (see
   `config/runner.example.json`).
3. `rel/install.sh` builds a release on this machine and installs it as a `systemd --user` unit
   (Linux) or a launchd LaunchAgent (macOS). On Linux, `loginctl enable-linger $USER` makes it
   start at boot. `mix loopctl.serve` runs the same daemon in the foreground for development.

Rotating the credential is `DELETE /api/v1/runners/:id` and enrolling again. That returns a new
`runner.id` as well as a new token, so update both `control.runner_id` and the token file, then
restart the service. A runner left on the old id is refused `forbidden_topic`, and the daemon
exits with status 78: systemd shows the unit failed without restarting it (then
`systemctl --user restart loopctl-runner` once the config is fixed), and on macOS the agent stays
stopped until `rel/install.sh` or `launchctl kickstart` starts it again. The log names the refusal. A token file that cannot be read three times in a row is treated the same way, so after fixing
it, restart the service. (A token the server merely rejects is retried indefinitely, and a
corrected file is picked up on the next reconnect without a restart.)

Until dispatch handling lands (loopctl#803), the daemon reports `draining: true`, so the control
plane never reserves capacity on a machine that cannot start a session.

### Hand-filed runs

```bash
mkdir -p ~/.config/loopctl-runner
cp config/runner.example.json ~/.config/loopctl-runner/runner.json   # then edit repos
mix loopctl.run config/story.example.json      # or `-` to read the story from stdin
mix loopctl.tree ~/.local/state/loopctl-runner/runs/<run_id>
mix loopctl.reap                               # also runs before every loopctl.run
```

`loopctl.run` creates `<repo>/.claude/worktrees/loop-<story id>` from a local base ref, runs
`claude -p` in it through a Port, writes `trace.ndjson`, `stdout.ndjson`, `stderr.log` and
`state.json` under the run directory, stops the session on its wall-clock budget or when it
is parked, and removes the worktree. It prints one JSON summary line and exits 0 on success,
1 on a failed session, 2 on a refusal.

## Why this repo is private, and what would make it public

It encodes fleet topology (which machines are enrolled, their capabilities, local paths), the
token handling for a channel that can cause code to be written and merged, and it is the
companion to an escalation predicate whose trigger list is a map of which code paths skip human
review.

The mechanism is publishable; the policy and topology are not. If this is built so that
topology and trigger lists live in configuration rather than in source, going public later is
deleting a config directory rather than a refactor. Build it that way.

## Enrolled machines

minis (Linux), mac-mini (macOS), blockit (macOS). Not beelink (dedicated CI host) and not
xps13 (4 threads, 8 GB soldered).

## Packaging

`mix release`, built on each target machine — every enrolled machine already has a full asdf
Elixir toolchain, and BEAM releases are not portable across OS or architecture. Supervised by
`systemd --user` on Linux and a launchd `LaunchAgent` on macOS, user-scoped in both cases.
See `docs/agent-delivery-loop.md` section 14, including three traps that will otherwise cost a
debugging session.
