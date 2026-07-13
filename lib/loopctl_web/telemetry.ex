defmodule LoopctlWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  alias Loopctl.Telemetry.ScaleAlerts
  alias Loopctl.Telemetry.ScaleMetrics

  # US-27.15: the internal port the Prometheus reporter binds for `/metrics`. It is
  # SEPARATE from the public 8080 `http_service` in fly.toml and is reachable ONLY
  # over Fly's private 6PN network by the managed-Prometheus scraper (the
  # `[metrics]` block). Tunable via `:metrics_port`.
  @default_metrics_port 9568

  # US-34.1: default cadence for the Oban `oban_jobs` poll's OWN `telemetry_poller`
  # instance — see `oban_poll_interval_ms/0`.
  @default_oban_poll_interval_ms 10_000

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      [
        # Telemetry poller will execute the given period measurements
        # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
        Supervisor.child_spec(
          {:telemetry_poller,
           measurements: periodic_measurements(), period: 10_000, name: :loopctl_telemetry_poller},
          id: :loopctl_telemetry_poller
        ),
        # US-34.1: the Oban `oban_jobs` poll runs on its OWN `telemetry_poller`
        # instance, with an INDEPENDENTLY configurable interval
        # (`:oban_metrics_poll_interval_ms`, default 10s) rather than inheriting the
        # tenant-label-gate poller's cadence above (AC-34.1.3 calls for a "bounded
        # interval (config)"). Two `:telemetry_poller` instances can coexist under one
        # Supervisor as long as each has a distinct `:name` (registered by
        # `:telemetry_poller`'s own `start_link/1`) and a distinct Supervisor child
        # `:id` (both default to `:telemetry_poller` otherwise, which would collide) —
        # `Supervisor.child_spec/2` overrides the id for exactly that reason. This also
        # shrinks the blast radius from the shared-poller crash risk documented on
        # `ScaleMetrics.dispatch_oban_stats/0`: a raise here can no longer take down
        # `refresh_tenant_label_gate/0`'s poller (still self-rescued regardless).
        Supervisor.child_spec(
          {:telemetry_poller,
           measurements: oban_periodic_measurements(),
           period: oban_poll_interval_ms(),
           name: :loopctl_oban_telemetry_poller},
          id: :loopctl_oban_telemetry_poller
        )
      ] ++ reporter_children() ++ scale_alerts_children()

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
      # Started through the fault-isolating `Loopctl.Telemetry.MetricsReporter` wrapper
      # (NOT `TelemetryMetricsPrometheus` directly) so a bind failure on the internal
      # :9568 port can never crash this supervisor and cascade into the app (team review
      # F1). The wrapper's init always succeeds; it starts/retries the reporter out of band.
      [
        {Loopctl.Telemetry.MetricsReporter,
         metrics: metrics(), port: metrics_port(), name: :loopctl_metrics}
      ]
    else
      []
    end
  end

  defp metrics_reporter_enabled? do
    Application.get_env(:loopctl, :metrics_reporter_enabled, false)
  end

  # US-27.15 (AC-27.15.2): the firing alert path. Supervised here so its ETS table +
  # telemetry handlers + check timer share the telemetry supervisor's lifecycle. Started
  # ONLY when `:scale_alerts_enabled` is true (prod via runtime.exs; OMITTED in :test so
  # the suite never runs background timers or owns the ETS table — tests start it
  # directly with a short window and drive `evaluate/0`). It is cheap and self-isolating:
  # its handlers self-rescue and it only POSTs when a webhook URL is set and a threshold
  # breaches.
  defp scale_alerts_children do
    if scale_alerts_enabled?() do
      [ScaleAlerts]
    else
      []
    end
  end

  defp scale_alerts_enabled? do
    Application.get_env(:loopctl, :scale_alerts_enabled, false)
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
    # NOTE: `telemetry_poller` runs every measurement in its OWN process and does NOT
    # isolate them — an uncaught raise in any measurement crashes ITS poller. So EVERY
    # measurement added here MUST be self-rescuing. `refresh_tenant_label_gate/0`
    # guards its only raising op (the DB count) with try/rescue (fail-soft to a
    # bounded gate); keep that invariant for future additions to THIS poller.
    [
      # US-27.15: refresh the metrics tenant-label cardinality gate (Tenants.count()
      # <= cap), caching the boolean in :persistent_term so the per-emit tag_values
      # path needs no DB hit. This is the ONLY DB read in the gating mechanism.
      {ScaleMetrics, :refresh_tenant_label_gate, []}
    ]
  end

  # US-34.1: split onto its OWN `telemetry_poller` instance (see `init/1`) so its
  # cadence is independently configurable and a raise here can never crash the
  # tenant-label-gate poller above. `dispatch_oban_stats/0` is fully self-rescuing
  # regardless (a poll error logs + skips rather than crashing this poller).
  defp oban_periodic_measurements do
    [
      # US-34.1: poll oban_jobs for per-(state, queue) counts + the :executing orphan
      # count, emitting the two gauges ScaleMetrics.scale_metrics/0 defines.
      {ScaleMetrics, :dispatch_oban_stats, []}
    ]
  end

  # The Oban poll's OWN configurable interval (`:oban_metrics_poll_interval_ms`,
  # default `@default_oban_poll_interval_ms`) — see `config/config.exs` for the
  # full rationale. Falls back to the default for any non-positive-integer value
  # rather than crashing supervisor init on a bad config.
  defp oban_poll_interval_ms do
    case Application.get_env(
           :loopctl,
           :oban_metrics_poll_interval_ms,
           @default_oban_poll_interval_ms
         ) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_oban_poll_interval_ms
    end
  end
end
