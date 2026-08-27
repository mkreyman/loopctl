defmodule Loopctl.Knowledge.IngestionHealthConsumerStallTest do
  @moduledoc """
  The nightly knowledge-lint consumer dead-man's-switch (#765 item 6).

  Every test here is written to KILL one guard: delete the guard it names and the test
  goes red. The two directions that matter are asserted explicitly and separately — a
  clean, quiet corpus must be quiet forever, and a corpus with work waiting and zero
  dispositions must alarm — because a detector that only ever gets tested in the alarming
  direction is one `true` away from paging on every healthy install.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge.IngestionHealth

  # Small windows so a test seeds three runs instead of seven. The DEFAULTS are asserted
  # separately (see "documented defaults") — driving them here would mean 7 fixtures per
  # test and would not test anything the explicit opts do not.
  @runs 3
  @opts %{consumer_stall_runs: @runs, consumer_pass_staleness_hours: 72}

  defp quiet_state(overrides \\ %{}), do: build(:knowledge_lint_state, overrides)

  defp with_consolidation(overrides),
    do: build(:knowledge_lint_state, %{"consolidation" => overrides})

  defp lint_run(tenant_id, hours_ago, state),
    do: knowledge_lint_run(tenant_id, hours_ago, state)

  defp lint_runs(tenant_id, count, state),
    do: knowledge_lint_runs(tenant_id, count, state)

  defp candidates_for(tenant_id, opts \\ @opts) do
    opts
    |> IngestionHealth.detect_consumer_stalled()
    |> Enum.filter(&(&1.tenant_id == tenant_id))
  end

  defp consumer_of(candidates, consumer),
    do: Enum.find(candidates, &(&1.consumer == consumer))

  # A draft this consumer would actually pick up: past the 48h fresh-hold floor, tenant
  # scope, shared visibility.
  defp held_draft(tenant_id) do
    captured_article(%{
      tenant_id: tenant_id,
      status: :draft,
      inserted_at: DateTime.add(DateTime.utc_now(), -96, :hour)
    })
  end

  describe "detect_consumer_stalled/1 — the quiet direction" do
    test "a clean corpus with nothing offered and every gate open is never a candidate" do
      tenant = fixture(:tenant)
      lint_runs(tenant.id, @runs, quiet_state())

      # KILLS: the `work? or hard_blind? or (paused and corroborated)` requirement in
      # class_candidate/4. Drop it and every healthy tenant becomes a candidate here.
      assert candidates_for(tenant.id) == []
    end

    test "one run that applied something clears the whole streak" do
      tenant = fixture(:tenant)
      starved = quiet_state(%{"drafts_offered" => 5})

      lint_run(tenant.id, 2, starved)
      lint_run(tenant.id, 26, quiet_state(%{"drafts_offered" => 5, "drafts_published" => 1}))
      lint_run(tenant.id, 50, starved)

      # KILLS: `applied_total == 0`. Without it a consumer that published last night
      # still alarms.
      assert candidates_for(tenant.id) == []
    end

    test "a class is not judged until a full window of completed runs exists" do
      tenant = fixture(:tenant)
      lint_runs(tenant.id, @runs - 1, quiet_state(%{"drafts_offered" => 5}))

      # KILLS: the `length(window) < runs` guard. Without it a tenant that ran the pass
      # for the first time last night is flagged on a window of one.
      assert candidates_for(tenant.id) == []
    end

    test "a tenant that has never completed a run is never a candidate" do
      tenant = fixture(:tenant)

      scan = IngestionHealth.detect_consumer_stalled_scan(@opts)

      assert Enum.filter(scan.candidates, &(&1.tenant_id == tenant.id)) == []

      refute MapSet.member?(
               scan.evaluated_keys,
               {tenant.id, IngestionHealth.consumer_pass_source_type()}
             )
    end

    test "a paused drain with an empty draft queue does not alarm" do
      tenant = fixture(:tenant)
      lint_runs(tenant.id, @runs, quiet_state(%{"drafts_gate" => "drain_disabled"}))

      # KILLS: the corroboration guard on the paused branch. Treating `drain_disabled` as
      # evidence on its own alarms forever on every keyless or paused tenant whose queue
      # is empty — which is how a real switch gets muted.
      assert candidates_for(tenant.id) == []
    end
  end

  describe "detect_consumer_stalled/1 — the alarming direction" do
    test "flags a draft consumer offered work that published nothing" do
      tenant = fixture(:tenant)
      lint_runs(tenant.id, @runs, quiet_state(%{"drafts_offered" => 11}))

      candidate = tenant.id |> candidates_for() |> consumer_of(:drafts)

      assert candidate.source_type == "knowledge_lint_drafts"
      assert candidate.anomaly_type == :consumer_stalled
      assert candidate.reason == :no_dispositions
      assert candidate.runs_examined == @runs
      assert candidate.evidence["work_observed"] == true
      assert candidate.evidence["applied_total"] == 0
      # The drought is at least as old as the OLDEST run in the window.
      assert candidate.hours_stale >= 48
    end

    test "flags a paused draft drain that is holding drafts" do
      tenant = fixture(:tenant)
      held_draft(tenant.id)
      lint_runs(tenant.id, @runs, quiet_state(%{"drafts_gate" => "drain_disabled"}))

      # KILLS: `corroborated?(:drafts, tenant_id)`. Return false unconditionally and a
      # drain an operator paused and forgot stays invisible with a full queue behind it.
      candidate = tenant.id |> candidates_for() |> consumer_of(:drafts)

      assert candidate.evidence["paused_runs"] == @runs
      assert candidate.evidence["work_observed"] == false
      assert "drain_disabled" in candidate.evidence["gates"]
    end

    test "flags a judge that failed every night, on the -1 sentinel alone" do
      tenant = fixture(:tenant)
      lint_runs(tenant.id, @runs, quiet_state(%{"conflicts_judge_candidates" => -1}))

      # KILLS: `candidates == -1` in class_reading(:conflict_judge, _). It is the only
      # field that CAN report a died-every-night judge — both truncation flags are
      # hardcoded false on that path — so without this clause the #761 shape is silent.
      candidate = tenant.id |> candidates_for() |> consumer_of(:conflict_judge)

      assert candidate.evidence["hard_blind_runs"] == @runs
      assert candidate.evidence["work_observed"] == false
    end

    test "flags a judge with candidates waiting that judged none" do
      tenant = fixture(:tenant)
      lint_runs(tenant.id, @runs, quiet_state(%{"conflicts_judge_candidates" => 400}))

      candidate = tenant.id |> candidates_for() |> consumer_of(:conflict_judge)

      assert candidate.evidence["work_observed"] == true
    end

    test "flags a retitle step whose wall clock cut in before its first application" do
      tenant = fixture(:tenant)

      state = with_consolidation(%{"generic_title_budget_exhausted" => true})
      lint_runs(tenant.id, @runs, state)

      # KILLS: `budget_exhausted? and applied == 0`. A step starved of the shared reserve
      # reports the same zero a clean corpus does; the flag is the only thing that differs.
      candidate = tenant.id |> candidates_for() |> consumer_of(:generic_titles)

      assert candidate.evidence["hard_blind_runs"] == @runs
    end

    test "flags a duplicate drain whose apply crashed every night" do
      tenant = fixture(:tenant)

      state = with_consolidation(%{"duplicate_apply_gate" => "apply_failed"})
      lint_runs(tenant.id, @runs, state)

      # KILLS: the `apply_failed`/`scan_failed` hard-blind gate list.
      candidate = tenant.id |> candidates_for() |> consumer_of(:duplicates)

      assert candidate.evidence["hard_blind_runs"] == @runs
      assert "apply_failed" in candidate.evidence["gates"]
    end

    test "reads the consolidation report's by_class as the work signal behind a paused gate" do
      tenant = fixture(:tenant)

      state =
        with_consolidation(%{
          "duplicate_apply_gate" => "drain_disabled",
          "by_class" => %{"duplicate_capture" => 4, "generic_title" => 0}
        })

      lint_runs(tenant.id, @runs, state)

      # KILLS: `proposals_for/2`. The apply tally reports nothing but zeroes behind a
      # pause; the SCAN's own proposal count is written anyway, and it is the only thing
      # that says a queue was waiting.
      candidate = tenant.id |> candidates_for() |> consumer_of(:duplicates)

      assert candidate.evidence["work_observed"] == true
      assert candidate.evidence["paused_runs"] == @runs
    end

    test "flags the pass itself when no run has completed inside the staleness window" do
      tenant = fixture(:tenant)
      lint_run(tenant.id, 96, quiet_state())

      # KILLS: pass_candidate/4. This is the #761 shape — six nights killed inside the
      # judge, no audit event written at all — and no per-class streak can see it,
      # because a streak counted over EVENTS freezes when the events stop.
      candidate = tenant.id |> candidates_for() |> consumer_of(:pass)

      assert candidate.source_type == IngestionHealth.consumer_pass_source_type()
      assert candidate.reason == :no_completion
      assert candidate.hours_stale >= 96
      assert candidate.evidence["threshold_hours"] == 72
    end

    test "does not flag the pass when a run completed inside the window" do
      tenant = fixture(:tenant)
      lint_run(tenant.id, 2, quiet_state())

      assert tenant.id |> candidates_for() |> consumer_of(:pass) == nil
    end

    test "one tenant's stalled consumer never flags another tenant" do
      stalled = fixture(:tenant)
      healthy = fixture(:tenant)

      lint_runs(stalled.id, @runs, quiet_state(%{"drafts_offered" => 11}))
      lint_runs(healthy.id, @runs, quiet_state())

      assert stalled.id |> candidates_for() |> consumer_of(:drafts)
      assert candidates_for(healthy.id) == []
    end
  end

  describe "auto_resolve_recovered_consumer_stalled/1" do
    test "closes an active stall whose consumer started applying again" do
      tenant = fixture(:tenant)
      lint_runs(tenant.id, @runs, quiet_state(%{"drafts_offered" => 11, "drafts_published" => 3}))

      anomaly =
        fixture(:ingestion_anomaly, %{
          tenant_id: tenant.id,
          source_type: "knowledge_lint_drafts",
          anomaly_type: :consumer_stalled,
          last_event_at: nil,
          hours_stale: 72,
          sample_count: @runs
        })

      scan = IngestionHealth.detect_consumer_stalled_scan(@opts)

      assert IngestionHealth.auto_resolve_recovered_consumer_stalled(scan) >= 1

      reloaded = Loopctl.AdminRepo.get!(Loopctl.Knowledge.IngestionAnomaly, anomaly.id)
      assert reloaded.resolved
      refute is_nil(reloaded.last_event_at)
    end

    test "leaves an anomaly open when this run could not judge its key" do
      tenant = fixture(:tenant)
      # Too few completed runs to judge a streak — absent from the candidate list, and
      # absent from `evaluated_keys` too.
      lint_runs(tenant.id, @runs - 1, quiet_state())

      anomaly =
        fixture(:ingestion_anomaly, %{
          tenant_id: tenant.id,
          source_type: "knowledge_lint_drafts",
          anomaly_type: :consumer_stalled,
          last_event_at: nil,
          hours_stale: 72,
          sample_count: @runs
        })

      scan = IngestionHealth.detect_consumer_stalled_scan(@opts)

      # KILLS: the `MapSet.member?(evaluated, key)` gate. Closing on mere absence from
      # the candidate list stamps `resolved: true` into the append-only audit log for
      # exactly the tenants whose evidence went missing.
      assert IngestionHealth.auto_resolve_recovered_consumer_stalled(scan) == 0

      reloaded = Loopctl.AdminRepo.get!(Loopctl.Knowledge.IngestionAnomaly, anomaly.id)
      refute reloaded.resolved
    end

    test "leaves a still-stalled consumer's anomaly open" do
      tenant = fixture(:tenant)
      lint_runs(tenant.id, @runs, quiet_state(%{"drafts_offered" => 11}))

      anomaly =
        fixture(:ingestion_anomaly, %{
          tenant_id: tenant.id,
          source_type: "knowledge_lint_drafts",
          anomaly_type: :consumer_stalled,
          last_event_at: nil,
          hours_stale: 72,
          sample_count: @runs
        })

      scan = IngestionHealth.detect_consumer_stalled_scan(@opts)

      assert IngestionHealth.auto_resolve_recovered_consumer_stalled(scan) == 0
      refute Loopctl.AdminRepo.get!(Loopctl.Knowledge.IngestionAnomaly, anomaly.id).resolved
    end
  end

  describe "documented defaults and derived bounds" do
    test "the shipped window is 7 runs / 72 hours" do
      assert IngestionHealth.consumer_stall_runs() == 7
      assert IngestionHealth.consumer_pass_staleness_hours() == 72
    end

    test "the history window is DERIVED from the two thresholds, never picked beside them" do
      # Double the longer of the two windows, so a tenant missing up to half its nightly
      # runs still has a full streak's worth of events inside it. Derive it differently
      # from the thresholds and this goes red — which is the #761 lesson in miniature.
      assert IngestionHealth.consumer_history_days(7, 72) == 14
      assert IngestionHealth.consumer_history_days(3, 240) == 20
    end

    test "the history window is clamped to the audit_log retention" do
      # Past retention the rows this detector reads do not exist, so asking for them is
      # a window that silently reports nothing.
      assert IngestionHealth.consumer_history_days(400, 72) == 90
    end

    test "every consumer has its own sentinel source_type" do
      types = IngestionHealth.consumer_source_types()

      assert IngestionHealth.consumer_pass_source_type() in types
      assert length(types) == length(Enum.uniq(types))
      # Each one reports SEEN, so the operator API never warns that a legitimate filter
      # names a never-seen source.
      assert Enum.all?(types, &IngestionHealth.source_type_seen?(Ecto.UUID.generate(), &1))
    end
  end
end
