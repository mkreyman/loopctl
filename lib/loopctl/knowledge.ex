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
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Custody
  alias Loopctl.DbCapacity
  alias Loopctl.Egress
  alias Loopctl.Egress.Policy, as: EgressPolicy
  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Embeddings
  alias Loopctl.ExitClass
  alias Loopctl.ExitTag
  alias Loopctl.HeavyRead
  alias Loopctl.HeavyRead.TenantGate
  alias Loopctl.KeysetSeek
  alias Loopctl.Knowledge.Analytics
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleAccessEvent
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.ConflictResolution
  alias Loopctl.Knowledge.EmbeddingConcurrency
  alias Loopctl.Knowledge.KbCuration
  alias Loopctl.Knowledge.OKF
  alias Loopctl.Knowledge.RankingPriors
  alias Loopctl.Knowledge.Reranker
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Llm.ProviderError
  alias Loopctl.LocalGuc
  alias Loopctl.Projects.Project
  alias Loopctl.Provider.RetryAfter
  alias Loopctl.Search.Regconfig
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
    project_id = attrs[:project_id] || attrs["project_id"]
    vis = Keyword.get(opts, :visibility_agent_id)
    effective_tenant_id = effective_tenant_id(tenant_id, attrs)

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
      # AuditContext impersonation trail (impersonated_by / impersonated_at /
      # effective_role) when a superadmin impersonates; %{} for direct writes. Recorded on
      # the article's audit entry so an impersonated create is fully attributable.
      audit_metadata = Keyword.get(opts, :metadata, %{})

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
            metadata: audit_metadata,
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
        # US-41.7 (AC-41.7.1/.2): assign this row's operation-0 sequence number and
        # record the RESOLVED egress posture for the create INSIDE the content
        # transaction. Cheap (one INSERT on the transaction's own connection) — the
        # chain append is batched out to Oban, never a per-article AdminRepo
        # round-trip (AC-41.7.7). A no-op unless the scope is marked `local_only`.
        |> maybe_assign_custody_sequence(tenant_id, opts)

      case AdminRepo.transaction(multi) do
        {:ok, %{article: article} = changes} ->
          # Only enqueue the flush when a sequence was ACTUALLY assigned. The
          # predominantly non-local_only tenant base assigns nothing, and adding an
          # unconditional Oban insert (plus a periodic no-op AdminRepo flush) to
          # every article create is exactly the hot-path cost AC-41.7.7 makes a
          # design constraint rather than an assertion.
          maybe_enqueue_custody_flush(tenant_id, changes)
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
      If that canonical article vanished between assess and now the proposal is
      created on the normal path — except under `on_low_novelty: :skip`, which is
      honoured here too (`:duplicate` is the HIGHER-overlap band, so falling through
      would create exactly what the caller opted out of).
    * `:low_novelty` — high overlap with existing knowledge. The article is created
      as a **draft** (downgraded from publish if needed) with the near-neighbors
      stamped into `metadata.proposal_novelty`, so the smarter consuming agent (or a
      human) resolves merge-vs-keep from the drafts review queue. Pass
      `on_low_novelty: :skip` to create **nothing** instead — for an UNATTENDED writer
      with no reviewer behind it, whose drafts would otherwise pile up as corpus debris.
      The verdict is then `:skipped_low_novelty` with the near-neighbor in `:article`
      (or `nil` if it vanished), and `created: false`. A skip is decided LAST: an
      invalid `project_id` or a payload the create changeset rejects still errors, and a
      proposal naming an existing row by IDENTITY (`idempotency_key`, or an exact active
      title) is still answered as `:deduplicated` / `{:error, :duplicate_title, _}`
      rather than dropped.
    * `:novel` / `:unknown` (gate fell open) — created on the requested path.

  The gate is mechanical and non-destructive: it never edits or deletes existing
  articles, and it falls open (`:unknown`) rather than blocking a write when the
  embedding backend is unavailable.

  Pass `on_gate_unavailable: :skip` (default `:create`) so a fell-open `:unknown`
  assessment returns `{:error, :gate_unavailable}` WITHOUT creating — for automated
  callers that must not inject an un-deduplicated article during an embedding outage and
  would rather retry once the gate can assess. Pass `embedding: vector` to reuse an
  already-computed embedding of the assessed text instead of generating a new one.

  Returns `{:ok, result}` where `result` is a map:

      %{
        verdict: :created | :gated_to_draft | :skipped_low_novelty | :duplicate | :deduplicated,
        article: %Article{} | nil,  # the created article, or the canonical existing one;
                                    # nil only for :skipped_low_novelty (neighbor vanished)
        created: boolean(),         # false for :duplicate / :deduplicated / :skipped_low_novelty
        assessment: %{verdict:, score:, neighbors:}
      }

  or `{:error, :duplicate_title, %Article{}}` / `{:error, %Ecto.Changeset{}}`,
  forwarded unchanged from `create_article/3`.
  """
  @spec propose_article(Ecto.UUID.t() | nil, map(), keyword()) ::
          {:ok, map()}
          | {:error, :duplicate_title, Article.t()}
          | {:error, :gate_unavailable}
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
      # there is nothing to dedup against, so create on the normal path. EXCEPT under
      # `on_low_novelty: :skip`: `:duplicate` is the higher-overlap band, so creating
      # here would publish for a caller that opted out of creating at LESS overlap —
      # inverting the option's own contract on the rarer, harder-to-notice branch.
      :error ->
        if Keyword.get(opts, :on_low_novelty, :draft) == :skip do
          skip_low_novelty(tenant_id, attrs, assessment, opts)
        else
          create_proposal(tenant_id, attrs, %{assessment | verdict: :novel}, opts, :created)
        end
    end
  end

  defp gate_proposal(tenant_id, attrs, %{verdict: :low_novelty} = assessment, opts) do
    if Keyword.get(opts, :on_low_novelty, :draft) == :skip do
      skip_low_novelty(tenant_id, attrs, assessment, opts)
    else
      gated_attrs =
        attrs
        |> Map.put("status", "draft")
        |> stamp_proposal_metadata(assessment)

      neighbor = List.first(assessment.neighbors)
      log_gate(tenant_id, "gate_draft", "drafted (high overlap)", neighbor, assessment, opts)
      create_proposal(tenant_id, gated_attrs, assessment, opts, :gated_to_draft)
    end
  end

  # :unknown — the gate FELL OPEN (embedding backend unavailable; it could not actually
  # assess novelty). By DEFAULT this proceeds like :novel (create), preserving the
  # never-block-a-write contract for interactive callers. An AUTOMATED caller that must
  # not inject an un-deduplicated article during an outage passes
  # `on_gate_unavailable: :skip`, which returns `{:error, :gate_unavailable}` WITHOUT
  # creating, so the caller can retry once embeddings recover and dedup then.
  defp gate_proposal(tenant_id, attrs, %{verdict: :unknown} = assessment, opts) do
    if Keyword.get(opts, :on_gate_unavailable, :create) == :skip do
      {:error, :gate_unavailable}
    else
      create_proposal(tenant_id, attrs, assessment, opts, :created)
    end
  end

  # :novel — the gate assessed the proposal as genuinely new; create on the requested path.
  defp gate_proposal(tenant_id, attrs, assessment, opts) do
    create_proposal(tenant_id, attrs, assessment, opts, :created)
  end

  # `on_low_novelty: :skip` (default `:draft`) — create NOTHING for a high-overlap
  # proposal, mirroring `on_gate_unavailable: :skip` above. The default drafts it so a
  # human or a smarter agent can resolve merge-vs-keep from the drafts queue; but an
  # UNATTENDED writer (session capture) has no such reviewer, so its drafts accumulate
  # as invisible corpus debris that nothing ever resolves. Such a caller would rather
  # drop the near-duplicate than bank it — the knowledge is by definition already in the
  # corpus, and the neighbour is returned so the drop can be counted and attributed.
  #
  # The drop is decided LAST, after EVERY check `create_article/3` resolves ahead of its
  # insert — project ownership, the idempotency-key identity, the full create changeset,
  # then the active-title identity, in that order and against the SAME
  # `effective_tenant_id` (nil for system scope) — so opting into skip never converts a
  # caller ERROR into a success-shaped no-op: an invalid/foreign `project_id`, an
  # over-long title, an unknown category/source_type or an oversized body still answers
  # the same 422 it would answer without the flag. A proposal naming an existing row BY
  # IDENTITY is answered FROM THAT ROW — `:deduplicated`, or `:duplicate_title` so the
  # client can retry with a disambiguated title — and never re-enters the insert path, so
  # no vanishing-row race can turn an opted-out proposal into a published article.
  defp skip_low_novelty(tenant_id, attrs, assessment, opts) do
    eff_tenant_id = effective_tenant_id(tenant_id, attrs)
    vis = Keyword.get(opts, :visibility_agent_id)

    with :ok <- validate_project_ownership(tenant_id, attrs["project_id"]),
         nil <-
           get_article_by_idempotency_key(eff_tenant_id, idempotency_key_from_attrs(attrs), vis),
         %{valid?: true} <- Article.create_changeset(%Article{tenant_id: eff_tenant_id}, attrs),
         nil <- title_identity(eff_tenant_id, attrs, vis) do
      drop_proposal(tenant_id, attrs, assessment, opts)
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      %Ecto.Changeset{} = changeset -> {:error, changeset}
      {:duplicate_title, existing} -> {:error, :duplicate_title, existing}
      # An idempotency_key match is the identity REGARDLESS of body (the key IS the
      # identity), exactly as on the create path.
      %Article{} = existing -> deduplicated_result(existing, assessment)
    end
  end

  # The same identity `create_article/3` resolves from its insert's unique violation: an
  # identical body is the idempotent no-op, a different one the 409 the client must
  # disambiguate.
  defp title_identity(tenant_id, attrs, vis) do
    case get_active_article_by_title(tenant_id, attrs["title"], vis) do
      %Article{} = existing ->
        if same_content?(existing, attrs), do: existing, else: {:duplicate_title, existing}

      _ ->
        nil
    end
  end

  defp deduplicated_result(existing, assessment),
    do:
      {:ok, %{verdict: :deduplicated, article: existing, created: false, assessment: assessment}}

  defp drop_proposal(tenant_id, attrs, assessment, opts) do
    # Resolved ONCE: the curation-log ref, the returned article and the `nearest` the
    # caller renders from the assessment must all name rows that still exist, or the
    # audit trail and the API answer disagree about the same drop.
    resolved = resolve_neighbors(tenant_id, assessment, opts)

    neighbor =
      case resolved do
        [{_raw, article} | _] -> article
        [] -> nil
      end

    assessment = Map.put(assessment, :neighbors, Enum.map(resolved, &elem(&1, 0)))
    log_gate(tenant_id, "gate_skip", "skipped (high overlap)", neighbor, assessment, opts)

    # The ONLY per-drop record that does not depend on the tenant's optional
    # kb_curation_log: the content is destroyed here, so "where did my capture go?"
    # must be answerable from the logs alone. The aggregate is the
    # `:skipped_low_novelty` write-stats counter the controller emits. The title is
    # truncated: a log line is not a content store, and it is attacker-supplied.
    Logger.info(
      "kb gate skipped low-novelty proposal tenant=#{inspect(tenant_id)} " <>
        "title=#{inspect(String.slice(to_string(attrs["title"]), 0, 200))} " <>
        "neighbor=#{inspect(neighbor && neighbor.id)} score=#{inspect(assessment.score)}"
    )

    {:ok,
     %{
       verdict: :skipped_low_novelty,
       article: neighbor,
       created: false,
       assessment: assessment
     }}
  end

  # System articles have no tenant — identity, uniqueness and dedup all resolve against
  # NULL, so every path mirroring `create_article/3` must resolve against THIS, not the
  # caller's tenant_id, or the two disagree about what already exists.
  defp effective_tenant_id(tenant_id, attrs) do
    if (attrs[:scope] || attrs["scope"]) in [:system, "system"], do: nil, else: tenant_id
  end

  defp create_proposal(tenant_id, attrs, assessment, opts, verdict) do
    # US-41.7: carry the gate's OWN egress fact into the create's custody entry.
    # The novelty gate embedded this proposal's title+body SYNCHRONOUSLY, before
    # the row existed; a `:low_novelty` proposal is then created as a DRAFT, which
    # never enqueues an embedding worker — so without this the create entry would
    # be the row's ONLY entry and would vacuously read `all_network_local` for a
    # body that had already left the process.
    opts = Keyword.put(opts, :gate_embedded, Map.get(assessment, :gate_embedded, false))

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

  # The near-neighbours a `:skipped_low_novelty` proposal was dropped in favour of, paired
  # with the rows they still resolve to. Unlike the `:duplicate` path this is advisory
  # only — a neighbour archived/deleted between assess and now is dropped rather than
  # falling back to creating, because the caller explicitly asked never to create on high
  # overlap. Only the VANISHED ones are dropped (not the whole list), so a skip stays as
  # attributable as a `gated_to_draft` for the same assessment.
  defp resolve_neighbors(tenant_id, assessment, opts) do
    vis = Keyword.take(opts, [:visibility_agent_id])

    Enum.flat_map(Map.get(assessment, :neighbors) || [], fn neighbor ->
      case get_article(tenant_id, neighbor.id, vis) do
        {:ok, article} -> [{neighbor, article}]
        _ -> []
      end
    end)
  end

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
  # has committed, so the winning row exists. The recovery SELECT
  # (get_active_article_by_title/3) mirrors the partial index's active predicate
  # AND is visibility-scoped by `vis` (mirroring get_article_by_idempotency_key/3,
  # #163): it returns the winning row only when the caller may see it. The
  # idempotency signal is the article BODY itself (server-side, unforgeable): if
  # the colliding payload's body equals the existing article's (after trimming
  # leading/trailing whitespace), the conflict is a duplicate/retry -> return the
  # existing row idempotently as `{:ok, :deduplicated, existing}` (a no-op the API
  # answers 200). Otherwise it is a genuine different-body title collision ->
  # `{:error, :duplicate_title, existing}` so the API can answer 409 (not a
  # retry-into-the-same-422). Non-(active-title) failures pass through unchanged.
  #
  # A nil recovery-SELECT result is an EXPECTED, intended outcome — not an
  # impossible/transient edge — and the caller deliberately falls through to a
  # generic uniqueness 422. Two distinct nil cases produce it:
  #
  #   1. Cross-agent private collision (the security invariant this path enforces):
  #      the title collides with ANOTHER agent's private/owner article, so the
  #      visibility filter excludes it. Falling through to a bare 422 leaks no
  #      UUID, body, or existence signal about that private row. DO NOT drop the
  #      visibility filter or this fallthrough to "fix" a phantom nil — doing so
  #      silently reintroduces the private-article existence/UUID leak (#163).
  #   2. Concurrent archival: the recovery SELECT runs after the insert's
  #      transaction has rolled back, so a THIRD writer may mutate or archive the
  #      winning row between its commit and our SELECT. That yields a transient,
  #      self-healing outcome — a 409 (body now differs) or the 422 (row now
  #      archived/superseded → SELECT returns nil) — which the client's next
  #      attempt resolves cleanly. We accept that rather than re-running the whole
  #      create under a lock.
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
        resolve_title_conflict(tenant_id, attrs, changeset, vis)

      true ->
        {:error, changeset}
    end
  end

  defp resolve_title_conflict(tenant_id, attrs, changeset, vis) do
    title = attrs[:title] || attrs["title"]

    case get_active_article_by_title(tenant_id, title, vis) do
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

  @doc """
  Look up an article by its `idempotency_key` across ALL statuses, mirroring the partial
  unique index (which has no status predicate) so the conflicting/canonical row is always
  found. `vis` (a `visibility_agent_id`) scopes the lookup to the owner-visible row so a
  key colliding with another agent's private article can't be echoed (#163).

  Public so callers holding a deterministic per-scope key (e.g. memory graduation) can
  resolve the existing article for an idempotent no-op WITHOUT re-running the novelty gate.
  """
  @spec get_article_by_idempotency_key(Ecto.UUID.t() | nil, String.t() | nil, term()) ::
          Article.t() | nil
  def get_article_by_idempotency_key(_tenant_id, nil, _vis), do: nil
  def get_article_by_idempotency_key(nil, _key, _vis), do: nil

  def get_article_by_idempotency_key(tenant_id, key, vis) when is_binary(key) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id and a.idempotency_key == ^key,
      order_by: [asc: a.inserted_at],
      limit: 1
    )
    |> maybe_filter_by_visibility(vis)
    |> AdminRepo.one()
  end

  # Non-binary key (e.g. an integer) → no lookup.
  def get_article_by_idempotency_key(_tenant_id, _key, _vis), do: nil

  # Only the active-title index — NOT the slug indexes, whose conflicts are on a
  # different field and must not be recovered via a title lookup.
  defp active_title_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "articles_tenant_title_active_idx"
    end)
  end

  defp get_active_article_by_title(_tenant_id, title, _vis) when not is_binary(title), do: nil

  # tenant_id is nil for system-scoped articles; a NULL `=` never matches, so the
  # recovery simply doesn't apply to system scope (its conflicts are slug-based).
  defp get_active_article_by_title(nil, _title, _vis), do: nil

  # `vis` (a `visibility_agent_id`) scopes the recovery SELECT to owner-visible rows,
  # mirroring get_article_by_idempotency_key/3 (#163). Because this path uses
  # AdminRepo (BYPASSRLS) the visibility filter MUST live in the query — RLS won't
  # apply it. A title colliding with another agent's private/owner article returns
  # nil here → the caller falls through to a generic uniqueness 422, with no UUID,
  # body, or existence signal leaked.
  defp get_active_article_by_title(tenant_id, title, vis) do
    from(a in Article,
      where:
        a.tenant_id == ^tenant_id and a.title == ^title and
          a.status not in [:archived, :superseded],
      order_by: [asc: a.inserted_at],
      limit: 1
    )
    |> maybe_filter_by_visibility(vis)
    |> AdminRepo.one()
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

  Resolves a TENANT-OWNED article first, then falls back to a PUBLISHED SYSTEM CANONICAL
  (#572). The fallback only ever widens what a tenant-scoped `:not_found` was allowed to
  catch, onto the same public canon the wiki serves unauthenticated at `/wiki/<slug>` and
  `heat_index/2` already lists — a tenant-owned row can never match it (`scope: :system`),
  so tenant isolation is untouched, and a draft or archived canonical stays invisible.

  That fallback used to live only in `progressive_drill/3`, and the split is what made the
  heat accounting incoherent: a canonical had NO caller-named read path, so its drill had
  to be counted while a tenant article's was not, and `heat_index/2` then ranked the two
  classes on one number that meant different things. Every article now earns heat the same
  way — through a `get` where the caller names an id the ranker did not just hand it.

  Records an access event when an `:api_key_id` is supplied via `opts` — `"get"` unless
  `:access_type` overrides it, which only `progressive_drill/3` does (the uncounted
  `"drill"`, #569). Recording is fire-and-forget, never affects the read, and no-ops without
  an `:api_key_id` — which is how a caller resolves an id without registering a read.

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
  - `{:error, :not_found}` if no tenant-owned article and no published system canonical
    has that id, or if a prefix matches more than one

  ## Prefix resolution (#652)

  An exact miss falls back to resolving `article_id` as a UNIQUE ID PREFIX within the
  same visibility scope. 16 of 20 sampled `knowledge_get` 404s carried a correct
  8-character prefix with a confabulated tail — 12 zero-padded
  (`f09da4ed-0000-0000-0000-000000000000`), 4 bare prefixes, and one fully plausible
  wrong UUID. Agents cannot reliably retype 36 characters out of context, and this is a
  found-it-then-lost-it failure: the search worked and the read was thrown away.

  The fallback takes the first 8 hex digits (dashes stripped) and range-scans the
  primary key between `<prefix>-0000-…` and `<prefix>-ffff-…`, so it costs an index
  range scan rather than a text scan. It resolves ONLY when exactly one visible article
  matches; two or more is `:not_found`, never a guess. The scope predicate is identical
  to the exact lookup, so this widens nothing: a prefix can no more reach another
  tenant's article than the full id could.
  """
  @spec get_article(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Article.t()} | {:error, :not_found}
  # ONE query, not a tenant lookup with a canonical fallback behind it: the MISS is the path an
  # outsider can drive at will (any id that exists in no tenant), and a second `AdminRepo`
  # round trip per miss put a 2x amplifier on the 3-connection pool that custody writes and the
  # per-request auth SELECT share — the same pool `with_heat_admission/3` below exists to
  # protect. The disjunction is decided in the WHERE, so a hit and a miss cost one checkout.
  #
  # `status == :published` on the system arm mirrors `get_system_article_by_slug/1` and
  # `list_system_articles/1`. This is a TENANT-FACING by-id path, not the privileged curation
  # one (`fetch_curatable_article/2`, which legitimately needs drafts), so it must never expose
  # a draft or archived canonical — and the tenant arm is unchanged, so a tenant still reads
  # its own drafts.
  def get_article(tenant_id, article_id, opts \\ []) do
    case locate_article(tenant_id, article_id) do
      {:ok, article} -> finalize_article_read(tenant_id, article, opts)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # Exact id first; only a MISS pays for the prefix fallback, so the common read is
  # byte-for-byte the query it always was.
  defp locate_article(tenant_id, article_id) do
    case exact_article(tenant_id, article_id) do
      nil -> prefix_article(tenant_id, article_id)
      article -> {:ok, article}
    end
  end

  # A non-UUID `article_id` would raise Ecto.Query.CastError here, so it never reaches
  # the query — a bare prefix goes straight to the fallback instead of a 500.
  defp exact_article(tenant_id, article_id) when is_binary(article_id) do
    case Ecto.UUID.cast(article_id) do
      {:ok, uuid} ->
        Article
        |> where([a], a.id == ^uuid)
        |> visible_article_scope(tenant_id)
        |> AdminRepo.one()

      :error ->
        nil
    end
  end

  defp exact_article(_tenant_id, _article_id), do: nil

  defp prefix_article(tenant_id, article_id) do
    case id_prefix_range(article_id) do
      {:ok, low, high} ->
        Article
        |> where([a], a.id >= ^low and a.id <= ^high)
        |> visible_article_scope(tenant_id)
        |> limit(2)
        |> AdminRepo.all()
        |> case do
          [article] ->
            emit_prefix_resolved(tenant_id, article, article_id)
            {:ok, article}

          _ ->
            {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  # The SAME disjunction the exact lookup uses — kept in one place so the prefix path
  # can never drift into a wider scope than the id path it backs up.
  defp visible_article_scope(query, tenant_id) do
    where(
      query,
      [a],
      a.tenant_id == ^tenant_id or (a.scope == :system and a.status == :published)
    )
  end

  # 8 hex digits = 32 bits. Against a corpus of ~10^5 articles a collision is ~0.002%
  # per lookup, and a collision resolves to :not_found anyway (two matches never
  # resolve), so the failure mode of being wrong here is the 404 the caller already had.
  @id_prefix_length 8

  defp id_prefix_range(value) when is_binary(value) do
    hex = value |> String.replace("-", "") |> String.downcase()

    with true <- String.length(hex) >= @id_prefix_length,
         prefix <- String.slice(hex, 0, @id_prefix_length),
         true <- String.match?(prefix, ~r/\A[0-9a-f]{8}\z/) do
      {:ok, prefix <> "-0000-0000-0000-000000000000", prefix <> "-ffff-ffff-ffff-ffffffffffff"}
    else
      _ -> :error
    end
  end

  defp id_prefix_range(_value), do: :error

  defp emit_prefix_resolved(tenant_id, article, requested) do
    :telemetry.execute(
      Loopctl.TelemetryEvents.article_prefix_resolved(),
      %{count: 1},
      %{tenant_id: tenant_id, article_id: article.id, requested: requested}
    )
  end

  # Shared visibility/preload/access-tracking tail of an article fetch, once the row itself
  # has been located (tenant-owned or a system canonical). Factored out so BOTH scopes get
  # identical visibility enforcement, link preloading, conflict-link filtering, and access
  # recording — never duplicated ad hoc per caller.
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

      # `:access_type` defaults to `"get"` — this function is shared by `get_article/3` and
      # `progressive_drill/3`, and only the latter overrides it, to the uncounted `"drill"`
      # (#569, now on BOTH branches — #572). That override is what stops the heat index
      # ranking on reads it caused itself; see `@heat_read_access_types`.
      #
      # A lookup that delivers no BODY must not register as one. There is no flag for that:
      # `Analytics.record_access/6` no-ops on a nil `api_key_id`, so a caller that wants a
      # silent resolve simply omits it — which is what `article_stats` does.
      Analytics.record_access(
        tenant_id,
        article.id,
        Keyword.get(opts, :api_key_id),
        Keyword.get(opts, :access_type, "get"),
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
    not restricted?(article) or owner_of(article) == agent_id
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
      # Same "settled" definition the conflict queue uses: a verdict nothing will act on
      # must not strip the conflict link from the article payload either, or the pair is
      # invisible on BOTH surfaces an actor could rediscover it from.
      where: ^settled_resolution(),
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
          # Single source of truth for the exp(-age_days/30) decay — shared with the #471
          # search_combined priors (RankingPriors.recency_decay/2).
          recency_score = RankingPriors.recency_decay(article.updated_at, now)

          # Demote MOC hubs and dead doctrine HERE too (#654 follow-up). This surface
          # re-ranks on its own `combined_score` and never sees `search_combined`'s fused
          # `:final_score`, so without this a hub demoted out of the search top-3 came
          # straight back at rank 1 — and `knowledge_context` returns FULL BODIES, so the
          # undemoted hub cost far more context here than it did in search.
          #
          # Applied per-surface rather than folded into `absolute_score/1`: that function
          # also feeds `hybrid_search/3`'s curated-vs-retrieved threshold, and moving a
          # score there would silently move the provenance decision boundary with it.
          demotion = RankingPriors.demotion_factor(article)

          combined =
            ((1.0 - recency_weight) * relevance + recency_weight * recency_score) * demotion

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

  # The relevance term of the context blend MUST be the ABSOLUTE per-row score
  # (`absolute_score/1` — raw cosine similarity, or a bounded transform of raw
  # ts_rank_cd), NEVER the fused `:final_score`. Post-#470 the default fusion is RRF,
  # whose `:final_score` is `Σ weight/(k+rank)` — a top value of ~0.008-0.016, ~30-60x
  # smaller than the old min-max 0..1 scale. Blending that against the 0..1 recency_score
  # in `build_context_results/6` (`0.7*relevance + 0.3*recency`) would let recency
  # dominate ordering ~25x, so an irrelevant-but-fresh article would beat a
  # highly-relevant-but-old one and `/knowledge/context` would order essentially by
  # recency. Reading the absolute score keeps relevance on the same 0..1 scale the
  # recency blend was calibrated for (same root fix as the hybrid resolver's
  # `absolute_score/1`, US-31.2 — #470 review).
  defp find_relevance_score(results, article_id) do
    case Enum.find(results, fn r -> r[:id] == article_id end) do
      nil -> 0.0
      r -> absolute_score(r)
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
        # #492: the deployment regconfig — MUST match the one the stored `search_vector`
        # was built with (the article generated column / the CR triggers), or a
        # differently-stemmed query matches nothing. Passed as a `?::text::regconfig` bind
        # param (never interpolated) — the `::text` is REQUIRED: a bare `?::regconfig` makes
        # Postgrex describe the param as the `regconfig` OID type and demand an integer, so a
        # string name raises at encode time. `::text::regconfig` keeps the param text and lets
        # PG cast it, with no injection surface even though it reaches SQL.
        regconfig = Regconfig.get()

        base_query =
          from(a in Article,
            where: a.tenant_id == ^tenant_id,
            where:
              fragment(
                "search_vector @@ websearch_to_tsquery(?::text::regconfig, ?)",
                ^regconfig,
                ^query_string
              ),
            select: %{
              id: a.id,
              tenant_id: a.tenant_id,
              project_id: a.project_id,
              title: a.title,
              category: a.category,
              status: a.status,
              tags: a.tags,
              # source_type feeds the #471 authority prior (it is NOT projected by
              # default elsewhere); carried on the keyword lane so the priors apply on the
              # degraded keyword_only fallback too (AC-5).
              source_type: a.source_type,
              # idempotency_key is the MOC-hub signal (#654 follow-up). Projected for the
              # SAME reason as source_type: RankingPriors fails open on a missing field,
              # so a lane that omits it silently stops demoting hubs on that lane only.
              idempotency_key: a.idempotency_key,
              inserted_at: a.inserted_at,
              updated_at: a.updated_at,
              relevance_score:
                fragment(
                  "ts_rank_cd(search_vector, websearch_to_tsquery(?::text::regconfig, ?))",
                  ^regconfig,
                  ^query_string
                ),
              snippet:
                fragment(
                  "ts_headline(?::text::regconfig, body, websearch_to_tsquery(?::text::regconfig, ?), 'StartSel=**, StopSel=**, MaxWords=35, MinWords=15')",
                  ^regconfig,
                  ^regconfig,
                  ^query_string
                )
            },
            order_by: [
              desc:
                fragment(
                  "ts_rank_cd(search_vector, websearch_to_tsquery(?::text::regconfig, ?))",
                  ^regconfig,
                  ^query_string
                ),
              # DETERMINISTIC secondary key: `ts_rank_cd` ties (common on short/overlapping
              # docs) otherwise resolve to Postgres' physical row order, which is not stable
              # run-to-run. In :keyword_only mode this raw order IS the final ranking, and the
              # retrieval-eval deploy gate compares `answered` at zero tolerance, so a tie at
              # the top-k boundary must not flip the result set. The id makes the order total.
              asc: a.id
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

        maybe_record_search_access(
          tenant_id,
          results,
          query_string,
          Keyword.put(opts, :_total_count, total_count),
          "keyword"
        )

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

    maybe_record_search_access(
      tenant_id,
      results,
      "",
      Keyword.put(opts, :_total_count, total_count),
      "list"
    )

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
    |> apply_project_scope(
      Keyword.get(opts, :project_id),
      Keyword.get(opts, :project_scope, :strict)
    )
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
  #
  # #582: only the first `Analytics.max_recorded_search_results/0` results get a row, so
  # the count of recorded rows is NOT the count of results returned. The true,
  # un-truncated figure is carried in `"results_returned"` so `RetrievalMetrics` can
  # expose the gap instead of silently reporting a truncated denominator as if it were
  # the whole result set. The cap lives in `Analytics` — the module that writes the rows
  # and documents the key — so the enforcement here and every doc that publishes the
  # number read ONE constant.
  # The serialized snippet cap. Lives here rather than in the renderer so the value the
  # backfill PRODUCES and the value the renderer ENFORCES are one constant.
  @max_snippet_length 300

  # How much of a body the lead extractor reads. Bigger than the snippet cap on purpose:
  # front matter that has to be skipped (an auto-extraction banner, a heading, a metadata
  # table) can easily run past 300 bytes, and scanning only 300 would return the banner it
  # was supposed to skip.
  @snippet_scan_bytes 1500

  # Extracted from `maybe_record_search_access/5` so that function stays readable: the
  # attempt row carries enough of the request to make a MISS interpretable later, which is
  # a dozen fields, and inlining them buried the control flow they sit inside.
  defp search_attempt_attrs(search_id, api_key_id, ctx, query_string, results, mode, opts) do
    top = List.first(results)

    attrs = %{
      search_id: search_id,
      api_key_id: api_key_id,
      # WHO searched. api_key_id alone is not the agent: under the v2 dispatch pattern a
      # key is minted PER DISPATCH, so counting keys counts dispatches, not agents.
      agent_id: Keyword.get(opts, :agent_id),
      project_id: Map.get(ctx, :project_id) || Map.get(ctx, "project_id"),
      story_id: Map.get(ctx, :story_id) || Map.get(ctx, "story_id"),
      # An explicit `mode=semantic` search holds only the embedding by the time it records,
      # so the site passes `nil`; the request's own query rides `:_query_string`. Without it
      # every semantic search filed itself under `query_terms IS NULL` — the "no query"
      # bucket the moduledoc keeps separate from a one-token query on purpose.
      query: query_string || Keyword.get(opts, :_query_string),
      # DERIVED from the lane, not defaulted to a literal. Defaulting made every
      # enumeration and hybrid row claim `tool = "knowledge_search"`, so a per-tool
      # breakdown was WRONG rather than merely absent.
      tool: Keyword.get(opts, :_tool) || tool_for_mode(mode),
      mode_requested: Keyword.get(opts, :_mode_requested) || requested_mode(mode),
      mode_used: mode,
      # WHICH SLICE of the KB. tenant_id names the corpus; these name the part of it the
      # query could ever have matched, without which a zero-result row is unreadable.
      filters: search_filters(opts),
      # The limit the CLIENT asked for, which is NOT `:limit` — that one has already been
      # defaulted and clamped by the controller, so "did callers ask for more than we
      # return" is unanswerable from it.
      limit_requested: Keyword.get(opts, :_limit_requested) || Keyword.get(opts, :limit),
      offset_requested: Keyword.get(opts, :offset),
      total_count: Keyword.get(opts, :_total_count),
      top_result_id: top_result_id(top),
      top_result_score: top_result_score(top),
      result_count: length(results),
      duration_ms: search_duration_ms(opts),
      ann_iterative_scan: Keyword.get(opts, :_ann_iterative_scan),
      degraded?: Keyword.get(opts, :_degraded, false),
      fallback_reason: Keyword.get(opts, :_fallback_reason)
    }

    # Client-asserted context merges UNDER the server-derived facts, never over them: a
    # request header must not be able to overwrite `agent_id`, `tool` or `outcome`. The
    # controller's whitelist makes a collision impossible TODAY — this makes it structural.
    Map.merge(client_context_attrs(opts), attrs)
  end

  # Read with `Map.get/2`, never `top[:key]`: Access is undefined on structs, so the Access
  # form raises on a struct-shaped result and the whole telemetry row is lost to the
  # recorder's rescue. Each lane names its score differently — fused rows carry
  # `:final_score`, the semantic lane `:similarity_score`, keyword (and the degraded
  # keyword-only fallback) `:relevance_score` — so all three are read, or the column the
  # schema justifies as "judge relevance later without replaying the query" stays NULL for
  # every non-fused lane.
  defp top_result_id(nil), do: nil
  defp top_result_id(top), do: Map.get(top, :id)

  defp top_result_score(nil), do: nil

  defp top_result_score(top) do
    Map.get(top, :final_score) || Map.get(top, :similarity_score) ||
      Map.get(top, :relevance_score) || Map.get(top, :score)
  end

  # The mode a client can actually REQUEST. `mode` at the record site is the internal LANE
  # label, so falling back to it invented buckets ("combined_fallback", "list_keyset",
  # "hybrid_curated") no request can produce and undercounted the implicit default. A lane
  # entered from combined reports combined; anything else records NULL (undeclared) rather
  # than a phantom.
  defp requested_mode(mode) when mode in ~w(keyword semantic combined), do: mode
  defp requested_mode("combined_fallback"), do: "combined"
  defp requested_mode(_lane), do: nil

  # The tool a row belongs to, derived from the lane that recorded it. `knowledge_list` and
  # `knowledge_hybrid_search` are not searches in the same sense as `knowledge_search`, and
  # folding them into one label polluted its outcome mix with enumeration calls.
  defp tool_for_mode(mode) when mode in ["list", "list_keyset"], do: "knowledge_list"
  defp tool_for_mode("hybrid_curated"), do: "knowledge_hybrid_search"
  defp tool_for_mode("hybrid_retrieved"), do: "knowledge_hybrid_search"
  defp tool_for_mode(_mode), do: "knowledge_search"

  # Wall time from the request entrypoint, which is the only place that knows when the
  # attempt began. Monotonic, so a clock step cannot produce a negative duration. Absent
  # for callers that never stamped a start (recorded as NULL, not as a wrong zero).
  # The metadata every surfaced-result row carries. `entrypoint` rides along ONLY when the
  # client declared one, and it is what lets `RetrievalMetrics` exclude infrastructure
  # traffic without joining back to `search_events` — the same shape `mode` is already
  # filtered on there (#673).
  #
  # It matters because the smoke test searches and NEVER opens: two searches per run made it
  # 66% of recorded searches, every one of them adding to the denominator of precision and
  # follow-through while being structurally incapable of adding to the numerator. A 1-4%
  # precision read as a catastrophic retrieval failure and was largely this.
  #
  # Client-asserted and therefore spoofable, exactly like the rest of the `client_*` surface
  # — analytics only, never an authorization input. The failure it permits is a caller
  # excluding its OWN rows from a quality metric, which is self-harm rather than an attack
  # on anyone else's numbers.
  # `session_id` rides along on the same terms and for a metric that could not be computed
  # without it (#711). `RetrievalMetrics` decides whether a search was REFORMULATED by asking
  # whether the same asker queried again inside the window. It used to ask that of
  # `api_key_id`, which is not an asker: only two keys search this system — the recall hook's
  # and the shared MCP key every session and subagent authenticates with — so the answer was
  # governed by how busy the system was, not by whether anyone was struggling. Without a
  # session on the SURFACED-RESULT row there is no way to scope the comparison, because that
  # metric reads `article_access_events` and never joins back to `search_events`.
  #
  # Same trust posture as `entrypoint`: client-asserted, spoofable, analytics-only. Rows that
  # do not carry it are excluded from that metric rather than compared on a weaker key —
  # see `RetrievalMetrics.reformulation_scoreable/1`.
  defp search_access_meta(mode, results, opts) do
    attrs = client_context_attrs(opts)

    %{"mode" => mode, "results_returned" => length(results)}
    |> put_client_meta("entrypoint", Map.get(attrs, :client_entrypoint))
    |> put_client_meta("session_id", Map.get(attrs, :client_session_id))
  end

  defp put_client_meta(meta, key, value) when is_binary(value) and value != "",
    do: Map.put(meta, key, value)

  defp put_client_meta(meta, _key, _value), do: meta

  defp search_duration_ms(opts) do
    case Keyword.get(opts, :_started_at) do
      started when is_integer(started) -> System.monotonic_time(:millisecond) - started
      _ -> nil
    end
  end

  # Client-asserted context (#658), threaded from the HTTP layer which decoded it from the
  # request header. UNTRUSTED and analytics-only — the api key remains the sole authority.
  defp client_context_attrs(opts) do
    case Keyword.get(opts, :_client_context) do
      %{} = attrs -> attrs
      _ -> %{}
    end
  end

  # Attaches the two facts a semantic lane knows and the recorder cannot recompute: the
  # candidate pool the ranker chose FROM (a page of 5 out of 100 and a page of 5 out of 5
  # are different retrieval events) and whether the ANN ran under `hnsw.iterative_scan`.
  # The scan state is read from the SAME opts the read was issued with, via the one
  # derivation `HeavyRead.iterative_scan_meta/1` — never a fresh probe.
  defp attempt_meta(opts, total_count, read_opts) do
    Keyword.merge(opts,
      _total_count: total_count,
      _ann_iterative_scan: Map.get(HeavyRead.iterative_scan_meta(read_opts), :ann_iterative_scan)
    )
  end

  # The corpus slice a search could match, captured so a zero-result row is interpretable.
  # Only keys the caller actually supplied are recorded — an absent filter and a filter set
  # to nil are different facts, and flattening them would make an over-scoped search look
  # identical to an unscoped one.
  defp search_filters(opts) do
    [:category, :tags, :match, :status, :project_id, :visibility, :threshold]
    |> Enum.reduce(%{}, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, nil} -> acc
        {:ok, value} -> Map.put(acc, Atom.to_string(key), normalize_filter_value(value))
        :error -> acc
      end
    end)
  end

  defp normalize_filter_value(v) when is_atom(v) and not is_boolean(v) and not is_nil(v),
    do: Atom.to_string(v)

  defp normalize_filter_value(v) when is_list(v), do: Enum.map(v, &normalize_filter_value/1)
  defp normalize_filter_value(v), do: v

  # Records BOTH halves of a search's telemetry (#658):
  #
  #   * the per-RESULT rows (rank, article_id) in `article_access_events`, unchanged; and
  #   * ONE row per ATTEMPT in `search_events`, INCLUDING attempts that surfaced nothing.
  #
  # The second half exists because this function used to return `:ok` on `results in
  # [nil, []]`, so a search that found nothing left no trace in the database at all. The
  # misses — the only searches that tell you the corpus or the query needs work — were the
  # exact population the schema could not represent, and recovering them meant hand-mining
  # 6,457 session transcripts. Both halves share one `search_id` so a miss and its (absent)
  # results are one correlated story.

  # ---------------------------------------------------------------------------
  # Snippet backfill — every result explains itself, whichever lane found it
  # ---------------------------------------------------------------------------

  @doc """
  The maximum serialized snippet length. Referenced by the renderer too, so the enforced
  cap and the documented one cannot drift.
  """
  @spec max_snippet_length() :: pos_integer()
  def max_snippet_length, do: @max_snippet_length

  # WHY THIS EXISTS. `snippet` is a `ts_headline` highlight and therefore comes ONLY from
  # the KEYWORD lane. A result the query did not lexically match — which is precisely what
  # the semantic lane is FOR — arrived with no snippet key at all, so the rows most in need
  # of an explanatory line were exactly the ones that had none. An agent handed a bare title
  # can neither judge it nor skip it honestly: it opens blindly or ignores the row, and both
  # show up in the follow-through metric as the retrieval's fault.
  #
  # Cost is bounded to the RETURNED PAGE, never the candidate pool: combined search runs its
  # sub-searches at `@max_relevance_page_size` and passes `_skip_snippet_backfill`, exactly
  # as it already passes `_skip_record_access`, so the fill happens once on the merged page.
  # One primary-key batch read of a bounded body prefix.
  defp with_snippets(tenant_id, results, opts) do
    if Keyword.get(opts, :_skip_snippet_backfill, false) do
      results
    else
      backfill_snippets(tenant_id, results)
    end
  end

  defp backfill_snippets(tenant_id, results) when is_list(results) do
    # NB this filter is a COST optimisation, not a correctness guard, and mutation testing
    # says so: `apply_leads/2` independently refuses to overwrite a result that already has
    # a snippet, so widening this to every result is behaviour-preserving and fails no test.
    # It stays because it decides how many bodies are read, which no test can see.
    missing = Enum.filter(results, &is_nil(Map.get(&1, :snippet)))

    case Enum.map(missing, & &1.id) do
      [] ->
        results

      ids ->
        case tenant_lead_rows(tenant_id, ids) do
          # A SHED is not "this tenant owns none of these ids". Collapsing it to an empty
          # list handed EVERY id on the page to `system_lead_rows/1`, so a shed spent an
          # AdminRepo connection under exactly the load the shed exists to relieve. The
          # degradation is: a shed backfill costs a snippet, and never a second query.
          :shed ->
            results

          rows ->
            resolved = MapSet.new(rows, &elem(&1, 0))

            (rows ++ system_lead_rows(Enum.reject(ids, &MapSet.member?(resolved, &1))))
            |> apply_lead_rows(results)
        end
    end
  rescue
    # A snippet is an aid, never the answer. If the backfill fails the results still stand.
    error ->
      Logger.warning("Knowledge snippet backfill failed: #{Exception.message(error)}")
      results
  end

  # HeavyRead, NOT AdminRepo: this runs on the public search path, and AdminRepo's small
  # pool is load-bearing for every authentication — the keyword lane already spends one
  # connection there per search, and a second would double that for a cosmetic field.
  # HeavyRead has its own pool and may SHED under load, which is the correct degradation
  # here: a shed backfill costs a snippet, never a result.
  defp tenant_lead_rows(tenant_id, ids) do
    query =
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.id in ^ids,
        select: {a.id, fragment("left(?, ?)", a.body, @snippet_scan_bytes)}
      )

    case HeavyRead.all(tenant_id, query, semantic_heavy_read_opts()) do
      rows when is_list(rows) -> rows
      _shed -> :shed
    end
  end

  # Every search population here is the DISJUNCTIVE `tenant_id == ^t or scope == :system`, so
  # a page can carry system canonicals — whose NULL `tenant_id` can never satisfy the
  # heavy-read tenant guard (`HeavyRead.guard!/2` refuses an OR-bypass, which is why
  # `hydrate_semantic_pool/6` reads them through AdminRepo too). Without this they were the
  # one class of result that still came back with a bare title.
  #
  # This is the one AdminRepo query the comment above tolerates, and it is bounded on both
  # sides: only the ids the tenant-scoped read did not resolve are asked for, so a page with
  # no canonical spends nothing, and a SHED never reaches here at all — `backfill_snippets/2`
  # returns on `:shed` rather than treating the whole page as unresolved.
  defp system_lead_rows([]), do: []

  defp system_lead_rows(ids) do
    from(a in Article,
      where: a.id in ^ids and a.scope == :system,
      select: {a.id, fragment("left(?, ?)", a.body, @snippet_scan_bytes)}
    )
    |> AdminRepo.all()
  end

  defp apply_lead_rows(rows, results) when is_list(rows) do
    apply_leads(results, Map.new(rows, fn {id, prefix} -> {id, lead_extract(prefix)} end))
  end

  defp apply_leads(results, leads) do
    Enum.map(results, fn result ->
      case {Map.get(result, :snippet), Map.get(leads, result.id)} do
        {nil, lead} when is_binary(lead) and lead != "" ->
          result |> Map.put(:snippet, lead) |> Map.put(:snippet_source, "lead")

        _ ->
          result
      end
    end)
  end

  # The first SUBSTANTIVE prose of a body.
  #
  # Naive `left(body, 300)` is not good enough here and the corpus says why: 99 articles
  # begin with the auto-extraction banner ("> ... NOT verified by a human"), many begin with
  # a markdown heading, and a lead built from either explains nothing while looking like it
  # does. So leading blockquotes, headings, rules, list bullets, images/badges and fenced
  # code are skipped, and the first real paragraph is taken.
  defp lead_extract(nil), do: nil

  defp lead_extract(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> drop_front_matter()
    |> Enum.take_while(&(String.trim(&1) != ""))
    |> Enum.join(" ")
    |> strip_light_markup()
    |> truncate_on_word_boundary(@max_snippet_length)
  end

  defp drop_front_matter(lines) do
    lines
    |> Enum.drop_while(&skippable_lead_line?/1)
    |> case do
      # A body that is nothing BUT front matter still deserves a snippet, so fall back to
      # its first non-blank line rather than returning an empty string.
      [] -> Enum.reject(lines, &(String.trim(&1) == ""))
      kept -> kept
    end
  end

  defp skippable_lead_line?(line) do
    trimmed = String.trim(line)

    trimmed == "" or
      String.starts_with?(trimmed, [">", "#", "---", "***", "```", "|", "!["]) or
      String.match?(trimmed, ~r/^[-*+]\s/)
  end

  # Deliberately LIGHT: unwrap link text, drop emphasis/backtick markers, collapse
  # whitespace. Not a markdown renderer — the goal is a line a human or an agent can read at
  # a glance, and an over-clever transform on untrusted body text is a bigger risk than a
  # stray character.
  defp strip_light_markup(text) do
    text
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, "")
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    # Backticks anywhere; `*` at token boundaries; `_` only when it touches no word
    # character at all. An unanchored `[*_`]+` ate the underscores INSIDE identifiers
    # (`tenant_id` rendered `tenantid`), and the token-boundary form still ate the ones at
    # their EDGES (`__MODULE__` rendered `MODULE`, `_unused` rendered `unused`) — which is
    # most of what this corpus's prose is made of, and a snippet naming an identifier the
    # corpus does not contain is worse than no snippet. An underscore emphasis marker is
    # indistinguishable from those by shape, so it survives as a literal `_`, which is a
    # character the corpus really does contain.
    |> String.replace(~r/`+/, "")
    |> String.replace(~r/(?<![\p{L}\p{N}])\*+|\*+(?![\p{L}\p{N}])/u, "")
    |> String.replace(~r/(?<![\p{L}\p{N}_])_+(?![\p{L}\p{N}_])/u, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate_on_word_boundary(text, max) do
    if String.length(text) <= max do
      text
    else
      # `max - 1` so the ellipsis fits INSIDE the cap. At `max` the result was `max + 1`
      # graphemes whenever the trailing-word trim found no whitespace to remove, and the
      # renderer then re-truncated it and appended a SECOND ellipsis.
      text
      |> String.slice(0, max - 1)
      |> String.replace(~r/\s+\S*$/, "")
      |> Kernel.<>("…")
    end
  end

  defp maybe_record_search_access(tenant_id, results, query_string, opts, mode) do
    results = results || []
    api_key_id = Keyword.get(opts, :api_key_id)
    skip? = Keyword.get(opts, :_skip_record_access, false)
    search_id = Ecto.UUID.generate()

    unless skip? or is_nil(api_key_id) do
      record_search_attempt(tenant_id, search_id, api_key_id, query_string, results, mode, opts)
    end

    cond do
      skip? ->
        :ok

      results == [] ->
        :ok

      is_nil(api_key_id) ->
        :ok

      true ->
        article_ids =
          results
          |> Enum.map(fn r -> r[:id] || Map.get(r, :id) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.take(Analytics.max_recorded_search_results())

        Analytics.record_search_access(
          tenant_id,
          article_ids,
          api_key_id,
          query_string,
          search_access_meta(mode, results, opts),
          # search_id rides the INTERNAL context, not the metadata map — metadata is
          # caller-supplied and a forged id would collapse the `searches` denominator (#582).
          Map.put(attribution_context(opts), :search_id, search_id)
        )
    end
  end

  # `Analytics.record_search_attempt/2` rescues its OWN body, which does not cover building
  # the attrs map at the call site: a struct-shaped result (Access is undefined on structs)
  # raised straight out of the search and 500'd the request. Recording is best-effort by
  # contract, so the construction has to sit inside the same rescue as the write.
  defp record_search_attempt(tenant_id, search_id, api_key_id, query_string, results, mode, opts) do
    ctx = attribution_context(opts)

    Analytics.record_search_attempt(
      tenant_id,
      search_attempt_attrs(search_id, api_key_id, ctx, query_string, results, mode, opts)
    )
  rescue
    error ->
      Logger.warning("knowledge.search_attempt_attrs failed: #{Exception.message(error)}")
      :ok
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
  # DELIBERATELY NO LONGER identical to `list_potential_conflicts/2`'s definition. The two
  # answer different questions and the divergence is the point: the QUEUE must keep showing
  # an unjudged conflict forever (it is still unjudged, and hiding it would strand it), while
  # SUPPRESSION must expire (see the window below). Keep both in mind when editing either —
  # re-unifying them would silently restore the unbounded suppression this exists to stop.
  defp open_conflict_subquery(tenant_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -conflict_suppression_window_days(), :day)

    from(l in ArticleLink,
      as: :link,
      where: l.tenant_id == ^tenant_id,
      where: l.relationship_type == :potential_conflict,
      where: fragment("(?->>'auto_generated') = 'true'", l.metadata),
      where:
        l.source_article_id == parent_as(:article).id or
          l.target_article_id == parent_as(:article).id,
      # FAIL OPEN past the window. Suppression is a safety measure premised on the
      # conflict being JUDGED soon; it is not premised on it being judged EVER. Left
      # unbounded it degrades into silent corpus deletion — measured on the hosted
      # deployment 2026-08-05: 16,117 open auto-generated conflicts, growing +500 every
      # night with no automatic drain, each removing BOTH of its articles from every
      # curated answer. That is up to ~32k article-slots withheld indefinitely to guard
      # against a contradiction nobody has confirmed exists.
      #
      # The trade, stated plainly: past the window a genuinely contradictory pair can be
      # cited again. That is the lesser harm. An unjudged flag is a SUSPICION raised by
      # cosine similarity >= 0.93 — which measures "these say similar things", not "these
      # disagree" — and withholding the corpus forever on an unconfirmed suspicion fails
      # the route's own purpose more reliably than the contradiction would.
      #
      # This is the backstop, not the mechanism. The drain is the automatic judge; this
      # exists so a stalled or crashed judge cannot silently empty curated retrieval
      # again. If you find yourself widening the window to mask a judge that is not
      # keeping up, fix the judge.
      where: l.inserted_at > ^cutoff,
      # SUPPRESSION releases on ROW EXISTENCE, deliberately NOT on `settled_resolution/0`.
      # The queue and the suppression ask different questions of the same table: the queue
      # asks "will anything act on this?", suppression asks "has anyone JUDGED this?".
      # Withholding both articles from every curated answer is premised on the pair being
      # UNJUDGED; once a verdict is recorded — even one the executor will not apply, such as
      # a capped supersede — the suspicion has been ruled on and the corpus must come back.
      # Holding suppression to the executor's bar meant an agent-only tenant could never
      # release it at all.
      where: not exists(judged_pair_subquery()),
      select: 1
    )
  end

  @doc """
  How long an UNJUDGED auto-generated `potential_conflict` suppresses its articles from
  curated sources.

  Public so the suppression window and the tests that pin it read one number. Override with
  `config :loopctl, :conflict_suppression_window_days, n`.
  """
  @spec conflict_suppression_window_days() :: pos_integer()
  def conflict_suppression_window_days do
    Application.get_env(:loopctl, :conflict_suppression_window_days, 14)
  end

  # THE single authority for "this potential_conflict link is still unresolved":
  # correlated on the enclosing `as: :link` binding, TRUE when NO SETTLING
  # conflict_resolutions row exists for the pair in either direction. The DISCOVERY surfaces
  # — `list_potential_conflicts/2` (the queue) and the article payload's
  # `potential_conflicts` links — compose THIS so the definition can never drift between
  # them. Curated SUPPRESSION composes `judged_pair_subquery/0` instead; it is a different
  # question and the split is deliberate.
  #
  # A row SETTLES the pair when it has been executed or closed (`executed_at` — which a
  # `:dismiss` carries from the moment it is recorded), or when it is pending and the
  # executor will act on it as recorded (`executable_resolution/0`). Row EXISTENCE is not
  # enough, and that is the point: a verdict nothing will ever act on — a `:supersede`
  # capped down from `:high`, or one whose recorder may not authorize an unattended
  # retirement — would otherwise remove the pair from the only queue an orchestrator+ key
  # can discover it in, leaving the documented remedy ("re-record it at :high") reachable
  # only by someone who already memorised both article ids.
  defp conflict_unresolved_subquery do
    from(r in pair_resolutions(), where: ^settled_resolution())
  end

  # The same correlation with NO predicate on the verdict: TRUE when ANY verdict exists for
  # the pair. Only curated SUPPRESSION uses this — see the note at its call site for why the
  # two questions must not share one predicate.
  defp judged_pair_subquery, do: pair_resolutions()

  defp pair_resolutions do
    from(r in ConflictResolution,
      where:
        r.tenant_id == parent_as(:link).tenant_id and
          ((r.source_article_id == parent_as(:link).source_article_id and
              r.target_article_id == parent_as(:link).target_article_id) or
             (r.source_article_id == parent_as(:link).target_article_id and
                r.target_article_id == parent_as(:link).source_article_id))
    )
    |> where(
      # A verdict settles only a flag that already EXISTED when it was recorded. The
      # correlation above is on the article PAIR alone, which #730 turned into a way to
      # pre-settle an arbitrary pair forever: one principal asserts it, a second records a
      # dismiss, and every LATER system flag over those two articles is born settled —
      # dropped from the queue and released from curated suppression before a reviewer ever
      # sees it. Compared against the LINK's `inserted_at` (article_links has no
      # `updated_at`) and COALESCEd to the row's own so a pre-column verdict still settles
      # rather than re-suppressing a corpus.
      [r],
      fragment(
        "COALESCE(?, ?) >= ?",
        r.annotated_at,
        r.inserted_at,
        parent_as(:link).inserted_at
      )
    )
  end

  # "This verdict is the end of the pair's story." Actually disposed of, or pending and
  # certain to be applied as recorded. Shared by every surface that hides a judged pair.
  # The two branches are mutually exclusive ON `executed_at` on purpose. `executable_resolution/0`
  # answers "WILL the executor act on this?", which is only a question about a row it has not
  # reached yet — left ungated it also declared an ALREADY-executed row settled, so a merge
  # skipped for `no_api_key` still qualified through the pending branch and the disposal check
  # below could never be reached.
  defp settled_resolution do
    dynamic(
      [r],
      (not is_nil(r.executed_at) and ^disposing_outcome()) or
        (is_nil(r.executed_at) and ^executable_resolution())
    )
  end

  # `executed_at` alone is NOT disposal, and treating it as such reopens the same black hole
  # from the other side. The executor stamps it on outcomes where nothing happened and
  # nothing will: a merge skipped for `no_api_key`, a permanently failed synthesis, a
  # supersede whose link create errored, a retracted flag. Settling on those would drop the
  # pair out of the queue and out of the article payload with both articles untouched and no
  # row anyone can act on — exactly the "not pending, not applied, not visible, forever"
  # state `executable_resolution/0` exists to prevent.
  #
  # `action` is ABSENT on a `:dismiss` (recorded complete with an empty result) and on rows
  # written before this field existed, so an unknown action DISPOSES — the default keeps a
  # settled pair settled. `skipped` is split by reason: `insufficient_confidence` is a
  # deliberate close (it disposes), `no_api_key` is a block that may lift (it does not).
  defp disposing_outcome do
    dynamic(
      [r],
      fragment("COALESCE(?->>'action', '') NOT IN ('noop', 'failed')", r.execution_result) and
        fragment("COALESCE(?->>'reason', '') <> 'no_api_key'", r.execution_result)
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
  Authoritative-curated check for a single article (AC-31.1.4), from ONE tenant's view.

  Unlike the pure `curated?/1` (status + marker only), this additionally excludes an article
  that is in an OPEN `:potential_conflict` — such an article is NOT treated as authoritative
  until the conflict is resolved. Works for BOTH tenant articles and system canonicals
  (`tenant_id == nil`), which AC-31.1.3 requires to participate as curated.

  `tenant_id` is the tenant ASKING, and it is required rather than derived from the article
  because for a system canonical there is nothing to derive it from — the canonical is shared
  and its own `tenant_id` is NULL. "Is this authoritative?" is only answerable relative to a
  viewer: a conflict raised by one tenant must never change what another tenant sees of the
  shared canon.
  """
  @spec authoritative_curated?(Article.t(), Ecto.UUID.t()) :: boolean()
  def authoritative_curated?(%Article{} = article, tenant_id) when is_binary(tenant_id) do
    curated?(article) and not article_in_open_conflict?(article, tenant_id)
  end

  # TRUE when the article is a member of an unresolved auto-generated
  # :potential_conflict pair. Correlates on the article's globally-unique id ONLY
  # (never `l.tenant_id == ^tenant_id`): a system canonical has `tenant_id == nil`,
  # and Ecto's `==` escaper wraps a pinned nil in a RUNTIME `not_nil!/2` guard that
  # RAISES `ArgumentError: comparing ... with nil is forbidden`. Article ids are UUIDs
  # unique across tenants, so id-only correlation is exactly as scoped as an id+tenant
  # filter would be while also participating for system articles (AC-31.1.3). Mirrors
  # open_conflict_subquery/0 and shares conflict_unresolved_subquery/0.
  defp article_in_open_conflict?(%Article{id: article_id}, tenant_id) do
    # The SAME fail-open window as `open_conflict_subquery/1` — see the long note there for
    # why suppression expires. These are two separate predicates serving one invariant (the
    # per-article authority check and the list query), so the window MUST be applied to both
    # or the invariant is only half true: a stale conflict would keep an article out of
    # `authoritative_curated?/1` while the list happily returned it, which is worse than
    # either behaviour consistently applied.
    cutoff = DateTime.add(DateTime.utc_now(), -conflict_suppression_window_days(), :day)

    query =
      from(l in ArticleLink,
        as: :link,
        # SCOPED TO THE ASKING TENANT, matching `open_conflict_subquery/1`. Article ids are
        # GLOBAL, so correlating on the id alone let ANY tenant's conflict link answer this
        # question — and for a shared system canonical that is a live cross-tenant
        # suppression: one tenant flags the canonical, every other tenant loses it from
        # authoritative answers for the whole window, silently and with no audit event.
        #
        # The earlier comment claimed the scope could not be added because pinning a nil
        # `tenant_id` trips Ecto's nil-comparison guard. That confused two different things:
        # the NULL is on the shared ARTICLE, never on the LINK. A link always belongs to
        # exactly one tenant, so scoping the link is unblocked — which is why the sibling
        # subquery has always done it.
        where: l.tenant_id == ^tenant_id,
        where: l.relationship_type == :potential_conflict,
        where: fragment("(?->>'auto_generated') = 'true'", l.metadata),
        where: l.source_article_id == ^article_id or l.target_article_id == ^article_id,
        where: l.inserted_at > ^cutoff,
        # Row EXISTENCE, matching `open_conflict_subquery/1` — these two are one invariant
        # applied to the per-article check and the list query, so they must release
        # suppression on the same signal or the invariant is only half true.
        where: not exists(judged_pair_subquery())
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

  Opts: `:limit` (default 50, clamped to the max page size), `:offset` (default 0),
  `:origin` (`"system"` or `"asserted"` — anything else is no filter).

  Returns `%{data: [%{link_id, similarity, origin, articles: [%{id, title, status,
  category}, ...]}], meta: %{limit, offset, total_count}}`.
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
        # kb-02: only surface flags with real provenance, so a stray or legacy
        # potential_conflict row is never presented as resolvable evidence. Two kinds
        # qualify and the row says which: `auto_generated` (the linker/lint sweep found
        # it) and `asserted` (#730 — a caller deliberately contested the pair, and the
        # row carries who and why). They are equally REACHABLE and not equally
        # AUTHORITATIVE: an assertion never suppresses its articles from curated answers
        # (`open_conflict_subquery/1` still requires `auto_generated`), and its asserter
        # may not judge it (`validate_not_self_asserted/2`).
        where:
          fragment("(?->>'auto_generated') = 'true'", l.metadata) or
            fragment("(?->>'asserted') = 'true'", l.metadata),
        where: not exists(conflict_unresolved_subquery())
      )
      |> filter_conflict_pairs_by_visibility(vis)
      |> filter_conflict_pairs_by_origin(Keyword.get(opts, :origin))

    total_count = AdminRepo.aggregate(base, :count, :id)

    rows =
      from([link: l, source: s, target: t] in base,
        # ASSERTED pairs lead, and that is a decision rather than an accident of NULL
        # ordering: they carry no similarity score (nothing measured them), and a pair a
        # caller deliberately contested with an argument is a stronger review signal than
        # the mechanical 0.93 threshold that produced most of this queue. Spelled
        # `desc_nulls_first` so the intent survives a Postgres default nobody remembers.
        order_by: [
          desc_nulls_first: fragment("(?->>'similarity_score')::float", l.metadata),
          asc: l.id
        ],
        limit: ^limit,
        offset: ^offset,
        select: %{
          link_id: l.id,
          similarity: fragment("(?->>'similarity_score')::float", l.metadata),
          metadata: l.metadata,
          source: %{id: s.id, title: s.title, status: s.status, category: s.category},
          target: %{id: t.id, title: t.title, status: t.status, category: t.category}
        }
      )
      |> AdminRepo.all()

    data = Enum.map(rows, &conflict_queue_row/1)

    %{data: data, meta: %{limit: limit, offset: offset, total_count: total_count}}
  end

  # One queue row. `origin` is the field a reviewer decides on: a `system` pair was flagged
  # by cosine similarity, which measures REDUNDANCY and cannot see contradiction, so its
  # `similarity` is the whole evidence; an `asserted` pair (#730) has no similarity score at
  # all and carries an argument instead, so the claim travels WITH the pair rather than
  # living in a body the reviewer would have to go and read. Named `origin` and not
  # `auto_generated` because a boolean invites reading the two as "real" and "not real"
  # when the difference is provenance, not validity.
  defp conflict_queue_row(%{metadata: metadata} = r) do
    asserted? = metadata["asserted"] == true

    base = %{
      link_id: r.link_id,
      similarity: r.similarity,
      origin: if(asserted?, do: "asserted", else: "system"),
      articles: [r.source, r.target]
    }

    if asserted? do
      Map.put(base, :assertion, %{
        # The server-derived PRINCIPAL, never the audit label. The label is
        # `"<role>:<key_name>"`, so echoing it here would enumerate the tenant's key names
        # and the roles behind them to every agent-role reader of the queue.
        asserted_by: metadata["asserted_by_principal"],
        asserted_at: metadata["asserted_at"],
        classification: metadata["classification"],
        evidence: metadata["evidence"],
        proposed_authoritative_article_id: metadata["proposed_authoritative_article_id"]
      })
    else
      base
    end
  end

  # `origin` filter (#730). The queue admits two provenances and a reviewer must be able to
  # ask for ONE: asserted rows lead the ordering and no nightly pass drains them, so without
  # this any agent-role caller decides what a reviewer sees first. An unrecognized value is
  # no filter rather than an error — this is a discovery surface, not a write.
  defp filter_conflict_pairs_by_origin(query, "system"),
    do: from([link: l] in query, where: fragment("(?->>'auto_generated') = 'true'", l.metadata))

  defp filter_conflict_pairs_by_origin(query, "asserted"),
    do: from([link: l] in query, where: fragment("(?->>'asserted') = 'true'", l.metadata))

  defp filter_conflict_pairs_by_origin(query, _origin), do: query

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
  ASSERT a conflict between two articles the system never flagged (#730).

  `annotate_conflict/3` can only judge a pair the AUTO-LINKER flagged by mechanical
  similarity, which is exactly the wrong precondition for a DELIBERATE correction: a
  session that has just written an article refuting another has a pair that is minutes
  old (the nightly linker has not run) and may never be lexically similar enough to be
  flagged at all — a good correction argues about the CONCLUSION and can share little
  vocabulary with what it corrects. So the moment you most want to contest an article is
  the moment the queue is unreachable.

  This opens the pair, and nothing else. The assertion:

    * creates the `:potential_conflict` link the caller cannot create directly (the
      public link controller still 422s that type), stamped `auto_generated: false` so
      it is never mistaken for system evidence;
    * carries the CLAIM — `classification`, `evidence` (required) and an optional
      `proposed_authoritative_article_id` — so a reviewer sees the argument, not just
      two ids;
    * surfaces the pair in `GET /api/v1/knowledge/conflicts` and in both articles'
      `potential_conflicts`, which is the structured signal a prose "SUPERSEDED" banner
      in the loser's body could never be (a caller reading snippets never sees a banner).

  ## What it deliberately does NOT do

  **It does not suppress either article from curated answers.** `open_conflict_subquery/1`
  and `article_in_open_conflict?/2` still require `auto_generated == true`, so an agent
  cannot retract an arbitrary article from the governed answer path by asserting a dispute
  over it. Suppression is a system judgement about a system flag.

  **It does not let the asserter act on its own assertion.** `annotate_conflict/3` refuses
  a verdict whose recorder is the principal that asserted the pair
  (`{:error, :self_asserted_conflict}`), and `apply_resolution/2` re-checks it at execution
  time. The pair is manufacturable BY CONSTRUCTION here — the caller names it — so this is
  the same structural separation the story lifecycle enforces between implementing and
  verifying, and the rule the KB's own confused-deputy pattern prescribes for any unattended
  actor consuming caller-recorded intent: the disposition's author must not have created
  both sides of the relationship. Reachability of the pair is what was missing; authority
  over it was not.

  Idempotent per pair: an existing flag (system or asserted, either direction) is returned
  as `{:ok, link, :existing}` rather than duplicated, so a retry is safe and an assertion
  can never overwrite a system flag's provenance.

  ## Options

    * `:visibility_agent_id` — agent-role scope; BOTH members must be visible, refused as
      `:article_not_visible` otherwise (parity with `annotate_conflict/3` and `create_link/3`).
    * `:actor_principal` — the asserting principal, resolved server-side from the key
      (`agent_id || api_key_id`). Persisted as `asserted_by_principal` and compared against
      the recorder's on every later verdict. **Required**: without it there is no identity
      to hold apart, so the assertion is refused rather than recorded unattributed.
    * `:actor_label` / `:actor_id` / `:actor_type` — the usual audit context.
  """
  @spec assert_conflict(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ArticleLink.t(), :created | :existing}
          | {:error,
             Ecto.Changeset.t()
             | :article_not_visible
             | :same_article
             | :missing_article_id
             | :evidence_required
             | :evidence_too_long
             | :invalid_classification
             | :invalid_proposed_article
             | :too_many_open_assertions
             | :unattributed_assertion
             | :assertion_not_recorded}
  def assert_conflict(tenant_id, attrs, opts \\ []) do
    get = fn key -> attrs[key] || attrs[to_string(key)] end
    # Checked in the order SUPPLIED and canonicalized only for storage: canonicalizing
    # first sorts the pair by UUID, so a bad `target_article_id` could come back as an
    # error naming `source_article_id`.
    raw_src = get.(:source_article_id)
    raw_tgt = get.(:target_article_id)
    principal = normalize_principal(Keyword.get(opts, :actor_principal))

    with {:ok, src_id, tgt_id} <- cast_distinct_pair(raw_src, raw_tgt),
         :ok <- validate_assertion_attributed(principal),
         :ok <- validate_assertion_evidence(get.(:evidence)),
         :ok <- validate_assertion_classification(get.(:classification)),
         :ok <-
           validate_proposed_authoritative(
             get.(:proposed_authoritative_article_id),
             src_id,
             tgt_id
           ),
         # VISIBILITY BEFORE EXISTENCE. To an agent caller an id it cannot see and an id
         # that does not exist must be the SAME answer, or the pair of them (404 here, a
         # 422 naming the field below) enumerates which private article ids are real —
         # exactly the probe the visibility model exists to prevent. A higher role passes
         # no scope, sees everything, and still gets the naming 422.
         :ok <-
           validate_assertion_visible(
             tenant_id,
             src_id,
             tgt_id,
             Keyword.get(opts, :visibility_agent_id)
           ),
         :ok <- validate_articles_exist(tenant_id, src_id, tgt_id),
         :ok <- validate_open_assertion_budget(tenant_id, principal) do
      {src, tgt} = canonical_pair(src_id, tgt_id)

      case fetch_conflict_flag(tenant_id, src, tgt) do
        {:ok, %ArticleLink{} = existing} ->
          {:ok, existing, :existing}

        {:error, :no_potential_conflict} ->
          insert_asserted_conflict(tenant_id, src, tgt, attrs, principal, opts)
      end
    end
  end

  defp insert_asserted_conflict(tenant_id, src, tgt, attrs, principal, opts) do
    get = fn key -> attrs[key] || attrs[to_string(key)] end

    # Written through AdminRepo rather than `create_link/3` on purpose: `create_link/3`
    # runs `strip_system_metadata/1`, which exists to stop a CALLER planting provenance
    # markers. The markers here are SERVER-authored (`auto_generated: false` is the one
    # that matters, and the caller has no way to influence it), so this is the same
    # posture the system conflict-writers take — the stripping stays the guard on the
    # caller-facing path it was built for.
    link_attrs = %{
      source_article_id: src,
      target_article_id: tgt,
      relationship_type: :potential_conflict,
      metadata: %{
        # NEVER `true`. This is what keeps an assertion out of curated suppression and
        # out of any future site that reads the marker as "the system found this".
        "auto_generated" => false,
        "asserted" => true,
        "asserted_by_principal" => principal,
        # The audit label, kept for the execution-time backstop's fallback branch only
        # (`apply_flagged_resolution/3`) and deliberately NOT rendered on the queue: it is
        # `"<role>:<key_name>"`, which would enumerate tenant key names to every
        # agent-role reader.
        "asserted_by" => Keyword.get(opts, :actor_label) || Keyword.get(opts, :actor_id),
        "asserted_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "classification" => scalar_or_nil(get.(:classification)),
        "evidence" => scalar_or_nil(get.(:evidence)),
        "proposed_authoritative_article_id" =>
          canonical_uuid_or_nil(get.(:proposed_authoritative_article_id))
      }
    }

    multi =
      Multi.new()
      |> Multi.insert(
        :link,
        ArticleLink.changeset(%ArticleLink{tenant_id: tenant_id}, link_attrs)
      )
      |> Audit.log_in_multi(:audit, &build_assert_conflict_audit(tenant_id, &1, opts))

    case AdminRepo.transaction(multi) do
      {:ok, %{link: link}} ->
        {:ok, link, :created}

      # Lost the insert race against a concurrent assertion (or the nightly promoter):
      # the unique index on (tenant, source, target, relationship_type) fired. The pair
      # IS flagged, which is all this call promises, so re-read rather than 422.
      {:error, :link, %Ecto.Changeset{} = changeset, _} ->
        case fetch_conflict_flag(tenant_id, src, tgt) do
          {:ok, %ArticleLink{} = existing} -> {:ok, existing, :existing}
          {:error, :no_potential_conflict} -> {:error, changeset}
        end

      # The only other step is the AUDIT insert, and its failure is not the caller's to
      # fix: the transaction rolled back, so no link exists. One stable term rather than a
      # CaseClauseError escaping the context as an unrenderable 500.
      {:error, _step, _reason, _changes} ->
        {:error, :assertion_not_recorded}
    end
  end

  defp build_assert_conflict_audit(tenant_id, %{link: link}, opts) do
    %{
      tenant_id: tenant_id,
      entity_type: "article_link",
      entity_id: link.id,
      action: "knowledge.conflict_asserted",
      actor_type: Keyword.get(opts, :actor_type, "api_key"),
      actor_id: Keyword.get(opts, :actor_id),
      actor_label: Keyword.get(opts, :actor_label),
      new_state: %{
        "source_article_id" => to_string(link.source_article_id),
        "target_article_id" => to_string(link.target_article_id),
        "relationship_type" => to_string(link.relationship_type),
        # The identity the separation turns on, recorded where it cannot be edited: a
        # later verdict on this pair is refused if it comes from this principal.
        "asserted_by_principal" => link.metadata["asserted_by_principal"],
        "classification" => link.metadata["classification"],
        "evidence" => link.metadata["evidence"]
      }
    }
  end

  # An article cannot conflict with itself, and the canonical-pair ordering would collapse
  # such a request into a self-link the unique index does not forbid. Decided on the CAST
  # uuid, never the raw string: `:binary_id` normalizes case only at DUMP time, so
  # "0B27..." and "0b27..." are distinct binaries to this guard AND to the changeset's
  # `validate_no_self_link`, and one article landed as a row whose two FK columns hold
  # identical bytes. The cast is also what keeps a non-uuid out of `where: a.id == ^value`,
  # which raises `Ecto.Query.CastError` — a 500 on an ordinary client typo.
  defp cast_distinct_pair(a, b) do
    with {:ok, cast_a} <- cast_article_id(a),
         {:ok, cast_b} <- cast_article_id(b) do
      if cast_a == cast_b, do: {:error, :same_article}, else: {:ok, cast_a, cast_b}
    end
  end

  defp cast_article_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :missing_article_id}
    end
  end

  defp cast_article_id(_value), do: {:error, :missing_article_id}

  defp canonical_uuid_or_nil(value) do
    case cast_article_id(value) do
      {:ok, uuid} -> uuid
      {:error, :missing_article_id} -> nil
    end
  end

  # The three values the tool schema and the OpenAPI request body both declare. Validated
  # rather than trusted because nothing casts this endpoint's params: an unconstrained
  # free-text classification is rendered verbatim to every reviewer of the queue and
  # defeats any consumer that branches on it. Absent is fine; wrong is not.
  @assertion_classifications ~w(redundant complementary contradictory)

  defp validate_assertion_classification(nil), do: :ok

  defp validate_assertion_classification(value)
       when is_binary(value) and value in @assertion_classifications,
       do: :ok

  defp validate_assertion_classification(_value), do: {:error, :invalid_classification}

  # The proposal is a CLAIM a reviewer reads, so it must at least name a member of the pair.
  # Unchecked it accepted any string — a non-uuid, or an article in another tenant — and
  # rendered it as the asserter's proposed winner for anything downstream to carry forward.
  defp validate_proposed_authoritative(nil, _src, _tgt), do: :ok

  defp validate_proposed_authoritative(value, src, tgt) do
    case cast_article_id(value) do
      {:ok, uuid} when uuid == src or uuid == tgt -> :ok
      _ -> {:error, :invalid_proposed_article}
    end
  end

  # A principal may hold only so many UNJUDGED assertions at once. Asserted rows lead the
  # queue and no nightly pass drains them (the auto-judge acts on system flags only), so
  # unbounded, one agent-role key decides what every reviewer sees first. Counted per
  # PRINCIPAL, not per tenant: the bound is on one caller monopolizing the page, never on a
  # tenant genuinely having many open disputes.
  @max_open_assertions_per_principal 25

  defp validate_open_assertion_budget(tenant_id, principal) do
    open =
      from(l in ArticleLink,
        as: :link,
        where: l.tenant_id == ^tenant_id,
        where: l.relationship_type == :potential_conflict,
        where: fragment("(?->>'asserted') = 'true'", l.metadata),
        where: fragment("?->>'asserted_by_principal' = ?", l.metadata, ^principal),
        where: not exists(conflict_unresolved_subquery())
      )
      |> AdminRepo.aggregate(:count, :id)

    if open >= @max_open_assertions_per_principal,
      do: {:error, :too_many_open_assertions},
      else: :ok
  end

  # FAIL CLOSED on an unattributed assertion. `asserted_by_principal` is the ONLY thing
  # separating the asserter from the judge; recorded as nil it would compare equal to every
  # other unattributed caller, which reads as maximum separation while providing none.
  defp validate_assertion_attributed(nil), do: {:error, :unattributed_assertion}
  defp validate_assertion_attributed(_principal), do: :ok

  # Evidence is required because an assertion with no argument is indistinguishable from
  # noise on the one queue a human reviews, and the queue is the whole deliverable here.
  # BOUNDED because it is echoed on every row of that queue and copied into the
  # append-only audit log: the only other limit is the 2 MB request body, which one
  # assertion turns into a multi-megabyte page for every reviewer.
  @max_assertion_evidence_bytes 4_000

  @doc """
  Byte cap on an asserted conflict's `evidence`, so the guard and the endpoint's OpenAPI
  description read ONE number.
  """
  @spec max_assertion_evidence_bytes() :: pos_integer()
  def max_assertion_evidence_bytes, do: @max_assertion_evidence_bytes

  defp validate_assertion_evidence(evidence) when is_binary(evidence) do
    cond do
      String.trim(evidence) == "" -> {:error, :evidence_required}
      byte_size(evidence) > @max_assertion_evidence_bytes -> {:error, :evidence_too_long}
      true -> :ok
    end
  end

  defp validate_assertion_evidence(_evidence), do: {:error, :evidence_required}

  defp validate_assertion_visible(tenant_id, src, tgt, agent_id) do
    case validate_pair_visible(tenant_id, src, tgt, agent_id) do
      :ok -> :ok
      {:error, :no_potential_conflict} -> {:error, :article_not_visible}
    end
  end

  # A principal is a server-derived id string; anything else (a map, a list, an empty
  # string) is no identity at all and is normalized to nil so the fail-closed checks fire.
  defp normalize_principal(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_principal(_value), do: nil

  # Link metadata is JSONB: keep only scalars a caller could reasonably have meant, so a
  # nested object in `classification` cannot be smuggled into the reviewer's view.
  defp scalar_or_nil(value) when is_binary(value), do: value
  defp scalar_or_nil(_value), do: nil

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

  ## Confidence is GRANTED, never accepted (see `grant_confidence/3`)

  `opts[:actor_role]` — the role of the key recording the verdict, resolved server-side
  from the authenticating key and never client-supplied. On a `:supersede` it CAPS the
  recorded confidence, because `confidence: :high` there is what authorizes the nightly
  executor to retire an article with nobody watching; a `:merge` retires nothing and is
  never capped. The role is persisted either way. A caller omitting it is recorded at the
  lowest-trust cap: an unidentified recorder is not a privileged one.
  """
  @spec annotate_conflict(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ConflictResolution.t()}
          | {:error, Ecto.Changeset.t() | :no_potential_conflict | :self_asserted_conflict}
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
         {:ok, flag} <- conflict_flag_for_verdict(tenant_id, src, tgt),
         # #730: an ASSERTED pair is reachable, but never by the principal that asserted it.
         :ok <- validate_not_self_asserted(flag, opts) do
      disposition = get.(:disposition)
      now = DateTime.utc_now()
      role = recorder_role(opts)
      {confidence, requested} = grant_confidence(get.(:confidence), disposition, role)

      row_attrs = %{
        source_article_id: src,
        target_article_id: tgt,
        authoritative_article_id: get.(:authoritative_article_id),
        classification: get.(:classification),
        disposition: disposition,
        confidence: confidence,
        requested_confidence: requested,
        evidence: get.(:evidence),
        annotated_by: Keyword.get(opts, :actor_label) || Keyword.get(opts, :actor_id),
        annotated_by_role: role,
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
               # Both provenance columns MUST be replaced with the rest. A re-annotation
               # that carried the new verdict but kept the previous row's recorder would
               # let a low-trust caller inherit a privileged recorder's authorization.
               :requested_confidence,
               :evidence,
               :annotated_by,
               :annotated_by_role,
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

      stamp_verdict_principal(flag, result, opts)

      result
    end
  end

  # #730: record the RECORDER's principal next to the asserter's, so the execution-time
  # separation re-check compares two server-derived identities. It used to compare audit
  # LABELS (`"<role>:<key_name>"`), and nothing makes a key name unique: a collision
  # silently discarded a legitimate verdict and closed the row, while two dispatch keys of
  # ONE agent never collide at all — so the backstop fired where it must not and stayed
  # quiet where it must. Only an asserted flag carries an asserter, so only it is stamped.
  defp stamp_verdict_principal(%ArticleLink{} = flag, {:ok, %ConflictResolution{}}, opts) do
    case normalize_principal(flag.metadata["asserted_by_principal"]) do
      nil ->
        :ok

      _asserted_by ->
        recorder = normalize_principal(Keyword.get(opts, :actor_principal))
        metadata = Map.put(flag.metadata, "verdict_by_principal", recorder)

        flag
        |> Ecto.Changeset.change(metadata: metadata)
        |> AdminRepo.update()

        :ok
    end
  end

  defp stamp_verdict_principal(_flag, _result, _opts), do: :ok

  # The roles whose recorded verdict may authorize an UNATTENDED RETIREMENT, and the one
  # place that set is written down. Read by `grant_confidence/3` (which caps what a
  # non-member may record) and re-checked by `executable_resolution/0` against the persisted
  # `annotated_by_role`, so the authorization is evidenced on the row rather than recomputed
  # from a value the request supplied.
  @unattended_authorizing_roles ~w(orchestrator user superadmin)

  # Confidence is the field that AUTHORIZES the nightly executor to retire a published
  # article with nobody in the loop, so for `:supersede` it is granted by the server, not
  # asserted by the caller.
  #
  # Why a cap rather than "record what they said and gate elsewhere": the conflict PAIR is
  # manufacturable — the queue is populated by a mechanical similarity threshold, so the
  # same party that records the verdict can arrange for the pair to exist. A party that can
  # arrange the input cannot also certify its own output as trusted; that is the same
  # structural separation the story lifecycle enforces between implementing and verifying.
  #
  # `:merge` is NOT capped, and that boundary is the whole point: it RETIRES NOTHING.
  # `merge_source_articles/2` synthesizes a NEW DRAFT and leaves both sources published, so
  # there is no unattended retirement to authorize — capping it bought no safety and turned
  # the disposition off for the agent role the KB-content carve-out (#331) exists to serve.
  # Curation stays agent-role in every disposition; what an agent cannot do alone is retire
  # somebody else's article while nobody is watching.
  #
  # Uncapped is not ungated. A `:merge` the executor will act on still spends the tenant's
  # paid model key and egresses both bodies, so it carries the same `evidence` requirement a
  # `:high` supersede does (`ConflictResolution.changeset/2`), and the draft it produces
  # inherits the most restrictive of its sources' visibility (`mergeable_visibility/2`) —
  # the two bars that replace the cap rather than nothing replacing it.
  #
  # Returns `{granted, requested_when_capped}` — the caller's ask is kept only when it was
  # lowered, so a capped verdict is auditable instead of silently rewritten.
  defp grant_confidence(requested, disposition, role) do
    asked = normalize_confidence(requested)
    granted = if capped?(disposition, role), do: cap_confidence(asked), else: asked

    if granted == asked, do: {granted, nil}, else: {granted, asked}
  end

  # Compared WITHOUT `to_string/1`, like every other disposition test on this path: a
  # non-scalar disposition (a JSON object) must reach the changeset's enum cast as a 422,
  # not raise a Protocol.UndefinedError out of the grant.
  defp capped?(disposition, role),
    do: disposition in [:supersede, "supersede"] and role not in @unattended_authorizing_roles

  # `:high` is the only value that authorizes the unattended write, so it is the only one
  # capped. An unrecognized value is left ALONE for the changeset's enum cast to reject —
  # coercing it here would answer a malformed request with a silent default.
  defp cap_confidence(:high), do: :medium
  defp cap_confidence(other), do: other

  defp normalize_confidence(nil), do: :medium
  defp normalize_confidence("high"), do: :high
  defp normalize_confidence("medium"), do: :medium
  defp normalize_confidence("low"), do: :low
  defp normalize_confidence(other), do: other

  # Fail closed: an omitted or unrecognized role is recorded as `agent`, the lowest trust
  # this surface grants. A caller that does not identify its recorder does not get the
  # benefit of the doubt on the one field that authorizes an unattended retirement.
  # Always a STRING, so the persisted column and the allowlist comparison are the same
  # type at every site.
  defp recorder_role(opts) do
    case Keyword.get(opts, :actor_role) do
      role when is_atom(role) and not is_nil(role) -> Atom.to_string(role)
      role when is_binary(role) -> role
      _ -> "agent"
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
  # The flag lookup AS THE VERDICT PATH needs it. When an id is missing we return
  # `:deferred` and let the changeset's required-field validation produce the 422, rather
  # than masking a malformed request as "no conflict" — the same deferral the pre-#730
  # `validate_potential_conflict_exists/3` made, and the reason it is preserved here
  # instead of collapsing both callers onto one lookup.
  defp conflict_flag_for_verdict(tenant_id, src, tgt) when is_binary(src) and is_binary(tgt),
    do: fetch_conflict_flag(tenant_id, src, tgt)

  defp conflict_flag_for_verdict(_tenant_id, _src, _tgt), do: {:ok, :deferred}

  # The same lookup, returning the LINK so its provenance can be read. A SYSTEM flag
  # (`auto_generated: true`) and an ASSERTED one (#730) are both real flags for the purpose
  # of "may a verdict be recorded here" — the distinction is not reachability but WHO may
  # record it, which `validate_not_self_asserted/2` decides from the link's stamped
  # `asserted_by_principal`. A SYSTEM flag is preferred when both somehow exist so the
  # stronger provenance wins the tie and an assertion can never downgrade a system flag.
  defp fetch_conflict_flag(tenant_id, src, tgt) when is_binary(src) and is_binary(tgt) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.relationship_type == :potential_conflict,
      where:
        fragment("(?->>'auto_generated') = 'true'", l.metadata) or
          fragment("(?->>'asserted') = 'true'", l.metadata),
      where:
        (l.source_article_id == ^src and l.target_article_id == ^tgt) or
          (l.source_article_id == ^tgt and l.target_article_id == ^src),
      order_by: [desc: fragment("(?->>'auto_generated') = 'true'", l.metadata)],
      limit: 1
    )
    |> AdminRepo.one()
    |> case do
      %ArticleLink{} = link -> {:ok, link}
      nil -> {:error, :no_potential_conflict}
    end
  end

  defp fetch_conflict_flag(_tenant_id, _src, _tgt), do: {:error, :no_potential_conflict}

  # #730: the asserter of a pair may not also judge it.
  #
  # An ASSERTED pair is manufacturable by definition — the caller named both ids — so the
  # one property that made `annotate_conflict/3` safe on a SYSTEM flag (the pair predates
  # and is independent of the caller) is absent by construction. The KB's own
  # confused-deputy pattern names the remedy: the disposition's author must not have
  # created both sides of the relationship. Role separation alone is not it, because a
  # `:merge` is never role-capped and a `:dismiss` is terminal the moment it is recorded —
  # so without this, asserting a pair and immediately dismissing it would let any caller
  # pre-settle an arbitrary pair and suppress a GENUINE system flag raised over it later.
  #
  # Fail closed on an unknown recorder: an assertion cannot be recorded without a principal
  # (`validate_assertion_attributed/1`), so a nil on THIS side means the verdict path did
  # not supply one, and permitting it would make "no identity" the way through.
  # `:deferred` — a malformed request whose 422 belongs to the changeset (see
  # `conflict_flag_for_verdict/3`). There is no pair to hold anyone apart from.
  defp validate_not_self_asserted(:deferred, _opts), do: :ok

  defp validate_not_self_asserted(%ArticleLink{metadata: metadata}, opts) do
    asserted_by = normalize_principal(metadata["asserted_by_principal"])
    recorder = normalize_principal(Keyword.get(opts, :actor_principal))

    cond do
      # A system flag carries no asserter — nothing to hold apart.
      is_nil(asserted_by) -> :ok
      is_nil(recorder) -> {:error, :self_asserted_conflict}
      asserted_by == recorder -> {:error, :self_asserted_conflict}
      true -> :ok
    end
  end

  @doc """
  Nightly executor for conflict resolutions (route-the-findings #4). Applies only
  high-confidence, not-yet-executed rows — and, for the one disposition that RETIRES an
  article (`:supersede`), only those recorded by a role that may authorize an unattended
  retirement. All reversible/non-destructive and audited:

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
        where: ^executable_resolution(),
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

    executed =
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

    close_unexecutable_resolutions(tenant_id)
    executed
  end

  # The SILENT BLACK HOLE, closed.
  #
  # WILL this pending row be applied as recorded? Composed into the executor AND into
  # `conflict_unresolved_subquery/0`, so "the executor acts on it" and "the pair is settled"
  # can never drift into disagreeing. The role check applies to `:supersede` ALONE — that is
  # the only disposition that retires an article unattended; a `:merge` synthesizes a new
  # draft and retires nothing, so an agent-recorded merge executes normally.
  defp executable_resolution do
    dynamic(
      [r],
      r.confidence == :high and
        (r.disposition == :merge or r.annotated_by_role in ^@unattended_authorizing_roles)
    )
  end

  # The executor requires `confidence == :high` (plus an authorizing recorder on a
  # `:supersede`). A `:supersede`/`:merge` that clears neither bar never executes — and if
  # the mere EXISTENCE of the row settled the pair it would also drop out of
  # `list_potential_conflicts/2` and Consolidation's `judged_pairs/1`, vanishing from every
  # surface while changing nothing: not pending, not applied, not visible, forever. That is
  # why `conflict_unresolved_subquery/0` settles a pair on `^executable_resolution()` rather
  # than on row existence: a verdict nothing will act on leaves the pair IN the queue, where
  # an orchestrator+ key can find it and re-record it. That is the routing step the remedy
  # ("re-annotate at :high confidence") needs in order to be actionable.
  #
  # What is closed here is the narrower case that visibility cannot help: a verdict the
  # caller DELIBERATELY recorded below `:high` (`requested_confidence IS NULL` — nothing was
  # capped). Re-surfacing that pair forever would just re-offer a question its judge already
  # answered. A CAPPED row is excluded: the caller asked for `:high` and the server granted
  # less, so it is left pending and its pair stays visible for an authorized re-record.
  #
  # Closed as DISMISSED rather than executed: lowering the executor's bar would let a
  # judgement its own author distrusted retire an article. Dismissing keeps both articles and
  # is undone by re-annotating the pair.
  #
  # Logged at :warning with the pair ids (bounded), not just a count — an operator who wants
  # to re-record needs to know WHICH pairs were closed.
  @logged_pairs 20

  defp close_unexecutable_resolutions(tenant_id) do
    now = DateTime.utc_now()

    scope =
      from(r in ConflictResolution,
        where: r.tenant_id == ^tenant_id,
        where: is_nil(r.executed_at),
        where: r.disposition in [:supersede, :merge],
        where: r.confidence != :high,
        where: is_nil(r.requested_confidence)
      )

    # LIMITed to what the log prints. This SELECT exists only to name the pairs; without the
    # limit a tenant with a large backlog materialises the entire unexecutable set every
    # night to print twenty of them. The `closed` COUNT still comes from `update_all`, so
    # the number stays exact while the sample stays bounded.
    pairs =
      AdminRepo.all(
        from(r in scope, select: {r.source_article_id, r.target_article_id}, limit: @logged_pairs)
      )

    {closed, _} =
      AdminRepo.update_all(scope,
        set: [
          executed_at: now,
          updated_at: now,
          execution_result: %{
            "action" => "skipped",
            "reason" => "insufficient_confidence",
            "detail" =>
              "A supersede/merge deliberately recorded below :high confidence is never " <>
                "executed by design. It was closed as dismissed so it cannot sit invisible " <>
                "and unapplied forever; both articles are retained. Re-annotate the pair at " <>
                ":high confidence to apply it."
          }
        ]
      )

    if closed > 0 do
      Logger.warning(
        "ConflictExecutor: tenant=#{tenant_id} closed #{closed} unexecutable resolution(s) " <>
          "(supersede/merge deliberately recorded below :high confidence). Both articles " <>
          "retained in each case; re-annotate to apply. Pairs: " <>
          inspect(pairs) <>
          ". A persistent count here means something upstream is recording judgements it " <>
          "does not believe."
      )
    end

    closed
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
    case fetch_conflict_flag(tenant_id, r.source_article_id, r.target_article_id) do
      {:ok, %ArticleLink{} = flag} ->
        apply_flagged_resolution(tenant_id, r, flag)

      {:error, :no_potential_conflict} ->
        mark_resolution_executed(r, %{
          "action" => "noop",
          "reason" => "potential_conflict flag retracted"
        })

        false
    end
  end

  # #730, defense in depth. `annotate_conflict/3` already refuses a verdict recorded by the
  # principal that asserted the pair, so this should be unreachable — it is here because the
  # KB's confused-deputy pattern prescribes re-validating at EXECUTION time that the
  # disposition's author did not create both sides, and a guard that only runs at write time
  # is one code path away from being bypassed by a future caller.
  #
  # It compares PRINCIPALS whenever both are on the row — the asserter's is stamped at
  # assert time and the recorder's at verdict time (`stamp_verdict_principal/3`) — and only
  # falls back to the audit LABELS when no verdict principal was stamped, which is exactly
  # the alternate-route write this backstop exists for. Labels are `"<role>:<key_name>"` and
  # nothing makes a key name unique, so deciding on them alone silently discarded a
  # legitimate verdict on a name collision and never fired for the two dispatch keys of one
  # agent. Closed as executed (audited) rather than skipped, so a refused row can never sit
  # pending forever while `executable_resolution/0` reads its pair as settled.
  defp apply_flagged_resolution(tenant_id, %ConflictResolution{} = r, %ArticleLink{} = flag) do
    asserted_by = normalize_principal(flag.metadata["asserted_by_principal"])
    recorder = normalize_principal(flag.metadata["verdict_by_principal"])

    self_asserted? =
      cond do
        is_nil(asserted_by) ->
          false

        not is_nil(recorder) ->
          asserted_by == recorder

        true ->
          label = normalize_principal(flag.metadata["asserted_by"])
          not is_nil(label) and label == normalize_principal(r.annotated_by)
      end

    if self_asserted? do
      mark_resolution_executed(r, %{
        "action" => "noop",
        "reason" => "self_asserted_conflict",
        "detail" =>
          "The verdict was recorded by the same actor that asserted this pair. An " <>
            "asserted pair is named by its caller, so its judge must be someone else."
      })

      false
    else
      apply_disposition(tenant_id, r)
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

    case mergeable_visibility(a, b) do
      :missing_source ->
        mark_resolution_executed(r, %{"action" => "noop", "reason" => "source missing"})
        false

      # Two sources restricted to DIFFERENT agents have no visibility the merged draft could
      # carry that discloses neither to the other. Refused BEFORE synthesis, so the bodies
      # are never egressed for a draft that could not have been written safely.
      :incompatible ->
        mark_resolution_executed(r, %{
          "action" => "noop",
          "reason" => "sources are restricted to different agents"
        })

        false

      {:ok, visibility} ->
        do_merge(tenant_id, r, a, b, visibility)
    end
  end

  # The visibility the merged draft must carry: the MOST RESTRICTIVE of its two sources,
  # with the owner that restriction belongs to. The synthesized body is derived from BOTH
  # sources' full text, and `create_merged_draft/6` previously set no `visibility` key at
  # all — which every read path COALESCEs to `shared`. A private/owner memory merged with a
  # shared article therefore landed as a tenant-wide readable draft, promoting restricted
  # content through a curation verdict. Same rule, and the same reason, as
  # `merge_egress_scope/3`.
  defp mergeable_visibility(nil, _b), do: :missing_source
  defp mergeable_visibility(_a, nil), do: :missing_source

  defp mergeable_visibility(a, b) do
    restricted = Enum.filter([a, b], &restricted?/1)
    owners = restricted |> Enum.map(&owner_of/1) |> Enum.uniq()

    case {restricted, owners} do
      {[], _} -> {:ok, %{}}
      {_, [owner]} -> {:ok, %{"visibility" => restrictive_label(restricted), "agent_id" => owner}}
      {_, _many} -> :incompatible
    end
  end

  defp restrictive_label(restricted) do
    if Enum.any?(restricted, &(visibility_of(&1) == "private")), do: "private", else: "owner"
  end

  defp restricted?(article), do: visibility_of(article) in ["private", "owner"]

  defp visibility_of(%Article{metadata: metadata}) do
    metadata = metadata || %{}
    metadata["visibility"] || metadata[:visibility] || "shared"
  end

  defp owner_of(%Article{metadata: metadata}) do
    metadata = metadata || %{}
    metadata["agent_id"] || metadata[:agent_id]
  end

  defp do_merge(tenant_id, r, a, b, visibility) do
    scope = merge_egress_scope(tenant_id, a, b)

    # US-41.7 (AC-41.7.1): BOTH articles' full bodies are POSTed to the tenant's
    # chat endpoint, so the merge is a content-touching operation on BOTH rows and
    # each gets its own posture entry. Recorded BEFORE the call so a synthesis that
    # egressed and then failed is still a recorded operation naming the endpoint it
    # went to (AC-41.7.2), with the outcome patched on afterwards.
    recorded = Enum.map([a, b], &Custody.record(scope, "article", &1.id, :merge))

    result =
      merge_synthesizer().synthesize(
        scope,
        %{title: a.title, body: a.body},
        %{title: b.title, body: b.body}
      )

    outcome = if match?({:ok, _}, result), do: :succeeded, else: :failed
    Enum.each(recorded, &Custody.record_outcome(&1, outcome))

    case result do
      {:ok, %{title: title, body: body}} ->
        create_merged_draft(tenant_id, r, a, title, body, visibility)

      {:error, reason} ->
        handle_merge_error(r, reason)
    end
  end

  # US-41.4 (AC-41.4.2): BOTH articles' bodies are POSTed to the model provider, so
  # the synthesis must run under the MOST RESTRICTIVE of their scopes. When either
  # article's project is marked `local_only`, that project's scope is used — a
  # tenant-wide scope would let one project's content ship because the OTHER
  # article happens to be unmarked.
  defp merge_egress_scope(tenant_id, a, b) do
    scopes =
      [a.project_id, b.project_id]
      |> Enum.uniq()
      |> Enum.map(&EgressScope.new(tenant_id, &1))

    Enum.find(scopes, hd(scopes), &EgressPolicy.local_only?/1)
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

  # US-41.3 (AC-41.3.4): a shape failure from the OpenAI-compatible sibling — the
  # configured local model cannot emit the required JSON object. PERMANENT, so the
  # nightly executor stops re-attempting an identical synthesis (and never drafts a
  # malformed merged article).
  defp permanent_merge_error?({:invalid_response_shape, _details}), do: true

  # US-41.4 (AC-41.4.3): `:egress_blocked` is a PERMANENT local configuration
  # refusal — nothing was sent and nothing changes on its own. Without this clause
  # the catch-all buckets it as transient and the nightly conflict executor retries
  # the identical, permanently refused synthesis forever, logging "transiently
  # failed". `:pin_stale` / `:egress_unavailable` stay transient (they self-heal),
  # which is why only this tag is listed.
  defp permanent_merge_error?({:egress_blocked, _details}), do: true

  # US-37.3: a throttle 4-tuple (429/503 + Retry-After) is transient — it must NOT
  # match the permanent 4xx clause below (that clause is arity-3 only, but be
  # explicit so the widened shape can never be misclassified as permanent).
  defp permanent_merge_error?({:api_error, _status, _tag, _retry_after}), do: false

  defp permanent_merge_error?({:api_error, status, _body})
       when is_integer(status) and status >= 400 and status < 500 and status != 408 and
              status != 429,
       do: true

  defp permanent_merge_error?(_), do: false

  defp create_merged_draft(tenant_id, r, source_a, title, body, visibility) do
    attrs = %{
      title: title,
      body: body,
      category: source_a.category,
      status: :draft,
      tags: ["merged"],
      # `visibility` is the restrictive merge of both sources (see `mergeable_visibility/2`),
      # empty when both are shared.
      metadata:
        Map.merge(
          %{
            "merged_from" => [r.source_article_id, r.target_article_id],
            "conflict_resolution_id" => r.id
          },
          visibility
        )
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
    # US-41.3: the DEFAULT is the tenant-aware ROUTER; the resolution point itself
    # (this Application.get_env) is unchanged, so config/test.exs's Mox mapping
    # still intercepts.
    Application.get_env(:loopctl, :merge_synthesizer, Loopctl.Knowledge.MergeSynthesizerRouter)
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

      plus `ann_iterative_scan` (and `ann_iterative_scan_reason` alongside
      `"unavailable"` only) — the same vector-read disclosure semantic search and memory
      recall carry, from the one derivation `Loopctl.HeavyRead.iterative_scan_meta/1`.

    * `{:ok, [], meta}` when the article has no embedding yet (`pool_exhausted: false`,
      and no `ann_iterative_scan` — that short-circuit runs no vector read)
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

    # Resolve the cutover flag ONCE for the whole operation and thread it (review): the
    # source-vector fetch and the candidate scan must see the SAME value, or an operator
    # flip mid-request makes suggest_links read the source from one table type and
    # candidates from the other (a dimension mismatch / empty result).
    reads_side_table? = Embeddings.side_table_reads_enabled?()

    with :ok <- validate_threshold(threshold) do
      case fetch_article_embedding(tenant_id, article_id, vis, reads_side_table?) do
        nil ->
          {:error, :not_found}

        %{embedding: nil} ->
          {:ok, [], empty_suggestion_meta(limit)}

        %{embedding: embedding} ->
          {suggestions, meta} =
            suggestion_candidates(tenant_id, article_id, embedding, threshold, limit, vis,
              reads_side_table: reads_side_table?
            )

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
  #
  # US-41.1 (review): behind the cutover flag the SOURCE vector comes from the
  # dimension-tagged side table, exactly like the CANDIDATE half already did
  # (`VectorSearch.candidate_pool_query/4`). `update_embedding/5` never writes
  # `articles.embedding` for a non-1536 dimension, so reading the source there
  # returned `%{embedding: nil}` for every 768/1024 tenant and
  # `suggest_links_with_meta/3` short-circuited to `{:ok, [], empty_suggestion_meta}`
  # — with `pool_exhausted: false`, i.e. indistinguishable from "no neighbours
  # exist". Migrating one half of a feature and not the other is the worst of both.
  defp fetch_article_embedding(tenant_id, article_id, vis, reads_side_table?) do
    if valid_uuid?(article_id) do
      if reads_side_table? do
        fetch_side_table_article_embedding(tenant_id, article_id, vis)
      else
        from(a in Article,
          where: a.tenant_id == ^tenant_id and a.id == ^article_id and a.status == :published,
          select: %{embedding: a.embedding}
        )
        |> maybe_filter_by_visibility(vis)
        |> AdminRepo.one()
      end
    end
  end

  # The article must still exist, be published and be visible — so the existence
  # half stays on `articles` (a missing row must yield `{:error, :not_found}`, NOT
  # "no embedding"), and only the VECTOR is left-joined from the side table at the
  # tenant's active dimension.
  defp fetch_side_table_article_embedding(tenant_id, article_id, vis) do
    dimension = Embeddings.active_dimension(tenant_id)

    from(a in Article,
      left_join: ae in ArticleEmbedding,
      on:
        ae.article_id == a.id and ae.tenant_id == ^tenant_id and ae.dim == ^dimension and
          ae.live_denorm,
      where: a.tenant_id == ^tenant_id and a.id == ^article_id and a.status == :published,
      select: %{embedding: ae.embedding}
    )
    |> maybe_filter_by_visibility(vis)
    |> AdminRepo.one()
  end

  defp suggestion_candidates(tenant_id, article_id, embedding, threshold, limit, vis, opts) do
    # Routed through Loopctl.HeavyRead (US-27.11): the dedicated heavy-read pool,
    # isolated from the small AdminRepo pool, with a per-read SET LOCAL
    # statement_timeout (US-27.13 — a short transaction, the connection released at
    # commit). The wrapper structurally requires a tenant_id-filtered query; the
    # tenant predicate lives in this query's inner subquery. The 15s client timeout
    # is a backstop above the server-side statement_timeout.
    query =
      suggestion_candidates_query(tenant_id, article_id, embedding, threshold, limit, vis, opts)

    # Bound ONCE and threaded into BOTH the read and its disclosure below, so the two can
    # never describe different executions (#631/#634).
    read_opts = suggested_links_read_opts(suggestion_candidate_pool(limit), opts)

    suggestions = HeavyRead.all(tenant_id, query, read_opts)

    returned = length(suggestions)

    meta =
      maybe_signal_under_fill(
        tenant_id,
        article_id,
        embedding,
        threshold,
        vis,
        limit,
        returned,
        opts
      )
      # #634: `:suggested_links` is an ANN endpoint too, and this is a CALLER-facing read
      # with a meta envelope — so it discloses in the same words as semantic search and
      # memory recall. `recall_truncated` cannot stand in for it: it flags the anti-join
      # cutting a FULL pool, not an index batch that never reached this tenant's rows, so
      # a starved scan reads as `recall_truncated: false` plus a short list, i.e. "this
      # article has no neighbours".
      |> Map.merge(HeavyRead.iterative_scan_meta(read_opts))

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
         returned,
         opts
       ) do
    pool = suggestion_candidate_pool(limit)
    base = %{requested: limit, returned: returned, pool: pool}
    not_truncated = Map.merge(base, %{pool_exhausted: false, recall_truncated: false})

    if returned < limit do
      case under_fill_probe(tenant_id, article_id, embedding, threshold, vis, pool, opts) do
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
  #
  # Public-but-`@doc false` (same precedent as `under_fill_probe_degraded/2` below) with the
  # read as a DEFAULTED trailing ARGUMENT — so a test can drive a real pool EXIT through THIS
  # function and the `catch` below is verified where it lives, instead of only its classifier
  # being asserted from a hand-built tuple (an inert guard passes that test either way).
  # Deliberately NOT read from `opts`: `opts` is threaded down from the public
  # `suggest_links_with_meta/3`, so a stray `:probe_read` key would silently replace
  # `HeavyRead.one/3` — and with it `HeavyRead.guard!/2`'s structural tenant-scoping — for
  # anyone who ever passes caller-influenced opts through. A positional argument no public
  # caller supplies cannot be reached that way.
  @doc false
  def under_fill_probe(
        tenant_id,
        article_id,
        embedding,
        threshold,
        vis,
        pool,
        opts,
        read \\ &HeavyRead.one/3
      )
      when is_function(read, 3) do
    candidates = suggestion_candidates_inner(tenant_id, article_id, embedding, vis, pool, opts)

    probe =
      from(c in subquery(candidates),
        select: %{
          ann_candidates: count(c.id),
          above_threshold:
            fragment("COUNT(*) FILTER (WHERE ? > ?)", c.similarity_score, ^threshold)
        }
      )

    case read.(tenant_id, probe, probe_read_opts(pool, opts)) do
      %{ann_candidates: a, above_threshold: t} ->
        {a || 0, t || 0}

      nil ->
        {0, 0}

      {:error, :heavy_read_overloaded} ->
        under_fill_probe_degraded(tenant_id, :heavy_read_overloaded)
    end
  rescue
    e in DBConnection.ConnectionError ->
      # `LocalGuc`'s capture ABORT shares this struct with a transient pool fault and is a
      # different animal — a deliberate refusal to override a GUC an enclosing scope owns —
      # so it is NAMED distinctly. It still degrades: this probe runs only after the
      # suggestions are already in hand and feeds a diagnostic signal, so re-raising would
      # trade a valid response for a 503 over a diagnostic read, which is precisely what the
      # AREA-5 fail-soft contract at `maybe_signal_under_fill/8` forbids.
      under_fill_probe_degraded(tenant_id, e)

    e in Postgrex.Error ->
      # Degrade ONLY on a server-side cancel (statement_timeout); re-raise anything else
      # (e.g. a malformed query) so genuine bugs surface in tests instead of silently
      # becoming a missing signal.
      if match?(%{postgres: %{code: :query_canceled}}, e) do
        under_fill_probe_degraded(tenant_id, e)
      else
        reraise(e, __STACKTRACE__)
      end
  catch
    # Both clauses above cover only the RAISE shape. A DBConnection checkout against a wedged
    # or unstarted pool EXITS, so it escaped the rescue entirely and destroyed an
    # ALREADY-COMPUTED suggestions response — turning a diagnostic read into a failed request,
    # the exact trade the AREA-5 fail-soft contract at `maybe_signal_under_fill/8` forbids and
    # that the `DBConnection.ConnectionError` clause above was written to prevent.
    #
    # Unlike the Postgrex clause there is no re-raise branch here: an exit carries no SQLSTATE
    # to tell a genuine query bug from a pool fault, and this probe runs after the response is
    # in hand, so degrading is the only answer that keeps the contract.
    kind, reason when kind in [:exit, :throw] ->
      under_fill_probe_degraded(tenant_id, {kind, ExitTag.tag(reason)})
  end

  @doc false
  # The probe's ONE fail-soft exit. A degraded probe used to be a 503; it is now a 200 whose
  # truncation signal is silently absent, so the refusal must stay ALERTABLE — a log line
  # alone is invisible to a dashboard. Emits the bounded counter
  # (`TelemetryEvents.vector_search_under_fill_probe_degraded/0`) and logs the CLASS TAG only:
  # `Exception.message/1` on a Postgrex/DBConnection struct names the backend host, database
  # and role. Public-but-`@doc false` so the degradation contract is testable through the real
  # path (see `heavy_read_opts/1` for the same precedent).
  def under_fill_probe_degraded(tenant_id, error) do
    error_class = probe_error_class(error)

    :telemetry.execute(
      Loopctl.TelemetryEvents.vector_search_under_fill_probe_degraded(),
      %{count: 1},
      %{tenant_id: tenant_id, endpoint: :suggested_links, error_class: error_class}
    )

    Logger.warning(
      "knowledge.vector_search under_fill probe degraded (#{error_class}) " <>
        "tenant_id=#{tenant_id}; suggestions returned"
    )

    :error
  end

  defp probe_error_class(%DBConnection.ConnectionError{} = e) do
    if LocalGuc.capture_abort?(e), do: "guc_capture_abort", else: "connection"
  end

  # Only reachable for 57014 — the caller re-raises every other SQLSTATE.
  defp probe_error_class(%Postgrex.Error{}), do: "timeout"

  # The per-tenant heavy-read gate SHEDDING this advisory read (`on_overload: :tag`, see
  # `probe_read_opts/2`) — its own class, because "the tenant is at its in-flight cap" is a
  # different operator action from a pool fault.
  defp probe_error_class(:heavy_read_overloaded), do: "overloaded"

  # The non-local-exit shapes, classified by `Loopctl.ExitTag` at the catch site and prefixed
  # by KIND so a dead pool (`exit:noproc`) is distinguishable from a throw escaping the probe.
  # `ExitClass` closes the tag set: this is a Prometheus label multiplied by `tenant_id`, and
  # `ExitTag` names ANY exit atom or exception MODULE, which is a log answer, not a label one.
  defp probe_error_class({kind, tag}) when kind in [:exit, :throw] and is_binary(tag),
    do: ExitClass.bounded(kind, tag)

  # The probe's read opts: the suggested-links opts plus `on_overload: :tag`. The API default
  # (`:raise`) turns a `TenantGate` shed into `Loopctl.HeavyRead.OverloadedError` — an
  # `:error`-kind raise named by neither `rescue` clause above nor the `:exit`/`:throw`
  # `catch` — so at exactly the load the gate exists for it escaped and sank an
  # ALREADY-COMPUTED 200 into a 429, the AREA-5 trade `maybe_signal_under_fill/8` forbids.
  defp probe_read_opts(pool, opts) do
    Keyword.put(suggested_links_read_opts(pool, opts), :on_overload, :tag)
  end

  @doc false
  # Per-read options for a heavy endpoint (US-27.4). Delegates to the single source of
  # truth, `Loopctl.HeavyRead.opts/1`, so the opts shape can't drift between callers
  # (Knowledge / Audit). Public-but-`@doc false` so the slow-query telemetry test can
  # exercise the real opts-building path (incl. the override branch) through this name.
  def heavy_read_opts(endpoint), do: HeavyRead.opts(endpoint)

  # Per-read opts for the suggested-links side-table ANN (#508 review). When the read
  # hits the dimension-tagged side table (`reads_side_table?` threaded from
  # `suggest_links_with_meta/3`), the inner ANN over-fetches to
  # `side_table_inner_pool(pool)` to offset the status/visibility trim the per-dimension
  # partial index cannot carry (`live_denorm` mirrors only `status <> 'superseded'`,
  # not draft/archived or other-agents' private). But an HNSW scan visits only
  # ~`ef_search` nodes regardless of LIMIT, so that over-fetch is INERT unless
  # `ef_search` is widened in lockstep — otherwise the inner returns ~ef_search rows and
  # the outer status/visibility/anti-join trim yields FEWER published+visible links than
  # the legacy `articles.embedding` path did (the exact silent under-return #508 fixed,
  # on the entire non-1536-dim tenant class), and the under-fill probe counts over the
  # same starved set. Mirrors `search_semantic_side_table/7` (`hnsw_ef_search` raise) and
  # `VectorSearch.nearest/4`'s `nearest_heavy_read_opts/2`. On the legacy path there is no
  # inner over-fetch, so the base opts stand. Piggybacks the SET LOCAL transaction every
  # heavy read already runs in (US-27.13) — no new pool-starvation risk.
  defp suggested_links_read_opts(pool, opts) do
    base = heavy_read_opts(:suggested_links)

    if Keyword.get(opts, :reads_side_table, false) do
      Keyword.put(
        base,
        :hnsw_ef_search,
        VectorSearch.side_table_ef_search(VectorSearch.side_table_inner_pool(pool))
      )
    else
      base
    end
  end

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
  def suggestion_candidates_query(
        tenant_id,
        article_id,
        embedding,
        threshold,
        limit,
        vis,
        opts \\ []
      ) do
    VectorSearch.candidate_query(
      tenant_id,
      embedding,
      limit,
      [
        exclude_id: article_id,
        exclude_linked: true,
        threshold: threshold,
        visibility_agent_id: vis,
        pool: suggestion_candidate_pool(limit)
      ] ++ Keyword.take(opts, [:reads_side_table])
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
  defp suggestion_candidates_inner(tenant_id, article_id, embedding, vis, pool, opts) do
    VectorSearch.candidate_pool_query(
      tenant_id,
      embedding,
      pool,
      [exclude_id: article_id, visibility_agent_id: vis] ++
        Keyword.take(opts, [:reads_side_table])
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
  # The SAMPLED candidate set. US-41.1 (review #3): behind the cutover flag the
  # vector is sourced from the dimension-tagged side table — the legacy column is
  # never written for a non-1536 tenant, so leaving this on `articles.embedding`
  # returned zero pairs for them. Both sources carry the conjunctive tenant equality
  # the structural guard requires.
  defp pair_candidates_query(tenant_id, bridge?, vis) do
    if Embeddings.side_table_reads_enabled?() do
      pair_candidates_side_table_query(tenant_id, bridge?, vis)
    else
      pair_candidates_legacy_query(tenant_id, bridge?, vis)
    end
  end

  # Public-but-`@doc false` with an EXPLICIT dimension (review) so the AC-41.1.12(i)
  # CI plan gate can EXPLAIN the side-table branch — the legacy gate runs with the
  # cutover flag off and therefore only ever covered the `articles.embedding` shape.
  @doc false
  def pair_candidates_side_table_query(tenant_id, bridge?, vis, dimension \\ nil) do
    dimension = dimension || Embeddings.active_dimension(tenant_id)

    from(ae in ArticleEmbedding,
      join: a in Article,
      on: a.id == ae.article_id and a.tenant_id == ^tenant_id,
      where: ae.tenant_id == ^tenant_id and ae.dim == ^dimension and ae.live_denorm,
      where: a.status == :published,
      order_by: a.id,
      limit: ^pair_candidate_cap(bridge?),
      select: %{
        id: a.id,
        tenant_id: a.tenant_id,
        title: a.title,
        category: a.category,
        embedding: ae.embedding
      }
    )
    |> maybe_filter_by_visibility_on_joined_article(vis)
  end

  defp pair_candidates_legacy_query(tenant_id, bridge?, vis) do
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
  end

  defp maybe_filter_by_visibility_on_joined_article(query, nil), do: query

  defp maybe_filter_by_visibility_on_joined_article(query, agent_id) when is_binary(agent_id) do
    where(
      query,
      [_ae, a],
      fragment("COALESCE(?->>'visibility', 'shared') NOT IN ('private','owner')", a.metadata) or
        fragment("?->>'agent_id' = ?", a.metadata, ^agent_id)
    )
  end

  defp do_distant_pairs(tenant_id, min_d, max_d, limit, offset, bridge?, vis) do
    candidates = pair_candidates_query(tenant_id, bridge?, vis)

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

    # US-41.1 (review): resolve the injected cutover decision ONCE for the whole
    # assessment and thread it. Resolving it separately for the prior COUNT and the
    # prior DISTANCE let a live cutover (AC-41.1.8 flips against serving traffic) land
    # between them, yielding a count from one relation and a distance from the other —
    # which breaks the "truthful disambiguator for nil scores" contract below and can
    # verdict a duplicate as novel. Mirrors `suggest_links_with_meta/3`.
    side_table? = Embeddings.side_table_reads_enabled?()
    prior_count = count_embedded_priors(tenant_id, prior_tag, vis, side_table?)

    scored =
      if prior_count == 0 do
        # No comparable (embedded) priors — skip embedding entirely; nothing to score
        # against, so no upstream calls are made and every idea scores nil.
        Enum.map(ideas, &Map.put(&1, :novelty_score, nil))
      else
        ideas
        |> Task.async_stream(&score_idea(tenant_id, &1, prior_tag, vis, side_table?),
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
  defp count_embedded_priors(tenant_id, prior_tag, vis, side_table?) do
    if side_table? do
      from(ae in ArticleEmbedding,
        where:
          ae.tenant_id == ^tenant_id and ae.dim == ^Embeddings.active_dimension(tenant_id) and
            ae.live_denorm,
        where: ae.article_id in subquery(prior_article_ids_query(tenant_id, prior_tag, vis))
      )
      |> AdminRepo.aggregate(:count, timeout: 15_000)
    else
      from(a in Article,
        where:
          a.tenant_id == ^tenant_id and a.status == :published and not is_nil(a.embedding) and
            fragment("? && ?", a.tags, ^[prior_tag])
      )
      |> maybe_filter_by_visibility(vis)
      |> AdminRepo.aggregate(:count, timeout: 15_000)
    end
  end

  defp score_idea(tenant_id, idea, prior_tag, vis, side_table?) do
    text = novelty_idea_text(idea)

    if String.trim(text) == "" do
      Map.put(idea, :novelty_score, nil)
    else
      score_embedding(tenant_id, idea, text, prior_tag, vis, side_table?)
    end
  end

  defp score_embedding(tenant_id, idea, text, prior_tag, vis, side_table?) do
    case generate_embedding(tenant_id, text) do
      {:ok, embedding} ->
        Map.put(
          idea,
          :novelty_score,
          nearest_prior_distance(tenant_id, embedding, prior_tag, vis, side_table?)
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

    # Truncate to max BYTES to prevent unbounded embedding input DoS. Measured AND cut in the
    # same unit (#572): `String.slice/3` counts GRAPHEMES, so a CJK idea that tripped the
    # 4 MiB byte guard was cut to 4M graphemes — up to ~12 MB, straight through the bound.
    if byte_size(text) > @max_idea_text_bytes do
      take_bytes(text, @max_idea_text_bytes)
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
  defp nearest_prior_distance(tenant_id, embedding, prior_tag, vis, side_table?) do
    # Query-vector length guard (review): the side-table novelty aggregate binds this
    # FRESH vector into the per-dimension `(embedding::vector(N))` cast, so a length
    # disagreeing with the read dimension would raise pgvector's "different vector
    # dimensions" 500 on the knowledge_create request path. `nil` is the documented
    # no-score degrade (indistinguishable from "no comparable priors").
    case Embeddings.check_query_vector(tenant_id, to_embedding_list(embedding)) do
      :ok -> run_nearest_prior_distance(tenant_id, embedding, prior_tag, vis, side_table?)
      {:error, _mismatch} -> nil
    end
  end

  defp run_nearest_prior_distance(tenant_id, embedding, prior_tag, vis, side_table?) do
    query = novelty_distance_query(tenant_id, embedding, prior_tag, vis, side_table?)
    # Heavy vector aggregate — dedicated pool via Loopctl.HeavyRead (US-27.11).
    # `on_overload: :tag` (US-37.5): over the tenant's HeavyRead slice the read is SHED
    # and returns `{:error, :heavy_read_overloaded}` — mapped to a DELIBERATE `nil` novelty
    # score here (the same graceful degrade a genuinely unscorable idea gets), rather than
    # RAISING an OverloadedError that the `Task.async_stream` in `novelty_scores/3` would
    # catch as an incidental `{:exit, _}` and log as a scary task crash. Non-destructive:
    # nil already means "not scored".
    opts = Keyword.put(heavy_read_opts(:novelty), :on_overload, :tag)

    case HeavyRead.one(tenant_id, query, opts) do
      {:error, :heavy_read_overloaded} ->
        nil

      distance ->
        # `:novelty` is an ANN endpoint with NO response envelope to disclose a degraded
        # scan in, and its consequence is a WRITE: a starved batch under-states the
        # nearest prior, the gate scores the idea novel, and a duplicate article is
        # written into the corpus the gate exists to dedupe. Same helper (and same
        # throttle) as every other envelope-less ANN write path (#634 round-2).
        HeavyRead.warn_if_ann_degraded("knowledge.novelty_scan", opts)
        distance
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
    novelty_distance_query(
      tenant_id,
      embedding,
      prior_tag,
      vis,
      Embeddings.side_table_reads_enabled?()
    )
  end

  # `novelty_distance_query/4` with the cutover decision RESOLVED BY THE CALLER, so one
  # novelty assessment cannot count priors on one relation and measure distance on the
  # other when an operator flips the flag mid-request (review).
  @doc false
  def novelty_distance_query(tenant_id, embedding, prior_tag, vis, side_table?) do
    # US-41.1 (review #3): behind the cutover flag the prior set is scanned on the
    # dimension-tagged side table. Leaving it on `articles.embedding` meant a
    # 768/1024 tenant — whose legacy column is NEVER written — saw ZERO priors, and
    # the novelty/dedup gate then verdicted every proposal `novel` and created
    # duplicates. That is a correctness regression, not a degradation.
    if side_table? do
      novelty_distance_side_table_query(tenant_id, embedding, prior_tag, vis)
    else
      novelty_distance_legacy_query(tenant_id, embedding, prior_tag, vis)
    end
  end

  defp novelty_distance_legacy_query(tenant_id, embedding, prior_tag, vis) do
    target = to_embedding_list(embedding)

    from(a in Article,
      where:
        a.tenant_id == ^tenant_id and a.status == :published and not is_nil(a.embedding) and
          fragment("? && ?", a.tags, ^[prior_tag]),
      select: fragment("MIN(? <=> ?::vector)", a.embedding, ^target)
    )
    |> maybe_filter_by_visibility(vis)
  end

  # Public-but-`@doc false` with an EXPLICIT dimension (review) so the AC-41.1.12(i)
  # CI plan gate can EXPLAIN the SIDE-TABLE branch of the novelty aggregate. The
  # existing US-27.7b gate EXPLAINs `novelty_distance_query/4` with the cutover flag
  # OFF, so it keeps gating the LEGACY branch only — and this branch is a materially
  # different shape (an `IN (subquery)` semi-join over `article_embeddings` instead
  # of an inline `tags &&` residual), i.e. exactly the #170/#172 failure class, with
  # no guarantee that Postgres's `MIN(x <=> $const)` -> `ORDER BY ... LIMIT 1`
  # rewrite survives. It is gated now.
  @doc false
  def novelty_distance_side_table_query(tenant_id, embedding, prior_tag, vis, dimension \\ nil) do
    target = to_embedding_list(embedding)
    dimension = dimension || Embeddings.active_dimension(tenant_id)

    from(ae in ArticleEmbedding,
      where: ae.tenant_id == ^tenant_id and ae.dim == ^dimension and ae.live_denorm,
      where: ae.article_id in subquery(prior_article_ids_query(tenant_id, prior_tag, vis))
    )
    |> VectorSearch.put_dimension_min_distance(dimension, target)
  end

  # The prior-tag article id set, shared by the novelty distance and the embedded-prior
  # count so the score and its disambiguating count are over the SAME population.
  defp prior_article_ids_query(tenant_id, prior_tag, vis) do
    from(a in Article,
      where:
        a.tenant_id == ^tenant_id and a.status == :published and
          fragment("? && ?", a.tags, ^[prior_tag]),
      select: a.id
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
    update_embedding(
      tenant_id,
      article_id,
      embedding_vector,
      content_hash,
      Embeddings.resolve_write_dimension(tenant_id)
    )
  end

  @doc """
  `update_embedding/4` with the tenant's dimension resolved BY THE CALLER.

  AC-41.1.11: `update_embedding/4` resolves the dimension per CALL (a `tenants`
  SELECT plus a settings read). The real US-37.4 batch path
  (`Loopctl.Workers.BatchArticleEmbeddingWorker.store_all/2`) loops over ~100
  articles, so calling the /4 form there performs ~100 tenant lookups — exactly the
  per-item resolution the AC forbids. Batch callers resolve ONCE with
  `Loopctl.Embeddings.resolve_write_dimension/1` and pass the result here.
  """
  @spec update_embedding(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          list(number()),
          String.t() | nil,
          pos_integer()
        ) :: {:ok, Article.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_embedding(tenant_id, article_id, embedding_vector, content_hash, dimension)
      when is_integer(dimension) do
    case AdminRepo.get_by(Article, id: article_id, tenant_id: tenant_id) do
      nil ->
        {:error, :not_found}

      article ->
        # AC-41.1.8(i): the legacy column write, the side-table write and the audit
        # entry all commit in ONE transaction — two transactions would leave the crash
        # window in which the legacy row exists without its mirror, which the resumable
        # backfill can never detect (the legacy row already exists, so it is skipped
        # forever) and only the reconciliation pass sweeps up.
        multi =
          Multi.new()
          |> Multi.run(:article, fn repo, _changes ->
            update_legacy_embedding(repo, article, embedding_vector, content_hash, dimension)
          end)
          |> Multi.run(:side_table, fn repo, _changes ->
            Embeddings.upsert_article_embedding_row(
              repo,
              tenant_id,
              article,
              embedding_vector,
              content_hash,
              dimension
            )
          end)
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
                "embedding_dimensions" => dimension
              }
            }
          end)

        case AdminRepo.transaction(multi) do
          {:ok, %{article: article}} -> {:ok, article}
          {:error, :article, changeset, _} -> {:error, changeset}
          {:error, :side_table, changeset, _} -> {:error, changeset}
          # The :audit step (Audit.log_in_multi) is also fallible; without this
          # catch-all its `{:error, :audit, reason, _}` fell through to a
          # CaseClauseError — a 500 / non-retryable crash instead of a mapped error.
          {:error, _step, reason, _} -> {:error, reason}
        end
    end
  end

  # The legacy `articles.embedding` half of the dual-write. It is SKIPPED entirely for
  # any non-1536 dimension: that column is typed `vector(1536)` and pgvector
  # HARD-ERRORS on storing a 768/1024-length value in it, so a dual-write mandate for
  # non-default dimensions is physically unexecutable. Those tenants are
  # side-table-ONLY (AC-41.1.8), and `Embeddings.recall_availability/1` is the
  # tenant-facing surface that SAYS so rather than failing opaquely.
  defp update_legacy_embedding(repo, article, embedding_vector, content_hash, dimension) do
    if dimension == Embeddings.legacy_dimension() do
      article
      |> Article.embedding_changeset(embedding_vector, content_hash, dimension)
      |> repo.update()
    else
      {:ok, article}
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
          # US-41.1: clearing an article's embedding must clear BOTH locations in the
          # same transaction, at EVERY dimension — otherwise a cleared article stays
          # semantically recallable from the side table.
          |> Multi.run(:side_table, fn repo, _changes ->
            Embeddings.delete_article_embeddings(repo, tenant_id, article_id)
          end)
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
          {:error, _step, reason, _} -> {:error, reason}
        end
    end
  end

  # --- Private helpers ---

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

  @doc """
  Whether `article_id` exists in `tenant_id` AND is visible to the caller (#163).

  Fails CLOSED: an article that does not exist (or is not visible to `vis`)
  returns `false`. Used by the US-41.7 custody-claim surface, which discloses a
  row's existence, operation timeline, occurred-at timestamps, endpoints and
  per-operation postures — not content, but #163's invariant is that visibility is
  ENFORCED, not advisory, so an agent must not read the custody timeline of
  another agent's private article any more than it reads the article.
  """
  @spec article_visible?(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) :: boolean()
  def article_visible?(tenant_id, article_id, vis) do
    tenant_id
    |> visible_article_ids([article_id], vis)
    |> MapSet.member?(article_id)
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

  # Dispatch the project filter between the STRICT (project-only) and the MERGED
  # (`global ∪ project`) predicate based on the `:project_scope` opt (#411 Gap 2, PR B).
  #
  #   * `:strict` (DEFAULT) → `maybe_filter_by_project_id/2` — `project_id == ^id`,
  #     the historical behaviour every existing search/list caller relies on. Absent
  #     `:project_scope` resolves here, so EVERY pre-existing caller is byte-identical.
  #   * `:with_global` → `scope_project_or_global/2` — `project_id IS NULL OR == ^id`,
  #     the merged-recall semantics `Loopctl.Memory.recall_context/2` needs so a
  #     project-scoped combined search ALSO surfaces tenant-wide (global) articles.
  #
  # Threaded from `search_combined/3` through its `sub_opts` into BOTH the keyword +
  # semantic-count filter set (`apply_search_filters/3`) and the semantic results pool
  # (`apply_semantic_pool_filters/2`), so results and `total_count` stay consistent.
  #
  # `nil` project_id behaviour DIFFERS by mode (deliberately):
  #   * `:strict` — a no-op (`maybe_filter_by_project_id/2` short-circuits nil), so an
  #     absent project matches ALL projects — the historical list/search behaviour.
  #   * `:with_global` — scopes to GLOBAL-ONLY (`project_id IS NULL`), NOT the query
  #     unchanged. The merged-recall contract (the OpenAPI RecallContextRequest and the
  #     MCP recall_context tool both promise "absent/blank project → global-only") and
  #     the memory half (`Memory.maybe_scope_project/2`, nil → `project_id IS NULL`)
  #     require the union to be global-only with no active project — NOT every project's
  #     articles flooding the merged limit for a multi-project tenant.
  defp apply_project_scope(query, nil, :with_global),
    do: where(query, [a], is_nil(a.project_id))

  defp apply_project_scope(query, project_id, :with_global),
    do: scope_project_or_global(query, project_id)

  defp apply_project_scope(query, project_id, _strict),
    do: maybe_filter_by_project_id(query, project_id)

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
    # US-41.1 AC-41.1.5/.8: behind the explicit, REVERSIBLE cutover flag the ANN runs
    # over the dimension-tagged side table instead of the legacy `articles.embedding`
    # column. The flag is a SystemConfig integer so the flip and the revert are both a
    # single operator UPDATE with no redeploy, and it may only be flipped once every
    # node runs the dual-write code (a Fly rolling deploy otherwise has old nodes
    # writing only the legacy column while new nodes read the side table).
    #
    # US-41.1 AC-41.1.8 (review #9): the query vector's LENGTH is checked against the
    # dimension the read path will scan BEFORE binding it into the `<=>` fragment.
    # WRITES were validated (`Dimensions.validate_vector_length/3`); READS were not,
    # so any drift — mid-model-change, a stale cached setting — surfaced as a raw
    # Postgrex "different vector dimensions" 500 instead of the documented keyword
    # fallback. The moduledoc's "unreachable safety net" claim is only true with this
    # check at the boundary.
    target_length = length(VectorSearch.to_embedding_list(query_embedding))

    if Embeddings.side_table_reads_enabled?() do
      dimension = Embeddings.active_dimension(tenant_id)

      if target_length == dimension do
        search_semantic_side_table(
          tenant_id,
          query_embedding,
          limit,
          offset,
          status,
          opts,
          dimension
        )
      else
        semantic_recall_unavailable(tenant_id, target_length, dimension)
      end
    else
      # The LEGACY column is `vector(1536)` unconditionally, so this needs NO tenant
      # lookup on the hot path — the expected length is a constant. The (rare) failure
      # branch is the only place that pays for `recall_availability/1`, which is the
      # AC-41.1.8 surface designated to SAY why recall is unavailable.
      if target_length == Embeddings.legacy_dimension() do
        search_semantic_legacy(tenant_id, query_embedding, limit, offset, status, opts)
      else
        semantic_recall_unavailable(tenant_id, target_length, Embeddings.legacy_dimension())
      end
    end
  end

  # AC-41.1.8: "the surface SAYS so rather than failing opaquely". The caller
  # (`search_combined/3` and the search controller) maps this to the keyword-only
  # degrade with a stable `fallback_reason`, so an agent gets a labelled 200 instead
  # of a pgvector 500 or a silent empty ranked set.
  defp semantic_recall_unavailable(tenant_id, target_length, expected) do
    availability = Embeddings.recall_availability(tenant_id)

    Logger.warning(
      "knowledge.semantic_recall_unavailable tenant_id=#{tenant_id} " <>
        "query_vector_length=#{target_length} expected=#{expected} " <>
        "reason=#{availability.reason || "query/corpus dimension mismatch"}"
    )

    {:error, :semantic_recall_unavailable}
  end

  defp search_semantic_legacy(tenant_id, query_embedding, limit, offset, status, opts) do
    heavy_opts = semantic_heavy_read_opts()
    results_query = semantic_results_query(tenant_id, query_embedding, opts)

    # COUNT — kept as a SEPARATE full-corpus filtered `count(*)` so `total_count` PRESERVES
    # its pre-27.7a meaning (the size of the whole embedded+filtered ranked corpus, NOT the
    # pool). It carries NO `ORDER BY embedding <=> …`: a count needs no ordering, and the
    # old subquery's ORDER BY forced a pointless full-corpus Seq Scan + Sort (~153ms at
    # 80k). Without it the count is index-served by the filter indexes (a selective
    # category+tags count is a BitmapAnd bounded by selectivity; the unfiltered count is a
    # bounded tenant scan — inherently O(tenant rows) for a true `count(*)`).
    count_query = semantic_count_query(tenant_id, query_embedding, status, opts)

    case HeavyRead.all(tenant_id, results_query, heavy_opts) do
      {:error, :heavy_read_overloaded} = err ->
        err

      results ->
        case HeavyRead.one(tenant_id, count_query, heavy_opts) do
          {:error, :heavy_read_overloaded} = err ->
            err

          total_count ->
            maybe_record_search_access(
              tenant_id,
              results,
              nil,
              attempt_meta(opts, total_count, heavy_opts),
              "semantic"
            )

            {:ok,
             %{
               results: with_snippets(tenant_id, results, opts),
               meta:
                 %{
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
                   pool_capped:
                     semantic_pool_capped?(
                       total_count,
                       length(results),
                       limit,
                       offset,
                       semantic_result_pool_cap()
                     )
                 }
                 |> Map.merge(legacy_system_corpus_meta())
                 |> Map.merge(HeavyRead.iterative_scan_meta(heavy_opts))
             }}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # US-41.1 — the SIDE-TABLE semantic read path (AC-41.1.5 / .6 / .7 / .10)
  # ---------------------------------------------------------------------------

  # THE dimension-scoped recall, in three stages, and the split is load-bearing:
  #
  #   1. INNER ANN (through `HeavyRead`) — a pure index-ordered top-`pool` over
  #      `article_embeddings` ALONE, whose WHERE carries ONLY the predicates the
  #      per-dimension partial index carries (`tenant_id`, `dim`, `live_denorm`).
  #      No join, no selective btree predicate: that is the #170/#172 shape that
  #      flips the planner off HNSW (cost ~57k vs ~880 at 76k rows). One base-table
  #      source with a conjunctive `tenant_id ==` equality, so `guard!/2` accepts it
  #      (AC-41.1.6) with nothing relaxed.
  #   2. HYDRATION — the ≤`pool` article ids are projected from `articles` with the
  #      selective filters applied. This is a bounded `id IN (...)` lookup, not a
  #      corpus scan, so no filter here can defeat anything. It carries the SAME
  #      `tenant_id == ^tenant_id or a.scope == :system` predicate the rest of this
  #      module uses, which is what lets AC-41.1.7's per-tenant materialization of
  #      the SHARED system corpus surface here (the embedding row carries the
  #      requesting tenant's `tenant_id`; the article row carries NULL).
  #   3. RANK + PAGE in Elixir over that same ≤`pool` set.
  #
  # A cross-dimension comparison is impossible BY CONSTRUCTION: stage 1 is scoped to
  # exactly one `dim`, so pgvector's "different vector dimensions" error is an
  # unreachable safety net rather than the mechanism.
  defp search_semantic_side_table(
         tenant_id,
         query_embedding,
         limit,
         offset,
         status,
         opts,
         dimension
       ) do
    pool = semantic_result_pool(offset + limit)

    # Review #7: the side-table inner ANN cannot carry the status/visibility
    # predicates the legacy inner did (they are not in the per-dimension partial
    # index — `live_denorm` only mirrors `status <> 'superseded'`), so drafts,
    # archived and other agents' private articles occupy pool slots and the real
    # predicates are applied in `hydrate_semantic_pool/6`. At an identical pool size
    # that returns strictly FEWER published rows than the legacy path. The inner
    # limit is therefore over-fetched and the hydration trims back.
    inner_pool = VectorSearch.side_table_inner_pool(pool)
    pool_query = semantic_side_table_pool_query(tenant_id, query_embedding, dimension, inner_pool)

    count_query = semantic_side_table_count_query(tenant_id, dimension, status, opts)

    # Raise `hnsw.ef_search` to cover the over-fetched inner pool (review): the HNSW
    # scan only returns ~ef_search nodes regardless of LIMIT, so the side-table
    # over-fetch that compensates for post-ANN status/visibility filtering does nothing
    # unless ef_search is widened in lockstep. Piggybacks on the SET LOCAL transaction
    # every heavy read already runs in (US-27.13) — no new pool-starvation risk.
    pool_opts =
      Keyword.put(
        semantic_heavy_read_opts(),
        :hnsw_ef_search,
        VectorSearch.side_table_ef_search(inner_pool)
      )

    case HeavyRead.all(tenant_id, pool_query, pool_opts) do
      {:error, :heavy_read_overloaded} = err ->
        err

      pool_rows ->
        case HeavyRead.one(tenant_id, count_query, semantic_heavy_read_opts()) do
          {:error, :heavy_read_overloaded} = err ->
            err

          total_count ->
            {results, survived} =
              hydrate_semantic_pool(tenant_id, pool_rows, status, opts, limit, offset)

            maybe_record_search_access(
              tenant_id,
              results,
              nil,
              attempt_meta(opts, total_count, pool_opts),
              "semantic"
            )

            {:ok,
             %{
               results: with_snippets(tenant_id, results, opts),
               meta:
                 %{
                   total_count: total_count,
                   limit: limit,
                   offset: offset,
                   search_mode: "semantic_only",
                   total_count_scope: "ranked_corpus",
                   embedding_dimension: dimension,
                   pool_capped:
                     semantic_pool_capped?(
                       total_count,
                       length(results),
                       limit,
                       offset,
                       semantic_side_table_response_reach(
                         inner_pool,
                         length(pool_rows),
                         survived
                       )
                     )
                 }
                 |> Map.merge(semantic_disclosure_meta(tenant_id, dimension))
                 # Derived from `pool_opts` — the opts the inner ANN ACTUALLY ran with —
                 # not from a fresh probe, so the disclosure can never disagree with the
                 # rows it accompanies. NOT memoized alongside the tenant-scoped
                 # disclosures above: this is a per-NODE backend capability with its own
                 # (much shorter) probe TTL, and caching it per tenant would keep
                 # reporting a state the node has already left.
                 |> Map.merge(HeavyRead.iterative_scan_meta(pool_opts))
             }}
        end
    end
  end

  # Stage 1 — the pure, dimension-scoped, index-ordered ANN. Public-but-`@doc false`
  # so the AC-41.1.12(i) CI plan gate and the AC-41.1.6 guard test can assert the
  # REAL request-path query rather than a hand-written lookalike.
  @doc false
  def semantic_side_table_pool_query(tenant_id, query_embedding, dimension, pool) do
    target = VectorSearch.to_embedding_list(query_embedding)

    ArticleEmbedding
    |> VectorSearch.index_safe_dimension_knn_base(tenant_id, target, dimension, pool)
    |> select([e], %{article_id: e.article_id, tenant_id: e.tenant_id})
    |> VectorSearch.put_dimension_distance(dimension, target)
  end

  # The `total_count` for the side-table path: the size of the tenant's LIVE,
  # embedded-at-this-dimension, filtered corpus. Joined to `articles` (both sources
  # carry the conjunctive tenant equality, so `guard!/2` accepts it) and carrying NO
  # `<=>` ordering — a count is order-independent, and an ORDER BY here would force a
  # full-corpus sort for nothing.
  #
  # SYSTEM-scoped articles ARE counted (review #13). The previous form joined
  # `articles` on `a.tenant_id == ^tenant_id`, which excluded them — while
  # `hydrate_semantic_pool/6` selects `a.tenant_id == ^tenant_id or a.scope ==
  # :system` and RETURNS them. Once a tenant materializes the system corpus
  # (AC-41.1.7), `length(results)` could therefore exceed `total_count`, breaking the
  # documented `total_count_scope: ranked_corpus` contract and making
  # `semantic_pool_capped?/5` emit a wrong truncation signal (degenerately:
  # `total_count: 0` alongside non-empty results).
  #
  # The join to `articles` is dropped entirely rather than OR-broadened: an
  # `or a.scope == :system` on the join-on is exactly the disjunctive tenant
  # predicate `guard!/2` refuses. The only remaining base-table source is
  # `article_embeddings`, which carries the conjunctive tenant equality, and the
  # article-side filtering happens in the `IN (subquery)` id set below — where the
  # `scope == :system` disjunction is safe because the embedding ROW is still
  # tenant-scoped (a system article is only counted for a tenant that has
  # materialized its own vector for it).
  @doc false
  def semantic_side_table_count_query(tenant_id, dimension, status, opts) do
    from(ae in ArticleEmbedding,
      where: ae.tenant_id == ^tenant_id,
      where: ae.dim == ^dimension,
      where: ae.live_denorm
    )
    |> apply_search_filters_on_article(tenant_id, status, opts)
    |> select([_ae], count())
  end

  # `apply_search_filters/3` targets the FIRST binding; here the article is not a
  # binding at all, so the filters are re-expressed against a subquery whose single
  # binding IS the article. Cheaper than duplicating nine filter helpers, and it
  # cannot drift from the keyword path's filter semantics.
  defp apply_search_filters_on_article(query, tenant_id, status, opts) do
    # The inner id set carries the SAME `tenant_id == ^tenant_id or scope == :system`
    # predicate `hydrate_semantic_pool/6` uses, so the count and the results are over
    # the same population. It is never unscoped: an unscoped inner set would scan
    # every tenant's articles to compute an id list that is then thrown away.
    filtered_ids =
      from(a in Article, where: a.tenant_id == ^tenant_id or a.scope == :system)
      |> apply_search_filters(status, opts)
      |> select([a], a.id)

    where(query, [ae], ae.article_id in subquery(filtered_ids))
  end

  # Stage 2 + 3. `AdminRepo` (not `HeavyRead`) deliberately: this is a bounded
  # `id IN (≤pool)` projection, not a heavy read, and it must be able to see
  # system-scoped rows — whose NULL `articles.tenant_id` cannot satisfy the heavy-read
  # guard. Isolation is preserved by construction: the ids come from stage 1, which
  # is RLS-equivalently scoped to this tenant's OWN embedding rows, and the predicate
  # here re-asserts `tenant_id == ^tenant_id or scope == :system` — the same explicit
  # predicate `fetch_stub_projection/3` and the keyword path already use.
  # Returns `{page, survived}` — the page AND how many ANN candidates survived the
  # post-ANN trim, which is what `semantic_side_table_response_reach/3` needs to tell a
  # complete page from one whose window was eaten by discarded rows.
  defp hydrate_semantic_pool(_tenant_id, [], _status, _opts, _limit, _offset), do: {[], 0}

  defp hydrate_semantic_pool(tenant_id, pool_rows, status, opts, limit, offset) do
    scores =
      Map.new(pool_rows, fn %{article_id: id, distance: distance} ->
        {id, 1 - (distance || 0.0)}
      end)

    filtered =
      from(a in Article,
        where: a.id in ^Map.keys(scores),
        where: a.tenant_id == ^tenant_id or a.scope == :system,
        select: %{
          id: a.id,
          tenant_id: a.tenant_id,
          project_id: a.project_id,
          title: a.title,
          category: a.category,
          status: a.status,
          tags: a.tags,
          inserted_at: a.inserted_at,
          updated_at: a.updated_at
        }
      )
      |> apply_search_filters(status, opts)
      |> AdminRepo.all()

    # Under-fill observability (review): the side-table inner ANN cannot carry
    # status/visibility, so drafts/archived/private rows occupy pool slots and are
    # trimmed HERE. When the post-filter set shrinks below the ANN candidate pool the
    # recall regression the fixed over-fetch is meant to offset is happening — emit it
    # so it is measured, not silent (KB ae9a1719: silent under-fill is the failure the
    # side-table design must avoid).
    emit_side_table_underfill(tenant_id, length(pool_rows), length(filtered), limit)

    page =
      filtered
      |> Enum.map(&Map.put(&1, :similarity_score, Map.fetch!(scores, &1.id)))
      |> Enum.sort_by(& &1.similarity_score, :desc)
      |> Enum.drop(offset)
      |> Enum.take(limit)

    {page, length(filtered)}
  end

  defp emit_side_table_underfill(tenant_id, pool_count, filtered_count, limit) do
    if filtered_count < pool_count do
      :telemetry.execute(
        [:loopctl, :knowledge, :semantic_search, :side_table_underfill],
        %{
          pool_candidates: pool_count,
          survived_filter: filtered_count,
          trimmed: pool_count - filtered_count,
          requested_limit: limit
        },
        %{tenant_id: tenant_id}
      )
    end

    :ok
  end

  # The AC-41.1.7 + AC-41.1.10 disclosures every semantic response carries.
  #
  # Both exist so recall NEVER shrinks silently: a tenant that has not materialized
  # the shared system corpus at its dimension gets an explicit "keyword_only" marker
  # for that corpus (a silent absence is indistinguishable from "nothing relevant"),
  # and a tenant mid-re-embed is told which rows are excluded from PENDING-dimension
  # recall and why.
  # COST GATE (review #8): on the LEGACY path none of this can change the answer —
  # results come from `articles.embedding`, there is no per-dimension corpus to be
  # unmaterialized and no re-embed can be observed — yet it was costing THREE extra
  # queries (a tenants SELECT + settings read for the dimension, a NOT EXISTS
  # anti-join over every system-scoped article, and a re-embed existence probe) on
  # the hottest read in the product, against AC-41.1.12's "the hosted default must
  # not regress". It is therefore emitted only on the side-table path, where the
  # dimension is already resolved and the disclosures are actually true statements
  # about what was scanned.
  #
  # MEMOIZED per (tenant, dimension) for a short TTL by
  # `Embeddings.search_disclosure_meta/2` (review): in the STEADY state the
  # system-corpus anti-join qualifies NO row, so its `LIMIT 1` never short-circuits
  # and it scans every system-scoped article with a per-row index probe — a cost that
  # grows with loopctl's own canonical wiki corpus, paid on every semantic search,
  # against AC-41.1.12's "the hosted default must not regress".
  # AC-41.1.7's "on demand" read-path materialization trigger now lives INSIDE
  # `Embeddings.search_disclosure_meta/2`'s memoized cache fill (review #11), so it
  # fires only on a DisclosureCache MISS rather than on every semantic response — the
  # per-request unindexed `oban_jobs` scan + Oban insert it used to cost is gone. The
  # worker is unique per `(tenant_id, dim)`, its batch query is an anti-join, and the
  # enqueue refuses to re-drive a permanently-terminated materialization.
  defp semantic_disclosure_meta(tenant_id, dimension) when is_integer(dimension) do
    Embeddings.search_disclosure_meta(tenant_id, dimension)
  end

  # AC-41.1.7 mandates the system-corpus recall state be stated EXPLICITLY on every
  # semantic response — "never a silent absence" (review, finding 3). On the LEGACY
  # (pre-cutover) read path the shared system corpus is not semantically recallable at
  # all: the legacy inner ANN (`index_safe_knn_base/4`) scopes `tenant_id ==
  # ^tenant_id`, which excludes the NULL-tenant system rows, so system articles are
  # keyword-only for EVERY tenant during the dual-write window. Emitting this static
  # note keeps the disclosure present pre-flip too, rather than absent until the
  # side-table path (which computes the per-tenant materialization state) takes over.
  # This is a compile-time constant — NO query — so it does not reintroduce the hot-path
  # cost the side-table disclosure is memoized to avoid.
  defp legacy_system_corpus_meta do
    %{
      system_corpus_recall: "keyword_only",
      system_corpus_reason:
        "the shared system-scoped corpus is semantically recallable only on the " <>
          "side-table read path; while this instance still serves the legacy " <>
          "(pre-cutover) embedding column it is matched by keyword only for every tenant."
    }
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
  #   * CAP truncation — `total_count > reach`: the corpus is larger than the deepest
  #     reachable pool (true regardless of `offset`, even on a full page).
  #   * POOL/FILTER starvation — a SHORT page (`returned < limit`) while MORE filtered
  #     results exist than were surfaced (`offset + returned < total_count`). This catches
  #     the case a `total_count > reach`-only check MISSED: a selective filter whose matches
  #     fall outside the top-`pool` nearest starves the page below the cap. (A genuine
  #     last page — `offset + returned == total_count` — is NOT flagged.)
  #
  # `reach` is PER-PATH and is passed in, never re-derived here: the legacy path pages
  # within the top-`cap` pool, while the side-table path hydrates from an OVER-FETCHED ANN
  # pool that is bounded by `hnsw.ef_search` and then trimmed by the post-ANN
  # status/visibility filters — so its reach is `semantic_side_table_response_reach/3`,
  # which is neither the raw cap (that claimed truncation on a complete page whenever the
  # corpus sat between `cap` and the over-fetch) nor the raw over-fetch (that claimed
  # completeness on a corpus the ef_search ceiling or the trim put out of reach).
  defp semantic_pool_capped?(total_count, returned, limit, offset, reach) do
    total_count > reach or
      (returned < limit and offset + returned < total_count)
  end

  # The reach for THIS side-table response. `semantic_side_table_reach/0` counts ANN
  # CANDIDATE slots, while `total_count` counts rows that SURVIVE the post-ANN
  # status/visibility trim (predicates the side-table inner index cannot carry). So when
  # the ANN window saturated AND part of it was discarded, every ranked row past that
  # window is unreachable at ANY offset and what survived IS the reach — otherwise a FULL
  # page over a mostly-draft corpus reports "complete" while most of `total_count` is
  # unreachable, and the starvation arm cannot catch it (that arm needs a SHORT page).
  #
  # Public-but-`@doc false`: the three branches are asserted directly, since staging a
  # saturated-and-trimmed ANN window through the SHARED test index would take a corpus
  # large enough to make the guard itself an approximate-recall coin flip.
  @doc false
  @spec semantic_side_table_response_reach(pos_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def semantic_side_table_response_reach(inner_pool, pool_count, survived) do
    if pool_count >= VectorSearch.side_table_ef_search(inner_pool) and survived < pool_count do
      survived
    else
      semantic_side_table_reach()
    end
  end

  # The deepest row the side-table path can surface at ANY offset: the pool is clamped to
  # the cap and the inner ANN over-fetches `side_table_over_fetch/0` times that — but an
  # HNSW scan only returns ~`hnsw.ef_search` nodes regardless of the LIMIT, so
  # `side_table_ef_search/1` (the SAME clamp the read itself applies) has the last word.
  # Without it the prod reach was overstated 4x — `4 * cap` = 4000 against a 1000-node
  # ceiling — reporting "complete" for every corpus between the two.
  #
  # Public-but-`@doc false`, and takes the cap, so the guard test can drive it with a cap
  # whose over-fetch actually blows past the ceiling — at the test cap it does not, and a
  # guard that only reads the configured value passes with the clamp deleted.
  @doc false
  @spec semantic_side_table_reach(pos_integer()) :: pos_integer()
  def semantic_side_table_reach(cap \\ semantic_result_pool_cap()) do
    VectorSearch.side_table_ef_search(VectorSearch.side_table_inner_pool(cap))
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
      # Deterministic total order: cosine similarity desc, then `id` asc as a
      # secondary key. Ties are real (two identical embeddings share similarity
      # 1.0), and Postgres leaves tied-row order unspecified, so without the id
      # tiebreak the RRF ranks that fusion derives from this list — and thus
      # which candidate wins the top slot by a sub-1e-5 RRF margin — would flip
      # run-to-run (#470 review).
      order_by: [desc: c.similarity_score, asc: c.id],
      select: %{
        id: c.id,
        tenant_id: c.tenant_id,
        project_id: c.project_id,
        title: c.title,
        category: c.category,
        status: c.status,
        tags: c.tags,
        # source_type feeds the #471 authority prior (see the keyword select). The inner
        # pool_select(:semantic) must project it for this outer select to read it.
        source_type: c.source_type,
        # Same contract for the MOC-hub demotion signal: inner projects it, outer reads it.
        idempotency_key: c.idempotency_key,
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
    |> apply_project_scope(
      Keyword.get(opts, :project_id),
      Keyword.get(opts, :project_scope, :strict)
    )
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
  #
  # Public-but-`@doc false` for the same reason `semantic_side_table_pool_query/4` is: the
  # `left: []` diagnostic (`Loopctl.VectorRecallDiagnostics`) must EXPLAIN the pool the read
  # ACTUALLY used, and a test-side reimplementation of this formula would drift silently and
  # then describe a query that never ran.
  @doc false
  def semantic_result_pool(needed) when is_integer(needed) and needed > 0 do
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

  # The hard ceiling on the relevance POOL (US-27.7a): results are paged within the
  # top-`cap` pool. It is the reachability ceiling on the LEGACY path only — the
  # side-table path hydrates from `side_table_inner_pool(pool)`, so its reach is
  # `semantic_side_table_reach/0`. Config `:semantic_result_pool_cap`.
  #
  # Public-but-`@doc false` so the `pool_capped` truncation tests can SEED RELATIVE TO the
  # enforced value instead of hardcoding it. A hardcoded `cap + 2` silently decouples the
  # moment the config moves — which is exactly how the wide `limit:` annotations in
  # `embeddings_side_table_reads_test.exs` became decorative: every one of them was clamped
  # back to the cap and nobody noticed, because nothing tied a test's numbers to this
  # function. Read it, never re-derive it.
  @doc false
  @spec semantic_result_pool_cap() :: pos_integer()
  def semantic_result_pool_cap,
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
    - `:project_scope` -- how `:project_id` filters (default `:strict`). `:strict`
      matches `project_id == id` (the historical behaviour); `:with_global` matches
      `project_id IS NULL OR == id`, so a project-scoped search ALSO surfaces
      tenant-wide (global) articles. Used by the merged `Loopctl.Memory.recall_context/2`
      recall (#411 Gap 2). Under `:strict` an absent `:project_id` is a no-op (all
      projects); under `:with_global` an absent `:project_id` scopes to GLOBAL-ONLY
      (`project_id IS NULL`), matching the documented `global ∪ active-project` union.
    - `:embedding` -- an optional precomputed `{:ok, embedding} | {:error, reason}`
      for `query_string`. When supplied the semantic half reuses it instead of making
      an outbound provider call (the merged recall shares ONE embedding across both
      halves — #411 Gap 2); an `{:error, _}` degrades to keyword-only as usual.
    - `:limit` -- max ranked results to return (default 10, max
      #{@max_relevance_page_size}, min 1); relevance top-N, capped well below the
      enumeration page size
    - `:offset` -- results to skip for pagination (default 0)
    - `:recency_weight` -- per-call override for the bounded recency prior weight
      (#471; default `:knowledge_recency_weight`, 0.3), clamped to `[0.0, 1.0]`. A
      weight of 0 makes recency a no-op. See `Loopctl.Knowledge.RankingPriors`.
    - `:authority_prior` -- per-call boolean toggle for the source/category authority
      prior (default `:knowledge_authority_prior_enabled`, true). The dead-doctrine
      demotion (`verdict-kill`/`:superseded`) applies regardless of this toggle.
    - `:authority_strength` -- per-call override for the authority prior strength
      (default `:knowledge_authority_strength`, 0.05), floored at 0.0. Scales the
      bounded authority factor within the `[0.9, 1.1]` band.
    - `:now` -- the `DateTime` the recency prior measures age against (default
      `DateTime.utc_now/0`). Injected so the priors stay pure/deterministic in tests.

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
      # Same reason as `_skip_record_access`: the sub-searches run at the wide pool size,
      # so filling snippets here would read bodies for candidates that never reach the
      # caller. The merged page is filled once, below.
      |> Keyword.put(:_skip_snippet_backfill, true)

    keyword_result = search_keyword(tenant_id, query_string, sub_opts)

    # Reuse a caller-supplied embedding when present (the merged recall generates ONE
    # embedding for both its memory + knowledge halves — #411 Gap 2) instead of making
    # a second outbound provider call; otherwise generate here as before.
    embedding_result =
      case Keyword.get(opts, :embedding) do
        nil -> try_generate_embedding(tenant_id, query_string, project_id_opt(opts))
        precomputed -> precomputed
      end

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

            # Optional third graph-neighbor lane (#470), OFF by default. Computed here
            # because it needs `tenant_id` (a DB read of the link graph); threaded into
            # `merge_results/5` via opts so that function stays a pure fusion function
            # (no DB) — its arity and public contract are unchanged.
            merge_opts =
              opts
              |> put_graph_lane(tenant_id, kw, semantic)
              |> put_curated_lane(tenant_id, kw, semantic)

            {:ok, merged} =
              merge_results(kw, semantic, keyword_weight, semantic_weight, merge_opts)

            maybe_record_search_access(
              tenant_id,
              merged.results,
              query_string,
              # The inner semantic read's scan state rides in `merged.meta`; without
              # carrying it out the DEFAULT lane recorded NULL while explicit
              # `mode=semantic` recorded a value, so the column compared a populated
              # class against an unpopulated one.
              Keyword.merge(opts,
                _total_count: merged.meta[:total_count],
                _ann_iterative_scan: merged.meta[:ann_iterative_scan]
              ),
              combined_search_mode(merged.meta[:provenance])
            )

            # Filled AFTER recording so the analytics rows describe what was retrieved, not
            # what was decorated, and once — on the merged page rather than either lane's
            # wide pool.
            with_snippets = with_snippets(tenant_id, merged.results, opts)

            # Phase 4 reranking (#470 successor), OFF by default. It runs LAST, on the
            # already-paginated page, for two reasons: `merge_results/5` is a pure DB-free
            # fusion function and this is an outbound provider call, and reranking the page
            # bounds the cost by the caller's limit instead of by the candidate pool.
            # AFTER snippets because the snippet is what the reranker judges relevance on —
            # ordering by titles alone throws away the one line #690 exists to provide.
            # `maybe_rerank/4` fails OPEN: every error path returns this same list.
            {:ok,
             %{
               merged
               | results: Reranker.maybe_rerank(tenant_id, query_string, with_snippets, opts)
             }}

          # US-41.1: `:semantic_recall_unavailable` joins `:heavy_read_overloaded`
          # here — the query vector cannot be compared against the corpus this tenant
          # actually has, so semantic contributes nothing and the response is
          # LABELLED rather than silently short.
          {:error, reason} ->
            combined_keyword_fallback(tenant_id, kw, reason, query_string, opts)
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
    # AC-5: the degraded keyword_only path STILL applies the priors it can — recency and
    # authority both need no embedding. The raw keyword lane has no fused `:final_score`,
    # so re-rank over its `:relevance_score` WITHOUT mutating that raw field (the hybrid
    # resolver reads it, and the public result shape must be preserved).
    reranked = apply_ranking_priors_fallback(kw.results, opts)
    paginated = paginate_results(reranked, opts)

    # The DEGRADATION, carried to the recorder. Without it the row lands as
    # `zero_results` and the provider outage reads as a corpus gap — the exact
    # misattribution `SearchEvent` documents as the thing that must not happen.
    maybe_record_search_access(
      tenant_id,
      paginated.results,
      query_string,
      Keyword.merge(opts,
        _degraded: true,
        _fallback_reason: fallback_reason,
        _total_count: kw.meta.total_count
      ),
      "combined_fallback"
    )

    {:ok,
     %{
       results: paginated.results,
       meta:
         kw.meta
         |> Map.merge(%{
           fallback: true,
           search_mode: "keyword_only",
           fallback_reason: fallback_reason,
           total_count: kw.meta.total_count,
           limit: paginated.limit,
           offset: paginated.offset
         })
         |> Map.merge(degraded_contract_meta(tenant_id, fallback_reason))
     }}
  end

  # US-41.4 (AC-41.4.7): the degraded response is EXPLICITLY LABELLED and never a
  # bare empty list. Whenever the semantic path is unavailable — `egress_blocked`,
  # circuit open, or an embedding fallback — the meta names the REASON and the
  # OFFENDING ENDPOINT, and carries a reserved, extensible `excluded_tiers` field.
  #
  # `excluded_tiers` is present and EMPTY here by contract. US-41.6 populates it:
  # AC-41.6.4 removes encrypted bodies from the FTS index, so without the field a
  # `local_only` + `encrypt_body` tenant would receive a successful-looking 200 with
  # a structurally impossible-to-populate result set that reads as "nothing in your
  # KB". Shipping the field now keeps the response contract stable across that
  # change. The offending-endpoint lookup is TENANT-scoped and DB-free.
  # Shared verbatim with the MEMORY half (`Loopctl.Memory.recall/2`) so the
  # AC-41.4.7 contract cannot drift between the two paths. `offending_endpoint` is
  # OMITTED for a non-egress reason (`no_embedding_key`, `rate_limited_local`,
  # budget shedding, a semantic-index problem): naming an endpoint that had nothing
  # to do with the failure would send an agent chasing the wrong thing.
  defp degraded_contract_meta(tenant_id, fallback_reason),
    do: Egress.degraded_contract_meta(tenant_id, fallback_reason)

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
  # US-41.4 (AC-41.4.6/.7): the scope is `local_only` and the resolved embedding
  # endpoint is not local, so the semantic path is refused BEFORE any request —
  # keyword fallback, HTTP 200, never a 500, and never a bare empty list.
  defp reason_to_tag(:egress_blocked), do: "egress_blocked"
  defp reason_to_tag(:pin_stale), do: "pin_stale"
  # US-41.4: the refusal now carries its DETAILS (`{tag, details}`) so the failure
  # that reaches an agent/Oban record names the scope and the offending endpoint.
  # The TAG stays bounded (safe as a Prometheus label).
  defp reason_to_tag({tag, details})
       when tag in [:egress_blocked, :pin_stale, :egress_unavailable] and is_map(details),
       do: to_string(tag)

  defp reason_to_tag(:egress_unavailable), do: "egress_unavailable"
  defp reason_to_tag(:circuit_open), do: "embedding_circuit_open"
  defp reason_to_tag(:rate_limited_local), do: "embedding_rate_limited_local"
  # US-37.5: the semantic heavy read was shed because the tenant is over its
  # per-tenant in-flight HeavyRead cap; search degraded to keyword-only.
  defp reason_to_tag(:heavy_read_overloaded), do: "heavy_read_overloaded"
  # US-41.1 AC-41.1.8: the query vector's length does not match the dimension the
  # read path scans (a non-1536 tenant before the read flag flips, or a model change
  # mid-flight). Search degrades to keyword-only and SAYS so.
  defp reason_to_tag(:semantic_recall_unavailable), do: "semantic_recall_unavailable"
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

  # Fuse the per-lane result lists into one ranked, deduplicated candidate set (#470).
  #
  # Default strategy is Reciprocal Rank Fusion (RRF); the legacy min-max weighted-sum
  # is retained behind `:min_max` for A/B and the eval harness. Both strategies produce
  # the IDENTICAL result/meta shape and BOTH preserve every candidate's raw, ABSOLUTE
  # `:relevance_score` / `:similarity_score` (the hybrid resolver US-31.2 reads those
  # raw fields via `absolute_score/1`, never the fused `:final_score`).
  #
  # `merge_results/5` is a PURE fusion function — the optional graph-neighbor lane
  # (which needs a DB read) is computed by the caller and threaded in via
  # `opts[:_graph_lane_results]`, so this arity and contract stay stable.
  defp merge_results(keyword_result, semantic_result, kw_weight, sem_weight, opts) do
    graph_results = Keyword.get(opts, :_graph_lane_results, [])

    sorted =
      case fusion_strategy(opts) do
        :min_max ->
          fuse_min_max(keyword_result.results, semantic_result.results, kw_weight, sem_weight)

        _rrf ->
          fuse_rrf(
            keyword_result.results,
            semantic_result.results,
            graph_results,
            kw_weight,
            sem_weight,
            opts
          )
      end
      # #471: re-rank the fused list by the recency + source-authority priors BEFORE the
      # top-k cut. Pure (no DB) — the result maps already carry updated_at/category/
      # source_type/tags/status, so merge_results/5 stays a DB-free fusion function.
      |> apply_ranking_priors_fused(opts)

    # #31 follow-up: the curated-vs-retrieved decision runs HERE, on the default path,
    # rather than only inside `hybrid_search/3`. It is a re-rank of this same fused pool —
    # not a different search — so exposing it as a separate tool asked every agent to know,
    # per query, whether a governed answer exists. Finding that out IS the search.
    {sorted, provenance_meta} = apply_curated_provenance(sorted, opts)

    paginated = paginate_results(sorted, opts)

    {:ok,
     %{
       results: paginated.results,
       meta:
         %{
           # `total_count` = size of the full fused/deduplicated candidate set
           # pre-pagination. When the (opt-in) graph lane is enabled it also counts the
           # one-hop neighbors it contributed; with the lane OFF (the default) this is
           # exactly the keyword ∪ semantic union, byte-for-byte as before.
           total_count: length(sorted),
           limit: paginated.limit,
           offset: paginated.offset,
           search_mode: "combined",
           # Names what `total_count` counts so a client can size/interpret the pool.
           # Default `merged_candidates`: the deduplicated UNION of a keyword and a
           # semantic sub-search (each capped at 100, so up to ~200 with no overlap),
           # NOT a corpus total or full match count. When the opt-in graph lane
           # actually contributes one-hop neighbors, the count folds them in, so the
           # scope becomes `merged_candidates_with_graph` — the documented
           # `merged_candidates` invariant (keyword ∪ semantic only) still holds for
           # its literal value (#470 review). Use list mode or knowledge_stats to size
           # the corpus.
           total_count_scope:
             if(graph_results == [],
               do: "merged_candidates",
               else: "merged_candidates_with_graph"
             ),
           # Carry the semantic sub-search's relevance-pool truncation forward (US-27.7a)
           # — combined is the DEFAULT mode, so silently dropping the flag would hide
           # truncation on the most-used path. `maybe_put` keeps the key absent unless the
           # semantic half was actually pool-capped.
           pool_capped: Map.get(semantic_result.meta, :pool_capped, false),
           # Observability for #297: how many rows the semantic half contributed. A
           # `0` here with `fallback: false` is the "embed worked but recall is broken"
           # signal (distinct from an embed-failure keyword_only fallback), so operators
           # and clients can tell the two silent-degradation causes apart. The graph
           # lane NEVER inflates this — it stays the semantic lane's own row count.
           semantic_result_count: length(semantic_result.results)
         }
         # Carried forward for the SAME reason as `pool_capped` above: combined is the
         # DEFAULT mode, so a degraded vector read that is disclosed only on `mode=semantic`
         # is undisclosed on the path almost every caller uses. Absent unless the semantic
         # half emitted it (a keyword-only degrade has no vector read to describe).
         |> Map.merge(
           Map.take(semantic_result.meta, [:ann_iterative_scan, :ann_iterative_scan_reason])
         )
         |> Map.merge(provenance_meta)
     }}
  end

  # --- Reciprocal Rank Fusion (#470) ------------------------------------------
  #
  # `score(doc) = Σ_lane weight_lane / (k + rank_lane(doc))`, ranks 1-based, keyword/
  # semantic per-lane weight 0.5 and the opt-in graph lane STRICTLY BELOW them (0.25) so a
  # zero-signal one-hop neighbor can never tie/outrank a genuine single-lane hit (#470
  # review), default k=60 (KB f4a10824). Rank-based fusion sidesteps the
  # incommensurable-scale problem (ts_rank_cd vs cosine similarity) that made the old
  # min-max weighted-sum brittle: a doc with cross-lane CONSENSUS can outrank one that
  # is #1 in a single lane. Each lane's list is ALREADY sorted by its own relevance
  # (keyword desc ts_rank_cd, semantic desc cosine similarity, graph desc consensus),
  # so its position IS its rank. Duplicate docs across lanes merge to one, summing
  # their contributions and keeping the UNION of raw fields.
  defp fuse_rrf(kw_results, sem_results, graph_results, kw_weight, sem_weight, opts) do
    k = rrf_k(opts)
    graph_weight = rrf_graph_weight(opts)

    lanes = [
      {kw_results, kw_weight},
      {sem_results, sem_weight},
      {graph_results, graph_weight}
    ]

    lanes
    |> Enum.reduce(%{}, fn {results, weight}, acc ->
      accumulate_rrf_lane(acc, results, weight, k)
    end)
    |> Map.values()
    # Deterministic total order: `final_score` desc with `id` as the secondary key.
    # RRF's `1/(k+rank)` values tie by construction, and `Map.values/1` order is
    # hash-driven, so without the id tiebreak which tied candidate survives the top-k
    # limit (and thus recall@k / nDCG@k / MRR) would flip run-to-run.
    |> Enum.sort_by(&{&1.final_score, &1.id}, :desc)
  end

  defp accumulate_rrf_lane(acc, results, weight, k) do
    results
    |> Enum.with_index(1)
    |> Enum.reduce(acc, fn {result, rank}, inner ->
      contribution = weight / (k + rank)

      Map.update(
        inner,
        result.id,
        Map.put(result, :final_score, contribution),
        fn existing ->
          # Union the raw fields (a doc seen in multiple lanes keeps kw's raw
          # `:relevance_score`/`:snippet` AND sem's raw `:similarity_score` — the
          # hybrid resolver needs both), and ADD this lane's contribution. `result`
          # carries no `:final_score`, so merging it in never clobbers the running sum.
          existing
          |> Map.merge(result)
          |> Map.put(:final_score, existing.final_score + contribution)
        end
      )
    end)
  end

  # --- Legacy min-max weighted-sum fusion (#470 A/B) --------------------------
  #
  # Retained behind `config :loopctl, :knowledge_fusion_strategy, :min_max` (or the
  # per-call `fusion_strategy: :min_max` opt) so the eval harness can compare the two
  # and an operator can roll back. Min-max normalizes each lane's raw scores into
  # `0..1` (dominated by pool outliers/composition — the reason RRF replaced it) and
  # weight-sums them. Graph lane is not fused here (min-max is the legacy 2-lane path).
  defp fuse_min_max(kw_results, sem_results, kw_weight, sem_weight) do
    kw_map =
      kw_results
      |> normalize_scores(:relevance_score)
      |> Map.new(fn r -> {r.id, Map.put(r, :final_score, kw_weight * r.normalized_score)} end)

    sem_map =
      sem_results
      |> normalize_scores(:similarity_score)
      |> Map.new(fn r -> {r.id, Map.put(r, :final_score, sem_weight * r.normalized_score)} end)

    kw_map
    |> Map.merge(sem_map, fn _id, kw, sem ->
      kw
      |> Map.merge(sem)
      |> Map.put(:final_score, kw.final_score + sem.final_score)
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1.final_score, &1.id}, :desc)
  end

  defp fusion_strategy(opts) do
    Keyword.get(
      opts,
      :fusion_strategy,
      Application.get_env(:loopctl, :knowledge_fusion_strategy, :rrf)
    )
  end

  defp rrf_k(opts) do
    Keyword.get(opts, :rrf_k, Application.get_env(:loopctl, :knowledge_rrf_k, 60))
  end

  # --- Recency + source-authority priors (#471) -------------------------------
  #
  # Post-fusion re-ranking applied on `search_combined/3`'s fused candidate list (and,
  # via apply_ranking_priors_fallback/2, on the degraded keyword_only path). PURE re-rank:
  # no DB, and the clock is threaded through opts (`:now`, defaulting to utc_now here) so
  # merge_results/5 stays DB-free and tests stay deterministic. Bounded BY DESIGN — see
  # Loopctl.Knowledge.RankingPriors — so the priors break ties without dominating strong
  # relevance.

  # Bounds for the authority factor band. Narrow so it only re-ranks near-ties.
  @authority_floor 0.9
  @authority_ceiling 1.1

  # Re-rank the FUSED list: multiply each candidate's fused `:final_score` by its prior
  # multiplier, then re-sort by `{final_score, id}` desc — the SAME deterministic tiebreak
  # fuse_rrf/fuse_min_max use, so with priors disabled (multiplier 1.0) the ordering is
  # byte-for-byte the pre-#471 fused ordering. Only `:final_score` (a fused field) is
  # adjusted; the raw `:relevance_score`/`:similarity_score` the hybrid resolver reads are
  # left untouched.
  defp apply_ranking_priors_fused(results, opts) do
    prior_opts = ranking_prior_opts(opts)

    results
    |> Enum.map(fn r ->
      Map.update(r, :final_score, 0.0, &(&1 * RankingPriors.multiplier(r, prior_opts)))
    end)
    |> Enum.sort_by(&{&1.final_score, &1.id}, :desc)
  end

  # Re-rank the degraded keyword_only list. There is no fused `:final_score`, so the sort
  # key is `relevance_score * multiplier` computed on the fly — the raw `:relevance_score`
  # is NEVER mutated (shape preserved; hybrid resolver safe). The two-stage stable sort
  # preserves the keyword lane's own `id ASC` tiebreak (its DB order is
  # `ts_rank_cd DESC, id ASC`), so with priors disabled the ordering is unchanged.
  defp apply_ranking_priors_fallback(results, opts) do
    prior_opts = ranking_prior_opts(opts)

    results
    |> Enum.sort_by(& &1.id, :asc)
    |> Enum.sort_by(
      fn r -> (Map.get(r, :relevance_score) || 0.0) * RankingPriors.multiplier(r, prior_opts) end,
      :desc
    )
  end

  defp ranking_prior_opts(opts) do
    [
      now: Keyword.get(opts, :now, DateTime.utc_now()),
      recency_weight: recency_weight_opt(opts),
      authority?: authority_prior_enabled?(opts),
      strength: authority_strength_opt(opts),
      floor: @authority_floor,
      ceiling: @authority_ceiling
    ]
  end

  defp recency_weight_opt(opts) do
    opts
    |> Keyword.get(:recency_weight, Application.get_env(:loopctl, :knowledge_recency_weight, 0.3))
    |> max(0.0)
    |> min(1.0)
  end

  defp authority_prior_enabled?(opts) do
    Keyword.get(
      opts,
      :authority_prior,
      Application.get_env(:loopctl, :knowledge_authority_prior_enabled, true)
    )
  end

  defp authority_strength_opt(opts) do
    opts
    |> Keyword.get(
      :authority_strength,
      Application.get_env(:loopctl, :knowledge_authority_strength, 0.05)
    )
    |> max(0.0)
  end

  defp rrf_graph_weight(opts) do
    Keyword.get(
      opts,
      :graph_weight,
      Application.get_env(:loopctl, :knowledge_rrf_graph_weight, 0.5)
    )
  end

  defp graph_lane_enabled?(opts) do
    Keyword.get(
      opts,
      :graph_lane,
      Application.get_env(:loopctl, :knowledge_rrf_graph_lane_enabled, false)
    )
  end

  defp rrf_graph_seed_count,
    do: Application.get_env(:loopctl, :knowledge_rrf_graph_seed_count, 10)

  defp rrf_graph_max_neighbors,
    do: Application.get_env(:loopctl, :knowledge_rrf_graph_max_neighbors, 20)

  # --- Graph-neighbor lane (#470) ---------------------------------------------
  #
  # OFF by default. When enabled, takes the top merged candidates as SEEDS, pulls their
  # one-hop link-graph neighbors (heavy-pool-routed, tenant-scoped, visibility-filtered — a
  # tenant B neighbor can never surface for tenant A), ranks them by cross-seed CONSENSUS
  # (how many DISTINCT seeds link to them, best seed position as tiebreak), and returns
  # requested-status article maps in that rank order for the fusion. The neighbor maps carry
  # NO `:relevance_score`/`:similarity_score`, so their hybrid-resolver `absolute_score`
  # is 0.0 — a graph-only hit can never falsely win the curated-vs-retrieved decision.

  # The curated candidate ids for this pool, threaded into `merge_results/5` via opts for
  # the SAME reason `put_graph_lane/4` is: the lookup is a DB read and `merge_results/5`
  # stays a pure fusion function. One bounded `SELECT id ... WHERE id = ANY($1)` over a pool
  # already capped at ~200, on a path that has already paid a keyword search, an embedding
  # and a vector read.
  defp put_curated_lane(opts, tenant_id, kw, semantic) do
    if Keyword.get(opts, :_skip_curated_provenance, false) do
      opts
    else
      case kw.results ++ semantic.results do
        [] -> opts
        candidates -> Keyword.put(opts, :_curated_ids, curated_source_ids(tenant_id, candidates))
      end
    end
  end

  # Decides provenance over the FUSED pool, and hoists a winning curated article to the front
  # of the FIRST page only.
  #
  # The decision is a property of the POOL, so it is reported on every page — a paginated
  # caller that lost `meta.provenance` after page 1 would have to branch on page number to
  # know whether a governed answer exists, and the whole point of the field is that a caller
  # branches on provenance alone.
  #
  # The HOIST is a property of the page, so it applies at offset 0 only: re-serving the
  # winner at the top of page 2 would show it twice to a caller paging forward.
  # `hybrid_search/3` forces `offset: 0` on its inner call for the mirror-image reason — so
  # a curated article ranked outside the caller's window is still FOUND.
  defp apply_curated_provenance(sorted, opts) do
    case Keyword.get(opts, :_curated_ids) do
      nil ->
        {sorted, %{}}

      curated_ids ->
        {ordered, decision} = decide_curated_provenance(sorted, curated_ids)
        if Keyword.get(opts, :offset, 0) == 0, do: {ordered, decision}, else: {sorted, decision}
    end
  end

  defp decide_curated_provenance(sorted, curated_ids) do
    # `candidate_scores/1` reads the per-lane ABSOLUTE score (`similarity_score` /
    # `relevance_score`), never the fused `:final_score`. That matters: post-#470 the fused
    # value is an RRF weight topping out near 0.016, so the configured thresholds — tuned
    # against a 0..1 scale — would be unreachable and every search would resolve
    # `:retrieved`. Those per-lane fields ride along through fusion, so the decision here is
    # the same one `hybrid_search/3` makes on the same pool.
    scores = candidate_scores(sorted)
    {curated, retrieved} = Enum.split_with(sorted, &MapSet.member?(curated_ids, &1.id))
    best_curated = Enum.max_by(curated, &Map.fetch!(scores, &1.id), fn -> nil end)
    curated_score = best_curated && Map.fetch!(scores, best_curated.id)
    best_retrieved_score = best_score(retrieved, scores)
    {threshold, margin} = hybrid_curated_threshold_and_margin(best_curated)

    case resolve_provenance(curated_score, best_retrieved_score, threshold, margin) do
      :curated ->
        {hoist_to_front(sorted, best_curated.id),
         %{
           provenance: :curated,
           confidence: curated_score,
           curated_article_id: best_curated.id
         }}

      :retrieved ->
        {sorted,
         %{provenance: :retrieved, confidence: best_retrieved_score, curated_article_id: nil}}
    end
  end

  defp put_graph_lane(opts, tenant_id, kw, semantic) do
    # Only the RRF fuser consumes `:_graph_lane_results` — `fuse_min_max/4` ignores
    # graph neighbors entirely. Gate the (DB-backed) lane build on the strategy being
    # RRF so a `graph_lane: true` + `fusion_strategy: :min_max` caller doesn't pay the
    # ~11 round-trip graph read only to have the result silently discarded (#470 review).
    if graph_lane_enabled?(opts) and fusion_strategy(opts) != :min_max do
      case build_graph_lane(tenant_id, kw, semantic, opts) do
        [] -> opts
        neighbors -> Keyword.put(opts, :_graph_lane_results, neighbors)
      end
    else
      opts
    end
  end

  defp build_graph_lane(tenant_id, kw, semantic, opts) do
    vis = Keyword.get(opts, :visibility_agent_id)
    # Graph-lane neighbors honor the SAME status filter the primary lanes use (search_keyword/
    # search_semantic both default `:published` and honor the caller opt). Hardcoding
    # `:published` here would make a `graph_lane: true` + non-published-status search return an
    # inconsistent lane vs. its primary lanes (#470 review).
    status = Keyword.get(opts, :status, :published)

    # Seeds: the top merged candidates by their existing lane order (keyword first,
    # then semantic), deduped, capped. Seeds themselves are excluded from the neighbor
    # set (a lane already ranks them; the graph lane exists to surface their neighbors).
    seed_ids =
      (kw.results ++ semantic.results)
      |> Enum.map(& &1.id)
      |> Enum.uniq()
      |> Enum.take(rrf_graph_seed_count())

    seed_set = MapSet.new(seed_ids)
    seed_index = seed_ids |> Enum.with_index() |> Map.new()

    # ONE tenant-scoped round-trip for the WHOLE seed set (was one AdminRepo query
    # PER seed — an N+1 that fanned up to `rrf_graph_seed_count` sequential reads
    # onto the deliberately small BYPASSRLS AdminRepo pool). Per-seed provenance is
    # recovered in memory from the source/target ids each link row already carries.
    # `%{neighbor_id => MapSet<seed_index>}`: a SET of DISTINCT seed indices, NOT a link-row
    # count, so a neighbor linked from ONE seed via several rows counts that seed once (#470
    # review — see `tally_graph_neighbor/3`).
    neighbor_stats =
      tenant_id
      |> list_links_for_seed_set(seed_ids, vis)
      |> Enum.reduce(%{}, fn link, acc ->
        link
        |> seed_neighbor_pairs(seed_set)
        |> Enum.reduce(acc, fn {seed_id, neighbor_id}, inner ->
          tally_graph_neighbor(inner, neighbor_id, Map.fetch!(seed_index, seed_id))
        end)
      end)

    ranked_ids =
      neighbor_stats
      # Rank: most DISTINCT seeds (consensus) first, then best (lowest) seed position, then
      # id for a deterministic total order.
      |> Enum.sort_by(fn {nid, seed_idxs} ->
        {-MapSet.size(seed_idxs), Enum.min(seed_idxs), nid}
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.take(rrf_graph_max_neighbors())

    fetch_graph_lane_articles(tenant_id, ranked_ids, status)
  end

  # Cap on link rows read per seed-set graph-lane query — bounds fan-out on a densely-linked
  # hub, matching the per-article `list_links_for_article/3` limit (#470 review). Without it,
  # up to `rrf_graph_seed_count` hub seeds could pull thousands of ArticleLink rows in one read.
  @graph_lane_link_limit 200

  # One tenant-scoped, visibility-filtered read of every link touching ANY seed in the set —
  # the single query that replaces the per-seed N+1.
  defp list_links_for_seed_set(_tenant_id, [], _vis), do: []

  defp list_links_for_seed_set(tenant_id, seed_ids, vis) do
    # Preload only the far-side fields the #163 visibility filter needs (id/tenant_id/status/
    # metadata) — NOT the full Article body. A dense hub would otherwise materialize hundreds
    # of full bodies just to drop them after the visibility check.
    summary =
      from(a in Article, select: struct(a, [:id, :tenant_id, :status, :metadata]))

    query =
      from(l in ArticleLink,
        where: l.tenant_id == ^tenant_id,
        where: l.source_article_id in ^seed_ids or l.target_article_id in ^seed_ids,
        preload: [source_article: ^summary, target_article: ^summary],
        order_by: [desc: l.inserted_at],
        limit: @graph_lane_link_limit
      )

    # Route through Loopctl.HeavyRead (US-27.11): the dedicated heavy-read pool with a per-read
    # SET LOCAL statement_timeout, isolated from the deliberately tiny ~3-connection BYPASSRLS
    # AdminRepo pool. search_combined is the DEFAULT mode, so once an operator enables the graph
    # lane EVERY combined search runs this — it must not starve light admin ops (the same reason
    # the distant-pairs self-join was routed here). `on_overload: :tag` degrades an over-cap
    # tenant's lane to empty (it is a purely additive recall lane) instead of raising a 429. The
    # (unscoped) preload of far-side articles stays safe because every id comes from a
    # tenant-scoped link row, and article links never cross tenants.
    case heavy_read_graph_lane(tenant_id, query) do
      {:error, :heavy_read_overloaded} ->
        []

      links ->
        # Visibility (#163): drop links whose far-side article the caller can't see, so a
        # neighbor can't leak another agent's private memory id/title — same filter the
        # per-article `list_links_for_article/3` applies. The neighbor STATUS filter is applied
        # downstream in `fetch_graph_lane_articles/3` (a link to a non-matching-status neighbor
        # yields no lane row), so no lane result can carry a wrong-status article.
        filter_links_by_visibility(links, vis)
    end
  end

  # HeavyRead read for the opt-in graph lane: heavy-pool-routed, statement-timed, and shed to
  # `{:error, :heavy_read_overloaded}` (never a 429) when the tenant is over its in-flight cap.
  defp heavy_read_graph_lane(tenant_id, query) do
    opts = Keyword.put(HeavyRead.opts(:graph_lane), :on_overload, :tag)
    HeavyRead.all(tenant_id, query, opts)
  end

  # A link contributes AT MOST one `{seed_id, neighbor_id}` edge: the neighbor is the
  # endpoint that is NOT itself a seed. A link between two seeds (or a self-link)
  # contributes none — a seed is already ranked by a primary lane. This mirrors the
  # old per-seed `graph_neighbor_ids/2` + seed-set reject, one link at a time.
  defp seed_neighbor_pairs(
         %ArticleLink{source_article_id: src, target_article_id: tgt},
         seed_set
       ) do
    src_seed = MapSet.member?(seed_set, src)
    tgt_seed = MapSet.member?(seed_set, tgt)

    cond do
      src_seed and not tgt_seed -> [{src, tgt}]
      tgt_seed and not src_seed -> [{tgt, src}]
      true -> []
    end
  end

  # Fold one `seed → neighbor` edge into the running `%{neighbor_id => MapSet<seed_index>}`
  # tally. The value is a SET of DISTINCT seed indices, so a neighbor linked from the SAME
  # seed via several ArticleLink rows — multiple relationship_types, or a bidirectional pair
  # whose source/target swap both map to the same {seed,neighbor} — counts that seed ONCE.
  # Consensus is then `MapSet.size` (distinct seeds), matching the documented distinct-seed
  # signal; counting link ROWS let a single densely-linked seed masquerade as multi-seed
  # consensus (#470 review).
  defp tally_graph_neighbor(acc, neighbor_id, seed_idx) do
    Map.update(acc, neighbor_id, MapSet.new([seed_idx]), &MapSet.put(&1, seed_idx))
  end

  defp fetch_graph_lane_articles(_tenant_id, [], _status), do: []

  defp fetch_graph_lane_articles(tenant_id, ranked_ids, status) do
    query =
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.id in ^ranked_ids and a.status == ^status,
        select: %{
          id: a.id,
          tenant_id: a.tenant_id,
          project_id: a.project_id,
          title: a.title,
          category: a.category,
          # source_type is projected here for symmetry with the keyword lane
          # (knowledge.ex ~1870) and the semantic pool (vector_search.ex ~499) so
          # RankingPriors.authority_factor reads the SAME source-authority prior no
          # matter which lane first surfaced a doc. Without it a graph-lane-only doc
          # would fall back to source_authority(nil) (the 0.0 neutral floor) and get a
          # category-only authority factor — asymmetric with kw/sem (#471 review).
          source_type: a.source_type,
          status: a.status,
          tags: a.tags,
          inserted_at: a.inserted_at,
          updated_at: a.updated_at
        }
      )

    # Also heavy-pool-routed (US-27.11) — a bounded (`<= rrf_graph_max_neighbors`) id-set read,
    # kept off the tiny AdminRepo pool for the same reason as the link read above.
    rows =
      case heavy_read_graph_lane(tenant_id, query) do
        {:error, :heavy_read_overloaded} -> []
        list -> list
      end
      |> Map.new(&{&1.id, &1})

    # Preserve the consensus rank order; silently drop any neighbor that isn't in the
    # requested status (other-status / visibility-filtered rows never join the lane).
    Enum.flat_map(ranked_ids, fn id ->
      case Map.fetch(rows, id) do
        {:ok, row} -> [row]
        :error -> []
      end
    end)
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
  `Loopctl.Knowledge.RetrievalMetrics` / `article_access_events` pipeline. NOTE: the
  named `curated_*`/`retrieved_*` breakdown this used to point at was removed in #712 —
  it read only these `hybrid_*` tags while the default path writes `combined_*`, so it
  saw ~3% of the decisions. "Prefer-curated silently hiding better retrieval" is
  observable per tenant by querying the mode tag directly, until a breakdown that reads
  BOTH namespaces earns its way back. That DB-backed
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
      # The default path now runs this same decision inside `merge_results/5`. Skip it on
      # the INNER call: this function applies `decide_curated_provenance/2` itself, over
      # the same pool, so letting the inner one run would pay for the curated lookup twice
      # to reach the identical answer.
      |> Keyword.put(:_skip_curated_provenance, true)

    with {:ok, %{results: pool_results, meta: pool_meta}} <-
           search_combined(tenant_id, query_string, pool_opts) do
      # ONE implementation of the decision, shared with the default path — see
      # `decide_curated_provenance/2`. This function's remaining job is the part that IS
      # specific to it: forcing the full pool at offset 0 so a curated article ranked
      # outside the caller's window is still found, then paging the reordered pool.
      curated_ids = curated_source_ids(tenant_id, pool_results)

      {ordered_pool, decision} = decide_curated_provenance(pool_results, curated_ids)

      provenance = decision.provenance
      confidence = decision.confidence
      curated_article_id = decision.curated_article_id

      page = paginate_results(ordered_pool, limit: requested_limit, offset: requested_offset)

      maybe_record_search_access(
        tenant_id,
        page.results,
        query_string,
        Keyword.merge(opts,
          _total_count: pool_meta[:total_count],
          _degraded: pool_meta[:fallback] == true,
          _fallback_reason: pool_meta[:fallback_reason]
        ),
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

  @doc """
  The ABSOLUTE (pool-independent) relevance score for a `search_combined/3` /
  `search_semantic/3` / `search_keyword/3` result map — the raw cosine `:similarity_score`
  (already 0..1) when present, else a bounded `raw/(raw+1)` transform of the raw keyword
  `:relevance_score`, else `0.0`.

  Public seam for CROSS-SOURCE ranking (e.g. `Loopctl.Memory.recall_context/2`), which must
  compare a knowledge result against memory's absolute cosine similarity on the SAME 0..1
  scale. It must NOT use the fused `:final_score`: post-#470 that is an RRF `Σ weight/(k+rank)`
  value (top ~0.008-0.016), which — compared against a memory row's 0..1 cosine — would
  systematically sink every knowledge row below every memory row (#470 review). This is the
  same absolute signal `absolute_score/1` gives the hybrid resolver (US-31.2).
  """
  @spec absolute_result_score(map()) :: float()
  def absolute_result_score(result) when is_map(result), do: absolute_score(result)
  def absolute_result_score(_), do: 0.0

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

  # The recorded mode carries the provenance DECISION, exactly as `hybrid_search_mode/1`
  # already does — because that is what makes the decision measurable. `search_events` joins
  # to `article_access_events` to answer "did the searcher open anything", so labelling the
  # branch here turns that join into "when we led with a governed article, did they open it,
  # and more often than when we did not?". That is the only feedback signal in the system
  # that is derived from what an agent DID rather than from what a ranker scored.
  #
  # `combined` (unlabelled) is still emitted when the curated lane did not run — an
  # inner/pool call that skipped it, or a search whose pool was empty — so the value is never
  # a guess. Rows written before this landed carry the bare `combined`; treat that as a third
  # class, not as `combined_retrieved`.
  defp combined_search_mode(:curated), do: "combined_curated"
  defp combined_search_mode(:retrieved), do: "combined_retrieved"
  defp combined_search_mode(_absent), do: "combined"

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

  # Bound on a single stub so the whole index stays paste-able into a cached prefix.
  # The cap is per-stub rather than a running total: truncating the LAST stub of a top-K list
  # would silently drop the tail, and a partially-listed index is worse than a shorter one
  # because nothing signals the omission. EVERY variable-length field is capped — a title is
  # validated only to 500 chars, so leaving it uncapped made the advertised budget a number
  # the payload could exceed several-fold.
  #
  # Every cap below is in BYTES — the unit `heat_stub_chars/1` measures and `fit_stub_to_cap/1`
  # enforces. Slicing a field by GRAPHEME while enforcing the total in bytes was the same
  # mixed-unit defect one level down: a CJK stub arrived 3x over the cap, so the fitter shrank
  # its summary to "" and then ate its title, and a non-Latin corpus got a title-only index.
  @heat_summary_chars 120
  @heat_title_chars 100
  # The fixed per-stub cost the caller actually pays, MEASURED off the wire shape
  # `{"id":"<36-char uuid>","title":"","category":"","heat":,"summary":""}`: the UUID plus the
  # JSON keys and punctuation around the five fields. The heat integer is variable-width, so it
  # is counted per stub in `heat_stub_chars/1` instead of being folded in here — `chars` is the
  # number a caller budgets a cached prefix against and must not under-report it. Both `chars`
  # and `char_budget` cover the STUB ARRAY only; `meta` itself (the fixed `drill` instruction
  # included) rides on top and is stated as such wherever the budget is advertised.
  @heat_stub_fixed_chars 91
  # `category` is a closed enum whose longest member is far under this.
  @heat_category_chars 24
  # Digits allotted to `heat` in the ADVERTISED budget; an access count cannot exceed them.
  @heat_count_chars 10
  @heat_stub_char_cap @heat_title_chars + @heat_summary_chars + @heat_category_chars +
                        @heat_stub_fixed_chars + @heat_count_chars

  # Heat counts CALLER-CHOSEN body fetches only. `"search"`, the reserved `"index"` AND
  # `"context"` are all LIST-shaped — `Analytics.record_search_access/6` and
  # `record_context_access/5` each write one row per RESULT of one ranker-run query — so
  # counting any of them would make heat a running tally of past ranker output, re-coupling
  # this route to the embedding similarity it exists to be uncorrelated with. A context pack
  # does ship bodies, but the caller asked ONE question and the ranker picked the N articles,
  # so one query would out-vote N deliberate reads. `"get"` is the only per-article fetch a
  # reader names. Deliberately NARROWER than the read set in
  # `RetrievalMetrics.compute_followed_through/2`, which asks a different question (was a body
  # DELIVERED, ranker-chosen or not) — the two sets must not be unified.
  #
  # `"drill"` is excluded for a THIRD reason, distinct from the list-shape one above (#569).
  # A drill IS a genuine single-article body read — it fails none of the tests that exclude
  # `"search"` and `"context"` — so it is not its SHAPE that disqualifies it, it is the HOP
  # FROM THIS INDEX: shown -> read -> ranked -> shown, a loop in which material that never
  # surfaced could not overtake material that already had, and `knowledge_progressive_drill`
  # is the very tool `meta.drill` names. The label is derived from WHICH READ PATH resolved
  # the article, never from a caller-declared origin — a declaration only binds the clients
  # that send it, leaving every older MCP release and every raw HTTP call feeding the loop.
  #
  # The exclusion is UNIFORM across scopes (#572), and the first attempt at it was not. A
  # system canonical's drill used to record a counted `"get"`, because `get_article/3` filtered
  # on `tenant_id` and a canon row's is NULL, so the drill was the only path to its body and
  # excluding it would have frozen the canon at heat 0. That reasoning was sound about the
  # canon and wrong about the INDEX: ranking a counted class against an uncounted one on a
  # single `heat` number means the number measures different things per row, and since drilling
  # is the DOCUMENTED path (`meta.drill`, the MCP tool text), following the docs raised only
  # canonicals. Monotonic drift toward the shared canon, self-reinforcing — a canon shown at
  # rank 1 got drilled, which held it at rank 1. The distinct-reader count (#567) bounds ONE
  # agent's loop, not a fleet all following the same instruction.
  #
  # The fix was to give the canon the read path it lacked rather than to count the one it had:
  # `get_article/3` now resolves published canonicals too, so every article earns heat the same
  # way and `knowledge_get` no longer 404s on a canon stub. Same rule as #563 (search
  # impressions) and #567 (one key's loop): heat must not rank on a signal heat produces —
  # and, now stated once rather than learned four times, it must not rank counted and uncounted
  # read paths on one number.
  @heat_read_access_types ~w(get)

  # The aggregate runs on the request path over `article_access_events`, the one table that
  # only ever grows, under a 10s statement timeout. An unbounded all-time scan therefore fails
  # (500) rather than degrades on exactly the tenant with the most history. A default window
  # bounds it; `:since` moves it either way, up to the ceiling below.
  @heat_default_window_days 90

  # The ceiling. `:since` is caller-supplied, so without a floor on the lookback the unbounded
  # all-time scan the default exists to prevent is one query parameter away. An older `:since`
  # is CLAMPED (not rejected — the caller still gets the widest window that can be served) and
  # `meta.heat_window` echoes what it actually got.
  @heat_max_window_days 365

  # The stub projection runs on the 3-connection `AdminRepo` pool WHILE holding this tenant's
  # heavy-read slot, so its wait has to be bounded well under the 15s Ecto default.
  @heat_stub_timeout_ms 5_000

  # The SQLSTATEs on which a server-side fault IS the saturation this route degrades to a 429
  # for. Everything else a `Postgrex.Error` can carry is a deterministic query fault and must
  # surface as a 500 instead of being retried forever behind an overload label.
  #
  # The three classes, enumerated in full rather than described — a list that is narrower than
  # the prose above it is how the next reader gets this wrong: the statement timeout (57014),
  # an exhausted backend (ALL of 53xxx), and a backend going away or refusing the connection
  # (57P01/57P02/57P03 and ALL of 08xxx — pgbouncer rejects with 08P01, which the earlier
  # three-code 08 list dropped into the 500 this rescue exists to prevent).
  @heat_saturation_sqlstates ~w(
    query_canceled
    insufficient_resources disk_full out_of_memory too_many_connections
    configuration_limit_exceeded
    admin_shutdown crash_shutdown cannot_connect_now
    connection_exception sqlclient_unable_to_establish_sqlconnection
    connection_does_not_exist sqlserver_rejected_establishment_of_sqlconnection
    connection_failure transaction_resolution_unknown protocol_violation
  )a

  @doc """
  A HEAT-ranked, topic-less stub index of the corpus (#554).

  The second retrieval route. `search_semantic/3` and `progressive_index/3` both start from a
  QUERY, so they share a failure mode: a paraphrase, or material that is topically central but
  lexically dissimilar to the question, comes back empty — and an empty result reads as "the KB
  has nothing" rather than "I asked badly", with nothing in context to contradict it. This route
  takes no query at all, so its misses are uncorrelated with embedding similarity.

  Ordering is by HEAT — the number of DISTINCT READERS (agents) that made a CALLER-CHOSEN
  body read (`#{Enum.join(@heat_read_access_types, "/")}`) inside the window; list-shaped
  ranker output (`search`, `context`) and this index's own drill hop are
  deliberately NOT counted, see `@heat_read_access_types`. Usage is treated as the authority on importance, so material that
  keeps proving worth reading holds its rank regardless of what today's query embeds near.
  Heat is WINDOWED, not cumulative: an empty result means "nothing was read within
  `meta.heat_window`", NOT "the corpus is empty".

  ## Why DISTINCT readers, not raw reads (#567)

  Counting event rows made the ranking self-serve: any agent could pin its own article at
  rank 1 by calling `knowledge_get` on it in a loop, and — because this index is meant to be
  pasted into a cached prefix — that ranking then propagates into every OTHER agent's context.
  A signal the ranked party controls is not a signal. A READER is `coalesce(agent_id,
  api_key_id)` of the key that read, NOT the key row: v2 mints a fresh ephemeral key per
  dispatch, so counting KEYS would count DISPATCHES — an agent that re-dispatches N times
  votes N times, the same pinning one cheap API call away. One AGENT contributes at most 1
  however many times, and from however many dispatches, it reads.

  That collapse needs an `agent_id` to collapse ONTO, so it is a claim about agent-bearing
  keys only. A key with none — a user/orchestrator key — votes as itself, so a tenant that
  mints N of them can lift its own article to heat N. Minting is a `:user`-role, audited
  surface and the effect stops inside that tenant's own index, but it is NOT the one-vote
  guarantee above and must not be restated as one.

  What the guarantee IS bounded by, stated exactly (#572): `api_keys.agent_id` carries a
  FOREIGN KEY to `agents(id)` (`api_keys_agent_id_fkey`, ON DELETE RESTRICT) plus a partial
  unique index of one active key per agent per role
  (`api_keys_one_role_per_agent_idx`), so a vote resolves to a row in the tenant's REGISTERED
  agent set — it is not a free-form string a dispatch can invent. The remaining lever is
  therefore registering agents, not minting keys or re-dispatching: N registered agents buy N
  votes. That is a bounded, audited, tenant-local surface rather than the one cheap API call
  the distinct-key count left open, which is the whole distance #567 moved. Do not describe
  this as "one agent, one vote" without the registration caveat.

  Breadth is a SMALL integer (fleet size), so ties are the common case — and a fleet sharing
  one key ties every article at 1. The tie is broken on DISTINCT READ DAYS, never on raw event
  rows: raw rows are the counter a loop inflates, so breaking the tie on them handed the whole
  ranking back to the ranked party in precisely the shared-key deployment where everything
  ties. A day counts once however long the loop runs, so sustained use outranks a burst, and
  the article id still keeps the order TOTAL.

  System-scoped published canonicals participate, exactly as they do in
  `list_curated_sources/2` and `progressive_drill/3` — a tenant whose most-read material is
  the shared canon would otherwise get an index that omits precisely what it reads most. They
  participate on the SAME terms as tenant-owned articles (#572): `get_article/3` resolves a
  published canonical, so a canon earns heat from a caller-named `get` and its drill is
  uncounted like any other. Making a canon's drill count instead — the first attempt at this
  — left the ranking comparing a counted class against an uncounted one, which is what
  `@heat_read_access_types` now forbids outright.

  ## Why this is NOT an option on `progressive_index/3`

  That function is topic-SEEDED: it begins with `search_keyword/3` over the caller's topic and
  enriches from there. Heat has no topic to seed from, so folding it in would mean a `topic ==
  nil` branch that skips the entire body — a second function wearing the first one's name. They
  share the clamping and visibility helpers instead.

  ## Options

    - `:limit` -- top-K, clamped to `1..#{@max_relevance_page_size}` exactly like
      `progressive_index/3`, so an explicit override cannot flood context either.
    - `:since` -- count only accesses at/after this `DateTime`. Defaults to the last
      #{@heat_default_window_days} days and is CLAMPED to at most #{@heat_max_window_days}
      days of lookback, so the request-path aggregate stays bounded either way; pass an older
      `DateTime` to widen it deliberately and read `meta.heat_window` for what you got. An
      explicit `:since` is served VERBATIM (#572); only the SYSTEM-derived bounds (the default
      lookback and the ceiling) are anchored at the start of today, which is what makes a
      default refresh byte-identical. A FUTURE `:since` is clamped to today's start.
    - `:category` -- restrict to one category atom.
    - `:visibility_agent_id` -- the calling agent's id (#163). An index is exactly the surface
      where a leak is easy and invisible, because a stub looks innocuous and nobody reads an
      index the way they read a body. Applied as a WHERE on the joined article, so another
      agent's `private`/`owner` memory can never appear even as a title.

  Returns `{:ok, %{results: [stub], meta: map}}`. Each stub carries `id`, `title`, `category`,
  `heat` and a one-line `summary`; `meta` states the character budget of the STUB ARRAY
  (derived from the EFFECTIVE top-K and enforced, since every stub field is capped, and
  exclusive of `meta`'s own fixed block), which access types were
  counted, whether the list was `truncated`, and — per the Tencent navigation-index property —
  WHICH TOOL to call with WHICH PARAMETER to drill, so the payload is self-describing rather
  than relying on the reader to infer that an id is actionable.
  """
  @spec heat_index(Ecto.UUID.t(), keyword()) :: {:ok, map()}
  def heat_index(tenant_id, opts \\ []) when is_binary(tenant_id) do
    top_k =
      opts |> Keyword.get(:limit, progressive_top_k()) |> max(1) |> min(@max_relevance_page_size)

    vis = Keyword.get(opts, :visibility_agent_id)
    since = opts |> Keyword.get(:since) |> heat_since()
    category = Keyword.get(opts, :category)

    # `top_k + 1` look-ahead: it costs one row and turns "you got exactly the cap" into a
    # stated `truncated`, which `progressive_index/3` already carries and a cacheable index
    # needs more, since nothing else in the payload signals the omission.
    # ONE gate slot across BOTH round trips (#567). The projection runs on `AdminRepo` — a
    # system canonical's NULL `tenant_id` cannot satisfy the heavy-read guard — which is a
    # 3-connection pool shared with custody writes. Acquiring per query released the slot
    # between them, so the aggregate was admitted and the projection then competed with the
    # request path ungated, on the smallest pool in the system, from a per-turn endpoint.
    # Nested `HeavyRead.all/3` for this tenant reuses this slot rather than taking a second.
    #
    # The NODE-level admin-pool bound is SPLIT in two, because the two phases spend different
    # pools. `heat_precheck!/2` is a non-reserving CHECK before anything runs, so a sustained
    # node-wide shed still costs nothing; the counted permit is held around the PROJECTION
    # only, the one phase that checks out an `AdminRepo` connection. Holding it across the
    # aggregate as well capped node-wide heat concurrency at the admin pool's bound while the
    # aggregate was running entirely on `HeavyReadRepo`'s own (larger, separately gated) pool —
    # shedding a tenant against a resource no in-flight call was using.
    admin_cap = heat_node_cap(DbCapacity.runtime_pool_sizes().admin_repo)
    heat_precheck!(tenant_id, admin_cap)

    {counted, stubs} =
      HeavyRead.with_slot(tenant_id, HeavyRead.opts(:heat_index), fn ->
        counted =
          tenant_id
          |> heat_counts_query(top_k + 1, since, category, vis)
          |> then(&HeavyRead.all(tenant_id, &1, HeavyRead.opts(:heat_index)))

        stubs =
          with_heat_admission(tenant_id, admin_cap, fn ->
            heat_stubs(tenant_id, Enum.take(counted, top_k), category, vis)
          end)

        {counted, stubs}
      end)

    ranked = Enum.take(counted, top_k)

    {:ok,
     %{
       results: stubs,
       meta: %{
         top_k: top_k,
         returned: length(stubs),
         # A ranked id that no longer resolves (archived, unpublished or deleted between the
         # aggregate and the projection — separate connections, no shared transaction) is
         # dropped, which would otherwise make a SHORT list indistinguishable from an
         # exhausted one. `truncated` is about the cap; this is about the drop.
         unresolved: length(ranked) - length(stubs),
         truncated: length(counted) > top_k,
         # A STATED budget, not an implied one: the caller is expected to paste this into a
         # cached prefix, so it needs to know the cost before it does. Derived from the
         # effective top-K (not the cap), so `limit: 5` does not advertise 100 stubs' worth.
         char_budget: heat_array_budget(top_k),
         # The WHOLE encoded array, not the sum of its stubs (#572). Summing per-stub sizes
         # omitted the framing the caller actually receives — the two brackets and the N-1
         # commas — so the number advertised as an ENFORCED budget was under by N+1 on every
         # response, and `char_budget` had the same hole. Encoding the array measures what
         # goes on the wire, with no framing constant to keep in sync.
         chars: stubs |> Jason.encode!() |> byte_size(),
         heat_window: DateTime.to_iso8601(since),
         counted_access_types: @heat_read_access_types,
         # The read instruction rides IN the payload (#554): an index that lists ids without
         # saying they are actionable gets read as prose.
         #
         # The note's heat-neutrality claim is now unconditional in FACT, not just in wording
         # (#572). It previously read as absolute while being false for the system canonicals
         # the same payload lists — their drill was counted — and nothing marked which stubs
         # those were, so a caller had no way to tell which half the sentence applied to.
         drill: %{
           tool: "knowledge_progressive_drill",
           parameter: "article_id",
           note:
             "Pass a listed id to read the full article; that read adds no heat to any article, tenant-owned or system canonical, so this index never feeds the ranking that surfaced the stub. knowledge_get opens the same ids and DOES count as a read. Ordering is distinct readers within meta.heat_window, not relevance to any query."
         }
       }
     }}
  end

  @doc "The default heat window, in days. Single source for the API description (#554)."
  @spec heat_default_window_days() :: pos_integer()
  def heat_default_window_days, do: @heat_default_window_days

  @doc "The maximum heat lookback, in days; an older `:since` is clamped to it."
  @spec heat_max_window_days() :: pos_integer()
  def heat_max_window_days, do: @heat_max_window_days

  # SNAPPED TO A UTC DAY BOUNDARY, and the same snapped value is both the aggregate cutoff and
  # the echoed `meta.heat_window` (#567). The window was `utc_now() - 90d` at microsecond
  # precision, so no two calls shared a cutoff and `meta.heat_window` differed on every
  # request — which defeats the one property this surface is built for. A caller is expected
  # to paste this index into a CACHED PREFIX, and a prefix that differs by a microsecond field
  # is a cache miss every time, so the route advertised cacheability while guaranteeing the
  # opposite. Day granularity is the coarsest boundary that still honours a `:since`, and it
  # makes the whole payload byte-identical between refreshes when nothing was read.
  #
  # FLOORED at `@heat_max_window_days` — without it the unbounded all-time scan the default
  # exists to prevent is one query parameter away.
  #
  # A caller's explicit `:since` is used VERBATIM (#572). It used to be rounded UP to the next
  # past day boundary, on the reasoning that flooring would silently WIDEN a window the caller
  # narrowed — true, but the fix inherited the same defect mirrored: ceiling silently NARROWED
  # it instead, dropping up to 24h of reads the caller explicitly asked for, and the guarding
  # test could not see it because it only asserted that reads BEFORE `:since` were excluded.
  # Neither rounding is honest when the exact value is available and costs nothing.
  #
  # The cacheability the snap protects belongs to the SYSTEM-derived bounds, and only there:
  # a caller passing an explicit timestamp is passing a per-call value, so there is no
  # byte-identical prefix to preserve — as the old comment already conceded for the
  # inside-today case, without following the concession to its conclusion. `meta.heat_window`
  # echoes whatever was served either way, so a verbatim value stays self-describing.
  #
  # The SYSTEM-derived bounds (the default lookback and the `@heat_max_window_days` ceiling)
  # are anchored at the START of today instead, so they serve the whole number of days the
  # route advertises — ceiling them served one day less than the constants the API description
  # is generated from — and stay byte-identical all day, which is what makes the payload
  # cacheable. Only a FUTURE `:since` is repaired downward, to today's start: it is degenerate
  # (200 + empty list + a window that has not happened yet reads as "the corpus is empty", the
  # exact misreading this route exists to prevent), and clamping rather than 400-ing matches
  # what the lower bound already does — `meta.heat_window` says what was actually served.
  defp heat_since(since) do
    now = DateTime.utc_now()
    today = floor_to_utc_day(now)

    since
    |> case do
      nil -> DateTime.add(today, -@heat_default_window_days, :day)
      %DateTime{} = given -> heat_snap(given, now, today)
    end
    |> at_least(DateTime.add(today, -@heat_max_window_days, :day))
  end

  # Only a FUTURE `:since` is repaired, down to today's start: it is degenerate (200 + empty
  # list + a window that has not happened yet reads as "the corpus is empty", the exact
  # misreading this route exists to prevent), and clamping rather than 400-ing matches what
  # the lower bound already does.
  defp heat_snap(given, now, today) do
    if DateTime.compare(given, now) == :gt, do: today, else: given
  end

  defp at_least(dt, lower),
    do: if(DateTime.compare(dt, lower) == :lt, do: lower, else: dt)

  defp floor_to_utc_day(%DateTime{} = dt),
    do: DateTime.new!(DateTime.to_date(dt), ~T[00:00:00], "Etc/UTC")

  # Aggregate over the EVENTS alone: no join to `articles`, so no article column (least of all
  # the unbounded body) enters the group key, and the article-side predicates ride in a bounded
  # `IN (subquery)` id set. `HeavyRead.guard!/2` does NOT walk a subquery that appears in a
  # WHERE expression (only `from`/join sources), so the `or a.scope == :system` disjunction
  # inside it is reasoned about HERE rather than proved: the rows being aggregated are
  # conjunctively tenant-scoped events, so the id set can only NARROW what this tenant already
  # generated. Same shape `apply_search_filters_on_article/4` uses.
  #
  # The `IN (subquery)` is NOT an unbounded corpus scan, and this was MEASURED rather than
  # argued (#567). `EXPLAIN (ANALYZE, BUFFERS)` on production, tenant `0abd22c2` with 79,025
  # published articles: the planner never enumerates the corpus. It drives from
  # `article_access_events_tenant_type_time_idx` (the windowed, tenant+access_type-scoped
  # event set) and resolves the subquery as a Memoized `articles_pkey` probe per DISTINCT
  # article seen in the window — 2,035 event rows, 1,256 probes, 779 memoize hits, 11.3 ms at
  # the 90-day default and 6.9 ms at the 365-day ceiling with a category filter. Cost scales
  # with articles READ in the window, not with the corpus.
  #
  # So do NOT "fix" this by aggregating first and filtering the top-K afterwards. Besides
  # being unnecessary, it inverts the meaning: the predicates would decide which articles
  # SURVIVE the ranking instead of which COMPETE for it, so a category-filtered call would
  # rank the whole corpus, take `top_k + 1`, and keep only the few that happen to match.
  #
  # The JOINED shape was then measured too, on the same production tenant: 11.9 ms, against
  # 11.3 ms without the join. The events/articles side plans identically (Nested Loop +
  # Memoized `articles_pkey`); the join is a Hash Left Join whose hash is the tenant's ENTIRE
  # key set — 10 rows, 0.02 ms to build — because `api_keys` is per-tenant tiny, and the
  # `count(DISTINCT ...)` turns the HashAggregate into a Sort + GroupAggregate over the 2,001
  # matched rows (220 kB quicksort). Still no supporting index needed, now as a plan rather
  # than an argument. Note the mechanism, since the obvious guess is wrong: this is NOT a
  # per-event primary-key probe on `api_keys`, so its cost tracks the tenant's KEY COUNT, not
  # its event count. A tenant that accumulates keys without bound is the shape that would
  # change this plan — re-measure there, not on event volume.
  #
  # A READER is `coalesce(k.agent_id, e.api_key_id)`, not the key row (#567 round 2). v2 mints
  # a fresh ephemeral key per dispatch, so distinct api_key_id counted DISPATCHES: an agent
  # re-dispatching N times voted N times, which is the pinning the distinct count exists to
  # prevent. LEFT join so a key this tenant cannot see (revoked-and-gone, superadmin, another
  # tenant) falls back to the key id — the old behaviour as a floor, never a dropped event.
  defp heat_counts_query(tenant_id, limit, since, category, vis) do
    from(e in ArticleAccessEvent,
      left_join: k in ApiKey,
      on: k.id == e.api_key_id and k.tenant_id == ^tenant_id,
      where: e.tenant_id == ^tenant_id,
      where: e.access_type in @heat_read_access_types,
      where: e.accessed_at >= ^since,
      where: e.article_id in subquery(heat_article_ids(tenant_id, category, vis)),
      group_by: e.article_id,
      # Readership is a SMALL integer (fleet size), so ties are the common case — under a
      # fleet sharing one key EVERY article ties at 1, and ordering straight to
      # `asc: e.article_id` made this index UUID order wearing heat's name. The tie-break is
      # DISTINCT READ DAYS: raw `count(e.id)` here re-opened the pinning the distinct count
      # exists to close, since inside a tie the ranking WOULD BE the row counter a loop
      # inflates. A day counts once however many times the loop runs, so the tie degrades to
      # sustained use rather than to traffic; the id still keeps the order TOTAL, so a page is
      # stable across calls — an index that reshuffles on every refresh cannot be cached,
      # which is the whole point of this surface.
      #
      # The day is cut in UTC EXPLICITLY: a bare `::date` cast resolves in the connection's
      # `TimeZone` GUC, so on a backend whose session timezone is not UTC the tie-break counted
      # days on a boundary the UTC-day-snapped `meta.heat_window` does not use — the payload
      # would state one window and rank on another.
      order_by: [
        desc: count(fragment("coalesce(?, ?)", k.agent_id, e.api_key_id), :distinct),
        desc: count(fragment("((? at time zone 'UTC'))::date", e.accessed_at), :distinct),
        asc: e.article_id
      ],
      limit: ^limit,
      select: %{
        article_id: e.article_id,
        heat: count(fragment("coalesce(?, ?)", k.agent_id, e.api_key_id), :distinct)
      }
    )
  end

  defp heat_article_ids(tenant_id, category, vis) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id or a.scope == :system,
      where: a.status == :published,
      # Machine-generated source hubs (US-42.1) are navigation, not knowledge, and are
      # excluded from the heat ranking. A hub exists to be traversed — every article from
      # its source points at it — so it accumulates readers as a FUNCTION of how many
      # siblings the harvest gave it, not of whether anyone found it useful. Letting that
      # rank would put the biggest imported book at the top of an index designed to be
      # pasted into a cached prefix, which is the same failure #567/#569/#572 each fixed
      # once: heat must not rank on a signal heat's own plumbing produces.
      where: fragment("coalesce(? ->> 'hub_kind', '') <> 'source'", a.metadata),
      select: a.id
    )
    |> heat_filter_category(category)
    |> maybe_filter_by_visibility(vis)
  end

  defp heat_filter_category(query, nil), do: query
  defp heat_filter_category(query, category), do: where(query, [a], a.category == ^category)

  # Bounded projection for the ≤top_k ranked ids only, on `AdminRepo` for the same reason
  # `hydrate_semantic_pool/6` is: a system canonical's NULL `tenant_id` cannot satisfy the
  # heavy-read guard. It runs INSIDE the `with_slot/3` admission `heat_index/2` holds, so it
  # carries an EXPLICIT short `:timeout`: this tenant's heavy-read slot is held for its whole
  # duration on the 3-connection admin pool that custody writes share, and at the 15s Ecto
  # default admin-pool contention would convert into shed (429) heavy reads for that tenant on
  # unrelated endpoints. The work itself is bounded — a primary-key lookup of at most
  # `@max_relevance_page_size` ids with `left(body, ...)` clipping the body, i.e. no scan,
  # unlike the aggregate it follows. `status`, visibility AND `category` are all re-applied
  # rather than trusted from the ranking query: the two run on separate connections, so an
  # article can be unpublished — or RE-CATEGORISED — in between, and this is the query that
  # actually reads a title. Category was the one predicate omitted here, so a
  # `category:`-filtered index could return a stub that had since moved out of that category;
  # every filter the aggregate applies must be re-applied here or the invariant is only
  # partial, which is worse than not claiming it.
  # The budget for a FULL page: `n` stubs at the per-stub cap, plus the JSON array framing
  # `chars` now measures — `[`, `]`, and the `n - 1` commas between stubs. An empty page
  # encodes as `[]`, hence the floor of 2.
  defp heat_array_budget(0), do: 2
  defp heat_array_budget(n), do: n * @heat_stub_char_cap + 2 + (n - 1)

  # NODE-level admission on top of the per-tenant one. `HeavyRead.with_slot/3` bounds how many
  # of THIS tenant's heat reads are in flight; nothing bounded the AGGREGATE across tenants.
  # `TenantGate` counts per key, so N tenants each admitted at their own cap queue up to N
  # concurrent checkouts on `AdminRepo` — a 3-connection pool (`ADMIN_POOL_SIZE || "3"`,
  # config/runtime.exs) that custody writes and the per-request auth SELECT also use. The
  # per-read `:timeout` bounds how long each waiter blocks, not how many waiters there are.
  #
  # The PERMIT covers the projection only — the phase that checks out an admin connection —
  # while `heat_precheck!/2` sheds before the aggregate, so a shed still costs none of the work
  # it is shedding.
  #
  # TWO keys, one permit each. The GLOBAL key is a FIXED string, not a tenant id — that is what
  # makes the count node-wide (`TenantGate.acquire/3` only guards `is_binary/1`, so a non-UUID
  # key is legal and cannot collide with a real tenant). The PER-TENANT key keeps a node permit
  # reachable by a NEIGHBOUR, mirroring the `pool - 1` ceiling `TenantGate.clamp_cap/1` already
  # uses: the node cap equals one tenant's OWN heat ceiling, so without a sub-cap a single
  # looping tenant could hold every node permit and 429 every other tenant on the node.
  @heat_admin_gate_key "knowledge.heat_stub_projection"
  @heat_shed_log_window_ms 60_000
  @admin_pool_default 3

  @doc false
  # The node cap as a pure function of the admin pool, so the BOUND itself is testable and not
  # merely the gate's existence. `pool - 1` so heat can never take the LAST admin connection
  # out from under a custody write — including at a pool of 1, where that leaves nothing to
  # admit and the endpoint is off until an operator raises `ADMIN_POOL_SIZE` (said once, by
  # name, in `heat_log_shed/2`).
  #
  # A pool of 0 is NOT a pool of zero connections — `DbCapacity.pool_size/1` reports an
  # UNREADABLE repo config as 0. A limiter that cannot read its own bound must fail OPEN
  # (`TenantGate` moduledoc, AC-37.5.5), so it falls back to the documented `ADMIN_POOL_SIZE`
  # default rather than turning a config read into a permanent outage of the endpoint.
  @spec heat_node_cap(non_neg_integer()) :: non_neg_integer()
  def heat_node_cap(0), do: @admin_pool_default - 1
  def heat_node_cap(admin_pool) when is_integer(admin_pool), do: max(0, admin_pool - 1)

  @doc false
  # The per-tenant sub-cap. `cap - 1` keeps a node permit reachable by a neighbour, but ONLY
  # where that leaves a tenant more than one: at the cap production actually reaches (pool 3 ->
  # cap 2) `cap - 1` was 1, which made a per-turn endpoint serial per tenant — a fleet's second
  # concurrent call 429'd on an idle node, which reads as pool saturation and is not.
  @spec heat_tenant_cap(non_neg_integer()) :: non_neg_integer()
  def heat_tenant_cap(cap) when is_integer(cap), do: min(cap, max(2, cap - 1))

  defp heat_gate_keys(tenant_id),
    do: [@heat_admin_gate_key, @heat_admin_gate_key <> ":" <> tenant_id]

  # A NON-RESERVING check, ahead of the aggregate: deciding admission after the group-by meant
  # every shed request first paid that history-growing scan, and a shed that costs the work it
  # is shedding sheds nothing. It reserves nothing, so a race can let one extra caller through
  # to the real acquire below — the counted permit is what enforces the cap, this only keeps
  # the SUSTAINED shed cheap.
  defp heat_precheck!(tenant_id, cap) do
    [global, per_tenant] = heat_gate_keys(tenant_id)

    if TenantGate.count(global) >= cap or TenantGate.count(per_tenant) >= heat_tenant_cap(cap),
      do: heat_shed!(tenant_id, cap)
  end

  defp with_heat_admission(tenant_id, cap, fun) do
    reclaimer = heat_permit_reclaimer(heat_gate_keys(tenant_id), cap)
    ref = Process.monitor(reclaimer)

    receive do
      {:heat_permit, ^reclaimer, :ok} ->
        Process.demonitor(ref, [:flush])

        try do
          fun.()
        after
          heat_await_release(reclaimer)
        end

      {:heat_permit, ^reclaimer, :shed} ->
        Process.demonitor(ref, [:flush])
        heat_shed!(tenant_id, cap)

      # The reclaimer holds no permit it has not told us about, so its death before a reply is
      # a shed, never a hang.
      {:DOWN, ^ref, :process, ^reclaimer, _reason} ->
        heat_shed!(tenant_id, cap)
    end
  end

  defp heat_shed!(tenant_id, cap) do
    heat_log_shed(tenant_id, cap)

    raise HeavyRead.OverloadedError,
      tenant_id: tenant_id,
      message: "heat index shed at the node-level admin-pool bound"
  end

  @doc false
  # Public (`@doc false`) so the NODE-wide bound is drivable in a test without saturating the
  # VM-wide production counter every parallel async read shares.
  @spec heat_acquire([binary()], non_neg_integer()) :: :ok | :shed
  def heat_acquire(_keys, cap) when cap < 1, do: :shed

  def heat_acquire([global, per_tenant], cap) do
    case TenantGate.acquire(global, 1, cap) do
      :ok -> heat_acquire_tenant(global, per_tenant, heat_tenant_cap(cap))
      {:error, :heavy_read_overloaded} -> :shed
    end
  end

  defp heat_acquire_tenant(global, per_tenant, tenant_cap) do
    case TenantGate.acquire(per_tenant, 1, tenant_cap) do
      :ok ->
        :ok

      {:error, :heavy_read_overloaded} ->
        TenantGate.release(global, 1)
        :shed
    end
  end

  # A permit must not outlive the process holding it. `try/after` does not run when a process
  # is KILLED (a brutal shutdown drain, a `max_heap_size` kill), and `TenantGate` never sweeps
  # or reaps — a limitation its moduledoc accepts for a PER-TENANT counter, where the drift is
  # one tenant's. On a node-wide key capped at 2 the same drift is permanent and fleet-wide:
  # two kills over a node's life would shed heat_index for every tenant on it, forever.
  #
  # So an unlinked reclaimer MONITORS the holder and performs the release itself — on `:done`
  # or on `:DOWN`, whichever arrives first, so the release is exactly-once by construction.
  # That is the reclaim guarantee `Knowledge.ExportConcurrency` gets from its GenServer's
  # monitors, without standing up a second registry for a permit held across one bounded call.
  #
  # The reclaimer also ACQUIRES, after installing the monitor, and reports the outcome back.
  # Acquiring in the caller and spawning afterwards left a window — microseconds, but the
  # failure in it is the permanent fleet-wide one this exists to eliminate — where a brutal
  # kill landed on a holder whose permits no monitor covered yet. Now no permit exists that is
  # not already covered.
  #
  # Public (`@doc false`) for the same reason `heat_projection_exit/2` is: the `:DOWN` path is
  # the one this exists for, and it cannot be driven through `heat_index/2` deterministically.
  @doc false
  @spec heat_permit_reclaimer([binary()], non_neg_integer()) :: pid()
  def heat_permit_reclaimer(keys, cap) when is_list(keys) do
    holder = self()

    spawn(fn ->
      ref = Process.monitor(holder)

      case heat_acquire(keys, cap) do
        :shed ->
          send(holder, {:heat_permit, self(), :shed})

        :ok ->
          send(holder, {:heat_permit, self(), :ok})
          heat_hold_permit(holder, ref, keys)
      end
    end)
  end

  defp heat_hold_permit(holder, ref, keys) do
    caller =
      receive do
        {:done, ^holder} ->
          Process.demonitor(ref, [:flush])
          holder

        {:DOWN, ^ref, :process, ^holder, _reason} ->
          nil
      end

    Enum.each(keys, &TenantGate.release(&1, 1))
    if caller, do: send(caller, {:released, self()})
  end

  # The normal path WAITS for the release rather than firing and forgetting it: the per-tenant
  # node permit is a small integer, so a caller that returned before its own permit came back
  # would eat into its own next sequential call. The monitor makes the wait terminate either
  # way — the reclaimer replies or it dies.
  defp heat_await_release(reclaimer) do
    ref = Process.monitor(reclaimer)
    send(reclaimer, {:done, self()})

    receive do
      {:released, ^reclaimer} -> Process.demonitor(ref, [:flush])
      {:DOWN, ^ref, :process, ^reclaimer, _reason} -> :ok
    end
  end

  # ONE line per window, not one per shed. heat_index is a per-turn endpoint, so a sustained
  # node-wide shed would otherwise put one warning per request per tenant into the incident the
  # warning exists to describe — the shape `HeavyRead.maybe_log_inconclusive/2` was written to
  # prevent. `:never` rather than a `0` default: `System.monotonic_time/1` starts at a large
  # NEGATIVE value, so a `0` default would not throttle the line, it would delete it.
  #
  # The line deliberately does NOT wear the per-tenant label. This bound is node-wide, so
  # `OverloadedError`'s default message ("the per-tenant in-flight capacity for this tenant")
  # would attribute saturation of the SHARED admin pool to whichever tenant happened to arrive
  # last — the systemic-fault-dressed-as-one-noisy-tenant confusion the rescue arms below exist
  # to prevent. The client-facing 429 body comes from `LoopctlWeb.ErrorJSON`.
  #
  # A cap below 1 is NOT load, so it is not throttled into that window and does not wear the
  # "shed" spelling: `ADMIN_POOL_SIZE=1` leaves no admin connection heat may take, so every
  # request 429s until an operator changes the value — a permanent CONFIG state that a
  # once-a-minute saturation line would hide behind the very error it explains. Said once per
  # node, guaranteed, naming the variable to change.
  defp heat_log_shed(tenant_id, cap) when cap < 1 do
    key = {__MODULE__, :heat_node_gate_disabled_warned}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Logger.warning(
        "heat_index: admin_pool_too_small ADMIN_POOL_SIZE must be >= 2 for the heat index; " <>
          "every request sheds tenant_id=#{tenant_id} cap=#{cap}"
      )
    end

    :ok
  end

  defp heat_log_shed(tenant_id, cap) do
    key = {__MODULE__, :heat_node_gate_shed_warned}
    deadline = :persistent_term.get(key, :never)
    now = System.monotonic_time(:millisecond)

    if deadline == :never or now >= deadline do
      :persistent_term.put(key, now + @heat_shed_log_window_ms)
      Logger.warning("heat_index: admin_pool_node_gate_shed tenant_id=#{tenant_id} cap=#{cap}")
    end

    :ok
  end

  defp heat_stubs(_tenant_id, [], _category, _vis), do: []

  defp heat_stubs(tenant_id, rows, category, vis) do
    ids = Enum.map(rows, & &1.article_id)

    by_id =
      from(a in Article,
        where: a.id in ^ids,
        where: a.tenant_id == ^tenant_id or a.scope == :system,
        where: a.status == :published,
        select: %{
          id: a.id,
          title: a.title,
          category: a.category,
          summary_source: fragment("left(?, ?)", a.body, ^(@heat_summary_chars * 8))
        }
      )
      |> heat_filter_category(category)
      |> maybe_filter_by_visibility(vis)
      |> heat_stub_projection(tenant_id)
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(rows, fn %{article_id: id, heat: heat} ->
      case Map.fetch(by_id, id) do
        {:ok, article} -> [heat_stub(article, heat)]
        :error -> []
      end
    end)
  end

  # The bounded wait is a SHED, not a 500. `@heat_stub_timeout_ms` bounds the projection so
  # admin-pool contention cannot hold this tenant's heavy-read slot for 15s — but the fault it
  # raises (a checkout/query deadline, which is exit-shaped as often as it is raised) escaped
  # `heat_index/2`'s `{:ok, _}` contract and the controller's match, so the SAME contention
  # that used to answer slowly now answered 500 on a per-turn endpoint whose declared
  # degradation is a 429. Re-raise it as the gate's own overload, which `HeavyReadOverloadHandler`
  # already maps to that 429 — no new error shape, and nothing of the fault is interpolated.
  #
  # It is LOGGED first, under a stable tag per fault class. Re-raising silently made this 429
  # indistinguishable from ordinary gate shedding, so saturation of the 3-connection admin pool
  # that custody writes share — a systemic fault — looked like one tenant reading too much, and
  # nothing in the logs said otherwise. The `:exit` clause also catches exits that are not pool
  # pressure at all (a shutdown, a sandbox ownership exit), which is exactly why its reason has
  # to reach the log rather than be discarded into an overload label.
  defp heat_stub_projection(query, tenant_id) do
    AdminRepo.all(query, timeout: @heat_stub_timeout_ms)
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error] ->
      heat_projection_raise(tenant_id, e, __STACKTRACE__)
  catch
    :exit, reason -> heat_projection_exit(tenant_id, reason)
  end

  @doc false
  # `Exception.message/1` on either rescued module carries the fault VERBATIM — a
  # ConnectionError names the backend host and port, a Postgrex.Error carries the failing
  # statement and its bound parameters. #562 sanitised exactly this one module over
  # (`HeavyRead.probe_failure_tag/1`); the heat path was written after and did not inherit it.
  # Only `tenant_id`, the exception MODULE and the SQLSTATE are interpolated — the code is a
  # closed Postgrex vocabulary and names nothing about the statement.
  #
  # `Postgrex.Error` is rescued alongside because the same saturation arrives from the SERVER
  # as often as from the pool — and an unrescued one escaped `heat_index/2`'s `{:ok, _}`
  # contract as a 500 on a per-turn endpoint whose declared degradation is 429. But only a
  # SATURATION fault degrades: both classes also carry permanent, deterministic faults (a
  # column a not-yet-run migration adds; a rotated credential), so rescuing them wholesale
  # dressed those as transient load shedding — the caller retries forever and the operator
  # sees ordinary gate shedding. Same conservatism `heat_projection_exit/2` applies on the
  # exit side; anything unplaceable is re-raised to surface as the 500/503 it is.
  #
  # It LOGS BEFORE it branches, like the exit side: the fault that must NOT wear the overload
  # label is exactly the one whose class has to reach the log rather than be re-raised in
  # silence, leaving nothing to say the admin-pool projection — not the aggregate — failed.
  #
  # `:raise`, not `exit:` — `ExitClass`'s kind prefix exists because a dead pool and a fault
  # raised out of a live one are different investigations, and both arms of this guard
  # reporting `exit:` collapsed exactly that distinction. The tag is bounded by the rescue's
  # own two-module clause list.
  #
  # Public (`@doc false`) purely as a test seam, for the reason `heat_projection_exit/2` is:
  # a real query cannot be made to raise a chosen SQLSTATE, so left inline BOTH arms would be
  # guards nothing ever exercises.
  @spec heat_projection_raise(Ecto.UUID.t(), Exception.t(), Exception.stacktrace()) :: no_return()
  def heat_projection_raise(tenant_id, e, stacktrace) do
    Logger.warning(
      "heat_stub_projection: admin_pool_read_failed tenant_id=#{tenant_id} " <>
        "error_class=#{ExitClass.classify(:raise, e)} sqlstate=#{heat_sqlstate(e)}"
    )

    if heat_saturation?(e) do
      reraise Loopctl.HeavyRead.OverloadedError, [tenant_id: tenant_id], stacktrace
    else
      reraise e, stacktrace
    end
  end

  # A pool-side failure — ANY `DBConnection.ConnectionError`, whatever its `:reason` — is
  # treated as saturation and shed as a 429. That is deliberate and the paragraph below gives
  # the measurement behind it. (An earlier version of this comment claimed the opposite: that
  # only `:queue_timeout` sheds and `reason: :error` re-raises into a 503. It described a
  # narrowing that was made once, measured to be wrong, and reverted — the code never matched
  # it, and the test at heat_index_test.exs asserts all three of `:queue_timeout`, `:closed`
  # and `:error` shed.)
  #
  # A SERVER-side fault is only saturation on `@heat_saturation_sqlstates`. A `Postgrex.Error`
  # carrying no SQLSTATE at all is a client-side encode/decode fault — a code bug, never load.
  #
  # The two arms are ASYMMETRIC on purpose, and narrowing this one to match its Postgrex twin
  # is a regression that has already been made once. A `Postgrex.Error` carries a precise,
  # machine-readable SQLSTATE, so splitting load from a permanent fault is exact. A
  # `DBConnection.ConnectionError` carries no such thing: its `:reason` is documented as
  # `:error | :queue_timeout`, `:error` is the DEFAULT that a connect failure and a deadline
  # share, and Postgrex sets a third value the typespec does not even list. MEASURED, by
  # driving `AdminRepo.query!(…, timeout: 30)` past a `pg_sleep`: the timeout THIS path exists
  # to impose (`@heat_stub_timeout_ms`) surfaces as `reason: :closed`, message "tcp send:
  # closed (the connection was closed by the pool, possibly due to a timeout …)". Matching
  # `:queue_timeout` alone therefore misses the dominant, BY-DESIGN case and answers 500 where
  # the endpoint documents 429.
  #
  # So this arm follows the shape the code deliberately produces rather than guessing from a
  # field that cannot carry the distinction. A connect/auth failure being shed as 429 here is
  # the accepted cost: it is rarer, and over-shedding a read-only index is a smaller error
  # than 500-ing the bounded wait this whole function exists to bound.
  defp heat_saturation?(%DBConnection.ConnectionError{}), do: true

  defp heat_saturation?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in @heat_saturation_sqlstates

  defp heat_saturation?(_e), do: false

  # The NUMERIC SQLSTATE (`"53300"`), which is what `LoopctlWeb.DBError.sqlstate/1` reads and
  # `LoopctlWeb.DBErrorLogger` emits under this key on every other DB path. `postgres.code` is
  # Postgrex's atom NAME, so logging that would put two value spaces under one field and miss
  # every operator alert keyed on the number.
  defp heat_sqlstate(%Postgrex.Error{postgres: %{pg_code: pg_code}}) when is_binary(pg_code),
    do: pg_code

  defp heat_sqlstate(_e), do: "none"

  @doc false
  # Only a DEMONSTRABLE pool exit becomes an overload. The blanket clause translated EVERY
  # exit into a 429 — a node `:shutdown` during a deploy, a sandbox ownership exit in tests,
  # a `{:timeout, {GenServer, :call, _}}` from something that is not the pool — so an
  # unrelated fault was reported to the caller as "you are reading too much" and to the
  # operator as ordinary gate shedding. `ExitClass.pool_exit?/1` is deliberately conservative
  # (what it cannot place is NOT a pool exit), so anything unplaceable is re-exited untouched
  # to whoever actually owns it. Same call `HeavyRead` makes.
  #
  # Public (`@doc false`) purely as a test seam: the branch that must NOT raise an overload is
  # unreachable from a real query, so left inline it would be a guard nothing ever exercises.
  @spec heat_projection_exit(Ecto.UUID.t(), term()) :: no_return()
  def heat_projection_exit(tenant_id, reason) do
    Logger.warning(
      "heat_stub_projection: admin_pool_exit tenant_id=#{tenant_id} " <>
        "error_class=#{ExitClass.classify(:exit, reason)} " <>
        "pool=#{ExitClass.pool_exit?(reason)}"
    )

    if ExitClass.pool_exit?(reason) do
      raise Loopctl.HeavyRead.OverloadedError, tenant_id: tenant_id
    else
      exit(reason)
    end
  end

  defp heat_stub(article, heat) do
    %{
      id: article.id,
      title: heat_title(article.title),
      category: to_string(article.category),
      heat: heat,
      summary: heat_summary(article.summary_source)
    }
    |> fit_stub_to_cap()
  end

  # `meta.char_budget` is documented as ENFORCED, so it has to be a real bound and not a
  # nominal one (#567). Slicing each field to its own character cap bounds the RAW value, but
  # the caller receives the ENCODED one, and a title carrying quotes, backslashes or control
  # characters encodes longer than it slices. Trim against the encoded length until the stub
  # actually fits: summary first (it is the padding), then title, so a stub whose title alone
  # escapes past the cap still cannot break the budget the caller sized its prefix on.
  defp fit_stub_to_cap(stub) do
    over = heat_stub_chars(stub) - @heat_stub_char_cap

    cond do
      over <= 0 -> stub
      stub.summary != "" -> fit_stub_to_cap(%{stub | summary: shrink_by(stub.summary, over)})
      stub.title != "" -> fit_stub_to_cap(%{stub | title: shrink_by(stub.title, over)})
      # id, category and heat alone; already under the cap by construction.
      true -> stub
    end
  end

  # Drop whole GRAPHEMES from the end until at least `by` BYTES are gone (#572). Now that the
  # overage is measured in bytes, the old `String.length(value) - by` mixed units the other
  # way: for a CJK value one byte of overage removed one grapheme, i.e. up to three bytes, so
  # a summary that was slightly over got shredded — and a large enough overage sliced it to
  # "".
  defp shrink_by(value, by), do: take_bytes(value, max(byte_size(value) - by, 0))

  # Keep at most `max` BYTES, dropping whole GRAPHEMES. Slicing at a byte OFFSET would split a
  # multibyte grapheme and put invalid UTF-8 on the wire, so the walk is per grapheme with a
  # byte target. This is also what makes the per-field caps enforceable in the unit the stub
  # cap is expressed in — `String.slice/3` counted graphemes and blew the byte budget on
  # arrival for any non-Latin script.
  defp take_bytes(value, max) do
    value
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, size} ->
      next = size + byte_size(grapheme)
      if next > max, do: {:halt, {acc, size}}, else: {:cont, {[grapheme | acc], next}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp heat_title(nil), do: ""
  defp heat_title(title), do: take_bytes(title, @heat_title_chars)

  # ONE line, always. A body's first paragraph can be arbitrarily long and can contain newlines
  # that would break a line-oriented consumer's parsing of the index.
  defp heat_summary(nil), do: ""

  defp heat_summary(body) do
    body
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> take_bytes(@heat_summary_chars)
  end

  # Measured off the ENCODED stub, which is what actually goes on the wire (#567). Summing
  # `String.length/1` over the RAW fields and adding `@heat_stub_fixed_chars` mixed two units:
  # the fixed constant was measured off the encoded shape (the keys, braces, quotes and
  # commas), while the values were counted unescaped. A title containing a quote, a backslash
  # or a control character encodes longer than it measures, so `meta.chars` under-reported the
  # wire size — and it under-reported it in the UNSAFE direction, for the one number a caller
  # is told to budget a cached prefix against.
  #
  # BYTES, not graphemes (#572). `String.length/1` counts graphemes, so a CJK or emoji title
  # under-reported the wire size by 3-4x — the same unsafe direction, on the same number, one
  # unit down. The budget exists so a caller can size a cached prefix, and every consumer of
  # that number (an HTTP body, a token estimate, a context window) is byte- or codepoint-
  # denominated; nothing downstream counts graphemes. `fit_stub_to_cap/1` enforces through
  # this same function, so the cap moves with it and is now a real byte bound.
  defp heat_stub_chars(stub), do: stub |> Jason.encode!() |> byte_size()

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
  index already surfaces. That fallback now lives in `get_article/3` itself
  (#572), so both read tools resolve the same set and this one is a thin
  access-type wrapper.

  EVERY drill records the uncounted `"drill"`, whichever scope answers, and the type is
  derived from the read PATH rather than from anything the caller says (#569) — a declared
  origin binds only the clients that send it, leaving older releases and raw HTTP calls
  feeding the loop. Making it uniform is #572: while a canonical's drill was counted and a
  tenant article's was not, `heat_index/2` ranked both classes on one number that meant
  different things, so following the documented path raised only the canon.
  """
  @spec progressive_drill(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Article.t()} | {:error, :not_found}
  def progressive_drill(tenant_id, article_id, opts \\ []) do
    # `"drill"` is the UNCOUNTED type (#569): this is the tool `heat_index/2`'s own
    # `meta.drill` names, so counting the hop let being SHOWN produce the rank that showed it.
    #
    # Excluding EVERY drill, not just one from the heat index, is the consistent rule rather
    # than the blunt one: a drill always follows a list THIS SYSTEM just produced (a heat stub
    # or a `progressive_index` stub), so it is list-ORIGINATED by construction — the same
    # property that excludes `"search"` and `"context"`. `knowledge_get` is the only read where
    # the caller names an id without the ranker having just handed it over, which is exactly
    # what "caller-chosen" was always supposed to mean.
    get_article(tenant_id, article_id, Keyword.put(opts, :access_type, "drill"))
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
    * `:scope` — the `Loopctl.Egress.Scope` this call is made on behalf of
      (US-41.4, AC-41.4.2). Defaults to the TENANT-WIDE scope. Supply it (or
      `:project_id`) whenever the caller knows the project, so a project-only
      `local_only` marking is enforced at the provider chokepoint.
    * `:project_id` — shorthand for building the scope from an already-present
      search/ingest filter.
  """
  @spec generate_embedding(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, [float()]} | {:error, term()}
  def generate_embedding(tenant_id, query_string, opts \\ []) when is_binary(tenant_id) do
    try_generate_embedding(tenant_id, query_string, opts)
  end

  # US-41.4 (AC-41.4.2): the egress scope this embedding call is made on behalf of.
  # Endpoint resolution is TENANT-scoped, so the project half narrows only the
  # local_only MARKING — which `Loopctl.Egress.Policy` resolves MOST-RESTRICTIVE-wins
  # (project OR tenant). A caller that knows no project (memories, tenant-wide
  # articles) correctly gets the tenant-wide scope.
  # Carries an already-present `:project_id` search/ingest filter into the egress
  # scope without dragging the rest of the sub-search opts along.
  defp project_id_opt(opts) do
    case Keyword.get(opts, :project_id) do
      nil -> []
      project_id -> [project_id: project_id]
    end
  end

  defp egress_scope(tenant_id, opts) do
    case Keyword.get(opts, :scope) do
      %EgressScope{} = scope -> scope
      _ -> EgressScope.new(tenant_id, Keyword.get(opts, :project_id))
    end
  end

  defp try_generate_embedding(tenant_id, query_string, opts) do
    ensure_circuit_breaker_table()

    if circuit_open?(tenant_id) do
      {:error, :circuit_open}
    else
      timeout = Keyword.get(opts, :timeout, @embedding_yield_ms)

      run_embedding_task(
        tenant_id,
        egress_scope(tenant_id, opts),
        query_string,
        timeout,
        embedding_model_override(tenant_id, opts)
      )
    end
  end

  # US-41.1 AC-41.1.10 — WHICH MODEL this embedding is generated with.
  #
  #   * `:active` (the DEFAULT, i.e. every ordinary caller): the model that produced
  #     the tenant's ACTIVE corpus. `Embeddings.query_model_override/1` returns `nil`
  #     unless the tenant's CONFIGURED model has moved away from that pin — which
  #     happens exactly during a re-embed, when a query vector from the configured
  #     (pending) model would disagree with every stored vector and black out recall
  #     for the whole window. `nil` keeps the client call byte-identical to before.
  #   * `:configured`: the tenant's current setting, pin ignored — the ONE caller is
  #     `ReembedWorker`, whose whole job is to produce vectors at the PENDING model's
  #     dimension.
  #   * a binary: an explicit model (tests / operator tools).
  defp embedding_model_override(tenant_id, opts) do
    case Keyword.get(opts, :embedding_model, :active) do
      :active -> Embeddings.query_model_override(tenant_id)
      :configured -> nil
      model when is_binary(model) -> model
      _ -> nil
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
  defp run_embedding_task(tenant_id, scope, query_string, timeout, model) do
    case embedding_concurrency().acquire(tenant_id) do
      :ok ->
        try do
          run_capped_embedding_task(tenant_id, scope, query_string, timeout, model)
        after
          embedding_concurrency().release(tenant_id)
        end

      {:error, :rate_limited_local} = err ->
        err
    end
  end

  defp run_capped_embedding_task(tenant_id, scope, query_string, timeout, model) do
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
          # `/2` when there is no model override, so the overwhelmingly common path
          # (and every existing client contract) is untouched.
          if is_binary(model) do
            embedding_client().generate_embedding(scope, query_string, model: model)
          else
            embedding_client().generate_embedding(scope, query_string)
          end
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
    * `:scope` / `:project_id` — the egress scope (US-41.4, AC-41.4.2); see
      `generate_embedding/3`.
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

      run_embeddings_task(
        tenant_id,
        egress_scope(tenant_id, opts),
        texts,
        timeout,
        embedding_model_override(tenant_id, opts)
      )
    end
  end

  # Mirrors `run_embedding_task/3`: ONE concurrency slot for the WHOLE batch
  # (US-37.2 — a batch is one outbound call, so it charges one slot), released in an
  # `after`. Over the cap → `{:error, :rate_limited_local}` (worker snoozes).
  defp run_embeddings_task(tenant_id, scope, texts, timeout, model) do
    case embedding_concurrency().acquire(tenant_id) do
      :ok ->
        try do
          run_capped_embeddings_task(tenant_id, scope, texts, timeout, model)
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
  defp run_capped_embeddings_task(tenant_id, scope, texts, timeout, model) do
    started_ms = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(Loopctl.Knowledge.EmbeddingTaskSupervisor, fn ->
        try do
          if is_binary(model) do
            embedding_client().generate_embeddings(scope, texts, model: model)
          else
            embedding_client().generate_embeddings(scope, texts)
          end
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
  # US-41.4 (AC-41.4.6): a fail-CLOSED egress refusal is a PERMANENT LOCAL
  # CONFIGURATION decision — the scope is `local_only` and the resolved endpoint is
  # not local — not a provider failure. No request was ever issued. Counting it
  # would open the per-tenant breaker (degrading every path for that tenant) and
  # emit the fleet-wide `[:loopctl, :llm, :provider_error]` storm signal for a
  # deliberate configuration state, exactly the failure `:rate_limited_local` was
  # exempted for above. The replacement operator signal is the dedicated
  # `[:loopctl, :egress, :blocked]` counter, so a tenant silently non-functional
  # since an enable is still visible on the dashboards.
  defp breaker_countable?(:egress_blocked), do: false
  # `:pin_stale` is DISTINCT from `:egress_blocked` (an IP changed, not a policy
  # refusal) and equally not a provider failure — remediation is a cheap re-pin.
  defp breaker_countable?(:pin_stale), do: false
  defp breaker_countable?(:egress_unavailable), do: false

  # The tagged refusal form `{tag, details}` (US-41.4 review): same reasoning —
  # never a provider failure, no request was issued.
  defp breaker_countable?({tag, details})
       when tag in [:egress_blocked, :pin_stale, :egress_unavailable] and is_map(details),
       do: false

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

  # US-41.7 — the ONE place an article's operation-0 custody sequence is assigned.
  # System-scoped articles (nil tenant) have no tenant to bind a claim to.
  #
  # Routed through `Custody.assign_in_multi/6` (rather than a local copy of it) so
  # the "never fail the content write over a posture-recording fault" swallow —
  # and the savepoint that makes it possible — has exactly ONE implementation.
  defp maybe_assign_custody_sequence(multi, nil, _opts), do: multi

  defp maybe_assign_custody_sequence(multi, tenant_id, opts) do
    # `:create` resolves NO endpoint by itself — UNLESS the novelty gate ran, in
    # which case this very request already POSTed the proposal's title+body to the
    # resolved embedding endpoint (`Loopctl.Knowledge.ProposalGate`), before the row
    # existed and therefore before any entry could be hung on it. `gate_embedded`
    # comes from the assessment, so a proposal that REUSED a caller-supplied vector
    # (no provider call) still records `[]`.
    custody_opts =
      if Keyword.get(opts, :gate_embedded, false),
        do: [endpoint_kinds: [:embedding]],
        else: []

    # The scope follows the ARTICLE's project, which is only known once the insert
    # has run — hence a scope FUNCTION over the Multi changes, not a static scope.
    Custody.assign_in_multi(
      multi,
      :custody_posture,
      &EgressScope.new(tenant_id, &1.article.project_id),
      "article",
      & &1.article.id,
      :create,
      custody_opts
    )
  end

  defp maybe_enqueue_custody_flush(tenant_id, %{custody_posture: %Custody.PostureEntry{}}),
    do: Custody.enqueue_flush(tenant_id)

  defp maybe_enqueue_custody_flush(_tenant_id, _changes), do: :ok

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

  # `as: :article` names the binding so `find_orphan_articles/3` can correlate a
  # `not exists` subquery back to it via `parent_as/1`. Naming a binding is inert for every
  # other consumer that re-composes this query.
  defp published_base_query(tenant_id, nil) do
    from(a in Article,
      as: :article,
      where: a.tenant_id == ^tenant_id,
      where: a.status == :published
    )
  end

  defp published_base_query(tenant_id, project_id) do
    base =
      from(a in Article,
        as: :article,
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

  # An orphan is an article that appears in NO link, in either direction.
  #
  # Expressed as two correlated `not exists` rather than `id not in subquery(...)` (#574).
  # That difference is not stylistic: PostgreSQL CANNOT turn `NOT IN (subquery)` into an
  # anti-join, because of three-valued NULL semantics — a single NULL in the subquery makes
  # the whole predicate NULL, so the planner has to keep the entire set. It therefore
  # materialised all 1.4M `article_links` rows TWICE and re-scanned that tuplestore once per
  # candidate article: a measured plan cost of 2.21 BILLION, six sequential scans per
  # execution across the parallel workers, and the single largest source of the 1.65 billion
  # `seq_tup_read` this table had accumulated.
  #
  # It did not merely run slowly — the nightly `KnowledgeLintWorker` for the only tenant with
  # a real corpus was DISCARDED after 3 attempts every night (a pool timeout inside this
  # query), so the lint had never once succeeded there. `NOT EXISTS` is anti-join-able, so
  # each candidate becomes an index probe on `article_links_source_article_id_index` /
  # `_target_article_id_index`.
  #
  # No index would have rescued the old shape: one tenant owns 100% of `article_links`, so
  # the `tenant_id` predicate those subqueries filtered on is entirely non-selective. The
  # SHAPE was the defect.
  defp find_orphan_articles(base, tenant_id, _project_id) do
    query =
      from(a in base,
        where:
          not exists(
            from(l in ArticleLink,
              where: l.tenant_id == ^tenant_id,
              where: l.source_article_id == parent_as(:article).id,
              select: 1
            )
          ),
        where:
          not exists(
            from(l in ArticleLink,
              where: l.tenant_id == ^tenant_id,
              where: l.target_article_id == parent_as(:article).id,
              select: 1
            )
          ),
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
