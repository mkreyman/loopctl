defmodule LoopctlWeb.ApiKeyControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/api_keys" do
    test "creates API key with valid attributes", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _admin} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/api_keys", %{"name" => "agent-1", "role" => "agent"})

      body = json_response(conn, 201)
      assert String.starts_with?(body["api_key"]["raw_key"], "lc_")
      assert body["api_key"]["role"] == "agent"
      assert body["api_key"]["name"] == "agent-1"
    end

    test "cannot create superadmin key", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _admin} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/api_keys", %{"name" => "hacker", "role" => "superadmin"})

      assert json_response(conn, 403)
    end

    test "respects max_api_keys limit", %{conn: conn} do
      tenant = fixture(:tenant, %{settings: %{"max_api_keys" => 2}})
      {raw_key, _admin} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "agent-1"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/api_keys", %{"name" => "third", "role" => "agent"})

      assert json_response(conn, 422)
    end

    test "requires user role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/api_keys", %{"name" => "test", "role" => "agent"})

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/v1/api_keys" do
    test "lists keys showing prefix only", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _admin} = fixture(:api_key, %{tenant_id: tenant.id, role: :user, name: "admin"})
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "agent-1"})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/api_keys")

      body = json_response(conn, 200)
      keys = body["api_keys"]
      assert length(keys) == 2

      Enum.each(keys, fn key ->
        assert Map.has_key?(key, "key_prefix")
        refute Map.has_key?(key, "key_hash")
        refute Map.has_key?(key, "raw_key")
      end)
    end

    test "excludes revoked keys by default", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _admin} = fixture(:api_key, %{tenant_id: tenant.id, role: :user, name: "admin"})
      {_raw, revoked} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "revoked"})
      Loopctl.Auth.revoke_api_key(revoked)

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/api_keys")

      body = json_response(conn, 200)
      assert length(body["api_keys"]) == 1
    end

    test "includes revoked keys when requested", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _admin} = fixture(:api_key, %{tenant_id: tenant.id, role: :user, name: "admin"})
      {_raw, revoked} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "revoked"})
      Loopctl.Auth.revoke_api_key(revoked)

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/api_keys?include_revoked=true")

      body = json_response(conn, 200)
      assert length(body["api_keys"]) == 2
    end
  end

  describe "DELETE /api/v1/api_keys/:id" do
    test "revokes an API key", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _admin} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      {_raw, target} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "target"})

      conn = conn |> auth_conn(raw_key) |> delete(~p"/api/v1/api_keys/#{target.id}")

      body = json_response(conn, 200)
      assert body["api_key"]["revoked_at"] != nil
    end

    test "cannot revoke another tenant's key", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _admin} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      {_raw, target} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent})

      conn = conn |> auth_conn(raw_key) |> delete(~p"/api/v1/api_keys/#{target.id}")

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/v1/api_keys/:id/rotate" do
    test "rotates key with grace period", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _admin} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      {_raw, old_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "worker"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/api_keys/#{old_key.id}/rotate", %{"grace_period_hours" => 12})

      body = json_response(conn, 201)
      assert String.starts_with?(body["new_key"]["raw_key"], "lc_")
      assert body["new_key"]["name"] == "worker"
      assert body["new_key"]["role"] == "agent"
      assert body["old_key_expires_at"] != nil
    end

    test "default grace period is 24 hours", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _admin} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      {_raw, old_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "default"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/api_keys/#{old_key.id}/rotate")

      body = json_response(conn, 201)
      expires_at = body["old_key_expires_at"]
      {:ok, parsed, _} = DateTime.from_iso8601(expires_at)
      diff = DateTime.diff(parsed, DateTime.utc_now(), :hour)
      # Should be approximately 24 hours
      assert diff >= 23 and diff <= 25
    end
  end

  describe "cross-tenant isolation" do
    test "cannot see another tenant's keys", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _admin_a} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user, name: "a"})
      fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent, name: "b"})

      conn = conn |> auth_conn(key_a) |> get(~p"/api/v1/api_keys")

      body = json_response(conn, 200)
      names = Enum.map(body["api_keys"], & &1["name"])
      assert "a" in names
      refute "b" in names
    end
  end
end
