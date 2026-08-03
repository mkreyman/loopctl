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

  # Public (mirrors `metrics/0` above) so the wiring itself is testable — a test
  # asserts the two US-34.1 Oban poller MFAs are present here, closing the gap
  # where the metric DEFINITIONS and poller FUNCTIONS were each tested in
  # isolation but nothing asserted either was actually wired into the 10s tick.
  def periodic_measurements do
    # NOTE: `telemetry_poller` runs every measurement through its OWN try/catch
    # (`make_measurements_and_filter_misbehaving/1`, verified against the vendored
    # telemetry_poller 1.3.0 source) — an uncaught raise does NOT crash the shared
    # poller or the other measurements (including the gate refresh). What it DOES do
    # is worse for the raising measurement specifically: telemetry_poller logs the
    # raise once and PERMANENTLY DROPS that MFA from the poll rotation until the next
    # app restart — the gauge/effect goes dark forever, silently.
    #
    # So EVERY measurement added here MUST run its body under
    # `ScaleMetrics.guarded_measurement/5`, which covers ALL THREE non-local exit kinds:
    # `rescue` + `catch :exit` + `catch :throw`, each degrading to a caller-supplied
    # fallback and firing the `loopctl.oban.poll.error.count` counter so a stale gauge is
    # detectable.
    #
    # An earlier version of this note asked only for "a catch-all rescue", and that
    # wording is exactly how this bug reached production: a DBConnection checkout against
    # a wedged, saturated or unstarted pool EXITS rather than raising, so every
    # measurement here satisfied the stated invariant and still went permanently dark on
    # the most likely fault. telemetry_poller drops the MFA on an exit and a throw the
    # same way it does on a raise — enumerating one of the three is not a partial
    # guarantee, it is none. Do not weaken this back to "rescue".
    [
      # US-27.15: refresh the metrics tenant-label cardinality gate (Tenants.count()
      # <= cap), caching the boolean in :persistent_term so the per-emit tag_values
      # path needs no DB hit. This is the ONLY DB read in the gating mechanism.
      {ScaleMetrics, :refresh_tenant_label_gate, []},

      # US-34.1 (AC-34.1.1/.3): per-{state, queue} poll of the GLOBAL `oban_jobs`
      # table, feeding the `loopctl.oban.jobs.count` gauge. Guarded per the note
      # above (`guarded_measurement/5`) and reports failures via the
      # `loopctl.oban.poll.error.count` counter.
      {ScaleMetrics, :poll_oban_queue_state, []},

      # US-34.1 (AC-34.1.2/.3): the `:executing`-older-than-N-min orphan poll,
      # feeding the `loopctl.oban.jobs.executing_orphan.count` gauge. Same
      # guarded-measurement contract.
      {ScaleMetrics, :poll_oban_executing_orphans, []},

      # US-38.3 (AC-38.3.2): the clustering-readiness peer poll, feeding the
      # `loopctl.cluster.peers.count` gauge from `Loopctl.ClusterReadiness.readiness/0`
      # (peer COUNT + bounded `status`, never node names). Same guarded contract.
      {ScaleMetrics, :poll_cluster_readiness, []}
    ]
  end
end
