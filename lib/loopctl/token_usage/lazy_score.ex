defmodule Loopctl.TokenUsage.LazyScore do
  @moduledoc """
  US-26.6.2 — Computes the "lazy-bastard" score for a story implementation.

  The score is a heuristic based on:
  - Token usage relative to story estimated hours
  - Tool call count (low = suspicious)
  - CoT length (very short = suspicious)
  - Tests run count (zero = suspicious)

  Stories above the threshold are flagged for re-review.
  """

  @threshold 0.7

  @doc """
  Computes a laziness score between 0.0 (thorough) and 1.0 (suspicious).

  ## Parameters

  - `metrics` — map with optional keys:
    - `:total_tokens` — total tokens consumed
    - `:estimated_hours` — story estimated hours
    - `:tool_call_count` — number of tool calls
    - `:cot_length_tokens` — chain-of-thought token count
    - `:tests_run_count` — number of tests executed

  ## Returns

  `{score, reasons}` where score is 0.0–1.0 and reasons is a list of
  strings explaining contributing factors.
  """
  @spec compute(map()) :: {float(), [String.t()]}
  def compute(metrics) do
    factors = [
      check_token_ratio(metrics),
      check_tool_calls(metrics),
      check_cot_length(metrics),
      check_tests_run(metrics)
    ]

    active = Enum.reject(factors, &is_nil/1)

    if active == [] do
      {0.0, []}
    else
      score = Enum.sum(Enum.map(active, &elem(&1, 0))) / length(active)
      reasons = Enum.flat_map(active, &elem(&1, 1))
      {Float.round(score, 2), reasons}
    end
  end

  @doc "Returns the threshold above which stories are flagged for re-review."
  @spec threshold() :: float()
  def threshold, do: @threshold

  @doc "Returns true if the score exceeds the re-review threshold."
  @spec flagged?(float()) :: boolean()
  def flagged?(score), do: score > @threshold

  # --- Factor checks ---

  defp check_token_ratio(%{total_tokens: tokens, estimated_hours: hours})
       when is_number(tokens) and is_number(hours) and hours > 0 do
    # Expected: ~10K tokens per estimated hour
    expected = hours * 10_000
    ratio = tokens / expected

    if ratio < 0.2 do
      {0.8, ["Token usage is #{Float.round(ratio * 100, 0)}% of expected"]}
    else
      nil
    end
  end

  defp check_token_ratio(_), do: nil

  defp check_tool_calls(%{tool_call_count: count}) when is_integer(count) do
    if count < 5 do
      {0.9, ["Only #{count} tool calls (suspiciously low)"]}
    else
      nil
    end
  end

  defp check_tool_calls(_), do: nil

  defp check_cot_length(%{cot_length_tokens: cot}) when is_integer(cot) do
    if cot < 100 do
      {0.7, ["CoT length #{cot} tokens (minimal reasoning)"]}
    else
      nil
    end
  end

  defp check_cot_length(_), do: nil

  defp check_tests_run(%{tests_run_count: 0}) do
    {1.0, ["Zero tests executed"]}
  end

  defp check_tests_run(%{tests_run_count: count}) when is_integer(count) and count < 3 do
    {0.6, ["Only #{count} tests run"]}
  end

  defp check_tests_run(_), do: nil
end
