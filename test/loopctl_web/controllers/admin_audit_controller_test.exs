defmodule LoopctlWeb.AdminAuditControllerTest do
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

  describe "GET /api/v1/admin/audit" do
    test "returns entries from all tenants", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant_a = fixture(:tenant, %{name: "Audit Tenant A"})
      tenant_b = fixture(:tenant, %{name: "Audit Tenant B"})

      create_audit_entry(tenant_a.id, %{actor_label: "user:a"})
      create_audit_entry(tenant_b.id, %{actor_label: "user:b"})
      # Superadmin entry (nil tenant)
      create_audit_entry(nil, %{actor_type: "superadmin", actor_label: "superadmin:admin"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/audit")

      body = json_response(conn, 200)

      labels = Enum.map(body["data"], & &1["actor_label"])
      assert "user:a" in labels
      assert "user:b" in labels
      assert "superadmin:admin" in labels

      # Each entry includes tenant info
      entry_a = Enum.find(body["data"], &(&1["actor_label"] == "user:a"))
      assert entry_a["tenant_id"] == tenant_a.id
      assert entry_a["tenant_name"] == "Audit Tenant A"
      assert entry_a["tenant_slug"] == tenant_a.slug
    end

    test "filter by tenant_id", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      create_audit_entry(tenant_a.id, %{actor_label: "user:filter-a"})
      create_audit_entry(tenant_b.id, %{actor_label: "user:filter-b"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/audit?tenant_id=#{tenant_a.id}")

      body = json_response(conn, 200)
      labels = Enum.map(body["data"], & &1["actor_label"])
      assert "user:filter-a" in labels
      refute "user:filter-b" in labels
    end

    test "filter by actor_type=superadmin shows impersonated actions", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant)

      create_audit_entry(tenant.id, %{
        actor_type: "superadmin",
        actor_label: "superadmin:impersonating"
      })

      create_audit_entry(tenant.id, %{actor_type: "api_key", actor_label: "user:regular"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/audit?actor_type=superadmin")

      body = json_response(conn, 200)
      assert Enum.all?(body["data"], &(&1["actor_type"] == "superadmin"))
      labels = Enum.map(body["data"], & &1["actor_label"])
      refute "user:regular" in labels
    end

    test "combined filters work correctly", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant)

      create_audit_entry(tenant.id, %{entity_type: "story", action: "status_changed"})
      create_audit_entry(tenant.id, %{entity_type: "project", action: "created"})
      create_audit_entry(tenant.id, %{entity_type: "story", action: "created"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(
          ~p"/api/v1/admin/audit?tenant_id=#{tenant.id}&entity_type=story&action=status_changed"
        )

      body = json_response(conn, 200)

      assert Enum.all?(body["data"], fn e ->
               e["entity_type"] == "story" and e["action"] == "status_changed"
             end)
    end

    test "date range filters work", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant)
      create_audit_entry(tenant.id)

      past = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
      future = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      # In range
      conn_in =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/audit?from=#{past}&to=#{future}")

      body = json_response(conn_in, 200)
      assert body["data"] != []

      # Out of range
      far_future = DateTime.utc_now() |> DateTime.add(7200) |> DateTime.to_iso8601()

      conn_out =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/audit?from=#{far_future}")

      body_out = json_response(conn_out, 200)
      assert body_out["data"] == []
    end

    test "pagination works", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant)

      for i <- 1..15 do
        create_audit_entry(tenant.id, %{actor_label: "user:paginate-#{i}"})
      end

      # Page 1
      conn1 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/audit?page=1&page_size=5")

      body1 = json_response(conn1, 200)
      assert length(body1["data"]) == 5
      assert body1["meta"]["page"] == 1
      assert body1["meta"]["total_count"] >= 15
      assert body1["meta"]["total_pages"] >= 3

      # Page 2
      conn2 =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/audit?page=2&page_size=5")

      body2 = json_response(conn2, 200)
      assert length(body2["data"]) == 5
    end

    test "null tenant_id entries included in unfiltered results", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      create_audit_entry(nil, %{
        actor_type: "superadmin",
        actor_label: "superadmin:direct-action"
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/audit")

      body = json_response(conn, 200)
      null_entries = Enum.filter(body["data"], &is_nil(&1["tenant_id"]))

      assert null_entries != []

      null_entry = hd(null_entries)
      assert is_nil(null_entry["tenant_name"])
      assert is_nil(null_entry["tenant_slug"])
    end

    test "entries ordered by inserted_at descending", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant)

      for i <- 1..5 do
        create_audit_entry(tenant.id, %{actor_label: "user:order-#{i}"})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/audit")

      body = json_response(conn, 200)
      timestamps = Enum.map(body["data"], & &1["inserted_at"])

      assert timestamps == Enum.sort(timestamps, :desc)
    end

    test "response includes all expected fields", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant)
      create_audit_entry(tenant.id)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/audit")

      body = json_response(conn, 200)
      entry = hd(body["data"])

      for field <-
            ~w(id tenant_id tenant_name tenant_slug entity_type entity_id action
               actor_type actor_id actor_label old_state new_state metadata inserted_at) do
        assert Map.has_key?(entry, field), "Missing field: #{field}"
      end
    end

    test "non-superadmin cannot access cross-tenant audit", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/audit")

      assert json_response(conn, 403)
    end
  end
end
