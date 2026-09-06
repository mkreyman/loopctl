defmodule Loopctl.Knowledge.VectorSearch do
  @moduledoc """
  The single, correct-by-construction kNN helper for every embedding-backed
  endpoint (US-27.6a).

  ## Why this module exists

  Every prior embedding endpoint hand-rolled its own cosine query, and the same
  root-cause bug shipped to production three times (#168 / #170 / #172): placing a
  JOIN or a distance-based `WHERE` **inside** the index-ordered query makes the
  pgvector HNSW planner abandon the index and Seq-Scan the entire corpus + Sort
  (cost ~57k vs ~880 at the ~76k-row prod scale), which then times out. There was
  no shared, proven path, so any new endpoint could reinvent the index-defeating
  mistake.

  `Loopctl.Knowledge.VectorSearch` encodes the verified `suggested_links` shape
  once. Routing every vector endpoint through it makes the failure mode
  *structurally unreachable*: the index-ordered subquery here only ever carries
  index-safe residual filters, and all exclusions / the threshold floor are applied
  in an outer query over the over-fetched pool.

  ## The shape (LOAD-BEARING — verified with EXPLAIN at prod scale)

  pgvector's HNSW cosine index only accelerates a PURE
  `ORDER BY embedding <=> $vec LIMIT pool`. So the query is split in two:

    * **INNER subquery** — the pure top-`pool` nearest by cosine distance. Only
      index-safe residual filters live here: tenant equality, `status=:published`,
      `embedding IS NOT NULL`, `id != $self` (a single-row equality exclusion that
      does not defeat the index), optional `tags &&`/`category =` membership, and
      the visibility metadata scope — each verified to keep the index. The target
      is a BOUND `^[float()]` list param (`to_embedding_list/1`), NEVER the stored
      `%Pgvector{}` struct (re-interpolating that struct was the #168 500).
    * **OUTER query** — over just the `pool` rows: the already-linked anti-join
      (both directions, tenant-scoped, only when `:exclude_linked` is set with an
      `:exclude_id` anchor), the `similarity_score > threshold` floor, the final
      `ORDER BY similarity_score DESC`, and `LIMIT k`.

  The `pool` over-fetches well beyond `k` for **anti-join + threshold** (structural
  exclusions of already-linked articles, similarity floor); these rarely starve
  the result because they act on ~small row counts. However, **`tags` and `category`
  are post-ANN filters applied to the ≤500-row pool** and can severely under-fill:
  a selective tag matching <1% of the corpus will rarely survive the pool's
  top-`pool`-by-cosine approximation, returning 0 results even when k matching
  articles exist corpus-wide. This is a known limitation of post-ANN filters.
  This module is the index-correct core + caller-cost bounds + tenant isolation.

  ## Recall ceiling + the under-fill signal (US-27.6b)

  Recall is bounded by **two** things, not one:

    1. `hnsw.ef_search` — pgvector's per-query search breadth, **default ~40**. The
       inner ANN only inspects ~`ef_search` graph nodes, so even before any filter
       the "nearest pool" is an *approximation* of the true top-`pool`.
    2. the over-fetch `pool` itself — the post-ANN filters (anti-join / threshold /
       tags / category) run over only those `pool` rows.

  **Under-fill is EXPECTED for a densely-linked hub:** when a hub's nearest pool is
  almost entirely already-linked (or below threshold), the result legitimately
  returns fewer than `k` even though more-distant unlinked candidates exist. That is
  the price of the indexed path — NOT a bug. The danger is that this looks
  *identical* to "no neighbors exist" (a genuinely-empty corpus). So under-fill is
  made **observable, not silent**: `Loopctl.Knowledge.suggest_links_with_meta/3`
  emits a `[:loopctl, :knowledge, :vector_search, :under_fill]` telemetry event and
  a response-`meta` flag when above-threshold (near) neighbors the ANN surfaced were
  hidden by the already-linked anti-join (`above_threshold > returned`) — NOT for a
  sparse region whose whole ANN pool is below the threshold (correct emptiness, see
  that function + `Loopctl.TelemetryEvents.vector_search_under_fill/0`). The detector
  is ef_search-independent (it compares counts over the set the ANN actually
  delivered, never a degenerate `ann_candidates >= pool` gate). The event's
  `excluded_by_link` measurement (`above_threshold - returned`) is the un-conflated
  count of above-threshold neighbors the anti-join removed — the recall-loss metric
  US-27.15 aggregates, computed from the single bounded under-fill probe.

  **Raising recall (US-38.4): `hnsw.ef_search` is now a per-query, live-tunable knob.**
  `hnsw.ef_search` is a pgvector **custom GUC** that still **cannot** be set via a
  Postgrex startup `:parameters` entry (managed PG/pgbouncer rejects it — the US-27.13
  outage class, guarded by `config_pgbouncer_safe_parameters_test.exs`). The historical
  objection that setting it per-request via `SET LOCAL` "needs a transaction and so
  re-introduces the #172 pool-starvation anti-pattern" is now **stale**: since US-27.13
  every heavy read ALREADY runs inside a short `SET LOCAL statement_timeout` transaction
  (`Loopctl.HeavyRead.run_timed_transaction/5`), so a `SET LOCAL hnsw.ef_search = N`
  piggybacks on that EXISTING bounded, self-draining transaction with **no new
  starvation risk**. `Loopctl.HeavyRead.opts/1` therefore attaches `:hnsw_ef_search`
  (config `SystemConfig "hnsw_ef_search"`, default 40 = pgvector's default) to every
  ANN endpoint **whenever that value differs from the default**, applied per-read. An
  operator raises recall fleet-wide with a single
  `UPDATE system_configs` — no redeploy. A role-level
  `ALTER ROLE <role> SET hnsw.ef_search = N` still works as a role-scoped default and is
  honored whenever `SystemConfig` is left at the default: the per-read `SET LOCAL` is emitted
  ONLY for a NON-default `SystemConfig` value, so it never silently shadows the role override
  (an unconditional `SET LOCAL` at the default would override that role default per-read —
  the bug this guard avoids). When both are set to non-default values the per-read
  `SystemConfig` `SET LOCAL` wins for that ANN read; see `docs/runbooks/knowledge-scale.md`.
  Recall is thus handled by
  **over-fetch + the under-fill signal + the ef_search knob**; the current value stays
  at the default until an operator raises it.

  ## Caller-cost bounds (AC-27.6a.4 — OWASP A06, insecure design)

  Every caller-tunable parameter that affects query cost has a **documented,
  enforced upper bound**. The heavy-read `statement_timeout` is a DESIGNED
  backstop, NOT the primary bound:

    * `k` / limit — clamped to `[1, max_k/0]` (default 100).
    * the over-fetch `pool` — `pool_size/2`:
      `k * pool_factor/0 |> max(pool_floor/0) |> min(max_pool/0) |> max(k)`
      (default factor 5, floor 100, cap 500), so the index scan stays cheap
      regardless of `k`, and a misconfigured `cap < k` can never starve the pool
      below `k` (US-27.6b AC-27.6b.1).
    * `:threshold` — clamped into `[0.0, 1.0]`.
    * `:tags` — truncated to `max_tags/0` (default 50) entries; an empty/`nil`
      list is ignored.
    * `:category` — a single index-safe equality (no cost amplification); an
      unknown value is ignored (validated against the `Article` category enum).

  ## Tenant isolation (AC-27.6a.5)

  Runs on `Loopctl.HeavyReadRepo` (BYPASSRLS) via `Loopctl.HeavyRead`, so the
  explicit `tenant_id` predicate is the only thing isolating tenants. EVERY
  relation is tenant-scoped — the candidate scan AND the anti-join's `ArticleLink`
  — and `HeavyRead.all/3`'s structural guard rejects any query whose base-table
  sources aren't all bound to the passed tenant.

  ## Per-read SET LOCAL transaction (US-27.13; supersedes the AC-27.6a.6 "no transaction" note)

  `nearest/4` runs through `HeavyRead.all/3`, which now wraps every heavy read in a SHORT
  `SET LOCAL statement_timeout` transaction (`BEGIN; SET LOCAL; SELECT; COMMIT`). This is the
  pgbouncer-safe way to apply a server-side timeout (a startup-`:parameters` statement_timeout
  is rejected by pgbouncer — the US-27.13 outage). The transaction is per-read and short — the
  connection is released at COMMIT — so it does NOT reintroduce the #172 round-1 long-held
  pool-starvation anti-pattern; it is the opposite (a bounded, self-draining hold). The
  earlier AC-27.6a.6 "bare pool read, no per-request transaction" guarantee is obsolete: a
  per-read transaction is now unavoidable behind pgbouncer.
  """

  @behaviour Loopctl.Knowledge.SimilaritySearchBehaviour

  import Ecto.Query

  alias Loopctl.Embeddings
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.Suppression

  @typedoc "A nearest-neighbour candidate row."
  @type candidate :: %{
          id: Ecto.UUID.t(),
          title: String.t(),
          category: atom() | nil,
          similarity_score: float()
        }

  @typedoc """
  A target embedding: a plain `[float()]` list or a stored `%Pgvector{}` struct —
  normalized to a bound `^[float()]` param via `to_embedding_list/1`.
  """
  @type target_embedding :: [float()] | %Pgvector{data: term()}

  # ---------------------------------------------------------------------------
  # Caller-cost bounds (AC-27.6a.4). Each is config-overridable but defaults to a
  # documented, conservative cap. The statement_timeout is a backstop, not these.
  # ---------------------------------------------------------------------------

  # Maximum `k`/limit. Mirrors the relevance-search cap (`@max_relevance_page_size`
  # in Loopctl.Knowledge) — a kNN result is a ranked top-N, not an enumeration, so
  # a huge `k` is both pointless and a cost amplifier on the over-fetch pool.
  @default_max_k 100

  # Maximum over-fetch pool — the most rows the inner HNSW scan will ever pull
  # before the outer exclusions trim to `k`. Mirrors `:max_suggestion_candidate_pool`.
  @default_max_pool 500

  # Over-fetch pool sizing (US-27.6b AC-27.6b.1). The inner pool is
  # `k * factor |> max(floor) |> min(cap) |> max(k)`. Each knob is a config
  # constant with a documented default; the FINAL `|> max(k)` is load-bearing —
  # it guarantees a misconfigured `cap < k` can NEVER drop the pool below the
  # requested `k`, so the cap can only ever ENLARGE the over-fetch, never starve
  # the result before the outer post-ANN filters run.
  @default_pool_factor 5
  @default_pool_floor 100

  # US-41.1 review #7: the side-table inner ANN cannot carry status/visibility (they
  # are not in the per-dimension partial index), so it over-fetches by this factor
  # and the outer query trims back to `pool`.
  @default_side_table_over_fetch 4

  # Maximum number of tag values accepted in a `:tags` overlap filter, so a caller
  # can't pass an unbounded array literal into the index-residual `&&` predicate.
  @default_max_tags 50

  @doc "Maximum permitted `k`/limit (config `:vector_search_max_k`, default #{@default_max_k})."
  @spec max_k() :: pos_integer()
  def max_k, do: Application.get_env(:loopctl, :vector_search_max_k, @default_max_k)

  @doc """
  Maximum over-fetch pool (config `:max_vector_pool`, default #{@default_max_pool}).

  `:max_vector_pool` is the canonical key (US-27.6b AC-27.6b.1). The pre-27.6b
  `:vector_search_max_pool` key is still honored as a fallback so an existing
  override keeps working.
  """
  @spec max_pool() :: pos_integer()
  def max_pool do
    Application.get_env(
      :loopctl,
      :max_vector_pool,
      Application.get_env(:loopctl, :vector_search_max_pool, @default_max_pool)
    )
  end

  @doc "Maximum number of `:tags` accepted (config `:vector_search_max_tags`, default #{@default_max_tags})."
  @spec max_tags() :: pos_integer()
  def max_tags, do: Application.get_env(:loopctl, :vector_search_max_tags, @default_max_tags)

  @doc "Over-fetch pool multiplier on `k` (config `:vector_pool_factor`, default #{@default_pool_factor})."
  @spec pool_factor() :: pos_integer()
  def pool_factor, do: Application.get_env(:loopctl, :vector_pool_factor, @default_pool_factor)

  @doc "Minimum over-fetch pool for small `k` (config `:vector_pool_floor`, default #{@default_pool_floor})."
  @spec pool_floor() :: pos_integer()
  def pool_floor, do: Application.get_env(:loopctl, :vector_pool_floor, @default_pool_floor)

  @doc """
  Computes the over-fetch pool for a requested `k` (US-27.6b AC-27.6b.1):

      pool = k * factor |> max(floor) |> min(cap) |> max(k)

  The factor/floor/cap default to the `:vector_pool_factor` / `:vector_pool_floor`
  / `:max_vector_pool` config (defaults #{@default_pool_factor} / #{@default_pool_floor}
  / #{@default_max_pool}). The final `|> max(k)` is the AC-27.6b.1 invariant: a
  misconfigured `cap < k` can never truncate the pool below `k`.

  `opts` lets a caller pass explicit knob values (used by the unit test to assert
  the floor-at-`k` wins without mutating global config, and by the live
  `suggested_links` path's back-compat `:max_suggestion_candidate_pool` cap alias).
  A `nil` opt falls back to the configured/default value.

    * `:factor` — multiplier (default `pool_factor/0`)
    * `:floor` — small-`k` floor (default `pool_floor/0`)
    * `:cap` — upper bound (default `max_pool/0`)
  """
  @spec pool_size(pos_integer(), keyword()) :: pos_integer()
  def pool_size(k, opts \\ []) when is_integer(k) and k > 0 do
    factor = Keyword.get(opts, :factor) || pool_factor()
    floor = Keyword.get(opts, :floor) || pool_floor()
    cap = Keyword.get(opts, :cap) || max_pool()

    (k * factor)
    |> max(floor)
    |> min(cap)
    # LOAD-BEARING: the cap can only ever ENLARGE the over-fetch, never drop the
    # pool below the requested k (a misconfigured cap < k is overridden here).
    |> max(k)
  end

  @doc """
  Executes the index-correct kNN query and returns up to `k` candidate maps,
  highest similarity first.

  Runs via `HeavyRead.all/3`, which applies the `:vector_search` server-side
  statement_timeout per-read via a short `SET LOCAL` transaction (US-27.13).

  See `candidate_query/4` for the parameters and `opts`. All cost-affecting params
  are clamped to their documented bounds before the query is built (AC-27.6a.4).

  `target_embedding` is a plain `[float()]` list or a `%Pgvector{}` — normalized to
  a bound `^[float()]` param via `to_embedding_list/1` (never the struct — #168).

  ## `:on_unavailable` — telling "no neighbours" apart from "no search"

  A query vector whose length disagrees with the tenant's read dimension cannot be
  searched at all, and the graceful degrade for it is an EMPTY list (below). For a
  caller whose next act is a READ that is exactly right: zero results renders as zero
  results. For a caller whose next act is a WRITE it is a silent falsehood — an empty
  pool scores as maximally novel, so an UNSEARCHABLE proposal reads as a genuinely
  novel one and gets published without any comparison having happened.

    * `:empty` (default) — `[]`, the historical degrade. Every existing caller keeps it.
    * `:tag` — `{:error, :search_unavailable}`, so a write-deciding caller can hold
      instead of guessing. Mirrors `on_overload: :tag` exactly, and for the same reason.
  """
  @impl true
  @spec nearest(Ecto.UUID.t(), target_embedding(), pos_integer(), keyword()) ::
          [candidate()] | {:error, :heavy_read_overloaded} | {:error, :search_unavailable}
  def nearest(tenant_id, target_embedding, k, opts \\ []) when is_binary(tenant_id) do
    # Query-vector length guard (review): the side-table ANN binds the target into the
    # per-dimension `(embedding::vector(N))` cast, so a fresh query vector whose length
    # disagrees with the read dimension (mid-model-change / stale setting / pin conflict)
    # would raise pgvector's "different vector dimensions" 500 on this request path. An
    # EMPTY result is the documented graceful degrade — every read caller already handles
    # "no neighbours" (suggest-links empty, ArticleLinkingWorker no links) — but see
    # `:on_unavailable` above for why a caller that WRITES on this result must not.
    case Embeddings.check_query_vector(tenant_id, to_embedding_list(target_embedding)) do
      :ok ->
        # Resolve the side-table cutover flag ONCE and thread it into `opts` before
        # BOTH stages run (review): candidate_query (via candidate_pool_query) and
        # nearest_heavy_read_opts each resolve `:reads_side_table` via Keyword.get_lazy
        # when it is absent, so an unthreaded call reads Embeddings.side_table_reads_enabled?/0
        # twice. A cutover flip (AC-41.1.8 can flip against live traffic) landing between
        # the two reads would let the query BUILD (side table, pool*4 over-fetch) and the
        # ef_search DECISION disagree — build side-table but not raise ef_search → transient
        # under-recall. This is the same "resolve once and thread" invariant candidate_pool_query
        # documents (vector_search.ex:447-452) and suggest_links honors (knowledge.ex:4713).
        opts =
          Keyword.put_new_lazy(opts, :reads_side_table, &Embeddings.side_table_reads_enabled?/0)

        query = candidate_query(tenant_id, target_embedding, k, opts)
        read_opts = nearest_heavy_read_opts(k, opts)

        case HeavyRead.all(tenant_id, query, read_opts) do
          {:error, :heavy_read_overloaded} = shed ->
            shed

          neighbors when is_list(neighbors) ->
            # Both callers of `nearest/4` take a WRITE decision on this result and neither
            # has a response envelope to disclose a degraded scan in — `ProposalGate`
            # verdicts a missed near-dup as novel (publishing a duplicate) and
            # `ArticleLinkingWorker` writes no link for a neighbour the batch never
            # returned. Warned here, once, from the opts the read ACTUALLY ran with, so
            # the two cannot describe different executions (#634 round-2).
            HeavyRead.warn_if_ann_degraded("knowledge.vector_search", read_opts)
            neighbors
        end

      {:error, _mismatch} ->
        # The dimension state that produces this does NOT self-heal on its own — a tenant
        # whose configured model returns a length this instance cannot index keeps
        # returning it (`Embeddings.recall_availability/2` says so in as many words) — so
        # a `:tag` caller is being told about a standing condition, not a blip.
        case Keyword.get(opts, :on_unavailable, :empty) do
          :tag -> {:error, :search_unavailable}
          _empty -> []
        end
    end
  end

  # On the side-table path the inner ANN over-fetches by `side_table_over_fetch/0` to
  # offset the status/visibility filtering it cannot carry — but an HNSW scan only
  # returns ~ef_search rows regardless of LIMIT, so the over-fetch is inert unless
  # ef_search is raised in lockstep (review). Raise it to cover the over-fetched inner
  # pool whenever this read hits the side table; the legacy path is unaffected.
  defp nearest_heavy_read_opts(k, opts) do
    base = heavy_read_opts(opts)

    reads_side_table? =
      Keyword.get_lazy(opts, :reads_side_table, &Embeddings.side_table_reads_enabled?/0)

    if reads_side_table? do
      pool = candidate_pool(clamp_k(k), Keyword.get(opts, :pool))
      Keyword.put(base, :hnsw_ef_search, side_table_ef_search(side_table_inner_pool(pool)))
    else
      base
    end
  end

  @doc """
  Builds the kNN `Ecto.Query` (returned, NOT executed) so plan tests can assert on
  its shape (AC-27.6a.3) and structure (AC-27.6a.2).

  ## Parameters

    * `tenant_id` — the tenant UUID. Scopes BOTH the candidate scan and any
      anti-join (AC-27.6a.5).
    * `target_embedding` — the query vector as a plain `[float()]` list or a
      `%Pgvector{}`; bound as a `^[float()]` param via `to_embedding_list/1`.
    * `k` — the maximum number of results (clamped to `[1, max_k/0]`).
    * `opts`:
      * `:exclude_id` — an article UUID to exclude from candidates (the "self"
        anchor); also the anchor for the already-linked anti-join.
      * `:exclude_linked` (boolean) — when `true` AND `:exclude_id` is given,
        excludes any article already linked to `exclude_id` in EITHER direction
        (any relationship type), applied in the OUTER query over the pool.
      * `:threshold` — minimum `similarity_score` (clamped to `[0.0, 1.0]`,
        default `0.0` — no floor); applied in the outer query.
      * `:tags` — tag overlap (`&&`) filter applied **AFTER the ANN fetch** over the
        over-fetched pool (truncated to `max_tags/0`). A selective tag can yield
        materially fewer than `k` results (even 0) when matching articles fall
        outside the top-pool nearest-by-distance.
      * `:category` — category equality (`=`) filter applied **AFTER the ANN fetch**
        over the pool. This is a post-ANN filter, not a tag-scoped kNN; recall
        depends on whether matching articles are in the top-`pool` nearest.
      * `:project_id` — project equality (`=`) filter applied **AFTER the ANN
        fetch** over the pool (the `articles(tenant_id, project_id, category)`
        btree means a selective `project_id =` on the INNER ANN would defeat HNSW,
        so it lives on the outer pool like `:category`). `nil` is ignored. This is
        the strict-equality form `search_semantic` uses.
      * `:project_or_global` — like `:project_id` but matches the given project
        UUID **OR** tenant-wide (`project_id IS NULL`) rows — the auto-link
        worker's "same-project plus tenant-wide" scope. Also a post-ANN outer
        filter; `nil` is ignored.
      * `:visibility_agent_id` — the agent visibility scope (same metadata
        predicate as the other knowledge reads).
      * `:pool` — override the over-fetch pool (still clamped by `max_pool/0` and
        floored at `k`).

  ## Returns

  An `Ecto.Query` selecting `%{id, title, category, similarity_score}` where
  `similarity_score = GREATEST(0, 1 - cosine_distance)`.
  """
  @spec candidate_query(Ecto.UUID.t(), target_embedding(), pos_integer(), keyword()) ::
          Ecto.Query.t()
  def candidate_query(tenant_id, target_embedding, k, opts \\ []) when is_binary(tenant_id) do
    k = clamp_k(k)
    pool = candidate_pool(k, Keyword.get(opts, :pool))
    threshold = clamp_threshold(Keyword.get(opts, :threshold, 0.0))

    exclude_id = Keyword.get(opts, :exclude_id)
    exclude_linked? = Keyword.get(opts, :exclude_linked, false) and is_binary(exclude_id)
    tags = clamp_tags(Keyword.get(opts, :tags))
    category = Keyword.get(opts, :category)
    project_id = Keyword.get(opts, :project_id)
    project_or_global = Keyword.get(opts, :project_or_global)

    # INNER: the pure index-ordered ANN top-`pool` (shared with the suggested_links
    # under-fill probe via candidate_pool_query/4 so their candidate set is identical
    # by construction — no drift). It carries ONLY index-safe residual filters; see
    # candidate_pool_query/4 for the load-bearing rationale.
    candidates = candidate_pool_query(tenant_id, target_embedding, pool, opts)

    # OUTER: over the materialized ≤pool rows — tags/category/project here are trivial
    # filters on a tiny result set (no corpus scan), so they cannot defeat the index.
    candidates
    |> outer_query()
    |> maybe_exclude_linked(tenant_id, exclude_id, exclude_linked?)
    |> maybe_filter_by_tags(tags)
    |> maybe_filter_by_category(category)
    |> maybe_filter_by_project(project_id)
    |> maybe_filter_by_project_or_global(project_or_global)
    |> where([c], c.similarity_score > ^threshold)
    |> order_by([c], desc: c.similarity_score)
    |> limit(^k)
  end

  # Builds the INNER index-ordered ANN top-`pool` subquery (returned, NOT executed).
  #
  # This is the pure `ORDER BY embedding <=> $const LIMIT pool` with ONLY index-safe
  # residual filters, exposed as its own (@doc false) public function so the live
  # `suggested_links` path's under-fill probe (`Loopctl.Knowledge.under_fill_probe/6`)
  # and the main `candidate_query/4` build the EXACT SAME inner by construction — the
  # probe's `ann_candidates`/`above_threshold` counts are then over the identical
  # candidate set the main query drew from, with zero risk of drift. `search_semantic`
  # shares this same inner too (US-27.7a), so a future edit there can't reintroduce a
  # full scan.
  #
  # WHAT MAY LIVE HERE (LOAD-BEARING — verified with EXPLAIN at 80k scale): ONLY filters
  # verified to keep the HNSW Index Scan — tenant/status/not-null equalities, the
  # single-row self-exclusion (`:exclude_id`), and the visibility `metadata->>` Filter
  # (`:visibility_agent_id`). Visibility is index-safe by OPERATOR CLASS, not selectivity:
  # the `metadata->>'key' = ...` / COALESCE form cannot be served by the articles
  # `jsonb_ops` GIN (it only answers @>/?), and there is no btree expression index on it —
  # so the planner can ONLY apply it as a Filter-after-HNSW-index, at ANY selectivity. DO
  # NOT add a btree/expression index on the visibility/agent_id metadata path or rewrite
  # this to a GIN-servable `metadata @> ...` form — that would let a selective scope flip
  # the planner off HNSW. `tags`/`category`/`project_id` are DELIBERATELY NOT here: they
  # HAVE GIN/btree indexes, so a selective `tags &&` / `category =` / `project_id =`
  # predicate makes the planner BitmapAnd-then-Sort and ABANDON the HNSW index (the
  # #170/#172 failure mode — proven by EXPLAIN at scale). They are applied on the OUTER
  # pool instead (see `candidate_query/4`).
  #
  # SELECT SHAPE: chosen by the `:select` opt (the SELECT list does NOT affect HNSW usage
  # — only the WHERE/ORDER BY/LIMIT do — so the two shapes share the SAME index-safe core):
  #   * `:knn` (default) — `%{id, title, category, tags, project_id, similarity_score}` with
  #     `similarity_score = GREATEST(0, 1 - cosine_distance)` (the suggested_links / worker
  #     shape). `tags`/`project_id` are carried so the outer over-the-pool query can
  #     post-filter on them without a second `articles` reference.
  #   * `:semantic` — `search_semantic`'s richer projection: adds `tenant_id`, `status`,
  #     `inserted_at`, `updated_at`, and `metadata` (so the outer pool can apply the
  #     GIN-servable `metadata @>` memory-type/agent/conversation filters — which CANNOT
  #     go in the inner without defeating HNSW), and uses the RAW
  #     `similarity_score = 1 - cosine_distance` (not GREATEST-clamped) to preserve the
  #     pre-US-27.7a semantic-search contract exactly.
  #
  # RECOGNIZED opts: `:exclude_id` (single-row index-safe self-exclusion),
  # `:visibility_agent_id` (index-safe metadata scope), `:status` (index-safe status
  # equality, default `:published`), `:select` (`:knn` | `:semantic`, default `:knn`).
  # Cost-affecting opts (`:tags`/`:category`/`:project_id`/`:threshold`/`:pool`) are
  # IGNORED here — they belong on the outer query in `candidate_query/4` (or the
  # search_semantic outer pool).
  @doc false
  @spec candidate_pool_query(Ecto.UUID.t(), target_embedding(), pos_integer(), keyword()) ::
          Ecto.Query.t()
  def candidate_pool_query(tenant_id, target_embedding, pool, opts \\ [])
      when is_binary(tenant_id) and is_integer(pool) do
    # US-41.1 AC-41.1.8 (review #3): the cutover flag routes EVERY consumer of this
    # helper — `suggest_links`, the novelty/dedup `ProposalGate`, and
    # `ArticleLinkingWorker` — onto the dimension-tagged side table, not just
    # `search_semantic`. Leaving them on `articles.embedding` was a CORRECTNESS
    # regression, not a degradation: `Knowledge.update_embedding/5` skips the legacy
    # column entirely for any non-1536 dimension, so for a 768/1024 tenant those
    # queries matched ZERO rows — `suggest_links` returned nothing and the dedup gate
    # saw no priors and verdicted every proposal `novel`, creating duplicates.
    # The cutover flag is resolved ONCE per operation and threaded via `:reads_side_table`
    # (review): re-reading `side_table_reads_enabled?/0` independently in the source-vector
    # fetch and the candidate scan let an operator flip mid-request be observed differently
    # by two stages of one operation (e.g. suggest_links reading the source from the side
    # table but candidates from `articles.embedding`). The caller (suggest_links,
    # search_semantic) resolves it once and passes it; absent, we fall back to a single read.
    reads_side_table? =
      Keyword.get_lazy(opts, :reads_side_table, &Embeddings.side_table_reads_enabled?/0)

    if reads_side_table? do
      dimension_candidate_pool_query(tenant_id, target_embedding, pool, opts)
    else
      legacy_candidate_pool_query(tenant_id, target_embedding, pool, opts)
    end
  end

  defp legacy_candidate_pool_query(tenant_id, target_embedding, pool, opts) do
    target = to_embedding_list(target_embedding)
    exclude_id = Keyword.get(opts, :exclude_id)
    vis = Keyword.get(opts, :visibility_agent_id)
    status = Keyword.get(opts, :status, :published)

    base =
      Article
      |> index_safe_knn_base(tenant_id, target, pool)
      |> maybe_filter_by_status(status)
      # The retrieval tombstone, on the inner ANN alongside `status` and for the same
      # reason: it is an index-safe equality-shaped residual (an `IS NULL` on a scalar
      # column), it costs no join and no distance term, and the suppressed set is a tiny
      # fraction of the corpus so it cannot meaningfully starve the pool. UNCONDITIONAL,
      # unlike `maybe_filter_by_status/2` — a `status: nil` caller asking for every
      # status is still asking a RETRIEVAL question, and this module has no consumer
      # that wants suppressed rows back.
      |> Suppression.exclude()
      |> maybe_exclude_self(exclude_id)
      |> maybe_filter_by_visibility(vis)

    pool_select(base, Keyword.get(opts, :select, :knn), target)
  end

  @doc """
  The SIDE-TABLE form of `candidate_pool_query/4` — same output shape, same pool
  size, dimension-scoped ANN.

  ## Why the inner ANN over-fetches (review #7)

  The legacy inner carried `status = :published` and the visibility predicate INSIDE
  the index-ordered top-k, so the pool held `pool` PUBLISHED, VISIBLE rows. The side
  table carries neither: the per-dimension partial index's only status-ish predicate
  is `live_denorm`, which mirrors `status <> 'superseded'` — so drafts, archived and
  other agents' private articles occupy pool slots and the real predicates can only
  be applied on the OUTER query. At an identical inner limit that returns strictly
  FEWER published rows than the legacy path, i.e. a silent recall regression at
  cutover.

  The inner limit is therefore multiplied by `side_table_over_fetch/0` before the
  outer status/visibility filters trim it back to `pool`. This is the documented,
  deliberate cost of the side table; the alternative — encoding `published` in
  `live_denorm` — would need a second denormalized marker plus a second partial HNSW
  index per dimension, doubling an already-expensive build.
  """
  @spec dimension_candidate_pool_query(
          Ecto.UUID.t(),
          target_embedding(),
          pos_integer(),
          keyword()
        ) :: Ecto.Query.t()
  def dimension_candidate_pool_query(tenant_id, target_embedding, pool, opts \\ []) do
    target = to_embedding_list(target_embedding)
    dimension = Keyword.get(opts, :dimension) || Embeddings.active_dimension(tenant_id)
    exclude_id = Keyword.get(opts, :exclude_id)
    vis = Keyword.get(opts, :visibility_agent_id)
    status = Keyword.get(opts, :status, :published)

    inner =
      ArticleEmbedding
      |> index_safe_dimension_knn_base(tenant_id, target, dimension, side_table_inner_pool(pool))
      |> select([e], %{article_id: e.article_id})
      |> put_dimension_distance(dimension, target)

    from(c in subquery(inner),
      join: a in Article,
      on: a.id == c.article_id and a.tenant_id == ^tenant_id,
      order_by: [asc: c.distance],
      limit: ^pool
    )
    |> maybe_filter_by_status_on_article(status)
    # Same predicate as the legacy branch, on the OUTER join where this path's status
    # and visibility filters already live — the cutover flag must never decide whether a
    # suppressed article can be retrieved.
    |> Suppression.exclude_last()
    |> maybe_exclude_self_on_article(exclude_id)
    |> maybe_filter_by_visibility_on_article(vis)
    |> dimension_pool_select(Keyword.get(opts, :select, :knn))
  end

  @doc """
  Inner-ANN over-fetch multiplier for the side-table pool (config
  `:embedding_side_table_over_fetch`, default #{@default_side_table_over_fetch}).
  """
  @spec side_table_over_fetch() :: pos_integer()
  def side_table_over_fetch do
    Application.get_env(
      :loopctl,
      :embedding_side_table_over_fetch,
      @default_side_table_over_fetch
    )
  end

  @doc false
  @spec side_table_inner_pool(pos_integer()) :: pos_integer()
  def side_table_inner_pool(pool) when is_integer(pool) and pool > 0 do
    pool * side_table_over_fetch()
  end

  # The largest `hnsw.ef_search` the side-table path will request per read. An HNSW
  # scan only inspects/returns ~`ef_search` graph nodes regardless of the LIMIT, so an
  # inner LIMIT of `pool * over_fetch` is a NO-OP unless ef_search is raised to cover it
  # — the over-fetch's whole purpose (offsetting the status/visibility filtering the
  # side-table inner cannot carry) is otherwise structurally unreachable (review).
  @default_max_side_table_ef_search 1000

  @doc "Cap on the per-read `hnsw.ef_search` the side-table ANN requests (config `:side_table_max_ef_search`)."
  @spec max_side_table_ef_search() :: pos_integer()
  def max_side_table_ef_search do
    Application.get_env(
      :loopctl,
      :side_table_max_ef_search,
      @default_max_side_table_ef_search
    )
  end

  @doc """
  The `hnsw.ef_search` to apply for a side-table ANN whose inner LIMIT is `inner_pool`:
  at least `inner_pool` (so the over-fetch actually returns that many candidates),
  capped at `max_side_table_ef_search/0`. The over-fetch is inert without this.
  """
  @spec side_table_ef_search(pos_integer()) :: pos_integer()
  def side_table_ef_search(inner_pool) when is_integer(inner_pool) and inner_pool > 0 do
    min(inner_pool, max_side_table_ef_search())
  end

  # Article-binding (second binding) forms of the inner filters. Same predicates as
  # the legacy inner, applied over the materialized ≤(pool * over_fetch) rows.
  defp maybe_filter_by_status_on_article(query, nil), do: query

  defp maybe_filter_by_status_on_article(query, status),
    do: where(query, [_c, a], a.status == ^status)

  defp maybe_exclude_self_on_article(query, nil), do: query

  defp maybe_exclude_self_on_article(query, exclude_id) when is_binary(exclude_id),
    do: where(query, [_c, a], a.id != ^exclude_id)

  defp maybe_filter_by_visibility_on_article(query, nil), do: query

  defp maybe_filter_by_visibility_on_article(query, agent_id) when is_binary(agent_id) do
    where(
      query,
      [_c, a],
      fragment("COALESCE(?->>'visibility', 'shared') NOT IN ('private','owner')", a.metadata) or
        fragment("?->>'agent_id' = ?", a.metadata, ^agent_id)
    )
  end

  # The SAME two projections `pool_select/3` emits, computed from the inner's raw
  # `distance` instead of a second `<=>` — so this module keeps its single home for
  # the cosine literal and the two paths cannot drift in score semantics.
  defp dimension_pool_select(query, :knn) do
    select(query, [c, a], %{
      id: a.id,
      title: a.title,
      category: a.category,
      tags: a.tags,
      project_id: a.project_id,
      similarity_score: fragment("GREATEST(0, 1 - ?)", c.distance)
    })
  end

  defp dimension_pool_select(query, :semantic) do
    select(query, [c, a], %{
      id: a.id,
      tenant_id: a.tenant_id,
      project_id: a.project_id,
      title: a.title,
      category: a.category,
      status: a.status,
      tags: a.tags,
      # The MOC-hub demotion signal (#654 follow-up) — RankingPriors fails open without
      # it, so the semantic lane would keep ranking hubs undemoted while keyword did not.
      idempotency_key: a.idempotency_key,
      metadata: a.metadata,
      inserted_at: a.inserted_at,
      updated_at: a.updated_at,
      similarity_score: fragment("1 - ?", c.distance)
    })
  end

  @doc """
  The single index-safe HNSW inner base query, PARAMETERIZED BY SCHEMA (US-28.2).

  This is the ONE load-bearing shape whose SQL is scale-gated (the #170/#172 prod
  500s): a pure `ORDER BY <schema>.embedding <=> $target LIMIT pool` carrying ONLY
  the index-safe residuals `tenant_id == ^tenant_id` and `embedding IS NOT NULL`.
  ANY additional predicate (subject scope, status, superseded, tags, category, …)
  MUST be applied on an OUTER query over the materialized ≤`pool` rows — putting a
  selective btree predicate here flips the planner off the HNSW index.

  Both `Loopctl.Knowledge`'s article recall (`candidate_pool_query/4`) and
  `Loopctl.Memory`'s agent-memory recall build their inner pool through THIS one
  function, so the index-safety fix lives in exactly one place and can never drift
  between the two consumers (US-28.2 technical-notes: "extract a shared kNN helper
  parameterized by schema/scope rather than duplicating the HNSW query"). The caller
  adds its own `select`/`select_merge` projection — the SELECT list does not affect
  HNSW usage, only the WHERE/ORDER BY/LIMIT do.

  `target` must already be a bound `[float()]` list (via `to_embedding_list/1`);
  `schema` is any Ecto schema carrying `tenant_id` + `embedding` columns.
  """
  @spec index_safe_knn_base(module(), Ecto.UUID.t(), [float()], pos_integer()) ::
          Ecto.Query.t()
  def index_safe_knn_base(schema, tenant_id, target, pool)
      when is_atom(schema) and is_binary(tenant_id) and is_list(target) and is_integer(pool) do
    from(x in schema,
      where: x.tenant_id == ^tenant_id,
      where: not is_nil(x.embedding),
      order_by: [asc: fragment("? <=> ?", x.embedding, ^target)],
      limit: ^pool
    )
  end

  @doc """
  The DIMENSION-SCOPED index-safe HNSW inner base over an embedding SIDE TABLE
  (US-41.1 AC-41.1.5).

  Same load-bearing filter-after-ANN shape as `index_safe_knn_base/4`, with two
  differences that are both required for the per-tenant-dimension design:

    * the ordering expression is the EXPLICIT CAST `(embedding::vector(N))`,
      character-identical to the expression the per-dimension index is built over
      (`Loopctl.Repo.HnswIndex.create_dimension_index_sql/2`). The side table's
      `embedding` column is an UNCONSTRAINED `vector` — pgvector refuses to
      HNSW-index that — so the cast is what supplies the typmod, and the planner
      can only match the index if the query repeats it verbatim.
    * the WHERE carries `dim = <literal>` (a compile-time literal per supported
      dimension via `dimension_where/2`, NOT a bound `^dimension` param — see that
      function) and `live_denorm`, which are EXACTLY the per-dimension index's
      partial predicate, matched even under a Postgres GENERIC plan. Nothing else
      may be added here:
      a JOIN or a selective btree predicate inside the index-ordered top-k is the
      #170/#172 production incident (cost ~57k vs ~880 at 76k rows). Subject
      scope, project, tags, category and status all belong on an OUTER query over
      the materialized pool.

  Because the inner pool is dimension-scoped, a cross-dimension similarity
  comparison is impossible BY CONSTRUCTION — pgvector's "different vector
  dimensions" error is an unreachable safety net, not the mechanism.

  `schema` is `Loopctl.Knowledge.ArticleEmbedding` or
  `Loopctl.Memory.MemoryEmbedding`; `target` must already be a bound `[float()]`
  list of exactly `dimension` components.

  `:live_only` (default `true`) drops the `live_denorm` predicate when `false` — the
  admin/oversight `include_superseded` recall path. That variant has NO matching
  partial index by design (the per-dimension indexes carry the live predicate the AC
  mandates, and a second full index per dimension would double an already-expensive
  HNSW build at corpus scale), so it plans as a bounded top-k sort rather than an
  index scan. Do NOT route interactive recall through it.
  """
  @spec index_safe_dimension_knn_base(
          module(),
          Ecto.UUID.t(),
          [float()],
          pos_integer(),
          pos_integer(),
          keyword()
        ) :: Ecto.Query.t()
  def index_safe_dimension_knn_base(schema, tenant_id, target, dimension, pool, opts \\ [])
      when is_atom(schema) and is_binary(tenant_id) and is_list(target) and
             is_integer(dimension) and is_integer(pool) do
    from(x in schema,
      where: x.tenant_id == ^tenant_id,
      limit: ^pool
    )
    |> dimension_where(dimension)
    |> maybe_live_denorm_only(Keyword.get(opts, :live_only, true))
    |> dimension_order_by(dimension, target)
  end

  defp maybe_live_denorm_only(query, false), do: query
  defp maybe_live_denorm_only(query, _true), do: where(query, [x], x.live_denorm)

  @doc """
  Whether `index_safe_dimension_knn_base/6` with these `opts` builds a shape a
  per-dimension HNSW index can actually serve.

  Callers that DISCLOSE whether their read was an index scan (see
  `Loopctl.HeavyRead.iterative_scan_meta/1`) must ask HERE rather than re-deriving the
  index set from their own flags: this function and `maybe_live_denorm_only/2` sit on the
  one predicate that decides it, so a migration adding a full (non-partial) per-dimension
  index changes both together and the disclosure cannot outlive the plan it describes.
  """
  @spec dimension_knn_index_scanned?(keyword()) :: boolean()
  def dimension_knn_index_scanned?(opts \\ []) when is_list(opts),
    do: Keyword.get(opts, :live_only, true)

  # ONE clause per SUPPORTED dimension, generated at COMPILE TIME.
  #
  # `fragment/2` requires a literal SQL string, and the cast's typmod cannot be a
  # bound parameter (a typmod is part of the TYPE, not a value) — so the only way to
  # emit `(embedding::vector(768))` is to have that exact literal in the AST. Doing it
  # per supported dimension makes the set of emittable casts a CLOSED, compile-time
  # set drawn from `:supported_embedding_dimensions`: no request-supplied value can
  # ever reach the SQL, and an unsupported dimension hits the raising fallback below
  # instead of silently sequential-scanning a corpus with no matching index.
  #
  # Compile-time (`Application.compile_env`) rather than runtime config is correct
  # here: adding a dimension ALSO requires a migration to build its indexes
  # CONCURRENTLY, so it is inherently a deploy-time change, and reading it the same
  # way at compile time makes a config/index mismatch impossible to introduce by
  # editing runtime config alone.
  # Fallback is [768, 1024, 1536] — NOT [..., 3072] (review). 3072 is above pgvector's
  # 2000-dimension HNSW ceiling and is deliberately excluded from the configured set
  # (config/config.exs), so a fallback that listed it would — if the config key were
  # ever absent — advertise 3072 on `.well-known`, build no index for it, and let the
  # query builder emit an unindexable `(embedding::vector(3072))` cast that
  # sequential-scans the corpus (the #170/#172 planner incident class).
  @supported_dimensions Application.compile_env(
                          :loopctl,
                          :supported_embedding_dimensions,
                          [768, 1024, 1536]
                        )

  @doc "The compile-time supported-dimension set this module can emit a cast for."
  @spec supported_dimensions() :: [pos_integer()]
  def supported_dimensions, do: @supported_dimensions

  for dim <- @supported_dimensions do
    # Built here (plain Elixir) and `unquote`d so `fragment/2` receives a LITERAL.
    # The left operand is character-identical to the indexed expression in
    # `Loopctl.Repo.HnswIndex.create_dimension_index_sql/2`; the right operand stays a
    # bound `^[float()]` param (never a re-interpolated `%Pgvector{}` — the #168 500)
    # and resolves to `vector` through the `<=>` operator, which is enough for the
    # planner to choose the per-dimension index (verified with EXPLAIN).
    cast_fragment = "(?::vector(#{dim})) <=> ?"

    defp dimension_order_by(query, unquote(dim), target) do
      order_by(query, [x], asc: fragment(unquote(cast_fragment), x.embedding, ^target))
    end
  end

  # NO raising fallback here (unlike `dimension_where/2`): in the ONLY caller,
  # `index_safe_dimension_knn_base/6` runs `dimension_where/2` — the single validation
  # gate — FIRST, which already raises for an unsupported dimension. A fallback here
  # would be unreachable dead code (dialyzer `pattern_match_cov`), since the type is
  # narrowed to the supported literal set by the time `dimension_order_by/3` is reached.

  # ONE clause per SUPPORTED dimension, generated at COMPILE TIME — the `dim` predicate
  # must be a LITERAL, not a bound `^dimension` param (review, finding 1).
  #
  # The per-dimension partial HNSW index carries a LITERAL partial predicate
  # (`WHERE dim = 768 AND live_denorm`, `Loopctl.Repo.HnswIndex.create_dimension_index_sql/2`).
  # Under a Postgres GENERIC plan (`plan_cache_mode=auto` flips a prepared statement to
  # generic after ~5 executions) the planner cannot PROVE `dim = $1` implies `dim = 768`, so
  # a bound `dim == ^dimension` disqualifies the partial index and the query reverts to a
  # seq-scan + sort over the whole vector relation — the exact #170/#172 outage this module
  # exists to prevent. Emitting `dim = 768` as a compile-time literal (the same closed,
  # compile-time set `dimension_order_by/3` draws its literal cast from) makes the predicate
  # match the index's literal predicate regardless of plan_cache_mode. An unsupported
  # dimension hits the raising fallback rather than planning a seq scan.
  for dim <- @supported_dimensions do
    defp dimension_where(query, unquote(dim)) do
      where(query, [x], x.dim == unquote(dim))
    end
  end

  defp dimension_where(_query, dimension) do
    raise ArgumentError,
          "embedding dimension #{inspect(dimension)} is not supported by this instance " <>
            "(supported: #{inspect(@supported_dimensions)}). A dimension is only supported " <>
            "once its per-dimension HNSW indexes have been built by a migration — index DDL " <>
            "is operator/migration plane only."
  end

  @doc """
  Merges the raw cosine `:distance` onto a SIDE-TABLE pool query's map selection,
  using the same explicit per-dimension cast as `index_safe_dimension_knn_base/5`.

  The only other home of the `<=>` literal for the side tables, keeping the
  single-home invariant the cosine-reintroduction lint enforces.
  """
  @spec put_dimension_distance(Ecto.Query.t(), pos_integer(), [float()]) :: Ecto.Query.t()
  def put_dimension_distance(query, dimension, target)
      when is_integer(dimension) and is_list(target) do
    dimension_distance_select(query, dimension, target)
  end

  for dim <- @supported_dimensions do
    distance_fragment = "(?::vector(#{dim})) <=> ?"

    defp dimension_distance_select(query, unquote(dim), target) do
      select_merge(query, [x], %{
        distance: fragment(unquote(distance_fragment), x.embedding, ^target)
      })
    end
  end

  defp dimension_distance_select(_query, dimension, _target) do
    raise ArgumentError, "embedding dimension #{inspect(dimension)} is not supported"
  end

  @doc """
  The SIDE-TABLE form of the `MIN(embedding <=> $const)` novelty aggregate.

  Postgres rewrites `MIN(x <=> $const)` into `ORDER BY (x <=> $const) LIMIT 1`, so
  this is index-servable exactly like the ordering forms above — provided the cast
  is character-identical to the indexed expression, which is why it is generated
  from the same compile-time dimension set and lives here rather than in a caller.
  """
  @spec put_dimension_min_distance(Ecto.Query.t(), pos_integer(), [float()]) :: Ecto.Query.t()
  def put_dimension_min_distance(query, dimension, target)
      when is_integer(dimension) and is_list(target) do
    dimension_min_distance_select(query, dimension, target)
  end

  for dim <- @supported_dimensions do
    min_fragment = "MIN((?::vector(#{dim})) <=> ?)"

    defp dimension_min_distance_select(query, unquote(dim), target) do
      select(query, [x], fragment(unquote(min_fragment), x.embedding, ^target))
    end
  end

  defp dimension_min_distance_select(_query, dimension, _target) do
    raise ArgumentError, "embedding dimension #{inspect(dimension)} is not supported"
  end

  @doc """
  Merges the raw cosine `:distance` (`embedding <=> $target`) onto `query`'s map
  selection.

  This is the centralized home for the distance projection so a schema-parameterized
  caller (agent-memory recall, which needs the raw distance to compute its own score)
  never hand-rolls the `<=>` literal outside this module — keeping the single-home
  invariant the cosine-reintroduction lint enforces. `query` must already carry a MAP
  `select` (the `:distance` key is merged into it); `target` is a bound `[float()]` list.
  """
  @spec put_distance(Ecto.Query.t(), [float()]) :: Ecto.Query.t()
  def put_distance(query, target) when is_list(target) do
    select_merge(query, [x], %{distance: fragment("? <=> ?", x.embedding, ^target)})
  end

  # Status equality on the inner ANN (index-safe, like the tenant/not-null filters).
  # NIL-SKIPPING to match `Loopctl.Knowledge.maybe_filter_by_status/2` and the
  # search_semantic COUNT path: `status: nil` means "all statuses" (no filter), so the
  # inner pool and the separate full-corpus count stay over the SAME population — without
  # this, `status == ^nil` would match nothing and a `status: nil` semantic search would
  # return empty results against a non-zero total_count. Suggested-links / the worker pass
  # no `:status`, so they keep the default `:published`.
  defp maybe_filter_by_status(query, nil), do: query

  defp maybe_filter_by_status(query, status),
    do: where(query, [a], a.status == ^status)

  # The index-safe inner's SELECT list. Varies by consumer but NEVER touches the
  # HNSW-load-bearing WHERE/ORDER BY/LIMIT above.
  defp pool_select(base, :knn, target) do
    select(base, [a], %{
      id: a.id,
      title: a.title,
      category: a.category,
      tags: a.tags,
      project_id: a.project_id,
      similarity_score: fragment("GREATEST(0, 1 - (? <=> ?))", a.embedding, ^target)
    })
  end

  defp pool_select(base, :semantic, target) do
    select(base, [a], %{
      id: a.id,
      tenant_id: a.tenant_id,
      project_id: a.project_id,
      title: a.title,
      category: a.category,
      status: a.status,
      tags: a.tags,
      # source_type is projected for lane-shape symmetry, NOT for ranking and not for any
      # search response: the source-type authority prior was removed on 2026-08-21 (see
      # RankingPriors, note above @kill_tag).
      source_type: a.source_type,
      # idempotency_key feeds the MOC-hub demotion in the same place (#654 follow-up).
      idempotency_key: a.idempotency_key,
      metadata: a.metadata,
      inserted_at: a.inserted_at,
      updated_at: a.updated_at,
      similarity_score: fragment("1 - (? <=> ?)", a.embedding, ^target)
    })
  end

  # The outer query over the over-fetched pool. Kept as its own clause so the
  # anti-join + tag/category post-filters can be added against the `c` binding.
  defp outer_query(candidates) do
    from(c in subquery(candidates),
      select: %{
        id: c.id,
        title: c.title,
        category: c.category,
        similarity_score: c.similarity_score
      }
    )
  end

  # --- inner (index-residual) filters: equality / membership only, no distance ---

  defp maybe_exclude_self(query, nil), do: query

  defp maybe_exclude_self(query, exclude_id) when is_binary(exclude_id),
    do: where(query, [a], a.id != ^exclude_id)

  defp maybe_filter_by_tags(query, nil), do: query
  defp maybe_filter_by_tags(query, []), do: query

  defp maybe_filter_by_tags(query, tags) when is_list(tags),
    do: where(query, [a], fragment("? && ?", a.tags, ^tags))

  defp maybe_filter_by_category(query, nil), do: query

  defp maybe_filter_by_category(query, category) do
    # `category` is a single index-safe equality (no cost amplification), but an
    # unknown atom would make Ecto.Enum raise on dump. Validate against the Article
    # enum and IGNORE an unknown value (consistent with clamping other bad caller
    # input) rather than 500 — only the 5 real categories ever reach the query.
    if category in Ecto.Enum.values(Article, :category) do
      where(query, [a], a.category == ^category)
    else
      query
    end
  end

  # Strict project equality on the OUTER pool (the `search_semantic` form, mirroring
  # Loopctl.Knowledge.maybe_filter_by_project_id/2). On the over-the-pool `c` binding,
  # never the inner ANN — `project_id` is part of the
  # `articles(tenant_id, project_id, category)` btree, so a selective `project_id =` on
  # the index-ordered subquery would defeat HNSW (same class as tags/category).
  defp maybe_filter_by_project(query, nil), do: query

  defp maybe_filter_by_project(query, project_id) when is_binary(project_id) do
    # Guard the :binary_id cast (defense in depth — the search controller 4xxs a
    # malformed project_id first). A non-UUID value matches nothing, mirroring
    # Loopctl.Knowledge.maybe_filter_by_project_id/2, rather than CastError-500.
    if valid_uuid?(project_id) do
      where(query, [c], c.project_id == ^project_id)
    else
      where(query, [c], false)
    end
  end

  # "Same-project OR tenant-wide" project scope on the OUTER pool — the auto-link
  # worker's `scope_by_project/2` semantics (US-21.2.3): a project-scoped source
  # compares against same-project AND tenant-wide (`project_id IS NULL`) rows. `nil`
  # (a tenant-wide source) is a no-op (compare against everything), matching the
  # worker's nil clause exactly. Applied over the pool for the same btree reason as
  # `maybe_filter_by_project/2`.
  defp maybe_filter_by_project_or_global(query, nil), do: query

  defp maybe_filter_by_project_or_global(query, project_id) when is_binary(project_id) do
    # Guard the :binary_id cast. A malformed value scopes to tenant-wide
    # (`project_id IS NULL`) rows only rather than CastError-500.
    if valid_uuid?(project_id) do
      where(query, [c], c.project_id == ^project_id or is_nil(c.project_id))
    else
      where(query, [c], is_nil(c.project_id))
    end
  end

  # Same agent-visibility metadata predicate as the other knowledge reads
  # (Loopctl.Knowledge.maybe_filter_by_visibility/2), on the `[a]` binding.
  defp maybe_filter_by_visibility(query, nil), do: query

  defp maybe_filter_by_visibility(query, agent_id) when is_binary(agent_id) do
    where(
      query,
      [a],
      fragment("COALESCE(?->>'visibility', 'shared') NOT IN ('private','owner')", a.metadata) or
        fragment("?->>'agent_id' = ?", a.metadata, ^agent_id)
    )
  end

  # Only ever called from the `is_binary(project_id)`-guarded clauses above, so a
  # single binary clause suffices (a catch-all would be dead code).
  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  # --- outer (over-the-pool) anti-join: already-linked, both directions ---

  defp maybe_exclude_linked(query, _tenant_id, _anchor, false), do: query

  defp maybe_exclude_linked(query, tenant_id, anchor, true) do
    from(c in query,
      left_join: l in ArticleLink,
      on:
        l.tenant_id == ^tenant_id and
          ((l.source_article_id == ^anchor and l.target_article_id == c.id) or
             (l.target_article_id == ^anchor and l.source_article_id == c.id)),
      where: is_nil(l.id)
    )
  end

  # --- cost bounds (AC-27.6a.4) ---

  defp clamp_k(k) when is_integer(k), do: k |> max(1) |> min(max_k())
  defp clamp_k(_), do: 1

  # Over-fetch pool for the inner ANN subquery. A `:pool` override (when a positive
  # integer) replaces the `k * factor` base but is STILL clamped by the floor/cap and
  # floored at `k` (so an override can't bust the cap or starve below `k`). With no
  # override it is the config-driven `pool_size/2` (k*factor |> max(floor) |> min(cap)
  # |> max(k)) — the SAME sizing as the live `suggested_links` path.
  defp candidate_pool(k, override) when is_integer(override) and override > 0 do
    # An explicit override acts as the base (in place of k*factor): floor it for the
    # small-k case, cap it, and never let it drop below k.
    override
    |> max(pool_floor())
    |> min(max_pool())
    |> max(k)
  end

  defp candidate_pool(k, _override), do: pool_size(k)

  defp clamp_threshold(t) when is_number(t), do: t |> max(0.0) |> min(1.0) |> :erlang.float()
  defp clamp_threshold(_), do: 0.0

  defp clamp_tags(nil), do: nil
  defp clamp_tags(tags) when is_list(tags), do: Enum.take(tags, max_tags())
  defp clamp_tags(_), do: nil

  # The HNSW-indexable cosine form binds the target as a plain `[float()]` list (the
  # value shape `search_semantic` binds), NEVER the stored `%Pgvector{}` struct —
  # re-interpolating that struct was the #168 production 500.
  @doc false
  @spec to_embedding_list(target_embedding()) :: [float()]
  def to_embedding_list(%Pgvector{} = vector), do: Pgvector.to_list(vector)
  def to_embedding_list(vector) when is_list(vector), do: vector

  # Per-read heavy-read options. Delegates to the SINGLE source of truth, `HeavyRead.opts/1`
  # (US-27.13), so this read carries the `:vector_search` server-side statement_timeout
  # (per-endpoint override else the pool default, applied via SET LOCAL) AND the endpoint key
  # for slow-query telemetry — rather than hand-rolling a list that drifts from every other
  # heavy consumer. `HeavyRead.opts/1` carries the 15s client-timeout backstop itself.
  #
  # US-37.5: a caller MAY pass `on_overload: :tag` (or `:raise`) in `nearest/4`'s opts to
  # choose the over-cap disposition. `:tag` makes the shed return
  # `{:error, :heavy_read_overloaded}` (the graceful-degrade path — the ProposalGate
  # write-back gate falls OPEN, the auto-link worker snoozes) instead of raising a 429.
  # Absent, it defaults to `HeavyRead`'s `:raise` (a plain API kNN read → 429).
  defp heavy_read_opts(opts) do
    base = HeavyRead.opts(:vector_search)

    case Keyword.fetch(opts, :on_overload) do
      {:ok, disposition} -> Keyword.put(base, :on_overload, disposition)
      :error -> base
    end
  end
end
