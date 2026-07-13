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
  # US-33.6: rebalanced toward the AdminRepo hot path (every authenticated request runs
  # ~5 AdminRepo queries, 2 writes, on this BYPASSRLS pool) while the RLS Repo pool sat
  # nearly idle. Conservative, budget-neutral shift: AdminRepo 3 -> 6, Repo 10 -> 7 (cedes
  # idle headroom), HeavyReadRepo untouched. per_node_total/peak_total/max_supported_nodes
  # are unchanged (21/67/3) — see the sizing comment in config/runtime.exs.
  @prod_pool_sizes %{repo: 7, admin_repo: 6, heavy_read_repo: 8}

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

  # The Oban Postgres notifier holds one dedicated LISTEN connection PER NODE (outside
  # the pools). Migrations on deploy + the remote console are a small per-cluster fixed
  # reserve.
  @notifier_per_node 1
  @fixed_ops 2

  # Verified live against fly mpg on 2026-06-24: `SHOW max_connections` = 100.
  # Re-verify post-deploy per docs/runbooks/knowledge-scale.md.
  @verified_live_max_connections 100
  @verified_on ~D[2026-06-24]

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
  Boot-time check (call in prod after repos start): reads the LIVE `max_connections`
  and warns if the ACTUAL configured pools, at `nodes` (env `EXPECTED_APP_NODES`,
  default 2), would exceed it. Logs only — never raises, never blocks boot.
  """
  @spec warn_if_over_budget(pos_integer()) :: :ok
  def warn_if_over_budget(nodes \\ expected_app_nodes()) do
    %{rows: [[raw]]} = Loopctl.Repo.query!("SHOW max_connections")
    live_max = String.to_integer(raw)
    sizes = runtime_pool_sizes()

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

  defp expected_app_nodes do
    case System.get_env("EXPECTED_APP_NODES") do
      nil -> 2
      v -> String.to_integer(v)
    end
  end
end
