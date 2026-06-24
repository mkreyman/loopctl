defmodule Loopctl.DbCapacityTest do
  @moduledoc """
  AC-27.11.5 / TC-27.11.3: the PEAK connection budget (all pools × nodes + rolling-
  deploy overlap + ops headroom) must fit within `max_connections`.

  This test reads the `max_connections` of the DB it is connected to (local/CI
  Postgres) as a sanity check AND asserts against the human-verified fly-mpg value
  recorded in `Loopctl.DbCapacity`. The AUTHORITATIVE live production check is the
  runbook command (docs/runbooks/knowledge-scale.md) — the CI DB is not prod, so
  this test cannot itself prove the prod budget; it guards the budget MODEL and the
  verified constant from regressing.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.DbCapacity
  alias Loopctl.Repo

  test "prod pool sizes match the runtime.exs env-var defaults" do
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

  test "peak budget models rolling-deploy overlap (steady + one node + ops headroom)" do
    # 2 nodes: 42 steady + 21 deploy-overlap + 4 ops = 67.
    assert DbCapacity.peak_total(2) == 42 + 21 + DbCapacity.ops_headroom()
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
    assert DbCapacity.fits?(DbCapacity.verified_live_max_connections(), n)
    refute DbCapacity.fits?(DbCapacity.verified_live_max_connections(), n + 1)
  end

  test "the verified live value carries a verification date (operator re-check anchor)" do
    assert %Date{} = DbCapacity.verified_on()
  end
end
