defmodule LoopctlWeb.GitHubCredentialControllerTest do
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Forge

  defp auth_conn(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp user_conn(conn) do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    {auth_conn(conn, raw_key), tenant}
  end

  describe "PUT /api/v1/tenants/me/github-credential" do
    test "stores the token for the caller's tenant; the response never carries it", %{conn: conn} do
      {conn, tenant} = user_conn(conn)

      body =
        conn
        |> put(~p"/api/v1/tenants/me/github-credential", %{token: "github_pat_ctrl_9876"})
        |> json_response(200)

      assert body["has_token"] == true
      assert body["token_hint"] == "…9876"
      assert body["operator_repositories"] == []
      refute inspect(body) =~ "github_pat_ctrl_9876"
      assert Forge.token(tenant.id) == {:ok, "github_pat_ctrl_9876"}
    end

    test "a missing or malformed token is 422 and stores nothing", %{conn: conn} do
      {conn, tenant} = user_conn(conn)

      assert conn |> put(~p"/api/v1/tenants/me/github-credential", %{}) |> json_response(422)

      assert conn
             |> put(~p"/api/v1/tenants/me/github-credential", %{token: "has space"})
             |> json_response(422)

      assert Forge.token(tenant.id) == :none
    end

    test "every role below user is 403 and stores nothing", %{conn: conn} do
      tenant = fixture(:tenant)

      for role <- [:agent, :orchestrator] do
        {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: role})

        assert conn
               |> auth_conn(raw_key)
               |> put(~p"/api/v1/tenants/me/github-credential", %{token: "github_pat_role_0001"})
               |> json_response(403)

        assert conn
               |> auth_conn(raw_key)
               |> get(~p"/api/v1/tenants/me/github-credential")
               |> json_response(403)
      end

      assert Forge.token(tenant.id) == :none
    end
  end

  describe "tier (#936)" do
    test "an agent-rooted tenant cannot set or clear one, and can still read", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      conn = auth_conn(conn, raw_key)

      assert %{"error" => %{"code" => "custody_tier_required"}} =
               conn
               |> put(~p"/api/v1/tenants/me/github-credential", %{token: "github_pat_tier_0001"})
               |> json_response(403)

      assert conn |> delete(~p"/api/v1/tenants/me/github-credential") |> json_response(403)

      assert %{"has_token" => false} =
               conn |> get(~p"/api/v1/tenants/me/github-credential") |> json_response(200)

      assert Forge.token(tenant.id) == :none
    end
  end

  describe "a tenant-less superadmin key" do
    test "is refused naming the impersonation header, on every verb", %{conn: conn} do
      {raw_super, _key} = fixture(:api_key, %{role: :superadmin})
      conn = auth_conn(conn, raw_super)

      for response <- [
            get(conn, ~p"/api/v1/tenants/me/github-credential"),
            put(conn, ~p"/api/v1/tenants/me/github-credential", %{token: "github_pat_super01"}),
            delete(conn, ~p"/api/v1/tenants/me/github-credential")
          ] do
        assert %{"error" => %{"code" => code}} = json_response(response, 422)
        assert code == "impersonation_tenant_required"
      end
    end
  end

  describe "GET and DELETE" do
    test "GET reports the tenant's own state only; DELETE clears it, twice safely", %{conn: conn} do
      {conn, tenant} = user_conn(conn)
      other = fixture(:tenant)
      {:ok, _} = Forge.set_token(other.id, "github_pat_other_0001", nil)

      assert %{"has_token" => false, "token_hint" => nil} =
               conn |> get(~p"/api/v1/tenants/me/github-credential") |> json_response(200)

      {:ok, _} = Forge.set_token(tenant.id, "github_pat_mine_00001", nil)

      assert %{"has_token" => true} =
               conn |> get(~p"/api/v1/tenants/me/github-credential") |> json_response(200)

      for _twice <- 1..2 do
        assert %{"has_token" => false} =
                 conn |> delete(~p"/api/v1/tenants/me/github-credential") |> json_response(200)
      end

      assert Forge.token(tenant.id) == :none
      assert Forge.token(other.id) == {:ok, "github_pat_other_0001"}
    end
  end
end
