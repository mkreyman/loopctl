defmodule Loopctl.HealthCheck.DefaultTest do
  @moduledoc """
  US-32.4: exercises `Loopctl.HealthCheck.Default.check/0` directly (previously only
  covered indirectly via `Loopctl.MockHealthChecker` in the controller test).

  The healthy path (`checks: %{scale_alerts: "ok"}`) is the default-config case
  (AC-32.4.3: `scale_alerts_enabled` is false in `config/test.exs`). The degraded path
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
    test "returns a scale_alerts check entry that is ok under the default test config" do
      assert {:ok, %{checks: %{scale_alerts: "ok"}} = result} = Default.check()
      refute Map.has_key?(result, :reasons)
      # Readiness formula: liveness AND the scale-alerts config-guard passing.
      assert result.ready == (result.status == "ok")
    end

    test "database and oban checks are present alongside scale_alerts" do
      assert {:ok, %{checks: checks}} = Default.check()

      assert Map.has_key?(checks, :database)
      assert Map.has_key?(checks, :oban)
      assert Map.has_key?(checks, :scale_alerts)
    end

    test "reports a version string" do
      assert {:ok, %{version: version}} = Default.check()
      assert is_binary(version)
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
      Mox.expect(Loopctl.MockObanOrphanCountChecker, :count_oban_executing_orphans, fn -> 0 end)
      assert {:ok, baseline} = Default.check()

      Mox.expect(Loopctl.MockObanOrphanCountChecker, :count_oban_executing_orphans, fn -> 11 end)
      assert {:ok, degraded} = Default.check()

      assert degraded.checks.oban_orphans == "error"
      assert %{oban_orphans: reason} = degraded.reasons
      assert reason =~ "11"
      assert reason =~ "10"

      assert degraded.ready == false

      # Critical regression guard (AC-34.2.2): a queue backlog must NOT depool a node
      # from Fly's LB — liveness (`status`) and the database/oban checks are UNCHANGED
      # by the orphan-count result.
      assert degraded.status == baseline.status
      assert degraded.checks.database == baseline.checks.database
      assert degraded.checks.oban == baseline.checks.oban
    end

    test "TC-34.2.2: no orphans / below threshold reports checks.oban_orphans = ok, no reasons.oban_orphans key, and ready tracks status" do
      Mox.expect(Loopctl.MockObanOrphanCountChecker, :count_oban_executing_orphans, fn -> 0 end)

      assert {:ok, result} = Default.check()

      assert result.checks.oban_orphans == "ok"
      refute Map.has_key?(result, :reasons)
      assert result.ready == (result.status == "ok")
    end

    test "TC-34.2.2b: a count at exactly the threshold does not degrade (only EXCEEDING the threshold does)" do
      Mox.expect(Loopctl.MockObanOrphanCountChecker, :count_oban_executing_orphans, fn -> 10 end)

      assert {:ok, result} = Default.check()

      assert result.checks.oban_orphans == "ok"
      refute Map.has_key?(result, :reasons)
    end

    test "TC-34.2.3: an orphan-count query raising degrades cleanly (checks.oban_orphans = error) instead of crashing the endpoint" do
      Mox.expect(Loopctl.MockObanOrphanCountChecker, :count_oban_executing_orphans, fn -> 0 end)
      assert {:ok, baseline} = Default.check()

      Mox.expect(Loopctl.MockObanOrphanCountChecker, :count_oban_executing_orphans, fn ->
        raise "boom"
      end)

      assert {:ok, result} = Default.check()

      assert result.checks.oban_orphans == "error"
      assert result.ready == false
      assert result.status == baseline.status
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
      # `Loopctl.MockObanOrphanCountChecker.count_oban_executing_orphans/0` to the
      # REAL `ScaleMetrics.count_oban_executing_orphans/0`, so `Default.check/0`
      # exercises the full chain: real rows -> real query -> real count -> ready=false.
      assert {:ok, result} = Default.check()

      assert result.checks.oban_orphans == "error"
      assert %{oban_orphans: reason} = result.reasons
      assert reason =~ "11"
      assert reason =~ "10"
      assert result.ready == false
    end
  end
end
