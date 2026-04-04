defmodule LoopctlWeb.SkillCostPerformanceControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Skills
  alias Loopctl.TokenUsage

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_context do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    skill =
      fixture(:skill, %{
        tenant_id: tenant.id,
        name: "test-skill-#{System.unique_integer([:positive])}"
      })

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id
      })

    {:ok, v1} = Skills.get_version(tenant.id, skill.id, 1)

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      agent: agent,
      user_key: user_key,
      agent_key: agent_key,
      skill: skill,
      story: story,
      v1: v1
    }
  end

  defp create_report(ctx, skill_version, cost_millicents) do
    {:ok, _report} =
      TokenUsage.create_report(ctx.tenant.id, %{
        story_id: ctx.story.id,
        agent_id: ctx.agent.id,
        project_id: ctx.project.id,
        input_tokens: 100,
        output_tokens: 50,
        model_name: "claude-opus-4",
        cost_millicents: cost_millicents,
        skill_version_id: skill_version.id
      })
  end

  # -------------------------------------------------------------------
  # GET /api/v1/skills/:id/cost-performance
  # -------------------------------------------------------------------

  describe "GET /api/v1/skills/:id/cost-performance" do
    test "returns empty data when no token reports are linked", %{conn: conn} do
      ctx = setup_context()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/skills/#{ctx.skill.id}/cost-performance")

      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "returns cost metrics for a version with linked reports", %{conn: conn} do
      ctx = setup_context()

      create_report(ctx, ctx.v1, 2000)
      create_report(ctx, ctx.v1, 4000)

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/skills/#{ctx.skill.id}/cost-performance")

      body = json_response(conn, 200)
      assert [row] = body["data"]

      assert row["version_number"] == 1
      assert row["total_invocations"] == 2
      assert row["total_cost_millicents"] == 6000
      assert row["avg_cost_per_invocation_millicents"] == 3000
      assert is_nil(row["cost_change_pct"])
      assert row["cost_regression"] == false
    end

    test "cost_regression is flagged when avg > 2x previous AND >= 3 invocations", %{conn: conn} do
      ctx = setup_context()

      {:ok, %{version: v2}} =
        Skills.create_version(ctx.tenant.id, ctx.skill.id, %{"prompt_text" => "v2"})

      create_report(ctx, ctx.v1, 1000)
      create_report(ctx, ctx.v1, 1000)
      create_report(ctx, ctx.v1, 1000)

      create_report(ctx, v2, 3000)
      create_report(ctx, v2, 3000)
      create_report(ctx, v2, 3000)

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/skills/#{ctx.skill.id}/cost-performance")

      body = json_response(conn, 200)
      assert [_v1, v2_row] = body["data"]

      assert v2_row["cost_regression"] == true
      assert v2_row["cost_change_pct"] == 200
    end

    test "returns 404 for nonexistent skill", %{conn: conn} do
      ctx = setup_context()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/skills/#{Ecto.UUID.generate()}/cost-performance")

      assert json_response(conn, 404)
    end

    test "agent role is forbidden (requires user role)", %{conn: conn} do
      ctx = setup_context()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/skills/#{ctx.skill.id}/cost-performance")

      assert json_response(conn, 403)
    end

    test "tenant isolation: cannot see another tenant's skill", %{conn: conn} do
      ctx_a = setup_context()
      tenant_b = fixture(:tenant)
      {key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :user})

      conn =
        conn
        |> auth_conn(key_b)
        |> get(~p"/api/v1/skills/#{ctx_a.skill.id}/cost-performance")

      assert json_response(conn, 404)
    end
  end

  # -------------------------------------------------------------------
  # GET /api/v1/skills/:id/versions/:version — extended with cost_summary
  # -------------------------------------------------------------------

  describe "GET /api/v1/skills/:id/versions/:version with cost_summary" do
    test "cost_summary is nil when no reports are linked", %{conn: conn} do
      ctx = setup_context()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/skills/#{ctx.skill.id}/versions/1")

      body = json_response(conn, 200)
      assert body["version"]["version"] == 1
      assert is_nil(body["cost_summary"])
    end

    test "cost_summary is populated when reports are linked", %{conn: conn} do
      ctx = setup_context()

      create_report(ctx, ctx.v1, 2000)
      create_report(ctx, ctx.v1, 4000)

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/skills/#{ctx.skill.id}/versions/1")

      body = json_response(conn, 200)
      summary = body["cost_summary"]

      assert summary["version_number"] == 1
      assert summary["total_invocations"] == 2
      assert summary["total_cost_millicents"] == 6000
      assert summary["avg_cost_per_invocation_millicents"] == 3000
    end
  end

  # -------------------------------------------------------------------
  # POST /api/v1/token-usage — skill_version_id validation
  # -------------------------------------------------------------------

  describe "POST /api/v1/token-usage with skill_version_id" do
    test "accepts valid skill_version_id from same tenant", %{conn: conn} do
      ctx = setup_context()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => ctx.story.id,
          "input_tokens" => 100,
          "output_tokens" => 50,
          "model_name" => "claude-opus-4",
          "cost_millicents" => 1000,
          "skill_version_id" => ctx.v1.id
        })

      body = json_response(conn, 201)
      assert body["token_usage_report"]["skill_version_id"] == ctx.v1.id
    end

    test "rejects skill_version_id from a different tenant", %{conn: conn} do
      ctx_a = setup_context()
      ctx_b = setup_context()

      conn =
        conn
        |> auth_conn(ctx_a.agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => ctx_a.story.id,
          "input_tokens" => 100,
          "output_tokens" => 50,
          "model_name" => "claude-opus-4",
          "cost_millicents" => 1000,
          "skill_version_id" => ctx_b.v1.id
        })

      assert json_response(conn, 422)
    end

    test "rejects nonexistent skill_version_id", %{conn: conn} do
      ctx = setup_context()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => ctx.story.id,
          "input_tokens" => 100,
          "output_tokens" => 50,
          "model_name" => "claude-opus-4",
          "cost_millicents" => 1000,
          "skill_version_id" => Ecto.UUID.generate()
        })

      assert json_response(conn, 422)
    end

    test "accepts report with nil skill_version_id (field is optional)", %{conn: conn} do
      ctx = setup_context()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> post(~p"/api/v1/token-usage", %{
          "story_id" => ctx.story.id,
          "input_tokens" => 100,
          "output_tokens" => 50,
          "model_name" => "claude-opus-4",
          "cost_millicents" => 1000
        })

      body = json_response(conn, 201)
      assert is_nil(body["token_usage_report"]["skill_version_id"])
    end
  end
end
