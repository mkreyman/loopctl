defmodule Loopctl.Knowledge do
  @moduledoc """
  Context module for the Knowledge Wiki.

  Provides CRUD operations for articles and article links. Articles
  are the core knowledge units — reusable patterns, conventions,
  decisions, findings, and references within a tenant's knowledge base.

  Most operations use AdminRepo (BYPASSRLS) with explicit `tenant_id`
  scoping, following the same pattern as other loopctl contexts. The heavy
  vector/enumeration reads (suggested_links, semantic search, distant_pairs,
  novelty, enumeration) route through `Loopctl.HeavyRead` → the dedicated
  `Loopctl.HeavyReadRepo` pool (also BYPASSRLS, same explicit `tenant_id`
  scoping), isolated so a slow read can't starve light admin ops.

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
  alias Loopctl.Knowledge.ConflictResolution
  alias Loopctl.Knowledge.EmbeddingConcurrency
  alias Loopctl.Knowledge.KbCuration
  alias Loopctl.Knowledge.OKF
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Projects.Project
  alias Loopctl.Provider.RetryAfter
  alias Loopctl.SystemConfig
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Workers.ArticleEmbeddingWorker
  alias Loopctl.Workers.BatchArticleEmbeddingWorker

  # US-37.4: default texts-per-array-batch for background embedding (`embedding_batch_max/0`).
  # Env-driven via SystemConfig (`"embedding_batch_max"`); this in-code default doubles
  # as the documented default and applies on a cache miss.
  @default_embedding_batch_max 100

  # US-37.4 (AC-37.4.4 review): CUMULATIVE per-request character budget for a single
  # provider array call (`embedding_batch_max_chars/0`). The count cap
  # (`embedding_batch_max/0`) alone does not bound aggregate tokens — 100 inputs each
  # sliced to ~32K chars is ~3.2M chars (~800k tokens), which can exceed an
  # OpenAI-compatible per-request token ceiling (~300k tokens) and return a permanent
  # HTTP 400. The worker sub-splits each count-chunk so no single array call exceeds
  # this many characters. Default ~1,000,000 chars (~250k tokens at ~4 chars/token)
  # keeps every request comfortably under the ceiling. Env-driven via SystemConfig
  # (`"embedding_batch_max_chars"`).
  @default_embedding_batch_max_chars 1_000_000

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

  # US-27.7a `search_semantic` relevance-pool sizing. The results path over-fetches the
  # top-`pool` ANN nearest, then post-filters + paginates within the pool (the inner ANN
  # is the shared HNSW-index-safe `VectorSearch.candidate_pool_query/4`). The pool covers
  # `offset + limit` floored/capped: the FLOOR keeps the common shallow page cheap-but-not
  # under-fetched, the CAP keeps the inner HNSW scan bounded. The cap is well above the
  # in-contract deepest page (`offset + limit` with `limit ≤ max_relevance_page_size`), so
  # every valid page is fully served; only an unusually-deep offset beyond it is truncated
  # (the documented post-ANN-filter recall tradeoff). Overridable via config
  # `:semantic_result_pool_floor` / `:semantic_result_pool_cap`.
  @default_semantic_result_pool_floor 200
  @default_semantic_result_pool_cap 1_000

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
  # `bridge_path: true` adds a per-pair link-graph EXISTS (direct link OR a shared
  # published neighbor) to the band filter. In-band ("distant") pairs are usually
  # graph-DISTANT, so few bridge — the paginated `LIMIT limit+1` page then cannot
  # early-terminate and evaluates the (expensive 2-hop) EXISTS over the whole in-band
  # set, which is O(candidates²) work (#202/#203). So the bridge branch uses a SMALLER
  # sample cap to keep it under the Theme 2 <2s budget; operator-tunable via
  # `config :loopctl, :max_bridge_pair_candidates`. The non-bridge path keeps the full
  # 1000 cap (it early-terminates in a few ms regardless).
  @max_bridge_pair_candidates 500
  @default_pair_limit 20
  @max_pair_limit 100
  # Upper bound on `:offset` (#202/#203 review, MED-5). A deep offset defeats the page's
  # early termination — Postgres must produce `offset + limit + 1` matching pairs before
  # returning — so an unbounded offset lets a caller force near-full O(candidates²)
  # evaluation of the cross-join. Clamp it (analogous to `limit`'s `min(@max_pair_limit)`);
  # operator-tunable via `config :loopctl, :max_pair_offset`. 10_000 ≫ any real page depth
  # at the default limit (500 pages) yet ≪ the ~500k max pairs at the 1000 candidate cap.
  @max_pair_offset 10_000
  @default_walk_length 4
  @max_walk_length 25
  # Novelty scoring embeds each idea concurrently (bounded) so a 50-idea batch doesn't
  # serialize 50 embedding round-trips. This is a STATIC CEILING; the effective width is
  # computed by novelty_concurrency/0, which caps it further to leave guaranteed headroom
  # below the per-tenant embedding budget (US-37.2 review): the fan-out and the SAME
  # tenant's interactive combined searches share EmbeddingConcurrency's per-tenant cap,
  # so an uncapped fan-out (5) could hold nearly the whole per-tenant budget (default 6)
  # and starve that tenant's concurrent interactive searches down to keyword fallback.
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

  @doc """
  Novelty-gated write-back. Wraps `create_article/3` with a semantic dedup gate so
  an agent proposing knowledge can't silently bloat the corpus with near-duplicates.

  The proposal is assessed against the published corpus (see
  `Loopctl.Knowledge.ProposalAssessorBehaviour`); then, by verdict:

    * `:duplicate` — a near-identical article already exists. Nothing is created;
      the canonical article is returned so the caller can read/update it instead.
    * `:low_novelty` — high overlap with existing knowledge. The article is created
      as a **draft** (downgraded from publish if needed) with the near-neighbors
      stamped into `metadata.proposal_novelty`, so the smarter consuming agent (or a
      human) resolves merge-vs-keep from the drafts review queue.
    * `:novel` / `:unknown` (gate fell open) — created on the requested path.

  The gate is mechanical and non-destructive: it never edits or deletes existing
  articles, and it falls open (`:unknown`) rather than blocking a write when the
  embedding backend is unavailable.

  Returns `{:ok, result}` where `result` is a map:

      %{
        verdict: :created | :gated_to_draft | :duplicate | :deduplicated,
        article: %Article{},        # the created article, or the canonical existing one
        created: boolean(),         # false for :duplicate / :deduplicated
        assessment: %{verdict:, score:, neighbors:}
      }

  or `{:error, :duplicate_title, %Article{}}` / `{:error, %Ecto.Changeset{}}`,
  forwarded unchanged from `create_article/3`.
  """
  @spec propose_article(Ecto.UUID.t() | nil, map(), keyword()) ::
          {:ok, map()}
          | {:error, :duplicate_title, Article.t()}
          | {:error, Ecto.Changeset.t()}
  def propose_article(tenant_id, attrs, opts \\ []) do
    attrs = stringify_top_keys(attrs)
    assessment = proposal_assessor().assess(tenant_id, attrs, opts)
    gate_proposal(tenant_id, attrs, assessment, opts)
  end

  defp proposal_assessor do
    Application.get_env(:loopctl, :proposal_assessor, Loopctl.Knowledge.ProposalGate)
  end

  defp gate_proposal(tenant_id, attrs, %{verdict: :duplicate} = assessment, opts) do
    case canonical_neighbor(tenant_id, assessment, opts) do
      {:ok, existing} ->
        log_gate(tenant_id, "gate_duplicate", "rejected duplicate", existing, assessment, opts)
        {:ok, %{verdict: :duplicate, article: existing, created: false, assessment: assessment}}

      # The canonical neighbor vanished (deleted/unpublished) between assess and now —
      # there is nothing to dedup against, so create on the normal path.
      :error ->
        create_proposal(tenant_id, attrs, %{assessment | verdict: :novel}, opts, :created)
    end
  end

  defp gate_proposal(tenant_id, attrs, %{verdict: :low_novelty} = assessment, opts) do
    gated_attrs =
      attrs
      |> Map.put("status", "draft")
      |> stamp_proposal_metadata(assessment)

    neighbor = List.first(assessment.neighbors)
    log_gate(tenant_id, "gate_draft", "drafted (high overlap)", neighbor, assessment, opts)
    create_proposal(tenant_id, gated_attrs, assessment, opts, :gated_to_draft)
  end

  # :novel or :unknown (gate fell open) — proceed on the requested path.
  defp gate_proposal(tenant_id, attrs, assessment, opts) do
    create_proposal(tenant_id, attrs, assessment, opts, :created)
  end

  defp create_proposal(tenant_id, attrs, assessment, opts, verdict) do
    case create_article(tenant_id, attrs, opts) do
      {:ok, article} ->
        {:ok, %{verdict: verdict, article: article, created: true, assessment: assessment}}

      {:ok, :deduplicated, article} ->
        {:ok, %{verdict: :deduplicated, article: article, created: false, assessment: assessment}}

      {:error, :duplicate_title, existing} ->
        {:error, :duplicate_title, existing}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # Concise curation-log line for a gate decision (only written when the tenant has
  # kb_curation_log on — KbCuration.record no-ops otherwise).
  defp log_gate(tenant_id, kind, prefix, neighbor, assessment, opts) do
    {nid, ntitle} =
      case neighbor do
        %Article{id: id, title: title} -> {id, title}
        %{id: id, title: title} -> {id, title}
        _ -> {nil, nil}
      end

    summary =
      prefix <>
        if(ntitle, do: " of \"#{ntitle}\"", else: "") <>
        if(assessment.score, do: " (sim=#{fmt_sim(assessment.score)})", else: "")

    KbCuration.record(tenant_id, kind, summary,
      refs: Enum.reject([nid], &is_nil/1),
      actor: Keyword.get(opts, :actor_label) || Keyword.get(opts, :actor_id),
      metadata: %{"similarity" => assessment.score}
    )
  end

  defp fmt_sim(s) when is_float(s), do: :erlang.float_to_binary(s, decimals: 3)
  defp fmt_sim(s), do: to_string(s)

  defp canonical_neighbor(tenant_id, %{neighbors: [%{id: id} | _]}, opts) do
    case get_article(tenant_id, id, Keyword.take(opts, [:visibility_agent_id])) do
      {:ok, article} -> {:ok, article}
      _ -> :error
    end
  end

  defp canonical_neighbor(_tenant_id, _assessment, _opts), do: :error

  defp stamp_proposal_metadata(attrs, %{score: score, neighbors: neighbors}) do
    existing = stringify_top_keys(attrs["metadata"] || %{})

    novelty = %{
      "verdict" => "low_novelty",
      "score" => score,
      "nearest" =>
        Enum.map(neighbors, fn n ->
          %{"id" => n.id, "title" => n.title, "score" => n.similarity_score}
        end)
    }

    Map.put(attrs, "metadata", Map.put(existing, "proposal_novelty", novelty))
  end

  defp stringify_top_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
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
      nil -> {:error, :not_found}
      article -> finalize_article_read(tenant_id, article, opts)
    end
  end

  # Shared visibility/preload/access-tracking tail of an article fetch, once the
  # row itself has been located (tenant-owned or, via `progressive_drill/3`'s
  # system fallback, a system canonical). Factored out so BOTH scopes get
  # identical visibility enforcement, link preloading, conflict-link filtering,
  # and access recording — never duplicated ad hoc per caller.
  defp finalize_article_read(tenant_id, article, opts) do
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
        |> drop_resolved_conflict_links(tenant_id)

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

  # Route-the-findings (#4): a `:potential_conflict` link whose pair already has a
  # resolution (dismissed/superseded/etc.) is no longer an OPEN conflict — drop it from
  # the surfaced links so `article_data_with_links`' `potential_conflicts` field shows
  # only conflicts still awaiting a decision. Other link types are untouched.
  defp drop_resolved_conflict_links(article, tenant_id) do
    peers =
      (article.outgoing_links ++ article.incoming_links)
      |> Enum.filter(&(&1.relationship_type == :potential_conflict))
      |> Enum.flat_map(&[&1.source_article_id, &1.target_article_id])
      |> Enum.uniq()

    resolved = resolved_peer_ids(tenant_id, article.id, peers)

    %{
      article
      | outgoing_links: reject_resolved(article.outgoing_links, article.id, resolved),
        incoming_links: reject_resolved(article.incoming_links, article.id, resolved)
    }
  end

  defp resolved_peer_ids(_tenant_id, _article_id, []), do: MapSet.new()

  defp resolved_peer_ids(tenant_id, article_id, _peers) do
    from(r in ConflictResolution,
      where: r.tenant_id == ^tenant_id,
      where: r.source_article_id == ^article_id or r.target_article_id == ^article_id,
      select: {r.source_article_id, r.target_article_id}
    )
    |> AdminRepo.all()
    |> Enum.flat_map(fn {s, t} -> [s, t] end)
    |> Enum.reject(&(&1 == article_id))
    |> MapSet.new()
  end

  defp reject_resolved(links, article_id, resolved) do
    Enum.reject(links, fn l ->
      l.relationship_type == :potential_conflict and
        (MapSet.member?(resolved, l.source_article_id) or
           MapSet.member?(resolved, l.target_article_id)) and
        (l.source_article_id == article_id or l.target_article_id == article_id)
    end)
  end

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
  Batch presence-check variant for the bulk-embedding path (US-37.4): fetches every
  article in `article_ids` for the tenant with the virtual `has_embedding` boolean
  set to `not is_nil(embedding)` — WITHOUT transferring the 1536-dim vector itself.
  The batch worker only needs to know whether a row is already embedded (and compare
  the separate `embedding_content_hash`); loading up to `embedding_batch_max` (~100)
  full pgvectors per job just to null-check them is avoidable I/O on this hot
  bulk-ingest path. Silently drops ids that don't resolve (deleted / wrong tenant).
  Order is NOT guaranteed — the caller keys by `id`. Scoped to ONE tenant (RLS +
  explicit predicate).
  """
  @spec get_articles_with_embedding_status(Ecto.UUID.t(), [Ecto.UUID.t()]) :: [Article.t()]
  def get_articles_with_embedding_status(tenant_id, article_ids)
      when is_binary(tenant_id) and is_list(article_ids) do
    query =
      from(a in Article,
        where: a.id in ^article_ids and a.tenant_id == ^tenant_id,
        select_merge: %{has_embedding: not is_nil(a.embedding)}
      )

    AdminRepo.all(query)
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

    base = scope_project_or_global(base, project_id)

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

    base = scope_project_or_global(base, project_id)

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

    base = scope_project_or_global(base, project_id)

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

    # The keyword_only fallback reason (#297) rides in the underlying combined
    # search meta; carry it into the context meta so `/knowledge/context` is as
    # diagnosable as `/knowledge/search`. Absent on the success path.
    fallback_reason = search.meta[:fallback_reason]

    if article_ids == [] do
      {:ok,
       %{
         results: [],
         meta:
           maybe_put_fallback_reason(
             %{
               total_count: 0,
               limit: limit,
               fallback: fallback?,
               recency_weight: recency_weight
             },
             fallback_reason
           )
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
         meta:
           maybe_put_fallback_reason(
             %{
               total_count: length(scored),
               limit: limit,
               fallback: fallback?,
               recency_weight: recency_weight
             },
             fallback_reason
           )
       }}
    end
  end

  # Only surface `fallback_reason` when the combined search actually degraded — the
  # success path leaves the key absent (never a stray `nil`).
  defp maybe_put_fallback_reason(meta, nil), do: meta
  defp maybe_put_fallback_reason(meta, reason), do: Map.put(meta, :fallback_reason, reason)

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
    # per-read SET LOCAL statement_timeout and optional per-endpoint override.
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
         {:ok, article} <- fetch_article(tenant_id, article_id, opts) do
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

    with {:ok, article} <- fetch_article(tenant_id, article_id, opts) do
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

  # --- Curated sources (US-31.1) ---

  @doc """
  Pure predicate: is this article a GOVERNED "curated" (authoritative) source?

  An article is curated **iff** it is `:published` AND carries the governed
  curated marker (`curated_at` is set). The marker is writable ONLY via the
  admin/curation-gated `mark_curated/3` path (it is absent from
  `Article`'s cast fields) — so an agent CANNOT self-promote its own article to
  authoritative merely by choosing a `:reference`/`:playbook` `category` or by
  setting a `metadata` flag. Category may be used as an additional *filter* by
  callers, but is never sufficient on its own.

  This function is deliberately **pure** — it inspects only the struct, does no
  DB call, and is unit-testable with an in-memory `%Article{}`. It knows only
  `status` + marker. The heavier authoritativeness rules (excluding an article in
  an OPEN `:potential_conflict`, and tenant-over-system precedence) live in
  `list_curated_sources/2` / `authoritative_curated?/1`, which do the DB work.

  ## System vs tenant scope (see also `list_curated_sources/2`)

  A system-scoped canonical article (`scope: :system`, `tenant_id` nil) MAY be
  curated and participate in the hybrid path. But a tenant's OWN curated article
  on the same topic takes precedence — a system canonical never overrides a
  tenant's fresher/own answer. System articles never leak as another tenant's
  private content: they are only ever surfaced via the explicit
  `or a.scope == :system` predicate in `list_curated_sources/2`.

  ## Examples

      iex> Knowledge.curated?(%Article{status: :published, curated_at: ~U[2026-07-10 00:00:00.000000Z]})
      true

      iex> Knowledge.curated?(%Article{status: :published, curated_at: nil})
      false

      iex> Knowledge.curated?(%Article{status: :draft, curated_at: ~U[2026-07-10 00:00:00.000000Z]})
      false
  """
  @spec curated?(Article.t()) :: boolean()
  def curated?(%Article{status: :published, curated_at: %DateTime{}}), do: true
  def curated?(%Article{}), do: false

  @doc """
  Governed setter: marks an article as curated (authoritative).

  This is the ONLY writer of the curated marker. It writes through the dedicated
  `Article.curation_changeset/3` (the marker is NOT in the ordinary cast fields) and
  records an `article.curated` audit event in the same transaction.

  Marking authoritative is a **trust gate** (the hybrid resolver, US-31.2, prefers
  curated answers), so the HTTP surface that reaches this MUST be role-gated at
  `:user` or above — do not expose it at `:agent`. The non-castable marker is the
  domain-layer half of the gate; the role check is the transport half.

  Marking is allowed regardless of the article's current status, but `curated?/1`
  only reports `true` once the article is `:published`.

  ## Audit & curation-feed scope

  - **Tenant-scoped article** (`tenant_id` a UUID): the `article.curated` audit event
    is recorded under that tenant, and a per-tenant `KbCuration` feed line is appended
    *when the tenant's `kb_curation_log` toggle is on* (off by default — see
    `Loopctl.Knowledge.KbCuration`).
  - **System-scope article** (`tenant_id == nil`): curation is a GLOBAL superadmin
    operation. The audit event is written with `tenant_id: nil` (global scope; the
    superadmin API is the oversight path) and NO per-tenant `KbCuration` feed line is
    written — that feed is per-tenant and a system canonical belongs to no tenant.
    Because the global path is destructive of the "trust curated" guarantee for
    EVERY tenant, the caller MUST pass `scope: :system` to use it; a bare `nil`
    `tenant_id` (e.g. from a missing tenant context) is rejected with
    `{:error, :system_scope_required}` rather than silently curating a global
    canonical. That domain guard is defense in depth — the transport layer
    (US-31.4) still MUST role-gate the system path at superadmin/WebAuthn.

  ## Parameters

  - `tenant_id` -- the owning tenant UUID (pass `nil` WITH `scope: :system` for a
    system canonical)
  - `article_id` -- the article UUID
  - `opts` -- `:actor_id`, `:actor_label`, `:actor_type`, `:at` (mark time), and
    `:scope` (`:system` REQUIRED when `tenant_id` is `nil`)

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, :not_found}` if not found / wrong tenant
  - `{:error, :system_scope_required}` if `tenant_id` is `nil` without `scope: :system`
  - `{:error, %Ecto.Changeset{}}` on a write failure
  """
  @spec mark_curated(Ecto.UUID.t() | nil, Ecto.UUID.t(), keyword()) ::
          {:ok, Article.t()}
          | {:error, :not_found | :system_scope_required | Ecto.Changeset.t()}
  def mark_curated(tenant_id, article_id, opts \\ []) do
    at = Keyword.get(opts, :at) || DateTime.utc_now()
    actor_label = Keyword.get(opts, :actor_label)
    changeset_fun = fn article -> Article.curation_changeset(article, at, actor_label) end

    write_curation(tenant_id, article_id, changeset_fun, "article.curated", opts)
  end

  @doc """
  Governed setter: clears an article's curated marker (the inverse of `mark_curated/3`).

  Reversible + audited, same governance as `mark_curated/3` — including the same
  audit & curation-feed scope rules (tenant-scoped vs global system-scope). Records an
  `article.uncurated` audit event. Returns the same shapes.
  """
  @spec unmark_curated(Ecto.UUID.t() | nil, Ecto.UUID.t(), keyword()) ::
          {:ok, Article.t()}
          | {:error, :not_found | :system_scope_required | Ecto.Changeset.t()}
  def unmark_curated(tenant_id, article_id, opts \\ []) do
    changeset_fun = fn article -> Article.curation_changeset(article, nil, nil) end
    write_curation(tenant_id, article_id, changeset_fun, "article.uncurated", opts)
  end

  defp write_curation(tenant_id, article_id, changeset_fun, action, opts) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    actor_type = Keyword.get(opts, :actor_type, "api_key")

    with :ok <- authorize_curation_scope(tenant_id, opts),
         {:ok, article} <- fetch_curatable_article(tenant_id, article_id) do
      changeset = changeset_fun.(article)

      multi =
        Multi.new()
        |> Multi.update(:article, changeset)
        |> Audit.log_in_multi(:audit, fn %{article: updated} ->
          %{
            tenant_id: updated.tenant_id,
            entity_type: "article",
            entity_id: updated.id,
            action: action,
            actor_type: actor_type,
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: %{"curated_at" => marker_iso(article.curated_at)},
            new_state: %{"curated_at" => marker_iso(updated.curated_at)}
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{article: updated}} ->
          KbCuration.record(
            updated.tenant_id,
            curation_kind(action),
            curation_summary(action, updated),
            refs: [updated.id],
            actor: actor_label
          )

          {:ok, updated}

        {:error, :article, changeset, _} ->
          {:error, changeset}
      end
    end
  end

  defp marker_iso(nil), do: nil
  defp marker_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp curation_kind("article.curated"), do: "curated"
  defp curation_kind("article.uncurated"), do: "uncurated"

  defp curation_summary("article.curated", article),
    do: "Marked article #{article.id} (#{article.title}) as curated"

  defp curation_summary("article.uncurated", article),
    do: "Cleared curated marker on article #{article.id} (#{article.title})"

  # US-31.1 defense in depth: curating a system-scoped canonical (tenant_id nil) is
  # a GLOBAL, all-tenant-visible authoritative operation. Reaching that path with a
  # nil tenant_id must be DELIBERATE, never accidental — an unset/missing tenant
  # context (a common bug shape) would otherwise silently curate a global article.
  # The caller must therefore explicitly declare `scope: :system` to use the
  # nil-tenant path; a nil tenant_id without it is rejected. This is orthogonal to
  # (and does not replace) the transport-layer role gate that US-31.4 must add:
  # tenant curation at role `:user`+, system curation at superadmin/WebAuthn.
  defp authorize_curation_scope(nil, opts) do
    if Keyword.get(opts, :scope) == :system do
      :ok
    else
      {:error, :system_scope_required}
    end
  end

  defp authorize_curation_scope(tenant_id, _opts) when is_binary(tenant_id), do: :ok

  # Fetches an article for curation. A tenant article is scoped by tenant_id; a
  # system article (tenant_id nil) is fetched by its system scope. Never crosses
  # tenants — a wrong tenant_id resolves to :not_found.
  defp fetch_curatable_article(nil, article_id) do
    case AdminRepo.one(from(a in Article, where: a.id == ^article_id and a.scope == :system)) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  defp fetch_curatable_article(tenant_id, article_id) when is_binary(tenant_id) do
    case AdminRepo.one(
           from(a in Article, where: a.id == ^article_id and a.tenant_id == ^tenant_id)
         ) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  @doc """
  Lists the AUTHORITATIVE curated sources visible to a tenant.

  Returns the tenant's OWN curated, published articles UNIONed with system-scoped
  (`scope: :system`, `tenant_id` nil) curated, published articles — the set the
  hybrid resolver (US-31.2) may prefer.

  Governance / correctness rules baked in:

    * **Explicit tenant predicate, never RLS.** Like every Knowledge read, this
      runs on `AdminRepo` (BYPASSRLS) scoped by an explicit
      `where a.tenant_id == ^tenant_id or a.scope == :system` — system articles
      are opted in *only* by that `or`, and one tenant never sees another tenant's
      private curated articles.
    * **Only published + governed marker.** Drafts, archived, and superseded
      articles are excluded (`curated?/1` semantics, enforced in SQL).
    * **Open conflicts excluded (AC-31.1.4).** An article in an OPEN
      `:potential_conflict` (an auto-generated conflict link with no
      `conflict_resolutions` row) is NOT returned as authoritative — the conflict
      must be surfaced/resolved first (ties to US-31.2 AC-31.2.6). The conflict
      link is correlated to the CALLER's `tenant_id` (see `open_conflict_subquery/1`)
      so one tenant's dispute over a shared system canonical cannot retract that
      global canonical from OTHER tenants' lists.
    * **Tenant precedence (AC-31.1.3).** When a tenant's own curated article and a
      system canonical share a topic (case-insensitive EXACT title — a v1
      interpretation; see below), the tenant's own wins and the system one is
      suppressed from the result — a system canonical never overrides a tenant's
      own answer. System canonicals on topics the tenant has NOT curated are still
      returned (they participate). Ownership is folded into the main query as a
      correlated `NOT EXISTS` (see `tenant_owns_topic_subquery/2`) evaluated
      INDEPENDENTLY of open-conflict status: if the tenant's own curated article on
      a topic is itself in an open conflict, it is excluded from the RESULT
      (AC-31.1.4) but STILL suppresses the system canonical — so on a topic the
      tenant owns-but-is-disputing, neither surfaces and the conflict must be
      resolved first, rather than papering over the tenant's disputed answer with
      the system one.

  ## Topic identity (v1 scope)

  "Same topic" for precedence is keyed on the article's **case-insensitive,
  trimmed title** (exact equality). Two curated articles about the same conceptual
  topic under DIFFERENT titles are treated as distinct topics and both surface.
  Broader (semantic) topic identity is deliberately OUT OF SCOPE for US-31.1 and
  belongs to the US-31.2 hybrid resolver's blending layer, which has embeddings;
  callers here must not assume title-equality captures semantic sameness.

  ## Options

  - `:category` -- restrict to a single category atom
  - `:include_system` -- set `false` to exclude system canonicals (default `true`)
  - `:limit` -- cap the number of rows returned (a positive integer; default
    unbounded). Precedence suppression is applied IN THE QUERY (correlated
    subquery), so `:limit` bounds the FINAL result set, not a pre-suppression pull.
    Use it when the caller (e.g. the US-31.2 resolver) wants a bounded result.
  - `:select` -- set `:id` for a body-less projection that returns a plain list of
    article UUIDs (`[Ecto.UUID.t()]`) instead of full `%Article{}` structs. Use this
    for identity/membership checks (e.g. the US-31.2 hybrid resolver's curated-id
    lookup) so per-query cost no longer scales with the curated corpus's article
    BODIES — only ids leave the database. Default (`nil`/anything else) returns full
    structs, unchanged. Combined with `:select, :id`, the `order_by` is also dropped
    (a MapSet has no order) — pure wasted sort work otherwise.
  - `:ids` -- restrict the scan to this list of article UUIDs (e.g. a caller's
    already-fetched candidate pool). Use this WITH `select: :id` so per-query cost
    scales with the caller's candidate set, not the tenant's entire curated/system-
    canonical corpus (US-31.2's `curated_source_ids/2` is the reference caller).
    Default (`nil`) scans the full curated corpus, unchanged.

  Results are ordered tenant-own-first (tenant rows before system canonicals), then
  most-recently-updated (unless `select: :id` drops the order, see above).

  ## Consistency & scaling notes

  Precedence is computed in a SINGLE query (one snapshot): the tenant-ownership
  suppression is a correlated `NOT EXISTS` on the same `%Article{}` scan rather than
  a second, independent read. This (a) removes the torn-view window a concurrent
  `mark_curated` could open between two reads, and (b) removes the previously
  unbounded full curated-title scan — ownership is now evaluated per candidate row
  via the partial index `articles_curated_published_idx`, so `:limit` genuinely
  bounds the work. Pass `select: :id` (above) for a body-less projection when only
  membership/identity is needed — the default remains full `%Article{}` structs
  (including bodies) for callers that need the whole record.
  """
  @spec list_curated_sources(Ecto.UUID.t(), keyword()) :: [Article.t()] | [Ecto.UUID.t()]
  def list_curated_sources(tenant_id, opts \\ []) when is_binary(tenant_id) do
    category = Keyword.get(opts, :category)
    limit = Keyword.get(opts, :limit)
    ids = Keyword.get(opts, :ids)

    base =
      tenant_id
      |> curated_sources_base_query(category, opts)
      |> maybe_filter_curated_by_category(category)
      |> maybe_filter_curated_by_ids(ids)
      |> maybe_limit_curated(limit)

    case Keyword.get(opts, :select) do
      # `order_by` is pure wasted sort work once the result is collapsed into a
      # MapSet (order is irrelevant to membership) — dropped here so an `:ids`-scoped
      # membership check (e.g. `curated_source_ids/2`) never pays for a corpus-wide
      # sort it never uses (review finding, US-31.2).
      :id -> base |> exclude(:order_by) |> select([a], a.id) |> AdminRepo.all()
      _ -> AdminRepo.all(base)
    end
  end

  defp curated_sources_base_query(tenant_id, category, opts) do
    include_system = Keyword.get(opts, :include_system, true)

    scope_filter =
      if include_system do
        # A system canonical participates ONLY when the tenant does not OWN the same
        # topic (AC-31.1.3). Folding the ownership check here (rather than a second
        # in-memory pass over a separately-read owned-topic set) keeps the whole
        # precedence decision in one atomic snapshot and bounded by :limit.
        dynamic(
          [a],
          a.tenant_id == ^tenant_id or
            (a.scope == :system and
               not exists(tenant_owns_topic_subquery(tenant_id, category)))
        )
      else
        dynamic([a], a.tenant_id == ^tenant_id)
      end

    from(a in Article,
      as: :article,
      where: a.status == :published,
      where: not is_nil(a.curated_at),
      where: ^scope_filter,
      # AC-31.1.4: never surface an article that is in an OPEN potential_conflict.
      where: not exists(open_conflict_subquery(tenant_id)),
      # Tenant-own-first: tenant rows (tenant_id NOT NULL, so `IS NULL` = false)
      # sort before system canonicals (tenant_id NULL, `IS NULL` = true), then freshest.
      order_by: [asc: fragment("? IS NULL", a.tenant_id), desc: a.updated_at, asc: a.id]
    )
  end

  defp maybe_filter_curated_by_category(query, nil), do: query

  defp maybe_filter_curated_by_category(query, category),
    do: from(a in query, where: a.category == ^category)

  # Membership scope (US-31.2 fix): restricts the curated-corpus scan to only the
  # given article ids (e.g. the hybrid resolver's <=200-candidate pool) instead of
  # materializing the tenant's ENTIRE curated/system-canonical universe just to test
  # membership of a small candidate set. `nil` (the default) is a no-op — every other
  # caller keeps scanning the full curated corpus unaffected.
  defp maybe_filter_curated_by_ids(query, nil), do: query

  defp maybe_filter_curated_by_ids(query, ids) when is_list(ids),
    do: from(a in query, where: a.id in ^ids)

  defp maybe_limit_curated(query, limit) when is_integer(limit) and limit > 0,
    do: from(a in query, limit: ^limit)

  defp maybe_limit_curated(query, _limit), do: query

  # Subquery correlated on the outer :article binding: TRUE when the article is a
  # member of an auto-generated :potential_conflict pair that has NOT yet been
  # resolved (no conflict_resolutions row either direction). The link is scoped to
  # `tenant_id` (the CALLER's tenant) so one tenant's unresolved dispute over a
  # shared system canonical (article ids are global) cannot retract that canonical
  # from ANOTHER tenant's list. For a tenant's own article the link necessarily
  # lives under that same tenant, so this predicate is a no-op restriction there.
  # Mirrors the open-conflict definition in list_potential_conflicts/2.
  defp open_conflict_subquery(tenant_id) do
    from(l in ArticleLink,
      as: :link,
      where: l.tenant_id == ^tenant_id,
      where: l.relationship_type == :potential_conflict,
      where: fragment("(?->>'auto_generated') = 'true'", l.metadata),
      where:
        l.source_article_id == parent_as(:article).id or
          l.target_article_id == parent_as(:article).id,
      where: not exists(conflict_unresolved_subquery()),
      select: 1
    )
  end

  # THE single authority for "this potential_conflict link is still unresolved":
  # correlated on the enclosing `as: :link` binding, TRUE when NO conflict_resolutions
  # row exists for the pair in either direction. Every open-conflict query
  # (open_conflict_subquery/0, article_in_open_conflict?/1, list_potential_conflicts/2)
  # composes THIS so the definition can never drift between paths.
  defp conflict_unresolved_subquery do
    from(r in ConflictResolution,
      where:
        r.tenant_id == parent_as(:link).tenant_id and
          ((r.source_article_id == parent_as(:link).source_article_id and
              r.target_article_id == parent_as(:link).target_article_id) or
             (r.source_article_id == parent_as(:link).target_article_id and
                r.target_article_id == parent_as(:link).source_article_id))
    )
  end

  # AC-31.1.3 tenant precedence, folded into list_curated_sources/2's main scan.
  # Correlated on the outer :article binding: TRUE when the CALLER's tenant OWNS the
  # outer article's topic — i.e. has its OWN curated + published article whose topic
  # (case-insensitive, trimmed title) matches. Evaluated INDEPENDENTLY of open-conflict
  # status: a tenant's disputed-but-owned topic (excluded from the RESULT by the
  # open-conflict filter) STILL suppresses a same-topic system canonical, so ownership
  # is queried directly here rather than derived from the conflict-filtered rows.
  # Applied only to `a.scope == :system` candidates, so tenant-own rows are unaffected.
  # Topic equality uses `lower(btrim(title))` on both sides — the SQL analogue of the
  # documented v1 case-insensitive exact-title key; the partial index
  # `articles_curated_published_idx` bounds the correlated lookup.
  defp tenant_owns_topic_subquery(tenant_id, category) do
    query =
      from(o in Article,
        where: o.tenant_id == ^tenant_id,
        where: o.status == :published,
        where: not is_nil(o.curated_at),
        where: fragment("lower(btrim(?)) = lower(btrim(?))", o.title, parent_as(:article).title),
        select: 1
      )

    case category do
      nil -> query
      cat -> from(o in query, where: o.category == ^cat)
    end
  end

  @doc """
  Authoritative-curated check for a single article (AC-31.1.4).

  Unlike the pure `curated?/1` (status + marker only), this additionally excludes
  an article that is in an OPEN `:potential_conflict` — such an article is NOT
  treated as authoritative until the conflict is surfaced/resolved. Does a DB lookup
  for the open conflict, correlated on the article's globally-unique id. Works for
  BOTH tenant articles and system canonicals (`tenant_id == nil`) — the latter is the
  exact input AC-31.1.3 requires to participate as curated.
  """
  @spec authoritative_curated?(Article.t()) :: boolean()
  def authoritative_curated?(%Article{} = article) do
    curated?(article) and not article_in_open_conflict?(article)
  end

  # TRUE when the article is a member of an unresolved auto-generated
  # :potential_conflict pair. Correlates on the article's globally-unique id ONLY
  # (never `l.tenant_id == ^tenant_id`): a system canonical has `tenant_id == nil`,
  # and Ecto's `==` escaper wraps a pinned nil in a RUNTIME `not_nil!/2` guard that
  # RAISES `ArgumentError: comparing ... with nil is forbidden`. Article ids are UUIDs
  # unique across tenants, so id-only correlation is exactly as scoped as an id+tenant
  # filter would be while also participating for system articles (AC-31.1.3). Mirrors
  # open_conflict_subquery/0 and shares conflict_unresolved_subquery/0.
  defp article_in_open_conflict?(%Article{id: article_id}) do
    query =
      from(l in ArticleLink,
        as: :link,
        where: l.relationship_type == :potential_conflict,
        where: fragment("(?->>'auto_generated') = 'true'", l.metadata),
        where: l.source_article_id == ^article_id or l.target_article_id == ^article_id,
        where: not exists(conflict_unresolved_subquery())
      )

    AdminRepo.exists?(query)
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
        # Visibility scope (#163/#331): an agent archiving via the workflow can only
        # reach an article it can see — another agent's private/owner memory resolves
        # to :not_found (404). Higher roles pass no scope.
        query =
          from(a in Article,
            where: a.id == ^article_id and a.tenant_id == ^tenant_id,
            lock: "FOR UPDATE"
          )
          |> maybe_filter_by_visibility(Keyword.get(opts, :visibility_agent_id))

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

  # Applies the "tenant-wide (nil project) OR this project" scope on the `[a]`
  # (Article) binding, guarding the :binary_id cast. A non-UUID project_id would
  # raise Ecto.Query.CastError on the `== ^project_id` comparison; a malformed
  # value scopes to tenant-wide articles only rather than crashing (callers 4xx
  # at the boundary — this is defense in depth).
  defp scope_project_or_global(query, nil), do: query

  defp scope_project_or_global(query, project_id) do
    if valid_uuid?(project_id) do
      where(query, [a], is_nil(a.project_id) or a.project_id == ^project_id)
    else
      where(query, [a], is_nil(a.project_id))
    end
  end

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
  # re-derivable).
  #
  # US-37.4: this is the truly-bulk background ingest path, so it BATCHES —
  # chunk the published rows into groups of `embedding_batch_max/0` (~100) and
  # enqueue ONE `BatchArticleEmbeddingWorker` per chunk. That worker embeds the
  # whole chunk in a single provider array call (one admission token + one
  # concurrency slot per batch), cutting provider round-trips ~100x vs. the old
  # per-article fan-out. Per-chunk `Oban.insert/1` (NOT `insert_all`) so the
  # worker's `unique:` window is honored — the basic Oban engine ignores `unique:`
  # for `insert_all`.
  #
  # NB: the INTERACTIVE single-article publish path (`maybe_enqueue_embedding/2`)
  # stays on the per-record `ArticleEmbeddingWorker` — batching is only for bulk.
  defp enqueue_bulk_embeddings(_tenant_id, []), do: :ok

  defp enqueue_bulk_embeddings(tenant_id, published) do
    published
    |> Enum.chunk_every(embedding_batch_max())
    |> Enum.each(fn chunk ->
      %{article_ids: Enum.map(chunk, & &1.id), tenant_id: tenant_id}
      |> BatchArticleEmbeddingWorker.new()
      |> Oban.insert()
    end)
  rescue
    e ->
      Logger.error("bulk_publish: embedding enqueue failed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Max number of texts per background embedding array batch (US-37.4).

  DB-backed + live-tunable via `Loopctl.SystemConfig` (`"embedding_batch_max"`); the
  in-code default (#{@default_embedding_batch_max}) matches the seeded row and
  applies on a cache miss. Floored at 1 (a non-positive tuned value can't wedge into
  an empty chunk).

  Respects both provider limits (AC-37.4.4) via TWO caps applied together — the
  worker chunks by the smaller of them, so neither the array size NOR the aggregate
  per-request tokens can overflow:

    * **Per-input token limit** — each text is sliced to 32K chars (~8k tokens) in
      the worker's `build_embedding_text/1`, at/under the embedder's ~8191-token
      per-input window, so no single array element overflows.
    * **Array-size limit (this knob)** — OpenAI-compatible `/embeddings` accepts up
      to ~2048 inputs per request; ~100 keeps each request small and bounds the
      per-batch blast radius on a provider error. Operators can lower this knob live
      (no redeploy).
    * **Cumulative per-request token limit** — `embedding_batch_max_chars/0` bounds
      the SUM of characters across a single array call, so a chunk of many
      large-text articles is sub-split before it can exceed the provider's
      per-request token ceiling. The count cap alone does NOT bound aggregate tokens
      (100 × ~8k tokens ≈ 800k > a ~300k ceiling), which is why this second cap
      exists.
  """
  @spec embedding_batch_max() :: pos_integer()
  def embedding_batch_max do
    "embedding_batch_max"
    |> SystemConfig.get_int(@default_embedding_batch_max)
    |> max(1)
  end

  @doc """
  Cumulative CHARACTER budget for a single background embedding array call (US-37.4,
  AC-37.4.4).

  Bounds the SUM of input characters per provider request, in addition to the
  `embedding_batch_max/0` count cap. `BatchArticleEmbeddingWorker` sub-splits each
  count-chunk so no single array call exceeds this many characters, keeping aggregate
  per-request tokens under an OpenAI-compatible ceiling (~300k tokens) that the count
  cap alone cannot guarantee. DB-backed + live-tunable via `Loopctl.SystemConfig`
  (`"embedding_batch_max_chars"`); the in-code default
  (#{@default_embedding_batch_max_chars}) applies on a cache miss. Floored at
  `@max_text_length` in the worker so a single oversized (already-sliced) input still
  forms its own chunk rather than wedging into an empty one.
  """
  @spec embedding_batch_max_chars() :: pos_integer()
  def embedding_batch_max_chars do
    "embedding_batch_max_chars"
    |> SystemConfig.get_int(@default_embedding_batch_max_chars)
    |> max(1)
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
    # kb-02 DEFENSE IN DEPTH: provenance/score flags are SYSTEM-authored only. Strip them
    # from any caller-supplied metadata before building the changeset so no create_link
    # path (the public API controller AND direct callers like OKF import) can plant the
    # `auto_generated`/`similarity_score` markers that promote_conflicts/1 and
    # validate_potential_conflict_exists/3 trust. System conflict-writers
    # (ArticleLinkingWorker, promote_conflicts) insert via AdminRepo directly, NOT through
    # create_link, so this stripping never touches legitimate system provenance.
    attrs = strip_system_metadata(attrs)
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
  Route-the-findings (#4) review surface: every `:potential_conflict` pair in the
  tenant — articles flagged "too similar to comfortably coexist" by the linker/lint
  sweep, highest-overlap first (most likely a true duplicate). The KB does not decide
  redundancy-vs-contradiction; this is the queue a consumer/human resolves.

  Opts: `:limit` (default 50, clamped to the max page size), `:offset` (default 0).

  Returns `%{data: [%{link_id, similarity, articles: [%{id, title, status, category},
  ...]}], meta: %{limit, offset, total_count}}`.
  """
  @spec list_potential_conflicts(Ecto.UUID.t(), keyword()) :: %{data: [map()], meta: map()}
  def list_potential_conflicts(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(@max_page_size)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    vis = Keyword.get(opts, :visibility_agent_id)

    # The queue shows OPEN conflicts only — a pair a retrieving agent has already
    # ruled on (a `conflict_resolutions` row, either direction) drops out. The
    # source/target Articles are joined into the base (as :source/:target) so both
    # the count and the page can be VISIBILITY-scoped (#331): an agent must not even
    # see — let alone resolve — a pair whose member is another agent's private/owner
    # memory (published memories are conflict-eligible). Higher roles pass no scope.
    base =
      from(l in ArticleLink,
        as: :link,
        join: s in Article,
        as: :source,
        on: s.id == l.source_article_id,
        join: t in Article,
        as: :target,
        on: t.id == l.target_article_id,
        where: l.tenant_id == ^tenant_id,
        where: l.relationship_type == :potential_conflict,
        # kb-02: only surface SYSTEM-flagged conflicts as resolvable evidence, so a stray
        # or legacy non-system potential_conflict row is never presented to a :user.
        where: fragment("(?->>'auto_generated') = 'true'", l.metadata),
        where: not exists(conflict_unresolved_subquery())
      )
      |> filter_conflict_pairs_by_visibility(vis)

    total_count = AdminRepo.aggregate(base, :count, :id)

    rows =
      from([link: l, source: s, target: t] in base,
        order_by: [
          desc: fragment("(?->>'similarity_score')::float", l.metadata),
          asc: l.id
        ],
        limit: ^limit,
        offset: ^offset,
        select: %{
          link_id: l.id,
          similarity: fragment("(?->>'similarity_score')::float", l.metadata),
          source: %{id: s.id, title: s.title, status: s.status, category: s.category},
          target: %{id: t.id, title: t.title, status: t.status, category: t.category}
        }
      )
      |> AdminRepo.all()

    data =
      Enum.map(rows, fn r ->
        %{link_id: r.link_id, similarity: r.similarity, articles: [r.source, r.target]}
      end)

    %{data: data, meta: %{limit: limit, offset: offset, total_count: total_count}}
  end

  # Visibility predicate for the conflict queue: BOTH members of a pair must be
  # visible to an agent caller (shared/non-memory, or owned by the caller). nil
  # (higher role) → no filter. Mirrors maybe_filter_by_visibility/2 but applied to
  # the two named article bindings at once.
  defp filter_conflict_pairs_by_visibility(query, nil), do: query

  defp filter_conflict_pairs_by_visibility(query, agent_id) when is_binary(agent_id) do
    from([source: s, target: t] in query,
      where:
        (fragment("COALESCE(?->>'visibility', 'shared') NOT IN ('private','owner')", s.metadata) or
           fragment("?->>'agent_id' = ?", s.metadata, ^agent_id)) and
          (fragment("COALESCE(?->>'visibility', 'shared') NOT IN ('private','owner')", t.metadata) or
             fragment("?->>'agent_id' = ?", t.metadata, ^agent_id))
    )
  end

  @doc """
  Record a retrieving agent's VERDICT on a potential-conflict pair (route-the-findings
  #4). The agent judges with live context; the KB never re-judges. Non-destructive: this
  writes only a `conflict_resolutions` row (last-write-wins per pair), so it's safe at
  agent role.

  Dispositions:

    * `:dismiss` — a false positive (the two don't actually conflict). Takes effect
      immediately: the pair drops out of the conflict queue and the nightly sweep won't
      re-surface it.
    * `:supersede` — one article wins; the loser should be retired. Requires
      `authoritative_article_id` (the winner, one of the pair). Applied by the nightly
      executor when `confidence: :high` — it creates a `supersedes` link and transitions
      the loser to `:superseded` (reversible + audited).
    * `:merge` — recorded for the later LLM-synthesis step; not executed here.

  `attrs`: `source_article_id`, `target_article_id` (any order), `disposition`, and
  optionally `authoritative_article_id`, `classification`, `evidence`, `confidence`
  (default `:medium`). Returns `{:ok, %ConflictResolution{}}` or `{:error, changeset}`.
  """
  @spec annotate_conflict(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ConflictResolution.t()}
          | {:error, Ecto.Changeset.t() | :no_potential_conflict}
  def annotate_conflict(tenant_id, attrs, opts \\ []) do
    get = fn key -> attrs[key] || attrs[to_string(key)] end
    {src, tgt} = canonical_pair(get.(:source_article_id), get.(:target_article_id))

    # kb-02 (GHSA-9gqg-9r6p-658v): a verdict may only be recorded against a REAL,
    # system-flagged conflict. Without this guard an agent could fabricate a verdict
    # on ANY two in-tenant articles and have the nightly executor retire/merge one of
    # them. Require a `:potential_conflict` ArticleLink for the pair (the linker/lint
    # sweep flags these; stored in either direction) BEFORE accepting any disposition.
    #
    # Visibility parity (#331): an agent caller may only record a verdict on a pair
    # whose BOTH members it can see. Without this, agent A could resolve a flagged
    # pair whose member is agent B's private/owner memory and have the executor
    # retire it (supersede) or LLM-synthesize its content into a new draft (merge —
    # cross-agent private disclosure). Checked FIRST and returning the same
    # :no_potential_conflict as an unflagged pair, so an agent can't probe which
    # private ids exist. Higher roles pass no scope and see everything.
    with :ok <-
           validate_pair_visible(tenant_id, src, tgt, Keyword.get(opts, :visibility_agent_id)),
         :ok <- validate_potential_conflict_exists(tenant_id, src, tgt) do
      disposition = get.(:disposition)
      now = DateTime.utc_now()

      row_attrs = %{
        source_article_id: src,
        target_article_id: tgt,
        authoritative_article_id: get.(:authoritative_article_id),
        classification: get.(:classification),
        disposition: disposition,
        confidence: get.(:confidence) || :medium,
        evidence: get.(:evidence),
        annotated_by: Keyword.get(opts, :actor_label) || Keyword.get(opts, :actor_id),
        annotated_at: now,
        # A dismiss is complete on record; supersede/merge defer to the executor.
        # Compare without to_string/1 so a non-scalar disposition (e.g. a JSON object)
        # can't raise here — it falls through to the changeset's inclusion validation.
        executed_at: if(disposition in ["dismiss", :dismiss], do: now, else: nil),
        execution_result: %{}
      }

      changeset =
        %ConflictResolution{tenant_id: tenant_id}
        |> ConflictResolution.changeset(row_attrs)

      result =
        AdminRepo.insert(changeset,
          on_conflict:
            {:replace,
             [
               :authoritative_article_id,
               :classification,
               :disposition,
               :confidence,
               :evidence,
               :annotated_by,
               :annotated_at,
               :executed_at,
               :execution_result,
               :updated_at
             ]},
          conflict_target: [:tenant_id, :source_article_id, :target_article_id]
        )

      with {:ok, %ConflictResolution{disposition: :dismiss} = res} <- result do
        log_resolution(
          tenant_id,
          res,
          "dismiss",
          "dismissed as #{res.classification || "not-a-conflict"}",
          [res.source_article_id, res.target_article_id]
        )
      end

      result
    end
  end

  # Visibility parity for conflict resolution (#331). nil (higher role) → no check.
  # For an agent caller, BOTH pair members must be visible (reusing visible_article_ids/3,
  # the same helper the change feed uses); otherwise the verdict is refused as if the
  # pair were never flagged (:no_potential_conflict → 422), so an agent can neither act
  # on nor probe another agent's private/owner memory. A missing/non-binary id is left
  # to validate_potential_conflict_exists + the changeset's required-field validation.
  defp validate_pair_visible(tenant_id, src, tgt, agent_id)
       when is_binary(agent_id) and is_binary(src) and is_binary(tgt) do
    visible = visible_article_ids(tenant_id, [src, tgt], agent_id)

    if MapSet.member?(visible, src) and MapSet.member?(visible, tgt) do
      :ok
    else
      {:error, :no_potential_conflict}
    end
  end

  defp validate_pair_visible(_tenant_id, _src, _tgt, _agent_id), do: :ok

  # kb-02: true only when the linker/lint sweep actually flagged this pair as a
  # potential conflict (link stored in either direction). When an id is missing we
  # return :ok and defer to the changeset's required-field validation (surfaces as a
  # 422) rather than masking a malformed request as "no conflict".
  #
  # PROVENANCE (kb-02 FIX A, defense in depth): require the flag to be SYSTEM-generated
  # (`metadata.auto_generated == true`), the marker both writer sites set —
  # `KnowledgeLintWorker.promote_conflicts/1` and `ArticleLinkingWorker`. Presence of a
  # `:potential_conflict` link alone is NOT sufficient evidence: even though the public
  # link controller now refuses to create that type, requiring the provenance marker
  # means no future/alternate path that plants such a link can be leveraged to fabricate
  # a destructive verdict.
  defp validate_potential_conflict_exists(tenant_id, src, tgt)
       when is_binary(src) and is_binary(tgt) do
    exists? =
      from(l in ArticleLink,
        where: l.tenant_id == ^tenant_id,
        where: l.relationship_type == :potential_conflict,
        where: fragment("(?->>'auto_generated') = 'true'", l.metadata),
        where:
          (l.source_article_id == ^src and l.target_article_id == ^tgt) or
            (l.source_article_id == ^tgt and l.target_article_id == ^src)
      )
      |> AdminRepo.exists?()

    if exists?, do: :ok, else: {:error, :no_potential_conflict}
  end

  defp validate_potential_conflict_exists(_tenant_id, _src, _tgt), do: :ok

  @doc """
  Nightly executor for conflict resolutions (route-the-findings #4). Applies only
  high-confidence, not-yet-executed rows — all reversible/non-destructive and audited:

    * `:supersede` — reuses `create_link/3` to create a `supersedes` link (winner → loser)
      and transition the loser to `:superseded` (reversible).
    * `:merge` — the LLM synthesizes a merged article (step 2); it lands as a **draft**
      (never auto-published) with both sources preserved and `merged_from` metadata, plus
      `relates_to` links to the sources. On synthesis failure the row is left for retry.

  `:dismiss` needs no execution (recorded complete on annotate). Bounded per run via
  `opts[:limit]`. Returns the count applied.
  """
  # Default wall-clock budget for ONE executor run. `:merge` rows each make an LLM
  # synthesis call (up to ~110s worst case with the merge client's 55s x 1-retry
  # budget), so an unbounded 200-row loop could pin a shared `:knowledge` queue slot
  # for hours and starve other tenants' ingestion/review/reclassify jobs (review #4).
  # A run applies rows until this budget elapses; the remainder (still
  # `executed_at IS NULL`) is picked up by the next nightly run. Config-overridable.
  @default_execute_budget_ms 120_000

  @spec execute_conflict_resolutions(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def execute_conflict_resolutions(tenant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    budget_ms = Keyword.get(opts, :budget_ms, execute_budget_ms())
    deadline = System.monotonic_time(:millisecond) + budget_ms

    rows =
      from(r in ConflictResolution,
        where: r.tenant_id == ^tenant_id,
        where: is_nil(r.executed_at),
        where: r.disposition in [:supersede, :merge],
        where: r.confidence == :high,
        # Deterministic OLDEST-first order (review round 4): without it Postgres can
        # return the same subset in the same arbitrary order every run, so a backlog
        # that exceeds the wall-clock budget would forever apply the same head rows and
        # NEVER reach the tail (permanently stuck at executed_at IS NULL, contradicting
        # the "remainder picked up next run" invariant). Oldest-first guarantees each
        # budgeted run makes forward progress toward the tail; the `id` tiebreaker keeps
        # the order TOTAL across equal `inserted_at` so no row is ever indefinitely skipped.
        order_by: [asc: r.inserted_at, asc: r.id],
        limit: ^limit
      )
      |> AdminRepo.all()

    Enum.reduce_while(rows, 0, fn r, count ->
      if System.monotonic_time(:millisecond) >= deadline do
        Logger.info(
          "ConflictExecutor: tenant=#{tenant_id} hit the #{budget_ms}ms execute budget " <>
            "after #{count} resolution(s); remainder left for the next run."
        )

        {:halt, count}
      else
        {:cont, if(apply_resolution(tenant_id, r), do: count + 1, else: count)}
      end
    end)
  end

  defp execute_budget_ms do
    Application.get_env(
      :loopctl,
      :knowledge_conflict_execute_budget_ms,
      @default_execute_budget_ms
    )
  end

  # kb-02 FIX B (TOCTOU): the flag is checked at annotate time, but a :user may DELETE
  # the potential_conflict link (retracting a mistaken flag) after the verdict is
  # recorded and before the nightly run. Re-validate the SYSTEM flag still exists right
  # before acting; if it was retracted, noop (audited) instead of retiring/merging.
  defp apply_resolution(tenant_id, %ConflictResolution{} = r) do
    case validate_potential_conflict_exists(tenant_id, r.source_article_id, r.target_article_id) do
      :ok ->
        apply_disposition(tenant_id, r)

      {:error, :no_potential_conflict} ->
        mark_resolution_executed(r, %{
          "action" => "noop",
          "reason" => "potential_conflict flag retracted"
        })

        false
    end
  end

  defp apply_disposition(tenant_id, %ConflictResolution{disposition: :supersede} = r),
    do: apply_supersede(tenant_id, r)

  defp apply_disposition(tenant_id, %ConflictResolution{disposition: :merge} = r),
    do: apply_merge(tenant_id, r)

  # The conflict pair is unordered; store it canonically (source <= target by UUID
  # string) so one row covers (A,B) and (B,A).
  defp canonical_pair(a, b) when is_binary(a) and is_binary(b) and a > b, do: {b, a}
  defp canonical_pair(a, b), do: {a, b}

  defp apply_supersede(tenant_id, %ConflictResolution{} = r) do
    winner = r.authoritative_article_id
    loser = if winner == r.source_article_id, do: r.target_article_id, else: r.source_article_id

    result =
      create_link(
        tenant_id,
        %{
          source_article_id: winner,
          target_article_id: loser,
          relationship_type: "supersedes"
        },
        actor_type: "system",
        actor_label: "worker:conflict_executor"
      )

    case result do
      {:ok, _link} ->
        mark_resolution_executed(r, %{
          "action" => "superseded",
          "winner" => winner,
          "loser" => loser
        })

        log_resolution(
          tenant_id,
          r,
          "supersede",
          "\"#{title_of(loser)}\" retired for \"#{title_of(winner)}\"",
          [
            winner,
            loser
          ]
        )

        true

      # Already superseded / link exists → the disposition is effectively done; record
      # and stop retrying. Any other error also stops (bad annotation), captured for review.
      {:error, reason} ->
        mark_resolution_executed(r, %{"action" => "noop", "reason" => inspect(reason)})
        false
    end
  end

  defp apply_merge(tenant_id, %ConflictResolution{} = r) do
    # Mandatory BYO (Epic 28, #179): merge synthesis runs on the tenant's OWN
    # Anthropic key. Without one, DON'T silently retry every run — mark the
    # resolution executed with a DISTINCT, queryable "skipped/no_api_key" marker
    # (not a false "merged" state) and record the block (review #10).
    if Loopctl.Llm.has_api_key?(tenant_id) do
      merge_source_articles(tenant_id, r)
    else
      Loopctl.Llm.record_blocked(tenant_id, :merge)
      mark_resolution_executed(r, %{"action" => "skipped", "reason" => "no_api_key"})
      false
    end
  end

  defp merge_source_articles(tenant_id, %ConflictResolution{} = r) do
    a = AdminRepo.get_by(Article, id: r.source_article_id, tenant_id: tenant_id)
    b = AdminRepo.get_by(Article, id: r.target_article_id, tenant_id: tenant_id)

    if is_nil(a) or is_nil(b) do
      mark_resolution_executed(r, %{"action" => "noop", "reason" => "source missing"})
      false
    else
      do_merge(tenant_id, r, a, b)
    end
  end

  defp do_merge(tenant_id, r, a, b) do
    case merge_synthesizer().synthesize(
           tenant_id,
           %{title: a.title, body: a.body},
           %{title: b.title, body: b.body}
         ) do
      {:ok, %{title: title, body: body}} ->
        create_merged_draft(tenant_id, r, a, title, body)

      {:error, reason} ->
        handle_merge_error(r, reason)
    end
  end

  # PERMANENT synthesis errors (non-408/429 4xx, unparseable output) must NOT be
  # left to retry every nightly run — that re-bills the tenant's paid Anthropic
  # call each time (review #6). Mark them executed with a distinct queryable
  # `failed` result. TRANSIENT errors (5xx/408/429/request_failed) are left
  # unexecuted so a later run legitimately retries. NEVER draft a placeholder.
  defp handle_merge_error(%ConflictResolution{} = r, reason) do
    if permanent_merge_error?(reason) do
      Logger.warning(
        "ConflictExecutor: merge synthesis PERMANENTLY failed for #{r.id} " <>
          "(#{inspect(reason)}); marking failed (not retrying)."
      )

      mark_resolution_executed(r, %{"action" => "failed", "reason" => inspect(reason)})
    else
      Logger.warning(
        "ConflictExecutor: merge synthesis transiently failed for #{r.id} " <>
          "(#{inspect(reason)}); leaving for retry."
      )
    end

    false
  end

  defp permanent_merge_error?(:unparseable_merge), do: true

  # US-37.3: a throttle 4-tuple (429/503 + Retry-After) is transient — it must NOT
  # match the permanent 4xx clause below (that clause is arity-3 only, but be
  # explicit so the widened shape can never be misclassified as permanent).
  defp permanent_merge_error?({:api_error, _status, _tag, _retry_after}), do: false

  defp permanent_merge_error?({:api_error, status, _body})
       when is_integer(status) and status >= 400 and status < 500 and status != 408 and
              status != 429,
       do: true

  defp permanent_merge_error?(_), do: false

  defp create_merged_draft(tenant_id, r, source_a, title, body) do
    attrs = %{
      title: title,
      body: body,
      category: source_a.category,
      status: :draft,
      tags: ["merged"],
      metadata: %{
        "merged_from" => [r.source_article_id, r.target_article_id],
        "conflict_resolution_id" => r.id
      }
    }

    opts = [actor_type: "system", actor_label: "worker:conflict_executor"]

    case create_article(tenant_id, attrs, opts) do
      {:ok, draft} ->
        Enum.each([r.source_article_id, r.target_article_id], fn src ->
          create_link(
            tenant_id,
            %{
              source_article_id: draft.id,
              target_article_id: src,
              relationship_type: "relates_to"
            },
            opts
          )
        end)

        mark_resolution_executed(r, %{"action" => "merged_draft", "draft_id" => draft.id})

        log_resolution(tenant_id, r, "merge", "drafted \"#{draft.title}\" from 2 sources", [
          draft.id,
          r.source_article_id,
          r.target_article_id
        ])

        true

      # A draft with this title already exists (likely a prior run) — stop retrying.
      {:error, :duplicate_title, existing} ->
        mark_resolution_executed(r, %{
          "action" => "noop",
          "reason" => "title_exists",
          "existing" => existing.id
        })

        false

      other ->
        Logger.warning(
          "ConflictExecutor: merge draft create failed for #{r.id}: #{inspect(other)}"
        )

        false
    end
  end

  defp merge_synthesizer do
    Application.get_env(:loopctl, :merge_synthesizer, Loopctl.Knowledge.ClaudeMergeSynthesizer)
  end

  defp mark_resolution_executed(%ConflictResolution{} = r, execution_result) do
    r
    |> Ecto.Changeset.change(executed_at: DateTime.utc_now(), execution_result: execution_result)
    |> AdminRepo.update()
  end

  # Concise curation-log line for a conflict resolution (no-ops unless the tenant has
  # kb_curation_log on). `refs` are the article ids involved; actor/confidence come from
  # the recorded verdict.
  defp log_resolution(tenant_id, %ConflictResolution{} = r, kind, summary, refs) do
    KbCuration.record(tenant_id, kind, summary,
      refs: refs,
      actor: r.annotated_by,
      confidence: r.confidence && to_string(r.confidence)
    )
  end

  defp title_of(article_id) do
    case AdminRepo.get(Article, article_id) do
      %Article{title: title} -> title
      _ -> article_id
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
  the indexed path.

  ## Recall ceiling + the under-fill signal (US-27.6b)

  Recall is bounded by `hnsw.ef_search` (pgvector **default ~40**) AND the over-fetch
  pool — see the `Loopctl.Knowledge.VectorSearch` moduledoc for the full ceiling
  discussion (why `ef_search` can't be raised via Postgrex `:parameters`, and that
  `ALTER ROLE … SET hnsw.ef_search` is the only safe non-transaction lever, US-27.11).
  Until that is verified on fly mpg, recall stays at the default and under-fill is made
  **observable**: use `suggest_links_with_meta/3` (the variant the endpoint calls) — it
  returns a `meta` flag `recall_truncated`/`pool_exhausted` AND emits a
  `[:loopctl, :knowledge, :vector_search, :under_fill]` telemetry event (once per
  request) whenever the nearest pool was filled to cap but the anti-join / threshold cut
  the result below `:limit`. That distinguishes an INCOMPLETE result from a
  genuinely-empty corpus — the silent-recall failure this story closes.

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
    # Back-compat 2-tuple shape (the original contract). Delegates to the
    # meta-bearing variant and drops the meta — callers that don't need the
    # under-fill signal (and the plan/EXPLAIN scale tests) keep `{:ok, list}`.
    case suggest_links_with_meta(tenant_id, article_id, opts) do
      {:ok, suggestions, _meta} -> {:ok, suggestions}
      other -> other
    end
  end

  @doc """
  Like `suggest_links/3`, but also returns a `meta` map describing recall
  completeness for the consumer (US-27.6b AC-27.6b.6).

  The endpoint controller calls THIS so an agent can distinguish an *incomplete*
  result (the densely-linked-hub case: the nearest pool was filled to cap but the
  already-linked anti-join / threshold cut it below the requested limit) from a
  *genuinely-empty* one (the corpus simply has fewer than `limit` eligible
  neighbors). The same condition emits the
  `[:loopctl, :knowledge, :vector_search, :under_fill]` telemetry event exactly
  once per request (see `suggestion_candidates/6`).

  ## Returns

    * `{:ok, [%{id, title, category, similarity_score}], meta}` where `meta` is:

          %{
            requested: limit,         # the requested limit (post-clamp)
            returned: length(result), # how many candidates came back
            pool: pool_size,          # the inner over-fetch pool
            # true when returned < requested AND the pool was filled to cap
            # (filters exhausted a FULL pool) — i.e. recall is incomplete:
            pool_exhausted: boolean,
            recall_truncated: boolean # alias of pool_exhausted (consumer-facing name)
          }

    * `{:ok, [], meta}` when the article has no embedding yet (`pool_exhausted: false`)
    * `{:error, :not_found}` / `{:error, :invalid_threshold}` as `suggest_links/3`
  """
  @impl Loopctl.Knowledge.SuggestLinksBehaviour
  @spec suggest_links_with_meta(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, [map()], map()} | {:error, :not_found} | {:error, :invalid_threshold}
  def suggest_links_with_meta(tenant_id, article_id, opts \\ []) do
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
          {:ok, [], empty_suggestion_meta(limit)}

        %{embedding: embedding} ->
          {suggestions, meta} =
            suggestion_candidates(tenant_id, article_id, embedding, threshold, limit, vis)

          {:ok, suggestions, meta}
      end
    end
  end

  # Meta for the no-embedding short-circuit: a 0-result is NOT under-fill (there is
  # no pool to fill), so the consumer must see `pool_exhausted: false`.
  defp empty_suggestion_meta(limit) do
    %{
      requested: limit,
      returned: 0,
      pool: suggestion_candidate_pool(limit),
      pool_exhausted: false,
      recall_truncated: false
    }
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
    # isolated from the small AdminRepo pool, with a per-read SET LOCAL
    # statement_timeout (US-27.13 — a short transaction, the connection released at
    # commit). The wrapper structurally requires a tenant_id-filtered query; the
    # tenant predicate lives in this query's inner subquery. The 15s client timeout
    # is a backstop above the server-side statement_timeout.
    query = suggestion_candidates_query(tenant_id, article_id, embedding, threshold, limit, vis)
    suggestions = HeavyRead.all(tenant_id, query, heavy_read_opts(:suggested_links))

    pool = suggestion_candidate_pool(limit)
    returned = length(suggestions)

    meta =
      maybe_signal_under_fill(
        tenant_id,
        article_id,
        embedding,
        threshold,
        vis,
        limit,
        pool,
        returned
      )

    {suggestions, meta}
  end

  # Under-fill signal (US-27.6b AC-27.6b.2/.5/.6). Builds the response `meta` and —
  # only when recall is genuinely truncated — emits ONE telemetry event per request.
  #
  # THE KEY DISTINCTION (the whole point of the story, per its background: "returns []
  # while near neighbors EXIST"): the recall incident is when above-threshold (near)
  # neighbors the ANN surfaced were hidden by the already-linked anti-join. We emit when:
  #
  #   recall_truncated = returned < limit
  #                      AND above_threshold > returned
  #
  # where `above_threshold` is how many of the candidates the inner ANN delivered clear
  # the similarity bar (IGNORING link status). Because the signal only fires when
  # `returned < limit` (so the outer LIMIT never bound and every unlinked above-threshold
  # candidate WAS returned), `above_threshold > returned` means above-threshold neighbors
  # were cut by the ANTI-JOIN specifically — a true recall incident.
  #
  # This is what stops the signal crying wolf on a SPARSE article whose whole ANN pool is
  # below the similarity threshold: that is correct emptiness (nothing clears the bar), so
  # `above_threshold == returned == 0` and we do NOT fire. The earlier `available >= pool`
  # gate was abandoned: under HNSW the inner ANN only inspects ~`ef_search` (~40) graph
  # nodes, so it delivers FEWER than `pool` (e.g. 100) candidates even on a huge corpus —
  # an `ann_candidates >= pool` check is therefore degenerate (essentially never true at
  # the default ef_search) and silently SUPPRESSED the signal at prod scale. The
  # above-threshold detector is ef_search-independent: it compares two counts over the
  # exact set the ANN actually surfaced.
  #
  # Both counts come from ONE bounded probe over the SAME inner ANN pool the main query
  # drew from — see `under_fill_probe/6`. When `returned >= limit` there is nothing to
  # detect, so we skip the probe entirely (zero added cost on the common full path).
  defp maybe_signal_under_fill(
         tenant_id,
         article_id,
         embedding,
         threshold,
         vis,
         limit,
         pool,
         returned
       ) do
    base = %{requested: limit, returned: returned, pool: pool}
    not_truncated = Map.merge(base, %{pool_exhausted: false, recall_truncated: false})

    if returned < limit do
      case under_fill_probe(tenant_id, article_id, embedding, threshold, vis, pool) do
        # The probe is ADVISORY: its read failing (connection drop / statement_timeout)
        # must NOT fail a request whose suggestions are already in hand. Degrade to "no
        # truncation signal" rather than discarding a valid result (security review,
        # AREA-5 fail-soft).
        :error ->
          not_truncated

        {ann_candidates, above_threshold} ->
          resolve_under_fill(
            base,
            tenant_id,
            limit,
            pool,
            returned,
            ann_candidates,
            above_threshold
          )
      end
    else
      not_truncated
    end
  end

  # The truncated-path verdict: recall is genuinely truncated when above-threshold (near)
  # neighbors the ANN surfaced outnumber what was returned (`above_threshold > returned`)
  # — i.e. the anti-join hid real neighbors, NOT a sparse region. Emits the signal exactly
  # once when so, and returns the consumer-facing `meta`.
  defp resolve_under_fill(base, tenant_id, limit, pool, returned, ann_candidates, above_threshold) do
    recall_truncated? = above_threshold > returned

    if recall_truncated? do
      emit_under_fill(tenant_id, limit, pool, returned, ann_candidates, above_threshold)
    end

    Map.merge(base, %{pool_exhausted: recall_truncated?, recall_truncated: recall_truncated?})
  end

  # ONE telemetry event + warn log per truncated request (AC-27.6b.2/.5). When
  # `returned < limit` the outer LIMIT never bound, so EVERY unlinked above-threshold
  # candidate in the pool WAS returned; therefore `above_threshold - returned` is EXACTLY
  # the above-threshold neighbors the already-linked anti-join hid — an UN-CONFLATED
  # recall-loss count (no extra read, no separate threshold component to disentangle).
  # This is the metric US-27.15 aggregates; see
  # `Loopctl.TelemetryEvents.vector_search_under_fill/0`. `ann_candidates` is the
  # ef_search-bounded count the ANN delivered — a recall-breadth diagnostic.
  defp emit_under_fill(tenant_id, limit, pool, returned, ann_candidates, above_threshold) do
    excluded_by_link = above_threshold - returned

    :telemetry.execute(
      Loopctl.TelemetryEvents.vector_search_under_fill(),
      %{
        requested: limit,
        returned: returned,
        pool: pool,
        ann_candidates: ann_candidates,
        above_threshold: above_threshold,
        excluded_by_link: excluded_by_link
      },
      %{
        tenant_id: tenant_id,
        endpoint: :suggested_links
      }
    )

    Logger.warning(
      "knowledge.vector_search under_fill endpoint=suggested_links tenant_id=#{tenant_id} " <>
        "requested=#{limit} returned=#{returned} pool=#{pool} ann_candidates=#{ann_candidates} " <>
        "above_threshold=#{above_threshold} excluded_by_link=#{excluded_by_link}"
    )
  end

  # Bounded under-fill probe (US-27.6b). Over the SAME inner ANN top-`pool` subquery the
  # main query draws from (so the candidate set is identical by construction), it returns
  # in ONE read:
  #
  #   * `ann_candidates`  = COUNT(*) of the rows the inner ANN actually delivered — bounded
  #     by `LIMIT pool` AND, under HNSW, by `~ef_search` (~40), so it doubles as a
  #     recall-breadth diagnostic (NOT a `>= pool` pool-full gate — see
  #     `maybe_signal_under_fill/8`). Touches at most `pool` rows (≤ `max_vector_pool`).
  #   * `above_threshold` = COUNT(*) FILTER (similarity_score > threshold) over that same
  #     delivered set — "do near (above-the-relevance-bar) neighbors actually exist?" — the
  #     signal that separates a real recall incident from a genuinely-sparse region
  #     (AC-27.6b.6).
  #
  # Runs on the SAME dedicated heavy-read pool, ONLY on the `returned < limit` path (one
  # bounded extra ANN-class read; the full-result path issues none), and carries NO vector
  # / body data. Returns `:error` (NOT raising) on a DB connectivity / timeout fault so the
  # caller can fail-soft — a genuine query bug still surfaces (we re-raise non-cancel
  # Postgrex errors).
  defp under_fill_probe(tenant_id, article_id, embedding, threshold, vis, pool) do
    candidates = suggestion_candidates_inner(tenant_id, article_id, embedding, vis, pool)

    probe =
      from(c in subquery(candidates),
        select: %{
          ann_candidates: count(c.id),
          above_threshold:
            fragment("COUNT(*) FILTER (WHERE ? > ?)", c.similarity_score, ^threshold)
        }
      )

    case HeavyRead.one(tenant_id, probe, heavy_read_opts(:suggested_links)) do
      %{ann_candidates: a, above_threshold: t} -> {a || 0, t || 0}
      nil -> {0, 0}
    end
  rescue
    e in DBConnection.ConnectionError ->
      Logger.warning(
        "knowledge.vector_search under_fill probe degraded (connection); suggestions returned: " <>
          Exception.message(e)
      )

      :error

    e in Postgrex.Error ->
      # Degrade ONLY on a server-side cancel (statement_timeout); re-raise anything else
      # (e.g. a malformed query) so genuine bugs surface in tests instead of silently
      # becoming a missing signal.
      if match?(%{postgres: %{code: :query_canceled}}, e) do
        Logger.warning(
          "knowledge.vector_search under_fill probe degraded (timeout); suggestions returned: " <>
            Exception.message(e)
        )

        :error
      else
        reraise(e, __STACKTRACE__)
      end
  end

  @doc false
  # Per-read options for a heavy endpoint (US-27.4). Delegates to the single source of
  # truth, `Loopctl.HeavyRead.opts/1`, so the opts shape can't drift between callers
  # (Knowledge / Audit). Public-but-`@doc false` so the slow-query telemetry test can
  # exercise the real opts-building path (incl. the override branch) through this name.
  def heavy_read_opts(endpoint), do: HeavyRead.opts(endpoint)

  # Builds the suggested-links candidate query (returned, not executed) so a test can
  # assert its SQL shape. Public-but-`@doc false` for that structural regression guard.
  #
  # US-27.7a: this now routes through the shared, scale-tested kNN helper
  # `Loopctl.Knowledge.VectorSearch.candidate_query/4` instead of a bespoke cosine query,
  # so the index-correct shape is enforced in ONE place and a future edit here can't
  # reintroduce the #170/#172 full scan. The verified shape is unchanged: the INNER pure
  # ANN (`ORDER BY embedding <=> $const LIMIT pool`, only index-safe residual filters) is
  # `VectorSearch.candidate_pool_query/4`, wrapped by an OUTER over-the-pool query carrying
  # the already-linked anti-join (both directions), the `similarity_score > threshold`
  # floor, the `order_by similarity desc`, and the final `limit`. The target is bound as a
  # `[float()]` LIST param (never the stored `%Pgvector{}` struct — the #168 500). `pool` is
  # the SAME `suggestion_candidate_pool/1` value as before (passed as `:pool`), so the
  # over-fetch is byte-identical to the pre-migration sizing.
  @doc false
  def suggestion_candidates_query(tenant_id, article_id, embedding, threshold, limit, vis) do
    VectorSearch.candidate_query(tenant_id, embedding, limit,
      exclude_id: article_id,
      exclude_linked: true,
      threshold: threshold,
      visibility_agent_id: vis,
      pool: suggestion_candidate_pool(limit)
    )
  end

  # The inner ANN top-`pool` subquery, SHARED by the main suggestion query and the
  # under-fill probe so their candidate set is identical BY CONSTRUCTION (no drift). It
  # delegates to the helper's `VectorSearch.candidate_pool_query/4` — the SAME inner
  # `candidate_query/4` builds — so the probe counts over EXACTLY the rows the main
  # suggestion query drew from (the US-27.6b under-fill invariant). It is the pure
  # top-`pool` nearest-by-cosine with only index-safe filters (tenant / status /
  # not-null / not-self / visibility) and the computed `similarity_score`. The
  # anti-join + threshold + final `limit` are applied by the OUTER query.
  defp suggestion_candidates_inner(tenant_id, article_id, embedding, vis, pool) do
    VectorSearch.candidate_pool_query(tenant_id, embedding, pool,
      exclude_id: article_id,
      visibility_agent_id: vis
    )
  end

  # Over-fetch factor for the inner ANN subquery: pull this many nearest candidates from
  # the HNSW index before the outer query applies the anti-join + threshold and trims to
  # `limit`. Scales with `limit` (headroom for exclusions), floored for the common small
  # `limit`, and capped so the index scan stays cheap.
  #
  # The factor/floor/cap are the SAME config constants the shared `VectorSearch` helper
  # reads (US-27.6b AC-27.6b.1), so the live `suggested_links` path and the shared kNN
  # helper never size their pools differently. `:max_suggestion_candidate_pool` is still
  # honored as a back-compat alias for the cap when set.
  defp suggestion_candidate_pool(limit) do
    VectorSearch.pool_size(limit,
      cap: Application.get_env(:loopctl, :max_suggestion_candidate_pool)
    )
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
  link graph (directly, or via a shared neighbor — ≤2 hops) are returned; that branch
  samples a smaller #{@max_bridge_pair_candidates}-article slice, because its per-pair
  graph EXISTS defeats the page's early termination and would otherwise blow the <2s
  budget on band-distant (rarely-bridged) pairs.

  ## Parameters

  - `opts` -- `:min_distance` (default 0.3), `:max_distance` (default 0.7),
    `:bridge_path` (default false), `:limit` (default #{@default_pair_limit},
    max #{@max_pair_limit}), `:offset`.

  ## Returns

  - `{:ok, %{pairs: [...], has_more: boolean}}` — `has_more` is a `limit + 1`
    look-ahead flag. NO exact total-pair count is returned: an exact count cannot
    early-terminate (it must evaluate the `<=>` for every one of the
    O(candidates²) sampled pairs), and profiling at prod scale (#202/#203) showed
    that full count pass — not the paginated read — was the entire latency cost.
    Page with `has_more` instead.
  - `{:error, :invalid_distance}` when the band is outside 0.0–2.0 or min > max
  """
  @spec distant_pairs(Ecto.UUID.t(), keyword()) ::
          {:ok, %{pairs: [map()], has_more: boolean()}}
          | {:error, :invalid_distance}
  def distant_pairs(tenant_id, opts \\ []) do
    min_d = Keyword.get(opts, :min_distance, 0.3)
    max_d = Keyword.get(opts, :max_distance, 0.7)
    limit = opts |> Keyword.get(:limit, @default_pair_limit) |> max(1) |> min(@max_pair_limit)
    offset = opts |> Keyword.get(:offset, 0) |> max(0) |> min(max_pair_offset())
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

  # Operator-tunable cap on the sampled candidate set (bounds the O(n²) self-join). The
  # bridge branch uses a smaller cap because its per-pair link-graph EXISTS defeats the
  # page's early termination (see @max_bridge_pair_candidates).
  defp max_pair_candidates do
    Application.get_env(:loopctl, :max_pair_candidates, @max_pair_candidates)
  end

  defp max_bridge_pair_candidates do
    Application.get_env(:loopctl, :max_bridge_pair_candidates, @max_bridge_pair_candidates)
  end

  # The COMPILE-TIME default caps (the module-attribute constants, config-independent). The
  # OpenAPI operation doc interpolates these so the numbers in the description can never drift
  # from the code (#202/#203 review, LOW-9). Public (`@doc false`) only so the controller can
  # reference them at compile time.
  @doc false
  def default_max_pair_candidates, do: @max_pair_candidates

  @doc false
  def default_max_bridge_pair_candidates, do: @max_bridge_pair_candidates

  # Operator-tunable upper bound on the `:offset` (#202/#203 MED-5).
  defp max_pair_offset do
    Application.get_env(:loopctl, :max_pair_offset, @max_pair_offset)
  end

  # #202/#203 MED-7 invariant: the effective bridge cap NEVER exceeds the general cap, so a
  # misconfigured larger bridge cap can't make `bridge_path` slower than the non-bridge path
  # it is meant to bound. Pure + public (`@doc false`) so the clamp is unit-testable without
  # `Application.put_env` (config-based DI — no put_env in tests).
  @doc false
  def effective_bridge_candidate_cap(bridge_cap, general_cap)
      when is_integer(bridge_cap) and is_integer(general_cap),
      do: min(bridge_cap, general_cap)

  # The sample cap for THIS request: the (clamped) smaller bridge cap when `bridge_path` is
  # on, else the full cap.
  defp pair_candidate_cap(true),
    do: effective_bridge_candidate_cap(max_bridge_pair_candidates(), max_pair_candidates())

  defp pair_candidate_cap(false), do: max_pair_candidates()

  # Column-to-column self-join: `(a.embedding <=> b.embedding) BETWEEN $min AND $max` over
  # a `LIMIT pair_candidate_cap(bridge?)` SAMPLED subquery. There is NO `$const` target
  # vector here (both operands are stored columns), so pgvector's HNSW index cannot apply BY
  # NATURE — this is NOT (and must not become) a `VectorSearch.nearest/4` call (US-27.7b —
  # registered in `Loopctl.Knowledge.CosineLintExceptions`). It is bounded by the sample
  # LIMIT (NOT an O(n²) scan over the whole 80k corpus) and stays tenant-scoped
  # (`a.tenant_id`/`b.tenant_id` filtered) via HeavyRead's structural guard.
  defp do_distant_pairs(tenant_id, min_d, max_d, limit, offset, bridge?, vis) do
    candidates =
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.status == :published and not is_nil(a.embedding),
        order_by: a.id,
        limit: ^pair_candidate_cap(bridge?),
        select: %{
          id: a.id,
          tenant_id: a.tenant_id,
          title: a.title,
          category: a.category,
          embedding: a.embedding
        }
      )
      |> maybe_filter_by_visibility(vis)

    # ONE query: the paginated pairs with a `limit + 1` look-ahead. The `<=>` band
    # filter over the sampled cross-join is the whole cost, and this ordered
    # `LIMIT (limit + 1)` lets Postgres STOP as soon as it has produced one more pair
    # than the page needs (early termination on the id-ordered nested loop) rather
    # than materializing every matching pair.
    #
    # There is deliberately NO companion `count(*)` query. An EXACT total-pair count
    # cannot early-terminate — it must evaluate the `<=>` for every one of the
    # O(candidates²) sampled pairs — and profiling at prod scale (#202/#203) showed
    # that full count pass, NOT the paginated read, was the entire ~7.85s cost (the
    # ordered `LIMIT limit+1` page returns in a few ms). Dropping it is what brings
    # the endpoint under the Epic 27 Theme 2 <2s target; `has_more` (the limit + 1
    # look-ahead) gives pagination everything it needs without that pass.
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

    # Fetch the page (+1 look-ahead) through Loopctl.HeavyRead (US-27.11): the
    # dedicated heavy-read pool with a per-read SET LOCAL statement_timeout (US-27.13),
    # isolated from the small AdminRepo pool so this self-join can't starve light admin
    # ops. A SINGLE short read now (the exact-count companion read was removed in
    # #202/#203). The query filters `a.tenant_id`/`b.tenant_id`, satisfying the
    # wrapper's structural tenant guard.
    #
    # The bridge branch reads under its OWN endpoint key (`:distant_pairs_bridge`) so its
    # slower per-pair-EXISTS reads carry a distinct `statement_timeout` backstop + slow-query
    # telemetry tag, separate from the fast non-bridge path (#202/#203 review, HIGH-4).
    endpoint = if bridge?, do: :distant_pairs_bridge, else: :distant_pairs

    pairs_with_lookahead =
      pairs_query
      |> maybe_filter_bridge_path(bridge?, vis)
      |> then(&HeavyRead.all(tenant_id, &1, heavy_read_opts(endpoint)))

    # Detect has_more by fetching limit+1; only return limit.
    has_more = length(pairs_with_lookahead) > limit
    pairs = Enum.take(pairs_with_lookahead, limit)

    %{pairs: pairs, has_more: has_more}
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
  at #{@novelty_concurrency}, and further capped to leave headroom below the per-tenant
  embedding cap). Priors default to published articles tagged `proposal`;
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
          max_concurrency: novelty_concurrency(),
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

  # Effective novelty fan-out width. Bounded by the static @novelty_concurrency ceiling
  # AND capped to leave headroom below EmbeddingConcurrency's per-tenant embedding cap,
  # so a single novelty batch can't consume the whole per-tenant budget and starve the
  # SAME tenant's concurrent interactive searches to keyword fallback (US-37.2 review).
  # Reserve at least ~1/3 of the per-tenant budget (min 1 slot) for other embedding
  # traffic; never exceed the static ceiling; never below 1. Reading max_per_tenant/0
  # directly (not via the acquire/release DI seam) is fine — it is a cached SystemConfig
  # read, and this runs once per novelty_scores/3 call, not per idea.
  defp novelty_concurrency do
    per_tenant = EmbeddingConcurrency.max_per_tenant()
    reserved = max(1, div(per_tenant, 3))

    (per_tenant - reserved)
    |> min(@novelty_concurrency)
    |> max(1)
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
    case generate_embedding(tenant_id, text) do
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
  #
  # This is a `MIN(? <=> $const::vector)` AGGREGATE over the prior-tag-scoped set, NOT a
  # top-k `ORDER BY <=> LIMIT k`, so it is NOT (and must not become) a `VectorSearch.nearest/4`
  # call: top-k-then-min ≠ the true MIN over the set (US-27.7b — registered in
  # `Loopctl.Knowledge.CosineLintExceptions`). The only helper it shares with `nearest/4`
  # is `to_embedding_list/1`, which normalizes the const to a plain `[float()]` param —
  # the SAME value shape `nearest/4` binds — so the `::vector` cast never re-interpolates a
  # stored `%Pgvector{}` struct (the #168 production 500). The query stays tenant-scoped
  # (`a.tenant_id == ^tenant_id`) and is bounded by prior-tag selectivity — NEVER a
  # full-corpus read (the verified plan shape is documented on novelty_distance_query/4).
  defp nearest_prior_distance(tenant_id, embedding, prior_tag, vis) do
    query = novelty_distance_query(tenant_id, embedding, prior_tag, vis)
    # Heavy vector aggregate — dedicated pool via Loopctl.HeavyRead (US-27.11).
    # `on_overload: :tag` (US-37.5): over the tenant's HeavyRead slice the read is SHED
    # and returns `{:error, :heavy_read_overloaded}` — mapped to a DELIBERATE `nil` novelty
    # score here (the same graceful degrade a genuinely unscorable idea gets), rather than
    # RAISING an OverloadedError that the `Task.async_stream` in `novelty_scores/3` would
    # catch as an incidental `{:exit, _}` and log as a scary task crash. Non-destructive:
    # nil already means "not scored".
    opts = Keyword.put(heavy_read_opts(:novelty), :on_overload, :tag)

    case HeavyRead.one(tenant_id, query, opts) do
      {:error, :heavy_read_overloaded} -> nil
      distance -> distance
    end
  end

  # The `MIN(embedding <=> $const::vector)` aggregate query, scoped to the prior-tag set.
  # Extracted so the US-27.7b scale gate can EXPLAIN the EXACT query the request path runs
  # (it executes inside a `Task.async_stream`, off the test process, so it can't be captured
  # in-process). The const is normalized to a plain `[float()]` via `to_embedding_list/1`
  # — the SAME value shape `nearest/4` binds — so the `::vector` cast never re-interpolates
  # a stored `%Pgvector{}` (the #168 prod 500). NOT a top-k helper (registered in
  # `Loopctl.Knowledge.CosineLintExceptions` — this function holds the `<=>` literal).
  #
  # BOUND (verified at 80k via EXPLAIN ANALYZE): tenant-scoped and bounded by prior-tag
  # selectivity, NEVER a full-corpus read. Postgres rewrites `MIN(embedding <=> $const)` into
  # `ORDER BY (embedding <=> $const) LIMIT 1` and serves it from the HNSW index
  # (`articles_embedding_hnsw_idx`) with `tags &&` as a Filter (~0.3ms / 676 buffers); for a
  # less-HNSW-friendly target/stats it may instead intersect the `tags &&` GIN
  # (`articles_tags_index`) bitmap. The planner picks by cost — both are bounded; the
  # invariant the scale test asserts is "bounded by prior-tag selectivity, not Seq Scan",
  # accepting EITHER plan (it does NOT pin the node type).
  @doc false
  def novelty_distance_query(tenant_id, embedding, prior_tag, vis) do
    target = to_embedding_list(embedding)

    from(a in Article,
      where:
        a.tenant_id == ^tenant_id and a.status == :published and not is_nil(a.embedding) and
          fragment("? && ?", a.tags, ^[prior_tag]),
      select: fragment("MIN(? <=> ?::vector)", a.embedding, ^target)
    )
    |> maybe_filter_by_visibility(vis)
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
  - `content_hash` -- optional SHA-256 hex of the embedded text; stored as the
    idempotency key so a retry can skip re-calling the paid provider (review #12)

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, changeset}` on dimension mismatch
  - `{:error, :not_found}` if the article does not exist in this tenant
  """
  @spec update_embedding(Ecto.UUID.t(), Ecto.UUID.t(), list(number()), String.t() | nil) ::
          {:ok, Article.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_embedding(tenant_id, article_id, embedding_vector, content_hash \\ nil) do
    case AdminRepo.get_by(Article, id: article_id, tenant_id: tenant_id) do
      nil ->
        {:error, :not_found}

      article ->
        changeset = Article.embedding_changeset(article, embedding_vector, content_hash)

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

  defp fetch_article(tenant_id, article_id, opts) do
    # Visibility scope (#163/#331): the write paths (update/archive) pass the
    # caller's `:visibility_agent_id` so an agent cannot mutate another agent's
    # `private`/`owner` memory — an invisible target resolves to :not_found (404),
    # matching the read paths. Higher roles pass no scope and reach any in-tenant
    # article.
    query =
      from(a in Article, where: a.id == ^article_id and a.tenant_id == ^tenant_id)
      |> maybe_filter_by_visibility(Keyword.get(opts, :visibility_agent_id))

    case AdminRepo.one(query) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  defp validate_project_ownership(_tenant_id, nil), do: :ok

  defp validate_project_ownership(tenant_id, project_id) do
    # `id: project_id` on a :binary_id column raises Ecto.Query.CastError for a
    # non-UUID value (a malformed string, or a non-string from a JSON body). Guard
    # the cast so create/update (and OKF import via create_article/update_article)
    # return the changeset error -> a clean 422, never a 500.
    if valid_uuid?(project_id) and
         not is_nil(AdminRepo.get_by(Project, id: project_id, tenant_id: tenant_id)) do
      :ok
    else
      {:error,
       %Article{}
       |> Ecto.Changeset.change()
       |> Ecto.Changeset.add_error(:project_id, "is invalid or does not belong to this tenant")}
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
    # Defense in depth: `project_id` is a `:binary_id` column, so a non-UUID
    # value would make `Ecto.UUID.dump/1` fail and raise `Ecto.Query.CastError`
    # (an unhandled 500). Callers validate at the API boundary and 422 first, but
    # a malformed value reaching here must not crash — treat it as "matches
    # nothing", consistent with a valid-but-nonexistent project.
    if valid_uuid?(project_id) do
      where(query, [a], a.project_id == ^project_id)
    else
      where(query, [a], false)
    end
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

  # kb-02: metadata keys reserved for system provenance. Callers of create_link/3 must
  # never set these (both string- and atom-key forms are dropped). Referencing the atoms
  # literally keeps them as existing atoms — no String.to_atom on input.
  @reserved_metadata_keys [
    "auto_generated",
    "similarity_score",
    :auto_generated,
    :similarity_score
  ]

  defp strip_system_metadata(attrs) when is_map(attrs) do
    cond do
      is_map(attrs[:metadata]) ->
        Map.put(attrs, :metadata, Map.drop(attrs[:metadata], @reserved_metadata_keys))

      is_map(attrs["metadata"]) ->
        Map.put(attrs, "metadata", Map.drop(attrs["metadata"], @reserved_metadata_keys))

      true ->
        attrs
    end
  end

  defp strip_system_metadata(attrs), do: attrs

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
          | {:error, :heavy_read_overloaded}
  def search_semantic(tenant_id, query_embedding, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 10) |> max(1) |> min(@max_relevance_page_size)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    status = Keyword.get(opts, :status, :published)

    # RESULTS — relevance-pool model (US-27.7a, EXPLAIN-driven). The inner ANN is the
    # shared, index-safe `VectorSearch.candidate_pool_query/4` (pure
    # `ORDER BY embedding <=> $const LIMIT pool` on the HNSW index), and ALL selective
    # filters (project/category/tags/memory-types/agents/conversation) are applied on the
    # OUTER over-the-pool subquery, paginated within the pool. This is required because the
    # pre-27.7a query applied those filters on the index-ordered scan itself, which at prod
    # scale flipped the planner to a BitmapAnd + Sort over the corpus and ABANDONED HNSW
    # (the #170/#172 shape — verified by EXPLAIN at 80k). status + visibility stay in the
    # inner (both index-safe). The result shape/score (`1 - cosine_distance`) and field set
    # are byte-for-byte the pre-27.7a contract (the `:semantic` pool select).
    #
    # RECALL/PAGINATION NOTE: results now come from the top-`pool` ANN that match the
    # filters, not a full-corpus rank, so a page DEEPER than the pool returns empty. The
    # pool is sized to comfortably cover `offset + limit` (and a config floor), so every
    # in-contract page (limit ≤ #{@max_relevance_page_size}) is served; only an
    # unusually-deep offset beyond the pool cap is affected — the documented post-ANN-filter
    # tradeoff `VectorSearch` already carries (see its moduledoc).
    # US-37.5: pass `on_overload: :tag` so an over-cap heavy-read shed returns
    # `{:error, :heavy_read_overloaded}` (rather than raising a 429) — semantic search
    # degrades gracefully to KEYWORD-only fallback on overload, exactly as it does on
    # an embedding failure. Either heavy read's shed short-circuits to the tagged error
    # the callers map to keyword fallback.
    results_query = semantic_results_query(tenant_id, query_embedding, opts)

    # COUNT — kept as a SEPARATE full-corpus filtered `count(*)` so `total_count` PRESERVES
    # its pre-27.7a meaning (the size of the whole embedded+filtered ranked corpus, NOT the
    # pool). It carries NO `ORDER BY embedding <=> …`: a count needs no ordering, and the
    # old subquery's ORDER BY forced a pointless full-corpus Seq Scan + Sort (~153ms at
    # 80k). Without it the count is index-served by the filter indexes (a selective
    # category+tags count is a BitmapAnd bounded by selectivity; the unfiltered count is a
    # bounded tenant scan — inherently O(tenant rows) for a true `count(*)`).
    count_query = semantic_count_query(tenant_id, query_embedding, status, opts)

    case HeavyRead.all(tenant_id, results_query, semantic_heavy_read_opts()) do
      {:error, :heavy_read_overloaded} = err ->
        err

      results ->
        case HeavyRead.one(tenant_id, count_query, semantic_heavy_read_opts()) do
          {:error, :heavy_read_overloaded} = err ->
            err

          total_count ->
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
                 total_count_scope: "ranked_corpus",
                 pool_capped: semantic_pool_capped?(total_count, length(results), limit, offset)
               }
             }}
        end
    end
  end

  # US-37.5: heavy-read opts for the semantic search reads with the graceful-degrade
  # flag — an over-cap shed returns `{:error, :heavy_read_overloaded}` (search falls
  # back to keyword-only) instead of raising a 429.
  defp semantic_heavy_read_opts do
    [{:on_overload, :tag} | heavy_read_opts(:semantic_search)]
  end

  # Relevance-pool truncation signal (US-27.7a — NOT silent; mirrors the suggested-links
  # `recall_truncated` / keyset `next_cursor: null` exhaustion conventions). Results come
  # from the top-`cap` relevance pool with the selective filters applied POST-ANN, so the
  # ranked+filtered set may exceed what pagination can reach. Two truncation modes, both
  # flagged (a `false` therefore means "this query's results are complete"):
  #
  #   * CAP truncation — `total_count > cap`: the corpus is larger than the reachable pool
  #     (true regardless of `offset`, even on a full page).
  #   * POOL/FILTER starvation — a SHORT page (`returned < limit`) while MORE filtered
  #     results exist than were surfaced (`offset + returned < total_count`). This catches
  #     the case a `total_count > cap`-only check MISSED: a selective filter whose matches
  #     fall outside the top-`pool` nearest starves the page below the cap. (A genuine
  #     last page — `offset + returned == total_count` — is NOT flagged.)
  defp semantic_pool_capped?(total_count, returned, limit, offset) do
    total_count > semantic_result_pool_cap() or
      (returned < limit and offset + returned < total_count)
  end

  # Builds `search_semantic`'s paginated RESULTS query (returned, not executed) — the
  # relevance-pool shape. Public-but-`@doc false` so the US-27.7a scale plan-assertion can
  # assert the REAL request-path query (AC-27.2.4): the inner ANN is the shared,
  # HNSW-index-safe `VectorSearch.candidate_pool_query/4` (`:semantic` projection), the
  # selective filters live on the OUTER over-the-pool subquery, and the page is taken
  # within the pool. See `search_semantic/3` for the full rationale + recall note.
  @doc false
  def semantic_results_query(tenant_id, query_embedding, opts) do
    limit = opts |> Keyword.get(:limit, 10) |> max(1) |> min(@max_relevance_page_size)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    status = Keyword.get(opts, :status, :published)
    pool = semantic_result_pool(offset + limit)

    inner_pool =
      VectorSearch.candidate_pool_query(tenant_id, query_embedding, pool,
        select: :semantic,
        status: status,
        visibility_agent_id: Keyword.get(opts, :visibility_agent_id)
      )

    from(c in subquery(inner_pool),
      order_by: [desc: c.similarity_score],
      select: %{
        id: c.id,
        tenant_id: c.tenant_id,
        project_id: c.project_id,
        title: c.title,
        category: c.category,
        status: c.status,
        tags: c.tags,
        inserted_at: c.inserted_at,
        updated_at: c.updated_at,
        similarity_score: c.similarity_score
      }
    )
    |> apply_semantic_pool_filters(opts)
    |> limit(^limit)
    |> offset(^offset)
  end

  # The full-corpus filtered `count(*)` for `search_semantic`'s `total_count` — NO
  # `embedding <=> …` ordering (a count is order-independent; the ordering only forced a
  # full-corpus Seq Scan + Sort pre-27.7a). The filter set is IDENTICAL to the results
  # path (status + visibility + project/category/tags/memory-types/agents/conversation),
  # so the count is the true size of the embedded+filtered ranked corpus. The tenant
  # predicate on the base `articles` source satisfies the `HeavyRead` guard directly.
  # Public-but-`@doc false` so the scale plan-assertion can assert the real count query.
  @doc false
  def semantic_count_query(tenant_id, query_embedding, status, opts) do
    _ = query_embedding

    base =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: not is_nil(a.embedding)
      )

    base
    |> apply_search_filters(status, opts)
    |> select([_a], count())
  end

  # Selective post-ANN filters for the semantic results pool, applied on the OUTER
  # subquery (`c` binding) over the ≤`pool` rows — NEVER the inner index-ordered ANN
  # (project/category/tags/`metadata @>` all have GIN/btree indexes and would defeat HNSW
  # there). status + visibility are already applied in the inner pool (index-safe), so they
  # are intentionally NOT re-applied here. Reuses the same equality/overlap/containment
  # predicate helpers as the keyword/list path against the `[c]` binding (whose subquery
  # select carries `project_id`/`category`/`tags`/`metadata`).
  defp apply_semantic_pool_filters(query, opts) do
    query
    |> maybe_filter_by_project_id(Keyword.get(opts, :project_id))
    |> maybe_filter_by_category(Keyword.get(opts, :category))
    |> maybe_filter_by_tags(Keyword.get(opts, :tags), Keyword.get(opts, :match, :any))
    |> maybe_filter_by_memory_types(Keyword.get(opts, :memory_types))
    |> maybe_filter_by_agents(Keyword.get(opts, :agents))
    |> maybe_filter_by_conversation_id(Keyword.get(opts, :conversation_id))
  end

  # Over-fetch pool for the semantic relevance results (US-27.7a). Sized to cover the
  # requested `offset + limit` page, floored for the common shallow page and HARD-capped so
  # the inner HNSW scan cost is BOUNDED regardless of caller input. Config:
  #   * `:semantic_result_pool_floor` (default #{@default_semantic_result_pool_floor})
  #   * `:semantic_result_pool_cap`   (default #{@default_semantic_result_pool_cap})
  #
  # The cap is a HARD ceiling — it is the last clamp, so it ALWAYS binds (AC-27.6a.4: every
  # caller-tunable cost parameter has an enforced upper bound). `offset` is NOT bounded by
  # the caller/controller (only floored at 0), so a final `max(needed)` would let a large
  # `offset` drive the inner `ORDER BY <=> LIMIT pool` to an arbitrary size — an unbounded
  # scan. We deliberately do NOT do that: a page whose `offset + limit` exceeds the cap is
  # served from the top-`cap` relevance pool and truncates (empty/partial) beyond it — the
  # documented post-ANN relevance tradeoff (deep enumeration is the keyset list path's job,
  # US-27.9a, not relevance search). The floor (≥ the `max_relevance_page_size` limit) keeps
  # every in-cap page fully served under the default config.
  defp semantic_result_pool(needed) when is_integer(needed) and needed > 0 do
    floor =
      Application.get_env(
        :loopctl,
        :semantic_result_pool_floor,
        @default_semantic_result_pool_floor
      )

    needed
    |> max(floor)
    |> min(semantic_result_pool_cap())
  end

  # The hard reachability ceiling for relevance-search pagination (US-27.7a): results come
  # from the top-`cap` relevance pool, so a consumer can page through at most `cap` ranked
  # rows regardless of `offset`. Drives both the results pool's hard cap and the
  # `meta.pool_capped` truncation signal. Config `:semantic_result_pool_cap`.
  defp semantic_result_pool_cap,
    do:
      Application.get_env(:loopctl, :semantic_result_pool_cap, @default_semantic_result_pool_cap)

  @doc """
  Combined keyword + semantic search with configurable weighting.

  Runs both `search_keyword/3` and `search_semantic/3`, normalizes their
  scores to a 0-1 range, then computes a weighted `final_score` for each
  article. Results are deduplicated by article ID and sorted by `final_score`
  descending.

  The query embedding is generated on-the-fly via the configured embedding
  client. If embedding generation fails (timeout, error, or circuit breaker),
  falls back to keyword-only search with `fallback: true` in the response meta,
  plus a stable, non-sensitive `fallback_reason` tag naming WHY (#297) — e.g.
  `"no_embedding_key"`, `"embedding_circuit_open"`, `"embedding_provider_error_401"`.
  When the embedding SUCCEEDS but semantic ranking returns nothing (a recall
  problem, not an embed failure), the meta carries `semantic_result_count: 0`
  with `fallback: false` instead. Both cases also emit
  `[:loopctl, :knowledge, :semantic_fallback]` telemetry + a warning log.

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
    embedding_result = try_generate_embedding(tenant_id, query_string, [])

    case {keyword_result, embedding_result} do
      {{:ok, kw}, {:ok, embedding}} ->
        # US-37.5: the semantic heavy read can be SHED when the tenant is over its
        # per-tenant in-flight HeavyRead cap. That returns `{:error,
        # :heavy_read_overloaded}` (rather than raising a 429) so combined search
        # degrades to keyword-only — the SAME graceful fallback as an embedding
        # failure, keeping OTHER tenants' access to the shared BYPASSRLS pool.
        case search_semantic(tenant_id, embedding, sub_opts) do
          {:ok, semantic} ->
            # Distinguish the OTHER silent-degradation cause (#297): the embedding
            # SUCCEEDED but semantic ranking returned nothing (a recall/HNSW problem,
            # NOT an embed failure). Combined does NOT fall back here — keyword still
            # merges — so this sets no fallback/fallback_reason; it only emits the
            # alertable signal and the meta carries `semantic_result_count`.
            maybe_emit_semantic_empty(tenant_id, length(semantic.results), query_string)

            {:ok, merged} = merge_results(kw, semantic, keyword_weight, semantic_weight, opts)

            maybe_record_search_access(
              tenant_id,
              merged.results,
              query_string,
              opts,
              "combined"
            )

            {:ok, merged}

          {:error, :heavy_read_overloaded} ->
            combined_keyword_fallback(tenant_id, kw, :heavy_read_overloaded, query_string, opts)
        end

      {{:ok, kw}, {:error, reason}} ->
        # Fallback to keyword-only. Capture the discarded embedding-error reason as
        # a stable, non-sensitive tag (sanitized via ProviderError so no api key /
        # provider body leaks), surface it in meta, and emit telemetry + a log so a
        # silent degradation becomes alertable (#297).
        combined_keyword_fallback(tenant_id, kw, reason, query_string, opts)

      {kw_error, _} ->
        kw_error
    end
  end

  # Degrade combined search to keyword-only when the semantic side is unavailable —
  # either an embedding-generation error (#297) OR an over-cap HeavyRead shed
  # (US-37.5, `:heavy_read_overloaded`). Records the discarded reason as a stable,
  # non-sensitive `fallback_reason` tag (sanitized via ProviderError), surfaces it in
  # meta, and emits telemetry + a log so the degradation is alertable, not silent.
  defp combined_keyword_fallback(tenant_id, kw, reason, query_string, opts) do
    fallback_reason = record_semantic_fallback(tenant_id, reason, query_string)
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
           fallback_reason: fallback_reason,
           total_count: kw.meta.total_count,
           limit: paginated.limit,
           offset: paginated.offset
         })
     }}
  end

  # -- Semantic → keyword fallback observability (#297) ------------------------
  #
  # #297: at ~77k-article scale every knowledge_search/context silently returned
  # `fallback: true, search_mode: "keyword_only"` and the discarded embedding-error
  # `_reason` made the outage UNDIAGNOSABLE. These helpers capture the reason as a
  # STABLE, non-sensitive tag, surface it in `meta.fallback_reason`, and emit an
  # alertable telemetry event + log — WITHOUT changing the fallback behavior.

  @doc """
  Record a semantic→keyword-only degradation and return a stable, non-sensitive
  `fallback_reason` tag for the response `meta` (#297).

  `reason` is the discarded embedding-generation error term. It is sanitized via
  `Loopctl.Llm.ProviderError.sanitize/1` FIRST, so no provider response body or api
  key can ever reach the returned tag, the emitted telemetry, or the log line. The
  mapping is a BOUNDED set (safe as a Prometheus label):

    * `:no_api_key` → `"no_embedding_key"`
    * `:circuit_open` → `"embedding_circuit_open"`
    * `:rate_limited_local` → `"embedding_rate_limited_local"` (US-37.1 admission gate)
    * `:timeout` → `"embedding_timeout"`
    * `{:api_error, status, _}` → `"embedding_provider_error_<status>"` (status only)
    * `{:request_failed, _}` → `"embedding_request_failed"`
    * `{:embedding_crash, _}` → `"embedding_crash"`
    * anything else → the generic `"embedding_error"` (the raw term is NEVER inspected)

  Emits `[:loopctl, :knowledge, :semantic_fallback]` telemetry and a
  `Logger.warning` naming the reason + tenant. The query TEXT never appears in
  telemetry/logs (only its byte length), matching the other knowledge search
  telemetry (id-only metadata).
  """
  @spec record_semantic_fallback(Ecto.UUID.t(), term(), String.t()) :: String.t()
  def record_semantic_fallback(tenant_id, reason, query_string) do
    tag = fallback_reason_tag(reason)
    emit_semantic_fallback(tenant_id, tag, query_string, 0)
    tag
  end

  # The "embed worked but recall is broken" cause of #297: the embedding SUCCEEDED
  # but semantic ranking returned ZERO rows. Combined search does NOT fall back here
  # (keyword still merges), so this emits the alertable signal WITHOUT a keyword_only
  # fallback — callers see it via `meta.semantic_result_count`, operators via the
  # `reason: "semantic_empty"` telemetry, keeping it distinct from an embed failure.
  defp maybe_emit_semantic_empty(_tenant_id, count, _query_string) when count > 0, do: :ok

  defp maybe_emit_semantic_empty(tenant_id, 0, query_string) do
    emit_semantic_fallback(tenant_id, "semantic_empty", query_string, 0)
    :ok
  end

  defp fallback_reason_tag(reason) do
    reason
    |> ProviderError.sanitize()
    |> reason_to_tag()
  end

  defp reason_to_tag(:no_api_key), do: "no_embedding_key"
  defp reason_to_tag(:circuit_open), do: "embedding_circuit_open"
  defp reason_to_tag(:rate_limited_local), do: "embedding_rate_limited_local"
  # US-37.5: the semantic heavy read was shed because the tenant is over its
  # per-tenant in-flight HeavyRead cap; search degraded to keyword-only.
  defp reason_to_tag(:heavy_read_overloaded), do: "heavy_read_overloaded"
  defp reason_to_tag(:timeout), do: "embedding_timeout"

  # US-37.3: the throttle 4-tuple carries a Retry-After — the tag is still status-only.
  defp reason_to_tag({:api_error, status, _, _}) when is_integer(status),
    do: "embedding_provider_error_#{status}"

  defp reason_to_tag({:api_error, status, _}) when is_integer(status),
    do: "embedding_provider_error_#{status}"

  defp reason_to_tag({:api_error, status}) when is_integer(status),
    do: "embedding_provider_error_#{status}"

  defp reason_to_tag({:request_failed, _}), do: "embedding_request_failed"
  defp reason_to_tag({:embedding_crash, _}), do: "embedding_crash"
  defp reason_to_tag(_other), do: "embedding_error"

  # Query TEXT is deliberately excluded from telemetry/logs (only `query_len`) — the
  # sibling knowledge telemetry (`keyset_byte_truncated`, `vector_search.under_fill`)
  # carries id-only metadata, and this keeps that contract. The Prometheus counter
  # (`Loopctl.Telemetry.ScaleMetrics`) tags ONLY by `reason` (a small fixed set) — no
  # `tenant_id` label — so cardinality stays bounded.
  defp emit_semantic_fallback(tenant_id, tag, query_string, semantic_result_count) do
    :telemetry.execute(
      Loopctl.TelemetryEvents.knowledge_semantic_fallback(),
      %{
        count: 1,
        query_len: byte_size(query_string),
        semantic_result_count: semantic_result_count
      },
      %{tenant_id: tenant_id, reason: tag}
    )

    Logger.warning(
      "knowledge.semantic_fallback reason=#{tag} tenant_id=#{tenant_id} " <>
        "query_len=#{byte_size(query_string)} (semantic ranking did not contribute)"
    )

    :ok
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

    # For a candidate found in BOTH pools, `Map.merge(kw, sem)` keeps EACH side's
    # exclusive raw fields (kw's raw `:relevance_score`/`:snippet`, sem's raw
    # `:similarity_score`) instead of silently dropping one — the hybrid resolver
    # (US-31.2) needs both raw, ABSOLUTE (non-pool-relative) scores to survive on the
    # merged result map so it never has to fall back to the pool-normalized
    # `:final_score` for its curated-confidence decision (see `absolute_score/1`).
    # `:final_score` itself is explicitly overridden to the correct weighted SUM
    # (Map.merge alone would have just taken sem's half).
    merged =
      Map.merge(kw_map, sem_map, fn _id, kw, sem ->
        kw
        |> Map.merge(sem)
        |> Map.put(:final_score, kw.final_score + sem.final_score)
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
         total_count_scope: "merged_candidates",
         # Carry the semantic sub-search's relevance-pool truncation forward (US-27.7a)
         # — combined is the DEFAULT mode, so silently dropping the flag would hide
         # truncation on the most-used path. `maybe_put` keeps the key absent unless the
         # semantic half was actually pool-capped.
         pool_capped: Map.get(semantic_result.meta, :pool_capped, false),
         # Observability for #297: how many rows the semantic half contributed. A
         # `0` here with `fallback: false` is the "embed worked but recall is broken"
         # signal (distinct from an embed-failure keyword_only fallback), so operators
         # and clients can tell the two silent-degradation causes apart.
         semantic_result_count: length(semantic_result.results)
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

  # --- Hybrid resolver (US-31.2) ---
  #
  # Composes the ALREADY-SHIPPED retrieval (`search_combined/3`) and curated
  # (`list_curated_sources/2` / US-31.1) subsystems into a single resolution layer.
  # Does NOT re-architect embeddings or add a migration (#305/#306).

  @default_hybrid_curated_threshold 0.75
  @default_hybrid_curated_margin 0.1
  # Keyword-scale (bounded `raw / (raw + 1)` transform of `ts_rank_cd`, see
  # `normalize_keyword_score/1`) threshold/margin — deliberately a DIFFERENT default
  # than the semantic-scale pair above. Calibrated against real `ts_rank_cd` output
  # (verified empirically): a confidently-matching, normal-length curated doc lands
  # around `~0.67`, while a merely-incidental single mention deep in an unrelated
  # document lands around `~0.29` — `0.5` cleanly separates the two with margin on
  # both sides.
  @default_hybrid_curated_threshold_keyword 0.5
  @default_hybrid_curated_margin_keyword 0.1

  @doc """
  Hybrid resolver (US-31.2): returns a **curated** answer ONLY when a governed curated
  source (US-31.1) actually answers the query — else falls back to **retrieval**
  (`search_combined/3`). Every response carries `meta.provenance` (`:curated` |
  `:retrieved`) so a caller branches on that FIELD alone, never on which subsystem
  answered (the literal fix for #305's "no caller-side RAG-or-curated branching").

  The harvested failure this guards against is WORSE than a plain RAG miss: a curated
  doc that is semantically near a query it does NOT answer, mislabeled authoritative,
  is a confidently-wrong answer that is now trusted. So `:curated` requires ALL of:

    * the curated candidate's ABSOLUTE confidence score (see `absolute_score/1` below
      — never a pool-relative, min-max-normalized score) clears the absolute
      confidence threshold FOR ITS OWN SCALE (config
      `:knowledge_hybrid_curated_threshold`, default `#{@default_hybrid_curated_threshold}`,
      for a semantic/cosine match; `:knowledge_hybrid_curated_threshold_keyword`,
      default `#{@default_hybrid_curated_threshold_keyword}`, for a keyword-only
      match), AND
    * it beats the best NON-curated candidate's absolute score by the matching margin
      (config `:knowledge_hybrid_curated_margin` /
      `:knowledge_hybrid_curated_margin_keyword`, defaults
      `#{@default_hybrid_curated_margin}` / `#{@default_hybrid_curated_margin_keyword}`),
      AND
    * it is authoritative (published, not superseded, not in an open
      `:potential_conflict` — enforced by `list_curated_sources/2`, US-31.1).

  Otherwise the response is `:retrieved` — a near-but-wrong curated doc that is
  semantically close but below threshold, or not competitive against retrieval, NEVER
  wins `:curated`. See `resolve_provenance/4` for the pure decision rule.

  ## Absolute, not pool-relative, scoring (AC-31.2.1/.2 — critical fix)

  `final_score` (built by `merge_results/5`) is a min-max-NORMALIZED, pool-RELATIVE
  score: a lone or top candidate in an otherwise-sparse pool always normalizes to
  `1.0` regardless of its TRUE similarity/relevance — that would let a curated doc
  win `:curated` at "confidence 1.0" even when it barely relates to the query. The
  provenance decision therefore scores every candidate via `absolute_score/1`, which
  reads the RAW, un-normalized field straight off the result map: `:similarity_score`
  (`1 - cosine_distance`, already on an absolute, bounded `0..1` scale) when present,
  else a BOUNDED transform of the raw `:relevance_score` (`ts_rank_cd`, itself
  unbounded — confirmed empirically up to ~2.0 for a short, title-exact match) — see
  `normalize_keyword_score/1`. `merge_results/5` preserves BOTH raw fields on every
  merged candidate (not just the winning half) specifically so this is always possible
  in "combined" mode.

  Cosine similarity and (normalized) `ts_rank_cd` are DIFFERENT, incommensurable
  scales — comparing them with ONE raw threshold/margin pair would either make the
  keyword branch practically unreachable (a realistic keyword-confident match sits
  well below a cosine-tuned `0.75`) or let an unnaturally high/low score on one scale
  distort a cross-scale margin subtraction. `hybrid_curated_threshold_and_margin/1`
  therefore selects the config pair matching the WINNING curated candidate's OWN
  scale (finding, US-31.2) — the threshold/margin is never compared across scales.

  ## Resolved over the ranked pool, independent of the caller's page (AC-31.2.1/.2)

  The provenance decision is made over the FULL ranked candidate pool (up to
  `#{@max_relevance_page_size}` per side, the same cap `search_combined/3` already
  uses for its sub-searches) — NOT the caller's paginated page. A genuinely-answering
  curated source ranked outside the caller's requested `:limit`/`:offset` window is
  still found and scored; a caller-supplied `:offset` shifts only which page of
  `results` comes BACK, never which candidates the resolver reasons over. When
  `:curated` wins, the winning article is additionally hoisted to the FRONT of the
  (still full, still ranked) pool BEFORE pagination — so `meta.provenance == :curated`
  always means `results |> List.first()` (at `offset: 0`) IS that curated answer,
  never a decoy that merely out-ranked it on the pool-relative `:final_score` (the
  "label != payload" defect this resolver exists to prevent, #305).

  ## Tenant isolation (AC-31.2.6)

  `tenant_id` is threaded into BOTH `search_combined/3` (retrieval) AND
  `list_curated_sources/2` (curated identification) — both run on `AdminRepo`/
  `HeavyRead` (BYPASSRLS). RLS does NOT backstop these reads; the explicit predicate
  in each function is the sole isolation boundary.

  ## Degradation honesty (AC-31.2.4, SOUL rule 7)

  This function does NOT re-implement `search_combined/3`'s embedding degradation — it
  reuses it. When embeddings are unavailable, `search_combined/3` already falls back to
  keyword-only (`meta.fallback: true`, `meta.search_mode: "keyword_only"`) and the
  curated candidate's absolute (normalized `ts_rank_cd`) score in that pool is compared
  against the matching KEYWORD-scale threshold: a curated source still confidently
  identifiable by keyword can win `:curated`; a merely-incidental keyword hit (low raw
  rank) falls to `:retrieved`, same as a weak semantic match would. Never a silent
  empty, never a false `:curated` under degraded matching.

  ## Shape parity (AC-31.2.3)

  Both provenance branches return the IDENTICAL map shape: `results` is the caller's
  requested page of the SAME ranked pool used for scoring — reordered (curated winner
  hoisted to the front) rather than re-filtered when `:curated` wins, so per-result
  keys are identical by construction regardless of provenance — and `meta` is always
  `search_combined/3`'s own meta (with `:limit`/`:offset` overridden to the caller's
  actual requested page) merged with exactly `%{provenance: ..., confidence: ...,
  curated_article_id: ...}` — no key ever appears on only one branch (`curated_article_id`
  is `nil` on the `:retrieved` branch).

  ## Provenance metrics (AC-31.2.5)

  The retrieval pool's OWN search-access recording is suppressed
  (`_skip_record_access: true` on the inner `search_combined/3` call, mirroring how
  `do_combined_search/5` already dedupes its own sub-search recordings) and replaced
  with a SINGLE recording (scoped to the caller's returned page) tagged
  `mode: "hybrid_curated"` or `mode: "hybrid_retrieved"` in the `ArticleAccessEvent`
  metadata — an additive extension of the existing mode tags (`"keyword"`,
  `"semantic"`, `"combined"`). This rides the existing
  `Loopctl.Knowledge.RetrievalMetrics` / `article_access_events` pipeline (see its
  `curated_searched`/`retrieved_searched` breakdown), so "prefer-curated silently
  hiding better retrieval" is observable per tenant without a new table. That DB-backed
  recording still requires a non-empty page + `:api_key_id` (an inherited constraint of
  `article_access_events`, whose `article_id`/`api_key_id` are NOT NULL); a MISS
  (empty page) or a keyless call additionally emits a bare
  `[:loopctl, :knowledge, :hybrid_provenance]` telemetry count (tenant/provenance/hit
  only — no article/query content) so that dimension stays observable too (closes the
  gap the DB recording structurally cannot).

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `query_string` -- the search query text
  - `opts` -- forwarded to `search_combined/3` (`:keyword_weight`, `:semantic_weight`,
    `:project_id`, `:category`, `:status`, `:tags`, `:limit`, `:offset`,
    `:api_key_id`, `:project_id`/`:story_id` attribution)

  ## Returns

  - `{:ok, %{results: [map()], meta: map()}}` -- `meta.provenance` is `:curated` or
    `:retrieved`. `meta.confidence` is the winning candidate's ABSOLUTE score for that
    SAME provenance class (0.0 when there are no results at all, or when `:retrieved`
    won with no genuine non-curated competitor in the pool) — never a rejected
    candidate from the OTHER provenance class. `meta.curated_article_id` is the
    winning curated article's id when `meta.provenance == :curated` (and it is
    guaranteed to be present, first, in `results`), else `nil`.
  - `{:error, :invalid_weights}` / `{:error, :empty_query}` / `{:error, atom(),
    String.t()}` -- propagated unchanged from `search_combined/3`
  """
  @spec hybrid_search(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, %{results: [map()], meta: map()}}
          | {:error, :invalid_weights}
          | {:error, :empty_query}
          | {:error, atom(), String.t()}
  def hybrid_search(tenant_id, query_string, opts \\ []) when is_binary(tenant_id) do
    requested_limit = Keyword.get(opts, :limit, 10)
    requested_offset = Keyword.get(opts, :offset, 0)

    # Force the INNER search over the full ranked pool (offset 0, the same cap
    # `search_combined/3`'s own sub-searches already use) so the provenance decision
    # below reasons over the top of the ranked pool, never just the caller's
    # requested page — a curated source ranked outside `:limit`/beyond `:offset` is
    # still found and scored (AC-31.2.1/.2, fixes the pagination-scoped defect).
    pool_opts =
      opts
      |> Keyword.put(:_skip_record_access, true)
      |> Keyword.put(:limit, @max_relevance_page_size)
      |> Keyword.put(:offset, 0)

    with {:ok, %{results: pool_results, meta: pool_meta}} <-
           search_combined(tenant_id, query_string, pool_opts) do
      curated_ids = curated_source_ids(tenant_id, pool_results)
      scores = candidate_scores(pool_results)

      {curated_candidates, retrieved_candidates} =
        Enum.split_with(pool_results, &MapSet.member?(curated_ids, &1.id))

      best_curated = Enum.max_by(curated_candidates, &Map.fetch!(scores, &1.id), fn -> nil end)
      curated_score = best_curated && Map.fetch!(scores, best_curated.id)
      best_retrieved_score = best_score(retrieved_candidates, scores)

      {threshold, margin} = hybrid_curated_threshold_and_margin(best_curated)

      provenance = resolve_provenance(curated_score, best_retrieved_score, threshold, margin)

      # (finding: mislabeled-authoritative decoy) When `:curated` wins, the winning
      # curated article MUST actually be present — and first — in the returned page,
      # never just a label attached to whatever the pool-relative ranking happened to
      # place in the requested window. Reordering the FULL pool (not just the page)
      # keeps `results` sourced from the same ranked pool for every offset (AC-31.2.3
      # shape parity is unaffected — same map shape, just reordered).
      {ordered_pool, confidence, curated_article_id} =
        case provenance do
          :curated ->
            {hoist_to_front(pool_results, best_curated.id), curated_score, best_curated.id}

          :retrieved ->
            # (finding: mislabeled confidence) `best_retrieved_score` — NEVER
            # `best_score(pool_results, scores)`, which would report a REJECTED
            # curated candidate's score (a different provenance class) as if it were
            # the winning retrieved candidate's confidence.
            {pool_results, best_retrieved_score, nil}
        end

      page = paginate_results(ordered_pool, limit: requested_limit, offset: requested_offset)

      maybe_record_search_access(
        tenant_id,
        page.results,
        query_string,
        opts,
        hybrid_search_mode(provenance)
      )

      emit_hybrid_provenance(tenant_id, provenance, page.results != [])

      {:ok,
       %{
         results: page.results,
         meta:
           Map.merge(pool_meta, %{
             provenance: provenance,
             confidence: confidence,
             # Always present on BOTH branches (nil for `:retrieved`) so a caller can
             # locate the curated answer via `meta.curated_article_id` even when the
             # ranked pool's own ordering places it outside `results` — the actionable
             # pointer this finding required alongside the hoist above.
             curated_article_id: curated_article_id,
             limit: page.limit,
             offset: page.offset
           })
       }}
    end
  end

  # Moves the winning curated candidate to the FRONT of the pool (stable order for
  # everything else) — called ONLY when provenance is `:curated`, so a caller
  # branching on `meta.provenance` can always trust `results |> List.first()` is the
  # curated, authoritative answer, never a decoy that happened to out-rank it on the
  # pool-relative `:final_score` (finding, US-31.2).
  defp hoist_to_front(pool_results, curated_id) do
    {winner, rest} = Enum.split_with(pool_results, &(&1.id == curated_id))
    winner ++ rest
  end

  # Body-less/id-only curated lookup (finding 5): `list_curated_sources/2` defaults to
  # returning full `%Article{}` structs (including bodies), which the resolver would
  # otherwise discard entirely except for `.id`. `select: :id` keeps this a per-query
  # hot path cheap regardless of how large the curated corpus grows. Scoped to the
  # POOL's own ids (`:ids`) — NEVER the tenant's full curated/system-canonical corpus
  # — so per-query cost scales with the <=200-candidate pool, not the curated corpus
  # (review finding, US-31.2).
  defp curated_source_ids(_tenant_id, []), do: MapSet.new()

  defp curated_source_ids(tenant_id, pool_results) do
    pool_ids = Enum.map(pool_results, & &1.id)
    tenant_id |> list_curated_sources(select: :id, ids: pool_ids) |> MapSet.new()
  end

  # Builds an id -> ABSOLUTE (non-pool-relative) score index used ONLY for the
  # provenance decision — `results` themselves are unaffected (AC-31.2.3 shape
  # parity). See `absolute_score/1` for why this reads raw fields instead of the
  # pool-normalized `:final_score`/`:normalized_score`.
  defp candidate_scores(results) do
    Map.new(results, fn r -> {r.id, absolute_score(r)} end)
  end

  # The ABSOLUTE, per-candidate confidence signal (critical fix, AC-31.2.1/.2): NEVER
  # the pool-relative, min-max-normalized `:final_score`/`:normalized_score` — those
  # force a lone/top candidate in a sparse pool to normalize to `1.0` regardless of its
  # TRUE similarity, which is exactly the false-confident-curated failure this resolver
  # exists to prevent.
  #
  # Prefers the raw `:similarity_score` (`1 - cosine_distance`, already on an absolute
  # 0..1 scale — see `search_semantic/3`) when the candidate was found in the semantic
  # pool; falls back to a BOUNDED transform of the raw `:relevance_score` (`ts_rank_cd`
  # — see `search_keyword/3`) for a keyword-only candidate. Both are ABSOLUTE (computed
  # independently of what else is in the pool), unlike `normalize_scores/2`'s output.
  # `merge_results/5` preserves BOTH raw fields on a candidate found in both pools, so
  # this always has the more-precisely-bounded semantic signal available when there is
  # one.
  defp absolute_score(%{similarity_score: score}) when is_number(score), do: score

  defp absolute_score(%{relevance_score: score}) when is_number(score),
    do: normalize_keyword_score(score)

  defp absolute_score(_result), do: 0.0

  # `ts_rank_cd` is RAW/UNBOUNDED (a short, heavily-title-weighted match can exceed
  # `1.0` — confirmed empirically up to ~2.0 for a title-exact match) — unlike cosine
  # similarity's bounded `0..1` scale. Applying the same saturating transform
  # Postgres's own `ts_rank_cd(..., normalization => 8)` uses (`rank / (rank + 1)`)
  # keeps the keyword-scale absolute score an ABSOLUTE (non-pool-relative — still a
  # pure function of the one raw score, never of what else is in the pool) but BOUNDED
  # `0..1` value: `meta.confidence` can no longer silently exceed `1.0` in keyword-only
  # mode, and the value is at least magnitude-comparable to cosine similarity (review
  # finding, US-31.2). This does NOT change `search_keyword/3`'s own public
  # `:relevance_score` field (still raw ts_rank_cd) — the transform is applied ONLY at
  # this resolver's own confidence/threshold boundary.
  defp normalize_keyword_score(raw) when is_number(raw) and raw > 0, do: raw / (raw + 1)
  defp normalize_keyword_score(_raw), do: 0.0

  defp best_score([], _scores), do: 0.0

  defp best_score(results, scores),
    do: results |> Enum.map(&Map.fetch!(scores, &1.id)) |> Enum.max()

  # Two INCOMPARABLE score scales feed `absolute_score/1` (bounded cosine similarity
  # vs. the bounded-but-differently-distributed keyword transform above) — a single
  # raw threshold/margin pair compared against BOTH scales interchangeably was the
  # defect (review finding, US-31.2). Selects the config pair matching the WINNING
  # curated candidate's OWN scale (mirroring `absolute_score/1`'s semantic-first
  # priority for a candidate present in both sub-pools); `nil` (no curated candidate at
  # all) is scale-irrelevant since `resolve_provenance/4` short-circuits to
  # `:retrieved` on a `nil` curated score regardless of which pair is passed.
  defp hybrid_curated_threshold_and_margin(%{similarity_score: score}) when is_number(score) do
    {hybrid_curated_threshold(), hybrid_curated_margin()}
  end

  defp hybrid_curated_threshold_and_margin(%{relevance_score: score}) when is_number(score) do
    {hybrid_curated_threshold_keyword(), hybrid_curated_margin_keyword()}
  end

  defp hybrid_curated_threshold_and_margin(_candidate) do
    {hybrid_curated_threshold(), hybrid_curated_margin()}
  end

  defp hybrid_search_mode(:curated), do: "hybrid_curated"
  defp hybrid_search_mode(:retrieved), do: "hybrid_retrieved"

  # Bare telemetry signal for AC-31.2.5's hit/miss + keyless observability gap
  # (finding 6): `maybe_record_search_access/5` structurally CANNOT record a MISS
  # (empty page — `article_id` is NOT NULL on `article_access_events`) or a keyless
  # call (no `api_key_id` to attribute to), so those two dimensions would otherwise be
  # invisible. This fires UNCONDITIONALLY (regardless of page emptiness or api key
  # presence) so an operator can attach a handler (or the `ScaleMetrics` counter) and
  # see EVERY provenance decision, not just the ones that happened to produce a
  # recordable DB row. Payload is id/atom/bool only — never article content or the
  # query text.
  defp emit_hybrid_provenance(tenant_id, provenance, hit?) do
    :telemetry.execute(
      Loopctl.TelemetryEvents.knowledge_hybrid_provenance(),
      %{count: 1},
      %{tenant_id: tenant_id, provenance: Atom.to_string(provenance), hit: hit?}
    )

    :ok
  end

  @doc """
  Pure resolution rule (TC-31.2.4) behind `hybrid_search/3` — no DB, unit-testable in
  isolation.

  `:curated` iff `curated_score` is present AND clears `threshold` AND beats
  `best_retrieved_score` by at least `margin`; `:retrieved` otherwise (including when
  `curated_score` is `nil` — no authoritative curated candidate was in the pool at
  all). This is the SINGLE, non-contradictory decision: AC-31.2.1 ("above threshold")
  and AC-31.2.2 ("beats retrieval by a margin, not superseded/conflicted") are both
  folded in here — the caller is responsible for only ever passing an ALREADY
  authoritative (`list_curated_sources/2`-filtered) `curated_score`, so the
  superseded/conflicted leg never reaches this pure function as a false positive.

  `threshold`/`margin` MUST already be scale-matched to `curated_score`/
  `best_retrieved_score` by the caller (`hybrid_search/3` does this via
  `hybrid_curated_threshold_and_margin/1`) — cosine similarity and (normalized)
  `ts_rank_cd` are different scales, and this function does no scale reasoning of its
  own; it only compares whatever numbers it is given.
  """
  @spec resolve_provenance(number() | nil, number(), number(), number()) ::
          :curated | :retrieved
  def resolve_provenance(nil, _best_retrieved_score, _threshold, _margin), do: :retrieved

  def resolve_provenance(curated_score, best_retrieved_score, threshold, margin)
      when is_number(curated_score) and is_number(best_retrieved_score) and
             is_number(threshold) and is_number(margin) do
    if curated_score >= threshold and curated_score - best_retrieved_score >= margin do
      :curated
    else
      :retrieved
    end
  end

  defp hybrid_curated_threshold do
    Application.get_env(
      :loopctl,
      :knowledge_hybrid_curated_threshold,
      @default_hybrid_curated_threshold
    )
  end

  defp hybrid_curated_margin do
    Application.get_env(
      :loopctl,
      :knowledge_hybrid_curated_margin,
      @default_hybrid_curated_margin
    )
  end

  defp hybrid_curated_threshold_keyword do
    Application.get_env(
      :loopctl,
      :knowledge_hybrid_curated_threshold_keyword,
      @default_hybrid_curated_threshold_keyword
    )
  end

  defp hybrid_curated_margin_keyword do
    Application.get_env(
      :loopctl,
      :knowledge_hybrid_curated_margin_keyword,
      @default_hybrid_curated_margin_keyword
    )
  end

  # --- Progressive disclosure (US-31.3) ---
  #
  # Composes ALREADY-SHIPPED subsystems into a bounded, topic-scoped stub index so
  # an agent reads a compact capped list (id/title/category/one-line summary) and
  # drills into only the chosen article(s), instead of over-retrieving many fuzzy
  # chunks. Built from `search_keyword/3` (topic match), `list_curated_sources/2`
  # (US-31.1 curated preference), a dedicated `:relates_to`-scoped hub-enrichment
  # query (NOT the general `graph_traversal/3`, which follows every relationship
  # type), and `Loopctl.Knowledge.OKF.derive_description/1` (the one-line summary).
  # Deliberately NOT the OKF full-export Markdown (`OKF.export/2`'s `index.md`),
  # which is a private, full-tenant, project-scoped listing bounded by
  # `okf_max_buffered_export_articles` — not a topic-scoped stub source (#305/#306).

  # Cap on the FINAL stub count returned by `progressive_index/3` (AC-31.3.2) — a
  # densely-linked hub cannot flood the caller's context no matter how many
  # curated neighbors it has. Configurable via `:progressive_top_k`.
  @default_progressive_top_k 10

  # Operational hub threshold (AC-31.3.4): an article counts as a hub when it has
  # AT LEAST this many outgoing `:relates_to` article_links. Hubs are emergent
  # (a link-degree fact), never a modeled type/field/tag. Configurable via
  # `:progressive_min_hub_relates_to`.
  @default_min_hub_relates_to 5

  @doc """
  The top-K cap on stubs returned by `progressive_index/3` (AC-31.3.2).
  Configurable via `:progressive_top_k` in application config; defaults to
  `#{@default_progressive_top_k}`.
  """
  @spec progressive_top_k() :: pos_integer()
  def progressive_top_k,
    do: Application.get_env(:loopctl, :progressive_top_k, @default_progressive_top_k)

  @doc """
  The outgoing `:relates_to` link-count threshold at which an article is treated
  as an operational hub for `progressive_index/3` hub enrichment (AC-31.3.4).
  Configurable via `:progressive_min_hub_relates_to` in application config;
  defaults to `#{@default_min_hub_relates_to}`.
  """
  @spec min_hub_relates_to() :: pos_integer()
  def min_hub_relates_to,
    do:
      Application.get_env(:loopctl, :progressive_min_hub_relates_to, @default_min_hub_relates_to)

  @doc """
  Progressive-disclosure entrypoint (US-31.3): for a topic/query, returns a
  COMPACT, CAPPED set of stubs — never full bodies, never the OKF full-export
  Markdown (AC-31.3.1).

  ## How the index is built

  1. **Seed** — `search_keyword/3` full-text-matches `topic` against published,
     tenant-scoped articles (title/body), returning candidate ids/titles/categories
     (no bodies). NOTE: this is a deliberate substitution for the
     `knowledge_index` catalog browse named in the story/AC — `knowledge_index`
     is a category/tag catalog with no topic scoping, so it cannot answer "for a
     topic/query" on its own; `search_keyword/3` is the topic-scoped mechanism
     that does. Caveat: a fuzzy `websearch_to_tsquery` match can silently omit a
     curated article that is topically relevant but shares no lexical tokens
     with `topic` and isn't linked from a lexically-matching hub — step 2's
     `:relates_to` traversal partially (not fully) mitigates this by recovering
     linked-but-lexically-disjoint neighbors.
  2. **Hub enrichment** (opt-out via `hub_enrich: false`) — among the seeds, any
     article with `>= min_hub_relates_to/0` outgoing `:relates_to` links is an
     operational hub (AC-31.3.4; hubs are not a modeled type). Its `:relates_to`
     targets are fetched bounded by `max_graph_neighbors_per_node/0` (the SAME
     fan-out cap `graph_traversal/3` uses elsewhere — mirrored, not
     re-implemented) and filtered down to the CURATED subset via
     `list_curated_sources/2`.
  3. **Curated preference** (AC-31.3.4) — governed curated sources (US-31.1,
     tenant-own-first, system canonicals participate per AC-31.1.3) are sorted
     ahead of non-curated matches.
  4. **Cap** — the combined, deduped candidate list is capped at `top_k`
     (AC-31.3.2); only the SURVIVING capped ids are read back (title/category/body)
     to derive each one-line summary — a dense hub's uncapped neighbors are never
     fetched at all.

  ## Parameters

  - `tenant_id` -- the tenant UUID (from the auth principal)
  - `topic` -- free-text query/topic string (same constraints as
    `search_keyword/3`: non-empty, <= 500 chars)
  - `opts` -- keyword list:
    - `:limit` -- top-K cap override (default `progressive_top_k/0`)
    - `:seed_limit` -- how many keyword-search seeds to consider before hub
      enrichment/capping (default 5x the effective top-K)
    - `:hub_enrich` -- set `false` to disable `:relates_to` hub enrichment and
      return only direct topic matches (default `true`)
    - `:category` -- restrict seed matching to a single category atom
    - `:visibility_agent_id` -- the calling agent's id (#163). Forwarded to the
      seed `search_keyword/3` call and re-applied to hub-neighbor discovery and
      the final stub projection, so another agent's `private`/`owner` memory
      never surfaces as an index stub within the same tenant. `nil` (the
      default, used by non-agent/higher-role callers) is a no-op — everything
      is visible.

  ## Returns

  - `{:ok, %{stubs: [%{id:, title:, category:, summary:}], meta: %{top_k:,
    candidate_count:, truncated:}}}` -- `truncated` is `true` when the
    (deduped) candidate pool exceeded `top_k` before capping
  - `{:error, :empty_query}` / `{:error, :bad_request, String.t()}` -- same as
    `search_keyword/3` (an empty/oversized topic is rejected before any query runs)
  """
  @spec progressive_index(Ecto.UUID.t(), String.t() | nil, keyword()) ::
          {:ok, %{stubs: [map()], meta: map()}}
          | {:error, atom()}
          | {:error, atom(), String.t()}
  def progressive_index(tenant_id, topic, opts \\ []) when is_binary(tenant_id) do
    # Clamped exactly like `search_keyword/3`'s own `:limit` (AC-31.3.2's
    # "bounded" top-K must hold even for an explicit caller override, not just
    # the default -- otherwise a densely-linked hub could still flood context).
    top_k =
      opts |> Keyword.get(:limit, progressive_top_k()) |> max(1) |> min(@max_relevance_page_size)

    seed_limit = Keyword.get(opts, :seed_limit, top_k * 5)
    hub_enrich? = Keyword.get(opts, :hub_enrich, true)
    category = Keyword.get(opts, :category)
    vis = Keyword.get(opts, :visibility_agent_id)

    with {:ok, %{results: seed_results}} <-
           search_keyword(tenant_id, topic,
             status: :published,
             limit: seed_limit,
             category: category,
             visibility_agent_id: vis,
             _skip_record_access: true
           ) do
      seed_ids = Enum.map(seed_results, & &1.id)

      hub_neighbor_ids =
        if hub_enrich? do
          progressive_hub_neighbor_ids(tenant_id, seed_ids, vis)
        else
          []
        end

      candidate_ids = Enum.uniq(seed_ids ++ hub_neighbor_ids)

      # Membership-only scan restricted to the (already small, capped) candidate
      # pool -- never the tenant's entire curated/system-canonical corpus. Mirrors
      # the `ids: raw_target_ids` scoping `progressive_hub_neighbor_ids/3` already
      # uses below.
      curated_ids =
        tenant_id
        |> list_curated_sources(select: :id, ids: candidate_ids)
        |> MapSet.new()

      {curated_first, rest} = Enum.split_with(candidate_ids, &MapSet.member?(curated_ids, &1))
      capped_ids = Enum.take(curated_first ++ rest, top_k)

      stubs =
        tenant_id
        |> fetch_stub_projection(capped_ids, vis)
        |> order_stubs(capped_ids)
        |> Enum.map(&build_stub/1)

      {:ok,
       %{
         stubs: stubs,
         meta: %{
           top_k: top_k,
           candidate_count: length(candidate_ids),
           truncated: length(candidate_ids) > top_k
         }
       }}
    end
  end

  # Hub-enrichment neighbor discovery (AC-31.3.4): finds which of the seed
  # articles are operational hubs (>= min_hub_relates_to/0 outgoing :relates_to
  # links), pulls their :relates_to targets bounded by the SAME per-node fan-out
  # cap `graph_traversal/3` uses, then narrows to the curated subset — never
  # returning a raw (potentially unbounded-fan-out) neighbor set uncurated.
  #
  # `vis` (#163): the hub targets are discovered via `ArticleLink`/
  # `list_curated_sources/2`, NEITHER of which is visibility-scoped, so a
  # private/owner memory reachable via a `:relates_to` edge is re-filtered here
  # before it can ever reach the candidate pool.
  defp progressive_hub_neighbor_ids(_tenant_id, [], _vis), do: []

  defp progressive_hub_neighbor_ids(tenant_id, seed_ids, vis) do
    hub_ids = operational_hub_ids(tenant_id, seed_ids, min_hub_relates_to())

    raw_target_ids =
      tenant_id
      |> hub_relates_to_targets(hub_ids, max_graph_neighbors_per_node())
      |> Enum.uniq()

    tenant_id
    |> list_curated_sources(select: :id, ids: raw_target_ids)
    |> filter_visible_candidate_ids(vis)
  end

  defp filter_visible_candidate_ids([], _vis), do: []
  defp filter_visible_candidate_ids(ids, nil), do: ids

  defp filter_visible_candidate_ids(ids, vis) do
    from(a in Article, where: a.id in ^ids, select: a.id)
    |> maybe_filter_by_visibility(vis)
    |> AdminRepo.all()
  end

  # Articles among `seed_ids` with >= `min_count` outgoing :relates_to links
  # (the operational hub definition, AC-31.3.4 — never a modeled type). The only
  # caller (`progressive_hub_neighbor_ids/3`) already short-circuits an empty
  # `seed_ids`, so this always receives a non-empty list.
  defp operational_hub_ids(tenant_id, seed_ids, min_count) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.relationship_type == :relates_to,
      where: l.source_article_id in ^seed_ids,
      group_by: l.source_article_id,
      having: count(l.id) >= ^min_count,
      select: l.source_article_id
    )
    |> AdminRepo.all()
  end

  # Depth-1 :relates_to targets of EVERY hub in `hub_ids`, bounded PER HUB at
  # the SQL level by `ROW_NUMBER() OVER (PARTITION BY source_article_id ...) <=
  # fanout_limit` -- the same fan-out cap (mirrors the `JOIN LATERAL ... LIMIT`
  # bound `execute_graph_traversal/4` uses, without pulling in the general
  # multi-hop/all-relationship-type traversal), but in ONE round-trip regardless
  # of hub count instead of one query per hub (review finding: bounded N+1).
  defp hub_relates_to_targets(_tenant_id, [], _fanout_limit), do: []

  defp hub_relates_to_targets(tenant_id, hub_ids, fanout_limit) do
    ranked =
      from(l in ArticleLink,
        where: l.tenant_id == ^tenant_id,
        where: l.relationship_type == :relates_to,
        where: l.source_article_id in ^hub_ids,
        select: %{
          target_article_id: l.target_article_id,
          rank:
            over(row_number(),
              partition_by: l.source_article_id,
              order_by: [asc: l.inserted_at, asc: l.id]
            )
        }
      )

    from(r in subquery(ranked),
      where: r.rank <= ^fanout_limit,
      select: r.target_article_id
    )
    |> AdminRepo.all()
  end

  # Body/metadata projection for ONLY the (already-capped) final candidate ids —
  # a dense hub's uncapped neighbors never reach this query. `tenant_id or scope
  # == :system` mirrors the explicit tenant-plus-system-canonical predicate used
  # throughout this module (AC-31.3.4 tenant isolation; system participates per
  # US-31.1 AC-31.1.3). `maybe_filter_by_visibility/2` is the LAST line of
  # defense-in-depth for #163: the seed and hub-neighbor pools are already
  # visibility-filtered upstream (`search_keyword/3`, `filter_visible_candidate_ids/2`),
  # but this is the query that actually reads title/body — it must never trust
  # the caller wired only one of those two upstream gates correctly.
  defp fetch_stub_projection(_tenant_id, [], _vis), do: []

  defp fetch_stub_projection(tenant_id, ids, vis) do
    from(a in Article,
      where: a.id in ^ids,
      where: a.tenant_id == ^tenant_id or a.scope == :system,
      select: %{
        id: a.id,
        title: a.title,
        category: a.category,
        body: a.body,
        metadata: a.metadata
      }
    )
    |> maybe_filter_by_visibility(vis)
    |> AdminRepo.all()
  end

  # `WHERE id IN (...)` has no defined row order — re-impose the curated-first,
  # capped candidate order the caller already computed.
  defp order_stubs(articles, ordered_ids) do
    by_id = Map.new(articles, &{&1.id, &1})

    ordered_ids
    |> Enum.map(&Map.get(by_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp build_stub(article) do
    %{
      id: article.id,
      title: article.title,
      category: article.category,
      summary: OKF.derive_description(article)
    }
  end

  @doc """
  Drill step (US-31.3, AC-31.3.3): fetches the full body of a single article a
  `progressive_index/3` stub pointed at, scope-enforced exactly like a direct
  fetch.

  Mirrors `progressive_index/3`'s OWN scope (AC-31.3.3 vs AC-31.3.4
  consistency): `progressive_index/3` surfaces both tenant-owned articles AND
  system-scope (`tenant_id: nil`) curated canonicals (`fetch_stub_projection/3`
  reads `where a.tenant_id == ^tenant_id or a.scope == :system`), so the drill
  step must be able to open EITHER. It tries the tenant-scoped fetch first
  (`get_article/3`); only when that misses does it fall back to the
  system-scope-by-id lookup (the same predicate `fetch_curatable_article/2`
  uses for curation) so a system canonical's `tenant_id: nil` never falls
  through to a false `:not_found`. A tenant-owned article never matches the
  system-scope fallback (system articles require `scope: :system`), so tenant
  isolation is unaffected — the fallback only ever *widens* what a tenant-scoped
  `:not_found` was allowed to catch, onto the same system-canonical set the
  index already surfaces.
  """
  @spec progressive_drill(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Article.t()} | {:error, :not_found}
  def progressive_drill(tenant_id, article_id, opts \\ []) do
    case get_article(tenant_id, article_id, opts) do
      {:error, :not_found} -> drill_system_canonical(tenant_id, article_id, opts)
      result -> result
    end
  end

  defp drill_system_canonical(tenant_id, article_id, opts) do
    # `status == :published` (mirrors `get_system_article_by_slug/1` and
    # `list_system_articles/1`) -- this is the ONLY tenant-facing read path for
    # a system canonical's body (get_article/2 requires a tenant_id match,
    # which nil-tenant system rows never satisfy), so unlike
    # `fetch_curatable_article/2` (the privileged, role-gated curation path
    # that legitimately needs drafts), this must never expose a draft or
    # archived system canonical by id.
    case AdminRepo.one(
           from(a in Article,
             where: a.id == ^article_id and a.scope == :system and a.status == :published
           )
         ) do
      nil -> {:error, :not_found}
      article -> finalize_article_read(tenant_id, article, opts)
    end
  end

  # --- Circuit breaker for embedding generation ---

  @circuit_breaker_table :loopctl_embedding_circuit_breaker
  @failure_threshold 3
  @failure_window_seconds 60
  # Base breaker cooldown (seconds). US-37.3: env-driven via SystemConfig
  # (`"embedding_breaker_cooldown_seconds"`) so it is tunable without a deploy; the
  # in-code default doubles as the documented default. A provider Retry-After
  # RAISES this floor (see `cooldown_seconds/1`), clamped to the SystemConfig max.
  @cooldown_seconds 30
  # Ceiling (seconds) the breaker's open cooldown is clamped to — the embedding-
  # breaker-specific max, env-driven via `"embedding_breaker_max_cooldown_seconds"`.
  # Deliberately distinct from the provider-generic `RetryAfter.max_seconds/0`.
  @max_cooldown_seconds 300
  # US-37.3 latency trip (AC-37.3.4): consecutive/windowed slow-but-successful
  # provider calls trip the breaker (slow-but-alive protection). Both knobs are
  # env-driven via SystemConfig; a threshold of 0 (the default) DISABLES the
  # latency trip entirely (disabled-safe).
  @default_latency_threshold_ms 0
  @default_latency_count 5

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

  # Reset ONLY the given tenant's breaker state. Preferred over
  # `reset_circuit_breaker/0` in async tests: the breaker is tenant-scoped, so a
  # global `delete_all_objects` would race concurrent tests and wipe each other's
  # per-tenant counts.
  @doc false
  def reset_circuit_breaker(tenant_id) when is_binary(tenant_id) do
    if :ets.whereis(@circuit_breaker_table) != :undefined do
      clear_tenant_breaker(tenant_id, System.monotonic_time(:second))
    end

    :ok
  end

  @doc """
  Remaining open-cooldown (seconds) for a tenant's embedding circuit breaker, or
  `0` when the breaker is closed/absent.

  US-37.3 (AC-37.3.5): lets an Oban embedding worker snooze for ~the remaining open
  window on `{:error, :circuit_open}` — a LOSS-FREE reschedule that consumes no
  attempt — instead of returning `{:error, ...}`, which burns a `max_attempts`
  budget. With a honored Retry-After cooldown up to the breaker max (300s) able to
  exceed a job's whole 4-attempt window, the `{:error, ...}` path would DISCARD the
  job and leave the article/memory permanently un-embedded (there is no embedding
  backfill). Snoozing avoids that.
  """
  @spec circuit_breaker_cooldown_remaining(Ecto.UUID.t()) :: non_neg_integer()
  def circuit_breaker_cooldown_remaining(tenant_id) when is_binary(tenant_id) do
    ensure_circuit_breaker_table()
    key = {tenant_id, :open_until}

    case :ets.lookup(@circuit_breaker_table, key) do
      [{^key, open_until}] -> max(0, open_until - System.monotonic_time(:second))
      [] -> 0
    end
  end

  # Task.yield budget for a query embedding. Kept STRICTLY ABOVE the embedding
  # client's own worst-case (single-attempt receive_timeout, no client retries —
  # see EmbeddingClient) so a slow-but-valid embed completes inside the yield and is
  # never killed-then-miscounted as a breaker failure (review #10).
  @embedding_yield_ms 5_000

  @doc """
  Generate an embedding for the given text with a PER-TENANT circuit breaker and
  timeout protection.

  Resolves the TENANT's OWN embedding key (mandatory BYO) via the configured
  embedding client, wrapped with:
  - A tenant-scoped circuit breaker (opens for a tenant after #{@failure_threshold}
    COUNTABLE failures within #{@failure_window_seconds}s — so a failing tenant only
    degrades ITSELF, never other tenants; review #1).
  - A per-node concurrency cap (US-37.2): `run_embedding_task/3` `acquire`s a slot
    from `Loopctl.Knowledge.EmbeddingConcurrency` before spawning the task and
    releases it after, so this SINGLE entry point bounds concurrent outbound embeds
    across the interactive path AND both Oban embedding workers. Over the cap it
    fast-fails with `{:error, :rate_limited_local}` (keyword fallback / worker snooze).
  - A `#{@embedding_yield_ms}`ms `Task.Supervisor.async_nolink` yield budget (review
    #10; US-37.2 supervises the task so its crash never crashes the caller).
  - A crash rescue handler.

  Returns `{:ok, embedding}` or `{:error, reason}`.

  ## What counts toward the breaker (US-37.3 — 4xx SPLIT)

  The blanket "all 4xx are exempt" rule is GONE. The 4xx class is now split by
  cause:

    * **429 / 408 (THROTTLE)** — COUNT toward the breaker. A sustained rate-limit
      storm is a systemic signal: counting it lets the breaker open so the
      interactive path sheds to keyword search and the workers snooze, instead of
      hot-retrying into a throttling provider. When the throttle response carried a
      provider `Retry-After`, that value RAISES the cooldown (see
      `cooldown_seconds/1`).
    * **401 / 403 (and other 4xx) — CREDENTIAL/request problems** — remain EXEMPT.
      A per-tenant bad/revoked key must never open a breaker that would degrade
      every tenant (review #1).
    * `{:error, :no_api_key}` (a per-tenant config gap) and
      `{:error, :rate_limited_local}` (US-37.1 node-local admission backpressure —
      self-imposed, not a provider failure) remain EXEMPT.
    * 5xx / transport / timeout / crash still count.
    * **Latency (AC-37.3.4)** — a run of slow-but-SUCCESSFUL calls (over the
      configured `"embedding_breaker_latency_threshold_ms"`, disabled at 0) also
      trips the breaker (slow-but-alive protection).

  This is the single guarded entry point — the embedding worker and the proposal
  gate route through it too (review #4) so circuit-open is both respected AND
  contributed to.

  It is ALSO the single choke point for the `[:loopctl, :llm, :provider_error]`
  telemetry signal's embedding half (US-34.3 AC-34.3.3, review MED #1): both Oban
  workers (`ArticleEmbeddingWorker`/`MemoryEmbeddingWorker`) AND every query-time
  caller (combined/semantic search, novelty scoring, `Memory.recall/2`, promotion
  near-dup lookup) funnel through here, so recording the signal in
  `run_embedding_task/3` — rather than per-worker after this function returns —
  covers every embedding path exactly once, with the same breaker-countable gate
  and no double-count. NOTE (US-37.3): because 429/408 now COUNT, they also emit
  the storm signal as `:transient` (throttle IS a systemic signal now) — the
  intended consequence of the split; a per-tenant 401/403 still never contributes.

  `opts`:
    * `:timeout` — Task.yield budget in ms (default `#{@embedding_yield_ms}`).
  """
  @spec generate_embedding(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, [float()]} | {:error, term()}
  def generate_embedding(tenant_id, query_string, opts \\ []) when is_binary(tenant_id) do
    try_generate_embedding(tenant_id, query_string, opts)
  end

  defp try_generate_embedding(tenant_id, query_string, opts) do
    ensure_circuit_breaker_table()

    if circuit_open?(tenant_id) do
      {:error, :circuit_open}
    else
      timeout = Keyword.get(opts, :timeout, @embedding_yield_ms)
      run_embedding_task(tenant_id, query_string, timeout)
    end
  end

  # US-37.2: gate EVERY outbound embedding on a per-node concurrency cap BEFORE
  # spawning the task, so the interactive query path AND both Oban embedding workers
  # (which route through here via generate_embedding/3) share ONE real node ceiling
  # (GH #352) — a GLOBAL cap plus a per-tenant sub-cap so one tenant's burst can't
  # starve every other tenant's semantic search. The acquire is charged to THIS
  # (request/worker) process for the request's tenant and released in an `after` so a
  # yield-timeout shutdown or an in-task crash still frees the slot; a crash of THIS
  # process is reclaimed by the gate's monitor. Over EITHER cap (or if the gate
  # GenServer is down), acquire fast-fails with {:error, :rate_limited_local} — the
  # breaker-exempt reason
  # (see breaker_countable?/1) the combined-search branch turns into a keyword-only
  # fallback and the workers snooze on — so the interactive path degrades gracefully
  # instead of blocking, and NO circuit-breaker / provider-error signal is recorded
  # (self-imposed backpressure is not a provider failure).
  defp run_embedding_task(tenant_id, query_string, timeout) do
    case embedding_concurrency().acquire(tenant_id) do
      :ok ->
        try do
          run_capped_embedding_task(tenant_id, query_string, timeout)
        after
          embedding_concurrency().release(tenant_id)
        end

      {:error, :rate_limited_local} = err ->
        err
    end
  end

  defp run_capped_embedding_task(tenant_id, query_string, timeout) do
    # Task.Supervisor.async_nolink so an embedding task crash surfaces as
    # {:exit, reason} from Task.yield (the `_ ->` clause -> {:error, :timeout})
    # rather than crashing THIS process (AC-37.2.5). The inner rescue still catches
    # embedding-client exceptions and returns {:error, {:embedding_crash, ...}};
    # async_nolink additionally protects against exits the rescue can't catch.
    # US-37.3 (AC-37.3.4): measure wall-clock per guarded call so a slow-but-alive
    # provider can trip the breaker on latency (not just on hard failures).
    started_ms = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(Loopctl.Knowledge.EmbeddingTaskSupervisor, fn ->
        try do
          embedding_client().generate_embedding(tenant_id, query_string)
        rescue
          e -> {:error, {:embedding_crash, Exception.message(e)}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, embedding}} ->
        record_call_outcome(tenant_id, System.monotonic_time(:millisecond) - started_ms)
        {:ok, embedding}

      # A missing tenant key is a config gap, not a provider failure — do NOT
      # record it against the (now tenant-scoped) circuit breaker.
      {:ok, {:error, :no_api_key}} ->
        {:error, :no_api_key}

      {:ok, {:error, reason} = err} ->
        maybe_record_failure(tenant_id, reason)
        maybe_record_provider_error(reason)
        err

      _ ->
        # nil (yield timeout), an abnormal task exit, or an async_nolink task crash
        # surfacing as {:exit, reason} — a provider/infra failure.
        record_failure(tenant_id)
        maybe_record_provider_error(:timeout)
        {:error, :timeout}
    end
  end

  @doc """
  US-37.4: batch variant of `generate_embedding/3` — embeds a LIST of texts in ONE
  provider round-trip, reusing the SAME per-tenant circuit breaker, per-node
  concurrency gate, latency telemetry, and error classification as the single-text
  path (ONE slot + ONE breaker signal per batch, not per text).

  Used ONLY by the truly-bulk background ingest path (`BatchArticleEmbeddingWorker`).
  The interactive single-query path stays on `generate_embedding/3` (latency-sensitive).

  Returns `{:ok, vectors}` with vectors in the SAME order as `texts`, or
  `{:error, reason}` (the whole batch fails/retries as a unit — never a partial
  half-write of vectors). An empty list returns `{:ok, []}` WITHOUT acquiring a slot
  or hitting the breaker.

  `opts`:
    * `:timeout` — Task.yield budget in ms (default `#{@embedding_yield_ms}`).
  """
  @spec generate_embeddings(Ecto.UUID.t(), [String.t()], keyword()) ::
          {:ok, [[float()]]} | {:error, term()}
  def generate_embeddings(tenant_id, texts, opts \\ [])
      when is_binary(tenant_id) and is_list(texts) do
    if texts == [] do
      {:ok, []}
    else
      try_generate_embeddings(tenant_id, texts, opts)
    end
  end

  defp try_generate_embeddings(tenant_id, texts, opts) do
    ensure_circuit_breaker_table()

    if circuit_open?(tenant_id) do
      {:error, :circuit_open}
    else
      timeout = Keyword.get(opts, :timeout, @embedding_yield_ms)
      run_embeddings_task(tenant_id, texts, timeout)
    end
  end

  # Mirrors `run_embedding_task/3`: ONE concurrency slot for the WHOLE batch
  # (US-37.2 — a batch is one outbound call, so it charges one slot), released in an
  # `after`. Over the cap → `{:error, :rate_limited_local}` (worker snoozes).
  defp run_embeddings_task(tenant_id, texts, timeout) do
    case embedding_concurrency().acquire(tenant_id) do
      :ok ->
        try do
          run_capped_embeddings_task(tenant_id, texts, timeout)
        after
          embedding_concurrency().release(tenant_id)
        end

      {:error, :rate_limited_local} = err ->
        err
    end
  end

  # Mirrors `run_capped_embedding_task/3` (supervised async_nolink, breaker/
  # provider-error recording) but calls the client's BATCH callback. ONE breaker
  # signal per batch — a batch failure counts once, not per text. UNLIKE the single
  # path it is EXEMPT from latency-based tripping (a batch's wall-clock is inherently
  # larger than one text; see the success clause below).
  defp run_capped_embeddings_task(tenant_id, texts, timeout) do
    started_ms = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(Loopctl.Knowledge.EmbeddingTaskSupervisor, fn ->
        try do
          embedding_client().generate_embeddings(tenant_id, texts)
        rescue
          e -> {:error, {:embedding_crash, Exception.message(e)}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, vectors}} ->
        # Review (LOW #5): the batch path is EXEMPT from latency-based breaker
        # tripping. `started_ms` here is the WHOLE-batch wall-clock (~100 texts),
        # inherently far larger than one interactive text; scoring it against the
        # single-call `embedding_breaker_latency_threshold_ms` would treat normal
        # batch latency as a "slow call" and could falsely trip the per-tenant
        # breaker (degrading that tenant to keyword search). A successful batch is
        # full health → just clear the tenant's breaker state (no slow-call count).
        # (Failure/timeout still counts below, exactly like the single path.)
        _elapsed_ms = System.monotonic_time(:millisecond) - started_ms
        record_success(tenant_id)
        {:ok, vectors}

      {:ok, {:error, :no_api_key}} ->
        {:error, :no_api_key}

      {:ok, {:error, reason} = err} ->
        maybe_record_failure(tenant_id, reason)
        maybe_record_provider_error(reason)
        err

      _ ->
        record_failure(tenant_id)
        maybe_record_provider_error(:timeout)
        {:error, :timeout}
    end
  end

  defp maybe_record_failure(tenant_id, reason) do
    # US-37.3: a throttle error may carry a provider Retry-After — thread it so the
    # breaker cooldown honors it (see `record_failure/2` -> `cooldown_seconds/1`).
    if breaker_countable?(reason),
      do: record_failure(tenant_id, RetryAfter.from_error(reason))

    :ok
  end

  # US-34.3 (AC-34.3.3) fix (review MED #1): the SINGLE choke point for the
  # embedding half of the `[:loopctl, :llm, :provider_error]` signal. Both Oban
  # workers (`ArticleEmbeddingWorker`/`MemoryEmbeddingWorker`) AND every query-time
  # caller (combined/semantic search, novelty scoring, `Memory.recall/2`, promotion
  # near-dup lookup) funnel through `run_embedding_task/3`, so recording here —
  # instead of per-worker after `generate_embedding/3` returns — covers every
  # embedding path exactly once with no double-count.
  #
  # Gated by the SAME `breaker_countable?/1` classification the circuit breaker
  # uses: a per-tenant CREDENTIAL 4xx (401/403) is never a systemic provider
  # incident, so it must never inflate this fleet-wide storm signal — exactly like
  # it must never trip the breaker. US-37.3: a THROTTLE 4xx (429/408) now DOES
  # count (throttle is a systemic signal), so it is recorded here as `:transient`.
  # `:no_api_key` and `:circuit_open` never reach this function (handled by earlier
  # `case` clauses in `run_embedding_task/3`), so no explicit exclusion is needed.
  defp maybe_record_provider_error(reason) do
    if breaker_countable?(reason) do
      class = if Loopctl.Llm.permanent_provider_error?(reason), do: :permanent, else: :transient
      Loopctl.Llm.record_provider_error("embedding", class)
    end

    :ok
  end

  # US-37.3 — 4xx SPLIT. The blanket 4xx exemption is gone; the class is split by
  # cause:
  #   * 429 (Too Many Requests) / 408 (Request Timeout) are THROTTLE signals — they
  #     COUNT. A sustained rate-limit storm is systemic, not per-tenant: counting it
  #     lets the breaker open so the interactive path sheds to keyword and the
  #     workers snooze, instead of hot-retrying into a throttling provider.
  #   * 401 / 403 (and every other 4xx) are per-tenant CREDENTIAL/request problems —
  #     EXEMPT, so one tenant's bad/revoked key never opens a breaker that would
  #     degrade every tenant sharing it (review #1). Mirrors the `:no_api_key` exemption.
  #   * 5xx counts (systemic outage). The throttle 4-tuple carries a Retry-After but
  #     classifies identically to its 3-tuple form.
  defp breaker_countable?({:api_error, status, _, _}) when status in [408, 429], do: true

  defp breaker_countable?({:api_error, status, _, _})
       when is_integer(status) and status >= 500,
       do: true

  defp breaker_countable?({:api_error, status, _, _}) when is_integer(status), do: false

  defp breaker_countable?({:api_error, status, _}) when status in [408, 429], do: true

  defp breaker_countable?({:api_error, status, _}) when is_integer(status) and status >= 500,
    do: true

  defp breaker_countable?({:api_error, status, _}) when is_integer(status), do: false

  defp breaker_countable?({:api_error, status}) when status in [408, 429], do: true

  defp breaker_countable?({:api_error, status}) when is_integer(status) and status >= 500,
    do: true

  defp breaker_countable?({:api_error, _status}), do: false
  defp breaker_countable?({:request_failed, _}), do: true
  defp breaker_countable?({:embedding_crash, _}), do: true
  defp breaker_countable?(:timeout), do: true
  defp breaker_countable?(:circuit_open), do: false
  # US-37.1 (AC-37.1.3): a node-local admission rate-limit is a self-imposed,
  # defensive fast-fail — NOT a provider failure. It must never count toward the
  # circuit breaker NOR the `[:loopctl, :llm, :provider_error]` storm signal
  # (both gate on `breaker_countable?/1`); otherwise our own backpressure would
  # trip the breaker and degrade every tenant.
  defp breaker_countable?(:rate_limited_local), do: false
  # Unknown/other transport-ish failures: count (conservative — a real outage).
  defp breaker_countable?(_), do: true

  defp circuit_open?(tenant_id) do
    key = {tenant_id, :open_until}

    case :ets.lookup(@circuit_breaker_table, key) do
      [{^key, open_until}] -> check_open_until(tenant_id, open_until)
      [] -> false
    end
  end

  defp check_open_until(tenant_id, open_until) do
    now = System.monotonic_time(:second)

    if now < open_until do
      true
    else
      # Cooldown expired — clear this tenant's breaker state.
      clear_tenant_breaker(tenant_id, now)
      false
    end
  end

  defp record_failure(tenant_id), do: record_failure(tenant_id, nil)

  # The failure counter is keyed by the WINDOW PERIOD (review #2): each rolling
  # window is a DISTINCT ETS key, so an expired window is simply a different key —
  # there is no non-atomic "check the timestamp, then reset the counter in place"
  # step to race. `update_counter/4` is the sole, atomic mutation, so a burst of
  # concurrent failures for one tenant counts reliably to the threshold.
  #
  # US-37.3: `retry_after` (seconds, or nil) is a provider Retry-After parsed from a
  # throttle response — it RAISES the cooldown floor when the breaker opens (see
  # `cooldown_seconds/1`) so we back off for at least as long as the provider asked.
  defp record_failure(tenant_id, retry_after) do
    ensure_circuit_breaker_table()
    now = System.monotonic_time(:second)
    period = period_for(now)

    # Bound ETS growth: the previous window's counter can never grow again, so drop
    # it. (At most one stale key per tenant survives between failures.)
    :ets.delete(@circuit_breaker_table, failures_key(tenant_id, period - 1))

    count =
      :ets.update_counter(
        @circuit_breaker_table,
        failures_key(tenant_id, period),
        {2, 1},
        {failures_key(tenant_id, period), 0}
      )

    if count >= @failure_threshold do
      open_breaker(tenant_id, now, retry_after)
    end

    :ok
  end

  # US-37.3 (AC-37.3.4): classify a SUCCESSFUL call's latency. A fast/normal
  # success clears the tenant's breaker state (full health); a SLOW success
  # (over the configured threshold) records a slow-call toward the latency trip.
  # Disabled-safe: a threshold of 0/unset means the latency trip never fires and a
  # success always just clears state (identical to pre-US-37.3 behavior).
  defp record_call_outcome(tenant_id, elapsed_ms) do
    threshold = latency_threshold_ms()

    if threshold > 0 and elapsed_ms > threshold do
      record_slow_call(tenant_id)
    else
      record_success(tenant_id)
    end
  end

  # Slow-but-alive protection. Mirrors the failure-window counter but on a distinct
  # `:slow` key, so a run of slow successes within the window trips the breaker
  # WITHOUT a fast success in between resetting it (a fast success clears both
  # counters via `record_success/1` -> `clear_tenant_breaker/2`). The cooldown here
  # uses the base cooldown (no provider Retry-After on a 200).
  defp record_slow_call(tenant_id) do
    ensure_circuit_breaker_table()
    now = System.monotonic_time(:second)
    period = period_for(now)

    :ets.delete(@circuit_breaker_table, slow_key(tenant_id, period - 1))

    count =
      :ets.update_counter(
        @circuit_breaker_table,
        slow_key(tenant_id, period),
        {2, 1},
        {slow_key(tenant_id, period), 0}
      )

    if count >= latency_count() do
      open_breaker(tenant_id, now, nil)
    end

    :ok
  end

  defp open_breaker(tenant_id, now, retry_after) do
    :ets.insert(
      @circuit_breaker_table,
      {{tenant_id, :open_until}, now + cooldown_seconds(retry_after)}
    )
  end

  # Cooldown (seconds) the breaker stays open. US-37.3: a provider Retry-After
  # RAISES the floor (back off at least as long as asked), bounded by the
  # SystemConfig max so a hostile header can't wedge the breaker open. Absent
  # Retry-After keeps the base cooldown.
  defp cooldown_seconds(nil), do: base_cooldown_seconds()

  defp cooldown_seconds(retry_after) when is_integer(retry_after) do
    retry_after |> max(base_cooldown_seconds()) |> min(max_cooldown_seconds())
  end

  defp base_cooldown_seconds do
    SystemConfig.get_int("embedding_breaker_cooldown_seconds", @cooldown_seconds)
  end

  # The breaker's OWN open-cooldown ceiling — an embedding-breaker-specific key,
  # NOT the provider-generic `RetryAfter.max_seconds/0` (which serves the Anthropic
  # client too). Keeping them separate lets an operator cap how long the embedding
  # breaker stays open without moving the shared Retry-After parser's ceiling.
  # Defaults to the same 300s, so behavior is unchanged until the key is tuned.
  defp max_cooldown_seconds do
    SystemConfig.get_int("embedding_breaker_max_cooldown_seconds", @max_cooldown_seconds)
  end

  defp latency_threshold_ms do
    SystemConfig.get_int("embedding_breaker_latency_threshold_ms", @default_latency_threshold_ms)
  end

  defp latency_count do
    SystemConfig.get_int("embedding_breaker_latency_count", @default_latency_count)
  end

  defp record_success(tenant_id) do
    ensure_circuit_breaker_table()
    clear_tenant_breaker(tenant_id, System.monotonic_time(:second))
    :ok
  end

  # Delete ALL of a tenant's breaker state: the open flag + the current and previous
  # window counters for BOTH the failure and the slow (latency) windows (a failure /
  # slow call is always in one of the two periods).
  defp clear_tenant_breaker(tenant_id, now) do
    period = period_for(now)
    :ets.delete(@circuit_breaker_table, {tenant_id, :open_until})
    :ets.delete(@circuit_breaker_table, failures_key(tenant_id, period))
    :ets.delete(@circuit_breaker_table, failures_key(tenant_id, period - 1))
    :ets.delete(@circuit_breaker_table, slow_key(tenant_id, period))
    :ets.delete(@circuit_breaker_table, slow_key(tenant_id, period - 1))
    :ok
  end

  defp failures_key(tenant_id, period), do: {tenant_id, :failures, period}
  defp slow_key(tenant_id, period), do: {tenant_id, :slow, period}

  defp period_for(now), do: div(now, @failure_window_seconds)

  defp ensure_circuit_breaker_table do
    if :ets.whereis(@circuit_breaker_table) == :undefined do
      init_circuit_breaker()
    end
  end

  defp embedding_client do
    Application.get_env(:loopctl, :embedding_client, Loopctl.Knowledge.EmbeddingClient)
  end

  # US-37.2: the per-node embedding-concurrency gate, resolved via config-based DI
  # (like embedding_client/0 above) so config/test.exs can swap in
  # Loopctl.MockEmbeddingConcurrency — letting a saturation test force
  # {:error, :rate_limited_local} deterministically without holding the real,
  # VM-wide global counter saturated (which would starve unrelated async searches).
  defp embedding_concurrency do
    Application.get_env(
      :loopctl,
      :embedding_concurrency,
      Loopctl.Knowledge.EmbeddingConcurrency
    )
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
    base =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.status == :published
      )

    # Defense in depth: a non-UUID project_id would raise Ecto.Query.CastError on
    # the `== ^project_id` binary_id comparison. Callers 422 before reaching here;
    # a malformed value that slips through scopes to tenant-wide articles only
    # (nil project) rather than crashing.
    if valid_uuid?(project_id) do
      where(base, [a], is_nil(a.project_id) or a.project_id == ^project_id)
    else
      where(base, [a], is_nil(a.project_id))
    end
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

    links = links_query |> scope_contradiction_links(project_id) |> AdminRepo.all()

    # Build clusters using union-find approach (group connected articles)
    build_contradiction_clusters(links)
  end

  # Scope contradiction links to a project, guarding the :binary_id cast. A
  # non-UUID project_id (e.g. `?project_id[]=x` decodes to a truthy list) would
  # otherwise CastError-500 on the `== ^project_id` comparison; a malformed value
  # scopes to tenant-wide (nil-project) links only rather than crashing.
  defp scope_contradiction_links(query, nil), do: query

  defp scope_contradiction_links(query, project_id) do
    if valid_uuid?(project_id) do
      from([al, src, tgt] in query,
        where:
          (is_nil(src.project_id) or src.project_id == ^project_id) and
            (is_nil(tgt.project_id) or tgt.project_id == ^project_id)
      )
    else
      from([al, src, tgt] in query,
        where: is_nil(src.project_id) and is_nil(tgt.project_id)
      )
    end
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
