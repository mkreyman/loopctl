defmodule Loopctl.HeavyRead.TenantGate do
  @moduledoc """
  Per-tenant, cost-weighted, node-local in-flight limiter on the HeavyRead pool
  (US-37.5, #354).

  ## Why

  Epic 33 gave heavy/BYPASSRLS reads their own isolated Ecto pool
  (`Loopctl.HeavyReadRepo`, `HEAVY_READ_POOL_SIZE` default 8) with a per-read
  `SET LOCAL statement_timeout`. But that pool is GLOBAL: one tenant's burst of
  heavy vector/analytic reads can hold all N connections and effectively 503 every
  OTHER tenant. `Loopctl.HeavyRead` was only a tenant-scoping GUARD + timeout
  wrapper, NOT a limiter. The only prior per-tenant fairness
  (`Loopctl.Oban.FairShare`, US-36.2) bounds Oban *queue* slots, not this
  synchronous pool.

  This gate is a NODE-LOCAL per-tenant in-flight semaphore: no tenant may hold more
  than `cap` (K) of the pool's N slots at once, so a tenant always leaves `N - K`
  slots for its neighbours. It is COST-WEIGHTED — a heavier read (vector/kNN,
  semantic ranking, memory recall) consumes MORE of a tenant's budget than a light
  one (change feed, enumeration) — so a tenant can run fewer concurrent heavy reads
  than light ones within the same K. Over the cap the acquire FAILS FAST with
  `{:error, :heavy_read_overloaded}` (a bounded-wait-then-shed variant is
  acceptable); `Loopctl.HeavyRead` maps that to a graceful degrade (keyword fallback
  for search, a 429 with the app error envelope for API reads) rather than a
  pool-exhaustion crash for other tenants.

  ## Design — lock-free ETS atomic counter (NOT a serialized GenServer)

  Mirrors the OTP-thinking "ETS counter" pattern (and the `Iron Law`): a GenServer
  that served every acquire/release would serialize EVERY heavy read through one
  process — a throughput bottleneck on the hot read path. Instead a single public,
  named ETS table holds one `{tenant_id, in_flight_weight}` counter per tenant, and
  `acquire/3` / `release/2` mutate it with `:ets.update_counter/4`, which is ATOMIC
  — so concurrent acquirers never lose an update and the cap can never be exceeded:

    * `acquire/3` atomically adds `weight`; if the new total exceeds `cap` it
      atomically subtracts it back and returns `{:error, :heavy_read_overloaded}`.
      Two concurrent over-cap acquires each add-then-undo, so NEITHER is admitted
      and the counter returns to its prior value — safe (never admits over `cap`;
      at worst a transient high value sheds an acquire that could have squeaked in,
      an acceptable fairness cost, never a safety one).
    * `release/2` atomically subtracts `weight`, FLOORED at 0 so a stray/double
      release can never drive the counter negative (which would inflate the
      effective cap).

  A tiny supervised process (started in `Loopctl.Application`) OWNS the table so it
  outlives the transient request/worker process that incremented it; acquire/release
  BYPASS that owner entirely (direct ETS ops). Zero-valued rows are intentionally
  NOT reaped: reaping under lock-free access races a concurrent re-acquire
  (`update_counter`'s `{key, 0}` default would recreate the row between the read-0
  and the delete, losing a live slot). The table therefore holds at most one small
  `{uuid, int}` row per distinct tenant that has ever done a heavy read on this node
  — bounded by tenant count, not by request volume.

  ## Crash-safety — `after`, not process monitors

  `Loopctl.HeavyRead` wraps `acquire → run → release` with `release/2` in an
  `after`, so a query that raises (statement_timeout CANCEL, DB error) or times out
  still releases its budget. Unlike `Loopctl.Knowledge.EmbeddingConcurrency` (a
  GenServer that MONITORS acquirers), this gate does not reclaim budget on a HARD
  process kill between acquire and the `after` — a rare, node-local drift the
  fail-open posture and owner restart tolerate. The simplicity of a lock-free
  counter on the hot read path is the deliberate trade.

  ## Fail-OPEN on a limiter fault (AC-37.5.5)

  A limiter that BLOCKS all heavy reads when it breaks is worse than no limiter. So,
  like `FairShare` failing open on an unmeasurable count, `acquire/3` and
  `release/2` are defensive: if the ETS op raises (e.g. the owner process is
  momentarily down and the table is gone), they LOG a warning and fail OPEN —
  `acquire/3` returns `:ok` (allow the read), `release/2` returns `:ok`. An
  unmeasurable limiter degrades to "no limit", never to "all reads blocked".

  A MALFORMED CAP is CLAMPED (not trusted, not fail-loud): `cap/0` runs the
  live-tunable `"heavy_read_tenant_cap"` value through `clamp_cap/1` into the
  structurally valid range `[heavy_weight/0, pool - 1]` — logging a warning when it
  clamps. This is deliberate and load-bearing for AC-37.5.5: an operator setting a
  NON-POSITIVE cap (`0`/negative) would otherwise make `acquire/4`'s `cap > 0` guard
  match no clause and raise a `FunctionClauseError` — which is NOT an
  `OverloadedError`, so the 429 handler never fires and EVERY heavy read on the node
  500s (the exact "limiter fault blocks all heavy reads" AC-37.5.5 forbids). Flooring
  at `heavy_weight/0` also prevents a `K < heavy_weight` value making every heavy read
  shed for all tenants, and the `pool - 1` ceiling stops a `K >= pool` value silently
  re-enabling the single-tenant monopolization this gate exists to prevent (it
  guarantees `N - K >= 1` slots always remain for neighbours). `Loopctl.SystemConfig.get_int/2`
  itself never raises (returns the default on miss); the clamp turns any out-of-range
  operator knob into a safe, logged value rather than a node-wide outage.

  The COST WEIGHTS get the same defense: `heavy_weight/0` and `light_weight/0` are FLOORED
  at 1, so a non-positive `:heavy_read_weight_heavy`/`:heavy_read_weight_light` app-env
  misconfiguration can never flow through `weight_for/1` into `acquire/4`'s `weight > 0`
  guard, miss every clause, and raise a `FunctionClauseError` OUTSIDE the acquire rescue
  (the same node-wide-500 fail-open violation the cap clamp guards against). `clamp_cap/1`
  additionally caps `heavy_weight/0` at the `pool - 1` ceiling when deriving its floor, so a
  `heavy_weight >= pool` can't push the cap floor to/above `pool` and silently re-enable
  monopolization (AC-37.5.5 bundles caps AND weights into the fail-open guarantee).

  ## Config — env-driven, live-tunable, node-local (AC-37.5.5)

    * `cap/0` (K) — the per-tenant slice. Read via the `"heavy_read_tenant_cap"`
      `SystemConfig` key (DB-backed, hot-path-safe, live-tunable with no deploy); on
      a cache miss it falls back to the `:heavy_read_tenant_cap` application env,
      whose default is `Loopctl.DbCapacity.heavy_read_tenant_slice/0` (`4`), which is
      pinned `< HEAVY_READ_POOL_SIZE` (8) so no tenant can take the whole pool. K is
      always `>= heavy_weight/0` so a single heavy read always fits (the gate can
      never starve a tenant to zero heavy reads).
    * `weight_for/1` — the per-endpoint cost weight, derived from the `endpoint`
      atom `Loopctl.HeavyRead.opts/1` already carries in `telemetry_options`.
      Heavy endpoints (vector/kNN, semantic ranking, memory recall, novelty,
      suggested-links, distant-pairs) cost `heavy_weight/0` (`2`); everything else
      (change feed, enumeration, ingestion-jobs, STH tail, LLM usage) costs
      `light_weight/0` (`1`). Both weights are `Application.get_env`-backed so
      `config/test.exs` can tune them.

  Node-local by design — one set of counters per node. Cluster-wide budget is
  explicitly deferred to Epic 38 (#353); the effective fleet ceiling is
  `cap * node_count`.

  ## Testing (async-safe, no `Application.put_env`)

  The core `acquire/3` / `release/2` take EXPLICIT `cap`/`weight` args, so the gate's
  own tests exercise K=2 and heavy-vs-light weights against fixed caps WITHOUT any
  global config mutation. The counters are VM-wide (public ETS), so the suite-wide
  `config/test.exs` `:heavy_read_tenant_cap` is set HIGH — the wired
  `Loopctl.HeavyRead` gate is then a no-op across incidental parallel heavy reads in
  the async suite (the `EmbeddingConcurrency`/`ExportConcurrency` precedent), while
  the dedicated cap tests pass their own low caps to the core functions. Tenant
  isolation holds structurally: the counter is keyed by `tenant_id`, so A's count
  never includes B's.
  """

  use GenServer

  require Logger

  alias Loopctl.DbCapacity
  alias Loopctl.SystemConfig

  @table :loopctl_heavy_read_inflight

  @cap_config_key "heavy_read_tenant_cap"
  @heavy_weight_env :heavy_read_weight_heavy
  @light_weight_env :heavy_read_weight_light
  @cap_env :heavy_read_tenant_cap

  @default_heavy_weight 2
  @default_light_weight 1

  # HeavyRead endpoints whose queries are the EXPENSIVE ones — vector/kNN scans,
  # semantic ranking, HNSW memory recall, the novelty/suggested-links ANN probes,
  # the distant-pairs analytic reads, and the long (60s) streamed-export scans. They
  # consume `heavy_weight/0` of a tenant's in-flight budget; every other (lighter,
  # bounded, fast-releasing) endpoint — change feed, enumeration, ingestion-jobs
  # count, STH tail, LLM usage — consumes `light_weight/0`.
  #
  # DRIFT GUARD: every atom here MUST be a `Loopctl.HeavyRead.known_endpoints/0`
  # member, and that full known set is partitioned (heavy vs light) by
  # `tenant_gate_test.exs`'s endpoint-weight guard — so a NEW heavy endpoint a caller
  # adds (registered in `known_endpoints/0`) cannot silently fall through
  # `weight_for/1` to light weight and under-charge a genuinely heavy read.
  @heavy_endpoints ~w(
    vector_search
    semantic_search
    memory_recall
    novelty
    suggested_links
    distant_pairs
    distant_pairs_bridge
    export
    graph_lane
  )a

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Tries to reserve `weight` units of `tenant_id`'s in-flight HeavyRead budget against
  `cap` (K).

  Atomically adds `weight` to the tenant's counter; returns `:ok` when the new total
  stays `<= cap` (the slot is held) or `{:error, :heavy_read_overloaded}` when it
  would exceed `cap` (the add is atomically undone — no budget is left reserved).
  Non-blocking: fails fast at the cap. Pair every successful `acquire/3` with a
  matching `release/2` (do it in an `after` so a crashing read never leaks budget).

  FAILS OPEN (`:ok`) — logging a warning — if the ETS op raises (owner momentarily
  down), so a broken limiter never blocks all heavy reads (AC-37.5.5).
  """
  @spec acquire(binary(), pos_integer(), pos_integer()) ::
          :ok | {:error, :heavy_read_overloaded}
  def acquire(tenant_id, weight, cap), do: acquire(tenant_id, weight, cap, @table)

  @doc false
  # Table-parameterized core (the production API is `acquire/3`, using @table). The
  # explicit `table` arg exists so the gate's own fail-open test can pass a NON-existent
  # table to exercise the rescue WITHOUT deleting the shared, VM-wide production table
  # (which every parallel async test reads/writes).
  @spec acquire(binary(), pos_integer(), pos_integer(), atom()) ::
          :ok | {:error, :heavy_read_overloaded}
  def acquire(tenant_id, weight, cap, table)
      when is_binary(tenant_id) and is_integer(weight) and weight > 0 and
             is_integer(cap) and cap > 0 and is_atom(table) do
    now = :ets.update_counter(table, tenant_id, {2, weight}, {tenant_id, 0})

    if now > cap do
      # Undo the reservation atomically (floored at 0 defensively). The transient
      # over-count is invisible to admitted reads and self-corrects here.
      :ets.update_counter(table, tenant_id, {2, -weight, 0, 0}, {tenant_id, 0})
      {:error, :heavy_read_overloaded}
    else
      :ok
    end
  rescue
    e ->
      Logger.warning(
        "HeavyRead.TenantGate acquire failed OPEN for tenant=#{tenant_id}: " <>
          Exception.message(e)
      )

      :ok
  end

  @doc """
  Releases `weight` units of `tenant_id`'s in-flight budget previously reserved by
  `acquire/3`.

  Atomically subtracts `weight`, FLOORED at 0 so a stray or double release can never
  drive the counter negative (which would inflate the effective cap). Idempotent
  enough for the crash path: releasing without a prior successful acquire just floors
  at 0. FAILS OPEN (`:ok`) if the ETS op raises — invoked from an `after` where a
  raised error would mask the read result.
  """
  @spec release(binary(), pos_integer()) :: :ok
  def release(tenant_id, weight), do: release(tenant_id, weight, @table)

  @doc false
  @spec release(binary(), pos_integer(), atom()) :: :ok
  def release(tenant_id, weight, table)
      when is_binary(tenant_id) and is_integer(weight) and weight > 0 and is_atom(table) do
    :ets.update_counter(table, tenant_id, {2, -weight, 0, 0}, {tenant_id, 0})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Current in-flight budget held by `tenant_id` on this node (for tests/telemetry)."
  @spec count(binary()) :: non_neg_integer()
  def count(tenant_id) when is_binary(tenant_id), do: count(tenant_id, @table)

  @doc false
  @spec count(binary(), atom()) :: non_neg_integer()
  def count(tenant_id, table) when is_binary(tenant_id) and is_atom(table) do
    case :ets.lookup(table, tenant_id) do
      [{^tenant_id, n}] -> n
      [] -> 0
    end
  rescue
    _ -> 0
  end

  @doc """
  The per-tenant in-flight cap (K) — the max HeavyRead budget one tenant may hold.

  Live-tunable via the `"heavy_read_tenant_cap"` `SystemConfig` key; on a cache miss
  it falls back to the `:heavy_read_tenant_cap` application env, whose default is
  `Loopctl.DbCapacity.heavy_read_tenant_slice/0` (pinned `< HEAVY_READ_POOL_SIZE`).
  The configured value is CLAMPED via `clamp_cap/1` into `[heavy_weight/0, pool - 1]`
  so a malformed operator knob (non-positive → node-wide 500; `< heavy_weight` →
  every read sheds; `>= pool` → monopolization) is turned into a safe, LOGGED value
  rather than an outage or a silently-defeated gate (AC-37.5.5). Always returns a
  positive integer `>= heavy_weight/0`, so `acquire/4`'s `cap > 0` guard always matches.
  """
  @spec cap() :: pos_integer()
  def cap do
    @cap_config_key
    |> SystemConfig.get_int(cap_default())
    |> clamp_cap()
  end

  @doc """
  Clamps a configured cap into the structurally valid range `[heavy_weight/0, pool - 1]`,
  logging a warning when the input was out of range.

  The lower floor (`heavy_weight/0`) guarantees a single heavy read always fits AND
  keeps `acquire/4`'s `cap > 0` guard satisfied (a non-positive cap would otherwise
  raise a `FunctionClauseError` OUTSIDE the acquire rescue → a node-wide 500, the
  AC-37.5.5 fail-open violation). The upper ceiling (`pool - 1`) guarantees at least
  one pool slot always remains for a tenant's neighbours, so no cap value can
  re-enable single-tenant monopolization. Exposed for the drift/range guard test.
  """
  @spec clamp_cap(integer()) :: pos_integer()
  def clamp_cap(configured) when is_integer(configured) do
    # The `pool - 1` ceiling ALWAYS wins: it guarantees `N - K >= 1` slots remain for a
    # tenant's neighbours (no single-tenant monopolization). `heavy_weight/0` is floored at
    # 1 (weight accessors) AND capped at that ceiling here, so a misconfigured
    # `heavy_weight >= pool` can't push the clamp FLOOR to/above `pool` and silently yield a
    # `cap >= pool` (which would re-enable the monopolization the ceiling exists to prevent).
    # Result: `clamped` always lands in `[1, pool - 1]`, a positive int satisfying
    # `acquire/4`'s `cap > 0` guard (AC-37.5.5).
    ceiling = max(1, pool_size() - 1)
    lower = min(heavy_weight(), ceiling)
    clamped = configured |> max(lower) |> min(ceiling)

    if clamped != configured do
      Logger.warning(
        "HeavyRead.TenantGate: configured cap #{inspect(configured)} out of range " <>
          "[#{lower}, #{ceiling}] (heavy_weight..pool-1); clamped to #{clamped}"
      )
    end

    clamped
  end

  @doc """
  The cost weight an endpoint's read consumes from a tenant's in-flight budget.

  Heavy endpoints (vector/kNN, semantic ranking, memory recall, novelty,
  suggested-links, distant-pairs) cost `heavy_weight/0`; every other endpoint (and an
  unknown/`nil` endpoint) costs `light_weight/0`. Derived from the `endpoint` atom
  `Loopctl.HeavyRead.opts/1` carries in `telemetry_options`.
  """
  @spec weight_for(atom() | nil) :: pos_integer()
  def weight_for(endpoint) when endpoint in @heavy_endpoints, do: heavy_weight()
  def weight_for(_endpoint), do: light_weight()

  @doc "The endpoint atoms weighted `heavy_weight/0` (for the drift/range guard test)."
  @spec heavy_endpoints() :: [atom()]
  def heavy_endpoints, do: @heavy_endpoints

  @doc """
  The in-flight budget a HEAVY endpoint's read consumes (env `:heavy_read_weight_heavy`,
  default #{@default_heavy_weight}).

  FLOORED at 1 (AC-37.5.5): a non-positive operator misconfiguration would otherwise flow
  through `weight_for/1` into `acquire/4`'s `weight > 0` guard, matching NO clause and
  raising a `FunctionClauseError` OUTSIDE the acquire rescue — a node-wide 500 on every
  heavy read of that class (the exact fail-open violation the cap's `clamp_cap/1` was added
  to prevent). A bad knob degrades to weight 1, not an outage.
  """
  @spec heavy_weight() :: pos_integer()
  def heavy_weight,
    do: max(1, Application.get_env(:loopctl, @heavy_weight_env, @default_heavy_weight))

  @doc """
  The in-flight budget a LIGHT endpoint's read consumes (env `:heavy_read_weight_light`,
  default #{@default_light_weight}). FLOORED at 1 for the same fail-open reason as
  `heavy_weight/0` — a non-positive knob can never make `acquire/4`'s `weight > 0` guard
  miss (AC-37.5.5).
  """
  @spec light_weight() :: pos_integer()
  def light_weight,
    do: max(1, Application.get_env(:loopctl, @light_weight_env, @default_light_weight))

  @doc false
  def table_name, do: @table

  defp cap_default,
    do: Application.get_env(:loopctl, @cap_env, DbCapacity.heavy_read_tenant_slice())

  # The heavy-read pool size the cap ceiling is derived from (`pool - 1`). The
  # documented budget (`DbCapacity.heavy_read_budget/0`) is the same reference
  # `heavy_read_tenant_slice/0` is pinned against, so cap and default stay coherent.
  defp pool_size, do: DbCapacity.heavy_read_budget().pool

  # --- Server callbacks (table-owner only; acquire/release bypass this process) ---

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

    {:ok, %{table: table}}
  end
end
