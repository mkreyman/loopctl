defmodule LoopctlWeb.TenantControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  describe "POST /api/v1/tenants/register" do
    test "successful registration", %{conn: conn} do
      params = %{
        "name" => "Test Corp",
        "slug" => "test-corp",
        "email" => "admin@test.com"
      }

      conn = post(conn, ~p"/api/v1/tenants/register", params)

      assert %{
               "tenant" => %{
                 "id" => _id,
                 "name" => "Test Corp",
                 "slug" => "test-corp",
                 "email" => "admin@test.com",
                 "status" => "active",
                 "settings" => %{}
               },
               "api_key" => %{
                 "raw_key" => raw_key,
                 "key_prefix" => key_prefix,
                 "role" => "user",
                 "name" => "default"
               }
             } = json_response(conn, 201)

      assert String.starts_with?(raw_key, "lc_")
      assert String.length(key_prefix) == 8
    end

    test "registration with custom settings", %{conn: conn} do
      params = %{
        "name" => "Custom Corp",
        "slug" => "custom-corp",
        "email" => "admin@custom.com",
        "settings" => %{"timezone" => "America/New_York"}
      }

      conn = post(conn, ~p"/api/v1/tenants/register", params)
      body = json_response(conn, 201)
      assert body["tenant"]["settings"] == %{"timezone" => "America/New_York"}
    end

    test "duplicate slug returns 409", %{conn: conn} do
      fixture(:tenant, %{slug: "taken-slug"})

      params = %{
        "name" => "Other",
        "slug" => "taken-slug",
        "email" => "other@test.com"
      }

      conn = post(conn, ~p"/api/v1/tenants/register", params)
      assert json_response(conn, 409)
    end

    test "missing required fields returns 422", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/tenants/register", %{"name" => "Test"})

      body = json_response(conn, 422)
      assert body["error"]["details"]["slug"]
      assert body["error"]["details"]["email"]
    end

    test "Multi rollback: duplicate slug creates no orphan tenant", %{conn: conn} do
      fixture(:tenant, %{slug: "rollback-slug"})

      # Count tenants before the failing registration
      before_count = Loopctl.AdminRepo.aggregate(Loopctl.Tenants.Tenant, :count, :id)

      params = %{
        "name" => "Orphan Corp",
        "slug" => "rollback-slug",
        "email" => "orphan@test.com"
      }

      conn = post(conn, ~p"/api/v1/tenants/register", params)
      assert json_response(conn, 409)

      # Verify no new tenant was created (Multi fully rolled back)
      after_count = Loopctl.AdminRepo.aggregate(Loopctl.Tenants.Tenant, :count, :id)
      assert after_count == before_count
    end

    test "does not require authentication", %{conn: conn} do
      params = %{
        "name" => "No Auth Corp",
        "slug" => "no-auth-corp",
        "email" => "admin@noauth.com"
      }

      conn = post(conn, ~p"/api/v1/tenants/register", params)
      # Should not return 401
      refute conn.status == 401
      assert conn.status == 201
    end

    test "returned API key can authenticate", %{conn: conn} do
      params = %{
        "name" => "Auth Test Corp",
        "slug" => "auth-test-corp",
        "email" => "admin@authtest.com"
      }

      resp = conn |> post(~p"/api/v1/tenants/register", params) |> json_response(201)
      raw_key = resp["api_key"]["raw_key"]

      # Use the returned key to access /tenants/me
      me_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> get(~p"/api/v1/tenants/me")

      body = json_response(me_conn, 200)
      assert body["tenant"]["slug"] == "auth-test-corp"
    end

    test "idempotent registration returns same key", %{conn: conn} do
      idempotency_key = Ecto.UUID.generate()

      params = %{
        "name" => "Idempotent Corp",
        "slug" => "idempotent-corp",
        "email" => "admin@idemp.com",
        "idempotency_key" => idempotency_key
      }

      resp1 = conn |> post(~p"/api/v1/tenants/register", params) |> json_response(201)
      resp2 = build_conn() |> post(~p"/api/v1/tenants/register", params) |> json_response(201)

      assert resp1["api_key"]["raw_key"] == resp2["api_key"]["raw_key"]
      assert resp1["tenant"]["id"] == resp2["tenant"]["id"]
    end
  end

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
