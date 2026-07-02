defmodule Loopctl.Workers.CostRollupWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

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

    # tokens-08 + FIX4: a transient per-tenant failure must NOT be swallowed into
    # a plain success with no follow-up (Oban would never retry, permanently
    # losing that day's summaries). The batch re-enqueues a NARROW follow-up
    # scoped to only the failed tenant/day, so healthy tenants are not
    # re-computed, and succeeded tenants stay persisted.
    test "re-enqueues a scoped retry for the failed tenant only, persisting succeeded tenants" do
      good_tenant = fixture(:tenant)
      bad_tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: good_tenant.id})

      good_tenant_id = good_tenant.id
      bad_tenant_id = bad_tenant.id

      # Exactly TWO aggregate calls (good + bad) during the batch. The scoped
      # retry is only ENQUEUED (manual mode), so it does not re-invoke aggregate.
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
        Oban.Testing.with_testing_mode(:manual, fn ->
          CostRollupWorker.perform(%Oban.Job{
            args: %{
              "period_start" => "2026-04-02",
              "period_end" => "2026-04-02",
              "tenant_ids" => [good_tenant.id, bad_tenant.id]
            }
          })
        end)

      # Batch reports success but the failure is NOT lost -- it is re-enqueued.
      assert result == :ok

      # A scoped follow-up job is enqueued for ONLY the failed tenant/day, so
      # healthy tenants are not re-computed on the retry.
      scoped_jobs =
        all_enqueued(worker: CostRollupWorker)
        |> Enum.filter(&(&1.args["scoped_retry"] == true))

      assert length(scoped_jobs) == 1
      scoped = hd(scoped_jobs)
      assert scoped.args["tenant_ids"] == [bad_tenant.id]
      assert scoped.args["period_start"] == "2026-04-02"
      assert scoped.args["period_end"] == "2026-04-02"

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

    # FIX4: a scoped retry job that fails again does NOT re-enqueue (which would
    # loop) -- it returns an error so Oban's bounded retry takes over.
    test "a scoped retry that fails again returns an error instead of re-enqueueing" do
      bad_tenant = fixture(:tenant)

      expect(Loopctl.MockCostRollup, :aggregate, fn _tenant_id, _start, _end ->
        {:error, "still timing out"}
      end)

      result =
        Oban.Testing.with_testing_mode(:manual, fn ->
          CostRollupWorker.perform(%Oban.Job{
            args: %{
              "period_start" => "2026-04-02",
              "period_end" => "2026-04-02",
              "tenant_ids" => [bad_tenant.id],
              "scoped_retry" => true
            }
          })
        end)

      assert {:error, {:rollup_failed, failed_ids}} = result
      assert bad_tenant.id in failed_ids

      # It must NOT have re-enqueued another scoped retry (no unbounded loop).
      assert all_enqueued(worker: CostRollupWorker) == []
    end

    # FIX2: a reversed period range is normalized (swapped), not silently skipped.
    # Strengthened so it FAILS without the swap: the chained CostAnomalyWorker
    # must receive the EARLIER date as period_start (without the swap it would
    # carry the later date and the anomaly candidate query would match nothing).
    test "normalizes a reversed period range and chains anomaly detection with the earlier date first" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      d1 = ~D[2026-04-01]
      d2 = ~D[2026-04-02]

      # period_start AFTER period_end -> must be swapped to [d1, d2] and roll up
      # BOTH days (2 aggregate calls), not zero.
      expect(Loopctl.MockCostRollup, :aggregate, 2, fn _tenant_id, start_date, end_date ->
        assert start_date == end_date
        assert start_date in [d1, d2]

        {:ok,
         [
           %{
             scope_type: :project,
             scope_id: project.id,
             total_input_tokens: 0,
             total_output_tokens: 0,
             total_cost_millicents: 100,
             report_count: 1,
             model_breakdown: %{},
             avg_cost_per_story_millicents: nil
           }
         ]}
      end)

      {result, anomaly_jobs} =
        Oban.Testing.with_testing_mode(:manual, fn ->
          r =
            CostRollupWorker.perform(%Oban.Job{
              args: %{
                # reversed on purpose
                "period_start" => Date.to_iso8601(d2),
                "period_end" => Date.to_iso8601(d1),
                "tenant_ids" => [tenant.id]
              }
            })

          {r, all_enqueued(worker: Loopctl.Workers.CostAnomalyWorker)}
        end)

      assert result == :ok

      import Ecto.Query

      summaries =
        from(c in CostSummary, where: c.tenant_id == ^tenant.id, order_by: c.period_start)
        |> AdminRepo.all()

      assert Enum.map(summaries, & &1.period_start) == [d1, d2]

      # The chained anomaly worker gets the normalized (earlier-first) range.
      assert [anomaly_job] = anomaly_jobs
      assert anomaly_job.args["period_start"] == Date.to_iso8601(d1)
      assert anomaly_job.args["period_end"] == Date.to_iso8601(d2)
    end

    # FIX3: an over-cap backfill range is clamped (not run unbounded).
    test "clamps a backfill range wider than the max to the cap" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      start_date = ~D[2026-01-01]
      # ~1 year -> must be clamped to 90 days (91 daily rows: day 0..90 inclusive).
      end_date = ~D[2026-12-31]
      expected_last = Date.add(start_date, 90)

      expect(Loopctl.MockCostRollup, :aggregate, 91, fn _tenant_id, day, day2 ->
        assert day == day2
        assert Date.compare(day, start_date) != :lt
        assert Date.compare(day, expected_last) != :gt

        {:ok,
         [
           %{
             scope_type: :project,
             scope_id: project.id,
             total_input_tokens: 0,
             total_output_tokens: 0,
             total_cost_millicents: 1,
             report_count: 1,
             model_breakdown: %{},
             avg_cost_per_story_millicents: nil
           }
         ]}
      end)

      assert :ok =
               CostRollupWorker.perform(%Oban.Job{
                 args: %{
                   "period_start" => Date.to_iso8601(start_date),
                   "period_end" => Date.to_iso8601(end_date),
                   "tenant_ids" => [tenant.id]
                 }
               })

      import Ecto.Query

      count =
        from(c in CostSummary, where: c.tenant_id == ^tenant.id) |> AdminRepo.aggregate(:count)

      # 91 daily rows (start .. start+90 inclusive), NOT 365.
      assert count == 91

      last_day =
        from(c in CostSummary,
          where: c.tenant_id == ^tenant.id,
          order_by: [desc: c.period_start],
          limit: 1
        )
        |> AdminRepo.one()

      assert last_day.period_start == expected_last
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
