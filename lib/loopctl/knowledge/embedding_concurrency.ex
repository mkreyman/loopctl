defmodule Loopctl.Knowledge.EmbeddingConcurrency do
  @moduledoc """
  Hard per-node cap on concurrent OUTBOUND embedding calls (US-37.2, GH #352).

  ## Why

  The default `combined` knowledge search embeds the query SYNCHRONOUSLY in the
  web/MCP request process. Before this cap that embed ran under a bare, un-pooled,
  un-capped `Task.async`, so a spike spawned UNBOUNDED concurrent outbound embedding
  calls — the Oban `embeddings: 5` queue cap only bounds BACKGROUND embeds and was
  illusory for interactive traffic, feeding the provider 429 storm. This gate makes
  the per-node ceiling REAL: EVERY `generate_embedding` entry point — the interactive
  query path AND both Oban embedding workers
  (`ArticleEmbeddingWorker`/`MemoryEmbeddingWorker`) — funnels through
  `Loopctl.Knowledge.run_embedding_task/3`, which `acquire/1`s a slot here before
  spawning its supervised task and `release/1`s it after. Over the cap, `acquire/1`
  fast-fails with `{:error, :rate_limited_local}` (the breaker-exempt reason shared
  with the US-37.1 admission gate): the interactive path degrades to keyword search
  (same fallback as `:circuit_open`), and a background worker snoozes loss-free.

  Complement to `Loopctl.Provider.Admission` (US-37.1): admission is a rate-over-time
  bucket (RPM); this is a SIMULTANEOUS-in-flight semaphore. Both are node-local
  defensive ceilings against a runaway burst, both fail SAFE.

  ## Two caps enforced atomically (global + per-tenant fairness)

  Mirroring `Loopctl.Knowledge.ExportConcurrency`, TWO independent caps are checked
  together, so one tenant's burst can't silently starve every other tenant's
  semantic search (the same isolation posture as the per-tenant embedding circuit
  breaker — a failing/bursting tenant degrades ITSELF, not its neighbours):

    * a GLOBAL cap (`"embedding_max_concurrent"`, default #{10}) — the TOTAL in-flight
      outbound embeds across all tenants on this node; and
    * a PER-TENANT cap (`"embedding_max_concurrent_per_tenant"`, default #{6}) — so a
      single tenant firing many interactive searches can consume at most its share of
      the global budget, always leaving slots for other tenants. Over EITHER cap,
      `acquire/1` refuses with `{:error, :rate_limited_local}` (keyword fallback /
      worker snooze) — never a 500, never a blocking wait.

  ## Cap sizing (env-driven, live-tunable, no deploy)

  Both caps are read via
  `Loopctl.SystemConfig.get_int(<key>, <default>)`, so an operator can retune them
  during an incident with no deploy (mirrors the US-37.1 admission RPM knobs). The
  in-code defaults apply on a SystemConfig cache miss, and each fallback is itself
  `Application.get_env`-backed so `config/test.exs` can raise a high suite-wide
  default (stops incidental parallel searches colliding on the shared VM-wide
  counters — the export-cap precedent).

  ### Why global `#{10}` / per-tenant `#{6}`

  Because BOTH the query path and the two workers acquire the SAME slot, the global
  cap is the TOTAL node ceiling for outbound embeds. The background `embeddings`
  Oban queue is 5; the interactive path was previously unbounded. `10` keeps
  interactive + background embedding concurrency bounded together at roughly 2x the
  background queue — enough headroom that a normal search never waits on a slot,
  while still shedding a runaway interactive burst well below the provider's hard
  ceiling. The per-tenant `#{6}` is generous enough that a single active tenant on an
  otherwise-idle node is not unduly throttled, while guaranteeing no single tenant
  can occupy more than 6 of the 10 slots — so a neighbour always retains capacity.
  Both live-tunable up/down per environment.

  ## Design (mirrors `Loopctl.Knowledge.ExportConcurrency`)

  A single supervised GenServer owns a public, named ETS table holding the in-flight
  counters. WRITES (acquire/release) are SERIALIZED through the GenServer's
  `handle_call`: this makes each check-cap → increment → register-monitor (and the
  symmetric demonitor → decrement) ONE atomic step, so a concurrent acquire can never
  interleave between the increment and the monitor and leak an unmonitored slot. Only
  the counter READS (`count/0`, `global_count/0`, `tenant_count/1`) bypass the
  GenServer with a direct, lock-free `:ets.lookup`. At `cap = 10` with network-bound
  embeds the serialized writes are not a real throughput bottleneck — the GenServer's
  job is correctness (atomic reservation) and crash-safety (monitoring), not raw
  write throughput. The GenServer also OWNS the table so it survives the transient
  request/worker process that incremented it, and MONITORS acquirers: an acquirer that
  crashes WITHOUT calling `release/1` would otherwise leak its slot forever, drifting
  the effective cap up; a `:DOWN` reclaims the leaked slot. The slot is charged to the
  CALLING process (the request/worker running `run_embedding_task/3`, which acquires →
  runs the task → releases synchronously), NOT to the off-process supervised task.

  ## Node-local by design

  One set of counters per node — distributed coordination is explicitly OUT OF SCOPE
  (Epic 38, #353). The effective fleet ceiling is `cap * node_count`.
  """

  use GenServer

  @behaviour Loopctl.Knowledge.EmbeddingConcurrency.Behaviour

  require Logger

  alias Loopctl.SystemConfig

  @table :loopctl_embedding_inflight
  @global_key :__global__
  @config_key "embedding_max_concurrent"
  @per_tenant_config_key "embedding_max_concurrent_per_tenant"
  @default_max 10
  @default_per_tenant 6

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Tries to reserve one outbound-embedding slot for `tenant_id`, charged to the
  CALLING process (monitored for crash-safe release), against the configured global
  (`max_concurrent/0`) AND per-tenant (`max_per_tenant/0`) caps.

  Returns `:ok` when BOTH the node-wide in-flight count and this tenant's in-flight
  count are below their caps (the counters are incremented atomically) or
  `{:error, :rate_limited_local}` when EITHER cap is already met (no counter is left
  incremented). Non-blocking — fails fast at the cap. Pair every successful
  `acquire/1` with a `release/1`.
  """
  @impl Loopctl.Knowledge.EmbeddingConcurrency.Behaviour
  @spec acquire(binary()) :: :ok | {:error, :rate_limited_local}
  def acquire(tenant_id) when is_binary(tenant_id) do
    acquire(tenant_id, max_concurrent(), max_per_tenant())
  end

  @doc """
  Like `acquire/1`, but reserves against EXPLICIT `global_max` / `tenant_max` caps
  instead of the configured ones.

  Production always uses `acquire/1` (which reads `max_concurrent/0` /
  `max_per_tenant/0`). This variant exists for the gate's OWN unit tests: the async
  suite sets deliberately HIGH `:embedding_max_concurrent[_per_tenant]` (see
  `config/test.exs`) so incidental parallel searches never collide on the shared,
  VM-wide global counter — so a test that must PROVE the cap refuses over-cap acquires
  passes its own fixed LOW caps here, independent of those high suite defaults. Mirrors
  `ExportConcurrency.acquire/3`.

  CRASH-SAFE: if this GenServer is down (so the `call` would `:exit` — e.g. a restart
  storm during exactly the burst this gate defends against, or app shutdown), the exit
  is caught and converted to `{:error, :rate_limited_local}`. This is the fail-SAFE
  direction: an unverifiable cap degrades the interactive path to keyword search (same
  as any over-cap refusal) rather than raising an unguarded `:exit` that would 500 the
  request (`run_embedding_task/3` calls `acquire/1` OUTSIDE the supervised task, so no
  `async_nolink` isolates it — only this guard does). Symmetric with `release/1`, which
  swallows the same exit.
  """
  @spec acquire(binary(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited_local}
  def acquire(tenant_id, global_max, tenant_max)
      when is_binary(tenant_id) and is_integer(global_max) and global_max > 0 and
             is_integer(tenant_max) and tenant_max > 0 do
    GenServer.call(__MODULE__, {:acquire, self(), tenant_id, global_max, tenant_max})
  catch
    :exit, _ -> {:error, :rate_limited_local}
  end

  @doc """
  Releases the slot previously reserved by `acquire/1` for `tenant_id` on the calling
  process.

  The decrement is performed EXACTLY ONCE per acquisition by the GenServer, gated on
  the caller still being tracked: a synchronous `call` (not a `cast`) with a
  `[:flush]` demonitor ensures an in-flight `:DOWN` for the same pid can't ALSO
  decrement — keeping the shared counters from being decremented twice (which would
  under-count in-flight embeds and admit MORE than the cap). Idempotent: releasing
  again (or without a prior successful acquire) is a no-op.

  CRASH-SAFE: if this GenServer is down (so the `call` would `:exit`), `release/1`
  swallows the exit and returns `:ok` — it is invoked from an `after` block in
  `run_embedding_task/3`, and a raised `:exit` there would MASK the embedding
  result. A dead GenServer is itself a restart that resets the counters, so nothing
  leaks.
  """
  @impl Loopctl.Knowledge.EmbeddingConcurrency.Behaviour
  @spec release(binary()) :: :ok
  def release(tenant_id) when is_binary(tenant_id) do
    GenServer.call(__MODULE__, {:release, self(), tenant_id})
  catch
    :exit, _ -> :ok
  end

  @doc "Current node-wide in-flight embedding count (for tests/telemetry)."
  @spec count() :: non_neg_integer()
  def count, do: counter(@global_key)

  @doc "Alias of `count/0` — current global in-flight embedding count."
  @spec global_count() :: non_neg_integer()
  def global_count, do: counter(@global_key)

  @doc "Current in-flight embedding count for `tenant_id` (for tests/telemetry)."
  @spec tenant_count(binary()) :: non_neg_integer()
  def tenant_count(tenant_id) when is_binary(tenant_id), do: counter(tenant_key(tenant_id))

  @doc """
  Configured per-node GLOBAL concurrent-embedding cap.

  Live-tunable via the `"embedding_max_concurrent"` `SystemConfig` key (DB-backed,
  hot-path-safe); on a cache miss it falls back to the `:embedding_max_concurrent`
  application env (default `#{@default_max}`).
  """
  @spec max_concurrent() :: pos_integer()
  def max_concurrent do
    SystemConfig.get_int(@config_key, config_default())
  end

  @doc """
  Configured PER-TENANT concurrent-embedding cap.

  Live-tunable via the `"embedding_max_concurrent_per_tenant"` `SystemConfig` key;
  on a cache miss it falls back to the `:embedding_max_concurrent_per_tenant`
  application env (default `#{@default_per_tenant}`).
  """
  @spec max_per_tenant() :: pos_integer()
  def max_per_tenant do
    SystemConfig.get_int(@per_tenant_config_key, per_tenant_default())
  end

  @doc false
  def table_name, do: @table

  defp config_default,
    do: Application.get_env(:loopctl, :embedding_max_concurrent, @default_max)

  defp per_tenant_default,
    do: Application.get_env(:loopctl, :embedding_max_concurrent_per_tenant, @default_per_tenant)

  # --- Server callbacks ---

  @impl GenServer
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

  @impl GenServer
  def handle_call({:acquire, pid, tenant_id, global_max, tenant_max}, _from, state) do
    # Re-entrant guard (review #5): if this pid is ALREADY tracked it holds a slot,
    # so a second acquire must NOT increment again — that would over-count the
    # semaphore and permanently leak a slot on the single release/:DOWN. Currently
    # unreachable (run_embedding_task/3 acquires → runs → releases synchronously, so
    # a pid never holds two concurrent slots), but gated here BEFORE reserve_slots so
    # the counters and the monitor map can never diverge under any future re-entrant
    # reuse. One in-flight slot per caller pid is the invariant the accounting relies
    # on.
    if Map.has_key?(state.pids, pid) do
      {:reply, :ok, state}
    else
      # Atomic slot reservation: check BOTH caps AND increment AND register the
      # monitor in ONE serialized GenServer operation, so a caller crash can never
      # interleave between the increment and the monitor (no unmonitored leaked slot).
      case reserve_slots(state.table, tenant_id, global_max, tenant_max) do
        :ok -> {:reply, :ok, track(state, pid, tenant_id)}
        {:error, :rate_limited_local} = err -> {:reply, err, state}
      end
    end
  end

  @impl GenServer
  def handle_call({:release, pid, tenant_id}, _from, state) do
    # EXACTLY-ONCE decrement, gated on the pid still being tracked. Demonitor with
    # [:flush] to purge any already-queued :DOWN for this pid so the :DOWN handler
    # can't ALSO decrement. If the pid is NOT tracked (a :DOWN already reclaimed it,
    # or a double-release), this is a no-op — the counters are never over-decremented.
    case Map.get(state.pids, pid) do
      nil ->
        {:reply, :ok, state}

      ref ->
        Process.demonitor(ref, [:flush])
        decrement(tenant_id)
        {:reply, :ok, untrack(state, ref, pid)}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # An acquirer crashed without releasing — reclaim its leaked slot so the cap
    # doesn't drift up permanently. Gated on still being tracked (a concurrent
    # release/1 may have already demonitored+decremented), so the decrement is
    # exactly-once with release.
    case Map.get(state.monitors, ref) do
      {^pid, tenant_id} ->
        decrement(tenant_id)
        Logger.warning("embedding concurrency: reclaimed leaked slot for crashed caller")
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
      {:error, :rate_limited_local}
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
      {:error, :rate_limited_local}
    else
      :ok
    end
  end

  # Register the crash-safe monitor. One in-flight acquire per caller pid:
  # `run_embedding_task/3` acquires → runs → releases synchronously, so a pid is
  # never tracked twice concurrently (and the handle_call re-entrant guard rejects a
  # second acquire before this runs). `Process.monitor` on an already-dead pid still
  # returns a ref and immediately delivers `:DOWN`, which the handler reclaims — so
  # there is no leak even if the caller died before this ran.
  defp track(state, pid, tenant_id) do
    ref = Process.monitor(pid)

    %{
      state
      | monitors: Map.put(state.monitors, ref, {pid, tenant_id}),
        pids: Map.put(state.pids, pid, ref)
    }
  end

  defp untrack(state, ref, pid) do
    %{state | monitors: Map.delete(state.monitors, ref), pids: Map.delete(state.pids, pid)}
  end

  # Decrement both counters, clamped at zero. With the exactly-once gating the clamp
  # should never fire, but it's kept as defense-in-depth so a stray decrement can
  # never drive a counter negative (which would inflate the effective cap). Called
  # ONLY from the GenServer process (release/DOWN), so decrements are serialized.
  defp decrement(tenant_id) do
    dec_floor(@global_key)
    dec_floor(tenant_key(tenant_id))
    :ok
  end

  defp dec_floor(key) do
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
