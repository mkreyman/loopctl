defmodule Loopctl.Memory do
  @moduledoc """
  Context for the agent-memory subsystem (Epic 28, Part 1).

  Two persistence substrates, kept strictly separate from the Knowledge Wiki:

  - `Loopctl.Memory.SessionMemory` — short-term, append-only, expiring working
    memory (no embedding).
  - `Loopctl.Memory.Memory` — long-term, `vector(1536)`-embedded, HNSW-recalled
    memory.

  US-28.2 adds the public write/read API — `remember/2`, `recall/2`, `forget/2`,
  `list/2`, `session_history/2`, `supersede/3` — plus the two Oban workers
  (`Loopctl.Workers.MemoryEmbeddingWorker`, `Loopctl.Workers.SessionMemoryPruneWorker`).

  ## Scope

  Every public function takes a `Loopctl.Memory.Scope` (`tenant_id`, `subject_id`,
  optional `project_id`) as its first argument. `tenant_id`/`subject_id` are the
  isolation boundary and are set programmatically — never from request params.

  ## The two persistence tiers + the repo split

  - OLTP writes/list/forget/session_history/supersede go through `Loopctl.AdminRepo`
    with EXPLICIT `(tenant_id, subject_id)` predicates on every query — mirroring the
    sibling `Loopctl.Knowledge` context (which likewise routes all article OLTP
    through `AdminRepo`). `AdminRepo` connects with a BYPASSRLS role, so the
    `memories` / `session_memories` RLS policies do NOT engage on ANY path in this
    context: the explicit `(tenant_id, subject_id)` predicate is the ONLY isolation
    here, not a second layer behind RLS. (The RLS policies exist for a HYPOTHETICAL
    RLS-enforcing `Loopctl.Repo` caller; this context has none. A maintainer relaxing
    an explicit predicate cannot lean on an RLS backstop that is not engaged.)
  - `recall/2` runs an HNSW cosine kNN over long-term memories on the BYPASSRLS
    `Loopctl.HeavyReadRepo` — reached ONLY through `Loopctl.HeavyRead.all_memory/4`,
    whose structural guard requires an explicit `(tenant_id, subject_id)` predicate
    (both tenant and subject isolation are application-level on that pool, not RLS).

  ## `subject_id` — the memory scope owner

  Every memory row is owned by a `subject_id` string resolved SERVER-SIDE from
  the caller's API key — never accepted from request params. See
  `subject_id_for/1`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Memory.Scope
  alias Loopctl.Memory.SessionMemory
  alias Loopctl.Workers.MemoryEmbeddingWorker

  @default_recall_k 10
  @default_list_limit 50
  @max_list_limit 200

  @typedoc "The pinned result envelope every read path returns."
  @type result_envelope :: %{results: list(), meta: map()}

  # ===========================================================================
  # Write path
  # ===========================================================================

  @doc """
  Writes a memory in `scope`, choosing the tier from `attrs[:tier]`:

    * `:session` (short-term) — appends a `Loopctl.Memory.SessionMemory`
      (requires `session_id`, `content`, `expires_at`). No embedding.
    * `:long_term` (default) — inserts a `Loopctl.Memory.Memory` (requires
      `text`) and enqueues `Loopctl.Workers.MemoryEmbeddingWorker` (the
      `embedding` starts NULL and is populated asynchronously).

  `tenant_id`, `subject_id`, and `project_id` come from `scope` and are set
  programmatically on the struct — never cast from `attrs`. A long-term write is
  refused with `{:error, :quota_exceeded}` once the per-`(tenant, subject)` cap
  (`:max_long_term_memories_per_subject`, default 10_000) is reached. The cap counts
  ONLY live (non-superseded) rows, so it bounds the recallable tier; superseded rows
  are intentionally uncounted and thus not directly capped (see `long_term_count/2`
  for that stated tradeoff and its bounds). The cap check + insert + embedding enqueue
  run in one advisory-locked transaction, so the cap is race-free under concurrent
  same-subject writers and the enqueue is atomic with the write. The API-layer
  RateLimiter (US-28.3) sits in front of this path.
  """
  @spec remember(Scope.t(), map()) ::
          {:ok, MemorySchema.t() | SessionMemory.t()}
          | {:error, Ecto.Changeset.t() | :quota_exceeded}
  def remember(%Scope{} = scope, attrs) when is_map(attrs) do
    case normalize_tier(opt(attrs, :tier, :long_term)) do
      :session -> remember_session(scope, attrs)
      :long_term -> remember_long_term(scope, attrs)
    end
  end

  defp remember_session(scope, attrs) do
    %SessionMemory{
      tenant_id: scope.tenant_id,
      subject_id: scope.subject_id,
      project_id: scope.project_id
    }
    |> SessionMemory.create_changeset(attrs)
    |> AdminRepo.insert()
  end

  # A fixed advisory-lock NAMESPACE (the first of the two int4 keys) so the memory
  # quota lock can never collide with an unrelated single-bigint or differently-keyed
  # advisory lock elsewhere. Computed at compile time from a stable term.
  @long_term_quota_lock_ns :erlang.phash2(:loopctl_memory_long_term_quota)

  # The cap check, the insert, AND the embedding enqueue run in ONE AdminRepo
  # transaction (via Ecto.Multi), so:
  #
  #   * the enqueue is GENUINELY ATOMIC with the write — and, critically, on the SAME
  #     connection. It uses `Oban.insert/3` (the Multi-aware variant), NOT the bare
  #     `Oban.insert/1`. `Oban.insert/1` would insert the `oban_jobs` row through
  #     Oban's CONFIGURED repo (`Loopctl.Repo`, config/config.exs) — a DIFFERENT
  #     pool/connection than this `AdminRepo` transaction — so the job would commit
  #     independently BEFORE (or without) the memory row, and a commit-window race
  #     could dispatch the worker against a not-yet-committed memory (the worker reads
  #     `not_found -> :ok`, a terminal no-op), stranding a NULL-embedding memory with
  #     no pending job, permanently invisible to semantic recall. `Oban.insert/3`
  #     instead adds an `Ecto.Multi.run` step that rebinds `conf.repo` to the repo the
  #     Multi executes on (AdminRepo here — see deps/oban engine `insert_job/5`), so
  #     the job row is written on the SAME AdminRepo connection inside this
  #     transaction and commits atomically with the memory (and it still applies the
  #     worker's `unique` contract, unlike a raw `Multi.insert` of the changeset). If
  #     the enqueue fails, the `:embedding_job` step returns `{:error, _}` and the
  #     whole transaction rolls back — a row can NEVER persist with `embedding: NULL`
  #     and no scheduled worker. In the `:inline` test engine the worker runs
  #     synchronously in this same transaction/connection and reads the just-inserted
  #     (uncommitted) row.
  #   * a transaction-scoped advisory lock (`:quota` step), keyed on the fixed
  #     namespace + the (tenant, subject) hash, SERIALIZES concurrent writers for the
  #     same subject so the count-then-insert cap (AC-28.2.1) is race-free — without it
  #     two writers under READ COMMITTED could each observe `count = cap - 1` and both
  #     insert past the cap. The lock auto-releases at COMMIT/ROLLBACK.
  defp remember_long_term(scope, attrs) do
    Multi.new()
    |> Multi.run(:quota, fn repo, _changes ->
      lock_long_term_quota!(repo, scope)

      if long_term_count(repo, scope) >= max_long_term_memories() do
        {:error, :quota_exceeded}
      else
        {:ok, :ok}
      end
    end)
    |> Multi.insert(:memory, long_term_changeset(scope, attrs))
    |> Oban.insert(:embedding_job, fn %{memory: memory} ->
      MemoryEmbeddingWorker.new(%{memory_id: memory.id, tenant_id: memory.tenant_id})
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{memory: memory}} -> {:ok, memory}
      {:error, :quota, :quota_exceeded, _changes} -> {:error, :quota_exceeded}
      {:error, :memory, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, :embedding_job, reason, _changes} -> {:error, reason}
    end
  end

  defp long_term_changeset(scope, attrs) do
    %MemorySchema{
      tenant_id: scope.tenant_id,
      subject_id: scope.subject_id,
      project_id: scope.project_id
    }
    |> MemorySchema.create_changeset(attrs)
  end

  # Serialize concurrent long-term writes for the SAME (tenant, subject) inside the
  # quota transaction. `pg_advisory_xact_lock(int4, int4)` — the two-int form so the
  # fixed namespace key isolates this lock class. Auto-released at COMMIT/ROLLBACK.
  defp lock_long_term_quota!(repo, scope) do
    key = :erlang.phash2({scope.tenant_id, scope.subject_id})
    repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@long_term_quota_lock_ns, key])
  end

  # Count of the subject's LIVE (non-superseded) long-term memories in scope.
  #
  # NB (tier-footprint tradeoff, by design): superseded rows are DELIBERATELY excluded
  # from the cap — the cap bounds the LIVE, recallable tier, matching the documented
  # `non-superseded rows` contract. A subject can therefore accumulate superseded rows
  # beyond the live cap via repeated create-then-supersede (each superseded row still
  # holds text + a 1536-d embedding). Growth is bounded by churn (every supersede
  # requires a live, counted `new_id`) and `forget/2` deletes rows outright; a
  # superseded-row cleanup worker is out of scope for US-28.2 and tracked with the
  # subsystem's pruning story. This is a stated tradeoff, not a contradiction.
  defp long_term_count(repo, scope) do
    MemorySchema
    |> where(
      [m],
      m.tenant_id == ^scope.tenant_id and m.subject_id == ^scope.subject_id and
        is_nil(m.superseded_by)
    )
    |> repo.aggregate(:count, :id)
  end

  # ===========================================================================
  # Recall (HNSW kNN over long-term memories, BYPASSRLS heavy-read pool)
  # ===========================================================================

  @doc """
  Recalls the top-`k` long-term memories for `scope` most similar to
  `opts[:query]` (cosine), via an HNSW kNN on `Loopctl.HeavyReadRepo`.

  Isolation is an EXPLICIT `(tenant_id, subject_id)` predicate enforced by
  `Loopctl.HeavyRead.all_memory/4`'s structural guard. Superseded rows are
  excluded unless `opts[:include_superseded]` is true.

  ## Index-safety (AC-28.2.3)

  A selective `(tenant_id, subject_id)` btree on the inner index-ordered subquery
  defeats the HNSW ANN index (#170/#172). So this uses OPTION (i): the inner pool
  over-fetches `k' > k` nearest-by-cosine with ONLY index-safe residual filters
  (tenant equality + `embedding IS NOT NULL`), and the SUBJECT scope is applied on
  the OUTER query over the materialized pool. The scale behaviour (a subject recalls
  its own top-k when other subjects dominate the corpus) is verified in the terminal
  story US-28.5.

  Superseded exclusion is handled differently: on the default path the inner ANN adds
  `superseded_by IS NULL`, served by the PARTIAL HNSW index
  `memories_live_embedding_hnsw_idx` (whose predicate exactly matches, so HNSW is
  kept), so superseded rows never occupy pool slots and default recall does not
  under-fill with live rows for a heavily-superseding subject. `include_superseded:
  true` uses the full index. `meta.underfilled` is `true` when fewer than the
  requested `k` rows were recalled (a small live scope OR cross-subject pool
  under-fill) so callers can distinguish it from a genuinely capped page.

  ## Degradation (AC-28.2.4)

  When embedding generation is unavailable (circuit open / no key / provider
  error), recall falls back to a recent-first ILIKE text match within the same
  `(tenant_id, subject_id)` scope and returns `meta.fallback: true` with a stable
  `meta.reason` tag — NEVER a silent empty result. A legitimately empty scope on
  the healthy path returns `results: []` with `meta.fallback: false, reason: nil`
  (the two zero-result cases are distinguishable).

  Options:

    * `:query` — the query text to embed / ILIKE against (default `""`).
    * `:limit` — max results (clamped to `[1, Loopctl.Knowledge.VectorSearch.max_k/0]`,
      default #{@default_recall_k}).
    * `:include_superseded` — include superseded rows (default `false`).

  Returns `%{results: [{memory, score} | ...], meta: %{total_count, fallback, reason,
  underfilled}}`.
  """
  @spec recall(Scope.t(), keyword() | map()) :: result_envelope()
  def recall(%Scope{} = scope, opts \\ []) do
    query_text = to_string(opt(opts, :query, ""))
    k = clamp_k(opt(opts, :limit, @default_recall_k))
    include_superseded? = truthy?(opt(opts, :include_superseded, false))

    case Knowledge.generate_embedding(scope.tenant_id, query_text) do
      {:ok, embedding} ->
        recall_semantic(scope, embedding, k, include_superseded?)

      {:error, reason} ->
        recall_fallback(scope, reason, query_text, k, include_superseded?)
    end
  end

  defp recall_semantic(scope, embedding, k, include_superseded?) do
    query = memory_candidate_query(scope, embedding, k, include_superseded?)

    rows =
      HeavyRead.all_memory(
        scope.tenant_id,
        scope.subject_id,
        query,
        HeavyRead.opts(:memory_recall)
      )

    results =
      Enum.map(rows, fn row ->
        # Clamp to [0, 1]: pgvector cosine distance ranges [0, 2], so a distance > 1
        # would make `1 - distance` NEGATIVE. Mirror VectorSearch's `:knn` score
        # contract (GREATEST of 0 and `1 - distance`) so the [{memory, score}]
        # envelope surfaced to US-28.3/US-28.4 never carries a negative similarity.
        # Ordering is by ascending distance (below), so the clamp cannot reorder.
        {row_to_memory(row), max(0.0, 1.0 - row.distance)}
      end)

    %{
      results: results,
      meta: %{
        total_count: length(results),
        fallback: false,
        reason: nil,
        underfilled: length(results) < k
      }
    }
  end

  # INNER: the pure index-ordered ANN top-`pool` — built through the SHARED,
  # schema-parameterized `Loopctl.Knowledge.VectorSearch.index_safe_knn_base/4` (the
  # single home of the #170/#172-safe HNSW shape) plus its `put_distance/2` for the
  # raw distance, so this path CANNOT drift from the article recall it mirrors and
  # holds no hand-rolled cosine literal of its own. It carries the index-safe
  # residuals (tenant + not-null embedding) PLUS, on the default path, the live-only
  # `superseded_by IS NULL` filter (see `maybe_live_only_inner/2`). Subject is
  # DELIBERATELY absent here — the memories(tenant_id, subject_id) btree would let a
  # selective subject flip the planner off HNSW. OUTER: subject scope (the structural
  # guard REQUIRES this predicate here) + superseded exclusion over the ≤pool rows —
  # trivial filters on a tiny set that cannot defeat the index.
  defp memory_candidate_query(scope, embedding, k, include_superseded?) do
    target = VectorSearch.to_embedding_list(embedding)
    pool = VectorSearch.pool_size(k)

    inner =
      MemorySchema
      |> VectorSearch.index_safe_knn_base(scope.tenant_id, target, pool)
      |> maybe_live_only_inner(include_superseded?)
      |> select([m], %{
        id: m.id,
        tenant_id: m.tenant_id,
        subject_id: m.subject_id,
        project_id: m.project_id,
        text: m.text,
        embedding_content_hash: m.embedding_content_hash,
        confidence: m.confidence,
        source: m.source,
        source_session_id: m.source_session_id,
        tags: m.tags,
        superseded_by: m.superseded_by,
        inserted_at: m.inserted_at,
        updated_at: m.updated_at
      })
      |> VectorSearch.put_distance(target)

    from(c in subquery(inner),
      where: c.subject_id == ^scope.subject_id,
      order_by: [asc: c.distance],
      limit: ^k,
      select: c
    )
    |> maybe_exclude_superseded_sub(include_superseded?)
  end

  # Live-only filter on the INNER index-ordered ANN, applied ONLY on the default
  # (exclude-superseded) path. This is the ONE additional inner predicate that is
  # index-SAFE despite the shared helper's "no extra inner predicate" rule: it EXACTLY
  # matches the partial HNSW index `memories_live_embedding_hnsw_idx`
  # (`... WHERE superseded_by IS NULL`, migration 20260709000300), so the planner
  # serves the ANN from that partial index rather than the full one — superseded rows
  # are not in the index and therefore cannot crowd the top-`pool`, so default recall
  # no longer under-fills with live rows when a subject has churned many supersedes.
  # `include_superseded: true` skips this and uses the full index (all rows wanted).
  defp maybe_live_only_inner(query, true), do: query

  defp maybe_live_only_inner(query, false),
    do: where(query, [m], is_nil(m.superseded_by))

  # Belt-and-suspenders exclusion on the OUTER over-the-pool query. Redundant with
  # `maybe_live_only_inner/2` on the default path (kept so the exclusion is correct
  # even if the inner ever changes) and load-bearing when `include_superseded?` is
  # false but the caller path bypasses the inner filter.
  defp maybe_exclude_superseded_sub(query, true), do: query

  defp maybe_exclude_superseded_sub(query, false),
    do: where(query, [c], is_nil(c.superseded_by))

  # Rebuild a %Memory{} from the recalled projection map. `embedding` is
  # `load_in_query: false` so it is intentionally absent (recall never returns the
  # raw vector); `:distance` is a computed column, dropped before struct build.
  defp row_to_memory(row) do
    struct(MemorySchema, Map.drop(row, [:distance]))
  end

  defp recall_fallback(scope, reason, query_text, k, include_superseded?) do
    reason_tag = fallback_reason_tag(reason)

    query =
      from(m in MemorySchema,
        where: m.tenant_id == ^scope.tenant_id,
        where: m.subject_id == ^scope.subject_id,
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: ^k
      )
      |> maybe_exclude_superseded_base(include_superseded?)
      |> maybe_ilike(query_text)

    rows =
      HeavyRead.all_memory(
        scope.tenant_id,
        scope.subject_id,
        query,
        HeavyRead.opts(:memory_recall)
      )

    results = Enum.map(rows, fn memory -> {memory, nil} end)

    %{
      results: results,
      meta: %{
        total_count: length(results),
        fallback: true,
        reason: reason_tag,
        underfilled: length(results) < k
      }
    }
  end

  defp maybe_ilike(query, ""), do: query

  defp maybe_ilike(query, text) when is_binary(text) do
    pattern = "%#{escape_like(text)}%"
    where(query, [m], ilike(m.text, ^pattern))
  end

  # Escape LIKE metacharacters so a query containing `%` or `_` is matched
  # literally rather than as a wildcard.
  defp escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # Map a discarded embedding-generation error to a STABLE, non-sensitive tag for
  # `meta.reason` (mirrors Loopctl.Knowledge's fallback tagging). Sanitized via
  # ProviderError first so no api key / provider body can leak.
  defp fallback_reason_tag(reason) do
    case ProviderError.sanitize(reason) do
      :no_api_key -> "no_embedding_key"
      :circuit_open -> "embedding_circuit_open"
      :timeout -> "embedding_timeout"
      {:api_error, status, _} when is_integer(status) -> "embedding_provider_error_#{status}"
      {:api_error, status} when is_integer(status) -> "embedding_provider_error_#{status}"
      {:request_failed, _} -> "embedding_request_failed"
      {:embedding_crash, _} -> "embedding_crash"
      _ -> "embedding_error"
    end
  end

  # ===========================================================================
  # forget / list / session_history / supersede (RLS OLTP path)
  # ===========================================================================

  @doc """
  Deletes a long-term memory by `id`, but ONLY within `scope`.

  A foreign-tenant id (invisible under RLS) or a foreign-subject id returns
  `{:error, :not_found}` — no existence leak. Because `superseded_by` is
  `on_delete: :nilify_all` (US-28.1), deleting a superseder nilifies its
  dependents' back-reference so no memory is left permanently hidden.
  """
  @spec forget(Scope.t(), String.t()) :: {:ok, :deleted} | {:error, :not_found}
  def forget(%Scope{} = scope, id) when is_binary(id) do
    if valid_uuid?(id) do
      {count, _} =
        MemorySchema
        |> where(
          [m],
          m.id == ^id and m.tenant_id == ^scope.tenant_id and
            m.subject_id == ^scope.subject_id
        )
        |> AdminRepo.delete_all()

      if count > 0, do: {:ok, :deleted}, else: {:error, :not_found}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Lists the long-term memories in `scope`, newest first, paginated.

  Options (keyword list or map, atom or string keys):

    * `:limit` — page size (clamped to `[1, #{@max_list_limit}]`, default #{@default_list_limit}).
    * `:offset` — pagination offset (default 0).
    * `:include_superseded` — include superseded rows (default `false`).

  Returns `%{results: [memory], meta: %{total_count, limit, offset}}`. `total_count`
  is the TRUE scoped total (never silently capped by `limit`).
  """
  @spec list(Scope.t(), keyword() | map()) :: result_envelope()
  def list(%Scope{} = scope, opts \\ []) do
    limit = clamp_limit(opt(opts, :limit, @default_list_limit))
    offset = max(to_int(opt(opts, :offset, 0), 0), 0)
    include_superseded? = truthy?(opt(opts, :include_superseded, false))

    base =
      MemorySchema
      |> where([m], m.tenant_id == ^scope.tenant_id and m.subject_id == ^scope.subject_id)
      |> maybe_exclude_superseded_base(include_superseded?)

    total = AdminRepo.aggregate(base, :count, :id)

    results =
      base
      |> order_by([m], desc: m.inserted_at, desc: m.id)
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    %{results: results, meta: %{total_count: total, limit: limit, offset: offset}}
  end

  @doc """
  Lists ALL subjects' long-term memories in `tenant_id`, newest first, paginated.

  Superadmin oversight path (US-28.3 AC-28.3.4): unlike `list/2` — which is
  strictly `(tenant_id, subject_id)`-scoped — this reader is tenant-scoped and
  subject-agnostic, so a superadmin key may inspect every subject's memories in
  its OWN tenant. The `tenant_id` predicate is the isolation boundary here (one
  tenant can never see another's rows); the CALLER is responsible for gating this
  to superadmin keys — a non-superadmin must never reach this function.

  Same options and `%{results, meta: %{total_count, limit, offset}}` envelope as
  `list/2`. Runs on `AdminRepo` (BYPASSRLS) with an explicit `tenant_id` predicate,
  mirroring the rest of this context.
  """
  @spec list_all_subjects(String.t(), keyword() | map()) :: result_envelope()
  def list_all_subjects(tenant_id, opts \\ []) when is_binary(tenant_id) do
    limit = clamp_limit(opt(opts, :limit, @default_list_limit))
    offset = max(to_int(opt(opts, :offset, 0), 0), 0)
    include_superseded? = truthy?(opt(opts, :include_superseded, false))

    base =
      MemorySchema
      |> where([m], m.tenant_id == ^tenant_id)
      |> maybe_exclude_superseded_base(include_superseded?)

    total = AdminRepo.aggregate(base, :count, :id)

    results =
      base
      |> order_by([m], desc: m.inserted_at, desc: m.id)
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    %{results: results, meta: %{total_count: total, limit: limit, offset: offset}}
  end

  @doc """
  Deletes a long-term memory by `id` anywhere in `tenant_id`, regardless of which
  subject owns it.

  Superadmin oversight path (US-28.3 AC-28.3.4): unlike `forget/2` — which is
  strictly `(tenant_id, subject_id)`-scoped — this delete is tenant-scoped and
  subject-agnostic, so a superadmin key may delete ANY memory in its OWN tenant.
  A foreign-tenant id (or an invalid UUID) returns `{:error, :not_found}` — no
  existence leak across tenants. The CALLER must gate this to superadmin keys; a
  non-superadmin must never reach it. Runs on `AdminRepo` (BYPASSRLS) with an
  explicit `tenant_id` predicate.
  """
  @spec forget_any(String.t(), String.t()) :: {:ok, :deleted} | {:error, :not_found}
  def forget_any(tenant_id, id) when is_binary(tenant_id) and is_binary(id) do
    if valid_uuid?(id) do
      {count, _} =
        MemorySchema
        |> where([m], m.id == ^id and m.tenant_id == ^tenant_id)
        |> AdminRepo.delete_all()

      if count > 0, do: {:ok, :deleted}, else: {:error, :not_found}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Returns a session's short-term memories for `(scope.tenant_id, opts[:session_id])`
  in insertion order (oldest first), paginated and scope-enforced.

  Options:

    * `:session_id` — the session identifier (required).
    * `:limit` — page size (clamped to `[1, #{@max_list_limit}]`, default #{@default_list_limit}).
    * `:offset` — pagination offset (default 0).

  Returns `%{results: [session_memory], meta: %{total_count, limit, offset}}`.
  """
  @spec session_history(Scope.t(), keyword() | map()) :: result_envelope()
  def session_history(%Scope{} = scope, opts \\ []) do
    session_id = opt(opts, :session_id, nil)
    limit = clamp_limit(opt(opts, :limit, @default_list_limit))
    offset = max(to_int(opt(opts, :offset, 0), 0), 0)

    base =
      SessionMemory
      |> where(
        [s],
        s.tenant_id == ^scope.tenant_id and s.session_id == ^session_id and
          s.subject_id == ^scope.subject_id
      )

    total = AdminRepo.aggregate(base, :count, :id)

    results =
      base
      # `seq` is a DB-generated bigserial (strictly monotonic per insert), so it is
      # the deterministic insertion-order key (AC-28.2.5). `inserted_at` leads for
      # readability; `seq` is the load-bearing tiebreaker that makes same-microsecond
      # appends deterministic where the random binary_id PK could not.
      |> order_by([s], asc: s.inserted_at, asc: s.seq)
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    %{results: results, meta: %{total_count: total, limit: limit, offset: offset}}
  end

  @doc """
  Marks the in-scope memory `old_id` as superseded by `new_id`.

  Both ids must be in `scope`; a foreign/absent id returns `{:error, :not_found}`.
  A superseded memory is excluded from `recall/2` and `list/2` by default.

  ## Concurrency + cycle prevention (AC-28.2.7)

  Both rows are locked `FOR UPDATE` in a stable (id-ordered) single statement, so
  concurrent supersedes on the same row are serialized (no lost update) and cannot
  race into a cycle. The cycle guard requires `new_id` to be a LIVE head (its own
  `superseded_by` is nil): a supersede may only ever point at a live survivor. This
  rejects the direct A↔B cycle AND any longer chain (A→B→C→A) AND superseding into an
  already-superseded row — none of which can leave a set of rows all hidden with no
  live head. `{:error, :cycle}` is returned in every such case. This is stronger than
  the AC-28.2.7 letter (which requires only A↔B + lost-update prevention), and matters
  because the Part 2 auto-promotion compiler (epic_28 #308) drives supersede
  programmatically, making an accidental longer cycle reachable.
  """
  @spec supersede(Scope.t(), String.t(), String.t()) ::
          {:ok, MemorySchema.t()}
          | {:error, :not_found | :self_supersede | :cycle | Ecto.Changeset.t()}
  def supersede(%Scope{} = scope, old_id, new_id)
      when is_binary(old_id) and is_binary(new_id) do
    cond do
      not (valid_uuid?(old_id) and valid_uuid?(new_id)) -> {:error, :not_found}
      old_id == new_id -> {:error, :self_supersede}
      true -> do_supersede(scope, old_id, new_id)
    end
  end

  defp do_supersede(scope, old_id, new_id) do
    AdminRepo.transaction(fn ->
      rows =
        MemorySchema
        |> where(
          [m],
          m.id in ^[old_id, new_id] and m.tenant_id == ^scope.tenant_id and
            m.subject_id == ^scope.subject_id
        )
        |> order_by([m], asc: m.id)
        |> lock("FOR UPDATE")
        |> AdminRepo.all()

      old = Enum.find(rows, &(&1.id == old_id))
      new = Enum.find(rows, &(&1.id == new_id))

      resolve_supersede(old, new, old_id, new_id)
    end)
  end

  # Called only inside the `do_supersede` transaction (rollbacks abort it).
  defp resolve_supersede(old, new, _old_id, new_id) do
    cond do
      is_nil(old) or is_nil(new) ->
        AdminRepo.rollback(:not_found)

      # Cycle guard: a supersede may ONLY point at a LIVE head (`new.superseded_by`
      # is nil). Requiring liveness — rather than only rejecting the direct
      # `new.superseded_by == old_id` (A↔B) case — structurally prevents cycles of
      # ANY length AND refuses superseding into an already-dead `new_id`. In a 3+
      # node cycle (supersede(A,B); supersede(B,C); then supersede(C,A)) the third
      # call has `new = A` with `A.superseded_by == B` (non-nil), so it is rejected
      # here instead of closing A→B→C→A with no live survivor. Both rows are held
      # `FOR UPDATE`, so the liveness read is consistent under concurrent supersedes.
      not is_nil(new.superseded_by) ->
        AdminRepo.rollback(:cycle)

      true ->
        apply_supersede(old, new_id)
    end
  end

  defp apply_supersede(old, new_id) do
    old
    |> Ecto.Changeset.change(superseded_by: new_id)
    |> AdminRepo.update()
    |> case do
      {:ok, memory} -> memory
      {:error, changeset} -> AdminRepo.rollback(changeset)
    end
  end

  # ===========================================================================
  # Worker support (BYPASSRLS AdminRepo — the workers run without a conn scope)
  # ===========================================================================

  @doc """
  Fetches a long-term memory (including its `embedding` + hash) by `id` within
  `tenant_id`, for `Loopctl.Workers.MemoryEmbeddingWorker`. Returns `{:ok, memory}`
  or `{:error, :not_found}`.
  """
  @spec get_memory_for_embedding(String.t(), String.t()) ::
          {:ok, MemorySchema.t()} | {:error, :not_found}
  def get_memory_for_embedding(tenant_id, id) when is_binary(tenant_id) and is_binary(id) do
    query =
      from(m in MemorySchema,
        where: m.id == ^id and m.tenant_id == ^tenant_id,
        select_merge: %{embedding: m.embedding}
      )

    case Loopctl.AdminRepo.one(query) do
      nil -> {:error, :not_found}
      memory -> {:ok, memory}
    end
  end

  @doc """
  Stores `embedding` + `content_hash` on the long-term memory `id` within
  `tenant_id`, via `Loopctl.Memory.Memory.embedding_changeset/3` (the only
  changeset allowed to touch `:embedding`). For the embedding worker.
  """
  @spec update_memory_embedding(String.t(), String.t(), list(number()), String.t()) ::
          {:ok, MemorySchema.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_memory_embedding(tenant_id, id, embedding, content_hash)
      when is_binary(tenant_id) and is_binary(id) do
    case Loopctl.AdminRepo.get_by(MemorySchema, id: id, tenant_id: tenant_id) do
      nil ->
        {:error, :not_found}

      memory ->
        memory
        |> MemorySchema.embedding_changeset(embedding, content_hash)
        |> Loopctl.AdminRepo.update()
    end
  end

  # ===========================================================================
  # shared helpers
  # ===========================================================================

  defp maybe_exclude_superseded_base(query, true), do: query

  defp maybe_exclude_superseded_base(query, false),
    do: where(query, [m], is_nil(m.superseded_by))

  defp normalize_tier(tier) when tier in [:session, :long_term], do: tier
  defp normalize_tier("session"), do: :session
  defp normalize_tier("long_term"), do: :long_term
  defp normalize_tier(_), do: :long_term

  defp max_long_term_memories do
    Application.get_env(:loopctl, :max_long_term_memories_per_subject, 10_000)
  end

  defp clamp_k(k), do: k |> to_int(@default_recall_k) |> max(1) |> min(VectorSearch.max_k())

  defp clamp_limit(limit),
    do: limit |> to_int(@default_list_limit) |> max(1) |> min(@max_list_limit)

  defp to_int(v, _default) when is_integer(v), do: v

  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {int, _} -> int
      :error -> default
    end
  end

  defp to_int(_v, default), do: default

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  # Read an option from a keyword list OR a map (atom or string key).
  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp opt(opts, key, default) when is_map(opts) do
    case Map.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Map.get(opts, to_string(key), default)
    end
  end

  @doc """
  Resolves the `subject_id` (memory scope owner) from an authenticated API key.

  The derivation is pinned and total:

  - For an **agent-role** key with a non-blank `agent_id`, the subject is the
    `agent_id` — so every ephemeral key an agent rotates through shares one
    memory scope.
  - Otherwise (user/orchestrator/superadmin keys, or an agent key without an
    `agent_id`), the subject is the API key's own `id`.

  Because `agent` is the FLOOR role and every authenticated key has a binary_id
  `id`, resolution always yields a non-null, non-blank subject for a real key —
  the `{:error, :subject_id_unresolvable}` path exists only to make the failure
  explicit rather than persist a null-scoped (leak-prone) row.

  ## Examples

      iex> Loopctl.Memory.subject_id_for(%Loopctl.Auth.ApiKey{role: :agent, agent_id: "agent-123", id: "key-1"})
      {:ok, "agent-123"}

      iex> Loopctl.Memory.subject_id_for(%Loopctl.Auth.ApiKey{role: :user, agent_id: nil, id: "key-1"})
      {:ok, "key-1"}
  """
  @spec subject_id_for(ApiKey.t()) :: {:ok, String.t()} | {:error, :subject_id_unresolvable}
  def subject_id_for(%ApiKey{role: :agent, agent_id: agent_id})
      when is_binary(agent_id) and agent_id != "" do
    {:ok, to_string(agent_id)}
  end

  def subject_id_for(%ApiKey{id: id}) when is_binary(id) and id != "" do
    {:ok, to_string(id)}
  end

  def subject_id_for(_), do: {:error, :subject_id_unresolvable}
end
