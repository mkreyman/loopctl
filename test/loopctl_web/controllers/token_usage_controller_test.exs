defmodule LoopctlWeb.TokenUsageControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_story_with_keys do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {agent_key, _agent_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id
      })

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      agent: agent,
      agent_key: agent_key,
      story: story
    }
  end

  # --- POST /api/v1/token-usage ---

  describe "POST /api/v1/token-usage" do
    test "creates a standalone token usage report", %{conn: conn} do
      %{story: story, agent_key: agent_key, agent: agent, project: project} =
        setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => story.id,
          "input_tokens" => 1000,
          "output_tokens" => 500,
          "model_name" => "claude-opus-4",
          "cost_millicents" => 2500,
          "phase" => "implementing"
        })

      body = json_response(conn, 201)
      report = body["token_usage_report"]

      assert report["story_id"] == story.id
      assert report["agent_id"] == agent.id
      assert report["project_id"] == project.id
      assert report["input_tokens"] == 1000
      assert report["output_tokens"] == 500
      assert report["model_name"] == "claude-opus-4"
      assert report["cost_millicents"] == 2500
      assert report["phase"] == "implementing"
      assert report["cost_dollars"] == "0.03"
    end

    test "defaults phase to 'other'", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => story.id,
          "input_tokens" => 100,
          "output_tokens" => 50,
          "model_name" => "gpt-4o",
          "cost_millicents" => 500
        })

      body = json_response(conn, 201)
      assert body["token_usage_report"]["phase"] == "other"
    end

    test "accepts optional session_id and metadata", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => story.id,
          "input_tokens" => 100,
          "output_tokens" => 50,
          "model_name" => "claude-sonnet-4",
          "cost_millicents" => 200,
          "session_id" => "sess-abc",
          "metadata" => %{"context" => "test"}
        })

      body = json_response(conn, 201)
      report = body["token_usage_report"]
      assert report["session_id"] == "sess-abc"
      assert report["metadata"] == %{"context" => "test"}
    end

    test "returns 422 for negative input_tokens", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => story.id,
          "input_tokens" => -1,
          "output_tokens" => 50,
          "model_name" => "claude-opus-4",
          "cost_millicents" => 100
        })

      assert json_response(conn, 422)
    end

    test "returns 422 for missing model_name", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => story.id,
          "input_tokens" => 100,
          "output_tokens" => 50,
          "cost_millicents" => 100
        })

      assert json_response(conn, 422)
    end

    test "returns 422 for empty model_name", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => story.id,
          "input_tokens" => 100,
          "output_tokens" => 50,
          "model_name" => "",
          "cost_millicents" => 100
        })

      assert json_response(conn, 422)
    end

    test "returns 422 when story_id is missing", %{conn: conn} do
      %{agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "input_tokens" => 100,
          "output_tokens" => 50,
          "model_name" => "claude-opus-4",
          "cost_millicents" => 100
        })

      assert json_response(conn, 422)
    end

    test "returns 404 for nonexistent story", %{conn: conn} do
      %{agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => Ecto.UUID.generate(),
          "input_tokens" => 100,
          "output_tokens" => 50,
          "model_name" => "claude-opus-4",
          "cost_millicents" => 100
        })

      assert json_response(conn, 404)
    end

    test "creates audit log entry", %{conn: conn} do
      %{story: story, agent_key: agent_key, tenant: tenant} = setup_story_with_keys()

      conn
      |> auth_conn(agent_key)
      |> post(~p"/api/v1/token-usage", %{
        "story_id" => story.id,
        "input_tokens" => 1000,
        "output_tokens" => 500,
        "model_name" => "claude-opus-4",
        "cost_millicents" => 2500
      })

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "token_usage_report",
          action: "created"
        )

      assert result.data != []
    end

    test "agent_id is set from authenticated key, not request body", %{conn: conn} do
      %{story: story, agent_key: agent_key, agent: agent} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => story.id,
          "input_tokens" => 100,
          "output_tokens" => 50,
          "model_name" => "claude-opus-4",
          "cost_millicents" => 100,
          # This should be ignored -- agent_id comes from auth
          "agent_id" => Ecto.UUID.generate()
        })

      body = json_response(conn, 201)
      assert body["token_usage_report"]["agent_id"] == agent.id
    end
  end

  # --- GET /api/v1/stories/:story_id/token-usage ---

  describe "GET /api/v1/stories/:story_id/token-usage" do
    test "lists token usage reports for a story with totals", %{conn: conn} do
      %{
        story: story,
        agent_key: agent_key,
        tenant: tenant,
        agent: agent,
        project: project
      } = setup_story_with_keys()

      for i <- 1..3 do
        fixture(:token_usage_report, %{
          tenant_id: tenant.id,
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: i * 1000,
          output_tokens: i * 500,
          cost_millicents: i * 2500
        })
      end

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}/token-usage")

      body = json_response(conn, 200)

      assert length(body["data"]) == 3
      assert body["meta"]["total_count"] == 3
      assert body["meta"]["page"] == 1

      totals = body["totals"]
      assert totals["total_input_tokens"] == 6000
      assert totals["total_output_tokens"] == 3000
      assert totals["total_tokens"] == 9000
      assert totals["total_cost_millicents"] == 15_000
      assert totals["report_count"] == 3
      assert totals["total_cost_dollars"] != nil
    end

    test "returns empty list for story with no reports", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}/token-usage")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
      assert body["totals"]["report_count"] == 0
    end

    test "supports pagination", %{conn: conn} do
      %{
        story: story,
        agent_key: agent_key,
        tenant: tenant,
        agent: agent,
        project: project
      } = setup_story_with_keys()

      for _i <- 1..5 do
        fixture(:token_usage_report, %{
          tenant_id: tenant.id,
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id
        })
      end

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}/token-usage?page=1&page_size=2")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 5
      assert body["meta"]["total_pages"] == 3
    end

    test "returns 404 for nonexistent story", %{conn: conn} do
      %{agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{Ecto.UUID.generate()}/token-usage")

      assert json_response(conn, 404)
    end

    test "includes cost_dollars in each report", %{conn: conn} do
      %{
        story: story,
        agent_key: agent_key,
        tenant: tenant,
        agent: agent,
        project: project
      } = setup_story_with_keys()

      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        cost_millicents: 100_000
      })

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}/token-usage")

      body = json_response(conn, 200)
      report = hd(body["data"])
      assert report["cost_dollars"] == "1.00"
    end
  end

  # --- Role enforcement ---

  describe "role enforcement" do
    test "user role can access token-usage endpoints (user >= agent)", %{conn: conn} do
      %{story: story, tenant: tenant} = setup_story_with_keys()
      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(user_key)
        |> get(~p"/api/v1/stories/#{story.id}/token-usage")

      assert json_response(conn, 200)
    end
  end

  # --- Tenant isolation ---

  describe "tenant isolation" do
    test "cross-tenant token-usage creation returns 404", %{conn: conn} do
      %{story: story} = setup_story_with_keys()

      tenant_b = fixture(:tenant)
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id})

      {key_b, _} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent, agent_id: agent_b.id})

      conn =
        conn
        |> auth_conn(key_b)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => story.id,
          "input_tokens" => 100,
          "output_tokens" => 50,
          "model_name" => "claude-opus-4",
          "cost_millicents" => 100
        })

      assert json_response(conn, 404)
    end

    test "cross-tenant token-usage listing returns 404", %{conn: conn} do
      %{story: story} = setup_story_with_keys()

      tenant_b = fixture(:tenant)
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id})

      {key_b, _} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent, agent_id: agent_b.id})

      conn =
        conn
        |> auth_conn(key_b)
        |> get(~p"/api/v1/stories/#{story.id}/token-usage")

      assert json_response(conn, 404)
    end
  end

  # --- Integration with report_story ---

  describe "POST /api/v1/stories/:id/report with token_usage" do
    test "creates token usage report atomically with status transition", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      reviewer_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {reviewer_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: reviewer_agent.id})

      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          project_id: project.id,
          agent_status: :implementing,
          assigned_agent_id: impl_agent.id
        })

      conn =
        conn
        |> auth_conn(reviewer_key)
        |> post(~p"/api/v1/stories/#{story.id}/report", %{
          "token_usage" => %{
            "input_tokens" => 5000,
            "output_tokens" => 2000,
            "model_name" => "claude-opus-4",
            "cost_millicents" => 10_000,
            "phase" => "reviewing"
          }
        })

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "reported_done"

      # Verify token usage report was created
      {:ok, result} =
        Loopctl.TokenUsage.list_reports_for_story(tenant.id, story.id)

      assert length(result.data) == 1
      report = hd(result.data)
      assert report.input_tokens == 5000
      assert report.output_tokens == 2000
      assert report.model_name == "claude-opus-4"
      assert report.cost_millicents == 10_000
      assert report.phase == "reviewing"
      assert report.agent_id == reviewer_agent.id
      assert report.project_id == project.id
    end

    test "report_story without token_usage still works", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      reviewer_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {reviewer_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: reviewer_agent.id})

      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          project_id: project.id,
          agent_status: :implementing,
          assigned_agent_id: impl_agent.id
        })

      conn =
        conn
        |> auth_conn(reviewer_key)
        |> post(~p"/api/v1/stories/#{story.id}/report", %{})

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "reported_done"

      # No token usage report should be created
      {:ok, result} = Loopctl.TokenUsage.list_reports_for_story(tenant.id, story.id)
      assert result.data == []
    end
  end
end
