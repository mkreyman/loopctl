defmodule Loopctl.Telemetry.ObanMetricsPollerTest do
  @moduledoc """
  US-34.1 integration tests for the two Oban metrics pollers
  (`Loopctl.Telemetry.ScaleMetrics.poll_oban_queue_state/0` and
  `poll_oban_executing_orphans/0`):

    * TC-34.1.1 — rows in a couple of states (`available`, `completed`) → the
      per-{state, queue} telemetry measurement reflects the actual counts.
    * TC-34.1.2 — one stale `executing` row (attempted_at older than the orphan
      threshold) + one recent `executing` row → the orphan gauge counts ONLY the
      stale one.
    * TC-34.1.3 — the poll query raising is logged and swallowed; no telemetry is
      emitted on failure (no metric corruption).

  `oban_jobs` is a GLOBAL table (no `tenant_id` column) and both pollers touch it
  directly via `Loopctl.AdminRepo` raw SQL (the `Loopctl.IndexHealth` precedent —
  `Loopctl.HeavyRead` structurally rejects a query with no tenant predicate).
  Rows are inserted through `AdminRepo` too, on the SAME sandboxed connection/
  transaction the pollers query — the standard cross-repo-visibility fix already
  used by `knowledge_ingestion_controller_test.exs`'s tenant-isolation tests.

  `async: false`: the executing_orphan gauge is UNTAGGED (a single global telemetry
  channel + Prometheus series), and `:telemetry.attach/4` registers by EVENT NAME
  (not by calling process) — running serially avoids a concurrently-running test's
  poll invocation firing through this test's attached handler.
  """
  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Telemetry.ScaleMetrics

  describe "poll_oban_queue_state/0 (AC-34.1.1, TC-34.1.1)" do
    test "emits a telemetry measurement per {state, queue} reflecting actual oban_jobs counts" do
      test_pid = self()
      handler_id = "test-oban-queue-state-#{System.unique_integer([:positive])}"
      # A per-test unique queue name disambiguates this test's rows/measurements
      # from any other test's concurrent poll (belt-and-suspenders on top of
      # async: false above).
      queue = "test_queue_#{System.unique_integer([:positive])}"

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
      insert_job(state: "completed", queue: queue)

      assert ScaleMetrics.poll_oban_queue_state() == :ok

      assert_receive {:oban_queue_state, %{state: "available", queue: ^queue}, %{count: 2}}, 1000
      assert_receive {:oban_queue_state, %{state: "completed", queue: ^queue}, %{count: 1}}, 1000
    end
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

  describe "poller defensiveness (AC-34.1.3, TC-34.1.3)" do
    # DataCase's setup checks AdminRepo out in :shared mode (this whole file is
    # async: false), under which EVERY process — including this test process for
    # any FURTHER call — routes to the same shared connection regardless of
    # per-process ownership, so a plain `checkin` doesn't disconnect anything.
    # Switching the pool back to `:manual` here removes that shared mapping
    # without touching the dedicated owner process DataCase started, so THIS
    # test process (which never explicitly checked out its own connection — it
    # was only riding the shared one) has no ownership at all afterward: its
    # very next AdminRepo call raises a genuine `DBConnection.OwnershipError` — a
    # REAL DB fault, not a stub. Self-contained: the NEXT test's `setup` calls
    # `start_owner!(shared: true)` again, which re-establishes shared mode fresh.
    setup do
      Sandbox.mode(Loopctl.AdminRepo, :manual)
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
  end

  defp insert_job(attrs) do
    attrs
    |> Enum.into(%{})
    |> Map.put_new(:worker, "Loopctl.Workers.IdempotencyCleanupWorker")
    |> Map.put_new(:args, %{})
    |> then(&struct(Oban.Job, &1))
    |> AdminRepo.insert!()
  end
end
