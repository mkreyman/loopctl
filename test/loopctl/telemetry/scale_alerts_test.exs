defmodule Loopctl.Telemetry.ScaleAlertsTest do
  @moduledoc """
  US-27.15 / TC-27.15.2 (AC-27.15.2): the FIRING alert path actually FIRES.

  This is the test the R2 round exists to add — the prior "alert path" only documented
  PromQL rules that fly-metrics.net Grafana cannot run, so nothing fired. Here we drive
  the three scale signals THROUGH the real telemetry handlers, call `evaluate/0`
  synchronously, and prove:

    * a breach POSTs an id-only alert via the `:webhook_delivery` DI (the Mox mock),
      with the right metric, value, threshold, and NO leaked tenant/vector/SQL content;
    * under threshold → NO delivery;
    * the edge-triggered DEBOUNCE: a sustained breach does NOT re-fire on the next
      `evaluate/0`; after the metric clears, a fresh breach fires again;
    * the bucketed p95 honors its sample floor and crosses at the right bucket.

  US-34.5 extends this coverage: durable delivery via `Loopctl.Workers.ScaleAlertDeliveryWorker`
  (AC-34.5.1 — a delivery failure is Oban's `:failure` state, not a logged-and-dropped
  POST), bounded periodic re-notify while a breach stays sustained (AC-34.5.2), re-arm on
  clear (AC-34.5.3), and the nil-url path still never enqueues (AC-34.5.4).

  `async: false`: the handlers attach GLOBAL `:telemetry` listeners on the three scale
  events, so a concurrent async test issuing a real heavy-read / db-error would pollute
  this instance's window counters. Running serially keeps the counts deterministic. It
  also lets us use Mox GLOBAL mode so the alert POST (which happens INSIDE the ScaleAlerts
  process, not the test process) is allowed without per-pid `Mox.allow`.

  Config (config/test.exs, NO put_env in the body): `:webhook_delivery` →
  `Loopctl.MockDelivery`, a deterministic `:scale_alert_webhook_url`, a 60s window.
  Thresholds are set PER TEST through the start opts' env? No — thresholds read from app
  env; we choose event COUNTS relative to the documented defaults instead, so we never
  mutate global config.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Loopctl.Telemetry.ScaleAlerts
  alias Loopctl.TelemetryEvents
  alias Loopctl.Workers.ScaleAlertDeliveryWorker

  setup :set_mox_global
  setup :verify_on_exit!

  # Documented defaults (config.exs): timeouts 5/min, p95 2000ms, under-fill 30/min.
  # The test-env window is 60s, so a per-minute rate == the raw count in one window.

  setup do
    # A unique ETS table + name per test so instances never collide, and so the
    # per-table telemetry handler id is unique. Start under the test supervisor; stop on
    # exit (which detaches the handlers via terminate/2).
    table = :"scale_alerts_test_#{System.unique_integer([:positive])}"
    name = :"scale_alerts_srv_#{System.unique_integer([:positive])}"

    pid = start_supervised!({ScaleAlerts, table: table, name: name})

    # Default permissive stub (DataCase isn't used here — this is a plain ExUnit.Case),
    # so an unexpected deliver doesn't crash; tests that assert a POST override with
    # expect/3. Allowed in global mode for any process.
    stub(Loopctl.MockDelivery, :deliver, fn _url, _body, _headers ->
      {:ok, %{status: 200, body: "ok"}}
    end)

    %{server: name, pid: pid, table: table}
  end

  # --- helpers that drive the REAL handlers via :telemetry.execute ---

  defp emit_timeout(n) do
    for _ <- 1..n do
      :telemetry.execute(TelemetryEvents.db_error(), %{count: 1}, %{
        mapped_code: "db_statement_timeout",
        endpoint: :suggested_links,
        tenant_id: "t-123"
      })
    end
  end

  defp emit_non_timeout(n) do
    for _ <- 1..n do
      :telemetry.execute(TelemetryEvents.db_error(), %{count: 1}, %{
        mapped_code: "db_serialization_failure",
        endpoint: :suggested_links
      })
    end
  end

  defp emit_under_fill(n) do
    for _ <- 1..n do
      :telemetry.execute(TelemetryEvents.vector_search_under_fill(), %{requested: 10}, %{
        endpoint: :suggested_links,
        tenant_id: "t-123"
      })
    end
  end

  # Heavy-read latency in ms → native units the real heavy-read query event carries.
  defp emit_latency(ms, n) do
    native = System.convert_time_unit(ms, :millisecond, :native)

    for _ <- 1..n do
      :telemetry.execute([:loopctl, :heavy_read_repo, :query], %{total_time: native}, %{
        options: [endpoint: :semantic_search]
      })
    end
  end

  defp expect_delivery(test_pid) do
    expect(Loopctl.MockDelivery, :deliver, fn url, body, headers ->
      send(test_pid, {:alert_delivered, url, body, headers})
      {:ok, %{status: 200, body: "ok"}}
    end)
  end

  describe "firing on breach (AC-27.15.2)" do
    test "db_statement_timeout rate over threshold POSTs an id-only alert", %{server: server} do
      test_pid = self()
      expect_delivery(test_pid)

      # 6 timeouts in a 60s window = 6/min > the 5/min default threshold.
      emit_timeout(6)
      # non-timeout db errors must NOT count toward the timeout rate.
      emit_non_timeout(10)

      assert :ok = ScaleAlerts.evaluate(server)

      assert_received {:alert_delivered, url, body, headers}
      assert url == "https://alerts.test.invalid/scale"
      assert {"content-type", "application/json"} in headers

      payload = Jason.decode!(body)
      assert payload["alert"] == "scale_degradation"
      assert payload["metric"] == "db_statement_timeout_rate"
      assert payload["value"] == 6.0
      assert payload["threshold"] == 5
      assert payload["window_seconds"] == 60
      assert is_binary(payload["at"])
    end

    test "under_fill rate over threshold fires the under_fill metric", %{server: server} do
      test_pid = self()
      expect_delivery(test_pid)

      # 31 > 30/min default.
      emit_under_fill(31)
      assert :ok = ScaleAlerts.evaluate(server)

      assert_received {:alert_delivered, _url, body, _headers}
      payload = Jason.decode!(body)
      assert payload["metric"] == "under_fill_rate"
      assert payload["value"] == 31.0
      assert payload["threshold"] == 30
    end

    test "p95 heavy-read latency over threshold fires the p95 metric", %{server: server} do
      test_pid = self()
      expect_delivery(test_pid)

      # 100 samples at 5000ms: p95 sits well above the 2000ms threshold. lat_total=100 is
      # above the @p95_min_samples floor (20), so p95 is evaluated. 5000ms lands in the
      # 5000 bucket → p95 estimate 5000 > 2000.
      emit_latency(5_000, 100)
      assert :ok = ScaleAlerts.evaluate(server)

      assert_received {:alert_delivered, _url, body, _headers}
      payload = Jason.decode!(body)
      assert payload["metric"] == "heavy_read_p95_latency_ms"
      assert payload["value"] == 5_000
      assert payload["threshold"] == 2_000
    end

    test "alert payload carries NO tenant content / vectors / SQL", %{server: server} do
      test_pid = self()
      expect_delivery(test_pid)

      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(server)

      assert_received {:alert_delivered, _url, body, _headers}
      # The tenant id we emitted MUST NOT appear anywhere in the payload.
      refute body =~ "t-123"
      refute body =~ "tenant"
      refute body =~ "vector"
      refute body =~ "SELECT"
      refute body =~ "embedding"

      keys = body |> Jason.decode!() |> Map.keys() |> Enum.sort()
      assert keys == ["alert", "at", "metric", "threshold", "value", "window_seconds"]
    end
  end

  describe "no firing under threshold" do
    test "timeout count at/under threshold does NOT deliver", %{server: server} do
      # No expect/3 → the permissive stub stands; verify_on_exit! would FAIL if an
      # unexpected expect were set, but here we assert NO delivery by counting calls.
      test_pid = self()

      stub(Loopctl.MockDelivery, :deliver, fn _url, _body, _headers ->
        send(test_pid, :unexpected_delivery)
        {:ok, %{status: 200, body: "ok"}}
      end)

      # 5/min == threshold; the check is strictly `>` so 5 does NOT breach.
      emit_timeout(5)
      assert :ok = ScaleAlerts.evaluate(server)

      refute_received :unexpected_delivery
    end

    test "p95 below the sample floor is skipped (no noise alert)", %{server: server} do
      test_pid = self()

      stub(Loopctl.MockDelivery, :deliver, fn _u, _b, _h ->
        send(test_pid, :unexpected_delivery)
        {:ok, %{status: 200, body: "ok"}}
      end)

      # Only 5 samples (< @p95_min_samples = 20), even though each is 9000ms.
      emit_latency(9_000, 5)
      assert :ok = ScaleAlerts.evaluate(server)

      refute_received :unexpected_delivery
    end
  end

  describe "edge-triggered debounce" do
    test "a sustained breach fires ONCE, not on every evaluate", %{server: server} do
      test_pid = self()

      # Override the setup stub so EVERY deliver call is observable (a 2nd fire that fell
      # through to a silent stub would otherwise hide a debounce regression). Any call
      # sends {:fired, ...}, so refute_received is airtight.
      stub(Loopctl.MockDelivery, :deliver, fn _url, body, _headers ->
        send(test_pid, {:fired, Jason.decode!(body)["metric"]})
        {:ok, %{status: 200, body: "ok"}}
      end)

      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(server)
      assert_received {:fired, "db_statement_timeout_rate"}

      # Second window STILL breaches (another 6) but the metric is already in breach →
      # debounced, NO new delivery.
      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(server)
      refute_received {:fired, _}
    end

    test "after the metric clears, a fresh breach fires again", %{server: server} do
      test_pid = self()

      stub(Loopctl.MockDelivery, :deliver, fn _url, body, _headers ->
        send(test_pid, {:fired, Jason.decode!(body)["value"]})
        {:ok, %{status: 200, body: "ok"}}
      end)

      # Breach #1
      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(server)
      assert_received {:fired, 6.0}

      # Clear: an empty window (0 timeouts) re-arms the metric — and does NOT re-fire.
      assert :ok = ScaleAlerts.evaluate(server)
      refute_received {:fired, _}

      # Breach #2 fires again now that it re-armed.
      emit_timeout(7)
      assert :ok = ScaleAlerts.evaluate(server)
      assert_received {:fired, 7.0}
    end
  end

  describe "tumbling window reset" do
    test "counters reset each evaluate so a one-off spike doesn't persist", %{server: server} do
      test_pid = self()

      stub(Loopctl.MockDelivery, :deliver, fn _url, _body, _headers ->
        send(test_pid, :fired)
        {:ok, %{status: 200, body: "ok"}}
      end)

      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(server)
      assert_received :fired

      # Window was reset; this evaluate sees 0 timeouts → clears, no fire.
      assert :ok = ScaleAlerts.evaluate(server)
      refute_received :fired
    end
  end

  describe "no webhook url configured (log-only opt-in)" do
    test "with a nil url, a breach logs and does NOT POST or enqueue (AC-34.5.4)" do
      test_pid = self()

      stub(Loopctl.MockDelivery, :deliver, fn _u, _b, _h ->
        send(test_pid, :unexpected_delivery)
        {:ok, %{status: 200, body: "ok"}}
      end)

      # A nil-url breach must never even reach Oban — assert no [:oban, :job, :start]
      # (or any other oban job event) fires for our worker at all (US-34.5: the nil
      # branch stays a SYNCHRONOUS log-only no-op, it must not enqueue).
      handler_id = {:scale_alerts_nilurl_oban, System.unique_integer([:positive])}

      :telemetry.attach(
        handler_id,
        [:oban, :job, :start],
        fn _event, _measurements, meta, _config ->
          send(test_pid, {:unexpected_oban_job, meta.job.worker})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Start a SEPARATE instance with the URL overridden to nil via a start opt (NO
      # put_env in the body — the override is instance config, restored automatically when
      # this supervised process stops). A breach must log, not POST, and (US-34.5) must
      # NOT enqueue a durable-delivery job either.
      table = :"scale_alerts_nilurl_#{System.unique_integer([:positive])}"
      name = :"scale_alerts_nilurl_srv_#{System.unique_integer([:positive])}"

      _pid =
        start_supervised!({ScaleAlerts, table: table, name: name, webhook_url: nil}, id: name)

      for _ <- 1..6 do
        :telemetry.execute(TelemetryEvents.db_error(), %{count: 1}, %{
          mapped_code: "db_statement_timeout",
          endpoint: :suggested_links
        })
      end

      assert :ok = ScaleAlerts.evaluate(name)
      refute_received :unexpected_delivery
      refute_received {:unexpected_oban_job, _}
    end
  end

  describe "durable delivery via Oban (AC-34.5.1)" do
    # ScaleAlerts is a long-running GenServer, so `deliver/2`'s `Oban.insert/1` executes
    # inside the SERVER process, not the test process — `Oban.Testing.with_testing_mode/2`
    # is a process-dictionary override scoped to the CALLING process (the pattern used
    # in `signup_test.exs`, where the enqueue happens via a plain context function call
    # in the test process itself) and does not reach across that GenServer.call boundary.
    # Instead we prove durability directly at Oban's own job-lifecycle telemetry: a
    # `perform/1` failure must be classified `state: :failure` (Oban's retryable state,
    # the trigger for its OWN backoff/retry scheduling) rather than being silently
    # swallowed — i.e. the alert genuinely ran THROUGH Oban's Executor, not a bare
    # logged-and-dropped POST. The worker-level test
    # (`scale_alert_delivery_worker_test.exs`) covers the complementary unit proof that
    # `perform/1` itself returns `{:error, _}` on failure and `:ok` on success.
    test "a delivery failure is classified by Oban as a retryable failure, not dropped",
         %{server: server} do
      test_pid = self()

      stub(Loopctl.MockDelivery, :deliver, fn _url, _body, _headers ->
        {:error, "connection_refused"}
      end)

      handler_id = {:scale_alerts_oban_exception, System.unique_integer([:positive])}

      :telemetry.attach(
        handler_id,
        [:oban, :job, :exception],
        fn _event, _measurements, meta, _config ->
          send(test_pid, {:oban_job_failed, meta.job.worker, meta.state})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # 6 timeouts in a 60s window = 6/min > the 5/min default threshold.
      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(server)

      expected_worker = inspect(ScaleAlertDeliveryWorker)
      assert_received {:oban_job_failed, ^expected_worker, :failure}
    end

    test "a delivery success runs through the durable worker path (not a bare POST)",
         %{server: server} do
      test_pid = self()

      handler_id = {:scale_alerts_oban_stop, System.unique_integer([:positive])}

      :telemetry.attach(
        handler_id,
        [:oban, :job, :stop],
        fn _event, _measurements, meta, _config ->
          send(test_pid, {:oban_job_succeeded, meta.job.worker, meta.state})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      expect(Loopctl.MockDelivery, :deliver, fn _url, _body, _headers ->
        {:ok, %{status: 200, body: "ok"}}
      end)

      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(server)

      expected_worker = inspect(ScaleAlertDeliveryWorker)
      assert_received {:oban_job_succeeded, ^expected_worker, :success}
    end
  end

  describe "a dropped enqueue does not silence re-notify (review fix)" do
    # Uses the `insert_fn` test seam (mirrors the existing `webhook_url`/`now_fn`
    # per-instance overrides) to simulate `Oban.insert/1` itself failing or raising —
    # distinct from the worker's OWN `perform/1` failing after a successful insert
    # (covered by the "durable delivery via Oban" describe block above).
    test "an Oban.insert {:error, _} keeps the breach 'due'; the very next evaluate retries" do
      test_pid = self()

      # Fail exactly the FIRST insert attempt, then delegate to the real Oban.insert/1.
      failed_once? = :counters.new(1, [])

      insert_fn = fn job ->
        if :counters.get(failed_once?, 1) == 0 do
          :counters.add(failed_once?, 1, 1)
          {:error, %Ecto.Changeset{valid?: false}}
        else
          Oban.insert(job)
        end
      end

      stub(Loopctl.MockDelivery, :deliver, fn _url, body, _headers ->
        send(test_pid, {:delivered, Jason.decode!(body)["metric"]})
        {:ok, %{status: 200, body: "ok"}}
      end)

      table = :"scale_alerts_dropped_enqueue_#{System.unique_integer([:positive])}"
      name = :"scale_alerts_dropped_enqueue_srv_#{System.unique_integer([:positive])}"

      _pid =
        start_supervised!({ScaleAlerts, table: table, name: name, insert_fn: insert_fn},
          id: name
        )

      # Edge fire: the enqueue is dropped -> nothing is ever delivered for this tick, and
      # (the bug this finding describes) `last_notified_at` must NOT have been stamped.
      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(name)
      refute_received {:delivered, _}

      # Sustained breach, very next tick: with the fix, a `nil` last_notified_at while
      # breaching means "never successfully notified" -> retried immediately (NOT after
      # waiting out a full `renotify_interval_ms`, which defaults to 15 minutes). This
      # time the insert succeeds and the alert is genuinely delivered.
      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(name)
      assert_received {:delivered, "db_statement_timeout_rate"}
    end

    test "an insert_fn that raises (DB unavailable) does not crash the GenServer" do
      test_pid = self()

      insert_fn = fn _job ->
        raise DBConnection.ConnectionError, "connection not available"
      end

      stub(Loopctl.MockDelivery, :deliver, fn _url, _body, _headers ->
        send(test_pid, :unexpected_delivery)
        {:ok, %{status: 200, body: "ok"}}
      end)

      table = :"scale_alerts_raise_#{System.unique_integer([:positive])}"
      name = :"scale_alerts_raise_srv_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!({ScaleAlerts, table: table, name: name, insert_fn: insert_fn},
          id: name
        )

      emit_timeout(6)
      # The call itself must complete normally (not crash/timeout) — proving `deliver/3`
      # rescued the raise instead of letting it propagate out of `handle_call(:evaluate)`.
      assert :ok = ScaleAlerts.evaluate(name)

      assert Process.alive?(pid)
      refute_received :unexpected_delivery
    end
  end

  describe "no secret persisted in the enqueued job (review fix)" do
    # Uses the `insert_fn` test seam to capture the EXACT job `deliver/3` builds, before
    # it reaches Oban, and proves the webhook URL (potentially secret-bearing) is never
    # part of the args that would be JSON-serialized into `oban_jobs.args`.
    test "the job enqueued for delivery carries only :payload — never the webhook url" do
      test_pid = self()

      insert_fn = fn job ->
        send(test_pid, {:captured_job_args, job.changes.args})
        Oban.insert(job)
      end

      stub(Loopctl.MockDelivery, :deliver, fn _url, _body, _headers ->
        {:ok, %{status: 200, body: "ok"}}
      end)

      table = :"scale_alerts_no_url_in_args_#{System.unique_integer([:positive])}"
      name = :"scale_alerts_no_url_in_args_srv_#{System.unique_integer([:positive])}"

      _pid =
        start_supervised!({ScaleAlerts, table: table, name: name, insert_fn: insert_fn},
          id: name
        )

      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(name)

      assert_received {:captured_job_args, args}
      assert Map.keys(args) == [:payload]
      refute Map.has_key?(args, :url)
    end
  end

  describe "malformed webhook url config does not crash the GenServer (review fix)" do
    # A non-nil, non-binary `:scale_alert_webhook_url` (e.g. a charlist/atom from a
    # config typo) must be treated as a delivery error, not raise past `deliver/3` and
    # crash the un-rescued `handle_call(:evaluate)`.
    test "a non-binary configured url logs, reports :error, and keeps the GenServer alive" do
      test_pid = self()

      stub(Loopctl.MockDelivery, :deliver, fn _u, _b, _h ->
        send(test_pid, :unexpected_delivery)
        {:ok, %{status: 200, body: "ok"}}
      end)

      table = :"scale_alerts_bad_url_#{System.unique_integer([:positive])}"
      name = :"scale_alerts_bad_url_srv_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {ScaleAlerts, table: table, name: name, webhook_url: :not_a_url},
          id: name
        )

      emit_timeout(6)
      # Must complete normally (not crash/timeout) — proving the catch-all `deliver/3`
      # clause handled the malformed config instead of raising FunctionClauseError.
      assert :ok = ScaleAlerts.evaluate(name)

      assert Process.alive?(pid)
      refute_received :unexpected_delivery

      # Sustained breach on the very next tick still doesn't crash or deliver — the
      # misconfiguration persists, so the metric legitimately never gets marked notified.
      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(name)
      assert Process.alive?(pid)
      refute_received :unexpected_delivery
    end
  end

  describe "bounded periodic re-notify while a breach is sustained (AC-34.5.2)" do
    test "re-fires once the re-notify interval elapses, stays silent before it, re-arms on clear" do
      test_pid = self()

      stub(Loopctl.MockDelivery, :deliver, fn _url, body, _headers ->
        send(test_pid, {:fired, Jason.decode!(body)["metric"]})
        {:ok, %{status: 200, body: "ok"}}
      end)

      # A mutable clock (Erlang :counters, no Application.put_env involved) injected as
      # a per-instance `now_fn` override — mirrors the existing `webhook_url` seam — so
      # the re-notify interval can be crossed deterministically without sleeping.
      clock = :counters.new(1, [])
      now_fn = fn -> :counters.get(clock, 1) end

      table = :"scale_alerts_renotify_#{System.unique_integer([:positive])}"
      name = :"scale_alerts_renotify_srv_#{System.unique_integer([:positive])}"

      _pid =
        start_supervised!(
          {ScaleAlerts, table: table, name: name, now_fn: now_fn, renotify_interval_ms: 1_000},
          id: name
        )

      # Edge fire: false -> true.
      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(name)
      assert_received {:fired, "db_statement_timeout_rate"}

      # Still breaching, interval NOT elapsed (500ms < 1_000ms) -> debounced, no 2nd fire.
      :counters.add(clock, 1, 500)
      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(name)
      refute_received {:fired, _}

      # Advance PAST the interval, still breaching -> bounded re-notify fires (TC-34.5.2).
      :counters.add(clock, 1, 600)
      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(name)
      assert_received {:fired, "db_statement_timeout_rate"}

      # Clear below threshold -> re-arms (no fire).
      assert :ok = ScaleAlerts.evaluate(name)
      refute_received {:fired, _}

      # A later breach fires again immediately (TC-34.5.3: edge semantics preserved).
      emit_timeout(6)
      assert :ok = ScaleAlerts.evaluate(name)
      assert_received {:fired, "db_statement_timeout_rate"}
    end
  end
end
