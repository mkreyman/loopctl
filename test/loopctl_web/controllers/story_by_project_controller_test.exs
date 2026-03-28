defmodule LoopctlWeb.StoryByProjectControllerTest do
  @moduledoc """
  Tests for GET /api/v1/stories?project_id=X (Issue 1 — project-scoped story listing).
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/stories?project_id=X" do
    test "returns stories for the given project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 2
      assert body["meta"]["limit"] == 100
      assert body["meta"]["offset"] == 0
    end

    test "returns 400 when project_id is missing", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/stories")

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "project_id"
    end

    test "filters by agent_status", %{conn: conn} do
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

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.2",
        agent_status: :implementing
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}&agent_status=pending")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["agent_status"] == "pending"
    end

    test "filters by verified_status", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        verified_status: :unverified
      })

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.2",
        verified_status: :verified
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}&verified_status=verified")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["verified_status"] == "verified"
    end

    test "filters by epic_id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      epic2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{tenant_id: tenant.id, epic_id: epic1.id, number: "1.1"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic2.id, number: "2.1"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}&epic_id=#{epic1.id}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["epic_id"] == epic1.id
    end

    test "respects limit and offset pagination", %{conn: conn} do
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
        |> get(~p"/api/v1/stories?project_id=#{project.id}&limit=2&offset=0")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 5
      assert body["meta"]["limit"] == 2
      assert body["meta"]["offset"] == 0
    end

    test "offset skips records", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      for i <- 1..4 do
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.#{i}"})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}&limit=2&offset=2")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 4
      assert body["meta"]["offset"] == 2
    end

    test "returns empty list for project with no stories", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end

    test "does not return stories from another tenant's project", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id})
      fixture(:story, %{tenant_id: tenant_b.id, epic_id: epic_b.id})

      conn =
        conn
        |> auth_conn(key_a)
        |> get(~p"/api/v1/stories?project_id=#{project_b.id}")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end

    test "requires agent or higher role", %{conn: conn} do
      # User role should be allowed (role: :agent is >= :agent)
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/stories?project_id=#{project.id}")

      # user role has :agent capability, should succeed
      assert json_response(conn, 200)
    end
  end
end
