defmodule LoopctlWeb.Plugs.SetTenantTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth.ApiKey
  alias Loopctl.Repo
  alias LoopctlWeb.Plugs.SetTenant

  describe "call/2" do
    test "sets RLS context for tenant-scoped key", %{conn: conn} do
      tenant = fixture(:tenant)
      api_key = %ApiKey{tenant_id: tenant.id, role: :user}

      conn =
        conn
        |> assign(:current_api_key, api_key)
        |> SetTenant.call([])

      refute conn.halted
      assert Repo.get_tenant_id() == tenant.id
    end

    test "does not set tenant context for superadmin key", %{conn: conn} do
      Repo.clear_tenant_id()
      api_key = %ApiKey{tenant_id: nil, role: :superadmin}

      conn =
        conn
        |> assign(:current_api_key, api_key)
        |> SetTenant.call([])

      refute conn.halted
      assert Repo.get_tenant_id() == nil
    end

    test "passes through when no current_api_key", %{conn: conn} do
      Repo.clear_tenant_id()
      conn = SetTenant.call(conn, [])

      refute conn.halted
      assert Repo.get_tenant_id() == nil
    end
  end
end
