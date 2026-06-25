defmodule LoopctlWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  alias Loopctl.Telemetry.ScaleMetrics

  # US-27.15: the internal port the Prometheus reporter binds for `/metrics`. It is
  # SEPARATE from the public 8080 `http_service` in fly.toml and is reachable ONLY
  # over Fly's private 6PN network by the managed-Prometheus scraper (the
  # `[metrics]` block). Tunable via `:metrics_port`.
  @default_metrics_port 9568

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      [
        # Telemetry poller will execute the given period measurements
        # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
        {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      ] ++ reporter_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # US-27.15: the Prometheus reporter is a SUPERVISED child that binds the internal
  # `/metrics` port. It is started ONLY when `:metrics_reporter_enabled` is true
  # (prod via runtime.exs; OMITTED in :test so the suite never binds :9568, and
  # controllable in dev). The metric DEFINITIONS remain testable without a running
  # server because `metrics/0` is pure. We share the ONE `metrics/0` list with the
  # reporter so the scraped metrics and the tested defs can never drift.
  defp reporter_children do
    if metrics_reporter_enabled?() do
      [
        {TelemetryMetricsPrometheus,
         metrics: metrics(), port: metrics_port(), name: :loopctl_metrics}
      ]
    else
      []
    end
  end

  defp metrics_reporter_enabled? do
    Application.get_env(:loopctl, :metrics_reporter_enabled, false)
  end

  defp metrics_port do
    Application.get_env(:loopctl, :metrics_port, @default_metrics_port)
  end

  def metrics do
    base_metrics() ++ ScaleMetrics.scale_metrics()
  end

  defp base_metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("loopctl.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("loopctl.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("loopctl.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("loopctl.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("loopctl.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # US-27.15: refresh the metrics tenant-label cardinality gate (Tenants.count()
      # <= cap), caching the boolean in :persistent_term so the per-emit tag_values
      # path needs no DB hit. This is the ONLY DB read in the gating mechanism.
      {ScaleMetrics, :refresh_tenant_label_gate, []}
    ]
  end
end
