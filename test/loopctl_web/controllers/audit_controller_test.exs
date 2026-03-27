defmodule LoopctlWeb.AuditControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Audit

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp create_audit_entry(tenant_id, attrs \\ %{}) do
    default = %{
      entity_type: "project",
      entity_id: Ecto.UUID.generate(),
      action: "created",
      actor_type: "api_key",
      actor_id: Ecto.UUID.generate(),
      actor_label: "user:test",
      new_state: %{"name" => "Test"}
    }

    merged = Map.merge(default, attrs)
    {:ok, entry} = Audit.create_log_entry(tenant_id, merged)
    entry
  end

  describe "GET /api/v1/audit" do
    test "returns paginated audit entries", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      for i <- 1..25 do
        create_audit_entry(tenant.id, %{actor_label: "user:admin-#{i}"})
      end

      # Page 1
      conn1 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/audit?page=1&page_size=10")

      body = json_response(conn1, 200)
      assert length(body["data"]) == 10
      assert body["pagination"]["total"] == 25
      assert body["pagination"]["page"] == 1
      assert body["pagination"]["page_size"] == 10

      # Page 3 (5 entries)
      conn3 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/audit?page=3&page_size=10")

      body3 = json_response(conn3, 200)
      assert length(body3["data"]) == 5
    end

    test "filters by entity_type", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      create_audit_entry(tenant.id, %{entity_type: "project"})
      create_audit_entry(tenant.id, %{entity_type: "story"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/audit?entity_type=project")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["entity_type"] == "project"
    end

    test "filters by action", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      create_audit_entry(tenant.id, %{action: "created"})
      create_audit_entry(tenant.id, %{action: "status_changed"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/audit?action=status_changed")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["action"] == "status_changed"
    end

    test "filters by entity_id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      target_id = Ecto.UUID.generate()
      create_audit_entry(tenant.id, %{entity_id: target_id})
      create_audit_entry(tenant.id, %{entity_id: Ecto.UUID.generate()})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/audit?entity_id=#{target_id}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["entity_id"] == target_id
    end

    test "filters by date range", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      create_audit_entry(tenant.id)

      past = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
      future = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      conn_in_range =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/audit?from=#{past}&to=#{future}")

      body = json_response(conn_in_range, 200)
      assert length(body["data"]) == 1

      # Future-only range returns no results
      far_future = DateTime.utc_now() |> DateTime.add(7200) |> DateTime.to_iso8601()

      conn_empty =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/audit?from=#{far_future}")

      body_empty = json_response(conn_empty, 200)
      assert body_empty["data"] == []
    end

    test "requires user role — agent is rejected", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/audit")

      assert json_response(conn, 403)
    end

    test "orchestrator cannot access audit (below user role)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/audit")

      # Orchestrator is below user in hierarchy: superadmin > user > orchestrator > agent
      assert json_response(conn, 403)
    end

    test "tenant isolation — cannot see other tenant's entries", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      {key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :user})

      create_audit_entry(tenant_a.id, %{actor_label: "user:a"})
      create_audit_entry(tenant_b.id, %{actor_label: "user:b"})

      conn_a = conn |> auth_conn(key_a) |> get(~p"/api/v1/audit")
      body_a = json_response(conn_a, 200)
      assert length(body_a["data"]) == 1
      assert hd(body_a["data"])["actor_label"] == "user:a"

      conn_b = conn |> auth_conn(key_b) |> get(~p"/api/v1/audit")
      body_b = json_response(conn_b, 200)
      assert length(body_b["data"]) == 1
      assert hd(body_b["data"])["actor_label"] == "user:b"
    end

    test "response includes all expected fields", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      create_audit_entry(tenant.id, %{
        entity_type: "project",
        action: "updated",
        old_state: %{"name" => "Old"},
        new_state: %{"name" => "New"},
        metadata: %{"source" => "api"}
      })

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/audit")
      body = json_response(conn, 200)
      entry = hd(body["data"])

      assert Map.has_key?(entry, "id")
      assert Map.has_key?(entry, "entity_type")
      assert Map.has_key?(entry, "entity_id")
      assert Map.has_key?(entry, "action")
      assert Map.has_key?(entry, "actor_type")
      assert Map.has_key?(entry, "actor_id")
      assert Map.has_key?(entry, "actor_label")
      assert Map.has_key?(entry, "old_state")
      assert Map.has_key?(entry, "new_state")
      assert Map.has_key?(entry, "metadata")
      assert Map.has_key?(entry, "inserted_at")
    end
  end
end
