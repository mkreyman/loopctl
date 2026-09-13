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

  ## What an operator can see (issue #815)

  - The channel process carries `runner_id`, `runner_name`, `tenant_id`, `node` and
    `machine` as Logger metadata from join, and each message's `dispatch_id`, `run_id`,
    `claim_epoch` (and a dispatch's `story_id`) while it is handled.
  - Every refusal — of a join or a message, `rate_limited` included — emits
    `[:loopctl, :runners, :message_refused]`; every refusal except `rate_limited` is also
    logged with its reason.
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
  alias Loopctl.LogValue
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.Presence
  alias LoopctlWeb.RunnerChannel.MinInterval
  alias LoopctlWeb.RunnerChannel.ReplyBucket
  alias LoopctlWeb.RunnerSocket

  @recheck_interval_ms 30_000
  # One source: the contract publishes these same values in its export.
  @min_status_interval_ms RunnerContract.min_interval_ms("status")
  @reply_capacity RunnerContract.dispatch_reply_burst() |> Map.fetch!("capacity")
  @reply_refill_ms RunnerContract.dispatch_reply_burst() |> Map.fetch!("refill_interval_ms")
  @min_trace_interval_ms RunnerContract.min_interval_ms("trace")
  @min_cursor_interval_ms RunnerContract.min_interval_ms("trace_cursor")
  # How often an unknown event is REPORTED (telemetry and a log line). It is answered
  # `unknown_event` every time; this bounds only what loopctl writes about it.
  @unknown_report_interval_ms 1_000
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
       |> assign(:last_trace_at, :never)
       |> assign(:last_cursor_at, :never)
       |> assign(:last_unknown_at, :never)
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
  def handle_info({:runner_dispatch, dispatch}, socket) do
    correlation = [
      dispatch_id: dispatch.dispatch_id,
      story_id: dispatch.story_id,
      claim_epoch: dispatch.claim_epoch
    ]

    with_correlation(correlation, fn ->
      cond do
        not sole_live_socket?(socket) ->
          drop_dispatch(socket, dispatch, "not the only live socket for this runner")

        Runners.custody_halted?(socket.assigns.tenant_id) ->
          drop_dispatch(socket, dispatch, "tenant custody halted")

        true ->
          push(socket, "dispatch", dispatch)
          DispatchLedger.mark_pushed(socket.assigns.tenant_id, dispatch.dispatch_id)
          {:noreply, socket}
      end
    end)
  end

  def handle_info(:recheck, socket) do
    %{runner: runner, tenant_id: tenant_id} = socket.assigns

    if Runners.authorized?(tenant_id, runner.id) do
      schedule_recheck()
      {:noreply, socket}
    else
      disconnect(socket, :no_longer_authorized)
    end
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
        {:ok, _record} -> {:reply, :ok, socket}
        {:error, reason} -> refuse(socket, "dispatch_reply", message_error(reason))
      end
    else
      {:error, :rate_limited} -> rate_limited(socket, "dispatch_reply", @reply_refill_ms)
      {:error, reason} -> refuse(socket, "dispatch_reply", message_error(reason))
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
  # a newer runner its event exists and to retry it. What the interval bounds is the
  # REPORTING: at most one telemetry event and one log line per interval, so a runner looping
  # over made-up names cannot buy a log line per frame. The reply is still sent every time.
  defp handle_message(_event, _payload, socket) do
    now = System.monotonic_time(:millisecond)

    case MinInterval.check(socket.assigns.last_unknown_at, now, @unknown_report_interval_ms) do
      :ok ->
        refuse(assign(socket, :last_unknown_at, now), "unknown", %{reason: "unknown_event"})

      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "unknown_event"}}, socket}
    end
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

  defp report_refusal(socket, event, reason) do
    metadata = Logger.metadata()

    :telemetry.execute([:loopctl, :runners, :message_refused], %{count: 1}, %{
      event: event,
      reason: reason,
      tenant_id: Map.get(socket.assigns, :tenant_id),
      runner_id: socket.assigns |> Map.get(:runner, %{}) |> Map.get(:id),
      dispatch_id: metadata[:dispatch_id],
      run_id: metadata[:run_id]
    })

    if reason != "rate_limited" do
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
  defp join_rate_ok(runner) do
    if Loopctl.RateLimiter.gate_ok?("runner_join:" <> runner.id, @join_window_ms, @max_joins),
      do: :ok,
      else: {:error, :join_rate_limited}
  end

  defp enrolled_machine(%{machine: machine}, %{name: machine}), do: :ok

  defp enrolled_machine(%{machine: declared}, _runner),
    do: {:error, {:machine_mismatch, declared}}

  # `node` and `machine_id` answer "which node holds this runner": two Fly machines can share
  # a node name, so the machine id is the one that tells them apart.
  defp presence_meta(meta, runner) do
    Map.merge(meta, %{
      runner_id: runner.id,
      node: Runners.node_name(),
      machine_id: Runners.machine_id()
    })
  end

  # This socket is tracked, and its meta is the only one in the tenant's pool holding the
  # runner's id. An untracked channel (no ref yet) is never the sole socket.
  defp sole_live_socket?(%{assigns: %{presence_ref: ref, runner: runner, tenant_id: tenant_id}})
       when is_binary(ref) do
    match?([%{phx_ref: ^ref}], Runners.live_metas(tenant_id, runner.id))
  end

  defp sole_live_socket?(_socket), do: false

  defp drop_dispatch(socket, dispatch, why) do
    Logger.warning(
      "runner #{socket.assigns.runner.id} dispatch #{dispatch.dispatch_id} dropped: #{why} " <>
        "tenant_id=#{socket.assigns.tenant_id} story_id=#{dispatch.story_id} " <>
        "claim_epoch=#{dispatch.claim_epoch}"
    )

    {:noreply, socket}
  end

  defp schedule_recheck, do: Process.send_after(self(), :recheck, @recheck_interval_ms)

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

  defp join_error(:not_authorized),
    do: %{reason: "not_authorized", disconnecting: "join_refused_not_authorized"}

  defp join_error(:join_rate_limited),
    do: %{reason: "rate_limited", max_joins: @max_joins, window_ms: @join_window_ms}

  defp join_error({:invalid, messages}), do: %{reason: "invalid_payload", details: messages}

  defp join_error({:unsupported_contract_version, sent, speaks}),
    do: %{reason: "unsupported_contract_version", sent: sent, supported: speaks}

  defp join_error({:machine_mismatch, declared}),
    do: %{reason: "machine_mismatch", declared: declared}

  # The stable codes of `RunnerContract.error_reasons/0`.
  defp message_error({:batch_too_large, max_events, max_bytes}),
    do: %{reason: "batch_too_large", max_events: max_events, max_bytes: max_bytes}

  defp message_error({:event_data_too_large, seq, max_data_bytes, max_event_bytes}),
    do: %{
      reason: "event_data_too_large",
      seq: seq,
      max_data_bytes: max_data_bytes,
      max_event_bytes: max_event_bytes
    }

  defp message_error(reason)
       when reason in [
              :unknown_dispatch,
              :stale_claim_epoch,
              :already_replied,
              :dispatch_not_accepted,
              :run_mismatch
            ],
       do: %{reason: Atom.to_string(reason)}

  # A value the contract let through and Postgres still refused (DispatchLedger's backstop).
  defp message_error(:rejected_by_database),
    do: %{reason: "invalid_payload", details: ["a value was refused by the database"]}

  defp message_error(reason), do: join_error(reason)
end
