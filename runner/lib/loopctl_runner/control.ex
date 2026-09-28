defmodule LoopctlRunner.Control do
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
       (`LoopctlRunner.DispatchRun`) for an `implement` dispatch, a `triage` report within the
       contract's byte cap (`LoopctlRunner.TriageDispatch`) for a `triage` one.

  Before any of these, the contract's own `RunnerDispatch` validation (1.5.0 types the story)
  refuses a malformed dispatch `other`, naming the field.

  The decision runs on untrusted input, so anything it raises is refused `other` naming only the
  exception's kind; the full error is logged locally and Control keeps running.

  An accepted dispatch is answered `accepted` and recorded as a pending start, which already counts
  in `in_flight` and against a repeat. Its run starts only when loopctl acknowledges that accept
  `ok` (a resend after a rejoin included), under the run supervisor (a `Task.Supervisor`), never
  inside this process: `LoopctlRunner.Run.execute/3` with the dispatch bound into `state.json`
  and a prompt from `LoopctlRunner.DispatchPrompt`. Any final refusal of the accept drops the
  pending start unrun, since a session started on an accept loopctl refused could not be stopped.

  The runs outlive this process, and what it would otherwise forget is on disk. On init:

    * every dispatch bound in a `state.json` (any status) or pending in `LoopctlRunner.PendingStarts`
      is treated as started, so a redelivered dispatch is answered `accepted` and starts nothing;
    * each pending start has its accept resent, and its run starts on `ok`;
    * each bound run that is over without `terminal_reported` in its `state.json` gets its terminal
      report, from the stage it recorded reaching, retried from wherever a refusal says the row is.

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
    * however the run ends, from the last stage reported -> `escalated` with edge
      `session_escalated` and a reason: exactly `DispatchRun.finished_reason/0` for a run that
      finished, otherwise its status, exit reason and any escalation text. A run whose task dies
      without saying so is reported as crashed.

  Replies: `ok` sends the next; `rate_limited` and `internal_error` retry with a backoff, the
  latter 3 times for an intermediate report (then that report is given up and the next goes) and
  8 times for the terminal one. A stream whose intermediate reports stop (`stale_stage` or another
  refusal) still sends its terminal `escalated` report, since that is what frees loopctl's slot;
  `stale_stage` on the terminal report CARRIES THE ROW it refused (contract 1.11.0), so the report
  is sent again from the `stage` it names, and never from the same stage twice. A stage no
  transition leaves is where that stops: `permanent_error_conditions` calls stale_stage permanent
  there, because the story has reached a stage no runner can report out of. Reports not yet
  acknowledged when the channel closes are resent after the rejoin, in order; a replay whose first
  copy committed is answered `ok`.

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
  still unacknowledged, which is the one case worth waiting for. A verdict loopctl had not
  recorded when the channel closed is resent after the rejoin: the message is idempotent per
  dispatch, and a byte-identical resend is answered `ok` with `replayed` true — which is logged,
  because an `ok` that recorded the verdict and an `ok` that applied nothing are otherwise the
  same answer.

  `triage` is NOT in `@kinds`, so none of this is reachable from the wire today: a triage dispatch
  is refused `kind_not_supported` before the accept path is consulted.

  ## Trace shipping

  While joined, the client ships run traces as `LoopctlRunner.TraceShip` decides: a
  `trace_cursor` for each shippable run after every join (loopctl replays nothing on a
  rejoin), then `trace` batches after the acknowledged seq, one push in flight at a time, the
  next sent no sooner than the contract's min interval after the last reply. With nothing to
  send it looks again every `:trace_poll_ms`, which is also the only time it rescans the run
  directories. Refusals are handled by reason: `rate_limited` waits; a size refusal splits the
  batch or ships the named event without its data; `invalid_payload` narrows the batch to one
  event and ships that event as a stub (all three logged as errors, since every batch is
  already checked against the contract and the byte rule); and a dispatch loopctl will no
  longer take gives the run up. A settle that cannot be written to disk is kept in memory and
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
    CheckpointStream,
    Config,
    Contract,
    ControlConfig,
    DispatchPolicy,
    DispatchRun,
    Health,
    Owner,
    PendingStarts,
    PendingVerdicts,
    PushedCommits,
    Run,
    Runs,
    RunState,
    TraceShip,
    TriageDispatch,
    TriageRun
  }

  @reconnect_backoff_ms [1_000, 2_000, 5_000, 10_000, 30_000, 60_000, 120_000]
  # The join budget is 30 per minute; this ladder never approaches it.
  @rejoin_backoff_ms [2_000, 5_000, 10_000, 30_000, 60_000]
  @fatal_reasons ~w(machine_mismatch unsupported_contract_version invalid_payload forbidden_topic unknown_topic)
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
  # The kinds this runner runs, declared on every join (`RunnerJoin.kinds`, contract 1.6.0) and
  # checked against every dispatch. ONE list, read by both: a declaration the kind check does not
  # honour is a self-contradiction loopctl suppresses for the rest of the connection, and a kind
  # check stricter than the declaration takes the machine out of that kind's work.
  # Fixed here, never from a story or the config, so nothing on the wire can widen it.
  #
  # ADDING A KIND HERE IS NOT ENOUGH TO RUN IT. The accept path below is implement-only: it
  # requires a `story` object, which the contract allows only on an implement dispatch. Declaring
  # a kind whose dispatch this runner cannot accept makes loopctl send it — the declaration
  # decides — and every one is refused as `other`, which suppresses nothing and records nothing,
  # so the machine soaks that kind for as long as it declares it. A new kind needs its payload,
  # its own contained tool set and its own accept path first; `control_test` holds that canary.
  #
  # EMPTY IS THE ONE VALUE THAT MUST NEVER SHIP. loopctl reads an empty array as no declaration
  # at all, falls back to its ledger, keeps sending `implement`, and caches the refusal
  # permanently for the life of this runner's row — the exact trap declaring exists to escape.
  # Draining is how this runner says it wants no work.
  @kinds ["implement"]

  if @kinds == [],
    do:
      raise(
        "@kinds must never be empty: loopctl reads an empty declaration as none, falls back to " <>
          "its permanent kind ledger, and this runner then refuses work it cannot recover from. " <>
          "Use draining to stop taking work."
      )

  # The refusal of a dispatch whose kind this runner does not run: a capability statement, not a
  # fault. Since 1.6.0 it is permanent only for a runner that declares nothing; this one declares,
  # so loopctl re-sends the kind on a later connection that declares it.
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

  defp build_join(%Config{control: control}, capacity, {draining?, accepts?}, measured, in_flight) do
    payload =
      %{
        "contract_version" => Contract.version(),
        "kinds" => @kinds,
        "machine" => control.machine,
        "cores" => capacity["cores"],
        "memory_mb" => capacity["memory_mb"],
        "repos" => control.repos,
        "max_sessions" => control.max_sessions,
        "in_flight" => in_flight,
        "draining" => reported_draining(draining?, accepts?)
      }
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
            # dispatch_id => claim_epoch for every dispatch this process started a run for, so
            # a repeat of one is never run twice.
            started_dispatches:
              started_dispatches(config.runs_dir, restores_pending_starts?(opts)),
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
            # dispatch_id => the stage stream (see stage_stream/1); push ref => dispatch_id.
            stage_streams: %{},
            stage_refs: %{},
            stage_retry_ms: Keyword.get(opts, :stage_retry_ms, stage_retry_ms()),
            # dispatch_id => its CheckpointStream (contract 1.20.0); push ref => dispatch_id. The
            # poll reads each stream's pushed commits; `pushed_commits` is PushedCommits.since/3,
            # replaceable so a test can hand a stream commits without a remote.
            checkpoint_streams: %{},
            checkpoint_refs: %{},
            checkpoint_timer: nil,
            checkpoint_poll_ms: Keyword.get(opts, :checkpoint_poll_ms, 5_000),
            pushed_commits: Keyword.get(opts, :pushed_commits, &PushedCommits.since/3),
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
        # verdicts loopctl never recorded, and finished runs whose terminal report it never took.
        socket =
          socket
          |> restore_pending_starts()
          |> restore_pending_verdicts()
          |> recover_terminal_reports()

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
  defp started_dispatches(runs_dir, restores_pending_starts?) do
    bound =
      for {_dir, %{"dispatch_id" => id, "claim_epoch" => epoch}} <- RunState.all(runs_dir),
          do: {id, epoch}

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
     |> resume_stages()
     |> schedule_checkpoints(0)}
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
        end),
      # The same for a checkpoint: an identical resend is answered `replayed: true`, so the head
      # in flight is sent again after the rejoin and nothing is lost with the channel.
      checkpoint_refs: %{},
      checkpoint_streams:
        Map.new(socket.assigns.checkpoint_streams, fn {id, stream} ->
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
    do: {:noreply, socket |> checkpoints_on(binding, event) |> run_message(binding, event)}

  # Every stream's pushed commits are read on one timer, whether or not the channel is joined:
  # reading is local, and what it queues goes out on the rejoin.
  def handle_info(
        {:checkpoint_tick, token},
        %{assigns: %{checkpoint_timer: {_, token}}} = socket
      ),
      do: {:noreply, socket |> assign(checkpoint_timer: nil) |> poll_checkpoints()}

  def handle_info({:checkpoint_tick, _stale_token}, socket), do: {:noreply, socket}

  def handle_info({:checkpoint_retry, id, token}, socket) do
    case socket.assigns.checkpoint_streams[id] do
      %{timer: {_timer, ^token}} = stream ->
        socket
        |> put_checkpoints(id, %{stream | timer: nil})
        |> send_next_checkpoint(id)
        |> then(&{:noreply, &1})

      _ ->
        {:noreply, socket}
    end
  end

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
          a.stage_streams |> Map.values() |> Enum.map(&length(&1.queue)) |> Enum.sum()
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

      Map.has_key?(socket.assigns.checkpoint_refs, ref) ->
        {:ok, checkpoint_answered(ref, reply, socket)}

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
    retry_ms = Map.get(reply, "min_interval_ms", 1_000)
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

      # A reply carried across a rejoin may find the question settled meanwhile: the claim moved
      # on, or the first copy was recorded after all. That is the expected end of a resend.
      {:error, %{"reason" => reason}}
      when carried? and reason in ["stale_claim_epoch", "already_replied", "unknown_dispatch"] ->
        Logger.info("loopctl no longer needs the resent dispatch_reply (#{reason})", ids)
        settle_reply(socket, payload, {:refused, reason})

      {:error, %{"reason" => reason} = refusal} ->
        # unknown_dispatch, stale_claim_epoch, already_replied: resending cannot change them.
        Logger.warning("loopctl refused the dispatch_reply (#{reason}): #{inspect(refusal)}", ids)
        settle_reply(socket, payload, {:refused, reason})

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
  @triage_verdict_retry_ms Map.fetch!(
                             Map.fetch!(
                               Map.fetch!(Contract.connection(), "limits"),
                               "triage_verdict_burst"
                             ),
                             "refill_interval_ms"
                           )

  defp triage_verdict_retry_ms, do: @triage_verdict_retry_ms

  # `verdict_refused/4`'s `:conditional` branch implements ONE condition — dispatch_not_accepted's,
  # whose evidence is an accept of ours still unacknowledged (`accept_outstanding?/3`). Pinned,
  # because `TriageDispatch` derives that set and the derivation subtracts only the EVENT's
  # permanent list, never `permanent_errors["*"]`: a vendoring that gave a "*"-permanent code a
  # condition would make `classify/1` answer `:conditional` for it, and this runner would then
  # resend the verdict on whether its accept is outstanding — evidence about an entirely different
  # question — for the life of the claim. A new condition is a branch to write, so it fails here.
  @verdict_conditional TriageDispatch.conditional()

  unless Enum.sort(@verdict_conditional) == ["dispatch_not_accepted"] do
    raise "the contract publishes conditions for #{inspect(Enum.sort(@verdict_conditional))} on a " <>
            "triage_verdict, and this module implements only dispatch_not_accepted's; give each " <>
            "new one its own branch before the vendoring lands"
  end

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
      case Contract.validate("RunnerDispatch", payload) do
        :ok ->
          Logger.info(
            "dispatch #{payload["dispatch_id"]} received " <>
              "(story #{payload["story_id"]}, #{payload["kind"]}, claim_epoch #{payload["claim_epoch"]})"
          )

          handle_dispatch(socket, payload)

        {:error, errors} ->
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

        push_dispatch_reply(socket, accepted_reply(dispatch), dispatch["story_id"])

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
      dispatches_disabled_detail: a.dispatch_refusal_detail
    }

    with :ok <- declared_kind(dispatch),
         {:accept, fields} <- a.decide.(dispatch, config, state),
         {:ok, work} <- work(dispatch, fields, a.config) do
      {:accept, work}
    end
  end

  # What this dispatch's kind is run from, checked for what the schema cannot say. Only a kind
  # `declared_kind/1` let through reaches here, and a declared kind with no clause of its own is
  # refused rather than guessed at: the note on `@kinds` says so, because a kind whose payload
  # this runner cannot read is work it would soak and never do.
  defp work(%{"kind" => "implement"} = dispatch, fields, config) do
    with {:ok, story_object} <- dispatch_story(dispatch),
         {:ok, story} <- local_story(dispatch, fields, story_object, config) do
      {:ok, %{kind: "implement", story: story}}
    end
  end

  # A triage run reads the checkout where it is, so it needs no branch and no worktree: the repo
  # the policy allowed, the report, and the budgets the policy already held to this runner's
  # ceilings. `dispatch["repo"]` is the owner/name form `TriageRun` resolves against `repos`.
  defp work(%{"kind" => "triage"} = dispatch, fields, _config) do
    with {:ok, triage} <- dispatch_triage(dispatch) do
      {:ok,
       %{
         kind: "triage",
         triage: triage,
         repo: dispatch["repo"],
         wall_clock_s: fields.wall_clock_s,
         max_turns: fields.max_turns
       }}
    end
  end

  # Reached two ways, and the wording has to be true of both: a kind this runner DECLARES and
  # cannot read (the note on `@kinds`), and a kind in a pending file that `rebuild_work/2` does not
  # re-check the declaration for. What is true either way is that there is no accept path.
  defp work(%{"kind" => kind}, _fields, _config),
    do: {:refuse, "other", "this runner has no accept path for a dispatch of kind #{kind}"}

  defp declared_kind(%{"kind" => kind}) when kind in @kinds, do: :ok
  defp declared_kind(_dispatch), do: {:refuse, @kind_refusal_reason, @kind_refusal}

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

  defp dispatch_triage(dispatch) do
    case TriageDispatch.triage_object(dispatch) do
      {:ok, triage} -> {:ok, triage}
      :none -> {:refuse, "other", "the dispatch carries no triage report"}
      {:error, detail} -> {:refuse, "other", detail}
    end
  end

  defp local_story(dispatch, fields, story_object, config) do
    case DispatchRun.story(dispatch, fields, story_object, config) do
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

  defp accepted_reply(dispatch),
    do: %{
      "dispatch_id" => dispatch["dispatch_id"],
      "claim_epoch" => dispatch["claim_epoch"],
      "decision" => "accepted"
    }

  # Accepting sends the accept and records a pending start; the run starts only once loopctl has
  # recorded the accept (settle_reply/3). A session started on an accept loopctl then refused
  # would run with no way to stop it, reporting stages and a trace nobody takes.
  defp accept_dispatch(socket, dispatch, work) do
    reply = accepted_reply(dispatch)
    :ok = Contract.validate("RunnerDispatchReply", reply)

    Logger.info(
      "dispatch #{dispatch["dispatch_id"]} accepted: #{describe_work(work)} starts once " <>
        "loopctl records it"
    )

    socket
    |> register_pending(dispatch, work)
    |> push_dispatch_reply(reply, dispatch["story_id"])
  end

  defp describe_work(%{kind: "implement", story: story}), do: "run of #{story.id}"
  defp describe_work(%{kind: "triage", triage: triage}), do: "triage of #{triage["record_id"]}"

  # The pending start is kept in memory and on disk (PendingStarts), so a restart resumes it.
  defp register_pending(socket, dispatch, work) do
    a = socket.assigns
    id = dispatch["dispatch_id"]
    binding = DispatchRun.binding(dispatch)
    target = a.name || self()
    on_stage = fn event -> notify_control(target, {:run_stage, binding, event}) end
    pending = %{dispatch: dispatch, work: work, opts: [binding: binding, on_stage: on_stage]}

    with {:error, reason} <- PendingStarts.write(a.config.runs_dir, dispatch) do
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
  defp restore_pending_starts(%{assigns: %{restores_pending_starts: false}} = socket) do
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

  defp restore_pending_starts(socket) do
    a = socket.assigns

    Enum.reduce(PendingStarts.all(a.config.runs_dir), socket, fn dispatch, socket ->
      id = dispatch["dispatch_id"]

      case rebuild_work(socket.assigns, dispatch) do
        {:ok, work} ->
          Logger.info("resending the accept of pending dispatch #{id}", dispatch_id: id)
          entry = {accepted_reply(dispatch), dispatch["story_id"], true}

          socket
          |> register_pending(dispatch, work)
          |> assign(reply_backlog: socket.assigns.reply_backlog ++ [entry])

        {:error, why} ->
          Logger.error(
            "pending dispatch #{id} no longer makes runnable work (#{why}); not started",
            dispatch_id: id
          )

          PendingStarts.delete(a.config.runs_dir, id)
          socket
      end
    end)
  end

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

      case TriageDispatch.sendable(payload) do
        {:ok, payload} ->
          Logger.info("resending the triage verdict of dispatch #{id}", dispatch_id: id)

          assign(socket,
            verdict_backlog: socket.assigns.verdict_backlog ++ [{payload, run_dir, true}]
          )

        {:error, errors} ->
          Logger.error(
            "the triage verdict recorded in #{run_dir} is not a message this runner may send " <>
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
    state = %{draining: false, in_flight: 0, free_disk_mb: fn _path -> min end}

    with {:accept, fields} <-
           DispatchPolicy.decide(dispatch, %{a.config | control: control}, state),
         {:ok, work} <- work(dispatch, fields, a.config) do
      undeclared_kind_warning(dispatch)
      {:ok, work}
    else
      # Every refusal on this path is a policy or a payload one; `work/3` turns what the object
      # validators report into the same shape, so there is nothing else to come back.
      {:refuse, reason, detail} -> {:error, "#{reason}: #{detail}"}
    end
  rescue
    exception -> {:error, inspect(exception.__struct__)}
  end

  # A bound run that is over (finished, or its owner gone) and whose terminal report loopctl never
  # acknowledged gets it now, from the stage it recorded reaching, with the full fallback chain.
  defp recover_terminal_reports(socket) do
    runs_dir = socket.assigns.config.runs_dir

    for {run_dir, %{"dispatch_id" => id, "claim_epoch" => epoch} = state} <-
          RunState.all(runs_dir),
        is_binary(id) and is_integer(epoch),
        # A triage run reports no stages, so there is no terminal stage to recover for one: its
        # report is the verdict, and a stage stream opened for it would move a story it does not
        # have. What a restart does NOT do is re-send that verdict, so a triage run whose Control
        # died between its outcome and loopctl recording it is left to loopctl's heal sweep.
        state["kind"] != "triage",
        is_nil(state["terminal_reported"]),
        not live?(state),
        reduce: socket do
      socket -> recover_terminal_report(socket, run_dir, state)
    end
  end

  # A stream already opened for the dispatch (a second run bound to it) is left alone.
  defp recover_terminal_report(socket, _run_dir, %{"dispatch_id" => id})
       when is_map_key(socket.assigns.stage_streams, id),
       do: socket

  defp recover_terminal_report(socket, run_dir, %{"dispatch_id" => id} = state) do
    status = state["status"]
    reached = state["reached"]
    Logger.info("reporting the unacknowledged end of dispatch #{id}'s run", dispatch_id: id)

    summary =
      if status in [nil, "starting", "running"],
        do: %{status: "crashed", error: "the run did not finish on a live runner"},
        else: %{status: status, reached: reached, escalations: Run.escalations(run_dir)}

    binding = Map.take(state, ["dispatch_id", "claim_epoch", "story_id"])

    socket
    |> put_stream(id, stage_stream(binding, reached || "implementing"))
    |> queue_end(id, summary)
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

      {%{work: %{kind: "implement", story: story}, dispatch: dispatch, opts: opts}, pending} ->
        run = a.run
        config = a.config

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
          stage_streams: Map.put(a.stage_streams, id, stage_stream(dispatch, "claimed"))
        )

      # A triage run opens no stage stream: the contract's stages move a STORY through its
      # lifecycle, and this dispatch has none to move. Its one report is the verdict, which the
      # run sends back as a message so that a Control which restarted under it still receives it.
      {%{work: %{kind: "triage"} = work, opts: opts}, pending} ->
        triage_run = a.triage_run
        config = a.config
        binding = Keyword.fetch!(opts, :binding)
        target = a.name || self()

        task =
          Task.Supervisor.async_nolink(a.run_supervisor, fn ->
            result =
              triage_run.(config, work.triage, work.repo,
                binding: binding,
                # Where the run keeps its state, reported the moment it exists rather than at the
                # end: a task killed from outside never reaches the end, and its state.json is
                # then the only thing that can be closed — by whoever knows where it is.
                on_start: fn run -> notify_control(target, {:triage_started, binding, run}) end,
                # The run directory travels with the outcome: it is where the message this
                # process is about to build is kept until loopctl records it, and a Control that
                # did not start this run has no other way to learn it.
                wall_clock_s: work.wall_clock_s,
                max_turns: work.max_turns
              )

            notify_control(
              target,
              {:triage_outcome, binding, Map.take(result, [:run_id, :run_dir]), result.outcome}
            )

            result
          end)

        Logger.info(
          "dispatch #{id} recorded as accepted: triage of #{work.triage["record_id"]} started " <>
            "in #{work.repo}",
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
              kind: "triage",
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
  # its attempts, whether INTERMEDIATE reports have stopped, whether the run's end is queued, and
  # the stages the terminal report was already refused from as stale.
  #
  # `stopped` never stops the terminal report. The terminal `escalated` is what gives loopctl's
  # slot back, so it is sent on every stream however its intermediate reports fared.
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
      terminal_tried: []
    }

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

          put_stream(socket, id, stage_stream(binding, from))

        _ ->
          socket
      end

    run_stage(socket, id, event)
  end

  defp run_message(socket, _binding, _event), do: socket

  defp event_from({:worktree, _}), do: "claimed"
  defp event_from({:implementing, _}), do: "worktree"
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

  defp run_stage(socket, id, {:finished, summary}), do: queue_end(socket, id, summary)

  defp run_stage(socket, _id, _event), do: socket

  # Escalated is the terminal for this deliberate merge-nothing first run ONLY, and must not be
  # generalised: once the loop merges, a story goes merged -> deployed.
  defp queue_end(socket, id, summary) do
    case socket.assigns.stage_streams[id] do
      %{ended: false} = stream ->
        socket
        |> put_stream(id, %{stream | ended: true})
        |> queue_stage(id, "escalated",
          edge: "session_escalated",
          reason: DispatchRun.end_reason(summary)
        )

      _ ->
        socket
    end
  end

  defp queue_stage(socket, id, to, opts \\ []) do
    case socket.assigns.stage_streams[id] do
      nil ->
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
      %{queue: [payload | _], push: nil, timer: nil} = stream ->
        if a.joined,
          do: push_stage(socket, id, stream, payload),
          else: socket

      _ ->
        socket
    end
  end

  defp push_stage(socket, id, stream, payload) do
    case push_event(socket, socket.assigns.topic, "stage", payload) do
      {:ok, ref} ->
        Logger.info(
          "stage report sent: #{payload["from"]} -> #{payload["to"]}",
          stage_ids(stream)
        )

        socket
        |> put_stream(id, %{stream | push: ref})
        |> assign(stage_refs: Map.put(socket.assigns.stage_refs, ref, id))

      # Not joined at this instant: the rejoin resumes every stream.
      {:error, reason} ->
        Logger.info("stage report held until the channel rejoins: #{inspect(reason)}")
        socket
    end
  end

  defp stage_answered(ref, reply, socket) do
    {id, refs} = Map.pop(socket.assigns.stage_refs, ref)
    socket = assign(socket, stage_refs: refs)

    case socket.assigns.stage_streams[id] do
      %{push: ^ref, queue: [_ | _]} = stream ->
        stream = %{stream | push: nil}

        stage_reply(socket, id, stream, reply)

      # A reply to a push from before the last rejoin.
      _ ->
        socket
    end
  end

  defp stage_reply(socket, id, %{queue: [payload | _]} = stream, reply) do
    case reply do
      {:error, %{"reason" => "rate_limited"}} ->
        retry_stage(socket, id, %{stream | rate_limited: stream.rate_limited + 1})

      {:error, %{"reason" => "internal_error"} = refusal} ->
        stage_internal_error(socket, id, stream, payload, refusal)

      {:error, %{"reason" => "stale_stage"} = refusal} ->
        stale_stage(socket, id, stream, payload, refusal)

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

    if terminal?(payload), do: mark_terminal_reported(socket, stream)
    advance(socket, id, stream)
  end

  defp terminal?(payload), do: payload["to"] == "escalated"

  # Recorded beside the run, so a later Control does not report this end again: true once loopctl
  # acknowledged it, "refused" once it refused it from every stage (a later Control would only be
  # refused again, and loopctl's heal sweep does that accounting).
  defp mark_terminal_reported(socket, stream, value \\ true)

  defp mark_terminal_reported(socket, %{dispatch: %{"dispatch_id" => id} = dispatch}, value) do
    epoch = dispatch["claim_epoch"]

    for {run_dir, %{"dispatch_id" => ^id, "claim_epoch" => ^epoch}} <-
          RunState.all(socket.assigns.config.runs_dir) do
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

      mark_terminal_reported(socket, stream, "refused")
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

  defp stale_stage(socket, id, stream, payload, refusal) do
    if terminal?(payload) do
      retry_terminal(socket, id, stream, payload, refusal)
    else
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

        advance(socket, id, stream)

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
  defp retry_stage(socket, id, stream) do
    tries = stream.rate_limited + stream.internal_errors

    delay =
      min(
        socket.assigns.stage_retry_ms * Integer.pow(2, min(tries - 1, 10)),
        @max_stage_backoff_ms
      )

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
      %{ended: true, push: nil, queue: []} ->
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

  # --- Checkpoints (contract 1.20.0: each commit an implement session pushed) ---

  # A stream opens when the run's worktree exists, which is when it has a branch to push. A run
  # this Control did not start (its predecessor crashed) gets one on its end instead, so its pushed
  # commits are still reported, all at once, before the stream closes. The run's end also takes
  # one last read: a session's final push lands moments before it exits.
  defp checkpoints_on(socket, %{"dispatch_id" => id} = binding, {:worktree, _})
       when is_binary(id),
       do: open_checkpoints(socket, id, binding)

  defp checkpoints_on(socket, %{"dispatch_id" => id} = binding, {:finished, _})
       when is_binary(id) do
    socket = open_checkpoints(socket, id, binding)

    case socket.assigns.checkpoint_streams[id] do
      nil ->
        socket

      stream ->
        socket
        |> put_checkpoints(id, %{read_pushed(stream) | ended: true})
        |> send_next_checkpoint(id)
        |> drop_checkpoints_if_done(id)
    end
  end

  defp checkpoints_on(socket, _binding, _event), do: socket

  defp open_checkpoints(socket, id, binding) do
    if Map.has_key?(socket.assigns.checkpoint_streams, id) do
      socket
    else
      stream = CheckpointStream.new(binding, run_story(socket, id), socket.assigns.pushed_commits)

      if CheckpointStream.readable?(stream) do
        socket |> put_checkpoints(id, stream) |> schedule_checkpoints(0)
      else
        Logger.warning(
          "dispatch #{id}'s pushed commits cannot be reported: its story.json was not found",
          dispatch_id: id
        )

        socket
      end
    end
  end

  # The story the run is working, from its run directory: known from the run's own `started`
  # message when this Control started it, and found by dispatch in the run state otherwise.
  defp run_story(socket, id) do
    run_dir =
      get_in(socket.assigns.runs, [id, :run_dir]) ||
        Enum.find_value(RunState.all(socket.assigns.config.runs_dir), fn
          {dir, %{"dispatch_id" => ^id}} -> dir
          _ -> nil
        end)

    with dir when is_binary(dir) <- run_dir,
         {:ok, body} <- File.read(Path.join(dir, "story.json")),
         {:ok, story} when is_map(story) <- JSON.decode(body) do
      story
    else
      _ -> %{}
    end
  end

  defp put_checkpoints(socket, id, stream),
    do: assign(socket, checkpoint_streams: Map.put(socket.assigns.checkpoint_streams, id, stream))

  defp schedule_checkpoints(%{assigns: %{checkpoint_timer: {_, _}}} = socket, _ms), do: socket

  defp schedule_checkpoints(socket, ms) do
    if socket.assigns.checkpoint_streams == %{} do
      socket
    else
      token = make_ref()
      timer = Process.send_after(self(), {:checkpoint_tick, token}, ms)
      assign(socket, checkpoint_timer: {timer, token})
    end
  end

  defp poll_checkpoints(socket) do
    socket.assigns.checkpoint_streams
    |> Map.keys()
    |> Enum.reduce(socket, fn id, socket ->
      stream = socket.assigns.checkpoint_streams[id]

      socket
      |> put_checkpoints(id, read_pushed(stream))
      |> send_next_checkpoint(id)
    end)
    |> schedule_checkpoints(socket.assigns.checkpoint_poll_ms)
  end

  # A read that fails is said once per distinct failure, not every poll, and queues nothing.
  defp read_pushed(%{stopped: true} = stream), do: stream

  defp read_pushed(stream) do
    case stream.reader.(stream.repo_path, stream.base, stream.branch) do
      {:ok, commits} ->
        %{CheckpointStream.enqueue(stream, commits) | read_error: nil}

      {:error, why} ->
        if why != stream.read_error,
          do:
            Logger.warning(
              "could not read the commits dispatch #{stream.dispatch["dispatch_id"]} pushed: #{why}",
              dispatch_id: stream.dispatch["dispatch_id"]
            )

        %{stream | read_error: why}
    end
  end

  defp send_next_checkpoint(socket, id) do
    a = socket.assigns

    case a.checkpoint_streams[id] do
      %{queue: [_ | _], push: nil, timer: nil} = stream when a.joined ->
        push_checkpoint(socket, id, stream)

      _ ->
        socket
    end
  end

  defp push_checkpoint(socket, id, stream) do
    case CheckpointStream.payload(stream) do
      {:ok, payload} ->
        case push_event(socket, socket.assigns.topic, "checkpoint", payload) do
          {:ok, ref} ->
            socket
            |> put_checkpoints(id, %{stream | push: ref})
            |> assign(checkpoint_refs: Map.put(socket.assigns.checkpoint_refs, ref, id))

          # Not joined at this instant: the rejoin sends it.
          {:error, reason} ->
            Logger.info("checkpoint held until the channel rejoins: #{inspect(reason)}")
            socket
        end

      {:error, errors} ->
        Logger.error(
          "checkpoint #{hd(stream.queue).commit_sha} not sent: it would fail the contract: " <>
            inspect(errors),
          dispatch_id: id
        )

        socket
        |> put_checkpoints(id, %{stream | queue: tl(stream.queue)})
        |> send_next_checkpoint(id)
    end
  end

  defp checkpoint_answered(ref, reply, socket) do
    {id, refs} = Map.pop(socket.assigns.checkpoint_refs, ref)
    socket = assign(socket, checkpoint_refs: refs)

    case socket.assigns.checkpoint_streams[id] do
      %{push: ^ref, queue: [head | _]} = stream ->
        {outcome, stream} = CheckpointStream.settle(stream, reply)
        ids = [dispatch_id: id, commit_sha: head.commit_sha]

        case outcome do
          :recorded ->
            Logger.info("loopctl recorded the checkpoint #{head.commit_sha}", ids)
            socket |> put_checkpoints(id, stream) |> send_next_checkpoint(id)

          :stopped ->
            Logger.warning(
              "loopctl refused checkpoint #{head.commit_sha} for good (#{inspect(reply)}); " <>
                "no further checkpoints are sent for this claim",
              ids
            )

            put_checkpoints(socket, id, stream)

          {:dropped, reason} ->
            Logger.error(
              "loopctl refused checkpoint #{head.commit_sha} (#{reason}); resending the same " <>
                "commit cannot change that, so the next one goes",
              ids
            )

            socket |> put_checkpoints(id, stream) |> send_next_checkpoint(id)

          {:retry, ms} ->
            retry_checkpoint(socket, id, stream, ms)
        end
        |> drop_checkpoints_if_done(id)

      # A reply to a push from before the last rejoin.
      _ ->
        socket
    end
  end

  # loopctl's own interval when it named one; otherwise doubling from the stage retry, capped.
  defp retry_checkpoint(socket, id, stream, ms) do
    delay =
      ms ||
        min(
          socket.assigns.stage_retry_ms * Integer.pow(2, min(stream.retries - 1, 10)),
          @max_stage_backoff_ms
        )

    token = make_ref()
    timer = Process.send_after(self(), {:checkpoint_retry, id, token}, delay)
    put_checkpoints(socket, id, %{stream | timer: {timer, token}})
  end

  # A stream is forgotten once its run has ended and nothing is left to send or stopped it.
  defp drop_checkpoints_if_done(socket, id) do
    case socket.assigns.checkpoint_streams[id] do
      %{ended: true, push: nil} = stream when stream.queue == [] or stream.stopped ->
        assign(socket, checkpoint_streams: Map.delete(socket.assigns.checkpoint_streams, id))

      _ ->
        socket
    end
  end

  # The task is over. A run that ended without reporting it (killed, or an exit rather than a
  # raise) is reported as crashed, and a state.json it left in flight is closed.
  defp run_ended(socket, ref, reason) do
    a = socket.assigns
    {id, run_refs} = Map.pop(a.run_refs, ref)
    {run, runs} = Map.pop(a.runs, id)
    socket = assign(socket, run_refs: run_refs, runs: runs)

    case run do
      %{kind: "triage"} -> triage_run_ended(socket, id, run, reason)
      _ -> implement_run_ended(socket, id, run, reason)
    end
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
  defp triage_run_ended(socket, id, %{binding: binding, run_dir: run_dir}, reason) do
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

    case recorded_message(run_dir) do
      {:ok, payload} ->
        Logger.info(
          "the run had already recorded its outcome; sending that, not an account of its death",
          verdict_ids(payload)
        )

        push_verdict(socket, payload, run_dir)

      :none ->
        triage_outcome(socket, binding, run_dir, died_with(run_dir, detail))
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
    case TriageDispatch.sendable(payload) do
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
  defp died_with(nil, detail), do: {:incomplete, "no_verdict_written", detail}

  defp died_with(run_dir, detail) do
    case TriageRun.outcome_on_disk(run_dir) do
      {:verdict, _} = verdict -> verdict
      {:incomplete, "verdict_invalid", _} = invalid -> invalid
      _ -> {:incomplete, "no_verdict_written", detail}
    end
  end

  defp implement_run_ended(socket, id, run, reason) do
    socket =
      if reason == :normal do
        socket
      else
        Logger.error("the run of dispatch #{id} died: #{inspect(reason)}", dispatch_id: id)
        close_crashed_state(run.run_dir)

        queue_end(socket, id, %{
          status: "crashed",
          error: "the run's process died: #{inspect(reason, limit: 5)}"
        })
      end

    socket
    |> queue_end(id, %{status: "crashed", error: "the run ended without reporting its end"})
    |> drop_stream_if_done(id)
  end

  defp close_crashed_state(nil), do: :ok

  defp close_crashed_state(run_dir) do
    case RunState.read(run_dir) do
      {:ok, %{"status" => status}} when status in ["starting", "running"] ->
        RunState.update(run_dir, %{status: "crashed"})

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
  defp sendable_message(binding, outcome) do
    case TriageDispatch.verdict_message(binding, outcome) do
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

  # A run this process did not start (its Control was replaced while it ran) has nothing here to
  # record against, and needs nothing: whatever ends it will report its own outcome.
  defp triage_started(socket, id, %{run_id: run_id, run_dir: run_dir}) do
    case socket.assigns.runs[id] do
      %{kind: "triage"} = run ->
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
      %{kind: "triage"} = run ->
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
      "the triage verdict is sent but not recorded on disk: its run has no directory; a restart " <>
        "before loopctl records it would lose it",
      verdict_ids(payload)
    )

    socket
  end

  defp store_verdict(socket, run_dir, payload) do
    with {:error, reason} <- PendingVerdicts.write(run_dir, payload) do
      Logger.error(
        "could not record the triage verdict in #{run_dir} (#{inspect(reason)}); a restart " <>
          "before loopctl records it would lose it",
        verdict_ids(payload)
      )
    end

    socket
  end

  defp push_verdict(socket, payload, run_dir, carried? \\ false) do
    case push_event(socket, socket.assigns.topic, "triage_verdict", payload) do
      {:ok, ref} ->
        Logger.info("triage_verdict sent", verdict_ids(payload))

        assign(socket,
          verdict_pushes:
            Map.put(socket.assigns.verdict_pushes, ref, {payload, run_dir, carried?})
        )

      # Not joined at this instant: kept, and sent once the channel is back.
      {:error, reason} ->
        Logger.warning(
          "triage_verdict held until the channel rejoins: #{inspect(reason)}",
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
      note_recorded(reply, ids)
      settle_verdict(socket, payload, run_dir)
    else
      verdict_refused(socket, reply, {payload, run_dir, carried?}, ids)
    end
  end

  # `replayed` is the whole reason the ack has a body: an `ok` that recorded this verdict and an
  # `ok` that found it already recorded and applied nothing are the same reply otherwise, and
  # after a resend the difference is what says whether the first copy landed.
  defp note_recorded({:ok, body}, ids) when is_map(body) do
    case Contract.validate("RunnerTriageVerdictAck", body) do
      :ok ->
        Logger.info(
          "loopctl recorded the triage verdict at #{body["recorded_at"]} " <>
            "(replayed: #{body["replayed"]})",
          ids
        )

      {:error, errors} ->
        Logger.warning(
          "loopctl acknowledged the triage verdict with an ack this build cannot read " <>
            "(#{inspect(errors)}); whether it was recorded now or replayed is unknown",
          ids
        )
    end
  end

  defp note_recorded(_reply, ids),
    do:
      Logger.warning(
        "loopctl acknowledged the triage verdict with no ack body; whether it was recorded now " <>
          "or replayed is unknown",
        ids
      )

  defp verdict_refused(socket, reply, {payload, _run_dir, _carried?} = entry, ids) do
    reason = refusal_reason(reply)

    case TriageDispatch.classify(reason) do
      :rate_limited ->
        backlog = socket.assigns.verdict_backlog ++ [entry]

        Logger.info(
          "loopctl rate-limited a triage_verdict; #{length(backlog)} in the backlog, sent one " <>
            "every #{socket.assigns.triage_verdict_retry_ms}ms",
          ids
        )

        socket |> assign(verdict_backlog: backlog) |> schedule_verdict_backlog()

      :internal_error ->
        verdict_internal_error(socket, entry, reply, ids)

      # `dispatch_not_accepted`'s condition, and ONLY it — see `@verdict_conditional`. The evidence
      # is the one thing only this runner holds: the row is not `accepted`, which covers an accept
      # of ours still in flight as well as one loopctl refused or superseded for good.
      :conditional ->
        if accept_outstanding?(socket, payload["dispatch_id"], payload["claim_epoch"]) do
          Logger.info(
            "loopctl has not recorded this runner's accept yet (#{reason}); resending the " <>
              "triage verdict after #{socket.assigns.triage_verdict_retry_ms}ms",
            ids
          )

          socket
          |> assign(verdict_backlog: socket.assigns.verdict_backlog ++ [entry])
          |> schedule_verdict_backlog()
        else
          give_up_verdict(socket, entry, reason, reply, "no accept of it is outstanding", ids)
        end

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

  defp refusal_reason({:error, %{"reason" => reason}}), do: reason
  defp refusal_reason(_reply), do: nil

  # Normally an error: the verdict is everything the run produced, and giving it up leaves
  # loopctl's ledger row waiting on this dispatch for as long as the claim holds.
  #
  # Not for a RESENT one whose dispatch has since gone away. A message carried across a rejoin or
  # restored at startup can arrive after the claim moved on or the dispatch was forgotten, and
  # that is the expected end of a resend rather than something to wake an operator for — the same
  # demotion `dispatch_reply_refused/4` makes, for the same reasons, on the same argument.
  #
  # The stored copy goes either way. Every refusal that reaches here is one no resend can move, so
  # a file left behind would be re-sent by every restart from now on, each one refused again.
  @settled_meanwhile ~w(unknown_dispatch stale_claim_epoch)

  defp give_up_verdict(socket, {payload, run_dir, carried?}, reason, reply, why, ids) do
    if carried? and reason in @settled_meanwhile do
      Logger.info("loopctl no longer needs the resent triage verdict (#{reason})", ids)
    else
      Logger.error(
        "giving up on the triage verdict for dispatch #{payload["dispatch_id"]} " <>
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
        "loopctl answered the triage verdict for dispatch #{id} with internal_error " <>
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
      verdict_errors: Map.delete(socket.assigns.verdict_errors, payload["dispatch_id"])
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

  # loopctl keeps no refusal state; what each of these means is fixed by its ledger fence, which
  # runs story epoch, batch epoch, accepted, run binding in that order. unknown_dispatch means
  # the row is not this runner's and never will be (the row is written before a dispatch is
  # broadcast); stale_claim_epoch means the claim moved on; run_mismatch means the run is bound
  # elsewhere. None of them changes, so each gives the run up at once.
  @given_up ~w(unknown_dispatch stale_claim_epoch run_mismatch)

  @doc "The trace refusals that give a run up at once."
  @spec given_up() :: [String.t()]
  def given_up, do: @given_up

  defp trace_refused(socket, _push, %{"reason" => "rate_limited"} = refusal) do
    interval = Map.get(refusal, "min_interval_ms", TraceShip.min_interval_ms("trace"))
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

  defp trace_refused(socket, %{run: run}, %{"reason" => reason} = refusal)
       when reason in @given_up do
    socket |> give_up(run, reason, refusal) |> schedule_trace(TraceShip.min_interval_ms("trace"))
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
