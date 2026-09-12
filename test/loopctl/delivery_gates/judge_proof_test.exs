defmodule Loopctl.DeliveryGates.JudgeProofTest do
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates
  alias Loopctl.DeliveryGates.GateB
  alias Loopctl.DeliveryGates.GateB.ProofResult

  @covered %{required: ["T1019", "U2", "HCBS"], covered: ["HCBS", "T1019", "U2", "S5125"]}

  defp pass?(%ProofResult{verdict: :pass, failures: [], route: nil}), do: true
  defp pass?(%ProofResult{}), do: false

  describe "passes" do
    test "when exactly the intended fixtures changed" do
      results = %{"f-rate" => :changed, "f-mod" => :changed, "f-other" => :unchanged}
      assert pass?(GateB.judge_proof({:changes, ["f-rate", "f-mod"]}, results, @covered))
    end

    test "when no output change was intended and none happened" do
      results = %{"f-rate" => :unchanged, "f-other" => :unchanged}
      assert pass?(GateB.judge_proof(:no_output_change, results, @covered))
    end

    test "through the facade" do
      assert pass?(
               DeliveryGates.judge_proof({:changes, ["a"]}, %{"a" => :changed}, %{
                 required: ["X"],
                 covered: ["X"]
               })
             )
    end
  end

  describe "fails on the intended half, and routes to Gate A" do
    test "an intended fixture that did not change: nothing changed is not a pass" do
      results = %{"f-rate" => :unchanged, "f-other" => :unchanged}

      assert %ProofResult{
               verdict: :fail,
               route: :gate_a,
               failures: [{:intended_fixture_unchanged, ["f-rate"]}]
             } = GateB.judge_proof({:changes, ["f-rate"]}, results, @covered)
    end

    test "one of several intended fixtures did not change" do
      results = %{"f-a" => :changed, "f-b" => :unchanged}

      assert %ProofResult{verdict: :fail, failures: [{:intended_fixture_unchanged, ["f-b"]}]} =
               GateB.judge_proof({:changes, ["f-a", "f-b"]}, results, @covered)
    end

    test "an intended fixture that did not run" do
      results = %{"f-other" => :unchanged}

      assert %ProofResult{verdict: :fail, failures: [{:intended_fixture_not_run, ["f-rate"]}]} =
               GateB.judge_proof({:changes, ["f-rate"]}, results, @covered)
    end
  end

  describe "fails on the unintended half, and routes to Gate A" do
    test "a fixture changed that was not intended" do
      results = %{"f-rate" => :changed, "f-other" => :changed}

      assert %ProofResult{
               verdict: :fail,
               route: :gate_a,
               failures: [{:unintended_fixture_changed, ["f-other"]}]
             } = GateB.judge_proof({:changes, ["f-rate"]}, results, @covered)
    end

    test "any change when no output change was intended" do
      results = %{"f-rate" => :unchanged, "f-other" => :changed}

      assert %ProofResult{verdict: :fail, failures: [{:unintended_fixture_changed, ["f-other"]}]} =
               GateB.judge_proof(:no_output_change, results, @covered)
    end

    test "both halves at once are both reported" do
      results = %{"f-rate" => :unchanged, "f-other" => :changed}

      assert %ProofResult{
               verdict: :fail,
               failures: [
                 {:intended_fixture_unchanged, ["f-rate"]},
                 {:unintended_fixture_changed, ["f-other"]}
               ]
             } = GateB.judge_proof({:changes, ["f-rate"]}, results, @covered)
    end
  end

  describe "fixture coverage" do
    test "a required code no fixture exercises fails, naming the uncovered codes" do
      coverage = %{required: ["T1019", "U2", "H0038", "HX"], covered: ["T1019", "U2"]}

      assert %ProofResult{
               verdict: :fail,
               route: :gate_a,
               failures: [{:uncovered_codes, ["H0038", "HX"]}]
             } =
               GateB.judge_proof(:no_output_change, %{"f" => :unchanged}, coverage)
    end

    test "fails even when the fixture diff is exactly as intended" do
      coverage = %{required: ["NEW1"], covered: []}

      assert %ProofResult{verdict: :fail, failures: [{:uncovered_codes, ["NEW1"]}]} =
               GateB.judge_proof({:changes, ["f"]}, %{"f" => :changed}, coverage)
    end

    test "malformed or empty coverage fails" do
      for bad <- [
            nil,
            %{},
            %{required: [], covered: []},
            %{required: ["X"]},
            %{required: "X", covered: ["X"]}
          ] do
        assert %ProofResult{verdict: :fail, failures: [{:invalid_coverage, ^bad}]} =
                 GateB.judge_proof(:no_output_change, %{"f" => :unchanged}, bad)
      end
    end
  end

  describe "fails closed on malformed input" do
    test "an intent that is neither {:changes, non-empty ids} nor :no_output_change" do
      for bad <- [
            nil,
            :changes,
            {:changes, []},
            {:changes, "f"},
            {:changes, [:f]},
            {:no_output_change}
          ] do
        assert %ProofResult{verdict: :fail, route: :gate_a, failures: [{:invalid_intent, ^bad}]} =
                 GateB.judge_proof(bad, %{"f" => :changed}, @covered)
      end
    end

    test "fixture results that are empty, not a map, or carry another state" do
      for bad <- [
            %{},
            nil,
            [{"f", :changed}],
            %{"f" => :different},
            %{"f" => true},
            %{f: :changed}
          ] do
        assert %ProofResult{verdict: :fail, failures: [{:invalid_fixture_results, ^bad}]} =
                 GateB.judge_proof(:no_output_change, bad, @covered)
      end
    end
  end
end
