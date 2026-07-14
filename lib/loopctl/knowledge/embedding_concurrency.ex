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
  `Loopctl.Knowledge.run_embedding_task/3`, which `acquire/0`s a slot here before
  spawning its supervised task and `release/0`s it after. Over the cap, `acquire/0`
  fast-fails with `{:error, :rate_limited_local}` (the breaker-exempt reason shared
  with the US-37.1 admission gate): the interactive path degrades to keyword search
  (same fallback as `:circuit_open`), and a background worker snoozes loss-free.

  Complement to `Loopctl.Provider.Admission` (US-37.1): admission is a rate-over-time
  bucket (RPM); this is a SIMULTANEOUS-in-flight semaphore. Both are node-local
  defensive ceilings against a runaway burst, both fail SAFE.

  ## Cap sizing (env-driven, live-tunable, no deploy)

  A SINGLE GLOBAL per-node counter — the AC requires only a node-wide `N`, not a
  per-tenant dimension (embedding calls stay tenant-scoped, but the CONCURRENCY
  ceiling is node-global). The cap is read via
  `Loopctl.SystemConfig.get_int("embedding_max_concurrent", <default>)`, so an
  operator can retune it during an incident with no deploy (mirrors the
  US-37.1 admission RPM knobs). The in-code default (`#{10}`) applies on a
  SystemConfig cache miss, and the fallback itself is `Application.get_env`-backed
  so `config/test.exs` can raise a high suite-wide default (stops incidental
  parallel searches colliding on the shared VM-wide counter — the export-cap
  precedent).

  ### Why `#{10}`

  Because BOTH the query path and the two workers now acquire the SAME slot, this
  cap is the TOTAL node ceiling for outbound embeds. The background `embeddings`
  Oban queue is 5; the interactive path was previously unbounded. `10` keeps
  interactive + background embedding concurrency bounded together at roughly 2x
  the background queue — enough headroom that a normal search never waits on a
  slot, while still shedding a runaway interactive burst well below the provider's
  hard ceiling. Live-tunable up/down per environment.

  ## Design (mirrors `Loopctl.Knowledge.ExportConcurrency`)

  A single supervised GenServer owns a public, named ETS table holding one
  in-flight counter; callers mutate it with atomic `:ets.update_counter` (lock-free)
  so the GenServer is never a throughput bottleneck. The GenServer exists only to
  OWN the table (so it survives the transient request/worker process that
  incremented it) and to MONITOR acquirers: an acquirer that crashes WITHOUT
  calling `release/0` would otherwise leak its slot forever, drifting the effective
  cap up. `acquire/0` registers the calling process for monitoring; a `:DOWN`
  reclaims the leaked slot. The slot is charged to the CALLING process (the
  request/worker running `run_embedding_task/3`, which acquires → runs the task →
  releases synchronously), NOT to the off-process supervised task.

  ## Node-local by design

  One counter per node — distributed coordination is explicitly OUT OF SCOPE
  (Epic 38, #353). The effective fleet ceiling is `cap * node_count`.
  """

  use GenServer

  @behaviour Loopctl.Knowledge.EmbeddingConcurrency.Behaviour

  require Logger

  alias Loopctl.SystemConfig

  @table :loopctl_embedding_inflight
  @global_key :__global__
  @config_key "embedding_max_concurrent"
  @default_max 10

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Tries to reserve one outbound-embedding slot for the CALLING process (monitored
  for crash-safe release), against the configured cap (`max_concurrent/0`).

  Returns `:ok` when the node-wide in-flight count is below the cap (the counter is
  incremented atomically) or `{:error, :rate_limited_local}` when the cap is already
  met (no counter left incremented). Non-blocking — fails fast at the cap. Pair
  every successful `acquire/0` with a `release/0`.
  """
  @impl Loopctl.Knowledge.EmbeddingConcurrency.Behaviour
  @spec acquire() :: :ok | {:error, :rate_limited_local}
  def acquire, do: acquire(max_concurrent())

  @doc """
  Like `acquire/0`, but reserves against an EXPLICIT `max` cap instead of the
  configured one.

  Production always uses `acquire/0` (which reads `max_concurrent/0`). This variant
  exists for the gate's OWN unit tests: the async suite sets a deliberately HIGH
  `:embedding_max_concurrent` (see `config/test.exs`) so incidental parallel
  searches never collide on the shared, VM-wide global counter — so a test that
  must PROVE the cap refuses over-cap acquires passes its own fixed LOW cap here,
  independent of that high suite default. Mirrors `ExportConcurrency.acquire/3`.
  """
  @spec acquire(pos_integer()) :: :ok | {:error, :rate_limited_local}
  def acquire(max) when is_integer(max) and max > 0 do
    GenServer.call(__MODULE__, {:acquire, self(), max})
  end

  @doc """
  Releases the slot previously reserved by `acquire/0` on the calling process.

  The decrement is performed EXACTLY ONCE per acquisition by the GenServer, gated on
  the caller still being tracked: a synchronous `call` (not a `cast`) with a
  `[:flush]` demonitor ensures an in-flight `:DOWN` for the same pid can't ALSO
  decrement — keeping the shared counter from being decremented twice (which would
  under-count in-flight embeds and admit MORE than the cap). Idempotent: releasing
  again (or without a prior successful acquire) is a no-op.

  CRASH-SAFE: if this GenServer is down (so the `call` would `:exit`), `release/0`
  swallows the exit and returns `:ok` — it is invoked from an `after` block in
  `run_embedding_task/3`, and a raised `:exit` there would MASK the embedding
  result. A dead GenServer is itself a restart that resets the counter, so nothing
  leaks.
  """
  @impl Loopctl.Knowledge.EmbeddingConcurrency.Behaviour
  @spec release() :: :ok
  def release do
    GenServer.call(__MODULE__, {:release, self()})
  catch
    :exit, _ -> :ok
  end

  @doc "Current node-wide in-flight embedding count (for tests/telemetry)."
  @spec count() :: non_neg_integer()
  def count, do: counter(@global_key)

  @doc """
  Configured per-node concurrent-embedding cap.

  Live-tunable via the `"embedding_max_concurrent"` `SystemConfig` key (DB-backed,
  hot-path-safe); on a cache miss it falls back to the `:embedding_max_concurrent`
  application env (default `#{@default_max}`).
  """
  @spec max_concurrent() :: pos_integer()
  def max_concurrent do
    SystemConfig.get_int(@config_key, config_default())
  end

  @doc false
  def table_name, do: @table

  defp config_default,
    do: Application.get_env(:loopctl, :embedding_max_concurrent, @default_max)

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

    # monitors: ref -> pid ; pids: pid -> ref (so a release can demonitor)
    {:ok, %{table: table, monitors: %{}, pids: %{}}}
  end

  @impl GenServer
  def handle_call({:acquire, pid, max}, _from, state) do
    # Atomic slot reservation: check the cap AND increment AND register the monitor
    # in ONE serialized GenServer operation, so a caller crash can never interleave
    # between the increment and the monitor (no unmonitored leaked slot).
    case reserve_slot(state.table, max) do
      :ok -> {:reply, :ok, track(state, pid)}
      {:error, :rate_limited_local} = err -> {:reply, err, state}
    end
  end

  @impl GenServer
  def handle_call({:release, pid}, _from, state) do
    # EXACTLY-ONCE decrement, gated on the pid still being tracked. Demonitor with
    # [:flush] to purge any already-queued :DOWN for this pid so the :DOWN handler
    # can't ALSO decrement. If the pid is NOT tracked (a :DOWN already reclaimed it,
    # or a double-release), this is a no-op — the counter is never over-decremented.
    case Map.get(state.pids, pid) do
      nil ->
        {:reply, :ok, state}

      ref ->
        Process.demonitor(ref, [:flush])
        decrement()
        {:reply, :ok, untrack(state, ref, pid)}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # An acquirer crashed without releasing — reclaim its leaked slot so the cap
    # doesn't drift up permanently. Gated on still being tracked (a concurrent
    # release/0 may have already demonitored+decremented), so the decrement is
    # exactly-once with release.
    case Map.get(state.monitors, ref) do
      ^pid ->
        decrement()
        Logger.warning("embedding concurrency: reclaimed leaked slot for crashed caller")
        {:noreply, untrack(state, ref, pid)}

      _ ->
        {:noreply, state}
    end
  end

  # --- Private ---

  # Increment the global counter; undo on over-cap. Net: a successful reserve leaves
  # it incremented, a failed one leaves it unchanged. Called only from the
  # (serialized) GenServer, so the increment-check-undo is atomic w.r.t. other
  # acquires.
  defp reserve_slot(table, max) do
    now = :ets.update_counter(table, @global_key, {2, 1}, {@global_key, 0})

    if now > max do
      :ets.update_counter(table, @global_key, {2, -1}, {@global_key, 0})
      {:error, :rate_limited_local}
    else
      :ok
    end
  end

  # Register the crash-safe monitor. One in-flight acquire per caller pid:
  # `run_embedding_task/3` acquires → runs → releases synchronously, so a pid is
  # never tracked twice concurrently. If a pid is already tracked (should not happen
  # in practice), we keep the existing monitor rather than adding a second.
  # `Process.monitor` on an already-dead pid still returns a ref and immediately
  # delivers `:DOWN`, which the handler reclaims — so there is no leak even if the
  # caller died before this ran.
  defp track(state, pid) do
    case Map.get(state.pids, pid) do
      nil ->
        ref = Process.monitor(pid)

        %{
          state
          | monitors: Map.put(state.monitors, ref, pid),
            pids: Map.put(state.pids, pid, ref)
        }

      _ref ->
        state
    end
  end

  defp untrack(state, ref, pid) do
    %{state | monitors: Map.delete(state.monitors, ref), pids: Map.delete(state.pids, pid)}
  end

  # Decrement, clamped at zero. With the exactly-once gating the clamp should never
  # fire, but it's kept as defense-in-depth so a stray decrement can never drive the
  # counter negative (which would inflate the effective cap). Called ONLY from the
  # GenServer process (release/DOWN), so decrements are serialized.
  defp decrement do
    :ets.update_counter(@table, @global_key, {2, -1, 0, 0}, {@global_key, 0})
    :ok
  end

  defp counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end
end
