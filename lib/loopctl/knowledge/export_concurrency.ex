defmodule Loopctl.Knowledge.ExportConcurrency do
  @moduledoc """
  Hard cap on concurrent in-flight streaming exports (US-27.16, AC-27.16.6).

  A full-KB streaming export holds a `Loopctl.HeavyReadRepo` (BYPASSRLS) checkout
  per page for the WHOLE client-paced download. The heavy pool is small (default 8,
  with only ~2 budgeted for these long-held export checkouts — see
  `config/runtime.exs`). Without a cap, N concurrent exports would each take a
  connection per page and could starve a light admin read (the exact failure
  TC-27.16.5 guards against). So a streaming export must `acquire/1` a slot BEFORE
  it starts streaming and `release/1` when it finishes; over the cap it is refused
  with `{:error, :too_many_exports}` (the controller answers `429`) — it never
  queues against the admin pool.

  Two independent caps are enforced atomically:

    * a GLOBAL cap (`:export_max_concurrent_global`, default #{2}) — total in-flight
      exports across all tenants, sized to the heavy pool's export reservation; and
    * a PER-TENANT cap (`:export_max_concurrent_per_tenant`, default #{1}) — so one
      tenant firing many exports can't consume the whole global budget.

  ## Design (mirrors `Loopctl.RateLimiter.Server`)

  A single GenServer owns a public, named ETS table of in-flight counters; callers
  read/write it directly with `:ets.update_counter` (atomic, lock-free) so the
  GenServer is never a throughput bottleneck. The GenServer exists only to OWN the
  table (so it survives the request process that incremented it) and to monitor
  acquirers: an acquirer that crashes WITHOUT calling `release/1` would otherwise
  leak its slot forever. `acquire/1` therefore registers the calling process for
  monitoring; a `:DOWN` decrements the leaked counters.

  ## Why not the HeavyRead pool's own queueing

  The pool would QUEUE an over-budget export (holding the request open, then
  failing with a checkout timeout) — indistinguishable from genuine DB trouble and
  still pressuring the pool. An explicit pre-flight cap fails FAST and CLEANLY with
  a `429` and a `Retry-After`, off the pool entirely.
  """

  use GenServer

  require Logger

  @table :loopctl_export_inflight
  @global_key :__global__

  @default_global 2
  @default_per_tenant 1

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Tries to reserve a streaming-export slot for `tenant_id`, charged to the CALLING
  process (monitored for crash-safe release).

  Returns `:ok` when both the global and the tenant's per-tenant in-flight counts
  are below their caps (the counters are incremented atomically), or
  `{:error, :too_many_exports}` when either cap is already met (no counter is left
  incremented). Pair every successful `acquire/1` with a `release/1`.
  """
  @spec acquire(binary()) :: :ok | {:error, :too_many_exports}
  def acquire(tenant_id) when is_binary(tenant_id) do
    global_max = max_global()
    tenant_max = max_per_tenant()

    # Reserve the global slot first (atomic increment, then check). If it would
    # exceed, undo immediately. Same for the per-tenant slot; if THAT exceeds, undo
    # both. Net effect: a fully successful acquire leaves both incremented, a failed
    # one leaves neither — no partial reservation can leak.
    global_now = :ets.update_counter(@table, @global_key, {2, 1}, {@global_key, 0})

    if global_now > global_max do
      :ets.update_counter(@table, @global_key, {2, -1}, {@global_key, 0})
      {:error, :too_many_exports}
    else
      acquire_tenant_slot(tenant_id, tenant_max)
    end
  end

  defp acquire_tenant_slot(tenant_id, tenant_max) do
    key = tenant_key(tenant_id)
    tenant_now = :ets.update_counter(@table, key, {2, 1}, {key, 0})

    if tenant_now > tenant_max do
      :ets.update_counter(@table, key, {2, -1}, {key, 0})
      :ets.update_counter(@table, @global_key, {2, -1}, {@global_key, 0})
      {:error, :too_many_exports}
    else
      # Register for crash-safe release: if the caller dies without release/1, the
      # GenServer decrements the slot it reserved.
      GenServer.cast(__MODULE__, {:track, self(), tenant_id})
      :ok
    end
  end

  @doc """
  Releases the streaming-export slot previously reserved by `acquire/1` for
  `tenant_id` on the calling process.

  Decrements both counters (never below zero) and stops monitoring the caller.
  Safe to call at most once per successful `acquire/1`; calling it without a prior
  successful acquire is a no-op at the floor.
  """
  @spec release(binary()) :: :ok
  def release(tenant_id) when is_binary(tenant_id) do
    GenServer.cast(__MODULE__, {:release, self(), tenant_id})
    decrement(tenant_id)
    :ok
  end

  @doc "Current global in-flight export count (for tests/telemetry)."
  @spec global_count() :: non_neg_integer()
  def global_count, do: counter(@global_key)

  @doc "Current in-flight export count for `tenant_id` (for tests/telemetry)."
  @spec tenant_count(binary()) :: non_neg_integer()
  def tenant_count(tenant_id) when is_binary(tenant_id), do: counter(tenant_key(tenant_id))

  @doc "Configured global concurrent-export cap."
  @spec max_global() :: pos_integer()
  def max_global,
    do: Application.get_env(:loopctl, :export_max_concurrent_global, @default_global)

  @doc "Configured per-tenant concurrent-export cap."
  @spec max_per_tenant() :: pos_integer()
  def max_per_tenant,
    do: Application.get_env(:loopctl, :export_max_concurrent_per_tenant, @default_per_tenant)

  @doc false
  def table_name, do: @table

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

        existing ->
          existing
      end

    # monitors: ref -> {pid, tenant_id} ; pids: pid -> ref (so a release can demonitor)
    {:ok, %{table: table, monitors: %{}, pids: %{}}}
  end

  @impl true
  def handle_cast({:track, pid, tenant_id}, state) do
    # Monitor once per pid (a pid runs one export at a time on the request path).
    case Map.get(state.pids, pid) do
      nil ->
        ref = Process.monitor(pid)

        {:noreply,
         %{
           state
           | monitors: Map.put(state.monitors, ref, {pid, tenant_id}),
             pids: Map.put(state.pids, pid, ref)
         }}

      _ref ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:release, pid, _tenant_id}, state) do
    {:noreply, demonitor_pid(state, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # An acquirer crashed without releasing — reclaim its leaked slot so the cap
    # doesn't drift down permanently.
    case Map.get(state.monitors, ref) do
      {^pid, tenant_id} ->
        decrement(tenant_id)
        Logger.warning("export concurrency: reclaimed leaked slot for crashed exporter")

        {:noreply,
         %{state | monitors: Map.delete(state.monitors, ref), pids: Map.delete(state.pids, pid)}}

      _ ->
        {:noreply, state}
    end
  end

  # --- Private ---

  defp demonitor_pid(state, pid) do
    case Map.get(state.pids, pid) do
      nil ->
        state

      ref ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: Map.delete(state.monitors, ref), pids: Map.delete(state.pids, pid)}
    end
  end

  # Decrement both counters, clamped at zero so a double-release or a
  # release-after-crash-reclaim can't drive a counter negative (which would inflate
  # the effective cap).
  defp decrement(tenant_id) do
    dec_floor(@global_key)
    dec_floor(tenant_key(tenant_id))
    :ok
  end

  defp dec_floor(key) do
    # update_counter with a threshold/setvalue: if (count - 1) < 0, set to 0.
    :ets.update_counter(@table, key, {2, -1, 0, 0}, {key, 0})
  end

  defp counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end

  defp tenant_key(tenant_id), do: {:tenant, tenant_id}
end
