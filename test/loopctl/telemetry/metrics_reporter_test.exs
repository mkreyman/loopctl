defmodule Loopctl.Telemetry.MetricsReporterTest do
  @moduledoc """
  US-27.15 / architect F1 (R2): the fault-isolating reporter wrapper actually ISOLATES.

  The whole reason `MetricsReporter` exists is that a reporter (ranch/cowboy) bind
  failure on the internal `:9568` port must NOT cascade through the telemetry supervisor
  and take down the API. The prior rounds asserted the wrapper EXISTED but never proved
  the isolation, because the prod-only start path (`TelemetryMetricsPrometheus.start_link`)
  was not injectable. R2 adds a `:start_fun` opt; these tests inject it to drive every
  start-failure mode WITHOUT binding a real port and prove:

    * an `{:error, _}`-returning start → the wrapper's `start_link` SUCCEEDS (init returns
      ok), it stays ALIVE, and it holds no reporter pid (a retry is scheduled, not a crash);
    * a RAISING start → same (the raise is caught, normalized, retried — not propagated);
    * an `exit`ing start → same;
    * the retry RECOVERS: a start that fails once then succeeds adopts the reporter pid on
      the next `:retry_start`.

  `async: false`: the wrapper registers its name as `Loopctl.Telemetry.MetricsReporter`
  (a singleton), so instances cannot run concurrently. NO real port is ever bound — the
  injected `start_fun` returns/raises synthetic results.
  """
  use ExUnit.Case, async: false

  alias Loopctl.Telemetry.MetricsReporter

  # The wrapper hardcodes `name: __MODULE__`; start it supervised so it auto-stops between
  # tests and the singleton name is freed.
  defp start_wrapper(start_fun) do
    start_supervised!(
      %{
        id: MetricsReporter,
        start:
          {MetricsReporter, :start_link, [[start_fun: start_fun, port: 0, name: :test_reporter]]}
      },
      restart: :temporary
    )
  end

  defp state(pid), do: :sys.get_state(pid)

  describe "start-failure isolation (architect F1)" do
    test "an {:error, :eaddrinuse} start does NOT crash the wrapper" do
      pid = start_wrapper(fn _opts -> {:error, :eaddrinuse} end)

      # init returned :ok and the continue ran try_start which hit the error branch and
      # scheduled a retry — the wrapper is ALIVE and holds no reporter pid.
      assert Process.alive?(pid)
      assert state(pid).pid == nil
    end

    test "a RAISING start is caught, not propagated (no cascade)" do
      pid = start_wrapper(fn _opts -> raise "boom in ranch" end)

      assert Process.alive?(pid)
      assert state(pid).pid == nil
    end

    test "an exiting start is caught, not propagated (no cascade)" do
      pid = start_wrapper(fn _opts -> exit(:eacces) end)

      assert Process.alive?(pid)
      assert state(pid).pid == nil
    end
  end

  describe "retry recovery" do
    test "a start that fails once then succeeds adopts the reporter on retry" do
      # A fake reporter process to 'adopt' on the 2nd start. It must outlive the retry.
      reporter = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(reporter), do: Process.exit(reporter, :kill) end)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      start_fun = fn _opts ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if n == 0, do: {:error, :eaddrinuse}, else: {:ok, reporter}
      end

      pid = start_wrapper(start_fun)

      # First start failed → no pid yet.
      assert state(pid).pid == nil

      # Drive the retry deterministically (the real timer is 30s) — the retry succeeds and
      # the wrapper adopts the reporter pid.
      send(pid, :retry_start)

      # Give the message a beat to process.
      _ = :sys.get_state(pid)
      assert state(pid).pid == reporter
    end

    test "retry is single-flight: a retry that finds a live reporter is a no-op" do
      reporter = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(reporter), do: Process.exit(reporter, :kill) end)

      pid = start_wrapper(fn _opts -> {:ok, reporter} end)
      assert state(pid).pid == reporter

      # A spurious retry must not start a second reporter or change the adopted pid.
      send(pid, :retry_start)
      _ = :sys.get_state(pid)
      assert state(pid).pid == reporter
    end
  end

  describe "{:already_started, pid} adoption is monitored" do
    test "an adopted (already-started) reporter's death schedules a retry" do
      # Simulate another process already owning the port: start_fun returns
      # {:error, {:already_started, pid}}. The wrapper must MONITOR it (it is not linked),
      # so when it dies the wrapper detects it and clears its pid (scheduling a retry).
      reporter = spawn(fn -> Process.sleep(:infinity) end)

      pid = start_wrapper(fn _opts -> {:error, {:already_started, reporter}} end)
      assert state(pid).pid == reporter

      # Kill the adopted reporter; the :DOWN must reach the wrapper and clear its pid.
      Process.exit(reporter, :kill)

      # Poll briefly for the DOWN to be processed.
      assert eventually(fn -> state(pid).pid == nil end)
      # And the wrapper itself survived (isolation held).
      assert Process.alive?(pid)
    end
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, retries - 1)
    end
  end
end
