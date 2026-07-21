defmodule Mix.Tasks.Loopctl.Retrieval.Eval do
  @moduledoc """
  #469 — run the golden-question retrieval eval and compare it against the committed
  baseline.

  Seeds the committed golden corpus (`priv/retrieval_eval/golden.jsonl`) into a
  throwaway tenant, runs every question through `Loopctl.Knowledge.search_combined/3`,
  prints recall@k / MRR / nDCG plus a per-question table with baseline deltas, and
  deletes everything it seeded (including the throwaway tenant).

  ## Usage

      mix loopctl.retrieval.eval
      mix loopctl.retrieval.eval --mode both --fail-on-regression
      mix loopctl.retrieval.eval --update-baseline
      mix loopctl.retrieval.eval --json

  ## Options

    * `--mode` — `embeddings` (default), `keyword_only`, or `both`. `keyword_only`
      forces the degraded path production takes when the embedding provider is
      unavailable; the report names the mode it actually observed either way.
    * `--golden` — path to a golden-set JSONL (default the committed one).
    * `--k` — a k for recall@k / nDCG@k. Repeatable (default `--k 5 --k 10`).
    * `--baseline` — path to the baseline JSON (default the committed one).
    * `--update-baseline` — rewrite the baseline from this run instead of comparing.
      Implies `--mode both` unless a mode is given explicitly.
    * `--fail-on-regression` — exit non-zero when any aggregate metric is below
      baseline by more than the tolerance. This is what CI runs.
    * `--tolerance` — float slack below baseline that is not a regression.
    * `--json` — emit the machine-readable result instead of the text report.

  Adding a labeled question and re-baselining: `docs/runbooks/retrieval_eval.md`.
  """

  use Mix.Task

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.RetrievalEval
  alias Loopctl.Knowledge.RetrievalEval.Baseline
  alias Loopctl.Knowledge.RetrievalEval.GoldenSet
  alias Loopctl.Knowledge.RetrievalEval.Report
  alias Loopctl.Tenants
  alias Loopctl.Tenants.Tenant

  @shortdoc "Run the golden-question retrieval eval against the committed baseline"

  @switches [
    golden: :string,
    mode: :string,
    k: [:integer, :keep],
    baseline: :string,
    update_baseline: :boolean,
    fail_on_regression: :boolean,
    tolerance: :float,
    json: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.start")

    golden =
      case Keyword.get(opts, :golden) do
        nil -> GoldenSet.default()
        path -> GoldenSet.load!(path)
      end

    # A run that scores NOTHING must never look green (the scale-nightly false-green
    # lesson). The guard lives in the LOADER — `GoldenSet.parse!/1` raises on an empty or
    # malformed file — so it cannot be bypassed by a caller that skips the task, and this
    # task inherits it. Re-checking here would be dead code (dialyzer proves the list is
    # non-empty by the time we get it).
    modes = modes(opts)
    k_values = k_values(opts)
    baseline_path = Keyword.get(opts, :baseline, Baseline.default_path())

    results =
      with_tenant(fn tenant_id ->
        Enum.map(modes, fn mode ->
          RetrievalEval.run(tenant_id,
            golden_set: golden,
            mode: mode,
            k_values: k_values
          )
        end)
      end)

    if Keyword.get(opts, :update_baseline, false) do
      update_baseline(results, baseline_path)
    else
      report(results, baseline_path, opts)
    end
  end

  # ===========================================================================

  defp modes(opts) do
    case Keyword.get(opts, :mode) do
      nil ->
        if Keyword.get(opts, :update_baseline, false),
          do: [:embeddings, :keyword_only],
          else: [:embeddings]

      "embeddings" ->
        [:embeddings]

      "keyword_only" ->
        [:keyword_only]

      "both" ->
        [:embeddings, :keyword_only]

      other ->
        Mix.raise("unknown --mode #{inspect(other)} (embeddings | keyword_only | both)")
    end
  end

  defp k_values(opts) do
    case Keyword.get_values(opts, :k) do
      [] -> [5, 10]
      values -> values |> Enum.sort() |> Enum.uniq()
    end
  end

  defp update_baseline(results, path) do
    Baseline.write!(path, Baseline.from_results(results))
    Mix.shell().info("Baseline written to #{path}")

    Enum.each(results, fn result -> Mix.shell().info(Report.render(result, nil)) end)
  end

  defp report(results, baseline_path, opts) do
    tolerance = Keyword.get(opts, :tolerance, Baseline.default_tolerance())
    fail_on_regression = Keyword.get(opts, :fail_on_regression, false)

    baseline =
      case Baseline.load(baseline_path) do
        {:ok, baseline} ->
          baseline

        {:error, reason} when fail_on_regression ->
          # In gate mode a missing/unreadable baseline is a HARD failure: a gate that
          # silently passes because it had nothing to compare against is a false green.
          Mix.raise("retrieval eval: cannot read baseline #{baseline_path} (#{inspect(reason)})")

        {:error, _reason} ->
          nil
      end

    comparisons =
      Enum.map(results, fn result ->
        comparison = baseline && Baseline.compare(result, baseline, tolerance: tolerance)
        {result, comparison}
      end)

    emit(comparisons, opts)
    maybe_fail(comparisons, fail_on_regression)
  end

  defp emit(comparisons, opts) do
    if Keyword.get(opts, :json, false) do
      payload = Enum.map(comparisons, fn {r, c} -> Report.to_json_map(r, c) end)
      Mix.shell().info(JSON.encode!(payload))
    else
      Enum.each(comparisons, fn {result, comparison} ->
        Mix.shell().info(Report.render(result, comparison))
        Mix.shell().info("")
      end)
    end
  end

  defp maybe_fail(_comparisons, false), do: :ok

  defp maybe_fail(comparisons, true) do
    problems =
      Enum.flat_map(comparisons, fn
        {_result, %{status: :ok}} ->
          []

        {result, %{status: :regression} = comparison} ->
          ["#{result.mode}: regression in #{Enum.join(comparison.regressions, ", ")}"]

        {result, %{status: status}} ->
          ["#{result.mode}: cannot compare (#{status})"]

        {result, nil} ->
          ["#{result.mode}: no baseline to compare against"]
      end)

    if problems == [] do
      Mix.shell().info("Retrieval eval: no regression against baseline.")
    else
      Enum.each(problems, fn problem -> Mix.shell().error(problem) end)
      Mix.raise("retrieval eval gate failed")
    end
  end

  # A throwaway tenant per run: the eval seeds a corpus, and seeding it into a real
  # tenant would pollute that tenant's KB. Deleted in an `after` so a raising run leaves
  # nothing behind either.
  defp with_tenant(fun) do
    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "retrieval-eval-#{System.unique_integer([:positive])}",
        slug: "retrieval-eval-#{System.unique_integer([:positive])}",
        email: "retrieval-eval-#{System.unique_integer([:positive])}@example.invalid"
      })

    try do
      fun.(tenant.id)
    after
      AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end
  end
end
