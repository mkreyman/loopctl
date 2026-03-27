defmodule LoopctlWeb.StoryHistoryControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Audit

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp create_audit_entry(tenant_id, attrs) do
    default = %{
      entity_type: "story",
      entity_id: Ecto.UUID.generate(),
      action: "created",
      actor_type: "api_key",
      actor_id: Ecto.UUID.generate(),
      actor_label: "user:test",
      new_state: %{"title" => "Test Story"}
    }

    merged = Map.merge(default, attrs)
    {:ok, entry} = Audit.create_log_entry(tenant_id, merged)
    entry
  end

  describe "GET /api/v1/stories/:id/history" do
    test "returns full chronological history for a story", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      story_id = Ecto.UUID.generate()

      # Create multiple audit entries in a lifecycle order
      create_audit_entry(tenant.id, %{
        entity_id: story_id,
        action: "created",
        actor_label: "user:admin"
      })

      create_audit_entry(tenant.id, %{
        entity_id: story_id,
        action: "status_changed",
        old_state: %{"agent_status" => "pending"},
        new_state: %{"agent_status" => "assigned"},
        actor_label: "agent:worker-1"
      })

      create_audit_entry(tenant.id, %{
        entity_id: story_id,
        action: "status_changed",
        old_state: %{"agent_status" => "assigned"},
        new_state: %{"agent_status" => "implementing"},
        actor_label: "agent:worker-1"
      })

      create_audit_entry(tenant.id, %{
        entity_id: story_id,
        action: "verified",
        actor_label: "orchestrator:main"
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/#{story_id}/history")

      body = json_response(conn, 200)
      assert length(body["data"]) == 4
      assert body["pagination"]["total"] == 4

      # Chronological order (ascending)
      actions = Enum.map(body["data"], & &1["action"])
      assert List.first(actions) == "created"
      assert List.last(actions) == "verified"
    end

    test "returns 404 for non-existent story", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      random_id = Ecto.UUID.generate()

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/#{random_id}/history")

      assert json_response(conn, 404)
    end

    test "returns 404 for invalid UUID", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/not-a-uuid/history")

      assert json_response(conn, 404)
    end

    test "tenant isolation — cannot view other tenant's story history", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :orchestrator})

      story_id = Ecto.UUID.generate()

      # Story belongs to tenant_b
      create_audit_entry(tenant_b.id, %{entity_id: story_id})

      conn =
        conn
        |> auth_conn(key_a)
        |> get(~p"/api/v1/stories/#{story_id}/history")

      # Tenant A cannot see it — returns 404 (not visible)
      assert json_response(conn, 404)
    end

    test "agent role can access story history", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      story_id = Ecto.UUID.generate()
      create_audit_entry(tenant.id, %{entity_id: story_id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/#{story_id}/history")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
    end

    test "empty history returns 200 with empty data when entity has other entries", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      story_id = Ecto.UUID.generate()

      # Create an audit entry for a different entity_type with the same entity_id
      # This simulates a story that exists but has no "story"-type audit entries
      {:ok, _} =
        Audit.create_log_entry(tenant.id, %{
          entity_type: "artifact_report",
          entity_id: story_id,
          action: "created",
          actor_type: "api_key",
          actor_id: Ecto.UUID.generate(),
          actor_label: "user:admin"
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/#{story_id}/history")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["pagination"]["total"] == 0
    end

    test "pagination works correctly", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      story_id = Ecto.UUID.generate()

      # Create 15 entries
      for i <- 1..15 do
        create_audit_entry(tenant.id, %{
          entity_id: story_id,
          action: "update_#{i}",
          actor_label: "user:admin-#{i}"
        })
      end

      # Page 1 (10 entries default)
      conn1 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/#{story_id}/history?page=1&page_size=10")

      body1 = json_response(conn1, 200)
      assert length(body1["data"]) == 10
      assert body1["pagination"]["total"] == 15
      assert body1["pagination"]["page"] == 1

      # Page 2 (5 remaining)
      conn2 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/#{story_id}/history?page=2&page_size=10")

      body2 = json_response(conn2, 200)
      assert length(body2["data"]) == 5
      assert body2["pagination"]["page"] == 2
    end

    test "response includes full audit details", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      story_id = Ecto.UUID.generate()

      create_audit_entry(tenant.id, %{
        entity_id: story_id,
        action: "status_changed",
        old_state: %{"agent_status" => "pending"},
        new_state: %{"agent_status" => "assigned"},
        metadata: %{"reason" => "auto-assign"}
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/#{story_id}/history")

      body = json_response(conn, 200)
      entry = hd(body["data"])

      assert Map.has_key?(entry, "id")
      assert Map.has_key?(entry, "action")
      assert Map.has_key?(entry, "actor_type")
      assert Map.has_key?(entry, "actor_id")
      assert Map.has_key?(entry, "actor_label")
      assert Map.has_key?(entry, "old_state")
      assert Map.has_key?(entry, "new_state")
      assert Map.has_key?(entry, "metadata")
      assert Map.has_key?(entry, "inserted_at")
      assert entry["old_state"] == %{"agent_status" => "pending"}
      assert entry["new_state"] == %{"agent_status" => "assigned"}
    end
  end
end
