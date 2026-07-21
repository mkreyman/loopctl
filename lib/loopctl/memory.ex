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

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Egress

  import Loopctl.Egress, only: [is_egress_refusal: 1]
  alias Loopctl.Embeddings
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Memory.MemoryEmbedding
  alias Loopctl.Memory.PromotionTelemetry
  alias Loopctl.Memory.RecallBumpCache
  alias Loopctl.Memory.Scope
  alias Loopctl.Memory.SessionMemory
  alias Loopctl.Memory.SessionPromotion
  alias Loopctl.Projects
  alias Loopctl.TelemetryEvents
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

  # `recall_context/2` (the merged memory ∪ knowledge recall, #411 Gap 2 PR B) clamps
  # its overall limit here. The per-source sub-recalls clamp independently (memory via
  # `clamp_k/1`, knowledge inside `search_combined/3`); this bounds the merged, re-ranked
  # page returned to the caller so a large `limit` cannot blow up the sort/take.
  @default_context_limit 10
  @max_context_limit 50

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
  programmatically on the struct — never cast from `attrs`. `tenant_id`/`subject_id`
  are the key-derived isolation boundary; `project_id` is a partition key that MAY
  originate from the request body (see the controller), so — because the insert runs
  on the BYPASSRLS `AdminRepo` and its `foreign_key_constraint(:project_id)` would
  otherwise validate against EVERY tenant's projects — a present `project_id` is
  validated tenant-ownership FIRST (`Loopctl.Projects.get_project/2`) and refused with
  `{:error, :project_not_found}` when it is malformed, nonexistent, or belongs to
  another tenant. This closes the cross-tenant FK existence oracle + cross-tenant graph
  edge the FK check would otherwise permit; the DB FK constraint is defense-in-depth,
  never the tenant-boundary gate (mirrors `Loopctl.Knowledge.validate_project_ownership/2`).
  A long-term write is
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
          | {:error, Ecto.Changeset.t() | :quota_exceeded | :project_not_found}
  def remember(%Scope{} = scope, attrs) when is_map(attrs) do
    with :ok <- validate_project_scope(scope) do
      case normalize_tier(opt(attrs, :tier, :long_term)) do
        :session -> remember_session(scope, attrs)
        :long_term -> remember_long_term(scope, attrs)
      end
    end
  end

  # `project_id` is a body-suppliable partition key that is INSERTED via the BYPASSRLS
  # `AdminRepo`, so the schema's `foreign_key_constraint(:project_id)` evaluates against
  # projects in EVERY tenant. Validating tenant-ownership HERE — before the write —
  # means the FK is never the tenant-boundary gate: a well-formed UUID that exists in
  # ANOTHER tenant (an existence oracle + a cross-tenant graph edge) and a nonexistent
  # UUID both take the SAME `{:error, :project_not_found}` path, so neither leaks nor
  # partitions across the isolation boundary. `nil` (global/tenant-wide) is always
  # allowed. Mirrors `Loopctl.Knowledge.validate_project_ownership/2`; a malformed
  # value is caught by `get_project/2`'s own UUID guard (→ `:not_found`).
  defp validate_project_scope(%Scope{project_id: nil}), do: :ok

  defp validate_project_scope(%Scope{tenant_id: tenant_id, project_id: project_id}) do
    case Projects.get_project(tenant_id, project_id) do
      {:ok, _project} -> :ok
      {:error, :not_found} -> {:error, :project_not_found}
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
      {:error, :memory, %Ecto.Changeset{} = changeset, _changes} -> memory_insert_error(changeset)
      {:error, :embedding_job, reason, _changes} -> {:error, reason}
    end
  end

  # `validate_project_scope/1` runs BEFORE this advisory-locked Multi (check-then-act),
  # so a project deleted in the window between that read and the insert trips the
  # BYPASSRLS `foreign_key_constraint(:project_id)` at insert time — surfacing as a
  # changeset error on `:project_id` rather than the intended `:project_not_found`. Map
  # that back so the deleted-mid-write RACE returns the SAME `{:error, :project_not_found}`
  # envelope (controller → `invalid_project_id`) as a foreign/nonexistent `project_id`
  # caught pre-insert, keeping the caller contract consistent (#411 review). Any other
  # changeset error (e.g. a `:text` validation) passes through unchanged.
  defp memory_insert_error(%Ecto.Changeset{errors: errors} = changeset) do
    if Keyword.has_key?(errors, :project_id) do
      {:error, :project_not_found}
    else
      {:error, changeset}
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

  ## `project_id` is a partition key here — recall does NOT tenant-validate it

  `scope.project_id` selects a PARTITION, it is not the isolation boundary
  (`tenant_id`/`subject_id` are). Recall therefore deliberately does NOT check
  project ownership, and its `nil`/foreign/nonexistent semantics differ from the
  write path ON PURPOSE:

    * `project_id: nil` → GLOBAL-ONLY: only rows whose `project_id` column is NULL
      (NOT a union across the subject's projects — see `Loopctl.Memory.Scope`).
    * a present, well-formed `project_id` → `global ∪ that project`.
    * a well-formed `project_id` that is a TYPO, STALE, or belongs to ANOTHER
      tenant → treated as global-only (it simply matches no in-tenant rows), with
      NO error. This is safe — the `(tenant_id, subject_id)` predicate still bounds
      every result, so a foreign project_id can never surface another tenant's or
      subject's rows — but it is INTENTIONALLY ASYMMETRIC with `remember/2`, which
      validates ownership up front and 422s a foreign/nonexistent `project_id`
      (`:project_not_found` → `invalid_project_id`). Recall stays validation-free so
      an unowned partition is a quiet empty-partition read rather than a DB round-trip
      on the hot recall path; the trade is that a client bug (wrong-tenant
      `project_id`) is masked on recall where it would 422 on create. Callers that
      need an unowned-project error must validate the id before recall.
    * a malformed (non-UUID) `project_id` → global-only (the `:binary_id` cast is
      guarded rather than raising; controllers 422 it at the boundary first).

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
  requested `k` rows were recalled — nothing more. It is a single boolean
  (`length(results) < k`) and DOES NOT distinguish WHY the page is short: a
  genuinely small live scope, a cross-SUBJECT pool under-fill, and (since #411
  Gap 2) a cross-PROJECT pool under-fill all raise it identically. So `underfilled:
  true` means only "fewer than `k` here" — a caller CANNOT read it as "there is
  nothing more" vs "matching rows exist beyond the pool horizon; retry wider". A
  cause-tagged signal (`meta.underfill_reason`) is deferred to the US-28.5 pool-
  calibration story; until then treat `underfilled` as a hint to widen `limit`, not
  a diagnosis.

  ## Project scope compounds the pool under-fill window (#411 Gap 2)

  The `global ∪ active-project` merge is a SECOND selective filter applied on the OUTER
  over-the-pool query (`maybe_scope_project/2`), stacked on the subject filter. The
  inner over-fetch pool (`VectorSearch.pool_size/1`) is calibrated for SUBJECT dilution
  only and is project-AGNOSTIC (a selective project predicate on the inner ANN would
  flip the planner off HNSW — #170/#172). So a subject whose in-scope
  (`global + active-project`) live memories are sparse relative to its total
  cross-project corpus can under-fill recall (`meta.underfilled: true`) even when ≥ k
  in-scope memories exist beyond the pool horizon — the SAME accepted tradeoff as the
  subject filter, now compounded. MITIGATION (`recall_pool_size/2`): when a project
  scope is active the over-fetch factor is DOUBLED so the project filter draws from a
  larger candidate pool, strictly REDUCING (never eliminating) the compounded
  under-fill window — bounded by `:max_vector_pool` so worst-case recall cost is
  unchanged. FULL pool re-calibration with a VERIFIED combined subject×project dilution
  bound remains the US-28.5-class scale story that owns pool calibration; recall
  SIGNALS any residual short page via `meta.underfilled` regardless.

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
    on_overload = recall_on_overload(opt(opts, :on_overload, :raise))

    # Reuse a precomputed embedding when the caller supplies one (the merged recall
    # generates it ONCE for both halves — #411 Gap 2); otherwise generate here.
    envelope =
      case opt(opts, :embedding, nil) ||
             Knowledge.generate_embedding(scope.tenant_id, query_text, egress_opts(scope)) do
        {:ok, embedding} ->
          recall_semantic(scope, embedding, k, include_superseded?, on_overload)

        {:error, reason} ->
          recall_fallback(scope, reason, query_text, k, include_superseded?, on_overload)
      end

    maybe_bump_recall(scope, envelope, include_superseded?)
    envelope
  end

  # #411 Gap 3: bump the recall-count / last_recalled_at for the rows this recall
  # returned — the "hotness" signal the graduation sweep thresholds on. Deliberately
  # OFF the response path (best-effort, fire-and-forget) and gated so it never pollutes
  # the signal or affects the response:
  #
  #   * ONLY the HEALTHY semantic path bumps (`meta.fallback == false`). A degraded
  #     ILIKE fallback OR a HeavyRead-shed empty envelope both set `fallback: true`, so
  #     neither bumps: a memory surfaced only because embeddings were down (a text
  #     substring match) is NOT evidence of genuine semantic hotness, and counting it
  #     would let a provider outage skew which memories graduate.
  #   * `include_superseded: true` oversight reads do NOT bump — an admin/superadmin
  #     inspecting the full (incl. superseded) corpus must not inflate live memories'
  #     hotness. Only the default live recall counts.
  #   * A bump failure is swallowed (logged at most): a recall response must NEVER fail
  #     because the analytics-style counter write failed. Mirrors the Knowledge
  #     `Analytics.record_access/6` fire-and-forget off-hot-path mechanism.
  defp maybe_bump_recall(_scope, %{meta: %{fallback: true}}, _include_superseded?), do: :ok
  defp maybe_bump_recall(_scope, _envelope, true), do: :ok

  defp maybe_bump_recall(scope, envelope, false) do
    # `Map.get(envelope, :results, [])` (not a `%{results: results}` head): a recall
    # response must NEVER fail because of the analytics-shaped bump, so an unexpected
    # `fallback: false` envelope shape lacking `results` degrades to a no-op here instead
    # of raising a FunctionClauseError on the recall hot path.
    #
    # RELEVANCE FLOOR (not just top-k page membership). A healthy recall returns the
    # top-k by cosine distance REGARDLESS of absolute relevance, so a subject with fewer
    # than k live memories has ALL of them returned on every query — making a naive bump
    # track the subject's query VOLUME, not any individual memory's value, and letting a
    # sparse scope (the common case for a new agent/project) auto-graduate low-relevance
    # NOISE after ~threshold recalls. Only bump rows whose similarity clears
    # `recall_bump_min_score/0`, so "frequently-recalled = proven-valuable" holds even
    # for tiny scopes. `score` is `max(0.0, 1.0 - distance)` (see `recall_semantic/5`),
    # so higher = more similar.
    floor = recall_bump_min_score()

    ids =
      for {%MemorySchema{id: id}, score} <- Map.get(envelope, :results, []),
          is_binary(id),
          is_number(score) and score >= floor,
          do: id

    bump_recall_counts(scope.tenant_id, ids)
  end

  @doc """
  Best-effort, OFF-hot-path increment of `recall_count` (+1) and refresh of
  `last_recalled_at` for the given live memory `ids` in `tenant_id`, DEDUPED to at most
  once per memory per `recall_bump_cooldown_seconds/0` so a tight single-agent recall loop
  cannot game the hotness signal that drives graduation.

  Mirrors `Loopctl.Knowledge.Analytics.record_access/6`: the write is fire-and-forget
  and can NEVER fail a recall. Under the default `:async` mode it runs in a task on the
  BOUNDED `Loopctl.Memory.RecallBumpTaskSupervisor` (a `max_children` cap bounds the
  fan-out so a recall burst can't spawn an unbounded set of background writes that starve
  the write pool — over the cap the bump is simply dropped); tests set
  `:memory_recall_bump_mode` to `:sync` so the write shares the Ecto sandbox connection
  (a spawned task would not — the classic external-process sandbox gotcha). Any error is
  logged and swallowed. The single UPDATE is scoped by `(tenant_id, id IN ...)` and is a
  no-op for an empty id list.

  ## Cooldown pre-filter (async path)

  Before spawning, the async path drops ids already bumped within their cooldown window
  via the node-local `Loopctl.Memory.RecallBumpCache`, so an idle-window recall issues
  ZERO tasks and ZERO DB writes — the cooldown no-op no longer amplifies a read 1:1 into
  a connection checkout. The DB-side `WHERE last_recalled_at < cutoff` REMAINS the source
  of truth (the ETS cache is node-local and lost on restart), so a cross-node or
  post-restart recall still dedups correctly at the DB.

  ## Dedup is best-effort under concurrency (by design)

  Two concurrent recalls of the same memory within one window can both read
  `last_recalled_at` as stale (Postgres READ COMMITTED evaluates the WHERE once per
  statement) and each increment +1, over-counting past the intended "at most once per
  window". The ETS pre-filter narrows this to a same-node, same-instant race, and the
  over-count is bounded by the concurrency, so the hotness signal is BEST-EFFORT: it
  raises the bar against a single-agent tight loop (the anti-gaming goal) without
  claiming a hard exactly-once guarantee. A hard guarantee would need a per-memory
  advisory lock / single-writer path, which is not worth its cost for an analytics-shaped
  counter.
  """
  @spec bump_recall_counts(String.t(), [String.t()]) :: :ok
  def bump_recall_counts(_tenant_id, []), do: :ok

  def bump_recall_counts(tenant_id, ids) when is_binary(tenant_id) and is_list(ids) do
    case Application.get_env(:loopctl, :memory_recall_bump_mode, :async) do
      :sync ->
        do_bump_recall_counts(tenant_id, ids)

      _async ->
        async_bump_recall_counts(tenant_id, ids)
    end
  rescue
    error ->
      Logger.warning("Memory.bump_recall_counts failed to spawn: #{Exception.message(error)}")
      :ok
  end

  defp async_bump_recall_counts(tenant_id, ids) do
    case RecallBumpCache.filter_uncooled(tenant_id, ids) do
      # Every id is still inside its cooldown window on this node — a guaranteed DB no-op.
      # Skip the task AND the connection checkout entirely.
      [] ->
        :ok

      fresh_ids ->
        Task.Supervisor.start_child(Loopctl.Memory.RecallBumpTaskSupervisor, fn ->
          do_bump_recall_counts(tenant_id, fresh_ids)
          # Record the bump only AFTER the write so the node-local window matches the DB.
          RecallBumpCache.mark(tenant_id, fresh_ids)
        end)

        :ok
    end
  end

  defp do_bump_recall_counts(tenant_id, ids) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -recall_bump_cooldown_seconds(), :second)

    # DEDUP the bump to at most once per memory per cooldown window. `recall_count` is the
    # "frequently-recalled / proven-valuable" signal the graduation sweep thresholds on, so
    # it must reflect BROAD, repeated value across sessions/time — not a tight single-agent
    # loop. Without this window a single agent issuing the same query N times in one loop
    # would force graduation (default threshold 3), letting one agent flood the wiki. Only
    # a recall whose row was last counted BEFORE the cooldown (or never) bumps; recalls
    # inside the window are ignored for hotness. `last_recalled_at` therefore marks the last
    # COUNTED recall, so it doubles as the dedup cursor.
    from(m in MemorySchema,
      where:
        m.tenant_id == ^tenant_id and m.id in ^ids and
          (is_nil(m.last_recalled_at) or m.last_recalled_at < ^cutoff)
    )
    |> AdminRepo.update_all(set: [last_recalled_at: now], inc: [recall_count: 1])

    :ok
  rescue
    error ->
      # A recall-count bump is analytics-shaped: never let a counter-write failure
      # surface (the recall already returned). Log at :warning so a persistently
      # failing bump is visible in production, then swallow.
      Logger.warning(
        "Memory.bump_recall_counts write failed (bump dropped): " <>
          Exception.message(error)
      )

      :ok
  end

  # `:on_overload` controls how a per-tenant HeavyRead cap SHED is handled (US-37.5):
  # `:raise` (the DEFAULT, standalone `/memory/recall`) raises `OverloadedError` → a 429;
  # `:tag` (the merged `/recall`, #411 Gap 2) degrades to an empty envelope so one shed
  # pool cannot sink the whole merged endpoint. Only these two values are honored.
  defp recall_on_overload(:tag), do: :tag
  defp recall_on_overload(_), do: :raise

  defp recall_semantic(scope, embedding, k, include_superseded?, on_overload) do
    query = memory_candidate_query(scope, embedding, k, include_superseded?)

    case HeavyRead.all_memory(
           scope.tenant_id,
           scope.subject_id,
           query,
           memory_recall_opts(on_overload)
         ) do
      {:error, :heavy_read_overloaded} ->
        overloaded_memory_env(scope.tenant_id, k)

      rows when is_list(rows) ->
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
  end

  # HeavyRead opts for a memory recall, with the caller's shed policy layered on. `:raise`
  # is `all_memory`'s own default, so it is only threaded explicitly for `:tag`.
  defp memory_recall_opts(:tag),
    do: Keyword.put(HeavyRead.opts(:memory_recall), :on_overload, :tag)

  defp memory_recall_opts(_), do: HeavyRead.opts(:memory_recall)

  # The empty, degraded memory envelope returned when the per-tenant HeavyRead cap SHED
  # the memory read on the merged `/recall` path (`on_overload: :tag`). Emits an
  # alertable telemetry event + log (the shed is otherwise silent here — a `:raise` shed
  # would have surfaced as a 429) so operators can see a memory-half degradation, then
  # returns empty so the knowledge half of the merged recall is still served rather than
  # the whole endpoint 429-ing. `reason` mirrors the memory `meta.reason` fallback-tag
  # contract (like the embedding-fallback tags), so callers can tell the memory side is
  # empty by capacity, not by scope.
  defp overloaded_memory_env(tenant_id, k) do
    emit_recall_degraded(tenant_id, "memory", "heavy_read_overloaded")

    %{
      results: [],
      meta: %{
        total_count: 0,
        fallback: true,
        reason: "heavy_read_overloaded",
        underfilled: k > 0
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
    # US-41.1 AC-41.1.5: behind the explicit, reversible cutover flag the ANN runs over
    # the dimension-tagged `memory_embeddings` side table so a tenant on a non-1536
    # model is recallable at all. Same filter-after-ANN shape either way.
    if Embeddings.side_table_reads_enabled?() do
      memory_side_table_candidate_query(scope, embedding, k, include_superseded?)
    else
      memory_legacy_candidate_query(scope, embedding, k, include_superseded?)
    end
  end

  # The DIMENSION-SCOPED side-table recall.
  #
  # INNER: `memory_embeddings` alone, ordered by the explicit `(embedding::vector(N))`
  # cast the per-dimension index is built over, carrying ONLY that index's partial
  # predicate (`tenant_id`, `dim`, `live_denorm`). No join, no subject predicate — both
  # would flip the planner off HNSW. OUTER: the `memories` join (which carries its own
  # conjunctive `tenant_id ==` equality, so `guard!/2` accepts both sources) plus the
  # subject equality on the OUTPUT binding, which is exactly what `guard_memory!/3`
  # requires — `subject_id` is DENORMALIZED onto the side table so the outer binding
  # can carry it without a second `memories` reference inside the ANN.
  #
  # `include_superseded: true` drops `live_denorm`, so that ADMIN/oversight path has no
  # matching partial index and plans as a bounded top-k sort over the tenant's rows at
  # this dimension. That is the deliberate tradeoff: the AC mandates the LIVE-row
  # predicate on the per-dimension index, and building a second, full index per
  # dimension would double an already-expensive HNSW build at corpus scale for a path
  # that is not on the interactive recall route.
  defp memory_side_table_candidate_query(scope, embedding, k, include_superseded?) do
    target = VectorSearch.to_embedding_list(embedding)
    pool = recall_pool_size(scope, k)
    dimension = Embeddings.active_dimension(scope.tenant_id)

    inner =
      MemoryEmbedding
      |> VectorSearch.index_safe_dimension_knn_base(scope.tenant_id, target, dimension, pool,
        live_only: not include_superseded?
      )
      |> select([e], %{
        memory_id: e.memory_id,
        tenant_id: e.tenant_id,
        subject_id: e.subject_id
      })
      |> VectorSearch.put_dimension_distance(dimension, target)

    from(c in subquery(inner),
      as: :embedding,
      join: m in MemorySchema,
      as: :memory,
      on: m.id == c.memory_id and m.tenant_id == ^scope.tenant_id,
      where: c.subject_id == ^scope.subject_id,
      order_by: [asc: c.distance],
      limit: ^k,
      select: %{
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
        updated_at: m.updated_at,
        distance: c.distance
      }
    )
    |> maybe_exclude_superseded_joined(include_superseded?)
    |> maybe_scope_project(scope.project_id)
  end

  # The superseded exclusion for the JOINED side-table shape: `memories` is the
  # `:memory` NAMED binding here (binding 0 is the embeddings subquery), so the
  # positional `[c]` form used by the legacy path would target the wrong source.
  defp maybe_exclude_superseded_joined(query, true), do: query

  defp maybe_exclude_superseded_joined(query, false),
    do: where(query, [memory: m], is_nil(m.superseded_by))

  defp memory_legacy_candidate_query(scope, embedding, k, include_superseded?) do
    target = VectorSearch.to_embedding_list(embedding)
    pool = recall_pool_size(scope, k)

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
      as: :memory,
      where: c.subject_id == ^scope.subject_id,
      order_by: [asc: c.distance],
      limit: ^k,
      select: c
    )
    |> maybe_exclude_superseded_sub(include_superseded?)
    |> maybe_scope_project(scope.project_id)
  end

  # POOL SIZING (#411 Gap 2): `VectorSearch.pool_size/2` is calibrated for SUBJECT
  # dilution ONLY (the subject filter lives on the OUTER query, off the HNSW inner ANN).
  # The project scope (`maybe_scope_project/2`) is a SECOND, independent outer filter
  # over this SAME pool, so a subject whose in-scope (global + active-project) rows are
  # sparse relative to its total cross-project corpus can under-fill (surfaced via
  # `meta.underfilled`). MITIGATION: when a project scope is ACTIVE we DOUBLE the
  # over-fetch factor so the project filter draws from more candidate rows before
  # LIMIT k — strictly REDUCING (never eliminating) the compounded under-fill window.
  # It stays bounded by `:max_vector_pool` (the `min(cap)` in `pool_size/2`), so
  # worst-case recall cost is unchanged and the deterministic under-fill test (whose
  # cap pins the pool) is unaffected. FULL pool re-calibration with a VERIFIED combined
  # subject×project dilution bound remains the US-28.5 scale story that owns pool
  # calibration; this is the safe interim mitigation, not that calibration.
  defp recall_pool_size(%Scope{project_id: project_id}, k) when is_binary(project_id) do
    VectorSearch.pool_size(k, factor: VectorSearch.pool_factor() * 2)
  end

  defp recall_pool_size(%Scope{}, k), do: VectorSearch.pool_size(k)

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

  # #411 Gap 2: recall returns the merged `global ∪ active-project` set. `project_id`
  # is a PARTITION key, NOT an isolation boundary — `tenant_id`/`subject_id` are (see
  # `Memory.Scope` moduledoc). So a nil scope resolves to global-only
  # (`project_id IS NULL`) and a present project merges global with that project. The
  # `:binary_id` cast is guarded the way Knowledge does it: a malformed (non-UUID)
  # value scopes to global-only rather than raising `Ecto.Query.CastError` (controllers
  # 4xx at the boundary — this is defense in depth).
  #
  # ONE helper (was two hand-copied `_outer`/`_base` clauses — a silent-drift hazard
  # on an isolation-adjacent path, #411 review). It targets the NAMED `:memory`
  # binding, which BOTH call sites declare (`as: :memory`): the semantic path's outer
  # over-the-pool subquery (whose `select` projects `project_id`) and the fallback
  # path's base `memories` table. Naming the binding (rather than the former positional
  # `[x]` first-binding) makes the "this must filter the memories relation" dependency
  # EXPLICIT and compile-checked: a future refactor that introduces a join with a
  # different first binding, or drops the `as: :memory`, fails to compile here instead
  # of silently filtering the wrong table on an isolation-adjacent path (#411 review).
  # NB: Memory's nil semantics (nil → global-only) DELIBERATELY differ from
  # `Loopctl.Knowledge.scope_project_or_global/2` (nil → no project filter at all);
  # they are different features, so this is intentionally NOT shared across contexts.
  #
  # This predicate MUST stay on the OUTER over-the-pool query (like the subject and
  # superseded filters) — never on `index_safe_knn_base`'s inner ANN, where a
  # selective predicate would flip the planner off the HNSW index.
  defp maybe_scope_project(query, project_id) when is_binary(project_id) do
    if valid_uuid?(project_id) do
      where(query, [memory: m], is_nil(m.project_id) or m.project_id == ^project_id)
    else
      where(query, [memory: m], is_nil(m.project_id))
    end
  end

  defp maybe_scope_project(query, _), do: where(query, [memory: m], is_nil(m.project_id))

  # Rebuild a %Memory{} from the recalled projection map. `embedding` is
  # `load_in_query: false` so it is intentionally absent (recall never returns the
  # raw vector); `:distance` is a computed column, dropped before struct build.
  defp row_to_memory(row) do
    struct(MemorySchema, Map.drop(row, [:distance]))
  end

  defp recall_fallback(scope, reason, query_text, k, include_superseded?, on_overload) do
    reason_tag = fallback_reason_tag(reason)

    query =
      from(m in MemorySchema,
        as: :memory,
        where: m.tenant_id == ^scope.tenant_id,
        where: m.subject_id == ^scope.subject_id,
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: ^k
      )
      |> maybe_exclude_superseded_base(include_superseded?)
      |> maybe_ilike(query_text)
      |> maybe_scope_project(scope.project_id)

    case HeavyRead.all_memory(
           scope.tenant_id,
           scope.subject_id,
           query,
           memory_recall_opts(on_overload)
         ) do
      {:error, :heavy_read_overloaded} ->
        overloaded_memory_env(scope.tenant_id, k)

      rows when is_list(rows) ->
        results = Enum.map(rows, fn memory -> {memory, nil} end)

        %{
          results: results,
          meta:
            %{
              total_count: length(results),
              fallback: true,
              reason: reason_tag,
              underfilled: length(results) < k
            }
            # US-41.4 (AC-41.4.7): WHENEVER the semantic path is unavailable the
            # response meta names the reason AND the offending endpoint, plus the
            # reserved `excluded_tiers`. This story threaded the egress scope through
            # the MEMORY path too, so the memory half carries the identical contract
            # as `Loopctl.Knowledge` search — an agent must never get a generic
            # "embedding_error" for what is actually a local_only refusal.
            |> Map.merge(Egress.degraded_contract_meta(scope.tenant_id, reason_tag))
        }
    end
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
  # US-41.4 (AC-41.4.6/.7): a fail-CLOSED egress refusal, in either the tagged
  # `{tag, details}` form or as a bare atom. Without these clauses
  # `ProviderError.sanitize/1`'s catch-all passed the term through to
  # `api_error_tag/1`, which reported the agent-illegible generic "embedding_error"
  # with no egress reason, no offending_endpoint and no degraded flag.
  defp fallback_reason_tag(refusal) when is_egress_refusal(refusal),
    do: refusal |> elem(0) |> to_string()

  defp fallback_reason_tag(reason)
       when reason in [:egress_blocked, :pin_stale, :egress_unavailable],
       do: to_string(reason)

  defp fallback_reason_tag(reason) do
    case ProviderError.sanitize(reason) do
      :no_api_key ->
        "no_embedding_key"

      :circuit_open ->
        "embedding_circuit_open"

      :timeout ->
        "embedding_timeout"

      {:request_failed, _} ->
        "embedding_request_failed"

      {:embedding_crash, _} ->
        "embedding_crash"

      other ->
        api_error_tag(other)
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
  # Merged recall (memory ∪ knowledge) — #411 Gap 2 PR B
  # ===========================================================================

  @doc """
  Runs BOTH the long-term memory recall AND the knowledge combined search for one
  `(query, project_id)` and returns a single merged, re-ranked result — the
  `global ∪ active-project` recall the harness previously had to assemble by calling
  `memory_recall` and `knowledge_context`/`knowledge_search` separately (#411 Gap 2).

  Both sub-recalls merge global with the active project:

    * memory — `recall/2` (already merges `global ∪ scope.project_id`; PR A).
    * knowledge — `Loopctl.Knowledge.search_combined/3` with
      `project_scope: :with_global`, so a project-scoped combined search ALSO surfaces
      tenant-wide (global) articles rather than project-only.

  `project_id` is the PARTITION key on both sides, NOT the isolation boundary
  (`tenant_id`/`subject_id` are — they come from `scope`, never the body). A nil
  `scope.project_id` is GLOBAL-ONLY on BOTH sides (memory: `project_id IS NULL`;
  knowledge: `:with_global` with a nil project also scopes to `project_id IS NULL`),
  so with no active project the union is global-only — matching the published
  RecallContextRequest / MCP recall_context contract. A present project merges global
  with that project on both.

  ## Scores are heuristically comparable, NOT calibrated

  The merged list is sorted by a single `score` DESC across BOTH sources, but the two
  scores come from different scales:

    * memory `score` = `max(0, 1 - cosine_distance)` — an absolute per-row similarity
      in `[0, 1]` (or `nil` on the ILIKE text-match fallback path, treated as `0.0`
      for ranking only).
    * knowledge `score` = the combined search's `final_score` — a weighted
      keyword+semantic score, MIN-MAX normalized WITHIN the returned pool (so it is
      pool-relative, not an absolute similarity).

  KNOWN BIAS: because the knowledge `final_score` is min-max normalized within the
  returned pool, the top knowledge row is ~1.0 regardless of its ABSOLUTE relevance,
  so knowledge items systematically outrank memory items in the default `results`
  ordering even when the memory matches are strong. This is a documented heuristic,
  NOT a calibrated cross-source ranking — do NOT read the merged `results` order as
  "knowledge was more relevant than memory". `meta.results_ranking` carries the stable
  tag `"heuristic_cross_source"` so consumers can detect this programmatically.

  Treat the cross-source ordering as a useful heuristic, not a calibrated ranking.
  Callers that need a calibrated re-rank get BOTH the merged view AND the untouched
  per-source envelopes (`:memory`, `:knowledge`), each carrying its own native scores.

  ## Degradation, never a 500 (and never a whole-endpoint 429)

  Degradation is SYMMETRIC across both halves — one degraded half never fails the whole
  call:

    * If `search_combined/3` returns an error (invalid weights, etc.) the knowledge side
      degrades to empty results with `meta.degraded?: true` and the memory side is still
      returned — the merged call never crashes on a knowledge fault. A keyword-only
      knowledge fallback (embedding unavailable) also sets `degraded?: true`.
    * If the per-tenant HeavyRead cap SHEDS the memory read, the merged path threads
      `on_overload: :tag` so the memory side degrades to an EMPTY envelope (with
      `degraded?: true`) instead of raising `OverloadedError` — so a shed memory pool
      429-ing cannot discard the knowledge results the caller could still have gotten.
      (The standalone `/memory/recall` keeps `on_overload: :raise` → a 429.)

  `meta.degraded_reason` names WHY (a bounded tag), and the knowledge/memory-half
  degradation each emits a `[:loopctl, :memory, :recall_context, :degraded]` telemetry
  event + log so a silent partial failure is alertable.

  ## Concurrency & cost

  The two halves run SEQUENTIALLY (memory read, then knowledge combined read), not
  Task-parallel — a deliberate cap-friendly choice that holds at most ONE per-tenant
  HeavyRead slot at a time. The tradeoff: additive (not max) wall-clock latency and ~2x
  the governed heavy-read throughput of a single search per `/recall`. Parallelizing is
  intentionally NOT done, because two simultaneous slots would double a single request's
  peak pressure under the very cap that shields other tenants.

  ## Known bias on the degraded path

  On a degraded knowledge side (keyword-only fallback) memory rows carry absolute cosine
  scores while knowledge rows carry raw (un-normalized) keyword `relevance_score`, which
  can exceed memory's cosine max of 1.0 and outrank memory in the merged `data`. A caller
  needing memory-first ordering under degradation should read the per-source `:memory`
  envelope (it preserves the honest native scores/nils), disclosed via `meta.degraded?`.

  ## Options

    * `:query` — the query text (default `""`); embedded/ILIKE'd on the memory side and
      passed to the knowledge combined search.
    * `:limit` — overall merged page size, clamped to `[1, #{@max_context_limit}]`
      (default #{@default_context_limit}). Applied per-source first, then to the merged,
      re-ranked list.
    * `:status` — knowledge status filter (controllers force `:published` for agent/
      orchestrator roles, mirroring `knowledge/context`).
    * `:visibility_agent_id` — knowledge agent-memory visibility scope (#163), passed
      through to `search_combined/3` exactly as the knowledge context controller does.

  ## Returns

      %{
        results: [
          %{source: :memory, score: float, memory: %Memory{}}
          | %{source: :knowledge, score: float, article: map()}
        ],                                   # merged, sorted score DESC, capped at limit
        memory: <the recall/2 envelope, unchanged>,
        knowledge: <the search_combined envelope (results + meta), or a degraded stub>,
        meta: %{
          query: String.t(),
          project_id: String.t() | nil,
          total_count: non_neg_integer(),    # length(results) after the merged cap
          memory_count: non_neg_integer(),   # memory rows BEFORE the merged cap
          knowledge_count: non_neg_integer(),# knowledge rows BEFORE the merged cap
          degraded?: boolean(),              # knowledge errored/fell back OR memory shed
          degraded_reason: String.t() | nil, # bounded tag naming why (nil when healthy)
          results_ranking: String.t()        # "heuristic_cross_source" (see KNOWN BIAS)
        }
      }

  NB the `:article` on a `:knowledge` merged item is the `search_combined/3` result map
  (article summary — id/title/category/tags/snippet + scores), the same shape the
  knowledge search endpoints serialize, NOT a hydrated `%Loopctl.Knowledge.Article{}`
  with a full body. The per-source `:knowledge` envelope carries the identical maps;
  callers wanting full bodies deep-read via `knowledge/context`.
  """
  @spec recall_context(Scope.t(), keyword() | map()) :: %{
          results: [map()],
          memory: result_envelope(),
          knowledge: %{results: [map()], meta: map()},
          meta: map()
        }
  def recall_context(%Scope{} = scope, opts \\ []) do
    query = to_string(opt(opts, :query, ""))
    limit = clamp_context_limit(opt(opts, :limit, @default_context_limit))

    # Generate the query embedding ONCE and thread it into BOTH halves. This
    # single-round-trip endpoint otherwise made TWO uncached outbound provider calls
    # for the identical query (recall/2 → generate_embedding AND knowledge_recall →
    # search_combined → try_generate_embedding), doubling embedding latency/cost and
    # consuming two per-tenant embedding-concurrency slots. Sharing one embedding also
    # makes the two halves' semantic-vs-keyword degradation AGREE (previously the
    # memory side could succeed while the knowledge side independently fell back).
    embedding_result = Knowledge.generate_embedding(scope.tenant_id, query, egress_opts(scope))

    # The two halves run SEQUENTIALLY (memory heavy-read, then the knowledge combined
    # keyword+semantic reads) rather than Task-parallel — a DELIBERATE cap-friendly
    # choice, NOT an oversight. Parallelizing would hold TWO per-tenant HeavyRead slots
    # simultaneously under the very cap that shields other tenants (US-37.5), doubling a
    # single /recall's peak concurrent slot pressure and raising the shed probability the
    # cap exists to bound; sequential holds at most ONE slot at a time. The tradeoff is
    # additive (not max) wall-clock latency and ~2x the governed heavy-read THROUGHPUT of
    # a single search per /recall — acceptable while the endpoint is throughput/cap-bound
    # rather than latency-bound. `on_overload: :tag` degrades a memory-half shed to an
    # empty envelope so it never sinks the whole endpoint (symmetric with the knowledge
    # half's keyword-only degrade).
    memory_env =
      recall(scope, query: query, limit: limit, embedding: embedding_result, on_overload: :tag)

    knowledge_env = knowledge_recall(scope, query, limit, opts, embedding_result)

    memory_items =
      Enum.map(memory_env.results, fn {memory, score} ->
        %{source: :memory, score: score, memory: memory}
      end)

    knowledge_items =
      Enum.map(knowledge_env.results, fn result ->
        %{source: :knowledge, score: knowledge_score(result), article: result}
      end)

    merged =
      (memory_items ++ knowledge_items)
      # `score` can be nil on the memory ILIKE fallback path — rank it as 0.0 without
      # mutating the per-source envelope (which preserves the honest nil).
      |> Enum.sort_by(&(&1.score || 0.0), :desc)
      |> Enum.take(limit)

    %{
      results: merged,
      memory: memory_env,
      knowledge: knowledge_env,
      meta: %{
        query: query,
        project_id: scope.project_id,
        total_count: length(merged),
        memory_count: length(memory_items),
        knowledge_count: length(knowledge_items),
        # `degraded?` is true when EITHER half degraded: the knowledge side errored/fell
        # back to keyword-only, OR the memory heavy-read pool was shed (empty by capacity).
        degraded?: knowledge_degraded?(knowledge_env) or memory_degraded?(memory_env),
        # A BOUNDED, non-sensitive tag naming WHY the merged recall degraded (or `nil`
        # when it did not), so a caller can distinguish a scope-empty half from a
        # fault-empty one without parsing the per-source envelopes. Knowledge degradation
        # is reported first (it drives the documented `degraded?`), then memory.
        degraded_reason: merged_degraded_reason(memory_env, knowledge_env),
        # The merged `results` order sorts memory's ABSOLUTE cosine similarity against
        # knowledge's POOL-NORMALIZED final_score — a heuristic, not a calibrated
        # cross-source ranking (knowledge is biased upward; see the moduledoc). Surface
        # a stable tag so consumers don't mistake the order for calibrated relevance.
        results_ranking: "heuristic_cross_source"
      }
    }
  end

  # Run the knowledge half via `search_combined/3` with the merged `:with_global`
  # project scope, translating its `{:ok, env} | {:error, ...}` result into a UNIFORM
  # `%{results: [...], meta: %{...}}` envelope. On ANY error (empty query, invalid
  # weights, bad_request) the knowledge side degrades to empty results tagged
  # `degraded?: true` — the merged call never propagates a knowledge fault as a crash.
  defp knowledge_recall(scope, query, limit, opts, embedding_result) do
    kopts =
      [
        project_id: scope.project_id,
        project_scope: :with_global,
        limit: limit
      ]
      |> maybe_put_opt(:status, opt(opts, :status, nil))
      |> maybe_put_opt(:visibility_agent_id, opt(opts, :visibility_agent_id, nil))
      # Thread the read-attribution key so `search_combined/3` records knowledge-access
      # analytics for /recall traffic (the guard in `maybe_record_search_access/5` skips
      # recording when `:api_key_id` is nil). Sibling search/context endpoints set it too.
      |> maybe_put_opt(:api_key_id, opt(opts, :api_key_id, nil))
      # Reuse the embedding generated ONCE in `recall_context/2` so the knowledge half
      # does not make a second provider call for the identical query (#411 Gap 2).
      |> maybe_put_opt(:embedding, embedding_result)

    case Knowledge.search_combined(scope.tenant_id, query, kopts) do
      {:ok, %{results: results, meta: meta}} ->
        # A keyword-only fallback (embedding unavailable) sets meta.fallback; carry
        # that forward as degraded? so the merged meta reflects a degraded knowledge side.
        %{results: results, meta: Map.put(meta, :degraded?, Map.get(meta, :fallback, false))}

      {:error, reason} ->
        degraded_knowledge_env(scope.tenant_id, reason, limit)

      {:error, reason, _message} ->
        degraded_knowledge_env(scope.tenant_id, reason, limit)
    end
  end

  # The uniform empty/degraded knowledge envelope used when `search_combined/3` returns
  # a hard `{:error, _}` (empty query, invalid weights, ...) rather than a keyword-only
  # fallback. Emits an alertable telemetry event + log (this branch was otherwise
  # SILENT — no signal for operators, unlike the keyword-fallback path which records a
  # reason) and builds a meta that is SHAPE-COMPATIBLE with the healthy
  # `search_combined/3` meta (`total_count`/`limit`/`offset`) so the endpoint serializer
  # can project it through the SAME `KnowledgeSearchJSON.render_meta` whitelist the
  # standalone knowledge endpoints use. The reason is carried ONLY as a BOUNDED,
  # non-sensitive `fallback_reason` tag — the raw internal reason atom is NEVER placed
  # in the client-facing meta (it lives only in telemetry/logs), so `/recall` no longer
  # leaks an internal atom the equivalent `/knowledge/search` would have stripped.
  defp degraded_knowledge_env(tenant_id, reason, limit) do
    tag = knowledge_degraded_reason_tag(reason)
    emit_recall_degraded(tenant_id, "knowledge", tag)

    %{
      results: [],
      meta: %{
        total_count: 0,
        limit: limit,
        offset: 0,
        degraded?: true,
        fallback: true,
        fallback_reason: tag
      }
    }
  end

  # Map a `search_combined/3` hard-error reason atom to a BOUNDED, non-sensitive tag safe
  # to surface in `meta`/telemetry (never the raw atom). These three atoms are the FULL
  # error contract of `search_combined/3` (dialyzer-verified) — with the controller now
  # rejecting blank AND over-length queries up front, `:empty_query`/`:bad_request` are
  # unreachable via `/recall`, but any of the contract's reasons is coerced to this set.
  defp knowledge_degraded_reason_tag(:empty_query), do: "empty_query"
  defp knowledge_degraded_reason_tag(:invalid_weights), do: "invalid_weights"
  defp knowledge_degraded_reason_tag(:bad_request), do: "bad_request"

  # Emit the merged-recall degradation signal (telemetry + log) for ONE degraded half so
  # a silent partial failure of `/recall` is alertable. `reason`/`side` are BOUNDED tags;
  # the query TEXT is never included (matching the other knowledge/memory telemetry).
  defp emit_recall_degraded(tenant_id, side, reason) do
    :telemetry.execute(
      TelemetryEvents.recall_context_degraded(),
      %{count: 1},
      %{tenant_id: tenant_id, side: side, reason: reason}
    )

    Logger.warning(
      "memory.recall_context degraded side=#{side} reason=#{reason} tenant_id=#{tenant_id}"
    )

    :ok
  end

  defp knowledge_degraded?(%{meta: meta}), do: Map.get(meta, :degraded?, false) == true

  # The memory half is "degraded" for the merged `degraded?`/`degraded_reason` ONLY when
  # its heavy read was SHED by the per-tenant cap (empty by capacity). An ordinary
  # embedding-unavailable ILIKE fallback is NOT counted here — that path degrades BOTH
  # halves and is already reflected via the knowledge side's keyword-only fallback.
  defp memory_degraded?(%{meta: meta}), do: Map.get(meta, :reason) == "heavy_read_overloaded"

  # A BOUNDED, non-sensitive tag naming why the merged recall degraded, or `nil`. Reports
  # the knowledge side first (it drives the documented `degraded?`), then memory.
  defp merged_degraded_reason(memory_env, knowledge_env) do
    cond do
      knowledge_degraded?(knowledge_env) ->
        knowledge_env.meta[:fallback_reason] || "knowledge_degraded"

      memory_degraded?(memory_env) ->
        memory_env.meta[:reason]

      true ->
        nil
    end
  end

  # Knowledge combined ranking score. Normal combined results carry `:final_score`
  # (pool-normalized weighted keyword+semantic, in [0, 1]); when combined DEGRADES to a
  # keyword-only fallback the results carry `:relevance_score` (and no `:final_score`),
  # so mirror `KnowledgeSearchJSON.extract_score/2`'s chain
  # (`final_score || relevance_score || similarity_score`) via bracket access rather
  # than scoring every degraded-path item 0.0 and sinking all knowledge below memory.
  # Defaults to 0.0 for a malformed/scoreless result map (defensive).
  defp knowledge_score(result) when is_map(result) do
    score = result[:final_score] || result[:relevance_score] || result[:similarity_score]
    if is_number(score), do: score, else: 0.0
  end

  defp knowledge_score(_), do: 0.0

  defp clamp_context_limit(limit),
    do: limit |> to_int(@default_context_limit) |> max(1) |> min(@max_context_limit)

  # Add `{key, value}` to the opts only when value is non-nil, so an absent status /
  # visibility scope leaves `search_combined/3` on its own defaults.
  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

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
  # Graduation — HOT long-term memories → durable knowledge articles (#411 Gap 3)
  # ===========================================================================
  #
  # DISTINCT from the Epic 29 promotion pipeline below (session turns → long-term
  # `memories`). Graduation is the NEXT tier up: a long-term memory that has been
  # recalled often enough (`recall_count >= graduation_recall_threshold/0`) is written
  # back into the curated Knowledge Wiki as a durable article, DEDUPED by the same
  # novelty gate (`Loopctl.Knowledge.propose_article/3`) that guards every agent
  # write-back — so re-graduation races and semantically-duplicate memories cannot
  # bloat the corpus. The scheduled cadence is `Loopctl.Workers.MemoryGraduationSweepWorker`;
  # `graduate_memory/3` is the explicit (per-memory) trigger the `memory_promote`-class
  # primitive maps onto, and is where the local→global re-scope option lives.

  @doc """
  Explicit graduation of ONE memory (by id, within `scope`) into a durable knowledge
  article.

  The `scope` `(tenant_id, subject_id)` is the isolation boundary — a caller may only
  graduate its OWN memory; a foreign/nonexistent id returns `{:error, :not_found}`
  (no cross-subject existence oracle). On success returns `{:ok, verdict, article}`
  where `verdict` is the novelty-gate outcome
  (`:created | :gated_to_draft | :duplicate | :deduplicated`).

  ## local→global re-scope (`:re_scope`)

  By DEFAULT the article inherits the memory's scope (`project_id`) — a project memory
  graduates to a project article, a global memory to a global article. Pass
  `re_scope: :global` to promote a PROJECT-scoped memory to a tenant-wide (global,
  `project_id: nil`) article. This is the ONLY way a memory changes scope on
  graduation: the automated sweep NEVER re-scopes (it always keeps the memory's scope),
  because over-generalizing a project fact to tenant-wide is a mis-scoping the novelty
  gate cannot catch — it must be an explicit, deliberate caller action.
  """
  @spec graduate_memory(Scope.t(), String.t(), keyword()) ::
          {:ok, atom(), Loopctl.Knowledge.Article.t()} | {:error, :not_found | term()}
  def graduate_memory(%Scope{} = scope, memory_id, opts \\ []) when is_binary(memory_id) do
    case fetch_owned_memory(scope, memory_id) do
      nil ->
        {:error, :not_found}

      %MemorySchema{} = memory ->
        # EXPLICIT (on-demand) graduation must NOT terminally stamp `graduated_at` on a
        # structural failure the way the sweep does for livelock protection: an over-size
        # body would otherwise 422 while silently consuming the memory's one-shot
        # graduation with no article and no recovery. Let the caller fix and retry.
        graduate_memory_record(memory, Keyword.put(opts, :stamp_structural_error, false))
    end
  end

  @doc """
  Graduates a `%Memory{}` record into a durable knowledge article via the novelty gate.

  Shared by `graduate_memory/3` (explicit) and `MemoryGraduationSweepWorker` (cadence).
  Builds the article attrs from the memory (title = first line of the text, body = the
  full text, category `:finding`, the memory's tags), threads a stable `idempotency_key`
  so re-graduating the same memory is a no-op dedup, then calls
  `Loopctl.Knowledge.propose_article/3`.

  On ANY successful verdict `graduated_at` is stamped (idempotently, only if still NULL)
  and the memory is never re-processed by the sweep — but the DURABILITY guarantee differs
  by verdict:

    * `:created` / `:duplicate` / `:deduplicated` — the content is represented by a
      PUBLISHED article (a fresh one, or the canonical existing one), i.e. searchable now.
    * `:gated_to_draft` — the novelty gate judged the content a near-duplicate and created
      it as an UNPUBLISHED draft in the human-review queue. It is NOT yet searchable; a
      reviewer publishes or discards it. Stamping is still correct: the content IS
      represented (as a draft), and re-selecting the memory would only re-spend embedding
      budget to hit the idempotency no-op — but the sweep does NOT re-materialize a draft
      that a reviewer later discards.

  A STRUCTURAL `{:error, changeset}` IS stamped, because it can never succeed on retry;
  leaving it un-stamped would livelock the hottest-first sweep on a permanently-invalid
  candidate, re-spending embedding budget every run.

  A TRANSIENT `{:error, :gate_unavailable}` — the novelty gate FELL OPEN because the
  embedding backend was down and could not actually assess novelty — is NOT stamped and
  NO article is created (`on_gate_unavailable: :skip` is passed to the gate). The memory
  stays eligible so a later tick RE-graduates and dedups once embeddings recover, instead
  of injecting an un-deduplicated published article during the outage and burning the
  memory's one-shot graduation.

  ## Embedding reuse

  The memory already stores its own `vector(1536)` embedding (populated async by
  `MemoryEmbeddingWorker`). When present it is threaded into the novelty gate
  (`propose_article/3` → `assess/3`) so graduation reuses it instead of paying a second
  embedding round-trip for the identical text; when the memory has not been embedded yet
  (NULL) the gate embeds as before.

  ## re_scope on an already-graduated memory refuses LOUDLY

  A memory has AT MOST ONE graduated article — the `(tenant_id, title)` unique index
  admits only one article per memory-title, so a project article and a global article of
  the SAME memory cannot coexist. `re_scope: :global` on an already-graduated PROJECT
  memory therefore returns `{:error, :already_graduated}` instead of silently hitting the
  existing article's idempotency/title path and returning the WRONG-scoped article as
  success. (On an already-graduated GLOBAL memory `re_scope: :global` is a no-op — same
  scope — so it dedups idempotently, NOT a 409.) Globalize a PROJECT memory by passing
  `re_scope: :global` on its FIRST graduation, before the hourly sweep graduates it
  project-scoped — the sweep never re-scopes, so if it graduates a project memory first,
  `re_scope: :global` will permanently 409 and that memory can no longer become
  tenant-wide (a nondeterministic race the caller cannot beat; graduate promptly, or
  re-point the published article's scope as a separate curation action). The per-memory,
  per-scope `idempotency_key` keeps a same-scope re-graduation an idempotent no-op, and an
  already-graduated memory SHORT-CIRCUITS to its existing article WITHOUT re-running the
  novelty gate (no repeated assessment/embedding spend).

  ## Reachability

  `graduate_memory/3` (explicit, incl. `re_scope: :global`) and
  `MemoryGraduationSweepWorker` (the hourly cadence, which never re-scopes) are its
  callers. The explicit primitive is now exposed on-demand to agents via
  `POST /api/v1/memory/graduate` (`MemoryController.graduate/2`) and the MCP
  `memory_graduate` tool — including the `re_scope: :global` path, driven by the
  endpoint's `re_scope` param (enum `"inherit"`/`"global"`). Ownership is enforced by the
  `(tenant_id, subject_id)` scope in `graduate_memory/3`, and the explicit path
  deliberately bypasses the sweep's recall-threshold/per-run caps (see
  `MemoryController.graduate/2` for the cost-model rationale).

  Options: `:re_scope` (`:global` → `project_id: nil`); `:actor_id`/`:actor_label`/
  `:actor_type` are forwarded to `propose_article/3` for audit attribution.
  """
  @spec graduate_memory_record(MemorySchema.t(), keyword()) ::
          {:ok, atom(), Loopctl.Knowledge.Article.t()}
          | {:error, :already_graduated | :gate_unavailable | term()}
  def graduate_memory_record(%MemorySchema{} = memory, opts \\ []) do
    cond do
      re_scope_conflict?(memory, opts) ->
        # An already-graduated PROJECT memory cannot gain a second, GLOBAL article (one
        # article per memory-title). Refuse LOUDLY rather than silently returning the
        # existing wrong-scoped article as success.
        {:error, :already_graduated}

      graduated?(memory) ->
        # Already graduated at its OWN scope (a same-scope retry, or `re_scope: :global`
        # on an already-global memory). Return the EXISTING article WITHOUT re-running the
        # novelty gate: `propose_article/3` ALWAYS assesses (and, for a not-yet-embedded
        # memory, embeds on the tenant's key) BEFORE the idempotency dedup, so re-proposing
        # an already-graduated memory would burn embedding/vector-search spend on EVERY
        # call. Short-circuit to the idempotent no-op the one-shot-per-memory cost model
        # (see `MemoryController.graduate/2`) actually assumes.
        resolve_existing_graduation(memory, opts)

      true ->
        do_graduate_memory_record(memory, opts)
    end
  end

  defp graduated?(%MemorySchema{graduated_at: nil}), do: false
  defp graduated?(%MemorySchema{}), do: true

  # `re_scope: :global` only takes effect on a memory that has not yet graduated; on an
  # already-graduated PROJECT memory it would collide with the existing article, so it is
  # refused. The sweep only ever calls with ungraduated memories (its query filters
  # `graduated_at IS NULL`), so this never affects the automated cadence.
  defp re_scope_conflict?(%MemorySchema{graduated_at: nil}, _opts), do: false
  # A GLOBAL memory (`project_id: nil`) is already tenant-wide, so `re_scope: :global` on
  # it is a semantic no-op — same `project_id`, same scope-encoded `idempotency_key`. It
  # can NEVER conflict; let it fall through to the idempotent short-circuit (200) instead
  # of a misleading 409 that claims a "different scope" and breaks defensive retries.
  defp re_scope_conflict?(%MemorySchema{project_id: nil}, _opts), do: false
  defp re_scope_conflict?(%MemorySchema{}, opts), do: Keyword.get(opts, :re_scope) == :global

  # The memory already has its single graduated article; look it up by the deterministic
  # per-scope idempotency key (owner-visible to the memory's subject) and return it as an
  # idempotent no-op instead of re-proposing. A graduated memory with NO live article (a
  # discarded draft, or a sweep-stamped structural failure) cannot be re-graduated → 409.
  defp resolve_existing_graduation(%MemorySchema{} = memory, opts) do
    project_id = graduation_project_id(memory, opts)
    key = graduation_idempotency_key(memory.id, project_id)

    case Knowledge.get_article_by_idempotency_key(memory.tenant_id, key, memory.subject_id) do
      nil -> {:error, :already_graduated}
      article -> {:ok, :duplicate, article}
    end
  end

  defp do_graduate_memory_record(%MemorySchema{} = memory, opts) do
    project_id = graduation_project_id(memory, opts)
    attrs = memory_to_article_attrs(memory, project_id)

    case Knowledge.propose_article(memory.tenant_id, attrs, propose_opts(memory, opts)) do
      {:ok, %{verdict: verdict, article: article}} ->
        stamp_graduated(memory)
        {:ok, verdict, article}

      {:error, :gate_unavailable} ->
        # The gate FELL OPEN (embedding backend down) — it could not assess novelty, so
        # nothing was created. Do NOT stamp: leave the memory eligible so a later tick
        # re-graduates and dedups once embeddings recover, rather than permanently marking
        # it graduated on an un-assessed (and un-deduplicated) outcome.
        {:error, :gate_unavailable}

      {:error, :duplicate_title, existing} ->
        # A same-title collision — the FULL memory-id title suffix makes this unreachable
        # for a DISTINCT memory (two distinct memories can no longer collide on title), so
        # the colliding row is ANOTHER graduation of THIS SAME memory. Two cases, told
        # apart by the existing article's scope:
        #   * SAME scope as requested — a concurrent same-scope graduation raced past the
        #     idempotency pre-check and won; the content IS represented at the right scope,
        #     so this is an idempotent no-op (stamp + `:duplicate`).
        #   * DIFFERENT scope — a concurrent FIRST graduation with a DIFFERING `re_scope`
        #     already created this memory's single article at another scope. The in-memory
        #     `graduated_at` guard can't catch this (both racers read `nil`); the
        #     scope-independent `(tenant_id, title)` unique index collapses them and the
        #     loser lands HERE. Returning `{:ok, :duplicate, existing}` would hand back the
        #     WRONG-scoped article as success and permanently mis-scope the memory, so we
        #     refuse LOUDLY (`:already_graduated` → 409) — closing the TOCTOU race so the
        #     one-article-per-memory guarantee holds without a row lock.
        if existing.project_id == graduation_project_id(memory, opts) do
          stamp_graduated(memory)
          {:ok, :duplicate, existing}
        else
          {:error, :already_graduated}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        # A STRUCTURAL (validation) failure is DETERMINISTIC — the same attrs fail
        # identically on every retry. For the AUTOMATED sweep (`stamp_structural_error`
        # defaults true) we stamp terminally: left un-stamped, the sweep would re-select
        # this (hottest-first, `graduated_at IS NULL`) memory every hour and re-spend the
        # novelty-gate embedding budget on a candidate that can NEVER succeed (a per-slot
        # livelock). For an EXPLICIT caller (`stamp_structural_error: false`, set by
        # `graduate_memory/3`) we do NOT stamp: terminally consuming the memory's one-shot
        # graduation on a 422 with no article and no recovery is wrong HTTP semantics —
        # memory text can legitimately exceed the Article body limit, so the caller must be
        # able to trim and retry. `graduated_at` means "graduation was terminally
        # attempted", not "a live article exists".
        if Keyword.get(opts, :stamp_structural_error, true) do
          Logger.warning(
            "Memory.graduate_memory_record structural failure (stamping to avoid livelock): " <>
              "tenant=#{memory.tenant_id} memory=#{memory.id} errors=#{inspect(changeset.errors)}"
          )

          stamp_graduated(memory)
        end

        {:error, changeset}
    end
  end

  @doc "Recall-count at/above which the graduation sweep graduates a memory."
  @spec graduation_recall_threshold() :: pos_integer()
  def graduation_recall_threshold do
    Application.get_env(:loopctl, :memory_graduation_recall_threshold, 3)
  end

  @doc "Per-run cap on memories graduated by one sweep tick (execution budget)."
  @spec graduation_max_per_run() :: pos_integer()
  def graduation_max_per_run do
    Application.get_env(:loopctl, :memory_graduation_max_per_run, 50)
  end

  @doc """
  Max distinct TENANTS a graduation sweep tick considers (a tenant cap, NOT a row cap).

  The sweep only ever needs `graduation_max_per_run/0` tenants (round-robin serves at
  least one memory per tenant, so no more than the per-run budget of tenants can
  contribute in one tick), and it pulls only ~`ceil(max_per_run / n_tenants)` rows per
  tenant, so the WORST-CASE candidate rows fetched per tick is bounded at roughly
  `2 * max_per_run` — NOT `scan_limit * max_per_run`. This knob only bounds how wide the
  DISTINCT-tenant scan may fan out before the random per-tick sample.
  """
  @spec graduation_scan_limit() :: pos_integer()
  def graduation_scan_limit do
    Application.get_env(:loopctl, :memory_graduation_scan_limit, 500)
  end

  @doc """
  Minimum cosine similarity a recalled memory must clear for its hotness bump to count.

  `recall/2` returns the top-k by distance regardless of absolute relevance, so without a
  floor a sparse subject scope (fewer than k live memories) would have ALL of its
  memories bumped on every query — auto-graduating low-relevance noise. Only a recall
  whose similarity (`max(0.0, 1.0 - distance)`) is at or above this floor bumps
  `recall_count`, keeping the "frequently-recalled = proven-valuable" premise honest for
  small scopes.
  """
  @spec recall_bump_min_score() :: float()
  def recall_bump_min_score do
    Application.get_env(:loopctl, :memory_recall_bump_min_score, 0.6)
  end

  @doc """
  Cooldown window (seconds) that dedups recall-count bumps per memory.

  A memory's `recall_count` is bumped at most once per this window (see
  `bump_recall_counts/2`), so a single agent replaying the same query in a tight loop
  cannot inflate the "frequently-recalled" hotness signal and force premature graduation.
  """
  @spec recall_bump_cooldown_seconds() :: pos_integer()
  def recall_bump_cooldown_seconds do
    Application.get_env(:loopctl, :memory_recall_bump_cooldown_seconds, 3600)
  end

  # A caller may only graduate a memory it OWNS: scoped by (tenant_id, subject_id) on
  # the BYPASSRLS AdminRepo (the explicit-predicate isolation this context uses).
  defp fetch_owned_memory(%Scope{} = scope, memory_id) do
    AdminRepo.one(
      from(m in MemorySchema,
        where:
          m.id == ^memory_id and m.tenant_id == ^scope.tenant_id and
            m.subject_id == ^scope.subject_id
      )
    )
  end

  defp graduation_project_id(%MemorySchema{} = memory, opts) do
    case Keyword.get(opts, :re_scope) do
      :global -> nil
      _ -> memory.project_id
    end
  end

  defp memory_to_article_attrs(%MemorySchema{} = memory, project_id) do
    %{
      title: graduation_title(memory),
      body: memory.text,
      category: :finding,
      # PUBLISHED, not draft: knowledge_search/knowledge_context return PUBLISHED articles
      # only, so a draft graduation would be invisible and the wiki would never grow.
      # create_article/3 TRUSTS attrs[:status] and the Article moduledoc requires a
      # non-controller caller to sanitize it server-side — this IS that sanitization. The
      # novelty gate may still downgrade to :draft on a :low_novelty verdict (the
      # human-review queue), which is the ONE intended unpublished outcome.
      status: :published,
      # Memory tags are unvalidated at the memory tier, but the Article changeset enforces
      # count (<=50), length (<=100), and format. Copying arbitrary client-set tags verbatim
      # would make a structurally-impossible candidate fail the changeset on EVERY sweep — a
      # per-slot livelock that re-spends embedding budget hourly. Sanitize to Article's
      # limits so graduation can never be poisoned by a hostile/oversized tag set.
      tags: sanitize_graduation_tags(memory.tags),
      project_id: project_id,
      # Stable per-memory, PER-SCOPE key: re-graduation to the SAME scope (a race, a
      # retry, or a second sweep before graduated_at commits) is an idempotent no-op
      # dedup rather than a partial dup. The scope MUST be encoded: a `re_scope: :global`
      # graduation of an already project-graduated memory would otherwise collide with
      # the project-scoped article's key and hit the idempotent fast path — silently
      # returning the wrong-scoped article and defeating the re-scope. Distinct scope =
      # distinct key = the global article actually gets created.
      idempotency_key: graduation_idempotency_key(memory.id, project_id),
      metadata: %{
        "source" => "memory_graduation",
        "graduated_from_memory_id" => memory.id,
        "graduated_from_subject_id" => memory.subject_id,
        "recall_count" => memory.recall_count,
        # PRESERVE SUBJECT-level isolation. A Memory is agent-private working memory scoped
        # by (tenant_id, subject_id); graduating it into a tenant-wide SHARED article would
        # expose one agent's private memory to every peer in the tenant (cross-subject
        # leak). Stamp OWNER visibility keyed to the memory's subject so the graduated
        # article stays discoverable by its owner (durable) but is NOT peer-readable —
        # `Knowledge.propose_article/3` is passed the matching `visibility_agent_id` so the
        # idempotency/dedup lookups resolve against the owner-visible row.
        "agent_id" => memory.subject_id,
        "visibility" => "owner",
        "memory_type" => "finding"
      }
    }
  end

  # Article tag constraints (mirror `Loopctl.Knowledge.Article`'s @max_tags/@max_tag_length/
  # @tag_pattern). Memory tags are unbounded/unvalidated, so clamp+filter to what the Article
  # changeset accepts: drop non-binary, empty, over-long, and format-invalid tags, then cap
  # the count. Keeping only ALREADY-VALID tags (rather than mangling) guarantees the article
  # changeset's tag validation cannot fail on a graduated memory.
  @graduation_max_tags 50
  @graduation_max_tag_length 100
  @graduation_tag_pattern ~r/^[a-zA-Z0-9_-]+$/
  defp sanitize_graduation_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(fn tag ->
      is_binary(tag) and byte_size(tag) > 0 and
        String.length(tag) <= @graduation_max_tag_length and
        Regex.match?(@graduation_tag_pattern, tag)
    end)
    |> Enum.take(@graduation_max_tags)
  end

  defp sanitize_graduation_tags(_), do: []

  # Title = the memory's first line, trimmed and byte-bounded, with the FULL memory-id
  # suffix so two DISTINCT memories whose first lines coincide can never collide on the
  # (tenant_id, title) unique index. A truncated (8-char) suffix left a birthday-bounded
  # collision window in which a distinct memory's body was silently dropped (it hit the
  # title index, returned the FIRST memory's article, and got stamped without ever being
  # captured); the full UUID closes that data-loss path. The novelty gate still catches
  # genuine SEMANTIC duplicates — the suffix only prevents a mechanical DB title clash.
  # Bounded to the Article 500-char title limit.
  @graduation_title_max 500
  defp graduation_title(%MemorySchema{text: text, id: id}) do
    suffix = " (memory " <> id <> ")"

    base =
      text
      |> String.split("\n", parts: 2)
      |> List.first()
      |> to_string()
      |> String.trim()

    base = if base == "", do: "Memory", else: base
    String.slice(base, 0, @graduation_title_max - String.length(suffix)) <> suffix
  end

  # Forward audit attribution to propose_article/3, plus the OWNER visibility agent id
  # (= the memory's subject) so the create dedup/idempotency lookups resolve against the
  # owner-visible graduated article (matches metadata.visibility = "owner").
  #
  #   * `on_gate_unavailable: :skip` — for AUTOMATED graduation the gate must NOT fall
  #     open and inject an un-deduplicated published article during an embedding outage;
  #     it returns `{:error, :gate_unavailable}` so the memory re-graduates later.
  #   * `:embedding` — reuse the memory's already-computed vector (when populated) so the
  #     gate does not re-embed identical text; omitted (→ gate embeds) when NULL.
  # `:metadata` carries the AuditContext impersonation trail (impersonated_by /
  # impersonated_at / effective_role) for a superadmin-impersonated graduation; forward it
  # so the graduated article's audit entry records WHO impersonated, not just the SA key
  # id — a silent gap in a custody-relevant write path otherwise.
  defp propose_opts(%MemorySchema{subject_id: subject_id} = memory, opts) do
    [visibility_agent_id: subject_id, on_gate_unavailable: :skip]
    |> maybe_put_embedding(memory)
    |> Keyword.merge(Keyword.take(opts, [:actor_id, :actor_label, :actor_type, :metadata]))
  end

  defp maybe_put_embedding(propose_opts, %MemorySchema{} = memory) do
    case fetch_memory_embedding(memory) do
      nil -> propose_opts
      embedding -> Keyword.put(propose_opts, :embedding, embedding)
    end
  end

  # The memory's `embedding` column is `load_in_query: false`, so it is NOT present on the
  # struct the sweep/fetch loaded — an EXPLICIT `select` overrides that and returns just
  # the vector (a cheap local read that saves an embedding API round-trip). NULL until
  # `MemoryEmbeddingWorker` has embedded the memory.
  defp fetch_memory_embedding(%MemorySchema{id: id, tenant_id: tenant_id}) do
    from(m in MemorySchema,
      where: m.id == ^id and m.tenant_id == ^tenant_id,
      select: m.embedding
    )
    |> AdminRepo.one()
    |> case do
      %Pgvector{} = vector -> Pgvector.to_list(vector)
      list when is_list(list) and list != [] -> list
      _ -> nil
    end
  end

  # Per-memory, PER-SCOPE idempotency key (see `memory_to_article_attrs/2`): global vs
  # project graduation MUST yield distinct keys so a `re_scope: :global` graduation of an
  # already project-graduated memory creates the global article instead of colliding with
  # (and returning) the project-scoped one.
  defp graduation_idempotency_key(memory_id, nil), do: "memory-graduation-#{memory_id}-global"

  defp graduation_idempotency_key(memory_id, project_id),
    do: "memory-graduation-#{memory_id}-project:#{project_id}"

  # Idempotent, conditional stamp: mark the memory graduated ONLY if still NULL, so a
  # concurrent stamp (two sweep ticks, or explicit + sweep) is a harmless no-op and the
  # memory is graduated at most once.
  defp stamp_graduated(%MemorySchema{id: id, tenant_id: tenant_id}) do
    now = DateTime.utc_now()

    from(m in MemorySchema,
      where: m.id == ^id and m.tenant_id == ^tenant_id and is_nil(m.graduated_at)
    )
    |> AdminRepo.update_all(set: [graduated_at: now, updated_at: now])

    :ok
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

  A present `scope.project_id` is tenant-ownership-validated FIRST (same
  `validate_project_scope/1` gate as `remember/2`) so this BYPASSRLS write can never
  point a promoted row at another tenant's project; a foreign/nonexistent id short-
  circuits the run with `{:error, :project_not_found}` (TERMINAL for the worker — a
  bad `project_id` is not fixed by retrying). `nil` (today's only caller value) skips
  the check.

  Returns `{:ok, summary}` on full success, `{:error, :embeddings_degraded}`,
  `{:error, :heavy_read_overloaded}` (the per-tenant HeavyRead gate shed the near-dup
  recall — a loss-free snooze for the worker, treated like `:embeddings_degraded`),
  `{:error, :project_not_found}` (foreign/nonexistent `project_id` — terminal),
  `{:error, :quota_exceeded, summary}`, or `{:error, other}` (a bad write —
  retryable). `summary` is `%{promoted, superseded, deduped}` (promoted = fresh
  inserts; superseded = insert-and-supersede pairs; deduped = exact-dup skips).
  """
  @spec persist_promotion(Scope.t(), [map()]) ::
          {:ok, map()}
          | {:error, :embeddings_degraded}
          | {:error, :heavy_read_overloaded}
          | {:error, :project_not_found}
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
    with :ok <- validate_project_scope(scope) do
      persist_promotion_candidates(scope, candidates)
    end
  end

  # #411 Gap 2 (security): `scope.project_id` reaches this BYPASSRLS durable-write
  # chokepoint straight from the promotion worker's Oban args (`Map.get(args,
  # "project_id")`) and is set on the row via `long_term_changeset/2` → the SAME
  # `AdminRepo` insert `remember/2` uses. The schema's `foreign_key_constraint(:project_id)`
  # runs BYPASSRLS and is explicitly "never the tenant-boundary gate" (schema moduledoc),
  # so this path MUST run the SAME `validate_project_scope/1` ownership check `remember/2`
  # does BEFORE the write — otherwise a future change that threads a `project_id` into
  # promotion (mirroring exactly what Gap 2 did for create) would persist an unvalidated,
  # possibly cross-tenant `project_id` with no compile-time signal, reopening the
  # cross-tenant graph edge / FK existence oracle on a promoted row. Today every caller
  # passes `project_id: nil` (short-circuits to `:ok` with no query), so this is a
  # future-proofing guard with no hot-path cost.
  defp persist_promotion_candidates(%Scope{} = scope, candidates) do
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
    case Knowledge.generate_embedding(
           scope.tenant_id,
           MemorySchema.embedding_input(text),
           egress_opts(scope)
         ) do
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
      nil ->
        {:ok, :skipped}

      row ->
        # US-41.1: still ONE transaction (the caller's) — the legacy column and the
        # side-table row are both written here, so the promoted row can never exist
        # with a vector in only one location.
        dimension = Embeddings.active_dimension(scope.tenant_id)

        with {:ok, updated} <-
               update_legacy_memory_embedding(repo, row, embedding, hash, dimension),
             {:ok, _side} <-
               Embeddings.upsert_memory_embedding_row(
                 repo,
                 scope.tenant_id,
                 row,
                 embedding,
                 hash,
                 dimension
               ) do
          {:ok, updated}
        end
    end
  end

  defp update_legacy_memory_embedding(repo, row, embedding, hash, dimension) do
    if dimension == Embeddings.legacy_dimension() do
      row |> MemorySchema.embedding_changeset(embedding, hash, dimension) |> repo.update()
    else
      {:ok, row}
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
        # US-41.1 AC-41.1.8(i)/AC-41.1.11: dimension resolved ONCE, then the legacy
        # `memories.embedding` column and the dimension-tagged side-table row are
        # written in ONE transaction. For a non-1536 tenant the legacy step is skipped
        # entirely — that column is `vector(1536)` and pgvector hard-errors on any
        # other length, so those tenants are side-table-only.
        dimension = Embeddings.active_dimension(tenant_id)

        Ecto.Multi.new()
        |> Embeddings.memory_embedding_multi(
          tenant_id,
          memory,
          embedding,
          content_hash,
          dimension
        )
        |> Loopctl.AdminRepo.transaction()
        |> case do
          {:ok, %{legacy: updated}} -> {:ok, updated}
          {:ok, _changes} -> {:ok, memory}
          {:error, _step, reason, _done} -> {:error, reason}
        end
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

  # US-41.4 (AC-41.4.2): thread the memory scope's PROJECT into the egress scope so a
  # project-only `local_only` marking blocks the outbound embedding call. Memories
  # frequently have no project, in which case this correctly degrades to the
  # tenant-wide scope.
  defp egress_opts(%Scope{project_id: project_id}), do: [project_id: project_id]

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
