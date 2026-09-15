defmodule Loopctl.Workers.DispatchDriverWorkerTest do
  @moduledoc """
  The cron caller of `Loopctl.Delivery.DispatchDriver.run/1` (#803 §3).

  The placing behaviour is `Loopctl.Delivery.DispatchDriverTest`'s; what is asserted here is
  the JOB — what an operator's Oban dashboard is told about a pass. `async: true` and
  sandboxed, because everything below either runs the disabled path (which touches no row) or
  is a pure function of a pass's outcomes.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Workers.DispatchDriverWorker

  setup :verify_on_exit!

  describe "perform/1" do
    test "a pass with the driver off is a successful job that places nothing" do
      # The state every deploy is in until an operator sets `:dispatch_driver_enabled`, which
      # no environment does — including this one. The entry is in the crontab from the moment
      # it ships, so this is the behaviour that actually runs every minute in production
      # today, and it must be a clean run rather than an error nobody can act on.
      assert DispatchDriverWorker.perform(%Oban.Job{args: %{}}) == :ok
    end
  end

  describe "run_result/1" do
    test "a pass where EVERY candidate errored fails the job" do
      # The one outcome no fixture can produce, and the one that must not report as a clean
      # run: on a connection-pool outage every candidate raises, the per-story rescue swallows
      # each, and an `:ok` here means Oban records success — no retry, nothing discarded,
      # nothing alerting, while the queue stops draining.
      assert DispatchDriverWorker.run_result([:errored, :errored]) ==
               {:error, {:all_candidates_errored, 2}}
    end

    test "a pass with some progress is a successful job" do
      # The one-bad-story case the per-story rescue exists for. Failing the job here would
      # retry a whole batch to re-place stories that are already claimed and running.
      assert DispatchDriverWorker.run_result([:errored, :placed]) == :ok
    end

    test "a pass that placed NOTHING for want of a runner is still a successful job" do
      # The ordinary state of a fleet with nothing connected — nobody is working right now.
      # A job that failed on it would retry, alert and eventually discard, every minute,
      # for a condition that is not a fault at all.
      assert DispatchDriverWorker.run_result([:no_runner, :no_runner]) == :ok
      assert DispatchDriverWorker.run_result([:unplaceable]) == :ok
    end

    test "an empty pass is a successful job" do
      # An empty queue is the steady state, not a failure — and `count == count` would make
      # zero-of-zero "every candidate errored" without the positive guard.
      assert DispatchDriverWorker.run_result([]) == :ok
    end
  end

  describe "batch_size/0" do
    test "the pass is bounded" do
      # Bounded per run, like every other drainer in this loop: the read is oldest-first, so
      # a remainder is simply the next pass's first candidates and a backlog drains in order.
      # An unbounded pass would hold AdminRepo's three-connection pool for as long as the
      # queue is long — the pool every authenticated request in the fleet also needs.
      assert DispatchDriverWorker.batch_size() > 0
      assert DispatchDriverWorker.batch_size() <= 100
    end
  end
end
