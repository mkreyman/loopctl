defmodule Loopctl.TokenUsage.LazyScoreTest do
  use ExUnit.Case, async: true

  alias Loopctl.TokenUsage.LazyScore

  test "thorough work scores near 0" do
    {score, reasons} =
      LazyScore.compute(%{
        total_tokens: 50_000,
        estimated_hours: 5,
        tool_call_count: 100,
        cot_length_tokens: 5000,
        tests_run_count: 25
      })

    assert score < 0.3
    assert reasons == []
  end

  test "lazy work with zero tests flags" do
    {score, reasons} =
      LazyScore.compute(%{
        total_tokens: 1000,
        estimated_hours: 8,
        tool_call_count: 2,
        cot_length_tokens: 50,
        tests_run_count: 0
      })

    assert score > LazyScore.threshold()
    assert LazyScore.flagged?(score)
    assert Enum.any?(reasons, &String.contains?(&1, "Zero tests"))
  end

  test "empty metrics score 0" do
    {score, _} = LazyScore.compute(%{})
    assert score == 0.0
  end

  describe "compute/1 with a Decimal estimated_hours (worker-02)" do
    # `estimated_hours` is `:decimal` in the Story schema. A caller that reads
    # it schemaless (or straight off the struct) hands LazyScore a %Decimal{}.
    # Pre-fix, the `is_number/1` guards silently rejected it, disabling the
    # token-ratio factor and the small-story exemption. These tests assert the
    # factors ENGAGE for a Decimal input, not the buggy pass-through.

    test "token-ratio factor engages for a Decimal estimated_hours" do
      # Only the token-ratio factor is active (the other three are nil), so the
      # score equals that factor's weight exactly. Pre-fix this returned
      # {0.0, []} because the Decimal disabled the sole active factor.
      {score, reasons} =
        LazyScore.compute(%{
          total_tokens: 1_000,
          estimated_hours: Decimal.new("8"),
          tool_call_count: 100,
          cot_length_tokens: 5_000,
          tests_run_count: 25
        })

      assert score == 0.8
      assert Enum.any?(reasons, &String.contains?(&1, "Token usage is"))
    end

    test "small-story exemption engages for a Decimal estimated_hours <= 1" do
      # A sub-1-hour story is exempt — floor 0.0, no reasons — even though every
      # raw factor screams "lazy". Pre-fix, the Decimal failed the exemption
      # guard so this scored ~0.87 instead.
      {score, reasons} =
        LazyScore.compute(%{
          total_tokens: 1_000,
          estimated_hours: Decimal.new("0.5"),
          tool_call_count: 0,
          cot_length_tokens: 10,
          tests_run_count: 0
        })

      assert score == 0.0
      assert reasons == []
    end

    test "Decimal and float estimated_hours produce identical scores" do
      metrics = fn hours ->
        %{
          total_tokens: 1_000,
          estimated_hours: hours,
          tool_call_count: 100,
          cot_length_tokens: 5_000,
          tests_run_count: 25
        }
      end

      assert LazyScore.compute(metrics.(Decimal.new("8"))) ==
               LazyScore.compute(metrics.(8.0))
    end
  end
end
