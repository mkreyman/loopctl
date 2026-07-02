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
                   "period_end" => "2026-04-02",
                   "tenant_ids" => [tenant.id]
                 }
               })

      # Verify summaries were created
      import Ecto.Query
      summaries = from(c in CostSummary, where: c.tenant_id == ^tenant.id) |> AdminRepo.all()
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

      job_args = %{
        "period_start" => "2026-04-02",
        "period_end" => "2026-04-02",
        "tenant_ids" => [tenant.id]
      }

      assert :ok = CostRollupWorker.perform(%Oban.Job{args: job_args})
      assert :ok = CostRollupWorker.perform(%Oban.Job{args: job_args})

      # Should still have only 1 record (upserted, not duplicated)
      import Ecto.Query
      summaries = from(c in CostSummary, where: c.tenant_id == ^tenant.id) |> AdminRepo.all()
      assert length(summaries) == 1
      assert hd(summaries).total_cost_millicents == 15_000
    end

    # tokens-08: a transient per-tenant failure must NOT be swallowed into :ok
    # (Oban would never retry, permanently losing that day's summaries). The job
    # must return an error so Oban retries, while succeeded tenants stay persisted.
    test "returns an error (so Oban retries) when a tenant rollup fails, still persisting succeeded tenants" do
      good_tenant = fixture(:tenant)
      bad_tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: good_tenant.id})

      good_tenant_id = good_tenant.id
      bad_tenant_id = bad_tenant.id

      expect(Loopctl.MockCostRollup, :aggregate, 2, fn tenant_id, _start, _end ->
        cond do
          tenant_id == good_tenant_id ->
            {:ok,
             [
               %{
                 scope_type: :project,
                 scope_id: project.id,
                 total_input_tokens: 1_000,
                 total_output_tokens: 500,
                 total_cost_millicents: 2_000,
                 report_count: 2,
                 model_breakdown: %{},
                 avg_cost_per_story_millicents: 1_000
               }
             ]}

          tenant_id == bad_tenant_id ->
            {:error, "database timeout"}
        end
      end)

      result =
        CostRollupWorker.perform(%Oban.Job{
          args: %{
            "period_start" => "2026-04-02",
            "period_end" => "2026-04-02",
            "tenant_ids" => [good_tenant.id, bad_tenant.id]
          }
        })

      # Not :ok -> Oban will retry the job
      assert {:error, {:rollup_failed, failed_ids}} = result
      assert bad_tenant.id in failed_ids
      refute good_tenant.id in failed_ids

      import Ecto.Query

      # The good tenant's summary was still written despite the other's failure.
      good_summaries =
        from(c in CostSummary, where: c.tenant_id == ^good_tenant.id) |> AdminRepo.all()

      assert length(good_summaries) == 1
      assert hd(good_summaries).total_cost_millicents == 2_000

      # The failed tenant wrote nothing.
      bad_summaries =
        from(c in CostSummary, where: c.tenant_id == ^bad_tenant.id) |> AdminRepo.all()

      assert bad_summaries == []
    end

    # tokens-09: a multi-day backfill (period_start..period_end) must produce ONE
    # daily summary row PER DAY, not a single collapsed row at period_start.
    test "backfill over a date range writes one daily summary row per day" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      d1 = ~D[2026-04-01]
      d2 = ~D[2026-04-02]
      d3 = ~D[2026-04-03]

      # Each day rolls up its OWN totals; the worker must call aggregate once per
      # day with a single-day window (period_start == period_end == day).
      day_cost = fn
        ^d1 -> 1_000
        ^d2 -> 2_000
        ^d3 -> 3_000
      end

      expect(Loopctl.MockCostRollup, :aggregate, 3, fn _tenant_id, start_date, end_date ->
        assert start_date == end_date

        {:ok,
         [
           %{
             scope_type: :project,
             scope_id: project.id,
             total_input_tokens: 0,
             total_output_tokens: 0,
             total_cost_millicents: day_cost.(start_date),
             report_count: 1,
             model_breakdown: %{},
             avg_cost_per_story_millicents: nil
           }
         ]}
      end)

      assert :ok =
               CostRollupWorker.perform(%Oban.Job{
                 args: %{
                   "period_start" => Date.to_iso8601(d1),
                   "period_end" => Date.to_iso8601(d3),
                   "tenant_ids" => [tenant.id]
                 }
               })

      import Ecto.Query

      summaries =
        from(c in CostSummary,
          where: c.tenant_id == ^tenant.id,
          order_by: c.period_start
        )
        |> AdminRepo.all()

      # THREE daily rows, not one collapsed row at d1.
      assert length(summaries) == 3

      assert Enum.map(summaries, & &1.period_start) == [d1, d2, d3]
      # Each row is a single-day period with its own totals.
      assert Enum.all?(summaries, fn s -> s.period_start == s.period_end end)
      assert Enum.map(summaries, & &1.total_cost_millicents) == [1_000, 2_000, 3_000]
    end

    test "defaults period to yesterday when not provided" do
      tenant = fixture(:tenant)

      yesterday = Date.add(Date.utc_today(), -1)

      expect(Loopctl.MockCostRollup, :aggregate, fn _, period_start, period_end ->
        assert period_start == yesterday
        assert period_end == yesterday
        {:ok, []}
      end)

      assert :ok =
               CostRollupWorker.perform(%Oban.Job{
                 args: %{"tenant_ids" => [tenant.id]}
               })
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
                 args: %{
                   "period_start" => "2026-04-02",
                   "period_end" => "2026-04-02",
                   "tenant_ids" => [tenant_a.id, tenant_b.id]
                 }
               })
    end

    test "skips suspended tenants" do
      active_tenant = fixture(:tenant)
      suspended_tenant = fixture(:tenant, %{status: :suspended})

      # Should only be called once (for active tenant)
      expect(Loopctl.MockCostRollup, :aggregate, fn _, _, _ ->
        {:ok, []}
      end)

      assert :ok =
               CostRollupWorker.perform(%Oban.Job{
                 args: %{
                   "period_start" => "2026-04-02",
                   "period_end" => "2026-04-02",
                   "tenant_ids" => [active_tenant.id, suspended_tenant.id]
                 }
               })
    end
  end
end
