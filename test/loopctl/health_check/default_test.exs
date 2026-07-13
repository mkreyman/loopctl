defmodule Loopctl.HealthCheck.DefaultTest do
  @moduledoc """
  US-32.4: exercises `Loopctl.HealthCheck.Default.check/0` directly (previously only
  covered indirectly via `Loopctl.MockHealthChecker` in the controller test). `check/0`
  reads live app env for scale-alert config, so — per `NEVER Application.put_env in
  tests` — this only asserts the healthy default-config case (AC-32.4.3:
  `scale_alerts_enabled` is false in `config/test.exs`, so no URL is required and the
  `scale_alerts` check is "ok" with no reasons attached). The misconfig branch is
  covered directly and exhaustively via the pure `ScaleAlerts.config_status/2` in
  `scale_alerts_config_test.exs`.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.HealthCheck.Default

  describe "check/0" do
    test "returns a scale_alerts check entry that is ok under the default test config" do
      assert {:ok, %{checks: %{scale_alerts: "ok"}} = result} = Default.check()
      refute Map.has_key?(result, :reasons)
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
end
