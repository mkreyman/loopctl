defmodule Loopctl.DbCapacity do
  @moduledoc """
  Connection-budget accounting for the configured Ecto pools (US-27.11, AC-27.11.5).

  The PEAK number of app connections — every pool across every node, plus the extra
  node a rolling deploy transiently overlaps, plus the per-node Oban Postgres notifier
  and a small fixed ops reserve — MUST fit within the managed Postgres
  `max_connections`. This module encodes the PRODUCTION default pool sizes (the env-var
  defaults in `config/runtime.exs`) for the static model/test, and ALSO checks the
  ACTUAL runtime pool sizes against the LIVE `max_connections` at boot
  (`warn_if_over_budget/0`) so an operator bumping a pool — or the DB being resized
  down — is caught, not just the defaults.

  > Keep `@prod_pool_sizes` in lockstep with the `POOL_SIZE` / `ADMIN_POOL_SIZE` /
  > `HEAVY_READ_POOL_SIZE` defaults in `config/runtime.exs`. A test pins the values.

  fly mpg `max_connections` is finite and can change out-of-band; the boot check reads
  the live value, and the runbook re-verifies post-deploy.
  """

  require Logger

  # Production default pool sizes = the env-var defaults in config/runtime.exs.
  #
  # US-33.6 (re-derived — no rebalance shipped, an explicit scope decision): a
  # Repo 10 -> 7 / AdminRepo 3 -> 6 rebalance was proposed on the premise that
  # "every authenticated request runs ~5 AdminRepo queries on the hot path while
  # Repo sits idle." That premise does not hold against the current codebase, but
  # NOT down to zero: US-33.3's ETS read-through api-key cache
  # (`Loopctl.Auth.ApiKeyCache`) plus US-33.4's debounced touch-writes
  # (`Loopctl.TouchBuffer`) cut the auth hot path's per-request AdminRepo cost from
  # ~5 statements to ~1 cheap indexed STH SELECT (`ValidateWitnessHeader` ->
  # `AuditChain.get_sth_at_position/2` -> `AdminRepo.one/1`, uncached, issued on
  # every well-formed request) — plus cold-cache miss load on a node during a
  # rolling deploy. ApiKeyCache's own "net ZERO" moduledoc claim is scoped to the
  # api-key TOUCH path only, not the whole pipeline. The Repo pool is NOT idle
  # either — Oban's 38-wide queue concurrency (`Loopctl.ObanConfig`) shares it
  # alongside web RLS traffic. With US-33.1's checkout-wait metrics not yet
  # conclusively populated in prod, sizes stay at their US-27.11 defaults pending
  # real data (watch `loopctl.admin_repo.checkout.queue_time` before trusting 3
  # conns has headroom) — see the full rationale in the sizing comment in
  # config/runtime.exs.
  @prod_pool_sizes %{repo: 10, admin_repo: 3, heavy_read_repo: 8}

  # HEAVY_READ_POOL_SIZE (K) splits into fast sub-2s reads + a reserve for long-held
  # streamed-export checkouts (US-27.16). fast + reserve == the pool size.
  #
  # The fast-reads budget (K≈6) serves the heavy-read consumers: 5 fast heavy reads
  # (suggested_links, semantic_search, distant_pairs, novelty, enumeration) PLUS one
  # rate-limited POLLING feed — the US-27.9b change feed (`:change_feed`). Each is a
  # bounded, fast-releasing read whose connection is released before the next checkout;
  # `suggested_links` additionally issues a SECOND bounded read on the under-fill path
  # (US-27.6b) — the under-fill probe, an ANN-class read bounded by `LIMIT pool` — but the
  # two reads are STRICTLY SEQUENTIAL (the probe runs only after the main read's connection
  # is released), so peak CONCURRENT checkouts per request stays 1 and the K budget is
  # unaffected; it only adds throughput demand on the truncated path, itself capped by the
  # api rate limiter. The K rationale
  # likewise holds for the change-feed poll (one bounded keyset page, rate-limited), so
  # even a poll storm cannot saturate the fast slots — it adds at most a brief transient
  # checkout.
  @heavy_read_fast_reads 6
  @heavy_read_export_reserve 2

  # US-37.5: the per-tenant in-flight SLICE (K) of the heavy-read pool. No single
  # tenant's concurrent, cost-weighted heavy reads may hold more than K of the pool's
  # N (=8) slots at once (`Loopctl.HeavyRead.TenantGate`), so a tenant always leaves
  # `N - K` slots for its neighbours — one tenant's vector/analytic burst can no longer
  # 503 every other tenant on the shared BYPASSRLS pool. K MUST be `< pool` (a test
  # pins this) so a tenant can never take the whole pool, and `>= 1` so the gate can
  # never starve a tenant to zero heavy reads. K=4 (~half of 8) leaves at least 4 slots
  # for other tenants while giving any one tenant ample concurrency (2 heavy reads at
  # weight 2, or 4 light reads at weight 1). Live-tunable per node via the
  # `"heavy_read_tenant_cap"` SystemConfig key / `:heavy_read_tenant_cap` app env
  # (see `Loopctl.HeavyRead.TenantGate.cap/0`); this is the documented default.
  @heavy_read_tenant_slice 4

  # The Oban Postgres notifier holds one dedicated LISTEN connection PER NODE (outside
  # the pools). Migrations on deploy + the remote console are a small per-cluster fixed
  # reserve.
  @notifier_per_node 1
  @fixed_ops 2

  # Verified live against fly mpg on 2026-06-24: `SHOW max_connections` = 100.
  # Re-verify post-deploy per docs/runbooks/knowledge-scale.md.
  @verified_live_max_connections 100
  @verified_on ~D[2026-06-24]

  @doc """
  Resolve the HeavyReadRepo read DSN (US-38.1): `REPLICA_DATABASE_URL` when an operator
  sets it, else the primary `admin_database_url`.

  Pure and side-effect-free so `config/runtime.exs` (prod-only, never reflected by
  `Application.get_env` under `mix test`) can call it AND it can be unit-tested with args —
  no `Application.put_env`. When the replica env var is `nil` (unset) the result is
  `admin_url`, byte-identical to today's HeavyReadRepo DSN.
  """
  @spec resolve_replica_url(String.t() | nil, String.t()) :: String.t()
  def resolve_replica_url(replica_env, admin_url)
  def resolve_replica_url(nil, admin_url), do: admin_url
  def resolve_replica_url("", admin_url), do: admin_url
  def resolve_replica_url(replica_env, _admin_url) when is_binary(replica_env), do: replica_env

  @doc "Production default pool sizes per node (matches config/runtime.exs env-var defaults)."
  @spec prod_pool_sizes() :: %{atom() => pos_integer()}
  def prod_pool_sizes, do: @prod_pool_sizes

  @doc "Pool sizes actually configured in the running app (the REAL runtime values)."
  @spec runtime_pool_sizes() :: %{atom() => non_neg_integer()}
  def runtime_pool_sizes do
    %{
      repo: pool_size(Loopctl.Repo),
      admin_repo: pool_size(Loopctl.AdminRepo),
      heavy_read_repo: pool_size(Loopctl.HeavyReadRepo)
    }
  end

  defp pool_size(repo), do: (Application.get_env(:loopctl, repo) || [])[:pool_size] || 0

  @doc """
  The heavy-read pool's K budget (AC-27.11.1): how `HEAVY_READ_POOL_SIZE` splits
  between fast vector reads and reserved long-held export checkouts.
  """
  @spec heavy_read_budget() :: %{
          fast_reads: pos_integer(),
          export_reserve: pos_integer(),
          pool: pos_integer()
        }
  def heavy_read_budget do
    %{
      fast_reads: @heavy_read_fast_reads,
      export_reserve: @heavy_read_export_reserve,
      pool: @heavy_read_fast_reads + @heavy_read_export_reserve
    }
  end

  @doc """
  The per-tenant in-flight SLICE (K) of the heavy-read pool (US-37.5): the max number
  of the pool's N slots one tenant's cost-weighted concurrent heavy reads may hold
  before `Loopctl.HeavyRead.TenantGate` sheds the next one. Always `< heavy_read_budget().pool`
  (no tenant can take the whole pool) and `>= 1`. The documented default the gate's
  `cap/0` falls back to on a `SystemConfig`/app-env miss.
  """
  @spec heavy_read_tenant_slice() :: pos_integer()
  def heavy_read_tenant_slice, do: @heavy_read_tenant_slice

  # ── Replica connection dimension (US-38.1) ────────────────────────────────────────────
  #
  # Today HeavyReadRepo's BYPASSRLS pool shares the PRIMARY database's `max_connections`
  # with Repo + AdminRepo. When an operator sets REPLICA_DATABASE_URL (a future gated infra
  # op) HeavyReadRepo targets a SEPARATE read replica, so its 8 connections stop counting
  # against the primary's budget and count against the replica's instead — raising the
  # primary's effective headroom (more app nodes fit before a rolling deploy exhausts the
  # primary). This is a PURE model parameterised by a `replica?` boolean; when
  # `replica? == false` (the default, and today's reality) every existing number is
  # UNCHANGED. Config-only — no pool size actually changes.

  @doc """
  Is a DISTINCT read replica configured for HeavyReadRepo? Reads the
  `:replica_database_url_configured` flag set in `config/runtime.exs` (true only when
  `REPLICA_DATABASE_URL` is set to a value different from the primary). Defaults to `false`
  (dev/test and prod-without-replica), so the budget model matches today.
  """
  @spec replica_configured?() :: boolean()
  def replica_configured? do
    Application.get_env(:loopctl, :replica_database_url_configured, false)
  end

  @doc """
  PRIMARY-database pool sizes per node. With no replica (`false`) this is the full prod
  set (repo + admin_repo + heavy_read_repo) — identical to `prod_pool_sizes/0`. With a
  replica (`true`) HeavyReadRepo moves off the primary, leaving only `repo` + `admin_repo`.
  """
  @spec primary_pool_sizes(boolean()) :: %{atom() => pos_integer()}
  def primary_pool_sizes(replica? \\ false)
  def primary_pool_sizes(false), do: @prod_pool_sizes
  def primary_pool_sizes(true), do: Map.take(@prod_pool_sizes, [:repo, :admin_repo])

  @doc """
  REPLICA-database pool sizes per node: `%{heavy_read_repo: 8}` when a replica is modeled
  (`true`), or an EMPTY map when not (`false`) — because with no replica the heavy-read
  pool lives on the primary (counted by `primary_pool_sizes/1`).
  """
  @spec replica_pool_sizes(boolean()) :: %{atom() => pos_integer()}
  def replica_pool_sizes(replica? \\ false)
  def replica_pool_sizes(false), do: %{}
  def replica_pool_sizes(true), do: Map.take(@prod_pool_sizes, [:heavy_read_repo])

  @doc """
  Sum of the PRIMARY pools on a single node. `false` → 21 (unchanged from
  `per_node_total/0`); `true` → 13 (repo 10 + admin_repo 3; heavy-read offloaded to the
  replica).
  """
  @spec primary_per_node_total(boolean()) :: pos_integer()
  def primary_per_node_total(replica? \\ false),
    do: replica? |> primary_pool_sizes() |> Map.values() |> Enum.sum()

  @doc """
  Sum of the REPLICA-side pools on a single node (US-38.1): `0` with no replica (`false`), or
  the offloaded heavy-read pool (`8`) when a replica is modeled (`true`).
  """
  @spec replica_per_node_total(boolean()) :: non_neg_integer()
  def replica_per_node_total(replica? \\ false),
    do: replica? |> replica_pool_sizes() |> Map.values() |> Enum.sum()

  @doc """
  Peak REPLICA-side connections during a rolling deploy: steady heavy-read pools across `nodes`
  nodes + one transient deploy-overlap node's pool. Unlike the PRIMARY peak there is NO Oban
  notifier and NO fixed ops reserve on the replica — the LISTEN notifier connects to the primary,
  and migrations/remote-console target the primary, never the read replica. So peak = 8·(nodes+1).
  """
  @spec replica_peak_total(pos_integer()) :: non_neg_integer()
  def replica_peak_total(nodes) when is_integer(nodes) and nodes > 0 do
    per = replica_per_node_total(true)
    per * nodes + per
  end

  @doc """
  The largest node count whose peak REPLICA-side budget still fits the REPLICA's own
  `max_connections` (US-38.1). Guards against pointing `REPLICA_DATABASE_URL` at a small
  replica instance whose `max_connections` the heavy-read pool would exhaust — the replica
  half of the connection-budget model. Beyond it, a deploy exhausts the replica's connections.
  """
  @spec replica_max_supported_nodes(pos_integer()) :: non_neg_integer()
  def replica_max_supported_nodes(max_connections) when is_integer(max_connections) do
    per = replica_per_node_total(true)
    # peak(n) = per*(n+1) <= max
    n = div(max_connections - per, per)
    max(n, 0)
  end

  @doc """
  Replica-side budget status for `nodes` nodes vs the REPLICA's `max_connections` (US-38.1).
  Returns `:ok` or `{:over, message}` — never raises. Mirrors `budget_status/3` for the
  replica dimension.
  """
  @spec replica_budget_status(pos_integer(), pos_integer()) :: :ok | {:over, String.t()}
  def replica_budget_status(max_connections, nodes)
      when is_integer(max_connections) and is_integer(nodes) and nodes > 0 do
    peak = replica_peak_total(nodes)

    if peak <= max_connections do
      :ok
    else
      {:over,
       "REPLICA DB connection budget EXCEEDED: peak #{peak} (heavy_read_repo pool " <>
         "#{replica_per_node_total(true)} × #{nodes} nodes + deploy overlap) > replica " <>
         "max_connections #{max_connections}. Provision a larger read replica, lower the node " <>
         "count, or reduce HEAVY_READ_POOL_SIZE."}
    end
  end

  @doc """
  The largest node count whose peak PRIMARY-database budget still fits `max_connections`.
  With no replica (`false`) this equals `max_supported_nodes/1` (the heavy-read pool is on
  the primary). With a replica (`true`) the 8-conn heavy-read pool is offloaded, so the
  primary per-node cost drops (21 → 13) and MORE nodes fit — the primary headroom rises.
  """
  @spec primary_max_supported_nodes(pos_integer(), boolean()) :: non_neg_integer()
  def primary_max_supported_nodes(
        max_connections \\ @verified_live_max_connections,
        replica? \\ false
      ) do
    per = primary_per_node_total(replica?)
    n = div(max_connections - @fixed_ops - per, per + @notifier_per_node)
    max(n, 0)
  end

  @doc "The last fly-mpg `SHOW max_connections` value verified by a human (see moduledoc)."
  @spec verified_live_max_connections() :: pos_integer()
  def verified_live_max_connections, do: @verified_live_max_connections

  @doc "The date `verified_live_max_connections/0` was last confirmed against fly mpg."
  @spec verified_on() :: Date.t()
  def verified_on, do: @verified_on

  @doc "Sum of the given (default: prod) pools on a single node."
  @spec per_node_total(map()) :: pos_integer()
  def per_node_total(sizes \\ @prod_pool_sizes), do: sizes |> Map.values() |> Enum.sum()

  @doc "Steady-state app connections across `nodes` nodes (pools are per-node)."
  @spec steady_total(pos_integer(), map()) :: pos_integer()
  def steady_total(nodes, sizes \\ @prod_pool_sizes) when is_integer(nodes) and nodes > 0,
    do: per_node_total(sizes) * nodes

  @doc """
  Peak app connections during a rolling deploy: steady across `nodes` nodes + one
  transient overlap node's pools + the per-node Oban notifier + fixed ops reserve.
  """
  @spec peak_total(pos_integer(), map()) :: pos_integer()
  def peak_total(nodes, sizes \\ @prod_pool_sizes) when is_integer(nodes) and nodes > 0 do
    per = per_node_total(sizes)
    per * nodes + per + @notifier_per_node * nodes + @fixed_ops
  end

  @doc "Does the PEAK budget across `nodes` nodes fit within `max_connections`?"
  @spec fits?(pos_integer(), pos_integer(), map()) :: boolean()
  def fits?(max_connections, nodes, sizes \\ @prod_pool_sizes)
      when is_integer(max_connections) and is_integer(nodes) and nodes > 0 do
    peak_total(nodes, sizes) <= max_connections
  end

  @doc """
  The largest node count whose peak budget still fits `max_connections` (default: the
  verified live value), for the prod default pool sizes. Beyond it, a deploy exhausts
  connections — keep the fly machine count at or below this.
  """
  @spec max_supported_nodes(pos_integer()) :: non_neg_integer()
  def max_supported_nodes(max_connections \\ @verified_live_max_connections) do
    per = per_node_total()
    # peak(n) = per*(n+1) + notifier*n + fixed <= max
    n = div(max_connections - @fixed_ops - per, per + @notifier_per_node)
    max(n, 0)
  end

  @doc """
  Budget status for `nodes` nodes at the given pool sizes vs `max_connections`.
  Returns `:ok` or `{:over, message}` — never raises.
  """
  @spec budget_status(pos_integer(), pos_integer(), map()) :: :ok | {:over, String.t()}
  def budget_status(max_connections, nodes, sizes \\ @prod_pool_sizes) do
    if fits?(max_connections, nodes, sizes) do
      :ok
    else
      {:over,
       "DB connection budget EXCEEDED: peak #{peak_total(nodes, sizes)} (pools #{inspect(sizes)} " <>
         "× #{nodes} nodes + deploy overlap + ops) > max_connections #{max_connections}. " <>
         "Reduce a pool size, lower the node count, or resize the DB plan."}
    end
  end

  @doc """
  The PRIMARY-database pool sizes the live boot check budgets, given the actual runtime
  `sizes` and whether a distinct replica is configured (US-38.1).

  With no replica the primary carries every pool (unchanged). With a replica, `heavy_read_repo`
  is offloaded to the replica, so it must NOT be counted against the primary's
  `max_connections` — otherwise the boot check emits a false "budget EXCEEDED" at exactly the
  node count `primary_max_supported_nodes/2` advertises as safe. Pure so both branches are
  unit-testable without `Application.put_env`.
  """
  @spec primary_budget_sizes(map(), boolean()) :: map()
  def primary_budget_sizes(sizes, replica?)
  def primary_budget_sizes(sizes, false), do: sizes
  def primary_budget_sizes(sizes, true), do: Map.delete(sizes, :heavy_read_repo)

  @doc """
  Boot-time check (call in prod after repos start): reads the LIVE `max_connections`
  and warns if the ACTUAL configured pools, at `nodes` (env `EXPECTED_APP_NODES`,
  default 2), would exceed it. Logs only — never raises, never blocks boot.

  US-38.1: when a distinct read replica is configured, the offloaded `heavy_read_repo` pool
  counts against the REPLICA's budget, not the primary's — so it is excluded here
  (`primary_budget_sizes/2`) and the check reflects the raised primary headroom
  (`primary_max_supported_nodes/2`) instead of a spurious over-budget warning.
  """
  @spec warn_if_over_budget(pos_integer()) :: :ok
  def warn_if_over_budget(nodes \\ expected_app_nodes()) do
    %{rows: [[raw]]} = Loopctl.Repo.query!("SHOW max_connections")
    live_max = String.to_integer(raw)
    sizes = primary_budget_sizes(runtime_pool_sizes(), replica_configured?())

    case budget_status(live_max, nodes, sizes) do
      :ok ->
        Logger.info(
          "DB connection budget OK: peak #{peak_total(nodes, sizes)} <= max_connections #{live_max} (#{nodes} nodes)"
        )

      {:over, message} ->
        Logger.warning(message)
    end

    :ok
  rescue
    e -> Logger.warning("DbCapacity boot check skipped: #{Exception.message(e)}")
  end

  @doc """
  Boot-time REPLICA-side budget check (US-38.1): when a distinct read replica is configured,
  reads the REPLICA's own live `max_connections` (via `Loopctl.HeavyRead.replica_max_connections/0`,
  the sole sanctioned toucher of the heavy-read pool) and warns if the heavy-read pool at
  `nodes` would exhaust it. A NO-OP when no replica is configured (the default). Logs only —
  never raises, never blocks boot.

  This is the replica half of the connection-budget model: `warn_if_over_budget/1` guards the
  PRIMARY, this guards the replica so a small replica instance can't be silently exhausted by
  the offloaded 8-conn heavy-read pool.
  """
  @spec warn_if_replica_over_budget(pos_integer()) :: :ok
  def warn_if_replica_over_budget(nodes \\ expected_app_nodes()) do
    if replica_configured?() do
      case Loopctl.HeavyRead.replica_max_connections() do
        {:ok, live_max} ->
          log_replica_budget(replica_budget_status(live_max, nodes), live_max, nodes)

        {:error, reason} ->
          Logger.warning(
            "DbCapacity replica boot check skipped (replica unreachable): #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  defp log_replica_budget(:ok, live_max, nodes) do
    Logger.info(
      "REPLICA connection budget OK: peak #{replica_peak_total(nodes)} <= replica " <>
        "max_connections #{live_max} (#{nodes} nodes)"
    )
  end

  defp log_replica_budget({:over, message}, _live_max, _nodes), do: Logger.warning(message)

  @doc """
  The expected app node count (env `EXPECTED_APP_NODES`, default 2) used as the
  default `nodes` argument to `warn_if_over_budget/1`. Public so tests (and any
  other caller wanting the SAME env-derived node count) don't have to
  hand-duplicate the parsing/default.
  """
  @spec expected_app_nodes() :: pos_integer()
  def expected_app_nodes do
    case System.get_env("EXPECTED_APP_NODES") do
      nil -> 2
      v -> String.to_integer(v)
    end
  end
end
