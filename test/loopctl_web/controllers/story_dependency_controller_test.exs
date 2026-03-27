defmodule LoopctlWeb.StoryDependencyControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/story_dependencies" do
    test "creates a valid dependency", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story_a = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      story_b = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/story_dependencies", %{
          "story_id" => story_b.id,
          "depends_on_story_id" => story_a.id
        })

      body = json_response(conn, 201)
      dep = body["story_dependency"]
      assert dep["story_id"] == story_b.id
      assert dep["depends_on_story_id"] == story_a.id
    end

    test "rejects self-dependency", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/story_dependencies", %{
          "story_id" => story.id,
          "depends_on_story_id" => story.id
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "cannot depend on itself"
    end

    test "rejects cycle", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story_a = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      story_b = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: story_b.id,
        depends_on_story_id: story_a.id
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/story_dependencies", %{
          "story_id" => story_a.id,
          "depends_on_story_id" => story_b.id
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "Cycle detected"
    end
  end

  describe "DELETE /api/v1/story_dependencies/:id" do
    test "deletes a dependency", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story_a = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      story_b = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})

      dep =
        fixture(:story_dependency, %{
          tenant_id: tenant.id,
          story_id: story_b.id,
          depends_on_story_id: story_a.id
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/story_dependencies/#{dep.id}")

      assert conn.status == 204
    end
  end

  describe "GET /api/v1/epics/:id/story_dependencies" do
    test "lists story deps for epic including cross-epic", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})
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
        |> get(~p"/api/v1/epics/#{epic_2.id}/story_dependencies")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
    end
  end
end
