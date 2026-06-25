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

  # US-27.3: the controller resolves the suggested-links executor through this
  # behaviour so a test can inject a deterministic DB error via Mox.
  @behaviour Loopctl.Knowledge.SuggestLinksBehaviour

  import Ecto.Query

  require Logger

  alias Ecto.Adapters.SQL
  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.HeavyRead
  alias Loopctl.KeysetSeek
  alias Loopctl.Knowledge.Analytics
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Projects.Project
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Workers.ArticleEmbeddingWorker

  # Maximum page size for the article list endpoint (`list_articles/2`). Larger
  # limits are HONORED up to this cap so callers can paginate to exhaustion at
  # limit ∈ {100, 200, 500, 1000}; the controller rejects a requested limit above
  # this with 400 rather than silently clamping (which truncated result sets and
  # caused callers advancing `offset` by the requested limit to skip rows).
  @max_page_size 1000

  # Default enumeration page size when the caller passes no `:limit`. The keyset
  # path fetches `@default_page_size + 1` to detect a next page without a COUNT.
  @default_page_size 20

  # Maximum effective page size for which the keyset enumeration path will honor
  # `include_body: true` (US-27.10). Body-less is the default (#166); opting into
  # full bodies is bounded WELL below `@max_page_size` so a caller can't request
  # bodies for thousands of rows. Bodies are up to 500KB (see @max_body_bytes),
  # so 25 rows max × 500KB is a 12.5MB worst case, trimmed by the 5MB
  # full_content_byte_budget in the view. A request for `include_body: true` with
  # a requested `limit` above this is rejected by the HTTP layer with 400 (never
  # a silent oversized response).
  @max_include_body_page 25

  @doc """
  The maximum page size (`limit`) honored by the **enumeration** paths
  (`list_articles/2`, `list_filtered/2`, `list_keyset/2`, `list_drafts/2`,
  `list_index/2`).

  Exposed so the controller can reject an over-large requested `limit` with a
  400 instead of silently clamping it.
  """
  @spec max_page_size() :: pos_integer()
  def max_page_size, do: @max_page_size

  @doc """
  The maximum effective page size for which the keyset enumeration path honors
  `include_body: true` (US-27.10).

  Body-less is the default (#166); opting into full bodies is bounded to this so
  a caller can't request bodies for thousands of rows and reproduce the large
  chunked-payload failure. The HTTP layer rejects an `include_body: true` request
  whose requested `limit` exceeds this with a 400 — it is NOT silently clamped.
  """
  @spec max_include_body_page() :: pos_integer()
  def max_include_body_page, do: @max_include_body_page

  # Maximum result count for the **relevance** search modes (keyword / semantic /
  # combined). These return a ranked top-N, not an exhaustive enumeration, so
  # they are deliberately capped well below `@max_page_size`: a huge ranked page
  # is both semantically pointless (callers want the best matches, not all of
  # them) and expensive (per-row `ts_headline` snippet generation). The HTTP
  # layer rejects a relevance-mode `limit` above this with 400 — it is NOT
  # silently clamped — so `meta.limit` never under-reports what was requested.
  @max_relevance_page_size 100

  @doc """
  The maximum result count for the relevance search modes (keyword / semantic /
  combined). Distinct from `max_page_size/0`, which governs the exhaustive
  enumeration paths.
  """
  @spec max_relevance_page_size() :: pos_integer()
  def max_relevance_page_size, do: @max_relevance_page_size

  # Default/maximum number of facet rows (distinct tags) returned by `tag_facets/2`.
  # An omitted `:limit` is bounded by this (not "all"), so a tenant with tens of
  # thousands of distinct tags can't force an unbounded response; `distinct_count`
  # still reports the true cardinality and `truncated` flags when rows were capped.
  @max_facet_rows 1000

  # Multi-hop graph traversal caps: bound a single traversal so a dense graph
  # can't return an unbounded node/edge set. `truncated` flags when either is hit.
  # Runtime-configurable (so tests can exercise truncation cheaply); defaults below.
  @max_graph_nodes 100
  @max_graph_edges 500
  # per-node link cap to bound fan-out
  @max_graph_neighbors_per_node 10

  # Creativity primitives (#152). The distant-pairs self-join is O(candidates²),
  # so it samples at most @max_pair_candidates embedded articles (bounding the
  # cross product); a random walk takes at most @max_walk_length steps. The
  # candidate cap is operator-tunable via `config :loopctl, :max_pair_candidates`.
  @max_pair_candidates 1000
  @default_pair_limit 20
  @max_pair_limit 100
  @default_walk_length 4
  @max_walk_length 25
  # Novelty scoring embeds each idea concurrently (bounded) so a 50-idea batch
  # doesn't serialize 50 embedding round-trips.
  @novelty_concurrency 5

  # Maximum text length for a novelty idea to prevent unbounded embedding input.
  # OpenAI's embedding API accepts up to ~8k tokens (~32k chars); we cap at 4MB
  # to protect against DoS. Text beyond this is silently truncated before embedding.
  @max_idea_text_bytes 4 * 1024 * 1024

  # Byte budget for full-content (`include_body: true`) list reads. An article
  # `body` is up to 500 KB, so a 1000-row full-body page could be ~500 MB — an
  # agent-callable memory/DoS vector. Full-content pages therefore return as many
  # rows as fit within this serialized-body budget (always ≥1 for progress), plus
  # `meta.next_offset`/`meta.has_more`/`meta.byte_truncated` to continue (offset
  # path) or early page termination (keyset path, US-27.10). Bounds the response
  # regardless of the requested `limit` or per-row body size. Worst case per page
  # is ~budget + one body: the always-take-≥1 rule can include one row beyond the
  # budget, and `body` is byte-validated (≤500_000 bytes, see
  # Article @max_body_bytes), so worst case is ≤ ~5.5 MB total here.
  # Enumeration that doesn't need bodies should use the body-less summary
  # (the default) or `GET /knowledge/index`.
  @full_content_byte_budget 5_000_000

  # Fields returned by the body-less article summary projection (everything on
  # the article except the potentially-huge `body` and the never-loaded
  # `embedding`). Loaded via `select: struct(a, @summary_fields)` so `body` is
  # never transferred from Postgres for enumeration reads.
  @summary_fields [
    :id,
    :tenant_id,
    :project_id,
    :title,
    :category,
    :status,
    :scope,
    :slug,
    :tags,
    :source_type,
    :source_id,
    :idempotency_key,
    :metadata,
    :inserted_at,
    :updated_at
  ]

  @doc """
  The full-content (`include_body: true`) serialized-body byte budget for list reads.

  Reads `:full_content_byte_budget` from app config (so ops can tune it and tests
  can exercise truncation cheaply), defaulting to #{@full_content_byte_budget} bytes.
  """
  @spec full_content_byte_budget() :: pos_integer()
  def full_content_byte_budget,
    do: Application.get_env(:loopctl, :full_content_byte_budget, @full_content_byte_budget)

  # --- Articles ---

  @doc """
  Creates a new article within a tenant.

  Sets `tenant_id` programmatically and records the `article.created`
  audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with title (required), body (required), category (required),
    and optional: status, tags, source_type, source_id, idempotency_key,
    metadata, project_id
  - `opts` -- keyword list with `:actor_id`, `:actor_label`, `:actor_type`

  ## Returns

  - `{:ok, %Article{}}` on a fresh create
  - `{:ok, :deduplicated, %Article{}}` for an idempotent no-op (existing row
    returned unchanged; no second audit/webhook/embedding; callers answer HTTP
    200 not 201). Two triggers:
      1. **idempotency_key** matches an existing article — returned **regardless
         of body** (the key is the identity), taking precedence over the title
         check; a changed title/body is NOT applied.
      2. a concurrent/retried create collided on the **active title** AND the
         incoming body is identical after trimming leading/trailing whitespace.
  - `{:error, :duplicate_title, %Article{}}` when the active title is taken by an
    article with a DIFFERENT body and no idempotency_key matched (the caller
    should answer 409, not retry)
  - `{:error, changeset}` on any other validation failure
  """
  @spec create_article(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Article.t()}
          | {:ok, :deduplicated, Article.t()}
          | {:error, :duplicate_title, Article.t()}
          | {:error, Ecto.Changeset.t()}
  def create_article(tenant_id, attrs, opts \\ []) do
    scope = attrs[:scope] || attrs["scope"] || :tenant
    project_id = attrs[:project_id] || attrs["project_id"]
    vis = Keyword.get(opts, :visibility_agent_id)

    # System articles have no tenant — set tenant_id to nil
    effective_tenant_id = if scope in [:system, "system"], do: nil, else: tenant_id

    with :ok <- validate_project_ownership(tenant_id, project_id),
         # Idempotent fast path: a prior capture with the same idempotency_key is
         # a clean no-op — return it unchanged regardless of body (the key IS the
         # identity), so a re-run can't create a partial duplicate. Visibility (#163):
         # an agent only dedups against a match it can SEE — a key colliding with
         # another agent's private memory falls through to insert, where the unique
         # index rejects it without echoing the private article's id.
         nil <-
           get_article_by_idempotency_key(
             effective_tenant_id,
             idempotency_key_from_attrs(attrs),
             vis
           ) do
      actor_id = Keyword.get(opts, :actor_id)
      actor_label = Keyword.get(opts, :actor_label)
      actor_type = Keyword.get(opts, :actor_type, "api_key")

      changeset =
        %Article{tenant_id: effective_tenant_id}
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
        {:ok, %{article: article}} ->
          {:ok, article}

        {:error, :article, changeset, _} ->
          resolve_create_conflict(effective_tenant_id, attrs, changeset, vis)
      end
    else
      # validate_project_ownership/2 failure
      {:error, _reason} = error ->
        error

      # Idempotency fast path hit: an article with this idempotency_key already
      # exists — return it as a no-op dedup (the API answers 200).
      %Article{} = existing ->
        {:ok, :deduplicated, existing}
    end
  end

  # Make concurrent/retried creates safe on the (tenant_id, title) active unique
  # index. By the time the insert fails the constraint, the winning transaction
  # has committed, so the existing row is visible (the recovery SELECT below
  # deliberately mirrors the partial index's predicate, so the conflicting row is
  # guaranteed visible unless it was concurrently archived). The idempotency
  # signal is the article BODY itself (server-side, unforgeable): if the colliding
  # payload's body equals the existing article's (after trimming leading/trailing
  # whitespace), the conflict is a duplicate/retry -> return the existing row
  # idempotently as `{:ok, :deduplicated, existing}` (a no-op the API answers 200).
  # Otherwise it is a genuine different-body title collision ->
  # `{:error, :duplicate_title, existing}` so the API can answer 409 (not a
  # retry-into-the-same-422). Non-(active-title) failures pass through unchanged.
  #
  # The recovery SELECT runs after the insert's transaction has rolled back, so
  # there is a tiny window in which a THIRD writer mutates or archives the winning
  # row between its commit and our SELECT. That only produces a transient,
  # self-healing outcome — a 409 (body now differs), or the original 422 (row now
  # archived → SELECT returns nil) — which the client's next attempt resolves
  # cleanly. We accept that rather than re-running the whole create under a lock.
  defp resolve_create_conflict(tenant_id, attrs, changeset, vis) do
    cond do
      # A single failed INSERT raises exactly one unique violation, so the
      # changeset carries at most one of these constraint names — the cond order
      # is not a tie-breaker, just which recovery to run. An idempotency_key
      # violation (a create that raced past the pre-check) returns the winner as
      # a no-op dedup regardless of body.
      idempotency_conflict?(changeset) ->
        case get_article_by_idempotency_key(tenant_id, idempotency_key_from_attrs(attrs), vis) do
          %Article{} = existing -> {:ok, :deduplicated, existing}
          _ -> {:error, changeset}
        end

      active_title_conflict?(changeset) ->
        resolve_title_conflict(tenant_id, attrs, changeset)

      true ->
        {:error, changeset}
    end
  end

  defp resolve_title_conflict(tenant_id, attrs, changeset) do
    title = attrs[:title] || attrs["title"]

    case get_active_article_by_title(tenant_id, title) do
      %Article{} = existing ->
        if same_content?(existing, attrs) do
          {:ok, :deduplicated, existing}
        else
          {:error, :duplicate_title, existing}
        end

      _ ->
        {:error, changeset}
    end
  end

  defp idempotency_key_from_attrs(attrs), do: attrs[:idempotency_key] || attrs["idempotency_key"]

  defp idempotency_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "articles_tenant_idempotency_key_idx"
    end)
  end

  # Look up by idempotency_key across ALL statuses, mirroring the partial unique
  # index (which has no status predicate) so the conflicting row is always found.
  defp get_article_by_idempotency_key(_tenant_id, nil, _vis), do: nil
  defp get_article_by_idempotency_key(nil, _key, _vis), do: nil

  defp get_article_by_idempotency_key(tenant_id, key, vis) when is_binary(key) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id and a.idempotency_key == ^key,
      order_by: [asc: a.inserted_at],
      limit: 1
    )
    |> maybe_filter_by_visibility(vis)
    |> AdminRepo.one()
  end

  # Non-binary key (e.g. an integer) → no lookup.
  defp get_article_by_idempotency_key(_tenant_id, _key, _vis), do: nil

  # Only the active-title index — NOT the slug indexes, whose conflicts are on a
  # different field and must not be recovered via a title lookup.
  defp active_title_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "articles_tenant_title_active_idx"
    end)
  end

  defp get_active_article_by_title(_tenant_id, title) when not is_binary(title), do: nil

  # tenant_id is nil for system-scoped articles; a NULL `=` never matches, so the
  # recovery simply doesn't apply to system scope (its conflicts are slug-based).
  defp get_active_article_by_title(nil, _title), do: nil

  defp get_active_article_by_title(tenant_id, title) do
    AdminRepo.one(
      from(a in Article,
        where:
          a.tenant_id == ^tenant_id and a.title == ^title and
            a.status not in [:archived, :superseded],
        order_by: [asc: a.inserted_at],
        limit: 1
      )
    )
  end

  # Same content == same (whitespace-normalized) body. Derived server-side from
  # the actual content, so a caller cannot forge a match to alias/read back a
  # different article, and two genuinely-different bodies never silently merge.
  defp same_content?(existing, attrs) do
    incoming = attrs[:body] || attrs["body"]

    is_binary(incoming) and is_binary(existing.body) and
      String.trim(incoming) == String.trim(existing.body)
  end

  @doc """
  Retrieves a single article by ID, scoped to the tenant.

  Preloads outgoing links (with target articles) and incoming links
  (with source articles).

  Records a `"get"` access event when an `:api_key_id` is supplied
  via `opts`. Recording is fire-and-forget and never affects the read.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID
  - `opts` -- keyword list with optional:
    - `:api_key_id` -- for access tracking
    - `:access_metadata` -- extra context attached to the event
    - `:project_id` -- attribute the read to a project (US-25.1)
    - `:story_id` -- attribute the read to a story (US-25.1)

  ## Returns

  - `{:ok, %Article{}}` with preloaded links
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_article(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Article.t()} | {:error, :not_found}
  def get_article(tenant_id, article_id, opts \\ []) do
    case AdminRepo.get_by(Article, id: article_id, tenant_id: tenant_id) do
      nil ->
        {:error, :not_found}

      article ->
        # Visibility enforcement (#163): a private/owner memory the caller doesn't
        # own resolves to :not_found — no existence leak, no access recorded.
        vis = Keyword.get(opts, :visibility_agent_id)

        if visible_to_caller?(article, vis) do
          article =
            article
            |> AdminRepo.preload(
              outgoing_links: :target_article,
              incoming_links: :source_article
            )
            |> filter_visible_links(vis)

          Analytics.record_access(
            tenant_id,
            article.id,
            Keyword.get(opts, :api_key_id),
            "get",
            Keyword.get(opts, :access_metadata, %{}),
            attribution_context(opts)
          )

          {:ok, article}
        else
          {:error, :not_found}
        end
    end
  end

  # In-memory mirror of `maybe_filter_by_visibility/2` for single-article fetches.
  # `nil` agent_id (higher roles) sees everything; an agent sees shared articles
  # and its own memories.
  defp visible_to_caller?(_article, nil), do: true

  defp visible_to_caller?(article, agent_id) when is_binary(agent_id) do
    metadata = article.metadata || %{}
    visibility = metadata["visibility"] || metadata[:visibility] || "shared"
    owner = metadata["agent_id"] || metadata[:agent_id]
    visibility not in ["private", "owner"] or owner == agent_id
  end

  # Drops preloaded links whose far-side article the caller can't see (#163), so a
  # shared article never leaks a private memory's title via its links.
  defp filter_visible_links(article, nil), do: article

  defp filter_visible_links(article, vis) when is_binary(vis) do
    %{
      article
      | outgoing_links:
          Enum.filter(article.outgoing_links, &link_side_visible?(&1.target_article, vis)),
        incoming_links:
          Enum.filter(article.incoming_links, &link_side_visible?(&1.source_article, vis))
    }
  end

  defp link_side_visible?(%Article{} = far_side, vis), do: visible_to_caller?(far_side, vis)
  defp link_side_visible?(_not_loaded, _vis), do: false

  # Extracts the attribution context map from the caller's opts. Returns
  # an empty map when neither `:project_id` nor `:story_id` was provided.
  defp attribution_context(opts) do
    %{
      project_id: Keyword.get(opts, :project_id),
      story_id: Keyword.get(opts, :story_id)
    }
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
    - `:source_id` -- filter by source_id (optional; a malformed id matches nothing)
    - `:idempotency_key` -- filter by exact idempotency_key (optional)
    - `:limit` -- max records to return (default 20, max #{@max_page_size}).
      Limits above the max are clamped here as a safety net; the HTTP layer
      rejects an over-large requested limit with 400 (no silent truncation).
    - `:offset` -- records to skip for pagination (default 0)
    - `:include_body` -- when false (default), each row is a body-less summary
      (the `body` column is never transferred), so large enumeration pages are
      cheap and safe. When true, full bodies are returned but the page is bounded
      by a serialized-body byte budget (#{@full_content_byte_budget} bytes): it
      returns the longest prefix that fits (always ≥1 row) and reports
      `meta.next_offset`/`meta.has_more`/`meta.byte_truncated` for continuation.

  ## Returns

  - body-less: `%{data: [%Article{} (no body)], meta: %{total_count, limit, offset, include_body: false}}`
  - full-content: `%{data: [%Article{}], meta: %{total_count, limit, offset, include_body: true,
    returned, next_offset, has_more, byte_truncated, byte_budget}}`
  """
  @spec list_articles(Ecto.UUID.t(), keyword()) :: %{data: [Article.t()], meta: map()}
  def list_articles(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(@max_page_size)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    include_body = Keyword.get(opts, :include_body, false)

    base =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        # Total order (id tie-break) so offset pagination can't skip/duplicate
        # rows that share an `inserted_at`.
        order_by: [desc: a.inserted_at, asc: a.id]
      )

    base = apply_article_filters(base, opts)
    total_count = AdminRepo.aggregate(base, :count, :id)

    if include_body do
      paginate_with_body_budget(base, total_count, limit, offset)
    else
      paginate_summary(base, total_count, limit, offset)
    end
  end

  # Body-less enumeration page: projects every field except the (potentially
  # huge) `body`, so the response is bounded by metadata size and large pages
  # (up to @max_page_size) are safe.
  defp paginate_summary(base, total_count, limit, offset) do
    articles =
      base
      |> limit(^limit)
      |> offset(^offset)
      |> select([a], struct(a, ^@summary_fields))
      |> AdminRepo.all()

    %{
      data: articles,
      meta: %{total_count: total_count, limit: limit, offset: offset, include_body: false}
    }
  end

  # Full-content page: bounds the response by a serialized-body byte budget
  # rather than a row count (bodies vary ~100x in size). First reads just the
  # id + body byte-length for the requested window (no body transfer), takes the
  # longest prefix that fits the budget (always ≥1 row), then loads the full rows
  # for exactly those ids. Surfaces continuation via `meta`.
  defp paginate_with_body_budget(base, total_count, limit, offset) do
    budget = full_content_byte_budget()

    # Run both queries in a read-only transaction for a consistent snapshot,
    # since concurrent writes between the sized query and the fetch could
    # let a page slightly exceed the budget or make returned/next_offset optimistic.
    {:ok, {ids, byte_truncated, articles}} =
      AdminRepo.transaction(fn ->
        sized =
          base
          |> limit(^limit)
          |> offset(^offset)
          |> select([a], %{id: a.id, bytes: fragment("coalesce(octet_length(?), 0)", a.body)})
          |> AdminRepo.all()

        {ids, byte_truncated} = take_within_byte_budget(sized, budget)

        articles =
          base
          |> where([a], a.id in ^ids)
          |> AdminRepo.all()

        {ids, byte_truncated, articles}
      end)

    returned = length(ids)
    next_offset = offset + returned

    %{
      data: articles,
      meta: %{
        total_count: total_count,
        limit: limit,
        offset: offset,
        include_body: true,
        returned: returned,
        next_offset: next_offset,
        has_more: next_offset < total_count,
        byte_truncated: byte_truncated,
        byte_budget: budget
      }
    }
  end

  # Takes the longest prefix of the (already-ordered) sized rows whose cumulative
  # body bytes stay within `budget`. Always takes at least one row so a page can
  # make progress even if a single body is unusually large. Returns
  # `{ids_in_order, truncated?}` where `truncated?` is true when the budget
  # stopped us before consuming the whole window.
  defp take_within_byte_budget(sized, budget) do
    {rev_ids, _sum, truncated} =
      Enum.reduce_while(sized, {[], 0, false}, fn %{id: id, bytes: bytes}, {acc, sum, _trunc} ->
        new_sum = sum + bytes

        cond do
          acc == [] -> {:cont, {[id], bytes, false}}
          new_sum > budget -> {:halt, {acc, sum, true}}
          true -> {:cont, {[id | acc], new_sum, false}}
        end
      end)

    {Enum.reverse(rev_ids), truncated}
  end

  @doc """
  Retrieves a system article by slug. No tenant scoping — system articles
  are globally visible.

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, :not_found}` if no published system article with that slug exists
  """
  @spec get_system_article_by_slug(String.t()) :: {:ok, Article.t()} | {:error, :not_found}
  def get_system_article_by_slug(slug) when is_binary(slug) do
    case AdminRepo.get_by(Article, slug: slug, scope: :system, status: :published) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  @doc """
  Lists all published system articles, optionally filtered by category.
  Returns results ordered by title.
  """
  @spec list_system_articles(keyword()) :: [Article.t()]
  def list_system_articles(opts \\ []) do
    base =
      from(a in Article,
        where: a.scope == :system and a.status == :published,
        order_by: [asc: a.title]
      )

    base =
      case Keyword.get(opts, :category) do
        nil -> base
        cat -> from(a in base, where: a.category == ^cat)
      end

    AdminRepo.all(base)
  end

  @doc """
  Lists all published system articles grouped by category.
  Returns a map of `%{category => [articles]}`.
  """
  @spec list_system_articles_grouped() :: %{atom() => [Article.t()]}
  def list_system_articles_grouped do
    list_system_articles()
    |> Enum.group_by(& &1.category)
  end

  @doc """
  Returns a lightweight knowledge index of published articles.

  The index includes only metadata fields (no body, embedding, or metadata)
  and groups the current page of results by category. Within the full filtered
  set, articles are ordered deterministically by `category` ascending,
  `updated_at` descending, then `id` ascending — so `offset`/`limit`
  pagination reaches every article without skipping or repeating.

  Unlike a relevance search, this endpoint honors `category`/`tags` filters
  and real pagination. `meta.categories` reports the per-category counts over
  the **entire** filtered set (not just the returned page) so callers can plan
  pagination and discover categories that fall on later pages. `meta.truncated`
  is `true` whenever more rows remain beyond the returned page.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `opts` -- keyword list with:
    - `:project_id` -- when provided, includes both tenant-wide (nil project_id)
      and project-specific articles
    - `:category` -- filter to a single category atom (optional)
    - `:tags` -- filter to articles matching ANY of the given tags (optional)
    - `:limit` -- max articles to return (default 1000, max 1000, min 1)
    - `:offset` -- rows to skip for pagination (default 0)
    - `:story_id` -- accepted for caller ergonomics (US-25.1); index listings
      are intentionally not recorded as access events so the value is not
      persisted anywhere

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
               offset: non_neg_integer(),
               limit: pos_integer(),
               truncated: boolean()
             }
           }}
  def list_index(tenant_id, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    limit = opts |> Keyword.get(:limit, @max_page_size) |> max(1) |> min(@max_page_size)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.status == :published
      )

    base =
      if project_id do
        where(base, [a], is_nil(a.project_id) or a.project_id == ^project_id)
      else
        base
      end

    base =
      base
      |> maybe_filter_by_category(Keyword.get(opts, :category))
      |> maybe_filter_by_tags(Keyword.get(opts, :tags), Keyword.get(opts, :match, :any))
      |> maybe_filter_by_source_type(Keyword.get(opts, :source_type))
      |> maybe_filter_by_source_id(Keyword.get(opts, :source_id))
      |> maybe_filter_by_visibility(Keyword.get(opts, :visibility_agent_id))

    total_count = AdminRepo.aggregate(base, :count, :id)

    # Per-category counts over the ENTIRE filtered set (not just the page),
    # so callers can see categories that live on later pages.
    categories =
      base
      |> group_by([a], a.category)
      |> select([a], {a.category, count(a.id)})
      |> AdminRepo.all()
      |> Map.new(fn {cat, n} -> {to_string(cat), n} end)

    # Deterministic ordering so offset/limit reaches every article exactly once.
    results =
      base
      |> select([a], %{
        id: a.id,
        title: a.title,
        category: a.category,
        tags: a.tags,
        status: a.status,
        updated_at: a.updated_at
      })
      |> order_by([a], asc: a.category, desc: a.updated_at, asc: a.id)
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    truncated = total_count > offset + length(results)

    # Group the current page by category (convert enum atoms to strings for JSON)
    grouped =
      Enum.group_by(results, fn article ->
        to_string(article.category)
      end)

    {:ok,
     %{
       articles: grouped,
       meta: %{
         total_count: total_count,
         categories: categories,
         offset: offset,
         limit: limit,
         truncated: truncated
       }
     }}
  end

  @doc """
  KEYSET (cursor) enumeration of the knowledge index (US-27.9b).

  The drift-free companion to `list_index/2`, applying the SAME index filters
  (`:project_id`, `:category`, `:tags` + `:match`, `:source_type`, `:source_id`,
  visibility) but seeking on the stable unique tuple `(inserted_at, id)` instead
  of `OFFSET`. The live offset-drift incident (#175) was a by-TAG walk on this
  surface (a tag count swung 9,881 → 4,981 mid-enumeration), so this rolls the
  proven US-27.9a keyset mechanic onto the index's by-tag/by-source enumerations:

      WHERE tenant_id = ^tenant_id
        AND status = :published
        AND (project_id IS NULL OR project_id = ^project_id)   -- when project-scoped
        AND <category/tags/source_type/source_id/visibility residuals>
        AND (cursor? -> (inserted_at, id) > (^c_inserted, ^c_id))
      ORDER BY inserted_at ASC, id ASC
      LIMIT ^(limit + 1)

  The `id` tie-break is mandatory (`inserted_at` is `utc_datetime_usec` and bulk
  `insert_all` ties timestamps per batch). The `limit + 1` peek tells us whether a
  next page exists WITHOUT a `COUNT` — so there is no count to drift either.

  Tenant scope comes from `tenant_id` (the caller's authenticated principal),
  NEVER from the cursor. The cursor (the same `Loopctl.Knowledge.ArticleCursor`
  the article-list keyset uses, verbatim) encodes only the intra-tenant ordering
  position and is decoded/verified at the HTTP layer.

  Unlike `list_keyset/2` (the search-list keyset), this path:

  - forces `status = :published` (the index is published-only) and supports the
    `(project_id IS NULL OR = project)` tenant-wide-plus-project visibility, and
  - APPLIES the `:source_type`/`:source_id` filters (the by-source enumeration —
    the search-list keyset did not need them). by-source is a selective scalar
    equality, served index-backed at scale by `articles_tenant_source_inserted_id_idx`
    (see the `:scale_nightly` plan test), with the `(tenant_id, inserted_at, id)`
    btree as the residual-free fallback.

  ## Parameters

  - `tenant_id` -- the tenant UUID (from the auth principal)
  - `opts` -- keyword list:
    - `:cursor` -- the decoded `{inserted_at, id}` position to seek AFTER, or
      `nil`/absent to start from the beginning
    - `:limit` -- max results per page (default 20, max #{@max_page_size}, min 1);
      clamped here as a safety net, the HTTP layer 400s an over-large request
    - `:project_id`, `:category`, `:tags`, `:match`, `:source_type`, `:source_id`,
      `:visibility_agent_id` -- same filters as `list_index/2`

  ## Returns

  - `{:ok, %{results: [map()], next_cursor: position_or_nil, has_more: bool,
    limit: effective_limit}}` where `next_cursor` is the `(inserted_at, id)` tuple
    of the LAST returned row when another page exists, else `nil`. `has_more` is
    exactly `next_cursor != nil`, never a COUNT.
  """
  @spec list_index_keyset(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             results: [map()],
             next_cursor: {DateTime.t(), Ecto.UUID.t()} | nil,
             has_more: boolean(),
             limit: pos_integer()
           }}
  def list_index_keyset(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_page_size) |> max(1) |> min(@max_page_size)

    # Fetch limit+1 to detect a next page without a COUNT (AC-27.9b.1).
    rows =
      tenant_id
      |> index_keyset_query(Keyword.put(opts, :limit, limit + 1))
      |> then(&HeavyRead.all(tenant_id, &1, heavy_read_opts(:enumeration)))

    {page, has_more?} = split_peek(rows, limit)
    next_cursor = keyset_next_cursor(page, has_more?)

    {:ok,
     %{
       results: page,
       next_cursor: next_cursor,
       has_more: has_more?,
       limit: limit
     }}
  end

  @doc """
  Builds the index KEYSET seek QUERYABLE (US-27.9b), returned (not executed) so
  the `:scale_nightly` plan test can assert it is index-backed via `EXPLAIN`.

  This is the EXACT query `list_index_keyset/2` runs (so the plan assertion guards
  the request path, not a stunt double). Same `opts` as `list_index_keyset/2`;
  `:limit` is applied as-is (the caller adds the `+1` peek).

  Plan note (AC-27.9b.2):

  - With no filter or a scalar `:category` residual the planner walks the
    `(tenant_id, inserted_at, id)` btree in order — true keyset, no Sort.
  - With `:source_id` (selective scalar equality) the planner uses the
    `(tenant_id, source_id, inserted_at, id)` composite btree, walking it in
    `(inserted_at, id)` order for that source — strictly index-ordered, no Sort.
  - With a `:tags` (array `&&`) residual the planner BitmapAnds the tags GIN with
    the keyset btree and Sorts — bounded by tag selectivity, NOT the corpus (the
    same bounded path US-27.9a already proved; no single index can serve both array
    containment and the order key).
  """
  @spec index_keyset_query(Ecto.UUID.t(), keyword()) :: Ecto.Query.t()
  def index_keyset_query(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_page_size + 1) |> max(1)
    project_id = Keyword.get(opts, :project_id)

    base =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.status == :published
      )

    base =
      if project_id do
        where(base, [a], is_nil(a.project_id) or a.project_id == ^project_id)
      else
        base
      end

    base
    |> maybe_filter_by_category(Keyword.get(opts, :category))
    |> maybe_filter_by_tags(Keyword.get(opts, :tags), Keyword.get(opts, :match, :any))
    |> maybe_filter_by_source_type(Keyword.get(opts, :source_type))
    |> maybe_filter_by_source_id(Keyword.get(opts, :source_id))
    |> maybe_filter_by_visibility(Keyword.get(opts, :visibility_agent_id))
    |> apply_keyset_seek(Keyword.get(opts, :cursor))
    |> select([a], %{
      id: a.id,
      title: a.title,
      category: a.category,
      tags: a.tags,
      status: a.status,
      updated_at: a.updated_at,
      inserted_at: a.inserted_at
    })
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> limit(^limit)
  end

  @doc """
  Returns aggregate article counts for a tenant (optionally scoped to a project).

  Cheap `COUNT(*) ... GROUP BY` aggregates — no article rows or metadata are
  loaded — so a caller can answer "how many articles are here?" without paging
  the index. Counts span ALL statuses (draft, published, archived, superseded);
  the `by_status` breakdown makes the split explicit. Consequently `total` is
  NOT comparable to the published-only counts elsewhere — `list_index/2`'s
  `meta.total_count` and `search_keyword/3` list-mode `total_count` both count
  published articles only, so they differ from `total` whenever
  drafts/archived/superseded exist.

  `by_category` and `by_status` are **dense**: every category/status is present,
  with a count of 0 when no article matches (so callers never get `nil` for a
  known key and need not enumerate the key universe themselves).

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `opts` -- keyword list with:
    - `:project_id` -- when provided, counts both tenant-wide (nil project_id)
      and project-specific articles (same visibility as `list_index/2`)

  ## Returns

  - `%{total: non_neg_integer(), by_category: %{String.t() => non_neg_integer()},
      by_status: %{String.t() => non_neg_integer()}}`
  """
  @spec stats(Ecto.UUID.t(), keyword()) :: %{
          total: non_neg_integer(),
          by_category: %{optional(String.t()) => non_neg_integer()},
          by_status: %{optional(String.t()) => non_neg_integer()}
        }
  def stats(tenant_id, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)

    base = from(a in Article, where: a.tenant_id == ^tenant_id)

    base =
      if project_id do
        where(base, [a], is_nil(a.project_id) or a.project_id == ^project_id)
      else
        base
      end

    # Visibility (#163): an agent's stats never count another agent's private memories.
    base = maybe_filter_by_visibility(base, Keyword.get(opts, :visibility_agent_id))

    # Zero-fill every category/status so the maps are dense: a caller can read
    # `by_status["published"]` and get 0 (not nil) for a wiki with no published
    # articles, and never has to know the key universe to interpret the result.
    by_category = count_by(base, :category, Ecto.Enum.values(Article, :category))
    by_status = count_by(base, :status, Ecto.Enum.values(Article, :status))

    # `status` is NOT NULL (Ecto.Enum, default :draft), so every row falls into
    # exactly one by_status bucket — summing them equals COUNT(*) and avoids a
    # third aggregate query. If status ever becomes nullable, switch `total` to
    # an explicit `AdminRepo.aggregate(base, :count, :id)`.
    total = by_status |> Map.values() |> Enum.sum()

    %{total: total, by_category: by_category, by_status: by_status}
  end

  @doc """
  Counts articles matching the given filters **without** returning any rows.

  Accepts the same filters as `list_articles/2` (`:project_id`, `:category`,
  `:status`, `:tags` + `:match`, `:source_type`, `:source_id`,
  `:idempotency_key`), so a single call answers "how many *published* articles
  tagged both X and Y" (status + `tags` + `match: :all`) without enumerating rows.

  ## Returns

  - `non_neg_integer()`
  """
  @spec count_articles(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def count_articles(tenant_id, opts \\ []) do
    from(a in Article, where: a.tenant_id == ^tenant_id)
    |> apply_article_filters(opts)
    |> AdminRepo.aggregate(:count, :id)
  end

  @doc """
  Counts articles grouped by each distinct tag (a tag facet).

  Unnests `tags` over the filtered article set and counts articles per tag, so
  callers can get a **distinct-tag count** and per-tag totals without paginating
  rows. Honors the same filters as `count_articles/2` (including `:status` and
  `:tags`/`:match`), plus an optional `:tag_prefix` to restrict to a tag family
  (e.g. `"book-"` to count distinct books). Ordered by descending count.

  ## Parameters

  - `opts` -- `list_articles/2` filters, plus:
    - `:tag_prefix` -- only tags starting with this literal prefix (LIKE-escaped)
    - `:limit` -- cap the number of facet rows (distinct tags) returned. Defaults
      to and is capped at #{@max_facet_rows} (never unbounded). `count` is the
      number of distinct articles carrying the tag (robust to duplicate tags in an
      article's array).

  Cost note: this unnests `tags` over the **whole filtered article set** and
  groups — the tags GIN index does not accelerate the unnest/group/sort. On large
  tenants narrow the scan with `:tag_prefix`, `:category`, `:status`, or
  `:project_id` rather than calling it unfiltered.

  ## Returns

  - `%{facets: [%{tag: String.t(), count: non_neg_integer()}],
      distinct_count: non_neg_integer(), truncated: boolean()}` --
    `distinct_count` is the TRUE number of distinct tags (independent of `:limit`);
    `truncated` is true when the row `:limit` returned fewer facet rows than that.
  """
  @spec tag_facets(Ecto.UUID.t(), keyword()) :: %{
          facets: [%{tag: String.t(), count: non_neg_integer()}],
          distinct_count: non_neg_integer(),
          truncated: boolean()
        }
  def tag_facets(tenant_id, opts \\ []) do
    base =
      from(a in Article, where: a.tenant_id == ^tenant_id)
      |> apply_article_filters(opts)

    unnested =
      from(a in subquery(base), select: %{tag: fragment("unnest(?)", a.tags), article_id: a.id})

    # The unnested (article_id, tag) rows after the optional tag-family prefix
    # filter. Both the true distinct count and the per-tag facet derive from this,
    # so the prefix is applied exactly once.
    tag_rows =
      case Keyword.get(opts, :tag_prefix) do
        prefix when is_binary(prefix) and prefix != "" ->
          pattern = like_escape(prefix) <> "%"
          from(t in subquery(unnested), where: like(t.tag, ^pattern))

        _ ->
          from(t in subquery(unnested))
      end

    row_limit = facet_row_limit(Keyword.get(opts, :limit))

    facets =
      from(t in subquery(tag_rows),
        group_by: t.tag,
        select: %{tag: t.tag, count: fragment("count(distinct ?)", t.article_id)},
        order_by: [desc: fragment("count(distinct ?)", t.article_id), asc: t.tag],
        limit: ^row_limit
      )
      |> AdminRepo.all()

    returned = length(facets)

    # The facet rows ARE the complete distinct-tag set unless we hit the row cap —
    # only then is a second (count distinct) pass needed for the true total. This
    # avoids the extra unnest/aggregate scan on the common (un-truncated) path.
    distinct_count =
      if returned < row_limit do
        returned
      else
        from(t in subquery(tag_rows), select: fragment("count(distinct ?)", t.tag))
        |> AdminRepo.one()
        |> Kernel.||(0)
      end

    %{facets: facets, distinct_count: distinct_count, truncated: returned < distinct_count}
  end

  # An explicit positive `:limit` is honored up to @max_facet_rows; an omitted or
  # non-positive limit defaults to @max_facet_rows (never unbounded).
  defp facet_row_limit(n) when is_integer(n) and n > 0, do: min(n, @max_facet_rows)
  defp facet_row_limit(_), do: @max_facet_rows

  # Escapes LIKE metacharacters (\\, %, _) in a literal prefix so a caller-supplied
  # `tag_prefix` is matched literally (no wildcard injection). Postgres LIKE uses
  # backslash as the default escape character.
  defp like_escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # COUNT(*) GROUP BY <field>, returning a dense %{string_value => count} map
  # with every value in `all_values` present (0 when no rows match).
  defp count_by(base, field, all_values) do
    counts =
      base
      |> group_by([a], field(a, ^field))
      |> select([a], {field(a, ^field), count(a.id)})
      |> AdminRepo.all()
      |> Map.new(fn {value, n} -> {to_string(value), n} end)

    zero_base = Map.new(all_values, fn value -> {to_string(value), 0} end)
    Map.merge(zero_base, counts)
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
    api_key_id = Keyword.get(opts, :api_key_id)

    # Run combined search with a wider internal limit to get candidate pool.
    # Suppress sub-search recording so context access is recorded once with
    # access_type="context" rather than duplicating as "search".
    search_opts =
      opts
      |> Keyword.take([
        :project_id,
        :memory_types,
        :agents,
        :conversation_id,
        :visibility_agent_id
      ])
      |> Keyword.merge(
        limit: limit * 3,
        offset: 0,
        status: status,
        _skip_record_access: true
      )

    {search_result, fallback?} = run_context_search(tenant_id, query_string, search_opts)
    vis = Keyword.get(opts, :visibility_agent_id)

    case search_result do
      {:ok, search} ->
        {:ok, context} =
          build_context_results(tenant_id, search, limit, recency_weight, fallback?, vis)

        context_ids = Enum.map(context.results, & &1.id)

        Analytics.record_context_access(
          tenant_id,
          context_ids,
          api_key_id,
          %{"query" => query_string},
          attribution_context(opts)
        )

        {:ok, context}

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

  defp build_context_results(tenant_id, search, limit, recency_weight, fallback?, vis) do
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
      linked_map = batch_linked_refs(tenant_id, article_ids_for_links, vis)

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
  defp batch_linked_refs(_tenant_id, [], _vis), do: %{}

  defp batch_linked_refs(tenant_id, article_ids, vis) do
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
        # Visibility (#163): never surface a linked article the caller can't see.
        |> Enum.filter(&visible_to_caller?(&1, vis))
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
    - `:limit` -- max ranked results to return (default 20, max
      #{@max_relevance_page_size}, min 1). Relevance search returns a ranked
      top-N, not an exhaustive enumeration; clamped here as a safety net while the
      HTTP layer rejects an over-large requested limit with 400 (no silent
      truncation). For complete enumeration use `list_filtered/2` (max
      #{@max_page_size}).
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
        limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(@max_relevance_page_size)
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

        maybe_record_search_access(tenant_id, results, query_string, opts, "keyword")

        {:ok,
         %{
           results: results,
           meta: %{
             total_count: total_count,
             limit: limit,
             offset: offset,
             search_mode: "keyword",
             # Exact number of articles whose search_vector matches the
             # stop-word-filtered tsquery — not a corpus total.
             total_count_scope: "keyword_matches"
           }
         }}
    end
  end

  @doc """
  Lists articles matching `tags`/`category`/`project_id` filters **without** a
  keyword-relevance query, so callers can enumerate the complete set of articles
  carrying a tag or category.

  This is the query-less companion to `search_keyword/3`: it returns the same
  result shape (`%{results: [...], meta: %{total_count, limit, offset}}`) but
  performs no `tsquery` matching, has no relevance score or snippet, and orders
  deterministically by `updated_at` descending then `id` ascending so
  `offset`/`limit` pagination reaches every matching article exactly once.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `opts` -- keyword list with:
    - `:project_id` -- filter by project UUID (optional)
    - `:category` -- filter by category atom (optional)
    - `:tags` -- filter by tag overlap, articles matching ANY tag (optional)
    - `:status` -- filter by status atom (default: `:published`)
    - `:limit` -- max results to return (default 20, max #{@max_page_size}, min 1).
      Limits above the max are clamped here as a safety net; the HTTP layer
      rejects an over-large requested limit with 400 (no silent truncation).
    - `:offset` -- results to skip for pagination (default 0)

  ## Returns

  - `{:ok, %{results: [map()], meta: map()}}`
  """
  @spec list_filtered(Ecto.UUID.t(), keyword()) :: {:ok, %{results: [map()], meta: map()}}
  def list_filtered(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(@max_page_size)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    status = Keyword.get(opts, :status, :published)

    base = from(a in Article, where: a.tenant_id == ^tenant_id)
    filtered = apply_search_filters(base, status, opts)

    # US-27.4: Count and results both route through HeavyRead to inherit the
    # pool-level statement_timeout and optional per-endpoint override.
    count_query = from(a in filtered, select: count(a.id))
    total_count = HeavyRead.one(tenant_id, count_query, heavy_read_opts(:enumeration))

    results_query =
      filtered
      |> select([a], %{
        id: a.id,
        tenant_id: a.tenant_id,
        project_id: a.project_id,
        title: a.title,
        category: a.category,
        status: a.status,
        tags: a.tags,
        inserted_at: a.inserted_at,
        updated_at: a.updated_at
      })
      |> order_by([a], desc: a.updated_at, asc: a.id)
      |> limit(^limit)
      |> offset(^offset)

    results = HeavyRead.all(tenant_id, results_query, heavy_read_opts(:enumeration))

    maybe_record_search_access(tenant_id, results, "", opts, "list")

    {:ok,
     %{
       results: results,
       meta: %{
         total_count: total_count,
         limit: limit,
         offset: offset,
         search_mode: "list",
         # Complete count of the filtered set — safe to paginate over with
         # offset/limit to enumerate every matching article.
         total_count_scope: "filtered_set"
       }
     }}
  end

  @doc """
  KEYSET (cursor) enumeration of the filtered article set (US-27.9a).

  The additive, drift-free companion to `list_filtered/2`. Where `list_filtered/2`
  uses `OFFSET` (which drifts under the concurrent writes this KB sees — a tag
  count was observed swinging 9,881 → 4,981 mid-enumeration), this seeks on the
  stable unique tuple `(inserted_at, id)`:

      WHERE tenant_id = ^tenant_id
        AND (cursor? -> (inserted_at, id) > (^c_inserted, ^c_id))
      ORDER BY inserted_at ASC, id ASC
      LIMIT ^(limit + 1)

  The `id` tie-break is mandatory: `inserted_at` is `utc_datetime_usec` and bulk
  `insert_all` ties timestamps per batch, so `inserted_at` alone is not unique and
  a page boundary could land mid-batch. The `limit + 1` "peek" tells us whether a
  next page exists WITHOUT a `COUNT` — so there is no count to drift either.

  Tenant scope comes from `tenant_id` (the caller's authenticated principal),
  NEVER from the cursor. The cursor encodes only the intra-tenant ordering
  position and is decoded/verified at the HTTP layer
  (`Loopctl.Knowledge.ArticleCursor`).

  ## Parameters

  - `tenant_id` -- the tenant UUID (from the auth principal)
  - `opts` -- keyword list:
    - `:cursor` -- the decoded `{inserted_at, id}` position to seek AFTER, or
      `nil`/absent to start from the beginning
    - `:limit` -- max results per page (default 20, max #{@max_page_size}, min 1);
      clamped here as a safety net, the HTTP layer 400s an over-large request
    - `:status` -- filter by status atom (default `:published`)
    - `:project_id`, `:category`, `:tags`, `:match`, `:memory_types`, `:agents`,
      `:conversation_id`, `:visibility_agent_id` -- same filters as `list_filtered/2`

    - `:include_body` -- when `true`, each result map carries the article `body`
      (US-27.10). Defaults to `false` (body-less summary projection, #166). The
      HTTP layer bounds this to `max_include_body_page/0`; the context honors it
      as passed so direct callers stay in control. When `true`, the returned page
      is ALSO bounded by `full_content_byte_budget/0` (the same serialized-body
      budget the offset full-content path uses) — see Returns.

  ## Returns

  - `{:ok, %{results: [map()], next_cursor: position_or_nil, has_more: bool,
    limit: effective_limit, include_body: bool, byte_truncated: bool}}` where
    `next_cursor` is the `(inserted_at, id)` tuple of the LAST returned row when
    another page exists, else `nil`. `has_more?` is exactly `next_cursor != nil`,
    never a COUNT.

    When `include_body: true`, the page (already ≤ `max_include_body_page/0` rows)
    is trimmed to the longest prefix whose cumulative `byte_size(body)` stays
    within `full_content_byte_budget/0` (always keeping ≥1 row for progress). The
    ≤25-row cap alone permits 25 × `Article` `@max_body_bytes` (500 KB) = 12.5 MB
    worst case; the byte budget keeps the keyset full-content page consistent with
    the offset path (~5.5 MB worst case *returned*). NB: unlike the offset path's
    sized pre-query, this trims IN MEMORY, so it transiently FETCHES up to
    `(max_include_body_page/0 + 1) × @max_body_bytes` (~13 MB) before trimming — a
    bounded cost justified at the 25-row cap (see the body comment). If the trim drops
    rows, `next_cursor` is
    recomputed from the LAST KEPT row (so the walk resumes over the dropped rows —
    drift-free by construction), `has_more` is forced `true`, and `byte_truncated`
    is `true`. When not trimmed (or body-less), `byte_truncated` is `false` and
    behavior is unchanged. The HTTP layer encodes `next_cursor` into an opaque
    cursor string.
  """
  @spec list_keyset(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             results: [map()],
             next_cursor: {DateTime.t(), Ecto.UUID.t()} | nil,
             has_more: boolean(),
             limit: pos_integer(),
             include_body: boolean(),
             byte_truncated: boolean()
           }}
  def list_keyset(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_page_size) |> max(1) |> min(@max_page_size)
    include_body? = Keyword.get(opts, :include_body, false) == true

    # Fetch limit+1 to detect a next page without a COUNT (AC-27.9a.1).
    rows =
      tenant_id
      |> keyset_query(
        opts
        |> Keyword.put(:limit, limit + 1)
        |> Keyword.put(:include_body, include_body?)
      )
      |> then(&HeavyRead.all(tenant_id, &1, heavy_read_opts(:enumeration)))

    {page, has_more?} = split_peek(rows, limit)

    # US-27.10: when bodies are included, bound the (≤25-row) page by the
    # serialized-body byte budget so it can't balloon past the offset path's cap.
    # The page rows already carry `body`, so this is an IN-MEMORY trim — no second
    # query. This deliberately diverges from `paginate_with_body_budget/4` (the offset
    # path), which runs a sized pre-query (`octet_length(body)`) so it never fetches a
    # body it will trim. The divergence is intentional and bounded: the offset path can
    # serve up to `@max_page_size` (1000) rows — a pre-query is essential there (else
    # ~500 MB fetched). The keyset path is HARD-capped at `@max_include_body_page` (25),
    # so the worst-case transient fetch is (25+1) × `@max_body_bytes` ≈ 13 MB per request,
    # naturally backpressured by the dedicated HeavyRead pool (HEAVY_READ_POOL_SIZE, ~8)
    # and its statement_timeout. At that bound the pre-query's saved bytes don't justify a
    # second query + read-only transaction per page, so the simpler in-memory trim wins.
    {page, has_more?, byte_truncated?} = maybe_byte_trim(page, has_more?, include_body?)

    # Surface budget truncation for ops tuning of `:full_content_byte_budget` (it is
    # otherwise only visible in the per-response `meta.byte_truncated`).
    if byte_truncated? do
      :telemetry.execute(
        [:loopctl, :knowledge, :keyset_byte_truncated],
        %{returned: length(page)},
        %{tenant_id: tenant_id}
      )
    end

    next_cursor = keyset_next_cursor(page, has_more?)

    maybe_record_search_access(tenant_id, page, "", opts, "list_keyset")

    {:ok,
     %{
       results: page,
       next_cursor: next_cursor,
       has_more: has_more?,
       limit: limit,
       include_body: include_body?,
       byte_truncated: byte_truncated?
     }}
  end

  # next_cursor is the {inserted_at, id} of the LAST row of the page when more
  # remains (peek OR byte-trim), else nil. Computed AFTER any byte-trim so a
  # trimmed page resumes at the last KEPT row — no gap over the dropped rows.
  defp keyset_next_cursor([], _has_more?), do: nil
  defp keyset_next_cursor(_page, false), do: nil

  defp keyset_next_cursor(page, true) do
    last = List.last(page)
    {last.inserted_at, last.id}
  end

  # Body-less pages have no body bytes to bound — pass through unchanged.
  defp maybe_byte_trim(page, has_more?, false), do: {page, has_more?, false}

  # Full-content page: take the longest prefix within `full_content_byte_budget/0`
  # (always ≥1 row). If rows were dropped, the page now ends earlier than the peek
  # said, so MORE remains regardless of the peek → force has_more? true and let
  # `keyset_next_cursor/2` seek from the last kept row.
  defp maybe_byte_trim(page, has_more?, true) do
    {kept, truncated?} = take_within_byte_budget_by_body(page, full_content_byte_budget())

    {kept, has_more? or truncated?, truncated?}
  end

  # In-memory sibling of `take_within_byte_budget/2` (the offset path's id/:bytes
  # version): keys on `byte_size(row.body || "")` over the already-fetched rows.
  # Always keeps ≥1 row so a single oversized body still makes progress. Returns
  # `{kept_rows_in_order, truncated?}`.
  defp take_within_byte_budget_by_body(rows, budget) do
    {rev_kept, _sum, truncated?} =
      Enum.reduce_while(rows, {[], 0, false}, fn row, {acc, sum, _trunc} ->
        bytes = byte_size(row.body || "")
        new_sum = sum + bytes

        cond do
          acc == [] -> {:cont, {[row], bytes, false}}
          new_sum > budget -> {:halt, {acc, sum, true}}
          true -> {:cont, {[row | acc], new_sum, false}}
        end
      end)

    {Enum.reverse(rev_kept), truncated?}
  end

  @doc """
  Builds the keyset seek QUERYABLE for the article list (US-27.9a), returned (not
  executed) so the `:scale_nightly` plan test can assert it is index-backed
  (`(tenant_id, inserted_at, id)`, no Seq Scan) via `EXPLAIN`.

  Same `opts` as `list_keyset/2`; `:limit` is applied as-is here (the caller adds
  the `+1` peek). This is the EXACT query `list_keyset/2` runs, so the plan
  assertion guards the request path, not a stunt double.

  `:include_body` (default `false`) controls whether the `select` map carries the
  potentially-huge `body` column (US-27.10). Body-less is the default so `body` is
  never transferred from Postgres for enumeration reads; `include_body: true` adds
  it (the HTTP layer bounds that to `max_include_body_page/0`). Tenant scope and
  visibility filtering are applied BEFORE the projection, so a `body` is only ever
  selected for a row the caller could already read.

  Plan note: with no filter or a scalar `:category` filter the planner walks the
  `(tenant_id, inserted_at, id)` btree in order (true keyset, no Sort). With a
  `:tags` (array `&&`) filter it BitmapAnds the tags GIN with the keyset btree and
  Sorts — bounded by tag selectivity, NOT the corpus, since no single index can serve
  both array containment and the order key. This is expected and non-regressive; do
  NOT try to "fix" the Sort away (see `keyset_plan_scale_test.exs` and
  docs/runbooks/knowledge-scale.md).
  """
  @spec keyset_query(Ecto.UUID.t(), keyword()) :: Ecto.Query.t()
  def keyset_query(tenant_id, opts \\ []) do
    # Default mirrors list_keyset/2's page (@default_page_size) + 1 peek row, so the
    # :scale_nightly plan test exercises the same shape the request path runs.
    limit = opts |> Keyword.get(:limit, @default_page_size + 1) |> max(1)
    status = Keyword.get(opts, :status, :published)

    base = from(a in Article, where: a.tenant_id == ^tenant_id)

    base
    |> apply_search_filters(status, opts)
    |> apply_keyset_seek(Keyword.get(opts, :cursor))
    |> keyset_select(Keyword.get(opts, :include_body, false) == true)
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> limit(^limit)
  end

  # Body-less projection (the default, #166): `body` is never transferred from
  # Postgres for enumeration reads, keeping payloads small.
  defp keyset_select(query, false) do
    select(query, [a], %{
      id: a.id,
      tenant_id: a.tenant_id,
      project_id: a.project_id,
      title: a.title,
      category: a.category,
      status: a.status,
      tags: a.tags,
      inserted_at: a.inserted_at,
      updated_at: a.updated_at
    })
  end

  # Full-content projection (US-27.10, `include_body: true`): same summary fields
  # plus the `body` column. Bounded to `max_include_body_page/0` by the HTTP layer.
  defp keyset_select(query, true) do
    select(query, [a], %{
      id: a.id,
      tenant_id: a.tenant_id,
      project_id: a.project_id,
      title: a.title,
      category: a.category,
      status: a.status,
      tags: a.tags,
      body: a.body,
      inserted_at: a.inserted_at,
      updated_at: a.updated_at
    })
  end

  # Row-value comparison `(inserted_at, id) > (^ins, ^id)`: the standard keyset seek
  # that the composite (tenant_id, inserted_at, id) btree serves directly. Shared with
  # the index / change-feed / streaming-export keysets via Loopctl.KeysetSeek (the
  # load-bearing type/2 annotations live there, in ONE place). `nil` cursor →
  # enumerate from the start.
  defp apply_keyset_seek(query, cursor), do: KeysetSeek.after_position(query, cursor)

  # Split limit+1 peek rows into the page (≤ limit) and whether more remain.
  defp split_peek(rows, limit) do
    if length(rows) > limit do
      {Enum.take(rows, limit), true}
    else
      {rows, false}
    end
  end

  defp apply_search_filters(query, status, opts) do
    query
    |> maybe_filter_by_status(status)
    |> maybe_filter_by_project_id(Keyword.get(opts, :project_id))
    |> maybe_filter_by_category(Keyword.get(opts, :category))
    |> maybe_filter_by_tags(Keyword.get(opts, :tags), Keyword.get(opts, :match, :any))
    |> maybe_filter_by_memory_types(Keyword.get(opts, :memory_types))
    |> maybe_filter_by_agents(Keyword.get(opts, :agents))
    |> maybe_filter_by_conversation_id(Keyword.get(opts, :conversation_id))
    |> maybe_filter_by_visibility(Keyword.get(opts, :visibility_agent_id))
  end

  # Agent-memory scoping via JSONB containment (`metadata @> '{"key": val}'`),
  # matching the conventions validated on the Article changeset. Lists are OR'd.
  defp maybe_filter_by_memory_types(query, nil), do: query
  defp maybe_filter_by_memory_types(query, []), do: query

  defp maybe_filter_by_memory_types(query, types) when is_list(types) do
    conditions =
      Enum.reduce(types, dynamic(false), fn type, acc ->
        dynamic([a], ^acc or fragment("? @> ?", a.metadata, ^%{"memory_type" => type}))
      end)

    where(query, ^conditions)
  end

  defp maybe_filter_by_agents(query, nil), do: query
  defp maybe_filter_by_agents(query, []), do: query

  defp maybe_filter_by_agents(query, agents) when is_list(agents) do
    conditions =
      Enum.reduce(agents, dynamic(false), fn agent, acc ->
        dynamic([a], ^acc or fragment("? @> ?", a.metadata, ^%{"agent_id" => agent}))
      end)

    where(query, ^conditions)
  end

  defp maybe_filter_by_conversation_id(query, nil), do: query
  defp maybe_filter_by_conversation_id(query, ""), do: query

  defp maybe_filter_by_conversation_id(query, conv_id) when is_binary(conv_id) do
    where(query, [a], fragment("? @> ?", a.metadata, ^%{"conversation_id" => conv_id}))
  end

  # Fire-and-forget recording of search access for the result list.
  # Skips when there is no api_key_id, no results, or the caller passed
  # `_skip_record_access: true` (used by combined search to dedupe).
  defp maybe_record_search_access(tenant_id, results, query_string, opts, mode) do
    cond do
      Keyword.get(opts, :_skip_record_access, false) ->
        :ok

      results in [nil, []] ->
        :ok

      is_nil(Keyword.get(opts, :api_key_id)) ->
        :ok

      true ->
        api_key_id = Keyword.fetch!(opts, :api_key_id)

        article_ids =
          results
          |> Enum.map(fn r -> r[:id] || Map.get(r, :id) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.take(20)

        Analytics.record_search_access(
          tenant_id,
          article_ids,
          api_key_id,
          query_string,
          %{"mode" => mode},
          attribution_context(opts)
        )
    end
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

  # Drafts are published in batches of this size; a request with more ids than
  # this is auto-chunked server-side rather than rejected.
  @bulk_publish_chunk_size 100

  # Hard ceiling on a single bulk-publish request. High enough that the old
  # 100-cap is gone for real workloads, but bounded so one request can't load an
  # unbounded set of full article rows into memory.
  @bulk_publish_max 5_000

  @doc """
  Publishes draft articles, **partial-success** style.

  Unlike the previous all-or-nothing behaviour, this publishes every valid
  draft and reports a per-id outcome for the rest instead of failing the whole
  call. Each requested id resolves to one of:

  - `"published"` -- it was a draft and is now published
  - `"skipped"` -- already published (idempotent no-op), or archived/superseded
    (`reason` says which); publishing those is not applicable
  - `"not_found"` -- no such article in this tenant
  - `"errored"` -- the publish transaction failed unexpectedly (a failing chunk
    is retried row-by-row, so only the genuinely-bad rows are marked errored)

  Duplicate ids are de-duplicated and malformed (non-UUID) ids resolve to
  `"not_found"`. There is **no 100-id cap**: ids are published server-side in
  chunks of #{@bulk_publish_chunk_size}, each its own transaction, so one bad
  row never rolls back the others. A single request is still bounded to
  #{@bulk_publish_max} ids (beyond that, `{:error, :bad_request, _}`) so it
  can't load an unbounded set of full rows into memory.

  Because this is partial-success, a `2xx`/`{:ok, _}` does NOT imply everything
  published — callers must inspect `counts` (a request of all already-published
  or not-found ids still returns `{:ok, _}` with `published: 0`).

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_ids` -- list of article UUIDs (any length up to #{@bulk_publish_max};
    deduplicated)
  - `opts` -- keyword list with `:actor_id`, `:actor_label`, `:actor_type`

  ## Returns

  - `{:ok, %{published: [%Article{}], results: [map()], counts: map()}}`
  - `{:error, :bad_request, message}` when `article_ids` is empty/nil or exceeds
    #{@bulk_publish_max}

  `counts` has `:requested`, `:published`, `:skipped`, `:not_found`, `:errored`.
  Each entry in `results` is `%{id:, outcome:, ...}` in request order.
  """
  @spec bulk_publish(Ecto.UUID.t(), [Ecto.UUID.t()], keyword()) ::
          {:ok, %{published: [Article.t()], results: [map()], counts: map()}}
          | {:error, :bad_request, String.t()}
  def bulk_publish(_tenant_id, article_ids, _opts) when article_ids in [nil, []] do
    {:error, :bad_request, "article_ids must not be empty"}
  end

  def bulk_publish(tenant_id, article_ids, opts) do
    # Drop non-string junk up front (real callers send JSON string ids); a
    # non-UUID string survives here and resolves to a clean "not_found" rather
    # than crashing the `id in ^ids` query.
    ids = article_ids |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.uniq()

    cond do
      ids == [] ->
        {:error, :bad_request, "article_ids must contain at least one UUID string"}

      length(ids) > @bulk_publish_max ->
        {:error, :bad_request,
         "Maximum #{@bulk_publish_max} article ids per bulk publish; split into smaller calls"}

      true ->
        {:ok, do_bulk_publish(tenant_id, ids, opts)}
    end
  end

  @doc """
  Unpublishes (published → draft) articles, **partial-success** style.

  The mirror of `bulk_publish/3` for cleanup passes: every currently-published id
  is moved back to `:draft` (records the `article.unpublished` audit event) and
  the rest get a per-id outcome instead of failing the whole call:

  - `"unpublished"` -- it was published and is now a draft
  - `"skipped"` -- already a draft (idempotent no-op), or archived/superseded
    (`reason` says which)
  - `"not_found"` -- no such article in this tenant
  - `"errored"` -- the transition failed unexpectedly (chunk retried row-by-row)

  Duplicate ids are de-duplicated, malformed ids resolve to `"not_found"`, ids are
  processed in chunks of #{@bulk_publish_chunk_size} (each its own transaction),
  and a request is bounded to #{@bulk_publish_max} ids. Partial-success: a
  `{:ok, _}` does NOT imply everything unpublished — inspect `counts`.

  ## Returns

  - `{:ok, %{unpublished: [%Article{}], results: [map()], counts: map()}}`
  - `{:error, :bad_request, message}` when `article_ids` is empty/nil or exceeds
    #{@bulk_publish_max}
  """
  @spec bulk_unpublish(Ecto.UUID.t(), [Ecto.UUID.t()], keyword()) ::
          {:ok, %{unpublished: [Article.t()], results: [map()], counts: map()}}
          | {:error, :bad_request, String.t()}
  def bulk_unpublish(_tenant_id, article_ids, _opts) when article_ids in [nil, []] do
    {:error, :bad_request, "article_ids must not be empty"}
  end

  def bulk_unpublish(tenant_id, article_ids, opts) do
    ids = article_ids |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.uniq()

    cond do
      ids == [] ->
        {:error, :bad_request, "article_ids must contain at least one UUID string"}

      length(ids) > @bulk_publish_max ->
        {:error, :bad_request,
         "Maximum #{@bulk_publish_max} article ids per bulk unpublish; split into smaller calls"}

      true ->
        {:ok, do_bulk_unpublish(tenant_id, ids, opts)}
    end
  end

  defp do_bulk_unpublish(tenant_id, article_ids, opts) do
    # Body-less load: bulk-unpublish renders summaries and only flips status, so
    # it never needs the article bodies (bounds memory for a 5000-id batch).
    existing = load_existing_by_ids(tenant_id, article_ids, false)

    published =
      for id <- article_ids,
          match?(%Article{status: :published}, Map.get(existing, id)),
          do: Map.fetch!(existing, id)

    # Unpublishing keeps the embedding (the body is unchanged), so no post-commit
    # re-embedding is needed — unlike bulk_publish.
    {unpublished, errored_ids} =
      transition_in_chunks(
        tenant_id,
        published,
        :draft,
        "article.unpublished",
        opts,
        fn _done -> :ok end
      )

    unpublished_ids = MapSet.new(unpublished, & &1.id)
    errored_set = MapSet.new(errored_ids)

    results =
      Enum.map(article_ids, &bulk_unpublish_result(&1, existing, unpublished_ids, errored_set))

    by_outcome = Enum.frequencies_by(results, & &1.outcome)

    %{
      unpublished: unpublished,
      results: results,
      counts: %{
        requested: length(article_ids),
        unpublished: Map.get(by_outcome, "unpublished", 0),
        skipped: Map.get(by_outcome, "skipped", 0),
        not_found: Map.get(by_outcome, "not_found", 0),
        errored: Map.get(by_outcome, "errored", 0)
      }
    }
  end

  defp bulk_unpublish_result(id, existing, unpublished_ids, errored_set) do
    cond do
      MapSet.member?(errored_set, id) ->
        %{id: id, outcome: "errored", reason: "unpublish_failed"}

      MapSet.member?(unpublished_ids, id) ->
        %{id: id, outcome: "unpublished", status: "draft"}

      true ->
        case Map.get(existing, id) do
          nil ->
            %{id: id, outcome: "not_found"}

          %Article{status: :draft} ->
            %{id: id, outcome: "skipped", reason: "already_draft", status: "draft"}

          %Article{status: status} ->
            %{
              id: id,
              outcome: "skipped",
              reason: "not_unpublishable_from_#{status}",
              status: to_string(status)
            }
        end
    end
  end

  @doc """
  Lists draft articles for a tenant, ordered by inserted_at desc.

  Returns source_type and source_id for review queue visibility.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `opts` -- keyword list with:
    - `:project_id` -- filter by project UUID (optional)
    - `:limit` -- max records to return (default 20, max #{@max_page_size}).
      Limits above the max are clamped here as a safety net; the HTTP layer
      rejects an over-large requested limit with 400 (no silent truncation).
    - `:offset` -- records to skip for pagination (default 0)

  ## Returns

  - `%{data: [%Article{}], meta: map()}` — drafts carry full bodies bounded by the
    serialized-body byte budget, so `meta` includes `total_count`, `limit`,
    `offset`, `include_body`, `returned`, `next_offset`, `has_more`,
    `byte_truncated`, and `byte_budget`.
  """
  @spec list_drafts(Ecto.UUID.t(), keyword()) :: %{data: [Article.t()], meta: map()}
  def list_drafts(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(@max_page_size)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.status == :draft,
        # Total order (id tie-break) for stable offset pagination.
        order_by: [desc: a.inserted_at, asc: a.id]
      )

    base = maybe_filter_by_project_id(base, Keyword.get(opts, :project_id))

    total_count = AdminRepo.aggregate(base, :count, :id)

    # The drafts review queue returns full bodies, so bound the response by the
    # same serialized-body byte budget the article list uses for include_body.
    paginate_with_body_budget(base, total_count, limit, offset)
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
    # Load every requested article once, keyed by id (lag-free, DB-of-record).
    # Body-less: the publish transition + audit only need id/status, and the
    # response is body-less summaries — never materialize up to 5000 bodies (#158).
    existing = load_existing_by_ids(tenant_id, article_ids, false)

    drafts =
      for id <- article_ids,
          match?(%Article{status: :draft}, Map.get(existing, id)),
          do: Map.fetch!(existing, id)

    # Publish drafts in bounded chunks; collect what actually published and any
    # ids whose chunk failed unexpectedly. Embeddings are enqueued AFTER each
    # chunk commits (post-commit), only for rows that actually published — Oban
    # runs on a separate repo/pool from AdminRepo, so enqueuing inside the
    # transaction would leak jobs for rolled-back rows.
    {published, errored_ids} =
      transition_in_chunks(
        tenant_id,
        drafts,
        :published,
        "article.published",
        opts,
        &enqueue_bulk_embeddings(tenant_id, &1)
      )

    published_ids = MapSet.new(published, & &1.id)
    errored_set = MapSet.new(errored_ids)

    results =
      Enum.map(article_ids, &bulk_publish_result(&1, existing, published_ids, errored_set))

    by_outcome = Enum.frequencies_by(results, & &1.outcome)

    %{
      published: published,
      results: results,
      counts: %{
        requested: length(article_ids),
        published: Map.get(by_outcome, "published", 0),
        skipped: Map.get(by_outcome, "skipped", 0),
        not_found: Map.get(by_outcome, "not_found", 0),
        errored: Map.get(by_outcome, "errored", 0)
      }
    }
  end

  defp valid_uuid?(id) when is_binary(id), do: match?({:ok, _}, Ecto.UUID.cast(id))
  defp valid_uuid?(_), do: false

  # Per-id outcome, in request order. Precedence: errored > published > existing-state.
  defp bulk_publish_result(id, existing, published_ids, errored_set) do
    cond do
      MapSet.member?(errored_set, id) ->
        %{id: id, outcome: "errored", reason: "publish_failed"}

      MapSet.member?(published_ids, id) ->
        %{id: id, outcome: "published", status: "published"}

      true ->
        case Map.get(existing, id) do
          nil ->
            %{id: id, outcome: "not_found"}

          %Article{status: :published} ->
            %{id: id, outcome: "skipped", reason: "already_published", status: "published"}

          %Article{status: status} ->
            %{
              id: id,
              outcome: "skipped",
              reason: "not_publishable_from_#{status}",
              status: to_string(status)
            }
        end
    end
  end

  # Shared bulk status-transition runner (used by bulk_publish -> :published and
  # bulk_archive -> :archived). Processes `articles` in bounded chunks; returns
  # `{transitioned, errored_ids}`. `post_commit` runs after each chunk's
  # transaction commits, with the rows that actually transitioned (publish uses
  # it to enqueue embeddings; archive passes a no-op).
  defp transition_in_chunks(tenant_id, articles, target_status, audit_action, opts, post_commit) do
    articles
    |> Enum.chunk_every(@bulk_publish_chunk_size)
    |> Enum.reduce({[], []}, fn chunk, {ok_acc, err_acc} ->
      {done, errored_ids} =
        transition_chunk_isolating_failures(tenant_id, chunk, target_status, audit_action, opts)

      post_commit.(done)
      {ok_acc ++ done, err_acc ++ errored_ids}
    end)
  end

  # Transition a chunk in one transaction; if it fails, retry each row alone so a
  # single bad row doesn't sink the whole chunk (true partial success). The retry
  # is bounded: at most @bulk_publish_max single-row transactions per request
  # (50 chunks x 100), so a pathological all-failing request can't run unbounded.
  #
  # NB: a draft->published / draft|published->archived update has no validation
  # that can fail for a well-formed row, so the `{:error, _}` branch is a
  # defensive fallback for genuine DB-level failures (serialization, connection
  # loss, a constraint regression). It is therefore not exercised by the
  # integration tests without fault injection (which this codebase has no DI seam
  # for) — the partial-success accounting around it (counts/results) is tested.
  defp transition_chunk_isolating_failures(tenant_id, chunk, target_status, audit_action, opts) do
    case execute_bulk_transition(tenant_id, chunk, target_status, audit_action, opts) do
      {:ok, done} ->
        {done, []}

      {:error, _changeset} ->
        {ok, err} =
          Enum.reduce(
            chunk,
            {[], []},
            &transition_one_isolated(tenant_id, &1, target_status, audit_action, opts, &2)
          )

        log_chunk_failures(audit_action, chunk, err)
        {ok, err}
    end
  end

  defp transition_one_isolated(tenant_id, article, target_status, audit_action, opts, {ok, err}) do
    case execute_bulk_transition(tenant_id, [article], target_status, audit_action, opts) do
      {:ok, done} -> {ok ++ done, err}
      {:error, _cs} -> {ok, err ++ [article.id]}
    end
  end

  # One aggregated log line per failing chunk (not one per row) so a systemic
  # failure of a large request can't flood the logs with thousands of lines.
  defp log_chunk_failures(_audit_action, _chunk, []), do: :ok

  defp log_chunk_failures(audit_action, chunk, errored_ids) do
    Logger.error(
      "#{audit_action}: #{length(errored_ids)}/#{length(chunk)} rows failed: " <>
        Enum.join(errored_ids, ", ")
    )
  end

  defp execute_bulk_transition(tenant_id, articles, target_status, audit_action, opts) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    actor_type = Keyword.get(opts, :actor_type, "api_key")

    # Use {action, index} tuples as Multi keys to avoid atom exhaustion.
    # String.to_atom with dynamic UUIDs would leak atoms (never GC'd).
    indexed_articles = Enum.with_index(articles)

    multi =
      indexed_articles
      |> Enum.reduce(Multi.new(), fn {article, idx}, multi ->
        changeset = Article.update_changeset(article, %{status: target_status})
        Multi.update(multi, {:item, idx}, changeset)
      end)
      |> add_bulk_audit_entries(
        tenant_id,
        indexed_articles,
        audit_action,
        actor_id,
        actor_label,
        actor_type
      )

    case AdminRepo.transaction(multi) do
      {:ok, results} ->
        done =
          indexed_articles
          |> Enum.map(fn {_article, idx} -> Map.get(results, {:item, idx}) end)
          |> Enum.reject(&is_nil/1)

        {:ok, done}

      {:error, _key, changeset, _completed} ->
        {:error, changeset}
    end
  end

  # Enqueue embedding jobs for the just-published rows, AFTER the publish
  # transaction has committed. Best-effort and crash-proof: the publish is
  # already durable, so a transient enqueue failure must never 500 the request or
  # abort the remaining chunks — we log and move on (the embedding is
  # re-derivable). Per-row `Oban.insert/1` (NOT `insert_all`) so the worker's
  # `unique: [keys: [:article_id], period: 300]` window is honored — the basic
  # Oban engine ignores `unique:` for `insert_all`. Bounded to <= 100 inserts per
  # chunk.
  defp enqueue_bulk_embeddings(_tenant_id, []), do: :ok

  defp enqueue_bulk_embeddings(tenant_id, published) do
    Enum.each(published, fn article ->
      %{article_id: article.id, tenant_id: tenant_id}
      |> ArticleEmbeddingWorker.new()
      |> Oban.insert()
    end)
  rescue
    e ->
      Logger.error("bulk_publish: embedding enqueue failed: #{Exception.message(e)}")
      :ok
  end

  defp add_bulk_audit_entries(
         multi,
         tenant_id,
         indexed_articles,
         audit_action,
         actor_id,
         actor_label,
         actor_type
       ) do
    Enum.reduce(indexed_articles, multi, fn {article, idx}, multi ->
      old_status = to_string(article.status)

      Audit.log_in_multi(multi, {:audit, idx}, fn changes ->
        updated = Map.get(changes, {:item, idx})

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
    end)
  end

  @doc """
  Archives articles in bulk (soft delete), **partial-success** style — the
  delete analogue of `bulk_publish/3`.

  Each requested id resolves to one of:

  - `"archived"` -- it was draft/published and is now archived
  - `"skipped"` -- already archived (idempotent no-op), or superseded
    (`reason` says which)
  - `"not_found"` -- no such article in this tenant
  - `"errored"` -- the archive transaction failed unexpectedly

  Duplicate ids are de-duplicated; malformed ids resolve to `"not_found"`.
  Bounded to #{@bulk_publish_max} ids per call (auto-chunked). Returns
  `{:ok, %{archived: [...], results: [...], counts: %{...}}}` or
  `{:error, :bad_request, msg}` when `article_ids` is empty/over the cap.
  """
  @spec bulk_archive(Ecto.UUID.t(), [Ecto.UUID.t()], keyword()) ::
          {:ok, %{archived: [Article.t()], results: [map()], counts: map()}}
          | {:error, :bad_request, String.t()}
  def bulk_archive(_tenant_id, article_ids, _opts) when article_ids in [nil, []] do
    {:error, :bad_request, "article_ids must not be empty"}
  end

  def bulk_archive(tenant_id, article_ids, opts) do
    ids = article_ids |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.uniq()

    cond do
      ids == [] ->
        {:error, :bad_request, "article_ids must contain at least one UUID string"}

      length(ids) > @bulk_publish_max ->
        {:error, :bad_request,
         "Maximum #{@bulk_publish_max} article ids per bulk delete; split into smaller calls"}

      true ->
        {:ok, do_bulk_archive(tenant_id, ids, opts)}
    end
  end

  defp do_bulk_archive(tenant_id, article_ids, opts) do
    # Body-less load: the archive transition + audit need only id/status, and the
    # response is body-less summaries — never materialize up to 5000 bodies (#158).
    existing = load_existing_by_ids(tenant_id, article_ids, false)

    archivable =
      for id <- article_ids,
          match?(%Article{status: s} when s in [:draft, :published], Map.get(existing, id)),
          do: Map.fetch!(existing, id)

    # Archiving has no post-commit side effect (archived rows are hidden from
    # search, so no embedding work is needed).
    {archived, errored_ids} =
      transition_in_chunks(tenant_id, archivable, :archived, "article.archived", opts, fn _ ->
        :ok
      end)

    archived_ids = MapSet.new(archived, & &1.id)
    errored_set = MapSet.new(errored_ids)

    results = Enum.map(article_ids, &bulk_archive_result(&1, existing, archived_ids, errored_set))
    by_outcome = Enum.frequencies_by(results, & &1.outcome)

    %{
      archived: archived,
      results: results,
      counts: %{
        requested: length(article_ids),
        archived: Map.get(by_outcome, "archived", 0),
        skipped: Map.get(by_outcome, "skipped", 0),
        not_found: Map.get(by_outcome, "not_found", 0),
        errored: Map.get(by_outcome, "errored", 0)
      }
    }
  end

  defp bulk_archive_result(id, existing, archived_ids, errored_set) do
    cond do
      MapSet.member?(errored_set, id) ->
        %{id: id, outcome: "errored", reason: "archive_failed"}

      MapSet.member?(archived_ids, id) ->
        %{id: id, outcome: "archived", status: "archived"}

      true ->
        case Map.get(existing, id) do
          nil ->
            %{id: id, outcome: "not_found"}

          %Article{status: :archived} ->
            %{id: id, outcome: "skipped", reason: "already_archived", status: "archived"}

          %Article{status: status} ->
            %{
              id: id,
              outcome: "skipped",
              reason: "not_archivable_from_#{status}",
              status: to_string(status)
            }
        end
    end
  end

  # Load the requested articles once, keyed by id. Malformed (non-UUID) ids are
  # kept out of the `id in ^ids` query (which would raise on cast) so they
  # resolve to a clean "not_found" via the absent map entry.
  # `include_body: false` projects every field except the (potentially large)
  # `body`, so a bulk op that never echoes the body (all of bulk publish/unpublish/
  # archive render body-less summaries) doesn't pull up to 5000 full bodies into
  # memory just to flip a status. The status transition and audit only need
  # id/status. Callers pass `include_body` explicitly (no default — every current
  # caller is body-less; pass `true` if a future caller needs full bodies).
  defp load_existing_by_ids(tenant_id, article_ids, include_body) do
    queryable_ids = Enum.filter(article_ids, &valid_uuid?/1)

    base =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.id in ^queryable_ids
      )

    query = if include_body, do: base, else: from(a in base, select: struct(a, ^@summary_fields))

    query
    |> AdminRepo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  Returns the ids of active (draft/published) articles matching `opts` (the same
  filters as `list_articles/2` — `:source_type`/`:source_id`/`:tags`/`:category`/
  `:project_id`) for a selector-based bulk archive. The bulk-delete endpoint
  currently drives it with the source and tag filters. Bounded: returns
  `{:error, :too_many}` when the match set exceeds #{@bulk_publish_max} (the
  caller should narrow the selector).
  """
  @spec list_archivable_ids(Ecto.UUID.t(), keyword()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, :too_many}
  def list_archivable_ids(tenant_id, opts) do
    ids =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.status in [:draft, :published],
        select: a.id,
        limit: ^(@bulk_publish_max + 1)
      )
      |> apply_article_filters(opts)
      |> AdminRepo.all()

    if length(ids) > @bulk_publish_max, do: {:error, :too_many}, else: {:ok, ids}
  end

  # --- Obsidian / OKF Export ---
  #
  # The materializing export (`:zip.create(_, [:memory])` over the full published
  # set) has been REPLACED by the bounded-memory streaming export (US-27.16). See
  # `Loopctl.Knowledge.StreamingExport` and its `ObsidianFormat` / `OKFFormat`
  # implementations, driven from the controllers via `LoopctlWeb.StreamingExport`.
  # `slugify/1` (below) remains the shared title→path slug helper used by both the
  # streaming formats and the OKF importer.

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
    vis = Keyword.get(opts, :visibility_agent_id)

    with :ok <- validate_articles_exist(tenant_id, source_id, target_id),
         # Visibility (#163): an agent may not link to (and thereby probe/leak) an
         # article it can't see — both endpoints must be visible to the caller.
         :ok <- validate_link_visibility(tenant_id, source_id, target_id, vis) do
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
  def list_links_for_article(tenant_id, article_id, opts \\ []) do
    vis = Keyword.get(opts, :visibility_agent_id)

    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.source_article_id == ^article_id or l.target_article_id == ^article_id,
      preload: [:source_article, :target_article],
      order_by: [desc: l.inserted_at],
      limit: 100
    )
    |> AdminRepo.all()
    # Visibility (#163): drop links whose far-side article the caller can't see, so
    # the link list can't leak another agent's private memory id/title.
    |> filter_links_by_visibility(vis)
  end

  defp filter_links_by_visibility(links, nil), do: links

  defp filter_links_by_visibility(links, vis) when is_binary(vis) do
    Enum.filter(links, fn link ->
      link_side_visible?(link.source_article, vis) and
        link_side_visible?(link.target_article, vis)
    end)
  end

  @default_suggestion_limit 5

  @doc "Default number of link suggestions when `:limit` is omitted."
  @spec default_suggestion_limit() :: pos_integer()
  def default_suggestion_limit, do: @default_suggestion_limit

  @doc """
  Suggests **typed link candidates** for an article by embedding similarity —
  **read-only**, creates nothing.

  Returns published articles most similar to `article_id` (cosine over the
  embedding) that are not already linked to it, so a caller can review them and
  POST a *typed* link (`relates_to`/`derived_from`/`contradicts`/`supersedes`) —
  unlike the auto-linker, which only ever creates ambient `relates_to`.

  Excludes the article itself and **any already-linked article** (either
  direction, any relationship type). Only embedded, `published` articles are
  considered. Honors `:threshold` (cosine similarity floor, default from
  `:suggestion_similarity_threshold` config or 0.5) and `:limit` (default
  #{@default_suggestion_limit}), ordered most-similar first. Tenant-scoped.

  Ranking is approximate nearest-neighbor over the HNSW embedding index, like the
  semantic-search path. Mechanically: the query pulls the nearest *candidate pool*
  (≈ `limit × 5`, min 100) via the index, then excludes the article's already-linked
  neighbors and any below-`threshold` and returns the top `:limit`. The
  already-linked exclusion is applied to that pool — NOT the whole corpus — because
  pushing the exclusion (or the distance floor) into the index scan defeats the HNSW
  index and forces a full-corpus Seq Scan (the #170/#172 prod 500; EXPLAIN-verified).
  Consequence: for a densely-linked "hub" whose nearest neighbors are almost all
  already linked, the result may contain fewer than `:limit` suggestions (or be
  empty) even though more-distant unlinked candidates exist — by design, the price of
  the indexed path. Recall is additionally bounded by `hnsw.ef_search`, as in
  semantic search.

  ## Returns

  - `{:ok, [%{id, title, category, similarity_score}]}` (highest similarity first)
  - `{:ok, []}` when the article has no embedding yet
  - `{:error, :not_found}` when the article doesn't exist / isn't published
  - `{:error, :invalid_threshold}` when `:threshold` is outside 0.0–1.0
  """
  @impl Loopctl.Knowledge.SuggestLinksBehaviour
  @spec suggest_links(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, [map()]} | {:error, :not_found} | {:error, :invalid_threshold}
  def suggest_links(tenant_id, article_id, opts \\ []) do
    threshold = Keyword.get(opts, :threshold) || default_suggestion_threshold()
    vis = Keyword.get(opts, :visibility_agent_id)

    limit =
      opts
      |> Keyword.get(:limit, @default_suggestion_limit)
      |> max(1)
      |> min(@max_relevance_page_size)

    with :ok <- validate_threshold(threshold) do
      case fetch_article_embedding(tenant_id, article_id, vis) do
        nil ->
          {:error, :not_found}

        %{embedding: nil} ->
          {:ok, []}

        %{embedding: embedding} ->
          {:ok, suggestion_candidates(tenant_id, article_id, embedding, threshold, limit, vis)}
      end
    end
  end

  defp default_suggestion_threshold,
    do: Application.get_env(:loopctl, :suggestion_similarity_threshold, 0.5)

  defp validate_threshold(t) when is_number(t) and t >= 0.0 and t <= 1.0, do: :ok
  defp validate_threshold(_), do: {:error, :invalid_threshold}

  # Lightweight fetch — only the embedding (skips body/metadata). A non-UUID or a
  # missing/non-published article yields nil → {:error, :not_found}.
  defp fetch_article_embedding(tenant_id, article_id, vis) do
    if valid_uuid?(article_id) do
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.id == ^article_id and a.status == :published,
        select: %{embedding: a.embedding}
      )
      |> maybe_filter_by_visibility(vis)
      |> AdminRepo.one()
    end
  end

  defp suggestion_candidates(tenant_id, article_id, embedding, threshold, limit, vis) do
    # Routed through Loopctl.HeavyRead (US-27.11): the dedicated heavy-read pool,
    # isolated from the small AdminRepo pool and carrying a pool-level
    # statement_timeout — no per-request transaction (the constraint that shaped the
    # #172 fix). The wrapper structurally requires a tenant_id-filtered query; the
    # tenant predicate lives in this query's inner subquery. The 15s client timeout
    # is a backstop above the server-side statement_timeout.
    query = suggestion_candidates_query(tenant_id, article_id, embedding, threshold, limit, vis)
    HeavyRead.all(tenant_id, query, heavy_read_opts(:suggested_links))
  end

  @doc false
  # Per-read options for a heavy endpoint (US-27.4): the 15s CLIENT timeout backstop
  # plus an optional per-endpoint SERVER-SIDE statement_timeout override (config
  # `:heavy_read_statement_timeout_overrides`, e.g. `%{suggested_links: 5_000}`). When
  # no override is configured the read uses the pool-level statement_timeout (the
  # default path, no per-request transaction). Also passes the endpoint key via
  # telemetry_options so slow-query logs can trace which endpoint triggered the query.
  # Public-but-`@doc false` so the slow-query telemetry test can exercise the real
  # opts-building path (incl. the override branch).
  def heavy_read_opts(endpoint) do
    base = [timeout: 15_000, telemetry_options: [endpoint: endpoint]]

    case heavy_read_statement_timeout(endpoint) do
      ms when is_integer(ms) and ms > 0 -> Keyword.put(base, :statement_timeout, ms)
      _ -> base
    end
  end

  defp heavy_read_statement_timeout(endpoint) do
    :loopctl
    |> Application.get_env(:heavy_read_statement_timeout_overrides, %{})
    |> Map.get(endpoint)
  end

  # Builds the suggested-links candidate query (returned, not executed) so a test can
  # assert its SQL shape. Public-but-`@doc false` for that structural regression guard.
  #
  # SHAPE IS LOAD-BEARING (verified with EXPLAIN against the ~76k-row prod corpus):
  # pgvector's HNSW index (cosine) only accelerates a PURE `ORDER BY embedding <=> $const
  # LIMIT k`. Adding the already-linked anti-join (a JOIN) OR a distance filter
  # (`... <=> ... > threshold`) to that same query makes the planner abandon the index and
  # Seq-Scan the entire corpus + Sort — the #172 / #170 production 500 (cost ~57k vs ~880).
  #
  # So this is split in two:
  #   * INNER subquery — the pure top-`pool` nearest by cosine. Only index-safe filters
  #     here (tenant, status, not-null, not-self, visibility — all verified to keep the
  #     index). The target is a BOUND `^param` LIST of floats (`to_embedding_list/1`),
  #     never the stored `%Pgvector{}` struct (that re-interpolation was the #168 500).
  #   * OUTER query — applies the already-linked anti-join + the `similarity_score >
  #     threshold` floor + the final `limit`, over just `pool` rows (cheap).
  #
  # `pool` over-fetches well beyond `limit` so the outer exclusions rarely starve the
  # result; effective recall is additionally bounded by `hnsw.ef_search` (default 40),
  # consistent with the `search_semantic` path. The caller has already confirmed the
  # target exists / is published / is embedded / is visible.
  @doc false
  def suggestion_candidates_query(tenant_id, article_id, embedding, threshold, limit, vis) do
    target = to_embedding_list(embedding)
    pool = suggestion_candidate_pool(limit)

    candidates =
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.status == :published,
        where: not is_nil(a.embedding),
        where: a.id != ^article_id,
        order_by: [asc: fragment("? <=> ?", a.embedding, ^target)],
        limit: ^pool,
        select: %{
          id: a.id,
          title: a.title,
          category: a.category,
          similarity_score: fragment("GREATEST(0, 1 - (? <=> ?))", a.embedding, ^target)
        }
      )
      |> maybe_filter_by_visibility(vis)

    from(c in subquery(candidates),
      # Exclude any article already linked to the target (either direction, any type).
      left_join: l in ArticleLink,
      on:
        l.tenant_id == ^tenant_id and
          ((l.source_article_id == ^article_id and l.target_article_id == c.id) or
             (l.target_article_id == ^article_id and l.source_article_id == c.id)),
      where: is_nil(l.id),
      where: c.similarity_score > ^threshold,
      order_by: [desc: c.similarity_score],
      limit: ^limit,
      select: %{
        id: c.id,
        title: c.title,
        category: c.category,
        similarity_score: c.similarity_score
      }
    )
  end

  # Over-fetch factor for the inner ANN subquery: pull this many nearest candidates from
  # the HNSW index before the outer query applies the anti-join + threshold and trims to
  # `limit`. Scales with `limit` (headroom for exclusions), floored for the common small
  # `limit`, and capped so the index scan stays cheap.
  defp suggestion_candidate_pool(limit) do
    max(limit * 5, 100)
    |> min(Application.get_env(:loopctl, :max_suggestion_candidate_pool, 500))
    # Never let a misconfigured cap drop the pool below `limit` — that would truncate the
    # candidate set before the outer exclusions even run.
    |> max(limit)
  end

  # The HNSW-indexable cosine form binds the target as a plain `[float()]` list (the
  # same value shape `search_semantic` binds), NEVER the stored `%Pgvector{}` struct —
  # re-interpolating that struct was the #168 production 500.
  defp to_embedding_list(%Pgvector{} = vector), do: Pgvector.to_list(vector)
  defp to_embedding_list(vector) when is_list(vector), do: vector

  @doc """
  Multi-hop traversal of the published article-link graph from a starting article.

  Walks `article_links` outward from `article_id` up to `depth` hops
  (**bidirectional** — a link is followed regardless of source/target direction),
  returning the reachable published articles and the links among them. Cycle-safe:
  a recursive-CTE path array prevents revisiting a node, so a cyclic graph
  terminates and no node appears twice. Bounded to #{@max_graph_nodes} nodes and
  #{@max_graph_edges} edges; `truncated` is true when either cap is hit.

  Only `published` articles are traversed (the agent-visible set), and everything
  is tenant-scoped.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the starting article UUID
  - `opts` -- `:depth` (1–3, default 1)

  ## Returns

  - `{:ok, %{nodes: [%{id, title, category, depth}], edges: [%{source_article_id,
    target_article_id, relationship_type}], truncated: boolean, node_count: integer}}`
  - `{:error, :invalid_depth}` when depth is outside 1–3
  - `{:error, :not_found}` when the starting article doesn't exist / isn't published
  """
  @spec graph_traversal(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, :invalid_depth} | {:error, :not_found}
  def graph_traversal(tenant_id, article_id, opts \\ []) do
    depth = Keyword.get(opts, :depth, 1)
    vis = Keyword.get(opts, :visibility_agent_id)

    with :ok <- validate_graph_depth(depth),
         true <- article_published?(tenant_id, article_id, vis) do
      {:ok, execute_graph_traversal(tenant_id, article_id, depth, vis)}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp validate_graph_depth(depth) when is_integer(depth) and depth >= 1 and depth <= 3, do: :ok
  defp validate_graph_depth(_), do: {:error, :invalid_depth}

  @doc """
  Maximum number of reachable nodes in a graph traversal result.
  Configurable via `:max_graph_nodes` in application config; defaults to #{@max_graph_nodes}.
  """
  @spec max_graph_nodes() :: pos_integer()
  def max_graph_nodes, do: Application.get_env(:loopctl, :max_graph_nodes, @max_graph_nodes)

  @doc """
  Maximum number of edges in a graph traversal result.
  Configurable via `:max_graph_edges` in application config; defaults to #{@max_graph_edges}.
  """
  @spec max_graph_edges() :: pos_integer()
  def max_graph_edges, do: Application.get_env(:loopctl, :max_graph_edges, @max_graph_edges)

  @doc """
  Maximum number of links followed per node in recursive graph traversal.
  Bounds fan-out to prevent unbounded explosion on high-degree hubs.
  Configurable via `:max_graph_neighbors_per_node` in application config; defaults to #{@max_graph_neighbors_per_node}.
  """
  @spec max_graph_neighbors_per_node() :: pos_integer()
  def max_graph_neighbors_per_node,
    do:
      Application.get_env(:loopctl, :max_graph_neighbors_per_node, @max_graph_neighbors_per_node)

  defp article_published?(tenant_id, article_id, vis) do
    valid_uuid?(article_id) and
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.id == ^article_id and a.status == :published
      )
      |> maybe_filter_by_visibility(vis)
      |> AdminRepo.exists?()
  end

  defp execute_graph_traversal(tenant_id, article_id, depth, vis) do
    {:ok, tenant_bin} = Ecto.UUID.dump(tenant_id)
    {:ok, article_bin} = Ecto.UUID.dump(article_id)

    # Visibility (#163): for agent callers, traversal only includes nodes the caller
    # may see (shared/own). $6 binds the caller identity; the clause is a fixed literal
    # (no user input concatenated), so it's injection-safe. Higher roles pass nil → no clause.
    {vis_clause, params} =
      if is_binary(vis) do
        {" AND (COALESCE(a.metadata->>'visibility', 'shared') NOT IN ('private','owner') OR a.metadata->>'agent_id' = $6)",
         [article_bin, tenant_bin, depth, max_graph_nodes(), max_graph_neighbors_per_node(), vis]}
      else
        {"", [article_bin, tenant_bin, depth, max_graph_nodes(), max_graph_neighbors_per_node()]}
      end

    # Bidirectional recursive walk with a path-array cycle guard and per-node neighbor cap
    # to bound fan-out, capped at @max_graph_nodes. Raw SQL because Ecto has no native
    # recursive-CTE builder. LATERAL limits neighbors per node to prevent unbounded explosion.
    node_sql = """
    WITH RECURSIVE graph AS (
      SELECT a.id AS node_id, ARRAY[a.id] AS path, 0 AS depth
      FROM articles a
      WHERE a.id = $1 AND a.tenant_id = $2 AND a.status = 'published'#{vis_clause}

      UNION ALL

      SELECT
        CASE WHEN l.source_article_id = g.node_id THEN l.target_article_id
             ELSE l.source_article_id END AS node_id,
        g.path || CASE WHEN l.source_article_id = g.node_id THEN l.target_article_id
                       ELSE l.source_article_id END,
        g.depth + 1
      FROM graph g
      JOIN LATERAL (
        SELECT source_article_id, target_article_id, relationship_type
        FROM article_links
        WHERE tenant_id = $2
          AND (source_article_id = g.node_id OR target_article_id = g.node_id)
        LIMIT $5
      ) l ON true
      JOIN articles a ON a.id = CASE WHEN l.source_article_id = g.node_id
                                     THEN l.target_article_id ELSE l.source_article_id END
        AND a.tenant_id = $2 AND a.status = 'published'#{vis_clause}
      WHERE g.depth < $3
        AND NOT (CASE WHEN l.source_article_id = g.node_id
                      THEN l.target_article_id ELSE l.source_article_id END = ANY(g.path))
    )
    SELECT node_id, depth FROM (
      SELECT DISTINCT ON (node_id) node_id, depth FROM graph ORDER BY node_id, depth ASC
    ) sub
    ORDER BY depth ASC, node_id
    LIMIT $4
    """

    case SQL.query(
           AdminRepo,
           node_sql,
           params,
           timeout: 5_000
         ) do
      {:ok, %{rows: node_rows}} ->
        nodes_truncated = length(node_rows) >= max_graph_nodes()

        node_ids_with_depth =
          Enum.map(node_rows, fn [node_bin, d] ->
            {:ok, uuid} = Ecto.UUID.load(node_bin)
            {uuid, d}
          end)

        node_ids = Enum.map(node_ids_with_depth, &elem(&1, 0))
        depth_map = Map.new(node_ids_with_depth)

        nodes = fetch_graph_nodes(tenant_id, node_ids, depth_map)
        fetched_node_ids = Enum.map(nodes, & &1.id)
        edges = fetch_graph_edges(tenant_id, fetched_node_ids)

        %{
          nodes: nodes,
          edges: edges,
          truncated: nodes_truncated or length(edges) >= max_graph_edges(),
          node_count: length(nodes)
        }

      {:error, reason} ->
        # Database error (timeout, connection, etc.) — return a degraded but valid
        # response (truncated: true) instead of crashing the request, and log so a
        # repeated dense-hub traversal is visible to operators rather than an
        # anonymous 500.
        Logger.warning(
          "knowledge graph traversal failed (depth=#{depth}, tenant=#{tenant_id}): " <>
            "#{inspect(reason)} — returning degraded (truncated) result"
        )

        %{nodes: [], edges: [], truncated: true, node_count: 0}
    end
  end

  defp fetch_graph_nodes(_tenant_id, [], _depth_map), do: []

  defp fetch_graph_nodes(tenant_id, node_ids, depth_map) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id and a.id in ^node_ids and a.status == :published,
      select: %{id: a.id, title: a.title, category: a.category}
    )
    |> AdminRepo.all()
    |> Enum.map(&Map.put(&1, :depth, Map.get(depth_map, &1.id)))
    |> Enum.sort_by(& &1.depth)
  end

  defp fetch_graph_edges(_tenant_id, []), do: []

  defp fetch_graph_edges(tenant_id, node_ids) do
    from(l in ArticleLink,
      where:
        l.tenant_id == ^tenant_id and
          l.source_article_id in ^node_ids and l.target_article_id in ^node_ids,
      order_by: [asc: l.inserted_at, asc: l.id],
      limit: ^max_graph_edges(),
      select: %{
        source_article_id: l.source_article_id,
        target_article_id: l.target_article_id,
        relationship_type: l.relationship_type
      }
    )
    |> AdminRepo.all()
  end

  # --- Creativity primitives (#152) ---

  @doc """
  Finds **distant-but-bridgeable** article pairs in the optimal-novelty embedding
  band (cosine distance ∈ [min, max], default 0.3–0.7) — the creative sweet spot
  (neither banal nor nonsense).

  Samples at most #{@max_pair_candidates} embedded published articles (bounding the
  O(n²) self-join), returns distinct unordered pairs ordered deterministically for
  pagination. With `bridge_path: true` only pairs that are also connected in the
  link graph (directly, or via a shared neighbor — ≤2 hops) are returned.

  ## Parameters

  - `opts` -- `:min_distance` (default 0.3), `:max_distance` (default 0.7),
    `:bridge_path` (default false), `:limit` (default #{@default_pair_limit},
    max #{@max_pair_limit}), `:offset`.

  ## Returns

  - `{:ok, %{pairs: [...], total_count: integer, has_more: boolean}}`
  - `{:error, :invalid_distance}` when the band is outside 0.0–2.0 or min > max
  """
  @spec distant_pairs(Ecto.UUID.t(), keyword()) ::
          {:ok, %{pairs: [map()], total_count: integer(), has_more: boolean()}}
          | {:error, :invalid_distance}
  def distant_pairs(tenant_id, opts \\ []) do
    min_d = Keyword.get(opts, :min_distance, 0.3)
    max_d = Keyword.get(opts, :max_distance, 0.7)
    limit = opts |> Keyword.get(:limit, @default_pair_limit) |> max(1) |> min(@max_pair_limit)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    bridge? = Keyword.get(opts, :bridge_path, false) == true
    vis = Keyword.get(opts, :visibility_agent_id)

    with :ok <- validate_distance_band(min_d, max_d) do
      {:ok, do_distant_pairs(tenant_id, min_d, max_d, limit, offset, bridge?, vis)}
    end
  end

  defp validate_distance_band(min_d, max_d)
       when is_number(min_d) and is_number(max_d) and min_d >= 0.0 and max_d <= 2.0 and
              min_d <= max_d,
       do: :ok

  defp validate_distance_band(_, _), do: {:error, :invalid_distance}

  # Operator-tunable cap on the sampled candidate set (bounds the O(n²) self-join).
  defp max_pair_candidates do
    Application.get_env(:loopctl, :max_pair_candidates, @max_pair_candidates)
  end

  defp do_distant_pairs(tenant_id, min_d, max_d, limit, offset, bridge?, vis) do
    candidates =
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.status == :published and not is_nil(a.embedding),
        order_by: a.id,
        limit: ^max_pair_candidates(),
        select: %{
          id: a.id,
          tenant_id: a.tenant_id,
          title: a.title,
          category: a.category,
          embedding: a.embedding
        }
      )
      |> maybe_filter_by_visibility(vis)

    # Build the base query for counting total pairs
    count_query =
      from(a in subquery(candidates),
        join: b in subquery(candidates),
        on: a.id < b.id,
        where: fragment("(? <=> ?) BETWEEN ? AND ?", a.embedding, b.embedding, ^min_d, ^max_d),
        select: count()
      )

    # Build the paginated query for fetching pairs
    pairs_query =
      from(a in subquery(candidates),
        join: b in subquery(candidates),
        on: a.id < b.id,
        where: fragment("(? <=> ?) BETWEEN ? AND ?", a.embedding, b.embedding, ^min_d, ^max_d),
        order_by: [asc: a.id, asc: b.id],
        limit: ^(limit + 1),
        offset: ^offset,
        select: %{
          a: %{id: a.id, title: a.title, category: a.category},
          b: %{id: b.id, title: b.title, category: b.category},
          distance: fragment("(? <=> ?)", a.embedding, b.embedding)
        }
      )

    # Fetch count and paginated pairs through Loopctl.HeavyRead (US-27.11): the
    # dedicated heavy-read pool with a pool-level statement_timeout, isolated from the
    # small AdminRepo pool so this O(n²) self-join can't starve light admin ops. No
    # transaction hold (count may shift between queries — acceptable, by design). Both
    # queries filter `a.tenant_id`/`b.tenant_id`, satisfying the wrapper's guard.
    total_count =
      count_query
      |> maybe_filter_bridge_path(bridge?, vis)
      |> then(&HeavyRead.one(tenant_id, &1, heavy_read_opts(:distant_pairs)))

    pairs_with_lookahead =
      pairs_query
      |> maybe_filter_bridge_path(bridge?, vis)
      |> then(&HeavyRead.all(tenant_id, &1, heavy_read_opts(:distant_pairs)))

    # Detect has_more by fetching limit+1; only return limit
    has_more = length(pairs_with_lookahead) > limit
    pairs = Enum.take(pairs_with_lookahead, limit)

    %{pairs: pairs, total_count: total_count, has_more: has_more}
  end

  # Bridge filter: keep only pairs connected within ≤2 hops in the link graph —
  # directly linked, or sharing a common neighbor (the #149 "bridgeable" notion).
  # The shared neighbor must be a distinct *published* article, consistent with
  # random_walk's published-only neighbors — a pair doesn't bridge through an
  # archived/draft middle. All node/link references are tenant-scoped.
  defp maybe_filter_bridge_path(query, false, _vis), do: query

  # Higher roles (vis nil): bridge through any published middle node.
  defp maybe_filter_bridge_path(query, true, nil) do
    where(
      query,
      [a, b],
      fragment(
        "EXISTS (SELECT 1 FROM article_links l WHERE l.tenant_id = ? AND ((l.source_article_id = ? AND l.target_article_id = ?) OR (l.source_article_id = ? AND l.target_article_id = ?)))",
        a.tenant_id,
        a.id,
        b.id,
        b.id,
        a.id
      ) or
        fragment(
          "EXISTS (SELECT 1 FROM articles m JOIN article_links la ON la.tenant_id = ? AND ((la.source_article_id = ? AND la.target_article_id = m.id) OR (la.target_article_id = ? AND la.source_article_id = m.id)) JOIN article_links lb ON lb.tenant_id = ? AND ((lb.source_article_id = ? AND lb.target_article_id = m.id) OR (lb.target_article_id = ? AND lb.source_article_id = m.id)) WHERE m.tenant_id = ? AND m.status = 'published' AND m.id <> ? AND m.id <> ?)",
          a.tenant_id,
          a.id,
          a.id,
          a.tenant_id,
          b.id,
          b.id,
          a.tenant_id,
          a.id,
          b.id
        )
    )
  end

  # Agent callers (#163): the bridge middle node must ALSO be visible to the caller,
  # so a pair can't be reported "bridgeable" through a private memory it can't see.
  defp maybe_filter_bridge_path(query, true, vis) when is_binary(vis) do
    where(
      query,
      [a, b],
      fragment(
        "EXISTS (SELECT 1 FROM article_links l WHERE l.tenant_id = ? AND ((l.source_article_id = ? AND l.target_article_id = ?) OR (l.source_article_id = ? AND l.target_article_id = ?)))",
        a.tenant_id,
        a.id,
        b.id,
        b.id,
        a.id
      ) or
        fragment(
          "EXISTS (SELECT 1 FROM articles m JOIN article_links la ON la.tenant_id = ? AND ((la.source_article_id = ? AND la.target_article_id = m.id) OR (la.target_article_id = ? AND la.source_article_id = m.id)) JOIN article_links lb ON lb.tenant_id = ? AND ((lb.source_article_id = ? AND lb.target_article_id = m.id) OR (lb.target_article_id = ? AND lb.source_article_id = m.id)) WHERE m.tenant_id = ? AND m.status = 'published' AND (COALESCE(m.metadata->>'visibility', 'shared') NOT IN ('private','owner') OR m.metadata->>'agent_id' = ?) AND m.id <> ? AND m.id <> ?)",
          a.tenant_id,
          a.id,
          a.id,
          a.tenant_id,
          b.id,
          b.id,
          a.tenant_id,
          ^vis,
          a.id,
          b.id
        )
    )
  end

  @doc """
  Random walk through the link graph from a starting article (Boden's
  random-exploration / incubation mechanism). Picks a random unvisited published
  neighbor at each step, so the walk never revisits a node; stops at `length`
  steps or when it reaches a dead end.

  ## Parameters

  - `start_id` -- the starting article UUID (must exist + be published)
  - `opts` -- `:length` (steps, default #{@default_walk_length}, max #{@max_walk_length})

  ## Returns

  - `{:ok, [%{id, title, category}]}` — the walk in order, starting with `start_id`
  - `{:error, :not_found}` when the start article doesn't exist / isn't published
  """
  @spec random_walk(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, [map()]} | {:error, :not_found}
  def random_walk(tenant_id, start_id, opts \\ []) do
    length = opts |> Keyword.get(:length, @default_walk_length) |> max(1) |> min(@max_walk_length)
    vis = Keyword.get(opts, :visibility_agent_id)

    case fetch_walk_node(tenant_id, start_id, vis) do
      nil -> {:error, :not_found}
      node -> {:ok, do_random_walk(tenant_id, node, MapSet.new([node.id]), length, [node], vis)}
    end
  end

  defp do_random_walk(_tenant_id, _current, _visited, 0, acc, _vis), do: Enum.reverse(acc)

  defp do_random_walk(tenant_id, current, visited, steps_left, acc, vis) do
    case random_unvisited_neighbor(tenant_id, current.id, visited, vis) do
      nil ->
        Enum.reverse(acc)

      next ->
        do_random_walk(
          tenant_id,
          next,
          MapSet.put(visited, next.id),
          steps_left - 1,
          [next | acc],
          vis
        )
    end
  end

  defp fetch_walk_node(tenant_id, article_id, vis) do
    if valid_uuid?(article_id) do
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.id == ^article_id and a.status == :published,
        select: %{id: a.id, title: a.title, category: a.category}
      )
      |> maybe_filter_by_visibility(vis)
      |> AdminRepo.one()
    end
  end

  defp random_unvisited_neighbor(tenant_id, current_id, visited, vis) do
    visited_ids = MapSet.to_list(visited)

    from(l in ArticleLink,
      where:
        l.tenant_id == ^tenant_id and
          (l.source_article_id == ^current_id or l.target_article_id == ^current_id),
      join: n in Article,
      on:
        n.tenant_id == ^tenant_id and n.status == :published and
          n.id ==
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE ? END",
              l.source_article_id,
              type(^current_id, Ecto.UUID),
              l.target_article_id,
              l.source_article_id
            ),
      where: n.id not in type(^visited_ids, {:array, Ecto.UUID}),
      order_by: fragment("random()"),
      limit: 1,
      select: %{id: n.id, title: n.title, category: n.category}
    )
    |> maybe_filter_neighbor_visibility(vis)
    |> AdminRepo.one()
  end

  # Visibility on the *second* query binding (`n`, the neighbor Article) — the
  # `[a]`-binding `maybe_filter_by_visibility/2` can't be reused here.
  defp maybe_filter_neighbor_visibility(query, nil), do: query

  defp maybe_filter_neighbor_visibility(query, vis) when is_binary(vis) do
    where(
      query,
      [_l, n],
      fragment("COALESCE(?->>'visibility', 'shared') NOT IN ('private','owner')", n.metadata) or
        fragment("?->>'agent_id' = ?", n.metadata, ^vis)
    )
  end

  @doc """
  Novelty scoring (#152 A2): for each idea, the **cosine distance** to its nearest
  prior proposal — `0` = identical to existing work, higher = more novel (up to `2.0`
  for an opposite embedding). Embeds each idea's text on the fly, concurrently (bounded
  at #{@novelty_concurrency}). Priors default to published articles tagged `proposal`;
  pass `:prior_tag` to use a different family.

  ## Parameters

  - `ideas` -- list of `%{...}` maps; the embed text is `idea[:text]` (or `"text"`),
    else `title <> " " <> thesis`-style fields are joined.
  - `opts` -- `:prior_tag` (default "proposal")

  ## Returns

  - `{:ok, [idea_with_novelty_score], prior_count}` — each idea gets `:novelty_score`
    (float in `[0, 2]`, or `nil` when its text is blank, couldn't be embedded, or there
    are no comparable priors). `prior_count` is the number of **embedded** prior
    proposals actually available for comparison (when it is `0`, every score is `nil`
    and no embedding work is done).
  """
  @spec novelty_scores(Ecto.UUID.t(), [map()], keyword()) :: {:ok, [map()], non_neg_integer()}
  def novelty_scores(tenant_id, ideas, opts \\ []) when is_list(ideas) do
    prior_tag = Keyword.get(opts, :prior_tag, "proposal")
    vis = Keyword.get(opts, :visibility_agent_id)
    prior_count = count_embedded_priors(tenant_id, prior_tag, vis)

    scored =
      if prior_count == 0 do
        # No comparable (embedded) priors — skip embedding entirely; nothing to score
        # against, so no upstream calls are made and every idea scores nil.
        Enum.map(ideas, &Map.put(&1, :novelty_score, nil))
      else
        ideas
        |> Task.async_stream(&score_idea(tenant_id, &1, prior_tag, vis),
          max_concurrency: @novelty_concurrency,
          timeout: :infinity,
          ordered: true
        )
        |> Enum.zip(ideas)
        |> Enum.map(fn
          {{:ok, scored_idea}, _original_idea} ->
            scored_idea

          {{:exit, reason}, original_idea} ->
            Logger.warning("novelty_scores: idea scoring task exited: #{inspect(reason)}")
            Map.put(original_idea, :novelty_score, nil)
        end)
      end

    {:ok, scored, prior_count}
  end

  # Count of embedded prior proposals visible to the caller — the set actually
  # compared against (matches nearest_prior_distance's filter), so it's a truthful
  # disambiguator for nil scores and never counts another agent's private priors.
  defp count_embedded_priors(tenant_id, prior_tag, vis) do
    from(a in Article,
      where:
        a.tenant_id == ^tenant_id and a.status == :published and not is_nil(a.embedding) and
          fragment("? && ?", a.tags, ^[prior_tag])
    )
    |> maybe_filter_by_visibility(vis)
    |> AdminRepo.aggregate(:count, timeout: 15_000)
  end

  defp score_idea(tenant_id, idea, prior_tag, vis) do
    text = novelty_idea_text(idea)

    if String.trim(text) == "" do
      Map.put(idea, :novelty_score, nil)
    else
      score_embedding(tenant_id, idea, text, prior_tag, vis)
    end
  end

  defp score_embedding(tenant_id, idea, text, prior_tag, vis) do
    case generate_embedding(text) do
      {:ok, embedding} ->
        Map.put(
          idea,
          :novelty_score,
          nearest_prior_distance(tenant_id, embedding, prior_tag, vis)
        )

      {:error, _} ->
        Map.put(idea, :novelty_score, nil)
    end
  end

  defp novelty_idea_text(idea) do
    text =
      case idea[:text] || idea["text"] do
        text when is_binary(text) and text != "" ->
          text

        _ ->
          [:title, :spark, :thesis]
          |> Enum.map(fn k -> idea[k] || idea[to_string(k)] end)
          |> Enum.filter(&is_binary/1)
          |> Enum.join(" ")
      end

    # Truncate to max bytes to prevent unbounded embedding input DoS
    if byte_size(text) > @max_idea_text_bytes do
      String.slice(text, 0, @max_idea_text_bytes)
    else
      text
    end
  end

  # Min cosine distance from the idea embedding to any prior proposal; nil when there
  # are no embedded priors (distinguishable from a genuine high score).
  defp nearest_prior_distance(tenant_id, embedding, prior_tag, vis) do
    from(a in Article,
      where:
        a.tenant_id == ^tenant_id and a.status == :published and not is_nil(a.embedding) and
          fragment("? && ?", a.tags, ^[prior_tag]),
      select: fragment("MIN(? <=> ?::vector)", a.embedding, ^embedding)
    )
    |> maybe_filter_by_visibility(vis)
    # Heavy vector aggregate — dedicated pool via Loopctl.HeavyRead (US-27.11).
    |> then(&HeavyRead.one(tenant_id, &1, heavy_read_opts(:novelty)))
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
    |> maybe_filter_by_tags(Keyword.get(opts, :tags), Keyword.get(opts, :match, :any))
    |> maybe_filter_by_source_type(Keyword.get(opts, :source_type))
    |> maybe_filter_by_source_id(Keyword.get(opts, :source_id))
    |> maybe_filter_by_idempotency_key(Keyword.get(opts, :idempotency_key))
    |> maybe_filter_by_visibility(Keyword.get(opts, :visibility_agent_id))
  end

  # Visibility enforcement (#163): when `:visibility_agent_id` is set (the caller is
  # an agent), hide other agents' `private`/`owner` memories. An article is visible
  # when its `metadata.visibility` is absent or `shared`, OR the caller owns it
  # (`metadata.agent_id` matches the caller's verified key identity). Higher roles
  # pass no `:visibility_agent_id` and see everything. An agent with no key
  # identity (agent_id "") owns nothing, so it sees only shared articles.
  #
  # Perf: this adds a `metadata->>...` filter (not the GIN-indexed `@>` form). It is
  # intentionally NOT given a dedicated index: the predicate is an OR whose first arm
  # (shared / non-memory) matches the overwhelming majority of rows, so the planner
  # must scan the tenant-scoped set regardless — a partial index on private/owner
  # rows can't serve a query that also returns the shared majority. The added per-row
  # JSONB extraction is cheap on the already-tenant-scoped scan; `distant_pairs`
  # applies it to the ≤1000-row candidate subquery before the O(n²) join, so it
  # doesn't compound the join cost.
  @doc """
  Returns the subset of `article_ids` that are visible to the caller (#163).

  `visibility_agent_id` nil (higher roles) ⇒ all ids that exist; an agent ⇒ only
  `shared`/non-memory articles plus its own. Used to filter indirect surfaces (the
  change feed) that reference articles by id without re-querying each one. Returns
  a `MapSet`. Ids that don't exist (hard-deleted) are excluded.
  """
  # No @spec: a `MapSet.t()` return annotation trips dialyzer's contract_with_opaque
  # check against the concrete success typing (a known false positive for opaque
  # built-ins). The behaviour is covered by tests instead.
  def visible_article_ids(_tenant_id, [], _vis), do: MapSet.new()

  def visible_article_ids(tenant_id, article_ids, vis) do
    ids = Enum.filter(article_ids, &valid_uuid?/1)

    from(a in Article, where: a.tenant_id == ^tenant_id and a.id in ^ids, select: a.id)
    |> maybe_filter_by_visibility(vis)
    |> AdminRepo.all()
    |> MapSet.new()
  end

  defp maybe_filter_by_visibility(query, nil), do: query

  defp maybe_filter_by_visibility(query, agent_id) when is_binary(agent_id) do
    where(
      query,
      [a],
      fragment("COALESCE(?->>'visibility', 'shared') NOT IN ('private','owner')", a.metadata) or
        fragment("?->>'agent_id' = ?", a.metadata, ^agent_id)
    )
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

  # `match` is `:any` (array overlap `&&`, the back-compat OR semantics) or
  # `:all` (array contains `@>` — articles carrying EVERY listed tag).
  defp maybe_filter_by_tags(query, nil, _match), do: query
  defp maybe_filter_by_tags(query, [], _match), do: query

  defp maybe_filter_by_tags(query, tags, :all) when is_list(tags) do
    where(query, [a], fragment("? @> ?", a.tags, ^tags))
  end

  defp maybe_filter_by_tags(query, tags, _any) when is_list(tags) do
    where(query, [a], fragment("? && ?", a.tags, ^tags))
  end

  defp maybe_filter_by_source_type(query, nil), do: query

  defp maybe_filter_by_source_type(query, source_type) do
    where(query, [a], a.source_type == ^source_type)
  end

  defp maybe_filter_by_source_id(query, nil), do: query

  defp maybe_filter_by_source_id(query, source_id) do
    # source_id is a binary_id; a malformed value would raise on cast, so match
    # nothing instead (a clean "exists? no" rather than a 500).
    if valid_uuid?(source_id) do
      where(query, [a], a.source_id == ^source_id)
    else
      where(query, [a], false)
    end
  end

  defp maybe_filter_by_idempotency_key(query, nil), do: query

  defp maybe_filter_by_idempotency_key(query, key) do
    where(query, [a], a.idempotency_key == ^key)
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

  # Agent callers may only link articles they can see; a hidden endpoint resolves
  # to :target_not_found (the controller renders 404) — no existence leak. Higher
  # roles (vis nil) skip the check.
  defp validate_link_visibility(_tenant_id, _source_id, _target_id, nil), do: :ok

  defp validate_link_visibility(tenant_id, source_id, target_id, vis) when is_binary(vis) do
    # Distinct ids so a self-link (source == target) checks one article and still
    # falls through to the changeset's self-link rejection (422) rather than 404.
    ids = Enum.uniq([source_id, target_id])

    visible_count =
      from(a in Article, where: a.tenant_id == ^tenant_id and a.id in ^ids)
      |> maybe_filter_by_visibility(vis)
      |> AdminRepo.aggregate(:count, :id)

    if visible_count == length(ids), do: :ok, else: {:error, :target_not_found}
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
    - `:limit` -- max ranked results to return (default 10, max
      #{@max_relevance_page_size}, min 1); relevance top-N, capped well below the
      enumeration page size
    - `:offset` -- results to skip for pagination (default 0)

  ## Returns

  - `{:ok, %{results: [map()], meta: map()}}` on success
  """
  @spec search_semantic(Ecto.UUID.t(), [float()], keyword()) ::
          {:ok, %{results: [map()], meta: map()}}
  def search_semantic(tenant_id, query_embedding, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 10) |> max(1) |> min(@max_relevance_page_size)
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

    # Heavy vector reads via Loopctl.HeavyRead (US-27.11): dedicated pool, pool-level
    # statement_timeout, isolated from the small AdminRepo pool. `filtered_query`
    # filters `a.tenant_id`; the count's tenant predicate lives in its inner subquery.
    count_query = from(q in subquery(filtered_query), select: count())
    total_count = HeavyRead.one(tenant_id, count_query, heavy_read_opts(:semantic_search))

    results =
      filtered_query
      |> limit(^limit)
      |> offset(^offset)
      |> then(&HeavyRead.all(tenant_id, &1, heavy_read_opts(:semantic_search)))

    maybe_record_search_access(tenant_id, results, nil, opts, "semantic")

    {:ok,
     %{
       results: results,
       meta: %{
         total_count: total_count,
         limit: limit,
         offset: offset,
         search_mode: "semantic_only",
         # Every EMBEDDED article passing the filters is ranked by similarity
         # (no relevance cutoff), so total_count is the size of that embedded
         # set — NOT a match count, and <= the total published count (articles
         # without an embedding are excluded). Use knowledge_stats for the
         # full wiki size.
         total_count_scope: "ranked_corpus"
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
    - `:limit` -- max ranked results to return (default 10, max
      #{@max_relevance_page_size}, min 1); relevance top-N, capped well below the
      enumeration page size
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
    # Use wide limits for sub-searches to get comprehensive score pools — at
    # least the relevance cap, so the merged/paginated result can satisfy a
    # request up to `max_relevance_page_size`. Suppress sub-search access
    # recording so we only record once at the merged result (otherwise each
    # article would be tracked twice).
    sub_opts =
      opts
      |> Keyword.merge(limit: @max_relevance_page_size, offset: 0)
      |> Keyword.put(:_skip_record_access, true)

    keyword_result = search_keyword(tenant_id, query_string, sub_opts)
    embedding_result = try_generate_embedding(query_string)

    case {keyword_result, embedding_result} do
      {{:ok, kw}, {:ok, embedding}} ->
        {:ok, semantic} = search_semantic(tenant_id, embedding, sub_opts)

        {:ok, merged} = merge_results(kw, semantic, keyword_weight, semantic_weight, opts)

        maybe_record_search_access(
          tenant_id,
          merged.results,
          query_string,
          opts,
          "combined"
        )

        {:ok, merged}

      {{:ok, kw}, {:error, _reason}} ->
        # Fallback to keyword-only
        paginated = paginate_results(kw.results, opts)

        maybe_record_search_access(
          tenant_id,
          paginated.results,
          query_string,
          opts,
          "combined_fallback"
        )

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
         search_mode: "combined",
         # Size of the deduplicated UNION of a keyword and a semantic sub-search
         # (each capped at 100, so up to ~200 with no overlap), NOT a corpus total
         # or full match count. Use list mode or knowledge_stats to size the corpus.
         total_count_scope: "merged_candidates"
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
    limit = opts |> Keyword.get(:limit, 10) |> max(1) |> min(@max_relevance_page_size)
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

  # ---------------------------------------------------------------------------
  # Analytics — article usage tracking
  # ---------------------------------------------------------------------------

  @doc """
  Records a fire-and-forget article access event.

  This 5-arity facade exists for backward compatibility; it delegates to
  `Loopctl.Knowledge.Analytics.record_access/6` with an empty attribution
  context. Callers that need to attribute the access to a project or story
  should call the Knowledge APIs (e.g. `get_article/3`, `search_keyword/3`)
  with `:project_id`/`:story_id` opts, or call
  `Loopctl.Knowledge.Analytics.record_access/6` directly.

  See `Loopctl.Knowledge.Analytics.record_access/6` for full semantics.
  """
  @spec record_access(
          Ecto.UUID.t(),
          Ecto.UUID.t() | nil,
          Ecto.UUID.t() | nil,
          String.t(),
          map()
        ) :: :ok
  def record_access(tenant_id, article_id, api_key_id, access_type, metadata \\ %{}) do
    Analytics.record_access(tenant_id, article_id, api_key_id, access_type, metadata)
  end

  @doc """
  Records fire-and-forget search access for a list of article ids.
  """
  @spec record_search_access(
          Ecto.UUID.t(),
          [Ecto.UUID.t()],
          Ecto.UUID.t() | nil,
          String.t() | nil,
          map()
        ) :: :ok
  def record_search_access(tenant_id, article_ids, api_key_id, query, metadata \\ %{}) do
    Analytics.record_search_access(tenant_id, article_ids, api_key_id, query, metadata)
  end

  @doc """
  Returns aggregated usage statistics for a single article.

  See `Loopctl.Knowledge.Analytics.get_article_stats/2` for the response shape.
  """
  @spec get_article_stats(Ecto.UUID.t(), Ecto.UUID.t()) :: map()
  def get_article_stats(tenant_id, article_id) do
    Analytics.get_article_stats(tenant_id, article_id)
  end

  @doc """
  Returns the top accessed articles for a tenant in a time window.
  """
  @spec list_top_articles(Ecto.UUID.t(), keyword()) :: [map()]
  def list_top_articles(tenant_id, opts \\ []) do
    Analytics.list_top_articles(tenant_id, opts)
  end

  @doc """
  Returns usage statistics for a single api_key or logical agent.

  Accepts either an `api_keys.id` or an `agents.id` — see
  `Loopctl.Knowledge.Analytics.get_agent_usage/3` for the resolution
  rules and response shape.
  """
  @spec get_agent_usage(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def get_agent_usage(tenant_id, id, opts \\ []) do
    Analytics.get_agent_usage(tenant_id, id, opts)
  end

  @doc """
  Returns a per-project wiki usage rollup.
  """
  @spec get_project_usage(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def get_project_usage(tenant_id, project_id, opts \\ []) do
    Analytics.get_project_usage(tenant_id, project_id, opts)
  end

  @doc """
  Returns published articles with zero accesses in the configured window.
  """
  @spec list_unused_articles(Ecto.UUID.t(), keyword()) :: [map()]
  def list_unused_articles(tenant_id, opts \\ []) do
    Analytics.list_unused_articles(tenant_id, opts)
  end
end
