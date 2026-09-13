defmodule LoopctlWeb.TelemetryPrometheusTest do
  @moduledoc """
  Issue #815: `LoopctlWeb.Telemetry.metrics/0` as the production reporter
  (`TelemetryMetricsPrometheus`) actually registers it. The reporter drops a summary at boot
  ("Metric type summary is unsupported") and a metric whose name collides, silently.

  `async: false`: a started reporter attaches telemetry handlers VM-wide, so every repo
  query any concurrent test made would run through them.
  """

  use ExUnit.Case, async: false

  describe "metrics/0 under the Prometheus reporter (issue #815)" do
    test "every metric registers: none is a summary the reporter drops, none collides" do
      name = :"telemetry_test_registry_#{System.unique_integer([:positive])}"
      metrics = LoopctlWeb.Telemetry.metrics()

      refute Enum.any?(metrics, &match?(%Telemetry.Metrics.Summary{}, &1))

      start_supervised!(
        {TelemetryMetricsPrometheus.Core, metrics: metrics, name: name, start_async: false}
      )

      registered = TelemetryMetricsPrometheus.Core.Registry.metrics(name)
      assert length(registered) == length(metrics)
    end

    test "runner refusals and ledger rejections are counted by their bounded tags" do
      name = :"telemetry_test_runner_#{System.unique_integer([:positive])}"

      start_supervised!(
        {TelemetryMetricsPrometheus.Core,
         metrics: LoopctlWeb.Telemetry.metrics(), name: name, start_async: false}
      )

      :telemetry.execute([:loopctl, :runners, :message_refused], %{count: 1}, %{
        event: "trace",
        reason: "stale_claim_epoch",
        tenant_id: Ecto.UUID.generate(),
        runner_id: Ecto.UUID.generate(),
        dispatch_id: nil,
        run_id: nil
      })

      :telemetry.execute([:loopctl, :runners, :ledger_rejected_by_database], %{count: 1}, %{
        operation: :record_trace,
        sqlstate: "22P05",
        constraint: nil,
        tenant_id: Ecto.UUID.generate(),
        runner_id: Ecto.UUID.generate(),
        dispatch_id: nil,
        run_id: nil
      })

      scrape = TelemetryMetricsPrometheus.Core.scrape(name)

      assert scrape =~
               ~s(loopctl_runners_message_refused_count{event="trace",reason="stale_claim_epoch"} 1)

      assert scrape =~
               ~s(loopctl_runners_ledger_rejected_by_database_count{operation="record_trace",sqlstate="22P05"} 1)

      refute scrape =~ "runner_id="
    end
  end
end
