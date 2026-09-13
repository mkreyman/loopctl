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

1. Enroll the machine with the `runner_enroll` tool of loopctl-mcp-server 2.92.0 or later, from a
   session on THAT machine whose environment carries a user-role `LOOPCTL_USER_KEY`:

   ```
   runner_enroll({name: "minis", token_file: "~/.config/loopctl-runner/token"})
   ```

   The MCP server writes the token to `token_file` itself, mode 600, and returns only the runner
   row, so the credential never reaches a transcript. It refuses a path that already exists
   without enrolling anything. Do not enroll with a direct HTTP call: the response body is the
   token. A machine whose environment has no user key can be enrolled from one that does, into a
   fresh path there, and the file copied across. `scp` neither creates the directory nor refuses
   to overwrite, so do both checks on the target first:

   ```bash
   ssh <target> 'mkdir -p -m 700 ~/.config/loopctl-runner && test ! -e ~/.config/loopctl-runner/token' &&
     scp -p <fresh path> <target>:.config/loopctl-runner/token &&   # -p keeps mode 600
     rm <fresh path>
   ```
2. Put the returned `runner.id` in the `control` section of `~/.config/loopctl-runner/runner.json`
   (see `config/runner.example.json`).
3. `rel/install.sh` builds a release on this machine and installs it as a `systemd --user` unit
   (Linux) or a launchd LaunchAgent (macOS). On Linux, `loginctl enable-linger $USER` makes it
   start at boot. `mix loopctl.serve` runs the same daemon in the foreground for development.
4. `runner_pool` lists the connected runners; the machine appears within a few seconds of the
   service starting. `runner_list` shows enrollments whether or not they are connected.

Rotating the credential is `runner_revoke({id})`, then deleting the old token file (enrollment
refuses an existing file), then enrolling again. That returns a new `runner.id` as well as a new
token, so update `control.runner_id` too, then restart the service. Revoking disconnects the
live socket. A runner left on the old id is refused `forbidden_topic`, and the daemon
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
