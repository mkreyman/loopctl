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
end
