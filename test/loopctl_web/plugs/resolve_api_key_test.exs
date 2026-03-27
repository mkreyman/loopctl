defmodule LoopctlWeb.Plugs.ResolveApiKeyTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias LoopctlWeb.Plugs.ResolveApiKey

  describe "call/2" do
    test "resolves valid key and assigns api_key + tenant", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> assign(:raw_api_key, raw_key)
        |> ResolveApiKey.call([])

      refute conn.halted
      assert conn.assigns.current_api_key.id == api_key.id
      assert conn.assigns.current_tenant.id == tenant.id
    end

    test "skips verification when raw_api_key is nil", %{conn: conn} do
      conn =
        conn
        |> assign(:raw_api_key, nil)
        |> ResolveApiKey.call([])

      refute conn.halted
      refute Map.has_key?(conn.assigns, :current_api_key)
    end

    test "halts with 401 for invalid key", %{conn: conn} do
      conn =
        conn
        |> assign(:raw_api_key, "lc_invalid_key_doesnt_exist")
        |> ResolveApiKey.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects suspended tenant with 403", %{conn: conn} do
      tenant = fixture(:tenant, %{status: :suspended})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> assign(:raw_api_key, raw_key)
        |> ResolveApiKey.call([])

      assert conn.halted
      assert conn.status == 403
    end

    test "passes through when no raw_api_key assign exists", %{conn: conn} do
      conn = ResolveApiKey.call(conn, [])

      refute conn.halted
      refute Map.has_key?(conn.assigns, :current_api_key)
    end
  end
end
