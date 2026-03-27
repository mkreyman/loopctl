defmodule LoopctlWeb.Plugs.ImpersonateTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias LoopctlWeb.Plugs.ExtractApiKey
  alias LoopctlWeb.Plugs.Impersonate
  alias LoopctlWeb.Plugs.RequireAuth
  alias LoopctlWeb.Plugs.ResolveApiKey
  alias LoopctlWeb.Plugs.SetTenant

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp impersonate_conn(conn, tenant_id) do
    put_req_header(conn, "x-impersonate-tenant", tenant_id)
  end

  defp effective_role_conn(conn, role) do
    put_req_header(conn, "x-effective-role", role)
  end

  defp resolve_and_auth(conn, raw_key) do
    conn
    |> auth_conn(raw_key)
    |> ExtractApiKey.call([])
    |> ResolveApiKey.call([])
    |> SetTenant.call([])
    |> RequireAuth.call([])
  end

  describe "call/2" do
    test "sets impersonation context for superadmin with valid tenant", %{conn: conn} do
      {raw_key, api_key} = fixture(:api_key, %{role: :superadmin})
      tenant = fixture(:tenant, %{name: "Target Tenant"})

      result =
        conn
        |> impersonate_conn(tenant.id)
        |> resolve_and_auth(raw_key)
        |> Impersonate.call([])

      assert result.assigns.impersonating == true
      assert result.assigns.current_tenant.id == tenant.id
      assert result.assigns.superadmin_api_key.id == api_key.id
      assert result.assigns.impersonated_tenant_id == tenant.id
      # F1 fix: current_api_key.tenant_id is updated to impersonated tenant
      assert result.assigns.current_api_key.tenant_id == tenant.id
    end

    test "silently ignores header for non-superadmin keys", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})

      result =
        conn
        |> impersonate_conn(tenant_b.id)
        |> resolve_and_auth(raw_key)
        |> Impersonate.call([])

      # Should NOT be impersonating
      refute Map.get(result.assigns, :impersonating)
      assert result.assigns.current_tenant.id == tenant_a.id
    end

    test "returns 404 for non-existent tenant ID", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      result =
        conn
        |> impersonate_conn(Ecto.UUID.generate())
        |> resolve_and_auth(raw_key)
        |> Impersonate.call([])

      assert result.halted
      assert result.status == 404
    end

    test "works with suspended tenants", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})
      tenant = fixture(:tenant, %{status: :suspended})

      result =
        conn
        |> impersonate_conn(tenant.id)
        |> resolve_and_auth(raw_key)
        |> Impersonate.call([])

      refute result.halted
      assert result.assigns.impersonating == true
      assert result.assigns.current_tenant.id == tenant.id
    end

    test "passes through when no impersonation header", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      result =
        conn
        |> resolve_and_auth(raw_key)
        |> Impersonate.call([])

      refute Map.get(result.assigns, :impersonating)
    end

    test "applies X-Effective-Role when present", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})
      tenant = fixture(:tenant)

      result =
        conn
        |> impersonate_conn(tenant.id)
        |> effective_role_conn("agent")
        |> resolve_and_auth(raw_key)
        |> Impersonate.call([])

      assert result.assigns.effective_role == :agent
      assert result.assigns.current_api_key.role == :agent
    end

    test "ignores invalid X-Effective-Role", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})
      tenant = fixture(:tenant)

      result =
        conn
        |> impersonate_conn(tenant.id)
        |> effective_role_conn("invalid")
        |> resolve_and_auth(raw_key)
        |> Impersonate.call([])

      assert result.assigns.effective_role == nil
      assert result.assigns.current_api_key.role == :superadmin
    end

    test "skips impersonation on admin routes", %{conn: conn} do
      {raw_key, api_key} = fixture(:api_key, %{role: :superadmin})
      tenant = fixture(:tenant)

      result =
        conn
        |> Map.put(:path_info, ["api", "v1", "admin", "tenants"])
        |> impersonate_conn(tenant.id)
        |> resolve_and_auth(raw_key)
        |> Impersonate.call([])

      # Should NOT be impersonating — admin route skips impersonation
      refute Map.get(result.assigns, :impersonating)
      assert result.assigns.current_api_key.id == api_key.id
      assert result.assigns.current_api_key.role == :superadmin
    end
  end
end
