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
    * `--cleanup` — reap any leaked eval tenants and their seeded corpus, then exit
      without running an eval. Use after a run was killed (OOM / SIGKILL / CI cancel)
      mid-flight and left rows behind. A tenant qualifies ONLY when it carries the
      programmatic eval marker (`settings.retrieval_eval = true`, which no signup path
      can set) — the user-choosable slug prefix alone is NOT sufficient — AND it is
      older than `--min-age` minutes, so a concurrently in-flight run's fresh tenant is
      never reaped out from under it.
    * `--min-age` — minutes a tenant must have existed before `--cleanup` will reap it
      (default 15). Guards against deleting a live run's tenant. Pass `--min-age 0`
      only when you KNOW no eval is in flight.
    * `--allow-prod` — permit the run in the `:prod` environment. Refused by default:
      the task mints a throwaway, human-UNANCHORED tenant and hard-deletes it plus its
      seeded published articles through `AdminRepo` (BYPASSRLS), which has no business
      running against a production database unasked. There is no real-embedding-provider
      path (the semantic lane is always synthetic), so a prod run buys nothing normal
      dev/CI does not.

  Adding a labeled question and re-baselining: `docs/runbooks/retrieval_eval.md`.
  """

  use Mix.Task

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.RetrievalEval
  alias Loopctl.Knowledge.RetrievalEval.Baseline
  alias Loopctl.Knowledge.RetrievalEval.GoldenSet
  alias Loopctl.Knowledge.RetrievalEval.Report
  alias Loopctl.Tenants
  alias Loopctl.Tenants.Tenant

  @shortdoc "Run the golden-question retrieval eval against the committed baseline"

  # Leaked eval tenants and their corpus are found by these stable markers so `--cleanup`
  # (and any future reaper) can reap them without guessing.
  #
  # The AUTHORITATIVE identifier is `@corpus_marker`, stamped programmatically by this task
  # into BOTH the throwaway tenant's `settings` (`settings.retrieval_eval = true`) and every
  # seeded article's `metadata`. It is safe as a delete predicate precisely because NO signup
  # path can set it: `Tenant.signup_changeset`/`self_signup_changeset` force `settings: %{}`
  # and never cast it, so a customer or squatting attacker who registers a colliding
  # `retrieval-eval-*` slug (the slug is user-chosen and unreserved) still cannot forge the
  # marker — and is therefore never a reap candidate. The slug prefix is only a cheap
  # pre-filter, NEVER the sole gate.
  @tenant_slug_prefix "retrieval-eval-"
  @corpus_marker "retrieval_eval"

  # `--cleanup` refuses to delete a tenant younger than this many minutes: a concurrently
  # in-flight eval (a parallel CI job or dev run on the same DB) has a freshly-created
  # throwaway tenant, and reaping it mid-run would wipe its seeded corpus and mis-score the
  # live run. Any normal run finishes well inside this window. `--min-age` overrides it.
  @reap_min_age_minutes 15

  @switches [
    golden: :string,
    mode: :string,
    k: [:integer, :keep],
    baseline: :string,
    update_baseline: :boolean,
    fail_on_regression: :boolean,
    tolerance: :float,
    json: :boolean,
    cleanup: :boolean,
    allow_prod: :boolean,
    min_age: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.start")

    # This task writes to and hard-deletes from the DB it is pointed at. In prod that is a
    # production database, and the run offers nothing dev/CI does not (the provider lane is
    # always synthetic). Refuse unless the operator opts in explicitly.
    guard_prod!(opts)

    if Keyword.get(opts, :cleanup, false) do
      reap_leaked_tenants(opts)
    else
      run_eval(opts)
    end
  end

  defp guard_prod!(opts) do
    if Application.get_env(:loopctl, :env) == :prod and not Keyword.get(opts, :allow_prod, false) do
      Mix.raise(
        "retrieval eval: refusing to run in :prod (mints and hard-deletes a throwaway " <>
          "tenant via AdminRepo). Pass --allow-prod only if you understand that."
      )
    end
  end

  defp run_eval(opts) do
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
    unique = System.unique_integer([:positive])

    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "#{@tenant_slug_prefix}#{unique}",
        slug: "#{@tenant_slug_prefix}#{unique}",
        email: "#{@tenant_slug_prefix}#{unique}@example.invalid",
        # The AUTHORITATIVE reap marker (see @corpus_marker): set programmatically here so
        # `--cleanup` deletes only tenants THIS task minted, never a customer tenant that
        # merely shares the (user-choosable) slug prefix. No signup path can set `settings`.
        settings: %{@corpus_marker => true}
      })

    try do
      fun.(tenant.id)
    after
      # Best-effort teardown that must NOT mask the eval result. An exception raised in an
      # `after` replaces the block's value, so a raw delete that hits an FK violation
      # (e.g. an Oban cron sweep wrote an audit/STH row for this tenant mid-run — those
      # tables reference tenants ON DELETE NO ACTION) would BOTH discard the eval AND
      # leave the tenant behind. Catch it, log it with the marker so `--cleanup` can
      # finish the job, and let the result stand.
      delete_tenant(tenant.id)
    end
  end

  # Reap eval tenants left behind by a killed run (OOM / SIGKILL / CI cancel).
  #
  # A tenant qualifies ONLY when ALL THREE hold — the AUTHORITATIVE gate is the programmatic
  # `settings.retrieval_eval` marker (unforgeable via any signup path); the slug prefix is a
  # cheap pre-filter, never the sole predicate; and the age guard keeps a concurrently
  # in-flight run's fresh tenant out of the sweep. Their seeded corpus is deleted first (by
  # the metadata marker) so a tenant with only-articles children deletes cleanly, and
  # `delete_tenant/1`'s FK-RESTRICT rescue leaves any tenant carrying non-eval children
  # intact (defense in depth behind the marker).
  defp reap_leaked_tenants(opts) do
    min_age = Keyword.get(opts, :min_age, @reap_min_age_minutes)

    tenant_ids =
      AdminRepo.all(
        from(t in Tenant,
          where:
            like(t.slug, ^"#{@tenant_slug_prefix}%") and
              fragment("? ->> ? = 'true'", t.settings, ^@corpus_marker) and
              t.inserted_at < ago(^min_age, "minute"),
          select: t.id
        )
      )

    if tenant_ids == [] do
      Mix.shell().info("Retrieval eval cleanup: no leaked eval tenants found.")
    else
      {reaped, failed} = Enum.reduce(tenant_ids, {0, 0}, &reap_tenant/2)

      Mix.shell().info(
        "Retrieval eval cleanup: reaped #{reaped} leaked eval tenant(s)" <>
          if(failed > 0, do: ", #{failed} could not be deleted (see logs)", else: "") <> "."
      )
    end
  end

  # Delete one leaked tenant's corpus (by marker) then the tenant itself, tallying the
  # outcome so a failure on one tenant does not abort the whole sweep.
  defp reap_tenant(tenant_id, {ok, bad}) do
    delete_corpus_for(tenant_id)

    case delete_tenant(tenant_id) do
      :ok -> {ok + 1, bad}
      :error -> {ok, bad + 1}
    end
  end

  defp delete_corpus_for(tenant_id) do
    AdminRepo.delete_all(
      from(a in Article,
        where:
          a.tenant_id == ^tenant_id and fragment("? ->> ? = 'true'", a.metadata, ^@corpus_marker)
      )
    )

    :ok
  end

  defp delete_tenant(tenant_id) do
    AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    :ok
  rescue
    error ->
      Logger.warning(
        "retrieval eval: could not delete throwaway tenant #{tenant_id} " <>
          "(#{Exception.message(error)}); run `mix loopctl.retrieval.eval --cleanup` to reap it"
      )

      :error
  end
end
