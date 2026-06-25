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
  a response-`meta` flag when the pool was filled to cap but filters cut it below
  `k` (see that function + `Loopctl.TelemetryEvents.vector_search_under_fill/0`).
  The event's `excluded_total` measurement is the COMBINED post-ANN exclusion count
  (anti-join + threshold); a per-reason split is deferred to US-27.15 because
  separating the two would cost an extra per-request read (AC-27.6b.5 cost bound).

  **Raising recall is deliberately NOT done per-request here.** `hnsw.ef_search` is
  a pgvector **custom GUC** that does not exist until the extension loads per
  session, so it **cannot** be set via a Postgrex startup `:parameters` entry
  (managed PG rejects it: *"unrecognized configuration parameter"* — see
  `docs/runbooks/knowledge-scale.md`). Setting it per-request would require a
  `SET LOCAL` inside a transaction, re-introducing the #172 pool-starvation
  anti-pattern on the small heavy-read pool. The only safe non-transaction lever is
  `ALTER ROLE <heavy_read_role> SET hnsw.ef_search = N` (US-27.11), and only if
  verified to apply on fly mpg. Until then recall stays at the default and is
  handled by **over-fetch + the under-fill signal**.

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

  ## No per-request transaction (AC-27.6a.6)

  `nearest/4` is a bare `HeavyRead.all/3` (no `:statement_timeout` override), i.e.
  a bare pool read with no enclosing transaction — matching
  `search_semantic`/`distant_pairs`, and avoiding the #172 round-1 pool-starvation
  anti-pattern on the small admin pool.
  """

  import Ecto.Query

  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink

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

  # Maximum number of tag values accepted in a `:tags` overlap filter, so a caller
  # can't pass an unbounded array literal into the index-residual `&&` predicate.
  @default_max_tags 50

  # Client-side timeout backstop for the heavy read (US-27.4 pattern). The
  # server-side statement_timeout (pool-level) is the real cap; this is a ceiling
  # above it so a hung connection can't pin a process forever.
  @client_timeout_ms 15_000

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

  A bare `HeavyRead.all/3` (no `:statement_timeout` override) — a pool read with
  NO per-request transaction (AC-27.6a.6).

  See `candidate_query/4` for the parameters and `opts`. All cost-affecting params
  are clamped to their documented bounds before the query is built (AC-27.6a.4).

  `target_embedding` is a plain `[float()]` list or a `%Pgvector{}` — normalized to
  a bound `^[float()]` param via `to_embedding_list/1` (never the struct — #168).
  """
  @spec nearest(Ecto.UUID.t(), target_embedding(), pos_integer(), keyword()) :: [
          candidate()
        ]
  def nearest(tenant_id, target_embedding, k, opts \\ []) when is_binary(tenant_id) do
    query = candidate_query(tenant_id, target_embedding, k, opts)
    HeavyRead.all(tenant_id, query, heavy_read_opts())
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
    target = to_embedding_list(target_embedding)
    k = clamp_k(k)
    pool = candidate_pool(k, Keyword.get(opts, :pool))
    threshold = clamp_threshold(Keyword.get(opts, :threshold, 0.0))

    exclude_id = Keyword.get(opts, :exclude_id)
    exclude_linked? = Keyword.get(opts, :exclude_linked, false) and is_binary(exclude_id)
    tags = clamp_tags(Keyword.get(opts, :tags))
    category = Keyword.get(opts, :category)
    vis = Keyword.get(opts, :visibility_agent_id)

    # INNER: pure index-ordered ANN. ONLY filters that are verified (at 80k scale,
    # vector_search_scale_test) to keep the HNSW Index Scan: tenant/status/not-null
    # equalities, the single-row self-exclusion, and the visibility metadata->>
    # Filter. Visibility is index-safe by OPERATOR CLASS, not by selectivity: the
    # `metadata->>'key' = ...` / COALESCE form cannot be served by the articles
    # `jsonb_ops` GIN (it only answers @>/?), and there is no btree expression index on
    # it — so the planner can ONLY apply it as a Filter-after-HNSW-index, at ANY
    # selectivity (same as the prod-verified suggested_links inner query). DO NOT add a
    # btree/expression index on the visibility/agent_id metadata path or rewrite this to
    # a GIN-servable `metadata @> ...` form — that would let a selective scope flip the
    # planner off HNSW. `tags`/`category` are DELIBERATELY NOT here: they HAVE GIN/btree
    # indexes, so a selective tags&&/category= predicate makes the planner
    # BitmapAnd-then-Sort and ABANDON the HNSW index (the #170/#172 failure mode —
    # proven by EXPLAIN at scale). They are applied on the OUTER pool instead.
    candidates =
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.status == :published,
        where: not is_nil(a.embedding),
        order_by: [asc: fragment("? <=> ?", a.embedding, ^target)],
        limit: ^pool,
        select: %{
          id: a.id,
          title: a.title,
          category: a.category,
          tags: a.tags,
          similarity_score: fragment("GREATEST(0, 1 - (? <=> ?))", a.embedding, ^target)
        }
      )
      |> maybe_exclude_self(exclude_id)
      |> maybe_filter_by_visibility(vis)

    # OUTER: over the materialized ≤pool rows — tags/category here are trivial filters
    # on a tiny result set (no corpus scan), so they cannot defeat the index.
    candidates
    |> outer_query()
    |> maybe_exclude_linked(tenant_id, exclude_id, exclude_linked?)
    |> maybe_filter_by_tags(tags)
    |> maybe_filter_by_category(category)
    |> where([c], c.similarity_score > ^threshold)
    |> order_by([c], desc: c.similarity_score)
    |> limit(^k)
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

  # Per-read heavy-read options: the 15s CLIENT timeout backstop + the endpoint key
  # for slow-query telemetry (US-27.4). NO `:statement_timeout` override → bare pool
  # read, no per-request transaction (AC-27.6a.6).
  defp heavy_read_opts do
    [timeout: @client_timeout_ms, telemetry_options: [endpoint: :vector_search]]
  end
end
