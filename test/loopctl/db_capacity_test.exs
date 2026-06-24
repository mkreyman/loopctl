defmodule Loopctl.DbCapacityTest do
  @moduledoc """
  AC-27.11.5 / TC-27.11.3: the sum of all configured pools (across app nodes) plus
  headroom must fit within the LIVE `max_connections`. The test reads the live value
  (`SHOW max_connections`) rather than trusting a constant, and also checks the
  human-verified fly-mpg value recorded in `Loopctl.DbCapacity`.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.DbCapacity
  alias Loopctl.Repo

  test "prod pool sizes match the runtime.exs env-var defaults" do
    assert DbCapacity.prod_pool_sizes() == %{repo: 10, admin_repo: 3, heavy_read_repo: 8}
    assert DbCapacity.per_node_total() == 21
    assert DbCapacity.total(2) == 42
  end

  test "the connection budget fits within the LIVE max_connections with headroom (TC-27.11.3)" do
    %{rows: [[raw]]} = Repo.query!("SHOW max_connections")
    live_max = String.to_integer(raw)

    # Up to a documented 2 app nodes (rolling deploy can briefly overlap a 3rd; the
    # 14-conn headroom absorbs that). Assert against BOTH the live DB this test runs
    # on and the human-verified fly-mpg value.
    assert DbCapacity.fits?(live_max, 2),
           "App pool budget #{DbCapacity.total(2)} + #{DbCapacity.headroom()} headroom " <>
             "exceeds live max_connections=#{live_max}. Lower a pool size or raise the DB plan."

    assert DbCapacity.fits?(DbCapacity.verified_live_max_connections(), 2)
  end
end
