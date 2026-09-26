defmodule Loopctl.Workers.TriageDispatchWorkerTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.Workers.TriageDispatchWorker

  describe "run_result/1" do
    test "a pass whose every candidate errored is a failed job" do
      assert {:error, {:all_candidates_errored, 2}} =
               TriageDispatchWorker.run_result([:errored, :errored])
    end

    # #884 review round 1, finding 2. A stranded row whose escalation keeps failing reappears
    # every pass, refused (:blocked) or raising; counted in the total it hid a systemic candidate
    # failure for ever.
    test "a failing stranded row does not hide a pass whose every candidate errored" do
      assert {:error, {:all_candidates_errored, 2}} =
               TriageDispatchWorker.run_result([:errored, {:stranded, :blocked}, :errored])
    end

    test "failing stranded rows alone do not fail the pass" do
      assert :ok = TriageDispatchWorker.run_result([{:stranded, :errored}, {:stranded, :blocked}])
    end

    test "one candidate that did not error keeps the pass clean" do
      assert :ok = TriageDispatchWorker.run_result([:errored, :dispatched])
    end
  end
end
