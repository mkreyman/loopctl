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
  alias Loopctl.Memory.PromotionTelemetry
  alias Loopctl.Memory.Scope
  alias Loopctl.Memory.SessionMemory
  alias Loopctl.Memory.SessionPromotion
  alias Loopctl.Workers.MemoryEmbeddingWorker
  alias Loopctl.Workers.MemoryPromotionWorker

  @default_near_dup_threshold 0.92
  @default_compiles_per_hour 200

  # Near-dup supersede only ever targets a prior `:promoted` memory (never a user's
  # explicit row — see `nearest_live/2`). Recall a small pool rather than the single
  # nearest so an explicit row sitting nearer than a promoted near-dup does not mask it.
  @near_dup_recall_pool 10

  @default_recall_k 10
  @default_list_limit 50
  @max_list_limit 200

  # The reserved subject_id the promotion-quality eval (US-29.5) seeds its synthetic
  # labeled sessions under. It lives HERE — the shared memory context — so the eval, the
  # cross-tenant auto-promotion sweep, and the durable-promotion write path all reference
  # ONE source of truth (`eval_subject_id/0`) instead of duplicating a string literal.
  #
  # Isolation from real subjects is STRUCTURAL, not naming convention:
  # `subject_id_for/1` always returns a UUID *value* (an agent key's `agent_id`, else the
  # key's own id — both UUIDs), and the compile-time guard below fails the build if this
  # sentinel is ever UUID-shaped. So a real subject_id and this value provably cannot
  # collide. (Note: `subject_id` is a `:string` column on both memory schemas — Ecto does
  # NOT reject a non-UUID at the DB layer, which is exactly why the durable-promotion
  # write path must ALSO refuse this subject; see `persist_promotion/2`.)
  @eval_subject_id "__promotion_eval__"

  if match?({:ok, _}, Ecto.UUID.cast(@eval_subject_id)) do
    raise "@eval_subject_id must NOT be a valid UUID — a UUID could collide with a " <>
            "real subject_id (Memory.subject_id_for/1 always returns a UUID)."
  end

  @typedoc "The pinned result envelope every read path returns."
  @type result_envelope :: %{results: list(), meta: map()}

  @doc """
  The reserved `subject_id` under which the promotion-quality eval (US-29.5) seeds its
  synthetic labeled sessions. Deliberately NOT a valid UUID, so it can never collide with
  a real subject (every real `subject_id` from `subject_id_for/1` is a UUID). Every
  durable-promotion write path refuses this subject so a concurrent auto-promotion sweep
  cannot turn eval turns into real `:promoted` memories.
  """
  @spec eval_subject_id() :: String.t()
  def eval_subject_id, do: @eval_subject_id

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
    |> SessionMemory.create_changeset(server_governed_expiry(attrs))
    |> AdminRepo.insert()
  end

  # Session turns MUST outlive the promotion sweep so auto-promotion can compile a
  # session's turns into durable memory BEFORE `SessionMemoryPruneWorker` deletes them
  # (AC-29.2.10 — no silent golden-nugget loss). The SERVER therefore governs the turn
  # lifetime rather than trusting a caller-supplied `expires_at`, which is what makes
  # `assert_promotion_ttl_invariant!/0` load-bearing rather than symbolic — BOTH knobs
  # now govern the real per-row prune deadline:
  #
  #   * `expires_at` absent → defaulted to `now + session_memory_ttl_seconds` (the knob
  #     config.exs documents as "used to set expires_at" — now actually true).
  #   * `expires_at` present but sooner than `now + promotion_sweep_window_seconds` →
  #     FLOORED up to that floor, so a short client TTL can never prune a turn before a
  #     sweep window has elapsed and the sweep/worker can see it.
  #
  # The boot invariant (`sweep_interval < sweep_window < ttl`) then guarantees the default
  # lifetime always clears the floor. A present-but-unparseable `expires_at` is passed
  # through untouched so the changeset surfaces the validation error (we don't mask bad
  # input).
  #
  # CROSS-STORY CONTRACT CHANGE (surfaced deliberately — US-29.2, epic_28 review): this
  # is on the SHARED `remember_session` write path used by the `memory_remember` MCP tool
  # and the memory HTTP API, so it changes the epic_28 session-memory write contract for
  # ALL existing consumers, not just the promoter:
  #
  #   * Retention floor: a caller that deliberately set a SHORT `expires_at` (e.g. 60s for
  #     an ephemeral / privacy-sensitive turn) now gets AT LEAST `sweep_window_seconds`
  #     (default 900s / 15 min) of retention. The floor is the MINIMUM lifetime that lets
  #     the sweep promote the turn; it is bounded (the sweep window, never the full TTL)
  #     and is the smallest value AC-29.2.10 permits. A caller needing a hard, shorter
  #     retention bound for a turn must not persist it as a session memory.
  #   * Optionality: `expires_at` is now OPTIONAL (previously the changeset required it);
  #     omitting it yields the TTL default instead of a validation error. This is additive.
  #
  # Both are intentional and documented at every consumer touchpoint (this moduledoc, the
  # `POST /memory` controller doc, and the config.exs knob comment) so the change is
  # explicit rather than slipped in as a promotion-worker detail.
  defp server_governed_expiry(attrs) do
    now = DateTime.utc_now()
    floor_at = DateTime.add(now, promotion_sweep_window_seconds(), :second)
    default_at = DateTime.add(now, session_memory_ttl_seconds(), :second)
    requested = opt(attrs, :expires_at, nil)

    cond do
      blank_expiry?(requested) ->
        put_expiry(attrs, floor_expiry(default_at, floor_at))

      match?(%DateTime{}, normalize_expiry(requested)) ->
        put_expiry(attrs, floor_expiry(normalize_expiry(requested), floor_at))

      true ->
        attrs
    end
  end

  defp blank_expiry?(nil), do: true
  defp blank_expiry?(""), do: true
  defp blank_expiry?(_), do: false

  defp normalize_expiry(%DateTime{} = dt), do: dt

  defp normalize_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> :error
    end
  end

  defp normalize_expiry(_), do: :error

  defp floor_expiry(%DateTime{} = at, %DateTime{} = floor_at) do
    if DateTime.compare(at, floor_at) == :lt, do: floor_at, else: at
  end

  # Write `expires_at` back into `attrs` in ITS OWN key space — Ecto's `cast/4` raises
  # on a map with mixed atom/string keys, so an atom key must not be spliced into a
  # string-keyed param map (or vice versa).
  defp put_expiry(attrs, value) do
    cond do
      Map.has_key?(attrs, :expires_at) -> Map.put(attrs, :expires_at, value)
      Map.has_key?(attrs, "expires_at") -> Map.put(attrs, "expires_at", value)
      Enum.any?(Map.keys(attrs), &is_atom/1) -> Map.put(attrs, :expires_at, value)
      true -> Map.put(attrs, "expires_at", value)
    end
  end

  # A fixed advisory-lock NAMESPACE (the first of the two int4 keys) so the memory
  # quota lock can never collide with an unrelated single-bigint or differently-keyed
  # advisory lock elsewhere. Computed at compile time from a stable term.
  @long_term_quota_lock_ns :erlang.phash2(:loopctl_memory_long_term_quota)

  # A DISTINCT advisory-lock namespace for the per-tenant promotion-budget reservation
  # (US-29.3 finding fix). Separate from the quota namespace so a promotion reservation
  # and a long-term-quota write for the same subject never collide, and so nested
  # acquisition (a reservation whose inline worker later takes the quota lock in tests)
  # is always ordered budget→quota and cannot deadlock.
  @promotion_budget_lock_ns :erlang.phash2(:loopctl_memory_promotion_budget)

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
        metadata: m.metadata,
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
    |> maybe_scope_project_outer(scope.project_id)
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

  # #411 Gap 2: recall returns the merged `global ∪ active-project` set (mirrors
  # `Loopctl.Knowledge.scope_project_or_global/2`). `project_id` is a PARTITION key,
  # NOT an isolation boundary — `tenant_id`/`subject_id` are (see `Memory.Scope`
  # moduledoc). So a nil scope resolves to global-only (`project_id IS NULL`) and a
  # present project merges global with that project. The `:binary_id` cast is guarded
  # the way Knowledge does it: a malformed (non-UUID) value scopes to global-only
  # rather than raising `Ecto.Query.CastError` (controllers 4xx at the boundary —
  # this is defense in depth). Two arities because Ecto `where` needs the binding
  # position at compile time: the semantic path filters the outer over-the-pool
  # subquery's `[c]` projection, the fallback path filters the base `[m]` table.
  #
  # This predicate MUST stay on the OUTER over-the-pool query (like the subject and
  # superseded filters) — never on `index_safe_knn_base`'s inner ANN, where a
  # selective predicate would flip the planner off the HNSW index.
  defp maybe_scope_project_outer(query, project_id) when is_binary(project_id) do
    if valid_uuid?(project_id) do
      where(query, [c], is_nil(c.project_id) or c.project_id == ^project_id)
    else
      where(query, [c], is_nil(c.project_id))
    end
  end

  defp maybe_scope_project_outer(query, _), do: where(query, [c], is_nil(c.project_id))

  defp maybe_scope_project_base(query, project_id) when is_binary(project_id) do
    if valid_uuid?(project_id) do
      where(query, [m], is_nil(m.project_id) or m.project_id == ^project_id)
    else
      where(query, [m], is_nil(m.project_id))
    end
  end

  defp maybe_scope_project_base(query, _), do: where(query, [m], is_nil(m.project_id))

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
      |> maybe_scope_project_base(scope.project_id)

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
      {:request_failed, _} -> "embedding_request_failed"
      {:embedding_crash, _} -> "embedding_crash"
      other -> api_error_tag(other)
    end
  end

  # US-37.3: an `{:api_error, ...}` (3-tuple, or the throttle 4-tuple carrying a
  # Retry-After) tags by status only; anything else is the generic tag.
  defp api_error_tag({:api_error, status, _, _}) when is_integer(status),
    do: "embedding_provider_error_#{status}"

  defp api_error_tag({:api_error, status, _}) when is_integer(status),
    do: "embedding_provider_error_#{status}"

  defp api_error_tag({:api_error, status}) when is_integer(status),
    do: "embedding_provider_error_#{status}"

  defp api_error_tag(_other), do: "embedding_error"

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
    * `:source` — filter by provenance (`:promoted` | `:explicit`, or the string
      forms; anything else is ignored → no filter). US-29.3 oversight of
      promoted-vs-explicit memories.

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
      |> maybe_filter_source(opt(opts, :source, nil))

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

  Same options (including the `:source` promoted/explicit filter — so a superadmin
  can filter oversight by provenance, US-29.3) and `%{results, meta: %{total_count,
  limit, offset}}` envelope as `list/2`. Runs on `AdminRepo` (BYPASSRLS) with an
  explicit `tenant_id` predicate, mirroring the rest of this context.
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
      |> maybe_filter_source(opt(opts, :source, nil))

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
          | {:error,
             :not_found | :self_supersede | :cycle | :already_superseded | Ecto.Changeset.t()}
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

      # `old` is ALREADY superseded. Overwriting its `superseded_by` pointer would
      # orphan the prior superseder — leaving TWO live heads for one logical fact
      # (reachable via two concurrent supersedes of the same row, e.g. two different
      # sessions of the same subject each promoting a near-dup of `old`). Idempotent when
      # it already points at THIS `new_id`; otherwise refuse rather than clobber.
      not is_nil(old.superseded_by) ->
        if old.superseded_by == new_id,
          do: old,
          else: AdminRepo.rollback(:already_superseded)

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
  # Promotion (Epic 29, Agent Memory Part 2 / auto-promotion — US-29.2)
  # ===========================================================================

  @doc """
  Explicit promotion trigger: enqueues a per-session promotion job for
  `scope.session_id`, enforcing the per-tenant promotion budget FIRST.

  Takes a `%Loopctl.Memory.Scope{}` carrying a `session_id` (the `%{scope | session_id:
  ...}` shape). Refuses `{:error, :budget_exceeded}` — WITHOUT enqueuing and therefore
  WITHOUT any LLM call — when the tenant has already hit its compiles/hour cap
  (`:memory_promotion_compiles_per_hour`), so a spamming agent cycling distinct
  `session_id`s cannot exhaust the tenant's BYO LLM key. On success returns
  `{:ok, %Oban.Job{}}`; a blank/whitespace-only or missing `session_id` returns
  `{:error, :missing_session_id}`.

  ## Budget reservation is ATOMIC (US-29.3 finding fix)

  The budget check and the enqueue run in ONE `AdminRepo` transaction under a
  per-tenant `pg_advisory_xact_lock`, and the used-budget count is
  `compiles-this-hour (watermarks) + in-flight promotion jobs` (jobs already enqueued
  but not yet compiled). Without this, N concurrent promotes of N DISTINCT
  `session_id`s would all read the same pre-burst watermark count, all pass, and all
  enqueue LLM compiles — overshooting the per-hour cap by the in-flight count (a
  TOCTOU). The lock serializes concurrent reservers per tenant, and counting in-flight
  jobs makes each reservation see the slots already claimed by committed peers, so the
  cap holds under concurrency. The lock is held only for the fast count+insert — never
  across the LLM call (that happens later in the async worker).

  The compile + persistence happen in `Loopctl.Workers.MemoryPromotionWorker`; the
  watermark makes an unchanged session a cheap no-op there, and a 0/1-turn session is
  skipped there WITHOUT advancing the watermark, so a junk `session_id` cannot consume
  the budget at zero LLM cost.

  ## `project_id` attribution is best-effort (by design)

  `MemoryPromotionWorker`'s Oban uniqueness is keyed on `(tenant_id, subject_id,
  session_id)` and DELIBERATELY excludes `project_id`, so an explicit trigger and the
  cross-tenant sweep can never double-promote the same session. A consequence: if the
  sweep (which enqueues with `project_id: nil` — sweep-promoted memory is tenant-wide)
  has ALREADY enqueued a job for this session, this explicit call conflicts and Oban
  returns the existing `project_id`-less job, so this caller's `project_id` is dropped
  and the promoted memory is written tenant-wide. This is intentional and safe:
  `project_id` is non-isolation attribution metadata (see `Loopctl.Memory.Scope`), never
  a tenant/subject boundary, so a tenant-wide promotion never leaks across the isolation
  boundary — it only loses the finer project tag. Adding `project_id` to the unique keys
  would instead let the sweep and the explicit trigger BOTH enqueue (distinct keys) and
  double-promote, which is worse; deduping the session wins over preserving the tag.
  """
  @spec promote_session(Scope.t()) ::
          {:ok, Oban.Job.t()} | {:error, :budget_exceeded | :missing_session_id | term()}
  def promote_session(%Scope{session_id: session_id} = scope) when is_binary(session_id) do
    # A whitespace-only session_id (e.g. "   ") is NOT a promotable session: guard on
    # the trimmed value so it takes the same `:missing_session_id` → 422 path as "" and
    # nil, rather than enqueuing a no-op job that would still write a budget-consuming
    # watermark (US-29.3 finding fix).
    if String.trim(session_id) == "" do
      {:error, :missing_session_id}
    else
      reserve_and_enqueue_promotion(scope, session_id)
    end
  end

  def promote_session(%Scope{}), do: {:error, :missing_session_id}

  # Non-terminal Oban states in which a promotion job still holds a claim on the
  # per-hour compile budget (it will yet call the LLM). `discarded`/`cancelled`/
  # `completed` jobs do NOT count — a discarded job never retries, and a completed one
  # has already written its watermark (counted separately).
  @promotion_inflight_states ~w(available scheduled executing retryable)
  @promotion_worker_name "Loopctl.Workers.MemoryPromotionWorker"

  defp reserve_and_enqueue_promotion(scope, session_id) do
    Multi.new()
    |> Multi.run(:budget, fn repo, _changes ->
      lock_promotion_budget!(repo, scope.tenant_id)

      if promotion_budget_used(repo, scope.tenant_id) < promotion_budget() do
        {:ok, :ok}
      else
        {:error, :budget_exceeded}
      end
    end)
    |> Oban.insert(:promotion_job, fn _changes ->
      MemoryPromotionWorker.new(%{
        "tenant_id" => scope.tenant_id,
        "subject_id" => scope.subject_id,
        "project_id" => scope.project_id,
        "session_id" => session_id
      })
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{promotion_job: %Oban.Job{} = job}} ->
        {:ok, job}

      {:error, :budget, :budget_exceeded, _changes} ->
        PromotionTelemetry.emit(:budget_exceeded, %{count: 1}, %{
          tenant_id: scope.tenant_id,
          subject_id: scope.subject_id,
          session_id: session_id
        })

        {:error, :budget_exceeded}

      {:error, :promotion_job, reason, _changes} ->
        {:error, reason}
    end
  end

  # Serialize concurrent promotion reservations for the SAME tenant inside the
  # reservation transaction. `pg_advisory_xact_lock(int4, int4)` — the two-int form so
  # the fixed namespace isolates this lock class from the long-term-quota lock.
  # Auto-released at COMMIT/ROLLBACK.
  defp lock_promotion_budget!(repo, tenant_id) do
    repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      @promotion_budget_lock_ns,
      :erlang.phash2(tenant_id)
    ])
  end

  # Budget already consumed/claimed by `tenant_id` this hour, computed on the LOCKED
  # connection: completed compiles (watermark rows in the last hour) PLUS in-flight
  # promotion jobs that have not yet compiled. A job that is briefly BOTH executing and
  # has just written its watermark double-counts by 1 — deliberately conservative (it
  # can only under-admit, never overshoot the cap).
  defp promotion_budget_used(repo, tenant_id) do
    since = DateTime.add(DateTime.utc_now(), -3600, :second)

    watermarks =
      SessionPromotion
      |> where([w], w.tenant_id == ^tenant_id and w.promoted_at >= ^since)
      |> repo.aggregate(:count, :id)

    watermarks + in_flight_promotions(repo, tenant_id)
  end

  # Count of `tenant_id`'s promotion jobs still holding a budget claim (enqueued but not
  # yet terminal). Reads the shared `oban_jobs` table (no RLS) on the locked connection.
  defp in_flight_promotions(repo, tenant_id) do
    repo.one(
      from(j in "oban_jobs",
        where:
          j.worker == ^@promotion_worker_name and
            j.state in ^@promotion_inflight_states and
            fragment("? ->> 'tenant_id' = ?", j.args, ^tenant_id),
        select: count(j.id)
      )
    )
  end

  @doc """
  Whether `tenant_id` is under its per-hour promotion (compile) budget.

  `extra` accounts for compiles already ENQUEUED in the current sweep tick that have
  not yet advanced the DB watermark count (async execution) — so the sweep can bound
  itself within a single pass.

  ## What the meter counts (precise)

  It counts `session_promotions` rows whose `promoted_at` falls in the last hour. Since
  `upsert_session_promotion/2` REPLACES the row for a `(tenant, subject, session)` via
  `ON CONFLICT DO UPDATE`, this is "distinct SESSIONS promoted this hour", NOT the raw
  number of LLM compile calls: a single session re-compiled N times in the hour collapses
  to ONE row with the latest `promoted_at`. For the threat this budget defends against —
  a spamming agent cycling through DISTINCT `session_id`s to burn the tenant's BYO LLM key
  — distinct sessions == compiles, so the meter is exact. Same-session re-compiles are
  bounded separately by `MemoryPromotionWorker`'s per-session Oban unique window
  (`period: 900`), which caps a single session to a handful of recompiles/hour. The cap is
  therefore enforced exactly on the distinct-session axis and bounded (not unbounded) on
  the same-session axis. See also the execution-time re-check in `MemoryPromotionWorker`,
  which tightens the pre-enqueue check into an at-compile gate under concurrent bursts.
  """
  @spec promotion_budget_available?(String.t(), non_neg_integer()) :: boolean()
  def promotion_budget_available?(tenant_id, extra \\ 0) when is_binary(tenant_id) do
    promotion_compiles_this_hour(tenant_id) + extra < promotion_budget()
  end

  @doc "Count of distinct sessions promoted for `tenant_id` in the last hour (watermark rows)."
  @spec promotion_compiles_this_hour(String.t()) :: non_neg_integer()
  def promotion_compiles_this_hour(tenant_id) when is_binary(tenant_id) do
    since = DateTime.add(DateTime.utc_now(), -3600, :second)

    SessionPromotion
    |> where([w], w.tenant_id == ^tenant_id and w.promoted_at >= ^since)
    |> AdminRepo.aggregate(:count, :id)
  end

  @doc "Per-tenant compiles/hour cap (`:memory_promotion_compiles_per_hour`)."
  @spec promotion_budget() :: pos_integer()
  def promotion_budget do
    Application.get_env(:loopctl, :memory_promotion_compiles_per_hour, @default_compiles_per_hour)
  end

  @doc """
  Reads the promotion watermark for `(scope, session_id)`, or `nil` if never promoted.
  """
  @spec get_session_promotion(Scope.t(), String.t()) :: SessionPromotion.t() | nil
  def get_session_promotion(%Scope{} = scope, session_id) when is_binary(session_id) do
    AdminRepo.one(
      from(w in SessionPromotion,
        where:
          w.tenant_id == ^scope.tenant_id and w.subject_id == ^scope.subject_id and
            w.session_id == ^session_id
      )
    )
  end

  @doc """
  Upserts the promotion watermark for `scope.session_id` to `fingerprint`.

  Called on EVERY completed promotion run — including a zero-survivor run — so that
  an unchanged session (same `content_hash`) is skipped on the next trigger. Keyed on
  `(tenant_id, subject_id, session_id)`; a re-run REPLACES the hash / newest-turn /
  `promoted_at`.
  """
  @spec upsert_session_promotion(Scope.t(), %{
          :content_hash => String.t(),
          :last_turn_inserted_at => DateTime.t() | nil,
          optional(:last_turn_seq) => integer() | nil,
          optional(atom()) => any()
        }) :: {:ok, SessionPromotion.t()} | {:error, Ecto.Changeset.t()}
  def upsert_session_promotion(%Scope{session_id: session_id} = scope, fingerprint)
      when is_binary(session_id) do
    attrs = %{
      session_id: session_id,
      session_content_hash: fingerprint.content_hash,
      last_turn_inserted_at: fingerprint.last_turn_inserted_at,
      last_turn_seq: Map.get(fingerprint, :last_turn_seq),
      promoted_at: DateTime.utc_now()
    }

    %SessionPromotion{tenant_id: scope.tenant_id, subject_id: scope.subject_id}
    |> SessionPromotion.upsert_changeset(attrs)
    |> AdminRepo.insert(
      on_conflict:
        {:replace,
         [
           :session_content_hash,
           :last_turn_inserted_at,
           :last_turn_seq,
           :promoted_at,
           :updated_at
         ]},
      conflict_target: [:tenant_id, :subject_id, :session_id]
    )
  end

  @doc """
  Persists a session's surviving promotion `candidates` (from
  `Loopctl.Memory.Promoter.compile/2`) as long-term `:promoted` memories in `scope`.

  For each candidate, in order:

    1. **Exact dedupe** — compute `embedding_content_hash` from the candidate text AT
       WRITE TIME (decoupled from the async embedding). If a `:promoted` memory with
       that hash already exists in scope, the candidate is a no-op (`deduped`). The
       write itself runs `ON CONFLICT DO NOTHING` against the partial unique index, so
       two concurrent workers (explicit + sweep on the same session) cannot
       double-insert.
    2. **Near-dup supersede** — embed the candidate and run the epic_28 cosine kNN,
       scoped to prior `:promoted` rows (`nearest_live/2`). If embedding generation is
       unavailable (circuit open / no key / provider error), NO near-dup answer is
       authoritative, so the whole run aborts with `{:error, :embeddings_degraded}` (the
       worker snoozes/retries rather than risk inserting a duplicate). Likewise, if the
       per-tenant HeavyRead gate SHEDS the recall (tenant over its slice), the run aborts
       with `{:error, :heavy_read_overloaded}` (the recall requests `on_overload: :tag`,
       so it never raises on this write path) for the same loss-free snooze. On a genuine
       near-match (score ≥ `:memory_promotion_near_dup_threshold`) the new row is inserted
       and the prior memory is `supersede/3`d.
    3. Otherwise the candidate is inserted fresh (`promoted`).

  Each inserted `:promoted` row's embedding is written SYNCHRONOUSLY at insert time,
  reusing the vector already computed for the near-dup check (no extra provider call and
  no async lag) — so the row is immediately recallable and a later candidate/session
  cannot duplicate it through the async-embedding window (unlike `remember/2`, whose
  explicit long-term writes still embed asynchronously). Subject-cap enforcement
  is shared with `remember/2` (advisory-locked count) — a candidate that would exceed
  the cap halts with `{:error, :quota_exceeded, summary}` (a TERMINAL condition for the
  worker; the rows written so far stand, matching the resumable-not-all-or-nothing
  contract).

  Returns `{:ok, summary}` on full success, `{:error, :embeddings_degraded}`,
  `{:error, :heavy_read_overloaded}` (the per-tenant HeavyRead gate shed the near-dup
  recall — a loss-free snooze for the worker, treated like `:embeddings_degraded`),
  `{:error, :quota_exceeded, summary}`, or `{:error, other}` (a bad write —
  retryable). `summary` is `%{promoted, superseded, deduped}` (promoted = fresh
  inserts; superseded = insert-and-supersede pairs; deduped = exact-dup skips).
  """
  @spec persist_promotion(Scope.t(), [map()]) ::
          {:ok, map()}
          | {:error, :embeddings_degraded}
          | {:error, :heavy_read_overloaded}
          | {:error, :quota_exceeded, map()}
          | {:error, term()}
  def persist_promotion(%Scope{subject_id: @eval_subject_id}, _candidates) do
    # STRUCTURAL refusal: the reserved promotion-eval subject is NEVER written into durable
    # memories, no matter who calls (a racing auto-promotion sweep, a stray explicit
    # trigger). This is the last-line guarantee behind the sweep's candidate filter that
    # the eval's synthetic/injection turns can never become real `:promoted` rows
    # (US-29.5 AC-29.5.3). No-op summary so a caller (the promotion worker) completes
    # cleanly without persisting anything.
    {:ok, %{promoted: 0, superseded: 0, deduped: 0}}
  end

  def persist_promotion(%Scope{} = scope, candidates) when is_list(candidates) do
    Enum.reduce_while(candidates, {:ok, %{promoted: 0, superseded: 0, deduped: 0}}, fn candidate,
                                                                                       {:ok, acc} ->
      case promote_one(scope, candidate) do
        {:ok, :deduped} -> {:cont, {:ok, %{acc | deduped: acc.deduped + 1}}}
        {:ok, :promoted} -> {:cont, {:ok, %{acc | promoted: acc.promoted + 1}}}
        {:ok, :superseded} -> {:cont, {:ok, %{acc | superseded: acc.superseded + 1}}}
        {:error, :embeddings_degraded} -> {:halt, {:error, :embeddings_degraded}}
        {:error, :heavy_read_overloaded} -> {:halt, {:error, :heavy_read_overloaded}}
        {:error, :quota_exceeded} -> {:halt, {:error, :quota_exceeded, acc}}
        {:error, other} -> {:halt, {:error, other}}
      end
    end)
  end

  defp promote_one(scope, candidate) do
    hash = MemorySchema.embedding_content_hash(candidate.text)

    if promoted_hash_exists?(AdminRepo, scope, hash) do
      {:ok, :deduped}
    else
      case nearest_live(scope, candidate.text) do
        {:error, :embeddings_degraded} ->
          {:error, :embeddings_degraded}

        {:error, :heavy_read_overloaded} = err ->
          err

        {:ok, near_dup_id, embedding} ->
          insert_promoted(scope, candidate, hash, near_dup_id, embedding)
      end
    end
  end

  # Recall the nearest near-dup that auto-promotion is ALLOWED to supersede: a prior
  # `:promoted` memory (never a user's explicit row). Returns `{:ok, near_dup_id | nil,
  # embedding}` — the freshly-computed query embedding is handed back so the caller can
  # store it SYNCHRONOUSLY on the new promoted row (see `insert_promoted/5`) — or
  # `{:error, :embeddings_degraded}` when embedding generation is unavailable (circuit
  # open / no key / provider error). AC-29.2.4: a degraded "no near-dup found" is NOT
  # authoritative, so the whole run aborts rather than risk inserting a duplicate.
  #
  # The candidate is embedded through `MemorySchema.embedding_input/1` — the SAME slice
  # the stored embeddings use — so the near-dup cosine compare is apples-to-apples with
  # the promoted rows it scans, and the exact vector we compare with is the exact vector
  # we persist (no drift between the dedup check and the stored row).
  #
  # Source-scoping to `:promoted` mirrors the exact-dedupe (`promoted_hash_exists?` is
  # `source = 'promoted'`-only) and closes AC-29.2.4's data-visibility hole: an
  # unattended cron/Stop-hook promoter must NEVER hide a human-authored (`source:
  # :explicit`) memory on a fuzzy cosine heuristic. This is a DELIBERATE, documented
  # narrowing of AC-29.2.4's literal wording ("on a near-match it SUPERSEDES the prior
  # memory"): a promoted near-dup of an EXPLICIT row is a permitted, SAFE duplicate
  # rather than a silent overwrite of human-authored knowledge. Results are
  # distance-ordered (nearest first), so the first ELIGIBLE promoted row above threshold
  # wins; missing one (pool dominated by explicit rows) is safe — insert fresh instead.
  defp nearest_live(scope, text) do
    case Knowledge.generate_embedding(scope.tenant_id, MemorySchema.embedding_input(text)) do
      {:error, _reason} ->
        {:error, :embeddings_degraded}

      {:ok, embedding} ->
        # The near-dup HNSW recall runs on the shared HeavyRead pool behind the
        # per-tenant TenantGate. Over the tenant's slice the read is SHED
        # (`on_overload: :tag`) and surfaces as `{:error, :heavy_read_overloaded}` —
        # propagate it up so the worker snoozes LOSS-FREE rather than raising (which
        # would burn an Oban attempt on the promotion WRITE path, US-37.5).
        case find_promoted_near_dup(scope, embedding) do
          {:error, :heavy_read_overloaded} = err -> err
          near_dup_id -> {:ok, near_dup_id, embedding}
        end
    end
  end

  # Run the index-safe HNSW kNN for `embedding` in scope and return the id of the nearest
  # `:promoted` row at/above the near-dup threshold, or nil. Reuses the SAME
  # `memory_candidate_query/4` that `recall_semantic/4` builds, so the near-dup path
  # cannot drift from ordinary recall.
  defp find_promoted_near_dup(scope, embedding) do
    query = memory_candidate_query(scope, embedding, @near_dup_recall_pool, false)
    # `on_overload: :tag` so an over-cap TenantGate shed returns
    # `{:error, :heavy_read_overloaded}` (mapped to a loss-free snooze upstream)
    # instead of RAISING an OverloadedError on the promotion write path (US-37.5).
    opts = Keyword.put(HeavyRead.opts(:memory_recall), :on_overload, :tag)

    case HeavyRead.all_memory(scope.tenant_id, scope.subject_id, query, opts) do
      {:error, :heavy_read_overloaded} = err -> err
      rows when is_list(rows) -> first_promoted_near_dup(rows)
    end
  end

  # The id of the nearest `:promoted` row at/above the near-dup threshold (rows are
  # distance-ordered, nearest first), or nil. An explicit-source near-dup is skipped —
  # auto-promotion never supersedes a human-authored row (AC-29.2.4).
  defp first_promoted_near_dup(rows) do
    Enum.find_value(rows, fn row ->
      score = max(0.0, 1.0 - row.distance)
      if score >= near_dup_threshold() and row.source == :promoted, do: row.id
    end)
  end

  # Insert one promoted candidate AND (when `near_dup_id` is present) supersede that
  # prior memory — in ONE AdminRepo transaction, so a worker crash/retry can never leave
  # the freshly-inserted row live ALONGSIDE an un-superseded near-dup (AC-29.2.4). Under
  # the subject-cap advisory lock; re-checks the exact-dup hash INSIDE the lock
  # (authoritative — the lock serializes same-subject writers) and writes ON CONFLICT DO
  # NOTHING against the partial unique index as a belt-and-suspenders backstop.
  #
  # The `embedding` — already computed for near-dup detection in `nearest_live/2`, at NO
  # extra provider call — is stored SYNCHRONOUSLY on the new row inside this same
  # transaction (`:store_embedding` step) INSTEAD of enqueuing the async
  # `MemoryEmbeddingWorker`. This is load-bearing for AC-29.2.4 under PROD's async
  # embedding: a promoted row left with a NULL embedding is INVISIBLE to cosine recall,
  # so the very next candidate in this run — or a paraphrase promoted from another
  # session within the async-embed lag window — would MISS it in `nearest_live/2` and
  # insert a duplicate (the exact-dedupe hash cannot catch a paraphrase, and the partial
  # unique index cannot either). Writing the vector at insert time closes that window:
  # the row is immediately recallable, and the behaviour no longer differs between the
  # `:inline` test engine (which embedded promoted rows synchronously and thus MASKED the
  # gap) and async prod. We never reach here without a valid vector — `nearest_live/2`
  # returns `{:error, :embeddings_degraded}` whenever embeddings are unavailable.
  # Returns `{:ok, :promoted | :superseded | :deduped}`.
  defp insert_promoted(scope, candidate, hash, near_dup_id, embedding) do
    attrs = %{
      text: candidate.text,
      confidence: candidate.confidence,
      source: :promoted,
      source_session_id: scope.session_id,
      embedding_content_hash: hash,
      tags: candidate.tags,
      metadata: promoted_metadata(candidate)
    }

    Multi.new()
    |> Multi.run(:lock, fn repo, _changes ->
      lock_long_term_quota!(repo, scope)
      {:ok, :ok}
    end)
    |> Multi.run(:precheck, fn repo, _changes ->
      if promoted_hash_exists?(repo, scope, hash),
        do: {:error, :already_promoted},
        else: {:ok, :absent}
    end)
    |> Multi.run(:quota, fn repo, _changes ->
      if long_term_count(repo, scope) >= max_long_term_memories(),
        do: {:error, :quota_exceeded},
        else: {:ok, :ok}
    end)
    |> Multi.insert(:memory, long_term_changeset(scope, attrs),
      on_conflict: :nothing,
      conflict_target:
        {:unsafe_fragment,
         "(tenant_id, subject_id, embedding_content_hash) WHERE source = 'promoted'"}
    )
    |> Multi.run(:store_embedding, fn repo, %{memory: memory} ->
      store_promoted_embedding(repo, scope, memory, embedding, hash)
    end)
    |> Multi.run(:supersede, fn repo, %{memory: memory} ->
      supersede_within(repo, scope, near_dup_id, memory)
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{supersede: outcome}} -> {:ok, outcome}
      {:error, :precheck, :already_promoted, _changes} -> {:ok, :deduped}
      {:error, :quota, :quota_exceeded, _changes} -> {:error, :quota_exceeded}
      {:error, :memory, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, :store_embedding, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, :supersede, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
    end
  end

  # Store the vector on the just-inserted promoted row, WITHIN the caller's transaction
  # (no external call — `embedding` was already computed by `nearest_live/2`). Reloads
  # the row by its scoped id: on the ON CONFLICT DO NOTHING belt-path (a concurrent
  # worker won the insert) there is no persisted row for `memory.id`, so the reload
  # returns nil and we no-op — the row that DID win already carries its own synchronous
  # embedding. A client-autogenerated binary_id means `memory.id` is populated even on a
  # conflict skip, so a reload — not an `is_nil(id)` check — is the reliable
  # "did-we-actually-insert" signal. Uses the sanctioned `embedding_changeset/3` (the one
  # changeset allowed to touch `:embedding`, which validates dimensions).
  defp store_promoted_embedding(repo, scope, memory, embedding, hash) do
    case reload_in_scope(repo, scope, memory.id) do
      nil -> {:ok, :skipped}
      row -> row |> MemorySchema.embedding_changeset(embedding, hash) |> repo.update()
    end
  end

  defp reload_in_scope(_repo, _scope, nil), do: nil

  defp reload_in_scope(repo, scope, id) do
    MemorySchema
    |> where(
      [m],
      m.id == ^id and m.tenant_id == ^scope.tenant_id and m.subject_id == ^scope.subject_id
    )
    |> repo.one()
  end

  # Supersede `near_dup_id` with the just-inserted `memory`, WITHIN the caller's
  # transaction (`repo`) — atomic with the insert. Returns `{:ok, :superseded}` when a
  # prior row was hidden, `{:ok, :promoted}` when the new row simply stands fresh (no
  # near-dup, self-match, on-conflict skip, or the near-dup vanished / was already
  # superseded by a concurrent run — never overwrite it, that would orphan the first
  # superseder into a second live head — AC-29.2.4 double-supersede guard).
  defp supersede_within(_repo, _scope, nil, _memory), do: {:ok, :promoted}

  defp supersede_within(repo, scope, near_dup_id, memory) do
    # A self-match (the near-dup we found IS the row we just inserted) has nothing to
    # supersede. The ON CONFLICT DO NOTHING belt-path (insert skipped by a concurrent
    # winner) is NOT special-cased here: `do_supersede_within/4` reloads `new_id` FOR
    # UPDATE and finds no row (a skipped insert never persisted under this id), so
    # `supersede_within_eligible?/2` is false and it returns `{:ok, :promoted}`. An
    # `is_nil(memory.id)` guard would be DEAD code — `Loopctl.Schema` autogenerates the
    # binary_id PK in Elixir before INSERT, so `memory.id` is always present on the
    # returned struct even when ON CONFLICT skipped the write; the FOR UPDATE reload, not
    # a nil id, is what detects the skip.
    if near_dup_id == memory.id do
      {:ok, :promoted}
    else
      do_supersede_within(repo, scope, near_dup_id, memory.id)
    end
  end

  defp do_supersede_within(repo, scope, old_id, new_id) do
    rows =
      MemorySchema
      |> where(
        [m],
        m.id in ^[old_id, new_id] and m.tenant_id == ^scope.tenant_id and
          m.subject_id == ^scope.subject_id
      )
      |> order_by([m], asc: m.id)
      |> lock("FOR UPDATE")
      |> repo.all()

    old = Enum.find(rows, &(&1.id == old_id))
    new = Enum.find(rows, &(&1.id == new_id))

    # A no-op (`{:ok, :promoted}`) is returned — new row simply stands fresh — when:
    #   * the near-dup vanished (forgotten / concurrent delete), OR
    #   * `new` is not a live head (concurrent supersede) — cannot point at a dead head, OR
    #   * `old` was already superseded by another concurrent run — overwriting its pointer
    #     would orphan the first superseder, leaving TWO live heads (AC-29.2.4 guard).
    if supersede_within_eligible?(old, new) do
      old
      |> Ecto.Changeset.change(superseded_by: new_id)
      |> repo.update()
      |> case do
        {:ok, _} -> {:ok, :superseded}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:ok, :promoted}
    end
  end

  defp supersede_within_eligible?(old, new) do
    not is_nil(old) and not is_nil(new) and is_nil(old.superseded_by) and
      is_nil(new.superseded_by)
  end

  defp promoted_hash_exists?(repo, scope, hash) do
    MemorySchema
    |> where(
      [m],
      m.tenant_id == ^scope.tenant_id and m.subject_id == ^scope.subject_id and
        m.source == :promoted and m.embedding_content_hash == ^hash
    )
    |> repo.exists?()
  end

  # Carry the compiler's `when_to_apply` + `cross_links` into the promoted memory's
  # metadata so the durable fact keeps its applicability note and article links.
  defp promoted_metadata(candidate) do
    %{
      "when_to_apply" => Map.get(candidate, :when_to_apply, ""),
      "cross_links" => Map.get(candidate, :cross_links, [])
    }
  end

  defp near_dup_threshold do
    Application.get_env(
      :loopctl,
      :memory_promotion_near_dup_threshold,
      @default_near_dup_threshold
    )
  end

  @doc "The session-turn TTL in seconds (`expires_at` = now + this)."
  @spec session_memory_ttl_seconds() :: pos_integer()
  def session_memory_ttl_seconds do
    Application.get_env(:loopctl, :session_memory_ttl_seconds, 3600)
  end

  @doc """
  The session-turn expiry FLOOR in seconds: `server_governed_expiry/1` floors any
  caller-supplied `expires_at` up to `now + this`. Must be strictly GREATER than the
  sweep interval and strictly LESS than the session-turn TTL (see
  `assert_promotion_ttl_invariant!/0`).
  """
  @spec promotion_sweep_window_seconds() :: pos_integer()
  def promotion_sweep_window_seconds do
    Application.get_env(:loopctl, :memory_promotion_sweep_window_seconds, 900)
  end

  @doc """
  The ACTUAL cadence of `Loopctl.Workers.MemoryPromotionSweepWorker`, in seconds — the
  data form of its `*/10` crontab entry (kept in sync there). The expiry floor must
  exceed this so a turn survives past its first eligible sweep tick, not merely up to it.
  """
  @spec promotion_sweep_interval_seconds() :: pos_integer()
  def promotion_sweep_interval_seconds do
    Application.get_env(:loopctl, :memory_promotion_sweep_interval_seconds, 600)
  end

  @doc """
  Asserts the TTL-vs-promotion safety invariant (AC-29.2.10). Raises otherwise.

  The binding constraint is a chain, not a single comparison:

      sweep_interval  <  sweep_window (expiry floor)  <  session_memory TTL

  * `sweep_window < ttl` — the DEFAULT lifetime (`now + ttl`) always clears the floor, so
    the flooring branch of `server_governed_expiry/1` never raises the default path.
  * `sweep_interval < sweep_window` — the REAL binding constraint the old assertion
    missed: a turn whose `expires_at` was floored to `now + sweep_window` must outlive
    its FIRST eligible sweep tick (which can land up to one full interval after the turn
    is written) with margin for the promotion job to run, or `SessionMemoryPruneWorker`
    (every 5 min) can delete it before the sweep-enqueued promotion compiles it. Flooring
    only to `now + sweep_interval` would give ZERO margin; requiring the floor to strictly
    exceed the interval reserves that margin (default 900 vs 600 = 300s ≈ one prune cycle).
  """
  @spec assert_promotion_ttl_invariant!() :: :ok
  def assert_promotion_ttl_invariant! do
    interval = promotion_sweep_interval_seconds()
    window = promotion_sweep_window_seconds()
    ttl = session_memory_ttl_seconds()

    cond do
      window >= ttl ->
        raise ArgumentError,
              "memory promotion sweep window / expiry floor (#{window}s) must be strictly " <>
                "shorter than the session-memory TTL (#{ttl}s) so turns are promoted before " <>
                "they are pruned (US-29.2 AC-29.2.10)"

      interval >= window ->
        raise ArgumentError,
              "memory promotion sweep interval (#{interval}s) must be strictly shorter than " <>
                "the expiry floor / sweep window (#{window}s) so a floored session turn " <>
                "survives past its first eligible sweep tick with margin for the promotion " <>
                "job to run before SessionMemoryPruneWorker deletes it (US-29.2 AC-29.2.10)"

      true ->
        :ok
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

  # Optional provenance filter for the list readers (US-29.3 promoted-vs-explicit
  # oversight). Accepts the `:promoted`/`:explicit` atoms or their string forms;
  # `nil` or any unrecognized value leaves the query unfiltered (no source filter).
  defp maybe_filter_source(query, source) when source in [:promoted, "promoted"],
    do: where(query, [m], m.source == :promoted)

  defp maybe_filter_source(query, source) when source in [:explicit, "explicit"],
    do: where(query, [m], m.source == :explicit)

  defp maybe_filter_source(query, _), do: query

  defp normalize_tier(tier) when tier in [:session, :long_term], do: tier
  defp normalize_tier("session"), do: :session
  defp normalize_tier("long_term"), do: :long_term
  defp normalize_tier(_), do: :long_term

  defp max_long_term_memories do
    Application.get_env(:loopctl, :max_long_term_memories_per_subject, 10_000)
  end

  @doc """
  The hard upper bound (#{@max_list_limit}) every list/history read clamps its
  `:limit` to (`clamp_limit/1`).

  Exposed so paginating callers can size their read window to match — e.g.
  `Loopctl.Memory.Promoter`'s most-recent-turns window MUST NOT exceed this, or
  its offset query silently clamps and drops the most-recent turns. Deriving that
  window from this function keeps the two coupled at compile time instead of via
  two independently-maintained `200`s.
  """
  @spec max_list_limit() :: pos_integer()
  def max_list_limit, do: @max_list_limit

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
