defmodule LoopctlWeb.RunnerChannel do
  @moduledoc """
  The runner channel: a runner joins its own topic, `"runner:<runner_id>"`, to enter its
  tenant's pool (issue #801). A join on any other runner's topic is refused.

  The socket authenticated the credential at connect (`LoopctlWeb.RunnerSocket`). Every
  join re-reads `Runners.authorized?/2`, validates the payload against `Loopctl.ApiSpec.RunnerContract.RunnerJoin`,
  refuses a declared machine name that is not the enrolled one, and tracks the runner
  in `Loopctl.Runners.Presence` under the tenant-scoped `Runners.pool_topic/1`.

  The runner never receives the pool: it is not subscribed to the presence topic, so
  one machine learns nothing about another's topology.

  ## Leaving the pool

  The Presence entry is tracked against this process, so it is removed whenever the
  process exits — the runner is killed, its socket drops, or this channel stops. There
  is no sweeper. Revocation stops it two ways:

  - `Runners.revoke_runner/3` broadcasts on `Runners.revocation_topic/1`; this channel
    disconnects the socket at once.
  - every `@recheck_interval_ms` it re-reads `Runners.authorized?/2`, which catches a
    key revoked through `DELETE /api/v1/api_keys/:id`, an expired key and a suspended
    tenant. That is the upper bound on how long such a revocation takes to bite.

  ## Dispatch

  The channel subscribes to `Runners.dispatch_topic/1` only once its Presence entry is
  tracked, and pushes each dispatch addressed to it as the `"dispatch"` event on its own
  topic. `Runners.dispatch/3` is the only sender and has already validated the payload and
  refused a halted tenant, an unauthorized runner, and a runner with zero or several live
  sockets. Immediately before the push the channel checks again, and drops the dispatch
  (logged) unless its own Presence ref is the only live meta for the runner AND the custody
  halt, re-read fresh, is clear. Those are the reads nearest the push; they close the window
  between the sender's reads and delivery. Across nodes Presence is eventually consistent, so
  exactly-once is held by `claim_epoch` (#803), not here. A runner cannot send `"dispatch"`
  itself; inbound it is an unknown event.

  ## Status

  `"status"` updates the runner's Presence meta (`RunnerStatus`). Updates closer
  together than `@min_status_interval_ms` are refused with `rate_limited`, because each
  one is a Presence diff broadcast across the PubSub.

  ## Dispatch replies and trace (contract 1.1.0, #803)

  `"dispatch_reply"` (`RunnerDispatchReply`), `"trace"` (`RunnerTraceBatch`) and
  `"trace_cursor"` (`RunnerTraceCursor`) are validated against the contract and applied by
  `Loopctl.Runners.DispatchLedger`, always as THIS socket's runner in THIS socket's tenant —
  a runner can answer, and ship a trace for, only a dispatch it was sent. Each is rate
  limited, refused with `rate_limited` and a retry interval, because each one is a database
  transaction: `trace` and `trace_cursor` by their own floors
  (`RunnerContract.min_interval_ms/1`), `dispatch_reply` by a small bucket
  (`RunnerContract.dispatch_reply_burst/0`). Only a valid message spends its limit.

  None of them checks the custody halt. The halt guards control-to-runner pushes, which
  start custody progress; these record what a runner already did, and a halted tenant must
  still be able to record that.

  ## Stage reporting (contract 1.4.0, #803)

  `"stage"` (`RunnerStageReport`) is the transition a runner's session made. It is cast by
  the contract, metered by its own bucket (`RunnerContract.stage_burst/0` — a bucket rather
  than a floor because a machine at `max_sessions: 2` walks two stories at once and a
  rejoining runner ships everything it buffered), and applied by
  `Loopctl.Delivery.RunnerStages.apply/3`, which resolves the runner's ACCEPTED dispatch to
  its story and then calls `Loopctl.Delivery.Stages.advance/4`. That function is the only
  writer of `story_stages`; the channel opens no second path to it, and the story is never
  taken off the wire.

  The reply is the row as it now stands (`stage`, `claim_epoch`, `lock_version`, `attempts`
  and the `effects` it holds), including on a REPLAY — a message whose first copy committed is
  answered `ok` rather than `stale_stage`, so a re-send after a rolling deploy costs nothing
  and tells the runner where the story is. A replay naming a DIFFERENT identity than the one
  recorded is `effect_conflict`, and the ack's `effects` is what it reconciles against. Arriving at a terminal stage also gives the session's runner slot back, in
  the transition's own transaction (`DispatchLedger.release_slot_in/4`).

  Like the three above it, `stage` does not check the custody halt: it records a transition
  a session already made.

  ## Session end (contract 1.16.0, US-44.3)

  `"session_ended"` (`RunnerSessionEnded`) is why the session under an implement dispatch
  stopped. Cast by the contract, metered by its own bucket (`RunnerContract.session_ended_burst/0`),
  and applied by `Loopctl.Delivery.RunnerStages.end_session/3`, which records it once on the
  dispatch's ledger row and decides from the reason what the story does — this channel opens
  no path to `story_stages` or to the claim of its own. The reply is the stage row as it then
  stands plus `replayed`, and an identical resend is answered `ok` even after the release its
  first copy caused. Like `stage`, it does not check the custody halt: it records what a
  session already did.

  ## What an operator can see (issue #815)

  - The channel process carries `runner_id`, `runner_name`, `tenant_id`, `node` and
    `machine` as Logger metadata from join, and each message's `dispatch_id`, `run_id`,
    `claim_epoch` (and a dispatch's `story_id`) while it is handled.
  - Every refusal — of a join or a message, `rate_limited` and every unknown event included —
    emits `[:loopctl, :runners, :message_refused]`. Every refusal except `rate_limited` is
    also logged with its reason, except that an unknown event's log line is written at most
    once per second per channel.
  - `terminate/2` logs why the channel closed, where it ran and for how long.
  - Before closing a runner's connection itself, the channel pushes `"disconnecting"` with
    the reason (`RunnerContract.RunnerDisconnecting`) and logs the same reason. A stopping
    node reaches every runner channel through `LoopctlWeb.RunnerShutdownNotice`.
  - A dispatch the channel pushes is stamped `pushed_at` in the ledger; one it drops is
    logged with its tenant, story and epoch.
  """

  use LoopctlWeb, :channel

  require Logger

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.Kinds
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.TriageVerdict
  alias Loopctl.LogValue
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.Presence
  alias LoopctlWeb.RunnerChannel.MinInterval
  alias LoopctlWeb.RunnerChannel.Refusal
  alias LoopctlWeb.RunnerChannel.ReplyBucket
  alias LoopctlWeb.RunnerSocket

  @recheck_interval_ms 30_000
  # One source: the contract publishes these same values in its export.
  @min_status_interval_ms RunnerContract.min_interval_ms("status")
  @reply_capacity RunnerContract.dispatch_reply_burst() |> Map.fetch!("capacity")
  @reply_refill_ms RunnerContract.dispatch_reply_burst() |> Map.fetch!("refill_interval_ms")
  @stage_capacity RunnerContract.stage_burst() |> Map.fetch!("capacity")
  @stage_refill_ms RunnerContract.stage_burst() |> Map.fetch!("refill_interval_ms")

  @verdict_capacity RunnerContract.triage_verdict_burst() |> Map.fetch!("capacity")
  @verdict_refill_ms RunnerContract.triage_verdict_burst() |> Map.fetch!("refill_interval_ms")
  @session_ended_capacity RunnerContract.session_ended_burst() |> Map.fetch!("capacity")
  @session_ended_refill_ms RunnerContract.session_ended_burst()
                           |> Map.fetch!("refill_interval_ms")
  @min_trace_interval_ms RunnerContract.min_interval_ms("trace")
  @min_cursor_interval_ms RunnerContract.min_interval_ms("trace_cursor")
  # How often an unknown event is LOGGED. It is answered `unknown_event` and counted in
  # telemetry every time; this bounds only the log lines.
  @unknown_log_interval_ms 1_000
  @join_window_ms 60_000
  @max_joins 30

  @impl true
  def join("runner:" <> runner_id, payload, %{assigns: %{runner: %{id: runner_id}}} = socket) do
    %{runner: runner} = socket.assigns

    # Subscribe BEFORE the authorization read: a revoke committing between the two is
    # then either seen by the read or delivered to this process, never lost.
    :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, Runners.revocation_topic(runner.id))

    Logger.metadata(
      runner_id: runner.id,
      runner_name: runner.name,
      tenant_id: socket.assigns.tenant_id,
      node: Runners.node_name(),
      machine: Runners.machine_id()
    )

    with :ok <- join_rate_ok(runner),
         :ok <- still_authorized(socket),
         {:ok, meta} <- RunnerContract.cast_join(payload),
         :ok <- enrolled_machine(meta, runner) do
      send(self(), :after_join)

      {:ok, %{contract_version: RunnerContract.version()},
       socket
       |> assign(:connected_at, System.monotonic_time(:millisecond))
       |> assign(:meta, Map.put(meta, :joined_at, DateTime.utc_now()))
       |> assign(:last_status_at, :never)
       |> assign(:reply_bucket, :full)
       |> assign(:stage_bucket, :full)
       |> assign(:verdict_bucket, :full)
       |> assign(:session_ended_bucket, :full)
       |> assign(:last_trace_at, :never)
       |> assign(:last_cursor_at, :never)
       |> assign(:last_unknown_at, :never)
       |> assign(:last_unknown_info_at, :never)
       # The dispatches THIS connection put on the wire. Per-connection on purpose: it is
       # what lets a `kind_not_supported` reply be attributed to the connection that carried
       # the dispatch rather than to whichever one the reply lands on
       # (`note_kind_refusal/3`). Bounded by the runner's capacity, since a slot is held from
       # push until the reply, and it dies with the channel.
       |> assign(:pushed_dispatches, MapSet.new())
       |> assign(:presence_ref, nil)}
    else
      {:error, reason} -> {:error, refuse_join(socket, join_error(reason))}
    end
  end

  def join("runner:" <> _other, _payload, socket),
    do: {:error, refuse_join(socket, %{reason: "forbidden_topic"})}

  def join(_topic, _payload, socket),
    do: {:error, refuse_join(socket, %{reason: "unknown_topic"})}

  @impl true
  def handle_info(:after_join, socket) do
    %{runner: runner, tenant_id: tenant_id, meta: meta} = socket.assigns

    # WHAT THE MACHINE DECLARED BECOMES WHAT LOOPCTL RESERVES AGAINST — bounded by what it was
    # ENROLLED with — and it happens HERE, before `Presence.track/4`. A dispatch needs a single
    # live socket in the pool (`Runners.dispatch/3`), so until the track below there is no way
    # to place one on THIS socket. It never refuses the join and never raises; see
    # `Runners.apply_declaration/4` for why the machine's number wins downward, why the
    # enrolled one is a ceiling, and why nothing about it reaches the audit chain.
    #
    # A FAILED write is REMEMBERED, not lost. The realistic failure is `:capacity_busy` — the
    # `runners` row's lock timeout running out against the row every dispatch in the tenant
    # contends on, i.e. exactly the load under which being dispatchable against a stale larger
    # number does the most harm — and nothing else reconciles it, since the heal sweep
    # recomputes `in_flight` and never `max_sessions`. So it is re-armed on the `:recheck`
    # timer below, which this socket already runs every 30 seconds — as a write that may only
    # LOWER the held capacity, see `retry_declaration/1`.
    socket = assign(socket, :declaration_pending, apply_declaration(tenant_id, runner, meta))

    {:ok, ref} =
      Presence.track(
        self(),
        Runners.pool_topic(tenant_id),
        runner.name,
        presence_meta(meta, runner)
      )

    # Subscribe to dispatches only AFTER this socket is in the pool, so no process can
    # receive a dispatch while `Runners.dispatch/3`'s single-socket read cannot see it. The
    # revocation subscribe stays in join/3, before the authorization read.
    :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, Runners.dispatch_topic(runner.id))
    :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, Runners.shutdown_topic())

    schedule_recheck()
    {:noreply, assign(socket, :presence_ref, ref)}
  end

  def handle_info(:runner_revoked, socket), do: disconnect(socket, :runner_revoked)

  # The node is stopping (`LoopctlWeb.RunnerShutdownNotice`). Tell the runner before the
  # socket drain closes it; the drain itself stops this channel.
  def handle_info(:server_shutdown, socket) do
    announce_disconnect(socket, :server_shutdown)
    {:noreply, socket}
  end

  # The checks nearest the push. `Runners.dispatch/3` made both already, but its reads can be
  # stale by the time this message arrives:
  #
  # - a second socket on this credential that its pool read did not see (joined since, or
  #   not yet in that node's Presence view) is subscribed too, and would push the same
  #   prompt. So push only when this socket's own Presence ref is the ONE live meta for the
  #   runner; every other receiver drops it.
  # - a halt can land between that read and this message, and a dispatch is custody
  #   progress. Re-read fresh, from THIS channel's own tenant.
  # TWO shapes, on purpose (issue #803). This release SENDS the two-element one, which every
  # deployed node already understands: a node of the PREVIOUS release has no clause for a
  # three-element message and would crash on it mid-rolling-deploy, dropping the dispatch. The
  # three-element clause is here so the NEXT release can start sending it with no window of
  # its own. Keep both until that release has shipped.
  def handle_info({:runner_dispatch, dispatch}, socket),
    do: dispatch_to_socket(dispatch, socket)

  def handle_info({:runner_dispatch, dispatch, _slot_generation}, socket),
    do: dispatch_to_socket(dispatch, socket)

  def handle_info(:recheck, socket) do
    %{runner: runner, tenant_id: tenant_id} = socket.assigns

    if Runners.authorized?(tenant_id, runner.id) do
      schedule_recheck()
      {:noreply, retry_declaration(socket)}
    else
      disconnect(socket, :no_longer_authorized)
    end
  end

  # Nothing else. A message shape this release does not know — a NEWER node's, mid-rolling
  # deploy — must not crash the channel: that drops whatever it carried and takes the runner's
  # socket down with it. The case this exists for is exactly the one that arrives at dispatch
  # rate on every channel at once, so the LOG is gated to one line per
  # `@unknown_log_interval_ms`, like an unknown event's; the message itself is always ignored.
  def handle_info(message, socket) do
    now = System.monotonic_time(:millisecond)

    socket =
      case MinInterval.check(socket.assigns.last_unknown_info_at, now, @unknown_log_interval_ms) do
        :ok ->
          tag =
            if is_tuple(message) and tuple_size(message) > 0, do: elem(message, 0), else: message

          Logger.warning(
            "runner #{socket.assigns.runner.id} ignored an unknown channel message: " <>
              "tag=#{inspect(tag)} tenant_id=#{socket.assigns.tenant_id}"
          )

          assign(socket, :last_unknown_info_at, now)

        {:error, :rate_limited} ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_in(event, payload, socket) do
    with_correlation(message_correlation(payload), fn ->
      handle_message(event, payload, socket)
    end)
  end

  defp handle_message("status", payload, socket) do
    now = System.monotonic_time(:millisecond)

    with :ok <- MinInterval.check(socket.assigns.last_status_at, now, @min_status_interval_ms),
         {:ok, status} <- RunnerContract.cast_status(payload) do
      %{runner: runner, tenant_id: tenant_id, meta: meta} = socket.assigns
      meta = Map.merge(meta, status)

      {:ok, ref} =
        Presence.update(
          self(),
          Runners.pool_topic(tenant_id),
          runner.name,
          presence_meta(meta, runner)
        )

      # An update re-issues the meta's phx_ref; keep the current one for sole_live_socket?/1.
      {:reply, :ok,
       socket
       |> assign(:meta, meta)
       |> assign(:last_status_at, now)
       |> assign(:presence_ref, ref)}
    else
      {:error, :rate_limited} ->
        refuse(socket, "status", %{
          reason: "rate_limited",
          min_interval_ms: @min_status_interval_ms
        })

      {:error, reason} ->
        refuse(socket, "status", join_error(reason))
    end
  end

  # Each handler below spends its rate limit only once the message is VALID — that is, once
  # it will cost a database round trip. A message refused at the contract cast costs none,
  # so the runner can correct it and resend at once.
  defp handle_message("dispatch_reply", payload, socket) do
    now = System.monotonic_time(:millisecond)
    %{runner: runner, tenant_id: tenant_id} = socket.assigns

    with {:ok, reply} <- RunnerContract.cast_dispatch_reply(payload),
         {:ok, bucket} <-
           ReplyBucket.take(socket.assigns.reply_bucket, now, @reply_capacity, @reply_refill_ms) do
      socket = assign(socket, :reply_bucket, bucket)

      case DispatchLedger.record_reply(tenant_id, runner.id, reply) do
        {:ok, record} -> {:reply, :ok, note_kind_refusal(socket, reply, record)}
        {:error, reason} -> refuse(socket, "dispatch_reply", message_error(reason))
      end
    else
      {:error, :rate_limited} -> rate_limited(socket, "dispatch_reply", @reply_refill_ms)
      {:error, reason} -> refuse(socket, "dispatch_reply", message_error(reason))
    end
  end

  # The stage a runner's session reached (contract 1.4.0, #803). Fenced on `claim_epoch`
  # exactly as `dispatch_reply` and `trace` are, and applied through
  # `Loopctl.Delivery.Stages.advance/4` — the ONE writer of `story_stages` — so the channel
  # never opens a second write path to the delivery state.
  defp handle_message("stage", payload, socket) do
    now = System.monotonic_time(:millisecond)
    %{runner: runner, tenant_id: tenant_id} = socket.assigns

    with {:ok, stage} <- RunnerContract.cast_stage(payload),
         {:ok, bucket} <-
           ReplyBucket.take(socket.assigns.stage_bucket, now, @stage_capacity, @stage_refill_ms) do
      socket = assign(socket, :stage_bucket, bucket)

      case RunnerStages.apply(tenant_id, runner.id, stage) do
        {:ok, row} -> {:reply, {:ok, stage_ack(row)}, socket}
        {:error, reason} -> refuse(socket, "stage", message_error(reason))
      end
    else
      {:error, :rate_limited} -> rate_limited(socket, "stage", @stage_refill_ms)
      {:error, reason} -> refuse(socket, "stage", message_error(reason))
    end
  end

  # What a triage session concluded (contract 1.9.0, #803). A separate message from `stage`
  # because `:triage_escalate` is NOT a runner-reportable edge — the machine calls it a
  # control-side verdict about a specific gate — so a runner cannot report its way to an
  # escalation and a `stage` message could never carry the outcome at all.
  #
  # IDEMPOTENT, and the ack says which it was. A verdict is produced once per run and the
  # session that wrote it has stopped, so a runner refused for any transient reason has no
  # move except resending the same bytes; `replayed: true` tells it the resend landed on the
  # verdict already recorded rather than applying anything twice.
  defp handle_message("triage_verdict", payload, socket) do
    now = System.monotonic_time(:millisecond)
    %{runner: runner, tenant_id: tenant_id} = socket.assigns

    with {:ok, message} <- RunnerContract.cast_triage_verdict_message(payload),
         {:ok, bucket} <-
           ReplyBucket.take(
             socket.assigns.verdict_bucket,
             now,
             @verdict_capacity,
             @verdict_refill_ms
           ) do
      socket = assign(socket, :verdict_bucket, bucket)

      case TriageVerdict.apply(tenant_id, runner.id, message) do
        {:ok, %{record: record, replayed?: replayed?}} ->
          {:reply, {:ok, %{recorded_at: record.inserted_at, replayed: replayed?}}, socket}

        {:error, reason} ->
          refuse(socket, "triage_verdict", message_error(reason))
      end
    else
      {:error, :rate_limited} -> rate_limited(socket, "triage_verdict", @verdict_refill_ms)
      {:error, reason} -> refuse(socket, "triage_verdict", message_error(reason))
    end
  end

  # Why an implement session ended (contract 1.16.0, US-44.3). The runner states the fact;
  # `RunnerStages.end_session/3` records it once and decides what it does to the story.
  #
  # IDEMPOTENT, and the ack says which it was, for the reason `triage_verdict`'s does: the
  # session that ended cannot say it again differently, so a runner refused for anything
  # transient has no move except resending the same bytes.
  defp handle_message("session_ended", payload, socket) do
    now = System.monotonic_time(:millisecond)
    %{runner: runner, tenant_id: tenant_id} = socket.assigns

    with {:ok, message} <- RunnerContract.cast_session_ended(payload),
         {:ok, bucket} <-
           ReplyBucket.take(
             socket.assigns.session_ended_bucket,
             now,
             @session_ended_capacity,
             @session_ended_refill_ms
           ) do
      socket = assign(socket, :session_ended_bucket, bucket)

      case RunnerStages.end_session(tenant_id, runner.id, message) do
        {:ok, %{row: row, replayed?: replayed?}} ->
          {:reply, {:ok, Map.put(stage_ack(row), :replayed, replayed?)}, socket}

        {:error, reason} ->
          refuse(socket, "session_ended", message_error(reason))
      end
    else
      {:error, :rate_limited} -> rate_limited(socket, "session_ended", @session_ended_refill_ms)
      {:error, reason} -> refuse(socket, "session_ended", message_error(reason))
    end
  end

  defp handle_message("trace", payload, socket) do
    now = System.monotonic_time(:millisecond)
    %{runner: runner, tenant_id: tenant_id} = socket.assigns

    with :ok <- MinInterval.check(socket.assigns.last_trace_at, now, @min_trace_interval_ms),
         {:ok, batch} <- RunnerContract.cast_trace_batch(payload) do
      socket = assign(socket, :last_trace_at, now)

      case DispatchLedger.record_trace(tenant_id, runner.id, batch) do
        {:ok, acked_seq} -> {:reply, {:ok, %{acked_seq: acked_seq}}, socket}
        {:error, reason} -> refuse(socket, "trace", message_error(reason))
      end
    else
      {:error, :rate_limited} -> rate_limited(socket, "trace", @min_trace_interval_ms)
      {:error, reason} -> refuse(socket, "trace", message_error(reason))
    end
  end

  defp handle_message("trace_cursor", payload, socket) do
    now = System.monotonic_time(:millisecond)
    %{runner: runner, tenant_id: tenant_id} = socket.assigns

    with :ok <- MinInterval.check(socket.assigns.last_cursor_at, now, @min_cursor_interval_ms),
         {:ok, %{run_id: run_id}} <- RunnerContract.cast_trace_cursor(payload) do
      acked_seq = DispatchLedger.trace_cursor(tenant_id, runner.id, run_id)
      {:reply, {:ok, %{acked_seq: acked_seq}}, assign(socket, :last_cursor_at, now)}
    else
      {:error, :rate_limited} -> rate_limited(socket, "trace_cursor", @min_cursor_interval_ms)
      {:error, reason} -> refuse(socket, "trace_cursor", message_error(reason))
    end
  end

  # An unknown event's name is the runner's own string: it is never a telemetry tag.
  # Every unknown event is answered `unknown_event` — never `rate_limited`, which would tell
  # a newer runner its event exists and to retry it — and counted in telemetry (its tag is
  # the fixed "unknown"). What the interval bounds is the LOG: at most one line per interval,
  # so a runner looping over made-up names cannot buy a log line per frame.
  defp handle_message(_event, _payload, socket) do
    now = System.monotonic_time(:millisecond)

    {socket, log?} =
      case MinInterval.check(socket.assigns.last_unknown_at, now, @unknown_log_interval_ms) do
        :ok -> {assign(socket, :last_unknown_at, now), true}
        {:error, :rate_limited} -> {socket, false}
      end

    report_refusal(socket, "unknown", "unknown_event", log?)
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  @impl true
  def terminate(reason, socket) do
    assigns = socket.assigns
    runner = Map.get(assigns, :runner)

    connected_ms =
      case Map.get(assigns, :connected_at) do
        at when is_integer(at) -> System.monotonic_time(:millisecond) - at
        _ -> nil
      end

    Logger.log(
      terminate_level(reason),
      "runner channel closed: reason=#{inspect(reason)} runner_id=#{runner && runner.id} " <>
        "runner_name=#{runner && runner.name} tenant_id=#{Map.get(assigns, :tenant_id)} " <>
        "node=#{Runners.node_name()} machine=#{inspect(Runners.machine_id())} " <>
        "connected_ms=#{inspect(connected_ms)} presence_ref=#{inspect(Map.get(assigns, :presence_ref))}"
    )

    :ok
  end

  # A close the channel or its transport initiated is routine; anything else crashed it.
  defp terminate_level(:normal), do: :info
  defp terminate_level(:shutdown), do: :info
  defp terminate_level({:shutdown, _}), do: :info
  defp terminate_level(_crash), do: :warning

  # A stage row as it now stands. A runner whose acknowledgement was lost re-sends and gets
  # this back from the replay path, so where the story actually is never needs a second
  # endpoint.
  #
  # Rendered by `RunnerStages.row_state/1` rather than here, because the `stale_stage` refusal
  # sends the same row for the same reason (#849) and the two must not be able to drift.
  defp stage_ack(row), do: RunnerStages.row_state(row)

  defp rate_limited(socket, event, min_interval_ms),
    do: refuse(socket, event, %{reason: "rate_limited", min_interval_ms: min_interval_ms})

  # Every refusal of a runner message goes through here: the reply the runner sees, one
  # telemetry event, and — for anything but routine backpressure — a log line.
  defp refuse(socket, event, %{reason: reason} = reply) do
    report_refusal(socket, event, reason)
    {:reply, {:error, reply}, socket}
  end

  defp refuse_join(socket, %{reason: reason} = reply) do
    report_refusal(socket, "join", reason)
    reply
  end

  defp report_refusal(socket, event, reason, log? \\ true) do
    metadata = Logger.metadata()

    :telemetry.execute([:loopctl, :runners, :message_refused], %{count: 1}, %{
      event: event,
      reason: reason,
      tenant_id: Map.get(socket.assigns, :tenant_id),
      runner_id: socket.assigns |> Map.get(:runner, %{}) |> Map.get(:id),
      dispatch_id: metadata[:dispatch_id],
      run_id: metadata[:run_id]
    })

    if log? and reason != "rate_limited" do
      Logger.info(
        "runner message refused: event=#{event} reason=#{reason} " <>
          "dispatch_id=#{inspect(metadata[:dispatch_id])} run_id=#{inspect(metadata[:run_id])}"
      )
    end
  end

  # Correlation ids of the message being handled. Read from the payload as sent, so each is
  # taken only in the shape it claims (`Loopctl.LogValue`: a UUID or an epoch, else
  # `:invalid`) — a runner cannot put an arbitrary value into the log stream through them.
  defp message_correlation(%{} = payload) do
    [
      dispatch_id: LogValue.uuid(Map.get(payload, "dispatch_id")),
      run_id: LogValue.uuid(Map.get(payload, "run_id")),
      claim_epoch: LogValue.epoch(Map.get(payload, "claim_epoch"))
    ]
  end

  defp message_correlation(_payload), do: []

  @correlation_keys [:dispatch_id, :run_id, :story_id, :claim_epoch]

  # A message's correlation ids label only the lines logged WHILE it is handled. They are
  # cleared when it returns, so a later close, recheck or disconnect line carries only the
  # sticky runner identity set at join — never the story of whatever dispatch came last.
  #
  # NOT cleared when handling raises: the process is about to die, and its crash report and
  # the `runner channel closed` warning are exactly the lines that need the ids.
  defp with_correlation(correlation, fun) do
    Logger.metadata(correlation)

    result =
      try do
        fun.()
      catch
        kind, reason ->
          Logger.error(
            "runner message handling failed: " <>
              Exception.format_banner(kind, reason, __STACKTRACE__)
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    Logger.metadata(Enum.map(@correlation_keys, &{&1, nil}))
    result
  end

  # The socket authenticated once, at connect. A join can come much later — a runner can
  # leave and rejoin on the same connection — so every join re-reads authorization, or a
  # revoked runner could re-enter the pool faster than the periodic recheck fires.
  #
  # A refusal also DISCONNECTS the socket: an unauthorized runner has no use for the
  # connection it still holds, and every further join would be another read.
  defp still_authorized(%{assigns: %{runner: runner, tenant_id: tenant_id}}) do
    if Runners.authorized?(tenant_id, runner.id) do
      :ok
    else
      # An unjoined topic cannot carry a `disconnecting` push, so the join's error reply
      # carries the reason (`join_error(:not_authorized)`). The transport is waiting on that
      # reply, so it is written to the client before this broadcast closes the socket.
      log_disconnecting(runner, :join_refused_not_authorized)
      LoopctlWeb.Endpoint.broadcast(RunnerSocket.socket_id(runner.id), "disconnect", %{})
      {:error, :not_authorized}
    end
  end

  # Every join costs an authorization read on AdminRepo and a Presence leave/join
  # broadcast, and each rejoin starts a fresh channel process whose status interval has
  # never fired. So joins are budgeted per runner, before any of that, on the shared
  # limiter (fail-CLOSED: a limiter fault refuses the join and the runner retries).
  #
  # The budget is per NODE unless `RATE_LIMITER=postgres` selects the shared counter: the
  # default limiter is node-local ETS, so a runner alternating between two machines gets up
  # to twice `@max_joins`. Clustering does not change that. It bounds a reconnect loop's
  # cost per node, which is what it is for, so the per-node default stands.
  defp join_rate_ok(runner) do
    if Loopctl.RateLimiter.gate_ok?("runner_join:" <> runner.id, @join_window_ms, @max_joins),
      do: :ok,
      else: {:error, :join_rate_limited}
  end

  defp enrolled_machine(%{machine: machine}, %{name: machine}), do: :ok

  defp enrolled_machine(%{machine: declared}, _runner),
    do: {:error, {:machine_mismatch, declared}}

  # `node` and `machine_id` answer "which node holds this runner". Presence replicates this
  # meta to every node of the cluster, so `GET /api/v1/runners/pool` on either machine names
  # the node that holds the socket.
  defp presence_meta(meta, runner) do
    Map.merge(meta, %{
      runner_id: runner.id,
      node: Runners.node_name(),
      machine_id: Runners.machine_id()
    })
  end

  # A RUNNER CONTRADICTING ITS OWN DECLARATION IS BOUNDED PER CONNECTION (contract 1.6.0).
  #
  # `Runners.dispatch/3` consults the declaration alone for a declaring runner and never the
  # ledger's `kind_not_supported` memory — deliberately, because that memory has no expiry
  # and is what locked an upgraded machine out for the life of its `runners` row. The cost is
  # that a runner which DECLARES a kind and then refuses it has nothing stopping the next
  # dispatch: each one writes a ledger row, takes a slot, is refused, releases the slot, and
  # the loop has no bound at all. That is not hypothetical — the motivating failure is a
  # runner mapping a TRANSIENT LOCAL CONDITION to `kind_not_supported`, and such a runner goes
  # on declaring the kind at every reconnect.
  #
  # So the refusal is honoured for the life of THIS CONNECTION, in this socket's own Presence
  # meta. Per-connection is the right lifetime and not a compromise: the declaration it
  # contradicts is per-connection, so the contradiction expires exactly when the claim does,
  # and the reconnect that re-declares the kind is the same unlock as everywhere else. It
  # needs no table and cannot outlive the machine that said it.
  #
  # Only for a DECLARING runner: an undeclaring one is already bounded by the ledger, and
  # writing this meta for it would add a second, weaker mechanism in front of the durable one.
  #
  # THIS IS A BOUND ON THE DAMAGE, NOT A SUPPORTED RECOVERY PATH, and the difference decides
  # what to do when it fires. `mkreyman/loopctl-runner` builds its join declaration and its
  # kind check from ONE list (its maintaining session, 2026-09-14), so a runner declaring a
  # kind and then refusing it is a BUG on that side — not a state anyone should recover from
  # by reconnecting. Reconnecting clears the suppression because the declaration it
  # contradicts is per-connection, not because a reconnect is the remedy. A log line here is
  # something to go and fix on the runner, and if a future change makes this fire routinely,
  # that is the signal the two sides have drifted apart rather than that the bound is working.
  defp note_kind_refusal(socket, %{decision: "refused", reason: "kind_not_supported"}, record) do
    %{runner: runner, tenant_id: tenant_id, meta: meta} = socket.assigns

    emit_kind_refused(tenant_id, runner, record, Runners.declared_kinds(meta), nil)

    case {Runners.declared_kinds(meta), record.kind} do
      {{:declared, kinds}, kind} when is_binary(kind) ->
        if kind in kinds and pushed_here?(socket, record) do
          Logger.warning(
            "runner declared kind #{kind} and then refused it as kind_not_supported; " <>
              "suppressing that kind for the rest of this connection. Reconnecting clears it."
          )

          suppress_kind(socket, meta, runner, tenant_id, kind)
        else
          socket
        end

      _ ->
        socket
    end
  end

  # A FAULT on a kind the runner DECLARED. Not a capability statement, so nothing is
  # suppressed — a fault is transient by assumption and the next dispatch should be tried —
  # but it is the same self-contradiction one step further in, and until now it was the one
  # shape this telemetry could not see.
  #
  # Found by the `loopctl-runner` maintaining session, 2026-09-15, from its own side: a
  # runner may declare a kind its ACCEPT PATH cannot actually run. Theirs requires a story
  # object, which the contract allows only on an implement dispatch, so a runner declaring
  # `triage` before its accept path exists refuses every triage dispatch with `other` —
  # suppressing nothing, recording no `kind_not_supported`, and soaking the kind for as long
  # as it is declared. Both existing outcome tags stay at zero while the machine eats
  # dispatches. 1.7.0 is what makes declaring `triage` possible, so the blind spot ships with
  # it unless it is closed here.
  defp note_kind_refusal(socket, %{decision: "refused", reason: "other"}, record) do
    %{runner: runner, tenant_id: tenant_id, meta: meta} = socket.assigns

    with {:declared, kinds} <- Runners.declared_kinds(meta),
         kind when is_binary(kind) <- record.kind,
         true <- kind in kinds,
         # SCOPED TO A KIND BEYOND THE HISTORIC BASELINE, which is the whole signal. `other`
         # is the contract's RESIDUAL refusal reason: every anticipated local condition has
         # its own code and anything else — an internal exception, a disk check that threw —
         # lands here. `implement` is dispatchable and every runner declares it, so counting
         # faults on it would drown the series in ordinary transient failures and hand an
         # operator a "your declaration has diverged" warning for a runner that hiccuped.
         #
         # A fault on a kind OUTSIDE `implied_by_silence/0` is different in kind, not just in
         # rate: nothing was ever sent for it before the runner declared it, so a structural
         # failure there is the declaration outrunning the accept path — the case this exists
         # to catch.
         false <- kind in Kinds.implied_by_silence() do
      Logger.warning(
        "runner declared kind #{kind} and then refused a dispatch of it as other; the " <>
          "declaration and what the runner can actually run may have diverged"
      )

      emit_kind_refused(tenant_id, runner, record, {:declared, kinds}, "declared_but_faulted")
    end

    socket
  end

  defp note_kind_refusal(socket, _reply, _record), do: socket

  # EMITTED ON EVERY `kind_not_supported`, NOT ONLY THE SUPPRESSED ONES — and that ordering
  # is the whole point. This counter first lived inside `suppress_kind/5`, which runs only
  # for a runner that DECLARED the kind, so it read zero during the one incident that is
  # live on the fleet today: no runner declares yet, so every machine takes the UNDECLARING
  # path, where a single refusal is permanent for the life of its `runners` row and the
  # machine sits connected and healthy-looking with no work for ever. An instrument blind to
  # the worst case it could report is the same defect as the event that had no metric at
  # all, one layer in.
  #
  # `outcome` separates them, and both tags are bounded: `kind` comes from the LEDGER row of
  # a dispatch loopctl itself sent, so it is from `dispatchable_kinds` and never a
  # runner-supplied string, and `outcome` is four literals — `permanent`, `suppressed`,
  # `not_declared` and `declared_but_faulted`. Ids stay in the logs.
  defp emit_kind_refused(tenant_id, runner, %{kind: kind}, declared, forced)
       when is_binary(kind) do
    outcome =
      cond do
        is_binary(forced) ->
          forced

        match?({:declared, _}, declared) ->
          {:declared, kinds} = declared
          if kind in kinds, do: "suppressed", else: "not_declared"

        true ->
          "permanent"
      end

    :telemetry.execute(
      [:loopctl, :runners, :declared_kind_refused],
      %{count: 1},
      %{kind: kind, outcome: outcome, tenant_id: tenant_id, runner_id: runner.id}
    )
  end

  defp emit_kind_refused(_tenant_id, _runner, _record, _declared, _forced), do: :ok

  # THE SUPPRESSION BELONGS TO THE CONNECTION THAT CARRIED THE DISPATCH, not to whichever one
  # the reply happens to arrive on. `DispatchLedger.record_reply/3` fences on
  # `(tenant_id, runner_id, dispatch_id)` and `claim_epoch` — never on a socket — so a reply
  # is accepted on ANY of the runner's channels.
  #
  # Without this, a reply that crosses a reconnect punishes the wrong connection: the runner
  # decides locally it cannot run a dispatch, its socket drops before the reply flushes, it
  # reconnects, re-declares the kind and sends the queued refusal — and the FRESH connection,
  # which has contradicted nothing, is suppressed for its whole life. That also defeats the
  # remedy this module and the pool's OpenAPI text both promise, "reconnecting clears it",
  # for the connection that just performed it.
  defp pushed_here?(%{assigns: %{pushed_dispatches: pushed}}, %{dispatch_id: id}),
    do: MapSet.member?(pushed, id)

  defp pushed_here?(_socket, _record), do: false

  defp remember_pushed(socket, dispatch) do
    update_in(socket.assigns.pushed_dispatches, &MapSet.put(&1, dispatch.dispatch_id))
  end

  # THE DECLARATION IS LEFT EXACTLY AS THE RUNNER SENT IT. An earlier version of this took
  # the kind out of `:kinds`, which made the pool report a statement the machine never made:
  # one that declared ["triage", "implement"] and refused a single implement dispatch
  # rendered as a triage-only machine, and one that declared ["implement"] and refused it
  # rendered as having declared NOTHING — the same as a pre-1.6.0 runner. The suppression is
  # a fact about what loopctl is withholding, not about what the runner said, so it lives in
  # its own key and `Runners.kind_supported/4` subtracts it at the decision.
  defp suppress_kind(socket, meta, runner, tenant_id, kind) do
    meta = Map.update(meta, :suppressed_kinds, [kind], &Enum.uniq([kind | &1]))

    {:ok, ref} =
      Presence.update(
        self(),
        Runners.pool_topic(tenant_id),
        runner.name,
        presence_meta(meta, runner)
      )

    socket |> assign(:meta, meta) |> assign(:presence_ref, ref)
  end

  # This socket is tracked, and its meta is the only one in the tenant's pool holding the
  # runner's id. An untracked channel (no ref yet) is never the sole socket. The pool is the
  # cluster-wide Presence replica, so a second socket on ANOTHER node counts too, once its
  # entry has replicated (see `Loopctl.Runners`, "Across the cluster").
  defp sole_live_socket?(%{assigns: %{presence_ref: ref, runner: runner, tenant_id: tenant_id}})
       when is_binary(ref) do
    match?([%{phx_ref: ^ref}], Runners.live_metas(tenant_id, runner.id))
  end

  defp sole_live_socket?(_socket), do: false

  # The push half of the delivery decision (`DispatchLedger.record_push/2`): this channel
  # pushes only if it WON the row, so a channel that dropped the same broadcast cannot free
  # the slot of the session this push starts, and a second socket cannot push it twice. One
  # database wait, never two: a decision that could not be taken leaves the dispatch unsent
  # and its slot to the sweep's undelivered grace, rather than spending another lock_timeout
  # inside the process that holds the runner's socket.
  defp push_if_this_channel_decides(socket, dispatch) do
    case DispatchLedger.record_push(socket.assigns.tenant_id, dispatch) do
      {:ok, :pushed} ->
        push(socket, "dispatch", dispatch)
        # Remembered so a `kind_not_supported` reply can be attributed to the connection
        # that actually carried the dispatch — see `note_kind_refusal/3`.
        {:noreply, remember_pushed(socket, dispatch)}

      {:ok, {:already, decided}} ->
        log_undelivered(socket, dispatch, "another process already decided: #{decided}")
        {:noreply, socket}

      {:error, reason} ->
        log_undelivered(socket, dispatch, "delivery not recorded: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  # A dispatch this channel must not push, but another might: no decision, no release.
  defp ignore_dispatch(socket, dispatch, why) do
    log_undelivered(socket, dispatch, why)
    {:noreply, socket}
  end

  # A dispatch NOBODY may push (the tenant is halted): the delivery decision is final, so the
  # slot goes back at once rather than waiting for the heal sweep's bound — but only if this
  # channel WINS the decision.
  # A drop that loses to a push releases nothing: that slot is holding a session. A failure
  # here is logged and swallowed, and the sweep still bounds the slot; a raise would take down
  # the runner's socket.
  defp drop_dispatch(socket, dispatch, why) do
    Logger.warning(
      "runner #{socket.assigns.runner.id} dispatch #{dispatch.dispatch_id} dropped: #{why} " <>
        "tenant_id=#{socket.assigns.tenant_id} story_id=#{dispatch.story_id} " <>
        "claim_epoch=#{dispatch.claim_epoch}"
    )

    release_dropped_slot(socket, dispatch)

    {:noreply, socket}
  end

  defp release_dropped_slot(socket, dispatch) do
    case DispatchLedger.record_drop(socket.assigns.tenant_id, dispatch.dispatch_id) do
      {:ok, :released} ->
        :ok

      {:ok, {:already, decided}} ->
        log_undelivered(socket, dispatch, "already #{decided}")

      {:error, reason} ->
        log_undelivered(socket, dispatch, "drop not recorded: #{inspect(reason)}")
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      log_undelivered(socket, dispatch, "drop not recorded: #{inspect(error.__struct__)}")
  end

  defp log_undelivered(socket, dispatch, what) do
    Logger.warning(
      "runner #{socket.assigns.runner.id} dispatch #{dispatch.dispatch_id} not delivered: " <>
        "#{what} tenant_id=#{socket.assigns.tenant_id} story_id=#{dispatch.story_id} " <>
        "claim_epoch=#{dispatch.claim_epoch}"
    )

    :ok
  end

  defp dispatch_to_socket(dispatch, socket) do
    correlation = [
      dispatch_id: dispatch.dispatch_id,
      story_id: dispatch.story_id,
      claim_epoch: dispatch.claim_epoch
    ]

    with_correlation(correlation, fn ->
      cond do
        # "NOT ME", not "nobody": another socket of this runner may be the one that should
        # push it, so this channel takes no delivery decision and releases nothing — doing
        # either would take the decision away from the channel that pushes. When no socket
        # pushes it, the heal sweep's undelivered grace is what returns the slot.
        not sole_live_socket?(socket) ->
          ignore_dispatch(socket, dispatch, "not the only live socket for this runner")

        Runners.custody_halted?(socket.assigns.tenant_id) ->
          drop_dispatch(socket, dispatch, "tenant custody halted")

        true ->
          push_if_this_channel_decides(socket, dispatch)
      end
    end)
  end

  defp schedule_recheck, do: Process.send_after(self(), :recheck, @recheck_interval_ms)

  # `true` while the declaration this connection carried has NOT reached the row. The socket's
  # `:meta` is the right thing to re-apply: capacity arrives once per connection and a
  # `RunnerStatus` event can never carry it (`max_sessions` is not among its fields), so the
  # value here is still the one this machine declared on join.
  defp apply_declaration(tenant_id, runner, meta, opts \\ []) do
    Runners.apply_declaration(tenant_id, runner, meta, opts) != :ok
  end

  # The retry runs AFTER `Presence.track/4`, so it does not have `:after_join`'s ordering
  # argument and does not need it: a lowering applied while the machine is dispatchable is
  # clamped by `Capacity.apply_declared/5` and converges, because the release path RECOUNTS
  # rather than decrementing. Staying over-dispatched until the machine happens to reconnect
  # is the worse of the two, and it was the behaviour before this.
  #
  # IT CAN ONLY LOWER (#846.4 review round 3, finding 5). This retry re-applies a declaration
  # THIS connection carried, and a connection can be superseded: two sockets can be live at
  # once (`Runners`' moduledoc documents the reconnect window in which a silent node's entry
  # lingers), so socket A, which joined declaring 4 and lost the runner row's lock, may be
  # retrying after socket B joined declaring 1 and wrote it. `only_lower: true` is what makes
  # that harmless — A's 4 is refused as a raise, whether or not B is still visible when A
  # retries, and the doc on `Capacity.apply_declared/5` carries the reasoning. The state this
  # retry exists to repair is the opposite one (a row left holding a LARGER stale number), so
  # the bound costs it nothing it was for.
  #
  # `sole_live_socket?/1` is kept in front of it as the cheap half of the same judgement:
  # while a runner has two live sockets it is `:runner_ambiguous` to `Runners.dispatch/3` and
  # no dispatch is being decided against the row at all, so there is nothing to gain by taking
  # the lock. It is NOT what makes the retry safe — round 2 read it that way, and it cannot
  # be: it is a check on the pool AT THIS INSTANT, and B can have joined, written and gone
  # between two of A's 30-second rechecks, leaving A sole and its declaration stale.
  #
  # `declaration_pending` is deliberately LEFT ARMED while ambiguous rather than cleared, so
  # the write lands on the first recheck after the ambiguity clears.
  defp retry_declaration(%{assigns: %{declaration_pending: true}} = socket) do
    if sole_live_socket?(socket) do
      %{runner: runner, tenant_id: tenant_id, meta: meta} = socket.assigns

      assign(
        socket,
        :declaration_pending,
        apply_declaration(tenant_id, runner, meta, only_lower: true)
      )
    else
      socket
    end
  end

  defp retry_declaration(socket), do: socket

  # Disconnecting the SOCKET (not just stopping this channel) keeps a revoked runner from
  # simply rejoining the topic on the connection it already has.
  #
  # The `disconnecting` push goes first. It and the broadcast below are both sent from this
  # process, and a transport handles its messages in order, so the runner receives the
  # reason before the close.
  defp disconnect(socket, reason) do
    announce_disconnect(socket, reason)

    LoopctlWeb.Endpoint.broadcast(
      RunnerSocket.socket_id(socket.assigns.runner.id),
      "disconnect",
      %{}
    )

    {:stop, {:shutdown, reason}, socket}
  end

  defp announce_disconnect(socket, reason) do
    push(socket, "disconnecting", %{reason: Atom.to_string(reason)})
    log_disconnecting(socket.assigns.runner, reason)
  end

  defp log_disconnecting(runner, reason) do
    Logger.info(
      "runner disconnecting: reason=#{reason} runner_id=#{runner.id} runner_name=#{runner.name}"
    )
  end

  # The reason -> refusal mapping lives in `LoopctlWeb.RunnerChannel.Refusal`, out of this
  # module and public, so its CATCH-ALL can be called by a test. Private here, the only way to
  # reach a missing clause was to crash a socket (#824 round 2).
  defp join_error(reason),
    do: Refusal.for_join(reason, max_joins: @max_joins, window_ms: @join_window_ms)

  defp message_error(reason), do: Refusal.for_message(reason)
end
