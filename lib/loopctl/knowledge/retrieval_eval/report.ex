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
    # `answered@k` is the headline numerator AND the strictest gate check (compared with
    # zero tolerance), so it is the metric most likely to regress alone — it MUST carry a
    # REGRESSION flag in the table an operator reads first, not only in the one-line
    # BASELINE status.
    rows =
      Enum.map(result.k_values, fn k ->
        {"recall@#{k}", result.recall_at_k[k]}
      end) ++
        Enum.map(result.k_values, fn k -> {"ndcg@#{k}", result.ndcg_at_k[k]} end) ++
        [{"mrr", result.mrr}, {"answered@#{result.answered_k}", result.answered}]

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
  # no-retrieval arm. The without-arm is 0 BY CONSTRUCTION (retrieval disabled = an empty
  # result set = nothing retrieved), not a measured A/B — it is the definitional floor the
  # with-retrieval numbers are read against, and it can never move. The line says so
  # explicitly so a skimming reader does not mistake a tautology for a measurement.
  defp headline_section(result) do
    """
    HEADLINE (with retrieval vs none — the "none" arm is 0 by construction, not measured)
      answered@#{result.answered_k} : #{result.answered}/#{result.question_count} with retrieval, \
    #{result.no_retrieval.answered}/#{result.question_count} without = 0 by construction \
    (spread #{result.spread.answered})
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

    # Render the recall@k and nDCG@k deltas alongside d.mrr, not just d.mrr: a fusion
    # change can lift the first-hit rank (d.mrr up) while dropping a second relevant doc
    # out of the top-k (d.recall down). MRR-only would render that as an all-winners table
    # with no loser — the opposite of the tradeoff signal the table exists to give.
    header =
      "  #{pad("question", 28)} #{pad("mode", 12)} #{pad("r@#{primary_k}", 7)} " <>
        "#{pad("mrr", 7)} #{pad("ndcg@#{primary_k}", 9)} " <>
        "#{pad("d.mrr", 9)} #{pad("d.r@#{primary_k}", 9)} #{pad("d.ndcg@#{primary_k}", 11)}"

    rows =
      Enum.map_join(result.question_results, "\n", fn q ->
        d = Map.get(deltas, q.id)

        "  #{pad(q.id, 28)} #{pad(q.observed_mode, 12)} " <>
          "#{pad(fmt(q.recall_at_k[primary_k]), 7)} #{pad(fmt(q.mrr), 7)} " <>
          "#{pad(fmt(q.ndcg_at_k[primary_k]), 9)} #{pad(fmt_delta(d && d.mrr_delta), 9)} " <>
          "#{pad(fmt_delta(d && d.recall_delta[primary_k]), 9)} " <>
          "#{pad(fmt_delta(d && d.ndcg_delta[primary_k]), 11)}"
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

  # The aggregates are genuinely not comparable across two question sets, so this still
  # fails the gate. What it must NOT do is stop there: every question present on BOTH sides
  # is still comparable, and the losers among them are exactly what a re-baseline is about
  # to absorb. Printing them is the whole point of this branch.
  defp baseline_section(%{status: :question_set_mismatch} = comparison) do
    header =
      "BASELINE\n  status: AGGREGATES INCOMPARABLE — the golden question set differs from " <>
        "the baseline's (a question was added, removed or renamed), so the aggregate " <>
        "metrics average over different questions and are not compared.\n" <>
        "  #{comparison.shared_question_count} question(s) appear on BOTH sides and WERE " <>
        "compared:"

    regressed =
      case comparison.question_regressions do
        [] ->
          "\n  no shared question regressed."

        ids ->
          "\n  REGRESSED (shared with the baseline, so this is a real drop, not " <>
            "composition):\n" <> Enum.map_join(ids, "\n", &"    #{&1}")
      end

    header <> regressed <> "\n" <> winners_losers(comparison)
  end

  defp baseline_section(%{status: :incomparable} = comparison) do
    "BASELINE\n  status: INCOMPARABLE — no baseline value for #{Enum.join(comparison.uncomparable, ", ")}\n" <>
      winners_losers(comparison)
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
      "uncomparable" => Map.get(comparison, :uncomparable, []),
      "winners" => comparison.winners,
      "losers" => comparison.losers,
      "aggregate" =>
        Enum.map(comparison.aggregate, fn row ->
          %{
            "metric" => row.metric,
            "current" => row.current,
            "baseline" => row.baseline,
            "delta" => row.delta,
            "regression" => row.regression?,
            "uncomparable" => Map.get(row, :uncomparable?, false)
          }
        end)
    }
  end

  defp keys_to_strings(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  @doc "The baseline default tolerance, surfaced for the mix task's help output."
  @spec default_tolerance() :: float()
  def default_tolerance, do: Baseline.default_tolerance()
end
