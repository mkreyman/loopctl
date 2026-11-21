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
that keeps this machine joined to loopctl's runner pool (1b), on the runner contract the
repository root exports (`priv/runner_contract/v1.json`). It
declares every kind the contract dispatches, the list `@kinds` in `LoopctlRunner.Control`
(`LoopctlRunner.Control.kinds/0`), which includes `spec_tune` (template `spec_tuner@1`,
US-48.13). A
`verify` session (template `verify@1`, a `:judge`, contract 1.28.0) judges a pull request at
the head loopctl names: the runner fetches that commit, cuts a detached tree at it, and the
session reviews the diff against the story's acceptance criteria and ends with one fenced JSON
`{"verdict": "pass" | "reject", "findings": [...]}` block. The runner adds the head it actually
checked out and sends it as `agent_result`; a block that does not parse, a `pass` carrying
findings, or a head that does not match sends nothing (`LoopctlRunner.VerifyPrompt`,
`LoopctlRunner.VerifyResult`). It never pushes, comments, merges or reports custody: loopctl
applies the verdict under its own verifier dispatch. Because its cwd is the implementer's tree, it
alone runs with `--setting-sources user`: the operator's user-scoped setup applies, and the pull
request's own `CLAUDE.md`, `.claude/` settings, hooks, agents and skills, and `.mcp.json` do not.
The repository's rules reach it from the base instead: `CLAUDE.md` as `origin/<base>` holds it,
in the prompt, up to 32 KiB (`LoopctlRunner.VerifyPrompt.base_rules/2`). For a repository in
the config's `selection_replay` (chg), a change touching one of its `paths` globs is also
REPLAYED (contract 1.32.0): beside the session, the runner runs `chg/bin/chg-replay-selection.py`
as the base holds it, comparing selection at the merge base and the head over the `product`'s
last `corpus` commits, and adds its output to a `pass` as `selection_replay`, which loopctl
reads to merge a selection change without a person (`LoopctlRunner.SelectionReplay`). When the
dispatch's `verify.loop_finding` names the `selection_miss` the story fixes (contract 1.33.0),
the replay also runs the head's selection at that commit and reports which of its failed tests
it covers, as `selection_replay.miss`. A reject
stops the replay; a replay that fails or does not finish in the session's time leaves the pass
without it, and loopctl escalates as before. A
`reply_draft` session (template `reply_draft@1`, a `:draft`, contract 1.26.0) runs on triage's
detached tree, reads the code (nothing it does there is pushed), writes a reply to the reporter that a person reviews
before anything is sent, and ends with one fenced JSON `{"body": ...}` block. The runner checks
that block against the spec's schema (non-blank, at most 3000 characters, no other key) and
sends it as `agent_result`; a draft that fails the check sends nothing and the run counts as
failed (`LoopctlRunner.ReplyDraftPrompt`, `LoopctlRunner.AgentResult`). A triage session dispatches three read-only lenses,
each ending its report with its own outcome and confidence, and states one verdict with the
per-lens `lens_verdicts` (contract 1.15.0) beside it, which is what Gate A reads
(`LoopctlRunner.TriagePrompt`, `LoopctlRunner.TriageVerdict`). Lens verdicts that fail the
contract are dropped rather than the verdict, which loopctl then escalates.

The daemon has a dispatch accept path, off by default. With `control.accepts_dispatches` false
(the default) it reports `draining: true` and refuses every `dispatch` with `dispatches_disabled`.
With it true, a dispatch passes the local allow-list (`LoopctlRunner.DispatchPolicy`: draining,
capacity, free disk, repo, branch prefix, wall clock, turns, token budget), must be of a kind this
runner declares, and an `implement` or `verify` dispatch must carry a well-formed `story` object (typed on the dispatch since contract 1.5.0); anything
else is refused
with a reason. An accepted dispatch runs `claude -p` in a worktree on the dispatch's branch, with a
prompt built from a fixed local template in which every story field is fenced as untrusted data.
The session runs `--permission-mode bypassPermissions` and inherits the operator's user-scoped
Claude setup — the same authority and the same rules a locally dispatched agent has. It implements
and tests, then finishes as the repository's delivery mode says, which the prompt states. The mode
is `.loopctl/mode` in the commit the worktree was cut from, never the working tree's, and the one
mode is `pr`: the session runs the operator's delivery loop up to an open pull request — a PR
opened with `gh pr create --base <base>` and reviewed — and never merges it (US-48.17; its prompt
says so). The merge is loopctl's: once its merge gate allows a head, it sends a `merge`
instruction, and the runner carries out exactly that one (`LoopctlRunner.MergeRun`, `gh pr merge
--squash --match-head-commit --subject --body`, closing keywords rewritten to `Refs` so the merge
closes no issue; it needs gh 2.86.0 or later, for `closingIssuesReferences`). The session leaves the worktree and the branch, which are the
runner's, for the runner to remove once the branch has shipped. A repository with no
`.loopctl/mode`, an empty one or any other value is refused before a session starts
(`repository has no .loopctl/mode` for the first): only an explicit `pr` runs. A repository that
still says `thread` is refused naming the retirement: loopctl removed change threads in contract
1.23.0, so nothing would merge what a thread session pushed. Teardown removes a shipped branch's worktree by merged content. The runner itself
commits nothing. The session inherits the environment an attended session has, except the runner's own release environment and
`ANTHROPIC_API_KEY` (a billing control).

Each accepted run reports the delivery stages the runner observes (`stage`): `claimed ->
worktree` and `worktree -> implementing` as they happen, and, for a pr-mode implement session,
what the forge says of its pull request once the session is over (US-48.16). Before its
`session_ended`, however the session ended, the runner asks
`gh pr list --repo <repo> --head <branch> --base <base> --state all --limit 5 --json
number,state,headRefName,headRefOid,baseRefName,isCrossRepository,mergeCommit,mergedAt,statusCheckRollup`
(bounded at 30 s, with `GH_TOKEN`/`GITHUB_TOKEN` let through and prompts off) and reports, over
edge `forward`, in order and only as far as it saw: `-> reviewing` and `-> pr_open` (`pr_number`,
`head_sha`) for an open or merged PR from this repo's branch into that base, `-> ci` (`head_sha`)
once every check on it is green or it merged, and `-> merged` (`merge_sha`) once it merged. The
newest matching PR decides; a closed-unmerged PR, a fork's PR, or no PR reports nothing more. A
stage loopctl already holds is skipped, not re-sent; a refusal stops the rest, logged and not
retried; a forge that fails or times out reports nothing more and logs a warning. The stages are
written to the run's `state.json` before they are sent, so a restarted runner sends them too.
Thread, triage, review and reply-draft runs report none of this. Anything else past
`implementing` is the session's to report. However the run ends, the runner then reports the
SESSION's end with `session_ended` (contract 1.16.0), carrying since 1.27.0 `turns_used` (the
CLI's last result line's `num_turns`) and `work_left_behind` (`git rev-list --count <branch> --not
--remotes=origin` in the worktree before teardown, on the local remote-tracking refs, no fetch:
non-zero is true), each omitted when the runner could not tell: `completed` for a session that exited 0 on its own,
`wall_clock_exceeded` or `max_turns_exceeded` for one that hit that budget, and `crashed` for any
other end — a non-zero exit, a park, a run that died. Control decides the story's next stage from
that reason. `-> escalated` (edge `session_escalated`) is reported only where it is the truth: for
a session that ran `loop-escalate`, before its `session_ended` (whose `completed` the contract says
"changes nothing", so it cannot undo the escalation), and for a run that never started a session
(no worktree, or a refused prompt), which has no session end to report. `usage_exhausted` is never
sent: nothing the runner reads tells a usage limit from any other failing exit.

`session_ended` goes once per dispatch, behind the stage reports, and is resent as the same bytes
until it settles — after a lost reply, a rejoin, or by a restarted daemon, which reports the end of
every finished run whose `state.json` lacks `terminal_reported`. loopctl answers a resend `ok`
with `replayed` true.

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
| a dispatch is refused `other` | `the dispatch carries no story`, `the dispatch story <field> ...` for a malformed story, or `the dispatch does not make a runnable story: ...` |
| a dispatch names a kind this runner does not declare | refused `kind_not_supported`, detail `this runner runs only: ` followed by `LoopctlRunner.Control.kinds/0` joined with `, `, judged before the dispatch is validated: a `review` dispatch (the kind contract 1.23.0 retired) draws this, as any other unknown string kind does. A `kind` that is not a string is malformed and refused `other` |
| a restart finds an unreported run of a retired kind | `the unreported end of dispatch <id>'s review run (<run_dir>) is not sent: this runner no longer runs review`, once; the run is recorded `terminal_reported: retired_kind` and never reported |
| a dispatch arrives again | `dispatch <id> was already accepted and started here; answering accepted again, starting nothing`; a different `claim_epoch` is refused `other` |
| an accepted run moves | `stage report sent: claimed -> worktree`, then `loopctl recorded the stage claimed -> worktree`, and the same for `worktree -> implementing`. Reports outstanding when the channel closes are resent after the rejoin |
| an accepted run ends | `session_ended sent: <reason>`, then `loopctl recorded session_ended (<reason>)` — with `; it was a resend, and loopctl applied nothing a second time` on a replay. A session that escalated first reports `-> escalated` with edge `session_escalated` and reason `run ended escalated; session exit reason ...; the session escalated: <text>`; a run with no session reports only that `-> escalated`, naming its status |
| loopctl refuses a `session_ended` | `rate_limited` waits the `min_interval_ms` it names and resends; `internal_error` is resent at most 3 times, then `giving up on session_ended for dispatch <id> ...` (a restart sends it again); `already_recorded` is `loopctl already holds a different session_ended ...` at warning level; any other reason is `loopctl refused session_ended ...` at error level, recorded, and not resent |
| loopctl refuses a stage | `refused the stage <from> -> <to> for dispatch <id> as stale_stage` (or with another reason), at error level; no later stage of that run is reported (`stage <from> -> <to> not reported`) |
| loopctl answers `internal_error` | resent with a backoff, at most 3 times, then `giving up on the stage ...`, `giving up on the dispatch_reply ...` or `giving up on this run's ... trace pushes` at error level; a trace given up this way ships again after a restart |
| a run's task dies without reporting | `the run of dispatch <id> died: <reason>`; its `state.json` is marked `escalated` if its session escalated, otherwise `crashed`, and it is reported from the stage that file recorded it reaching: `-> escalated` alone if no session started, `-> escalated` then `session_ended` `completed` if its session escalated, otherwise `session_ended` `crashed` |
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
`{"home_care_billing": {"TEST_DB_BASE": "hcb_loop_{story}"}}`, so a branch's
migration never touches the checkout's test database. Keep such a name as short as the repo's own
default: home_care_billing appends a worktree partition and its race lane a pid to `TEST_DB_BASE`,
and budgets 22 bytes for it against Postgres's 63 (`lib/mix/tasks/hcb.test.partitioned.ex`), so the
longer `home_care_billing_loop_{story}_test` made its push gate refuse every loop push. In a value, `{story}` becomes 8 hex of a hash
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

`loopctl.run` creates `<repo>/.claude/worktrees/loop-<story id>` from `origin`'s copy of the base
when a bounded fetch of it succeeds (the local base ref otherwise), runs `claude -p` in it
through a Port, writes `trace.ndjson`, `stdout.ndjson`, `stderr.log` and `state.json` under the
run directory, stops the session on its wall-clock budget or when it is parked, and removes the
worktree unless it holds work — or repositories of its own. It prints one JSON summary line and
exits 0 on success, 1 on a failed session, 2 on a refusal.

### Eval harness (US-48.10)

```bash
mix loopctl_runner.eval triage@1                    # one spec version
mix loopctl_runner.eval reply_draft                 # every version of a spec
mix loopctl_runner.eval implement@1 --keep-scratch  # keep the built fixture and run dirs
mix loopctl_runner.eval triage@1 --cli test/support/bin   # offline, on the suite's fake CLI
```

A case is `eval/<spec>@<version>/<case>.json`: the `RunnerDispatch` loopctl would send (`input`),
the fixture it runs against (`fixture`), and what must hold of the result (`expectations`:
`schema_valid`, `outcomes_allowed`, `escalation_codes`, `lens_agreement`, `forbidden`,
`screens`, `rubric`). `LoopctlRunner.Eval.Case` documents the shape and refuses a case that
breaks it. Each case goes through the runner's own launcher and session path, the same
`Run`/`TriageRun` a dispatch reaches, with no control socket: nothing connects to loopctl. The
message is read off disk and built with the runner's own builders, as the daemon would have
pushed it.

The harness only checks out fixtures: `eval/fixtures/<name>.json` manifests that build a
deterministic git repo (fixed author, dates and contents, so the same manifest always builds the
same sha). A case whose `fixture.repo` resolves outside `eval/fixtures` or the run's scratch
directory, symlinks included, refuses the whole run before any case runs. verify@1 judges a pull
request, so its cases use `tiny_app_pr`, whose history runs past a case's base: the base is the
case's `fixture.commit`, the head the one its `input.verify.head_sha` names, and its outcome is
the verdict (`pass` or `reject`), not `agent_result`.

Results go to `eval/results/<spec>@<version>/<case>.json` (`--results-dir` to move them) in the
format loopctl replays through its screens: `format`, `spec`, `case`, `machine`, `recorded_at`,
`input`, `event`, `message`, `runner_outcome`, `expected`. The task prints a table and exits
non-zero naming every failing case. `rubric` is never scored; the table says
`rubric unjudged` for a person to read the result. `screens` names the loopctl screens the
recorded message is expected to trip (`gate_a`, `gate_b`, `draft_injection`,
`draft_dispatchable` for triage; `injection_detector_draft` for reply_draft; none for implement).
Triage and reply cases dispatch against `acme/widgets`, the repo loopctl's tests configure, so
Gate B replays them cleanly.

`--cli <dir>` puts a fake `claude` first on the session's PATH (through the repo's session
environment, not this process's) and plays `eval/offline/<spec>@<version>/<case>.json`. The
committed files under `eval/results/` were recorded that way, and their `machine` says so.
Without `--cli` the real CLI runs, which is a paid model call.

**implement@1 results are machine-dependent.** A build session runs the fixture's own
`mix test` on whatever Elixir, OTP and toolchain the machine has, so its outcome depends on the
machine as much as on the model. `machine` records the hostname for that reason: compare
implement results only across runs from the same machine. loopctl does not replay them.

**An eval session loads no MCP server.** Every session the harness launches gets
`--strict-mcp-config --mcp-config <scratch>/mcp-none.json`, a file holding `{"mcpServers":{}}`
(`LoopctlRunner.Session.mcp_isolation/1`). This is the one place the runner overrides the MCP
set, for AC-48.10.5, which says an eval never reaches the production socket. The operator's
loopctl MCP entry names its own `LOOPCTL_SERVER` and keys in its `env`, so no session
environment could redirect it: the only way to keep an eval session off production loopctl is
not to load that server. It applies to evals only. A dispatched session's argv carries no MCP
flag (the builders' `:mcp_args` option defaults to `[]`, and nothing on the dispatch path sets
it), so dispatched sessions keep the operator's MCP set as the posture rule in CLAUDE.md
requires. An eval session still inherits the rest of `~/.claude`.

## Why this repo is private, and what would make it public

It encodes fleet topology (which machines are enrolled, their capabilities, local paths), the
token handling for a channel that can cause code to be written and merged, and it is the
companion to an escalation predicate whose trigger list is a map of which code paths skip human
review.

The mechanism is publishable; the policy and topology are not. If this is built so that
topology and trigger lists live in configuration rather than in source, going public later is
deleting a config directory rather than a refactor. Build it that way.

## Enrolled machines

minis, ryzen and x1 (Linux), mac-mini and blockit (macOS). ryzen also runs the `fleet-ci` pool and
the local model, so its runner declares one session (Mark, 2026-11-06: ryzen and x1 belong in the
implementer pool). Not beelink (the fleet's main CI host) and not xps13 (retired).

## Packaging

`mix release`, built on each target machine — every enrolled machine already has a full asdf
Elixir toolchain, and BEAM releases are not portable across OS or architecture. Supervised by
`systemd --user` on Linux and a launchd `LaunchAgent` on macOS, user-scoped in both cases.
See `docs/agent-delivery-loop.md` section 14, including three traps that will otherwise cost a
debugging session.
