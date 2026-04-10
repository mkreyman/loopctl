defmodule Loopctl.Knowledge do
  @moduledoc """
  Context module for the Knowledge Wiki.

  Provides CRUD operations for articles and article links. Articles
  are the core knowledge units — reusable patterns, conventions,
  decisions, findings, and references within a tenant's knowledge base.

  All operations use AdminRepo (BYPASSRLS) with explicit `tenant_id`
  scoping, following the same pattern as other loopctl contexts.

  ## Usage

  ### Creating an article

      Loopctl.Knowledge.create_article(tenant_id, %{
        title: "Ecto Multi Pattern",
        body: "Use Ecto.Multi for atomic operations...",
        category: :pattern,
        tags: ["ecto", "transactions"]
      }, actor_id: api_key.id, actor_label: "user:admin")

  ### Listing articles with filters

      Loopctl.Knowledge.list_articles(tenant_id,
        project_id: project_id,
        category: :pattern,
        tags: ["ecto"],
        limit: 10,
        offset: 0
      )
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Projects.Project
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Workers.ArticleEmbeddingWorker

  # --- Articles ---

  @doc """
  Creates a new article within a tenant.

  Sets `tenant_id` programmatically and records the `article.created`
  audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with title (required), body (required), category (required),
    and optional: status, tags, source_type, source_id, metadata, project_id
  - `opts` -- keyword list with `:actor_id`, `:actor_label`, `:actor_type`

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec create_article(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Article.t()} | {:error, Ecto.Changeset.t()}
  def create_article(tenant_id, attrs, opts \\ []) do
    project_id = attrs[:project_id] || attrs["project_id"]

    with :ok <- validate_project_ownership(tenant_id, project_id) do
      actor_id = Keyword.get(opts, :actor_id)
      actor_label = Keyword.get(opts, :actor_label)
      actor_type = Keyword.get(opts, :actor_type, "api_key")

      changeset =
        %Article{tenant_id: tenant_id}
        |> Article.create_changeset(attrs)

      # Content is always "changed" on create (title + body are required).
      # Only enqueue embedding if the article will be published.
      needs_embedding? = content_or_publish_changed?(changeset)

      multi =
        Multi.new()
        |> Multi.insert(:article, changeset)
        |> Audit.log_in_multi(:audit, fn %{article: article} ->
          %{
            tenant_id: tenant_id,
            entity_type: "article",
            entity_id: article.id,
            action: "article.created",
            actor_type: actor_type,
            actor_id: actor_id,
            actor_label: actor_label,
            new_state: %{
              "title" => article.title,
              "category" => to_string(article.category),
              "status" => to_string(article.status),
              "tags" => article.tags,
              "project_id" => article.project_id
            }
          }
        end)
        |> EventGenerator.generate_events(:webhook_events, fn %{article: article} ->
          %{
            tenant_id: tenant_id,
            event_type: "article.created",
            project_id: article.project_id,
            payload: article_event_payload(article)
          }
        end)
        |> maybe_enqueue_embedding(tenant_id, needs_embedding?)

      case AdminRepo.transaction(multi) do
        {:ok, %{article: article}} -> {:ok, article}
        {:error, :article, changeset, _} -> {:error, changeset}
      end
    end
  end

  @doc """
  Retrieves a single article by ID, scoped to the tenant.

  Preloads outgoing links (with target articles) and incoming links
  (with source articles).

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID

  ## Returns

  - `{:ok, %Article{}}` with preloaded links
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_article(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Article.t()} | {:error, :not_found}
  def get_article(tenant_id, article_id) do
    case AdminRepo.get_by(Article, id: article_id, tenant_id: tenant_id) do
      nil ->
        {:error, :not_found}

      article ->
        article =
          AdminRepo.preload(article,
            outgoing_links: :target_article,
            incoming_links: :source_article
          )

        {:ok, article}
    end
  end

  @doc """
  Fetches a single article by tenant and ID, including the embedding vector.

  The `embedding` field uses `load_in_query: false` to avoid loading the
  (potentially large) vector on every query. This function explicitly
  selects the embedding for callers that need it (e.g., embedding and
  linking workers).

  ## Returns

  - `{:ok, %Article{}}` with the `embedding` field populated
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_article_with_embedding(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Article.t()} | {:error, :not_found}
  def get_article_with_embedding(tenant_id, article_id) do
    query =
      from(a in Article,
        where: a.id == ^article_id and a.tenant_id == ^tenant_id,
        select_merge: %{embedding: a.embedding}
      )

    case AdminRepo.one(query) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  @doc """
  Lists articles for a tenant with optional filtering and pagination.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `opts` -- keyword list with:
    - `:project_id` -- filter by project UUID (optional)
    - `:category` -- filter by category atom (optional)
    - `:status` -- filter by status atom (optional)
    - `:tags` -- filter by tag overlap, articles matching ANY tag (optional)
    - `:source_type` -- filter by source_type string (optional)
    - `:limit` -- max records to return (default 20, max 100)
    - `:offset` -- records to skip for pagination (default 0)

  ## Returns

  - `%{data: [%Article{}], meta: %{total_count: integer, limit: integer, offset: integer}}`
  """
  @spec list_articles(Ecto.UUID.t(), keyword()) :: %{
          data: [Article.t()],
          meta: %{total_count: non_neg_integer(), limit: pos_integer(), offset: non_neg_integer()}
        }
  def list_articles(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(100)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        order_by: [desc: a.inserted_at]
      )

    base = apply_article_filters(base, opts)

    total_count = AdminRepo.aggregate(base, :count, :id)

    articles =
      base
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    %{
      data: articles,
      meta: %{total_count: total_count, limit: limit, offset: offset}
    }
  end

  @doc """
  Returns a lightweight knowledge index of published articles.

  The index includes only metadata fields (no body, embedding, or metadata)
  and groups results by category, sorted by `updated_at` descending within
  each group.

  Results are capped at 1000 articles. When the total exceeds 1000,
  `meta.truncated` is set to `true` and `meta.total_count` reflects the
  full count.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `opts` -- keyword list with:
    - `:project_id` -- when provided, includes both tenant-wide (nil project_id)
      and project-specific articles

  ## Returns

  - `{:ok, %{articles: %{category => [map()]}, meta: map()}}`
  """
  @spec list_index(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             articles: %{optional(String.t()) => [map()]},
             meta: %{
               total_count: non_neg_integer(),
               categories: %{optional(String.t()) => non_neg_integer()},
               truncated: boolean()
             }
           }}
  def list_index(tenant_id, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)

    query =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.status == :published,
        select: %{
          id: a.id,
          title: a.title,
          category: a.category,
          tags: a.tags,
          status: a.status,
          updated_at: a.updated_at
        },
        order_by: [asc: a.category, desc: a.updated_at]
      )

    query =
      if project_id do
        where(query, [a], is_nil(a.project_id) or a.project_id == ^project_id)
      else
        query
      end

    # Get total count via subquery
    count_query = from(q in subquery(query), select: count())
    total_count = AdminRepo.one(count_query)

    # Cap at 1000
    results =
      query
      |> limit(1000)
      |> AdminRepo.all()

    truncated = total_count > 1000

    # Group by category (convert enum atoms to strings for JSON)
    grouped =
      Enum.group_by(results, fn article ->
        to_string(article.category)
      end)

    categories = Map.new(grouped, fn {cat, arts} -> {cat, length(arts)} end)

    {:ok,
     %{
       articles: grouped,
       meta: %{
         total_count: total_count,
         categories: categories,
         truncated: truncated
       }
     }}
  end

  # --- Context Retrieval ---

  @doc """
  Retrieves full article bodies ranked by combined relevance + recency.

  Runs a combined (keyword + semantic) search, fetches full article records,
  computes recency scores using exponential decay, and re-ranks by a weighted
  combination of relevance and recency. Each result includes one-hop linked
  article references (max 5 per result).

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `query_string` -- the search query (required, max 500 characters)
  - `opts` -- keyword list with:
    - `:project_id` -- filter by project UUID (optional)
    - `:status` -- filter by status atom (default: `:published`)
    - `:limit` -- max results to return (default 5, max 20, min 1)
    - `:recency_weight` -- float between 0.0 and 1.0 (default 0.3)

  ## Returns

  - `{:ok, %{results: [map()], meta: map()}}` on success
  - `{:error, :empty_query}` when query is empty or nil
  - `{:error, :bad_request, String.t()}` when query exceeds 500 characters

  ## Scoring

  `combined_score = (1 - recency_weight) * relevance + recency_weight * recency_score`

  where `recency_score = exp(-age_in_days / 30.0)`.
  """
  @spec get_context(Ecto.UUID.t(), String.t() | nil, keyword()) ::
          {:ok, %{results: [map()], meta: map()}}
          | {:error, :empty_query}
          | {:error, atom(), String.t()}
  def get_context(tenant_id, query_string, opts \\ []) do
    query_string = to_string(query_string) |> String.trim()

    if query_string == "" do
      {:error, :empty_query}
    else
      do_get_context(tenant_id, query_string, opts)
    end
  end

  defp do_get_context(tenant_id, query_string, opts) do
    limit = opts |> Keyword.get(:limit, 5) |> max(1) |> min(20)
    recency_weight = opts |> Keyword.get(:recency_weight, 0.3) |> max(0.0) |> min(1.0)
    status = Keyword.get(opts, :status, :published)

    # Run combined search with a wider internal limit to get candidate pool
    search_opts =
      opts
      |> Keyword.take([:project_id])
      |> Keyword.merge(limit: limit * 3, offset: 0, status: status)

    {search_result, fallback?} = run_context_search(tenant_id, query_string, search_opts)

    case search_result do
      {:ok, search} ->
        build_context_results(tenant_id, search, limit, recency_weight, fallback?)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_context_search(tenant_id, query_string, search_opts) do
    case search_combined(tenant_id, query_string, search_opts) do
      {:ok, result} ->
        fallback? = result.meta[:fallback] == true
        {{:ok, result}, fallback?}

      {:error, _} ->
        # If combined fails entirely, try keyword-only
        case search_keyword(tenant_id, query_string, search_opts) do
          {:ok, result} -> {{:ok, result}, true}
          error -> {error, true}
        end
    end
  end

  defp build_context_results(tenant_id, search, limit, recency_weight, fallback?) do
    article_ids =
      search.results
      |> Enum.map(& &1[:id])
      |> Enum.reject(&is_nil/1)
      |> Enum.take(limit * 2)

    if article_ids == [] do
      {:ok,
       %{
         results: [],
         meta: %{
           total_count: 0,
           limit: limit,
           fallback: fallback?,
           recency_weight: recency_weight
         }
       }}
    else
      articles = fetch_full_context_articles(tenant_id, article_ids)
      now = DateTime.utc_now()

      article_ids_for_links = Enum.map(articles, & &1.id)
      linked_map = batch_linked_refs(tenant_id, article_ids_for_links)

      scored =
        articles
        |> Enum.map(fn article ->
          relevance = find_relevance_score(search.results, article.id)
          age_days = DateTime.diff(now, article.updated_at, :second) / 86_400.0
          recency_score = :math.exp(-age_days / 30.0)
          combined = (1.0 - recency_weight) * relevance + recency_weight * recency_score

          linked = Map.get(linked_map, article.id, [])

          %{
            id: article.id,
            title: article.title,
            category: to_string(article.category),
            tags: article.tags || [],
            body: article.body,
            updated_at: article.updated_at,
            relevance_score: Float.round(relevance + 0.0, 4),
            recency_score: Float.round(recency_score, 4),
            combined_score: Float.round(combined, 4),
            linked_articles: linked
          }
        end)
        |> Enum.sort_by(& &1.combined_score, :desc)
        |> Enum.take(limit)

      {:ok,
       %{
         results: scored,
         meta: %{
           total_count: length(scored),
           limit: limit,
           fallback: fallback?,
           recency_weight: recency_weight
         }
       }}
    end
  end

  defp fetch_full_context_articles(tenant_id, article_ids) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id and a.id in ^article_ids
    )
    |> AdminRepo.all()
  end

  defp find_relevance_score(results, article_id) do
    case Enum.find(results, fn r -> r[:id] == article_id end) do
      nil ->
        0.0

      r ->
        Map.get(r, :final_score) ||
          Map.get(r, :relevance_score) ||
          Map.get(r, :similarity_score) ||
          0.0
    end
  end

  # Batch-fetches linked article refs for all given article IDs in a single query.
  # Returns a map of article_id => [%{id, title, category}], capped at 5 per article.
  defp batch_linked_refs(_tenant_id, []), do: %{}

  defp batch_linked_refs(tenant_id, article_ids) do
    links =
      from(l in ArticleLink,
        where: l.tenant_id == ^tenant_id,
        where: l.source_article_id in ^article_ids or l.target_article_id in ^article_ids,
        preload: [:source_article, :target_article]
      )
      |> AdminRepo.all()

    # Group links by the article they belong to (could be source or target)
    Enum.reduce(article_ids, %{}, fn article_id, acc ->
      relevant_links =
        Enum.filter(links, fn link ->
          link.source_article_id == article_id or link.target_article_id == article_id
        end)

      linked =
        relevant_links
        |> Enum.flat_map(fn link ->
          [link.source_article, link.target_article]
          |> Enum.reject(&(is_nil(&1) or &1.id == article_id))
        end)
        |> Enum.uniq_by(& &1.id)
        |> Enum.take(5)
        |> Enum.map(fn article ->
          %{id: article.id, title: article.title, category: to_string(article.category)}
        end)

      Map.put(acc, article_id, linked)
    end)
  end

  @doc """
  Full-text keyword search on articles using PostgreSQL tsvector.

  Uses `websearch_to_tsquery` for parsing the query string, weighted
  `ts_rank_cd` for relevance ranking, and `ts_headline` for snippet
  generation.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `query_string` -- the search query (max 500 characters)
  - `opts` -- keyword list with:
    - `:project_id` -- filter by project UUID (optional)
    - `:category` -- filter by category atom (optional)
    - `:status` -- filter by status atom (default: `:published`)
    - `:tags` -- filter by tag overlap, articles matching ANY tag (optional)
    - `:limit` -- max results to return (default 20, max 100, min 1)
    - `:offset` -- results to skip for pagination (default 0)

  ## Returns

  - `{:ok, %{results: [map()], meta: map()}}` on success
  - `{:error, :empty_query}` when query is empty or nil
  - `{:error, :bad_request, String.t()}` when query exceeds 500 characters
  """
  @spec search_keyword(Ecto.UUID.t(), String.t() | nil, keyword()) ::
          {:ok, %{results: [map()], meta: map()}}
          | {:error, atom()}
          | {:error, atom(), String.t()}
  def search_keyword(tenant_id, query_string, opts \\ [])

  def search_keyword(_tenant_id, nil, _opts), do: {:error, :empty_query}
  def search_keyword(_tenant_id, "", _opts), do: {:error, :empty_query}

  def search_keyword(tenant_id, query_string, opts) do
    query_string = String.trim(query_string)

    cond do
      query_string == "" ->
        {:error, :empty_query}

      String.length(query_string) > 500 ->
        {:error, :bad_request, "Query too long (max 500 characters)"}

      true ->
        limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(100)
        offset = opts |> Keyword.get(:offset, 0) |> max(0)
        status = Keyword.get(opts, :status, :published)

        base_query =
          from(a in Article,
            where: a.tenant_id == ^tenant_id,
            where: fragment("search_vector @@ websearch_to_tsquery('english', ?)", ^query_string),
            select: %{
              id: a.id,
              tenant_id: a.tenant_id,
              project_id: a.project_id,
              title: a.title,
              category: a.category,
              status: a.status,
              tags: a.tags,
              inserted_at: a.inserted_at,
              updated_at: a.updated_at,
              relevance_score:
                fragment(
                  "ts_rank_cd(search_vector, websearch_to_tsquery('english', ?))",
                  ^query_string
                ),
              snippet:
                fragment(
                  "ts_headline('english', body, websearch_to_tsquery('english', ?), 'StartSel=**, StopSel=**, MaxWords=35, MinWords=15')",
                  ^query_string
                )
            },
            order_by: [
              desc:
                fragment(
                  "ts_rank_cd(search_vector, websearch_to_tsquery('english', ?))",
                  ^query_string
                )
            ]
          )

        filtered_query = apply_search_filters(base_query, status, opts)

        count_query = from(q in subquery(filtered_query), select: count())
        total_count = AdminRepo.one(count_query)

        results =
          filtered_query
          |> limit(^limit)
          |> offset(^offset)
          |> AdminRepo.all()

        {:ok,
         %{results: results, meta: %{total_count: total_count, limit: limit, offset: offset}}}
    end
  end

  defp apply_search_filters(query, status, opts) do
    query
    |> maybe_filter_by_status(status)
    |> maybe_filter_by_project_id(Keyword.get(opts, :project_id))
    |> maybe_filter_by_category(Keyword.get(opts, :category))
    |> maybe_filter_by_tags(Keyword.get(opts, :tags))
  end

  @doc """
  Updates an existing article.

  Uses `update_changeset` and records the `article.updated` audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID
  - `attrs` -- map of fields to update
  - `opts` -- keyword list with `:actor_id`, `:actor_label`, `:actor_type`

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, changeset}` on validation failure
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec update_article(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Article.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_article(tenant_id, article_id, attrs, opts \\ []) do
    project_id = attrs[:project_id] || attrs["project_id"]

    with :ok <- validate_project_ownership(tenant_id, project_id),
         {:ok, article} <- fetch_article(tenant_id, article_id) do
      actor_id = Keyword.get(opts, :actor_id)
      actor_label = Keyword.get(opts, :actor_label)
      actor_type = Keyword.get(opts, :actor_type, "api_key")
      old_state = article_state_snapshot(article)
      changeset = Article.update_changeset(article, attrs)

      changed_fields = changeset.changes |> Map.keys() |> Enum.map(&to_string/1)

      # Check changeset BEFORE Multi: only enqueue embedding when
      # title/body changed OR status transitions to :published.
      needs_embedding? = content_or_publish_changed?(changeset)

      multi =
        Multi.new()
        |> Multi.update(:article, changeset)
        |> Audit.log_in_multi(:audit, fn %{article: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "article",
            entity_id: updated.id,
            action: "article.updated",
            actor_type: actor_type,
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: old_state,
            new_state: article_state_snapshot(updated)
          }
        end)
        |> EventGenerator.generate_events(:webhook_events, fn %{article: updated} ->
          %{
            tenant_id: tenant_id,
            event_type: "article.updated",
            project_id: updated.project_id,
            payload:
              updated
              |> article_event_payload()
              |> Map.put("changed_fields", changed_fields)
          }
        end)
        |> maybe_enqueue_embedding(tenant_id, needs_embedding?)

      case AdminRepo.transaction(multi) do
        {:ok, %{article: updated}} -> {:ok, updated}
        {:error, :article, changeset, _} -> {:error, changeset}
      end
    end
  end

  @doc """
  Archives an article by setting its status to `:archived`.

  Records the `article.archived` audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID
  - `opts` -- keyword list with `:actor_id`, `:actor_label`, `:actor_type`

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec archive_article(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Article.t()} | {:error, :not_found}
  def archive_article(tenant_id, article_id, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    actor_type = Keyword.get(opts, :actor_type, "api_key")

    with {:ok, article} <- fetch_article(tenant_id, article_id) do
      old_status = to_string(article.status)
      changeset = Article.update_changeset(article, %{status: :archived})

      multi =
        Multi.new()
        |> Multi.update(:article, changeset)
        |> Audit.log_in_multi(:audit, fn %{article: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "article",
            entity_id: updated.id,
            action: "article.archived",
            actor_type: actor_type,
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: %{"status" => old_status},
            new_state: %{"status" => to_string(updated.status)}
          }
        end)
        |> EventGenerator.generate_events(:webhook_events, fn %{article: updated} ->
          %{
            tenant_id: tenant_id,
            event_type: "article.archived",
            project_id: updated.project_id,
            payload: article_event_payload(updated)
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{article: updated}} -> {:ok, updated}
        {:error, :article, changeset, _} -> {:error, changeset}
      end
    end
  end

  # --- Publish Workflow ---

  @doc """
  Publishes an article by transitioning its status from `:draft` to `:published`.

  Validates the transition via `Article.valid_transition?/2` and records
  the `article.published` audit event. Enqueues embedding generation.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID
  - `opts` -- keyword list with `:actor_id`, `:actor_label`, `:actor_type`

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, :not_found}` if not found or belongs to another tenant
  - `{:error, :unprocessable_entity, message}` on invalid transition
  """
  @spec publish_article(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Article.t()}
          | {:error, :not_found}
          | {:error, :unprocessable_entity, String.t()}
          | {:error, Ecto.Changeset.t()}
  def publish_article(tenant_id, article_id, opts \\ []) do
    transition_article(tenant_id, article_id, :published, "article.published", opts)
  end

  @doc """
  Unpublishes an article by transitioning its status from `:published` to `:draft`.

  Validates the transition via `Article.valid_transition?/2` and records
  the `article.unpublished` audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID
  - `opts` -- keyword list with `:actor_id`, `:actor_label`, `:actor_type`

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, :not_found}` if not found or belongs to another tenant
  - `{:error, :unprocessable_entity, message}` on invalid transition
  """
  @spec unpublish_article(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Article.t()}
          | {:error, :not_found}
          | {:error, :unprocessable_entity, String.t()}
          | {:error, Ecto.Changeset.t()}
  def unpublish_article(tenant_id, article_id, opts \\ []) do
    transition_article(tenant_id, article_id, :draft, "article.unpublished", opts)
  end

  @doc """
  Archives an article via the publish workflow.

  Unlike `archive_article/3` (called by DELETE), this function validates
  the status transition. Only `:draft` and `:published` articles can be
  archived. `:superseded` articles return a 422 error.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID
  - `opts` -- keyword list with `:actor_id`, `:actor_label`, `:actor_type`

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, :not_found}` if not found or belongs to another tenant
  - `{:error, :unprocessable_entity, message}` on invalid transition
  """
  @spec archive_article_workflow(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Article.t()}
          | {:error, :not_found}
          | {:error, :unprocessable_entity, String.t()}
          | {:error, Ecto.Changeset.t()}
  def archive_article_workflow(tenant_id, article_id, opts \\ []) do
    transition_article(tenant_id, article_id, :archived, "article.archived", opts)
  end

  @doc """
  Atomically publishes multiple draft articles.

  Validates that all article IDs belong to the tenant and that all
  articles are in `:draft` status. If any article fails validation,
  the entire operation is rolled back (atomic Multi).

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_ids` -- list of article UUIDs (max 100)
  - `opts` -- keyword list with `:actor_id`, `:actor_label`, `:actor_type`

  ## Returns

  - `{:ok, %{published: [%Article{}], count: integer}}` on success
  - `{:error, :bad_request, message}` when article_ids exceeds 100
  - `{:error, :bad_request, message}` when article_ids is empty
  - `{:error, :unprocessable_entity, message}` when any article is not a draft
  - `{:error, :not_found}` when any article ID is not found in the tenant
  """
  @spec bulk_publish(Ecto.UUID.t(), [Ecto.UUID.t()], keyword()) ::
          {:ok, %{published: [Article.t()], count: non_neg_integer()}}
          | {:error, atom(), String.t()}
          | {:error, :not_found}
  def bulk_publish(tenant_id, article_ids, opts \\ []) do
    cond do
      article_ids == [] or is_nil(article_ids) ->
        {:error, :bad_request, "article_ids must not be empty"}

      length(article_ids) > 100 ->
        {:error, :bad_request, "Maximum 100 articles per bulk publish"}

      true ->
        do_bulk_publish(tenant_id, article_ids, opts)
    end
  end

  @doc """
  Lists draft articles for a tenant, ordered by inserted_at desc.

  Returns source_type and source_id for review queue visibility.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `opts` -- keyword list with:
    - `:project_id` -- filter by project UUID (optional)
    - `:limit` -- max records to return (default 20, max 100)
    - `:offset` -- records to skip for pagination (default 0)

  ## Returns

  - `%{data: [%Article{}], meta: %{total_count: integer, limit: integer, offset: integer}}`
  """
  @spec list_drafts(Ecto.UUID.t(), keyword()) :: %{
          data: [Article.t()],
          meta: %{total_count: non_neg_integer(), limit: pos_integer(), offset: non_neg_integer()}
        }
  def list_drafts(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(100)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.status == :draft,
        order_by: [desc: a.inserted_at]
      )

    base = maybe_filter_by_project_id(base, Keyword.get(opts, :project_id))

    total_count = AdminRepo.aggregate(base, :count, :id)

    articles =
      base
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    %{
      data: articles,
      meta: %{total_count: total_count, limit: limit, offset: offset}
    }
  end

  # Shared transition logic for publish/unpublish/archive workflow
  defp transition_article(tenant_id, article_id, target_status, audit_action, opts) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    actor_type = Keyword.get(opts, :actor_type, "api_key")

    needs_embedding? = target_status == :published

    # Fetch-and-lock inside the transaction to eliminate TOCTOU races where
    # concurrent requests could change the status between validation and update.
    multi =
      Multi.new()
      |> Multi.run(:fetch, fn _repo, _changes ->
        query =
          from(a in Article,
            where: a.id == ^article_id and a.tenant_id == ^tenant_id,
            lock: "FOR UPDATE"
          )

        case AdminRepo.one(query) do
          nil -> {:error, {:not_found, nil}}
          article -> validate_transition_and_wrap(article, target_status)
        end
      end)
      |> Multi.run(:article, fn _repo, %{fetch: {article, _old_status}} ->
        changeset = Article.update_changeset(article, %{status: target_status})
        AdminRepo.update(changeset)
      end)
      |> Audit.log_in_multi(:audit, fn %{fetch: {_article, old_status}, article: updated} ->
        %{
          tenant_id: tenant_id,
          entity_type: "article",
          entity_id: updated.id,
          action: audit_action,
          actor_type: actor_type,
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{"status" => old_status},
          new_state: %{"status" => to_string(updated.status)}
        }
      end)
      |> EventGenerator.generate_events(:webhook_events, fn %{article: updated} ->
        %{
          tenant_id: tenant_id,
          event_type: audit_action,
          project_id: updated.project_id,
          payload: article_event_payload(updated)
        }
      end)
      |> maybe_enqueue_embedding(tenant_id, needs_embedding?)

    case AdminRepo.transaction(multi) do
      {:ok, %{article: updated}} ->
        {:ok, updated}

      {:error, :fetch, {:not_found, _}, _} ->
        {:error, :not_found}

      {:error, :fetch, {:unprocessable_entity, message}, _} ->
        {:error, :unprocessable_entity, message}

      {:error, :article, changeset, _} ->
        {:error, changeset}
    end
  end

  # Validates the transition and wraps the result for Multi.run compatibility.
  # Returns {:ok, {article, old_status_string}} or {:error, {error_type, detail}}.
  defp validate_transition_and_wrap(article, target_status) do
    if Article.valid_transition?(article.status, target_status) do
      {:ok, {article, to_string(article.status)}}
    else
      {:error,
       {:unprocessable_entity, "Cannot transition from #{article.status} to #{target_status}"}}
    end
  end

  defp do_bulk_publish(tenant_id, article_ids, opts) do
    # Fetch all articles up front and validate
    articles =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.id in ^article_ids
      )
      |> AdminRepo.all()

    with :ok <- validate_bulk_all_found(articles, article_ids),
         :ok <- validate_bulk_all_drafts(articles) do
      execute_bulk_publish(tenant_id, articles, article_ids, opts)
    end
  end

  defp validate_bulk_all_found(articles, article_ids) do
    found_ids = MapSet.new(articles, & &1.id)
    requested_ids = MapSet.new(article_ids)

    if MapSet.subset?(requested_ids, found_ids) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp validate_bulk_all_drafts(articles) do
    case Enum.find(articles, &(&1.status != :draft)) do
      nil ->
        :ok

      non_draft ->
        {:error, :unprocessable_entity,
         "Article #{non_draft.id} is in status #{non_draft.status}, expected draft"}
    end
  end

  defp execute_bulk_publish(tenant_id, articles, article_ids, opts) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    actor_type = Keyword.get(opts, :actor_type, "api_key")

    # Use {action, index} tuples as Multi keys to avoid atom exhaustion.
    # String.to_atom with dynamic UUIDs would leak atoms (never GC'd).
    indexed_articles = Enum.with_index(articles)

    multi =
      indexed_articles
      |> Enum.reduce(Multi.new(), fn {article, idx}, multi ->
        changeset = Article.update_changeset(article, %{status: :published})
        Multi.update(multi, {:publish, idx}, changeset)
      end)
      |> add_bulk_audit_entries(tenant_id, indexed_articles, actor_id, actor_label, actor_type)
      |> add_bulk_embedding_jobs(tenant_id, article_ids)

    case AdminRepo.transaction(multi) do
      {:ok, results} ->
        published =
          indexed_articles
          |> Enum.map(fn {_article, idx} -> Map.get(results, {:publish, idx}) end)
          |> Enum.reject(&is_nil/1)

        {:ok, %{published: published, count: length(published)}}

      {:error, _key, changeset, _completed} ->
        {:error, changeset}
    end
  end

  defp add_bulk_audit_entries(
         multi,
         tenant_id,
         indexed_articles,
         actor_id,
         actor_label,
         actor_type
       ) do
    Enum.reduce(indexed_articles, multi, fn {_article, idx}, multi ->
      Audit.log_in_multi(multi, {:audit, idx}, fn changes ->
        updated = Map.get(changes, {:publish, idx})

        %{
          tenant_id: tenant_id,
          entity_type: "article",
          entity_id: updated.id,
          action: "article.published",
          actor_type: actor_type,
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{"status" => "draft"},
          new_state: %{"status" => to_string(updated.status)}
        }
      end)
    end)
  end

  defp add_bulk_embedding_jobs(multi, tenant_id, article_ids) do
    Multi.run(multi, :embedding_jobs, fn _repo, _changes ->
      Enum.each(article_ids, fn article_id ->
        ArticleEmbeddingWorker.new(%{article_id: article_id, tenant_id: tenant_id})
        |> Oban.insert()
      end)

      {:ok, :enqueued}
    end)
  end

  # --- Obsidian Export ---

  @doc """
  Exports published articles as an Obsidian-compatible ZIP archive.

  The ZIP contains:
  - One `.md` file per published article, organized as `{category}/{slug}.md`
  - YAML frontmatter with title, category, tags, status, source_type, created_at, updated_at
  - A `## Related Articles` section with [[wikilinks]] for article links
  - A root `_index.md` listing all articles grouped by category with [[wikilinks]]

  Only published articles are included. If no published articles exist,
  the ZIP contains only `_index.md` (empty index).

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `opts` -- keyword list:
    - `:project_id` -- optional project UUID to scope export

  ## Returns

  - `{:ok, zip_binary}` on success
  - `{:error, :payload_too_large}` if published article count exceeds 5,000
  """
  @spec export_obsidian(Ecto.UUID.t(), keyword()) ::
          {:ok, binary()} | {:error, :payload_too_large}
  @max_export_articles 5_000

  def export_obsidian(tenant_id, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)

    if count_published_for_export(tenant_id, project_id) > @max_export_articles do
      {:error, :payload_too_large}
    else
      articles = fetch_published_for_export(tenant_id, project_id)
      zip_binary = build_obsidian_zip(articles)
      {:ok, zip_binary}
    end
  end

  defp count_published_for_export(tenant_id, project_id) do
    export_base_query(tenant_id, project_id)
    |> AdminRepo.aggregate(:count, :id)
  end

  defp fetch_published_for_export(tenant_id, project_id) do
    export_base_query(tenant_id, project_id)
    |> preload(outgoing_links: :target_article, incoming_links: :source_article)
    |> order_by([a], asc: a.category, asc: a.title)
    |> AdminRepo.all()
  end

  defp export_base_query(tenant_id, project_id) do
    query = from(a in Article, where: a.tenant_id == ^tenant_id and a.status == :published)

    if project_id do
      where(query, [a], is_nil(a.project_id) or a.project_id == ^project_id)
    else
      query
    end
  end

  defp build_obsidian_zip(articles) do
    grouped = Enum.group_by(articles, &to_string(&1.category))

    article_files =
      Enum.flat_map(grouped, fn {category, arts} ->
        Enum.map(arts, fn article ->
          path = "#{category}/#{slugify(article.title)}.md"
          content = build_obsidian_markdown(article)
          {String.to_charlist(path), content}
        end)
      end)

    index = build_obsidian_index(grouped)
    files = [{~c"_index.md", index} | article_files]

    {:ok, {_filename, zip_binary}} = :zip.create(~c"export.zip", files, [:memory])
    zip_binary
  end

  defp build_obsidian_markdown(article) do
    frontmatter = build_frontmatter(article)
    body = article.body || ""
    related = build_related_section(article)

    content = "#{frontmatter}\n#{body}"

    if related != "" do
      "#{content}\n\n#{related}\n"
    else
      "#{content}\n"
    end
  end

  defp build_frontmatter(article) do
    tags_yaml =
      case article.tags do
        [] -> ""
        tags -> "\ntags:\n" <> Enum.map_join(tags, "\n", &"  - #{&1}")
      end

    source_type_yaml =
      case article.source_type do
        nil -> ""
        st -> "\nsource_type: #{st}"
      end

    """
    ---
    title: "#{escape_yaml_string(article.title)}"
    category: #{article.category}#{tags_yaml}
    status: #{article.status}#{source_type_yaml}
    created_at: "#{DateTime.to_iso8601(article.inserted_at)}"
    updated_at: "#{DateTime.to_iso8601(article.updated_at)}"
    ---
    """
  end

  defp build_related_section(article) do
    outgoing =
      (article.outgoing_links || [])
      |> Enum.filter(&(&1.target_article != nil and &1.target_article.status == :published))
      |> Enum.map(fn link ->
        "- [[#{link.target_article.title}]] (#{link.relationship_type})"
      end)

    incoming =
      (article.incoming_links || [])
      |> Enum.filter(&(&1.source_article != nil and &1.source_article.status == :published))
      |> Enum.map(fn link ->
        "- [[#{link.source_article.title}]] (#{link.relationship_type})"
      end)

    all_links = Enum.uniq(outgoing ++ incoming)

    case all_links do
      [] -> ""
      links -> "## Related Articles\n\n" <> Enum.join(links, "\n")
    end
  end

  defp build_obsidian_index(grouped) do
    header = "# Knowledge Base Index\n\n"

    body =
      grouped
      |> Enum.sort_by(fn {category, _} -> category end)
      |> Enum.map_join("\n\n", fn {category, articles} ->
        article_list =
          articles
          |> Enum.sort_by(& &1.title)
          |> Enum.map_join("\n", fn article ->
            "- [[#{article.title}]]"
          end)

        "## #{String.capitalize(category)}\n\n#{article_list}"
      end)

    header <> body <> "\n"
  end

  @doc false
  def slugify(title) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^\w\s-]/u, "")
      |> String.replace(~r/\s+/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    if slug == "", do: "untitled", else: slug
  end

  defp escape_yaml_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  # --- Article Links ---

  @doc """
  Creates a new link between two articles.

  Sets `tenant_id` programmatically. Validates that both source and target
  articles exist within the same tenant. Records the `article_link.created`
  audit event.

  When the relationship type is `:supersedes`, the target article's status
  is set to `:superseded` within the same Multi transaction.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with source_article_id, target_article_id, relationship_type,
    and optional metadata

  ## Returns

  - `{:ok, %ArticleLink{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec create_link(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ArticleLink.t()} | {:error, Ecto.Changeset.t() | :target_not_found}
  def create_link(tenant_id, attrs, opts \\ []) do
    source_id = attrs[:source_article_id] || attrs["source_article_id"]
    target_id = attrs[:target_article_id] || attrs["target_article_id"]
    rel_type = attrs[:relationship_type] || attrs["relationship_type"]

    with :ok <- validate_articles_exist(tenant_id, source_id, target_id) do
      changeset =
        %ArticleLink{tenant_id: tenant_id}
        |> ArticleLink.changeset(attrs)

      multi =
        Multi.new()
        |> Multi.insert(:link, changeset)
        |> maybe_supersede_target(tenant_id, target_id, rel_type)
        |> Audit.log_in_multi(:audit, &build_link_audit(tenant_id, &1, opts))
        |> generate_link_created_events(tenant_id, source_id, target_id, rel_type)

      case AdminRepo.transaction(multi) do
        {:ok, %{link: link}} -> {:ok, link}
        {:error, :link, changeset, _} -> {:error, changeset}
        {:error, :superseded_target, reason, _} -> {:error, reason}
      end
    end
  end

  @doc """
  Deletes an article link, scoped by tenant.

  Records the `article_link.deleted` audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `link_id` -- the article link UUID

  ## Returns

  - `{:ok, %ArticleLink{}}` on success
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec delete_link(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ArticleLink.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_link(tenant_id, link_id, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    actor_type = Keyword.get(opts, :actor_type, "api_key")

    case AdminRepo.get_by(ArticleLink, id: link_id, tenant_id: tenant_id) do
      nil ->
        {:error, :not_found}

      link ->
        multi =
          Multi.new()
          |> Multi.delete(:link, link)
          |> Audit.log_in_multi(:audit, fn %{link: deleted} ->
            %{
              tenant_id: tenant_id,
              entity_type: "article_link",
              entity_id: deleted.id,
              action: "article_link.deleted",
              actor_type: actor_type,
              actor_id: actor_id,
              actor_label: actor_label,
              old_state: %{
                "source_article_id" => to_string(deleted.source_article_id),
                "target_article_id" => to_string(deleted.target_article_id),
                "relationship_type" => to_string(deleted.relationship_type)
              }
            }
          end)
          |> EventGenerator.generate_events(:webhook_events, fn %{link: deleted} ->
            %{
              tenant_id: tenant_id,
              event_type: "article_link.deleted",
              payload: %{
                "id" => deleted.id,
                "source_article_id" => deleted.source_article_id,
                "target_article_id" => deleted.target_article_id,
                "relationship_type" => to_string(deleted.relationship_type)
              }
            }
          end)

        case AdminRepo.transaction(multi) do
          {:ok, %{link: deleted}} -> {:ok, deleted}
          {:error, :link, changeset, _} -> {:error, changeset}
          {:error, :audit, changeset, _} -> {:error, changeset}
        end
    end
  end

  @doc """
  Lists all links for an article (both outgoing and incoming),
  with linked articles preloaded.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID

  ## Returns

  - List of `%ArticleLink{}` structs with linked articles preloaded
  """
  @spec list_links_for_article(Ecto.UUID.t(), Ecto.UUID.t()) :: [ArticleLink.t()]
  def list_links_for_article(tenant_id, article_id) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.source_article_id == ^article_id or l.target_article_id == ^article_id,
      preload: [:source_article, :target_article],
      order_by: [desc: l.inserted_at],
      limit: 100
    )
    |> AdminRepo.all()
  end

  # --- Embeddings ---

  @doc """
  Updates the embedding vector for an article.

  Validates that the embedding dimension matches the configured
  `:embedding_dimensions` (default 1536). The embedding is set via
  a dedicated `embedding_changeset/2`, not the standard update changeset,
  ensuring separation of concerns.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID
  - `embedding_vector` -- a list of floats matching the configured dimension

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, changeset}` on dimension mismatch
  - `{:error, :not_found}` if the article does not exist in this tenant
  """
  @spec update_embedding(Ecto.UUID.t(), Ecto.UUID.t(), list(number())) ::
          {:ok, Article.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_embedding(tenant_id, article_id, embedding_vector) do
    case AdminRepo.get_by(Article, id: article_id, tenant_id: tenant_id) do
      nil ->
        {:error, :not_found}

      article ->
        changeset = Article.embedding_changeset(article, embedding_vector)

        multi =
          Multi.new()
          |> Multi.update(:article, changeset)
          |> Audit.log_in_multi(:audit, fn %{article: updated} ->
            %{
              tenant_id: tenant_id,
              entity_type: "article",
              entity_id: updated.id,
              action: "article.embedding_updated",
              actor_type: "system",
              actor_id: nil,
              actor_label: "worker:embedding",
              new_state: %{
                "embedding_dimensions" => embedding_dimensions(updated.embedding)
              }
            }
          end)

        case AdminRepo.transaction(multi) do
          {:ok, %{article: article}} -> {:ok, article}
          {:error, :article, changeset, _} -> {:error, changeset}
        end
    end
  end

  @doc """
  Clears the embedding vector for an article by setting it to nil.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, :not_found}` if the article does not exist in this tenant
  """
  @spec clear_embedding(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Article.t()} | {:error, :not_found}
  def clear_embedding(tenant_id, article_id) do
    case AdminRepo.get_by(Article, id: article_id, tenant_id: tenant_id) do
      nil ->
        {:error, :not_found}

      article ->
        changeset = Ecto.Changeset.change(article, embedding: nil)

        multi =
          Multi.new()
          |> Multi.update(:article, changeset)
          |> Audit.log_in_multi(:audit, fn %{article: updated} ->
            %{
              tenant_id: tenant_id,
              entity_type: "article",
              entity_id: updated.id,
              action: "article.embedding_cleared",
              actor_type: "system",
              actor_id: nil,
              actor_label: "worker:embedding",
              new_state: %{"embedding_dimensions" => nil}
            }
          end)

        case AdminRepo.transaction(multi) do
          {:ok, %{article: article}} -> {:ok, article}
          {:error, :article, changeset, _} -> {:error, changeset}
        end
    end
  end

  # --- Private helpers ---

  defp embedding_dimensions(nil), do: nil
  defp embedding_dimensions(embedding) when is_list(embedding), do: length(embedding)
  defp embedding_dimensions(%Pgvector{} = vector), do: length(Pgvector.to_list(vector))

  defp fetch_article(tenant_id, article_id) do
    case AdminRepo.get_by(Article, id: article_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  defp validate_project_ownership(_tenant_id, nil), do: :ok

  defp validate_project_ownership(tenant_id, project_id) do
    case AdminRepo.get_by(Project, id: project_id, tenant_id: tenant_id) do
      nil ->
        {:error,
         %Article{}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:project_id, "does not belong to this tenant")}

      _project ->
        :ok
    end
  end

  defp apply_article_filters(query, opts) do
    query
    |> maybe_filter_by_project_id(Keyword.get(opts, :project_id))
    |> maybe_filter_by_category(Keyword.get(opts, :category))
    |> maybe_filter_by_status(Keyword.get(opts, :status))
    |> maybe_filter_by_tags(Keyword.get(opts, :tags))
    |> maybe_filter_by_source_type(Keyword.get(opts, :source_type))
  end

  defp maybe_filter_by_project_id(query, nil), do: query

  defp maybe_filter_by_project_id(query, project_id) do
    where(query, [a], a.project_id == ^project_id)
  end

  defp maybe_filter_by_category(query, nil), do: query

  defp maybe_filter_by_category(query, category) do
    where(query, [a], a.category == ^category)
  end

  defp maybe_filter_by_status(query, nil), do: query

  defp maybe_filter_by_status(query, status) do
    where(query, [a], a.status == ^status)
  end

  defp maybe_filter_by_tags(query, nil), do: query
  defp maybe_filter_by_tags(query, []), do: query

  defp maybe_filter_by_tags(query, tags) when is_list(tags) do
    where(query, [a], fragment("? && ?", a.tags, ^tags))
  end

  defp maybe_filter_by_source_type(query, nil), do: query

  defp maybe_filter_by_source_type(query, source_type) do
    where(query, [a], a.source_type == ^source_type)
  end

  defp validate_articles_exist(tenant_id, source_id, target_id) do
    source_exists =
      from(a in Article,
        where: a.id == ^source_id and a.tenant_id == ^tenant_id,
        select: true
      )
      |> AdminRepo.one()

    target_exists =
      from(a in Article,
        where: a.id == ^target_id and a.tenant_id == ^tenant_id,
        select: true
      )
      |> AdminRepo.one()

    cond do
      is_nil(source_exists) ->
        {:error,
         %Article{}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:source_article_id, "does not exist in this tenant")}

      is_nil(target_exists) ->
        {:error,
         %Article{}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:target_article_id, "does not exist in this tenant")}

      true ->
        :ok
    end
  end

  defp maybe_supersede_target(multi, tenant_id, _target_id, rel_type)
       when rel_type in [:supersedes, "supersedes"] do
    Multi.run(multi, :superseded_target, fn _repo, changes ->
      case AdminRepo.get_by(Article,
             id: changes.link.target_article_id,
             tenant_id: tenant_id
           ) do
        nil ->
          {:error, :target_not_found}

        target ->
          target
          |> Article.update_changeset(%{status: :superseded})
          |> AdminRepo.update()
      end
    end)
  end

  defp maybe_supersede_target(multi, _tenant_id, _target_id, _rel_type), do: multi

  defp build_link_audit(tenant_id, changes, opts) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    actor_type = Keyword.get(opts, :actor_type, "api_key")

    new_state = %{
      "source_article_id" => to_string(changes.link.source_article_id),
      "target_article_id" => to_string(changes.link.target_article_id),
      "relationship_type" => to_string(changes.link.relationship_type)
    }

    new_state =
      if Map.has_key?(changes, :superseded_target) do
        Map.put(new_state, "target_superseded", true)
      else
        new_state
      end

    %{
      tenant_id: tenant_id,
      entity_type: "article_link",
      entity_id: changes.link.id,
      action: "article_link.created",
      actor_type: actor_type,
      actor_id: actor_id,
      actor_label: actor_label,
      new_state: new_state
    }
  end

  defp article_state_snapshot(article) do
    %{
      "title" => article.title,
      "body" => article.body,
      "category" => to_string(article.category),
      "status" => to_string(article.status),
      "tags" => article.tags,
      "project_id" => article.project_id,
      "metadata" => article.metadata
    }
  end

  defp article_event_payload(article) do
    %{
      "id" => article.id,
      "title" => article.title,
      "category" => to_string(article.category),
      "project_id" => article.project_id,
      "status" => to_string(article.status),
      "tags" => article.tags
    }
  end

  defp generate_link_created_events(multi, tenant_id, source_id, target_id, rel_type) do
    multi
    |> EventGenerator.generate_events(:webhook_events, fn %{link: link} ->
      source = AdminRepo.get_by!(Article, id: source_id, tenant_id: tenant_id)
      target = AdminRepo.get_by!(Article, id: target_id, tenant_id: tenant_id)

      %{
        tenant_id: tenant_id,
        event_type: "article_link.created",
        payload: %{
          "id" => link.id,
          "source_article_id" => link.source_article_id,
          "target_article_id" => link.target_article_id,
          "relationship_type" => to_string(link.relationship_type),
          "source_title" => source.title,
          "target_title" => target.title
        }
      }
    end)
    |> maybe_generate_superseded_event(tenant_id, source_id, target_id, rel_type)
  end

  defp maybe_generate_superseded_event(multi, tenant_id, source_id, target_id, rel_type)
       when rel_type in [:supersedes, "supersedes"] do
    EventGenerator.generate_events(multi, :webhook_events_superseded, fn _changes ->
      source = AdminRepo.get_by!(Article, id: source_id, tenant_id: tenant_id)
      target = AdminRepo.get_by!(Article, id: target_id, tenant_id: tenant_id)

      %{
        tenant_id: tenant_id,
        event_type: "article.superseded",
        project_id: target.project_id,
        payload: %{
          "superseded_article_id" => target_id,
          "superseded_title" => target.title,
          "superseding_article_id" => source_id,
          "superseding_title" => source.title
        }
      }
    end)
  end

  defp maybe_generate_superseded_event(multi, _tenant_id, _source_id, _target_id, _rel_type),
    do: multi

  # --- Semantic Search ---

  @doc """
  Searches articles by cosine similarity against a query embedding vector.

  Returns top-K results ordered by cosine similarity (ascending distance
  via the `<=>` operator). Each result includes a `similarity_score` computed
  as `1 - cosine_distance`.

  Only articles with non-null embeddings are considered.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `query_embedding` -- a list of floats (the query vector)
  - `opts` -- keyword list with:
    - `:project_id` -- filter by project UUID (optional)
    - `:category` -- filter by category atom (optional)
    - `:status` -- filter by status atom (default: `:published`)
    - `:tags` -- filter by tag overlap, articles matching ANY tag (optional)
    - `:limit` -- max results to return (default 10, max 50, min 1)
    - `:offset` -- results to skip for pagination (default 0)

  ## Returns

  - `{:ok, %{results: [map()], meta: map()}}` on success
  """
  @spec search_semantic(Ecto.UUID.t(), [float()], keyword()) ::
          {:ok, %{results: [map()], meta: map()}}
  def search_semantic(tenant_id, query_embedding, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 10) |> max(1) |> min(50)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    status = Keyword.get(opts, :status, :published)

    base_query =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: not is_nil(a.embedding),
        select: %{
          id: a.id,
          tenant_id: a.tenant_id,
          project_id: a.project_id,
          title: a.title,
          category: a.category,
          status: a.status,
          tags: a.tags,
          inserted_at: a.inserted_at,
          updated_at: a.updated_at,
          similarity_score: fragment("1 - (embedding <=> ?)", ^query_embedding)
        },
        order_by: fragment("embedding <=> ?", ^query_embedding)
      )

    filtered_query = apply_search_filters(base_query, status, opts)

    count_query = from(q in subquery(filtered_query), select: count())
    total_count = AdminRepo.one(count_query)

    results =
      filtered_query
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok,
     %{
       results: results,
       meta: %{
         total_count: total_count,
         limit: limit,
         offset: offset,
         search_mode: "semantic_only"
       }
     }}
  end

  @doc """
  Combined keyword + semantic search with configurable weighting.

  Runs both `search_keyword/3` and `search_semantic/3`, normalizes their
  scores to a 0-1 range, then computes a weighted `final_score` for each
  article. Results are deduplicated by article ID and sorted by `final_score`
  descending.

  The query embedding is generated on-the-fly via the configured embedding
  client. If embedding generation fails (timeout, error, or circuit breaker),
  falls back to keyword-only search with `fallback: true` in the response meta.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `query_string` -- the search query text
  - `opts` -- keyword list with:
    - `:keyword_weight` -- weight for keyword scores (default 0.5)
    - `:semantic_weight` -- weight for semantic scores (default 0.5)
    - `:project_id`, `:category`, `:status`, `:tags` -- standard filters
    - `:limit` -- max results to return (default 10, max 50, min 1)
    - `:offset` -- results to skip for pagination (default 0)

  ## Returns

  - `{:ok, %{results: [map()], meta: map()}}` on success
  - `{:error, :invalid_weights}` when weights don't sum to 1.0
  - `{:error, :empty_query}` when query is empty
  """
  @spec search_combined(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, %{results: [map()], meta: map()}}
          | {:error, :invalid_weights}
          | {:error, :empty_query}
          | {:error, atom(), String.t()}
  def search_combined(tenant_id, query_string, opts \\ []) do
    keyword_weight = Keyword.get(opts, :keyword_weight, 0.5)
    semantic_weight = Keyword.get(opts, :semantic_weight, 0.5)

    with :ok <- validate_weights(keyword_weight, semantic_weight),
         {:ok, trimmed} <- validate_query_string(query_string) do
      do_combined_search(tenant_id, trimmed, keyword_weight, semantic_weight, opts)
    end
  end

  defp validate_weights(keyword_weight, semantic_weight) do
    if keyword_weight >= 0 and semantic_weight >= 0 and
         abs(keyword_weight + semantic_weight - 1.0) < 0.01 do
      :ok
    else
      {:error, :invalid_weights}
    end
  end

  defp validate_query_string(nil), do: {:error, :empty_query}
  defp validate_query_string(""), do: {:error, :empty_query}

  defp validate_query_string(query_string) do
    trimmed = String.trim(query_string)

    cond do
      trimmed == "" ->
        {:error, :empty_query}

      String.length(trimmed) > 500 ->
        {:error, :bad_request, "Query too long (max 500 characters)"}

      true ->
        {:ok, trimmed}
    end
  end

  defp do_combined_search(tenant_id, query_string, keyword_weight, semantic_weight, opts) do
    # Use wide limits for sub-searches to get comprehensive score pools
    sub_opts = Keyword.merge(opts, limit: 50, offset: 0)

    keyword_result = search_keyword(tenant_id, query_string, sub_opts)
    embedding_result = try_generate_embedding(query_string)

    case {keyword_result, embedding_result} do
      {{:ok, kw}, {:ok, embedding}} ->
        {:ok, semantic} = search_semantic(tenant_id, embedding, sub_opts)
        merge_results(kw, semantic, keyword_weight, semantic_weight, opts)

      {{:ok, kw}, {:error, _reason}} ->
        # Fallback to keyword-only
        paginated = paginate_results(kw.results, opts)

        {:ok,
         %{
           results: paginated.results,
           meta:
             Map.merge(kw.meta, %{
               fallback: true,
               search_mode: "keyword_only",
               total_count: kw.meta.total_count,
               limit: paginated.limit,
               offset: paginated.offset
             })
         }}

      {kw_error, _} ->
        kw_error
    end
  end

  defp merge_results(keyword_result, semantic_result, kw_weight, sem_weight, opts) do
    kw_normalized = normalize_scores(keyword_result.results, :relevance_score)
    sem_normalized = normalize_scores(semantic_result.results, :similarity_score)

    # Build merged map by article ID
    kw_map =
      Map.new(kw_normalized, fn r ->
        {r.id, Map.put(r, :final_score, kw_weight * r.normalized_score)}
      end)

    sem_map =
      Map.new(sem_normalized, fn r ->
        {r.id, Map.put(r, :final_score, sem_weight * r.normalized_score)}
      end)

    merged =
      Map.merge(kw_map, sem_map, fn _id, kw, sem ->
        Map.put(kw, :final_score, kw.final_score + sem.final_score)
      end)

    sorted =
      merged
      |> Map.values()
      |> Enum.sort_by(& &1.final_score, :desc)

    paginated = paginate_results(sorted, opts)

    {:ok,
     %{
       results: paginated.results,
       meta: %{
         total_count: length(sorted),
         limit: paginated.limit,
         offset: paginated.offset,
         search_mode: "combined"
       }
     }}
  end

  defp normalize_scores([], _score_key), do: []

  defp normalize_scores(results, score_key) do
    scores = Enum.map(results, &Map.get(&1, score_key, 0))
    min_s = Enum.min(scores)
    max_s = Enum.max(scores)
    range = max_s - min_s

    Enum.map(results, fn r ->
      score = Map.get(r, score_key, 0)
      normalized = if range == 0, do: 1.0, else: (score - min_s) / range
      Map.put(r, :normalized_score, normalized)
    end)
  end

  defp paginate_results(results, opts) do
    limit = opts |> Keyword.get(:limit, 10) |> max(1) |> min(50)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    paginated =
      results
      |> Enum.drop(offset)
      |> Enum.take(limit)

    %{results: paginated, limit: limit, offset: offset}
  end

  # --- Circuit breaker for embedding generation ---

  @circuit_breaker_table :loopctl_embedding_circuit_breaker
  @failure_threshold 3
  @failure_window_seconds 60
  @cooldown_seconds 30

  @doc false
  def init_circuit_breaker do
    if :ets.whereis(@circuit_breaker_table) == :undefined do
      try do
        :ets.new(@circuit_breaker_table, [
          :set,
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])
      rescue
        ArgumentError -> :already_exists
      end
    end

    :ok
  end

  @doc false
  def reset_circuit_breaker do
    if :ets.whereis(@circuit_breaker_table) != :undefined do
      :ets.delete_all_objects(@circuit_breaker_table)
    end

    :ok
  end

  @doc """
  Generate an embedding for the given text with circuit breaker and timeout protection.

  Wraps the configured embedding client with:
  - Circuit breaker (opens after #{@failure_threshold} failures within #{@failure_window_seconds}s)
  - 5-second Task.async timeout
  - Crash rescue handler

  Returns `{:ok, embedding}` or `{:error, reason}`.
  """
  def generate_embedding(query_string) do
    try_generate_embedding(query_string)
  end

  defp try_generate_embedding(query_string) do
    ensure_circuit_breaker_table()

    if circuit_open?() do
      {:error, :circuit_open}
    else
      task =
        Task.async(fn ->
          try do
            embedding_client().generate_embedding(query_string)
          rescue
            e -> {:error, {:embedding_crash, Exception.message(e)}}
          end
        end)

      case Task.yield(task, 5_000) || Task.shutdown(task) do
        {:ok, {:ok, embedding}} ->
          record_success()
          {:ok, embedding}

        {:ok, {:error, reason}} ->
          record_failure()
          {:error, reason}

        nil ->
          record_failure()
          {:error, :timeout}
      end
    end
  end

  defp circuit_open? do
    case :ets.lookup(@circuit_breaker_table, :circuit_open_until) do
      [{:circuit_open_until, open_until}] ->
        now = System.monotonic_time(:second)

        if now < open_until do
          true
        else
          # Cooldown expired, reset
          :ets.delete(@circuit_breaker_table, :circuit_open_until)
          :ets.delete(@circuit_breaker_table, :failures)
          false
        end

      [] ->
        false
    end
  end

  defp record_failure do
    ensure_circuit_breaker_table()
    now = System.monotonic_time(:second)

    failures =
      case :ets.lookup(@circuit_breaker_table, :failures) do
        [{:failures, existing}] -> existing
        [] -> []
      end

    # Keep only failures within the window
    recent = Enum.filter(failures, fn t -> now - t < @failure_window_seconds end)
    updated = [now | recent]
    :ets.insert(@circuit_breaker_table, {:failures, updated})

    if length(updated) >= @failure_threshold do
      :ets.insert(
        @circuit_breaker_table,
        {:circuit_open_until, now + @cooldown_seconds}
      )
    end
  end

  defp record_success do
    ensure_circuit_breaker_table()
    :ets.insert(@circuit_breaker_table, {:failures, []})
    :ets.delete(@circuit_breaker_table, :circuit_open_until)
  end

  defp ensure_circuit_breaker_table do
    if :ets.whereis(@circuit_breaker_table) == :undefined do
      init_circuit_breaker()
    end
  end

  defp embedding_client do
    Application.get_env(:loopctl, :embedding_client, Loopctl.Knowledge.EmbeddingClient)
  end

  # --- Embedding helpers ---

  # Returns true when the changeset includes title/body changes or a
  # status transition to :published. Used BEFORE the Multi executes so
  # the decision is based on the changeset, not the DB result.
  defp content_or_publish_changed?(changeset) do
    content_changed? =
      Map.has_key?(changeset.changes, :title) or Map.has_key?(changeset.changes, :body)

    status_changed_to_published? = changeset.changes[:status] == :published

    content_changed? or status_changed_to_published?
  end

  defp maybe_enqueue_embedding(multi, _tenant_id, false), do: multi

  defp maybe_enqueue_embedding(multi, tenant_id, true) do
    Multi.run(multi, :embedding_job, fn _repo, %{article: article} ->
      if article.status == :published do
        ArticleEmbeddingWorker.new(%{article_id: article.id, tenant_id: tenant_id})
        |> Oban.insert()
      else
        {:ok, :skipped}
      end
    end)
  end

  # --- Lint ---

  @all_categories [:pattern, :convention, :decision, :finding, :reference]
  @default_stale_days 90
  @default_min_coverage 3
  @default_max_per_category 50
  @hard_max_per_category 500

  @doc """
  Analyzes published articles and returns a structured lint report.

  The lint operation is read-only — no data is modified. It identifies:

  - **stale_articles** — articles not updated in N days (configurable via `:stale_days`)
  - **orphan_articles** — published articles with zero ArticleLinks (neither source nor target)
  - **contradiction_clusters** — groups of articles linked with `contradicts` relationship
  - **coverage_gaps** — categories with fewer than N published articles (configurable via `:min_coverage`)
  - **broken_sources** — articles whose `source_id` references a deleted entity

  ## Parameters

  - `tenant_id` — the tenant UUID
  - `opts` — keyword list with:
    - `:project_id` — scope to a specific project (includes tenant-wide articles)
    - `:stale_days` — threshold in days for stale detection (default 90)
    - `:min_coverage` — minimum published articles per category (default 3)
    - `:max_per_category` — cap for items returned in each issue array (default 50,
      max 500). Total counts before capping are returned in the summary under
      `:total_per_category`, and per-category truncation flags under `:truncated`.

  ## Returns

  - `{:ok, map()}` with `:stale_articles`, `:orphan_articles`, `:contradiction_clusters`,
    `:coverage_gaps`, `:broken_sources`, and `:summary`
  """
  @spec lint(Ecto.UUID.t(), keyword()) :: {:ok, map()}
  def lint(tenant_id, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    stale_days = Keyword.get(opts, :stale_days, @default_stale_days)
    min_coverage = Keyword.get(opts, :min_coverage, @default_min_coverage)

    max_per_category =
      opts
      |> Keyword.get(:max_per_category, @default_max_per_category)
      |> max(1)
      |> min(@hard_max_per_category)

    # Base query for published articles scoped to tenant (+ optional project)
    base = published_base_query(tenant_id, project_id)

    stale = find_stale_articles(base, stale_days)
    orphans = find_orphan_articles(base, tenant_id, project_id)
    contradictions = find_contradiction_clusters(tenant_id, project_id)
    gaps = find_coverage_gaps(base, min_coverage)
    broken = find_broken_sources(base)

    total_articles = AdminRepo.one(from(a in base, select: count(a.id)))

    # Capture totals BEFORE capping so callers know the true size.
    total_per_category = %{
      stale_articles: length(stale),
      orphan_articles: length(orphans),
      contradiction_clusters: length(contradictions),
      coverage_gaps: length(gaps),
      broken_sources: length(broken)
    }

    truncated = %{
      stale_articles: length(stale) > max_per_category,
      orphan_articles: length(orphans) > max_per_category,
      contradiction_clusters: length(contradictions) > max_per_category,
      coverage_gaps: length(gaps) > max_per_category,
      broken_sources: length(broken) > max_per_category
    }

    stale_capped = Enum.take(stale, max_per_category)
    orphans_capped = Enum.take(orphans, max_per_category)
    contradictions_capped = Enum.take(contradictions, max_per_category)
    gaps_capped = Enum.take(gaps, max_per_category)
    broken_capped = Enum.take(broken, max_per_category)

    # total_issues reflects the TRUE total before capping, so callers know the
    # full issue count even when arrays are truncated.
    total_issues =
      total_per_category.stale_articles + total_per_category.orphan_articles +
        total_per_category.contradiction_clusters + total_per_category.coverage_gaps +
        total_per_category.broken_sources

    all_issues = stale ++ orphans ++ contradictions ++ gaps ++ broken

    issues_by_severity =
      all_issues
      |> Enum.group_by(& &1.severity)
      |> Map.new(fn {severity, items} -> {severity, length(items)} end)

    summary = %{
      total_articles: total_articles,
      total_issues: total_issues,
      issues_by_severity: issues_by_severity,
      total_per_category: total_per_category,
      truncated: truncated,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok,
     %{
       stale_articles: stale_capped,
       orphan_articles: orphans_capped,
       contradiction_clusters: contradictions_capped,
       coverage_gaps: gaps_capped,
       broken_sources: broken_capped,
       summary: summary
     }}
  end

  defp published_base_query(tenant_id, nil) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: a.status == :published
    )
  end

  defp published_base_query(tenant_id, project_id) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: a.status == :published,
      where: is_nil(a.project_id) or a.project_id == ^project_id
    )
  end

  defp find_stale_articles(base, stale_days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-stale_days * 86_400, :second)

    query =
      from(a in base,
        where: a.updated_at < ^cutoff,
        select: %{
          id: a.id,
          title: a.title,
          updated_at: a.updated_at
        },
        order_by: [asc: a.updated_at]
      )

    now = DateTime.utc_now()

    AdminRepo.all(query)
    |> Enum.map(fn article ->
      days_since = DateTime.diff(now, article.updated_at, :day)

      %{
        article_id: article.id,
        title: article.title,
        last_updated: article.updated_at,
        days_since_update: days_since,
        severity: "warning",
        suggested_action: "Review and update or archive this article"
      }
    end)
  end

  defp find_orphan_articles(base, tenant_id, project_id) do
    # Subquery: article IDs that appear in any link (source or target)
    linked_ids_subquery =
      from(al in ArticleLink,
        where: al.tenant_id == ^tenant_id,
        select: %{id: al.source_article_id}
      )
      |> maybe_scope_links_to_project(project_id)

    linked_target_ids_subquery =
      from(al in ArticleLink,
        where: al.tenant_id == ^tenant_id,
        select: %{id: al.target_article_id}
      )
      |> maybe_scope_links_to_project(project_id)

    query =
      from(a in base,
        where: a.id not in subquery(linked_ids_subquery),
        where: a.id not in subquery(linked_target_ids_subquery),
        select: %{
          id: a.id,
          title: a.title,
          category: a.category
        },
        order_by: [asc: a.title]
      )

    AdminRepo.all(query)
    |> Enum.map(fn article ->
      %{
        article_id: article.id,
        title: article.title,
        category: to_string(article.category),
        severity: "info",
        suggested_action: "Consider linking to related articles or reviewing for relevance"
      }
    end)
  end

  defp maybe_scope_links_to_project(query, nil), do: query

  defp maybe_scope_links_to_project(query, _project_id) do
    # Links don't have project_id — we keep all links within the tenant.
    # The orphan check is scoped via the base query (published articles for
    # the project). A link to/from articles outside this project scope is
    # still valid and means the article is NOT orphaned.
    query
  end

  defp find_contradiction_clusters(tenant_id, project_id) do
    # Find all :contradicts links within the tenant
    links_query =
      from(al in ArticleLink,
        where: al.tenant_id == ^tenant_id,
        where: al.relationship_type == :contradicts,
        join: src in Article,
        on: src.id == al.source_article_id and src.status == :published,
        join: tgt in Article,
        on: tgt.id == al.target_article_id and tgt.status == :published,
        select: %{
          link_id: al.id,
          source_article_id: al.source_article_id,
          source_title: src.title,
          target_article_id: al.target_article_id,
          target_title: tgt.title
        }
      )

    links_query =
      if project_id do
        from([al, src, tgt] in links_query,
          where:
            (is_nil(src.project_id) or src.project_id == ^project_id) and
              (is_nil(tgt.project_id) or tgt.project_id == ^project_id)
        )
      else
        links_query
      end

    links = AdminRepo.all(links_query)

    # Build clusters using union-find approach (group connected articles)
    build_contradiction_clusters(links)
  end

  defp build_contradiction_clusters([]), do: []

  defp build_contradiction_clusters(links) do
    # Group links into connected clusters via a simple union-find
    {clusters, _parent} =
      Enum.reduce(links, {%{}, %{}}, fn link, {clusters, parent} ->
        src_id = link.source_article_id
        tgt_id = link.target_article_id

        src_root = find_root(parent, src_id)
        tgt_root = find_root(parent, tgt_id)

        # Merge into the same cluster
        root = min(src_root, tgt_root)
        parent = Map.put(parent, src_root, root)
        parent = Map.put(parent, tgt_root, root)
        parent = Map.put(parent, src_id, root)
        parent = Map.put(parent, tgt_id, root)

        # Track link in cluster keyed by root
        cluster_links = Map.get(clusters, root, [])
        clusters = Map.put(clusters, root, [link | cluster_links])

        # Re-key any existing clusters to new root
        clusters =
          if src_root != root and Map.has_key?(clusters, src_root) do
            existing = Map.get(clusters, src_root, [])
            clusters = Map.delete(clusters, src_root)
            Map.update(clusters, root, existing, &(existing ++ &1))
          else
            clusters
          end

        clusters =
          if tgt_root != root and Map.has_key?(clusters, tgt_root) do
            existing = Map.get(clusters, tgt_root, [])
            clusters = Map.delete(clusters, tgt_root)
            Map.update(clusters, root, existing, &(existing ++ &1))
          else
            clusters
          end

        {clusters, parent}
      end)

    # Normalize clusters: re-root all entries using current parent map
    normalized =
      Enum.reduce(clusters, %{}, fn {_key, links}, acc ->
        all_ids =
          links
          |> Enum.flat_map(fn l -> [l.source_article_id, l.target_article_id] end)
          |> Enum.uniq()

        root = Enum.min(all_ids)
        Map.update(acc, root, links, &(links ++ &1))
      end)

    normalized
    |> Enum.map(fn {_root, links} ->
      links = Enum.uniq_by(links, & &1.link_id)

      # Collect all unique articles in the cluster
      articles =
        links
        |> Enum.flat_map(fn l ->
          [
            %{id: l.source_article_id, title: l.source_title},
            %{id: l.target_article_id, title: l.target_title}
          ]
        end)
        |> Enum.uniq_by(& &1.id)

      %{
        article_ids: Enum.map(articles, & &1.id),
        titles: Enum.map(articles, & &1.title),
        link_ids: Enum.map(links, & &1.link_id),
        severity: "warning",
        suggested_action: "Resolve contradiction by updating or superseding one article"
      }
    end)
  end

  defp find_root(parent, id) do
    case Map.get(parent, id) do
      nil -> id
      ^id -> id
      other -> find_root(parent, other)
    end
  end

  defp find_coverage_gaps(base, min_coverage) do
    # Count published articles per category
    counts_query =
      from(a in base,
        group_by: a.category,
        select: {a.category, count(a.id)}
      )

    counts = AdminRepo.all(counts_query) |> Map.new()

    @all_categories
    |> Enum.filter(fn cat -> Map.get(counts, cat, 0) < min_coverage end)
    |> Enum.map(fn cat ->
      current = Map.get(counts, cat, 0)

      %{
        category: to_string(cat),
        current_count: current,
        threshold: min_coverage,
        severity: "info",
        suggested_action: "Add more articles in this category"
      }
    end)
  end

  # --- Pipeline Status ---

  @doc """
  Returns knowledge pipeline status for a tenant.

  Includes:
  - `pending_extractions` -- count of available/scheduled ReviewKnowledgeWorker jobs
  - `recent_drafts` -- 20 most recent draft articles with source_type "review_finding"
  - `publish_rate` -- ratio of published to total (published + draft) review_finding articles
  - `extraction_errors` -- count and 5 most recent failed/discarded extraction jobs
  - `auto_extract_enabled` -- current tenant setting (default true)

  All queries filter by tenant_id in SQL via the Oban job args JSONB field.
  """
  @spec pipeline_status(Ecto.UUID.t()) :: {:ok, map()}
  def pipeline_status(tenant_id) do
    tenant = AdminRepo.get(Loopctl.Tenants.Tenant, tenant_id)

    auto_extract_enabled =
      case tenant do
        nil -> true
        t -> Loopctl.Tenants.get_tenant_settings(t, "knowledge_auto_extract", true) != false
      end

    pending = count_pending_extractions(tenant_id)
    drafts = list_recent_drafts(tenant_id)
    rate = calculate_publish_rate(tenant_id)
    errors = list_extraction_errors(tenant_id)

    {:ok,
     %{
       pending_extractions: pending,
       recent_drafts: drafts,
       publish_rate: rate,
       extraction_errors: errors,
       auto_extract_enabled: auto_extract_enabled
     }}
  end

  defp count_pending_extractions(tenant_id) do
    seven_days_ago = DateTime.add(DateTime.utc_now(), -7, :day)
    tenant_id_str = to_string(tenant_id)

    from(j in "oban_jobs",
      where:
        j.worker == "Loopctl.Workers.ReviewKnowledgeWorker" and
          j.state in ["available", "scheduled"] and
          j.inserted_at > ^seven_days_ago and
          fragment("? ->> 'tenant_id' = ?", j.args, ^tenant_id_str),
      select: count(j.id)
    )
    |> AdminRepo.one()
  end

  defp list_recent_drafts(tenant_id) do
    from(a in Article,
      where:
        a.tenant_id == ^tenant_id and
          a.status == :draft and
          a.source_type == "review_finding",
      order_by: [desc: a.inserted_at],
      limit: 20,
      select: %{
        id: a.id,
        title: a.title,
        source_id: a.source_id,
        inserted_at: a.inserted_at
      }
    )
    |> AdminRepo.all()
  end

  defp calculate_publish_rate(tenant_id) do
    counts =
      from(a in Article,
        where:
          a.tenant_id == ^tenant_id and
            a.source_type == "review_finding" and
            a.status in [:draft, :published],
        group_by: a.status,
        select: {a.status, count(a.id)}
      )
      |> AdminRepo.all()
      |> Map.new()

    published = Map.get(counts, :published, 0)
    draft = Map.get(counts, :draft, 0)
    total = published + draft

    if total == 0, do: 0.0, else: published / total
  end

  defp list_extraction_errors(tenant_id) do
    tenant_id_str = to_string(tenant_id)

    error_count =
      from(j in "oban_jobs",
        where:
          j.worker == "Loopctl.Workers.ReviewKnowledgeWorker" and
            j.state in ["retryable", "discarded"] and
            fragment("? ->> 'tenant_id' = ?", j.args, ^tenant_id_str),
        select: count(j.id)
      )
      |> AdminRepo.one()

    recent_errors =
      from(j in "oban_jobs",
        where:
          j.worker == "Loopctl.Workers.ReviewKnowledgeWorker" and
            j.state in ["retryable", "discarded"] and
            fragment("? ->> 'tenant_id' = ?", j.args, ^tenant_id_str),
        order_by: [desc: j.attempted_at],
        limit: 5,
        select: %{
          id: j.id,
          state: j.state,
          error_reason: fragment("?[array_length(?, 1)]", j.errors, j.errors),
          attempted_at: j.attempted_at
        }
      )
      |> AdminRepo.all()

    %{
      count: error_count,
      recent: recent_errors
    }
  end

  defp find_broken_sources(base) do
    # Find articles with source_type "review_finding" whose source_id
    # no longer exists in the review_records table
    alias Loopctl.Artifacts.ReviewRecord

    query =
      from(a in base,
        where: a.source_type == "review_finding" and not is_nil(a.source_id),
        left_join: rr in ReviewRecord,
        on: rr.id == a.source_id and rr.tenant_id == a.tenant_id,
        where: is_nil(rr.id),
        select: %{
          id: a.id,
          title: a.title,
          source_type: a.source_type,
          source_id: a.source_id
        },
        order_by: [asc: a.title]
      )

    AdminRepo.all(query)
    |> Enum.map(fn article ->
      %{
        article_id: article.id,
        title: article.title,
        source_type: article.source_type,
        source_id: article.source_id,
        severity: "warning",
        suggested_action:
          "Source entity was deleted; consider updating or removing source reference"
      }
    end)
  end
end
