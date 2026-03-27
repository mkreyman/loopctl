defmodule LoopctlWeb.ChangeControllerTest do
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

  describe "GET /api/v1/changes" do
    test "returns changes since timestamp", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()

      create_audit_entry(tenant.id, %{actor_label: "user:entry-1"})
      create_audit_entry(tenant.id, %{actor_label: "user:entry-2"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes?since=#{past}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["has_more"] == false
      assert body["next_since"] == nil

      # Entries are ordered ascending
      labels = Enum.map(body["data"], & &1["actor_label"])
      assert labels == ["user:entry-1", "user:entry-2"]
    end

    test "missing since parameter returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes")

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "since"
    end

    test "invalid since timestamp returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes?since=not-a-date")

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "Invalid timestamp"
    end

    test "filters by project_id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      project_a = Ecto.UUID.generate()
      project_b = Ecto.UUID.generate()
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()

      create_audit_entry(tenant.id, %{project_id: project_a, actor_label: "proj-a"})
      create_audit_entry(tenant.id, %{project_id: project_b, actor_label: "proj-b"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes?since=#{past}&project_id=#{project_a}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["actor_label"] == "proj-a"
    end

    test "filters by entity_type and action combined", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()

      create_audit_entry(tenant.id, %{entity_type: "story", action: "status_changed"})
      create_audit_entry(tenant.id, %{entity_type: "story", action: "created"})
      create_audit_entry(tenant.id, %{entity_type: "project", action: "status_changed"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes?since=#{past}&entity_type=story&action=status_changed")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["entity_type"] == "story"
      assert hd(body["data"])["action"] == "status_changed"
    end

    test "result cap with has_more flag", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()

      # Create 5 entries — use limit query param to cap at 3
      for i <- 1..5 do
        create_audit_entry(tenant.id, %{actor_label: "user:entry-#{i}"})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes?since=#{past}&limit=3")

      body = json_response(conn, 200)
      assert length(body["data"]) == 3
      assert body["has_more"] == true
      assert body["next_since"] != nil

      # Using next_since should get remaining entries
      conn2 =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes?since=#{body["next_since"]}&limit=3")

      body2 = json_response(conn2, 200)
      assert length(body2["data"]) == 2
      assert body2["has_more"] == false
    end

    test "agent role can access change feed", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()
      create_audit_entry(tenant.id)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes?since=#{past}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
    end

    test "tenant isolation on change feed", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :orchestrator})

      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()

      create_audit_entry(tenant_a.id, %{actor_label: "tenant-a"})
      create_audit_entry(tenant_b.id, %{actor_label: "tenant-b"})

      conn =
        conn
        |> auth_conn(key_a)
        |> get(~p"/api/v1/changes?since=#{past}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["actor_label"] == "tenant-a"
    end

    test "response omits old_state", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()

      create_audit_entry(tenant.id, %{
        old_state: %{"name" => "Old"},
        new_state: %{"name" => "New"}
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes?since=#{past}")

      body = json_response(conn, 200)
      entry = hd(body["data"])
      refute Map.has_key?(entry, "old_state")
      assert entry["new_state"] == %{"name" => "New"}
    end

    test "response includes expected fields", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()
      create_audit_entry(tenant.id)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/changes?since=#{past}")

      body = json_response(conn, 200)
      entry = hd(body["data"])

      assert Map.has_key?(entry, "id")
      assert Map.has_key?(entry, "entity_type")
      assert Map.has_key?(entry, "entity_id")
      assert Map.has_key?(entry, "action")
      assert Map.has_key?(entry, "actor_type")
      assert Map.has_key?(entry, "actor_label")
      assert Map.has_key?(entry, "new_state")
      assert Map.has_key?(entry, "metadata")
      assert Map.has_key?(entry, "inserted_at")
    end
  end
end
