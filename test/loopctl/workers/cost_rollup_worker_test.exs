defmodule Loopctl.Workers.CostRollupWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.TokenUsage.CostSummary
  alias Loopctl.Workers.CostRollupWorker

  describe "perform/1" do
    test "calls rollup service and upserts cost summaries" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id})

      period_start = ~D[2026-04-02]
      period_end = ~D[2026-04-02]

      expected_tenant_id = tenant.id

      # Mock the rollup service to return aggregated data
      expect(Loopctl.MockCostRollup, :aggregate, fn tenant_id, start_date, end_date ->
        assert tenant_id == expected_tenant_id
        assert start_date == period_start
        assert end_date == period_end

        {:ok,
         [
           %{
             scope_type: :project,
             scope_id: project.id,
             total_input_tokens: 50_000,
             total_output_tokens: 25_000,
             total_cost_millicents: 75_000,
             report_count: 10,
             model_breakdown: %{
               "claude-opus-4" => %{"implementing" => %{"input_tokens" => 50_000}}
             },
             avg_cost_per_story_millicents: 7_500
           },
           %{
             scope_type: :agent,
             scope_id: agent.id,
             total_input_tokens: 30_000,
             total_output_tokens: 15_000,
             total_cost_millicents: 45_000,
             report_count: 5,
             model_breakdown: %{},
             avg_cost_per_story_millicents: nil
           }
         ]}
      end)

      assert :ok =
               CostRollupWorker.perform(%Oban.Job{
                 args: %{
                   "period_start" => "2026-04-02",
                   "period_end" => "2026-04-02"
                 }
               })

      # Verify summaries were created
      summaries = AdminRepo.all(CostSummary)
      assert length(summaries) == 2

      project_summary = Enum.find(summaries, &(&1.scope_type == :project))
      assert project_summary.tenant_id == tenant.id
      assert project_summary.scope_id == project.id
      assert project_summary.total_input_tokens == 50_000
      assert project_summary.total_output_tokens == 25_000
      assert project_summary.total_cost_millicents == 75_000
      assert project_summary.report_count == 10
      assert project_summary.avg_cost_per_story_millicents == 7_500
      assert project_summary.period_start == ~D[2026-04-02]
      assert project_summary.period_end == ~D[2026-04-02]

      agent_summary = Enum.find(summaries, &(&1.scope_type == :agent))
      assert agent_summary.scope_id == agent.id
      assert agent_summary.total_cost_millicents == 45_000
      assert agent_summary.avg_cost_per_story_millicents == nil
    end

    test "rollup is idempotent - running twice produces same result" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      rollup_data = [
        %{
          scope_type: :project,
          scope_id: project.id,
          total_input_tokens: 10_000,
          total_output_tokens: 5_000,
          total_cost_millicents: 15_000,
          report_count: 3,
          model_breakdown: %{},
          avg_cost_per_story_millicents: 5_000
        }
      ]

      # Run rollup twice with same data
      expect(Loopctl.MockCostRollup, :aggregate, 2, fn _, _, _ ->
        {:ok, rollup_data}
      end)

      assert :ok =
               CostRollupWorker.perform(%Oban.Job{
                 args: %{"period_start" => "2026-04-02", "period_end" => "2026-04-02"}
               })

      assert :ok =
               CostRollupWorker.perform(%Oban.Job{
                 args: %{"period_start" => "2026-04-02", "period_end" => "2026-04-02"}
               })

      # Should still have only 1 record (upserted, not duplicated)
      summaries = AdminRepo.all(CostSummary)
      assert length(summaries) == 1
      assert hd(summaries).total_cost_millicents == 15_000
    end

    test "handles rollup service errors gracefully" do
      _tenant = fixture(:tenant)

      expect(Loopctl.MockCostRollup, :aggregate, fn _, _, _ ->
        {:error, "database timeout"}
      end)

      # Should still return :ok (logs errors but doesn't fail job)
      assert :ok =
               CostRollupWorker.perform(%Oban.Job{
                 args: %{"period_start" => "2026-04-02", "period_end" => "2026-04-02"}
               })
    end

    test "defaults period to yesterday when not provided" do
      _tenant = fixture(:tenant)

      yesterday = Date.add(Date.utc_today(), -1)

      expect(Loopctl.MockCostRollup, :aggregate, fn _, period_start, period_end ->
        assert period_start == yesterday
        assert period_end == yesterday
        {:ok, []}
      end)

      assert :ok = CostRollupWorker.perform(%Oban.Job{args: %{}})
    end

    test "processes multiple tenants" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      expect(Loopctl.MockCostRollup, :aggregate, 2, fn tenant_id, _, _ ->
        assert tenant_id in [tenant_a.id, tenant_b.id]
        {:ok, []}
      end)

      assert :ok =
               CostRollupWorker.perform(%Oban.Job{
                 args: %{"period_start" => "2026-04-02", "period_end" => "2026-04-02"}
               })
    end

    test "skips suspended tenants" do
      _active_tenant = fixture(:tenant)
      _suspended_tenant = fixture(:tenant, %{status: :suspended})

      # Should only be called once (for active tenant)
      expect(Loopctl.MockCostRollup, :aggregate, fn _, _, _ ->
        {:ok, []}
      end)

      assert :ok =
               CostRollupWorker.perform(%Oban.Job{
                 args: %{"period_start" => "2026-04-02", "period_end" => "2026-04-02"}
               })
    end
  end
end
