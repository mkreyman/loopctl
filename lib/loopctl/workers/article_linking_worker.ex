defmodule Loopctl.Workers.ArticleLinkingWorker do
  @moduledoc """
  Oban worker that auto-discovers semantic relationships between articles
  using pgvector cosine similarity and creates `relates_to` links.

  Runs in the `:knowledge` queue with max 3 attempts. Enqueued by
  `ArticleEmbeddingWorker` after an embedding is successfully stored.

  ## Flow

  1. Fetch the article by `article_id` + `tenant_id`
  2. If article was deleted or has no embedding, return `:ok` (no-op)
  3. Query candidate articles via cosine similarity (1 - cosine distance)
  4. Filter candidates above the configured threshold
  5. Check existing links in both directions to avoid duplicates
  6. Create `relates_to` links with `auto_generated: true` metadata
  7. Log audit event `knowledge.articles_linked`

  ## Scoping (AC-21.2.3)

  - Project-scoped articles compare against same-project articles plus
    tenant-wide articles (project_id IS NULL).
  - Tenant-wide articles compare against all articles in the tenant.

  Since US-27.7a the similarity lookup runs through the shared
  `Loopctl.Knowledge.VectorSearch.nearest/4` (the index-correct HNSW kNN path on
  the HeavyRead pool), with the project scope applied as a post-ANN filter over the
  over-fetch pool. The worker therefore links among the GLOBAL-nearest pool that
  match the project, not the nearest-WITHIN-project — the documented post-ANN-filter
  tradeoff (see `find_similar_articles/4`). For the worker's small `max_comparisons`
  (default 50) against a generously sized pool the two are equivalent.

  ## Limits (AC-21.2.8 / AC-21.2.15)

  Configurable max comparisons via
  `Application.get_env(:loopctl, :article_link_max_comparisons, 50)`.
  Logs a warning when candidate count exceeds the limit. Since US-27.7a the lookup
  runs through `VectorSearch.nearest/4`, whose `k` is clamped to
  `VectorSearch.max_k/0` (default 100), so a configured value above that ceiling is
  capped (a documented kNN cost bound); the default 50 is unaffected, and a clamp is
  logged once per job.

  ## Threshold (AC-21.2.4)

  Configurable via `Application.get_env(:loopctl, :article_link_threshold, 0.6)`.
  Only articles with cosine similarity >= threshold get linked.

  ## Retry Strategy (AC-21.2.13)

  Custom polynomial backoff: `attempt^4 + 15 + rand(0..30*attempt)`.

  ## Uniqueness (AC-21.2.14)

  Unique per `article_id` within a 300-second window.
  """

  use Oban.Worker,
    queue: :knowledge,
    max_attempts: 3,
    unique: [period: 300, keys: [:article_id]]

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.VectorSearch

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"article_id" => article_id, "tenant_id" => tenant_id} = args}) do
    case Knowledge.get_article_with_embedding(tenant_id, article_id) do
      {:error, :not_found} ->
        # Article deleted -- no-op
        :ok

      {:ok, %Article{embedding: nil}} ->
        # No embedding yet -- no-op
        :ok

      {:ok, %Article{} = article} ->
        threshold = resolve_threshold(args)
        max_comparisons = clamped_max_comparisons()
        find_and_link_similar(article, tenant_id, threshold, max_comparisons)
    end
  end

  # Optional per-job threshold override (query-shaped, so it lives in args, not
  # config DI). KnowledgeLintWorker uses a LOWER threshold when re-linking orphans
  # so a totally-isolated article connects to its nearest neighbor instead of
  # near-missing the default cutoff forever. Falls back to the global config.
  defp resolve_threshold(args) do
    case Map.get(args, "threshold") do
      t when is_number(t) and t >= 0 -> t / 1
      _ -> Application.get_env(:loopctl, :article_link_threshold, 0.6)
    end
  end

  # `max_comparisons` flows to the kNN helper as `k`, which is clamped to
  # `VectorSearch.max_k/0` (US-27.7a cost bound). Surface that clamp once so an operator
  # who configured a higher value isn't silently capped (default 50 is well under it).
  defp clamped_max_comparisons do
    configured = Application.get_env(:loopctl, :article_link_max_comparisons, 50)
    max_k = VectorSearch.max_k()

    if configured > max_k do
      Logger.warning(
        "article_link_max_comparisons=#{configured} exceeds VectorSearch.max_k=#{max_k}; " <>
          "capping similarity comparisons at #{max_k}"
      )

      max_k
    else
      configured
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  # --- Private ---

  defp find_and_link_similar(article, tenant_id, threshold, max_comparisons) do
    log_if_exceeds_limit(article, tenant_id, max_comparisons)

    candidates = find_similar_articles(article, tenant_id, threshold, max_comparisons)
    conflict_threshold = conflict_threshold()

    # A `relates_to` ambient link for everything >= the link threshold, PLUS a
    # `:potential_conflict` flag (route-the-findings #4) for pairs >= the conflict
    # threshold — too similar to comfortably coexist, for the consumer to resolve.
    # Dedup is type-aware so the two link types don't crowd each other out.
    relates =
      build_links(article.id, candidates, tenant_id, :relates_to, fn _sim -> true end)

    conflicts =
      build_links(article.id, candidates, tenant_id, :potential_conflict, fn sim ->
        sim >= conflict_threshold
      end)

    created_count = create_links(relates ++ conflicts, tenant_id)
    log_audit_event(article.id, tenant_id, created_count)
    :ok
  end

  defp build_links(article_id, candidates, tenant_id, type, keep?) do
    existing = get_existing_link_pairs(article_id, tenant_id, type)

    candidates
    |> Enum.filter(fn %{similarity: sim} -> keep?.(sim) end)
    |> Enum.reject(fn %{id: cid} ->
      MapSet.member?(existing, {article_id, cid}) or MapSet.member?(existing, {cid, article_id})
    end)
    |> Enum.map(fn %{id: target_id, similarity: score} ->
      %{
        source_article_id: article_id,
        target_article_id: target_id,
        relationship_type: type,
        metadata: %{"auto_generated" => true, "similarity_score" => score}
      }
    end)
  end

  defp conflict_threshold do
    Application.get_env(:loopctl, :knowledge_conflict_threshold, 0.93)
  end

  # US-27.7a: route the similarity lookup through the shared, scale-tested kNN helper
  # (`Loopctl.Knowledge.VectorSearch.nearest/4`) on the dedicated HeavyRead pool instead
  # of a bespoke `AdminRepo` cosine query. The helper's index-correct shape guarantees a
  # background link pass can never silently full-scan the corpus at prod scale (the rot
  # this epic targets) — the inner ANN is the pure `ORDER BY <=> LIMIT pool` HNSW path,
  # and the project scope is applied on the OUTER pool (`project_id` is in the
  # `articles(tenant_id, project_id, category)` btree, so an inner predicate would defeat
  # HNSW).
  #
  # BEHAVIOR PRESERVED: self exclusion, published-only, and the project scope
  # ("same-project OR tenant-wide" for a project-scoped source; no project filter for a
  # tenant-wide one) are unchanged — the latter via the helper's `:project_or_global` opt,
  # which mirrors the old `scope_by_project/2` exactly. The threshold boundary is
  # preserved for any POSITIVE `threshold`: we ask the helper for `threshold: 0.0` (no
  # floor in the indexed query) and keep the INCLUSIVE `sim >= threshold` filter in memory
  # here — the helper's own floor is strict `>`, so leaving the boundary check here keeps a
  # candidate whose similarity equals the (positive) threshold linkable, identical to the
  # pre-migration code. (Edge: at `threshold == 0.0` the helper's `> 0.0` floor — over the
  # `GREATEST(0, 1 - distance)` score — additionally drops exactly-orthogonal candidates
  # the old in-memory `>= 0.0` kept. This is a deliberate, harmless tightening for
  # auto-linking: a 0.0-similarity "relates_to" link is noise; the default threshold is 0.6.)
  #
  # RECALL NOTE (post-ANN-filter tradeoff): because the project scope now runs on the
  # OUTER pool (it must, to keep HNSW), the worker links among the GLOBAL-nearest `pool`
  # rows that THEN match the project — not the nearest-WITHIN-project. With a generously
  # sized pool (`pool_size(max_comparisons)`) this is equivalent for the small
  # `max_comparisons` (default 50) the worker uses; in a pathological corpus where a
  # project's matches all fall outside the global top-pool it could under-fill, the same
  # documented post-ANN-filter limitation `VectorSearch` carries for `tags`/`category`.
  defp find_similar_articles(article, tenant_id, threshold, max_comparisons) do
    tenant_id
    |> VectorSearch.nearest(article.embedding, max_comparisons,
      exclude_id: article.id,
      project_or_global: article.project_id,
      threshold: 0.0,
      pool: VectorSearch.pool_size(max_comparisons)
    )
    # The helper returns `%{id, title, category, similarity_score}`; the linking path
    # keys on `:id` + `:similarity`, so map the score across and keep the inclusive
    # `>= threshold` boundary in memory (see the threshold note above).
    |> Enum.map(fn %{id: id, similarity_score: score} -> %{id: id, similarity: score} end)
    |> Enum.filter(fn %{similarity: sim} -> sim >= threshold end)
  end

  defp log_if_exceeds_limit(article, tenant_id, max_comparisons) do
    total =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.id != ^article.id,
        where: not is_nil(a.embedding),
        where: a.status == :published
      )
      |> scope_by_project(article.project_id)
      |> AdminRepo.aggregate(:count)

    if total > max_comparisons do
      Logger.warning(
        "Article linking: #{total} candidate articles exceeds limit of #{max_comparisons} " <>
          "for article #{article.id}"
      )
    end
  end

  # Candidate-COUNT scoping for the over-limit warning only (a plain `count(*)`, NOT the
  # vector scan — the kNN lookup itself routes through `VectorSearch.nearest/4`). Mirrors
  # the historical scope: a tenant-wide article counts against the whole tenant; a
  # project-scoped one against same-project plus tenant-wide (`project_id IS NULL`).
  defp scope_by_project(query, nil), do: query

  defp scope_by_project(query, project_id) do
    where(query, [a], is_nil(a.project_id) or a.project_id == ^project_id)
  end

  defp get_existing_link_pairs(article_id, tenant_id, type) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.relationship_type == ^type,
      where: l.source_article_id == ^article_id or l.target_article_id == ^article_id,
      select: {l.source_article_id, l.target_article_id}
    )
    |> AdminRepo.all()
    |> MapSet.new()
  end

  defp create_links([], _tenant_id), do: 0

  defp create_links(links, tenant_id) do
    Enum.reduce(links, 0, fn attrs, count ->
      changeset =
        %ArticleLink{tenant_id: tenant_id}
        |> ArticleLink.changeset(attrs)

      case AdminRepo.insert(changeset) do
        {:ok, _link} -> count + 1
        # Skip on constraint violation (duplicate link)
        {:error, _changeset} -> count
      end
    end)
  end

  defp log_audit_event(article_id, tenant_id, created_count) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "article",
      entity_id: article_id,
      action: "knowledge.articles_linked",
      actor_type: "system",
      actor_id: nil,
      actor_label: "worker:article_linking",
      new_state: %{
        "article_id" => article_id,
        "new_link_count" => created_count
      }
    })
  end
end
