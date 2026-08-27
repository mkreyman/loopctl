defmodule Loopctl.Workers.IngestionHealthWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.Knowledge.IngestionHealth
  alias Loopctl.Workers.IngestionHealthWorker
  alias Loopctl.Workers.ScaleAlertDeliveryWorker
  alias Loopctl.Workers.WebhookDeliveryWorker

  # Defaults: established_threshold 5, staleness_threshold_hours 72, source ["session_log"].
  @stale_hours 96
  @fresh_hours 1

  defp captured(tenant_id, source_type, hours_ago) do
    captured_article(%{
      tenant_id: tenant_id,
      source_type: source_type,
      status: :published,
      inserted_at: DateTime.add(DateTime.utc_now(), -hours_ago, :hour)
    })
  end

  defp seed_captures(tenant_id, source_type, count, hours_ago) do
    for _ <- 1..count, do: captured(tenant_id, source_type, hours_ago)
  end

  defp detected_audit_count(tenant_id, source_type) do
    from(a in AuditLog,
      where:
        a.tenant_id == ^tenant_id and a.entity_type == "ingestion_anomaly" and
          a.action == "detected" and
          fragment("?->>'source_type' = ?", a.metadata, ^source_type)
    )
    |> AdminRepo.aggregate(:count)
  end

  defp anomalies_for(tenant_id) do
    from(a in IngestionAnomaly, where: a.tenant_id == ^tenant_id) |> AdminRepo.all()
  end

  describe "perform/1 — nightly consumer-stall detection (#765 item 6)" do
    # The real defaults apply here on purpose: this is the wiring test, and the number of
    # runs it takes to trip the switch in production is part of the wiring.
    defp consumer_anomalies(tenant_id) do
      tenant_id |> anomalies_for() |> Enum.filter(&(&1.anomaly_type == :consumer_stalled))
    end

    test "flags a starved consumer, writing audit + operator alert" do
      tenant = fixture(:tenant)

      knowledge_lint_runs(
        tenant.id,
        IngestionHealth.consumer_stall_runs(),
        build(:knowledge_lint_state, %{"drafts_offered" => 11})
      )

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

        assert_enqueued(worker: ScaleAlertDeliveryWorker)
      end)

      assert [anomaly] = consumer_anomalies(tenant.id)
      assert anomaly.source_type == "knowledge_lint_drafts"
      assert anomaly.sample_count == IngestionHealth.consumer_stall_runs()
      assert anomaly.metadata["consumer"] == "drafts"
      assert anomaly.metadata["reason"] == "no_dispositions"
      # The alert fired and the row records that it did, so a healthy next run takes the
      # silent update path instead of re-paging.
      assert anomaly.alerted

      assert detected_audit_count(tenant.id, "knowledge_lint_drafts") == 1
    end

    test "a healthy nightly pass produces no consumer-stall anomaly" do
      tenant = fixture(:tenant)

      knowledge_lint_runs(
        tenant.id,
        IngestionHealth.consumer_stall_runs(),
        build(:knowledge_lint_state, %{})
      )

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      end)

      assert consumer_anomalies(tenant.id) == []
    end

    test "an existing stall is refreshed silently — no second audit entry" do
      tenant = fixture(:tenant)

      knowledge_lint_runs(
        tenant.id,
        IngestionHealth.consumer_stall_runs(),
        build(:knowledge_lint_state, %{"drafts_offered" => 11})
      )

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      end)

      assert [_one] = consumer_anomalies(tenant.id)
      assert detected_audit_count(tenant.id, "knowledge_lint_drafts") == 1
    end

    test "a globally dead pass pages ONCE, not once per tenant" do
      tenants = for _ <- 1..3, do: fixture(:tenant)
      for t <- tenants, do: knowledge_lint_run(t.id, 100, build(:knowledge_lint_state, %{}))

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

        # KILLS: the `pass` clause in notify/2 + fire_consumer_pass_system_alert/1. The
        # cause is the ONE nightly cron, so the per-tenant path pages N times for it —
        # 2,000 pages at the documented sizing, for a single dead worker.
        assert [job] = all_enqueued(worker: ScaleAlertDeliveryWorker)
        assert job.args["payload"]["scope"] == "system"
        assert job.args["payload"]["affected_tenants"] == 3
      end)

      # One anomaly row per tenant all the same, so `resolve`/`archive` stay per tenant.
      for t <- tenants, do: assert([_] = consumer_anomalies(t.id))
    end

    test "an archived stall is never re-flagged" do
      tenant = fixture(:tenant)

      knowledge_lint_runs(
        tenant.id,
        IngestionHealth.consumer_stall_runs(),
        build(:knowledge_lint_state, %{"drafts_offered" => 11})
      )

      fixture(:ingestion_anomaly, %{
        tenant_id: tenant.id,
        source_type: "knowledge_lint_drafts",
        anomaly_type: :consumer_stalled,
        last_event_at: nil,
        hours_stale: 72,
        sample_count: 7,
        archived: true
      })

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      end)

      # The operator escape hatch: exactly the row that was already there, unresolved and
      # unrefreshed, and no new one beside it.
      assert [existing] = consumer_anomalies(tenant.id)
      assert existing.archived
      assert detected_audit_count(tenant.id, "knowledge_lint_drafts") == 0
    end
  end

  describe "perform/1 — capture-silence detection" do
    test "flags an established + stale source_type, writing audit + operator alert" do
      tenant = fixture(:tenant)
      seed_captures(tenant.id, "session_log", 5, @stale_hours)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

        # An operator alert was ENQUEUED (id-only payload) — assert the job, not the network.
        assert_enqueued(worker: ScaleAlertDeliveryWorker)
      end)

      [anomaly] = anomalies_for(tenant.id)
      assert anomaly.anomaly_type == :capture_silence
      assert anomaly.source_type == "session_log"
      assert anomaly.sample_count == 5
      assert anomaly.hours_stale >= 72
      assert anomaly.resolved == false

      assert detected_audit_count(tenant.id, "session_log") == 1
    end

    test "fires a per-tenant knowledge.ingestion_anomaly_detected webhook when subscribed" do
      tenant = fixture(:tenant)

      webhook =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          events: ["knowledge.ingestion_anomaly_detected"]
        })

      seed_captures(tenant.id, "session_log", 5, @stale_hours)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert_enqueued(worker: WebhookDeliveryWorker, args: %{tenant_id: tenant.id})
      end)

      events =
        from(e in Loopctl.Webhooks.WebhookEvent,
          where: e.tenant_id == ^tenant.id and e.webhook_id == ^webhook.id
        )
        |> AdminRepo.all()

      assert length(events) == 1
      assert hd(events).event_type == "knowledge.ingestion_anomaly_detected"
    end

    test "does not flag an established source_type that is still fresh" do
      tenant = fixture(:tenant)
      seed_captures(tenant.id, "session_log", 5, @fresh_hours)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        refute_enqueued(worker: ScaleAlertDeliveryWorker)
      end)

      assert anomalies_for(tenant.id) == []
    end

    test "does not flag a source_type that never became established (below threshold)" do
      tenant = fixture(:tenant)
      # 4 stale captures — below the established_threshold of 5.
      seed_captures(tenant.id, "session_log", 4, @stale_hours)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

      assert anomalies_for(tenant.id) == []
      assert detected_audit_count(tenant.id, "session_log") == 0
    end

    test "does not monitor an unmonitored source_type even when established + stale" do
      tenant = fixture(:tenant)
      seed_captures(tenant.id, "manual", 5, @stale_hours)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

      assert anomalies_for(tenant.id) == []
    end

    test "a second run on the same stale condition updates in place and does NOT re-notify" do
      tenant = fixture(:tenant)
      seed_captures(tenant.id, "session_log", 5, @stale_hours)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

        # Exactly ONE operator alert across the two runs (anti-alarm-fatigue).
        assert length(all_enqueued(worker: ScaleAlertDeliveryWorker)) == 1
      end)

      # Still exactly one anomaly row and one detected audit entry.
      assert length(anomalies_for(tenant.id)) == 1
      assert detected_audit_count(tenant.id, "session_log") == 1
    end

    test "a resolved anomaly is NOT re-created/re-notified while silence persists" do
      tenant = fixture(:tenant)
      seed_captures(tenant.id, "session_log", 5, @stale_hours)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        [anomaly] = anomalies_for(tenant.id)

        # Operator resolves it; the source_type is still silent (no new capture).
        assert {:ok, _} = IngestionHealth.resolve_anomaly(tenant.id, anomaly.id)

        # Next hourly run must NOT create a fresh anomaly or re-fire the alarm.
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

        assert length(all_enqueued(worker: ScaleAlertDeliveryWorker)) == 1
      end)

      # Still exactly one (now-resolved) row and one detected audit entry.
      assert length(anomalies_for(tenant.id)) == 1
      assert detected_audit_count(tenant.id, "session_log") == 1
    end

    test "re-flags only after captures resume and the source goes silent again" do
      tenant = fixture(:tenant)
      seed_captures(tenant.id, "session_log", 5, @stale_hours)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      [anomaly] = anomalies_for(tenant.id)
      assert {:ok, _} = IngestionHealth.resolve_anomaly(tenant.id, anomaly.id)

      # Captures RESUME (a newer article) then the source goes silent again past
      # the staleness threshold — this is a genuinely new regression.
      captured(tenant.id, "session_log", 80)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

      # A second (unresolved) anomaly is created for the new silence episode.
      unresolved = anomalies_for(tenant.id) |> Enum.reject(& &1.resolved)
      assert length(unresolved) == 1
      assert detected_audit_count(tenant.id, "session_log") == 2
    end

    test "an archived anomaly permanently suppresses re-detection for that source_type" do
      tenant = fixture(:tenant)
      seed_captures(tenant.id, "session_log", 5, @stale_hours)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      [anomaly] = anomalies_for(tenant.id)
      assert {:ok, _} = IngestionHealth.archive_anomaly(tenant.id, anomaly.id)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        # No new operator alert — the archived source_type is suppressed.
        assert all_enqueued(worker: ScaleAlertDeliveryWorker) == []
      end)

      # No new anomaly rows were created (still just the archived one).
      assert length(anomalies_for(tenant.id)) == 1
    end

    test "re-fires a lost operator alert for an unresolved-but-unalerted row (at-least-once)" do
      tenant = fixture(:tenant)
      seed_captures(tenant.id, "session_log", 5, @stale_hours)

      # Simulate a crash between the atomic anomaly insert and the post-commit
      # enqueues: the row exists, unresolved, but was never alerted.
      last_event = DateTime.add(DateTime.utc_now(), -@stale_hours, :hour)

      anomaly =
        fixture(:ingestion_anomaly, %{
          tenant_id: tenant.id,
          source_type: "session_log",
          hours_stale: @stale_hours,
          sample_count: 5,
          last_event_at: last_event
        })

      refute anomaly.alerted

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        # The lost operator alert is recovered on this run.
        assert_enqueued(worker: ScaleAlertDeliveryWorker)
      end)

      # The row is now marked alerted so a healthy subsequent run won't re-fire.
      [reloaded] = anomalies_for(tenant.id)
      assert reloaded.alerted == true
    end

    test "auto-resolves an open anomaly whose captures resumed" do
      tenant = fixture(:tenant)

      anomaly =
        fixture(:ingestion_anomaly, %{
          tenant_id: tenant.id,
          source_type: "session_log",
          last_event_at: DateTime.add(DateTime.utc_now(), -100, :hour)
        })

      # A fresh capture after the anomaly's snapshot — the stream recovered.
      captured(tenant.id, "session_log", 1)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

      [reloaded] = anomalies_for(tenant.id)
      assert reloaded.id == anomaly.id
      assert reloaded.resolved == true
    end

    test "operator-alert payload conforms to the ScaleAlert contract (metric/value/threshold)" do
      tenant = fixture(:tenant)
      seed_captures(tenant.id, "session_log", 5, @stale_hours)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

        [job] = all_enqueued(worker: ScaleAlertDeliveryWorker)
        payload = job.args["payload"]

        assert payload["alert"] == "ingestion.capture_silence"
        assert payload["metric"] == "ingestion.capture_silence.hours_stale"
        assert is_integer(payload["value"])
        assert payload["threshold"] == 72
        assert payload["window_seconds"] == 72 * 3600
      end)
    end

    test "tenant isolation — tenant A's silence never flags tenant B" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      # A is established + stale; B is established + fresh.
      seed_captures(tenant_a.id, "session_log", 5, @stale_hours)
      seed_captures(tenant_b.id, "session_log", 5, @fresh_hours)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

      assert length(anomalies_for(tenant_a.id)) == 1
      assert anomalies_for(tenant_b.id) == []
    end

    test "succeeds when no tenants exist" do
      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
    end
  end

  # --- PR B2: high-reject-rate detection ---

  describe "perform/1 — high-reject-rate detection" do
    # Reject-rate config pins (config/test.exs): min_attempts 10, threshold 0.5.
    defp seed_reject_stats(tenant_id, source_type, counters) do
      fixture(
        :ingestion_write_stats,
        Map.merge(%{tenant_id: tenant_id, source_type: source_type}, counters)
      )
    end

    test "flags an established high-reject source_type with audit + operator alert + webhook" do
      tenant = fixture(:tenant)

      fixture(:webhook, %{
        tenant_id: tenant.id,
        events: ["knowledge.ingestion_anomaly_detected"]
      })

      # 10 attempts, 8 rejects (rate 0.8 > 0.5, total >= min_attempts 10).
      seed_reject_stats(tenant.id, "web_article", %{created_count: 2, title_conflict_count: 8})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert_enqueued(worker: ScaleAlertDeliveryWorker)
        assert_enqueued(worker: WebhookDeliveryWorker, args: %{tenant_id: tenant.id})
      end)

      [anomaly] = anomalies_for(tenant.id)
      assert anomaly.anomaly_type == :high_reject_rate
      assert anomaly.source_type == "web_article"
      assert anomaly.resolved == false
      assert anomaly.sample_count == 10
      assert anomaly.metadata["total_attempts"] == 10
      assert anomaly.metadata["rejects"] == 8
      assert anomaly.metadata["reject_rate"] > 0.5
      assert anomaly.metadata["dominant_reason"] == "title_conflict"
      assert anomaly.metadata["window_days"] == 7

      assert detected_audit_count(tenant.id, "web_article") == 1
    end

    test "operator-alert payload conforms to the ScaleAlert contract for high_reject_rate" do
      tenant = fixture(:tenant)
      seed_reject_stats(tenant.id, "web_article", %{created_count: 2, validation_error_count: 8})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

        [job] = all_enqueued(worker: ScaleAlertDeliveryWorker)
        payload = job.args["payload"]

        assert payload["alert"] == "ingestion.high_reject_rate"
        assert payload["metric"] == "ingestion.high_reject_rate.reject_rate"
        assert payload["value"] > 0.5
        assert payload["threshold"] == 0.5
        assert payload["window_seconds"] == 7 * 86_400
        assert payload["dominant_reason"] == "validation_error"
      end)
    end

    test "does not flag below min_attempts even at a high reject rate" do
      tenant = fixture(:tenant)
      # 5 attempts, 4 rejects (rate 0.8) but total < min_attempts 10.
      seed_reject_stats(tenant.id, "web_article", %{created_count: 1, title_conflict_count: 4})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        refute_enqueued(worker: ScaleAlertDeliveryWorker)
      end)

      assert anomalies_for(tenant.id) == []
    end

    test "does not flag when the reject rate is at/below threshold" do
      tenant = fixture(:tenant)
      # 10 attempts, 4 rejects (rate 0.4 <= 0.5).
      seed_reject_stats(tenant.id, "web_article", %{created_count: 6, title_conflict_count: 4})

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

      assert anomalies_for(tenant.id) == []
      assert detected_audit_count(tenant.id, "web_article") == 0
    end

    test "a second run on the same reject condition updates in place and does NOT re-notify" do
      tenant = fixture(:tenant)
      seed_reject_stats(tenant.id, "web_article", %{created_count: 2, title_conflict_count: 8})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

        assert length(all_enqueued(worker: ScaleAlertDeliveryWorker)) == 1
      end)

      assert length(anomalies_for(tenant.id)) == 1
      assert detected_audit_count(tenant.id, "web_article") == 1
    end

    test "tenant isolation — tenant A's rejects never flag tenant B" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      seed_reject_stats(tenant_a.id, "web_article", %{created_count: 2, title_conflict_count: 8})
      # B: same volume but low reject rate.
      seed_reject_stats(tenant_b.id, "web_article", %{created_count: 8, title_conflict_count: 2})

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

      assert [%{anomaly_type: :high_reject_rate}] = anomalies_for(tenant_a.id)
      assert anomalies_for(tenant_b.id) == []
    end

    test "flags a NULL/unstamped source_type reject bucket under the sentinel source_type" do
      tenant = fixture(:tenant)
      seed_reject_stats(tenant.id, nil, %{created_count: 2, title_conflict_count: 8})

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

      [anomaly] = anomalies_for(tenant.id)
      assert anomaly.anomaly_type == :high_reject_rate
      assert anomaly.source_type == IngestionHealth.unstamped_source_type()
      assert anomaly.metadata["total_attempts"] == 10
      assert anomaly.metadata["rejects"] == 8
    end
  end

  # --- Retention-sweep stall detection (issue #498, AC-39.5.5) ---------------------
  #
  # The absence-of-success half: a ChannelPostSweeper that stops running emits NO
  # failure telemetry, so the only observable evidence is expired channel_posts rows
  # that are still present. Grace window is pinned at 6h by config/test.exs.

  # No channel_post fixture exists (create_post/4 always stamps expires_at at now+30d),
  # so insert ChannelPost structs directly on the BYPASSRLS AdminRepo — the same idiom
  # the ChannelPostSweeper spec uses — to control expires_at.
  defp overdue_post(tenant_id, hours_overdue) do
    project = fixture(:project, %{tenant_id: tenant_id})
    agent = fixture(:agent, %{tenant_id: tenant_id})

    %ChannelPost{
      tenant_id: tenant_id,
      project_id: project.id,
      agent_id: agent.id,
      body: "post",
      expires_at: DateTime.add(DateTime.utc_now(), -hours_overdue, :hour)
    }
    |> AdminRepo.insert!()
  end

  defp sweep_anomalies(tenant_id) do
    tenant_id |> anomalies_for() |> Enum.filter(&(&1.anomaly_type == :sweep_stalled))
  end

  describe "perform/1 — retention-sweep stall detection (TC-39.5.9+)" do
    test "flags a tenant whose expired channel posts outlived the grace window" do
      tenant = fixture(:tenant)
      overdue_post(tenant.id, 24)
      overdue_post(tenant.id, 10)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert length(all_enqueued(worker: ScaleAlertDeliveryWorker)) == 1
      end)

      [anomaly] = sweep_anomalies(tenant.id)
      assert anomaly.source_type == IngestionHealth.sweep_source_type()
      assert anomaly.sample_count == 2
      assert anomaly.hours_stale >= 24
      assert anomaly.resolved == false
      # The stall episode is ACTIVE until recovery stamps last_event_at.
      assert is_nil(anomaly.last_event_at)
      assert anomaly.metadata["overdue_count"] == 2

      assert detected_audit_count(tenant.id, IngestionHealth.sweep_source_type()) == 1
    end

    test "does not flag expired rows still inside the grace window" do
      tenant = fixture(:tenant)
      # Expired 1h ago — the sweep has 6h of grace before it counts as stalled.
      overdue_post(tenant.id, 1)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        refute_enqueued(worker: ScaleAlertDeliveryWorker)
      end)

      assert sweep_anomalies(tenant.id) == []
    end

    test "a second run on the same stall updates in place and does NOT re-alert" do
      tenant = fixture(:tenant)
      overdue_post(tenant.id, 24)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

        assert length(all_enqueued(worker: ScaleAlertDeliveryWorker)) == 1
      end)

      assert length(sweep_anomalies(tenant.id)) == 1
      assert detected_audit_count(tenant.id, IngestionHealth.sweep_source_type()) == 1
    end

    test "re-fires a lost operator alert for an unresolved-but-unalerted row" do
      tenant = fixture(:tenant)
      overdue_post(tenant.id, 24)

      # Simulate a crash between the atomic insert and the post-commit enqueues.
      anomaly =
        fixture(:ingestion_anomaly, %{
          tenant_id: tenant.id,
          source_type: IngestionHealth.sweep_source_type(),
          anomaly_type: :sweep_stalled,
          last_event_at: nil,
          hours_stale: 24,
          sample_count: 1
        })

      refute anomaly.alerted

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert_enqueued(worker: ScaleAlertDeliveryWorker)
      end)

      [reloaded] = sweep_anomalies(tenant.id)
      assert reloaded.alerted == true
    end

    test "auto-closes an open stall once the sweep drains the backlog" do
      tenant = fixture(:tenant)
      post = overdue_post(tenant.id, 24)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      [open] = sweep_anomalies(tenant.id)
      assert open.resolved == false

      # The sweep recovers and deletes the backlog — no overdue rows remain.
      AdminRepo.delete!(post)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

      [closed] = sweep_anomalies(tenant.id)
      assert closed.resolved == true
      # Recovery stamps last_event_at (episode ended) so the row stops suppressing a
      # FUTURE stall — without this the type would freeze open forever, since both
      # pre-existing auto-resolvers are scoped to the other anomaly_types.
      assert %DateTime{} = closed.last_event_at
    end

    test "an archived stall anomaly suppresses re-detection" do
      tenant = fixture(:tenant)
      overdue_post(tenant.id, 24)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      [anomaly] = sweep_anomalies(tenant.id)
      assert {:ok, _} = IngestionHealth.archive_anomaly(tenant.id, anomaly.id)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert all_enqueued(worker: ScaleAlertDeliveryWorker) == []
      end)

      assert length(sweep_anomalies(tenant.id)) == 1
    end

    test "operator-alert payload conforms to the ScaleAlert contract and is SYSTEM-scoped" do
      tenant = fixture(:tenant)
      overdue_post(tenant.id, 24)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

        [job] = all_enqueued(worker: ScaleAlertDeliveryWorker)
        payload = job.args["payload"]

        assert payload["alert"] == "coordination.channel_post_sweep_stalled"
        assert payload["metric"] == "coordination.channel_post_sweep_stalled.hours_stale"
        assert payload["value"] >= 24
        assert payload["threshold"] == IngestionHealth.sweep_staleness_hours()
        assert payload["window_seconds"] == IngestionHealth.sweep_staleness_hours() * 3600
        # The CAUSE is the single global sweeper, so the alert is one system-scope
        # signal carrying the blast radius — not one alert per tenant.
        assert payload["scope"] == "system"
        assert payload["affected_tenants"] == 1
        assert payload["tenant_ids"] == [tenant.id]
        assert payload["overdue_count"] == 1
        assert is_binary(payload["at"])
      end)
    end

    # The detector is deliberately isolated (its own rescue/catch) so a saturated
    # AdminRepo pool cannot abort the sibling detectors — but with a log line as its ONLY
    # signal, a persistently failing residue read would reproduce, one level up, the
    # "visible only in logs / assumed healthy" failure #498 exists to close.
    test "the detector's own failure emits telemetry AND leaves the sibling detectors running" do
      tenant = fixture(:tenant)
      seed_captures(tenant.id, "session_log", 5, @stale_hours)

      handler = "test-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach(
        handler,
        Loopctl.TelemetryEvents.sweep_stall_detection_failed(),
        fn name, measurements, metadata, _ ->
          send(test_pid, {:telemetry, List.last(name), measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # Break ONLY the residue read at the DB: a SESSION-LOCAL temp table shadows
      # `channel_posts` on this connection (pg_temp is searched first) and lacks
      # `expires_at`, so the detector's first statement raises. It vanishes on the
      # sandbox rollback, so no concurrent async test can see it.
      AdminRepo.query!("CREATE TEMP TABLE channel_posts (id uuid)")

      log =
        capture_log(fn ->
          assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        end)

      assert log =~ "sweep-stall detection failed"

      assert_receive {:telemetry, :sweep_stall_detection_failed, %{count: 1},
                      %{error_class: "Postgrex.Error"}}

      # The isolation still holds: capture-silence flagging ran to completion.
      assert Enum.any?(anomalies_for(tenant.id), &(&1.anomaly_type == :capture_silence))
    end

    # The at-MOST-once regression (#498 review): `alerted` used to be committed per
    # candidate DURING flagging, while the only operator alert for the type was enqueued
    # after the whole pipe. A dropped enqueue then left rows alerted with no alert ever
    # emitted, and every later run took the silent update path — the alert was lost
    # forever. The flip now happens ONLY after a successful enqueue.
    test "a DROPPED system-alert enqueue leaves the anomaly unalerted so the next run re-fires" do
      tenant = fixture(:tenant)
      overdue_post(tenant.id, 24)

      failing_insert = fn _job -> {:error, %Ecto.Changeset{valid?: false}} end

      candidate = %{
        tenant_id: tenant.id,
        hours_stale: 24,
        overdue_count: 1
      }

      anomaly =
        fixture(:ingestion_anomaly, %{
          tenant_id: tenant.id,
          source_type: IngestionHealth.sweep_source_type(),
          anomaly_type: :sweep_stalled,
          last_event_at: nil,
          hours_stale: 24,
          sample_count: 1
        })

      log =
        capture_log(fn ->
          assert :error =
                   IngestionHealthWorker.commit_sweep_system_alert(
                     [{candidate, anomaly}],
                     failing_insert
                   )
        end)

      assert log =~ "left unalerted for re-fire next run"
      refute AdminRepo.get!(IngestionAnomaly, anomaly.id).alerted

      # ...and the very next hourly run re-fires it and only THEN marks it alerted.
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert [_] = all_enqueued(worker: ScaleAlertDeliveryWorker)
      end)

      assert AdminRepo.get!(IngestionAnomaly, anomaly.id).alerted
    end

    test "a SUCCESSFUL enqueue is what marks the participating anomalies alerted" do
      tenant = fixture(:tenant)
      overdue_post(tenant.id, 24)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert [_] = all_enqueued(worker: ScaleAlertDeliveryWorker)
      end)

      assert [%{alerted: true}] = sweep_anomalies(tenant.id)
    end

    # A global-worker outage leaves residue in N tenants. Each gets its OWN anomaly row
    # (its retention really is unenforced), but the operator must get ONE alert saying
    # "the sweeper is down", not N identical ones.
    test "N affected tenants produce N anomaly rows but exactly ONE operator alert" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      overdue_post(tenant_a.id, 24)
      overdue_post(tenant_b.id, 30)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

        assert [job] = all_enqueued(worker: ScaleAlertDeliveryWorker)
        payload = job.args["payload"]
        assert payload["affected_tenants"] == 2
        assert Enum.sort(payload["tenant_ids"]) == Enum.sort([tenant_a.id, tenant_b.id])
        assert payload["overdue_count"] == 2
      end)

      assert length(sweep_anomalies(tenant_a.id)) == 1
      assert length(sweep_anomalies(tenant_b.id)) == 1
    end

    # The anti-alarm-fatigue gate: an operator RESOLVED the row while the stall persists.
    # Without it the worker would re-create + re-alert every hour forever.
    test "an operator-resolved but still-stalled episode suppresses re-creation" do
      tenant = fixture(:tenant)
      overdue_post(tenant.id, 24)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      [open] = sweep_anomalies(tenant.id)
      {:ok, resolved} = IngestionHealth.resolve_anomaly(tenant.id, open.id, actor_type: "system")
      # The episode is still ACTIVE (last_event_at nil) — that is what suppresses.
      assert is_nil(resolved.last_event_at)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert all_enqueued(worker: ScaleAlertDeliveryWorker) == []
      end)

      # No SECOND row was created, and no second detected audit entry.
      assert length(sweep_anomalies(tenant.id)) == 1
      assert detected_audit_count(tenant.id, IngestionHealth.sweep_source_type()) == 1
    end

    # The re-arm the suppression gate depends on: once recovery stamps last_event_at, the
    # resolved row stops suppressing, so a FRESH stall fires a second alert.
    test "a recovered stall re-arms: a fresh stall re-fires" do
      tenant = fixture(:tenant)
      post = overdue_post(tenant.id, 24)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      [open] = sweep_anomalies(tenant.id)
      assert open.resolved == false

      # The sweep recovers (backlog drained) — recovery closes and stamps last_event_at.
      AdminRepo.delete!(post)
      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      [closed] = sweep_anomalies(tenant.id)
      assert closed.resolved == true
      assert %DateTime{} = closed.last_event_at

      # A NEW stall: the recovered row no longer suppresses, so a fresh unresolved
      # anomaly is created AND a second operator alert fires.
      overdue_post(tenant.id, 24)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert length(all_enqueued(worker: ScaleAlertDeliveryWorker)) == 1
      end)

      assert Enum.any?(sweep_anomalies(tenant.id), &(&1.resolved == false))
      assert detected_audit_count(tenant.id, IngestionHealth.sweep_source_type()) == 2
    end

    # Suspending a tenant drops it from the ACTIVE-tenant candidate join, but that is not
    # recovery — closing on it would write a false "retention recovered" entry into the
    # append-only, hash-chained audit log while the sweeper may still be dead.
    test "suspending a tenant does NOT auto-close its open stall as recovered" do
      tenant = fixture(:tenant)
      overdue_post(tenant.id, 24)

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      [open] = sweep_anomalies(tenant.id)
      assert open.resolved == false

      AdminRepo.update_all(
        from(t in Loopctl.Tenants.Tenant, where: t.id == ^tenant.id),
        set: [status: :suspended]
      )

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

      [still_open] = sweep_anomalies(tenant.id)
      assert still_open.resolved == false
      assert is_nil(still_open.last_event_at)
    end

    test "fires the per-tenant anomaly webhook for a stall on its OWN event type" do
      tenant = fixture(:tenant)

      webhook =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          events: ["coordination.channel_post_sweep_stalled"]
        })

      overdue_post(tenant.id, 24)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
        assert_enqueued(worker: WebhookDeliveryWorker, args: %{tenant_id: tenant.id})
      end)

      events =
        from(e in Loopctl.Webhooks.WebhookEvent,
          where: e.tenant_id == ^tenant.id and e.webhook_id == ^webhook.id
        )
        |> AdminRepo.all()

      assert length(events) == 1
      assert hd(events).payload["anomaly_type"] == "sweep_stalled"
      assert hd(events).event_type == "coordination.channel_post_sweep_stalled"
    end

    # A retention event is not a knowledge-ingestion event: a tenant that subscribed to
    # watch KB ingestion must not start receiving coordination-bus alerts (#498 review).
    test "a knowledge.ingestion_anomaly_detected subscriber receives NO stall event" do
      tenant = fixture(:tenant)

      webhook =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          events: ["knowledge.ingestion_anomaly_detected"]
        })

      overdue_post(tenant.id, 24)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      end)

      assert from(e in Loopctl.Webhooks.WebhookEvent,
               where: e.tenant_id == ^tenant.id and e.webhook_id == ^webhook.id
             )
             |> AdminRepo.all() == []
    end

    test "tenant isolation — tenant A's stalled sweep never flags tenant B" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      overdue_post(tenant_a.id, 24)
      # Tenant B's posts are all live — its retention IS being enforced.
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id})

      AdminRepo.insert!(%ChannelPost{
        tenant_id: tenant_b.id,
        project_id: project_b.id,
        agent_id: agent_b.id,
        body: "post",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

      [anomaly] = sweep_anomalies(tenant_a.id)
      assert anomaly.tenant_id == tenant_a.id
      assert sweep_anomalies(tenant_b.id) == []
      assert detected_audit_count(tenant_b.id, IngestionHealth.sweep_source_type()) == 0
    end
  end

  describe "high-reject-rate recovery + re-arm" do
    test "auto-closes an open reject anomaly once the reject rate recovers" do
      tenant = fixture(:tenant)
      seed_reject_stats(tenant.id, "web_article", %{created_count: 2, title_conflict_count: 8})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      end)

      [open] = anomalies_for(tenant.id)
      assert open.resolved == false
      assert is_nil(open.last_event_at)

      # Rejects recover: replace the rollup with a healthy window (no longer a candidate).
      Loopctl.AdminRepo.delete_all(
        from(s in Loopctl.Knowledge.IngestionWriteStats, where: s.tenant_id == ^tenant.id)
      )

      seed_reject_stats(tenant.id, "web_article", %{created_count: 10, title_conflict_count: 0})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      end)

      [closed] = anomalies_for(tenant.id)
      assert closed.resolved == true
      # last_event_at is stamped with the recovery time (episode ended) so the row
      # stops suppressing a future storm.
      assert %DateTime{} = closed.last_event_at
    end

    test "a resolved anomaly re-arms after recovery: a fresh storm re-fires" do
      tenant = fixture(:tenant)
      seed_reject_stats(tenant.id, "web_article", %{created_count: 2, title_conflict_count: 8})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      end)

      # Operator resolves; rejects then recover so the recovery pass stamps last_event_at.
      [open] = anomalies_for(tenant.id)
      {:ok, _} = IngestionHealth.resolve_anomaly(tenant.id, open.id, actor_type: "system")

      Loopctl.AdminRepo.delete_all(
        from(s in Loopctl.Knowledge.IngestionWriteStats, where: s.tenant_id == ^tenant.id)
      )

      seed_reject_stats(tenant.id, "web_article", %{created_count: 10, title_conflict_count: 0})
      assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})

      # A NEW storm: because the resolved row was marked recovered (last_event_at set),
      # it no longer suppresses — a fresh unresolved anomaly is created. Clear the rollup
      # first so the new storm reuses today's (tenant, source, day) bucket.
      AdminRepo.delete_all(
        from(s in Loopctl.Knowledge.IngestionWriteStats, where: s.tenant_id == ^tenant.id)
      )

      seed_reject_stats(tenant.id, "web_article", %{created_count: 2, title_conflict_count: 8})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = IngestionHealthWorker.perform(%Oban.Job{args: %{}})
      end)

      assert Enum.any?(anomalies_for(tenant.id), &(&1.resolved == false))
    end
  end
end
