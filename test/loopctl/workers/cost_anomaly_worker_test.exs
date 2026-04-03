defmodule Loopctl.Workers.CostAnomalyWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.TokenUsage.CostAnomaly
  alias Loopctl.TokenUsage.CostSummary
  alias Loopctl.Workers.CostAnomalyWorker

  defp setup_tenant_with_epic do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    %{tenant: tenant, project: project, epic: epic, agent: agent}
  end

  defp create_story_with_reports(tenant, epic, agent, cost_millicents) do
    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: epic.project_id
      })

    # Insert a token usage report directly for this story
    fixture(:token_usage_report, %{
      tenant_id: tenant.id,
      story_id: story.id,
      agent_id: agent.id,
      project_id: epic.project_id,
      cost_millicents: cost_millicents
    })

    story
  end

  describe "perform/1" do
    test "flags high_cost stories (>3x epic average)" do
      ctx = setup_tenant_with_epic()
      period_start = Date.utc_today()
      period_end = Date.utc_today()

      # Create stories: 3 normal cost, 1 very expensive
      _normal1 = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 10_000)
      _normal2 = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 10_000)
      _normal3 = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 10_000)
      expensive = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 100_000)

      # Epic average = (10k + 10k + 10k + 100k) / 4 = 32_500
      # The expensive story = 100_000 / 32_500 = 3.07x -> flagged

      # Create the epic cost summary (as if rollup ran)
      %CostSummary{tenant_id: ctx.tenant.id}
      |> CostSummary.changeset(%{
        scope_type: :epic,
        scope_id: ctx.epic.id,
        period_start: period_start,
        period_end: period_end,
        total_cost_millicents: 130_000,
        report_count: 4,
        avg_cost_per_story_millicents: 32_500
      })
      |> AdminRepo.insert!()

      assert :ok =
               CostAnomalyWorker.perform(%Oban.Job{
                 args: %{
                   "period_start" => Date.to_iso8601(period_start),
                   "period_end" => Date.to_iso8601(period_end)
                 }
               })

      anomalies = AdminRepo.all(CostAnomaly)
      high_cost = Enum.filter(anomalies, &(&1.anomaly_type == :high_cost))

      assert length(high_cost) == 1
      anomaly = hd(high_cost)
      assert anomaly.story_id == expensive.id
      assert anomaly.story_cost_millicents == 100_000
      assert anomaly.reference_avg_millicents == 32_500
      assert anomaly.resolved == false
    end

    test "flags suspiciously_low stories (<0.1x epic average)" do
      ctx = setup_tenant_with_epic()
      period_start = Date.utc_today()
      period_end = Date.utc_today()

      # Create stories: 3 normal cost, 1 very cheap
      _normal1 = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 50_000)
      _normal2 = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 50_000)
      _normal3 = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 50_000)
      cheap = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 100)

      # Epic average = (50k + 50k + 50k + 100) / 4 = 37_525
      # The cheap story = 100 / 37_525 = 0.0026x -> flagged

      %CostSummary{tenant_id: ctx.tenant.id}
      |> CostSummary.changeset(%{
        scope_type: :epic,
        scope_id: ctx.epic.id,
        period_start: period_start,
        period_end: period_end,
        total_cost_millicents: 150_100,
        report_count: 4,
        avg_cost_per_story_millicents: 37_525
      })
      |> AdminRepo.insert!()

      assert :ok =
               CostAnomalyWorker.perform(%Oban.Job{
                 args: %{
                   "period_start" => Date.to_iso8601(period_start),
                   "period_end" => Date.to_iso8601(period_end)
                 }
               })

      anomalies = AdminRepo.all(CostAnomaly)
      low_cost = Enum.filter(anomalies, &(&1.anomaly_type == :suspiciously_low))

      assert length(low_cost) == 1
      assert hd(low_cost).story_id == cheap.id
    end

    test "does not flag stories within normal range" do
      ctx = setup_tenant_with_epic()
      period_start = Date.utc_today()
      period_end = Date.utc_today()

      # All stories have similar cost
      _s1 = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 10_000)
      _s2 = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 12_000)
      _s3 = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 8_000)

      # Average = 10_000
      %CostSummary{tenant_id: ctx.tenant.id}
      |> CostSummary.changeset(%{
        scope_type: :epic,
        scope_id: ctx.epic.id,
        period_start: period_start,
        period_end: period_end,
        total_cost_millicents: 30_000,
        report_count: 3,
        avg_cost_per_story_millicents: 10_000
      })
      |> AdminRepo.insert!()

      assert :ok =
               CostAnomalyWorker.perform(%Oban.Job{
                 args: %{
                   "period_start" => Date.to_iso8601(period_start),
                   "period_end" => Date.to_iso8601(period_end)
                 }
               })

      assert AdminRepo.all(CostAnomaly) == []
    end

    test "updates existing unresolved anomaly instead of duplicating" do
      ctx = setup_tenant_with_epic()
      period_start = Date.utc_today()
      period_end = Date.utc_today()

      expensive = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 100_000)

      # Pre-existing anomaly for this story
      existing =
        fixture(:cost_anomaly, %{
          tenant_id: ctx.tenant.id,
          story_id: expensive.id,
          anomaly_type: :high_cost,
          story_cost_millicents: 80_000,
          reference_avg_millicents: 20_000,
          deviation_factor: Decimal.new("4.0")
        })

      %CostSummary{tenant_id: ctx.tenant.id}
      |> CostSummary.changeset(%{
        scope_type: :epic,
        scope_id: ctx.epic.id,
        period_start: period_start,
        period_end: period_end,
        total_cost_millicents: 100_000,
        report_count: 1,
        avg_cost_per_story_millicents: 25_000
      })
      |> AdminRepo.insert!()

      assert :ok =
               CostAnomalyWorker.perform(%Oban.Job{
                 args: %{
                   "period_start" => Date.to_iso8601(period_start),
                   "period_end" => Date.to_iso8601(period_end)
                 }
               })

      anomalies = AdminRepo.all(CostAnomaly)
      # Should still be only 1 anomaly (updated, not duplicated)
      assert length(anomalies) == 1
      anomaly = hd(anomalies)
      assert anomaly.id == existing.id
      # Updated with new figures
      assert anomaly.story_cost_millicents == 100_000
      assert anomaly.reference_avg_millicents == 25_000
    end

    test "succeeds when no tenants exist" do
      # Delete all tenants (clean state)
      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: %{}})
    end
  end
end
