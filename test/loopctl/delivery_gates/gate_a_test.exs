defmodule Loopctl.DeliveryGates.GateATest do
  use ExUnit.Case, async: true

  import Loopctl.Fixtures

  alias Loopctl.DeliveryGates
  alias Loopctl.DeliveryGates.GateA
  alias Loopctl.DeliveryGates.GateA.Result

  defp trio(overrides \\ [%{}, %{}, %{}]) do
    Enum.map(overrides, &build(:trio_output, &1))
  end

  defp kinds(%Result{reasons: reasons}), do: Enum.map(reasons, &elem(&1, 0))

  describe "proceeds" do
    test "on three uncontested story verdicts" do
      assert %Result{decision: :proceed, verdict: :story, reasons: []} = GateA.evaluate(trio())
    end

    test "on three unanimous reject verdicts" do
      outputs = trio(List.duplicate(%{"verdict" => "reject"}, 3))
      assert %Result{decision: :proceed, verdict: :reject, reasons: []} = GateA.evaluate(outputs)
    end

    test "through the facade" do
      assert %Result{decision: :proceed} = DeliveryGates.gate_a(trio())
    end

    test "on a soft escalation reason code, which is recorded and does not gate" do
      outputs = trio([%{"escalation_reasons" => ["touches_claims_path"]}, %{}, %{}])

      assert %Result{decision: :proceed, soft_signals: [{0, "touches_claims_path"}]} =
               GateA.evaluate(outputs)
    end
  end

  describe "confidence is recorded and never gates" do
    test "zero confidence on every agent still proceeds" do
      outputs = trio(List.duplicate(%{"confidence" => 0.0}, 3))

      assert %Result{decision: :proceed, confidences: [+0.0, +0.0, +0.0]} =
               GateA.evaluate(outputs)
    end

    test "full confidence does not clear an escalation" do
      outputs =
        trio([%{"confidence" => 1}, %{"confidence" => 1, "verdict" => "escalate"}, %{}])

      assert %Result{decision: :escalate, confidences: [1, 1, 0.8]} = GateA.evaluate(outputs)
    end
  end

  describe "escalates on the trio's shape (fail closed)" do
    test "fewer or more than three outputs" do
      assert %Result{decision: :escalate, reasons: [{:trio_size, 2}]} =
               GateA.evaluate(trio([%{}, %{}]))

      assert %Result{decision: :escalate, reasons: [{:trio_size, 4}]} =
               GateA.evaluate(trio([%{}, %{}, %{}, %{}]))

      assert %Result{decision: :escalate, reasons: [{:trio_size, 0}]} = GateA.evaluate([])
    end

    test "not a list" do
      assert %Result{decision: :escalate, reasons: [{:trio_size, :not_a_list}]} =
               GateA.evaluate(nil)

      assert %Result{decision: :escalate} = GateA.evaluate(%{"verdict" => "story"})
    end

    test "an output that is not a map" do
      assert %Result{decision: :escalate, reasons: [{:malformed_output, 1, :not_a_map}]} =
               GateA.evaluate([build(:trio_output), "story", build(:trio_output)])
    end

    test "a missing required key" do
      for key <- ~w(verdict escalation_reasons contradicts confidence) do
        outputs = [Map.delete(build(:trio_output), key), build(:trio_output), build(:trio_output)]

        assert %Result{decision: :escalate, reasons: [{:malformed_output, 0, {:missing, ^key}}]} =
                 GateA.evaluate(outputs)
      end
    end

    test "an invalid value for each required key" do
      cases = [
        {"verdict", "approve"},
        {"verdict", nil},
        {"escalation_reasons", "workflow_change_not_defect_fix"},
        {"escalation_reasons", [:atom]},
        {"contradicts", nil},
        {"contradicts", [%{"kind" => "rumour", "ref" => "x", "why" => "y"}]},
        {"contradicts", [%{"kind" => "story", "ref" => "x"}]},
        {"confidence", 1.5},
        {"confidence", -0.1},
        {"confidence", "0.9"}
      ]

      for {key, value} <- cases do
        outputs = trio([%{}, %{}, %{key => value}])

        assert %Result{
                 decision: :escalate,
                 reasons: [{:malformed_output, 2, {:invalid, ^key}}],
                 confidences: [0.8, 0.8, nil]
               } = GateA.evaluate(outputs),
               "expected #{key} = #{inspect(value)} to be malformed"
      end
    end
  end

  describe "escalates on the request" do
    test "when the verdicts disagree" do
      outputs = trio([%{}, %{"verdict" => "reject"}, %{}])

      assert %Result{
               decision: :escalate,
               verdict: nil,
               reasons: [{:verdict_disagreement, [:story, :reject, :story]}]
             } = GateA.evaluate(outputs)
    end

    test "when any one agent's verdict is escalate" do
      for index <- 0..2 do
        overrides = List.replace_at([%{}, %{}, %{}], index, %{"verdict" => "escalate"})
        result = GateA.evaluate(trio(overrides))

        assert result.decision == :escalate
        assert {:agent_escalated, index} in result.reasons
      end
    end

    test "when all three agree to escalate" do
      outputs = trio(List.duplicate(%{"verdict" => "escalate"}, 3))
      result = GateA.evaluate(outputs)

      assert result.decision == :escalate
      assert result.verdict == nil
      assert kinds(result) == [:agent_escalated, :agent_escalated, :agent_escalated]
    end

    test "when any agent reports a contradiction, even with a story verdict" do
      contradiction = %{"kind" => "kb", "ref" => "decision-123", "why" => "reverses it"}
      outputs = trio([%{}, %{}, %{"contradicts" => [contradiction]}])

      assert %Result{decision: :escalate, reasons: [{:contradiction, 2, [^contradiction]}]} =
               GateA.evaluate(outputs)
    end

    test "on each contradiction kind" do
      for kind <- ~w(story kb code) do
        outputs =
          trio([%{"contradicts" => [%{"kind" => kind, "ref" => "r", "why" => "w"}]}, %{}, %{}])

        assert %Result{decision: :escalate} = GateA.evaluate(outputs)
      end
    end

    test "when a reason says the request inverts or removes deliberately-added behaviour" do
      outputs =
        trio([%{}, %{"escalation_reasons" => ["inverts_or_removes_deliberate_behaviour"]}, %{}])

      assert %Result{decision: :escalate, reasons: [{:inverts_deliberate_behaviour, 1}]} =
               GateA.evaluate(outputs)
    end

    test "when a reason says the request is a workflow change rather than a defect fix" do
      outputs = trio([%{"escalation_reasons" => ["workflow_change_not_defect_fix"]}, %{}, %{}])

      assert %Result{decision: :escalate, reasons: [{:workflow_change, 0}]} =
               GateA.evaluate(outputs)
    end

    test "the gating codes are the documented contract strings" do
      assert Enum.sort(GateA.gating_reason_codes()) ==
               ["inverts_or_removes_deliberate_behaviour", "workflow_change_not_defect_fix"]
    end

    test "a malformed output and a valid disagreement are both reported" do
      outputs = [build(:trio_output), :garbage, build(:trio_output, %{"verdict" => "reject"})]
      result = GateA.evaluate(outputs)

      assert result.decision == :escalate
      assert kinds(result) == [:malformed_output, :verdict_disagreement]
    end
  end

  test "reads no file path: identical requests with different predicted touches decide the same" do
    a = trio([%{"story" => %{"touches" => ["lib/app/payments/submit.ex"]}}, %{}, %{}])
    b = trio([%{"story" => %{"touches" => ["README.md"]}}, %{}, %{}])

    assert GateA.evaluate(a) == GateA.evaluate(b)
  end

  describe "rate/1" do
    test "reports escalated over total, and counts each reason kind once per result" do
      contradiction = %{"kind" => "story", "ref" => "US-1", "why" => "w"}

      results = [
        GateA.evaluate(trio()),
        GateA.evaluate(trio()),
        GateA.evaluate(
          trio([%{"contradicts" => [contradiction]}, %{"contradicts" => [contradiction]}, %{}])
        ),
        GateA.evaluate(trio([%{"verdict" => "reject"}, %{}, %{}]))
      ]

      assert DeliveryGates.gate_a_rate(results) == %{
               total: 4,
               escalated: 2,
               rate: 0.5,
               by_reason: %{contradiction: 1, verdict_disagreement: 1}
             }
    end

    test "an empty set has no rate rather than a zero rate" do
      assert GateA.rate([]) == %{total: 0, escalated: 0, rate: nil, by_reason: %{}}
    end
  end
end
