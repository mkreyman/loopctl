defmodule Loopctl.Skills.SkillCostPerformanceTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Skills
  alias Loopctl.TokenUsage

  # Helper to create a full setup with tenant, project, epic, story, skill
  defp setup_context do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

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

    # Get the v1 skill_version
    {:ok, v1} = Skills.get_version(tenant.id, skill.id, 1)

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      agent: agent,
      skill: skill,
      story: story,
      v1: v1
    }
  end

  # Creates a token usage report linked to a skill version
  defp create_report(ctx, skill_version, cost_millicents) do
    {:ok, report} =
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

    report
  end

  # -------------------------------------------------------------------
  # cost_performance/2
  # -------------------------------------------------------------------

  describe "cost_performance/2" do
    test "returns empty list when no token usage reports are linked" do
      ctx = setup_context()

      assert {:ok, []} = Skills.cost_performance(ctx.tenant.id, ctx.skill.id)
    end

    test "returns cost metrics for a single version" do
      ctx = setup_context()

      create_report(ctx, ctx.v1, 1000)
      create_report(ctx, ctx.v1, 3000)

      assert {:ok, [row]} = Skills.cost_performance(ctx.tenant.id, ctx.skill.id)

      assert row.version_number == 1
      assert row.total_invocations == 2
      assert row.total_cost_millicents == 4000
      assert row.avg_cost_per_invocation_millicents == 2000
      assert is_nil(row.cost_change_pct)
      assert row.cost_regression == false
    end

    test "returns metrics for multiple versions with cost_change_pct" do
      ctx = setup_context()

      # Create v2
      {:ok, %{version: v2}} =
        Skills.create_version(ctx.tenant.id, ctx.skill.id, %{
          "prompt_text" => "v2 prompt"
        })

      # v1: avg 1000, 3 invocations
      create_report(ctx, ctx.v1, 1000)
      create_report(ctx, ctx.v1, 1000)
      create_report(ctx, ctx.v1, 1000)

      # v2: avg 1500 (50% more expensive than v1)
      create_report(ctx, v2, 1500)
      create_report(ctx, v2, 1500)
      create_report(ctx, v2, 1500)

      assert {:ok, [row_v1, row_v2]} = Skills.cost_performance(ctx.tenant.id, ctx.skill.id)

      assert row_v1.version_number == 1
      assert row_v1.cost_change_pct == nil

      assert row_v2.version_number == 2
      assert row_v2.cost_change_pct == 50
      assert row_v2.cost_regression == false
    end

    test "flags cost_regression when avg_cost > 2x previous AND >= 3 invocations" do
      ctx = setup_context()

      {:ok, %{version: v2}} =
        Skills.create_version(ctx.tenant.id, ctx.skill.id, %{
          "prompt_text" => "v2 prompt"
        })

      # v1: avg 1000
      create_report(ctx, ctx.v1, 1000)
      create_report(ctx, ctx.v1, 1000)
      create_report(ctx, ctx.v1, 1000)

      # v2: avg 3000 (3x v1) with 3 invocations — should flag regression
      create_report(ctx, v2, 3000)
      create_report(ctx, v2, 3000)
      create_report(ctx, v2, 3000)

      assert {:ok, [_row_v1, row_v2]} = Skills.cost_performance(ctx.tenant.id, ctx.skill.id)

      assert row_v2.cost_regression == true
      assert row_v2.cost_change_pct == 200
    end

    test "does not flag cost_regression with fewer than 3 invocations" do
      ctx = setup_context()

      {:ok, %{version: v2}} =
        Skills.create_version(ctx.tenant.id, ctx.skill.id, %{
          "prompt_text" => "v2 prompt"
        })

      # v1: avg 1000
      create_report(ctx, ctx.v1, 1000)
      create_report(ctx, ctx.v1, 1000)
      create_report(ctx, ctx.v1, 1000)

      # v2: avg 5000 (5x v1) but only 2 invocations — not enough sample
      create_report(ctx, v2, 5000)
      create_report(ctx, v2, 5000)

      assert {:ok, [_row_v1, row_v2]} = Skills.cost_performance(ctx.tenant.id, ctx.skill.id)

      assert row_v2.cost_regression == false
    end

    test "returns :not_found for nonexistent skill" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Skills.cost_performance(tenant.id, Ecto.UUID.generate())
    end

    test "tenant isolation: cannot see another tenant's skill data" do
      ctx_a = setup_context()
      ctx_b = setup_context()

      # Create data for tenant_a's skill
      create_report(ctx_a, ctx_a.v1, 1000)

      # Tenant B cannot see tenant A's skill
      assert {:error, :not_found} =
               Skills.cost_performance(ctx_b.tenant.id, ctx_a.skill.id)
    end
  end

  # -------------------------------------------------------------------
  # version_cost_summary/3
  # -------------------------------------------------------------------

  describe "version_cost_summary/3" do
    test "returns nil when no reports are linked" do
      ctx = setup_context()
      assert {:ok, nil} = Skills.version_cost_summary(ctx.tenant.id, ctx.skill.id, 1)
    end

    test "returns cost summary when reports exist" do
      ctx = setup_context()

      create_report(ctx, ctx.v1, 2000)
      create_report(ctx, ctx.v1, 4000)

      assert {:ok, summary} = Skills.version_cost_summary(ctx.tenant.id, ctx.skill.id, 1)

      assert summary.version_number == 1
      assert summary.total_invocations == 2
      assert summary.total_cost_millicents == 6000
      assert summary.avg_cost_per_invocation_millicents == 3000
    end

    test "returns :not_found for nonexistent skill" do
      tenant = fixture(:tenant)

      assert {:error, :not_found} =
               Skills.version_cost_summary(tenant.id, Ecto.UUID.generate(), 1)
    end

    test "returns :not_found for nonexistent version" do
      ctx = setup_context()

      assert {:error, :not_found} =
               Skills.version_cost_summary(ctx.tenant.id, ctx.skill.id, 99)
    end
  end

  # -------------------------------------------------------------------
  # validate_skill_version_ownership in TokenUsage.create_report/3
  # -------------------------------------------------------------------

  describe "TokenUsage.create_report/3 with skill_version_id" do
    test "creates report with valid skill_version_id from same tenant" do
      ctx = setup_context()

      assert {:ok, report} =
               TokenUsage.create_report(ctx.tenant.id, %{
                 story_id: ctx.story.id,
                 agent_id: ctx.agent.id,
                 project_id: ctx.project.id,
                 input_tokens: 100,
                 output_tokens: 50,
                 model_name: "claude-opus-4",
                 cost_millicents: 500,
                 skill_version_id: ctx.v1.id
               })

      assert report.skill_version_id == ctx.v1.id
    end

    test "creates report when skill_version_id is nil" do
      ctx = setup_context()

      assert {:ok, report} =
               TokenUsage.create_report(ctx.tenant.id, %{
                 story_id: ctx.story.id,
                 agent_id: ctx.agent.id,
                 project_id: ctx.project.id,
                 input_tokens: 100,
                 output_tokens: 50,
                 model_name: "claude-opus-4",
                 cost_millicents: 500
               })

      assert is_nil(report.skill_version_id)
    end

    test "rejects skill_version_id from different tenant" do
      ctx_a = setup_context()
      ctx_b = setup_context()

      # Try to use tenant_b's skill_version in a tenant_a report
      assert {:error, :unprocessable_entity, msg} =
               TokenUsage.create_report(ctx_a.tenant.id, %{
                 story_id: ctx_a.story.id,
                 agent_id: ctx_a.agent.id,
                 project_id: ctx_a.project.id,
                 input_tokens: 100,
                 output_tokens: 50,
                 model_name: "claude-opus-4",
                 cost_millicents: 500,
                 skill_version_id: ctx_b.v1.id
               })

      assert msg =~ "skill_version_id"
    end

    test "rejects nonexistent skill_version_id" do
      ctx = setup_context()

      assert {:error, :unprocessable_entity, _msg} =
               TokenUsage.create_report(ctx.tenant.id, %{
                 story_id: ctx.story.id,
                 agent_id: ctx.agent.id,
                 project_id: ctx.project.id,
                 input_tokens: 100,
                 output_tokens: 50,
                 model_name: "claude-opus-4",
                 cost_millicents: 500,
                 skill_version_id: Ecto.UUID.generate()
               })
    end
  end
end
