defmodule LoopctlWeb.ProjectProgressControllerTest do
  @moduledoc """
  Controller tests for the project progress summary endpoint (US-5.2).

  GET /api/v1/projects/:id/progress

  NOTE: Story and Epic schemas don't exist yet (Epic 6). All progress
  values are currently zeroed. These tests verify the JSON response
  structure, HTTP status codes, role enforcement, and tenant scoping.
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/projects/:id/progress" do
    test "returns 200 with zeroed progress for empty project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{project.id}/progress")

      body = json_response(conn, 200)
      progress = body["progress"]

      assert progress["total_stories"] == 0
      assert progress["total_epics"] == 0
      assert progress["epics_completed"] == 0
      assert progress["verification_percentage"] == 0.0
      assert progress["estimated_hours_total"] == 0
      assert progress["estimated_hours_completed"] == 0
    end

    test "response includes stories_by_agent_status with all keys", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{project.id}/progress")

      body = json_response(conn, 200)
      agent_status = body["progress"]["stories_by_agent_status"]

      assert agent_status["pending"] == 0
      assert agent_status["contracted"] == 0
      assert agent_status["assigned"] == 0
      assert agent_status["implementing"] == 0
      assert agent_status["reported_done"] == 0
    end

    test "response includes stories_by_verified_status with all keys", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{project.id}/progress")

      body = json_response(conn, 200)
      verified_status = body["progress"]["stories_by_verified_status"]

      assert verified_status["unverified"] == 0
      assert verified_status["verified"] == 0
      assert verified_status["rejected"] == 0
    end

    test "returns 404 for nonexistent project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{uuid()}/progress")

      assert json_response(conn, 404)
    end

    test "returns 404 for project in different tenant", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project_b.id}/progress")

      assert json_response(conn, 404)
    end

    test "accessible by agent role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{project.id}/progress")

      assert json_response(conn, 200)
    end

    test "accessible by orchestrator role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{project.id}/progress")

      assert json_response(conn, 200)
    end

    test "accessible by user role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{project.id}/progress")

      assert json_response(conn, 200)
    end

    test "returns progress for archived project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      # Archive the project
      Loopctl.Projects.archive_project(tenant.id, project)

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{project.id}/progress")

      body = json_response(conn, 200)
      assert body["progress"]["total_stories"] == 0
    end

    test "verification_percentage is 0.0 when no stories exist", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{project.id}/progress")

      body = json_response(conn, 200)
      assert body["progress"]["verification_percentage"] == 0.0
    end
  end
end
