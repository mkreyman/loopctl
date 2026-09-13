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
  """

  use LoopctlWeb, :channel

  require Logger

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Runners
  alias Loopctl.Runners.Presence
  alias LoopctlWeb.RunnerSocket

  @recheck_interval_ms 30_000
  @min_status_interval_ms 1_000
  @join_window_ms 60_000
  @max_joins 30

  @impl true
  def join("runner:" <> runner_id, payload, %{assigns: %{runner: %{id: runner_id}}} = socket) do
    %{runner: runner} = socket.assigns

    # Subscribe BEFORE the authorization read: a revoke committing between the two is
    # then either seen by the read or delivered to this process, never lost.
    :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, Runners.revocation_topic(runner.id))

    with :ok <- join_rate_ok(runner),
         :ok <- still_authorized(socket),
         {:ok, meta} <- RunnerContract.cast_join(payload),
         :ok <- enrolled_machine(meta, runner) do
      send(self(), :after_join)

      {:ok, %{contract_version: RunnerContract.version()},
       socket
       |> assign(:meta, Map.put(meta, :joined_at, DateTime.utc_now()))
       |> assign(:last_status_at, :never)
       |> assign(:presence_ref, nil)}
    else
      {:error, reason} -> {:error, join_error(reason)}
    end
  end

  def join("runner:" <> _other, _payload, _socket), do: {:error, %{reason: "forbidden_topic"}}
  def join(_topic, _payload, _socket), do: {:error, %{reason: "unknown_topic"}}

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

    schedule_recheck()
    {:noreply, assign(socket, :presence_ref, ref)}
  end

  def handle_info(:runner_revoked, socket), do: disconnect(socket, :runner_revoked)

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
    cond do
      not sole_live_socket?(socket) ->
        drop_dispatch(socket, dispatch, "not the only live socket for this runner")

      Runners.custody_halted?(socket.assigns.tenant_id) ->
        drop_dispatch(socket, dispatch, "tenant custody halted")

      true ->
        push(socket, "dispatch", dispatch)
        {:noreply, socket}
    end
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
  def handle_in("status", payload, socket) do
    now = System.monotonic_time(:millisecond)

    with :ok <- status_interval_ok(socket.assigns.last_status_at, now),
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
        {:reply, {:error, %{reason: "rate_limited", min_interval_ms: @min_status_interval_ms}},
         socket}

      {:error, reason} ->
        {:reply, {:error, join_error(reason)}, socket}
    end
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unknown_event"}}, socket}

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

  # `:never` rather than 0: monotonic time is negative on a fresh VM, so a 0 sentinel
  # would refuse the first update.
  defp status_interval_ok(:never, _now), do: :ok

  defp status_interval_ok(last, now) when now - last >= @min_status_interval_ms, do: :ok
  defp status_interval_ok(_last, _now), do: {:error, :rate_limited}

  defp presence_meta(meta, runner), do: Map.put(meta, :runner_id, runner.id)

  # This socket is tracked, and its meta is the only one in the tenant's pool holding the
  # runner's id. An untracked channel (no ref yet) is never the sole socket.
  defp sole_live_socket?(%{assigns: %{presence_ref: ref, runner: runner, tenant_id: tenant_id}})
       when is_binary(ref) do
    match?([%{phx_ref: ^ref}], Runners.live_metas(tenant_id, runner.id))
  end

  defp sole_live_socket?(_socket), do: false

  defp drop_dispatch(socket, dispatch, why) do
    Logger.warning(
      "runner #{socket.assigns.runner.id} dispatch #{dispatch.dispatch_id} dropped: #{why}"
    )

    {:noreply, socket}
  end

  defp schedule_recheck, do: Process.send_after(self(), :recheck, @recheck_interval_ms)

  # Disconnecting the SOCKET (not just stopping this channel) keeps a revoked runner from
  # simply rejoining the topic on the connection it already has.
  defp disconnect(socket, reason) do
    Logger.info("runner #{socket.assigns.runner.id} disconnected: #{inspect(reason)}")

    LoopctlWeb.Endpoint.broadcast(
      RunnerSocket.socket_id(socket.assigns.runner.id),
      "disconnect",
      %{}
    )

    {:stop, {:shutdown, reason}, socket}
  end

  defp join_error(:not_authorized), do: %{reason: "not_authorized"}

  defp join_error(:join_rate_limited),
    do: %{reason: "rate_limited", max_joins: @max_joins, window_ms: @join_window_ms}

  defp join_error({:invalid, messages}), do: %{reason: "invalid_payload", details: messages}

  defp join_error({:unsupported_contract_version, sent, speaks}),
    do: %{reason: "unsupported_contract_version", sent: sent, supported: speaks}

  defp join_error({:machine_mismatch, declared}),
    do: %{reason: "machine_mismatch", declared: declared}
end
