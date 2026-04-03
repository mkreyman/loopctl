defmodule Loopctl.TokenUsage.DefaultRollupTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.TokenUsage.DefaultRollup

  defp setup_tenant_with_reports do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    story1 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id
      })

    story2 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id
      })

    # Create reports for story1
    fixture(:token_usage_report, %{
      tenant_id: tenant.id,
      story_id: story1.id,
      agent_id: agent.id,
      project_id: project.id,
      input_tokens: 1000,
      output_tokens: 500,
      cost_millicents: 2500,
      model_name: "claude-opus-4",
      phase: "implementing"
    })

    # Create reports for story2
    fixture(:token_usage_report, %{
      tenant_id: tenant.id,
      story_id: story2.id,
      agent_id: agent.id,
      project_id: project.id,
      input_tokens: 2000,
      output_tokens: 1000,
      cost_millicents: 5000,
      model_name: "claude-opus-4",
      phase: "reviewing"
    })

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      agent: agent,
      story1: story1,
      story2: story2
    }
  end

  describe "aggregate/3" do
    test "aggregates reports by agent, epic, and project" do
      ctx = setup_tenant_with_reports()

      # Use a wide date range to capture all reports
      period_start = Date.add(Date.utc_today(), -1)
      period_end = Date.add(Date.utc_today(), 1)

      {:ok, rows} = DefaultRollup.aggregate(ctx.tenant.id, period_start, period_end)

      # Should have agent, epic, and project summaries
      agent_rows = Enum.filter(rows, &(&1.scope_type == :agent))
      epic_rows = Enum.filter(rows, &(&1.scope_type == :epic))
      project_rows = Enum.filter(rows, &(&1.scope_type == :project))

      assert agent_rows != []
      assert epic_rows != []
      assert project_rows != []

      # Check project aggregate
      project_row = Enum.find(project_rows, &(&1.scope_id == ctx.project.id))
      assert project_row.total_input_tokens == 3000
      assert project_row.total_output_tokens == 1500
      assert project_row.total_cost_millicents == 7500
      assert project_row.report_count == 2

      # Check epic aggregate
      epic_row = Enum.find(epic_rows, &(&1.scope_id == ctx.epic.id))
      assert epic_row.total_cost_millicents == 7500
      # avg_cost_per_story = 7500 / 2 stories = 3750
      assert epic_row.avg_cost_per_story_millicents == 3750

      # Check model breakdown contains data
      assert map_size(project_row.model_breakdown) > 0
    end

    test "returns empty list when no reports exist for period" do
      tenant = fixture(:tenant)

      {:ok, rows} = DefaultRollup.aggregate(tenant.id, ~D[2025-01-01], ~D[2025-01-01])
      assert rows == []
    end

    test "tenant isolation - only aggregates reports for the given tenant" do
      ctx = setup_tenant_with_reports()
      tenant_b = fixture(:tenant)

      period_start = Date.add(Date.utc_today(), -1)
      period_end = Date.add(Date.utc_today(), 1)

      {:ok, rows_a} = DefaultRollup.aggregate(ctx.tenant.id, period_start, period_end)
      {:ok, rows_b} = DefaultRollup.aggregate(tenant_b.id, period_start, period_end)

      assert rows_a != []
      assert rows_b == []
    end

    test "includes model breakdown with per-phase data" do
      ctx = setup_tenant_with_reports()

      period_start = Date.add(Date.utc_today(), -1)
      period_end = Date.add(Date.utc_today(), 1)

      {:ok, rows} = DefaultRollup.aggregate(ctx.tenant.id, period_start, period_end)

      project_row =
        Enum.find(rows, &(&1.scope_type == :project and &1.scope_id == ctx.project.id))

      assert is_map(project_row.model_breakdown)

      # Should have claude-opus-4 with implementing and reviewing phases
      assert Map.has_key?(project_row.model_breakdown, "claude-opus-4")
      model_data = project_row.model_breakdown["claude-opus-4"]
      assert Map.has_key?(model_data, "implementing")
      assert Map.has_key?(model_data, "reviewing")
    end
  end
end
