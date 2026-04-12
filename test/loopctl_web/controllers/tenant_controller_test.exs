defmodule LoopctlWeb.TenantControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  # NOTE: Prior to US-26.0.1 this module also covered
  # `POST /api/v1/tenants/register`. That endpoint is removed for Chain
  # of Custody v2 — `/signup` (WebAuthn-gated LiveView) is the only
  # path to create a tenant. Coverage for the new flow lives in
  # `test/loopctl_web/live/signup_live_test.exs`.

  describe "GET /api/v1/tenants/me" do
    test "returns current tenant profile", %{conn: conn} do
      tenant = fixture(:tenant, %{name: "My Tenant"})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> get(~p"/api/v1/tenants/me")

      body = json_response(conn, 200)
      assert body["tenant"]["name"] == "My Tenant"
      assert body["tenant"]["id"] == tenant.id
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tenants/me")
      assert json_response(conn, 401)
    end
  end

  describe "PATCH /api/v1/tenants/me" do
    test "updates tenant name", %{conn: conn} do
      tenant = fixture(:tenant, %{name: "Old Name"})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> patch(~p"/api/v1/tenants/me", %{"name" => "New Name"})

      body = json_response(conn, 200)
      assert body["tenant"]["name"] == "New Name"
    end

    test "updates tenant settings", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> patch(~p"/api/v1/tenants/me", %{
          "settings" => %{"rate_limit_requests_per_minute" => 500}
        })

      body = json_response(conn, 200)
      assert body["tenant"]["settings"]["rate_limit_requests_per_minute"] == 500
    end
  end
end
