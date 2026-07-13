defmodule Loopctl.Telemetry.ScaleMetricsObanTest do
  @moduledoc """
  US-34.1 (AC-34.1.1/.2/.3): `Loopctl.Telemetry.ScaleMetrics.dispatch_oban_stats/0`
  — the periodic measurement wired into `LoopctlWeb.Telemetry.periodic_measurements/0`
  — polls real `oban_jobs` rows and emits the per-(state, queue) job-count gauge
  event and the `:executing` orphan-count gauge event, and is defensive against a
  poll-time DB error (never crashes the shared `telemetry_poller`).

  Uses `Loopctl.DataCase` (needs the DB for the integration-style TC-34.1.1/.2
  cases); TC-34.1.3 overrides the `Loopctl.MockObanStats` DI seam with
  `Mox.expect/3` to force a raise deterministically, matching the project's
  established pattern for exercising an otherwise-unreproducible DB-error path
  (see `Loopctl.MockSuggestLinks`'s DB-error-surfacing test).
  """
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  alias Loopctl.Telemetry.ScaleMetrics

  setup :verify_on_exit!

  # Captures every `event_name` telemetry emission that occurs while `fun` runs,
  # scoped to THIS test process (mirrors the existing under-fill / admin_repo
  # probe pattern used elsewhere in the suite, e.g.
  # vector_search_under_fill_test.exs).
  defp capture_events(event_name, fun) do
    test_pid = self()
    handler_id = {__MODULE__, event_name, make_ref()}

    :telemetry.attach(
      handler_id,
      event_name,
      fn ^event_name, measurements, metadata, _config ->
        if self() == test_pid do
          send(test_pid, {:telemetry_event, measurements, metadata})
        end
      end,
      nil
    )

    try do
      fun.()
      collect_events([])
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_events(acc) do
    receive do
      {:telemetry_event, measurements, metadata} ->
        collect_events([{measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # US-34.1 review finding: `job_state_counts/0`'s `GROUP BY state, queue` returns NO
  # row for an empty (state, queue) group, so the gauge must ZERO-FILL the full known
  # cartesian (7 Oban states x the configured queue set) or a group that drains to
  # zero (e.g. Lifeline just rescued a backlog) would leave the `last_value` gauge
  # stuck at its last-seen non-zero value forever.
  @known_cartesian_size 7 * length(Loopctl.ObanConfig.queues())

  describe "dispatch_oban_stats/0 — per-(state, queue) job-count gauge (AC-34.1.1, TC-34.1.1)" do
    test "emits a [:loopctl, :oban, :jobs] measurement per group reflecting real oban_jobs rows" do
      fixture(:oban_job, state: "available", queue: "default")
      fixture(:oban_job, state: "available", queue: "default")
      fixture(:oban_job, state: "completed", queue: "webhooks")

      events =
        capture_events([:loopctl, :oban, :jobs], fn ->
          assert ScaleMetrics.dispatch_oban_stats() == :ok
        end)

      assert {%{count: 2}, %{state: "available", queue: "default"}} in events
      assert {%{count: 1}, %{state: "completed", queue: "webhooks"}} in events
    end

    test "zero-fills the entire known cartesian (all counts 0) when oban_jobs has no rows" do
      events =
        capture_events([:loopctl, :oban, :jobs], fn ->
          assert ScaleMetrics.dispatch_oban_stats() == :ok
        end)

      refute events == []
      assert length(events) == @known_cartesian_size
      assert Enum.all?(events, fn {%{count: count}, _metadata} -> count == 0 end)
    end

    test "zero-fills a group that drained to zero, alongside the real non-zero counts" do
      fixture(:oban_job, state: "executing", queue: "default")

      events =
        capture_events([:loopctl, :oban, :jobs], fn ->
          assert ScaleMetrics.dispatch_oban_stats() == :ok
        end)

      # The one seeded group is non-zero...
      assert {%{count: 1}, %{state: "executing", queue: "default"}} in events
      # ...but every OTHER known (state, queue) combination — e.g. a drained group —
      # still emits an explicit 0 instead of being silently omitted.
      assert {%{count: 0}, %{state: "completed", queue: "default"}} in events
      assert {%{count: 0}, %{state: "available", queue: "webhooks"}} in events
      assert length(events) == @known_cartesian_size
    end
  end

  describe "dispatch_oban_stats/0 — :executing orphan gauge (AC-34.1.2, TC-34.1.2)" do
    test "emits a [:loopctl, :oban, :orphans] measurement counting ONLY the stale executing job" do
      # Older than the default 40-minute orphan threshold (ScaleMetrics.
      # oban_orphan_threshold_minutes/0), which is deliberately ABOVE Lifeline's
      # 30-minute rescue_after.
      stale = DateTime.add(DateTime.utc_now(), -45 * 60, :second)
      recent = DateTime.add(DateTime.utc_now(), -5 * 60, :second)

      fixture(:oban_job, state: "executing", attempted_at: stale)
      fixture(:oban_job, state: "executing", attempted_at: recent)

      events =
        capture_events([:loopctl, :oban, :orphans], fn ->
          assert ScaleMetrics.dispatch_oban_stats() == :ok
        end)

      assert [{%{count: 1}, %{}}] = events
    end
  end

  describe "dispatch_oban_stats/0 — defensive on poll error (AC-34.1.3, TC-34.1.3)" do
    test "logs and returns :ok (never raises) when the state-count query raises" do
      expect(Loopctl.MockObanStats, :job_state_counts, fn ->
        raise DBConnection.ConnectionError, message: "boom"
      end)

      log =
        capture_log(fn ->
          assert ScaleMetrics.dispatch_oban_stats() == :ok
        end)

      assert log =~ "oban_jobs metrics poll failed"
      assert log =~ "DBConnection.ConnectionError"
    end

    test "logs and returns :ok (never raises) when the orphan-count query raises" do
      expect(Loopctl.MockObanStats, :job_state_counts, fn -> [] end)

      expect(Loopctl.MockObanStats, :executing_orphan_count, fn _minutes ->
        raise Postgrex.Error, message: "boom"
      end)

      log =
        capture_log(fn ->
          assert ScaleMetrics.dispatch_oban_stats() == :ok
        end)

      assert log =~ "oban_jobs metrics poll failed"
      assert log =~ "Postgrex.Error"
    end

    test "a poll error never emits a stale/corrupt measurement" do
      expect(Loopctl.MockObanStats, :job_state_counts, fn ->
        raise DBConnection.ConnectionError, message: "boom"
      end)

      events =
        capture_events([:loopctl, :oban, :jobs], fn ->
          capture_log(fn -> ScaleMetrics.dispatch_oban_stats() end)
        end)

      assert events == []
    end

    test "an unexpected (non-DB) exception still propagates — the narrow rescue never masks a real bug" do
      expect(Loopctl.MockObanStats, :job_state_counts, fn -> raise ArgumentError, "boom" end)

      assert_raise ArgumentError, fn -> ScaleMetrics.dispatch_oban_stats() end
    end
  end
end
