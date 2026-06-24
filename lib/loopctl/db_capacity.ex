defmodule Loopctl.DbCapacity do
  @moduledoc """
  Connection-budget accounting for the configured Ecto pools (US-27.11, AC-27.11.5).

  The PEAK number of app connections — every pool, across every node, plus the
  transient extra node a rolling deploy briefly runs, plus ops headroom — MUST fit
  within the managed Postgres `max_connections`. This module encodes the PRODUCTION
  default pool sizes (the env-var defaults in `config/runtime.exs`) and models the
  peak, so a test can assert the budget fits the LIVE `max_connections`
  (`db_capacity_test.exs`, TC-27.11.3) and the runbook can re-verify post-deploy.

  > Keep `@prod_pool_sizes` in lockstep with the `POOL_SIZE` / `ADMIN_POOL_SIZE` /
  > `HEAVY_READ_POOL_SIZE` defaults in `config/runtime.exs` (those are
  > `System.get_env` defaults and can't be read at compile time here). A test pins
  > the values, but not the coupling — a reviewer bumping a default must update both.

  fly mpg `max_connections` is finite and can change out-of-band, so the test reads
  the LIVE value (`SHOW max_connections`) rather than trusting a constant; the
  authoritative production re-check is the runbook command (see moduledoc of the
  test).
  """

  # Production default pool sizes = the env-var defaults in config/runtime.exs:
  # POOL_SIZE=10, ADMIN_POOL_SIZE=3, HEAVY_READ_POOL_SIZE=8.
  @prod_pool_sizes %{repo: 10, admin_repo: 3, heavy_read_repo: 8}

  # HEAVY_READ_POOL_SIZE (K) is split: fast sub-2s vector reads + a reserve for
  # long-held streamed-export checkouts (US-27.16), which hold a connection for
  # minutes. fast + reserve MUST equal the heavy_read_repo pool size.
  @heavy_read_fast_reads 6
  @heavy_read_export_reserve 2

  # Ops connections beyond the pools, per cluster: a migration on deploy, the Oban
  # Postgres notifier, and the remote console (`fly ssh console`).
  @ops_headroom 4

  # Verified live against fly mpg on 2026-06-24: `SHOW max_connections` = 100.
  # Re-verify post-deploy per docs/runbooks/knowledge-scale.md (it can change
  # out-of-band when the DB plan is resized).
  @verified_live_max_connections 100
  @verified_on ~D[2026-06-24]

  @doc "Production default pool sizes per node (matches config/runtime.exs env-var defaults)."
  @spec prod_pool_sizes() :: %{atom() => pos_integer()}
  def prod_pool_sizes, do: @prod_pool_sizes

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

  @doc "Ops connections reserved per cluster (migration/notifier/console)."
  @spec ops_headroom() :: non_neg_integer()
  def ops_headroom, do: @ops_headroom

  @doc "The last fly-mpg `SHOW max_connections` value verified by a human (see moduledoc)."
  @spec verified_live_max_connections() :: pos_integer()
  def verified_live_max_connections, do: @verified_live_max_connections

  @doc "The date `verified_live_max_connections/0` was last confirmed against fly mpg."
  @spec verified_on() :: Date.t()
  def verified_on, do: @verified_on

  @doc "Sum of all configured pools on a single node."
  @spec per_node_total() :: pos_integer()
  def per_node_total, do: @prod_pool_sizes |> Map.values() |> Enum.sum()

  @doc "Steady-state app connections across `nodes` app nodes (pools are per-node)."
  @spec steady_total(pos_integer()) :: pos_integer()
  def steady_total(nodes) when is_integer(nodes) and nodes > 0, do: per_node_total() * nodes

  @doc """
  Peak app connections during a rolling deploy: steady-state across `nodes` nodes,
  plus one extra node's full pools (fly replaces one machine at a time, so old + new
  briefly overlap), plus ops headroom.
  """
  @spec peak_total(pos_integer()) :: pos_integer()
  def peak_total(nodes) when is_integer(nodes) and nodes > 0 do
    steady_total(nodes) + per_node_total() + @ops_headroom
  end

  @doc "Does the PEAK connection budget across `nodes` nodes fit within `max_connections`?"
  @spec fits?(pos_integer(), pos_integer()) :: boolean()
  def fits?(max_connections, nodes)
      when is_integer(max_connections) and is_integer(nodes) and nodes > 0 do
    peak_total(nodes) <= max_connections
  end

  @doc """
  The largest node count whose peak budget still fits `max_connections` (defaults to
  the human-verified live value). Beyond this, a deploy would exhaust connections.
  """
  @spec max_supported_nodes(pos_integer()) :: non_neg_integer()
  def max_supported_nodes(max_connections \\ @verified_live_max_connections) do
    # peak(n) = per_node*n + per_node + ops <= max  ⇒  n <= (max - ops)/per_node - 1
    n = div(max_connections - @ops_headroom, per_node_total()) - 1
    max(n, 0)
  end
end
