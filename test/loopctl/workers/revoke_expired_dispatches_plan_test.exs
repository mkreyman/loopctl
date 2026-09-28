defmodule Loopctl.Workers.RevokeExpiredDispatchesPlanTest do
  @moduledoc """
  Epic 32 (scalability), US-32.1, AC-32.1.2: the query `RevokeExpiredDispatchesWorker`
  actually issues is served by the partial index `dispatches_expires_at_active_index`,
  chosen by the DEFAULT planner (no `enable_seqscan = off`).

  Two things make this deterministic, and both are load-bearing:

    * `async: false`. ExUnit runs every async module first and the sync ones after, one
      at a time, so no other test is writing `dispatches` while this one plans. The same
      assertion in the async suite failed at random, because the planner's choice moved
      with the rows its neighbours had in flight.
    * a seeded, ANALYZEd table in the production shape: a large revoked history (every
      swept dispatch stays in the table, past its expiry) and a small live set. The RATIO
      is what keeps the choice from being marginal. The planner multiplies the two
      predicates' selectivities as if independent, so with a live fraction of 10% it
      estimated ~1,800 matching rows and a Seq Scan won; at the fraction here the estimate
      is a few dozen rows and the partial index wins by an order of magnitude. `ANALYZE`
      runs inside this test's sandbox transaction, so it counts the seeded rows and its
      statistics roll back with them.

  The query is captured from the worker's own `perform/1` through repo telemetry, not
  rebuilt here, so a change to the worker's WHERE clause that stops implying the index
  predicate `revoked_at IS NULL` turns this red.
  """

  use Loopctl.DataCase, async: false

  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.PlanAssertions
  alias Loopctl.Workers.RevokeExpiredDispatchesWorker

  @revoked_history 20_000
  @live 50

  test "the worker's sweep uses dispatches_expires_at_active_index at seeded scale" do
    tenant = fixture(:tenant)

    AdminRepo.query!(
      """
      INSERT INTO dispatches (tenant_id, role, expires_at, revoked_at)
      SELECT $1::uuid, 'agent',
             now() - make_interval(hours => g),
             now() - make_interval(hours => g) - interval '1 minute'
      FROM generate_series(1, $2::int) g
      """,
      [Ecto.UUID.dump!(tenant.id), @revoked_history]
    )

    AdminRepo.query!(
      """
      INSERT INTO dispatches (tenant_id, role, expires_at)
      SELECT $1::uuid, 'agent', now() + make_interval(mins => g)
      FROM generate_series(1, $2::int) g
      """,
      [Ecto.UUID.dump!(tenant.id), @live]
    )

    AdminRepo.query!("ANALYZE dispatches")

    sweep =
      fn -> assert :ok = RevokeExpiredDispatchesWorker.perform(%Oban.Job{args: %{}}) end
      |> PlanAssertions.capture_repo_queries()
      |> PlanAssertions.only_query_matching(~r/FROM "dispatches".*"expires_at" </s)

    PlanAssertions.assert_index_used(sweep, "dispatches_expires_at_active_index")
  end
end
