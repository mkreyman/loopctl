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
  against stale numbers — `compare/3` flags the mismatch instead of reporting deltas that
  mean nothing.

  ## Regression rule

  A metric REGRESSES when `current < baseline - tolerance` (default tolerance
  `#{inspect(0.005)}`; `answered` uses a whole-question tolerance of 0). A metric that is
  `nil` on ONE side only is reported as an undefined delta and — because it means the
  metric stopped being computable — counts as a regression; `nil` on BOTH sides is inert.
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
        status: :ok | :regression | :missing_mode | :golden_version_mismatch,
        golden_version: %{current: .., baseline: ..},
        aggregate: [%{metric: "recall@5", current: .., baseline: .., delta: .., regression?: ..}],
        questions: [%{id: .., metric deltas ..}],
        winners: [..], losers: [..],
        regressions: [metric names]
      }
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
        base_report(result, baseline_golden, :golden_version_mismatch)

      true ->
        build_comparison(result, baseline_mode, baseline_golden, tolerance)
    end
  end

  defp base_report(result, baseline_golden, status) do
    %{
      status: status,
      golden_version: %{current: result.golden_version, baseline: baseline_golden},
      aggregate: [],
      questions: [],
      winners: [],
      losers: [],
      regressions: []
    }
  end

  defp build_comparison(result, baseline_mode, baseline_golden, tolerance) do
    aggregate =
      metric_rows(result, baseline_mode, tolerance) ++
        [answered_row(result, baseline_mode)]

    questions = question_rows(result, baseline_mode)
    regressions = aggregate |> Enum.filter(& &1.regression?) |> Enum.map(& &1.metric)

    %{
      status: if(regressions == [], do: :ok, else: :regression),
      golden_version: %{current: result.golden_version, baseline: baseline_golden},
      aggregate: aggregate,
      questions: questions,
      winners: questions |> Enum.filter(&positive?(&1.mrr_delta)) |> Enum.map(& &1.id),
      losers: questions |> Enum.filter(&negative?(&1.mrr_delta)) |> Enum.map(& &1.id),
      regressions: regressions
    }
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
      regression?: regression?(current, baseline, tolerance)
    }
  end

  # `answered` is a whole-question count: any drop is a regression (no float tolerance).
  defp answered_row(result, baseline_mode) do
    baseline = baseline_mode["answered"]
    current = result.answered

    %{
      metric: "answered@#{result.answered_k}",
      current: current,
      baseline: baseline,
      delta: delta(current, baseline),
      regression?: is_integer(baseline) and current < baseline
    }
  end

  defp question_rows(result, baseline_mode) do
    baseline_questions = baseline_mode["questions"] || %{}

    Enum.map(result.question_results, fn q ->
      base = Map.get(baseline_questions, q.id, %{})

      %{
        id: q.id,
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
