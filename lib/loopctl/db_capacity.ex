defmodule Loopctl.DbCapacity do
  @moduledoc """
  Connection-budget accounting for the configured Ecto pools (US-27.11, AC-27.11.5).

  The sum of every app pool, across every app node, plus headroom for migrations,
  the remote console, and the Oban Postgres notifier, MUST fit within the managed
  Postgres `max_connections`. This module encodes the PRODUCTION default pool sizes
  (the env-var defaults in `config/runtime.exs`) and the headroom, so a test can
  assert the budget fits the LIVE `max_connections` (see `db_capacity_test.exs`,
  TC-27.11.3) and the runbook can re-verify post-deploy.

  fly mpg `max_connections` is finite and can change out-of-band, so the test reads
  the LIVE value (`SHOW max_connections`) rather than trusting a constant.
  """

  # Production default pool sizes = the env-var defaults in config/runtime.exs:
  # POOL_SIZE=10, ADMIN_POOL_SIZE=3, HEAVY_READ_POOL_SIZE=8.
  @prod_pool_sizes %{repo: 10, admin_repo: 3, heavy_read_repo: 8}

  # Connections to leave free per cluster for: schema migrations on deploy, the
  # remote console (`fly ssh console`), the Oban Postgres notifier/peer, and
  # transient reconnects during a rolling deploy (old + new node briefly overlap).
  @headroom 14

  # Verified live against fly mpg on 2026-06-24: `SHOW max_connections` = 100.
  # Re-verify post-deploy per docs/runbooks/knowledge-scale.md (it can change
  # out-of-band when the DB plan is resized).
  @verified_live_max_connections 100

  @doc "Production default pool sizes per node (matches config/runtime.exs env-var defaults)."
  @spec prod_pool_sizes() :: %{atom() => pos_integer()}
  def prod_pool_sizes, do: @prod_pool_sizes

  @doc "Connections reserved per cluster for migrations/console/notifier/rolling-deploy overlap."
  @spec headroom() :: non_neg_integer()
  def headroom, do: @headroom

  @doc "The last fly-mpg `SHOW max_connections` value verified by a human (see moduledoc)."
  @spec verified_live_max_connections() :: pos_integer()
  def verified_live_max_connections, do: @verified_live_max_connections

  @doc "Sum of all configured pools on a single node."
  @spec per_node_total() :: pos_integer()
  def per_node_total, do: @prod_pool_sizes |> Map.values() |> Enum.sum()

  @doc "Total app connections across `nodes` app nodes (pools are per-node)."
  @spec total(pos_integer()) :: pos_integer()
  def total(nodes) when is_integer(nodes) and nodes > 0, do: per_node_total() * nodes

  @doc """
  Does the app's connection budget across `nodes` nodes (+ headroom) fit within
  `max_connections`?
  """
  @spec fits?(pos_integer(), pos_integer()) :: boolean()
  def fits?(max_connections, nodes)
      when is_integer(max_connections) and is_integer(nodes) and nodes > 0 do
    total(nodes) + @headroom <= max_connections
  end
end
