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

    # Reserve the slots ONLY IF the monitor registration succeeds atomically.
    # Use a GenServer call to atomically (on the server) check the caps, increment
    # the counters IF both pass, and register the monitor — all in one operation.
    # If ANY of these fail, the counters are never incremented. This prevents a
    # monitor-setup failure from leaving an incremented but unmonitored slot (#4).
    GenServer.call(__MODULE__, {:acquire, self(), tenant_id, global_max, tenant_max})
  end

  @doc """
  Releases the streaming-export slot previously reserved by `acquire/1` for
  `tenant_id` on the calling process.

  The decrement is performed EXACTLY ONCE per acquisition by the GenServer, gated
  on the caller still being tracked: a synchronous `call` (not a `cast` + a
  separate ETS write) ensures that an in-flight `:DOWN` for the same pid can't
  ALSO decrement (the GenServer demonitors with `[:flush]`, purging a queued
  `:DOWN`, and removes the pid from tracking before returning). This is what keeps
  the SHARED GLOBAL counter from being decremented twice — a double-decrement would
  under-count in-flight exports and admit MORE than `max_global/0`.

  Idempotent: calling it again (or without a prior successful acquire) is a no-op,
  because the pid is no longer tracked.

  CRASH-SAFE: if the `ExportConcurrency` GenServer is down (so the `call` would
  `:exit`), `release/1` swallows the exit and returns `:ok` — it is invoked from the
  controller's `after` block, and a raised `:exit` there would MASK the streaming
  body's real error (#4). A dead GenServer is itself a restart event that resets the
  counters, so nothing leaks.
  """
  @spec release(binary()) :: :ok
  def release(tenant_id) when is_binary(tenant_id) do
    GenServer.call(__MODULE__, {:release, self(), tenant_id})
  catch
    :exit, _ -> :ok
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
  def handle_call({:acquire, pid, tenant_id, global_max, tenant_max}, _from, state) do
    # Atomic slot reservation (#4): check the caps AND increment the counters AND
    # register the monitor all in ONE serialized GenServer operation, so a caller
    # crash can never interleave between the increment and the monitor (no
    # unmonitored leaked slot). `reserve_slots/4` does the increment-check-undo;
    # `track/3` registers the crash-safe monitor.
    case reserve_slots(state.table, tenant_id, global_max, tenant_max) do
      :ok -> {:reply, :ok, track(state, pid, tenant_id)}
      {:error, :too_many_exports} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:release, pid, tenant_id}, _from, state) do
    # EXACTLY-ONCE decrement, gated on the pid still being tracked. If it is, this
    # release owns the decrement; we demonitor with [:flush] to purge any already-
    # queued :DOWN for this pid so the :DOWN handler can't ALSO decrement. If the
    # pid is NOT tracked (a :DOWN already reclaimed it, or a double-release), this
    # is a no-op — the global counter is never decremented twice.
    case Map.get(state.pids, pid) do
      nil ->
        {:reply, :ok, state}

      ref ->
        Process.demonitor(ref, [:flush])
        decrement(tenant_id)
        {:reply, :ok, untrack(state, ref, pid)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # An acquirer crashed without releasing — reclaim its leaked slot so the cap
    # doesn't drift up permanently. Gated on still being tracked (a concurrent
    # release/1 may have already demonitored+decremented), so the decrement is
    # exactly-once with release.
    case Map.get(state.monitors, ref) do
      {^pid, tenant_id} ->
        decrement(tenant_id)
        Logger.warning("export concurrency: reclaimed leaked slot for crashed exporter")
        {:noreply, untrack(state, ref, pid)}

      _ ->
        {:noreply, state}
    end
  end

  # --- Private ---

  # Increment global then per-tenant; undo on either over-cap. Net: a successful
  # reserve leaves BOTH incremented, a failed one leaves NEITHER. Called only from
  # the (serialized) GenServer, so the increment-check-undo is atomic w.r.t. other
  # acquires.
  defp reserve_slots(table, tenant_id, global_max, tenant_max) do
    global_now = :ets.update_counter(table, @global_key, {2, 1}, {@global_key, 0})

    if global_now > global_max do
      :ets.update_counter(table, @global_key, {2, -1}, {@global_key, 0})
      {:error, :too_many_exports}
    else
      reserve_tenant_slot(table, tenant_id, tenant_max)
    end
  end

  defp reserve_tenant_slot(table, tenant_id, tenant_max) do
    key = tenant_key(tenant_id)
    tenant_now = :ets.update_counter(table, key, {2, 1}, {key, 0})

    if tenant_now > tenant_max do
      :ets.update_counter(table, key, {2, -1}, {key, 0})
      :ets.update_counter(table, @global_key, {2, -1}, {@global_key, 0})
      {:error, :too_many_exports}
    else
      :ok
    end
  end

  # Register the crash-safe monitor (one per pid — one export per request process).
  # `Process.monitor` on an already-dead pid still returns a ref and immediately
  # delivers `:DOWN`, which the handler reclaims — so there is no leak even if the
  # request pid died before this ran.
  defp track(state, pid, tenant_id) do
    case Map.get(state.pids, pid) do
      nil ->
        ref = Process.monitor(pid)

        %{
          state
          | monitors: Map.put(state.monitors, ref, {pid, tenant_id}),
            pids: Map.put(state.pids, pid, ref)
        }

      _ref ->
        state
    end
  end

  defp untrack(state, ref, pid) do
    %{state | monitors: Map.delete(state.monitors, ref), pids: Map.delete(state.pids, pid)}
  end

  # Decrement both counters, clamped at zero. With the exactly-once gating in the
  # GenServer the clamp should never actually fire, but it's kept as defense-in-depth
  # so a stray decrement can never drive a counter negative (which would inflate the
  # effective cap). Called ONLY from the GenServer process (release/DOWN), so the
  # two decrements are serialized — never a concurrent double-decrement.
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
