defmodule LoopctlWeb.Plugs.RateLimiterTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Auth.ApiKey
  alias LoopctlWeb.Plugs.RateLimiter

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "rate limiting" do
    test "request within limit succeeds with headers", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/tenants/me")

      assert conn.status == 200
      assert get_resp_header(conn, "x-ratelimit-limit") != []
      assert get_resp_header(conn, "x-ratelimit-remaining") != []
      assert get_resp_header(conn, "x-ratelimit-reset") != []
    end

    test "request exceeding limit returns 429", %{conn: _conn} do
      tenant = fixture(:tenant, %{settings: %{"rate_limit_requests_per_minute" => 3}})
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # First 3 requests should succeed
      for _ <- 1..3 do
        resp = build_conn() |> auth_conn(raw_key) |> get(~p"/api/v1/tenants/me")
        assert resp.status == 200
      end

      # 4th request should be rate limited
      resp = build_conn() |> auth_conn(raw_key) |> get(~p"/api/v1/tenants/me")
      assert resp.status == 429
      body = json_response(resp, 429)
      assert body["error"]["message"] == "Rate limit exceeded"
      assert get_resp_header(resp, "retry-after") != []
    end

    test "tenant-level custom rate limit is respected", %{conn: conn} do
      tenant = fixture(:tenant, %{settings: %{"rate_limit_requests_per_minute" => 5}})
      {raw_key, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/tenants/me")

      [limit] = get_resp_header(conn, "x-ratelimit-limit")
      assert limit == "5"
    end

    test "superadmin key bypasses rate limiting", %{conn: conn} do
      api_key = %ApiKey{
        id: Ecto.UUID.generate(),
        role: :superadmin,
        tenant_id: nil
      }

      # Test the plug directly rather than going through a full endpoint
      conn =
        conn
        |> assign(:current_api_key, api_key)
        |> assign(:current_tenant, nil)
        |> RateLimiter.call([])

      refute conn.halted
      # No rate limit headers for superadmin
      assert get_resp_header(conn, "x-ratelimit-limit") == []
    end
  end
end
