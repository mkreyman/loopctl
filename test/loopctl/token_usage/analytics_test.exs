defmodule Loopctl.TokenUsage.AnalyticsTest do
  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.TokenUsage.Analytics

  setup :verify_on_exit!

  # Builds a shared test dataset: 2 agents, 2 models, 2 epics, multiple stories
  defp setup_analytics_data do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, title: "Epic One"})
    epic2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, title: "Epic Two"})

    agent1 = fixture(:agent, %{tenant_id: tenant.id, name: "agent-alpha"})
    agent2 = fixture(:agent, %{tenant_id: tenant.id, name: "agent-beta"})

    story1 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic1.id,
        project_id: project.id,
        verified_status: :verified,
        assigned_agent_id: agent1.id
      })

    story2 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic1.id,
        project_id: project.id,
        verified_status: :rejected,
        assigned_agent_id: agent2.id
      })

    story3 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic2.id,
        project_id: project.id,
        verified_status: :verified,
        assigned_agent_id: agent1.id
      })

    # Agent1 uses claude-opus-4, Agent2 uses claude-sonnet-4
    _r1 =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story1.id,
        agent_id: agent1.id,
        project_id: project.id,
        model_name: "claude-opus-4",
        input_tokens: 2000,
        output_tokens: 1000,
        cost_millicents: 5000,
        phase: "implementing"
      })

    _r2 =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story2.id,
        agent_id: agent2.id,
        project_id: project.id,
        model_name: "claude-sonnet-4",
        input_tokens: 1000,
        output_tokens: 500,
        cost_millicents: 1500,
        phase: "implementing"
      })

    _r3 =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story3.id,
        agent_id: agent1.id,
        project_id: project.id,
        model_name: "claude-opus-4",
        input_tokens: 3000,
        output_tokens: 1500,
        cost_millicents: 7000,
        phase: "reviewing"
      })

    # A planning report by agent2
    _r4 =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story1.id,
        agent_id: agent2.id,
        project_id: project.id,
        model_name: "claude-sonnet-4",
        input_tokens: 500,
        output_tokens: 200,
        cost_millicents: 700,
        phase: "planning"
      })

    %{
      tenant: tenant,
      project: project,
      epic1: epic1,
      epic2: epic2,
      agent1: agent1,
      agent2: agent2,
      story1: story1,
      story2: story2,
      story3: story3
    }
  end

  # ---------------------------------------------------------------------------
  # agent_metrics/2
  # ---------------------------------------------------------------------------

  describe "agent_metrics/2" do
    test "returns per-agent metrics" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.agent_metrics(ctx.tenant.id)

      assert length(result.data) == 2
      assert result.total == 2
      assert result.page == 1
    end

    test "includes expected fields per agent" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.agent_metrics(ctx.tenant.id)

      # Agent2 is cheaper, so it should rank first (rank 1)
      agent2_entry = Enum.find(result.data, &(&1.agent_id == ctx.agent2.id))
      assert agent2_entry != nil
      assert agent2_entry.agent_name == "agent-beta"
      assert agent2_entry.total_cost_millicents == 2200
      assert agent2_entry.total_input_tokens == 1500
      assert agent2_entry.total_output_tokens == 700
      assert agent2_entry.primary_model == "claude-sonnet-4"
      assert agent2_entry.efficiency_rank == 1
    end

    test "calculates efficiency_rank (1 = cheapest per story)" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.agent_metrics(ctx.tenant.id)

      ranks = Enum.map(result.data, & &1.efficiency_rank)
      assert ranks == [1, 2]

      cheapest = hd(result.data)
      # Agent2 avg 1100/story (2200 over 2 stories), Agent1 avg 6000/story (12000 over 2 stories)
      assert cheapest.agent_id == ctx.agent2.id
    end

    test "filters by project_id" do
      ctx = setup_analytics_data()

      # Create another project with no reports
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})

      {:ok, result} =
        Analytics.agent_metrics(ctx.tenant.id, project_id: other_project.id)

      assert result.data == []
      assert result.total == 0
    end

    test "filters by date range" do
      ctx = setup_analytics_data()

      # Future date range -- no results
      {:ok, result} =
        Analytics.agent_metrics(ctx.tenant.id,
          since: Date.add(Date.utc_today(), 1),
          until: Date.add(Date.utc_today(), 2)
        )

      assert result.data == []
    end

    test "returns empty for tenant with no data" do
      tenant = fixture(:tenant)

      {:ok, result} = Analytics.agent_metrics(tenant.id)

      assert result.data == []
      assert result.total == 0
    end

    test "tenant isolation" do
      ctx = setup_analytics_data()
      other_tenant = fixture(:tenant)

      {:ok, result} = Analytics.agent_metrics(other_tenant.id)

      assert result.data == []
      assert result.total == 0

      {:ok, own_result} = Analytics.agent_metrics(ctx.tenant.id)
      assert own_result.total == 2
    end
  end

  # ---------------------------------------------------------------------------
  # epic_metrics/2
  # ---------------------------------------------------------------------------

  describe "epic_metrics/2" do
    test "returns per-epic metrics" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.epic_metrics(ctx.tenant.id)

      assert length(result.data) == 2
      assert result.total == 2
    end

    test "includes expected fields per epic" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.epic_metrics(ctx.tenant.id)

      epic1_entry = Enum.find(result.data, &(&1.epic_id == ctx.epic1.id))
      assert epic1_entry != nil
      assert epic1_entry.epic_name == "Epic One"
      assert epic1_entry.story_count == 2
      # story2 is rejected, so only story1 is completed (verified)
      assert epic1_entry.completed_story_count == 1
      # r1 (5000) + r2 (1500) + r4 (700) = 7200
      assert epic1_entry.total_cost_millicents == 7200
    end

    test "includes model_breakdown" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.epic_metrics(ctx.tenant.id)

      epic1_entry = Enum.find(result.data, &(&1.epic_id == ctx.epic1.id))
      assert is_map(epic1_entry.model_breakdown)
      assert Map.has_key?(epic1_entry.model_breakdown, "claude-opus-4")
    end

    test "includes budget and utilization when budget exists" do
      ctx = setup_analytics_data()

      # Create a budget for epic1
      fixture(:token_budget, %{
        tenant_id: ctx.tenant.id,
        scope_type: :epic,
        scope_id: ctx.epic1.id,
        budget_millicents: 100_000
      })

      {:ok, result} = Analytics.epic_metrics(ctx.tenant.id)

      epic1_entry = Enum.find(result.data, &(&1.epic_id == ctx.epic1.id))
      assert epic1_entry.budget_millicents == 100_000
      assert epic1_entry.utilization_pct != nil
    end

    test "budget_millicents is nil when no budget" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.epic_metrics(ctx.tenant.id)

      epic2_entry = Enum.find(result.data, &(&1.epic_id == ctx.epic2.id))
      assert epic2_entry.budget_millicents == nil
      assert epic2_entry.utilization_pct == nil
    end

    test "filters by project_id" do
      ctx = setup_analytics_data()
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})

      {:ok, result} =
        Analytics.epic_metrics(ctx.tenant.id, project_id: other_project.id)

      assert result.data == []
    end

    test "returns empty for tenant with no epics" do
      tenant = fixture(:tenant)

      {:ok, result} = Analytics.epic_metrics(tenant.id)

      assert result.data == []
      assert result.total == 0
    end

    test "tenant isolation" do
      _ctx = setup_analytics_data()
      other_tenant = fixture(:tenant)

      {:ok, result} = Analytics.epic_metrics(other_tenant.id)

      assert result.data == []
    end
  end

  # ---------------------------------------------------------------------------
  # project_metrics/2
  # ---------------------------------------------------------------------------

  describe "project_metrics/2" do
    test "returns project cost overview" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.project_metrics(ctx.tenant.id, ctx.project.id)

      # Total: 5000 + 1500 + 7000 + 700 = 14200
      assert result.total_cost_millicents == 14_200
      assert result.total_input_tokens == 6500
      assert result.total_output_tokens == 3200
      assert result.agent_count == 2
      assert result.story_count == 3
    end

    test "includes cost_by_phase" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.project_metrics(ctx.tenant.id, ctx.project.id)

      assert is_map(result.cost_by_phase)
      assert result.cost_by_phase["implementing"] == 6500
      assert result.cost_by_phase["reviewing"] == 7000
      assert result.cost_by_phase["planning"] == 700
    end

    test "includes model_breakdown" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.project_metrics(ctx.tenant.id, ctx.project.id)

      assert is_map(result.model_breakdown)
      assert Map.has_key?(result.model_breakdown, "claude-opus-4")
      assert Map.has_key?(result.model_breakdown, "claude-sonnet-4")
    end

    test "includes budget and utilization when budget exists" do
      ctx = setup_analytics_data()

      fixture(:token_budget, %{
        tenant_id: ctx.tenant.id,
        scope_type: :project,
        scope_id: ctx.project.id,
        budget_millicents: 50_000
      })

      {:ok, result} = Analytics.project_metrics(ctx.tenant.id, ctx.project.id)

      assert result.budget_millicents == 50_000
      # 14200 / 50000 * 100 = 28
      assert result.utilization_pct == 28
    end

    test "returns not_found for nonexistent project" do
      tenant = fixture(:tenant)

      assert {:error, :not_found} =
               Analytics.project_metrics(tenant.id, Ecto.UUID.generate())
    end

    test "returns zeros when project has no token data" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      {:ok, result} = Analytics.project_metrics(tenant.id, project.id)

      assert result.total_cost_millicents == 0
      assert result.total_input_tokens == 0
      assert result.total_output_tokens == 0
      assert result.agent_count == 0
      assert result.story_count == 0
    end

    test "tenant isolation" do
      ctx = setup_analytics_data()
      other_tenant = fixture(:tenant)

      assert {:error, :not_found} =
               Analytics.project_metrics(other_tenant.id, ctx.project.id)
    end
  end

  # ---------------------------------------------------------------------------
  # model_metrics/2
  # ---------------------------------------------------------------------------

  describe "model_metrics/2" do
    test "returns per-model metrics" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.model_metrics(ctx.tenant.id)

      assert length(result.data) == 2
      assert result.total == 2
    end

    test "includes expected fields per model" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.model_metrics(ctx.tenant.id)

      opus = Enum.find(result.data, &(&1.model_name == "claude-opus-4"))
      assert opus != nil
      # r1 (5000) + r3 (7000) = 12000
      assert opus.total_cost_millicents == 12_000
      assert opus.total_input_tokens == 5000
      assert opus.total_output_tokens == 2500
      assert opus.report_count == 2
      assert opus.avg_cost_per_report_millicents == 6000
    end

    test "includes verification correlation" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.model_metrics(ctx.tenant.id)

      opus = Enum.find(result.data, &(&1.model_name == "claude-opus-4"))
      # story1 (verified) + story3 (verified) -- both had opus reports
      assert opus.stories_verified_count == 2
      assert opus.stories_rejected_count == 0
      assert opus.verification_rate_pct == 100

      sonnet = Enum.find(result.data, &(&1.model_name == "claude-sonnet-4"))
      # story2 (rejected) + story1 (verified) -- both had sonnet reports
      assert sonnet.stories_verified_count == 1
      assert sonnet.stories_rejected_count == 1
      assert sonnet.verification_rate_pct == 50
    end

    test "filters by project_id" do
      ctx = setup_analytics_data()
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})

      {:ok, result} =
        Analytics.model_metrics(ctx.tenant.id, project_id: other_project.id)

      assert result.data == []
    end

    test "returns empty for tenant with no data" do
      tenant = fixture(:tenant)

      {:ok, result} = Analytics.model_metrics(tenant.id)

      assert result.data == []
      assert result.total == 0
    end

    test "tenant isolation" do
      _ctx = setup_analytics_data()
      other_tenant = fixture(:tenant)

      {:ok, result} = Analytics.model_metrics(other_tenant.id)

      assert result.data == []
    end
  end

  # ---------------------------------------------------------------------------
  # trend_metrics/2
  # ---------------------------------------------------------------------------

  describe "trend_metrics/2" do
    test "returns daily trend" do
      ctx = setup_analytics_data()

      {:ok, result} = Analytics.trend_metrics(ctx.tenant.id)

      # All reports were inserted today, so expect 1 period
      assert length(result.data) == 1

      entry = hd(result.data)
      assert entry.period == Date.utc_today()
      assert entry.total_cost_millicents == 14_200
      assert entry.total_tokens == 9700
      assert entry.report_count == 4
      assert entry.unique_agents == 2
    end

    test "returns weekly trend" do
      ctx = setup_analytics_data()

      {:ok, result} =
        Analytics.trend_metrics(ctx.tenant.id, granularity: "weekly")

      assert length(result.data) == 1

      entry = hd(result.data)
      # Weekly period start is the Monday of the current week
      assert entry.total_cost_millicents == 14_200
    end

    test "filters by project_id" do
      ctx = setup_analytics_data()
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})

      {:ok, result} =
        Analytics.trend_metrics(ctx.tenant.id, project_id: other_project.id)

      assert result.data == []
    end

    test "filters by date range" do
      ctx = setup_analytics_data()

      {:ok, result} =
        Analytics.trend_metrics(ctx.tenant.id,
          since: Date.add(Date.utc_today(), 1)
        )

      assert result.data == []
    end

    test "returns empty for tenant with no data" do
      tenant = fixture(:tenant)

      {:ok, result} = Analytics.trend_metrics(tenant.id)

      assert result.data == []
      assert result.total == 0
    end

    test "tenant isolation" do
      _ctx = setup_analytics_data()
      other_tenant = fixture(:tenant)

      {:ok, result} = Analytics.trend_metrics(other_tenant.id)

      assert result.data == []
    end
  end
end
