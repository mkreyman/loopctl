defmodule Loopctl.Workers.RevokeExpiredDispatchesPlanScaleTest do
  @moduledoc """
  Epic 32, US-32.1, AC-32.1.2: the query `RevokeExpiredDispatchesWorker` actually issues is
  served by an index range scan on the partial index `dispatches_expires_at_active_index`,
  chosen by the DEFAULT planner (no `enable_seqscan = off`), with no Seq Scan.

  It lives in the `:scale` job, on that job's own database, because the planner's choice
  depends on table statistics, and there are only two ways to control them:

    * commit the seed and ANALYZE it here. Inside a sandbox transaction an ANALYZE still
      writes `pg_class.reltuples`/`relpages` in place, so its statistics outlive the rollback
      and skew every later test that plans a `dispatches` query. In the shared default-suite
      database that is a flake source; here the rows are committed on purpose, deleted on
      exit, and the table re-ANALYZEd so the next module plans against what is really there.
    * seed the production SHAPE. Every swept dispatch stays in the table past its expiry, so
      the table is a large revoked history plus a small live set. The ratio is what makes
      the choice decisive: the planner multiplies the two predicates' selectivities as if
      independent, so at a live fraction of 10% it estimated ~1,800 matching rows and
      seq-scanned, while at the fraction here the estimate is a few dozen rows.

  The query is captured from the worker's own `perform/1` through repo telemetry, not rebuilt
  here, so a WHERE clause that stops implying the index predicate `revoked_at IS NULL`, or
  stops being a range on `expires_at`, turns this red.

      SCALE_TESTS=true mix test --only scale test/loopctl/workers/revoke_expired_dispatches_plan_scale_test.exs
  """

  use ExUnit.Case, async: false

  import Ecto.Query

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

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  setup do
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

        tenant_id = Ecto.UUID.dump!(tenant.id)

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

        AdminRepo.query!("ANALYZE dispatches")
        tenant
      end)

    on_exit(fn ->
      unboxed(fn ->
        AdminRepo.delete_all(from(d in Dispatch, where: d.tenant_id == ^tenant.id))
        AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
        AdminRepo.query!("ANALYZE dispatches")
      end)
    end)

    :ok
  end

  test "the worker's sweep is an index range scan on the partial index, never a Seq Scan" do
    unboxed(fn ->
      {sql, params} =
        fn -> assert :ok = RevokeExpiredDispatchesWorker.perform(%Oban.Job{args: %{}}) end
        |> PlanAssertions.capture_repo_queries()
        |> PlanAssertions.only_query_matching(~r/FROM "dispatches".*"expires_at" </s)

      %{rows: [[plan]]} = AdminRepo.query!("EXPLAIN (FORMAT JSON) " <> sql, params)
      plan = if is_binary(plan), do: Jason.decode!(plan), else: plan
      root = plan |> List.first() |> Map.fetch!("Plan")

      # Every node that reads `dispatches`: exactly one, and it is the range scan.
      assert [scan] = dispatch_scans(root), "plan: #{Jason.encode!(plan)}"
      assert scan["Node Type"] in ["Index Scan", "Index Only Scan"], Jason.encode!(plan)
      assert scan["Index Name"] == @index
      assert scan["Index Cond"] =~ ~r/expires_at < /
    end)
  end

  defp dispatch_scans(node) do
    here = if node["Relation Name"] == "dispatches", do: [node], else: []
    here ++ Enum.flat_map(Map.get(node, "Plans", []), &dispatch_scans/1)
  end
end
