defmodule LoopctlWeb.DependencyGraphControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/stories/ready" do
    test "returns ready stories with no dependencies", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        agent_status: :pending
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/ready?project_id=#{project.id}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert body["meta"]["total_count"] == 1
    end

    test "excludes stories with unverified dependencies", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      dep_story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.1",
          agent_status: :pending,
          verified_status: :unverified
        })

      blocked_story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.2",
          agent_status: :pending
        })

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: blocked_story.id,
        depends_on_story_id: dep_story.id
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/ready?project_id=#{project.id}")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      assert dep_story.id in ids
      refute blocked_story.id in ids
    end

    test "filters by epic_id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic_1.id,
        number: "1.1",
        agent_status: :pending
      })

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic_2.id,
        number: "2.1",
        agent_status: :pending
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/ready?epic_id=#{epic_1.id}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
    end

    test "respects epic-level dependencies", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_2.id,
        depends_on_epic_id: epic_1.id
      })

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic_1.id,
        number: "1.1",
        agent_status: :reported_done,
        verified_status: :unverified
      })

      story_2 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic_2.id,
          number: "2.1",
          agent_status: :pending
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/ready?project_id=#{project.id}")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      refute story_2.id in ids
    end
  end

  describe "GET /api/v1/stories/blocked" do
    test "returns blocked stories with blocking dependencies", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      blocker =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.1",
          agent_status: :implementing,
          verified_status: :unverified
        })

      blocked =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.2",
          agent_status: :pending
        })

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: blocked.id,
        depends_on_story_id: blocker.id
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories/blocked?project_id=#{project.id}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      item = hd(body["data"])
      assert item["story"]["id"] == blocked.id
      assert length(item["blocking_dependencies"]) == 1
      assert hd(item["blocking_dependencies"])["id"] == blocker.id
    end
  end

  describe "GET /api/v1/projects/:id/dependency_graph" do
    test "returns full graph", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_2.id,
        depends_on_epic_id: epic_1.id
      })

      story_1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_1.id, number: "1.1"})
      story_2 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_2.id, number: "2.1"})

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: story_2.id,
        depends_on_story_id: story_1.id
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/dependency_graph")

      body = json_response(conn, 200)
      graph = body["graph"]

      assert length(graph["epics"]) == 2
      assert length(graph["epic_dependencies"]) == 1
      assert length(graph["story_dependencies"]) == 1

      # Each epic should have stories with statuses
      epic = hd(graph["epics"])
      assert is_list(epic["stories"])
    end

    test "returns 404 for nonexistent project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{uuid()}/dependency_graph")

      assert json_response(conn, 404)
    end

    test "returns 404 for project in different tenant", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project_b.id}/dependency_graph")

      assert json_response(conn, 404)
    end
  end
end
