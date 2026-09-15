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

    test "includes poll_cluster_readiness/0 (US-38.3, AC-38.3.2)" do
      assert {ScaleMetrics, :poll_cluster_readiness, []} in LoopctlWeb.Telemetry.periodic_measurements()
    end
  end

  # #834 round 3, finding 1. A `:telemetry.execute` with no metric definition and no
  # `attach` exports NO SERIES — the event fires, the code reads as instrumented, and no
  # alert can ever be written against it. That shipped here: the per-connection kind
  # suppression emitted `declared_kind_refused` with a comment saying "this event is what an
  # alert counts", and nothing counted it.
  #
  # Scanning the SOURCE rather than listing the events by hand, for the same reason the
  # pollers above are asserted by wiring: a hand-kept list is exactly what stops being
  # updated when someone adds the next event.
  describe "every runner-channel telemetry event has a metric" do
    test "no :telemetry.execute in the runner channel is emitted into the void" do
      emitted =
        "lib/loopctl_web/runner_channel.ex"
        |> File.read!()
        |> then(&Regex.scan(~r/:telemetry\.execute\(\s*\[([^\]]+)\]/, &1))
        |> Enum.map(fn [_all, inside] ->
          inside
          |> String.split(",")
          |> Enum.map(&(&1 |> String.trim() |> String.trim_leading(":")))
        end)
        |> Enum.uniq()

      # The scan has to find something, or the assertion below passes vacuously on a regex
      # that stopped matching.
      assert length(emitted) >= 2

      defined =
        LoopctlWeb.Telemetry.metrics()
        |> Enum.map(& &1.event_name)
        |> Enum.map(fn name -> Enum.map(name, &to_string/1) end)
        |> MapSet.new()

      for event <- emitted do
        assert MapSet.member?(defined, event),
               "runner_channel.ex emits #{inspect(event)} and LoopctlWeb.Telemetry.metrics/0 " <>
                 "defines no metric for it, so it exports no series and no alert can fire " <>
                 "on it. Add a metric or stop emitting the event."
      end
    end
  end
end
