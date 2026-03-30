defmodule LoopctlWeb.StoryStatusAliasControllerTest do
  @moduledoc """
  Tests for route aliases (Issue 4 — discoverability):
  - POST /stories/:id/report-done  -> StoryStatusController.report
  - POST /stories/:id/start-work   -> StoryStatusController.start
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/stories/:id/report-done" do
    test "alias works identically to /report (cross-agent)", %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})

      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      # Manually set to implementing with the implementer agent
      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      # A different agent (reviewer) does the reporting
      reviewer = fixture(:agent, %{tenant_id: tenant.id})

      {reviewer_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: reviewer.id})

      conn =
        conn
        |> auth_conn(reviewer_key)
        |> post(~p"/api/v1/stories/#{story.id}/report-done", %{
          "summary" => "Done via alias"
        })

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "reported_done"
    end

    test "returns 404 for nonexistent story", %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{uuid()}/report-done", %{"summary" => "done"})

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/v1/stories/:id/start-work" do
    test "alias works identically to /start", %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {raw_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      # Manually set to assigned with correct agent (mirrors pattern in story_status_controller_test)
      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start-work")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "implementing"
    end

    test "returns 404 for nonexistent story", %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{uuid()}/start-work")

      assert json_response(conn, 404)
    end
  end
end
