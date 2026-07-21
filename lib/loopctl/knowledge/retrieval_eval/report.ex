defmodule Loopctl.Knowledge.RetrievalEval.Report do
  @moduledoc """
  Human-readable rendering of a `Loopctl.Knowledge.RetrievalEval` result (#469 AC-1/AC-3).

  Rendering is a PURE function of the result (+ optional baseline comparison) so the
  table can be asserted in tests without running a mix task. Every number is nil-safe:
  an UNDEFINED metric prints as `n/a`, never as `0.0` — the two mean different things
  (see the `RetrievalEval` moduledoc) and a report that flattens them would hide an
  unscoreable question behind a plausible-looking zero.
  """

  alias Loopctl.Knowledge.RetrievalEval.Baseline

  @doc """
  Render the full report: the mode it ran in, the aggregate metrics, the
  with-retrieval-vs-none headline spread, and the per-question table (with baseline
  deltas when a comparison is supplied).
  """
  @spec render(map(), map() | nil) :: String.t()
  def render(result, comparison \\ nil) do
    [
      header(result),
      "",
      aggregate_section(result, comparison),
      "",
      headline_section(result),
      "",
      question_table(result, comparison),
      "",
      baseline_section(comparison)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp header(result) do
    reasons =
      case result.fallback_reasons do
        empty when empty == %{} ->
          "none"

        map ->
          Enum.map_join(map, ", ", fn {reason, n} -> "#{reason} x#{n}" end)
      end

    """
    Retrieval eval — golden set #{result.golden_version}
      requested mode : #{result.mode}
      observed mode  : #{result.observed_mode}
      fallback reason: #{reasons}
      questions      : #{result.question_count}\
    """
  end

  defp aggregate_section(result, comparison) do
    rows =
      Enum.map(result.k_values, fn k ->
        {"recall@#{k}", result.recall_at_k[k]}
      end) ++
        Enum.map(result.k_values, fn k -> {"ndcg@#{k}", result.ndcg_at_k[k]} end) ++
        [{"mrr", result.mrr}]

    baseline_by_metric =
      case comparison do
        %{aggregate: aggregate} -> Map.new(aggregate, &{&1.metric, &1})
        _ -> %{}
      end

    body =
      Enum.map_join(rows, "\n", fn {metric, value} ->
        base = Map.get(baseline_by_metric, metric)

        "  #{pad(metric, 12)} #{pad(fmt(value), 8)} " <>
          "base=#{pad(fmt(base && base.baseline), 8)} " <>
          "delta=#{pad(fmt_delta(base && base.delta), 9)}#{regression_flag(base)}"
      end)

    "AGGREGATE\n" <> body
  end

  # The Cerebras framing (#469 scope 4): questions answered WITH retrieval versus the
  # no-retrieval arm, which is 0 by construction (an empty result set retrieves nothing).
  defp headline_section(result) do
    """
    HEADLINE (with retrieval vs none)
      answered@#{result.answered_k} : #{result.answered}/#{result.question_count} with retrieval, \
    #{result.no_retrieval.answered}/#{result.question_count} without (spread #{result.spread.answered})
      mrr           : #{fmt(result.mrr)} vs #{fmt(result.no_retrieval.mrr)} \
    (spread #{fmt_delta(result.spread.mrr)})\
    """
  end

  defp question_table(result, comparison) do
    deltas =
      case comparison do
        %{questions: questions} -> Map.new(questions, &{&1.id, &1})
        _ -> %{}
      end

    primary_k = Enum.min(result.k_values)

    header =
      "  #{pad("question", 28)} #{pad("mode", 12)} #{pad("r@#{primary_k}", 7)} " <>
        "#{pad("mrr", 7)} #{pad("ndcg@#{primary_k}", 9)} #{pad("d.mrr", 9)}"

    rows =
      Enum.map_join(result.question_results, "\n", fn q ->
        d = Map.get(deltas, q.id)

        "  #{pad(q.id, 28)} #{pad(q.observed_mode, 12)} " <>
          "#{pad(fmt(q.recall_at_k[primary_k]), 7)} #{pad(fmt(q.mrr), 7)} " <>
          "#{pad(fmt(q.ndcg_at_k[primary_k]), 9)} #{pad(fmt_delta(d && d.mrr_delta), 9)}"
      end)

    "PER-QUESTION\n" <> header <> "\n" <> rows
  end

  defp baseline_section(nil), do: nil

  defp baseline_section(%{status: :missing_mode, golden_version: gv}) do
    "BASELINE\n  no baseline entry for this mode (golden #{gv.baseline || "n/a"}) — nothing to compare"
  end

  defp baseline_section(%{status: :golden_version_mismatch, golden_version: gv}) do
    "BASELINE\n  golden set version changed (#{gv.baseline} -> #{gv.current}) — re-baseline before comparing"
  end

  defp baseline_section(%{status: :ok} = comparison) do
    "BASELINE\n  status: OK (no regression)\n" <> winners_losers(comparison)
  end

  defp baseline_section(%{status: :regression} = comparison) do
    "BASELINE\n  status: REGRESSION in #{Enum.join(comparison.regressions, ", ")}\n" <>
      winners_losers(comparison)
  end

  defp winners_losers(comparison) do
    "  winners: #{list(comparison.winners)}\n  losers : #{list(comparison.losers)}"
  end

  defp list([]), do: "none"
  defp list(ids), do: Enum.join(ids, ", ")

  defp regression_flag(%{regression?: true}), do: "  REGRESSION"
  defp regression_flag(_), do: ""

  @doc "Format a metric value: `n/a` for an undefined (nil) metric, never `0.000`."
  @spec fmt(number() | nil) :: String.t()
  def fmt(nil), do: "n/a"
  def fmt(value) when is_integer(value), do: Integer.to_string(value)
  def fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)

  @doc "Format a delta with an explicit sign; `n/a` when undefined."
  @spec fmt_delta(number() | nil) :: String.t()
  def fmt_delta(nil), do: "n/a"
  def fmt_delta(value) when value >= 0, do: "+" <> fmt(value)
  def fmt_delta(value), do: fmt(value)

  defp pad(value, width), do: String.pad_trailing(to_string(value), width)

  @doc """
  A machine-readable (JSON-encodable) view of a result plus its baseline comparison,
  for `--json`.
  """
  @spec to_json_map(map(), map() | nil) :: map()
  def to_json_map(result, comparison \\ nil) do
    %{
      "golden_version" => result.golden_version,
      "mode" => to_string(result.mode),
      "observed_mode" => result.observed_mode,
      "fallback_reasons" => result.fallback_reasons,
      "question_count" => result.question_count,
      "answered" => result.answered,
      "answered_k" => result.answered_k,
      "mrr" => result.mrr,
      "recall_at_k" => keys_to_strings(result.recall_at_k),
      "ndcg_at_k" => keys_to_strings(result.ndcg_at_k),
      "no_retrieval" => %{
        "answered" => result.no_retrieval.answered,
        "mrr" => result.no_retrieval.mrr,
        "recall_at_k" => keys_to_strings(result.no_retrieval.recall_at_k),
        "ndcg_at_k" => keys_to_strings(result.no_retrieval.ndcg_at_k)
      },
      "spread" => %{
        "answered" => result.spread.answered,
        "mrr" => result.spread.mrr,
        "recall_at_k" => keys_to_strings(result.spread.recall_at_k),
        "ndcg_at_k" => keys_to_strings(result.spread.ndcg_at_k)
      },
      "questions" =>
        Enum.map(result.question_results, fn q ->
          %{
            "id" => q.id,
            "observed_mode" => q.observed_mode,
            "fallback_reason" => q.fallback_reason,
            "mrr" => q.mrr,
            "recall_at_k" => keys_to_strings(q.recall_at_k),
            "ndcg_at_k" => keys_to_strings(q.ndcg_at_k),
            "answered" => q.answered
          }
        end),
      "baseline" => comparison_json(comparison)
    }
  end

  defp comparison_json(nil), do: nil

  defp comparison_json(comparison) do
    %{
      "status" => to_string(comparison.status),
      "regressions" => comparison.regressions,
      "winners" => comparison.winners,
      "losers" => comparison.losers,
      "aggregate" =>
        Enum.map(comparison.aggregate, fn row ->
          %{
            "metric" => row.metric,
            "current" => row.current,
            "baseline" => row.baseline,
            "delta" => row.delta,
            "regression" => row.regression?
          }
        end)
    }
  end

  defp keys_to_strings(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  @doc "The baseline default tolerance, surfaced for the mix task's help output."
  @spec default_tolerance() :: float()
  def default_tolerance, do: Baseline.default_tolerance()
end
