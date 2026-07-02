defmodule Loopctl.Workers.CostAnomalyWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.TokenUsage.CostAnomaly
  alias Loopctl.TokenUsage.CostSummary
  alias Loopctl.TokenUsage.Report
  alias Loopctl.Workers.CostAnomalyWorker

  defp detected_audit_count(tenant_id, story_id) do
    from(a in AuditLog,
      where:
        a.tenant_id == ^tenant_id and a.entity_type == "cost_anomaly" and
          a.action == "detected" and
          fragment("?->>'story_id' = ?", a.metadata, ^story_id)
    )
    |> AdminRepo.aggregate(:count)
  end

  defp setup_tenant_with_epic do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    %{tenant: tenant, project: project, epic: epic, agent: agent}
  end

  defp create_story_with_reports(tenant, epic, agent, cost_millicents) do
    story = create_bare_story(tenant, epic)

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

  defp create_bare_story(tenant, epic) do
    fixture(:story, %{
      tenant_id: tenant.id,
      epic_id: epic.id,
      project_id: epic.project_id
    })
  end

  # Adds a report to a story, optionally backdated `days_ago` days so we can
  # model a story whose cost is spread across multiple days.
  defp add_report(tenant, story, agent, epic, cost_millicents, days_ago) do
    report =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        project_id: epic.project_id,
        cost_millicents: cost_millicents
      })

    if days_ago > 0 do
      ts = DateTime.add(DateTime.utc_now(), -days_ago, :day)

      from(r in Report, where: r.id == ^report.id)
      |> AdminRepo.update_all(set: [inserted_at: ts])
    end

    report
  end

  # Adds a (possibly over-correcting) negative correction report that references
  # a live original, so the story's net cumulative cost can be driven negative.
  defp add_correction(tenant, story, agent, epic, original_id, cost_millicents) do
    %Report{
      tenant_id: tenant.id,
      story_id: story.id,
      agent_id: agent.id,
      project_id: epic.project_id,
      corrects_report_id: original_id
    }
    |> Report.correction_changeset(%{
      input_tokens: 0,
      output_tokens: 0,
      model_name: "claude-opus-4",
      cost_millicents: cost_millicents
    })
    |> AdminRepo.insert!()
  end

  # Inserts the epic cost summary the rollup would have written for `period`.
  # Only its existence (scope_type + period) marks the epic as a candidate; the
  # comparison baseline is recomputed from cumulative story totals, so `avg` here
  # only matters for the pre-fix (single-day-slice) behavior.
  defp insert_epic_summary(ctx, period, avg) do
    %CostSummary{tenant_id: ctx.tenant.id}
    |> CostSummary.changeset(%{
      scope_type: :epic,
      scope_id: ctx.epic.id,
      period_start: period,
      period_end: period,
      total_cost_millicents: avg,
      report_count: 1,
      avg_cost_per_story_millicents: avg
    })
    |> AdminRepo.insert!()
  end

  defp period_args(period) do
    %{"period_start" => Date.to_iso8601(period), "period_end" => Date.to_iso8601(period)}
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

      # 3 normal + 1 expensive story so the expensive one is genuinely > 3x the
      # epic per-story-total average: (10k + 10k + 10k + 100k) / 4 = 32_500;
      # 100_000 / 32_500 = 3.07x.
      _normal1 = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 10_000)
      _normal2 = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 10_000)
      _normal3 = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 10_000)
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
      # Should still be only 1 anomaly (updated, not duplicated)
      assert length(anomalies) == 1
      anomaly = hd(anomalies)
      assert anomaly.id == existing.id
      # Updated with the recomputed cumulative-total figures.
      assert anomaly.story_cost_millicents == 100_000
      assert anomaly.reference_avg_millicents == 32_500
    end

    # tokens-06(a): a story that is expensive CUMULATIVELY but cheap on any
    # single day must still be flagged. The old per-day-slice comparison missed
    # it because no individual day crossed the threshold.
    test "flags a story whose cumulative cost across multiple days exceeds 3x the epic average" do
      ctx = setup_tenant_with_epic()
      period = Date.utc_today()

      # 5 normal stories, each a single 10k report today.
      for _ <- 1..5, do: create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 10_000)

      # One expensive story: 60k total spread across 3 days (20k each). No single
      # day's slice (20k) trips the comparison; only the cumulative total does.
      expensive = create_bare_story(ctx.tenant, ctx.epic)
      add_report(ctx.tenant, expensive, ctx.agent, ctx.epic, 20_000, 0)
      add_report(ctx.tenant, expensive, ctx.agent, ctx.epic, 20_000, 5)
      add_report(ctx.tenant, expensive, ctx.agent, ctx.epic, 20_000, 10)

      # Epic per-story-total avg = (5*10k + 60k) / 6 = 18_333; 60k/18_333 = 3.27x.
      insert_epic_summary(ctx, period, 18_333)

      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: period_args(period)})

      high = AdminRepo.all(CostAnomaly) |> Enum.filter(&(&1.anomaly_type == :high_cost))
      assert length(high) == 1
      anomaly = hd(high)
      assert anomaly.story_id == expensive.id
      # Full cumulative cost, not a single day's slice.
      assert anomaly.story_cost_millicents == 60_000
    end

    # tokens-06(b): a completed story that gets a tiny follow-up report on a
    # later day must NOT be flagged suspiciously_low -- its cumulative total is
    # normal even though the follow-up day's slice alone is minuscule.
    test "does not flag a completed story as suspiciously_low when it gets a small later follow-up" do
      ctx = setup_tenant_with_epic()
      period = Date.utc_today()

      # 3 normal stories, each 30k today.
      for _ <- 1..3, do: create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 30_000)

      # A story that already cost 30k earlier (backdated, out of today's window)
      # and gets a tiny 100mc follow-up today. Cumulative total = 30_100 (normal),
      # even though today's slice alone is only 100mc.
      completed = create_bare_story(ctx.tenant, ctx.epic)
      add_report(ctx.tenant, completed, ctx.agent, ctx.epic, 30_000, 7)
      add_report(ctx.tenant, completed, ctx.agent, ctx.epic, 100, 0)

      # Per-story-total avg = (3*30k + 30_100) / 4 = 30_025; 30_100/30_025 ≈ 1.0x.
      insert_epic_summary(ctx, period, 30_025)

      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: period_args(period)})

      anomalies = AdminRepo.all(CostAnomaly)
      refute Enum.any?(anomalies, &(&1.anomaly_type == :suspiciously_low))
      assert anomalies == []
    end

    # tokens-06(c): repeated nightly runs over an unchanged total must not pile
    # up duplicate anomaly rows.
    test "does not create duplicate anomaly rows across repeated runs for the same unchanged total" do
      ctx = setup_tenant_with_epic()
      period = Date.utc_today()

      for _ <- 1..3, do: create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 10_000)
      expensive = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 100_000)

      # Per-story-total avg = (3*10k + 100k) / 4 = 32_500; 100k/32_500 = 3.07x.
      insert_epic_summary(ctx, period, 32_500)

      job = %Oban.Job{args: period_args(period)}
      assert :ok = CostAnomalyWorker.perform(job)
      assert :ok = CostAnomalyWorker.perform(job)
      assert :ok = CostAnomalyWorker.perform(job)

      anomalies = AdminRepo.all(CostAnomaly)
      assert length(anomalies) == 1
      assert hd(anomalies).story_id == expensive.id

      # Exactly ONE "detected" audit entry across the repeated runs -- notify
      # fires only on the genuine insert, never on the subsequent update/no-op
      # runs (FIX1: persisted-only notification).
      assert detected_audit_count(ctx.tenant.id, expensive.id) == 1
    end

    # FIX1c: when an unresolved anomaly already exists for a story (as a
    # concurrent winner would have written), a run must UPDATE it in place and
    # NOT emit a second "detected" audit entry -- i.e. never notify for a
    # non-newly-persisted anomaly.
    test "does not emit a second detected audit entry when the anomaly already exists" do
      ctx = setup_tenant_with_epic()
      period = Date.utc_today()

      for _ <- 1..3, do: create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 10_000)
      expensive = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 100_000)

      # Pre-existing unresolved anomaly (as though a concurrent run already
      # inserted + notified for it).
      fixture(:cost_anomaly, %{
        tenant_id: ctx.tenant.id,
        story_id: expensive.id,
        anomaly_type: :high_cost,
        story_cost_millicents: 90_000,
        reference_avg_millicents: 30_000,
        deviation_factor: Decimal.new("3.0")
      })

      insert_epic_summary(ctx, period, 32_500)

      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: period_args(period)})

      # Still exactly one anomaly row, and NO new "detected" audit entry.
      assert length(AdminRepo.all(CostAnomaly)) == 1
      assert detected_audit_count(ctx.tenant.id, expensive.id) == 0
    end

    # FIX A: a story whose net cumulative cost is negative (over-correction) must
    # NOT be flagged suspiciously_low (and thus never persisted/notified), while a
    # genuinely low-but-nonnegative story still IS flagged.
    test "does not flag a net-negative story, but still flags a genuinely low positive story" do
      ctx = setup_tenant_with_epic()
      period = Date.utc_today()

      # Normal stories keep the epic average positive.
      for _ <- 1..3, do: create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 30_000)

      # A genuinely low (but non-negative) story -> SHOULD be flagged.
      low = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 100)

      # A story driven net-negative by an over-correction (+5k then -20k = -15k).
      negative = create_bare_story(ctx.tenant, ctx.epic)
      original = add_report(ctx.tenant, negative, ctx.agent, ctx.epic, 5_000, 0)
      add_correction(ctx.tenant, negative, ctx.agent, ctx.epic, original.id, -20_000)

      insert_epic_summary(ctx, period, 15_000)

      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: period_args(period)})

      anomalies = AdminRepo.all(CostAnomaly)

      low_anomalies = Enum.filter(anomalies, &(&1.anomaly_type == :suspiciously_low))
      assert length(low_anomalies) == 1
      assert hd(low_anomalies).story_id == low.id

      # The negative story produced no anomaly at all...
      refute Enum.any?(anomalies, &(&1.story_id == negative.id))
      # ...no negative cost was ever persisted...
      assert Enum.all?(anomalies, &(&1.story_cost_millicents >= 0))
      # ...and no audit/notify fired for it.
      assert detected_audit_count(ctx.tenant.id, negative.id) == 0
    end

    # FIX A (create == update symmetry): the shared changeset that the insert_all
    # path now validates through rejects negative costs, so insert_all can never
    # persist what create_changeset would reject.
    test "create_changeset rejects negative costs (the invariant the insert path enforces)" do
      changeset =
        CostAnomaly.create_changeset(
          %CostAnomaly{tenant_id: Ecto.UUID.generate(), story_id: Ecto.UUID.generate()},
          %{
            anomaly_type: :suspiciously_low,
            story_cost_millicents: -15_000,
            reference_avg_millicents: 15_000,
            deviation_factor: Decimal.new("-1.0")
          }
        )

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :story_cost_millicents)
    end

    # FIX B: a reversed period range must still detect anomalies (the swap). The
    # candidate-epic query (period_start >= start and <= end) matches ZERO epics
    # for a reversed range, so without the swap detection is silently skipped.
    test "detects anomalies even when the period range is reversed" do
      ctx = setup_tenant_with_epic()
      today = Date.utc_today()

      for _ <- 1..3, do: create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 10_000)
      expensive = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 100_000)

      insert_epic_summary(ctx, today, 32_500)

      # period_start AFTER period_end (reversed on purpose).
      args = %{
        "period_start" => Date.to_iso8601(Date.add(today, 1)),
        "period_end" => Date.to_iso8601(Date.add(today, -1))
      }

      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: args})

      high = Enum.filter(AdminRepo.all(CostAnomaly), &(&1.anomaly_type == :high_cost))
      assert length(high) == 1
      assert hd(high).story_id == expensive.id
    end

    # FIX B: an over-cap period range is clamped, so an epic rolled up beyond the
    # 90-day cap is not scanned (bounds the work). Without the cap the far epic
    # would be a candidate and its story flagged.
    test "clamps an over-cap period range, excluding epics beyond the cap" do
      ctx = setup_tenant_with_epic()
      start_date = ~D[2026-01-01]
      # Epic summary rolled up ~200 days in -> beyond the 90-day cap.
      far_day = Date.add(start_date, 200)

      for _ <- 1..3, do: create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 10_000)
      _expensive = create_story_with_reports(ctx.tenant, ctx.epic, ctx.agent, 100_000)

      insert_epic_summary(ctx, far_day, 32_500)

      log =
        capture_log(fn ->
          assert :ok =
                   CostAnomalyWorker.perform(%Oban.Job{
                     args: %{
                       "period_start" => Date.to_iso8601(start_date),
                       # ~1 year -> clamped to start + 90 days
                       "period_end" => Date.to_iso8601(Date.add(start_date, 364))
                     }
                   })
        end)

      # The clamp ran...
      assert log =~ "exceeds 90 days; clamping end"
      # ...and the far epic (day 200, outside [start, start+90]) was NOT scanned.
      assert AdminRepo.all(CostAnomaly) == []
    end

    test "succeeds when no tenants exist" do
      # Delete all tenants (clean state)
      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: %{}})
    end
  end
end
