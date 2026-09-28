defmodule Loopctl.Workers.RevokeExpiredDispatchesPlanScaleTest do
  @moduledoc """
  Epic 32, US-32.1, AC-32.1.2: in the table shape production settles into, the query
  `RevokeExpiredDispatchesWorker` actually issues is an index range scan on the partial
  index `dispatches_expires_at_active_index`, chosen by the DEFAULT planner (no
  `enable_seqscan = off`), with no Seq Scan.

  ## Which shape, and where the guarantee ends

  Every swept dispatch stays in the table past its expiry, so a table that has run for a
  while is a large revoked history, a small live set, and a small expired-but-unswept
  backlog the next sweep will take. That is the seed: 20,000 revoked, 50 live, 20 in the
  backlog.

  The guarantee does not extend to a table with a large live fraction. The planner
  multiplies the selectivities of `revoked_at IS NULL` and `expires_at < $1` as if they were
  independent, and they are not (a revoked row is almost always an expired one), so as the
  live fraction grows it overestimates the matches and switches to a Seq Scan. Measured
  with this seed on 2026-09-28 (Postgres 16): the index is chosen at 500 live rows of
  20,500 (2.4%) and a Seq Scan at 1,000 of 21,000 (4.8%). A table in that regime is either
  young, and small enough that a Seq Scan is cheap, or carrying an unusual burst of live
  dispatches; neither is what this index was added for.

  ## Why the scale job, and why not the shared test database

  An ANALYZE inside a sandbox transaction still writes `pg_class.reltuples`/`relpages` in
  place, so its statistics outlive the rollback and skew every other test that plans a
  `dispatches` query. So this test commits its seed, and runs only where that is harmless:
  CI's scale job, which has a database of its own, or a local database other than the
  default suite's (a worktree's derived partition, or an explicit `MIX_TEST_PARTITION`).
  It refuses to run against the shared `loopctl_test` outside CI.

      MIX_TEST_PARTITION=_plan MIX_ENV=test mix ecto.create
      MIX_TEST_PARTITION=_plan MIX_ENV=test mix ecto.migrate
      MIX_TEST_PARTITION=_plan SCALE_TESTS=true mix test --only scale test/loopctl/workers/revoke_expired_dispatches_plan_scale_test.exs

  The query is captured from the worker's own `perform/1` through repo telemetry, not
  rebuilt here, so a WHERE clause that stops implying the index predicate `revoked_at IS
  NULL`, or stops being a range on `expires_at`, turns this red.
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
    if AdminRepo.config()[:database] == "loopctl_test" and is_nil(System.get_env("CI")) do
      raise "RevokeExpiredDispatchesPlanScaleTest commits 20k rows and ANALYZEs dispatches; " <>
              "run it against its own database (see the moduledoc), not the shared loopctl_test"
    end

    Loopctl.DataCase.stub_all_defaults()

    tenant =
      unboxed(fn ->
        slug = "revoke-plan-scale-#{System.unique_integer([:positive])}"

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
    on_exit(fn ->
      unboxed(fn ->
        AdminRepo.delete_all(from(d in Dispatch, where: d.tenant_id == ^tenant.id))
        AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
        AdminRepo.query!("ANALYZE dispatches")
      end)
    end)

    unboxed(fn -> seed!(Ecto.UUID.dump!(tenant.id)) end)
    :ok
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

    AdminRepo.query!("ANALYZE dispatches")
  end

  test "the worker's sweep is an index range scan on the partial index, never a Seq Scan" do
    unboxed(fn ->
      sweep =
        fn -> assert :ok = RevokeExpiredDispatchesWorker.perform(%Oban.Job{args: %{}}) end
        |> PlanAssertions.capture_repo_queries()
        |> PlanAssertions.only_query_matching(~r/FROM "dispatches".*"expires_at" </s)

      PlanAssertions.assert_index_range_scan(sweep, "dispatches", @index, ~r/expires_at < /)
    end)
  end
end
