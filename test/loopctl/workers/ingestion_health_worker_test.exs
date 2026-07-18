defmodule Loopctl.Workers.IngestionHealthWorkerTest do
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
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
end
