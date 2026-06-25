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

  `pool` over-fetches well beyond `k` so the outer exclusions rarely starve the
  result; effective recall is additionally bounded by `hnsw.ef_search` (default
  40), consistent with `search_semantic`. (Over-fetch sizing, recall semantics,
  and under-fill monitoring are tuned in US-27.6b — this module is the
  index-correct core + caller-cost bounds + tenant isolation.)

  ## Caller-cost bounds (AC-27.6a.4 — OWASP A06, insecure design)

  Every caller-tunable parameter that affects query cost has a **documented,
  enforced upper bound**. The heavy-read `statement_timeout` is a DESIGNED
  backstop, NOT the primary bound:

    * `k` / limit — clamped to `[1, max_k/0]` (default 100).
    * the over-fetch `pool` — `max(k*5, 100) |> min(max_pool/0) |> max(k)`
      (default cap 500), so the index scan stays cheap regardless of `k`.
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

  @doc "Maximum over-fetch pool (config `:vector_search_max_pool`, default #{@default_max_pool})."
  @spec max_pool() :: pos_integer()
  def max_pool, do: Application.get_env(:loopctl, :vector_search_max_pool, @default_max_pool)

  @doc "Maximum number of `:tags` accepted (config `:vector_search_max_tags`, default #{@default_max_tags})."
  @spec max_tags() :: pos_integer()
  def max_tags, do: Application.get_env(:loopctl, :vector_search_max_tags, @default_max_tags)

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
      * `:tags` — index-residual tag overlap (`&&`) filter on the candidate scan
        (truncated to `max_tags/0`).
      * `:category` — index-residual `category =` filter on the candidate scan.
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
    # Filter (no supporting index, so Filter-after-index — same as the prod-verified
    # suggested_links inner query). `tags`/`category` are DELIBERATELY NOT here: they
    # have GIN/btree indexes, so a selective tags&&/category= predicate makes the
    # planner BitmapAnd-then-Sort and ABANDON the HNSW index (the #170/#172 failure
    # mode — proven by EXPLAIN at scale). They are applied on the OUTER pool instead.
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
        tags: c.tags,
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

  # Over-fetch factor for the inner ANN subquery (mirrors Knowledge.suggestion_candidate_pool/1):
  # scale with `k`, floor for the common small `k`, cap so the index scan stays cheap,
  # and never below `k` (a misconfigured cap must not truncate before the outer filters).
  defp candidate_pool(k, override) do
    base = override_pool(override, k)

    base
    |> max(100)
    |> min(max_pool())
    |> max(k)
  end

  defp override_pool(nil, k), do: k * 5
  defp override_pool(p, _k) when is_integer(p) and p > 0, do: p
  defp override_pool(_p, k), do: k * 5

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
