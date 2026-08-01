defmodule Loopctl.HealthCheck.DefaultTest do
  @moduledoc """
  US-32.4: exercises `Loopctl.HealthCheck.Default.check/0` directly (previously only
  covered indirectly via `Loopctl.MockHealthChecker` in the controller test).

  The default-config case (AC-32.4.3: `scale_alerts_enabled` is false in
  `config/test.exs`) grades `checks.scale_alerts` as **"warn"**, not "ok" — that file also
  sets `:scale_alert_webhook_url` as a delivery-test fixture, which is the
  incoherent-but-legitimate combination #376 added the WARN grade for. What makes it a
  healthy path is that a warn does not block `ready`. The degraded path
  — the primary AC-32.4.1 behavior — is exercised via the
  `Loopctl.Telemetry.ScaleAlerts.ConfigStatusBehaviour` DI seam
  (`Loopctl.MockScaleAlertsConfigChecker`), overridden with `Mox.expect/3`, so it is
  covered WITHOUT `Application.put_env`. The pure guard itself
  (`ScaleAlerts.config_status/2`) is unit-tested exhaustively in
  `scale_alerts_config_test.exs`.

  Assertions on `status`/`checks.database`/`checks.oban` are made DIFFERENTIALLY
  (comparing a scale_alerts-ok call against a scale_alerts-error call), never against a
  hardcoded "ok" literal — `check_oban/0` calls the real `Oban.check_queue/1`, which does
  not report `paused` the same way under this suite's `testing: :inline` Oban config, so
  hardcoding "ok" here would be an environment assumption, not a behavior assertion.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.HealthCheck.Default

  setup :verify_on_exit!

  describe "check/0 — healthy default config" do
    # "warn", not "ok", is the CORRECT value here (#376): `config/test.exs` sets
    # `:scale_alert_webhook_url` as a fixture for the delivery tests while
    # `:scale_alerts_enabled` stays false, which is exactly the incoherent-but-legitimate
    # combination the WARN grade exists to describe. The invariant this test actually
    # guards is unchanged and is the one that matters — a non-"error" scale_alerts grade
    # must leave `ready` tracking liveness alone.
    test "returns a scale_alerts check entry that does not block readiness under the default test config" do
      assert {:ok, %{checks: %{scale_alerts: grade}} = result} = Default.check()
      assert grade == "warn"
      assert result.reasons.scale_alerts =~ "SCALE_ALERTS_ENABLED"
      # Readiness formula: liveness AND the scale-alerts config-guard not ERRORING.
      assert result.ready == (result.status == "ok")
    end

    test "database and oban checks are present alongside scale_alerts" do
      assert {:ok, %{checks: checks}} = Default.check()

      assert Map.has_key?(checks, :database)
      assert Map.has_key?(checks, :oban)
      assert Map.has_key?(checks, :scale_alerts)
    end

    test "does NOT disclose an app version on the unauthenticated response (#461 item 5)" do
      assert {:ok, result} = Default.check()
      refute Map.has_key?(result, :version)
      # status/ready/checks — the fields the LB and deploy gate act on — are intact.
      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :ready)
      assert Map.has_key?(result, :checks)
    end
  end

  describe "check/0 — WARN-grade scale_alerts config (#376)" do
    # The consequence that matters, asserted where it is observable: a `{:warn, _}` guard
    # result is SURFACED in checks/reasons but must NOT flip `ready`. `config/test.exs`
    # runs this exact shape (a webhook URL set while the checker is disabled), as may an
    # operator pausing alerting without removing the secret — blocking readiness on it
    # would red every deploy of a healthy release, the #363 alarm fatigue this signal was
    # just rescued from.
    test "surfaces checks.scale_alerts = warn + a reason, and leaves ready untouched" do
      Mox.expect(Loopctl.MockScaleAlertsConfigChecker, :config_status, fn -> :ok end)
      assert {:ok, baseline} = Default.check()

      Mox.expect(Loopctl.MockScaleAlertsConfigChecker, :config_status, fn ->
        {:warn, "SCALE_ALERT_WEBHOOK_URL is set but scale alerts are disabled"}
      end)

      assert {:ok, warned} = Default.check()

      assert warned.checks.scale_alerts == "warn"
      assert warned.reasons.scale_alerts =~ "SCALE_ALERT_WEBHOOK_URL"

      # The whole point: visible, but not a deploy gate.
      assert warned.ready == baseline.ready
      assert warned.status == baseline.status
    end
  end

  describe "check/0 — degraded scale_alerts config-guard (AC-32.4.1)" do
    test "surfaces checks.scale_alerts = error + reasons.scale_alerts, flips ready, and leaves liveness (status/database/oban) untouched" do
      Mox.expect(Loopctl.MockScaleAlertsConfigChecker, :config_status, fn -> :ok end)
      assert {:ok, baseline} = Default.check()

      Mox.expect(Loopctl.MockScaleAlertsConfigChecker, :config_status, fn ->
        {:error, "scale alerts enabled but SCALE_ALERT_WEBHOOK_URL is not set"}
      end)

      assert {:ok, degraded} = Default.check()

      assert degraded.checks.scale_alerts == "error"

      assert degraded.reasons == %{
               scale_alerts: "scale alerts enabled but SCALE_ALERT_WEBHOOK_URL is not set"
             }

      assert degraded.ready == false

      # Critical-review regression guard: liveness (`status` — what Fly's continuous
      # /health load-balancer check acts on) and the database/oban checks are UNCHANGED
      # by the scale_alerts result. A benign config-only misconfig must never depool an
      # otherwise-healthy node.
      assert degraded.status == baseline.status
      assert degraded.checks.database == baseline.checks.database
      assert degraded.checks.oban == baseline.checks.oban
    end

    test "a raise from the config-status checker degrades cleanly (checks.scale_alerts = error) instead of crashing the endpoint" do
      Mox.expect(Loopctl.MockScaleAlertsConfigChecker, :config_status, fn -> :ok end)
      assert {:ok, baseline} = Default.check()

      Mox.expect(Loopctl.MockScaleAlertsConfigChecker, :config_status, fn -> raise "boom" end)
      assert {:ok, result} = Default.check()

      assert result.checks.scale_alerts == "error"
      assert result.ready == false
      assert result.status == baseline.status
    end
  end

  describe "check/0 — Oban orphan backlog readiness signal (US-34.2)" do
    test "TC-34.2.1: orphan count above threshold degrades checks.oban_orphans, adds reasons.oban_orphans, flips ready, and leaves liveness (status/database/oban) untouched" do
      Mox.expect(Loopctl.MockObanOrphanCountChecker, :cached_executing_orphan_count, fn ->
        {:ok, 0}
      end)

      assert {:ok, baseline} = Default.check()

      Mox.expect(Loopctl.MockObanOrphanCountChecker, :cached_executing_orphan_count, fn ->
        {:ok, 11}
      end)

      assert {:ok, degraded} = Default.check()

      assert degraded.checks.oban_orphans == "error"

      # Review finding: the exact count/threshold are NOT disclosed in the reason
      # string — both /health and /health/ready are unauthenticated, so any
      # internet caller could otherwise read the live stuck-job count and the
      # configured trip point directly off the response body.
      assert degraded.reasons.oban_orphans ==
               "oban executing-orphan count exceeds configured threshold"

      assert degraded.ready == false

      # Critical regression guard (AC-34.2.2): a queue backlog must NOT depool a node
      # from Fly's LB — liveness (`status`) and the database/oban checks are UNCHANGED
      # by the orphan-count result.
      assert degraded.status == baseline.status
      assert degraded.checks.database == baseline.checks.database
      assert degraded.checks.oban == baseline.checks.oban
    end

    test "TC-34.2.2: no orphans / below threshold reports checks.oban_orphans = ok, no reasons.oban_orphans key, and ready tracks status" do
      Mox.expect(Loopctl.MockObanOrphanCountChecker, :cached_executing_orphan_count, fn ->
        {:ok, 0}
      end)

      assert {:ok, result} = Default.check()

      assert result.checks.oban_orphans == "ok"
      refute Map.has_key?(result.reasons, :oban_orphans)
      assert result.ready == (result.status == "ok")
    end

    test "TC-34.2.2b: a count at exactly the threshold does not degrade (only EXCEEDING the threshold does)" do
      Mox.expect(Loopctl.MockObanOrphanCountChecker, :cached_executing_orphan_count, fn ->
        {:ok, 10}
      end)

      assert {:ok, result} = Default.check()

      assert result.checks.oban_orphans == "ok"
      refute Map.has_key?(result.reasons, :oban_orphans)
    end

    test "review finding: `:not_yet_polled` (the brief window before US-34.1's poller has run once) is treated as ok, not degraded" do
      Mox.expect(Loopctl.MockObanOrphanCountChecker, :cached_executing_orphan_count, fn ->
        :not_yet_polled
      end)

      assert {:ok, result} = Default.check()

      assert result.checks.oban_orphans == "ok"
      refute Map.has_key?(result.reasons, :oban_orphans)
    end

    test "AC-34.2.3 defensive rescue (NOT story TC-34.2.3 — see the dedicated check_oban/0 hard-error test below): an orphan-count checker raising degrades cleanly instead of crashing" do
      Mox.expect(Loopctl.MockObanOrphanCountChecker, :cached_executing_orphan_count, fn ->
        {:ok, 0}
      end)

      assert {:ok, baseline} = Default.check()

      Mox.expect(Loopctl.MockObanOrphanCountChecker, :cached_executing_orphan_count, fn ->
        raise "boom"
      end)

      assert {:ok, result} = Default.check()

      assert result.checks.oban_orphans == "error"
      assert result.ready == false
      assert result.status == baseline.status
    end

    test "TC-34.2.3: an unresponsive queue producer is still a hard error (retained behavior) — real Oban.check_queue/1, no DI seam, no mocking" do
      # check_oban/0 is completely UNCHANGED by this story — it still calls the
      # real `Oban.check_queue(queue: :default)` with no DI seam. Under this
      # suite's `testing: :inline` Oban config (config/test.exs) there is no live
      # queue producer registered, so the real call genuinely returns `nil`
      # (verified directly: `Oban.check_queue(queue: :default) == nil` here) —
      # exercising check_oban/0's existing `_ -> {"error"}` hard-error branch for
      # real, not via a mock. This is the actual "queue-responsive ping still
      # hard-errors" case the story's TC-34.2.3 asks for.
      assert Oban.check_queue(queue: :default) == nil

      assert {:ok, result} = Default.check()

      assert result.checks.oban == "error"
      assert result.status == "degraded"
      assert result.ready == false
    end

    test "TC-34.2.1 (real rows, end-to-end): real orphaned oban_jobs rows counted via the real query (no Mox override) degrade checks.oban_orphans and flip ready" do
      alias Loopctl.Telemetry.ScaleMetrics

      threshold_minutes = ScaleMetrics.oban_metrics_orphan_threshold_minutes()
      health_threshold = 10
      now = DateTime.utc_now()

      # 11 real stale `:executing` rows — above both the AGE threshold (marks them as
      # orphans) and the COUNT threshold (11 > 10) — inserted directly, no mocking.
      for _ <- 1..(health_threshold + 1) do
        %Oban.Job{
          worker: "Loopctl.Workers.IdempotencyCleanupWorker",
          queue: "default",
          args: %{},
          state: "executing",
          attempted_at: DateTime.add(now, -(threshold_minutes + 5) * 60, :second)
        }
        |> Repo.insert!()
      end

      # A recent executing job is legitimately mid-flight, NOT an orphan — confirms
      # the real query's age filter, not just its count(*).
      %Oban.Job{
        worker: "Loopctl.Workers.IdempotencyCleanupWorker",
        queue: "default",
        args: %{},
        state: "executing",
        attempted_at: DateTime.add(now, -1, :second)
      }
      |> Repo.insert!()

      # No Mox.expect here — `stub_all_defaults/0` (data_case.ex) delegates
      # `Loopctl.MockObanOrphanCountChecker.cached_executing_orphan_count/0` to a
      # fresh call to the REAL `ScaleMetrics.count_oban_executing_orphans/0`
      # (deliberately NOT the `:persistent_term` cache — see the stub's comment),
      # so `Default.check/0` exercises the full chain: real rows -> real query ->
      # real count -> ready=false, scoped to this test's own sandboxed transaction.
      assert {:ok, result} = Default.check()

      assert result.checks.oban_orphans == "error"

      # Review finding: the exact count/threshold are NOT disclosed publicly.
      assert result.reasons.oban_orphans ==
               "oban executing-orphan count exceeds configured threshold"

      assert result.ready == false
    end
  end
end
