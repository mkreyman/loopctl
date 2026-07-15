defmodule Loopctl.DbCapacityTest do
  @moduledoc """
  AC-27.11.5 / TC-27.11.3: the PEAK connection budget (all pools × nodes + rolling-
  deploy overlap + per-node Oban notifier + ops) must fit within `max_connections`.

  This test reads the `max_connections` of the DB it is connected to (CI Postgres) as a
  sanity check AND asserts against the human-verified fly-mpg value in
  `Loopctl.DbCapacity`. The AUTHORITATIVE prod check is the boot-time
  `warn_if_over_budget/0` (against the live DB + the ACTUAL runtime pool sizes) plus the
  runbook command — the CI DB is not prod, so this test guards the budget MODEL and the
  verified constant from regressing.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.DbCapacity
  alias Loopctl.Repo

  test "prod pool sizes match the runtime.exs env-var defaults" do
    # US-33.6: re-derived, no rebalance shipped (explicit scope decision) — US-33.3/33.4
    # already cut the auth hot path's per-request AdminRepo cost from ~5 statements to
    # ~1 (the ValidateWitnessHeader plug still issues one uncached STH SELECT per
    # request — NOT net-zero), and the Repo pool is not idle (Oban's 38-wide queue
    # concurrency shares it), so sizes stay at US-27.11 defaults.
    assert DbCapacity.prod_pool_sizes() == %{repo: 10, admin_repo: 3, heavy_read_repo: 8}
    assert DbCapacity.per_node_total() == 21
    assert DbCapacity.steady_total(2) == 42
  end

  test "heavy-read K budget: fast reads + export reserve == the heavy_read pool size (AC-27.11.1)" do
    %{fast_reads: fast, export_reserve: reserve, pool: pool} = DbCapacity.heavy_read_budget()
    assert fast > 0 and reserve > 0
    assert fast + reserve == pool
    assert pool == DbCapacity.prod_pool_sizes().heavy_read_repo
  end

  test "US-37.5: per-tenant heavy-read slice K is >= 1 and strictly < the pool size" do
    k = DbCapacity.heavy_read_tenant_slice()
    pool = DbCapacity.heavy_read_budget().pool

    assert k >= 1
    # K < pool so no single tenant's cost-weighted concurrent heavy reads can hold the
    # WHOLE pool — always leaving pool - K slots for other tenants (no cross-tenant 503).
    assert k < pool
  end

  test "peak budget = steady + one overlap node + per-node notifier + fixed ops" do
    # 2 nodes: 42 steady + 21 overlap + 2 notifier(1/node) + 2 fixed = 67.
    assert DbCapacity.peak_total(2) == 67
  end

  test "TC-33.6.1: peak budget at EXPECTED_APP_NODES stays strictly under max_connections with margin" do
    # Reads EXPECTED_APP_NODES through DbCapacity.expected_app_nodes/0 — the SAME
    # source warn_if_over_budget/0 defaults to — rather than hand-asserting a
    # literal node count, so this actually exercises the env-derived node count
    # the TC step calls for. No env override in CI/dev, so this is 2 today; the
    # margin assertion (not a literal peak_total/67 equality, already covered by
    # the "peak budget = steady + ..." test above) is the non-redundant coverage.
    nodes = DbCapacity.expected_app_nodes()
    assert DbCapacity.peak_total(nodes) < DbCapacity.verified_live_max_connections()
  end

  test "the PEAK budget fits within the LIVE max_connections and the verified value (TC-27.11.3)" do
    %{rows: [[raw]]} = Repo.query!("SHOW max_connections")
    live_max = String.to_integer(raw)

    assert DbCapacity.fits?(live_max, 2),
           "Peak pool budget #{DbCapacity.peak_total(2)} exceeds live max_connections=#{live_max}."

    assert DbCapacity.fits?(DbCapacity.verified_live_max_connections(), 2)
  end

  test "max_supported_nodes is honest: more nodes than that would exhaust connections" do
    n = DbCapacity.max_supported_nodes()
    assert n == 3
    assert DbCapacity.fits?(DbCapacity.verified_live_max_connections(), n)
    refute DbCapacity.fits?(DbCapacity.verified_live_max_connections(), n + 1)
  end

  test "budget_status flags an over-budget pool configuration (operator pool bump)" do
    # A 30-conn heavy pool blows the budget on the verified 100-conn DB.
    bloated = %{repo: 10, admin_repo: 3, heavy_read_repo: 30}
    assert {:over, msg} = DbCapacity.budget_status(100, 2, bloated)
    assert msg =~ "EXCEEDED"
    assert :ok = DbCapacity.budget_status(100, 2, DbCapacity.prod_pool_sizes())
  end

  test "runtime_pool_sizes reads the actually-configured pools" do
    sizes = DbCapacity.runtime_pool_sizes()
    assert Map.keys(sizes) |> Enum.sort() == [:admin_repo, :heavy_read_repo, :repo]
    assert Enum.all?(Map.values(sizes), &(is_integer(&1) and &1 > 0))
  end

  test "the verified live value carries a verification date (operator re-check anchor)" do
    assert %Date{} = DbCapacity.verified_on()
  end
end
