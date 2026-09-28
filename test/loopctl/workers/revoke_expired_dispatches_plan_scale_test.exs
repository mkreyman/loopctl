defmodule Loopctl.Workers.RevokeExpiredDispatchesPlanScaleTest do
  @moduledoc """
  Epic 32, US-32.1, AC-32.1.2: in the table shape production settles into, the query
  `RevokeExpiredDispatchesWorker` actually issues is an index range scan on the partial
  index `dispatches_expires_at_active_index`, chosen by the DEFAULT planner (no
  `enable_seqscan = off`), with no Seq Scan.

  ## Which shape

  Every swept dispatch stays in the table past its expiry, so a table that has run for a
  while is a large revoked history, a small live set, and a small expired-but-unswept
  backlog the next sweep will take. That is the seed; its sizes are the module attributes
  below. Measured 2026-09-28 (Postgres 16) on a clean table, varying only the live set, the
  index is sought at every live fraction tried, from 50 live rows up to 20,000 (half the
  table).

  ## Why only in CI's scale job

  It commits its seed and ANALYZEs `dispatches`, and an ANALYZE writes
  `pg_class.reltuples`/`relpages` in place, so whatever database it runs in, every other
  test planning a `dispatches` query there plans against its statistics until the next
  ANALYZE. CI's scale job is a database nothing else uses, so the module is skipped unless
  `CI=true` (GitHub Actions sets it). Setting `CI=true` locally runs it against whatever
  database this tree's test config resolves to, with that cost.

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
  if System.get_env("CI") != "true" do
    @moduletag skip:
                 "runs only in CI's scale job (CI=true): it commits rows and ANALYZEs dispatches"
  end

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
    #
    # Foreign-key triggers are off for the delete (`session_replication_role = replica`,
    # scoped to its transaction; the test role is a superuser). Four foreign keys reference
    # `dispatches`, the self-reference `parent_dispatch_id` among them with no index, so a
    # plain delete checks each of the 20k rows against a scan of the table. Measured
    # 2026-09-28: it did not finish inside the test's exit, and every run leaked its seed.
    # Nothing references these rows: they are inserted raw, with no parent, story or
    # criterion pointing at them.
    on_exit(fn ->
      unboxed(fn ->
        {:ok, _} =
          AdminRepo.transaction(fn ->
            AdminRepo.query!("SET LOCAL session_replication_role = replica")
            AdminRepo.delete_all(from(d in Dispatch, where: d.tenant_id == ^tenant.id))
            AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
          end)

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
