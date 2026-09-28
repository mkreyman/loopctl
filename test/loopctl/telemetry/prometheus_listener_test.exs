defmodule Loopctl.Telemetry.PrometheusListenerTest do
  @moduledoc """
  Starts the ONE Cowboy listener in the release — `TelemetryMetricsPrometheus`, through
  plug_cowboy, cowboy, cowlib and ranch — and scrapes it, so a bump of any of those (PR #926)
  is exercised by the suite rather than first seen as a missing `/metrics` in production.
  `Loopctl.Telemetry.MetricsReporter` starts it with an injected start function in its own
  tests, so nothing else reaches this path.
  """

  use ExUnit.Case, async: true

  test "the reporter's Cowboy listener starts and serves /metrics" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    name = :"prometheus_listener_#{System.unique_integer([:positive])}"

    start_supervised!(
      {TelemetryMetricsPrometheus,
       metrics: [Telemetry.Metrics.counter("loopctl.test.listener.count")],
       port: port,
       name: name,
       plug_cowboy_opts: [ip: {127, 0, 0, 1}]}
    )

    assert {:ok, %Req.Response{status: 200}} =
             Req.get("http://127.0.0.1:#{port}/metrics", retry: false)
  end
end
