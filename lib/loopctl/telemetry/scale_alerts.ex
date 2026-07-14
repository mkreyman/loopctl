defmodule Loopctl.Telemetry.ScaleAlerts do
  @moduledoc """
  The FIRING scale-alert path (US-27.15, AC-27.15.2).

  US-27.15's Prometheus metrics (`Loopctl.Telemetry.ScaleMetrics`) give a degradation
  TREND in `fly-metrics.net` Grafana — but Fly's managed Grafana has **alerting
  DISABLED** ("Fly.io doesn't include built-in alerting on metrics, so you'll need to
  set up alerting yourself against the Prometheus endpoint"). So the documented PromQL
  rules VISUALIZE but nothing FIRES. AC-27.15.2 ("at least one alert path that FIRES
  over a window") therefore needs a self-contained, loopctl-owned firing path. This is
  it: a supervised threshold checker that windows the three scale signals and, on a
  threshold breach, POSTs a small id-only alert to an operator-configured webhook
  (Slack / PagerDuty / generic) — no external Grafana/Alertmanager required.

  ## Data collection — the ETS-counter pattern (NOT a per-event GenServer call)

  The three scale signals are HIGH-FREQUENCY request-path events. Routing every event
  through a `GenServer.call/cast` would make this process a serialization bottleneck on
  the hot path (the OTP Iron Law). Instead, the attached `:telemetry` handlers write
  DIRECTLY to a public, `write_concurrency` ETS table owned by this GenServer, using the
  atomic `:ets.update_counter/3` (no message to this process at all). The GenServer only
  READS (and resets) the table on its periodic `:evaluate` tick.

  Three counters per tumbling window:

    * `:timeout_count` — incremented from `[:loopctl, :db, :error]` when
      `metadata.mapped_code == "db_statement_timeout"` (the 57014 class).
    * `:under_fill_count` — incremented from
      `[:loopctl, :knowledge, :vector_search, :under_fill]`.
    * a **bucketed latency histogram** from `[:loopctl, :heavy_read_repo, :query]`:
      `total_time` (native) is converted to ms and the matching bucket counter
      `{:lat_bucket, idx}` is incremented, plus `:lat_total`. Bucket-based p95 is the
      SAME approximation Prometheus uses (`histogram_quantile` over `_bucket` series) —
      bounded memory, NO per-sample reservoir. The buckets are the exact set the
      `ScaleMetrics` histogram uses (`#{inspect([10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000])}`),
      plus an implicit `+Inf` overflow bucket so a >10s query is still counted.

  Each handler is **self-rescuing** (mirrors `Loopctl.Telemetry.SlowQueryLogger` and
  `LoopctlWeb.DBErrorLogger`): a handler raise must NEVER break the request path it is
  observing, so it logs and returns `:ok`.

  ## Evaluation + firing (the GenServer)

  A periodic timer (`:scale_alert_check_interval_ms`, default 60_000) sends `:evaluate`;
  `evaluate/0` exposes the same work SYNCHRONOUSLY so tests drive it without sleeping.
  Each `:evaluate`:

    1. atomically READS + RESETS the window counters (a tumbling window),
    2. computes per-window:
       * `timeout_rate` = `timeout_count / window_minutes` (per-minute rate),
       * `under_fill_rate` = `under_fill_count / window_minutes`,
       * `p95_latency_ms` = the bucket upper bound whose cumulative count first crosses
         95% of `:lat_total` — skipped (`nil`) when `lat_total` is below a small floor
         (`@p95_min_samples`) to avoid alerting on statistical noise,
    3. compares each to its configured threshold,
    4. **edge-triggered fire + bounded periodic RE-NOTIFY (US-34.5)**: per-metric
       breach state (`breaching?`, `last_notified_at`) is held in the GenServer. An
       alert fires on the transition INTO breach (edge-triggered semantics unchanged
       from US-27.15). While the breach remains SUSTAINED, it re-fires once
       `renotify_interval_ms/0` has elapsed since the last notification — so an
       hours-long breach keeps paging instead of going silent after the first alert —
       and stays silent in between (bounded, not per-tick spam). The metric re-arms
       (`last_notified_at` cleared) once it clears back below threshold, so a later
       breach fires immediately again.

  On a firing breach the alert is an id-only map — `%{alert, metric, value, threshold,
  window_seconds, at}` — JSON-encoded and delivered via `Loopctl.Workers.ScaleAlertDeliveryWorker`
  (US-34.5, AC-34.5.1): the payload is enqueued through Oban's `:webhooks` queue rather
  than POSTed synchronously in-process, so a transient failure retries with Oban's
  backoff instead of being logged-and-dropped. **The enqueued job args carry ONLY the
  id-only `payload` — never the webhook URL** (secrets-at-rest review fix): Oban
  persists job args as cleartext JSON with no encryption plugin configured, and the
  webhook URL is commonly secret-bearing (Slack/PagerDuty tokens), so the worker instead
  re-resolves the URL at run time from `webhook_url/0`, mirroring the sibling
  `WebhookDeliveryWorker`'s pattern of never persisting a secret in `args`. The worker
  resolves the SAME `:webhook_delivery` DI (`Application.compile_env(:loopctl,
  :webhook_delivery, Loopctl.Webhooks.ReqDelivery)`) the webhook worker uses. **No
  tenant content, vectors, bodies, params, or SQL ever appears in the payload.** When the
  URL is `nil` alerting is OFF (opt-in): the breach is logged at `:warning` synchronously
  and nothing is enqueued or POSTed — this path is unchanged by US-34.5.

  ## Three additional signals (US-34.3) — same machinery, no changes to the above

  US-34.3 is purely additive plumbing on top of the same windowed-ETS-counter →
  periodic `:evaluate` → edge-fire → bounded re-notify → Oban delivery pipeline. It
  does NOT change the three signals documented above.

    * **(a) primary Repo checkout `queue_time` p95** — sourced from Ecto's own query
      event for `Loopctl.Repo`, `[:loopctl, :repo, :query]`, measurement `:queue_time`
      (native units, the SAME metric US-33.1's `loopctl.repo.checkout.queue_time`
      distribution reads). Bucketed exactly like the heavy-read p95 (SAME `@buckets`,
      `bucket_index/1`), but into a SEPARATE counter set (`{:qt_bucket, idx}` /
      `:qt_total`) so it never collides with the heavy-read histogram. **`:queue_time`
      is SKIPPED (not defaulted to 0) when absent from `measurements`** (review fix,
      HIGH): Ecto's `log_measurements/3` drops a measurement key entirely when its
      value is `nil`, which happens whenever the connection was already checked out
      (e.g. every statement after the first inside a transaction — the common case
      under loopctl's per-request RLS `SET LOCAL` transactions). Counting that absent
      case as a synthetic 0ms sample would flood the histogram and dilute the p95
      downward, masking the exact checkout-contention storm this signal exists to
      catch. Mirrors the `Telemetry.Metrics` distribution in `ScaleMetrics`, which
      likewise skips a datapoint when the measurement is absent.
    * **(b) fleet-wide Oban job discard/retry rate** — sourced from BOTH
      `[:oban, :job, :exception]` (Oban's own `Executor` emits this for a retryable
      failure, `meta.state == :failure`, AND an exhausted job that just converted to
      a terminal discard, `meta.state == :discard`, normalized from `:exhausted`) AND
      `[:oban, :job, :stop]` filtered to `meta.state in [:discard, :cancelled]`
      (review fix, MEDIUM): a DELIBERATE `{:discard, reason}` / bare `:discard` or
      `{:cancel, reason}` return — e.g. `ArticleEmbeddingWorker`/
      `MemoryEmbeddingWorker`'s own permanent-provider-error discard path — is
      terminal from its FIRST attempt and never touches `:exception` at all; only the
      `:stop` event covers it. Together the two attachments genuinely cover both
      halves of "discard/retry rate": every retryable failure/exhaustion (`:exception`)
      and every deliberate discard/cancel (`:stop`). `:success`/`:snoozed` `:stop`
      states are excluded. `oban_jobs` has no tenant dimension on either event (only
      bounded `worker`/`queue`/`state` labels, none of which we tag — the counter is a
      pure increment, mirroring `:under_fill_count`).
    * **(c) LLM/embedding provider-error rate** — sourced from the NEW
      `[:loopctl, :llm, :provider_error]` event (`Loopctl.TelemetryEvents.llm_provider_error/0`),
      emitted from the shared `Loopctl.Llm.Anthropic` HTTP client (every Anthropic
      call site — content extraction/classification/merge/memory-promotion — funnels
      through it) AND from `ArticleEmbeddingWorker`/`MemoryEmbeddingWorker`'s
      embedding-provider branch, both via `Loopctl.Llm.record_provider_error/2`, on a
      genuine provider failure. **Deliberately NOT `[:loopctl, :llm, :blocked]`**: that
      event fires when a tenant has no BYO key configured (a config state checked
      BEFORE any provider call), so windowing it as a provider-error proxy would
      false-page on keyless tenants while missing a real 429/5xx/transport storm
      entirely (see `Loopctl.Telemetry.ScaleMetrics`'s "AC-34.4.3 coordination" note).
      A single unconditional counter (`:provider_error_count`) mirrors
      `:under_fill_count`; the emit site alone decides transient vs permanent
      (`:class` metadata, unused by this counter, which windows total volume).

  All three plug into the exact same `step/8` / `step_p95/8` edge-fire helpers and
  `notify/7` delivery path — no new delivery code, no change to the existing three
  signals' behavior.

  ## Operator / system scope — NOT tenant-scoped

  This component is operator/system-scoped: it observes fleet-wide degradation, not a
  tenant action. It deliberately does NOT use the tenant-scoped
  `Loopctl.Webhooks.EventGenerator` (subscriptions, signing, per-tenant delivery
  tracking) — it reuses ONLY the `Loopctl.Webhooks.DeliveryBehaviour` DI for the raw
  HTTP POST.

  ## Test-env gate

  Started in prod (`:scale_alerts_enabled` true in `runtime.exs`); in `:test` it is NOT
  auto-started (default `false`) so the suite never runs background timers, owns the ETS
  table, or binds anything. Tests start it directly with a short window and drive
  `evaluate/0`.
  """
  use GenServer

  @behaviour Loopctl.Telemetry.ScaleAlerts.ConfigStatusBehaviour

  require Logger

  alias Loopctl.Telemetry.ScaleAlerts.Window
  alias Loopctl.Workers.ScaleAlertDeliveryWorker

  @table :loopctl_scale_alerts

  @handler_id __MODULE__
  @db_error_event [:loopctl, :db, :error]
  @under_fill_event [:loopctl, :knowledge, :vector_search, :under_fill]
  @heavy_read_event [:loopctl, :heavy_read_repo, :query]

  # US-34.3: the three additional signals.
  @repo_query_event [:loopctl, :repo, :query]
  @oban_exception_event [:oban, :job, :exception]
  # Review fix (MEDIUM): a deliberate `{:discard, reason}` / bare `:discard` return
  # (loopctl's OWN permanent-failure path, e.g. `ArticleEmbeddingWorker`/
  # `MemoryEmbeddingWorker` on a revoked key) — and an explicit `{:cancel, reason}` —
  # is emitted by Oban's Executor as `[:oban, :job, :stop]` with `state: :discard` /
  # `:cancelled`, NEVER `[:oban, :job, :exception]` (that event is reserved for
  # `:failure`/`:exhausted`). Without this, a mass permanent-discard storm (e.g. a
  # revoked/invalid provider key) increments NOTHING on this "discard rate" signal.
  @oban_stop_event [:oban, :job, :stop]
  @provider_error_event [:loopctl, :llm, :provider_error]

  # The latency buckets — the SAME bounded set as the ScaleMetrics histogram so the
  # bucket-based p95 here matches what Prometheus' histogram_quantile would report. A
  # value above the last bound lands in the implicit `+Inf` overflow bucket (index 9),
  # whose reported upper bound is the last finite bound (a conservative p95 estimate).
  @buckets [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
  @bucket_count length(@buckets)

  # Below this many latency samples in a window, p95 is statistical noise — skip it
  # rather than fire on one or two slow queries.
  @p95_min_samples 20

  @default_check_interval_ms 60_000
  # Documented threshold DEFAULTS (per-minute rates / ms). Tunable via config + env.
  @default_timeout_rate_per_min 5
  @default_p95_latency_ms 2_000
  @default_under_fill_rate_per_min 30

  # US-34.5 (AC-34.5.2): bounded periodic re-notify while a breach stays sustained.
  # Default 15 minutes; floored at 1 minute so a misconfigured near-zero value can't
  # turn re-notify into per-tick spam.
  @default_renotify_interval_ms 15 * 60_000
  @renotify_interval_floor_ms 60_000

  # US-34.3: documented DEFAULTS for the three additional signals.
  @default_queue_time_p95_ms 500
  @default_oban_discard_rate_per_min 10
  @default_provider_error_rate_per_min 10

  @metrics %{
    timeout: "db_statement_timeout_rate",
    p95: "heavy_read_p95_latency_ms",
    under_fill: "under_fill_rate",
    queue_time_p95: "repo_queue_time_p95_ms",
    oban_discard_rate: "oban_discard_rate",
    provider_error_rate: "provider_error_rate"
  }

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: name(opts))

  @doc """
  Synchronously evaluate the current window: read+reset counters, compare to thresholds,
  fire (edge-triggered) on any new breach. Returns `:ok`. Exposed so tests drive the
  firing path deterministically with no sleeping.
  """
  @spec evaluate(GenServer.server()) :: :ok
  def evaluate(server \\ __MODULE__), do: GenServer.call(server, :evaluate)

  @doc "The latency buckets (ms) used for the bucketed p95 (matches the histogram)."
  @spec buckets() :: [pos_integer()]
  def buckets, do: @buckets

  # --- Config accessors (documented defaults) ---

  @doc "Periodic check interval in ms (`:scale_alert_check_interval_ms`, default 60_000)."
  @spec check_interval_ms() :: pos_integer()
  def check_interval_ms,
    do: Application.get_env(:loopctl, :scale_alert_check_interval_ms, @default_check_interval_ms)

  @doc """
  The tumbling-window length in ms (`:scale_alert_window_ms`). Defaults to the check
  interval — each `:evaluate` covers exactly the events since the previous one. Used to
  convert counts into per-minute rates and to report `window_seconds` in the payload.
  """
  @spec window_ms() :: pos_integer()
  def window_ms, do: Application.get_env(:loopctl, :scale_alert_window_ms, check_interval_ms())

  @doc """
  Bounded periodic re-notify interval in ms while a breach remains sustained
  (`:scale_alert_renotify_interval_ms`, default #{@default_renotify_interval_ms} = 15
  min). Floored at #{@renotify_interval_floor_ms}ms (AC-34.5.2) so an operator
  misconfiguration can't turn re-notify into per-tick alert spam.
  """
  @spec renotify_interval_ms() :: pos_integer()
  def renotify_interval_ms do
    configured =
      Application.get_env(
        :loopctl,
        :scale_alert_renotify_interval_ms,
        @default_renotify_interval_ms
      )

    max(configured, @renotify_interval_floor_ms)
  end

  @doc "Timeout-rate threshold (timeouts/min, `:scale_alert_timeout_rate_per_min`)."
  @spec timeout_rate_threshold() :: number()
  def timeout_rate_threshold,
    do:
      Application.get_env(
        :loopctl,
        :scale_alert_timeout_rate_per_min,
        @default_timeout_rate_per_min
      )

  @doc "p95 heavy-read latency threshold (ms, `:scale_alert_p95_latency_ms`)."
  @spec p95_latency_threshold() :: number()
  def p95_latency_threshold,
    do: Application.get_env(:loopctl, :scale_alert_p95_latency_ms, @default_p95_latency_ms)

  @doc "Under-fill rate threshold (events/min, `:scale_alert_under_fill_rate_per_min`)."
  @spec under_fill_rate_threshold() :: number()
  def under_fill_rate_threshold,
    do:
      Application.get_env(
        :loopctl,
        :scale_alert_under_fill_rate_per_min,
        @default_under_fill_rate_per_min
      )

  @doc """
  Repo checkout `queue_time` p95 threshold (ms, `:scale_alert_queue_time_p95_ms`,
  US-34.3 AC-34.3.1).
  """
  @spec queue_time_p95_threshold() :: number()
  def queue_time_p95_threshold,
    do:
      Application.get_env(
        :loopctl,
        :scale_alert_queue_time_p95_ms,
        @default_queue_time_p95_ms
      )

  @doc """
  Fleet-wide Oban job discard/retry-exception rate threshold (events/min,
  `:scale_alert_oban_discard_rate_per_min`, US-34.3 AC-34.3.2).
  """
  @spec oban_discard_rate_threshold() :: number()
  def oban_discard_rate_threshold,
    do:
      Application.get_env(
        :loopctl,
        :scale_alert_oban_discard_rate_per_min,
        @default_oban_discard_rate_per_min
      )

  @doc """
  LLM/embedding provider-error rate threshold (events/min,
  `:scale_alert_provider_error_rate_per_min`, US-34.3 AC-34.3.3).
  """
  @spec provider_error_rate_threshold() :: number()
  def provider_error_rate_threshold,
    do:
      Application.get_env(
        :loopctl,
        :scale_alert_provider_error_rate_per_min,
        @default_provider_error_rate_per_min
      )

  @doc "The operator webhook URL (`:scale_alert_webhook_url`), or `nil` (alerting off)."
  @spec webhook_url() :: String.t() | nil
  def webhook_url, do: Application.get_env(:loopctl, :scale_alert_webhook_url)

  @doc """
  Pure config-guard (US-32.4): validates that a webhook URL is configured whenever
  scale alerts are enabled. A misconfigured deploy (`scale_alerts_enabled: true` with no
  `SCALE_ALERT_WEBHOOK_URL`) silently disables the firing path — the breach is only
  logged, never delivered — so an operator believes alerting is on when it is not. This
  function is the pure guard surfaced by `Loopctl.HealthCheck.Default` so a misconfigured
  deploy fails a READINESS signal (readiness-flag approach, NOT a boot-raise: raising in
  `runtime.exs` could take a live fleet down on a bad deploy).

  IMPORTANT (post-review correction): this guard does NOT flip `/health`'s top-level
  `status` — `fly.toml` wires plain `GET /health` as the CONTINUOUS load-balancer
  liveness check (10s interval, `min_machines_running: 1`), not a deploy-only smoke
  probe, so coupling a benign config-only concern to it would let a missing webhook URL
  depool an otherwise-healthy fleet. Instead it is surfaced as `checks.scale_alerts` /
  `reasons.scale_alerts` (visible, non-blocking for routing) AND folded into the
  separate `ready` field that only `GET /health/ready` acts on — a genuine deploy-time
  smoke gate, distinct from the liveness probe. See `Loopctl.HealthCheck.Default`.

  Takes config as ARGS (not read internally) so it is unit-testable without
  `Application.put_env`. Blank (empty/whitespace-only, or any non-binary) URLs are
  treated as unset. The error reason names the env var only — never a URL value (no
  secret is logged).
  """
  @spec config_status(boolean(), String.t() | nil) :: :ok | {:error, String.t()}
  def config_status(false, _url), do: :ok

  def config_status(true, url) do
    if blank?(url) do
      {:error, "scale alerts enabled but SCALE_ALERT_WEBHOOK_URL is not set"}
    else
      :ok
    end
  end

  @doc "Zero-arg convenience: `config_status/2` fed from the live app env."
  @impl Loopctl.Telemetry.ScaleAlerts.ConfigStatusBehaviour
  @spec config_status() :: :ok | {:error, String.t()}
  def config_status do
    config_status(Application.get_env(:loopctl, :scale_alerts_enabled, false), webhook_url())
  end

  defp blank?(nil), do: true
  defp blank?(url) when is_binary(url), do: String.trim(url) == ""

  # Fail-safe catch-all: a non-nil, non-binary config value (e.g. a charlist or atom
  # from a config typo) is treated as unset rather than raising — `check_scale_alerts/0`
  # in `Loopctl.HealthCheck.Default` must degrade cleanly, never crash the endpoint.
  defp blank?(_other), do: true

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)

    # Trap exits so `terminate/2` runs on a supervised shutdown and DETACHES the global
    # telemetry handlers. Without this, a stopped instance leaves zombie handlers attached
    # that keep firing on the global scale events into a now-deleted ETS table (each
    # raises → is rescued → logged) — harmless to correctness but noisy, and a per-test
    # handler/table leak in the suite.
    Process.flag(:trap_exit, true)

    # Owned by this process; public + write_concurrency so the request-path handlers
    # write via :ets.update_counter without touching this GenServer.
    ^table =
      :ets.new(table, [
        :set,
        :named_table,
        :public,
        write_concurrency: true,
        read_concurrency: true
      ])

    reset_counters(table)
    attach_handlers(table)

    # No work in init beyond table creation; schedule the first tick out of band.
    schedule_tick()

    {:ok,
     %{
       table: table,
       # The operator webhook URL: an optional per-instance override (so a test can drive
       # the nil-url log-only path without mutating global app env), defaulting to the
       # configured `:scale_alert_webhook_url`. Resolved ONCE at init — a URL change needs
       # a restart, which is fine for an operator config.
       webhook_url: Keyword.get(opts, :webhook_url, webhook_url()),
       # US-34.5: clock seam. Defaults to a real monotonic-ms clock; tests inject a
       # per-instance override (mirrors `webhook_url` above) so the re-notify interval
       # can be crossed deterministically without sleeping or mutating global config.
       now_fn: Keyword.get(opts, :now_fn, &default_now/0),
       # US-34.5 (AC-34.5.2): an optional per-instance override of the bounded re-notify
       # interval, same pattern as `webhook_url`/`now_fn` — lets a test cross the
       # interval quickly. Defaults to the (floored) configured value.
       renotify_interval_ms: Keyword.get(opts, :renotify_interval_ms, renotify_interval_ms()),
       # Test seam (same pattern as `webhook_url`/`now_fn`): the function used to durably
       # enqueue a `ScaleAlertDeliveryWorker` job. Defaults to `Oban.insert/1`. Lets a test
       # deterministically simulate an enqueue failure (`{:error, _}`) or a raised
       # connection error WITHOUT touching the real DB pool, to prove `last_notified_at`
       # is only advanced on a genuine `{:ok, _}` enqueue (review fix, US-34.5).
       insert_fn: Keyword.get(opts, :insert_fn, &Oban.insert/1),
       # Per-metric breach state for the edge-triggered fire + bounded re-notify
       # (US-34.5): `breaching?` false = armed; `last_notified_at` is the clock value
       # (per `now_fn`) of the last delivered notification, `nil` while armed.
       breaching: %{
         timeout: %{breaching?: false, last_notified_at: nil},
         p95: %{breaching?: false, last_notified_at: nil},
         under_fill: %{breaching?: false, last_notified_at: nil},
         queue_time_p95: %{breaching?: false, last_notified_at: nil},
         oban_discard_rate: %{breaching?: false, last_notified_at: nil},
         provider_error_rate: %{breaching?: false, last_notified_at: nil}
       }
     }}
  end

  @impl true
  def handle_call(:evaluate, _from, state) do
    {:reply, :ok, do_evaluate(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_evaluate(state)
    schedule_tick()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{table: table}) do
    # Detach so a restarted instance re-attaches cleanly (attach is idempotent anyway).
    _ = :telemetry.detach(handler_id(table))
    :ok
  end

  # --- Telemetry attach (idempotent, per-table handler id) ---

  defp attach_handlers(table) do
    events = [
      @db_error_event,
      @under_fill_event,
      @heavy_read_event,
      @repo_query_event,
      @oban_exception_event,
      @oban_stop_event,
      @provider_error_event
    ]

    case :telemetry.attach_many(handler_id(table), events, &__MODULE__.handle_event/4, %{
           table: table
         }) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  # Per-table handler id so a test instance with its own table does not collide with the
  # prod instance's boot-attached handler.
  defp handler_id(@table), do: @handler_id
  defp handler_id(table), do: {@handler_id, table}

  @doc false
  # The request-path handlers: cheap, atomic ETS counter writes, self-rescuing so a
  # raise can NEVER break the request being observed (mirrors SlowQueryLogger).
  def handle_event(@db_error_event, _measurements, metadata, %{table: table}) do
    if Map.get(metadata, :mapped_code) == "db_statement_timeout" do
      :ets.update_counter(table, :timeout_count, 1)
    end

    :ok
  rescue
    e ->
      Logger.error("ScaleAlerts db_error handler error: #{Exception.message(e)}")
      :ok
  end

  def handle_event(@under_fill_event, _measurements, _metadata, %{table: table}) do
    :ets.update_counter(table, :under_fill_count, 1)
    :ok
  rescue
    e ->
      Logger.error("ScaleAlerts under_fill handler error: #{Exception.message(e)}")
      :ok
  end

  def handle_event(@heavy_read_event, measurements, _metadata, %{table: table}) do
    total_native = Map.get(measurements, :total_time, 0)
    duration_ms = System.convert_time_unit(total_native, :native, :millisecond)
    idx = bucket_index(duration_ms)

    :ets.update_counter(table, {:lat_bucket, idx}, 1)
    :ets.update_counter(table, :lat_total, 1)
    :ok
  rescue
    e ->
      Logger.error("ScaleAlerts heavy_read handler error: #{Exception.message(e)}")
      :ok
  end

  # US-34.3 (AC-34.3.1): mirrors the `@heavy_read_event` clause, but reads
  # `measurements.queue_time` (Ecto's per-query connection-checkout wait, native
  # units) and writes to a SEPARATE bucket set (`{:qt_bucket, idx}` / `:qt_total`) so
  # it never collides with the heavy-read histogram.
  #
  # Review fix (HIGH): `queue_time` is DROPPED by Ecto's own `log_measurements/3`
  # (`deps/ecto_sql/lib/ecto/adapters/sql.ex`) whenever the connection was already
  # checked out — i.e. every statement inside a transaction after the first checkout.
  # loopctl runs virtually every tenant query inside a transaction (RLS `SET LOCAL`
  # per CLAUDE.md), so the majority of these events carry NO `:queue_time` key at
  # all (absent, not `nil`). Defaulting the absent case to `0` (the prior behavior)
  # floods the histogram with synthetic 0ms samples and biases the bucketed p95
  # sharply downward — during a real checkout-contention storm (the leading
  # indicator AC-34.3.1 exists to surface), genuinely-high-queue_time samples can be
  # a small minority, so the diluted p95 may never cross the threshold. Skip the
  # sample entirely when `:queue_time` is absent — mirroring `Loopctl.Telemetry.
  # ScaleMetrics`'s `Telemetry.Metrics` distribution, which silently skips a
  # datapoint when its measurement key is absent — instead of counting a phantom 0ms
  # checkout.
  def handle_event(@repo_query_event, measurements, _metadata, %{table: table}) do
    case Map.fetch(measurements, :queue_time) do
      :error ->
        :ok

      {:ok, total_native} ->
        duration_ms = System.convert_time_unit(total_native, :native, :millisecond)
        idx = bucket_index(duration_ms)

        :ets.update_counter(table, {:qt_bucket, idx}, 1)
        :ets.update_counter(table, :qt_total, 1)
        :ok
    end
  rescue
    e ->
      Logger.error("ScaleAlerts repo_query handler error: #{Exception.message(e)}")
      :ok
  end

  # US-34.3 (AC-34.3.2): fleet-wide Oban job discard/retry rate, half (a). Oban's own
  # Executor emits `[:oban, :job, :exception]` for a retryable failure AND an
  # exhausted job converting to a terminal discard — no metadata filtering, mirrors
  # `:under_fill_count`. See the `@oban_stop_event` clause below for half (b): a
  # DELIBERATE discard/cancel, which this event never observes.
  def handle_event(@oban_exception_event, _measurements, _metadata, %{table: table}) do
    :ets.update_counter(table, :oban_discard_count, 1)
    :ok
  rescue
    e ->
      Logger.error("ScaleAlerts oban_exception handler error: #{Exception.message(e)}")
      :ok
  end

  # Review fix (MEDIUM, AC-34.3.2): the sibling half of the discard signal — a
  # deliberate `{:discard, _}`/bare `:discard` or `{:cancel, _}` job return emits
  # `[:oban, :job, :stop]` (`meta.state` `:discard` / `:cancelled`), never the
  # `:exception` event above. Only these two terminal, non-retryable states count;
  # `:success` and `:snoozed` (the OTHER `:stop` states) are explicitly excluded.
  def handle_event(@oban_stop_event, _measurements, %{state: state}, %{table: table})
      when state in [:discard, :cancelled] do
    :ets.update_counter(table, :oban_discard_count, 1)
    :ok
  rescue
    e ->
      Logger.error("ScaleAlerts oban_stop handler error: #{Exception.message(e)}")
      :ok
  end

  # US-34.3 (AC-34.3.3): genuine LLM/embedding provider-error rate, sourced from the
  # NEW `[:loopctl, :llm, :provider_error]` event (emitted from exactly one choke
  # point, `Loopctl.Llm.record_provider_error/2`) — deliberately NOT
  # `[:loopctl, :llm, :blocked]` (a missing-key config signal, not a provider-error
  # one; see the moduledoc). A single unconditional counter mirrors `:under_fill_count`.
  def handle_event(@provider_error_event, _measurements, _metadata, %{table: table}) do
    :ets.update_counter(table, :provider_error_count, 1)
    :ok
  rescue
    e ->
      Logger.error("ScaleAlerts provider_error handler error: #{Exception.message(e)}")
      :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # --- Window evaluation + edge-triggered firing + bounded re-notify (US-34.5) ---

  defp do_evaluate(
         %{
           table: table,
           breaching: breaching,
           webhook_url: url,
           now_fn: now_fn,
           renotify_interval_ms: renotify_interval,
           insert_fn: insert_fn
         } = state
       ) do
    window = read_and_reset(table)
    window_min = window_minutes()

    timeout_rate = window.timeout_count / window_min
    under_fill_rate = window.under_fill_count / window_min
    p95 = p95_from_buckets(window.lat_total, window.buckets)

    # US-34.3: the three additional signals, computed the SAME way as their siblings.
    queue_time_p95 = p95_from_buckets(window.qt_total, window.qt_buckets)
    oban_discard_rate = window.oban_discard_count / window_min
    provider_error_rate = window.provider_error_count / window_min

    # A single clock read per evaluate: every metric in this tick is judged against the
    # SAME "now", so two metrics breaching in the same window re-notify in lockstep.
    now = now_fn.()

    breaching =
      breaching
      |> step(
        :timeout,
        timeout_rate,
        timeout_rate_threshold(),
        url,
        now,
        renotify_interval,
        insert_fn
      )
      |> step(
        :under_fill,
        under_fill_rate,
        under_fill_rate_threshold(),
        url,
        now,
        renotify_interval,
        insert_fn
      )
      |> step_p95(:p95, p95, p95_latency_threshold(), url, now, renotify_interval, insert_fn)
      |> step(
        :oban_discard_rate,
        oban_discard_rate,
        oban_discard_rate_threshold(),
        url,
        now,
        renotify_interval,
        insert_fn
      )
      |> step(
        :provider_error_rate,
        provider_error_rate,
        provider_error_rate_threshold(),
        url,
        now,
        renotify_interval,
        insert_fn
      )
      |> step_p95(
        :queue_time_p95,
        queue_time_p95,
        queue_time_p95_threshold(),
        url,
        now,
        renotify_interval,
        insert_fn
      )

    %{state | breaching: breaching}
  end

  # Edge-triggered fire on the transition false -> true; while sustained (still over
  # threshold), re-fire once `renotify_interval` has elapsed since the last
  # notification (AC-34.5.2), otherwise stay debounced. Re-arms (clears
  # `last_notified_at`) on the transition back under threshold (AC-34.5.3: WHICH
  # breaches fire is unchanged — only the sustained-breach behavior is new).
  #
  # Review fix (US-34.5): `notify/7` only returns `now` when the alert was ACTUALLY
  # delivered/durably enqueued (`deliver/3` -> `:ok`); otherwise it returns `fallback`
  # unchanged. A dropped enqueue (Oban.insert returns `{:error, _}` or raises) must NOT
  # be recorded as a successful notification — doing so would advance `last_notified_at`
  # to `now` and silence the sustained breach for a full `renotify_interval` even though
  # nobody was actually paged. Instead we keep the PRIOR `last_notified_at` (via
  # `notify/7`'s `fallback`) so the very next `:evaluate` retries the enqueue rather than
  # waiting out the interval.
  defp step(breaching, metric, value, threshold, url, now, renotify_interval, insert_fn) do
    %{breaching?: was_breaching?, last_notified_at: last_notified_at} =
      Map.fetch!(breaching, metric)

    over? = value > threshold

    cond do
      over? and not was_breaching? ->
        last_notified_at = notify(metric, value, threshold, url, insert_fn, now, nil)
        Map.put(breaching, metric, %{breaching?: true, last_notified_at: last_notified_at})

      over? and renotify_due?(last_notified_at, now, renotify_interval) ->
        last_notified_at = notify(metric, value, threshold, url, insert_fn, now, last_notified_at)
        Map.put(breaching, metric, %{breaching?: true, last_notified_at: last_notified_at})

      over? ->
        # sustained breach, re-notify interval not yet elapsed — debounced
        breaching

      true ->
        Map.put(breaching, metric, %{breaching?: false, last_notified_at: nil})
    end
  end

  # `nil` while still breaching means the metric was NEVER successfully notified (its
  # edge-trigger or a prior renotify attempt had its enqueue dropped) — retry on the very
  # NEXT evaluate rather than waiting out a full interval that was never actually served.
  defp renotify_due?(nil, _now, _renotify_interval), do: true

  defp renotify_due?(last_notified_at, now, renotify_interval),
    do: now - last_notified_at >= renotify_interval

  # p95 is `nil` when below the sample floor — treat as "not breaching" and re-arm so a
  # quiet window clears the breach state (a later busy window can fire again). Takes
  # `metric` as an explicit arg (US-34.3) so the SAME helper serves both the
  # heavy-read p95 (`:p95`) and the repo checkout queue_time p95 (`:queue_time_p95`).
  defp step_p95(breaching, metric, nil, _threshold, _url, _now, _renotify_interval, _insert_fn),
    do: Map.put(breaching, metric, %{breaching?: false, last_notified_at: nil})

  defp step_p95(breaching, metric, p95, threshold, url, now, renotify_interval, insert_fn),
    do: step(breaching, metric, p95, threshold, url, now, renotify_interval, insert_fn)

  # Fires the alert and stamps `last_notified_at` to `now` ONLY on a genuine successful
  # delivery/enqueue; otherwise keeps `fallback` (either `nil` for a never-notified edge
  # fire, or the previous notification's timestamp for a failed renotify attempt) so the
  # breach stays "due" and is retried on the next tick instead of going silent.
  defp notify(metric, value, threshold, url, insert_fn, now, fallback) do
    payload = %{
      alert: "scale_degradation",
      metric: Map.fetch!(@metrics, metric),
      value: round_value(value),
      threshold: threshold,
      window_seconds: div(window_ms(), 1000),
      at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    if deliver(payload, url, insert_fn) == :ok, do: now, else: fallback
  end

  # AC-34.5.4: no URL configured → alerting is OFF. This stays a SYNCHRONOUS log-only
  # no-op — never enqueue when the URL is nil (US-32.4 readiness guard unchanged).
  defp deliver(payload, nil, _insert_fn) do
    Logger.warning(
      "scale alert (no webhook configured): #{payload.metric}=#{payload.value} " <>
        "> threshold #{payload.threshold} over #{payload.window_seconds}s"
    )

    :ok
  end

  # AC-34.5.1: durable delivery — enqueue through Oban's `:webhooks` queue instead of
  # POSTing synchronously in-process, so a transient failure retries with Oban's
  # backoff (`ScaleAlertDeliveryWorker`) rather than being logged-and-dropped.
  #
  # Review fix (secrets-at-rest): the job args carry ONLY the id-only `payload` — never
  # `url`. The webhook URL is commonly secret-bearing (Slack/PagerDuty routing tokens),
  # and Oban persists job args as cleartext JSON in `oban_jobs` with no encryption
  # plugin configured; `Oban.Plugins.Pruner` then retains terminal jobs for 7 days. That
  # would leak the URL into the DB, every backup, the Oban Web dashboard, and any Oban
  # telemetry/APM consumer. `ScaleAlertDeliveryWorker.perform/1` re-resolves the URL from
  # `ScaleAlerts.webhook_url/0` (the SAME resolve-once operator config this GenServer
  # already reads at `init/1`) instead, mirroring the sibling `WebhookDeliveryWorker`
  # pattern of never persisting a secret in `args`.
  #
  # Review fix: `insert_fn.(job)` (default `Oban.insert/1`, `Repo.insert/1` underneath)
  # can RAISE (e.g. `DBConnection.ConnectionError` on pool exhaustion / DB down) rather
  # than returning `{:error, _}` — it only returns an error tuple for changeset
  # validation failures. `do_evaluate/1` runs inside `handle_call(:evaluate)` /
  # `handle_info(:tick)`, which are NOT rescue-wrapped (unlike the request-path
  # `handle_event/4` telemetry handlers), so an unrescued raise here would crash the
  # GenServer and discard all breach/re-notify state on restart. Rescue here, log, and
  # report `:error` like any other dropped enqueue — the caller (`notify/7`) already
  # treats that as "not notified" and retries on the next tick.
  defp deliver(payload, url, insert_fn) when is_binary(url) do
    job = %{payload: payload} |> ScaleAlertDeliveryWorker.new()

    case insert_fn.(job) do
      {:ok, _job} ->
        Logger.info("scale alert enqueued for delivery: #{payload.metric}=#{payload.value}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "scale alert enqueue failed (#{inspect(reason)}): #{payload.metric}=#{payload.value}"
        )

        :error
    end
  rescue
    e ->
      Logger.error(
        "scale alert enqueue raised (#{Exception.message(e)}): #{payload.metric}=#{payload.value}"
      )

      :error
  end

  # Review fix: a non-nil, non-binary `:scale_alert_webhook_url` (e.g. a charlist/atom
  # from a config typo) matched neither the `nil` clause above nor the `is_binary(url)`
  # clause, so `notify/7` raised a `FunctionClauseError` OUTSIDE the `deliver/3` rescue —
  # that raise then propagated out of `handle_call(:evaluate)`/`handle_info(:tick)`
  # (neither rescue-wrapped) and crashed the GenServer, discarding breach/re-notify
  # state. This mirrors the module's own defensive `blank?/1` catch-all (line ~263):
  # treat a malformed URL as a config error, not an unset URL — log and report `:error`
  # so `notify/7` keeps the prior `last_notified_at` and retries on the next tick,
  # exactly like a dropped enqueue.
  defp deliver(payload, url, _insert_fn) do
    Logger.error(
      "scale alert webhook url misconfigured (expected a string or nil, got #{inspect(url)}): " <>
        "#{payload.metric}=#{payload.value} treated as a failed delivery"
    )

    :error
  end

  # --- Counter table helpers ---

  defp reset_counters(table) do
    :ets.insert(table, [
      {:timeout_count, 0},
      {:under_fill_count, 0},
      {:lat_total, 0},
      # US-34.3: the three additional signals' scalar counters.
      {:qt_total, 0},
      {:oban_discard_count, 0},
      {:provider_error_count, 0}
    ])

    for idx <- 0..@bucket_count do
      :ets.insert(table, {{:lat_bucket, idx}, 0})
      # US-34.3: a SEPARATE bucket set for the repo checkout queue_time p95, so it
      # never collides with the heavy-read latency histogram above.
      :ets.insert(table, {{:qt_bucket, idx}, 0})
    end

    :ok
  end

  # Read + zero each window counter atomically (see `read_zero/2`). A tumbling window:
  # each evaluate consumes exactly the counts accrued since the previous evaluate, then
  # resets to 0. Reading the counters one-at-a-time (not in one giant atomic op) is fine —
  # a request-path increment that lands BETWEEN two counters' reads simply belongs to the
  # next window, which is the correct tumbling-window semantics.
  defp read_and_reset(table) do
    timeout_count = read_zero(table, :timeout_count)
    under_fill_count = read_zero(table, :under_fill_count)
    lat_total = read_zero(table, :lat_total)
    buckets = for idx <- 0..@bucket_count, do: read_zero(table, {:lat_bucket, idx})

    # US-34.3: the three additional signals.
    qt_total = read_zero(table, :qt_total)
    qt_buckets = for idx <- 0..@bucket_count, do: read_zero(table, {:qt_bucket, idx})
    oban_discard_count = read_zero(table, :oban_discard_count)
    provider_error_count = read_zero(table, :provider_error_count)

    %Window{
      timeout_count: timeout_count,
      under_fill_count: under_fill_count,
      lat_total: lat_total,
      buckets: buckets,
      qt_total: qt_total,
      qt_buckets: qt_buckets,
      oban_discard_count: oban_discard_count,
      provider_error_count: provider_error_count
    }
  end

  # Atomic read-and-zero in a SINGLE `update_counter` (so a request-path handler's
  # increment can never be lost between a separate read and a separate reset). The op
  # LIST is applied atomically and returns one result per op:
  #
  #   * `{2, 0}` — add 0 to position 2; returns the current value V.
  #   * `{2, 0, 0, 0}` — `{pos, incr, threshold, setval}`: add 0 (still V), and because
  #     V >= 0 satisfies the `>= threshold(0)` clause, RESET it to `setval(0)`.
  #
  # The whole list runs under ETS's per-key lock, so the value read by op 1 is exactly
  # the value zeroed by op 2 — no increment in between is dropped. We keep op 1's result
  # (the pre-reset count) and discard op 2's (always 0).
  defp read_zero(table, key) do
    [value, _zeroed] = :ets.update_counter(table, key, [{2, 0}, {2, 0, 0, 0}])
    value
  end

  # --- p95 from buckets (cumulative crossing of the 95th percentile) ---

  # Takes the total sample count + bucket list as explicit args (US-34.3) so the SAME
  # helper serves both the heavy-read latency histogram and the repo checkout
  # queue_time histogram (a separate counter set, same layout).
  defp p95_from_buckets(total, _buckets) when total < @p95_min_samples, do: nil

  defp p95_from_buckets(total, buckets) do
    target = total * 0.95
    cumulative_cross(buckets, target, 0, 0)
  end

  # Walk buckets accumulating counts; the FIRST bucket whose cumulative count reaches the
  # 95% target gives the p95 estimate as that bucket's upper bound. The overflow bucket
  # (index == @bucket_count) reports the last finite bound (conservative).
  defp cumulative_cross([count | rest], target, acc, idx) do
    acc = acc + count

    if acc >= target do
      bucket_upper_bound(idx)
    else
      cumulative_cross(rest, target, acc, idx + 1)
    end
  end

  defp cumulative_cross([], _target, _acc, _idx), do: bucket_upper_bound(@bucket_count)

  # Bucket index for a duration: first bucket whose finite upper bound is >= ms, else the
  # overflow bucket (@bucket_count).
  defp bucket_index(ms), do: bucket_index(ms, @buckets, 0)
  defp bucket_index(ms, [bound | _], idx) when ms <= bound, do: idx
  defp bucket_index(ms, [_ | rest], idx), do: bucket_index(ms, rest, idx + 1)
  defp bucket_index(_ms, [], idx), do: idx

  # The reported upper bound for a bucket index. The overflow bucket reports the last
  # finite bound (a conservative p95 — a breach is still surfaced by the timeout counter).
  defp bucket_upper_bound(idx) when idx < @bucket_count, do: Enum.at(@buckets, idx)
  defp bucket_upper_bound(_overflow), do: List.last(@buckets)

  # --- misc ---

  defp window_minutes do
    # Avoid a divide-by-zero and absurd rates from a sub-second window.
    max(window_ms() / 60_000, 1.0e-6)
  end

  defp round_value(value) when is_float(value), do: Float.round(value, 2)
  defp round_value(value), do: value

  defp schedule_tick, do: Process.send_after(self(), :tick, check_interval_ms())

  # Real clock for the `now_fn` seam (US-34.5): monotonic ms — immune to wall-clock
  # adjustments and cheap to call every evaluate.
  defp default_now, do: System.monotonic_time(:millisecond)

  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)
end
