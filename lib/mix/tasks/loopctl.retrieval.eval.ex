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
    * `--fail-on-regression` — exit non-zero when any aggregate metric is below baseline
      by more than the tolerance, AND whenever a question shared with the baseline
      regressed or carried a metric the baseline has no value for. Those two gate on every
      status, including one whose aggregates are fine or not comparable. This is what CI
      runs.
    * `--tolerance` — float slack below baseline that is not a regression.
    * `--json` — emit the machine-readable result instead of the text report.
    * `--graph-lane` / `--no-graph-lane` — force the optional RRF graph-neighbour lane
      (#470) on or off, overriding `:knowledge_rrf_graph_lane_enabled`. Absent, the run
      inherits the application default, which is what the committed baseline was measured
      under. A graph-lane experiment is therefore two runs of this task compared to EACH
      OTHER — never a lane-on run compared to a lane-off baseline. Note the lane lives in
      the branch where BOTH keyword and semantic succeeded, so it is a no-op under
      `--mode keyword_only`.
    * `--graph-weight` — override the graph lane's RRF weight for this run. This is the
      knob that trades the lane's multi-hop recall gain against the top-rank perturbation
      it causes on single-fact questions.
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
  alias Loopctl.Knowledge.Reranker
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

  # The model a `--record-rerank` run asks. Named here rather than resolved per tenant
  # because the recording is one deliberate experiment, and the fixture records which model
  # produced it. Override with `--rerank-model`.
  @default_rerank_model "claude-haiku-4-5-20251001"

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
    allow_dirty: :boolean,
    min_age: :integer,
    graph_lane: :boolean,
    graph_weight: :float,
    rerank: :boolean,
    record_rerank: :boolean,
    rerank_fixture: :string,
    rerank_model: :string
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
      refuse_on_leaked_corpus!(opts)
      run_eval(opts)
    end
  end

  # REFUSE to score against a database that still holds another run's seeded corpus.
  #
  # The ANN is ONE HNSW index shared by every tenant, and `search_semantic` applies the
  # tenant predicate as a residual AFTER the index returns its neighbourhood (see the wiki
  # article "Multi-tenant HNSW: residual filter drops results under cross-tenant density").
  # So a leaked corpus is not inert background: it crowds the neighbourhood, and this
  # tenant's own answers fall outside the window and simply do not come back.
  #
  # Measured 2026-08-25, and it is why this guard exists. A `--filler` sweep was killed
  # mid-run by a timeout, leaving 12,500 filler rows in two abandoned tenants. Every later
  # cell of that sweep then scored against a progressively dirtier index, and nine golden
  # questions went from MRR 1.000 to 0.000 — the answer not demoted but ABSENT. Read as a
  # pool-depth curve it said "a deeper pool is worse", which is a conclusion about run
  # ORDER wearing a pool's clothes. Every number from that sweep was discarded.
  #
  # Fails CLOSED, and names the remedy: a sweep that silently tolerates this produces
  # confident numbers that mean nothing.
  defp refuse_on_leaked_corpus!(opts) do
    leaked =
      AdminRepo.aggregate(
        from(a in Loopctl.Knowledge.Article,
          where: fragment("coalesce((?->>'retrieval_eval')::boolean, false)", a.metadata)
        ),
        :count
      )

    if leaked > 0 and not Keyword.get(opts, :allow_dirty, false) do
      Mix.raise("""
      retrieval eval: #{leaked} seeded eval row(s) from a previous run are still in this       database.

      The ANN index is shared across tenants and the tenant filter is applied AFTER it, so       a leaked corpus crowds this run's neighbourhood and its answers silently drop out of       the results. Any metric produced now would describe the leftovers, not the ranking.

      Reap them first:   mix loopctl.retrieval.eval --cleanup

      (--allow-dirty overrides this, for diagnosing the leak itself. Never for a measurement.)
      """)
    end

    :ok
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

    if Keyword.get(opts, :record_rerank, false), do: start_recorder!()

    results =
      with_tenant(fn tenant_id ->
        Enum.map(modes, fn mode ->
          RetrievalEval.run(
            tenant_id,
            [golden_set: golden, mode: mode, k_values: k_values]
            |> maybe_put_graph_lane(opts)
          )
        end)
      end)

    if Keyword.get(opts, :record_rerank, false), do: dump_rerank_fixture(opts, golden)

    if Keyword.get(opts, :update_baseline, false) do
      update_baseline(results, baseline_path)
    else
      report(results, baseline_path, opts)
    end
  end

  # ===========================================================================

  # `--graph-lane` / `--no-graph-lane` force the optional RRF graph-neighbour lane on or off
  # for this run, overriding `:knowledge_rrf_graph_lane_enabled`. Absent, the run inherits
  # the application default — which is what the COMMITTED baseline is measured under, so a
  # graph-lane experiment is two runs compared to each other, never one run compared to a
  # baseline recorded under different retrieval settings.
  defp maybe_put_graph_lane(run_opts, opts) do
    case Keyword.fetch(opts, :graph_lane) do
      {:ok, value} -> Keyword.put(run_opts, :graph_lane, value)
      :error -> run_opts
    end
    |> maybe_put_graph_weight(opts)
    |> maybe_put_rerank(opts)
  end

  # `--rerank` scores the Phase 4 second stage. `--record-rerank` implies it and swaps the
  # implementation for the REAL provider-backed one, writing what it returns to the fixture;
  # otherwise the run replays the committed recording, so CI never bills a provider and two
  # runs of the same commit score identically.
  defp maybe_put_rerank(run_opts, opts) do
    recording? = Keyword.get(opts, :record_rerank, false)
    rerank? = recording? or Keyword.get(opts, :rerank, false)

    if rerank? do
      run_opts
      |> Keyword.put(:rerank, true)
      |> Keyword.put(:reranker, if(recording?, do: Reranker.Recorder, else: Reranker.Fixture))
      |> then(&if recording?, do: Keyword.merge(&1, recording_credentials!(opts)), else: &1)
      |> maybe_put_fixture_path(opts)
    else
      run_opts
    end
  end

  # The eval mints a THROWAWAY tenant, which by construction has no stored LLM settings —
  # and tenant LLM work is mandatory-BYO with no global key path (config/runtime.exs says
  # so in as many words). So a recording run reads `ANTHROPIC_API_KEY` and passes it
  # explicitly rather than writing a credential into a tenant row that exists for two
  # minutes. Refused loudly when absent: a recording run that silently produced nothing
  # would then be caught by `dump_rerank_fixture/2`, but the message here names the actual
  # remedy.
  defp recording_credentials!(opts) do
    api_key =
      System.get_env("ANTHROPIC_API_KEY") ||
        Mix.raise(
          "retrieval eval: --record-rerank needs ANTHROPIC_API_KEY. The eval's tenant is " <>
            "throwaway and has no stored LLM settings, and there is no global key path for " <>
            "tenant LLM work."
        )

    [
      rerank_api_key: api_key,
      rerank_model: Keyword.get(opts, :rerank_model, @default_rerank_model)
    ]
  end

  # Write the recording collected during a `--record-rerank` run. Refuses to overwrite the
  # committed file with NOTHING: an empty entry map means every provider call failed (no
  # key, a 401, a timeout), and replacing a real recording with that turns a provider
  # outage into a silent, permanent "the reranker never reorders anything".
  defp dump_rerank_fixture(opts, golden) do
    entries = Reranker.Recorder.entries()
    path = Keyword.get(opts, :rerank_fixture, default_rerank_fixture_path())

    if entries == %{} do
      Mix.raise(
        "retrieval eval: --record-rerank observed nothing — every reranker call failed " <>
          "(no API key, provider error, or unparseable replies). Refusing to overwrite " <>
          "#{path} with an empty recording."
      )
    end

    payload = %{
      "golden_version" => golden.version,
      "model" => Keyword.get(opts, :rerank_model, @default_rerank_model),
      "note" =>
        "Recorded by `mix loopctl.retrieval.eval --record-rerank` from " <>
          "Loopctl.Knowledge.Reranker.Llm. Values are candidate TITLES in the model's " <>
          "chosen order. Regenerate after changing the golden set; a key that is not " <>
          "recorded replays as 'keep the fused order', never as an error.",
      "entries" => entries
    }

    File.write!(path, JSON.encode!(payload))
    Mix.shell().info("retrieval eval: recorded #{map_size(entries)} rerank orderings to #{path}")
  end

  # `priv/` inside the CHECKOUT, not the build's app_dir: a recording written into
  # `_build` is invisible to git and would be silently discarded by the next `mix clean`.
  defp default_rerank_fixture_path,
    do: Path.join(File.cwd!(), "priv/retrieval_eval/rerank_fixture.json")

  defp maybe_put_fixture_path(run_opts, opts) do
    case Keyword.fetch(opts, :rerank_fixture) do
      {:ok, path} -> Keyword.put(run_opts, :rerank_fixture_path, path)
      :error -> run_opts
    end
  end

  defp maybe_put_graph_weight(run_opts, opts) do
    case Keyword.fetch(opts, :graph_weight) do
      {:ok, value} -> Keyword.put(run_opts, :graph_weight, value)
      :error -> run_opts
    end
  end

  defp start_recorder! do
    case Reranker.Recorder.start_link() do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Mix.raise("retrieval eval: could not start the rerank recorder: #{inspect(reason)}")
    end
  end

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
        {_result, %{status: :ok, question_regressions: [], question_uncomparable: []}} ->
          []

        {result, %{status: :ok} = comparison} ->
          ["#{result.mode}: aggregates OK, but #{question_phrase(comparison)}"]

        {result, %{status: :regression} = comparison} ->
          [
            "#{result.mode}: regression in #{Enum.join(comparison.regressions, ", ")}" <>
              also_per_question(comparison)
          ]

        {result, %{status: status} = comparison} ->
          ["#{result.mode}: cannot compare (#{status})" <> also_per_question(comparison)]

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

  # A per-question verdict gates and is named on EVERY path — never only where the aggregate
  # happened to fail. A question that loses a rank while another gains nets out to a flat
  # aggregate (the runbook's own reranking case), and a moved question set makes the
  # aggregate uncomparable without making the shared questions so — that is what let three
  # questions lose a rank apiece across the golden_v3 -> v5 growth without anyone reading
  # it. A metric with NO baseline value gates for the same reason its aggregate twin does:
  # "could not be compared" is not "did not regress".
  defp also_per_question(comparison) do
    case question_phrase(comparison) do
      "" -> ""
      phrase -> ", AND " <> phrase
    end
  end

  defp question_phrase(comparison) do
    [
      phrase(comparison.question_regressions, "regressed"),
      phrase(comparison.question_uncomparable, "had no baseline value for a metric")
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", and ")
  end

  defp phrase([], _what), do: ""

  defp phrase(ids, what),
    do: "#{length(ids)} shared question(s) #{what}: #{Enum.join(ids, ", ")}"

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

    # Seeded rows can outlive their tenant row: a killed run leaves both, but a partly-torn-
    # down one can leave articles whose tenant was already deleted. Reaping by tenant alone
    # left those behind, and they are exactly as damaging to the shared ANN index — so sweep
    # the marker too, independently of which tenants are found.
    seeded =
      from(a in Loopctl.Knowledge.Article,
        where: fragment("coalesce((?->>'retrieval_eval')::boolean, false)", a.metadata),
        select: a.id
      )

    # LINKS FIRST. `article_links` FKs both endpoints with `on_delete: :restrict`, so
    # deleting a linked article raises a foreign-key violation and reaps NOTHING —
    # `delete_corpus/2` carries the same ordering and the same comment, and this reaper
    # was written without it and failed on its first real run against a dirty database.
    AdminRepo.delete_all(
      from(l in Loopctl.Knowledge.ArticleLink,
        where: l.source_article_id in subquery(seeded) or l.target_article_id in subquery(seeded)
      )
    )

    {orphaned, _} = AdminRepo.delete_all(seeded)

    if orphaned > 0 do
      Mix.shell().info("Retrieval eval cleanup: deleted #{orphaned} seeded eval article(s).")
    end

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
