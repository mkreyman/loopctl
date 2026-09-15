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
that keeps this machine joined to loopctl's runner pool (1b), on runner contract 1.6.0.

The daemon has a dispatch accept path, off by default. With `control.accepts_dispatches` false
(the default) it reports `draining: true` and refuses every `dispatch` with `dispatches_disabled`.
With it true, a dispatch passes the local allow-list (`LoopctlRunner.DispatchPolicy`: draining,
capacity, free disk, repo, branch prefix, wall clock, turns, token budget), must be an `implement`
dispatch, and must carry a well-formed `story` object (typed on the dispatch since contract 1.5.0); anything
else is refused
with a reason. An accepted dispatch runs `claude -p` in a worktree on the dispatch's branch, with a
prompt built from a fixed local template in which every story field is fenced as untrusted data,
and the runner config's own `allowed_tools`, under `--permission-mode dontAsk` so nothing else
runs, with no user or repository settings loaded and none of the runner's release environment.
The session implements and tests; it commits, pushes, opens PRs and merges nothing.

Each accepted run reports its delivery stages to loopctl (`stage`): `claimed -> worktree`,
`worktree -> implementing`, and, however the run ends, `-> escalated` with edge
`session_escalated`. This first end-to-end run merges nothing by design, so `escalated` is its
deliberate terminal: a run that finished says "first end-to-end run: implementation finished,
merging nothing by design", and any other end names its status, exit reason and escalation text.

The daemon also ships run traces (`trace` and `trace_cursor`): after every join it asks loopctl
where each run's stored trace ends and sends the lines after it, in batches within the
contract's limits. loopctl stores a trace only for a dispatch this runner accepted, so a run ships
only when its `state.json` carries `dispatch_id` and `claim_epoch`, which an accepted run writes
before its session starts; hand-filed runs never do.

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
token, so update `control.runner_id` too, then start the service again. Revoking disconnects the
live socket: loopctl first pushes `disconnecting` with `runner_revoked` (contract 1.2), and the
daemon stops rather than reconnecting. It stops the same way on `no_longer_authorized`, on a join
refused as no longer authorized, on a runner left on the old id (`forbidden_topic`), and on a token
file that cannot be read three times in a row. It exits with status 78: systemd shows the unit
failed without restarting it (then `systemctl --user restart loopctl-runner` once fixed), and on
macOS the agent stays stopped until `rel/install.sh` or `launchctl kickstart` starts it again. The
log names the reason. A refused websocket upgrade (HTTP 403, which carries no reason) is retried
with a backoff, and a corrected token file is picked up on the next attempt without a restart.

While `control.accepts_dispatches` is false, the daemon reports `draining: true`, so the control
plane never reserves capacity on a machine that will not start a session.

### Troubleshooting the daemon

- **Logs:** `journalctl --user -u loopctl-runner` on Linux, `~/Library/Logs/loopctl-runner.log` on
  macOS.
  - Every line is stamped in UTC and carries `runner_id`, except a refusal to start logged before
    the config has loaded (`refusing to start the runner daemon`), so do not filter on
    `runner_id` when the daemon will not start.
  - A dispatch's lines also carry `dispatch_id`, `story_id` and `claim_epoch`, the keys loopctl
    logs, so the two sides of one incident join on them.
- **Live state:** ask the running daemon directly.

  ```bash
  ~/.local/share/loopctl-runner/current/bin/loopctl_runner rpc \
    'IO.inspect(LoopctlRunner.Control.info(LoopctlRunner.Control))'
  ```

  It returns:
  - `joined` and `joined_at`;
  - `draining` as this runner reports it (loopctl's `runner_pool` can lag it while a status push
    is pending), and `accepts_dispatches`;
  - `last_disconnect`, `connect_attempts` and `next_reconnect_ms`;
  - `last_status_rtt_ms`, `last_status_acked_at` and `status_push_pending`;
  - `dispatch_replies_pending` and `dispatch_reply_backlog` (rate-limited replies waiting);
  - `pending_starts` (accepted, waiting for loopctl to record the accept), `runs_in_flight` (the
    dispatch ids of runs still going) and `stage_reports_pending`;
  - `trace_acked` (the acknowledged seq per run on this channel) and `trace_push_pending`;
  - `sample_error`, `last_refusal` and `token_failures`.
- **The pool, as loopctl sees it:** `runner_pool`. It lists joined runners only, so a runner
  missing from it while `joined` is true is a disagreement worth reporting to loopctl.

What the log says in each failure:

| situation | log line |
|---|---|
| partition, or a half-open socket | `has not answered the status push` at the next status tick, then `socket disconnected: <reason>; reconnect attempt N in Xms` 30-60s in, when Slipstream finds its previous 30s heartbeat unanswered |
| loopctl restarted or dropped the socket | `loopctl is disconnecting this runner (server_shutdown); it will reconnect` when loopctl announces it, then `socket disconnected: :closed (loopctl announced server_shutdown)`, then `joined ... after Ns out of the pool (N reconnect attempts)` |
| loopctl closed only the channel | `loopctl channel runner:<id> closed: :closed_by_loopctl; rejoining`, then `joined ...` |
| the runner was revoked | `loopctl is disconnecting this runner (runner_revoked); stopping until it is re-enrolled`, then `stopping with exit status 78` |
| slow link | `loopctl answered a status push after Nms; the link is slow` (5s or more), when the late reply lands |
| no answer at all | `loopctl has not answered the status push sent Nms ago (last answered <time>)`, at each tick once the oldest unanswered push is 5s old |
| revoked or rejected token | `upgrade refused with HTTP 403; reconnect attempt N in Xms`, retried with backoff |
| misconfiguration | `loopctl refused runner:<id> (<reason>)`, then `stopping with exit status 78` (0 under launchd) |
| a metric cannot be read | `health sample omitted: cannot read <metric>`, once, until `health sample readable again` |
| a dispatch arrives | `dispatch <id> received`, then either `dispatch <id> refused (<reason>): <detail>` and `dispatch_reply sent: refused (<reason>)`, or `dispatch <id> accepted: run of story-<story_id> starts once loopctl records it` and `dispatch_reply sent: accepted`; then `loopctl recorded the dispatch_reply`, all with `dispatch_id`, `story_id` and `claim_epoch` |
| a dispatch is refused `other` | `the dispatch carries no story`, `triage dispatches are not supported by this runner yet`, `the dispatch story <field> ...` for a malformed story, or `the dispatch does not make a runnable story: ...` |
| a dispatch arrives again | `dispatch <id> was already accepted and started here; answering accepted again, starting nothing`; a different `claim_epoch` is refused `other` |
| an accepted run moves | `stage report sent: claimed -> worktree`, then `loopctl recorded the stage claimed -> worktree`, and the same for `worktree -> implementing` and `-> escalated`. Reports outstanding when the channel closes are resent after the rejoin |
| an accepted run ends | the escalation marker is the `-> escalated` report with edge `session_escalated`; its reason is `first end-to-end run: implementation finished, merging nothing by design` for a finished run, otherwise `run ended <status>; session exit reason ...; the session escalated: <text>` |
| loopctl refuses a stage | `refused the stage <from> -> <to> for dispatch <id> as stale_stage` (or with another reason), at error level; no later stage of that run is reported (`stage <from> -> <to> not reported`) |
| loopctl answers `internal_error` | resent with a backoff, at most 3 times, then `giving up on the stage ...`, `giving up on the dispatch_reply ...` or `giving up on this run's ... trace pushes` at error level; a trace given up this way ships again after a restart |
| a run's task dies without reporting | `the run of dispatch <id> died: <reason>`; its `state.json` is marked `crashed` and it is reported `-> escalated` as crashed |
| loopctl did not record an accept | `dispatch <id> accepted: run of ... starts once loopctl records it`, then either `dispatch <id> recorded as accepted: run of ... started` or `loopctl did not record this runner's accept of dispatch <id> (<reason>); its run is not started` at error level. A run starts only after loopctl records its accept |
| the daemon restarted with runs going | runs keep going and report to the new daemon (`a run this Control did not start reported ...`), waiting up to a minute for it to register; a redelivered dispatch already bound in a `state.json` is answered `accepted` again and starts nothing |
| the daemon restarted with work unfinished | `resending the accept of pending dispatch <id>` for each file in `runs_dir/.pending/` (an accepted dispatch whose run had not started), and `reporting the unacknowledged end of dispatch <id>'s run` for each finished run whose `state.json` lacks `terminal_reported` |
| a later dispatch of the same story | its worktree is `.claude/worktrees/loop-story-<story_id>`, keyed on the story, so it adopts the worktree an earlier run kept |
| a dispatch that cannot be answered | `dispatch not answered: ...`, when it has no usable `dispatch_id` and `claim_epoch` or a refusal would fail the contract |
| loopctl refuses that reply | `loopctl refused the dispatch_reply (<reason>)`; `rate_limited` waits in the backlog, the rest are not resent |
| the channel drops with a reply outstanding | `resending N dispatch_reply(s) loopctl had not recorded when the channel closed` after the rejoin; `no longer needs the resent dispatch_reply (<reason>)` when the claim moved on meanwhile |
| a run's trace is being shipped | `trace cursor: loopctl holds this run through seq N`, then `trace shipped in full through seq N` once the run has finished, all with `run_id`, `dispatch_id` and `claim_epoch` |
| loopctl holds the dispatch as not accepted | `trace waits for this runner's accept of the dispatch to be recorded` while an accept reply is unacknowledged; otherwise the run is given up at once (`dispatch_not_accepted`) |
| loopctl will not take a trace | `loopctl will not take this run's trace (<reason>)`; the run's `trace_ship.json` records it and the run is not shipped again |
| the runner and loopctl disagree on a size | `loopctl refused a N-event trace batch as too large` or `refused trace event N as too large` at error level: a byte-rule mismatch to report; shipping continues by splitting or by dropping that event's data |
| loopctl cannot store an event | `loopctl refused a N-event trace batch as invalid`, then `refused trace event N (invalid_payload): ... shipping it as a stub`, at error level; the batch is narrowed only through the refused range, and a stub that is refused too gives the run up |
| a finished run's trace grows | the reaper's `run.reaped` lines ship on the next poll; `trace_ship.json` records the trace size it was done at |
| `trace_ship.json` cannot be written | `trace shipped in full through seq N, but recording it failed`, once; the run is asked about again after a restart |
| loopctl is ahead of this build | `loopctl sent "<event>", which this runner (contract X) does not handle`, once per event |

A run's own record is its directory under `runs_dir`: `state.json`, `trace.ndjson`, `stdout.ndjson`
and `stderr.log`, plus `trace_ship.json` once its trace is fully shipped or given up on, and
`mix loopctl.tree <run dir>` prints the trace as a tree.

### Per-repo session environment

`session_env` in the runner config adds environment variables to every session for one repo, e.g.
`{"home_care_billing": {"TEST_DB_BASE": "home_care_billing_loop_{story}_test"}}`, so a branch's
migration never touches the checkout's test database. In a value, `{story}` becomes 8 hex of a hash
of the story id, stable across that story's runs, and `{run}` the first 8 hex of the run id. Prefer
`{story}`: nothing drops what a session creates, so `{run}` leaves a new database behind on every
run, while `{story}` reuses one per story, as the story's worktree is reused. Names the runner sets
or reads itself (`LOOP_*`, `LOOPCTL_*`, `ANTHROPIC_*`, `GIT_*`) are refused.

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
