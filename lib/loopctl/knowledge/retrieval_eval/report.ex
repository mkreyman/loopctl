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
    #{provenance_banner()}
      requested mode : #{result.mode}
      observed mode  : #{result.observed_mode}
      fallback reason: #{reasons}
      questions      : #{result.question_count}\
    """
  end

  # Every number this report prints is produced on a SYNTHETIC fixture, and the banner
  # exists because that fact does not survive being quoted.
  #
  # The limitation was already written down — the runbook says "read the numbers as a
  # REGRESSION signal, not an absolute quality score" and "there is no real-embedding-
  # provider path" — and on 2026-08-25 a session that had READ that runbook still reported
  # this eval's +6.5% MRR to the owner as the answer to "did the search refactor improve
  # search?". Measured against production traffic the same day, the real answer was "no
  # measurable change in either direction" (weekly MRR sigma 0.045; the observed gap 0.022).
  #
  # So the caveat is attached to the ARTIFACT rather than to a document about the artifact.
  # A doc can be read and then not applied at reporting time; a banner travels with the
  # number into whatever paraphrases it. Do not remove it to tidy the output, and do not
  # weaken it to "synthetic embeddings" alone — the CORPUS is invented too (hand-authored
  # prose, median body 123 characters, against a production corpus of ~86,000 real
  # articles), and that is the half that misleads about absolute quality.
  @spec provenance_banner() :: String.t()
  def provenance_banner do
    "  ⚠ SYNTHETIC FIXTURE — invented corpus + synthetic embeddings. Valid as a\n" <>
      "    REGRESSION signal between two runs of this harness. NOT a measurement of\n" <>
      "    production retrieval quality; do not quote these figures as one. For the\n" <>
      "    real corpus, measure logged traffic (docs/runbooks/retrieval_eval.md)."
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

  # Both mismatch statuses drop the AGGREGATES only — the shared questions are still scored.
  defp baseline_section(%{status: :golden_version_mismatch, golden_version: gv} = comparison) do
    "BASELINE\n  status: AGGREGATES INCOMPARABLE — golden set version changed " <>
      "(#{gv.baseline} -> #{gv.current}) — re-baseline before comparing." <>
      shared_question_lines(comparison)
  end

  defp baseline_section(%{status: :question_set_mismatch} = comparison) do
    "BASELINE\n  status: AGGREGATES INCOMPARABLE — the golden question set differs from " <>
      "the baseline's (a question was added, removed or renamed), so the aggregate " <>
      "metrics average over different questions and are not compared." <>
      shared_question_lines(comparison)
  end

  defp baseline_section(%{status: :incomparable} = comparison) do
    "BASELINE\n  status: INCOMPARABLE — no baseline value for #{Enum.join(comparison.uncomparable, ", ")}" <>
      question_notes(comparison) <> "\n" <> winners_losers(comparison)
  end

  defp baseline_section(%{status: :ok, question_regressions: [_ | _]} = comparison) do
    "BASELINE\n  status: PER-QUESTION REGRESSION (aggregates OK — a question that loses a " <>
      "rank while another gains nets out)" <>
      question_notes(comparison) <> "\n" <> winners_losers(comparison)
  end

  defp baseline_section(%{status: :ok, question_uncomparable: [_ | _]} = comparison) do
    "BASELINE\n  status: NOT FULLY COMPARED (the aggregates held)" <>
      question_notes(comparison) <> "\n" <> winners_losers(comparison)
  end

  defp baseline_section(%{status: :ok} = comparison) do
    "BASELINE\n  status: OK (no regression)\n" <> winners_losers(comparison)
  end

  defp baseline_section(%{status: :regression} = comparison) do
    "BASELINE\n  status: REGRESSION in #{Enum.join(comparison.regressions, ", ")}" <>
      question_notes(comparison) <> "\n" <> winners_losers(comparison)
  end

  # An EMPTY intersection is a THIRD answer — nothing was compared, which is not an all-clear.
  defp shared_question_lines(%{shared_question_count: 0}) do
    "\n  no question appears on BOTH sides — nothing was comparable per-question either."
  end

  defp shared_question_lines(comparison) do
    verdict =
      case question_notes(comparison) do
        "" -> "\n  no shared question regressed."
        notes -> notes
      end

    "\n  #{comparison.shared_question_count} question(s) appear on BOTH sides (a golden-set " <>
      "change also moves the shared corpus and the labels, so confirm the cause of any " <>
      "drop):" <> verdict <> "\n" <> winners_losers(comparison)
  end

  # Two INDEPENDENT lists over the same questions, so BOTH render (picking one clause hid
  # every uncomparable id behind any regression) and on EVERY status, as the gate does.
  defp question_notes(cmp) do
    note("REGRESSED per-question", Map.get(cmp, :question_regressions, [])) <>
      note("NOT COMPARED (uncomparable, not clean)", Map.get(cmp, :question_uncomparable, []))
  end

  defp note(_label, []), do: ""
  defp note(label, ids), do: "\n  #{label}: #{Enum.join(ids, ", ")}"

  defp winners_losers(comparison) do
    "  winners: #{list(comparison.winners)}\n  losers : #{list(comparison.losers)}"
  end

  # The gate exits non-zero on a per-question verdict, so `--json` may not answer "ok" to it.
  defp json_status(%{status: :ok, question_regressions: [_ | _]}), do: "question_regression"
  defp json_status(%{status: :ok, question_uncomparable: [_ | _]}), do: "question_uncomparable"
  defp json_status(%{status: status}), do: to_string(status)

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
      # The JSON path is the one a script or another agent consumes, so it carries the
      # same disclosure as the text report rather than relying on the reader having seen it.
      "provenance" => "synthetic_fixture",
      "provenance_note" =>
        "Invented corpus and synthetic embeddings. Valid as a regression signal between " <>
          "runs of this harness; NOT a measurement of production retrieval quality.",
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
      "status" => json_status(comparison),
      "regressions" => comparison.regressions,
      "uncomparable" => Map.get(comparison, :uncomparable, []),
      "shared_question_count" => Map.get(comparison, :shared_question_count, 0),
      "question_regressions" => Map.get(comparison, :question_regressions, []),
      "question_uncomparable" => Map.get(comparison, :question_uncomparable, []),
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
