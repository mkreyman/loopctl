defmodule LoopctlWeb.ExportControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/projects/:id/export" do
    test "export returns complete project structure", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id, name: "Test Project"})

      epic =
        fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1, title: "Epic 1"})

      story_1_1 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.1",
          title: "Story 1.1",
          agent_status: :implementing
        })

      story_1_2 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.2",
          title: "Story 1.2",
          agent_status: :pending
        })

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: story_1_2.id,
        depends_on_story_id: story_1_1.id
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/export")

      body = json_response(conn, 200)

      assert body["project"]["name"] == "Test Project"
      assert body["export_metadata"]["project_id"] == project.id
      assert is_binary(body["export_metadata"]["exported_at"])
      assert is_binary(body["export_metadata"]["loopctl_version"])

      assert length(body["epics"]) == 1
      epic_json = hd(body["epics"])
      assert epic_json["number"] == 1
      assert length(epic_json["stories"]) == 2

      # Stories ordered by number
      first_story = Enum.at(epic_json["stories"], 0)
      assert first_story["number"] == "1.1"
      assert first_story["agent_status"] == "implementing"

      # Dependencies as number pairs
      assert length(body["story_dependencies"]) == 1
      dep = hd(body["story_dependencies"])
      assert dep["story"] == "1.2"
      assert dep["depends_on"] == "1.1"
    end

    test "round-trip fidelity -- export then import", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Source project with data
      source = fixture(:project, %{tenant_id: tenant.id})

      epic =
        fixture(:epic, %{tenant_id: tenant.id, project_id: source.id, number: 1, title: "Epic 1"})

      s1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1", title: "S1"})
      s2 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2", title: "S2"})

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: s2.id,
        depends_on_story_id: s1.id
      })

      # Export
      export_conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{source.id}/export")

      export_body = json_response(export_conn, 200)

      # Import into a new project
      target = fixture(:project, %{tenant_id: tenant.id})

      import_conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{target.id}/import", export_body)

      import_body = json_response(import_conn, 201)
      assert import_body["import"]["epics_created"] == 1
      assert import_body["import"]["stories_created"] == 2
      assert import_body["import"]["dependencies_created"] == 1
    end

    test "export includes all story fields", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        agent_status: :reported_done,
        verified_status: :rejected,
        metadata: %{"priority" => "high"}
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/export")

      body = json_response(conn, 200)
      story = body["epics"] |> hd() |> Map.get("stories") |> hd()

      assert story["agent_status"] == "reported_done"
      assert story["verified_status"] == "rejected"
      assert story["metadata"]["priority"] == "high"
    end

    test "tenant isolation on export", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/projects/#{project_b.id}/export")

      assert json_response(conn, 404)
    end

    test "agent role can export", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/export")

      assert json_response(conn, 200)
    end

    test "export with no epics returns valid empty structure", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/export")

      body = json_response(conn, 200)
      assert body["epics"] == []
      assert body["story_dependencies"] == []
      assert body["export_metadata"]["project_id"] == project.id
    end

    test "export ordering is deterministic", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      # Create epics in reverse order
      fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 3, title: "Epic 3"})
      fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1, title: "Epic 1"})
      fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2, title: "Epic 2"})

      conn1 =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/export")

      body1 = json_response(conn1, 200)

      conn2 =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/export")

      body2 = json_response(conn2, 200)

      # Same ordering
      epic_numbers_1 = Enum.map(body1["epics"], & &1["number"])
      epic_numbers_2 = Enum.map(body2["epics"], & &1["number"])

      assert epic_numbers_1 == [1, 2, 3]
      assert epic_numbers_1 == epic_numbers_2
    end
  end
end
