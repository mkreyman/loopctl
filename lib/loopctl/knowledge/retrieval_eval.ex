defmodule Loopctl.Knowledge.RetrievalEval do
  @moduledoc """
  Golden-question retrieval eval (#469) — the falsifiability gate for every ranking
  change to `Loopctl.Knowledge.search_combined/3`.

  ## What it measures

  A COMMITTED golden set (`Loopctl.Knowledge.RetrievalEval.GoldenSet`) pairs each real
  agent question with its own labeled corpus. `compute/2` seeds that corpus into the
  given tenant, runs every question through `search_combined/3`, maps the returned
  article ids back to the labels' stable `doc_id`s, and scores:

    * `recall@k` — share of a question's relevant docs present in the top k.
    * `MRR` — reciprocal rank of the FIRST relevant doc (0.0 when none is retrieved).
    * `nDCG@k` — discounted cumulative gain over graded relevance, normalized by the
      ideal ordering.

  It also reports the **with-retrieval vs no-retrieval spread**: the no-retrieval arm is
  "retrieval disabled", i.e. an empty result set, which scores recall/MRR/nDCG = 0 BY
  CONSTRUCTION. That is the Cerebras "17/20 with the KB vs 0/20 without" framing made
  mechanical — no LLM is called to produce it, and none is needed: with no documents the
  answer set is empty by definition.

  ## What it is NOT

    * **Not a live-traffic metric.** `Loopctl.Knowledge.RetrievalMetrics` computes a
      search→open PRECISION PROXY from `article_access_events`; it has no labels and no
      recall/MRR/nDCG. This module reuses its module SHAPE (`compute/2` → `run/1` →
      telemetry) — deliberately, so the two read alike — but NOT its SQL. Bending a
      labeled eval into an access-event query would measure a different thing.
    * **Not a network or LLM dependency.** Labels are self-contained (see `GoldenSet`),
      and both the document and query embeddings are DETERMINISTIC functions of the
      committed TEXT (`embedding_for_text/1`). Nothing is fetched.
    * **Not a claim about a real embedding provider.** The semantic lane is ALWAYS a
      SYNTHETIC stand-in — in dev, CI, and prod alike: a random-projection bag of words
      over the document text and, independently, over the question text — reproducible
      without a provider, and derived from TEXT rather than from the labels (a query
      vector built out of its own relevant documents would rank them first by construction
      and pin the eval at a vacuous 1.0). There is deliberately NO real-provider path on
      this task: `embedding_opt/2` always supplies a synthetic vector (or, in
      `:keyword_only`, `{:error, :no_api_key}`), and the corpus is seeded with synthetic
      `embedding_for_doc/1` vectors, regardless of `MIX_ENV`. Read the numbers as a
      REGRESSION signal on ranking changes, not as an absolute measure of a provider's
      quality.
    * **Not persisted.** The baseline is a committed JSON file
      (`Loopctl.Knowledge.RetrievalEval.Baseline`) — no table, no migration, and the
      baseline moves only through a reviewed diff.

  ## Modes (AC #469-4)

  `:mode` selects which retrieval lane runs, and the result REPORTS the mode it actually
  observed (never assumes it):

    * `:embeddings` — passes the deterministic query vector as the precomputed
      `:embedding`, so keyword + semantic merge.
    * `:keyword_only` — passes `embedding: {:error, :no_api_key}`, which is exactly the
      degraded path production takes when the embedding provider is unavailable. The
      per-question mode and `fallback_reason` are read out of the search response's own
      `meta` (`meta.fallback`, `meta.search_mode`, `meta.fallback_reason`) rather than
      probed independently.

  The aggregate `:observed_mode` is `"combined"`, `"keyword_only"`, or `"mixed"` when the
  questions disagree — a mixed run is a signal in itself (part of the corpus degraded).

  ## Undefined metrics are `nil`, never `0.0`

  A question with no labels has an UNDEFINED recall (nothing to recall), and an all-zero
  ideal gain vector has an UNDEFINED nDCG. Those return `nil` so a "metric floor" alert
  cannot misfire on an empty/unscoreable set — `0.0` means "ran and retrieved nothing",
  which is a completely different fact. The report renders `nil` as `n/a`.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.RetrievalEval.GoldenSet

  @default_k_values [5, 10]

  @telemetry_event [:loopctl, :knowledge, :retrieval_eval]

  # Fixed namespace for the deterministic (UUIDv5) article ids `seed_corpus/2` derives from
  # each golden `doc_id`. Any constant 16-byte value works; this one is arbitrary.
  @doc_id_namespace <<0x04, 0x69, 0x5E, 0xED, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00,
                      0x00, 0x00, 0x04, 0x69>>

  @type mode :: :embeddings | :keyword_only

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Run the eval for `tenant_id` and emit telemetry. Same options as `compute/2`.
  """
  @spec run(Ecto.UUID.t(), keyword()) :: map()
  def run(tenant_id, opts \\ []) do
    result = compute(tenant_id, opts)

    :telemetry.execute(
      @telemetry_event,
      %{
        mrr: result.mrr,
        answered: result.answered,
        question_count: result.question_count
      },
      %{
        tenant_id: tenant_id,
        mode: result.mode,
        observed_mode: result.observed_mode,
        golden_version: result.golden_version
      }
    )

    result
  end

  @doc """
  Seed the golden corpus under `tenant_id`, score every golden question, and clean up.

  Options:

    * `:golden_set` — the labeled set (default `GoldenSet.default/0`).
    * `:mode` — `:embeddings` (default) or `:keyword_only`.
    * `:k_values` — the k's for recall@k / nDCG@k (default `#{inspect(@default_k_values)}`).
    * `:keyword_weight` / `:semantic_weight` — passed through to `search_combined/3`.

  Returns a result map with aggregate metrics, the observed mode, the no-retrieval arm,
  the with-vs-without spread, and a per-question breakdown (`:question_results`).
  """
  @spec compute(Ecto.UUID.t(), keyword()) :: map()
  def compute(tenant_id, opts \\ []) do
    golden = Keyword.get(opts, :golden_set) || GoldenSet.default()
    mode = Keyword.get(opts, :mode, :embeddings)
    k_values = opts |> Keyword.get(:k_values, @default_k_values) |> Enum.sort() |> Enum.uniq()

    # Pre-generate the seeded article ids so the try/after cleanup can name EXACTLY this
    # run's rows even when scoring raises mid-way — and so a concurrent run against the
    # same tenant can never delete the other's in-flight corpus.
    doc_id_by_article_id = seed_corpus(tenant_id, golden)

    try do
      question_results =
        Enum.map(golden.questions, fn question ->
          score_question(tenant_id, question, doc_id_by_article_id, mode, k_values, opts)
        end)

      aggregate(golden, question_results, mode, k_values)
    after
      delete_corpus(tenant_id, Map.keys(doc_id_by_article_id))
    end
  end

  # ===========================================================================
  # Metrics (pure — hand-verifiable, exercised directly by the tests)
  # ===========================================================================

  @doc """
  Recall@k: the share of `relevant` doc_ids present in the first `k` of `ranked`.

  `nil` (UNDEFINED) when `relevant` is empty — there is nothing to recall. Note that
  when `length(relevant) > k`, recall@k cannot reach 1.0 by construction; that is the
  standard definition and is stable across runs, so it does not distort a delta.
  """
  @spec recall_at_k([String.t()], [String.t()], pos_integer()) :: float() | nil
  def recall_at_k(_ranked, [], _k), do: nil

  def recall_at_k(ranked, relevant, k) do
    relevant_set = MapSet.new(relevant)
    hits = ranked |> Enum.take(k) |> Enum.count(&MapSet.member?(relevant_set, &1))
    hits / length(relevant)
  end

  @doc """
  Reciprocal rank of the first relevant doc in `ranked` (1-based). `0.0` when no relevant
  doc appears at all; `nil` (UNDEFINED) when `relevant` is empty.
  """
  @spec reciprocal_rank([String.t()], [String.t()]) :: float() | nil
  def reciprocal_rank(_ranked, []), do: nil

  def reciprocal_rank(ranked, relevant) do
    relevant_set = MapSet.new(relevant)

    case Enum.find_index(ranked, &MapSet.member?(relevant_set, &1)) do
      nil -> 0.0
      idx -> 1 / (idx + 1)
    end
  end

  @doc """
  nDCG@k over graded gains: `DCG@k / IDCG@k` with the standard `gain / log2(rank + 1)`
  discount (rank is 1-based).

  `gains` maps doc_id to its gain; a doc absent from the map contributes 0. `ideal_gains`
  is the full list of achievable gains (typically every relevant doc's grade) — the
  normalizer takes its top `k` in descending order. Returns `nil` (UNDEFINED) when the
  ideal DCG is 0, i.e. there is no achievable gain to normalize against.
  """
  @spec ndcg_at_k([String.t()], %{String.t() => number()}, [number()], pos_integer()) ::
          float() | nil
  def ndcg_at_k(ranked, gains, ideal_gains, k) do
    dcg =
      ranked
      |> Enum.take(k)
      |> Enum.with_index(1)
      |> Enum.reduce(0.0, fn {doc_id, rank}, acc ->
        acc + discounted(Map.get(gains, doc_id, 0), rank)
      end)

    idcg =
      ideal_gains
      |> Enum.sort(:desc)
      |> Enum.take(k)
      |> Enum.with_index(1)
      |> Enum.reduce(0.0, fn {gain, rank}, acc -> acc + discounted(gain, rank) end)

    if idcg == 0.0, do: nil, else: dcg / idcg
  end

  defp discounted(gain, rank), do: gain / :math.log2(rank + 1)

  @doc """
  Mean of `values`, ignoring `nil`s. Returns `nil` when every value is `nil` (or the list
  is empty) — an undefined aggregate, not a zero.
  """
  @spec mean([float() | nil]) :: float() | nil
  def mean(values) do
    defined = Enum.reject(values, &is_nil/1)

    case defined do
      [] -> nil
      list -> Enum.sum(list) / length(list)
    end
  end

  # ===========================================================================
  # Deterministic synthetic embeddings
  # ===========================================================================

  @doc """
  A deterministic, L2-normalized synthetic embedding for `text`.

  It is a **random-projection bag of words**: every token is mapped to a fixed
  pseudo-random unit direction (seeded by `{token, dimension}`), the directions are
  summed with term frequency as the weight, and the sum is L2-normalized. Two texts about
  the same thing therefore land close together and two unrelated texts land near
  orthogonal — a real topical signal, computed with no provider and no network.

  This is deliberately NOT `Loopctl.Knowledge.ScaleSeed.embedding_for/1` (whose smooth
  component makes index-adjacent rows near-neighbours — right for an ANN-recall load test,
  meaningless for relevance), and deliberately NOT a vector derived from the LABELS: a
  query vector built out of its own relevant documents would rank them first by
  construction, pinning the eval at a vacuous 1.0 that no ranking change could ever move.

  Honest limitation: bag-of-words projection has no synonymy, so this measures a
  lexically-grounded topical similarity, not a real provider's semantics. It is a
  REGRESSION instrument, not an absolute quality score.
  """
  @spec embedding_for_text(String.t()) :: [float()]
  def embedding_for_text(text) do
    dims = Application.get_env(:loopctl, :embedding_dimensions, 1_536)
    max = 1_000_000
    tokens = term_frequencies(text)

    for d <- 0..(dims - 1) do
      Enum.reduce(tokens, 0.0, fn {token, weight}, acc ->
        acc + weight * (:erlang.phash2({token, d}, max) / max * 2.0 - 1.0)
      end)
    end
    |> l2_normalize()
  end

  @doc """
  The deterministic embedding of a golden corpus document: its title and body, projected
  by `embedding_for_text/1`.
  """
  @spec embedding_for_doc(GoldenSet.doc()) :: [float()]
  def embedding_for_doc(%{title: title, body: body}),
    do: embedding_for_text(title <> " " <> body)

  @doc """
  The deterministic query vector for a golden `question`: its QUESTION TEXT projected by
  `embedding_for_text/1` — the same function the documents go through, and no peek at the
  labels.
  """
  @spec query_embedding(GoldenSet.question()) :: [float()]
  def query_embedding(%{question: question}), do: embedding_for_text(question)

  # Case-folded word tokens with their counts. Tokens shorter than 3 characters are
  # dropped: they are overwhelmingly stop words ("a", "is", "do") that add a shared,
  # non-discriminating direction to every vector.
  defp term_frequencies(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3))
    |> Enum.frequencies()
  end

  defp l2_normalize(floats) do
    norm = floats |> Enum.reduce(0.0, fn f, acc -> acc + f * f end) |> :math.sqrt()

    if norm == 0.0, do: floats, else: Enum.map(floats, &(&1 / norm))
  end

  # ===========================================================================
  # Scoring
  # ===========================================================================

  defp score_question(tenant_id, question, doc_id_by_article_id, mode, k_values, opts) do
    max_k = Enum.max(k_values)

    search_opts =
      opts
      |> Keyword.take([:keyword_weight, :semantic_weight])
      |> Keyword.merge(
        limit: max_k,
        status: :published,
        embedding: embedding_opt(mode, question),
        _skip_record_access: true
      )

    {ranked, meta} =
      case Knowledge.search_combined(tenant_id, question.question, search_opts) do
        {:ok, %{results: results, meta: meta}} ->
          {Enum.map(results, &Map.get(doc_id_by_article_id, &1.id)), meta}

        other ->
          # A hard search error scores as "retrieved nothing" (recall 0 — a health
          # signal) rather than crashing the whole eval; the reason is logged.
          Logger.warning("retrieval eval: search failed for #{question.id}: #{inspect(other)}")
          {[], %{}}
      end

    ranked = Enum.reject(ranked, &is_nil/1)
    gains = Map.new(question.corpus, &{&1.doc_id, GoldenSet.grade(question, &1.doc_id)})
    ideal_gains = Enum.map(question.relevant, &GoldenSet.grade(question, &1))

    recall = Map.new(k_values, &{&1, recall_at_k(ranked, question.relevant, &1)})
    ndcg = Map.new(k_values, &{&1, ndcg_at_k(ranked, gains, ideal_gains, &1)})

    %{
      id: question.id,
      question: question.question,
      observed_mode: Map.get(meta, :search_mode, "unknown"),
      fallback: Map.get(meta, :fallback, false),
      fallback_reason: Map.get(meta, :fallback_reason),
      ranked: ranked,
      relevant: question.relevant,
      recall_at_k: recall,
      mrr: reciprocal_rank(ranked, question.relevant),
      ndcg_at_k: ndcg,
      answered: answered?(recall, k_values)
    }
  end

  # A question counts as ANSWERED when at least one relevant doc is in the top-k at the
  # STRICTEST k in the run (the smallest). This is the headline "17/20" numerator.
  defp answered?(recall, k_values) do
    case Map.get(recall, Enum.min(k_values)) do
      nil -> false
      value -> value > 0.0
    end
  end

  defp embedding_opt(:keyword_only, _question), do: {:error, :no_api_key}
  defp embedding_opt(:embeddings, question), do: {:ok, query_embedding(question)}

  defp aggregate(golden, question_results, mode, k_values) do
    answered = Enum.count(question_results, & &1.answered)
    question_count = length(question_results)

    recall =
      Map.new(k_values, fn k ->
        {k, mean(Enum.map(question_results, fn q -> q.recall_at_k[k] end))}
      end)

    ndcg =
      Map.new(k_values, fn k ->
        {k, mean(Enum.map(question_results, fn q -> q.ndcg_at_k[k] end))}
      end)

    mrr = mean(Enum.map(question_results, & &1.mrr))

    # The no-retrieval arm: with retrieval disabled the result set is EMPTY, so every
    # metric is 0.0 by construction (0.0, not nil — the metrics are well-defined, they
    # are simply not met). Computed through the SAME metric functions on an empty
    # ranking so it can never drift from the with-retrieval definition.
    without =
      Enum.map(golden.questions, fn q ->
        gains = Map.new(q.corpus, &{&1.doc_id, GoldenSet.grade(q, &1.doc_id)})
        ideal = Enum.map(q.relevant, &GoldenSet.grade(q, &1))

        %{
          recall_at_k: Map.new(k_values, &{&1, recall_at_k([], q.relevant, &1)}),
          ndcg_at_k: Map.new(k_values, &{&1, ndcg_at_k([], gains, ideal, &1)}),
          mrr: reciprocal_rank([], q.relevant)
        }
      end)

    no_retrieval = %{
      recall_at_k:
        Map.new(k_values, fn k -> {k, mean(Enum.map(without, fn q -> q.recall_at_k[k] end))} end),
      ndcg_at_k:
        Map.new(k_values, fn k -> {k, mean(Enum.map(without, fn q -> q.ndcg_at_k[k] end))} end),
      mrr: mean(Enum.map(without, & &1.mrr)),
      answered: 0
    }

    %{
      golden_version: golden.version,
      mode: mode,
      observed_mode: observed_mode(question_results),
      fallback_reasons: fallback_reasons(question_results),
      question_count: question_count,
      k_values: k_values,
      recall_at_k: recall,
      mrr: mrr,
      ndcg_at_k: ndcg,
      answered: answered,
      answered_k: Enum.min(k_values),
      no_retrieval: no_retrieval,
      spread: %{
        answered: answered - no_retrieval.answered,
        recall_at_k:
          Map.new(k_values, fn k -> {k, delta(recall[k], no_retrieval.recall_at_k[k])} end),
        ndcg_at_k: Map.new(k_values, fn k -> {k, delta(ndcg[k], no_retrieval.ndcg_at_k[k])} end),
        mrr: delta(mrr, no_retrieval.mrr)
      },
      question_results: question_results
    }
  end

  defp delta(nil, _), do: nil
  defp delta(_, nil), do: nil
  defp delta(a, b), do: a - b

  # Read the run's mode out of the search responses themselves (`meta.search_mode`),
  # never from what we asked for — a run that silently degraded must SAY so.
  defp observed_mode(question_results) do
    case question_results |> Enum.map(& &1.observed_mode) |> Enum.uniq() do
      [] -> "unknown"
      [single] -> single
      _multiple -> "mixed"
    end
  end

  defp fallback_reasons(question_results) do
    question_results
    |> Enum.map(& &1.fallback_reason)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  # ===========================================================================
  # Corpus seeding / cleanup
  # ===========================================================================

  @doc """
  Seed the golden set's whole corpus as PUBLISHED, embedded articles under `tenant_id`
  and return the `%{article_id => doc_id}` map the scorer uses to translate results back
  into labels.

  Written through `insert_all` (not the create changeset) for two reasons: the embedding
  is writable only by the dedicated embedding changeset, and the eval needs each document
  published AND embedded in one statement. Ids are generated up front so the caller can
  clean up EXACTLY its own rows (see `delete_corpus/2`) even if scoring raises.

  ## Article ids are DETERMINISTIC (not random), and doc-ordered by construction

  The article id is a deterministic UUID whose HIGH bytes derive from the golden `doc_id`
  ALONE and whose LOW bytes fold in the `tenant_id`. That split is load-bearing for the
  deploy gate's reproducibility, NOT cosmetic:

    * `Knowledge.merge_results/5` keys its merged-candidate map by article id and returns
      `Map.values/1`, whose iteration order is hash-driven by those keys; the id is ALSO the
      deterministic secondary sort key that breaks `final_score` ties in both the merge and
      the keyword `ORDER BY`. With random ids, which of two score-tied docs lands inside the
      top-k boundary would flip run-to-run — making recall@k / nDCG@k / MRR / answered
      nondeterministic exactly under the Reciprocal Rank Fusion change (#470) whose scores
      tie BY CONSTRUCTION, i.e. the successor story this zero-tolerance gate exists to score.
    * Because the HIGH bytes (which dominate the lexical UUID order) come from `doc_id` only,
      the RELATIVE order of two different docs is stable across runs even though each run
      mints a FRESH throwaway tenant — so a tie resolves the same way when the gate re-runs
      against the committed baseline.
    * The LOW bytes fold in `tenant_id` so the SAME doc seeded into different tenants (the
      tenant-isolation tests) or by concurrent runs gets a globally-unique id — the
      `articles` primary key is `id` ALONE, so a purely doc-derived id would PK-collide.
  """
  @spec seed_corpus(Ecto.UUID.t(), GoldenSet.t()) :: %{Ecto.UUID.t() => String.t()}
  def seed_corpus(tenant_id, golden) do
    seeded =
      Enum.map(GoldenSet.corpus(golden), fn doc ->
        {deterministic_article_id(tenant_id, doc.doc_id), doc}
      end)

    insert_corpus(tenant_id, seeded)
    Map.new(seeded, fn {id, doc} -> {id, doc.doc_id} end)
  end

  # A deterministic, well-formed (version-5, variant-10) UUID for a seeded article.
  #
  # High 60 bits (which dominate the lexical/`ORDER BY` comparison) come from `doc_id` ALONE,
  # giving a stable cross-run ordering the deploy gate can reproduce; the low 62 bits fold in
  # `tenant_id`, guaranteeing global uniqueness (the `articles` PK is `id`) so the same doc in
  # two tenants / concurrent runs never collides. Distinct docs get distinct high bits (SHA-1
  # collision resistance); a high-bit collision between two different docs is ~1-in-2^60 and
  # would merely fall back to the tenant-folded low bits for that one pair.
  defp deterministic_article_id(tenant_id, doc_id) do
    <<hi::48, _::4, hi_rest::12, _::binary>> = :crypto.hash(:sha, @doc_id_namespace <> doc_id)

    <<_::2, lo::62, _::binary>> =
      :crypto.hash(:sha, @doc_id_namespace <> tenant_id <> "|" <> doc_id)

    <<hi::48, 5::4, hi_rest::12, 2::2, lo::62>>
    |> Ecto.UUID.load!()
  end

  defp insert_corpus(tenant_id, seeded) do
    now = DateTime.utc_now()

    rows =
      Enum.map(seeded, fn {id, doc} ->
        # Per-doc age (#471): a doc with `age_days` set is seeded as if last updated that
        # many days ago, so the recency prior in search_combined/3 is exercisable. Absent
        # age → `now` (the pre-#471 behavior — every doc the same age).
        ts = seeded_timestamp(now, Map.get(doc, :age_days))

        %{
          id: id,
          tenant_id: tenant_id,
          title: doc.title,
          body: doc.body,
          category: doc.category,
          status: :published,
          scope: :tenant,
          tags: doc.tags,
          metadata: %{"retrieval_eval" => true, "doc_id" => doc.doc_id},
          embedding: Pgvector.new(embedding_for_doc(doc)),
          inserted_at: ts,
          updated_at: ts
        }
      end)

    AdminRepo.insert_all(Article, rows)
    :ok
  end

  # Age a seed timestamp back by `age_days` (nil/0 → `now`). Uses whole seconds so the
  # eval stays reproducible run-to-run.
  defp seeded_timestamp(now, nil), do: now
  defp seeded_timestamp(now, 0), do: now

  defp seeded_timestamp(now, age_days) when is_number(age_days) do
    DateTime.add(now, -round(age_days * 86_400), :second)
  end

  @doc """
  Delete ONLY the given seeded rows (by the ids `seed_corpus/2` generated), scoped to
  `tenant_id`.

  Never a blanket "delete this tenant's eval articles": a concurrent run against the same
  tenant must not be able to wipe the other's in-flight corpus. `compute/2` calls this
  from an `after`, so it runs on the happy path AND when scoring raises.
  """
  @spec delete_corpus(Ecto.UUID.t(), [Ecto.UUID.t()]) :: :ok
  def delete_corpus(tenant_id, article_ids) do
    from(a in Article, where: a.tenant_id == ^tenant_id and a.id in ^article_ids)
    |> AdminRepo.delete_all()

    :ok
  end
end
