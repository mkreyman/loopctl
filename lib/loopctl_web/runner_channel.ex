defmodule LoopctlWeb.RunnerChannel do
  @moduledoc """
  The `"runners"` channel: a runner joins it to enter its tenant's pool (issue #801).

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

  @impl true
  def join("runners", payload, socket) do
    %{runner: runner, tenant_id: tenant_id} = socket.assigns

    # Subscribe BEFORE the authorization read: a revoke committing between the two is
    # then either seen by the read or delivered to this process, never lost.
    :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, Runners.revocation_topic(runner.id))

    with :ok <- still_authorized(tenant_id, runner),
         {:ok, meta} <- RunnerContract.cast_join(payload),
         :ok <- enrolled_machine(meta, runner) do
      send(self(), :after_join)

      {:ok, %{contract_version: RunnerContract.version()},
       socket
       |> assign(:meta, Map.put(meta, :joined_at, DateTime.utc_now()))
       |> assign(:last_status_at, :never)}
    else
      {:error, reason} -> {:error, join_error(reason)}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_info(:after_join, socket) do
    %{runner: runner, tenant_id: tenant_id, meta: meta} = socket.assigns

    {:ok, _ref} =
      Presence.track(
        self(),
        Runners.pool_topic(tenant_id),
        runner.name,
        presence_meta(meta, runner)
      )

    schedule_recheck()
    {:noreply, socket}
  end

  def handle_info(:runner_revoked, socket), do: disconnect(socket, :runner_revoked)

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

      {:ok, _ref} =
        Presence.update(
          self(),
          Runners.pool_topic(tenant_id),
          runner.name,
          presence_meta(meta, runner)
        )

      {:reply, :ok, socket |> assign(:meta, meta) |> assign(:last_status_at, now)}
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
  defp still_authorized(tenant_id, runner) do
    if Runners.authorized?(tenant_id, runner.id), do: :ok, else: {:error, :not_authorized}
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

  defp join_error({:invalid, messages}), do: %{reason: "invalid_payload", details: messages}

  defp join_error({:unsupported_contract_version, sent, speaks}),
    do: %{reason: "unsupported_contract_version", sent: sent, supported: speaks}

  defp join_error({:machine_mismatch, declared}),
    do: %{reason: "machine_mismatch", declared: declared}
end
