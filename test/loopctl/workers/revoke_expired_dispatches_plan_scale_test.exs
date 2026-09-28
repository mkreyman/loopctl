defmodule Loopctl.Workers.RevokeExpiredDispatchesPlanScaleTest do
  @moduledoc """
  Epic 32, US-32.1, AC-32.1.2: the query `RevokeExpiredDispatchesWorker` actually issues is
  served by the partial index `dispatches_expires_at_active_index`, chosen by the DEFAULT
  planner (no `enable_seqscan = off`). The query reads one table, so a plan that uses the
  index cannot also Seq Scan it. The planner reaches the index by an Index Scan with a small
  live set and by a Bitmap Index Scan with a larger one; both are a range seek on it, and
  `PlanAssertions.assert_index_used/2` accepts either.

  The seed is the shape a table that has run for a while settles into, since every swept
  dispatch stays in it past expiry: a large revoked history, a small live set and a small
  expired backlog the next sweep will take. Measured 2026-09-28 on Postgres 16, the index is
  used at every live set tried, from 50 rows to half the table.

  The query is captured from the worker's own `perform/1` through repo telemetry, not
  rebuilt here, so a WHERE clause that stops implying the index predicate
  `revoked_at IS NULL`, or stops being a range on `expires_at`, turns this red.

  Synchronous and outside the sandbox, like every `:scale` test: the seed has to be
  committed for a separate VACUUM ANALYZE to count it, and an ANALYZE writes
  `pg_class.reltuples`/`relpages` in place, so it is not something to run beside the async
  suite. CI runs it in the scale job:

      SCALE_TESTS=true mix test --only scale test/loopctl/workers/revoke_expired_dispatches_plan_scale_test.exs
  """

  use ExUnit.Case, async: false

  import Ecto.Query
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
      unboxed(fn ->
        slug = "revoke-plan-scale-#{Ecto.UUID.generate()}"

        {:ok, tenant} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "Revoke plan scale #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        tenant
      end)

    # Registered before anything is seeded, so a seed that fails part-way is still removed.
    on_exit(fn -> unboxed(fn -> remove!(tenant.id) end) end)

    unboxed(fn -> seed!(Ecto.UUID.dump!(tenant.id)) end)
    :ok
  end

  # The dispatches go with foreign-key triggers off (`session_replication_role = replica`,
  # scoped to one transaction; the test role is a superuser). The foreign keys that reference
  # `dispatches` include its own `parent_dispatch_id`, which has no index, so a plain delete
  # checks every row against a scan of the table: measured 2026-09-28, 20k rows did not
  # finish inside the test's exit and every run leaked its seed. Nothing references these
  # rows, which are inserted raw. The tenant is deleted after that transaction commits, with
  # its triggers on, so its own cascades still run.
  defp remove!(tenant_id) do
    {:ok, _} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!("SET LOCAL session_replication_role = replica")
        AdminRepo.delete_all(from(d in Dispatch, where: d.tenant_id == ^tenant_id))
      end)

    AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    AdminRepo.query!("VACUUM ANALYZE dispatches")
  end

  defp seed!(tenant_id) do
    AdminRepo.query!(
      """
      INSERT INTO dispatches (tenant_id, role, expires_at, revoked_at)
      SELECT $1::uuid, 'agent',
             now() - make_interval(hours => g),
             now() - make_interval(hours => g) - interval '1 minute'
      FROM generate_series(1, $2::int) g
      """,
      [tenant_id, @revoked_history]
    )

    AdminRepo.query!(
      """
      INSERT INTO dispatches (tenant_id, role, expires_at)
      SELECT $1::uuid, 'agent', now() + make_interval(mins => g)
      FROM generate_series(1, $2::int) g
      """,
      [tenant_id, @live]
    )

    AdminRepo.query!(
      """
      INSERT INTO dispatches (tenant_id, role, expires_at)
      SELECT $1::uuid, 'agent', now() - make_interval(secs => g)
      FROM generate_series(1, $2::int) g
      """,
      [tenant_id, @backlog]
    )

    # Plan against the table's clean state, which is what CI's fresh database has. A
    # database this test has already run in carries its earlier seeds' deleted rows: as dead
    # heap tuples until a VACUUM, and as index pages a VACUUM empties but never returns.
    # Measured 2026-09-28 after repeated local runs: the partial index held 70 entries in
    # 131 pages, which priced its scan at 540 against about 590 for a Seq Scan, and the
    # planner went either way from run to run. REINDEX rebuilds it at its real size.
    AdminRepo.query!("REINDEX INDEX #{@index}")
    AdminRepo.query!("VACUUM ANALYZE dispatches")
  end

  test "the worker's sweep is served by the partial index" do
    unboxed(fn ->
      sweep =
        fn -> assert :ok = RevokeExpiredDispatchesWorker.perform(%Oban.Job{args: %{}}) end
        |> PlanAssertions.capture_repo_queries()
        |> PlanAssertions.only_query_matching(~r/FROM "dispatches".*"expires_at" </s)

      PlanAssertions.assert_index_used(sweep, @index)
    end)
  end
end
