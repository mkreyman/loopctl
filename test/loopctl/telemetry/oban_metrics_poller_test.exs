defmodule Loopctl.Telemetry.ObanMetricsPollerTest do
  @moduledoc """
  US-34.1 integration tests for the two Oban metrics pollers
  (`Loopctl.Telemetry.ScaleMetrics.poll_oban_queue_state/0` and
  `poll_oban_executing_orphans/0`):

    * TC-34.1.1 — rows in a couple of NON-TERMINAL states (`available`,
      `retryable`) → the per-{state, queue} telemetry measurement reflects the
      actual counts.
    * TC-34.1.1a — terminal states (`completed`/`discarded`/`cancelled`) are
      EXCLUDED from the poll/zero-fill matrix entirely (review finding: a bare
      `GROUP BY state, queue` over all 8 states forces a full Seq Scan once the
      terminal partitions dominate under the pruner's 7-day retention) — a
      `completed` row never produces ANY measurement, not even a `count: 0`.
    * TC-34.1.1b — zero-fill: a `{state, queue}` pair with NO rows still emits an
      explicit `count: 0` measurement every poll (review finding fix — a
      `last_value/2` gauge has no expiry, so without an explicit zero-fill a
      drained pair would read stale-high forever).
    * TC-34.1.1c — drain-to-zero: a pair that HAD jobs, then drains to none,
      reads `0` on the very next poll rather than retaining the prior non-zero
      reading.
    * TC-34.1.1d — the `:queue` label is structurally bounded to
      `ScaleMetrics.oban_queues/0` (the configured set) — a job in an
      unconfigured/ad-hoc queue name never produces a Prometheus series.
    * TC-34.1.2 — one stale `executing` row (attempted_at older than the orphan
      threshold) + one recent `executing` row → the orphan gauge counts ONLY the
      stale one.
    * TC-34.1.3 — the poll query raising is logged and swallowed (via a
      CATCH-ALL rescue — review finding, broadened from a narrow DB-fault-only
      rescue since `telemetry_poller` permanently drops a raising measurement
      from its rotation rather than crashing); no gauge measurement is emitted on
      failure (no metric corruption), and the poll-failure counter
      (`loopctl.oban.poll.error.count`) fires instead.

  Also covers `cached_executing_orphan_count/0` (US-34.2 review finding): the
  `:persistent_term` cache `poll_oban_executing_orphans/0` writes on every
  SUCCESSFUL poll, which `Loopctl.HealthCheck.Default.check_oban_orphans/0` reads
  instead of issuing its own fresh query — `:not_yet_polled` before the first
  poll, `{:ok, count}` after, and a FAILED poll leaving the prior cached value in
  place (same staleness semantics as the `last_value/2` gauge it also feeds).

  `oban_jobs` is a GLOBAL table (no `tenant_id` column). Both pollers now query
  it via `Loopctl.Repo` (review finding — moved off the tiny 3-connection
  `Loopctl.AdminRepo` pool, since `oban_jobs` has no RLS policy so the RLS-role
  `Repo` reads it exactly as well). Rows are inserted through `Loopctl.Repo` too,
  on the SAME sandboxed connection/transaction the pollers query — the standard
  cross-repo-visibility fix already used by
  `knowledge_ingestion_controller_test.exs`'s tenant-isolation tests (write and
  read must share a Repo module to be visible to each other under Sandbox).

  Tests use a REAL configured queue name (from `ScaleMetrics.oban_queues/0`)
  rather than an ad-hoc `"test_queue_N"` string: `poll_oban_queue_state/0` now
  zero-fills and emits ONLY the fixed `oban_active_states/0` x `oban_queues/0`
  matrix, so an unconfigured queue name would never produce ANY measurement (by
  design — AC-34.1.5). Sandbox isolation (each async test owns its own
  transaction/connection) is what actually prevents cross-test interference, not
  the queue name — the old per-test-unique name was defensive
  belt-and-suspenders, not a correctness requirement.

  `async: false`: the executing_orphan gauge is UNTAGGED (a single global telemetry
  channel + Prometheus series), and `:telemetry.attach/4` registers by EVENT NAME
  (not by calling process) — running serially avoids a concurrently-running test's
  poll invocation firing through this test's attached handler.
  """
  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.Telemetry.ScaleMetrics

  describe "poll_oban_queue_state/0 (AC-34.1.1, TC-34.1.1)" do
    test "emits a telemetry measurement per {state, queue} reflecting actual oban_jobs counts" do
      test_pid = self()
      handler_id = "test-oban-queue-state-#{System.unique_integer([:positive])}"
      queue = configured_queue()

      :telemetry.attach(
        handler_id,
        [:loopctl, :oban, :jobs, :count],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:oban_queue_state, metadata, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      insert_job(state: "available", queue: queue)
      insert_job(state: "available", queue: queue)
      insert_job(state: "retryable", queue: queue)

      assert ScaleMetrics.poll_oban_queue_state() == :ok

      assert_receive {:oban_queue_state, %{state: "available", queue: ^queue}, %{count: 2}}, 1000
      assert_receive {:oban_queue_state, %{state: "retryable", queue: ^queue}, %{count: 1}}, 1000
    end

    test "terminal states (completed/discarded/cancelled) are excluded entirely — no measurement, not even zero-fill (TC-34.1.1a, review finding)" do
      test_pid = self()
      handler_id = "test-oban-terminal-excluded-#{System.unique_integer([:positive])}"
      queue = configured_queue()

      :telemetry.attach(
        handler_id,
        [:loopctl, :oban, :jobs, :count],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:oban_queue_state, metadata, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      insert_job(state: "completed", queue: queue)
      insert_job(state: "discarded", queue: queue)
      insert_job(state: "cancelled", queue: queue)

      assert ScaleMetrics.poll_oban_queue_state() == :ok

      refute_receive {:oban_queue_state, %{state: "completed"}, _measurements}, 300
      refute_receive {:oban_queue_state, %{state: "discarded"}, _measurements}, 300
      refute_receive {:oban_queue_state, %{state: "cancelled"}, _measurements}, 300
    end

    test "zero-fills: a {state, queue} pair with no rows still emits count: 0 (TC-34.1.1b)" do
      test_pid = self()
      handler_id = "test-oban-zero-fill-#{System.unique_integer([:positive])}"
      [queue_a, queue_b | _] = ScaleMetrics.oban_queues() |> Enum.map(&Atom.to_string/1)

      :telemetry.attach(
        handler_id,
        [:loopctl, :oban, :jobs, :count],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:oban_queue_state, metadata, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Only ONE row exists at all: {available, queue_a}. Every other pair in the
      # active-state matrix — including {available, queue_b} and
      # {scheduled, queue_a} — has NO backing row, so the GROUP BY never returns
      # them, yet the poller must still emit an explicit count: 0 for each (the
      # fix under test).
      insert_job(state: "available", queue: queue_a)

      assert ScaleMetrics.poll_oban_queue_state() == :ok

      assert_receive {:oban_queue_state, %{state: "available", queue: ^queue_a}, %{count: 1}},
                     1000

      assert_receive {:oban_queue_state, %{state: "available", queue: ^queue_b}, %{count: 0}},
                     1000

      assert_receive {:oban_queue_state, %{state: "scheduled", queue: ^queue_a}, %{count: 0}},
                     1000
    end

    test "drain-to-zero: a pair that held jobs reads 0 on the next poll once drained (TC-34.1.1c)" do
      test_pid = self()
      handler_id = "test-oban-drain-#{System.unique_integer([:positive])}"
      queue = configured_queue()

      :telemetry.attach(
        handler_id,
        [:loopctl, :oban, :jobs, :count],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:oban_queue_state, metadata, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{id: job_id} = insert_job(state: "available", queue: queue)

      assert ScaleMetrics.poll_oban_queue_state() == :ok

      assert_receive {:oban_queue_state, %{state: "available", queue: ^queue}, %{count: 1}}, 1000

      # Drain the queue entirely (simulates Oban completing/removing the job).
      Repo.delete_all(from(j in Oban.Job, where: j.id == ^job_id))

      assert ScaleMetrics.poll_oban_queue_state() == :ok

      # Without the zero-fill fix, `last_value/2` would retain the stale count: 1
      # forever since no row (not even a zero row) is ever emitted for a drained
      # pair by a bare GROUP BY count(*).
      assert_receive {:oban_queue_state, %{state: "available", queue: ^queue}, %{count: 0}}, 1000
    end

    test "the :queue label is bounded to the configured set — an ad-hoc queue name never emits (TC-34.1.1d)" do
      test_pid = self()
      handler_id = "test-oban-unconfigured-queue-#{System.unique_integer([:positive])}"
      ad_hoc_queue = "totally_unconfigured_queue_#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :oban, :jobs, :count],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:oban_queue_state, metadata, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      insert_job(state: "available", queue: ad_hoc_queue)

      assert ScaleMetrics.poll_oban_queue_state() == :ok

      refute_receive {:oban_queue_state, %{queue: ^ad_hoc_queue}, _measurements}, 500
    end
  end

  # A real, currently-configured Oban queue name (from `ScaleMetrics.oban_queues/0`)
  # — asserted to actually be a member so a future queue-list change fails this
  # helper loudly instead of silently testing a stale/removed queue.
  defp configured_queue do
    queues = ScaleMetrics.oban_queues() |> Enum.map(&Atom.to_string/1)
    queue = "analytics"
    assert queue in queues
    queue
  end

  describe "poll_oban_executing_orphans/0 (AC-34.1.2, TC-34.1.2)" do
    test "counts only the executing job whose attempted_at exceeds the threshold" do
      threshold_minutes = ScaleMetrics.oban_metrics_orphan_threshold_minutes()
      now = DateTime.utc_now()

      # Stale: attempted well past the threshold — the orphan.
      insert_job(
        state: "executing",
        queue: "default",
        attempted_at: DateTime.add(now, -(threshold_minutes + 5) * 60, :second)
      )

      # Recent: attempted a second ago — still legitimately mid-flight, NOT an orphan.
      insert_job(
        state: "executing",
        queue: "default",
        attempted_at: DateTime.add(now, -1, :second)
      )

      test_pid = self()
      handler_id = "test-oban-orphan-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :oban, :jobs, :executing_orphan, :count],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:oban_orphan, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert ScaleMetrics.poll_oban_executing_orphans() == :ok

      assert_receive {:oban_orphan, %{count: 1}}, 1000
    end
  end

  describe "count_oban_executing_orphans/0 (US-34.2, AC-34.2.3 — extracted for reuse by the health check)" do
    test "returns the orphan count directly (not just via telemetry), counting only the stale executing job" do
      threshold_minutes = ScaleMetrics.oban_metrics_orphan_threshold_minutes()
      now = DateTime.utc_now()

      insert_job(
        state: "executing",
        queue: "default",
        attempted_at: DateTime.add(now, -(threshold_minutes + 5) * 60, :second)
      )

      insert_job(
        state: "executing",
        queue: "default",
        attempted_at: DateTime.add(now, -1, :second)
      )

      assert ScaleMetrics.count_oban_executing_orphans() == 1
    end

    test "returns 0 when there are no stale executing jobs" do
      assert ScaleMetrics.count_oban_executing_orphans() == 0
    end

    test "poll_oban_executing_orphans/0 still emits the SAME count this function computes (unchanged behavior after the extraction)" do
      threshold_minutes = ScaleMetrics.oban_metrics_orphan_threshold_minutes()
      now = DateTime.utc_now()

      insert_job(
        state: "executing",
        queue: "default",
        attempted_at: DateTime.add(now, -(threshold_minutes + 5) * 60, :second)
      )

      test_pid = self()
      handler_id = "test-oban-orphan-reuse-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :oban, :jobs, :executing_orphan, :count],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:oban_orphan, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      direct_count = ScaleMetrics.count_oban_executing_orphans()
      assert ScaleMetrics.poll_oban_executing_orphans() == :ok

      assert_receive {:oban_orphan, %{count: ^direct_count}}, 1000
    end
  end

  describe "cached_executing_orphan_count/0 (US-34.2 review finding — health-check reuse of the poller's cache)" do
    test "returns :not_yet_polled before any poll has ever completed" do
      :persistent_term.erase({ScaleMetrics, :cached_executing_orphan_count})

      assert ScaleMetrics.cached_executing_orphan_count() == :not_yet_polled
    end

    test "returns {:ok, count} reflecting the last successful poll, without issuing a fresh query" do
      threshold_minutes = ScaleMetrics.oban_metrics_orphan_threshold_minutes()
      now = DateTime.utc_now()

      insert_job(
        state: "executing",
        queue: "default",
        attempted_at: DateTime.add(now, -(threshold_minutes + 5) * 60, :second)
      )

      assert ScaleMetrics.poll_oban_executing_orphans() == :ok
      assert ScaleMetrics.cached_executing_orphan_count() == {:ok, 1}
    end

    test "a FAILED poll leaves the prior cached value in place (same staleness semantics as the last_value gauge)" do
      threshold_minutes = ScaleMetrics.oban_metrics_orphan_threshold_minutes()
      now = DateTime.utc_now()

      insert_job(
        state: "executing",
        queue: "default",
        attempted_at: DateTime.add(now, -(threshold_minutes + 5) * 60, :second)
      )

      assert ScaleMetrics.poll_oban_executing_orphans() == :ok
      assert ScaleMetrics.cached_executing_orphan_count() == {:ok, 1}

      # Force the NEXT poll to fail (same technique as "poller defensiveness"
      # below): drop this test process's sandbox ownership so its next Repo call
      # raises a genuine DBConnection.OwnershipError.
      Sandbox.mode(Loopctl.Repo, :manual)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ScaleMetrics.poll_oban_executing_orphans() == :ok
        end)

      assert log =~ "Oban executing-orphan poll failed"

      # The cache retains the last SUCCESSFUL value — never resets to 0/unknown
      # just because a poll cycle failed.
      assert ScaleMetrics.cached_executing_orphan_count() == {:ok, 1}
    end
  end

  describe "poller defensiveness (AC-34.1.3, TC-34.1.3)" do
    # DataCase's setup checks Repo out in :shared mode (this whole file is
    # async: false), under which EVERY process — including this test process for
    # any FURTHER call — routes to the same shared connection regardless of
    # per-process ownership, so a plain `checkin` doesn't disconnect anything.
    # Switching the pool back to `:manual` here removes that shared mapping
    # without touching the dedicated owner process DataCase started, so THIS
    # test process (which never explicitly checked out its own connection — it
    # was only riding the shared one) has no ownership at all afterward: its
    # very next Repo call raises a genuine `DBConnection.OwnershipError` — a
    # REAL DB fault, not a stub. Self-contained: the NEXT test's `setup` calls
    # `start_owner!(shared: true)` again, which re-establishes shared mode fresh.
    setup do
      Sandbox.mode(Loopctl.Repo, :manual)
      :ok
    end

    test "poll_oban_queue_state/0 logs and returns :ok without raising on a DB fault" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ScaleMetrics.poll_oban_queue_state() == :ok
        end)

      assert log =~ "Oban queue/state poll failed"
    end

    test "poll_oban_executing_orphans/0 logs and returns :ok without raising on a DB fault" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ScaleMetrics.poll_oban_executing_orphans() == :ok
        end)

      assert log =~ "Oban executing-orphan poll failed"
    end

    test "no metric corruption: neither gauge emits when the poll fails" do
      test_pid = self()
      handler_id = "test-oban-no-corruption-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:loopctl, :oban, :jobs, :count],
          [:loopctl, :oban, :jobs, :executing_orphan, :count]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:unexpected_emit, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      ExUnit.CaptureLog.capture_log(fn ->
        ScaleMetrics.poll_oban_queue_state()
        ScaleMetrics.poll_oban_executing_orphans()
      end)

      refute_receive {:unexpected_emit, _event, _measurements, _metadata}, 200
    end

    test "the poll-failure counter fires from both pollers on a DB fault (review finding)" do
      test_pid = self()
      handler_id = "test-oban-poll-error-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :oban, :poll, :error],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:oban_poll_error, metadata, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      ExUnit.CaptureLog.capture_log(fn ->
        ScaleMetrics.poll_oban_queue_state()
      end)

      assert_receive {:oban_poll_error, %{poller: :queue_state, exception: exception},
                      %{count: 1}},
                     500

      assert exception.__struct__ in [DBConnection.OwnershipError, Postgrex.Error]

      ExUnit.CaptureLog.capture_log(fn ->
        ScaleMetrics.poll_oban_executing_orphans()
      end)

      assert_receive {:oban_poll_error, %{poller: :executing_orphans, exception: exception2},
                      %{count: 1}},
                     500

      assert exception2.__struct__ in [DBConnection.OwnershipError, Postgrex.Error]
    end
  end

  # The catch-all `rescue e ->` clause (review finding — broadened from a narrow
  # DB-fault-only rescue) has NO type restriction, so the SAME code path proven
  # above via `DBConnection.OwnershipError` (a real DB fault, simulated via
  # Sandbox mode rather than any `Application.put_env` config mutation) also
  # covers a non-DB exception class (e.g. an `ArgumentError` from an invalid
  # config tunable, or the `FunctionClauseError` `oban_queues/0` itself now
  # guards against). The classification of NON-DB exceptions into the bounded
  # `error_class` tag (`"config_error"`/`"other"`) is unit-tested directly via
  # `oban_poll_error_tags/1` in `scale_metrics_test.exs`, and the config
  # validators themselves (`validate_positive_poll_timeout!/1`,
  # `queues_from_config/1`) are exposed as pure functions there too — so neither
  # needs an `Application.put_env` integration test here.

  defp insert_job(attrs) do
    attrs
    |> Enum.into(%{})
    |> Map.put_new(:worker, "Loopctl.Workers.IdempotencyCleanupWorker")
    |> Map.put_new(:args, %{})
    |> then(&struct(Oban.Job, &1))
    |> Repo.insert!()
  end
end
