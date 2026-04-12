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
end
