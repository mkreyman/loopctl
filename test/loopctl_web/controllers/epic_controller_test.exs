defmodule LoopctlWeb.EpicControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/projects/:project_id/epics" do
    test "creates an epic with valid attributes", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/epics", %{
          "number" => 1,
          "title" => "Foundation",
          "phase" => "p0_foundation",
          "position" => 1
        })

      body = json_response(conn, 201)
      epic = body["epic"]

      assert epic["number"] == 1
      assert epic["title"] == "Foundation"
      assert epic["phase"] == "p0_foundation"
      assert epic["position"] == 1
      assert epic["project_id"] == project.id
      assert epic["tenant_id"] == tenant.id
      assert is_binary(epic["id"])
    end

    test "rejects duplicate number within project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/epics", %{
          "number" => 1,
          "title" => "Duplicate"
        })

      assert json_response(conn, 422)
    end

    test "allows same number in different projects", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project_a = fixture(:project, %{tenant_id: tenant.id})
      project_b = fixture(:project, %{tenant_id: tenant.id})
      fixture(:epic, %{tenant_id: tenant.id, project_id: project_a.id, number: 1})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project_b.id}/epics", %{
          "number" => 1,
          "title" => "Same Number"
        })

      assert json_response(conn, 201)
    end

    test "rejects missing required fields", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/epics", %{})

      assert json_response(conn, 422)
    end

    test "requires user role (agent cannot create)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/epics", %{
          "number" => 1,
          "title" => "test"
        })

      assert json_response(conn, 403)
    end

    test "returns 404 for nonexistent project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{uuid()}/epics", %{
          "number" => 1,
          "title" => "Orphan"
        })

      assert json_response(conn, 404)
    end

    test "creates audit log entry", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/projects/#{project.id}/epics", %{
        "number" => 1,
        "title" => "Audited"
      })

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "epic", action: "created")

      assert length(result.data) == 1
    end
  end

  describe "GET /api/v1/projects/:project_id/epics" do
    test "lists epics for project with story counts", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{project.id}/epics")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 2

      # Each epic should have story_count and completion_percentage
      first = hd(body["data"])
      assert Map.has_key?(first, "story_count")
      assert Map.has_key?(first, "completion_percentage")
    end

    test "paginates results", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      for i <- 1..5 do
        fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: i})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/epics?page=1&page_size=2")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 5
      assert body["meta"]["total_pages"] == 3
    end

    test "returns 404 for nonexistent project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{uuid()}/epics")

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/epics/:id" do
    test "returns epic with stories", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/epics/#{epic.id}")

      body = json_response(conn, 200)
      assert body["epic"]["id"] == epic.id
      assert is_list(body["epic"]["stories"])
    end

    test "returns 404 for nonexistent epic", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/epics/#{uuid()}")

      assert json_response(conn, 404)
    end

    test "returns 404 for epic in different tenant", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/epics/#{epic_b.id}")

      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/epics/:id" do
    test "updates epic fields", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/epics/#{epic.id}", %{
          "title" => "Updated Title",
          "phase" => "p1_core"
        })

      body = json_response(conn, 200)
      assert body["epic"]["title"] == "Updated Title"
      assert body["epic"]["phase"] == "p1_core"
    end

    test "number cannot be changed via update", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/epics/#{epic.id}", %{
          "number" => 99,
          "title" => "Updated"
        })

      body = json_response(conn, 200)
      # Number should remain unchanged since it's not in update_changeset cast
      assert body["epic"]["number"] == 1
    end

    test "requires user role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/epics/#{epic.id}", %{"title" => "nope"})

      assert json_response(conn, 403)
    end

    test "creates audit log entry", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn
      |> auth_conn(raw_key)
      |> patch(~p"/api/v1/epics/#{epic.id}", %{"title" => "Renamed"})

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "epic", action: "updated")

      assert length(result.data) == 1
    end
  end

  describe "DELETE /api/v1/epics/:id" do
    test "deletes an epic", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/epics/#{epic.id}")

      assert conn.status == 204

      # Verify it's gone
      get_conn =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/epics/#{epic.id}")

      assert json_response(get_conn, 404)
    end

    test "requires user role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/epics/#{epic.id}")

      assert json_response(conn, 403)
    end

    test "creates audit log entry", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn
      |> auth_conn(raw_key)
      |> delete(~p"/api/v1/epics/#{epic.id}")

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "epic", action: "deleted")

      assert length(result.data) == 1
    end
  end

  describe "GET /api/v1/epics/:id/progress" do
    test "returns epic progress (empty when no stories)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/epics/#{epic.id}/progress")

      body = json_response(conn, 200)
      progress = body["progress"]

      assert progress["stories_by_agent_status"]["pending"] == 0
      assert progress["stories_by_verified_status"]["unverified"] == 0
    end

    test "returns 404 for nonexistent epic", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/epics/#{uuid()}/progress")

      assert json_response(conn, 404)
    end
  end

  describe "cross-tenant isolation" do
    test "cannot access another tenant's epic", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id})

      conn = conn |> auth_conn(key_a) |> get(~p"/api/v1/epics/#{epic_b.id}")

      assert json_response(conn, 404)
    end
  end
end
