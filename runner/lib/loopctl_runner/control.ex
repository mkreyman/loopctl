defmodule LoopctlRunner.Control do
  # How long a claim's end is kept (`ClaimEnded.prune/3`): far past any run of that claim.
  @claim_marker_max_age_s 7 * 24 * 3600
  @moduledoc """
  The runner's outbound connection to loopctl (build order step 1b, design §2 and §7).

  A client, never a cluster peer. It connects to `/runner/socket/websocket` with the
  token in the `x-loopctl-runner-token` header, joins its own topic `runner:<runner_id>`
  with a `RunnerJoin` payload — which declares `kinds`, the dispatch kinds this machine runs, the
  one field in it that changes what loopctl sends — and pushes a `RunnerStatus` every
  `status_interval_s`.
  loopctl tracks the joined channel in its tenant-scoped Presence set; the channel dying
  with the socket IS the liveness signal, so there is nothing here to deregister.

  Every outgoing payload is validated against the vendored contract first, and every join
  — rejoins included — carries a freshly built payload: a rejoin that replayed the first
  join's payload would tell loopctl stale `draining`, `in_flight` and sample values.

  ## Dispatches

  `control.accepts_dispatches` (false by default; the `:accepts_dispatches` option overrides it
  in tests) decides whether this runner takes dispatches at all. While it is false the runner
  reports `draining: true` whatever `set_draining/2` was told, so the control plane never
  reserves capacity here for a session that would not start.

  Every `dispatch` is answered with a `dispatch_reply` (contract 1.1). A malformed one that still
  carries its `dispatch_id` and `claim_epoch` is refused `other` with the validation errors. A
  valid one is checked in this order:

    1. a `dispatch_id` this runner already started is never run again: the same `claim_epoch`
       is answered `accepted` again (loopctl answers an identical repeat `ok`), another is
       refused `other`;
    2. the `kind` must be one this runner declared (`@kinds`): any other is refused
       `kind_not_supported`, before the policy, because that reason states a capability and a
       transient refusal (draining, at capacity) is a statement about a moment — answering the
       capability first is what keeps the two from being confused. Since 1.6.0 the refusal lasts
       the connection for a runner that declares, and is permanent for one that does not;
    3. `LoopctlRunner.DispatchPolicy` — its reason and detail on a refusal, with `in_flight`
       counting every run this process accepted from the moment it accepted it;
    4. the dispatch must carry the object its kind is run from, meeting what the schema cannot
       say, or it is refused `other`: a `story` whose `id` equals `story_id`
       (`LoopctlRunner.DispatchRun`) for an `implement` dispatch, and a `triage` report within the
       contract's byte cap (`LoopctlRunner.TriageDispatch`) for a `triage` one.

  Before any of these, the contract's own `RunnerDispatch` validation (1.5.0 types the story)
  refuses a malformed dispatch `other`, naming the field — except a dispatch whose `kind` is a
  string outside `@kinds`, which is refused `kind_not_supported` before it is validated
  (`declared_kind/1`): the contract's kind enum stopped naming `review` in 1.23.0, and a kind this
  runner does not run is answered as the capability statement it is, whatever else the message
  carries, never as a malformed message.

  The decision runs on untrusted input, so anything it raises is refused `other` naming only the
  exception's kind; the full error is logged locally and Control keeps running.

  An accepted dispatch is answered `accepted` and recorded as a pending start, which already counts
  in `in_flight` and against a repeat. Its run starts only when loopctl acknowledges that accept
  `ok` (a resend after a rejoin included), under the run supervisor (a `Task.Supervisor`), never
  inside this process: `LoopctlRunner.Run.execute/3` with the dispatch bound into `state.json`
  and a prompt from `LoopctlRunner.DispatchPrompt`, which the run builds once its worktree exists
  (`LoopctlRunner.DispatchRun.prompt/4`): a missing or malformed `.loopctl/mode` in the commit the
  worktree was cut from, or one that still says `thread` (retired with loopctl's change threads in
  contract 1.23.0), ends that run `refused` before a session starts. Any final refusal of the accept drops the
  pending start unrun, since a session started on an accept loopctl refused could not be stopped.

  The runs outlive this process, and what it would otherwise forget is on disk. On init:

    * every dispatch bound in a `state.json` or pending in `LoopctlRunner.PendingStarts` is treated
      as started, so a redelivered dispatch is answered `accepted` and starts nothing — except a
      run that ended owing nothing (`DispatchRun.end_reports/1` is `[]`: an implement or triage
      run that started no session);
    * each pending start has its accept resent, and its run starts on `ok` — unless it no longer
      makes runnable work, when it is dropped and its accept not resent. One dropped because its
      `deadline_at` passed is forgotten too, unless a run on disk started for it, so loopctl's
      re-send is decided afresh; one dropped for anything else is still answered `accepted`;
    * each bound run that is over without `terminal_reported` in its `state.json` gets its end
      reported again — its `session_ended`, and a terminal `-> escalated` where the run sends one,
      from the stage it recorded reaching and retried from wherever a refusal says the row is.

  Runs report their stages to the registered name, waiting up to a minute for one to exist, so they
  reach the successor.

  Every reply is routed by the ref of the push it answers, so a rate-limited `dispatch_reply`
  is never mistaken for a status. Rate-limited replies wait in a backlog sent one per the
  contract's burst refill interval by a single timer; `internal_error` replies go the same way,
  but only `@internal_error_attempts` times before the reply is given up and logged as an error.
  A reply loopctl had not recorded when the channel closed is kept and resent after the rejoin:
  loopctl does not dispatch again, and it answers an identical repeat `ok`.

  ## Stage reports

  The run tells this process where it is through `Run.execute/3`'s `:on_stage` callback, as
  messages carrying the dispatch binding, and each becomes a contract `stage` report, pushed
  strictly in order, one at a time per dispatch. A message from a run this process did not start
  opens that dispatch's stream on demand, from the stage its event follows:

    * `claimed` -> `worktree` once the worktree exists, with its `branch` and `worktree_path`;
    * `worktree` -> `implementing` as the session starts;
    * for a pr-mode implement session, once it is over and before its end (US-48.16), what the
      forge says of its pull request (`{:observed, stages}`, from `DispatchRun.observe/4`):
      `reviewing`, `pr_open`, `ci` and `merged`, over edge `forward`, in order and as far as it
      saw. A stage the stream already holds is skipped; a `stale_stage` naming a stage at or past
      one is the row already holding it, so those are dropped and the next is rebuilt from the
      row's stage; any other refusal, a give-up, or a gap in the line stops the rest (logged,
      never retried), and the run's end still goes. They are in `state.json` before they are
      announced, so a restarted Control, or one whose task died, queues them from there;
    * however the run ends, what `DispatchRun.end_reports/1` says. A run that had a session sends
      `session_ended` (contract 1.16.0) with the reason `DispatchRun.session_ended/2` reads off its
      status — `completed`, `wall_clock_exceeded`, `max_turns_exceeded` or `crashed` — plus,
      when known (1.27.0), `turns_used` and `work_left_behind`, and nothing
      about the story's stage: the session delivers, so the stages after `implementing` are its to
      report, and control decides the story's next stage from that reason. `-> escalated` (edge
      `session_escalated`, a reason naming the status, exit reason and any escalation text) is sent
      only for a session that ran `loop-escalate`, before its `session_ended`, and for a run that
      never started a session (no worktree, or a refused prompt), which sends nothing else. A run
      whose dispatch's `deadline_at` passed before its session started sends nothing at all and
      records its end settled (`terminal_reported` `skipped`): the claim is loopctl's lease sweep's
      by then. Its dispatch is forgotten as its end arrives; a re-send that arrives while its task
      is still ending is refused `other` (`busy:`), and after that it is decided afresh. A session
      the deadline stopped is reported `crashed`, not `wall_clock_exceeded`. A run
      whose task dies without saying so is reported from what it left on disk
      (`Run.unfinished/2`): the stage it recorded reaching, and `escalated` if its session
      escalated, otherwise `crashed`.

  `session_ended` goes once per dispatch and only behind the stage reports, whose order it would
  otherwise break: a `crashed` one releases the claim, and a report sent after that is refused.
  It is composed once and resent as the same bytes — after a lost reply, a rejoin, or by a later
  Control — which loopctl answers `ok` with `replayed` true. It is settled on `ok` and on the
  contract's permanent refusals for the event (`already_recorded` meaning done); `rate_limited`
  waits out the `min_interval_ms` the refusal names, and `internal_error` is retried with the
  stream's backoff 3 times, after which only this process gives up on it.

  Stage replies: `ok` sends the next; `rate_limited` and `internal_error` retry with a backoff, the
  latter 3 times for an intermediate report (then that report is given up and the next goes) and
  8 times for the terminal one. Any other PERMANENT refusal the contract publishes for a stage
  report refuses that report only (1.22.0): it is dropped, never resent, and the next report goes.
  A stream whose intermediate reports stop (an ordinary `stale_stage`, or a reply this build
  cannot read) still sends its end, since that is what frees loopctl's slot;
  `stale_stage` on the terminal report CARRIES THE ROW it refused (contract 1.11.0), so the report
  is sent again from the `stage` it names, and never from the same stage twice. A stage no
  transition leaves is where that stops: `permanent_error_conditions` calls stale_stage permanent
  there, because the story has reached a stage no runner can report out of. Reports not yet
  acknowledged when the channel closes are resent after the rejoin, in order; a replay whose first
  copy committed is answered `ok`. A refusal that ENDS THE CLAIM is not one of these: see below.

  Two refusals END THE RUN, per `permanent_error_conditions`: `stale_stage` naming a stage no
  transition leaves, and `dispatch_not_accepted` — on a stage report or a trace batch — while no
  accept of this runner's for the dispatch is outstanding (while one is, the report waits for it).
  The intermediate reports stop and the session is stopped as below, but the claim stands, so the
  run's end is still reported whole.

  ## Tuning runs (contract 1.30.0, US-48.13)

  `spec_tune` is the one dispatch that names no story. Since 1.30.0 `story_id` is not in the
  schema's `required`, so a dispatch that passes the schema is then held to `DispatchShape`: a
  `spec_tune` with a `story_id`, a non-zero `claim_epoch` or no `spec_tune` object, and any other
  kind with no `story_id`, is refused `other` before anything is decided. An accepted one runs
  spec_tuner@1 on the detached-tree path (`TriageRun`, keyed by its dispatch), its result is the
  eval harness's score of the session's proposal (`SpecTune`), and it is recorded before it is
  pushed and resent unchanged after a restart, as every `agent_result` is. `:critic` is the
  option that names where the eval set lives.

  ## Merges (contract 1.29.0, US-48.17)

  A `pr`-mode session stops at a green pull request; it never merges (`DispatchPrompt`). loopctl's
  merge gate judges the verified head and, on allow, pushes `merge` (`RunnerMergeInstruction`)
  to the runner holding the claim, and this runner merges exactly that head
  (`LoopctlRunner.MergeRun`, through the `:merge_forge` seam: `gh pr merge --squash
  --match-head-commit`). The instruction is acted on only when it validates and names a
  dispatch, `claim_epoch`, story and repository of an implement run on disk here whose claim was
  never recorded over, whose session is over and whose end has been reported, and — when that run
  observed its pull request — the same pull request; the pull request must also be the run's own
  branch into its base, not a fork's. Anything else is logged and dropped: the contract defines
  no reply, and loopctl resends an instruction that drew no merge report.

  The merge runs off this process, under the run supervisor, one per story at a time; an
  instruction resent while it runs is dropped, and one resent after it reads the pull request
  first, so a merge already made is reported again (`ci -> merged`, idempotent on loopctl's side)
  and never made twice. What it found is reported on a stream of its own opened at `ci`: `ci ->
  merged` with `effects.merge_sha`, `ci -> implementing` over `base_moved` when the head is no
  longer the allowed one, `ci -> escalated` over `session_escalated` when GitHub refused for
  another reason and refused again on `MergeRun`'s one retry, a few seconds later and after a
  fresh read (the race a sibling merge causes clears in that time). A forge it could not read reports nothing, and loopctl's resend (or its own
  gate, finding the merge made) settles it. A merge whose task this process loses to a restart
  is the same case: loopctl's resend finds it.

  Nothing here renews the claim. loopctl holds a story waiting at `ci` itself while it sees this
  runner connected; the connection, with its status pushes, is all the runner contributes.

  ## A claim loopctl ended (contract 1.22.0)

  Read from `x-connection.claim_ending_errors`, per event, and never written here: a refusal in the
  set of the event it answered — `unknown_dispatch` or `stale_claim_epoch` on a `stage`, a `trace`
  batch or a `dispatch_reply` — means the claim that message ran under is over. So nothing more of
  that dispatch's work is sent: its queued stage reports, a terminal `escalated` among them, are
  dropped, and one in flight is left unanswered. The end is
  recorded first as ONE marker for the claim (`LoopctlRunner.ClaimEnded`), which a run of it reads
  immediately before starting its session — so a claim that ended while its tree was cut starts
  none — and which a Control that starts over reads to stop any session of it still running, and
  to send none of its work, a triage verdict included. Every run of that dispatch AND epoch
  already in its session here — with a stream or not, of any kind — has it stopped, as the reaper
  stops an orphan's, in a task under the run supervisor, looking again every
  `session_stop_retry_ms` only while a followed run's session is still to stop. Its
  `session_ended` still goes when it does, treated by that event's own rules. An accept refused
  before its run started ends nothing here: nothing runs under it. An event the
  table does not key — `session_ended`,
  `trace_cursor` — has no claim-ending refusal. Every OTHER permanent refusal refuses only the
  message that drew it, 1.22.0's `claim_epoch_mismatch` and `wrong_dispatch_kind` included, and
  nothing is resent on one. The set holds because the join declares the contract version vendored.

  ## Triage verdicts

  An accepted `triage` dispatch runs `LoopctlRunner.TriageRun.execute/4` on the same supervisor,
  and reports ONE thing: a `triage_verdict` message carrying exactly one of `verdict` and
  `incomplete`. It reports no stages — the contract's stage machine moves a story, and a triage
  dispatch has none — so that message is the whole of its report, and the run tells this process
  its outcome the way an implement run tells it a stage: as a message to the registered name, so a
  run whose Control died reaches the successor.

  The run's task dying without having reported is itself reported, as `no_verdict_written`, and
  the state.json it left at `running` is closed with the run directory the run announced when it
  started: the outcome is this dispatch's only output, and one never sent leaves loopctl's ledger
  row waiting for as long as the claim holds — while a state left in flight would be counted by
  every status push for the life of this BEAM.

  The message outlives this process the way a pending accept does. It is written to its run
  directory (`LoopctlRunner.PendingVerdicts`) before anything is told about it and deleted when
  loopctl has recorded it or the refusal is one no resend can move, so a Control that starts over
  one resends exactly the bytes that were composed for it — never a message rebuilt, which loopctl
  would refuse `already_recorded` if a single field had drifted. The run itself writes one at its
  end, which is what covers a run that finishes while NO Control is registered to take its
  message; this process writes the one it states for a run whose task died saying nothing.

  Refusals are read from the contract (`LoopctlRunner.TriageDispatch.classify/1`), not from a list
  written here: `rate_limited` waits out the `triage_verdict_burst` refill in the same shape of
  backlog a `dispatch_reply` uses, `internal_error` is retried to the terminal ceiling, and a
  permanent refusal is logged as an error and given up, since the contract says nothing will move
  it. `dispatch_not_accepted` is permanent unless an accept this runner sent for that dispatch is
  still unacknowledged, which is the one case worth waiting for. `stale_claim_epoch` is permanent
  for that message only (1.22.0): the story was reclaimed twice while the verdict was recorded, and
  loopctl repairs the epoch from the verdict itself, so the same bytes are resent once before the
  verdict is given up — once across restarts too, recorded beside the message
  (`LoopctlRunner.PendingVerdicts.mark_resent/1`). A verdict loopctl had not
  recorded when the channel closed is resent after the rejoin: the message is idempotent per
  dispatch, and a byte-identical resend is answered `ok` with `replayed` true — which is logged,
  because an `ok` that recorded the verdict and an `ok` that applied nothing are otherwise the
  same answer.

  The verdict travels with the three lenses' own judgements in `lens_verdicts` (1.15.0), which
  Gate A reads (`LoopctlRunner.TriageVerdict.validate/1`). A pending triage start is resumed like
  any other, and runs in a detached worktree of its own (`LoopctlRunner.TriageRun`), never in the
  repository's live checkout.

  ## Trace shipping

  While joined, the client ships run traces as `LoopctlRunner.TraceShip` decides: a
  `trace_cursor` for each shippable run after every join (loopctl replays nothing on a
  rejoin), then `trace` batches after the acknowledged seq, one push in flight at a time, the
  next sent no sooner than the contract's min interval after the last reply. With nothing to
  send it looks again every `:trace_poll_ms`, which is also the only time it rescans the run
  directories. Refusals are handled by reason: `rate_limited` waits; a size refusal splits the
  batch or ships the named event without its data; `invalid_payload` narrows the batch to one
  event and ships that event as a stub (all three logged as errors, since every batch is
  already checked against the contract and the byte rule); and any other permanent refusal
  (`given_up/0`, read from the contract) gives the run up, since every batch of the run carries
  the binding it refused — and one that ends the claim ends the dispatch's work as above. A settle that cannot be written to disk is kept in memory and
  logged once; it never takes the connection down.

  ## Refusals

  Join replies are read by `reason` (loopctl `RunnerChannel`):

    * `rate_limited` — the 30-joins-per-minute budget; rejoin after a backoff.
    * `not_authorized` — revoked runner or key, or inactive tenant. loopctl also closes the
      socket, and the reconnect path backs off; but a refusal carrying `disconnecting:
      "join_refused_not_authorized"` (contract 1.2) means the credential no longer works, and is
      fatal like the reasons below.
    * `machine_mismatch`, `unsupported_contract_version`, `invalid_payload`,
      `forbidden_topic`, `unknown_topic` — this machine's configuration or build is wrong,
      and retrying cannot fix it. The client calls its `:on_fatal` hook, which by default
      stops the VM with `fatal_exit_status/0`. A runner that silently stayed "active" with
      no connection inside would be worse than a stopped one: the systemd unit does not
      restart on 78 (`RestartPreventExitStatus`), and the launchd agent exits 0, which
      `KeepAlive` does not restart.
      Re-enrolment gives a NEW runner id, so it is a config change plus a restart.

  A `disconnecting` push (contract 1.2) arrives just before loopctl closes the connection
  itself. `runner_revoked` and `no_longer_authorized` are fatal the same way; `server_shutdown`
  is named on the close that follows, and the runner reconnects.

  A refused upgrade is an HTTP 403 with an empty body and no reason; it is retried with a
  backoff capped at two minutes. The token file is re-read on every attempt: an unreadable
  one is retried three times, for a rewrite in progress, and then treated as fatal. The
  backoff resets only on a successful join, so a server that accepts the upgrade and then
  drops the socket cannot hold the client on its fastest retry.
  """

  use Slipstream

  require Logger

  alias LoopctlRunner.{
    AgentResult,
    AtomicFile,
    ClaimEnded,
    Config,
    Contract,
    ControlConfig,
    DispatchPolicy,
    DispatchRun,
    DispatchShape,
    Forge,
    Health,
    MergeRun,
    Owner,
    PendingStarts,
    PendingVerdicts,
    ProcessGroup,
    Reaper,
    Run,
    Runs,
    RunState,
    Session,
    Story,
    Templates,
    TraceShip,
    TriageDispatch,
    TriageRun,
    Worktree,
    WorktreeLock
  }

  @reconnect_backoff_ms [1_000, 2_000, 5_000, 10_000, 30_000, 60_000, 120_000]
  # The join budget is 30 per minute; this ladder never approaches it.
  @rejoin_backoff_ms [2_000, 5_000, 10_000, 30_000, 60_000]
  @fatal_reasons ~w(machine_mismatch unsupported_contract_version incompatible_client_version invalid_payload forbidden_topic unknown_topic)
  @ex_config 78
  # An empty or mid-rewrite token file gets a few attempts; a file that stays unreadable is
  # a misconfiguration, and fatal, so the service does not sit "active" with no connection.
  @max_token_failures 3
  # A status reply slower than this is logged: the link is degraded well before the heartbeat
  # timeout declares it dead.
  @slow_reply_ms 5_000
  # loopctl's internal_error is transient on its side, but unlike rate_limited it carries no
  # promise that waiting helps: a few attempts, then the message is given up and logged.
  @internal_error_attempts 3
  # The terminal stage report frees loopctl's slot, so it is retried longer, still bounded: with
  # the doubling backoff capped at 5s, eight attempts span about 20 seconds.
  @terminal_internal_error_attempts 8
  # The longest wait between stage retries.
  @max_stage_backoff_ms 5_000
  # How long a stop of a claim-ended dispatch's session waits before it looks again, while the run
  # has not yet reported its end: a session that had not started when the claim ended is started
  # by the run after it, and is stopped by the next look.
  @session_stop_retry_ms 1_000
  # The kinds this runner runs, declared on every join (`RunnerJoin.kinds`, contract 1.6.0) and
  # checked against every dispatch. ONE list, read by both: a declaration the kind check does not
  # honour is a self-contradiction loopctl suppresses for the rest of the connection, and a kind
  # check stricter than the declaration takes the machine out of that kind's work.
  # Fixed here, never from a story or the config, so nothing on the wire can widen it.
  #
  # ADDING A KIND HERE IS NOT ENOUGH TO RUN IT. Each kind declared needs its template in
  # `Templates` (a compile-time raise below refuses a kind without one), the accept path that
  # template names in `work/3`, and its start in `start_pending/2`. Declaring a kind whose dispatch this runner cannot
  # accept makes loopctl send it — the declaration decides — and every one is refused as `other`,
  # which suppresses nothing and records nothing, so the machine soaks that kind for as long as it
  # declares it. `implement` and `triage` have both; `triage` became declarable once its session
  # stated one lens verdict per lens beside the verdict (contract 1.15.0's `lens_verdicts`, which
  # Gate A reads — without them every triage escalated). `reply_draft` (contract 1.26.0, US-48.9)
  # runs on triage's accept path and in `TriageRun`, and answers with `agent_result`. `verify`
  # (contract 1.28.0, US-48.18) takes the same path over a different subject — the story and the
  # pull request's head, `TriageRun.subject/2` — and answers with `agent_result` too. `spec_tune`
  # (contract 1.30.0, US-48.13) is the one STORY-LESS kind (`DispatchShape`): it runs
  # spec_tuner@1 on the same path, keyed by its dispatch, and its `agent_result` is the eval
  # harness's score of the session's proposal (`SpecTune`). They are the contract's whole
  # `dispatchable_kinds` since 1.30.0; `contract_test` holds the set.
  #
  # EMPTY IS THE ONE VALUE THAT MUST NEVER SHIP. loopctl reads an empty array as no declaration
  # at all, falls back to its ledger, keeps sending `implement`, and caches the refusal
  # permanently for the life of this runner's row — the exact trap declaring exists to escape.
  # Draining is how this runner says it wants no work.
  @kinds ["implement", "triage", "reply_draft", "verify", "spec_tune"]

  # The kinds whose template runs on the detached-tree path (`run: :triage`): a subject
  # (`TriageRun.subject/2`), `TriageRun`, no stage stream, one message back. Derived from the
  # registry, never listed, so a template that moves path moves here with it.
  @scratch_kinds for t <- Templates.all(), t.run == :triage, t.kind in @kinds, do: t.kind

  if @kinds == [],
    do:
      raise(
        "@kinds must never be empty: loopctl reads an empty declaration as none, falls back to " <>
          "its permanent kind ledger, and this runner then refuses work it cannot recover from. " <>
          "Use draining to stop taking work."
      )

  # Every declared kind runs through a template (`Templates`, US-48.8): a dispatch of kind K runs
  # the version-1 template whose kind is K (`Templates.for_dispatch/1` — `spec_tuner@1` for
  # `spec_tune`), so a declared kind with none is the soaked kind the note above warns of.
  for kind <- @kinds, Templates.for_dispatch(%{"kind" => kind}) == :error do
    raise "@kinds declares #{kind}, which has no version-1 template in LoopctlRunner.Templates: every " <>
            "dispatch of it would be refused `other`, and loopctl would keep sending it"
  end

  # The refusal of a dispatch whose kind this runner does not run: a capability statement, not a
  # fault. Since 1.6.0 it is permanent only for a runner that declares nothing; this one declares,
  # so loopctl re-sends the kind on a later connection that declares it.
  # The vendored RunnerJoin, read once: whether it declares `specs` decides whether a join sends it.
  @join_definition Contract.schema_def("RunnerJoin")

  @kind_refusal_reason "kind_not_supported"
  @kind_refusal "this runner runs only: " <> Enum.join(@kinds, ", ")

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Slipstream.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :transient}
  end

  @doc "Marks this runner draining (no new dispatches) or not, and reports it."
  @spec set_draining(GenServer.server(), boolean()) :: :ok
  def set_draining(server, draining?) when is_boolean(draining?),
    do: GenServer.cast(server, {:set_draining, draining?})

  @doc "The client's current view, for diagnostics and tests."
  @spec info(GenServer.server()) :: map()
  def info(server), do: GenServer.call(server, :info)

  @doc "The draining flag loopctl is told: true while no dispatch can be accepted."
  @spec reported_draining(boolean(), boolean()) :: boolean()
  def reported_draining(draining?, accepts_dispatches?), do: draining? or not accepts_dispatches?

  @doc "The `RunnerJoin` payload for this machine, validated against the contract."
  @spec join_payload(Config.t(), map(), boolean(), boolean()) ::
          {:ok, map()} | {:error, [String.t()]}
  def join_payload(%Config{} = config, capacity, draining?, accepts? \\ false),
    do:
      build_join(
        config,
        capacity,
        {draining?, accepts?},
        measure(config),
        Runs.in_flight(config.runs_dir)
      )

  defp build_join(
         %Config{control: control} = config,
         capacity,
         {draining?, accepts?},
         measured,
         in_flight
       ) do
    payload =
      %{
        "contract_version" => Contract.version(),
        # Judged against loopctl's release set (contract 1.34.0, US-52.8): a build below its
        # runner minimum is refused `incompatible_client_version`, which is fatal here.
        "runner_version" => runner_version(),
        "kinds" => @kinds,
        # EXACTLY the set DispatchPolicy enforces (contract 1.14.0): silence is read as no
        # constraint, and a superset is the same failure — loopctl derives a branch this machine
        # then refuses, and every refusal costs the story's claim.
        "branch_prefixes" => config.branch_prefixes,
        "machine" => control.machine,
        "cores" => capacity["cores"],
        "memory_mb" => capacity["memory_mb"],
        "repos" => control.repos,
        "max_sessions" => control.max_sessions,
        "in_flight" => in_flight,
        "draining" => reported_draining(draining?, accepts?)
      }
      # The templates this runner holds for the kinds it declares (AC-48.8.1), sent only once the
      # vendored RunnerJoin names `specs` (`Templates.join_field/2`), so every byte is validated.
      |> Map.merge(Templates.join_field(@kinds, @join_definition))
      |> put_sample(measured)

    with :ok <- Contract.validate("RunnerJoin", payload), do: {:ok, payload}
  end

  @doc "The `RunnerStatus` payload, validated against the contract."
  @spec status_payload(Config.t(), boolean(), boolean()) :: {:ok, map()} | {:error, [String.t()]}
  def status_payload(%Config{} = config, draining?, accepts? \\ false),
    do: build_status(draining?, accepts?, measure(config), Runs.in_flight(config.runs_dir))

  defp build_status(draining?, accepts?, measured, in_flight) do
    payload =
      %{
        "in_flight" => in_flight,
        "draining" => reported_draining(draining?, accepts?)
      }
      |> put_sample(measured)

    with :ok <- Contract.validate("RunnerStatus", payload), do: {:ok, payload}
  end

  defp measure(config, measure \\ &Health.measure/2),
    do: measure.(config.runs_dir, Runs.last_success_at(config.runs_dir))

  # An unreadable metric omits the sample rather than reporting a healthy-looking zero;
  # loopctl treats a stale sample as a breached threshold.
  defp put_sample(payload, {:ok, sample}), do: Map.put(payload, "sample", sample)
  defp put_sample(payload, {:error, _metric}), do: payload

  @impl Slipstream
  def init(opts) do
    %Config{control: %ControlConfig{} = control} = config = Keyword.fetch!(opts, :config)
    # Every line from this process names the runner, the key loopctl's logs correlate on.
    Logger.metadata(runner_id: control.runner_id)

    case Health.capacity() do
      {:ok, capacity} ->
        # ONE reading of the runs on disk, for the dispatches they started and for the pending
        # starts that restore may forget: two readings are two answers about one directory.
        started_runs = started_runs(RunState.all(config.runs_dir))

        socket =
          new_socket()
          |> assign(
            config: config,
            control: control,
            capacity: capacity,
            on_fatal: Keyword.get(opts, :on_fatal, &halt/1),
            # The config decides; the option lets a test override it.
            accepts_dispatches:
              Keyword.get(opts, :accepts_dispatches, control.accepts_dispatches),
            # What a `dispatches_disabled` refusal says when something other than the config
            # turned dispatches off for this process — the foreground dev task. nil for a daemon
            # under a service manager, where the config IS the reason and says so itself.
            dispatch_refusal_detail: Keyword.get(opts, :dispatch_refusal_detail),
            # Whether a crashed predecessor's pending accepts are resumed. The decide path is not
            # the only way a session starts: `restore_pending_starts/1` resends an accept for work
            # ALREADY taken, and `ok` starts the run — so a process that must take no work has to
            # be stopped over the START path too, not only over the decision.
            restores_pending_starts: restores_pending_starts?(opts),
            # Where accepted runs are started, and what runs them (replaceable in tests).
            run_supervisor: Keyword.get(opts, :run_supervisor, LoopctlRunner.RunSupervisor),
            run: Keyword.get(opts, :run, &Run.execute/3),
            triage_run: Keyword.get(opts, :triage_run, &TriageRun.execute/4),
            # A spec_tuner@1 run's critic options (US-48.13, `TriageRun`'s `:critic`): the eval
            # directory (default `eval`, against the working directory, as the harness reads it)
            # and, in a test, the fake CLI. Never anything the wire can set.
            critic: Keyword.get(opts, :critic, []),
            # What a pr-mode implement run asks about its pull request once its session is over
            # (US-48.16, `DispatchRun.observe/4`): `(repo, head, base, timeout_ms)`, the `gh` CLI
            # in production, replaceable so a test never reaches GitHub.
            forge: Keyword.get(opts, :forge, &Forge.pull_requests/4),
            # What a `merge` instruction (US-48.17) reads and merges through (`MergeRun`): the
            # `gh` CLI in production, replaceable so a test never reaches GitHub.
            merge_forge:
              Keyword.get(opts, :merge_forge, %{
                view: &Forge.pull_request/3,
                edit_body: &Forge.edit_body/4,
                merge: &Forge.merge/5
              }),
            # `MergeRun`'s options (`:retry_after_ms`, the wait before a refused merge's one
            # retry): its defaults in production, a test's own so it never sleeps.
            merge_opts: Keyword.get(opts, :merge_opts, []),
            # The merge in flight per STORY (story_id => %{ref, dispatch_id, head_sha}), so one
            # story never has two merges at once, and task ref => story_id.
            merges: %{},
            merge_refs: %{},
            # dispatch_id => claim_epoch for every dispatch this process started a run for, so
            # a repeat of one is never run twice.
            started_dispatches:
              started_dispatches(config.runs_dir, started_runs, restores_pending_starts?(opts)),
            # In memory, for the life of this PROCESS — `mark_unjoined/2` does not clear it, and
            # that is deliberate rather than an oversight: a superseded ledger row stays
            # superseded, so the fact does not expire with a connection, and forgetting it on a
            # rejoin would send this runner back to polling a row nothing will move. It is dropped
            # per dispatch when that dispatch's trace is settled, which is the last moment anything
            # asks about it.
            superseded_dispatches: %{},
            # dispatch_id => %{dispatch, work, opts}: accepted, waiting for loopctl to record it.
            # `work` is what the dispatch's kind runs — a story, or a triage report and its repo.
            pending_starts: %{},
            # The registered name runs report to, so they reach a successor of this process.
            name: Keyword.get(opts, :name),
            # Runs in flight: dispatch_id => %{ref, run_id, run_dir, kind}, a triage run's entry
            # also carrying `binding` and `verdict` (:pending until its outcome is reported, which
            # is what keeps its task ending from reporting a second time); and ref => dispatch_id.
            runs: %{},
            run_refs: %{},
            # A dead run's session being ended off this process before its end is reported:
            # task ref => {dispatch_id, run_dir, what to finish} (`end_session_first/4`).
            session_enders: %{},
            # The session of a dispatch whose CLAIM loopctl ended (contract 1.22.0) being stopped
            # off this process: task ref => {dispatch_id, claim_epoch, run dirs}
            # (`stop_run_session/4`), and the claims whose stop is still going (task or timer),
            # and how long a stop that found the run still going waits before it looks again.
            session_stops: %{},
            session_stopping: MapSet.new(),
            session_stop_retry_ms:
              Keyword.get(opts, :session_stop_retry_ms, @session_stop_retry_ms),
            # How a dead run's session is ended before its end is reported: passed in so a test
            # can be a session that survives, which no real signal can stage.
            end_session: Keyword.get(opts, :end_session, &Reaper.end_session_outcome/2),
            # dispatch_id => the stage stream (see stage_stream/1); push ref => dispatch_id.
            stage_streams: %{},
            stage_refs: %{},
            stage_retry_ms: Keyword.get(opts, :stage_retry_ms, stage_retry_ms()),
            internal_error_attempts:
              Keyword.get(opts, :internal_error_attempts, @internal_error_attempts),
            terminal_internal_error_attempts:
              Keyword.get(
                opts,
                :terminal_internal_error_attempts,
                @terminal_internal_error_attempts
              ),
            # dispatch_id => internal_error replies so far to its dispatch_reply.
            reply_errors: %{},
            # run_id => internal_error replies so far to its trace pushes.
            trace_errors: %{},
            token_failures: 0,
            topic: "runner:" <> control.runner_id,
            draining: false,
            joined: false,
            connect_attempts: 0,
            next_reconnect_ms: nil,
            status_timer: nil,
            last_refusal: nil,
            slow_reply_ms: Keyword.get(opts, :slow_reply_ms, @slow_reply_ms),
            # What an operator needs to tell a partition from a slow link: see info/1.
            joined_at: nil,
            unjoined_since: nil,
            last_disconnect: nil,
            # Every status push awaiting its reply, oldest first, as {ref, sent_ms}.
            status_pushes: [],
            last_status_rtt_ms: nil,
            last_status_acked_at: nil,
            sample_error: nil,
            # Health.measure/2, replaceable so an unreadable metric can be exercised.
            measure: Keyword.get(opts, :measure, &Health.measure/2),
            # Health.free_disk_mb/1 for the dispatch policy, read apart from the sample.
            free_disk: Keyword.get(opts, :free_disk, &Health.free_disk_mb/1),
            # DispatchPolicy.decide/3, replaceable so a test can make the decision raise.
            decide: Keyword.get(opts, :decide, &DispatchPolicy.decide/3),
            unhandled_events: MapSet.new(),
            # The reason loopctl gave in a `disconnecting` push, named on the close that follows.
            announced_disconnect: nil,
            # dispatch_reply pushes awaiting their reply: ref => {payload, story_id, carried?},
            # carried? being true once the reply has outlived a channel.
            dispatch_replies: %{},
            # Rate-limited dispatch_replies, oldest first, sent one per refill interval by a
            # single timer, so a backlog never retries all at once.
            reply_backlog: [],
            reply_timer: nil,
            dispatch_reply_retry_ms:
              Keyword.get(opts, :dispatch_reply_retry_ms, dispatch_reply_retry_ms()),
            # triage_verdict pushes awaiting their reply (ref => {payload, carried?}), those
            # waiting out a refusal, their single timer, and the internal_errors each dispatch's
            # verdict has collected. Shaped like the dispatch_reply backlog above, and separate
            # from it: the two events have their own burst budgets and their own refusals.
            verdict_pushes: %{},
            verdict_backlog: [],
            verdict_timer: nil,
            verdict_errors: %{},
            # Dispatches whose verdict was refused `stale_claim_epoch` and resent once already
            # (`verdict_refused/4`): the second such refusal gives it up.
            verdict_resent: MapSet.new(),
            triage_verdict_retry_ms:
              Keyword.get(opts, :triage_verdict_retry_ms, triage_verdict_retry_ms()),
            # The trace shipper (TraceShip): the acknowledged seq per run, learned by a cursor
            # after each join; the one trace push awaiting its reply; its timer; per-run
            # adjustments after a refusal; and how often an idle shipper looks for new lines.
            # The trace shipper (TraceShip): the runs found at the last poll; where each run
            # stands on this channel (acknowledged seq, and the byte offset after it once
            # known); the one trace push awaiting its reply; its timer; per-run adjustments
            # after a refusal; runs settled this session even if recording that failed.
            trace_runs: nil,
            trace_positions: %{},
            trace_push: nil,
            trace_timer: nil,
            # run_id => {max events per batch, until this seq is acknowledged}
            trace_max_events: %{},
            # run_id => monotonic ms before which the run is not tried again, so a run waiting
            # on loopctl never holds up the others; and when run state was last rescanned.
            trace_backoff: %{},
            trace_refreshed_ms: nil,
            trace_omit: MapSet.new(),
            trace_stub: MapSet.new(),
            trace_settled: %{},
            trace_poll_ms: Keyword.get(opts, :trace_poll_ms, 2_000),
            # TraceShip.runs/1, replaceable so a test can count how often run state is scanned.
            trace_find_runs: Keyword.get(opts, :trace_find_runs, &TraceShip.runs/1)
          )

        # What a crashed predecessor left unfinished: accepts whose run never started, triage
        # verdicts loopctl never recorded, and finished runs whose end it never took.
        socket =
          socket
          |> restore_pending_starts(MapSet.new(started_runs, fn {id, _epoch} -> id end))
          |> restore_pending_verdicts()
          |> recover_terminal_reports()
          |> restart_claim_stops()

        {:ok, socket, {:continue, :connect}}

      {:error, reason} ->
        {:stop, {:shutdown, {:capacity_unreadable, reason}}}
    end
  end

  defp restores_pending_starts?(opts), do: Keyword.get(opts, :restores_pending_starts, true)

  # Every dispatch a run on this machine is bound to, in any status: a Control that restarted
  # must answer a redelivered dispatch accepted again, and never start it a second time.
  #
  # A pending entry counts ONLY when this process will resume it. `handle_dispatch/2` consults
  # this map BEFORE the policy and answers a match `accepted` — so a process that leaves the
  # pending files for the service daemon and claims their ids here tells loopctl a story is
  # executing that nothing will run: `settle_reply/3` then calls `start_pending/2`, which pops
  # nothing and returns, in silence, until the claim lease expires. Seeded from RunState alone,
  # a redelivery falls through to `decide_dispatch/2` and is refused `dispatches_disabled`,
  # which is the truth.
  defp started_dispatches(runs_dir, bound, restores_pending_starts?) do
    pending =
      if restores_pending_starts? do
        for %{"dispatch_id" => id, "claim_epoch" => epoch} <- PendingStarts.all(runs_dir),
            do: {id, epoch}
      else
        []
      end

    for {id, epoch} <- bound ++ pending,
        is_binary(id) and is_integer(epoch),
        reduce: %{} do
      acc -> Map.update(acc, id, epoch, &max(&1, epoch))
    end
  end

  # The dispatches a run on disk started for, with their epochs — less a run that ended owing no
  # report (`sessionless_end?/1`), which the running process forgot as it ended, and so does this.
  defp started_runs(states) do
    for {_dir, %{"dispatch_id" => id, "claim_epoch" => epoch} = state} <- states,
        not sessionless_end?(%{
          kind: state["kind"],
          status: state["status"],
          reached: state["reached"]
        }),
        do: {id, epoch}
  end

  # THE rule for a run that started no session and owes nothing (`DispatchRun.end_reports/1` is
  # `[]`: its deadline passed first). loopctl re-sends such a dispatch with a later `deadline_at`
  # (contract 1.19.0), and one still in `started_dispatches` is answered `accepted` with nothing
  # behind it, so its id is forgotten the moment its end is known: live (`forget_sessionless/2`),
  # and at startup (`started_runs/1`). A re-send that arrives while the old run's task is still in
  # `runs` is refused `busy` (`decision/2`) rather than accepted over it — `runs` is keyed by
  # dispatch — and once that task is gone it is decided afresh.
  defp sessionless_end?(summary), do: DispatchRun.end_reports(summary) == []

  defp forget_sessionless(socket, id),
    do: assign(socket, started_dispatches: Map.delete(socket.assigns.started_dispatches, id))

  defp halt(reason) do
    status = fatal_exit_status()
    Logger.error("loopctl runner stopping with exit status #{status}: #{inspect(reason)}")
    System.stop(status)
  end

  @doc """
  The exit status for a fatal refusal: 78 (EX_CONFIG) by default, which the systemd unit
  does not restart; `LOOPCTL_RUNNER_FATAL_EXIT` overrides it. The launchd agent sets 0,
  because `KeepAlive` restarts every non-zero exit and has no way to exempt one — and a
  wrapper shell to translate the code would stand between launchd and the BEAM, swallowing
  the SIGTERM that lets the runner shut its sessions down in order.
  """
  @spec fatal_exit_status() :: non_neg_integer()
  def fatal_exit_status do
    case Integer.parse(System.get_env("LOOPCTL_RUNNER_FATAL_EXIT", "")) do
      {status, ""} when status in 0..255 -> status
      _ -> @ex_config
    end
  end

  @impl Slipstream
  def handle_continue(:connect, socket), do: connect_now(socket)

  @impl Slipstream
  def handle_connect(socket) do
    case fresh_join_payload(socket) do
      {{:ok, payload}, socket} -> {:ok, join(socket, socket.assigns.topic, payload)}
      {{:error, errors}, socket} -> fatal(socket, {:invalid_join_payload, errors})
    end
  end

  @impl Slipstream
  def handle_join(topic, response, socket) do
    Logger.info("loopctl runner joined #{topic}#{outage(socket.assigns)}: #{inspect(response)}")
    record_join(socket.assigns.config, response)

    if socket.assigns.reply_backlog != [],
      do:
        Logger.info(
          "resending #{length(socket.assigns.reply_backlog)} dispatch_reply(s) loopctl had not " <>
            "recorded when the channel closed"
        )

    if socket.assigns.verdict_backlog != [],
      do:
        Logger.info(
          "resending #{length(socket.assigns.verdict_backlog)} triage_verdict(s) loopctl had " <>
            "not recorded when the channel closed"
        )

    {:ok,
     socket
     |> assign(
       joined: true,
       joined_at: now_iso(),
       # An announcement belongs to the close it preceded; a join means that close is over.
       announced_disconnect: nil,
       unjoined_since: nil,
       last_refusal: nil,
       connect_attempts: 0,
       next_reconnect_ms: nil
     )
     |> schedule_status()
     |> schedule_reply_backlog()
     |> schedule_verdict_backlog()
     |> schedule_trace(0, true)
     |> resume_stages()}
  end

  @doc "This runner's own version, the application vsn, as `RunnerJoin.runner_version` sends it."
  @spec runner_version() :: String.t()
  def runner_version, do: :loopctl_runner |> Application.spec(:vsn) |> to_string()

  @doc """
  Where an admitted join is recorded: `joined.json` beside `runs_dir`, which the installer
  (US-52.10) reads to prove a new release joined.
  """
  @spec joined_file(Config.t()) :: Path.t()
  def joined_file(%Config{runs_dir: runs_dir}),
    do: Path.join(Path.dirname(Path.expand(runs_dir)), "joined.json")

  # Never raises: a record the installer cannot read is that installer's failure to report, and
  # must not take a joined channel down with it.
  defp record_join(config, response) do
    body =
      Jason.encode!(%{
        contract_version: Contract.version(),
        runner_version: runner_version(),
        release_set: Map.get(response || %{}, "release_set"),
        joined_at: now_iso()
      })

    file = joined_file(config)

    # A runner that has run nothing yet has no state directory: runs_dir is created by the first
    # run, and the join comes first (blockit, 2026-11-20).
    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- AtomicFile.write(file, body) do
      :ok
    else
      {:error, reason} -> Logger.warning("could not record the join in joined.json: #{reason}")
    end
  rescue
    error -> Logger.warning("could not record the join in joined.json: #{inspect(error)}")
  end

  # How long the runner was out of the pool, so a rejoin line says what the outage cost.
  defp outage(%{unjoined_since: nil}), do: ""

  defp outage(%{unjoined_since: since, connect_attempts: attempts}) do
    " after #{Float.round((now_ms() - since) / 1000, 1)}s out of the pool" <>
      " (#{attempts} reconnect attempts)"
  end

  # A join refused as not_authorized carries `disconnecting` in its error reply (contract 1.2):
  # the credential no longer works, so reconnecting cannot help until the runner is re-enrolled.
  @impl Slipstream
  def handle_topic_close(
        topic,
        {:failed_to_join, %{"disconnecting" => "join_refused_not_authorized"} = response},
        socket
      ) do
    Logger.error(
      "loopctl refused #{topic}: the runner credential is no longer authorized: #{inspect(response)}"
    )

    fatal(
      assign(socket, last_refusal: "not_authorized"),
      {:join_refused, "not_authorized", response}
    )
  end

  def handle_topic_close(topic, {:failed_to_join, %{"reason" => reason} = response}, socket)
      when reason in @fatal_reasons do
    Logger.error("loopctl refused #{topic} (#{reason}): #{inspect(response)}")
    fatal(assign(socket, last_refusal: reason), {:join_refused, reason, response})
  end

  def handle_topic_close(topic, reason, socket) do
    Logger.warning("loopctl channel #{topic} closed: #{inspect(reason)}; rejoining")

    socket =
      socket
      |> cancel_status()
      |> mark_unjoined(inspect(reason))
      |> assign(last_refusal: refusal(reason))

    case fresh_join_payload(socket) do
      {{:ok, payload}, socket} ->
        case rejoin(socket, topic, payload) do
          {:ok, socket} -> {:ok, socket}
          # Disconnected meanwhile: the reconnect path will join again, freshly.
          {:error, _} -> {:ok, socket}
        end

      {{:error, errors}, socket} ->
        fatal(socket, {:invalid_join_payload, errors})
    end
  end

  # loopctl closing the channel on its own (phx_close) reaches Slipstream as a leave, whose
  # default callback does nothing: the runner would stay out of the pool, believing itself
  # joined, and never rejoin. This client never leaves its topic, so every leave is loopctl's.
  @impl Slipstream
  def handle_leave(topic, socket), do: handle_topic_close(topic, :closed_by_loopctl, socket)

  defp refusal({:failed_to_join, %{"reason" => reason}}), do: reason
  defp refusal(_), do: nil

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    announced =
      if socket.assigns.announced_disconnect,
        do: " (loopctl announced #{socket.assigns.announced_disconnect})",
        else: ""

    socket =
      socket
      |> cancel_status()
      |> mark_unjoined(describe_disconnect(reason) <> announced)
      |> assign(announced_disconnect: nil)
      |> schedule_reconnect()

    Logger.warning(
      "loopctl socket disconnected: #{socket.assigns.last_disconnect}; " <>
        "reconnect attempt #{socket.assigns.connect_attempts} " <>
        "in #{socket.assigns.next_reconnect_ms}ms"
    )

    {:ok, socket}
  end

  # A push still awaiting its reply died with the channel: that is a disconnect, already
  # logged, not an unanswered status.
  defp mark_unjoined(socket, reason) do
    assign(socket,
      joined: false,
      unjoined_since: socket.assigns.unjoined_since || now_ms(),
      last_disconnect: reason,
      status_pushes: [],
      dispatch_replies: %{},
      reply_backlog: carry_dispatch_replies(socket.assigns),
      reply_timer: cancel_reply_timer(socket.assigns.reply_timer),
      # A verdict is a run's ONLY output and is idempotent per dispatch, so one the channel died
      # under is resent after the rejoin rather than lost; loopctl answers the repeat `ok` and
      # applies no second transition.
      verdict_pushes: %{},
      verdict_backlog: carry_verdicts(socket.assigns),
      verdict_timer: cancel_reply_timer(socket.assigns.verdict_timer),
      # loopctl replays nothing on a rejoin: every cursor is asked again on the next channel.
      trace_positions: %{},
      trace_runs: nil,
      trace_push: nil,
      trace_timer: cancel_reply_timer(socket.assigns.trace_timer),
      # A stage report stays at the head of its queue until acknowledged, so one in flight is
      # simply sent again, in order, after the rejoin.
      stage_refs: %{},
      stage_streams:
        Map.new(socket.assigns.stage_streams, fn {id, stream} ->
          {id, %{stream | push: nil, timer: cancel_reply_timer(stream.timer)}}
        end)
    )
  end

  # A dispatch_reply loopctl had not recorded when the channel closed, in flight or waiting out
  # a rate limit, is kept and resent after the rejoin (handle_join/3). loopctl does not dispatch
  # again on a rejoin, so a dropped refusal would leave its ledger row waiting for as long as
  # the claim holds; and an identical repeat is answered ok, so resending cannot do harm. The
  # backlog timer is cancelled all the same: nothing is sent until the new channel is joined.
  defp carry_dispatch_replies(%{dispatch_replies: in_flight, reply_backlog: backlog}) do
    for {payload, story_id, _carried?} <- Map.values(in_flight) ++ backlog,
        do: {payload, story_id, true}
  end

  defp carry_verdicts(%{verdict_pushes: in_flight, verdict_backlog: backlog}) do
    for {payload, run_dir, _carried?} <- Map.values(in_flight) ++ backlog,
        do: {payload, run_dir, true}
  end

  defp cancel_reply_timer(nil), do: nil

  defp cancel_reply_timer({timer, _token}) do
    Process.cancel_timer(timer)
    nil
  end

  # A refused upgrade carries only an HTTP status worth reading; its headers are noise.
  defp describe_disconnect({:error, {:upgrade_failure, %{status_code: code}}}),
    do: "upgrade refused with HTTP #{code}"

  defp describe_disconnect(reason), do: inspect(reason)

  @impl Slipstream
  def handle_info(:reconnect, socket), do: connect_now(socket)

  def handle_info(:status, %{assigns: %{joined: true}} = socket) do
    socket = assign(socket, status_timer: nil)

    a = socket.assigns
    measured = measure(a.config, a.measure)
    socket = socket |> note_sample(measured) |> warn_unanswered()

    case build_status(a.draining, a.accepts_dispatches, measured, in_flight(a)) do
      {:ok, payload} ->
        case push_event(socket, a.topic, "status", payload) do
          {:ok, ref} ->
            # Every push is tracked until its own reply lands: tracking only one would leave a
            # late reply matching nothing, or a push sent meanwhile unwatched once the first
            # settles.
            pushes = socket.assigns.status_pushes ++ [{ref, now_ms()}]
            {:noreply, socket |> assign(status_pushes: pushes) |> schedule_status()}

          # loopctl closed the channel and the close is still on its way to handle_topic_close:
          # the rejoin that follows sends a fresh status, so this tick is simply skipped.
          {:error, reason} ->
            Logger.info("status not sent: #{inspect(reason)}; the channel is rejoining")
            {:noreply, schedule_status(socket)}
        end

      {:error, errors} ->
        fatal(socket, {:invalid_status_payload, errors})
    end
  end

  def handle_info(:status, socket), do: {:noreply, assign(socket, status_timer: nil)}

  # One backlogged dispatch_reply per refill interval. The timer is cancelled with the channel
  # (mark_unjoined/2), but cancelling cannot recall a message already in the mailbox, so the
  # message must carry the token of the CURRENT timer and find the channel joined; a stale one
  # is dropped rather than re-arming a second timer.
  def handle_info(
        {:send_reply_backlog, token},
        %{assigns: %{joined: true, reply_timer: {_timer, token}}} = socket
      ) do
    socket = assign(socket, reply_timer: nil)

    case socket.assigns.reply_backlog do
      [{payload, story_id, carried?} | rest] ->
        socket =
          socket
          |> assign(reply_backlog: rest)
          |> push_dispatch_reply(payload, story_id, carried?)
          |> schedule_reply_backlog()

        {:noreply, socket}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_info({:send_reply_backlog, _stale_token}, socket), do: {:noreply, socket}

  # The same shape for triage_verdicts, on their own burst budget and their own timer: a
  # rate-limited verdict must not wait behind a rate-limited dispatch_reply, nor spend its refill.
  def handle_info(
        {:send_verdict_backlog, token},
        %{assigns: %{joined: true, verdict_timer: {_timer, token}}} = socket
      ) do
    socket = assign(socket, verdict_timer: nil)

    case socket.assigns.verdict_backlog do
      [{payload, run_dir, carried?} | rest] ->
        socket =
          socket
          |> assign(verdict_backlog: rest)
          |> push_verdict(payload, run_dir, carried?)
          |> schedule_verdict_backlog()

        {:noreply, socket}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_info({:send_verdict_backlog, _stale_token}, socket), do: {:noreply, socket}

  # What a triage run reports: its one outcome, carried as a message rather than read off the
  # task's return value, so a run whose Control died reaches the successor — the same reason
  # `{:run_stage, _, _}` above is a message.
  def handle_info({:triage_outcome, binding, run, outcome}, socket)
      when is_map(binding) and is_map(run),
      do: {:noreply, triage_outcome(socket, binding, run[:run_dir], outcome)}

  # Where a triage run keeps its state, learned while it is still running.
  def handle_info({:triage_started, %{"dispatch_id" => id}, run}, socket) when is_map(run),
    do: {:noreply, triage_started(socket, id, run)}

  # One trace step per tick, and only the current timer's tick on a joined channel.
  def handle_info(
        {:trace_tick, token, refresh?},
        %{assigns: %{joined: true, trace_timer: {_timer, token}}} = socket
      ),
      do: {:noreply, socket |> assign(trace_timer: nil) |> trace_step(refresh?)}

  def handle_info({:trace_tick, _stale_token, _refresh?}, socket), do: {:noreply, socket}

  # What a run reports through Run.execute/3's :on_stage callback.
  def handle_info({:run_stage, binding, event}, socket) when is_map(binding),
    do: {:noreply, run_message(socket, binding, event)}

  def handle_info({:stage_retry, dispatch_id, token}, socket) do
    case socket.assigns.stage_streams[dispatch_id] do
      %{timer: {_timer, ^token}} = stream ->
        socket
        |> put_stream(dispatch_id, %{stream | timer: nil})
        |> send_next_stage(dispatch_id)
        |> then(&{:noreply, &1})

      # A timer cancelled with the channel, or for a stream already over.
      _ ->
        {:noreply, socket}
    end
  end

  # A run's task returned; its result is in the run directory and its end already reported.
  def handle_info({ref, _result}, socket)
      when is_reference(ref) and is_map_key(socket.assigns.run_refs, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, run_ended(socket, ref, :normal)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when is_map_key(socket.assigns.run_refs, ref),
      do: {:noreply, run_ended(socket, ref, reason)}

  def handle_info({ref, ended}, socket)
      when is_reference(ref) and is_map_key(socket.assigns.session_enders, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, session_ender_done(socket, ref, {:ended, ended})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when is_map_key(socket.assigns.session_enders, ref),
      do: {:noreply, session_ender_done(socket, ref, {:died, reason})}

  def handle_info({ref, ended}, socket)
      when is_reference(ref) and is_map_key(socket.assigns.session_stops, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, session_stop_done(socket, ref, {:ended, ended})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when is_map_key(socket.assigns.session_stops, ref),
      do: {:noreply, session_stop_done(socket, ref, {:died, reason})}

  def handle_info({:retry_session_stop, id, epoch, run_dirs}, socket),
    do: {:noreply, launch_session_stop(socket, id, epoch, run_dirs)}

  def handle_info({ref, outcome}, socket)
      when is_reference(ref) and is_map_key(socket.assigns.merge_refs, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, merge_done(socket, ref, outcome)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when is_map_key(socket.assigns.merge_refs, ref),
      do:
        {:noreply,
         merge_done(socket, ref, {:unreachable, "the merge task died: #{inspect(reason)}"})}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Slipstream
  def handle_cast({:set_draining, draining?}, socket) do
    send(self(), :status)
    {:noreply, socket |> assign(draining: draining?) |> cancel_status()}
  end

  @impl Slipstream
  def handle_call(:info, _from, socket) do
    info =
      Map.take(socket.assigns, [
        :joined,
        :joined_at,
        :connect_attempts,
        :next_reconnect_ms,
        :last_refusal,
        :last_disconnect,
        :last_status_rtt_ms,
        :last_status_acked_at,
        :sample_error,
        :token_failures,
        :topic
      ])

    a = socket.assigns

    info =
      Map.merge(info, %{
        status_push_pending: a.status_pushes != [],
        dispatch_replies_pending: map_size(a.dispatch_replies),
        dispatch_reply_backlog: length(a.reply_backlog),
        triage_verdicts_pending: map_size(a.verdict_pushes),
        triage_verdict_backlog: length(a.verdict_backlog),
        trace_acked:
          Map.new(a.trace_positions, fn {run_id, %{acked: acked}} -> {run_id, acked} end),
        trace_push_pending: a.trace_push != nil,
        # The value this runner reports, which is not the set_draining/2 flag while no dispatch
        # can be accepted. It is what the next status carries, not proof loopctl received it:
        # runner_pool can lag it while a push is pending, rate-limited or lost with the socket.
        draining: reported_draining(a.draining, a.accepts_dispatches),
        accepts_dispatches: a.accepts_dispatches,
        # Runs this process accepted that are still going, where each keeps its state (nil until
        # the run says, which is what lets a run that dies be closed), and stage reports not yet
        # recorded.
        runs_in_flight: Map.keys(a.runs),
        run_dirs: Map.new(a.runs, fn {id, run} -> {id, run.run_dir} end),
        pending_starts: Map.keys(a.pending_starts),
        stage_reports_pending:
          a.stage_streams |> Map.values() |> Enum.map(&length(&1.queue)) |> Enum.sum(),
        session_ended_pending: Enum.count(Map.values(a.stage_streams), & &1.session_ended),
        # Stories with a merge instruction being carried out (US-48.17).
        merges_in_flight: Map.keys(a.merges),
        # Claims whose sessions are being stopped because loopctl ended the claim or the run.
        session_stops_pending: MapSet.size(a.session_stopping)
      })

    {:reply, info, socket}
  end

  # Every reply is routed by the ref of the push it answers, so a refusal is handled as a
  # refusal of THAT event: a rate-limited dispatch_reply must not resend a status.
  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    cond do
      Map.has_key?(socket.assigns.dispatch_replies, ref) ->
        dispatch_reply_answered(ref, reply, socket)

      Map.has_key?(socket.assigns.verdict_pushes, ref) ->
        {:ok, verdict_answered(ref, reply, socket)}

      match?(%{ref: ^ref}, socket.assigns.trace_push) ->
        {:ok, trace_answered(reply, socket)}

      Map.has_key?(socket.assigns.stage_refs, ref) ->
        {:ok, stage_answered(ref, reply, socket)}

      List.keymember?(socket.assigns.status_pushes, ref, 0) ->
        handle_status_reply(reply, settle_status(socket, ref, reply))

      # A reply to a push from before the last rejoin: nothing is waiting on it any more.
      true ->
        {:ok, socket}
    end
  end

  # A status that landed inside loopctl's 1s floor is sent again once the floor has passed,
  # so a change such as draining is delayed, never dropped until the next tick.
  defp handle_status_reply({:error, %{"reason" => "rate_limited"} = reply}, socket) do
    retry_ms = refusal_interval(reply, 1_000)
    Logger.info("loopctl rate-limited a status push; resending in #{retry_ms}ms")
    socket = cancel_status(socket)
    {:ok, assign(socket, status_timer: Process.send_after(self(), :status, retry_ms))}
  end

  defp handle_status_reply({:error, %{"reason" => reason} = reply}, socket) do
    Logger.warning("loopctl refused a status push (#{reason}): #{inspect(reply)}")
    {:ok, socket}
  end

  defp handle_status_reply(_reply, socket), do: {:ok, socket}

  defp dispatch_reply_answered(ref, reply, socket) do
    {{payload, story_id, carried?}, pending} = Map.pop(socket.assigns.dispatch_replies, ref)
    socket = assign(socket, dispatch_replies: pending)

    ids = [
      dispatch_id: payload["dispatch_id"],
      story_id: story_id,
      claim_epoch: payload["claim_epoch"]
    ]

    if acked?(reply) do
      Logger.info(
        "loopctl recorded the dispatch_reply: #{payload["decision"]} (#{payload["reason"]})",
        ids
      )

      {:ok, settle_reply(socket, payload, :recorded)}
    else
      {:ok, dispatch_reply_refused(socket, reply, {payload, story_id, carried?}, ids)}
    end
  end

  # The refusals that end the claim a dispatch_reply ran under (contract 1.22.0). A refused ACCEPT
  # starts nothing (`settle_reply/3`); what this adds is the run ALREADY going under that claim —
  # an accept repeated for a dispatch this process started — whose work stops with it.
  @reply_claim_ending Contract.claim_ending_errors("dispatch_reply")
  @reply_settled_meanwhile @reply_claim_ending ++ ["already_replied"]

  defp dispatch_reply_refused(socket, reply, {payload, _story_id, carried?} = entry, ids) do
    case reply do
      {:error, %{"reason" => "rate_limited"}} ->
        backlog = socket.assigns.reply_backlog ++ [entry]

        Logger.info(
          "loopctl rate-limited a dispatch_reply; #{length(backlog)} in the backlog, " <>
            "sent one every #{socket.assigns.dispatch_reply_retry_ms}ms",
          ids
        )

        socket |> assign(reply_backlog: backlog) |> schedule_reply_backlog()

      {:error, %{"reason" => "internal_error"} = refusal} ->
        reply_internal_error(socket, entry, refusal, ids)

      # A reply carried across a rejoin may find the question settled meanwhile: the claim is
      # over (the contract's claim-ending set for the event), or the first copy was recorded after
      # all (`already_replied`). That is the expected end of a resend.
      {:error, %{"reason" => reason}}
      when carried? and reason in @reply_settled_meanwhile ->
        Logger.info("loopctl no longer needs the resent dispatch_reply (#{reason})", ids)

        socket
        |> settle_reply(payload, {:refused, reason})
        |> reply_claim_ended(payload, reason)

      {:error, %{"reason" => reason} = refusal} ->
        # Every other refusal is permanent or unknown, and resending cannot change it. One that
        # ends the claim also stops whatever runs under it (`end_claim/5`).
        Logger.warning("loopctl refused the dispatch_reply (#{reason}): #{inspect(refusal)}", ids)

        socket
        |> settle_reply(payload, {:refused, reason})
        |> reply_claim_ended(payload, reason)

      # A bare :error (an error reply with an empty body) or one without a reason: still a
      # refusal, and not one resending is known to fix.
      other ->
        Logger.warning(
          "loopctl refused the dispatch_reply without a reason: #{inspect(other)}",
          ids
        )

        settle_reply(socket, payload, {:refused, "no reason given"})
    end
  end

  #
  # Only for a claim something RUNS under here: an accept refused before its run started drops the
  # pending start (`settle_reply/3`), and with no run there is no work to hold back, no session to
  # stop and nothing for a later run to honour.
  defp reply_claim_ended(socket, %{"dispatch_id" => id, "claim_epoch" => epoch}, reason)
       when reason in @reply_claim_ending do
    if Map.get(socket.assigns.started_dispatches, id) == epoch,
      do: end_claim(socket, id, epoch, "dispatch_reply", reason),
      else: socket
  end

  defp reply_claim_ended(socket, _payload, _reason), do: socket

  # An internal_error is retried through the backlog, but only a few times: unlike rate_limited
  # it promises nothing about waiting. Giving up is an error, because loopctl's ledger row then
  # waits on this dispatch for as long as the claim holds.
  defp reply_internal_error(socket, {payload, _story_id, _carried?} = entry, refusal, ids) do
    id = payload["dispatch_id"]
    attempts = Map.get(socket.assigns.reply_errors, id, 0) + 1

    if attempts >= socket.assigns.internal_error_attempts do
      Logger.error(
        "giving up on the dispatch_reply (#{payload["decision"]}) for dispatch #{id} after " <>
          "#{attempts} internal_error replies from loopctl: #{inspect(refusal)}",
        ids
      )

      settle_reply(socket, payload, {:refused, "internal_error"})
    else
      Logger.warning(
        "loopctl answered the dispatch_reply for dispatch #{id} with internal_error " <>
          "(#{attempts} of #{socket.assigns.internal_error_attempts}); resending",
        ids
      )

      socket
      |> assign(
        reply_errors: Map.put(socket.assigns.reply_errors, id, attempts),
        reply_backlog: socket.assigns.reply_backlog ++ [entry]
      )
      |> schedule_reply_backlog()
    end
  end

  # The reply's question is settled one way or the other, for good: its error count goes, and an
  # accept decides its pending run. Only loopctl recording the accept starts the run; any final
  # refusal of it (the claim moved on, the dispatch is unknown, a conflicting reply was recorded,
  # no reason, internal_error given up) means the run never starts.
  defp settle_reply(socket, payload, outcome) do
    id = payload["dispatch_id"]
    socket = assign(socket, reply_errors: Map.delete(socket.assigns.reply_errors, id))

    case {payload["decision"], outcome} do
      {"accepted", :recorded} -> start_pending(socket, id)
      {"accepted", {:refused, why}} -> drop_pending(socket, id, why)
      _ -> socket
    end
  end

  # Arms the single backlog timer if there is a backlog and it is not already armed.
  defp schedule_reply_backlog(%{assigns: %{reply_backlog: []}} = socket), do: socket

  defp schedule_reply_backlog(%{assigns: %{reply_timer: timer}} = socket) when timer != nil,
    do: socket

  defp schedule_reply_backlog(socket) do
    token = make_ref()

    timer =
      Process.send_after(
        self(),
        {:send_reply_backlog, token},
        socket.assigns.dispatch_reply_retry_ms
      )

    assign(socket, reply_timer: {timer, token})
  end

  # The contract's burst refill: one token comes back every refill interval. Fetched at COMPILE
  # time and never defaulted, for the reason spelled out under @triage_verdict_retry_ms below —
  # these two carried `|| 250` while 250 is exactly what the contract publishes, so a renamed key
  # would have changed nothing observable on the implement path either.
  @burst_refill_ms Map.fetch!(Contract.connection(), "limits")

  @stage_retry_ms Map.fetch!(Map.fetch!(@burst_refill_ms, "stage_burst"), "refill_interval_ms")

  @dispatch_reply_retry_ms Map.fetch!(
                             Map.fetch!(@burst_refill_ms, "dispatch_reply_burst"),
                             "refill_interval_ms"
                           )

  # What a rate-limited `session_ended` waits when the refusal names no `min_interval_ms`.
  @session_ended_retry_ms Map.fetch!(
                            Map.fetch!(@burst_refill_ms, "session_ended_burst"),
                            "refill_interval_ms"
                          )

  defp stage_retry_ms, do: @stage_retry_ms

  defp dispatch_reply_retry_ms, do: @dispatch_reply_retry_ms

  # A verdict's own budget, which is far slower than a dispatch_reply's: 4 per second refilling
  # one a second.
  #
  # Fetched at COMPILE time and never defaulted. A default that happens to equal what the contract
  # publishes is the worst kind: a vendoring that renames or moves this key would change nothing
  # observable, leaving this runner resending at an interval loopctl no longer refills at — too
  # fast is a rate limit it keeps hitting, too slow is a verdict that crawls — with no test and no
  # log able to see it. A renamed key fails the build instead, which is the moment to decide.
  #
  # A draft's `agent_result` rides the SAME backlog (one message per scratch run, the same
  # settling), so the backlog waits out the slower of the two refills: loopctl buckets them apart,
  # and waiting the longer interval can only be slower than either needs, never a refusal.
  @triage_verdict_retry_ms max(
                             Map.fetch!(
                               Map.fetch!(
                                 Map.fetch!(Contract.connection(), "limits"),
                                 "triage_verdict_burst"
                               ),
                               "refill_interval_ms"
                             ),
                             Map.fetch!(
                               Map.fetch!(
                                 Map.fetch!(Contract.connection(), "limits"),
                                 "agent_result_burst"
                               ),
                               "refill_interval_ms"
                             )
                           )

  defp triage_verdict_retry_ms, do: @triage_verdict_retry_ms

  # The round trip of a status push. A slow one is logged when its reply lands; one still
  # unanswered past the slow threshold is logged at each tick by warn_unanswered/1.
  defp settle_status(socket, ref, reply) do
    case List.keyfind(socket.assigns.status_pushes, ref, 0) do
      nil ->
        socket

      {^ref, sent_ms} ->
        rtt = now_ms() - sent_ms

        if rtt >= socket.assigns.slow_reply_ms,
          do: Logger.warning("loopctl answered a status push after #{rtt}ms; the link is slow")

        assign(socket,
          status_pushes: List.keydelete(socket.assigns.status_pushes, ref, 0),
          last_status_rtt_ms: rtt,
          last_status_acked_at:
            if(acked?(reply), do: now_iso(), else: socket.assigns.last_status_acked_at)
        )
    end
  end

  # Slipstream hands an empty ok reply over as :ok and one with a body as {:ok, body}.
  defp acked?(:ok), do: true
  defp acked?({:ok, _body}), do: true
  defp acked?(_reply), do: false

  # Measured from the oldest unanswered push, and only past the slow threshold: a status sent
  # at once by set_draining/2 can find the last push still in flight on a healthy link.
  defp warn_unanswered(%{assigns: %{status_pushes: [{_ref, sent_ms} | _]}} = socket) do
    age = now_ms() - sent_ms

    if age >= socket.assigns.slow_reply_ms do
      Logger.warning(
        "loopctl has not answered the status push sent #{age}ms ago " <>
          "(last answered #{socket.assigns.last_status_acked_at || "never"}); " <>
          "the link is slow or half-open"
      )
    end

    socket
  end

  defp warn_unanswered(socket), do: socket

  defp note_sample(socket, {:ok, _sample}) do
    if socket.assigns.sample_error,
      do: Logger.info("health sample readable again; loopctl receives samples")

    assign(socket, sample_error: nil)
  end

  defp note_sample(socket, {:error, metric}) do
    if socket.assigns.sample_error != metric,
      do:
        Logger.warning(
          "health sample omitted: cannot read #{metric}; loopctl sees this runner's sample as stale"
        )

    assign(socket, sample_error: metric)
  end

  @impl Slipstream
  def handle_message(_topic, "dispatch", payload, socket) do
    Logger.metadata(dispatch_metadata(payload))

    socket =
      case {undeclared_kind(payload), Contract.validate("RunnerDispatch", payload)} do
        # A kind this runner does not run is answered as the capability statement it is, before
        # the contract's enum can call it malformed: `review` left that enum in 1.23.0, and a
        # loopctl still sending one is told the truth — this runner never runs it — and nothing
        # else about the message is judged. Only a STRING kind: anything else is malformed.
        {{:refuse, reason, detail}, _validation} ->
          Logger.warning("dispatch #{payload["dispatch_id"]} refused (#{reason}): #{detail}")
          refuse_dispatch(socket, payload, %{"reason" => reason, "detail" => detail})

        {:ok, :ok} ->
          shaped(socket, payload)

        {:ok, {:error, errors}} ->
          Logger.warning("malformed dispatch received: #{inspect(errors)}")
          detail = String.slice("invalid dispatch: " <> Enum.join(errors, "; "), 0, 500)
          refuse_dispatch(socket, payload, %{"reason" => "other", "detail" => detail})
      end

    # The identifiers belong to this dispatch's lines only.
    Logger.metadata(Enum.map(dispatch_metadata(payload), fn {key, _} -> {key, nil} end))
    {:ok, socket}
  end

  # loopctl is about to close the connection itself (contract 1.2). A revoked or no longer
  # authorized credential stops the runner, as a refusal retrying cannot fix does; a server
  # shutdown is only named, and the reconnect path brings the runner back.
  @stop_reasons ~w(runner_revoked no_longer_authorized)

  def handle_message(_topic, "disconnecting", payload, socket) do
    case {Contract.validate("RunnerDisconnecting", payload), payload} do
      {:ok, %{"reason" => reason}} when reason in @stop_reasons ->
        Logger.error(
          "loopctl is disconnecting this runner (#{reason}); stopping until it is re-enrolled"
        )

        fatal(assign(socket, last_refusal: reason), {:disconnecting, reason})

      {:ok, %{"reason" => reason}} ->
        Logger.info("loopctl is disconnecting this runner (#{reason}); it will reconnect")
        {:ok, assign(socket, announced_disconnect: reason)}

      {{:error, errors}, _} ->
        Logger.warning(
          "malformed disconnecting push, the reconnect path will handle the close: #{inspect(errors)}"
        )

        {:ok, socket}
    end
  end

  # US-48.17 (contract 1.29.0): loopctl's merge gate allowed a head; see "Merges" in the moduledoc.
  def handle_message(_topic, "merge", payload, socket) do
    Logger.metadata(dispatch_metadata(payload))
    socket = merge_instructed(socket, payload)
    Logger.metadata(Enum.map(dispatch_metadata(payload), fn {key, _} -> {key, nil} end))
    {:ok, socket}
  end

  # Contract minor versions add optional fields and events; unknown ones are ignored, but
  # logged once per event name, so a server ahead of this build is visible in the log.
  def handle_message(_topic, event, _payload, socket) do
    if MapSet.member?(socket.assigns.unhandled_events, event) do
      {:ok, socket}
    else
      Logger.warning(
        "loopctl sent #{inspect(event)}, which this runner (contract #{Contract.version()}) " <>
          "does not handle; ignoring it and any repeats"
      )

      {:ok, assign(socket, unhandled_events: MapSet.put(socket.assigns.unhandled_events, event))}
    end
  end

  # What the schema cannot say (contract 1.30.0, `DispatchShape`): `story_id` on every kind but
  # the story-less `spec_tune`, never on it, and the `spec_tune` object on it alone. A dispatch
  # that breaks one is malformed, so `other`, judged before anything about it is decided.
  defp shaped(socket, payload) do
    case DispatchShape.errors(payload) do
      [] ->
        Logger.info(
          "dispatch #{payload["dispatch_id"]} received " <>
            "(#{subject_label(payload)}, #{payload["kind"]}, claim_epoch #{payload["claim_epoch"]})"
        )

        handle_dispatch(socket, payload)

      errors ->
        Logger.warning("malformed dispatch received: #{inspect(errors)}")
        detail = String.slice("invalid dispatch: " <> Enum.join(errors, "; "), 0, 500)
        refuse_dispatch(socket, payload, %{"reason" => "other", "detail" => detail})
    end
  end

  defp subject_label(%{"story_id" => story_id}), do: "story #{story_id}"
  defp subject_label(_payload), do: "no story"

  # Whatever identifiers a dispatch carries, even a malformed one, so its log lines join
  # loopctl's on the same keys.
  defp dispatch_metadata(payload) when is_map(payload) do
    for {key, field} <- [
          dispatch_id: "dispatch_id",
          story_id: "story_id",
          claim_epoch: "claim_epoch"
        ],
        value = payload[field],
        is_binary(value) or is_integer(value),
        do: {key, value}
  end

  defp dispatch_metadata(_payload), do: []

  # --- The accept path ---

  # The contract's dispatch_reply is idempotent on loopctl's side only: a repeat of a dispatch
  # this runner already started must never start a second session.
  defp handle_dispatch(socket, dispatch) do
    id = dispatch["dispatch_id"]
    epoch = dispatch["claim_epoch"]

    case Map.fetch(socket.assigns.started_dispatches, id) do
      {:ok, ^epoch} ->
        Logger.warning(
          "dispatch #{id} was already accepted and started here; answering accepted again, " <>
            "starting nothing"
        )

        socket
        |> extend_pending_deadline(dispatch)
        |> push_dispatch_reply(accepted_reply(dispatch), dispatch["story_id"])

      {:ok, started_epoch} ->
        Logger.warning(
          "dispatch #{id} was already started here at claim_epoch #{started_epoch}; refusing it"
        )

        # THE signal that a claim moved, recorded where it happens rather than inferred later from
        # whatever replies happen to be pending. A NEWER epoch for a dispatch this runner already
        # started means loopctl reclaimed the story, so the ledger row for the epoch the run holds
        # is superseded and no accept will ever move it. An older one says nothing.
        #
        # This is also the first moment the runner knows a session it is RUNNING has lost its
        # claim: every stage report that session makes will be refused stale, and its work will
        # not be taken. It is logged at error rather than acted on — ending a live session on a
        # reclaim is loopctl's call to make and there is no accept path for it to travel yet, and
        # a runner that killed sessions on its own reading of an epoch would be the more dangerous
        # mistake of the two.
        if epoch > started_epoch do
          Logger.error(
            "dispatch #{id} was reclaimed at claim_epoch #{epoch} while this runner holds it at " <>
              "#{started_epoch}; a session may still be running for a claim that has moved",
            dispatch_id: id
          )
        end

        socket
        |> note_superseded(id, epoch, started_epoch)
        |> refuse_dispatch(dispatch, %{
          "reason" => "other",
          "detail" => "this runner already started dispatch #{id} at claim_epoch #{started_epoch}"
        })

      :error ->
        decide_dispatch(socket, dispatch)
    end
  end

  # A RE-SEND carries the re-send's own `deadline_at` (contract 1.19.0: "a RE-SEND of the dispatch
  # carries the re-send's time + its `wall_clock_seconds` + the grace"), and loopctl's lease sweep
  # holds the claim until that one. A start still PENDING takes it when it is later — in memory,
  # where `start_pending/2` reads the work, and in the pending file, where a restart reads it — so
  # the run is bounded by the deadline loopctl now holds rather than the one it replaced. Never an
  # earlier one: "your acceptance and a re-send may move the claim later, never earlier". A start
  # held with NO deadline takes the re-send's: it is the only bound loopctl's sweep now keeps to.
  #
  # A run that has ALREADY STARTED keeps the stop it started with: its session's timer was set as
  # the session started (`Story.stop_after/4`), and nothing re-arms it. A session that stop ends is
  # reported `crashed`, not `wall_clock_exceeded` (`Run`, `DispatchRun.session_ended/2`): the
  # contract's `wall_clock_exceeded` "escalate[s] an in-flight story over the control-only
  # `budget_reported` edge", while `crashed` "releases the claim at once over `runner_lost` —
  # re-queued" — and a stop that came early only because the re-send moved the deadline later is no
  # budget the story overran and nothing a human is needed for.
  defp extend_pending_deadline(socket, dispatch) do
    a = socket.assigns
    id = dispatch["dispatch_id"]

    with %{dispatch: held, work: work} = pending <- a.pending_starts[id],
         %DateTime{} = later <- Story.deadline!(dispatch["deadline_at"]),
         true <- later_than?(later, work_deadline(work)) do
      held = Map.put(held, "deadline_at", dispatch["deadline_at"])
      pending = %{pending | dispatch: held, work: put_work_deadline(work, later)}

      with {:error, reason} <- PendingStarts.write(a.config.runs_dir, held) do
        Logger.error(
          "could not record dispatch #{id}'s later deadline_at on disk (#{inspect(reason)}); " <>
            "a restart before it starts would bound it by the earlier one",
          dispatch_id: id
        )
      end

      Logger.info(
        "dispatch #{id} re-sent with deadline_at #{DateTime.to_iso8601(later)}, later than its " <>
          "pending start held; that start is bounded by it now",
        dispatch_id: id
      )

      assign(socket, pending_starts: Map.put(a.pending_starts, id, pending))
    else
      _ -> socket
    end
  end

  defp later_than?(_later, nil), do: true
  defp later_than?(later, %DateTime{} = current), do: DateTime.compare(later, current) == :gt

  # A triage holds its stop bound on the work itself: it runs no `Story` built at the accept.
  defp work_deadline(%{kind: "implement", story: story}), do: story.deadline_at

  defp work_deadline(%{kind: kind, deadline_at: deadline_at}) when kind in @scratch_kinds,
    do: deadline_at

  defp put_work_deadline(%{kind: "implement", story: story} = work, deadline),
    do: %{work | story: %{story | deadline_at: deadline}}

  defp put_work_deadline(%{kind: kind} = work, deadline) when kind in @scratch_kinds,
    do: %{work | deadline_at: deadline}

  defp decide_dispatch(socket, dispatch) do
    case guarded_decision(socket.assigns, dispatch) do
      {:accept, work} ->
        accept_dispatch(socket, dispatch, work)

      {:refuse, reason, detail} ->
        Logger.warning("dispatch #{dispatch["dispatch_id"]} refused (#{reason}): #{detail}")

        refuse_dispatch(socket, dispatch, %{
          "reason" => reason,
          "detail" => String.slice(detail, 0, 500)
        })
    end
  end

  # The whole decision — policy, story validation, prompt — runs on a payload from the wire, so
  # whatever it raises becomes a refusal instead of taking Control down. loopctl is told only the
  # kind of failure; the message and stack, which can quote the payload, stay in the local log.
  defp guarded_decision(a, dispatch) do
    decision(a, dispatch)
  rescue
    exception ->
      Logger.error(
        "deciding dispatch #{dispatch["dispatch_id"]} raised; refusing it: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:refuse, "other",
       "the runner failed deciding this dispatch (#{inspect(exception.__struct__)})"}
  catch
    kind, reason ->
      Logger.error(
        "deciding dispatch #{dispatch["dispatch_id"]} failed; refusing it: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:refuse, "other", "the runner failed deciding this dispatch (#{kind})"}
  end

  defp decision(a, dispatch) do
    config = %{a.config | control: %{a.config.control | accepts_dispatches: a.accepts_dispatches}}

    state = %{
      draining: a.draining,
      in_flight: in_flight(a),
      free_disk_mb: &free_disk_mb(a, &1),
      dispatches_disabled_detail: a.dispatch_refusal_detail,
      # A dispatch in `runs` that reached the policy is one forgotten as its sessionless run ended
      # (`sessionless_end?/1`) while that run's task is still going: refused `busy` until it is gone.
      ending: Map.has_key?(a.runs, dispatch["dispatch_id"]),
      # The instant a `deadline_at` is judged at: one past it is refused `other`, never
      # `kind_not_supported`, and loopctl places the story again.
      now: DateTime.utc_now()
    }

    with :ok <- declared_kind(dispatch),
         {:accept, fields} <- a.decide.(dispatch, config, state),
         {:ok, work} <- work(dispatch, fields, a) do
      {:accept, work}
    end
  end

  # What this dispatch is run from, through the template registry (`Templates`, US-48.8): the
  # dispatch's template names the accept path, and that path checks the payload for what the
  # schema cannot say. Only a kind `declared_kind/1` let through reaches here; a dispatch this
  # runner holds no template for is refused rather than guessed at, by the clause at the end — the
  # note on `@kinds` says why, because work this runner cannot read is work it would soak and never
  # do.
  defp work(dispatch, fields, a) do
    case Templates.for_dispatch(dispatch) do
      {:ok, template} -> accept_path(template, dispatch, fields, a)
      :error -> no_accept_path(dispatch)
    end
  end

  defp accept_path(%{run: :story} = template, dispatch, fields, a) do
    with {:ok, story_object} <- dispatch_story(dispatch),
         {:ok, story} <- local_story(dispatch, fields, a.config) do
      # No prompt is built here: `Run.execute/3` calls this function once the worktree exists,
      # and it reads the delivery mode from the commit the tree was cut from then
      # (`DispatchRun.prompt/4`).
      {:ok,
       %{
         kind: template.kind,
         story: story,
         prompt: DispatchRun.prompt(dispatch, fields, story_object, template)
       }}
    end
  end

  # A triage run cuts its own detached worktree (`TriageRun`), so it needs no branch here: the repo
  # the policy allowed, the report, and the budgets the policy already held to this runner's
  # ceilings. `dispatch["repo"]` is the owner/name form `TriageRun` resolves against `repos`.
  #
  # Its `deadline_at` (contract 1.19.0) binds the triage session as it binds an implement one: the
  # instant the policy parsed, so a pending start rebuilt from its file keeps it.
  #
  # What the run is over is the template's SUBJECT (`TriageRun.subject/2`): the fenced report for
  # triage and reply_draft, the story and the pull request's head for verify.
  defp accept_path(%{run: :triage} = template, dispatch, fields, _a) do
    with {:ok, subject} <- dispatch_subject(template, dispatch) do
      {:ok,
       %{
         kind: template.kind,
         template: template,
         subject: subject,
         repo: dispatch["repo"],
         base_branch: dispatch["base_branch"],
         wall_clock_s: fields.wall_clock_s,
         max_turns: fields.max_turns,
         deadline_at: fields.deadline_at
       }}
    end
  end

  # Reached two ways, and the wording has to be true of both: a kind this runner DECLARES and holds
  # no template for (the note on `@kinds`), and a kind in a pending file that `rebuild_work/2` does
  # not re-check the declaration for. What is true either way is that there is no accept path. It
  # is `other`, never `kind_not_supported`: that capability statement is `declared_kind/1`'s alone.
  defp no_accept_path(%{"kind" => kind}),
    do: {:refuse, "other", "this runner has no accept path for a dispatch of kind #{kind}"}

  defp no_accept_path(_dispatch),
    do: {:refuse, "other", "this runner has no accept path for a dispatch with no kind"}

  defp declared_kind(%{"kind" => kind}) when kind in @kinds, do: :ok
  defp declared_kind(_dispatch), do: {:refuse, @kind_refusal_reason, @kind_refusal}

  # `declared_kind/1` on a message not yet validated: only a string kind is judged here, so a
  # missing or mistyped one still reaches the contract's validation and is refused `other`.
  defp undeclared_kind(%{"kind" => kind} = payload) when is_binary(kind),
    do: declared_kind(payload)

  defp undeclared_kind(_payload), do: :ok

  # A pending start this build would no longer accept: it is finished anyway (see rebuild_work/2),
  # and the one thing that must not happen is its doing so quietly.
  defp undeclared_kind_warning(%{"kind" => kind} = dispatch) when kind not in @kinds do
    Logger.warning(
      "pending dispatch #{dispatch["dispatch_id"]} is a #{kind}, which this runner no longer " <>
        "declares; finishing it because its accept was already given",
      dispatch_id: dispatch["dispatch_id"]
    )
  end

  defp undeclared_kind_warning(_dispatch), do: :ok

  @doc "The dispatch kinds this runner declares and runs."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The join refusals this runner treats as fatal to the service."
  @spec fatal_reasons() :: [String.t()]
  def fatal_reasons, do: @fatal_reasons

  defp dispatch_story(dispatch) do
    case DispatchRun.story_object(dispatch) do
      {:ok, story} -> {:ok, story}
      :none -> {:refuse, "other", "the dispatch carries no story"}
      {:error, detail} -> {:refuse, "other", detail}
    end
  end

  defp dispatch_subject(template, dispatch) do
    case TriageRun.subject(template, dispatch) do
      {:ok, subject} -> {:ok, subject}
      :none -> {:refuse, "other", "the dispatch carries no triage report"}
      {:error, detail} -> {:refuse, "other", detail}
    end
  end

  defp local_story(dispatch, fields, config) do
    case DispatchRun.story(dispatch, fields, config) do
      {:ok, story} ->
        {:ok, story}

      {:error, detail} ->
        {:refuse, "other", "the dispatch does not make a runnable story: " <> detail}
    end
  end

  defp free_disk_mb(a, path) do
    case a.free_disk.(path) do
      {:ok, free} -> free
      :error -> nil
    end
  end

  # Runs this process accepted count from the moment they are accepted, while their start waits
  # on loopctl and before their state.json exists; every other run in flight on this machine
  # (a run started by an earlier Control included) counts from its state.json.
  defp in_flight(a) do
    mine = MapSet.new(Map.keys(a.runs) ++ Map.keys(a.pending_starts))
    Runs.in_flight(a.config.runs_dir, mine) + map_size(a.runs) + map_size(a.pending_starts)
  end

  # A repeat of an accept already given carries no session fields: loopctl judges a repeat on its
  # decision alone, and the first accept already named the session.
  defp accepted_reply(dispatch),
    do: %{
      "dispatch_id" => dispatch["dispatch_id"],
      "claim_epoch" => dispatch["claim_epoch"],
      "decision" => "accepted"
    }

  # The FIRST accept names the session it will start (contract 1.35.0, US-52.15): the uuid
  # generated here, which `start_pending/2` launches Claude Code with as `--session-id`, so
  # loopctl's holder for this dispatch carries the session's transcript id, and the worktree an
  # implement run will cut. A scratch kind runs in a directory the run makes, so it names none.
  defp accepted_reply(dispatch, work, session_id) do
    dispatch
    |> accepted_reply()
    |> Map.put("session_id", session_id)
    |> put_worktree(work)
  end

  defp put_worktree(reply, %{kind: "implement", story: story}),
    do: Map.put(reply, "worktree", Worktree.path_for(story.repo_path, story.id))

  defp put_worktree(reply, _work), do: reply

  # Accepting sends the accept and records a pending start; the run starts only once loopctl has
  # recorded the accept (settle_reply/3). A session started on an accept loopctl then refused
  # would run with no way to stop it, reporting stages and a trace nobody takes.
  defp accept_dispatch(socket, dispatch, work) do
    session_id = Session.uuid4()
    reply = accepted_reply(dispatch, work, session_id)
    :ok = Contract.validate("RunnerDispatchReply", reply)

    Logger.info(
      "dispatch #{dispatch["dispatch_id"]} accepted: #{describe_work(work)} starts once " <>
        "loopctl records it"
    )

    socket
    |> register_pending(dispatch, work, session_id)
    |> push_dispatch_reply(reply, dispatch["story_id"])
  end

  defp describe_work(%{kind: "implement", story: story}), do: "run of #{story.id}"

  defp describe_work(%{kind: kind, subject: subject}) when kind in @scratch_kinds,
    do: "#{kind} of #{subject_id(subject)}"

  # The id a scratch run's log lines name: a report's record, or a verified story with its PR.
  defp subject_id(%{"story" => %{"id" => id}, "verify" => %{"pr_number" => pr}}),
    do: "story #{id} (pull request ##{pr})"

  # A tuning run names no story or record: it is named by the spec it tunes.
  defp subject_id(%{"spec_tune" => %{"target" => %{"id" => id, "version" => version}}}),
    do: "spec #{id}@#{version}"

  defp subject_id(subject), do: subject["record_id"]

  # The pending start is kept in memory and on disk (PendingStarts), so a restart resumes it.
  defp register_pending(socket, dispatch, work, session_id) do
    a = socket.assigns
    id = dispatch["dispatch_id"]
    binding = DispatchRun.binding(dispatch)
    target = a.name || self()
    on_stage = fn event -> notify_control(target, {:run_stage, binding, event}) end

    pending = %{
      dispatch: dispatch,
      work: work,
      opts: [binding: binding, on_stage: on_stage, session_id: session_id]
    }

    with {:error, reason} <- PendingStarts.write(a.config.runs_dir, dispatch, session_id) do
      Logger.error(
        "could not record the pending start of dispatch #{id} on disk (#{inspect(reason)}); " <>
          "a restart before it starts would forget it",
        dispatch_id: id
      )
    end

    assign(socket,
      started_dispatches: Map.put(a.started_dispatches, id, dispatch["claim_epoch"]),
      pending_starts: Map.put(a.pending_starts, id, pending)
    )
  end

  # A Control starting over pending files resends each accept and starts the run on ok, as for a
  # fresh accept. The work is rebuilt against the current config; work that no longer builds is
  # logged and forgotten rather than started.
  defp restore_pending_starts(%{assigns: %{restores_pending_starts: false}} = socket, _bound) do
    # The scenario this refuses is ordinary and ends in a real production session: the service
    # daemon accepts a dispatch and writes a pending entry, it dies, and someone runs
    # `mix loopctl.serve` over the SAME runs_dir to see why. Recovery does not go through
    # `DispatchPolicy` — `rebuild_work/2` forces `accepts_dispatches: true`, because the accept
    # was already given — so the foreground refusal would be bypassed entirely and the run would
    # start in the operator's login shell. Nothing is deleted and no accept is resent: the entry
    # is work this process is not taking, and the service daemon resumes it on its next start.
    case PendingStarts.all(socket.assigns.config.runs_dir) do
      [] ->
        socket

      pending ->
        Logger.warning(
          "not resuming #{length(pending)} pending start(s): this process takes no work, and " <>
            "resuming one would start a session here. They are left for the service daemon; " <>
            "pass --accept-dispatches to resume them in the foreground."
        )

        socket
    end
  end

  # `bound` is the ids of the dispatches a run on disk started for (`started_runs/1`, from init's one
  # reading of them).
  defp restore_pending_starts(socket, bound) do
    a = socket.assigns

    Enum.reduce(PendingStarts.all_with_sessions(a.config.runs_dir), socket, fn {dispatch,
                                                                                session_id},
                                                                               socket ->
      id = dispatch["dispatch_id"]

      case rebuild_work(socket.assigns, dispatch) do
        {:ok, work} ->
          Logger.info("resending the accept of pending dispatch #{id}", dispatch_id: id)
          # The session id the first accept named, so the run starts as the session loopctl
          # was told about; a file written before 1.35.0 has none, and gets one now.
          session_id = session_id || Session.uuid4()
          entry = {accepted_reply(dispatch, work, session_id), dispatch["story_id"], true}

          socket
          |> register_pending(dispatch, work, session_id)
          |> assign(reply_backlog: socket.assigns.reply_backlog ++ [entry])

        {:error, kind, why} ->
          Logger.error(
            "pending dispatch #{id} no longer makes runnable work (#{why}); not started, and its " <>
              "accept is not resent",
            dispatch_id: id
          )

          PendingStarts.delete(a.config.runs_dir, id)
          forget_dropped(socket, id, kind, bound)
      end
    end)
  end

  # `started_dispatches/3` counted the pending file this process just dropped, and a dispatch left
  # in that map is answered `accepted` on redelivery. A start dropped for its DEADLINE started no
  # session — the fact `sessionless_end?/1` reads off a run that ended `deadline_passed` — and
  # loopctl re-sends it with a later `deadline_at` (contract 1.19.0): forgotten, that re-send is
  # decided afresh, unless a run on disk started for the dispatch (`bound`). A start dropped for anything
  # else stays counted, answered idempotently, as it always was: that re-send would be refused for
  # the same reason, and nothing about it will change by being asked again.
  defp forget_dropped(socket, id, :deadline_passed, bound) do
    if MapSet.member?(bound, id), do: socket, else: forget_sessionless(socket, id)
  end

  defp forget_dropped(socket, _id, _kind, _bound), do: socket

  # A triage verdict its predecessor pushed and loopctl never recorded is sent again, as the bytes
  # that were pushed: the run is long over, its answer exists, and nothing else will ever state it.
  # The resend is idempotent per dispatch — loopctl answers it `ok` with `replayed` true — so
  # sending one loopctl did record costs a log line, while not sending one it did not costs the
  # whole run. A payload that no longer validates is not sent and is not deleted: it cannot be
  # made into a message, and it is the only record of what that run concluded.
  defp restore_pending_verdicts(socket) do
    Enum.reduce(PendingVerdicts.all(socket.assigns.config.runs_dir), socket, fn {run_dir, payload},
                                                                                socket ->
      id = payload["dispatch_id"]

      # A reply_draft run's agent_result is kept in the same file and resent the same way.
      case message_sendable(payload) do
        {:ok, payload} ->
          Logger.info("resending the #{message_event(payload)} of dispatch #{id}",
            dispatch_id: id
          )

          assign(socket,
            verdict_backlog: socket.assigns.verdict_backlog ++ [{payload, run_dir, true}]
          )

        {:error, errors} ->
          Logger.error(
            "the #{message_name(payload)} recorded in #{run_dir} is not a message this runner may send " <>
              "(#{inspect(errors)}); it is kept, unsent",
            dispatch_id: id
          )

          socket
      end
    end)
  end

  # Capacity, draining and disk were decided when the dispatch was accepted; only what the work is
  # built from is checked again.
  #
  # The KIND is not re-checked, for that same reason, and the distinction is worth stating because
  # it looks like a way past `declared_kind/1`: that check decides whether this runner TAKES ON new
  # work, and a pending file is work it already took on and told loopctl it had. The accept is what
  # binds — loopctl's ledger row is waiting on it — so a build whose `@kinds` lost a kind finishes
  # what it accepted rather than dropping it silently, and says so in the log. Nothing on the wire
  # reaches here: a pending file is written only by this runner, only after `declared_kind/1` let
  # the dispatch through.
  defp rebuild_work(a, dispatch) do
    control = %{
      a.config.control
      | accepts_dispatches: true,
        max_sessions: max(a.config.control.max_sessions, 1)
    }

    min = control.min_free_disk_mb

    state = %{
      draining: false,
      in_flight: 0,
      free_disk_mb: fn _path -> min end,
      # The deadline IS re-checked, unlike capacity: it was true of the moment the accept was
      # given, and a restart can come long after. A pending start past it is dropped below.
      now: DateTime.utc_now()
    }

    with {:accept, fields} <-
           DispatchPolicy.decide(dispatch, %{a.config | control: control}, state),
         {:ok, work} <- work(dispatch, fields, a) do
      undeclared_kind_warning(dispatch)
      {:ok, work}
    else
      # Every refusal on this path is a policy or a payload one; `work/3` turns what the object
      # validators report into the same shape, so there is nothing else to come back. The
      # deadline's is told apart (`DispatchPolicy`: `other`, its detail `deadline_passed:`), because
      # only a start dropped for its deadline is forgotten (`forget_dropped/4`).
      {:refuse, "other", "deadline_passed:" <> _ = detail} ->
        {:error, :deadline_passed, "other: #{detail}"}

      {:refuse, reason, detail} ->
        {:error, :refused, "#{reason}: #{detail}"}
    end
  rescue
    exception -> {:error, :raised, inspect(exception.__struct__)}
  end

  # A bound run that is over (finished, or its owner gone) and whose end loopctl never acknowledged
  # gets it reported now, from the stage it recorded reaching, with the full fallback chain. The
  # summary is rebuilt from `state.json` — the status `DispatchRun.session_ended/2` reads its reason
  # from, `reached`, and the escalations file — so the `session_ended` resent here is the one the
  # run's own Control composed.
  defp recover_terminal_reports(socket) do
    runs_dir = socket.assigns.config.runs_dir

    for {run_dir, %{"dispatch_id" => id, "claim_epoch" => epoch} = state} <-
          RunState.all(runs_dir),
        is_binary(id) and is_integer(epoch),
        # A triage run reports no stages, so there is no terminal stage to recover for one: its
        # report is the verdict, and a stage stream opened for it would move a story it does not
        # have. What a restart does NOT do is re-send that verdict, so a triage run whose Control
        # died between its outcome and loopctl recording it is left to loopctl's heal sweep.
        # A reply_draft run is the same: its one report is its agent_result.
        state["kind"] not in @scratch_kinds,
        is_nil(state["terminal_reported"]),
        not live?(state),
        reduce: socket do
      socket -> recover_or_retire(socket, run_dir, state)
    end
  end

  # A run of a kind this build no longer runs — a `review` an older build started, before
  # contract 1.23.0 retired the kind — has no end this build can report: its judgements' events are
  # gone from the contract, and the stage stream an implement run's end goes through would move the
  # implementer's story. It is closed as settled, said once, and never reported.
  defp recover_or_retire(socket, run_dir, %{"kind" => kind} = state)
       when is_binary(kind) and kind not in @kinds do
    Logger.warning(
      "the unreported end of dispatch #{state["dispatch_id"]}'s #{kind} run (#{run_dir}) is not " <>
        "sent: this runner no longer runs #{kind}",
      dispatch_id: state["dispatch_id"]
    )

    retire_run(run_dir)
    socket
  end

  defp recover_or_retire(socket, run_dir, state),
    do: recover_terminal_report(socket, run_dir, state)

  # A write that fails leaves the run unsettled, so the next Control says the same once more.
  defp retire_run(run_dir) do
    RunState.update(run_dir, %{terminal_reported: "retired_kind"})
  rescue
    exception ->
      Logger.warning(
        "could not record #{run_dir} settled (#{inspect(exception.__struct__)}); a restart " <>
          "will say so again"
      )
  end

  # A stream already opened for the dispatch (a second run bound to it) is left alone.
  defp recover_terminal_report(socket, _run_dir, %{"dispatch_id" => id})
       when is_map_key(socket.assigns.stage_streams, id),
       do: socket

  # The stream is opened at once — `reached` is what `Run.unfinished/2` would read back too — so a
  # second run bound to the dispatch is left alone while the run's session is still being ended.
  defp recover_terminal_report(socket, run_dir, %{"dispatch_id" => id} = state) do
    Logger.info("reporting the unacknowledged end of dispatch #{id}'s run", dispatch_id: id)
    binding = Map.take(state, ["dispatch_id", "claim_epoch", "story_id"])

    socket
    |> put_stream(id, open_stream(socket, binding, state["reached"] || "implementing"))
    |> end_session_first(id, run_dir, {:recovered, run_dir, state})
  end

  # A run whose owner died never recorded how it ended; `Run.unfinished/2` reads what it left on
  # disk, as it does for a run that raised on a live runner, so both are reported alike.
  defp recovered_end(socket, id, run_dir, state) do
    status = state["status"]

    summary =
      if status in [nil, "starting", "running"],
        do: Run.unfinished(run_dir, "the run did not finish on a live runner"),
        else: %{
          status: status,
          reached: state["reached"],
          escalations: Run.escalations(run_dir),
          # Contract 1.27.0's optional facts, as the run recorded them (absent: omitted).
          turns_used: state["turns_used"],
          work_left_behind: state["work_left_behind"]
        }

    # A run with no end to report (`DispatchRun.end_reports/1`: an implement run that passed its
    # deadline before it began) queues nothing, and its stream goes at once rather than lingering.
    # Its stream was opened by `recover_terminal_report/3`, before its session was ended. What the
    # run observed of its pull request (US-48.16) goes first, from `state.json`, as it would have
    # from the run's own message: the stages loopctl already holds are skipped as it says so.
    socket
    |> queue_observed_from_disk(id, run_dir)
    |> queue_end(id, summary)
    |> drop_stream_if_done(id)
  end

  defp live?(state), do: state["status"] in ["starting", "running"] and Owner.alive?(state)

  # A run reports to whichever Control is alive: by registered name when there is one, so a run
  # that outlives a Control crash reaches its successor. While none is registered (a restart in
  # progress) the run waits for one, up to `:wait_ms`, then logs what it could not deliver; the
  # run itself must never crash on it.
  @notify_wait_ms 60_000
  @notify_poll_ms 200

  @doc false
  @spec notify_control(atom() | pid(), term(), keyword()) :: :ok
  def notify_control(target, message, opts \\ [])

  def notify_control(target, message, opts) when is_atom(target) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :wait_ms, @notify_wait_ms)
    await_control(target, message, deadline, Keyword.get(opts, :poll_ms, @notify_poll_ms))
  end

  def notify_control(pid, message, _opts) when is_pid(pid) do
    send(pid, message)
    :ok
  end

  defp await_control(target, message, deadline, poll_ms) do
    case Process.whereis(target) do
      pid when is_pid(pid) ->
        notify_control(pid, message)

      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(poll_ms)
          await_control(target, message, deadline, poll_ms)
        else
          Logger.error(
            "no #{inspect(target)} registered to take a run's stage message " <>
              "(#{describe_run_message(message)}); it was not delivered"
          )

          :ok
        end
    end
  end

  defp describe_run_message({:run_stage, %{"dispatch_id" => id}, event}) when is_tuple(event),
    do: "#{elem(event, 0)} for dispatch #{id}"

  # A triage run's outcome is its ONLY report, so the line that says it was not delivered is the
  # only record of it: it names the dispatch and what the run concluded.
  defp describe_run_message({:triage_outcome, %{"dispatch_id" => id}, _run, outcome}),
    do: "the triage outcome of dispatch #{id} (#{describe_outcome(outcome)})"

  defp describe_run_message({:triage_started, %{"dispatch_id" => id}, %{run_dir: dir}}),
    do: "the start of dispatch #{id}'s triage run in #{dir}"

  defp describe_run_message(_message), do: "unrecognised message"

  defp start_pending(socket, id) do
    a = socket.assigns

    case Map.pop(a.pending_starts, id) do
      {nil, _} ->
        socket

      {%{work: %{kind: "implement", story: story} = work, dispatch: dispatch, opts: opts},
       pending} ->
        run = a.run
        config = a.config

        # Built here, from the dispatch and the story the accept path made, so a pending start
        # rebuilt from its file observes exactly as one accepted in this process.
        opts =
          opts
          |> Keyword.put(:prompt, work.prompt)
          |> Keyword.put(:observe, DispatchRun.observe(dispatch, story, a.forge))
          # The repository as loopctl names it (`owner/name`), in state.json beside the binding:
          # the story keeps only the checkout's name, and a `merge` instruction (US-48.17) must
          # name exactly the repository this dispatch was for.
          |> Keyword.update(:binding, %{}, &Map.put(&1, "forge_repo", dispatch["repo"]))

        task =
          Task.Supervisor.async_nolink(a.run_supervisor, fn -> run.(config, story, opts) end)

        Logger.info(
          "dispatch #{id} recorded as accepted: run of #{story.id} started on #{story.branch}",
          dispatch_id: id
        )

        PendingStarts.delete(config.runs_dir, id)

        assign(socket,
          pending_starts: pending,
          runs:
            Map.put(a.runs, id, %{
              ref: task.ref,
              run_id: nil,
              run_dir: nil,
              kind: "implement"
            }),
          run_refs: Map.put(a.run_refs, task.ref, id),
          stage_streams: Map.put(a.stage_streams, id, open_stream(socket, dispatch, "claimed"))
        )

      # A triage run opens no stage stream: the contract's stages move a STORY through its
      # lifecycle, and this dispatch has none to move. Its one report is the verdict, which the
      # run sends back as a message so that a Control which restarted under it still receives it.
      # A reply_draft run takes this same path: its one report is its agent_result.
      {%{work: %{kind: kind} = work, opts: opts}, pending} when kind in @scratch_kinds ->
        triage_run = a.triage_run
        config = a.config
        critic = a.critic
        binding = Keyword.fetch!(opts, :binding)
        target = a.name || self()

        task =
          Task.Supervisor.async_nolink(a.run_supervisor, fn ->
            result =
              triage_run.(config, work.subject, work.repo,
                binding: binding,
                # The template `work/3` resolved, so the prompt rendered is the one it accepted.
                template: work.template,
                # Where the run keeps its state, reported the moment it exists rather than at the
                # end: a task killed from outside never reaches the end, and its state.json is
                # then the only thing that can be closed — by whoever knows where it is.
                on_start: fn run -> notify_control(target, {:triage_started, binding, run}) end,
                # The run directory travels with the outcome: it is where the message this
                # process is about to build is kept until loopctl records it, and a Control that
                # did not start this run has no other way to learn it.
                # The base a triage-shaped run judges origin's copy of (`TriageRun`).
                base_branch: Map.get(work, :base_branch),
                wall_clock_s: work.wall_clock_s,
                max_turns: work.max_turns,
                deadline_at: work.deadline_at,
                # A tuning run's critic: where its eval set lives, and a test's fake CLI. Read
                # only by a spec_tuner@1 run (`TriageRun`).
                critic: critic,
                # The session id this dispatch's accept named (contract 1.35.0).
                session_id: Keyword.get(opts, :session_id)
              )

            notify_control(
              target,
              {:triage_outcome, binding, Map.take(result, [:run_id, :run_dir]), result.outcome}
            )

            result
          end)

        Logger.info(
          "dispatch #{id} recorded as accepted: #{kind} of #{subject_id(work.subject)} " <>
            "started in #{work.repo}",
          dispatch_id: id
        )

        PendingStarts.delete(config.runs_dir, id)

        assign(socket,
          pending_starts: pending,
          runs:
            Map.put(a.runs, id, %{
              ref: task.ref,
              run_id: nil,
              run_dir: nil,
              kind: kind,
              verdict: :pending,
              binding: binding
            }),
          run_refs: Map.put(a.run_refs, task.ref, id)
        )
    end
  end

  defp drop_pending(socket, id, why) do
    a = socket.assigns

    case Map.pop(a.pending_starts, id) do
      {nil, _} ->
        socket

      {_pending, pending} ->
        Logger.error(
          "loopctl did not record this runner's accept of dispatch #{id} (#{why}); " <>
            "its run is not started",
          dispatch_id: id
        )

        PendingStarts.delete(a.config.runs_dir, id)

        assign(socket,
          pending_starts: pending,
          started_dispatches: Map.delete(a.started_dispatches, id)
        )
    end
  end

  # --- Stage reports (a run's messages in, contract `stage` pushes out) ---

  # One per accepted dispatch: the dispatch it reports for, the stage last queued, reports
  # waiting in order (the head stays until acknowledged), the push in flight, a retry timer and
  # its attempts, whether INTERMEDIATE reports have stopped, whether the run's end is queued, the
  # stages the terminal report was already refused from as stale, the `session_ended` payload
  # waiting behind the stage reports, and whether a terminal `escalated` was given up unsettled.
  #
  # `stopped` never stops the run's end: a terminal `escalated` and a `session_ended` are what give
  # loopctl's slot back, so they are sent on every stream however its intermediate reports fared.
  # `claim_ended` (contract 1.22.0, `end_claim/5`) is the one thing that does: loopctl refused one
  # of the dispatch's messages with a code that ends the claim it ran under, so nothing more of its
  # work goes — no stage report, terminal ones included — and only its `session_ended` is still
  # sent.
  # `session_ended` goes only once the queue is EMPTY — after every stage report — because a
  # `crashed` one releases the claim, and a stage report sent after that is refused as stale.
  defp stage_stream(dispatch, stage),
    do: %{
      dispatch: Map.take(dispatch, ["dispatch_id", "claim_epoch", "story_id"]),
      stage: stage,
      queue: [],
      push: nil,
      timer: nil,
      rate_limited: 0,
      internal_errors: 0,
      stopped: false,
      ended: false,
      terminal_tried: [],
      session_ended: nil,
      escalation_unsettled: false,
      claim_ended: false,
      stop_session: false
    }

  # Every stream is opened through here, so each honours a claim recorded over
  # (`LoopctlRunner.ClaimEnded`): it takes nothing of that claim's work but the `session_ended`. A
  # session of it still running was stopped where the end was learnt, or when this Control started
  # (`restart_claim_stops/1`).
  defp open_stream(socket, dispatch, stage) do
    stream = stage_stream(dispatch, stage)

    if ClaimEnded.ended?(socket.assigns.config.runs_dir, dispatch),
      do: %{stream | claim_ended: true, stopped: true, stop_session: true},
      else: stream
  end

  defp put_stream(socket, id, stream),
    do: assign(socket, stage_streams: Map.put(socket.assigns.stage_streams, id, stream))

  # A run this process did not start (its Control crashed and this one replaced it) gets a stream
  # on its first stage message, built from the binding the message carries. Its accept was
  # recorded, or it would not be running; the stage it reports from is the one its event follows.
  defp run_message(socket, %{"dispatch_id" => id} = binding, event) when is_binary(id) do
    socket =
      case {socket.assigns.stage_streams[id], event_from(event)} do
        {nil, from} when is_binary(from) ->
          Logger.info(
            "a run this Control did not start reported #{elem(event, 0)}; " <>
              "reporting its stages from #{from}",
            dispatch_id: id
          )

          put_stream(socket, id, open_stream(socket, binding, from))

        _ ->
          socket
      end

    run_stage(socket, id, event)
  end

  defp run_message(socket, _binding, _event), do: socket

  defp event_from({:worktree, _}), do: "claimed"
  defp event_from({:implementing, _}), do: "worktree"
  defp event_from({:observed, _}), do: "implementing"
  defp event_from({:finished, summary}), do: Map.get(summary, :reached) || "implementing"
  defp event_from(_event), do: nil

  defp run_stage(socket, id, {:started, %{run_id: run_id, run_dir: run_dir}}) do
    case socket.assigns.runs[id] do
      nil ->
        socket

      run ->
        runs = Map.put(socket.assigns.runs, id, %{run | run_id: run_id, run_dir: run_dir})
        assign(socket, runs: runs)
    end
  end

  defp run_stage(socket, id, {:worktree, %{branch: branch, worktree_path: path}}),
    do:
      queue_stage(socket, id, "worktree", effects: %{"branch" => branch, "worktree_path" => path})

  defp run_stage(socket, id, {:implementing, _}), do: queue_stage(socket, id, "implementing")

  defp run_stage(socket, id, {:observed, observed}), do: queue_observed(socket, id, observed)

  defp run_stage(socket, id, {:finished, summary}) do
    socket = if sessionless_end?(summary), do: forget_sessionless(socket, id), else: socket
    queue_end(socket, id, summary)
  end

  defp run_stage(socket, _id, _event), do: socket

  # The run's end, as `DispatchRun.end_reports/1` says: `-> escalated` only when no session ever
  # started or the session ran loop-escalate — the story's stage is otherwise the session's to
  # report, since the session delivers — and `session_ended` for every run that had a session.
  defp queue_end(socket, id, summary) do
    case socket.assigns.stage_streams[id] do
      %{ended: false} = stream ->
        socket = put_stream(socket, id, %{stream | ended: true})

        # A claim loopctl already ended takes no escalation; one that was the run's LAST end report
        # is recorded refused, as its refusal would have been, so a later Control does not send it.
        record_refused_end(
          socket,
          stream,
          stream.claim_ended and DispatchRun.end_reports(summary) == [:escalated]
        )

        Enum.reduce(DispatchRun.end_reports(summary), socket, fn
          :escalated, socket ->
            queue_stage(socket, id, "escalated",
              edge: "session_escalated",
              reason: DispatchRun.end_reason(summary)
            )

          :session_ended, socket ->
            queue_session_ended(socket, id, summary)
        end)

      _ ->
        socket
    end
  end

  # Composed ONCE and kept as it was composed: every resend of it — after a lost reply, a rejoin,
  # or by a later Control from `state.json` — is the same bytes, which loopctl answers `ok` with
  # `replayed` true; a payload rebuilt with another reason would be refused `already_recorded`.
  defp queue_session_ended(socket, id, summary) do
    stream = socket.assigns.stage_streams[id]

    case DispatchRun.session_ended(stream.dispatch, summary) do
      {:ok, payload} ->
        socket
        |> put_stream(id, %{stream | session_ended: payload})
        |> send_next_stage(id)

      {:error, errors} ->
        Logger.error(
          "session_ended not reported: it would fail the contract: #{inspect(errors)}",
          stage_ids(stream)
        )

        socket
    end
  end

  # --- Observed stages (US-48.16): a pr-mode session's pull request, as the forge reported it ---
  #
  # A pr-mode session opens its pull request, or on a rework pushes to the one the dispatch names,
  # and stops at green CI (it never merges: loopctl does, through `MergeRun`). Nothing the session
  # says tells loopctl how far that pull request got. So
  # once it is over the run asks the forge (`DispatchRun.observe/4`) and the stages that answer
  # shows arrive here as `{:observed, stages}`, ahead of the run's end. Each is an ORDINARY stage
  # report over `forward` in this dispatch's stream — sent in order, one at a time, held across a
  # rejoin, with `session_ended` behind the last of them — never a path of its own. The run wrote
  # them to `state.json` first (`observed_stages`), so a Control that never saw the message (it
  # was not running, or the run's task died) queues them from disk before the run's end.
  #
  # The main line they move along, and the four a runner observes on it.
  @observed_line ~w(implementing reviewing pr_open ci merged deployed verified done)
  @observed_tos ~w(reviewing pr_open ci merged)

  # In order, and only as far as each one queues: a stage this stream already holds (queued
  # before, or reported by this Control) is not queued twice, and the first that cannot follow
  # the stream's stage — or that `queue_stage/4` does not take — ends the sequence.
  defp queue_observed(socket, id, observed) when is_list(observed) do
    Enum.reduce_while(observed, socket, fn entry, socket ->
      case queue_one_observed(socket, id, entry) do
        {:cont, socket} -> {:cont, socket}
        {:halt, socket} -> {:halt, socket}
      end
    end)
  end

  defp queue_observed(socket, _id, _observed), do: socket

  defp queue_one_observed(socket, id, %{"to" => to} = entry) when to in @observed_tos do
    case socket.assigns.stage_streams[id] do
      nil ->
        {:halt, socket}

      %{stage: stage} = stream ->
        cond do
          held_at_or_past?(stage, to) ->
            {:cont, socket}

          line_index(stage) != nil and line_index(stage) + 1 == line_index(to) ->
            queue_observed_next(socket, id, to, entry)

          true ->
            Logger.warning(
              "the observed stage -> #{to} is not reported: this dispatch's stream is at " <>
                "#{stage}, which it does not follow",
              stage_ids(stream)
            )

            {:halt, socket}
        end
    end
  end

  defp queue_one_observed(socket, _id, _entry), do: {:halt, socket}

  # Queued only if the stream took it: a stream that stopped (`stop_intermediates`) does not move.
  defp queue_observed_next(socket, id, to, entry) do
    socket = queue_stage(socket, id, to, edge: "forward", effects: observed_effects(entry))

    if socket.assigns.stage_streams[id][:stage] == to,
      do: {:cont, socket},
      else: {:halt, socket}
  end

  defp observed_effects(%{"effects" => effects}) when is_map(effects) and effects != %{},
    do: effects

  defp observed_effects(_entry), do: nil

  defp line_index(stage), do: Enum.find_index(@observed_line, &(&1 == stage))

  # Whether a story at `held` already holds `to`: both on the main line, `held` at or past it.
  defp held_at_or_past?(held, to) do
    case {line_index(held), line_index(to)} do
      {h, t} when is_integer(h) and is_integer(t) -> h >= t
      _ -> false
    end
  end

  defp observed_report?(payload),
    do: payload["edge"] == "forward" and payload["to"] in @observed_tos

  # What a run that ended where this Control did not see its `{:observed, _}` left on disk.
  defp queue_observed_from_disk(socket, id, run_dir) when is_binary(run_dir) do
    case RunState.read(run_dir) do
      {:ok, %{"observed_stages" => [_ | _] = observed}} -> queue_observed(socket, id, observed)
      _ -> socket
    end
  end

  defp queue_observed_from_disk(socket, _id, _run_dir), do: socket

  # --- Merges (US-48.17): loopctl's merge gate allowed a head, and this runner holds its claim ---
  #
  # Untrusted until it matches: the instruction must validate against `RunnerMergeInstruction`, and
  # name a dispatch, epoch, story and repository of an implement run on disk here whose claim was
  # never recorded over, whose session is over, whose end has been reported, and whose observed
  # pull request (when the run saw one) is the one named. Anything else is logged and dropped:
  # the contract defines no reply, and loopctl resends an instruction no merge answered.
  defp merge_instructed(socket, payload) do
    with :ok <- merge_valid(payload),
         {:ok, where} <- held_for_merge(socket, payload),
         :ok <- merge_not_running(socket, payload) do
      launch_merge(socket, payload, where)
    else
      {:drop, why} ->
        Logger.warning(
          "merge instruction for pull request ##{inspect(payload["pr_number"])} not acted on: " <>
            why
        )

        socket
    end
  end

  defp merge_valid(payload) do
    case Contract.validate("RunnerMergeInstruction", payload) do
      :ok -> :ok
      {:error, errors} -> {:drop, "it fails the contract: " <> Enum.join(errors, "; ")}
    end
  end

  defp held_for_merge(socket, %{"dispatch_id" => id, "claim_epoch" => epoch} = payload) do
    a = socket.assigns
    runs = for {_dir, %{"dispatch_id" => ^id}} = run <- RunState.all(a.config.runs_dir), do: run

    cond do
      runs == [] ->
        {:drop, "no run of dispatch #{id} is on this runner"}

      ClaimEnded.ended?(a.config.runs_dir, payload) ->
        {:drop, "loopctl ended the claim dispatch #{id} ran under at claim_epoch #{epoch}"}

      not Enum.any?(runs, fn {_dir, state} -> state["claim_epoch"] == epoch end) ->
        held = runs |> Enum.map(fn {_dir, state} -> state["claim_epoch"] end) |> Enum.uniq()

        {:drop,
         "dispatch #{id} is held here at claim_epoch #{inspect(held)}, not #{inspect(epoch)}"}

      Map.has_key?(a.runs, id) ->
        {:drop, "dispatch #{id}'s session is still running"}

      Map.has_key?(a.stage_streams, id) ->
        {:drop,
         "dispatch #{id} still has stage reports going out (its run's end, or a merge's); " <>
           "loopctl sends the merge again if none answers it"}

      true ->
        runs
        |> Enum.filter(fn {_dir, state} -> state["claim_epoch"] == epoch end)
        |> List.last()
        |> merge_where(payload, a.control)
    end
  end

  # The run's own branch and base, which the pull request must be from and into, once the run is
  # shown to be this instruction's: an implement run (a scratch run records its `kind`), of the
  # story named, for the repository named, and — when it observed its pull request — that one.
  defp merge_where({run_dir, state}, payload, control) do
    story = read_run_story(run_dir)

    cond do
      state["kind"] not in [nil, "implement"] ->
        {:drop,
         "dispatch #{payload["dispatch_id"]} is a #{state["kind"]} run, which merges nothing"}

      state["story_id"] != payload["story_id"] ->
        {:drop,
         "dispatch #{payload["dispatch_id"]} is story #{inspect(state["story_id"])}, " <>
           "not #{payload["story_id"]}"}

      not is_binary(story["branch"]) or not is_binary(story["base"]) ->
        {:drop, "dispatch #{payload["dispatch_id"]}'s run recorded no branch and base"}

      not merge_repo?(state, story, payload["repo"], control) ->
        {:drop,
         "dispatch #{payload["dispatch_id"]} was for " <>
           "#{state["forge_repo"] || story["repo"]}, not #{payload["repo"]}"}

      not observed_pr?(state, payload["pr_number"]) ->
        {:drop,
         "dispatch #{payload["dispatch_id"]}'s run observed another pull request than " <>
           "##{payload["pr_number"]}"}

      true ->
        {:ok, %{branch: story["branch"], base: story["base"]}}
    end
  end

  defp read_run_story(run_dir) do
    with {:ok, raw} <- File.read(Path.join(run_dir, "story.json")),
         {:ok, story} when is_map(story) <- JSON.decode(raw) do
      story
    else
      _ -> %{}
    end
  end

  # A run started since US-48.17 records the repository as loopctl names it. One started by an
  # earlier build records only the checkout's name, so it is matched the way `DispatchPolicy`
  # accepted it: a repository this runner serves, whose last segment is that name.
  defp merge_repo?(%{"forge_repo" => repo}, _story, named, _control) when is_binary(repo),
    do: repo == named

  defp merge_repo?(_state, story, named, control),
    do: named in control.repos and List.last(String.split(named, "/")) == story["repo"]

  # The pull request the run itself saw at `pr_open`, when it saw one, must be the one named.
  defp observed_pr?(%{"observed_stages" => observed}, number) when is_list(observed) do
    case Enum.find(observed, &match?(%{"to" => "pr_open"}, &1)) do
      %{"effects" => %{"pr_number" => seen}} -> seen == number
      _ -> true
    end
  end

  defp observed_pr?(_state, _number), do: true

  # One merge per story at a time. A repeat while one runs is the same instruction resent, and the
  # running merge answers it; a repeat after it finished runs again and reads the pull request
  # first, so a merge already made is reported, never made twice.
  defp merge_not_running(socket, %{"story_id" => story_id, "head_sha" => head}) do
    case socket.assigns.merges[story_id] do
      nil -> :ok
      %{head_sha: ^head} -> {:drop, "a merge of story #{story_id} at #{head} is already running"}
      %{head_sha: other} -> {:drop, "a merge of story #{story_id} at #{other} is still running"}
    end
  end

  defp launch_merge(socket, payload, where) do
    a = socket.assigns
    forge = a.merge_forge
    merge_opts = a.merge_opts

    task =
      Task.Supervisor.async_nolink(a.run_supervisor, fn ->
        MergeRun.execute(payload, where, forge, merge_opts)
      end)

    Logger.info(
      "merging pull request ##{payload["pr_number"]} of #{payload["repo"]} at " <>
        "#{payload["head_sha"]}, as loopctl's merge gate allowed"
    )

    assign(socket,
      merges:
        Map.put(a.merges, payload["story_id"], %{
          ref: task.ref,
          instruction: payload,
          head_sha: payload["head_sha"]
        }),
      merge_refs: Map.put(a.merge_refs, task.ref, payload["story_id"])
    )
  end

  defp merge_done(socket, ref, outcome) do
    a = socket.assigns
    {story_id, merge_refs} = Map.pop(a.merge_refs, ref)
    {%{instruction: instruction}, merges} = Map.pop(a.merges, story_id)
    socket = assign(socket, merges: merges, merge_refs: merge_refs)
    ids = dispatch_metadata(instruction)
    number = instruction["pr_number"]

    case outcome do
      {:merged, merge_sha} ->
        Logger.info(
          "pull request ##{number} is merged as #{merge_sha}; reporting ci -> merged",
          ids
        )

        merge_stage(socket, instruction, "merged",
          edge: "forward",
          effects: %{"merge_sha" => merge_sha}
        )

      {:head_moved, head} ->
        reason =
          "pull request ##{number}'s head is now #{head}, not #{instruction["head_sha"]}, " <>
            "the head the merge gate allowed; nothing was merged"

        Logger.warning(reason, ids)
        merge_stage(socket, instruction, "implementing", edge: "base_moved", reason: reason)

      {:escalate, reason} ->
        Logger.error("pull request ##{number} not merged: #{reason}", ids)
        merge_stage(socket, instruction, "escalated", edge: "session_escalated", reason: reason)

      {kind, reason} when kind in [:not_ours, :unreachable] and is_binary(reason) ->
        Logger.warning(
          "pull request ##{number} not merged, nothing reported (#{kind}): #{reason}",
          ids
        )

        socket

      other ->
        Logger.error(
          "pull request ##{number}: the merge answered #{inspect(other, limit: 5)}; nothing reported",
          ids
        )

        socket
    end
  end

  # The merge's report goes as an ordinary stage report — in order, held across a rejoin, read by
  # the same reply handling — on a stream of its own opened at `ci`, the stage loopctl's
  # instruction says the story holds. The stream is born ended, so it is dropped once its one
  # report settles. A stream of this dispatch that is still open means its run's end is still
  # going out, and a report queued behind it would be read as that end's reply: it is not sent, and
  # loopctl's resent instruction finds the merge already made.
  defp merge_stage(socket, instruction, to, opts) do
    id = instruction["dispatch_id"]

    if Map.has_key?(socket.assigns.stage_streams, id) do
      Logger.warning(
        "ci -> #{to} not reported: dispatch #{id} still has stage reports going out; loopctl " <>
          "resends the merge instruction and this runner reports it then",
        dispatch_metadata(instruction)
      )

      socket
    else
      stream = %{open_stream(socket, instruction, "ci") | ended: true}

      socket
      |> put_stream(id, stream)
      |> queue_stage(id, to, opts)
      |> drop_stream_if_done(id)
    end
  end

  defp queue_stage(socket, id, to, opts \\ []) do
    case socket.assigns.stage_streams[id] do
      nil ->
        socket

      %{claim_ended: true} = stream ->
        Logger.info(
          "stage #{stream.stage} -> #{to} not reported: loopctl ended the claim this dispatch ran " <>
            "under",
          stage_ids(stream)
        )

        socket

      %{stopped: true} = stream when to != "escalated" ->
        Logger.info(
          "stage #{stream.stage} -> #{to} not reported: this dispatch's intermediate reports " <>
            "have stopped; its terminal report will still be sent",
          stage_ids(stream)
        )

        socket

      stream ->
        case DispatchRun.stage_report(stream.dispatch, stream.stage, to, opts) do
          {:ok, payload} ->
            socket
            |> put_stream(id, %{stream | stage: to, queue: stream.queue ++ [payload]})
            |> send_next_stage(id)

          {:error, errors} ->
            Logger.error(
              "stage #{stream.stage} -> #{to} not reported: it would fail the contract: " <>
                inspect(errors),
              stage_ids(stream)
            )

            socket
        end
    end
  end

  defp resume_stages(socket),
    do: Enum.reduce(Map.keys(socket.assigns.stage_streams), socket, &send_next_stage(&2, &1))

  # The head of the queue goes out when nothing is in flight or waiting out a retry and the
  # channel is joined. A stream exists only for a run that started, and a run starts only once
  # loopctl has recorded its accept, so nothing here waits on the accept.
  defp send_next_stage(socket, id) do
    a = socket.assigns

    case a.stage_streams[id] do
      %{push: nil, timer: nil} = stream ->
        if a.joined,
          do: push_next(socket, id, stream),
          else: socket

      _ ->
        socket
    end
  end

  # The stage reports first, in order, and the `session_ended` only behind the last of them.
  defp push_next(socket, id, %{queue: [payload | _]} = stream),
    do: push_stage(socket, id, stream, "stage", payload)

  defp push_next(socket, id, %{session_ended: %{} = payload} = stream),
    do: push_stage(socket, id, stream, "session_ended", payload)

  defp push_next(socket, _id, _stream), do: socket

  defp push_stage(socket, id, stream, event, payload) do
    case push_event(socket, socket.assigns.topic, event, payload) do
      {:ok, ref} ->
        Logger.info(sent_line(event, payload), stage_ids(stream))

        socket
        |> put_stream(id, %{stream | push: ref})
        |> assign(stage_refs: Map.put(socket.assigns.stage_refs, ref, id))

      # Not joined at this instant: the rejoin resumes every stream.
      {:error, reason} ->
        Logger.info("stage report held until the channel rejoins: #{inspect(reason)}")
        socket
    end
  end

  defp sent_line("stage", payload),
    do: "stage report sent: #{payload["from"]} -> #{payload["to"]}"

  defp sent_line("session_ended", payload),
    do: "session_ended sent: #{payload["reason"]}"

  defp stage_answered(ref, reply, socket) do
    {id, refs} = Map.pop(socket.assigns.stage_refs, ref)
    socket = assign(socket, stage_refs: refs)

    case socket.assigns.stage_streams[id] do
      %{push: ^ref, queue: [_ | _]} = stream ->
        stream = %{stream | push: nil}

        stage_reply(socket, id, stream, reply)

      # Pushed only with the queue empty, and nothing is queued after the run's end.
      %{push: ^ref, queue: [], session_ended: %{}} = stream ->
        session_ended_reply(socket, id, %{stream | push: nil}, reply)

      # A reply to a push from before the last rejoin.
      _ ->
        socket
    end
  end

  # Settled on `ok` (a resend's `replayed` true included) and on every refusal the contract calls
  # permanent, `already_recorded` meaning done; `rate_limited` waits out the interval the refusal
  # names and `internal_error` is retried with the stream's backoff, both resending the same
  # payload. A settled one is recorded beside the run, so a later Control does not send it again.
  defp session_ended_reply(socket, id, %{session_ended: payload} = stream, reply) do
    case reply do
      {:error, %{"reason" => reason} = refusal} ->
        session_ended_refused(
          socket,
          id,
          stream,
          DispatchRun.session_ended_refusal(reason),
          refusal
        )

      _ ->
        if acked?(reply) do
          Logger.info(
            "loopctl recorded session_ended (#{payload["reason"]})" <> replayed_note(reply),
            stage_ids(stream)
          )

          settle_session_ended(socket, id, stream, true)
        else
          session_ended_refused(socket, id, stream, :unknown, reply)
        end
    end
  end

  # The wait a rate_limited refusal names, taken only when it is a positive integer that
  # Process.send_after/3 accepts (at most 2^32 - 1 ms): the refusal is loopctl's data, and anything
  # else (null, a float, a string, zero, too large) would crash this process or spin the retry, so
  # it gets the default instead.
  defp refusal_interval(%{"min_interval_ms" => ms}, _default)
       when is_integer(ms) and ms > 0 and ms <= 0xFFFFFFFF,
       do: ms

  defp refusal_interval(_refusal, default), do: default

  defp replayed_note({:ok, %{"replayed" => true}}),
    do: "; it was a resend, and loopctl applied nothing a second time"

  defp replayed_note(_reply), do: ""

  defp session_ended_refused(socket, id, stream, :rate_limited, refusal) do
    delay = refusal_interval(refusal, @session_ended_retry_ms)
    retry_stage(socket, id, %{stream | rate_limited: stream.rate_limited + 1}, delay)
  end

  defp session_ended_refused(socket, id, stream, :internal_error, refusal) do
    attempts = stream.internal_errors + 1

    if attempts < socket.assigns.internal_error_attempts do
      retry_stage(socket, id, %{stream | internal_errors: attempts})
    else
      Logger.error(
        "giving up on session_ended for dispatch #{id} after #{attempts} internal_error " <>
          "replies from loopctl: #{inspect(refusal)}; a restarted Control sends it again",
        stage_ids(stream)
      )

      settle_session_ended(socket, id, stream, nil)
    end
  end

  defp session_ended_refused(socket, id, stream, :done, refusal) do
    Logger.warning(
      "loopctl already holds a different session_ended for dispatch #{id} " <>
        "(#{stream.session_ended["reason"]} was refused: #{inspect(refusal)}); nothing to resend",
      stage_ids(stream)
    )

    settle_session_ended(socket, id, stream, true)
  end

  defp session_ended_refused(socket, id, stream, kind, refusal) do
    Logger.error(
      "loopctl refused session_ended (#{stream.session_ended["reason"]}) for dispatch #{id}" <>
        if(kind == :unknown, do: " for a reason this build does not know", else: "") <>
        ": #{inspect(refusal)}; it is not sent again, and the story stays where it is until " <>
        "loopctl reclaims it",
      stage_ids(stream)
    )

    settle_session_ended(socket, id, stream, "refused")
  end

  # `recorded` is what goes beside the run: true or "refused" once settled, nil when only THIS
  # process gives up, so a restart sends it again. A terminal `escalated` given up unsettled before
  # it keeps the whole end unrecorded for the same reason.
  defp settle_session_ended(socket, id, stream, recorded) do
    if recorded != nil and not stream.escalation_unsettled,
      do: mark_terminal_reported(socket, stream, recorded)

    socket
    |> put_stream(id, %{stream | session_ended: nil, rate_limited: 0, internal_errors: 0})
    |> drop_stream_if_done(id)
  end

  # The refusals of a stage report that end the claim it ran under (contract 1.22.0). Every other
  # permanent one refuses only that report, and is `stage_refused/5`'s.
  @stage_claim_ending Contract.claim_ending_errors("stage")

  # Every other PERMANENT refusal of a stage report "refuses only the message that drew it"
  # (`claim_ending_remedy`): the contract's permanent set for the event, less the claim-ending
  # codes and the codes whose permanence carries a condition, each of which has its own branch.
  @stage_per_message Enum.filter(
                       Map.fetch!(Map.fetch!(Contract.connection(), "errors"), "stage"),
                       &(&1 in Contract.permanent_errors("stage"))
                     ) --
                       (@stage_claim_ending ++
                          Map.keys(
                            Map.fetch!(Contract.connection(), "permanent_error_conditions")
                          ))

  defp stage_reply(socket, id, %{queue: [payload | _]} = stream, reply) do
    case reply do
      {:error, %{"reason" => "rate_limited"}} ->
        retry_stage(socket, id, %{stream | rate_limited: stream.rate_limited + 1})

      {:error, %{"reason" => "internal_error"} = refusal} ->
        stage_internal_error(socket, id, stream, payload, refusal)

      {:error, %{"reason" => "stale_stage"} = refusal} ->
        stale_stage(socket, id, stream, payload, refusal)

      {:error, %{"reason" => reason} = refusal} when reason in @stage_claim_ending ->
        stage_claim_ended(socket, id, stream, payload, refusal)

      {:error, %{"reason" => "dispatch_not_accepted"}} ->
        stage_not_accepted(socket, id, stream, payload)

      {:error, %{"reason" => reason}} when reason in @stage_per_message ->
        stage_dropped(socket, id, stream, payload, reason)

      _ ->
        if acked?(reply),
          do: stage_recorded(socket, id, stream, payload),
          else: stage_refused(socket, id, stream, payload, inspect(reply))
    end
  end

  defp stage_recorded(socket, id, stream, payload) do
    Logger.info(
      "loopctl recorded the stage #{payload["from"]} -> #{payload["to"]}",
      stage_ids(stream)
    )

    if last_end_report?(stream, payload), do: mark_terminal_reported(socket, stream)
    advance(socket, id, stream)
  end

  defp terminal?(payload), do: payload["to"] == "escalated"

  # A terminal `escalated` is the LAST thing a run reports only when no session followed it; with
  # a `session_ended` behind it, that report's settling is what records the run's end.
  defp last_end_report?(stream, payload), do: terminal?(payload) and stream.session_ended == nil

  # Recorded beside the run, so a later Control does not report this end again: true once loopctl
  # acknowledged its LAST end report — the `session_ended`, or the terminal `escalated` of a run
  # that had no session — and "refused" once it refused that for good (a later Control would only
  # be refused again, and loopctl's heal sweep does that accounting). One key for the whole end,
  # and the key the previous build wrote for its terminal `escalated`, so a run whose end an older
  # build already reported is not reported a second time after an upgrade.
  defp mark_terminal_reported(socket, stream, value \\ true)

  defp mark_terminal_reported(socket, %{dispatch: %{"dispatch_id" => id} = dispatch}, value) do
    epoch = dispatch["claim_epoch"]

    for {run_dir, _state} <- claim_runs(socket, id, epoch) do
      RunState.update(run_dir, %{terminal_reported: value})
    end

    :ok
  rescue
    exception ->
      Logger.warning(
        "could not record that dispatch #{id}'s terminal report was acknowledged " <>
          "(#{inspect(exception.__struct__)}); a restart will report it again",
        dispatch_id: id
      )
  end

  # The head is settled, one way or another: the next report goes.
  defp advance(socket, id, %{queue: [_ | rest]} = stream) do
    socket
    |> put_stream(id, %{
      stream
      | queue: rest,
        rate_limited: 0,
        internal_errors: 0,
        terminal_tried: []
    })
    |> drop_stream_if_done(id)
    |> send_next_stage(id)
  end

  # The claim is over: the refused report is settled as refused — recorded so when it was the run's
  # last end report — and `end_claim/5` stops everything else of the dispatch's work but its
  # `session_ended`, and its session with it.
  defp stage_claim_ended(socket, id, %{queue: [_ | rest]} = stream, payload, refusal) do
    record_refused_end(socket, stream, last_end_report?(stream, payload))

    socket
    |> put_stream(id, %{stream | queue: rest, rate_limited: 0, internal_errors: 0})
    |> end_claim(id, payload["claim_epoch"], "stage", refusal["reason"])
  end

  # A permanent refusal that is not the claim's or the run's end refuses THAT report only: it is
  # dropped, never resent, and the next report goes. The terminal one is `stage_refused/5`'s.
  # An OBSERVED report (US-48.16) refused this way stops the observed sequence instead: the next
  # one was built from the refused one's `to`, and loopctl has just said the row did not get there.
  defp stage_dropped(socket, id, stream, payload, reason) do
    if terminal?(payload) or observed_report?(payload) do
      stage_refused(socket, id, stream, payload, reason)
    else
      Logger.error(
        "loopctl refused the stage #{payload["from"]} -> #{payload["to"]} for dispatch #{id} " <>
          "(#{reason}); that report is dropped, and the next one still goes",
        stage_ids(stream)
      )

      advance(socket, id, %{stream | stage: stage_after_drop(stream, payload)})
    end
  end

  # The report was never recorded, so loopctl's row is still at its `from`: the stream goes back
  # there, which is what the next report, and the terminal one, are built from. Only when nothing
  # was queued after it — a later report already queued was built from the dropped one's `to`, and
  # the `stale_stage` it draws carries the row (`resync_stage/3`).
  defp stage_after_drop(%{stage: to}, %{"from" => from, "to" => to}), do: from
  defp stage_after_drop(%{stage: stage}, _payload), do: stage

  # `dispatch_not_accepted` is permanent "unless an accept YOU sent for this dispatch is still
  # unacknowledged": then the report waits for that accept, resent with the stream's backoff.
  # Otherwise the run is over (`end_run/5`); the refused report is settled as refused.
  defp stage_not_accepted(socket, id, %{queue: [_ | rest]} = stream, payload) do
    epoch = payload["claim_epoch"]

    if accept_outstanding?(socket, id, epoch) do
      Logger.info(
        "stage #{payload["from"]} -> #{payload["to"]} waits for this runner's accept of " <>
          "dispatch #{id} to be recorded",
        stage_ids(stream)
      )

      retry_stage(socket, id, %{stream | rate_limited: stream.rate_limited + 1})
    else
      record_refused_end(socket, stream, last_end_report?(stream, payload))

      socket
      |> put_stream(id, %{stream | queue: rest, rate_limited: 0, internal_errors: 0})
      |> end_run(
        id,
        epoch,
        "stage",
        "dispatch_not_accepted, with no accept of this runner's outstanding"
      )
    end
  end

  # A refusal nothing can fix. On an intermediate report it stops the intermediate reports, which
  # can no longer follow a stage loopctl disagrees with, and keeps the terminal one. On the
  # terminal report it is the end of the stream.
  defp stage_refused(socket, id, stream, payload, why) do
    if terminal?(payload) do
      Logger.error(
        "loopctl refused the terminal stage #{payload["from"]} -> escalated for dispatch #{id}: " <>
          "#{why}; the story stays where it is until loopctl reclaims it",
        stage_ids(stream)
      )

      if last_end_report?(stream, payload), do: mark_terminal_reported(socket, stream, "refused")
      advance(socket, id, stream)
    else
      Logger.error(
        "loopctl refused the stage #{payload["from"]} -> #{payload["to"]} for dispatch #{id}: " <>
          "#{why}; no further intermediate stages are reported for it, the terminal one still is",
        stage_ids(stream)
      )

      stop_intermediates(socket, id, stream)
    end
  end

  # Every stage a report can be sent FROM, read from the contract's own transition table. A stage
  # that is no entry's `from` is terminal: nothing a runner can say moves the story out of it, so
  # it is what `permanent_error_conditions` turns stale_stage's permanence on.
  @stage_transitions Map.fetch!(Contract.connection(), "stage_transitions")
  @reportable_froms @stage_transitions |> Enum.map(&Map.fetch!(&1, "from")) |> Enum.uniq()

  # Two lists that must agree, with nothing checking that they do — which is the shape this repo
  # keeps finding defects in. `RunnerStageReport.from` is what a report may SAY; the transition
  # table is what this runner may report FROM. They are equal today, and the equality is why the
  # branch that handled "the named stage builds no report" was unreachable: a stage the table
  # names is always a stage the enum accepts. Asserted at compile time so a contract that moves
  # one and not the other fails the build, rather than making that branch quietly live again.
  @report_froms Contract.schema_def("RunnerStageReport")
                |> Map.fetch!("properties")
                |> Map.fetch!("from")
                |> Map.fetch!("enum")

  if Enum.sort(@reportable_froms) != Enum.sort(@report_froms) do
    raise "the contract's stage_transitions and RunnerStageReport.from no longer agree: " <>
            "#{inspect(Enum.sort(@reportable_froms))} vs #{inspect(Enum.sort(@report_froms))}"
  end

  # A `stale_stage` refusal CARRIES THE ROW since 1.11.0, and `stage` is the field this reads.
  # Fetched at COMPILE time, and through `error_fields/2`, which fetches the event and the code
  # too: the table is complete, so a lookup that finds nothing means the field is no longer
  # published — and got rather than fetched, `refusal["stage"]` would simply be nil on every
  # refusal from then on, which is the fixed walk this replaced, back with nothing to see it.
  @stale_stage_fields Contract.error_fields("stage", "stale_stage")

  unless "stage" in @stale_stage_fields do
    raise "the vendored contract no longer publishes `stage` on a stale_stage refusal of a " <>
            "stage report (it publishes #{inspect(@stale_stage_fields)}); the terminal report " <>
            "has nothing to retry from and would guess again"
  end

  # And its permanence is CONDITIONAL, on that same table. Pinned so a vendoring that drops the
  # condition — making stale_stage flatly transient, or flatly permanent in `permanent_errors` —
  # fails the build rather than leaving this code implementing a rule the contract stopped stating.
  @stale_stage_condition Map.fetch!(
                           Map.fetch!(Contract.connection(), "permanent_error_conditions"),
                           "stale_stage"
                         )

  defp stale_stage(socket, id, %{queue: [_ | rest]} = stream, payload, refusal) do
    stage = refusal["stage"]

    cond do
      terminal?(payload) ->
        retry_terminal(socket, id, stream, payload, refusal)

      # US-48.16: an observed stage the row already holds is not a disagreement.
      observed_report?(payload) and held_at_or_past?(stage, payload["to"]) ->
        skip_held(socket, id, stream, stage)

      # An intermediate report refused with the story at a stage no runner can report out of: the
      # published condition says "Stop, and end the run" — its session with it.
      is_binary(stage) and stage not in @reportable_froms ->
        socket
        |> put_stream(id, %{stream | queue: rest, rate_limited: 0, internal_errors: 0})
        |> end_run(
          id,
          payload["claim_epoch"],
          "stage",
          "stale_stage: the story is at #{stage}, which no transition leaves"
        )

      true ->
        stage_refused(
          socket,
          id,
          resync_stage(stream, refusal, id),
          payload,
          "stale_stage #{inspect(refusal)}"
        )
    end
  end

  # The row is worth keeping even when the report it refused was an INTERMEDIATE one. The
  # intermediates stop either way — they cannot follow a stage loopctl disagrees with — but
  # `stream.stage` is what `queue_end/3` builds the terminal report's `from` from, and left at the
  # value loopctl has just called wrong it guarantees that report one refused round trip before
  # `retry_terminal/5` can act on the same row. That round trip also spends an entry of
  # `terminal_tried`, out of a budget bounded by the transition table, so the report that frees
  # loopctl's slot gets fewer attempts for nothing.
  defp resync_stage(stream, refusal, id) do
    believed = stream.stage

    case refusal["stage"] do
      stage when stage in @reportable_froms and stage != believed ->
        Logger.info(
          "dispatch #{id}'s row is at #{stage}, not #{believed}; its terminal report will be " <>
            "sent from there",
          stage_ids(stream)
        )

        %{stream | stage: stage}

      # No row, the stage this stream already believes, or one no report may be sent from: nothing
      # to learn, and a stage outside the enum would only fail the contract check locally.
      _stage ->
        stream
    end
  end

  # A `stale_stage` on an observed report naming a stage AT OR PAST it: loopctl already holds that
  # stage — the session reported it through its own tools, or a resend after a restart finds its
  # first copy recorded. Nothing is wrong, so nothing stops: every observed report the row already
  # holds is dropped unsent, the next is sent from the stage the row names, and the stream takes
  # that stage when nothing observed is left to send. Bounded: each skip drops at least the
  # refused report, and a row that moved BACK draws the ordinary refusal, which stops the sequence.
  defp skip_held(socket, id, %{queue: [_ | rest]} = stream, held) do
    {dropped, rest} =
      Enum.split_with(rest, &(observed_report?(&1) and held_at_or_past?(held, &1["to"])))

    Logger.info(
      "loopctl already holds dispatch #{id}'s story at #{held}; the observed stages up to it " <>
        "(#{Enum.map_join([hd(stream.queue) | dropped], ", ", & &1["to"])}) are not sent again",
      stage_ids(stream)
    )

    case resend_from(stream, rest, held) do
      {:ok, rest} ->
        stage =
          if Enum.any?(rest, &observed_report?/1) or held not in @reportable_froms,
            do: stream.stage,
            else: held

        socket
        |> put_stream(id, %{
          stream
          | queue: rest,
            stage: stage,
            rate_limited: 0,
            internal_errors: 0,
            terminal_tried: []
        })
        |> drop_stream_if_done(id)
        |> send_next_stage(id)

      {:error, why} ->
        stage_refused(socket, id, stream, hd(stream.queue), why)
    end
  end

  # The first observed report left is rebuilt FROM the stage the row holds, which is the
  # transition that applies from there.
  defp resend_from(stream, [%{"to" => to} = next | later] = rest, held) do
    if observed_report?(next) and next["from"] != held do
      case DispatchRun.stage_report(stream.dispatch, held, to,
             edge: "forward",
             effects: next["effects"]
           ) do
        {:ok, rebuilt} -> {:ok, [rebuilt | later]}
        {:error, errors} -> {:error, "the observed stage #{held} -> #{to}: #{inspect(errors)}"}
      end
    else
      {:ok, rest}
    end
  end

  defp resend_from(_stream, rest, _held), do: {:ok, rest}

  # The story is not where the report said, and since 1.11.0 the refusal says where it IS: the
  # terminal report is sent again FROM the stage it names, which is the transition that applies
  # from there. Only the terminal report is retried — it is the one that frees loopctl's slot.
  #
  # PERMANENT when that stage is no transition's `from`. The story has then reached a stage no
  # runner can report out of, which a session reaches by escalating through the HTTP surface under
  # the same claim while its run is still going, and there is nothing left to say: the run ends.
  # That is the published condition, checked as published — whether the specific edge exists from
  # there is loopctl's to refuse, and inventing a second condition here is how the two sides drift.
  #
  # This used to walk a FIXED list of the stages the story could still be at, because the refusal
  # named none. On 2026-09-14 all three were refused in turn and not one of them could say where
  # the row was. A stage already tried is never tried again, which bounds this at the length of the
  # transition table however the row moves underneath.
  defp retry_terminal(socket, id, %{queue: [_ | rest]} = stream, payload, refusal) do
    tried = stream.terminal_tried ++ [payload["from"]]
    stage = refusal["stage"]

    cond do
      # A refusal with no row at all. loopctl builds this reply in ONE place, from a row it already
      # holds, so it should not happen — but `error_fields` is an override table maintained BESIDE
      # that builder rather than derived from it (read in loopctl's source, 2026-09-15), so the
      # promise can drift from the reply without either side noticing. This is what makes that
      # tolerable: the refusal is given up with a line naming it, rather than sending the runner
      # back to guessing at stages, which is what the walk here used to do on exactly this input.
      not is_binary(stage) ->
        stage_refused(
          socket,
          id,
          stream,
          payload,
          "stale_stage naming no stage: #{inspect(refusal)}"
        )

      stage not in @reportable_froms ->
        Logger.error(
          "dispatch #{id}'s story is at #{stage}, which no transition leaves; its terminal " <>
            "report is given up and the run ends. #{@stale_stage_condition}",
          stage_ids(stream)
        )

        stage_refused(
          socket,
          id,
          stream,
          payload,
          "the story is at #{stage}, which no transition leaves"
        )

      stage in tried ->
        stage_refused(
          socket,
          id,
          stream,
          payload,
          "stale_stage naming #{stage}, already tried (#{Enum.join(tried, ", ")})"
        )

      true ->
        retry_terminal_from(socket, id, stream, payload, rest, stage, tried)
    end
  end

  defp retry_terminal_from(socket, id, stream, payload, rest, stage, tried) do
    case DispatchRun.stage_report(stream.dispatch, stage, payload["to"],
           edge: payload["edge"],
           reason: payload["reason"]
         ) do
      {:ok, retry} ->
        Logger.warning(
          "loopctl refused #{payload["from"]} -> #{payload["to"]} for dispatch #{id} as " <>
            "stale_stage; its row is at #{stage}, so trying #{stage} -> #{payload["to"]}",
          stage_ids(stream)
        )

        socket
        |> put_stream(id, %{stream | queue: [retry | rest], terminal_tried: tried})
        |> send_next_stage(id)

      {:error, errors} ->
        stage_refused(
          socket,
          id,
          stream,
          payload,
          "stale_stage naming #{stage}, which this runner cannot report from: #{inspect(errors)}"
        )
    end
  end

  # internal_error: an intermediate report is retried a few times and then given up, and the
  # stream moves on to the next report; the terminal report gets a longer bounded retry, because
  # it is the one that frees loopctl's slot.
  defp stage_internal_error(socket, id, stream, payload, refusal) do
    attempts = stream.internal_errors + 1

    ceiling =
      if terminal?(payload),
        do: socket.assigns.terminal_internal_error_attempts,
        else: socket.assigns.internal_error_attempts

    cond do
      attempts < ceiling ->
        retry_stage(socket, id, %{stream | internal_errors: attempts})

      terminal?(payload) ->
        Logger.error(
          "giving up on the terminal stage #{payload["from"]} -> escalated for dispatch #{id} " <>
            "after #{attempts} internal_error replies from loopctl: #{inspect(refusal)}; the " <>
            "story is left short of its terminal until loopctl reclaims it",
          stage_ids(stream)
        )

        advance(socket, id, %{stream | escalation_unsettled: true})

      # An observed report given up stops the rest of them, as a refusal of one does.
      observed_report?(payload) ->
        Logger.error(
          "giving up on the observed stage #{payload["from"]} -> #{payload["to"]} for dispatch " <>
            "#{id} after #{attempts} internal_error replies from loopctl: #{inspect(refusal)}; " <>
            "no further observed stage is reported for it, its session_ended still is",
          stage_ids(stream)
        )

        stop_intermediates(socket, id, stream)

      true ->
        Logger.error(
          "giving up on the stage #{payload["from"]} -> #{payload["to"]} for dispatch #{id} " <>
            "after #{attempts} internal_error replies from loopctl: #{inspect(refusal)}; " <>
            "moving on to the next report",
          stage_ids(stream)
        )

        advance(socket, id, stream)
    end
  end

  # Doubling from the contract's burst refill interval, capped: a stream never retries tightly.
  # `delay` overrides that when the refusal names its own interval.
  defp retry_stage(socket, id, stream, delay \\ nil) do
    tries = stream.rate_limited + stream.internal_errors

    delay =
      delay ||
        capped_backoff(socket.assigns.stage_retry_ms, tries, 10, @max_stage_backoff_ms)

    token = make_ref()
    timer = Process.send_after(self(), {:stage_retry, id, token}, delay)
    put_stream(socket, id, %{stream | timer: {timer, token}})
  end

  # No further intermediate reports; a terminal report already queued stays and is sent.
  defp stop_intermediates(socket, id, %{queue: [_ | rest]} = stream) do
    socket
    |> put_stream(id, %{
      stream
      | stopped: true,
        queue: Enum.filter(rest, &terminal?/1),
        rate_limited: 0,
        internal_errors: 0
    })
    |> drop_stream_if_done(id)
    |> send_next_stage(id)
  end

  # A stream is forgotten once its run has ended and it has nothing left to send.
  defp drop_stream_if_done(socket, id) do
    a = socket.assigns

    case a.stage_streams[id] do
      %{ended: true, push: nil, queue: [], session_ended: nil} ->
        if Map.has_key?(a.runs, id),
          do: socket,
          else: assign(socket, stage_streams: Map.delete(a.stage_streams, id))

      _ ->
        socket
    end
  end

  defp stage_ids(%{dispatch: dispatch}),
    do: [
      dispatch_id: dispatch["dispatch_id"],
      story_id: dispatch["story_id"],
      claim_epoch: dispatch["claim_epoch"]
    ]

  # The task is over. A run that ended without reporting it (killed, or an exit rather than a
  # raise) is reported from what it left on disk, and a state.json it left in flight is closed —
  # once its session is over (`end_session_first/4`), whatever its kind.
  defp run_ended(socket, ref, reason) do
    a = socket.assigns
    {id, run_refs} = Map.pop(a.run_refs, ref)
    {run, runs} = Map.pop(a.runs, id)

    socket
    |> assign(run_refs: run_refs, runs: runs)
    |> end_session_first(id, run.run_dir, {:task_ended, run, reason})
  end

  # A triage run that reported its outcome is over: the verdict is its whole report, and the task
  # ending is not news. The state is closed all the same, and that is not belt and braces:
  # `TriageRun.finish/5` is rescue-guarded because `RunState.update/2` can fail, and a run whose
  # end could not be written reports its outcome perfectly well while leaving `running` and a live
  # owner behind — counted by `Runs.in_flight/2` for the life of this BEAM, with nothing to reap.
  # `close_crashed_state/1` does nothing to a state that is already closed.
  defp triage_run_ended(socket, _id, %{verdict: :reported, run_dir: run_dir}, _reason) do
    close_crashed_state(run_dir)
    socket
  end

  # A run that did NOT report is reported here, because the alternative is a dispatch loopctl waits
  # on for as long as the claim holds — but never OVER what the run itself concluded. `finish/5`
  # records the outcome as a message before the trace closes, the state is written or the task
  # returns, so a task killed anywhere in that window leaves a real verdict on disk while this
  # process sees only a death. Sending a report over it would be worse than sending nothing: the
  # real verdict then differs from what loopctl recorded, and a different verdict for one dispatch
  # is refused `already_recorded`, permanently.
  #
  # So the order is what the run got as far as: the message it recorded, then the verdict it read
  # but never turned into one (`TriageRun` makes that judgement, not this process — two mappings
  # from the same directory would drift), and only then the runner's own account of the death.
  defp triage_run_ended(socket, id, %{binding: binding, run_dir: run_dir} = run, reason) do
    detail =
      if reason == :normal,
        do: "the run ended without reporting its outcome",
        else: "the run's process died: #{inspect(reason, limit: 5)}"

    Logger.error("the triage run of dispatch #{id} #{detail}", dispatch_id: id)

    # The run cannot close its own state: it is not running any more. Left at `running` with this
    # BEAM's live owner recorded, `Runs.in_flight/2` would count it on every status push for as
    # long as this BEAM lives, and the runner would refuse dispatches at_capacity for ever — with
    # nothing to reap, since the owner really is alive. `run_dir` is nil only for a run killed
    # before its announcement reached this process, and `TriageRun` announces before it writes
    # any state, so that really is a run with nothing to close: a directory and nothing in it.
    close_crashed_state(run_dir)
    # A kill skips the run's `after`, which gives its own tree back (#69).
    if reason != :normal, do: give_scratch_tree_to_reaper(run_dir)

    case recorded_message(run_dir) do
      {:ok, payload} ->
        Logger.info(
          "the run had already recorded its outcome; sending that, not an account of its death",
          verdict_ids(payload)
        )

        push_verdict(socket, payload, run_dir)

      :none ->
        triage_outcome(socket, binding, run_dir, died_with(run_dir, detail, run[:kind]))
    end
  end

  # The outcome the run recorded, and only if it is still one this runner may push. Pushing a
  # payload without that check is how the run's real answer would be destroyed rather than
  # delivered: loopctl refuses it `invalid_payload`, which is permanent, and settling a permanent
  # refusal DELETES the file — taking with it the fallback in `died_with/2`, which can still
  # recover the verdict the session wrote. Unsendable, it is kept and stepped over, exactly as the
  # startup sweep keeps one.
  defp recorded_message(run_dir) do
    case PendingVerdicts.read(run_dir) do
      {:ok, payload} -> checked_message(payload, run_dir)
      :none -> :none
      {:error, why} -> recorded_message_unusable(run_dir, "cannot be read (#{inspect(why)})")
    end
  end

  defp checked_message(payload, run_dir) do
    case message_sendable(payload) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, errors} ->
        recorded_message_unusable(
          run_dir,
          "is not a message this runner may send (#{inspect(errors)})"
        )
    end
  end

  defp recorded_message_unusable(run_dir, why) do
    Logger.error(
      "the outcome recorded in #{run_dir} #{why}; it is not sent, and what the run directory " <>
        "says is reported instead"
    )

    :none
  end

  # What the run left behind, judged by the module that judges it for a run that lives: a verdict
  # the session wrote is still the answer, and bytes that are not one are still `verdict_invalid`.
  # Everything else is the death, in this process's own words, because that is the only part of
  # this it witnessed.
  #
  # A `:draft` run (reply_draft) is judged the same way by the same module: a result its session's
  # final message stated is still the answer, and anything else is `{:no_result, _}`, for which
  # nothing is sent — never a triage verdict, which loopctl would refuse for that dispatch.
  #
  # verify@1 answers with `agent_result` as well, and is judged the same way: its result is
  # completed from the head the run recorded checking out, and a run that recorded none is
  # `{:no_result, _}` (`TriageRun.outcome_on_disk/2`).
  defp died_with(run_dir, detail, kind) do
    case Templates.for_dispatch(%{"kind" => kind}) do
      {:ok, template} ->
        if Templates.agent_result?(template),
          do: died_drafting(run_dir, detail, template),
          else: died_with(run_dir, detail)

      :error ->
        died_with(run_dir, detail)
    end
  end

  defp died_with(nil, detail), do: {:incomplete, "no_verdict_written", detail}

  defp died_with(run_dir, detail) do
    case TriageRun.outcome_on_disk(run_dir) do
      {:verdict, _} = verdict -> verdict
      {:incomplete, "verdict_invalid", _} = invalid -> invalid
      _ -> {:incomplete, "no_verdict_written", detail}
    end
  end

  defp died_drafting(nil, detail, _template), do: {:no_result, detail}

  defp died_drafting(run_dir, detail, template) do
    case TriageRun.outcome_on_disk(run_dir, template) do
      {:agent_result, _key, _result} = result -> result
      _ -> {:no_result, detail}
    end
  end

  # A run that returned or raised has already queued its own end, and `queue_end/3` sends a run's
  # end once. One that died without doing so is reported from what it left on disk
  # (`Run.unfinished/2`): the stage it recorded reaching and its session's escalations.
  defp task_ended(socket, id, run, reason) do
    detail =
      if reason == :normal,
        do: "the run ended without reporting its end",
        else: "the run's process died: #{inspect(reason, limit: 5)}"

    summary = Run.unfinished(run.run_dir, detail)

    if reason != :normal do
      Logger.error("the run of dispatch #{id} died: #{inspect(reason)}", dispatch_id: id)
      close_crashed_state(run.run_dir, summary.status)
      give_scratch_tree_to_reaper(run.run_dir)
    end

    # A run that died after recording what it observed (US-48.16) but before announcing it: the
    # stages are queued from disk, and any it did announce are already this stream's.
    socket
    |> queue_observed_from_disk(id, run.run_dir)
    |> queue_end(id, summary)
    |> drop_stream_if_done(id)
  end

  # A run whose task died may leave its session running — the launcher ends it when the Port's
  # pipe closes, but not before this process reads what the run left — and that session can still
  # act AFTER its end is reported: an implement session push, a triage session write its verdict.
  # So a run whose state is still in flight has its tree ended first, as the reaper ends an
  # orphan's, whatever its kind, and its end is reported only once that is done.
  #
  # The ending runs in a task under the run supervisor, never in this process: a session that
  # ignores TERM takes up to twice `kill_grace_s` to go, and this process owns the channel — its
  # heartbeats and every other dispatch's stream. The task's answer (`session_ender_done/3`) is
  # what finishes the run's end; a task that dies finishes it too, logged, since reporting what is
  # on disk beats never reporting the run at all. A run that is not in flight finishes at once.
  defp end_session_first(socket, id, run_dir, next) when is_binary(run_dir) do
    case RunState.read(run_dir) do
      {:ok, %{"status" => status} = state} when status in ["starting", "running"] ->
        grace_ms = socket.assigns.config.kill_grace_s * 1000

        end_session = socket.assigns.end_session

        task =
          Task.Supervisor.async_nolink(socket.assigns.run_supervisor, fn ->
            end_session.(state, grace_ms)
          end)

        enders =
          Map.put(socket.assigns.session_enders, task.ref, {id, run_dir, next, state["run_id"]})

        assign(socket, session_enders: enders)

      _ ->
        finish_end(socket, id, next)
    end
  end

  defp end_session_first(socket, id, _run_dir, next), do: finish_end(socket, id, next)

  # The dead run's hold on its trees: a kill skipped the release in its `after` (#69), and only
  # once its session is gone may another run take them. Found by the run's id (`WorktreeLock`),
  # so a kill before its state recorded a path frees them too. Called only for a session that is
  # gone: one that survived, or whose ender died, keeps them (`session_ender_done/3` says so).
  defp release_dead_hold(runs_dir, id, run_id, {:gone, _text}) do
    released = if is_binary(run_id), do: WorktreeLock.release_held_by(runs_dir, run_id), else: []

    for path <- released,
        do: Logger.info("released dead run #{run_id}'s hold on #{path}", dispatch_id: id)

    :ok
  end

  defp session_ender_done(socket, ref, outcome) do
    {{id, run_dir, next, run_id}, enders} = Map.pop(socket.assigns.session_enders, ref)

    case outcome do
      {:ended, {:survived, text}} ->
        Logger.error(
          "the session of #{run_dir} survived its end (#{text}): run #{run_id} keeps its hold " <>
            "on its trees until this runner restarts, so no run works where it still writes",
          dispatch_id: id
        )

      {:ended, {:gone, text} = ended} ->
        Logger.info(
          "the session of #{run_dir}, before its end is reported: #{text}",
          dispatch_id: id
        )

        release_dead_hold(socket.assigns.config.runs_dir, id, run_id, ended)

      {:died, reason} ->
        Logger.error(
          "the session of #{run_dir} could not be ended before its end is reported " <>
            "(#{inspect(reason, limit: 5)}); reporting what the run left on disk",
          dispatch_id: id
        )
    end

    socket |> assign(session_enders: enders) |> finish_end(id, next)
  end

  # --- A claim loopctl ended (contract 1.22.0, `x-connection.claim_ending_errors`) ---

  # "The claim the refused message ran under is over: send that dispatch no more messages of its
  # work (the events keyed here) and stop its session. An implement session still sends
  # its `session_ended` when its process exits, as always". Keyed by the dispatch AND the epoch the
  # refused message carried: a message of another claim says nothing about this one, and a stream
  # of another epoch for the same dispatch is not this claim's.
  #
  # The end is recorded FIRST, as one marker for the claim (`LoopctlRunner.ClaimEnded`): a run of it
  # reads that marker immediately before starting its session and starts none, and a Control that
  # starts over honours it. The stream of THIS claim, when there is one, drops what it still owes
  # (`claim_over/3`), and every run of the claim still in flight has its session stopped — a
  # stream-less triage run, a run a predecessor started, or one of an older epoch alike.
  defp end_claim(socket, id, epoch, event, reason) do
    with {:error, why} <-
           ClaimEnded.record(socket.assigns.config.runs_dir, id, epoch, event, reason) do
      Logger.warning(
        "could not record that dispatch #{id}'s claim #{epoch} ended (#{inspect(why)}); a run " <>
          "of it could still start its session, and a restart will not know it",
        dispatch_id: id,
        claim_epoch: epoch
      )
    end

    case socket.assigns.stage_streams[id] do
      %{dispatch: %{"claim_epoch" => ^epoch}, claim_ended: true} ->
        socket |> drop_stream_if_done(id) |> send_next_stage(id)

      %{dispatch: %{"claim_epoch" => ^epoch}} = stream ->
        Logger.error(
          "loopctl refused #{event} for dispatch #{id} (#{reason}), which ends the claim it ran " <>
            "under: nothing more of its work is sent, " <>
            if(stream.ended,
              do: "its session is already over",
              else: "a session of it is stopped and one not yet started never starts"
            ) <> ", and the session_ended of a session that ran still goes",
          stage_ids(stream)
        )

        socket
        |> claim_over(id, stream)
        |> stop_run_session(id, epoch, live_claim_run_dirs(socket, id, epoch))
        |> drop_stream_if_done(id)
        |> send_next_stage(id)

      _none_of_this_claim ->
        stop_claim_elsewhere(socket, id, epoch, "#{event} (#{reason})")
    end
  end

  # No stream of the claim here: nothing queued to drop. An error only when a run of it is still
  # going on this machine and is stopped; otherwise it is the expected end of a claim this process
  # holds nothing of.
  defp stop_claim_elsewhere(socket, id, epoch, what) do
    case live_claim_run_dirs(socket, id, epoch) do
      [] ->
        Logger.info(
          "loopctl refused #{what} for dispatch #{id} at claim_epoch #{epoch}, which ends that " <>
            "claim; nothing of it is running here",
          dispatch_id: id,
          claim_epoch: epoch
        )

        socket

      run_dirs ->
        Logger.error(
          "loopctl refused #{what} for dispatch #{id} at claim_epoch #{epoch}, which ends that " <>
            "claim: the session of #{Enum.join(run_dirs, ", ")} is stopped",
          dispatch_id: id,
          claim_epoch: epoch
        )

        stop_run_session(socket, id, epoch, run_dirs)
    end
  end

  # A Control that starts over stops the session of every run still in flight whose claim a
  # predecessor saw end — every kind, triage included, stream or none: one reading of the runs,
  # matched against the (few) claims recorded over.
  defp restart_claim_stops(socket) do
    runs_dir = socket.assigns.config.runs_dir
    ClaimEnded.prune(runs_dir, System.os_time(:second), @claim_marker_max_age_s)
    ended = MapSet.new(ClaimEnded.all(runs_dir))

    runs_dir
    |> RunState.all()
    |> Enum.filter(fn {_dir, state} ->
      live?(state) and MapSet.member?(ended, {state["dispatch_id"], state["claim_epoch"]})
    end)
    |> Enum.group_by(
      fn {_dir, state} -> {state["dispatch_id"], state["claim_epoch"]} end,
      fn {dir, _state} -> dir end
    )
    |> Enum.reduce(socket, fn {{id, epoch}, run_dirs}, socket ->
      Logger.warning(
        "dispatch #{id}'s claim #{epoch} was recorded over, and a run of it is still in flight: " <>
          "stopping its session",
        dispatch_id: id,
        claim_epoch: epoch
      )

      stop_run_session(socket, id, epoch, run_dirs)
    end)
  end

  defp claim_over(socket, id, stream) do
    # A terminal `escalated` that was the run's LAST end report — no `session_ended` behind it — is
    # recorded refused, as its refusal would have been, so a later Control does not send it.
    record_refused_end(
      socket,
      stream,
      stream.ended and Enum.any?(stream.queue, &terminal?/1) and stream.session_ended == nil
    )

    stream = %{stream | stopped: true, claim_ended: true, stop_session: true}
    drop_owed(socket, id, stream, fn _payload -> false end)
  end

  # Records the run's end refused when `last?`: the report refused — or dropped with its claim —
  # was the run's LAST end report, so a later Control does not send it.
  defp record_refused_end(socket, stream, true),
    do: mark_terminal_reported(socket, stream, "refused")

  defp record_refused_end(_socket, _stream, false), do: :ok

  # What a stream still owes is cut down to the stage reports `keep?` keeps. When the HEAD of that
  # work is dropped, what was waiting on it goes too: a push in flight is orphaned rather than
  # awaited — its ref forgotten, so its reply lands on nothing, where it would otherwise be read as
  # the answer to a `session_ended` queued behind it — and a retry timer is cancelled, so the next
  # message is not held behind a backoff meant for one never sent. A `session_ended`, in flight or
  # waiting, is always kept, with its own timer.
  defp drop_owed(socket, id, stream, keep?) do
    head =
      case stream do
        %{queue: [head | _]} -> if keep?.(head), do: :kept, else: :dropped
        _session_ended_or_nothing -> :kept
      end

    stream = %{
      stream
      | queue: Enum.filter(stream.queue, keep?),
        rate_limited: 0,
        internal_errors: 0
    }

    case head do
      :kept ->
        put_stream(socket, id, stream)

      :dropped ->
        cancel_stage_timer(stream.timer)

        socket
        |> assign(stage_refs: Map.delete(socket.assigns.stage_refs, stream.push))
        |> put_stream(id, %{stream | push: nil, timer: nil})
    end
  end

  defp cancel_stage_timer({timer, _token}), do: Process.cancel_timer(timer)
  defp cancel_stage_timer(nil), do: false

  # `permanent_error_conditions` says two refusals END THE RUN without ending the claim:
  # `stale_stage` naming a stage no transition leaves, and `dispatch_not_accepted` with no accept
  # of this runner's in flight. The session is stopped as a claim-ending refusal stops it
  # (`stop_run_session/4`), and the intermediate stage reports stop, since the run they describe is
  # over. What differs from a claim's end is what is still SENT: the claim stands, so the run's end
  # — a terminal `escalated`, its `session_ended` — is reported as it
  # would be, and loopctl answers each by its own rules. Held in memory only. A run of the claim
  # with no stream of that epoch here has its session stopped all the same.
  defp end_run(socket, id, epoch, event, why) do
    case socket.assigns.stage_streams[id] do
      %{dispatch: %{"claim_epoch" => ^epoch}, stop_session: false} = stream ->
        Logger.error(
          "loopctl refused #{event} for dispatch #{id} (#{why}), which ends the run: no further " <>
            "intermediate stage is reported, " <>
            if(stream.ended, do: "its session is already over", else: "its session is stopped") <>
            ", and its end is still reported",
          stage_ids(stream)
        )

        socket
        |> drop_owed(id, %{stream | stopped: true, stop_session: true}, &terminal?/1)
        |> stop_run_session(id, epoch, live_claim_run_dirs(socket, id, epoch))
        |> drop_stream_if_done(id)
        |> send_next_stage(id)

      %{dispatch: %{"claim_epoch" => ^epoch}} ->
        socket |> drop_stream_if_done(id) |> send_next_stage(id)

      _none_of_this_claim ->
        stop_run_session(socket, id, epoch, live_claim_run_dirs(socket, id, epoch))
    end
  end

  # The runs of one claim still in flight on this machine: bound to the dispatch at that epoch,
  # `starting` or `running`, their owner alive. Read once, when the stop begins; the stop then
  # follows only those directories (`launch_session_stop/4`).
  defp live_claim_run_dirs(socket, id, epoch) do
    for {run_dir, state} <- claim_runs(socket, id, epoch), live?(state), do: run_dir
  end

  # Every run on disk bound to the dispatch at that epoch: the one place that filter is written.
  defp claim_runs(socket, id, epoch) do
    for {_dir, %{"dispatch_id" => ^id, "claim_epoch" => ^epoch}} = run <-
          RunState.all(socket.assigns.config.runs_dir),
        do: run
  end

  # The session is ended off this process, as `end_session_first/4` ends a dead run's: by the
  # reaper's own means, in a task under the run supervisor. One stop at a time per claim, and none
  # at all when no run of it is in flight. Used when loopctl ended the claim (`end_claim/5`) or the
  # run (`end_run/5`).
  defp stop_run_session(socket, _id, _epoch, []), do: socket

  defp stop_run_session(socket, id, epoch, run_dirs) do
    if MapSet.member?(socket.assigns.session_stopping, {id, epoch}) do
      socket
    else
      socket
      |> assign(session_stopping: MapSet.put(socket.assigns.session_stopping, {id, epoch}))
      |> launch_session_stop(id, epoch, run_dirs)
    end
  end

  defp launch_session_stop(socket, id, epoch, run_dirs) do
    a = socket.assigns
    grace_ms = a.config.kill_grace_s * 1000

    task =
      Task.Supervisor.async_nolink(a.run_supervisor, fn ->
        end_run_sessions(run_dirs, grace_ms)
      end)

    assign(socket, session_stops: Map.put(a.session_stops, task.ref, {id, epoch, run_dirs}))
  end

  # In the task: each run's session ended (`Reaper.end_session/2` leaves a run not in flight
  # alone), and which of the runs are STILL in flight afterwards.
  defp end_run_sessions(run_dirs, grace_ms) do
    ended =
      for run_dir <- run_dirs,
          {:ok, state} <- [RunState.read(run_dir)],
          do: {run_dir, end_session_of(state, grace_ms)}

    still =
      for run_dir <- run_dirs,
          {:ok, state} <- [RunState.read(run_dir)],
          live?(state) and session_pending_or_alive?(state),
          do: run_dir

    {ended, still}
  end

  # Whether a run's session is still to stop: not started yet (no process group recorded — a run
  # that passed its claim check just before the claim ended starts one), or started and still
  # alive. One whose session is gone is not looked at again while it tears down.
  defp session_pending_or_alive?(%{"pgid" => pgid}) when is_integer(pgid),
    do: ProcessGroup.alive?(pgid)

  defp session_pending_or_alive?(_state), do: true

  # One run's failure to be ended is that run's answer, not the stop's: the others are still ended,
  # and whether it is in flight is still asked, so the looking goes on only while it is.
  defp end_session_of(state, grace_ms) do
    Reaper.end_session(state, grace_ms)
  rescue
    exception -> "could not be ended: #{inspect(exception.__struct__)}"
  end

  # A run that passed its claim check just before the claim ended starts its session afterwards,
  # so while a followed run is in flight with its session not started or still alive, the stop
  # looks again after `session_stop_retry_ms`. A run whose session is gone is dropped from the
  # looking; for every kind of run alike. A stop task that died is tried again on the same runs.
  defp session_stop_done(socket, ref, outcome) do
    {{id, epoch, run_dirs}, stops} = Map.pop(socket.assigns.session_stops, ref)
    socket = assign(socket, session_stops: stops)

    retry =
      case outcome do
        {:ended, {ended, still}} ->
          for {run_dir, what} <- ended, what not in ["not in flight", "gone"] do
            Logger.info("the session of #{run_dir}, whose claim or run loopctl ended: #{what}",
              dispatch_id: id,
              claim_epoch: epoch
            )
          end

          still

        {:died, reason} ->
          Logger.error(
            "stopping the session of dispatch #{id}, whose claim or run loopctl ended, failed " <>
              "(#{inspect(reason, limit: 5)}); trying again",
            dispatch_id: id,
            claim_epoch: epoch
          )

          run_dirs
      end

    case retry do
      [] ->
        assign(socket,
          session_stopping: MapSet.delete(socket.assigns.session_stopping, {id, epoch})
        )

      run_dirs ->
        Process.send_after(
          self(),
          {:retry_session_stop, id, epoch, run_dirs},
          socket.assigns.session_stop_retry_ms
        )

        socket
    end
  end

  defp finish_end(socket, id, {:task_ended, %{kind: kind} = run, reason})
       when kind in @scratch_kinds,
       do: triage_run_ended(socket, id, run, reason)

  defp finish_end(socket, id, {:task_ended, run, reason}), do: task_ended(socket, id, run, reason)

  defp finish_end(socket, id, {:recovered, run_dir, state}),
    do: recovered_end(socket, id, run_dir, state)

  # A killed run's own scratch tree — a triage run's cut beside a held reused one —
  # was never released: the teardown that removes it is in the run's `after`, which a kill skips.
  # Recorded `remove_failed`, which is what the reaper collects from a run that is over whoever
  # owned it, so the next reap removes the tree and the Claude project directory its cwd made.
  # Never a triage repo's REUSED tree, which the entry says (`"reused"`): it outlives the run. Its
  # lock, the dead run's hold, is released once the run's session is gone (`session_ender_done/3`).
  defp give_scratch_tree_to_reaper(nil), do: :ok

  defp give_scratch_tree_to_reaper(run_dir) do
    case RunState.read(run_dir) do
      {:ok, %{"worktree" => %{"reused" => true}}} ->
        :ok

      {:ok, %{"worktree" => %{"scratch" => true, "status" => status} = tree}}
      when status in ["creating", "created"] ->
        RunState.update(run_dir, %{worktree: Map.put(tree, "status", "remove_failed")})

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Closed with the status the run's end is reported with, so a later Control reading it back
  # reports the same end.
  defp close_crashed_state(run_dir, status \\ "crashed")
  defp close_crashed_state(nil, _status), do: :ok

  defp close_crashed_state(run_dir, closed_as) do
    case RunState.read(run_dir) do
      {:ok, %{"status" => status}} when status in ["starting", "running"] ->
        RunState.update(run_dir, %{status: closed_as})

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # A refusal can only be addressed to a dispatch whose id and epoch arrived intact; without
  # them loopctl could not match the reply, and the malformed dispatch is logged only.
  defp refuse_dispatch(socket, %{"dispatch_id" => id, "claim_epoch" => epoch} = dispatch, why)
       when is_binary(id) and is_integer(epoch) and epoch >= 0 do
    payload =
      Map.merge(%{"dispatch_id" => id, "claim_epoch" => epoch, "decision" => "refused"}, why)

    case Contract.validate("RunnerDispatchReply", payload) do
      :ok ->
        story_id = if is_binary(dispatch["story_id"]), do: dispatch["story_id"]
        push_dispatch_reply(socket, payload, story_id)

      {:error, errors} ->
        Logger.warning(
          "dispatch not answered: a refusal would fail the contract: #{inspect(errors)}"
        )

        socket
    end
  end

  defp refuse_dispatch(socket, _dispatch, _why) do
    Logger.warning("dispatch not answered: it carries no usable dispatch_id and claim_epoch")
    socket
  end

  defp push_dispatch_reply(socket, payload, story_id, carried? \\ false) do
    case push_event(socket, socket.assigns.topic, "dispatch_reply", payload) do
      {:ok, ref} ->
        Logger.info("dispatch_reply sent: #{payload["decision"]} (#{payload["reason"]})",
          dispatch_id: payload["dispatch_id"],
          story_id: story_id,
          claim_epoch: payload["claim_epoch"]
        )

        assign(socket,
          dispatch_replies:
            Map.put(socket.assigns.dispatch_replies, ref, {payload, story_id, carried?})
        )

      # Not joined at this instant: kept, and sent once the channel is back.
      {:error, reason} ->
        Logger.warning("dispatch_reply held until the channel rejoins: #{inspect(reason)}",
          dispatch_id: payload["dispatch_id"],
          claim_epoch: payload["claim_epoch"]
        )

        assign(socket,
          reply_backlog: socket.assigns.reply_backlog ++ [{payload, story_id, carried?}]
        )
    end
  end

  # --- Triage verdicts (a triage run's one report) ---

  # A run whose deadline passed before its session started owes nothing: after the deadline the claim
  # is loopctl's lease sweep's to release, and there is no verdict to state. It is still remembered
  # as having reported, so its task ending does not report an account of its death instead, and
  # its dispatch is forgotten, as any run's that started no session is (`sessionless_end?/1`).
  defp triage_outcome(socket, binding, _run_dir, {:deadline_passed, detail}) do
    id = binding["dispatch_id"]

    Logger.warning(
      "the triage run of dispatch #{id} did not start: #{detail}; nothing is reported for it",
      dispatch_id: id
    )

    socket
    |> mark_verdict_reported(id)
    |> forget_sessionless(id)
  end

  # A `:draft` run (reply_draft) that produced no result sends NOTHING: `agent_result` has no
  # incomplete form, and a triage verdict for that dispatch would be refused. It is the run
  # FAILING, said as an error here and recorded `failed:no_result` in its state; loopctl's heal
  # sweep frees the slot and the next pass may draft the ticket again. It is remembered as
  # reported, so its task ending does not try to state it a second time.
  defp triage_outcome(socket, binding, _run_dir, {:no_result, detail}) do
    id = binding["dispatch_id"]

    Logger.error(
      "the draft run of dispatch #{id} produced no result to send (#{detail}); nothing is sent " <>
        "for it",
      dispatch_id: id
    )

    mark_verdict_reported(socket, id)
  end

  # The run's outcome, however it ended, becomes the one message loopctl is owed for this
  # dispatch. A payload that would fail the contract is NOT sent: loopctl refuses it
  # `invalid_payload`, which is permanent, so pushing it would discard the run's only output and
  # leave the ledger row waiting all the same — and the local log is the only place the outcome
  # can still be read.
  defp triage_outcome(socket, binding, run_dir, outcome) do
    id = binding["dispatch_id"]

    case sendable_message(binding, outcome) do
      {:ok, payload} ->
        Logger.info(
          "the triage run of dispatch #{id} ended: #{describe_outcome(outcome)}",
          verdict_ids(payload)
        )

        socket
        |> mark_verdict_reported(id)
        |> store_verdict(run_dir, payload)
        |> push_verdict(payload, run_dir)

      :none ->
        Logger.error(
          "nothing can be sent for dispatch #{id}: not even an incomplete addressed to it is a " <>
            "message loopctl would take; its run's outcome was #{describe_outcome(outcome)}",
          dispatch_id: id
        )

        socket
    end
  end

  # The outcome as a message, or the nearest thing loopctl will take. A run whose outcome will not
  # make one is still a dispatch loopctl is waiting on, and a report it can record beats silence:
  # `verdict_invalid` says exactly what happened when the verdict is what would not go — the
  # session wrote one and this runner's own validation refused it — and `no_verdict_written` is
  # expressible from a binding alone. Only a binding this runner cannot even address a message to
  # has nothing left, and then nothing is marked reported, so the run's task ending tries again.
  #
  # An agent_result has no fallback: there is no incomplete to fall back to, and a triage verdict
  # in its place would be refused for that dispatch. One that will not make a message is the run
  # failing, logged, and nothing is sent.
  defp sendable_message(binding, {:agent_result, _key, _result} = outcome) do
    case TriageRun.message(binding, outcome) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, errors} ->
        Logger.error(
          "the agent_result for dispatch #{binding["dispatch_id"]} is not a message this runner " <>
            "may send (#{inspect(errors)}); nothing is sent for it",
          dispatch_id: binding["dispatch_id"]
        )

        :none
    end
  end

  defp sendable_message(binding, outcome) do
    case TriageRun.message(binding, outcome) do
      {:ok, payload} -> {:ok, payload}
      {:error, errors} -> fallback_message(binding, outcome, errors)
    end
  end

  defp fallback_message(binding, outcome, errors) do
    reason = fallback_reason(outcome)

    Logger.error(
      "the triage verdict for dispatch #{binding["dispatch_id"]} is not a message this runner " <>
        "may send (#{inspect(errors)}); reporting #{reason} instead",
      dispatch_id: binding["dispatch_id"]
    )

    # The detail says where to look, never what was wrong: the errors can quote a verdict a
    # session composed after reading the reporter's own words, and the local log is where that
    # belongs.
    fallback =
      {:incomplete, reason,
       "the runner could not turn this run's outcome into a message; see the runner's log"}

    case TriageDispatch.verdict_message(binding, fallback) do
      {:ok, payload} -> {:ok, payload}
      {:error, _errors} -> :none
    end
  end

  # A verdict that would not go is the one case the contract has a word for.
  defp fallback_reason({:verdict, _verdict}), do: "verdict_invalid"
  defp fallback_reason(_outcome), do: "no_verdict_written"

  # The outcome named by its contract enums only. A verdict's prose and an incomplete's detail are
  # written by a session that had just read the reporter's words, and this line is not where they
  # are quoted.
  defp describe_outcome({:verdict, verdict}),
    do: "a verdict (#{verdict["outcome"]}, confidence #{verdict["confidence"]})"

  defp describe_outcome({:incomplete, reason, _detail}), do: "incomplete: #{reason}"
  defp describe_outcome({:error, _reason}), do: "a runner failure, reported as incomplete"

  defp describe_outcome({:deadline_passed, _detail}),
    do: "its deadline_at had passed; not started"

  # The draft's body is the session's prose about the reporter's words: never quoted here.
  defp describe_outcome({:agent_result, {id, version}, _result}),
    do: "an agent_result for #{id}@#{version}"

  defp describe_outcome({:no_result, _detail}), do: "no result, so nothing is sent"

  # A run this process did not start (its Control was replaced while it ran) has nothing here to
  # record against, and needs nothing: whatever ends it will report its own outcome.
  defp triage_started(socket, id, %{run_id: run_id, run_dir: run_dir}) do
    case socket.assigns.runs[id] do
      %{kind: kind} = run when kind in @scratch_kinds ->
        assign(socket,
          runs: Map.put(socket.assigns.runs, id, %{run | run_id: run_id, run_dir: run_dir})
        )

      _ ->
        socket
    end
  end

  # A run this process started is remembered as having reported, so its task ending does not
  # report a second time for the same dispatch.
  defp mark_verdict_reported(socket, id) do
    case socket.assigns.runs[id] do
      %{kind: kind} = run when kind in @scratch_kinds ->
        assign(socket, runs: Map.put(socket.assigns.runs, id, %{run | verdict: :reported}))

      _ ->
        socket
    end
  end

  # The message goes to disk BEFORE it is pushed, so that the copy which survives a restart is the
  # one that was sent rather than one rebuilt afterwards: loopctl answers a resend of the same
  # message `ok` and refuses a different verdict for the same dispatch permanently.
  #
  # Usually a second write of what the run already recorded at its end, and deliberately so: this
  # is the copy of the bytes that were actually PUSHED, and it is the only copy for the one
  # outcome no run can record — the one this process states because the run's task died before it
  # concluded anything.
  #
  # A run with no directory is a run that failed before it had one, so there is nothing to keep it
  # beside and nothing else about it to recover; it is logged, because what is lost is the restart
  # guarantee and not the push.
  defp store_verdict(socket, nil, payload) do
    Logger.warning(
      "the #{message_name(payload)} is sent but not recorded on disk: its run has no directory; a restart " <>
        "before loopctl records it would lose it",
      verdict_ids(payload)
    )

    socket
  end

  defp store_verdict(socket, run_dir, payload) do
    with {:error, reason} <- PendingVerdicts.write(run_dir, payload) do
      Logger.error(
        "could not record the #{message_name(payload)} in #{run_dir} (#{inspect(reason)}); a restart " <>
          "before loopctl records it would lose it",
        verdict_ids(payload)
      )
    end

    socket
  end

  # A verdict whose claim loopctl already ended (`LoopctlRunner.ClaimEnded`, recorded beside a run
  # of that dispatch and epoch) is not sent: "send that dispatch no more messages of its work". It
  # is settled as given up without a round trip, so neither this process nor a restart sends it.
  # Asked of every run of the claim, not only the verdict's own: the refusal that ended it may have
  # answered another run's trace.
  defp push_verdict(socket, payload, run_dir, carried? \\ false) do
    if claim_recorded_ended?(socket, payload) do
      Logger.warning(
        "the #{message_name(payload)} of dispatch #{payload["dispatch_id"]} is not sent: loopctl ended the " <>
          "claim it ran under; it is given up",
        verdict_ids(payload)
      )

      settle_verdict(socket, payload, run_dir)
    else
      send_verdict(socket, payload, run_dir, carried?)
    end
  end

  defp claim_recorded_ended?(socket, %{"dispatch_id" => id, "claim_epoch" => epoch})
       when is_binary(id) and is_integer(epoch),
       do: ClaimEnded.ended?(socket.assigns.config.runs_dir, id, epoch)

  defp claim_recorded_ended?(_socket, _payload), do: false

  defp send_verdict(socket, payload, run_dir, carried?) do
    event = message_event(payload)

    case push_event(socket, socket.assigns.topic, event, payload) do
      {:ok, ref} ->
        Logger.info("#{event} sent", verdict_ids(payload))

        assign(socket,
          verdict_pushes:
            Map.put(socket.assigns.verdict_pushes, ref, {payload, run_dir, carried?})
        )

      # Not joined at this instant: kept, and sent once the channel is back.
      {:error, reason} ->
        Logger.warning(
          "#{event} held until the channel rejoins: #{inspect(reason)}",
          verdict_ids(payload)
        )

        assign(socket,
          verdict_backlog: socket.assigns.verdict_backlog ++ [{payload, run_dir, carried?}]
        )
    end
  end

  defp verdict_answered(ref, reply, socket) do
    {{payload, run_dir, carried?}, pending} = Map.pop(socket.assigns.verdict_pushes, ref)
    socket = assign(socket, verdict_pushes: pending)
    ids = verdict_ids(payload)

    if acked?(reply) do
      note_recorded(reply, payload, ids)
      settle_verdict(socket, payload, run_dir)
    else
      verdict_refused(socket, reply, {payload, run_dir, carried?}, ids)
    end
  end

  # `replayed` is the whole reason the ack has a body: an `ok` that recorded this verdict and an
  # `ok` that found it already recorded and applied nothing are the same reply otherwise, and
  # after a resend the difference is what says whether the first copy landed.
  # The ack is read against the event's own published reply (`RunnerTriageVerdictAck`,
  # `RunnerAgentResultAck`: both `{recorded_at, replayed}`).
  defp note_recorded({:ok, body}, payload, ids) when is_map(body) do
    name = message_name(payload)

    case Contract.validate(message_ack(payload), body) do
      :ok ->
        Logger.info(
          "loopctl recorded the #{name} at #{body["recorded_at"]} " <>
            "(replayed: #{body["replayed"]})",
          ids
        )

      {:error, errors} ->
        Logger.warning(
          "loopctl acknowledged the #{name} with an ack this build cannot read " <>
            "(#{inspect(errors)}); whether it was recorded now or replayed is unknown",
          ids
        )
    end
  end

  defp note_recorded(_reply, payload, ids),
    do:
      Logger.warning(
        "loopctl acknowledged the #{message_name(payload)} with no ack body; whether it was " <>
          "recorded now or replayed is unknown",
        ids
      )

  # --- One message per scratch run: a triage verdict, or a draft's agent_result ---
  #
  # Both are kept in the same file (`PendingVerdicts`), pushed through the same backlog and
  # settled the same way; what differs is the event, its ack, how it is validated and how its
  # refusals read, and each of those is decided here from the payload, so a message restored from
  # disk by a Control that never saw its run is pushed as what it is.

  defp message_event(payload),
    do: if(AgentResult.message?(payload), do: AgentResult.event(), else: "triage_verdict")

  defp message_name(payload),
    do: if(AgentResult.message?(payload), do: "agent_result", else: "triage verdict")

  defp message_ack(payload),
    do: Map.fetch!(Map.fetch!(Contract.connection(), "replies"), message_event(payload))

  defp message_sendable(payload) do
    if AgentResult.message?(payload),
      do: AgentResult.sendable(payload),
      else: TriageDispatch.sendable(payload)
  end

  # `already_recorded` is `:permanent` for both: a different message for the same dispatch is
  # never settled by a resend, so it is given up, never retried.
  defp message_classify(payload, reason) do
    if AgentResult.message?(payload),
      do: AgentResult.classify(reason),
      else: TriageDispatch.classify(reason)
  end

  defp verdict_refused(socket, reply, {payload, _run_dir, _carried?} = entry, ids) do
    reason = refusal_reason(reply)

    case message_classify(payload, reason) do
      :rate_limited ->
        backlog = socket.assigns.verdict_backlog ++ [entry]

        Logger.info(
          "loopctl rate-limited a #{message_event(payload)}; #{length(backlog)} in the backlog, sent one " <>
            "every #{socket.assigns.triage_verdict_retry_ms}ms",
          ids
        )

        socket |> assign(verdict_backlog: backlog) |> schedule_verdict_backlog()

      :internal_error ->
        verdict_internal_error(socket, entry, reply, ids)

      # `dispatch_not_accepted`'s condition (`TriageDispatch` pins which reads which). The evidence
      # is the one thing only this runner holds: the row is not `accepted`, which covers an accept
      # of ours still in flight as well as one loopctl refused or superseded for good.
      :conditional ->
        if accept_outstanding?(socket, payload["dispatch_id"], payload["claim_epoch"]) do
          Logger.info(
            "loopctl has not recorded this runner's accept yet (#{reason}); resending the " <>
              "#{message_name(payload)} after #{socket.assigns.triage_verdict_retry_ms}ms",
            ids
          )

          socket
          |> assign(verdict_backlog: socket.assigns.verdict_backlog ++ [entry])
          |> schedule_verdict_backlog()
        else
          give_up_verdict(socket, entry, reason, reply, "no accept of it is outstanding", ids)
        end

      # stale_claim_epoch (1.22.0): the same bytes once more, then given up.
      :resend_once ->
        verdict_resend_once(socket, entry, reason, reply, ids)

      :permanent ->
        give_up_verdict(socket, entry, reason, reply, "nothing will change it", ids)

      :unknown ->
        give_up_verdict(
          socket,
          entry,
          reason,
          reply,
          "this build (contract #{Contract.version()}) does not handle that refusal",
          ids
        )
    end
  end

  # 1.22.0: permanent for THIS message only — the story was reclaimed twice while the verdict was
  # being recorded, and loopctl repairs a reclaim-moved epoch from the verdict itself — so the same
  # bytes go once more, and a second such refusal gives the verdict up. That it was resent is kept
  # beside the message (`PendingVerdicts.mark_resent/1`), so a restart does not resend it again.
  defp verdict_resend_once(socket, {payload, run_dir, _carried?} = entry, reason, reply, ids) do
    id = payload["dispatch_id"]

    if MapSet.member?(socket.assigns.verdict_resent, id) or PendingVerdicts.resent?(run_dir) do
      give_up_verdict(socket, entry, reason, reply, "refused so again after its one resend", ids)
    else
      Logger.warning(
        "loopctl refused the triage verdict (#{reason}); resending the same bytes once after " <>
          "#{socket.assigns.triage_verdict_retry_ms}ms",
        ids
      )

      with {:error, why} <- PendingVerdicts.mark_resent(run_dir) do
        Logger.warning(
          "could not record beside the triage verdict that it was resent (#{inspect(why)}); a " <>
            "restart may resend it once more",
          ids
        )
      end

      socket
      |> assign(
        verdict_resent: MapSet.put(socket.assigns.verdict_resent, id),
        verdict_backlog: socket.assigns.verdict_backlog ++ [entry]
      )
      |> schedule_verdict_backlog()
    end
  end

  defp refusal_reason({:error, %{"reason" => reason}}), do: reason
  defp refusal_reason(_reply), do: nil

  # Normally an error: the verdict is everything the run produced, and giving it up leaves
  # loopctl's ledger row waiting on this dispatch for as long as the claim holds.
  #
  # Not for a RESENT one whose claim has since ended — the contract's claim-ending set for the
  # event, `unknown_dispatch` as of 1.22.0. A message carried across a rejoin or restored at
  # startup can arrive after the dispatch was forgotten, and that is the expected end of a resend
  # rather than something to wake an operator for — the same demotion `dispatch_reply_refused/4`
  # makes, for the same reasons, on the same argument. `stale_claim_epoch` is not in it since
  # 1.22.0: on a verdict it means the story was reclaimed twice mid-record, which is worth a line.
  #
  # The stored copy goes either way. Every refusal that reaches here is one no resend can move, so
  # a file left behind would be re-sent by every restart from now on, each one refused again.
  @settled_meanwhile %{
    "triage_verdict" => Contract.claim_ending_errors("triage_verdict"),
    "agent_result" => Contract.claim_ending_errors("agent_result")
  }

  defp give_up_verdict(socket, {payload, run_dir, carried?}, reason, reply, why, ids) do
    name = message_name(payload)

    if carried? and reason in Map.fetch!(@settled_meanwhile, message_event(payload)) do
      Logger.info("loopctl no longer needs the resent #{name} (#{reason})", ids)
    else
      Logger.error(
        "giving up on the #{name} for dispatch #{payload["dispatch_id"]} " <>
          "(#{reason || "no reason given"}): #{why}: #{inspect(reply)}",
        ids
      )
    end

    settle_verdict(socket, payload, run_dir)
  end

  # The verdict is this run's terminal report, so it gets the terminal ceiling: loopctl promises
  # nothing about waiting out an internal_error, and the alternative to a bounded retry is a
  # message resent for ever.
  defp verdict_internal_error(socket, {payload, _run_dir, _carried?} = entry, reply, ids) do
    id = payload["dispatch_id"]
    attempts = Map.get(socket.assigns.verdict_errors, id, 0) + 1
    ceiling = socket.assigns.terminal_internal_error_attempts

    if attempts >= ceiling do
      give_up_verdict(socket, entry, "internal_error", reply, "#{attempts} attempts", ids)
    else
      Logger.warning(
        "loopctl answered the #{message_name(payload)} for dispatch #{id} with internal_error " <>
          "(#{attempts} of #{ceiling}); resending",
        ids
      )

      socket
      |> assign(
        verdict_errors: Map.put(socket.assigns.verdict_errors, id, attempts),
        verdict_backlog: socket.assigns.verdict_backlog ++ [entry]
      )
      |> schedule_verdict_backlog()
    end
  end

  # Settled one way or the other: nothing is owed for this dispatch any more, so the copy kept for
  # a restart goes, and so does its error count.
  defp settle_verdict(socket, payload, run_dir) do
    PendingVerdicts.delete(run_dir)

    assign(socket,
      verdict_errors: Map.delete(socket.assigns.verdict_errors, payload["dispatch_id"]),
      verdict_resent: MapSet.delete(socket.assigns.verdict_resent, payload["dispatch_id"])
    )
  end

  defp schedule_verdict_backlog(%{assigns: %{verdict_backlog: []}} = socket), do: socket

  defp schedule_verdict_backlog(%{assigns: %{verdict_timer: timer}} = socket) when timer != nil,
    do: socket

  defp schedule_verdict_backlog(socket) do
    token = make_ref()

    timer =
      Process.send_after(
        self(),
        {:send_verdict_backlog, token},
        socket.assigns.triage_verdict_retry_ms
      )

    assign(socket, verdict_timer: {timer, token})
  end

  defp verdict_ids(payload),
    do: [dispatch_id: payload["dispatch_id"], claim_epoch: payload["claim_epoch"]]

  # `base` doubled for each try after the first, the doubling capped at 2^`exp_cap`, the result at
  # `max`.
  defp capped_backoff(base, tries, exp_cap, max),
    do: min(base * Integer.pow(2, min(tries - 1, exp_cap)), max)

  # --- Trace shipping (TraceShip decides, this process pushes) ---

  # A poll tick re-reads the run directories; a tick after a reply works from the runs found
  # then, so shipping a long trace at the contract's 50ms pace does not rescan every run's
  # state (and spawn `ps` for each live one) twenty times a second.
  defp schedule_trace(socket, ms, refresh? \\ false)

  defp schedule_trace(%{assigns: %{trace_timer: timer}} = socket, _ms, _refresh?)
       when timer != nil,
       do: socket

  defp schedule_trace(socket, ms, refresh?) do
    token = make_ref()
    timer = Process.send_after(self(), {:trace_tick, token, refresh?}, ms)
    assign(socket, trace_timer: {timer, token})
  end

  defp poll_trace(socket), do: schedule_trace(socket, socket.assigns.trace_poll_ms, true)

  # The first run with something to do gets one push; a run finished and fully acknowledged is
  # settled on the way. With nothing to do, look again after the poll.
  defp trace_step(%{assigns: %{trace_push: push}} = socket, _refresh?) when push != nil,
    do: socket

  defp trace_step(socket, refresh?) do
    now = now_ms()
    socket = refresh_runs(socket, refresh?, now)

    live =
      Enum.reject(
        socket.assigns.trace_runs,
        &(settled_here?(socket, &1) or backed_off?(socket, &1, now))
      )

    {action, socket} =
      Enum.reduce_while(live, {nil, socket}, fn run, {_, socket} ->
        case trace_action(run, socket) do
          {:skip, socket} -> {:cont, {nil, socket}}
          {action, socket} -> {:halt, {action, socket}}
        end
      end)

    case action do
      nil ->
        poll_trace(socket)

      {:cursor, run} ->
        socket
        |> take_turn(run)
        |> push_trace(run, :cursor, "trace_cursor", %{"run_id" => run.run_id}, nil)

      {:batch, run, payload, next} ->
        socket |> take_turn(run) |> push_trace(run, :batch, "trace", payload, next)
    end
  end

  # Settled this session: given up for good, or done while the trace is still the size it was
  # then. A done trace that has grown (the reaper appends to it) ships again.
  defp settled_here?(socket, run) do
    case socket.assigns.trace_settled[run.run_id] do
      nil -> false
      :abandoned -> true
      {:done, bytes} -> TraceShip.trace_bytes(run) <= bytes
    end
  end

  defp trace_action(run, socket) do
    a = socket.assigns

    case Map.fetch(a.trace_positions, run.run_id) do
      :error ->
        {{:cursor, run}, socket}

      {:ok, position} ->
        opts = [
          max_events: batch_cap(a.trace_max_events, run, position.acked),
          omit_seqs: seqs_for(a.trace_omit, run),
          stub_seqs: seqs_for(a.trace_stub, run)
        ]

        case TraceShip.next_batch(run, position, opts) do
          {:ok, payload, next} ->
            {{:batch, run, payload, next}, socket}

          {:none, idle} ->
            {:skip, socket |> put_position(run, idle) |> settle_if_shipped(run, idle.acked)}

          {:error, errors} ->
            {:skip, give_up(socket, run, "local_invalid_payload", errors)}
        end
    end
  end

  defp seqs_for(set, run), do: for({run_id, seq} <- set, run_id == run.run_id, do: seq)

  # Rescanned on a poll, and at least once a poll interval even while a long backlog ships,
  # so a run that starts meanwhile is not left waiting for the backlog to finish.
  defp refresh_runs(%{assigns: a} = socket, refresh?, now) do
    stale? = a.trace_refreshed_ms == nil or now - a.trace_refreshed_ms >= a.trace_poll_ms

    if refresh? or a.trace_runs == nil or stale?,
      do:
        assign(socket, trace_runs: a.trace_find_runs.(a.config.runs_dir), trace_refreshed_ms: now),
      else: socket
  end

  # The monotonic clock may be negative, so no backoff is the absence of an entry, never 0.
  defp backed_off?(socket, run, now) do
    case Map.fetch(socket.assigns.trace_backoff, run.run_id) do
      {:ok, until} -> until > now
      :error -> false
    end
  end

  # The run that just got a push goes to the back, so every run with work takes turns.
  defp take_turn(socket, run) do
    {mine, others} = Enum.split_with(socket.assigns.trace_runs, &(&1.run_id == run.run_id))
    assign(socket, trace_runs: others ++ mine)
  end

  # This run waits a poll interval; the others are tried at the contract's pace meanwhile.
  defp back_off(socket, run) do
    until = now_ms() + socket.assigns.trace_poll_ms

    socket
    |> assign(trace_backoff: Map.put(socket.assigns.trace_backoff, run.run_id, until))
    |> schedule_trace(TraceShip.min_interval_ms("trace"))
  end

  # A narrowed batch size holds only until the refused range is acknowledged.
  defp batch_cap(caps, run, acked) do
    case caps[run.run_id] do
      {max, until} when acked < until -> max
      _ -> TraceShip.max_events()
    end
  end

  defp narrow(socket, run, max, until),
    do:
      assign(socket,
        trace_max_events: Map.put(socket.assigns.trace_max_events, run.run_id, {max, until})
      )

  # A run still in flight is not finished whatever it has shipped: skip the tail read for it.
  defp settle_if_shipped(%{} = socket, %{finished?: false}, _acked), do: socket

  defp settle_if_shipped(socket, run, acked) do
    {trace_bytes, last} = TraceShip.last_seq(run)

    if acked >= last do
      case TraceShip.mark_done(run, acked, trace_bytes) do
        :ok ->
          Logger.info("trace shipped in full through seq #{acked}", trace_ids(run))

        {:error, reason} ->
          Logger.warning(
            "trace shipped in full through seq #{acked}, but recording it failed " <>
              "(#{inspect(reason)}); it will be asked about again after a restart",
            trace_ids(run)
          )
      end

      socket
      |> forget_superseded(run.dispatch_id)
      |> assign(
        trace_settled: Map.put(socket.assigns.trace_settled, run.run_id, {:done, trace_bytes})
      )
    else
      socket
    end
  end

  defp give_up(socket, run, reason, detail) do
    Logger.warning(
      "loopctl will not take this run's trace (#{reason}): #{inspect(detail)}; " <>
        "no longer shipping it",
      trace_ids(run)
    )

    with {:error, error} <- TraceShip.mark_abandoned(run, reason) do
      Logger.warning(
        "recording that the trace was given up failed (#{inspect(error)}); " <>
          "it is skipped until a restart",
        trace_ids(run)
      )
    end

    socket
    |> forget_superseded(run.dispatch_id)
    |> assign(trace_settled: Map.put(socket.assigns.trace_settled, run.run_id, :abandoned))
  end

  # Nothing else removes an entry — unlike `started_dispatches`, this map is never rebuilt from
  # disk, so on a long-lived connection across many reclaims it would only grow. A settled trace
  # is the last thing that asks about it.
  defp forget_superseded(socket, dispatch_id) do
    seen = Map.delete(socket.assigns.superseded_dispatches, dispatch_id)
    assign(socket, superseded_dispatches: seen)
  end

  @doc """
  `Slipstream.push/4`, or a deliberate restart of Control when the connection is gone.

  A push is a `GenServer.call` to the connection process. Two outcomes mean that process is
  gone, or no longer answering, while Control still believes it is joined:

    * the call EXITS: the process stopped mid-call (loopctl closing the socket for a deploy,
      14:02:06 on 2026-09-14) or did not answer in time;
    * it returns `{:error, :not_connected}`: the process died before the call, without a
      disconnect reaching Control (a crash sends none).

  Neither can be handled at a push site. A dead connection sends no disconnect, so nothing would
  ever rejoin, and a timed-out push may still have been delivered. The restart is the recovery
  Control already has and the first end-to-end run proved: it reconnects, resends pending
  accepts (an identical repeat is answered `ok`), resumes every trace from loopctl's cursor and
  every run's stages from its state. What this adds is the cause, logged in one line before the
  exit.

  The exit is `{:push_exited, reason}`, deliberately NOT `{:shutdown, _}`: Control's child spec
  is `:transient`, which restarts only an abnormal exit, and `{:shutdown, _}` is how `fatal/2`
  stops Control for good. `reason` is the call's own exit reason, without the call's arguments,
  which carry the whole socket.
  """
  @spec push_event(Slipstream.Socket.t(), String.t(), String.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def push_event(socket, topic, event, payload) do
    case push_or_exit_reason(socket, topic, event, payload) do
      {:exited, reason} -> restart_on_push(event, reason)
      {:error, :not_connected} -> restart_on_push(event, :not_connected)
      result -> result
    end
  end

  # The catch stays in here: an exit raised by the restart must not be caught by it.
  defp push_or_exit_reason(socket, topic, event, payload) do
    push(socket, topic, event, payload)
  catch
    :exit, {reason, {GenServer, :call, _args}} -> {:exited, reason}
    :exit, reason -> {:exited, reason}
  end

  defp restart_on_push(event, reason) do
    Logger.warning("#{event} push failed (#{inspect(reason)}); restarting the loopctl client")
    exit({:push_exited, reason})
  end

  defp push_trace(socket, run, kind, event, payload, next) do
    case push_event(socket, socket.assigns.topic, event, payload) do
      {:ok, ref} ->
        count = if kind == :batch, do: length(payload["events"]), else: 0
        first = if kind == :batch, do: hd(payload["events"])["seq"]
        push = %{ref: ref, kind: kind, run: run, next: next, count: count, first: first}
        assign(socket, trace_push: push)

      {:error, reason} ->
        Logger.warning("#{event} not sent: #{inspect(reason)}", trace_ids(run))
        poll_trace(socket)
    end
  end

  defp trace_answered(reply, socket) do
    push = socket.assigns.trace_push
    socket = assign(socket, trace_push: nil)

    case reply do
      {:ok, %{"acked_seq" => acked}} when is_integer(acked) ->
        socket
        |> assign(trace_errors: Map.delete(socket.assigns.trace_errors, push.run.run_id))
        |> trace_acked(push, acked)

      {:error, %{"reason" => _} = refusal} ->
        trace_refused(socket, push, refusal)

      other ->
        trace_unexpected(socket, push, other)
    end
  end

  defp trace_acked(socket, %{kind: :cursor, run: run}, acked) do
    Logger.info("trace cursor: loopctl holds this run through seq #{acked}", trace_ids(run))

    socket
    |> put_position(run, %{acked: acked, offset: nil})
    |> schedule_trace(TraceShip.min_interval_ms("trace_cursor"))
  end

  defp trace_acked(socket, %{kind: :batch, run: run, next: next}, acked) do
    before = socket.assigns.trace_positions[run.run_id]

    cond do
      # The batch landed exactly: resume from where its last line ends.
      acked == next.acked ->
        socket
        |> put_position(run, next)
        |> schedule_trace(TraceShip.min_interval_ms("trace"))

      # loopctl holds more than this batch reached: its acknowledgement wins, offset unknown.
      acked > next.acked ->
        socket
        |> put_position(run, %{acked: acked, offset: nil})
        |> schedule_trace(TraceShip.min_interval_ms("trace"))

      # Stored but not contiguous: resending the same batch at once would spin.
      true ->
        Logger.warning(
          "trace batch through seq #{next.acked} left the acknowledgement at #{acked} " <>
            "(was #{inspect(before && before.acked)}); retrying after the poll",
          trace_ids(run)
        )

        socket
        |> put_position(run, %{acked: acked, offset: nil})
        |> back_off(run)
    end
  end

  defp put_position(socket, run, position),
    do:
      assign(socket,
        trace_positions: Map.put(socket.assigns.trace_positions, run.run_id, position)
      )

  # Every PERMANENT refusal a trace batch can draw, read from the contract, less the two handled
  # by name below: `invalid_payload`, which narrows the batch before anything is given up, and
  # `dispatch_not_accepted`, whose permanence is conditional. Each of the rest is about the RUN's
  # binding, which every batch of the run carries unchanged, so the next batch would draw it too:
  # the run is given up at once. As of 1.22.0 that is `unknown_dispatch` and `stale_claim_epoch`,
  # which END THE CLAIM (`claim_ending_errors`), and `run_mismatch` and `claim_epoch_mismatch`,
  # which refuse only the batch — but refuse every one of them.
  @trace_errors Map.fetch!(Map.fetch!(Contract.connection(), "errors"), "trace")
  @trace_permanent Contract.permanent_errors("trace")
  @given_up Enum.filter(@trace_errors, &(&1 in @trace_permanent)) --
              ~w(invalid_payload dispatch_not_accepted)

  @doc "The trace refusals that give a run up at once."
  @spec given_up() :: [String.t()]
  def given_up, do: @given_up

  defp trace_refused(socket, _push, %{"reason" => "rate_limited"} = refusal) do
    interval = refusal_interval(refusal, TraceShip.min_interval_ms("trace"))
    schedule_trace(socket, interval)
  end

  # Every batch is checked against the contract and the byte rule before it is sent, so each of
  # these means loopctl disagrees. Each is logged as an error and narrowed until it cannot be:
  # a batch halves (or goes one event at a time), a size refusal of one event drops its data,
  # and a repeat refusal of one event ships it as a stub. Only a refused stub gives the run up.
  defp trace_refused(socket, %{run: run} = push, %{"reason" => "batch_too_large"} = refusal),
    do: narrow_or_escalate(socket, push, refusal, div(push.count, 2), "too large", run)

  defp trace_refused(
         socket,
         %{run: run},
         %{"reason" => "event_data_too_large", "seq" => seq} = refusal
       )
       when is_integer(seq) do
    if MapSet.member?(socket.assigns.trace_omit, {run.run_id, seq}) do
      escalate_event(socket, run, seq, refusal)
    else
      Logger.error(
        "loopctl refused trace event #{seq} as too large: #{inspect(refusal)}; " <>
          "shipping it without its data",
        trace_ids(run)
      )

      socket
      |> assign(trace_omit: MapSet.put(socket.assigns.trace_omit, {run.run_id, seq}))
      |> schedule_trace(TraceShip.min_interval_ms("trace"))
    end
  end

  defp trace_refused(socket, %{run: run} = push, %{"reason" => "event_data_too_large"} = refusal),
    do: narrow_or_escalate(socket, push, refusal, div(push.count, 2), "too large", run)

  defp trace_refused(socket, %{run: run} = push, %{"reason" => "invalid_payload"} = refusal),
    do: narrow_or_escalate(socket, push, refusal, 1, "invalid", run)

  defp trace_refused(socket, %{run: run} = push, %{"reason" => reason} = refusal)
       when reason in @given_up do
    socket
    |> give_up(run, reason, refusal)
    |> trace_claim_ended(push, reason)
    |> schedule_trace(TraceShip.min_interval_ms("trace"))
  end

  # dispatch_not_accepted flips only when this runner's accept dispatch_reply commits. While an
  # accept for the run's dispatch is still unacknowledged (in flight, rate-limited, or carried
  # across a rejoin) it is that reply the trace is waiting on: wait a poll and try again. With no
  # accept outstanding it is terminal: the dispatch was refused, or its accept was lost.
  defp trace_refused(socket, %{run: run}, %{"reason" => "dispatch_not_accepted"} = refusal) do
    if accept_outstanding?(socket, run.dispatch_id, run.claim_epoch) do
      Logger.info(
        "trace waits for this runner's accept of the dispatch to be recorded",
        trace_ids(run)
      )

      back_off(socket, run)
    else
      socket
      |> give_up(run, "dispatch_not_accepted", refusal)
      |> trace_run_ended(run)
      |> schedule_trace(TraceShip.min_interval_ms("trace"))
    end
  end

  # loopctl failed on its side. Retried after a poll like an unexpected reply, but only a few
  # times: then the run is given up for this session, in memory only, so a restart tries again.
  defp trace_refused(socket, %{run: run} = push, %{"reason" => "internal_error"} = refusal) do
    attempts = Map.get(socket.assigns.trace_errors, run.run_id, 0) + 1

    socket =
      assign(socket, trace_errors: Map.put(socket.assigns.trace_errors, run.run_id, attempts))

    if attempts >= socket.assigns.internal_error_attempts do
      Logger.error(
        "giving up on this run's #{push.kind} trace pushes for dispatch #{run.dispatch_id} " <>
          "after #{attempts} internal_error replies from loopctl: #{inspect(refusal)}; " <>
          "it is shipped again after a restart",
        trace_ids(run)
      )

      socket
      |> assign(
        trace_settled: Map.put(socket.assigns.trace_settled, run.run_id, :abandoned),
        trace_errors: Map.delete(socket.assigns.trace_errors, run.run_id)
      )
      |> schedule_trace(TraceShip.min_interval_ms("trace"))
    else
      Logger.warning(
        "loopctl answered a #{push.kind} trace push with internal_error " <>
          "(#{attempts} of #{socket.assigns.internal_error_attempts}); retrying after the poll",
        trace_ids(run)
      )

      back_off(socket, run)
    end
  end

  defp trace_refused(socket, push, refusal), do: trace_unexpected(socket, push, {:error, refusal})

  # A batch refused with a code that ends the claim it ran under (contract 1.22.0) ends the
  # dispatch's work and its session, not only its trace (`end_claim/5`, keyed by the run's dispatch
  # AND epoch). Looked up by the EVENT the push was, so a `trace_cursor` — which the table does not
  # key, and so ends no claim — never does.
  defp trace_claim_ended(socket, %{kind: kind, run: run}, reason) do
    event = if kind == :batch, do: "trace", else: "trace_cursor"

    if reason in Contract.claim_ending_errors(event),
      do: end_claim(socket, run.dispatch_id, run.claim_epoch, event, reason),
      else: socket
  end

  # `dispatch_not_accepted` with no accept of ours in flight ends the RUN (`end_run/5`).
  defp trace_run_ended(socket, run),
    do:
      end_run(
        socket,
        run.dispatch_id,
        run.claim_epoch,
        "trace",
        "dispatch_not_accepted, with no accept of this runner's outstanding"
      )

  # The refusal means the ledger row is not `accepted`, and only ONE of the states that covers is
  # worth retrying: `sent`, where the accept this runner pushed has not landed yet. `refused` and
  # `superseded` are final and no later accept moves them. loopctl publishes the condition as
  # `x-connection.permanent_error_conditions`; this is that condition read against the only
  # evidence this runner has.
  #
  # Two earlier versions of this guard inferred that evidence from the REPLIES pending for the
  # same dispatch_id, and both were wrong in the same expensive direction — they abandoned the
  # trace of a live run, permanently, because `TraceShip` never revisits a run it gave up on:
  #
  #   * comparing the ACCEPT's epoch to the run's can never be false, since an accept is only ever
  #     pushed at the epoch its run started from;
  #   * counting any pending REFUSAL for that dispatch as a withdrawal catches refusals that say
  #     nothing about this accept — a malformed re-delivery is refused with the `claim_epoch`
  #     echoed straight out of the payload the runner just rejected as invalid, and a policy
  #     refusal from before the run started is still queued behind the reply rate limit.
  #
  # So the claim moving is RECORDED where it is observed — `note_superseded/4`, on the one branch
  # that means it — instead of being pattern-matched out of a mailbox. There is no same-epoch case
  # to detect: after an accept, a re-dispatch at that same epoch is answered with another accept
  # (`handle_dispatch/2`), never a refusal.
  defp accept_outstanding?(socket, dispatch_id, claim_epoch) do
    a = socket.assigns

    accepted? =
      Enum.any?(Map.values(a.dispatch_replies) ++ a.reply_backlog, fn {payload, _id, _carried?} ->
        payload["dispatch_id"] == dispatch_id and payload["decision"] == "accepted"
      end)

    accepted? and Map.get(a.superseded_dispatches, dispatch_id, claim_epoch) <= claim_epoch
  end

  # `put`, and the GUARD is what makes that safe. Every entry this can store is already newer than
  # the epoch the run holds, and the predicate only asks whether ANY stored epoch exceeds it, so
  # which of two newer epochs wins cannot change an answer. Folding with `max` here — the shape
  # `started_dispatches/1` uses, and the obvious defensive move — would be strictly worse: it
  # would ALSO absorb an older epoch if the guard ever stopped rejecting one, which is exactly the
  # defect the guard exists to prevent, and it would hide it from every test that could catch it.
  defp note_superseded(socket, id, epoch, started_epoch) when epoch > started_epoch do
    seen = Map.put(socket.assigns.superseded_dispatches, id, epoch)
    Slipstream.Socket.assign(socket, superseded_dispatches: seen)
  end

  defp note_superseded(socket, _id, _epoch, _started_epoch), do: socket

  defp narrow_or_escalate(
         socket,
         %{count: count, next: next},
         refusal,
         fewer,
         what,
         run
       )
       when count > 1 do
    fewer = max(1, fewer)

    Logger.error(
      "loopctl refused a #{count}-event trace batch as #{what}: #{inspect(refusal)}; " <>
        "sending #{fewer} at a time through seq #{next.acked}",
      trace_ids(run)
    )

    socket
    |> narrow(run, fewer, next.acked)
    |> schedule_trace(TraceShip.min_interval_ms("trace"))
  end

  defp narrow_or_escalate(socket, %{first: first}, refusal, _fewer, _what, run),
    do: escalate_event(socket, run, first, refusal)

  # One event refused whole: ship it as a stub, and give up only if the stub is refused too.
  defp escalate_event(socket, run, seq, refusal) do
    if MapSet.member?(socket.assigns.trace_stub, {run.run_id, seq}) do
      socket
      |> give_up(run, refusal["reason"], refusal)
      |> schedule_trace(TraceShip.min_interval_ms("trace"))
    else
      Logger.error(
        "loopctl refused trace event #{seq} (#{refusal["reason"]}): #{inspect(refusal)}; " <>
          "shipping it as a stub",
        trace_ids(run)
      )

      socket
      |> assign(trace_stub: MapSet.put(socket.assigns.trace_stub, {run.run_id, seq}))
      |> schedule_trace(TraceShip.min_interval_ms("trace"))
    end
  end

  defp trace_unexpected(socket, %{kind: kind, run: run}, reply) do
    Logger.warning(
      "unexpected reply to a #{kind} trace push: #{inspect(reply)}; retrying after the poll",
      trace_ids(run)
    )

    back_off(socket, run)
  end

  defp trace_ids(run),
    do: [run_id: run.run_id, dispatch_id: run.dispatch_id, claim_epoch: run.claim_epoch]

  defp fresh_join_payload(socket) do
    a = socket.assigns
    measured = measure(a.config, a.measure)

    {build_join(a.config, a.capacity, {a.draining, a.accepts_dispatches}, measured, in_flight(a)),
     note_sample(socket, measured)}
  end

  # The token is re-read on every attempt, so a corrected file is picked up without a
  # restart. An unreadable one is retried a few times (a rewrite in progress), then fatal.
  defp connect_now(socket) do
    control = socket.assigns.control

    case ControlConfig.read_token(control) do
      {:ok, token} ->
        {:noreply,
         socket
         |> assign(token_failures: 0)
         |> connect!(
           uri: control.url,
           headers: [{"x-loopctl-runner-token", token}],
           rejoin_after_msec: @rejoin_backoff_ms,
           reconnect_after_msec: @reconnect_backoff_ms
         )}

      {:error, reason} ->
        failures = socket.assigns.token_failures + 1
        Logger.error("loopctl runner cannot read its token (#{failures}): #{reason}")
        socket = assign(socket, last_refusal: "token_unreadable", token_failures: failures)

        if failures >= @max_token_failures,
          do: fatal(socket, {:token_unreadable, reason}),
          else: {:noreply, schedule_reconnect(socket)}
    end
  end

  defp schedule_reconnect(socket) do
    attempt = socket.assigns.connect_attempts
    delay = Enum.at(@reconnect_backoff_ms, attempt, List.last(@reconnect_backoff_ms))
    Process.send_after(self(), :reconnect, delay)
    assign(socket, connect_attempts: attempt + 1, next_reconnect_ms: delay)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp fatal(socket, reason) do
    socket.assigns.on_fatal.(reason)
    {:stop, {:shutdown, reason}, socket}
  end

  defp schedule_status(socket) do
    socket = cancel_status(socket)
    interval = socket.assigns.control.status_interval_s * 1000
    assign(socket, status_timer: Process.send_after(self(), :status, interval))
  end

  defp cancel_status(%{assigns: %{status_timer: nil}} = socket), do: socket

  defp cancel_status(socket) do
    Process.cancel_timer(socket.assigns.status_timer)
    assign(socket, status_timer: nil)
  end
end
