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

  ## Limits (AC-21.2.8 / AC-21.2.15)

  Configurable max comparisons via
  `Application.get_env(:loopctl, :article_link_max_comparisons, 50)`.
  Logs a warning when candidate count exceeds the limit.

  ## Threshold (AC-21.2.4)

  Configurable via `Application.get_env(:loopctl, :article_link_threshold, 0.8)`.
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

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"article_id" => article_id, "tenant_id" => tenant_id}}) do
    case Knowledge.get_article_with_embedding(tenant_id, article_id) do
      {:error, :not_found} ->
        # Article deleted -- no-op
        :ok

      {:ok, %Article{embedding: nil}} ->
        # No embedding yet -- no-op
        :ok

      {:ok, %Article{} = article} ->
        threshold = Application.get_env(:loopctl, :article_link_threshold, 0.8)
        max_comparisons = Application.get_env(:loopctl, :article_link_max_comparisons, 50)
        find_and_link_similar(article, tenant_id, threshold, max_comparisons)
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
    existing_pairs = get_existing_link_pairs(article.id, tenant_id)

    new_links =
      candidates
      |> Enum.reject(fn %{id: cid} ->
        MapSet.member?(existing_pairs, {article.id, cid}) or
          MapSet.member?(existing_pairs, {cid, article.id})
      end)
      |> Enum.map(fn %{id: target_id, similarity: score} ->
        %{
          source_article_id: article.id,
          target_article_id: target_id,
          relationship_type: :relates_to,
          metadata: %{"auto_generated" => true, "similarity_score" => score}
        }
      end)

    created_count = create_links(new_links, tenant_id)
    log_audit_event(article.id, tenant_id, created_count)
    :ok
  end

  defp find_similar_articles(article, tenant_id, threshold, max_comparisons) do
    embedding = article.embedding

    base_query =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.id != ^article.id,
        where: not is_nil(a.embedding),
        where: a.status == :published,
        select: %{
          id: a.id,
          similarity: fragment("1 - (? <=> ?)", a.embedding, ^embedding)
        },
        order_by: [asc: fragment("? <=> ?", a.embedding, ^embedding)],
        limit: ^max_comparisons
      )

    query = scope_by_project(base_query, article.project_id)

    query
    |> AdminRepo.all()
    |> Enum.filter(fn %{similarity: sim} -> sim >= threshold end)
  end

  defp scope_by_project(query, nil) do
    # Tenant-wide article: compare against all articles in the tenant
    query
  end

  defp scope_by_project(query, project_id) do
    # Project-scoped article: compare against same project + tenant-wide
    where(query, [a], is_nil(a.project_id) or a.project_id == ^project_id)
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

  defp get_existing_link_pairs(article_id, tenant_id) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
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
