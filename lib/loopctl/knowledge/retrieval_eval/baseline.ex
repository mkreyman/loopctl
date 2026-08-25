defmodule Loopctl.Knowledge.RetrievalEval.Baseline do
  @moduledoc """
  The COMMITTED retrieval-eval baseline (#469 AC-2) and the regression comparison
  against it.

  The baseline is a plain JSON file (`priv/retrieval_eval/baseline_v1.json`), not a
  database table: CI starts with an empty DB, the numbers must be reviewable in a diff,
  and a file needs no migration and no tenant scoping. `mix loopctl.retrieval.eval
  --update-baseline` rewrites it; moving the baseline is therefore always an explicit,
  reviewed commit.

  ## File shape

      {
        "version": "baseline_v1",
        "golden_version": "golden_v1",
        "generated_at": "2026-07-21T00:00:00Z",
        "modes": {
          "embeddings": {
            "observed_mode": "combined",
            "question_count": 25,
            "answered": 24,
            "answered_k": 5,
            "mrr": 0.91,
            "recall_at_k": {"5": 0.93, "10": 0.95},
            "ndcg_at_k": {"5": 0.90, "10": 0.92},
            "questions": {"q-...": {"mrr": 1.0, "recall_at_k": {...}, "ndcg_at_k": {...}}}
          },
          "keyword_only": { ... }
        }
      }

  `golden_version` is recorded so a re-labelled golden set cannot be silently compared
  against stale numbers — on a mismatch `compare/3` drops the AGGREGATES and keeps the
  per-question rows the baseline still has. Those drops are CANDIDATES, not proven ranking
  regressions: the seeded corpus is the UNION of every question's docs, so a question added
  alongside the bump adds distractors for the rest, and a bump may relabel the shared ones.
  Because the version is free text the loader never checksums, `compare/3` ALSO compares the
  question-id SET and flags `:question_set_mismatch` when the run and the baseline cover
  different questions, even if the version was left untouched.

  ## Regression rule

  A metric REGRESSES when `current < baseline - tolerance` (default tolerance
  `#{inspect(0.005)}`; `answered` uses a whole-question tolerance of 0). A metric that is
  `nil` on ONE side only is reported as an undefined delta and — because it means the
  metric stopped being computable — counts as a regression; `nil` on BOTH sides is inert.
  A metric that is a NUMBER now with NO baseline counterpart (e.g. a `--k` not in the
  baseline) is `:incomparable`, not `:ok` — the gate fails closed rather than pretending
  it compared something it could not. Both apply PER QUESTION too: `question_regressions`
  and `question_uncomparable` fail the gate on EVERY status, `:ok` included.
  """

  @relative_path "retrieval_eval/baseline_v1.json"
  @version "baseline_v1"
  @default_tolerance 0.005

  @type t :: map()

  @doc "Absolute path of the committed baseline file."
  @spec default_path() :: String.t()
  def default_path do
    :loopctl
    |> :code.priv_dir()
    |> Path.join(@relative_path)
  end

  @doc "The default tolerance below baseline that is NOT treated as a regression."
  @spec default_tolerance() :: float()
  def default_tolerance, do: @default_tolerance

  @doc "Load a baseline file. Returns `{:error, :enoent}` when it has not been created yet."
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, contents} <- File.read(path) do
      JSON.decode(contents)
    end
  end

  @doc """
  Build the JSON-encodable baseline document from one result per mode.
  """
  @spec from_results([map()]) :: t()
  def from_results(results) when results != [] do
    %{
      "version" => @version,
      "golden_version" => hd(results).golden_version,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "modes" => Map.new(results, fn r -> {to_string(r.mode), mode_entry(r)} end)
    }
  end

  @doc """
  Write `baseline` to `path` as indented, key-sorted JSON.

  Pretty-printed on purpose: the baseline's whole job is to make a ranking change's
  effect visible in a REVIEWED diff, and a single-line JSON blob shows every metric as
  one changed line.
  """
  @spec write!(String.t(), t()) :: :ok
  def write!(path, baseline) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encode_pretty(baseline) <> "\n")
  end

  @doc "Indented, key-sorted JSON encoding of a decoded JSON value."
  @spec encode_pretty(term()) :: String.t()
  def encode_pretty(value), do: encode_pretty(value, "")

  defp encode_pretty(value, indent) when is_map(value) and map_size(value) > 0 do
    inner = indent <> "  "

    body =
      value
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join(",\n", fn {k, v} ->
        inner <> JSON.encode!(to_string(k)) <> ": " <> encode_pretty(v, inner)
      end)

    "{\n" <> body <> "\n" <> indent <> "}"
  end

  defp encode_pretty(value, indent) when is_list(value) and value != [] do
    inner = indent <> "  "
    body = Enum.map_join(value, ",\n", fn v -> inner <> encode_pretty(v, inner) end)
    "[\n" <> body <> "\n" <> indent <> "]"
  end

  defp encode_pretty(value, _indent), do: JSON.encode!(value)

  defp mode_entry(result) do
    %{
      "observed_mode" => result.observed_mode,
      "question_count" => result.question_count,
      "answered" => result.answered,
      "answered_k" => result.answered_k,
      "mrr" => result.mrr,
      "recall_at_k" => stringify_keys(result.recall_at_k),
      "ndcg_at_k" => stringify_keys(result.ndcg_at_k),
      "questions" =>
        Map.new(result.question_results, fn q ->
          {q.id,
           %{
             "mrr" => q.mrr,
             "recall_at_k" => stringify_keys(q.recall_at_k),
             "ndcg_at_k" => stringify_keys(q.ndcg_at_k)
           }}
        end)
    }
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  @doc """
  Compare a `result` against the baseline document for the same mode.

  Options: `:tolerance` (default `default_tolerance/0`).

  Returns

      %{
        status: :ok | :regression | :incomparable | :missing_mode
              | :golden_version_mismatch | :question_set_mismatch,
        golden_version: %{current: .., baseline: ..},
        aggregate: [%{metric: "recall@5", current: .., baseline: .., delta: ..,
                      regression?: .., uncomparable?: ..}],
        questions: [%{id: .., regressed_metrics: [..], uncomparable_metrics: [..],
                      metric deltas ..}],
        shared_question_count: <questions present on BOTH sides>,
        question_regressions: [question ids], question_uncomparable: [question ids],
        winners: [..], losers: [..],
        regressions: [metric names],
        uncomparable: [metric names]
      }

  Both mismatch statuses still carry the per-question comparison over the questions the
  baseline still has — only the AGGREGATES are dropped.
  """
  @spec compare(map(), t(), keyword()) :: map()
  def compare(result, baseline, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    mode_key = to_string(result.mode)
    baseline_mode = get_in(baseline, ["modes", mode_key])
    baseline_golden = baseline["golden_version"]

    cond do
      is_nil(baseline_mode) ->
        base_report(result, baseline_golden, :missing_mode)

      baseline_golden != result.golden_version ->
        shared_report(result, baseline_mode, baseline_golden, tolerance, :golden_version_mismatch)

      question_set_changed?(result, baseline_mode) ->
        shared_report(result, baseline_mode, baseline_golden, tolerance, :question_set_mismatch)

      true ->
        build_comparison(result, baseline_mode, baseline_golden, tolerance)
    end
  end

  # `golden_version` is a free-text header field the loader does not derive or checksum, so
  # adding/removing/renaming a question without bumping it would let a stale baseline pass:
  # a new question missing from the baseline yields nil per-question deltas that read as
  # non-regressions, and a differing question COUNT is never compared. Comparing the actual
  # question-id SET closes that gap independently of the version string — the gate refuses
  # to compare a run whose questions do not match the baseline's exactly.
  defp question_set_changed?(result, baseline_mode) do
    current_ids = MapSet.new(result.question_results, & &1.id)
    baseline_ids = baseline_mode |> Map.get("questions", %{}) |> Map.keys() |> MapSet.new()
    not MapSet.equal?(current_ids, baseline_ids)
  end

  defp base_report(result, baseline_golden, status) do
    %{
      status: status,
      golden_version: %{current: result.golden_version, baseline: baseline_golden},
      aggregate: [],
      questions: [],
      shared_question_count: 0,
      question_regressions: [],
      question_uncomparable: [],
      winners: [],
      losers: [],
      regressions: [],
      uncomparable: []
    }
  end

  defp build_comparison(result, baseline_mode, baseline_golden, tolerance) do
    aggregate =
      metric_rows(result, baseline_mode, tolerance) ++
        [answered_row(result, baseline_mode)]

    questions = question_rows(result, baseline_mode, tolerance)
    regressions = aggregate |> Enum.filter(& &1.regression?) |> Enum.map(& &1.metric)

    # A metric present in the current run but ABSENT from the baseline (e.g. `--k 3`
    # against a baseline that only holds k=5 and k=10) cannot be judged. Treating it as
    # "no regression" is a false green — the gate would print "no regression" having
    # silently compared only the metrics that happened to overlap. Surface it as its own
    # uncomparable status so gate mode fails closed.
    uncomparable = aggregate |> Enum.filter(& &1.uncomparable?) |> Enum.map(& &1.metric)

    %{
      status: comparison_status(regressions, uncomparable),
      golden_version: %{current: result.golden_version, baseline: baseline_golden},
      aggregate: aggregate,
      questions: questions,
      shared_question_count: length(questions),
      question_regressions: ids_with(questions, :regressed_metrics),
      question_uncomparable: ids_with(questions, :uncomparable_metrics),
      # Winners/losers span EVERY per-question metric delta (mrr, recall@k, nDCG@k), not
      # mrr alone: a change that lifts mrr while dropping recall must show up as a loser,
      # so a question can legitimately be BOTH a winner and a loser — that IS the tradeoff.
      winners: questions |> Enum.filter(&any_positive_delta?/1) |> Enum.map(& &1.id),
      losers: questions |> Enum.filter(&any_negative_delta?/1) |> Enum.map(& &1.id),
      regressions: regressions,
      uncomparable: uncomparable
    }
  end

  # Regression wins over uncomparable wins over ok, so the most serious signal is the
  # reported status and gate mode never reads "ok" while a metric it could not compare
  # lurks in the aggregate.
  defp comparison_status([_ | _], _uncomparable), do: :regression
  defp comparison_status([], [_ | _]), do: :incomparable
  defp comparison_status([], []), do: :ok

  # Per-question winner/loser predicates over the full delta set. Undefined (nil) deltas
  # are inert — neither a win nor a loss.
  defp any_positive_delta?(q), do: Enum.any?(question_deltas(q), &positive?/1)
  defp any_negative_delta?(q), do: Enum.any?(question_deltas(q), &negative?/1)

  defp question_deltas(q) do
    [q.mrr_delta | Map.values(q.recall_delta) ++ Map.values(q.ndcg_delta)]
  end

  defp metric_rows(result, baseline_mode, tolerance) do
    recall_rows =
      Enum.map(result.k_values, fn k ->
        row(
          "recall@#{k}",
          result.recall_at_k[k],
          get_in(baseline_mode, ["recall_at_k", to_string(k)]),
          tolerance
        )
      end)

    ndcg_rows =
      Enum.map(result.k_values, fn k ->
        row(
          "ndcg@#{k}",
          result.ndcg_at_k[k],
          get_in(baseline_mode, ["ndcg_at_k", to_string(k)]),
          tolerance
        )
      end)

    recall_rows ++ ndcg_rows ++ [row("mrr", result.mrr, baseline_mode["mrr"], tolerance)]
  end

  defp row(metric, current, baseline, tolerance) do
    %{
      metric: metric,
      current: current,
      baseline: baseline,
      delta: delta(current, baseline),
      regression?: regression?(current, baseline, tolerance),
      uncomparable?: uncomparable?(current, baseline)
    }
  end

  # The current run produced a number for this metric but the baseline has none to compare
  # against — the comparison is undefined, and in gate mode that must not read as "ok".
  # (nil-current is handled by regression?/3 as a regression; nil-on-both is inert.)
  defp uncomparable?(current, baseline), do: is_number(current) and is_nil(baseline)

  # `answered` is a whole-question count: any drop is a regression (no float tolerance).
  defp answered_row(result, baseline_mode) do
    baseline = baseline_mode["answered"]
    current = result.answered

    %{
      metric: "answered@#{result.answered_k}",
      current: current,
      baseline: baseline,
      delta: delta(current, baseline),
      regression?: is_integer(baseline) and current < baseline,
      uncomparable?: uncomparable?(current, baseline)
    }
  end

  defp question_rows(result, baseline_mode, tolerance) do
    baseline_questions = baseline_mode["questions"] || %{}

    Enum.map(result.question_results, fn q ->
      base = Map.get(baseline_questions, q.id, %{})
      {regressed, uncomparable} = question_verdicts(q, base, result.k_values, tolerance)

      %{
        id: q.id,
        regressed_metrics: regressed,
        uncomparable_metrics: uncomparable,
        observed_mode: q.observed_mode,
        fallback_reason: q.fallback_reason,
        mrr: q.mrr,
        mrr_baseline: base["mrr"],
        mrr_delta: delta(q.mrr, base["mrr"]),
        recall_at_k: q.recall_at_k,
        recall_delta:
          Map.new(result.k_values, fn k ->
            {k, delta(q.recall_at_k[k], get_in(base, ["recall_at_k", to_string(k)]))}
          end),
        ndcg_at_k: q.ndcg_at_k,
        ndcg_delta:
          Map.new(result.k_values, fn k ->
            {k, delta(q.ndcg_at_k[k], get_in(base, ["ndcg_at_k", to_string(k)]))}
          end)
      }
    end)
  end

  # Which of THIS question's metrics regressed against its own baseline row, and which
  # had NO baseline value to compare against at all (the per-question twin of the
  # aggregate `uncomparable`, e.g. `--k 3` against a k=5/k=10 baseline). "Did not regress"
  # and "could not be compared" are different answers, and the report must never print the
  # first when it means the second. A question absent from the baseline yields `base ==
  # %{}` -- it cannot regress, and every metric of it is uncomparable.
  defp question_verdicts(q, base, k_values, tolerance) do
    metrics =
      [{"mrr", q.mrr, base["mrr"]}] ++
        Enum.flat_map(k_values, fn k ->
          [
            {"recall@#{k}", q.recall_at_k[k], get_in(base, ["recall_at_k", to_string(k)])},
            {"ndcg@#{k}", q.ndcg_at_k[k], get_in(base, ["ndcg_at_k", to_string(k)])}
          ]
        end)

    {for({m, current, base_value} <- metrics, regression?(current, base_value, tolerance), do: m),
     for({m, current, base_value} <- metrics, uncomparable?(current, base_value), do: m)}
  end

  defp ids_with(questions, key), do: for(q <- questions, Map.fetch!(q, key) != [], do: q.id)

  # The AGGREGATES are not comparable here -- across two question sets they average over
  # different questions, and across two golden versions the labels themselves moved -- so
  # both mismatch statuses stay NON-`:ok` and gate mode still fails closed. The per-question
  # rows for the shared questions are still worth SCORING, and throwing them away was a real
  # blind spot: the runbook tells you to bump the version and regenerate the baseline to add
  # a question, so EVERY growth of the golden set arrived as a commit the gate had given up
  # on. Scored 2026-08-25 against golden_v5, pre-#693 code: q-self-report 1.00 -> 0.33 mrr,
  # q-egress-policy 1.00 -> 0.50, q-audit-chain-sth 0.33 -> 0.25 across golden_v3 -> v5.
  # What a drop CANNOT establish is its own cause -- the corpus is a union and a bump may
  # relabel -- so the report words them as candidates.
  defp shared_report(result, baseline_mode, baseline_golden, tolerance, status) do
    questions = question_rows(result, baseline_mode, tolerance)
    # `Map.get/3`'s default never fires on a PRESENT-but-null "questions" -- the shape a
    # hand-edited baseline reaches this branch with.
    baseline_ids = MapSet.new(Map.keys(baseline_mode["questions"] || %{}))
    shared = Enum.filter(questions, &MapSet.member?(baseline_ids, &1.id))

    %{
      status: status,
      golden_version: %{current: result.golden_version, baseline: baseline_golden},
      aggregate: [],
      questions: shared,
      shared_question_count: length(shared),
      question_regressions: ids_with(shared, :regressed_metrics),
      question_uncomparable: ids_with(shared, :uncomparable_metrics),
      winners: shared |> Enum.filter(&any_positive_delta?/1) |> Enum.map(& &1.id),
      losers: shared |> Enum.filter(&any_negative_delta?/1) |> Enum.map(& &1.id),
      regressions: [],
      uncomparable: []
    }
  end

  # A metric that became UNDEFINED (nil now, a number before) is a regression: it stopped
  # being computable, which is at least as bad as a numeric drop. nil on both sides is
  # inert; a newly-defined metric (nil before) cannot regress.
  defp regression?(nil, baseline, _tolerance) when is_number(baseline), do: true
  defp regression?(_current, nil, _tolerance), do: false
  defp regression?(nil, _baseline, _tolerance), do: false
  defp regression?(current, baseline, tolerance), do: current < baseline - tolerance

  defp delta(nil, _), do: nil
  defp delta(_, nil), do: nil
  defp delta(current, baseline), do: current - baseline

  defp positive?(delta), do: is_number(delta) and delta > 0
  defp negative?(delta), do: is_number(delta) and delta < 0

  @doc "The version tag written into a fresh baseline document."
  @spec version() :: String.t()
  def version, do: @version
end
