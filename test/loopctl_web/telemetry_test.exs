defmodule LoopctlWeb.TelemetryTest do
  @moduledoc """
  US-34.1 wiring test: `periodic_measurements/0` is the `telemetry_poller` MFA list
  actually driven by the 10s tick (`LoopctlWeb.Telemetry.init/1`). Before this test,
  `poll_oban_queue_state/0` and `poll_oban_executing_orphans/0` were each tested in
  isolation (`oban_metrics_poller_test.exs`) and their `Telemetry.Metrics` DEFINITIONS
  were tested in isolation (`scale_metrics_test.exs`), but nothing asserted the two
  poller functions are actually wired into `periodic_measurements/0` — a future
  refactor could silently drop either MFA and both gauges would go dark with no
  failing test. Pure module — no DB needed, so this uses plain ExUnit.Case (like
  `oban_config_test.exs`), not DataCase.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Telemetry.ScaleMetrics

  describe "periodic_measurements/0 (US-34.1 poller wiring)" do
    test "includes poll_oban_queue_state/0 (AC-34.1.1)" do
      assert {ScaleMetrics, :poll_oban_queue_state, []} in LoopctlWeb.Telemetry.periodic_measurements()
    end

    test "includes poll_oban_executing_orphans/0 (AC-34.1.2)" do
      assert {ScaleMetrics, :poll_oban_executing_orphans, []} in LoopctlWeb.Telemetry.periodic_measurements()
    end

    test "also still includes the pre-existing tenant-label gate refresh (regression guard)" do
      assert {ScaleMetrics, :refresh_tenant_label_gate, []} in LoopctlWeb.Telemetry.periodic_measurements()
    end
  end
end
