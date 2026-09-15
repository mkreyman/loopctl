defmodule Loopctl.Workers.StoryCompletionWorkerTest do
  @moduledoc """
  The cron half of the loop's last transition (#803 §3).

  `Loopctl.Delivery.CompletionTest` binds the selection and the settlement rule. What is here
  is the WORKER's own contract, which that module cannot state: which outcomes are a clean run
  and which one must NOT be, because a sweep that reports `:ok` while completing nothing is
  indistinguishable from an empty queue — and that indistinguishability is exactly how
  `verified` stayed absorbing without anyone noticing.

  `run_result/1` is pure, so this file is `async: true` and touches no database.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Workers.StoryCompletionWorker

  describe "run_result/1" do
    test "an empty pass is a clean run" do
      # Nothing at `verified` is the ordinary state of a fleet whose stories are still in
      # flight, and it is not a fault.
      assert StoryCompletionWorker.run_result([]) == :ok
    end

    test "completing stories is a clean run" do
      assert StoryCompletionWorker.run_result([:completed, :completed]) == :ok
    end

    test "a pass that only RACED is clean — that is two nodes sweeping, working" do
      # `:stale_stage` on every candidate means another node got there first. Reporting that
      # as a failure would make a healthy multi-node fleet look broken, and would retry a
      # batch that is already done.
      assert StoryCompletionWorker.run_result([:raced, :raced]) == :ok
    end

    test "a pass that only WAITED is clean — the drainer has not settled them yet" do
      # Every candidate's closure went `:pending` between the read and the write. The reporter
      # is still owed a comment; the next pass asks again. Nothing here needs a person.
      assert StoryCompletionWorker.run_result([:waiting]) == :ok
    end

    test "a pass where EVERY candidate errored is NOT a clean run" do
      # The assertion that keeps this worker honest. A systemic failure — a broken chain
      # append, a database refusing the write — must surface as a failed job rather than as a
      # quiet `:ok`, which is the shape that hid the missing writer in the first place.
      assert StoryCompletionWorker.run_result([:errored, :errored]) ==
               {:error, {:all_candidates_errored, 2}}
    end

    test "one error beside real progress is NOT a failed pass" do
      # One story failing must not fail the pass and make Oban retry the batch: the read is
      # oldest-first, so the same candidate would head every retry and the ones behind it
      # would starve. The error is already logged naming the tenant and the story.
      assert StoryCompletionWorker.run_result([:errored, :completed]) == :ok
    end
  end

  describe "the batch bound" do
    test "a pass is bounded, so one sweep cannot take the whole table" do
      assert StoryCompletionWorker.batch_size() > 0
      assert StoryCompletionWorker.batch_size() <= 200
    end
  end
end
