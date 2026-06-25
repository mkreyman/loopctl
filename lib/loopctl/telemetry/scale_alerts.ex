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
    4. **edge-triggered DEBOUNCE**: per-metric breach state is held in the GenServer; an
       alert FIRES only on the transition INTO breach, not every interval while a breach
       is sustained (avoids alert spam). The metric re-arms (can fire again) once it
       clears back below threshold.

  On a firing breach the alert is an id-only map — `%{alert, metric, value, threshold,
  window_seconds, at}` — JSON-encoded and POSTed via the webhook delivery DI
  (`Application.get_env(:loopctl, :webhook_delivery, Loopctl.Webhooks.ReqDelivery)`, the
  SAME key the webhook worker uses) to `:scale_alert_webhook_url`. **No tenant content,
  vectors, bodies, params, or SQL ever appears in the payload.** When the URL is `nil`
  alerting is OFF (opt-in): the breach is logged at `:warning` and nothing is POSTed. A
  delivery `{:error, _}` is logged, never raised.

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

  require Logger

  alias Loopctl.Telemetry.ScaleAlerts.Window

  @table :loopctl_scale_alerts

  @handler_id __MODULE__
  @db_error_event [:loopctl, :db, :error]
  @under_fill_event [:loopctl, :knowledge, :vector_search, :under_fill]
  @heavy_read_event [:loopctl, :heavy_read_repo, :query]

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

  @metrics %{
    timeout: "db_statement_timeout_rate",
    p95: "heavy_read_p95_latency_ms",
    under_fill: "under_fill_rate"
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

  @doc "The operator webhook URL (`:scale_alert_webhook_url`), or `nil` (alerting off)."
  @spec webhook_url() :: String.t() | nil
  def webhook_url, do: Application.get_env(:loopctl, :scale_alert_webhook_url)

  # The webhook delivery client — the SAME DI key the webhook worker uses, so the test
  # mock applies. Operator/system-scoped: only the DeliveryBehaviour POST is reused, NOT
  # the tenant-scoped EventGenerator.
  defp delivery_client,
    do: Application.get_env(:loopctl, :webhook_delivery, Loopctl.Webhooks.ReqDelivery)

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
       # per-metric breach flags for the edge-triggered debounce (false = armed).
       breaching: %{timeout: false, p95: false, under_fill: false}
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
    events = [@db_error_event, @under_fill_event, @heavy_read_event]

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

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # --- Window evaluation + edge-triggered firing ---

  defp do_evaluate(%{table: table, breaching: breaching, webhook_url: url} = state) do
    window = read_and_reset(table)
    window_min = window_minutes()

    timeout_rate = window.timeout_count / window_min
    under_fill_rate = window.under_fill_count / window_min
    p95 = p95_from_buckets(window)

    breaching =
      breaching
      |> step(:timeout, timeout_rate, timeout_rate_threshold(), url)
      |> step(:under_fill, under_fill_rate, under_fill_rate_threshold(), url)
      |> step_p95(p95, p95_latency_threshold(), url)

    %{state | breaching: breaching}
  end

  # Edge-triggered: fire only on the transition false -> true; re-arm on true -> false.
  defp step(breaching, metric, value, threshold, url) do
    over? = value > threshold

    cond do
      over? and not breaching[metric] ->
        fire(metric, value, threshold, url)
        Map.put(breaching, metric, true)

      not over? ->
        Map.put(breaching, metric, false)

      true ->
        # sustained breach — debounced, do not re-fire
        breaching
    end
  end

  # p95 is `nil` when below the sample floor — treat as "not breaching" and re-arm so a
  # quiet window clears the breach state (a later busy window can fire again).
  defp step_p95(breaching, nil, _threshold, _url), do: Map.put(breaching, :p95, false)
  defp step_p95(breaching, p95, threshold, url), do: step(breaching, :p95, p95, threshold, url)

  defp fire(metric, value, threshold, url) do
    payload = %{
      alert: "scale_degradation",
      metric: Map.fetch!(@metrics, metric),
      value: round_value(value),
      threshold: threshold,
      window_seconds: div(window_ms(), 1000),
      at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    deliver(payload, url)
  end

  defp deliver(payload, url) do
    case url do
      nil ->
        # Opt-in: no URL configured → log the breach, POST nothing.
        Logger.warning(
          "scale alert (no webhook configured): #{payload.metric}=#{payload.value} " <>
            "> threshold #{payload.threshold} over #{payload.window_seconds}s"
        )

        :ok

      url ->
        body = Jason.encode!(payload)
        headers = [{"content-type", "application/json"}]

        case delivery_client().deliver(url, body, headers) do
          {:ok, _resp} ->
            Logger.info("scale alert delivered: #{payload.metric}=#{payload.value}")
            :ok

          {:error, reason} ->
            Logger.warning(
              "scale alert delivery failed (#{inspect(reason)}): #{payload.metric}=#{payload.value}"
            )

            :ok
        end
    end
  end

  # --- Counter table helpers ---

  defp reset_counters(table) do
    :ets.insert(table, [{:timeout_count, 0}, {:under_fill_count, 0}, {:lat_total, 0}])

    for idx <- 0..@bucket_count, do: :ets.insert(table, {{:lat_bucket, idx}, 0})

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

    %Window{
      timeout_count: timeout_count,
      under_fill_count: under_fill_count,
      lat_total: lat_total,
      buckets: buckets
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

  defp p95_from_buckets(%Window{lat_total: lat_total}) when lat_total < @p95_min_samples, do: nil

  defp p95_from_buckets(%Window{lat_total: lat_total, buckets: buckets}) do
    target = lat_total * 0.95
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

  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)
end
