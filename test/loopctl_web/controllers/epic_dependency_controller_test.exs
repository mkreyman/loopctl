defmodule LoopctlWeb.EpicDependencyControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/epic_dependencies" do
    test "creates a valid dependency", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/epic_dependencies", %{
          "epic_id" => epic_b.id,
          "depends_on_epic_id" => epic_a.id
        })

      body = json_response(conn, 201)
      dep = body["epic_dependency"]
      assert dep["epic_id"] == epic_b.id
      assert dep["depends_on_epic_id"] == epic_a.id
    end

    test "rejects self-dependency", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/epic_dependencies", %{
          "epic_id" => epic.id,
          "depends_on_epic_id" => epic.id
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "cannot depend on itself"
    end

    test "rejects cycle", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_b.id,
        depends_on_epic_id: epic_a.id
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/epic_dependencies", %{
          "epic_id" => epic_a.id,
          "depends_on_epic_id" => epic_b.id
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "Cycle detected"
    end

    test "rejects cross-project dependency", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project_a = fixture(:project, %{tenant_id: tenant.id})
      project_b = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project_a.id})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project_b.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/epic_dependencies", %{
          "epic_id" => epic_b.id,
          "depends_on_epic_id" => epic_a.id
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "same project"
    end

    test "rejects duplicate", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_b.id,
        depends_on_epic_id: epic_a.id
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/epic_dependencies", %{
          "epic_id" => epic_b.id,
          "depends_on_epic_id" => epic_a.id
        })

      assert json_response(conn, 409)
    end
  end

  describe "DELETE /api/v1/epic_dependencies/:id" do
    test "deletes a dependency", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      dep =
        fixture(:epic_dependency, %{
          tenant_id: tenant.id,
          epic_id: epic_b.id,
          depends_on_epic_id: epic_a.id
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/epic_dependencies/#{dep.id}")

      assert conn.status == 204
    end
  end

  describe "GET /api/v1/projects/:id/epic_dependencies" do
    test "lists dependencies for project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_b.id,
        depends_on_epic_id: epic_a.id
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/epic_dependencies")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
    end

    test "returns 404 for nonexistent project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{uuid()}/epic_dependencies")

      assert json_response(conn, 404)
    end
  end
end
