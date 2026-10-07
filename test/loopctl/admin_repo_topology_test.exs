defmodule Loopctl.AdminRepoTopologyTest do
  @moduledoc """
  What production's TWO connections do that the test route's one connection cannot show
  (`Loopctl.AdminRepo.Route`), each proved both ways: on the route, then on production's
  topology through `Loopctl.Test.ProductionTopology`.

  - An AdminRepo transaction inside a failing `Repo.with_tenant/2` commits on its own in
    production (its own connection), and rolls back with the tenant transaction on the route.
  - A process holding a row lock through Repo and then writing the row through AdminRepo
    WAITS on itself in production, and passes straight through on the route.

  `async: false`, the documented exception: its subject is the second connection, which needs
  rows both connections see, so they are COMMITTED (`fixture(:committed_tenant)`) and swept.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Loopctl.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Repo
  alias Loopctl.Test.ProductionTopology
  alias Loopctl.WorkBreakdown.Story

  setup do
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()

    # Committed fixtures run their own unboxed checkouts, so they go before this process's.
    tenant = fixture(:committed_tenant, %{})
    story = fixture(:committed_story, %{tenant_id: tenant.id})
    on_exit(fn -> sweep_committed_tenants([tenant.id]) end)

    :ok = Sandbox.checkout(Repo, sandbox: false)
    %{tenant: tenant, story: story}
  end

  defp chain_entries(tenant_id),
    do: AdminRepo.aggregate(from(e in Entry, where: e.tenant_id == ^tenant_id), :count)

  # An audit-chain append (an AdminRepo transaction of its own) inside a tenant transaction
  # that then fails.
  defp append_then_fail(tenant_id) do
    Repo.with_tenant(tenant_id, fn ->
      {:ok, _entry} =
        AuditChain.append(tenant_id, %{
          action: "topology_probe",
          actor_lineage: [],
          entity_type: "story",
          entity_id: nil,
          payload: %{}
        })

      Repo.rollback(:tenant_failed)
    end)
  end

  test "an AdminRepo append inside a failing tenant transaction commits on its own", ctx do
    # The route: one connection, so the append joins the tenant transaction and its
    # rollback takes the entry with it.
    assert {:error, :tenant_failed} = append_then_fail(ctx.tenant.id)
    assert chain_entries(ctx.tenant.id) == 0

    # Production: the append is a second transaction on a second connection, committed
    # before the tenant transaction fails.
    :ok = ProductionTopology.checkout_unboxed!([AdminRepo])
    assert {:error, :tenant_failed} = append_then_fail(ctx.tenant.id)
    assert chain_entries(ctx.tenant.id) == 1
  end

  # The story row locked through Repo, then written through AdminRepo with a short
  # `lock_timeout`, all in this one process. Rolled back either way.
  defp lock_then_write(ctx) do
    Repo.with_tenant(ctx.tenant.id, fn ->
      from(s in Story, where: s.id == ^ctx.story.id, lock: "FOR UPDATE") |> Repo.one!()

      written =
        AdminRepo.transaction(fn ->
          AdminRepo.query!("SET LOCAL lock_timeout = '200ms'")

          from(s in Story, where: s.id == ^ctx.story.id)
          |> AdminRepo.update_all(set: [updated_at: DateTime.utc_now()])
        end)

      Repo.rollback({:written, written})
    end)
  end

  test "a lock held through Repo blocks the same process's AdminRepo write", ctx do
    # The route: one connection holds the lock and makes the write, so nothing waits.
    assert {:error, {:written, {:ok, {1, nil}}}} = lock_then_write(ctx)

    # Production: the write is on AdminRepo's own connection and waits on the lock this
    # process holds through Repo, until lock_timeout.
    :ok = ProductionTopology.checkout_unboxed!([AdminRepo])

    error = assert_raise Postgrex.Error, fn -> lock_then_write(ctx) end
    assert error.postgres.code == :lock_not_available
  end
end
