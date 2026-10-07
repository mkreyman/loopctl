defmodule Loopctl.Repo.WithTenantRestoreTest do
  @moduledoc """
  Under the SQL sandbox `with_tenant/2`'s transaction is a SAVEPOINT, and a `SET LOCAL` (the
  tenant setting, and in test `SET LOCAL ROLE`) outlives its RELEASE. `with_tenant/2` puts both
  back, so the rest of the test's connection is not left reading as one tenant's RLS role.
  """

  use Loopctl.DataCase, async: true

  defp connection_state do
    %{rows: [[user, tenant]]} =
      Repo.query!("SELECT current_user, current_setting('app.current_tenant_id', true)")

    # A custom setting Postgres has never seen reads NULL; once set and restored it reads ''.
    # Both mean "no tenant", and the session cannot undefine it, so compare them as one state.
    # (The RLS policies cast the setting to uuid, which '' would fail, but they are never
    # evaluated here: the role goes back to the connection's own, which bypasses RLS.)
    {user, if(tenant in [nil, ""], do: :unset, else: tenant)}
  end

  test "the role and tenant setting are restored once with_tenant returns" do
    before = connection_state()
    tenant_id = Ecto.UUID.generate()

    inside =
      Repo.with_tenant(tenant_id, fn -> connection_state() end)

    assert {:ok, {inside_user, ^tenant_id}} = inside
    refute inside_user == elem(before, 0), "with_tenant should switch to the RLS role in test"

    assert connection_state() == before
  end

  test "the outer role and tenant come back, not the connection defaults" do
    # Only a restore of what was there passes this; a reset to defaults leaves postgres.
    outer_tenant = Ecto.UUID.generate()
    Repo.query!("SELECT set_config('app.current_tenant_id', $1, true)", [outer_tenant])
    Repo.query!("SET LOCAL ROLE loopctl_app")
    before = connection_state()

    assert {:ok, _} = Repo.with_tenant(Ecto.UUID.generate(), fn -> :ok end)

    assert connection_state() == before
    assert before == {"loopctl_app", outer_tenant}
    Repo.query!("RESET ROLE")
  end

  test "a with_tenant nested in another raises, as it does outside the sandbox" do
    assert_raise RuntimeError, ~r/called inside an existing Repo transaction/, fn ->
      Repo.with_tenant(Ecto.UUID.generate(), fn ->
        Repo.with_tenant(Ecto.UUID.generate(), fn -> :ok end)
      end)
    end
  end

  test "tenant_multi/2 puts the context back after its transaction" do
    before = connection_state()
    tenant_id = Ecto.UUID.generate()

    multi =
      Ecto.Multi.run(Ecto.Multi.new(), :seen, fn _repo, _changes -> {:ok, connection_state()} end)

    assert {:ok, %{seen: {_rls_user, ^tenant_id}}} =
             tenant_id |> Repo.tenant_multi(multi) |> Repo.transaction()

    assert connection_state() == before
  end
end
