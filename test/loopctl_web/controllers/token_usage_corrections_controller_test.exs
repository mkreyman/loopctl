defmodule LoopctlWeb.TokenUsageCorrectionsControllerTest do
  @moduledoc """
  Controller tests for US-21.13: Token Usage Report Correction & Deletion.

  Covers:
  - DELETE /api/v1/token-usage/:id (role: user only)
  - POST /api/v1/token-usage/:id/correction (role: user only)
  - AC-21.13.8: Agent role cannot delete or correct (403)
  - AC-21.13.9: Tenant isolation (404)
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_with_user_key do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {agent_key, _agent_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    {user_key, _user_api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id
      })

    report =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 1000,
        output_tokens: 500,
        cost_millicents: 2500
      })

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      agent: agent,
      agent_key: agent_key,
      user_key: user_key,
      story: story,
      report: report
    }
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/v1/token-usage/:id
  # ---------------------------------------------------------------------------

  describe "DELETE /api/v1/token-usage/:id" do
    test "user role can soft-delete a report (200)", %{conn: conn} do
      %{user_key: user_key, report: report} = setup_with_user_key()

      conn =
        conn
        |> auth_conn(user_key)
        |> delete(~p"/api/v1/token-usage/#{report.id}")

      body = json_response(conn, 200)
      assert body["token_usage_report"]["id"] == report.id
      assert body["token_usage_report"]["deleted_at"] != nil
    end

    test "deleted report is excluded from the listing", %{conn: conn} do
      %{user_key: user_key, agent_key: agent_key, story: story, report: report} =
        setup_with_user_key()

      conn
      |> auth_conn(user_key)
      |> delete(~p"/api/v1/token-usage/#{report.id}")

      list_conn =
        build_conn()
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}/token-usage")

      body = json_response(list_conn, 200)
      assert body["meta"]["total_count"] == 0
      assert body["data"] == []
    end

    test "returns 404 for nonexistent report", %{conn: conn} do
      %{user_key: user_key} = setup_with_user_key()

      conn =
        conn
        |> auth_conn(user_key)
        |> delete(~p"/api/v1/token-usage/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns 404 for already deleted report", %{conn: conn} do
      %{user_key: user_key, report: report} = setup_with_user_key()

      # First delete
      conn
      |> auth_conn(user_key)
      |> delete(~p"/api/v1/token-usage/#{report.id}")

      # Second delete attempt
      conn2 =
        build_conn()
        |> auth_conn(user_key)
        |> delete(~p"/api/v1/token-usage/#{report.id}")

      assert json_response(conn2, 404)
    end

    # AC-21.13.8: Agent role CANNOT delete
    test "agent role returns 403 on delete", %{conn: conn} do
      %{agent_key: agent_key, report: report} = setup_with_user_key()

      conn =
        conn
        |> auth_conn(agent_key)
        |> delete(~p"/api/v1/token-usage/#{report.id}")

      assert json_response(conn, 403)
    end

    # AC-21.13.9: Tenant isolation
    test "cross-tenant delete returns 404", %{conn: conn} do
      %{report: report} = setup_with_user_key()

      other_tenant = fixture(:tenant)
      {other_user_key, _} = fixture(:api_key, %{tenant_id: other_tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(other_user_key)
        |> delete(~p"/api/v1/token-usage/#{report.id}")

      assert json_response(conn, 404)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/v1/token-usage/:id/correction
  # ---------------------------------------------------------------------------

  describe "POST /api/v1/token-usage/:id/correction" do
    test "user role can create a correction (201)", %{conn: conn} do
      %{user_key: user_key, report: report} = setup_with_user_key()

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/token-usage/#{report.id}/correction", %{
          "input_tokens" => -100,
          "output_tokens" => -50,
          "cost_millicents" => -250
        })

      body = json_response(conn, 201)
      correction = body["token_usage_report"]
      assert correction["corrects_report_id"] == report.id
      assert correction["input_tokens"] == -100
      assert correction["output_tokens"] == -50
      assert correction["cost_millicents"] == -250
    end

    test "correction shows in story listing as separate report", %{conn: conn} do
      %{user_key: user_key, agent_key: agent_key, story: story, report: report} =
        setup_with_user_key()

      conn
      |> auth_conn(user_key)
      |> post(~p"/api/v1/token-usage/#{report.id}/correction", %{
        "input_tokens" => -100,
        "output_tokens" => -50,
        "cost_millicents" => -250
      })

      list_conn =
        build_conn()
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}/token-usage")

      body = json_response(list_conn, 200)
      # original + correction = 2 reports
      assert body["meta"]["total_count"] == 2
      # net cost: 2500 - 250 = 2250
      assert body["totals"]["total_cost_millicents"] == 2250
    end

    test "returns 422 if correction would make total negative", %{conn: conn} do
      %{user_key: user_key, report: report} = setup_with_user_key()

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/token-usage/#{report.id}/correction", %{
          "input_tokens" => 0,
          "output_tokens" => 0,
          "cost_millicents" => -9999
        })

      assert json_response(conn, 422)
    end

    test "returns 404 for nonexistent original report", %{conn: conn} do
      %{user_key: user_key} = setup_with_user_key()

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/token-usage/#{Ecto.UUID.generate()}/correction", %{
          "input_tokens" => -100,
          "output_tokens" => -50,
          "cost_millicents" => -250
        })

      assert json_response(conn, 404)
    end

    # AC-21.13.8: Agent role CANNOT create corrections
    test "agent role returns 403 on correction", %{conn: conn} do
      %{agent_key: agent_key, report: report} = setup_with_user_key()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/token-usage/#{report.id}/correction", %{
          "input_tokens" => -100,
          "output_tokens" => -50,
          "cost_millicents" => -250
        })

      assert json_response(conn, 403)
    end

    # AC-21.13.9: Tenant isolation
    test "cross-tenant correction returns 404", %{conn: conn} do
      %{report: report} = setup_with_user_key()

      other_tenant = fixture(:tenant)
      {other_user_key, _} = fixture(:api_key, %{tenant_id: other_tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(other_user_key)
        |> post(~p"/api/v1/token-usage/#{report.id}/correction", %{
          "input_tokens" => -100,
          "output_tokens" => -50,
          "cost_millicents" => -250
        })

      assert json_response(conn, 404)
    end
  end
end
