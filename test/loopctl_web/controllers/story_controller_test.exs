defmodule LoopctlWeb.StoryControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/epics/:epic_id/stories" do
    test "creates a story with valid attributes", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/epics/#{epic.id}/stories", %{
          "number" => "1.1",
          "title" => "Phoenix scaffold",
          "estimated_hours" => 8,
          "acceptance_criteria" => [%{"id" => "AC-1", "description" => "App boots"}]
        })

      body = json_response(conn, 201)
      story = body["story"]

      assert story["number"] == "1.1"
      assert story["title"] == "Phoenix scaffold"
      assert story["agent_status"] == "pending"
      assert story["verified_status"] == "unverified"
      assert story["epic_id"] == epic.id
      assert story["project_id"] == project.id
      assert story["tenant_id"] == tenant.id
    end

    test "rejects duplicate number within project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/epics/#{epic.id}/stories", %{
          "number" => "1.1",
          "title" => "Duplicate"
        })

      assert json_response(conn, 422)
    end

    test "rejects missing required fields", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/epics/#{epic.id}/stories", %{})

      assert json_response(conn, 422)
    end

    test "requires user role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/epics/#{epic.id}/stories", %{
          "number" => "1.1",
          "title" => "test"
        })

      assert json_response(conn, 403)
    end

    test "creates audit log entry", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/epics/#{epic.id}/stories", %{
        "number" => "1.1",
        "title" => "Audited"
      })

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "story", action: "created")

      assert length(result.data) == 1
    end
  end

  describe "GET /api/v1/epics/:epic_id/stories" do
    test "lists stories for epic", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/epics/#{epic.id}/stories")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 2
    end

    test "stories sort in natural numeric order", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.10"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "2.1"})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/epics/#{epic.id}/stories")

      body = json_response(conn, 200)
      numbers = Enum.map(body["data"], & &1["number"])
      assert numbers == ["1.1", "1.2", "1.10", "2.1"]
    end

    test "filters by agent_status", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        agent_status: :pending
      })

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.2",
        agent_status: :implementing
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/epics/#{epic.id}/stories?agent_status=pending")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["agent_status"] == "pending"
    end
  end

  describe "GET /api/v1/stories/:id" do
    test "returns story with dependencies and artifacts", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/stories/#{story.id}")

      body = json_response(conn, 200)
      assert body["story"]["id"] == story.id
      assert is_list(body["story"]["dependencies"])
      assert is_list(body["story"]["artifacts"])
      assert body["story"]["latest_verification"] == nil
    end

    test "returns 404 for nonexistent story", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/stories/#{uuid()}")

      assert json_response(conn, 404)
    end

    test "returns 404 for story in different tenant", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id})
      story_b = fixture(:story, %{tenant_id: tenant_b.id, epic_id: epic_b.id})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/stories/#{story_b.id}")

      assert json_response(conn, 404)
    end

    test "embeds project_mission when project has one", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      project =
        fixture(:project, %{
          tenant_id: tenant.id,
          mission: "Build the #1 AI dev loop tool by 2027."
        })

      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/stories/#{story.id}")

      body = json_response(conn, 200)
      assert body["story"]["project_mission"] == "Build the #1 AI dev loop tool by 2027."
    end

    test "omits project_mission key when project has no mission", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/stories/#{story.id}")

      body = json_response(conn, 200)
      refute Map.has_key?(body["story"], "project_mission")
    end
  end

  describe "PATCH /api/v1/stories/:id" do
    test "updates story metadata fields", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/stories/#{story.id}", %{
          "title" => "Updated Title"
        })

      body = json_response(conn, 200)
      assert body["story"]["title"] == "Updated Title"
    end

    test "cannot update agent_status or verified_status", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/stories/#{story.id}", %{
          "agent_status" => "reported_done",
          "verified_status" => "verified",
          "title" => "Updated Title"
        })

      body = json_response(conn, 200)
      assert body["story"]["title"] == "Updated Title"
      assert body["story"]["agent_status"] == "pending"
      assert body["story"]["verified_status"] == "unverified"
    end

    test "requires user role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/stories/#{story.id}", %{"title" => "nope"})

      assert json_response(conn, 403)
    end
  end

  describe "DELETE /api/v1/stories/:id" do
    test "deletes a story", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/stories/#{story.id}")

      assert conn.status == 204

      get_conn =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/#{story.id}")

      assert json_response(get_conn, 404)
    end

    test "creates audit log entry", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn
      |> auth_conn(raw_key)
      |> delete(~p"/api/v1/stories/#{story.id}")

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "story", action: "deleted")

      assert length(result.data) == 1
    end
  end

  describe "cross-tenant isolation" do
    test "cannot access another tenant's story", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id})
      story_b = fixture(:story, %{tenant_id: tenant_b.id, epic_id: epic_b.id})

      conn = conn |> auth_conn(key_a) |> get(~p"/api/v1/stories/#{story_b.id}")

      assert json_response(conn, 404)
    end
  end

  # Issue 2: param aliasing — page_size accepted as alias for limit in epic stories index
  describe "GET /api/v1/epics/:epic_id/stories — param aliasing" do
    test "accepts page_size as alias for page_size (normal param)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      for i <- 1..5 do
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.#{i}"})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/epics/#{epic.id}/stories?page_size=2")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["page_size"] == 2
    end

    test "accepts limit as alias for page_size in epic stories index", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      for i <- 1..5 do
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.#{i}"})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/epics/#{epic.id}/stories?limit=3")

      body = json_response(conn, 200)
      assert length(body["data"]) == 3
      assert body["meta"]["page_size"] == 3
    end

    test "page_size takes precedence over limit when both provided", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      for i <- 1..5 do
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.#{i}"})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/epics/#{epic.id}/stories?page_size=2&limit=4")

      body = json_response(conn, 200)
      # page_size is preferred when both are present
      assert length(body["data"]) == 2
      assert body["meta"]["page_size"] == 2
    end
  end

  # Issue 2: param aliasing — limit accepted as alias for page_size in project stories index
  describe "GET /api/v1/stories?project_id=X — param aliasing" do
    test "accepts page_size as alias for limit in project stories index", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      for i <- 1..5 do
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.#{i}"})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}&page_size=2")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["limit"] == 2
    end

    test "limit takes precedence over page_size when both provided", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      for i <- 1..5 do
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.#{i}"})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}&limit=3&page_size=2")

      body = json_response(conn, 200)
      # limit is preferred when both are present
      assert length(body["data"]) == 3
      assert body["meta"]["limit"] == 3
    end
  end
end
