defmodule Loopctl.Workers.RevokeExpiredDispatchesPlanScaleTest do
  @moduledoc """
  Epic 32, US-32.1, AC-32.1.2: the query `RevokeExpiredDispatchesWorker` actually issues is
  served by the partial index `dispatches_expires_at_active_index`, chosen by the DEFAULT
  planner (no `enable_seqscan = off`), and is the ONLY index in the plan, so a bitmap that
  also reads the tenant-leading composite or any other index whole fails. The query reads one
  table, so a plan that uses the index cannot also Seq Scan it. With a small live set the
  planner reaches the index by an Index Scan, with a larger one by a Bitmap Index Scan; both
  seek it.

  The seed is the shape a table that has run for a while settles into, since every swept
  dispatch stays in it past expiry: a large revoked history, a small live set and a small
  expired backlog the next sweep will take. Measured 2026-09-28 on Postgres 16, the index is
  used at every live set tried, from 50 rows to half the table.

  The query is captured from the worker's own `perform/1` through repo telemetry, not
  rebuilt here, so a WHERE clause that stops implying the index predicate
  `revoked_at IS NULL`, or stops being a range on `expires_at`, turns this red. The sweep
  runs inside a transaction this test rolls back: it is cross-tenant, and in a database other
  tests have used it would otherwise revoke their expired dispatches too.

  Synchronous and outside the sandbox like every `:scale` test, which is this repo's
  standing exception to its async rule: the seed has to be committed for a separate VACUUM
  ANALYZE to count it. The ANALYZE writes `pg_class.reltuples`/`relpages` in place, so run it
  in a database no other suite is using at the same time; CI runs it in the scale job's own:

      SCALE_TESTS=true mix test --only scale test/loopctl/workers/revoke_expired_dispatches_plan_scale_test.exs
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Loopctl.Fixtures
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.PlanAssertions
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.RevokeExpiredDispatchesWorker

  @moduletag :scale

  @index "dispatches_expires_at_active_index"
  @revoked_history 20_000
  @live 50
  @backlog 20

  setup :verify_on_exit!

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  setup do
    Loopctl.DataCase.stub_all_defaults()

    tenant =
      unboxed(fn -> fixture(:tenant, slug: "revoke-plan-scale-#{Ecto.UUID.generate()}") end)

    # Registered before anything is seeded, so a seed that fails part-way is still removed.
    on_exit(fn ->
      unboxed(fn ->
        AdminRepo.delete_all(from(d in Dispatch, where: d.tenant_id == ^tenant.id))
        AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
        AdminRepo.query!("VACUUM ANALYZE dispatches")
      end)
    end)

    unboxed(fn -> seed!(tenant.id) end)
    {:ok, tenant: tenant}
  end

  defp seed!(tenant_id) do
    fixture(:dispatch_sweep_history,
      tenant_id: tenant_id,
      revoked: @revoked_history,
      live: @live,
      backlog: @backlog
    )

    # Plan against the table's clean state, which is what CI's fresh database has. A
    # database this test has already run in carries its earlier seeds' deleted rows: as dead
    # heap tuples until a VACUUM, and as index pages a VACUUM empties but never returns.
    # Measured 2026-09-28 after repeated local runs: the partial index held 70 entries in
    # 131 pages, which priced its scan at 540 against about 590 for a Seq Scan, and the
    # planner went either way from run to run. REINDEX rebuilds it at its real size;
    # CONCURRENTLY, so writers elsewhere in the database are not blocked behind it. An
    # interrupted concurrent rebuild leaves an INVALID `<index>_ccnew*` behind that every
    # later insert keeps maintaining, so any such leftover is dropped first.
    %{rows: leftovers} =
      AdminRepo.query!(
        "SELECT c.relname FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid " <>
          "WHERE i.indrelid = 'public.dispatches'::regclass AND NOT i.indisvalid " <>
          "AND c.relname ~ ('^' || $1 || '_cc(new|old)[0-9]*$')",
        [@index]
      )

    for [name] <- leftovers, do: AdminRepo.query!("DROP INDEX CONCURRENTLY IF EXISTS #{name}")

    AdminRepo.query!("REINDEX INDEX CONCURRENTLY #{@index}")
    AdminRepo.query!("VACUUM ANALYZE dispatches")
  end

  test "the worker's sweep is served by the partial index", %{tenant: tenant} do
    unboxed(fn ->
      captured =
        PlanAssertions.capture_repo_queries(fn ->
          {:error, :rolled_back} =
            AdminRepo.transaction(fn ->
              assert :ok = RevokeExpiredDispatchesWorker.perform(%Oban.Job{args: %{}})

              # perform/1 answers :ok whatever its write did, so check the write: the backlog,
              # and only the backlog, of this tenant's dispatches is revoked.
              # Raw, unquoted SQL so the capture below cannot mistake it for the sweep.
              assert %{rows: [[@live]]} =
                       AdminRepo.query!(
                         "select count(*) from dispatches where tenant_id = $1 and revoked_at is null",
                         [Ecto.UUID.dump!(tenant.id)]
                       )

              AdminRepo.rollback(:rolled_back)
            end)
        end)

      sweep = PlanAssertions.only_query_matching(captured, ~r/\ASELECT .* FROM "dispatches"/s)

      PlanAssertions.assert_only_index_used(sweep, "dispatches", @index, "revoked_at")
    end)
  end
end
