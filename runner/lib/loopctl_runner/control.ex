defmodule LoopctlRunner.Control do
  @moduledoc """
  The runner's outbound connection to loopctl (build order step 1b, design §2 and §7).

  A client, never a cluster peer. It connects to `/runner/socket/websocket` with the
  token in the `x-loopctl-runner-token` header, joins its own topic `runner:<runner_id>`
  with a `RunnerJoin` payload, and pushes a `RunnerStatus` every `status_interval_s`.
  loopctl tracks the joined channel in its tenant-scoped Presence set; the channel dying
  with the socket IS the liveness signal, so there is nothing here to deregister.

  Every outgoing payload is validated against the vendored contract first, and every join
  — rejoins included — carries a freshly built payload: a rejoin that replayed the first
  join's payload would tell loopctl stale `draining`, `in_flight` and sample values.

  ## Draining until dispatches are accepted

  This runner has no dispatch accept path yet (design build order step 6). While
  `:accepts_dispatches` is false — the default, and the only production setting until then — it
  reports `draining: true` whatever `set_draining/2` was told, so the control plane never
  reserves capacity here for a session that would not start.

  A `dispatch` that does arrive is validated and refused back to loopctl with a
  `dispatch_reply` (contract 1.1): `dispatches_disabled` for a valid one, `other` with the
  validation errors for a malformed one that still carries its `dispatch_id` and `claim_epoch`.
  Every reply is routed by the ref of the push it answers, so a rate-limited `dispatch_reply`
  is never mistaken for a status. Rate-limited replies wait in a backlog sent one per the
  contract's burst refill interval by a single timer. A reply loopctl had not recorded when the
  channel closed is kept and resent after the rejoin: loopctl does not dispatch again, and it
  answers an identical repeat `ok`.

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

  alias LoopctlRunner.{Config, Contract, ControlConfig, Health, Runs, TraceShip}

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
    do: build_join(config, capacity, draining?, accepts?, measure(config))

  defp build_join(%Config{control: control} = config, capacity, draining?, accepts?, measured) do
    payload =
      %{
        "contract_version" => Contract.version(),
        "machine" => control.machine,
        "cores" => capacity["cores"],
        "memory_mb" => capacity["memory_mb"],
        "repos" => control.repos,
        "max_sessions" => control.max_sessions,
        "in_flight" => Runs.in_flight(config.runs_dir),
        "draining" => reported_draining(draining?, accepts?)
      }
      |> put_sample(measured)

    with :ok <- Contract.validate("RunnerJoin", payload), do: {:ok, payload}
  end

  @doc "The `RunnerStatus` payload, validated against the contract."
  @spec status_payload(Config.t(), boolean(), boolean()) :: {:ok, map()} | {:error, [String.t()]}
  def status_payload(%Config{} = config, draining?, accepts? \\ false),
    do: build_status(config, draining?, accepts?, measure(config))

  defp build_status(config, draining?, accepts?, measured) do
    payload =
      %{
        "in_flight" => Runs.in_flight(config.runs_dir),
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
            # No dispatch accept path exists yet (loopctl#803); an option so the draining
            # value is observable in tests before it does.
            accepts_dispatches: Keyword.get(opts, :accepts_dispatches, false),
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

        {:ok, socket, {:continue, :connect}}

      {:error, reason} ->
        {:stop, {:shutdown, {:capacity_unreadable, reason}}}
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
     |> schedule_trace(0, true)}
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
      # loopctl replays nothing on a rejoin: every cursor is asked again on the next channel.
      trace_positions: %{},
      trace_runs: nil,
      trace_push: nil,
      trace_timer: cancel_reply_timer(socket.assigns.trace_timer)
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

    case build_status(a.config, a.draining, a.accepts_dispatches, measured) do
      {:ok, payload} ->
        case push(socket, a.topic, "status", payload) do
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

  # One trace step per tick, and only the current timer's tick on a joined channel.
  def handle_info(
        {:trace_tick, token, refresh?},
        %{assigns: %{joined: true, trace_timer: {_timer, token}}} = socket
      ),
      do: {:noreply, socket |> assign(trace_timer: nil) |> trace_step(refresh?)}

  def handle_info({:trace_tick, _stale_token, _refresh?}, socket), do: {:noreply, socket}

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
        trace_acked:
          Map.new(a.trace_positions, fn {run_id, %{acked: acked}} -> {run_id, acked} end),
        trace_push_pending: a.trace_push != nil,
        # The value this runner reports, which is not the set_draining/2 flag while no dispatch
        # can be accepted. It is what the next status carries, not proof loopctl received it:
        # runner_pool can lag it while a push is pending, rate-limited or lost with the socket.
        draining: reported_draining(a.draining, a.accepts_dispatches),
        accepts_dispatches: a.accepts_dispatches
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

      match?(%{ref: ^ref}, socket.assigns.trace_push) ->
        {:ok, trace_answered(reply, socket)}

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

    case reply do
      {:error, %{"reason" => "rate_limited"}} ->
        backlog = socket.assigns.reply_backlog ++ [{payload, story_id, carried?}]

        Logger.info(
          "loopctl rate-limited a dispatch_reply; #{length(backlog)} in the backlog, " <>
            "sent one every #{socket.assigns.dispatch_reply_retry_ms}ms",
          ids
        )

        {:ok, socket |> assign(reply_backlog: backlog) |> schedule_reply_backlog()}

      # A reply carried across a rejoin may find the question settled meanwhile: the claim moved
      # on, or the first copy was recorded after all. That is the expected end of a resend.
      {:error, %{"reason" => reason}}
      when carried? and reason in ["stale_claim_epoch", "already_replied", "unknown_dispatch"] ->
        Logger.info("loopctl no longer needs the resent dispatch_reply (#{reason})", ids)
        {:ok, socket}

      {:error, %{"reason" => reason} = refusal} ->
        # unknown_dispatch, stale_claim_epoch, already_replied: resending cannot change them.
        Logger.warning("loopctl refused the dispatch_reply (#{reason}): #{inspect(refusal)}", ids)
        {:ok, socket}

      ok when ok == :ok or (is_tuple(ok) and elem(ok, 0) == :ok) ->
        Logger.info(
          "loopctl recorded the dispatch_reply: #{payload["decision"]} (#{payload["reason"]})",
          ids
        )

        {:ok, socket}

      # A bare :error (an error reply with an empty body) or one without a reason: still a
      # refusal, and not one resending is known to fix.
      other ->
        Logger.warning(
          "loopctl refused the dispatch_reply without a reason: #{inspect(other)}",
          ids
        )

        {:ok, socket}
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

  # The contract's burst refill: one token comes back every refill interval.
  defp dispatch_reply_retry_ms do
    get_in(Contract.connection(), ["limits", "dispatch_reply_burst", "refill_interval_ms"]) || 250
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
          Logger.warning(
            "dispatch #{payload["dispatch_id"]} received: this runner accepts no dispatches yet " <>
              "(story #{payload["story_id"]}, #{payload["kind"]}, claim_epoch #{payload["claim_epoch"]})"
          )

          # No accept path exists (build order step 6), so every dispatch is refused, and
          # loopctl is told why rather than left waiting on a claim nobody will run.
          refuse_dispatch(socket, payload, %{"reason" => "dispatches_disabled"})

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
    case push(socket, socket.assigns.topic, "dispatch_reply", payload) do
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

      assign(socket,
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

    assign(socket, trace_settled: Map.put(socket.assigns.trace_settled, run.run_id, :abandoned))
  end

  defp push_trace(socket, run, kind, event, payload, next) do
    case push(socket, socket.assigns.topic, event, payload) do
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
      {:ok, %{"acked_seq" => acked}} when is_integer(acked) -> trace_acked(socket, push, acked)
      {:error, %{"reason" => _} = refusal} -> trace_refused(socket, push, refusal)
      other -> trace_unexpected(socket, push, other)
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
    if accept_outstanding?(socket, run.dispatch_id) do
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

  defp trace_refused(socket, push, refusal), do: trace_unexpected(socket, push, {:error, refusal})

  defp accept_outstanding?(socket, dispatch_id) do
    a = socket.assigns
    replies = Map.values(a.dispatch_replies) ++ a.reply_backlog

    Enum.any?(replies, fn {payload, _story_id, _carried?} ->
      payload["dispatch_id"] == dispatch_id and payload["decision"] == "accepted"
    end)
  end

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

    {build_join(a.config, a.capacity, a.draining, a.accepts_dispatches, measured),
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
