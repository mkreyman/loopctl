defmodule LoopctlWeb.MemoryController do
  @moduledoc """
  Controller for the Agent Memory HTTP API (US-28.3) — a thin JSON layer over the
  `Loopctl.Memory` context. The MCP layer (US-28.4) calls THIS API, not the context.

  - `POST   /api/v1/memory`         — remember (write a long-term or session memory)
  - `POST   /api/v1/memory/recall`  — semantic recall (query in the request BODY)
  - `POST   /api/v1/memory/promote` — trigger session→long-term promotion (US-29.3)
  - `GET    /api/v1/memory`         — list (limit/offset + total_count meta)
  - `DELETE /api/v1/memory/:id`     — forget
  - `POST   /api/v1/recall`         — MERGED recall: one round-trip returning the
    re-ranked `global ∪ active-project` union of long-term memory AND knowledge
    (`Loopctl.Memory.recall_context/2`, #411 Gap 2). Reuses the same key-derived
    `(tenant_id, subject_id)` scope + `project_id` partition + 422 envelopes as
    `/memory/recall`.

  ## Scope is derived from the KEY, never the body (AC-28.3.2)

  The `(tenant_id, subject_id)` scope is resolved SERVER-SIDE from the resolved
  API key — `tenant_id` from the key's tenant, `subject_id` via
  `Loopctl.Memory.subject_id_for/1` (agent_id for agent keys, else the api_key id).
  Any `tenant_id`/`subject_id`/`scope` in the request body is IGNORED. If the
  subject cannot be resolved the request is rejected with a deterministic 422
  (`subject_id_unresolvable`) — never a null-scoped write.

  ## Role note (NOT a privilege gate)

  `agent` is the FLOOR role, so the `RequireRole, role: :agent` plug below is a
  no-op present only for documentation parity with sibling controllers —
  'authenticated' is the effective gate. The REAL boundary for own-memory
  operations is `(tenant_id, subject_id)`, not role. The ONE role-sensitive path is
  superadmin oversight (AC-28.3.4): a superadmin key MAY list all subjects'
  memories in its tenant (`?all_subjects=true`) and delete any memory in the
  tenant. A non-superadmin's `all_subjects=true` is ignored (falls back to its own
  subject); a non-superadmin delete is confined to its own subject.

  ## Full :authenticated plug chain applies (AC-28.3.3)

  These routes live on the `:authenticated` pipeline, so a custody-halted key
  cannot write (`CheckCustodyHalt` → 503), a missing/invalid witness header is
  rejected (`ValidateWitnessHeader`), and the write path is subject to the
  `RateLimiter` — consistent with every other authenticated write endpoint.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Memory
  alias Loopctl.Memory.Scope
  alias LoopctlWeb.Helpers.Visibility
  alias LoopctlWeb.MemoryJSON
  alias LoopctlWeb.RecallJSON

  action_fallback LoopctlWeb.FallbackController

  # Documentation parity only — agent is the floor role, so this is a no-op. The
  # enforced boundary is (tenant_id, subject_id) + the in-controller superadmin
  # check for all_subjects/any-delete. See @moduledoc.
  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Agent Memory"])

  @memory_attr_keys ~w(tier text session_id role content expires_at confidence source_session_id tags metadata)

  # The merged-recall query length cap, mirroring the knowledge half's
  # `Loopctl.Knowledge.validate_query_string/1` 500-char limit so `/recall` rejects an
  # over-length query at the boundary (BEFORE the shared embedding call) exactly as the
  # standalone `/knowledge/search` does — never half-degrading to a memory-only 200.
  @max_context_query_length 500

  operation(:create,
    summary: "Remember (write a memory)",
    description:
      "Writes a memory under the caller's own `(tenant_id, subject_id)` scope, " <>
        "derived from the API key — NOT from the body (any tenant_id/subject_id in " <>
        "the body is ignored). `tier` selects the substrate: `long_term` (default; " <>
        "requires `text`, embedded asynchronously and recalled by semantic " <>
        "similarity) or `session` (short-term; requires `session_id` and `content`; " <>
        "`expires_at` is OPTIONAL — the server defaults it to now + the session-memory " <>
        "TTL and floors any supplied value up to the promotion sweep window, so a turn " <>
        "is always promoted before it can be pruned). An optional `project_id` (UUID) " <>
        "partitions the memory to a project; absent/blank writes a tenant-wide (global) " <>
        "memory. `project_id` is a partition key, NOT an isolation boundary, but it is " <>
        "validated for tenant-ownership — a malformed value, or a well-formed UUID that " <>
        "is not a project in the caller's own tenant, is rejected with a 422 " <>
        "(`invalid_project_id`) rather than persisted. Returns 201 with the created " <>
        "memory. Subject to the full " <>
        ":authenticated chain (custody halt, witness header, rate limiting).",
    request_body: {"Memory params", "application/json", Schemas.MemoryCreateRequest},
    responses: %{
      201 => {"Memory created", "application/json", Schemas.MemoryResponse},
      422 =>
        {"Validation error, quota exceeded, invalid project_id, or subject unresolvable",
         "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 => {"Tenant custody halted", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:recall,
    summary: "Recall (semantic search)",
    description:
      "Recalls the caller's own long-term memories most similar to `query` " <>
        "(cosine over an HNSW index), scoped to the key's `(tenant_id, subject_id)`. " <>
        "An optional `project_id` (UUID) partitions the result: absent/blank returns " <>
        "GLOBAL memories only (the rows whose `project_id` is NULL — NOT a union across " <>
        "all your projects), while a present `project_id` returns the " <>
        "merged `global ∪ that-project` set; another project's memories are excluded. " <>
        "A malformed `project_id` is a 422 (`invalid_project_id`). NOTE the deliberate " <>
        "asymmetry with `POST /memory` (create): recall does NOT tenant-validate a " <>
        "well-formed `project_id`, because it is a partition key, not the isolation " <>
        "boundary. A well-formed `project_id` that is a typo, stale, or owned by another " <>
        "tenant is treated as an empty partition and returns your GLOBAL rows only with " <>
        "NO error (never any other tenant's/subject's rows — the `(tenant_id, subject_id)` " <>
        "predicate still bounds every result), whereas create 422s the same value. " <>
        "The query is " <>
        "supplied in the request BODY. When embedding generation is " <>
        "unavailable the response degrades to a recent-first text match with " <>
        "`meta.fallback: true` and a stable `meta.reason` (score is null on that " <>
        "path) — never a silent empty result. No silent hard cap: `limit` is " <>
        "clamped to the vector-search max and `meta.underfilled` flags a short page " <>
        "(a small live scope, or a cross-subject/cross-project pool under-fill).",
    request_body: {"Recall params", "application/json", Schemas.MemoryRecallRequest},
    responses: %{
      200 => {"Recall results", "application/json", Schemas.MemoryRecallResponse},
      422 =>
        {"Subject unresolvable, non-string query, or invalid project_id", "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 => {"Tenant custody halted", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:context,
    summary: "Merged recall (memory ∪ knowledge, one round-trip)",
    description:
      "Returns ONE merged, re-ranked result combining the caller's long-term MEMORY " <>
        "recall AND the KNOWLEDGE combined search for `(query, project_id)` — the " <>
        "`global ∪ active-project` union the harness previously assembled by calling " <>
        "`/memory/recall` and `/knowledge/search` separately (#411 Gap 2). NOTE the " <>
        "knowledge half is the COMBINED SEARCH: article SUMMARIES (id/title/category/" <>
        "tags/score + a truncated snippet), NOT the deep-read `/knowledge/context` " <>
        "(full article bodies + one-hop linked references + recency weighting). Callers " <>
        "needing full bodies or linked refs must still call `/knowledge/context`. Both " <>
        "sides merge global with the active project: an absent/blank `project_id` " <>
        "returns GLOBAL-ONLY memory AND global-only knowledge; a present `project_id` " <>
        "merges global with that project on BOTH sides (another project's rows are " <>
        "excluded). `project_id` is a PARTITION key, NOT the isolation boundary — " <>
        "`(tenant_id, subject_id)` is, and is derived from the API key, never the body. " <>
        "A malformed `project_id` is a 422 (`invalid_project_id`); a non-string, " <>
        "missing, or blank/whitespace-only `query` is a 422 (`invalid_query`); a query " <>
        "longer than 500 characters is a 422 (`query_too_long`) — rejected up front " <>
        "(matching `/knowledge/search`) BEFORE any embedding is generated, never a " <>
        "half-degraded memory-only 200. The " <>
        "response carries the merged `results` (each tagged `source: memory|knowledge`, " <>
        "sorted by a heuristically-comparable `score` DESC — `meta.results_ranking` is " <>
        "`heuristic_cross_source`) PLUS the untouched per-source `memory` and " <>
        "`knowledge` envelopes so callers can re-rank. Cross-source scores are " <>
        "heuristic, not calibrated (memory = absolute cosine similarity; knowledge = " <>
        "pool-normalized keyword+semantic, which biases knowledge UPWARD in the default " <>
        "order). On a DEGRADED knowledge side (keyword-only fallback) memory rows carry " <>
        "absolute cosine scores while knowledge rows carry raw (un-normalized) keyword " <>
        "`relevance_score`, which can outrank memory in the merged `data` — callers who " <>
        "need memory-first ordering under degradation should read the per-source `memory` " <>
        "envelope (it preserves the honest native scores). If the knowledge search " <>
        "errors or degrades to keyword-only, OR the memory heavy-read pool is shed under " <>
        "the per-tenant cap, the OTHER side is still returned and `meta.degraded?` is " <>
        "true (`meta.degraded_reason` names why) — never a 500 and never a whole-endpoint " <>
        "429 from one shed pool. Agent role " <>
        "is forced to published articles and its own/`shared` memories (#163).",
    request_body: {"Recall params", "application/json", Schemas.RecallContextRequest},
    responses: %{
      200 => {"Merged recall results", "application/json", Schemas.RecallContextResponse},
      422 =>
        {"Subject unresolvable, non-string/blank/over-length query, or invalid project_id",
         "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 => {"Tenant custody halted", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:promote,
    summary: "Promote (trigger session→long-term promotion)",
    description:
      "Triggers promotion of the caller's own session `session_id` into durable " <>
        "long-term `:promoted` memories via `Loopctl.Memory.promote_session/1`. " <>
        "Scope (`tenant_id`, `subject_id`) is derived from the API key — a caller " <>
        "may only promote its OWN (tenant, subject) sessions; any tenant/subject in " <>
        "the body is ignored, only `session_id` is read. Returns 202 with the " <>
        "enqueued job reference on success; returns 429 (standard error envelope) " <>
        "when the tenant is over its per-hour promotion budget, WITHOUT enqueuing or " <>
        "calling the LLM. Subject to the full :authenticated write chain (custody " <>
        "halt, witness header, rate limiting).",
    request_body: {"Promote params", "application/json", Schemas.MemoryPromoteRequest},
    responses: %{
      202 => {"Promotion enqueued", "application/json", Schemas.MemoryPromoteResponse},
      422 =>
        {"Missing session_id or subject/tenant unresolvable", "application/json",
         Schemas.ErrorResponse},
      429 => {"Promotion budget exceeded", "application/json", Schemas.PromotionBudgetError},
      500 =>
        {"Promotion could not be enqueued (server error)", "application/json",
         Schemas.ErrorResponse},
      503 => {"Tenant custody halted", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:graduate,
    summary: "Graduate (memory → durable knowledge article)",
    description:
      "Graduates ONE of the caller's own long-term memories (by `memory_id`) into a " <>
        "durable Knowledge Wiki article via the novelty gate — the explicit, on-demand " <>
        "trigger for the same primitive the hourly `MemoryGraduationSweepWorker` runs " <>
        "(#411 Gap 3). Scope (`tenant_id`, `subject_id`) is derived from the API key — a " <>
        "caller may only graduate its OWN memory; a foreign/nonexistent `memory_id` " <>
        "returns 404 (no cross-subject existence oracle). By DEFAULT the article inherits " <>
        "the memory's `project_id` (a project memory → a project article, a global memory " <>
        "→ a global article); pass `re_scope: \"global\"` to promote a PROJECT-scoped " <>
        "memory to a tenant-wide (`project_id: null`) article — the ONLY way graduation " <>
        "re-scopes (the sweep never does). Because a memory has AT MOST ONE graduated " <>
        "article, `re_scope: \"global\"` on an ALREADY-graduated memory returns 409 " <>
        "(`already_graduated`) rather than silently returning the wrong-scoped article; " <>
        "re-scope on the FIRST graduation instead. The article is DEDUPED by the novelty " <>
        "gate: `verdict` is `created` (novel → published) or `gated_to_draft` (near-dup → " <>
        "unpublished draft) with 201, or `duplicate`/`deduplicated` (already represented → " <>
        "the canonical article, nothing created) with 200. A malformed `memory_id` is a " <>
        "422 (`invalid_memory_id`). If the novelty gate falls open because the embedding " <>
        "backend is down it returns 503 (`gate_unavailable`) WITHOUT stamping — retry once " <>
        "embeddings recover. Subject to the full :authenticated write chain (custody halt, " <>
        "witness header, rate limiting).",
    request_body: {"Graduate params", "application/json", Schemas.MemoryGraduateRequest},
    responses: %{
      200 =>
        {"Graduated (dedup: content already represented by an existing article)",
         "application/json", Schemas.MemoryGraduateResponse},
      201 =>
        {"Graduated (a new published article or review draft was created)", "application/json",
         Schemas.MemoryGraduateResponse},
      404 =>
        {"Memory not found in the caller's own scope", "application/json", Schemas.ErrorResponse},
      409 =>
        {"Memory already graduated (re_scope on an already-graduated memory)", "application/json",
         Schemas.ErrorResponse},
      422 =>
        {"Malformed memory_id, invalid structural content, or subject unresolvable",
         "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 =>
        {"Novelty gate unavailable (embedding backend down) — retryable", "application/json",
         Schemas.ErrorResponse}
    }
  )

  operation(:index,
    summary: "List memories",
    description:
      "Lists the caller's own long-term memories, newest first, paginated with " <>
        "`meta.total_count/limit/offset` (total is the true scoped count, never " <>
        "silently capped by `limit`). Optionally filter by provenance with " <>
        "`source=promoted|explicit` (US-29.3). Superadmin oversight: a superadmin " <>
        "key may pass `all_subjects=true` to list EVERY subject's memories within " <>
        "its tenant; the same parameter from a non-superadmin key is ignored " <>
        "(results stay confined to its own subject).",
    parameters: [
      limit: [in: :query, type: :integer, description: "Page size (default 50, max 200)"],
      offset: [in: :query, type: :integer, description: "Records to skip (default 0)"],
      include_superseded: [
        in: :query,
        type: :boolean,
        description: "Include superseded memories (default false)"
      ],
      source: [
        in: :query,
        type: :string,
        description:
          "Filter by provenance — one of `promoted` (session→long-term promotions) " <>
            "or `explicit` (directly written). Any other/omitted value → no filter."
      ],
      all_subjects: [
        in: :query,
        type: :boolean,
        description:
          "Superadmin only: list all subjects' memories in the tenant. Ignored for " <>
            "non-superadmin keys."
      ]
    ],
    responses: %{
      200 => {"Memory list", "application/json", Schemas.MemoryListResponse},
      422 => {"Subject unresolvable", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:delete,
    summary: "Forget (delete a memory)",
    description:
      "Deletes a long-term memory by id within the caller's own subject scope. A " <>
        "foreign-subject, foreign-tenant, or unknown id returns 404 (no existence " <>
        "leak). Superadmin oversight: a superadmin key may delete ANY memory within " <>
        "its tenant.",
    parameters: [id: [in: :path, type: :string, description: "Memory UUID"]],
    responses: %{
      200 => {"Deleted", "application/json", Schemas.MemoryDeleteResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 =>
        {"Superadmin oversight delete without an impersonation target", "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  # --- Actions ---

  @doc "POST /api/v1/memory"
  def create(conn, params) do
    case parse_project_id(params["project_id"]) do
      {:ok, project_id} ->
        create_with_project(conn, params, project_id)

      :error ->
        invalid_project_id(conn)
    end
  end

  defp create_with_project(conn, params, project_id) do
    with_scope(conn, project_id, fn scope ->
      case Memory.remember(scope, memory_attrs(params)) do
        {:ok, memory} ->
          conn |> put_status(:created) |> json(MemoryJSON.show(%{memory: memory}))

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}

        {:error, :quota_exceeded} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{
            error: %{
              status: 422,
              code: "quota_exceeded",
              message:
                "The per-subject long-term memory quota has been reached. " <>
                  "Forget existing memories before writing new ones."
            }
          })

        # A body-supplied `project_id` that is malformed, nonexistent, or belongs to
        # ANOTHER tenant (#411 Gap 2 tenancy fix): `Memory.remember/2` validates
        # tenant-ownership BEFORE the RLS-bypassing insert, so the cross-tenant FK
        # check is never the boundary gate. Both "foreign" and "nonexistent" collapse
        # to the SAME 422 (no cross-tenant existence oracle), reusing the malformed-UUID
        # `invalid_project_id` envelope so the three cases are indistinguishable.
        {:error, :project_not_found} ->
          invalid_project_id(conn)

          # NOTE (review finding, disproven): the four clauses above are EXHAUSTIVE
          # for `Memory.remember/2`. Dialyzer's success typing proves the return is
          # exactly `{:ok, memory} | {:error, :quota_exceeded} | {:error,
          # :project_not_found} | {:error, %Ecto.Changeset{}}` — the
          # `remember_long_term/2` `:embedding_job` Multi step can only fail with an
          # `Ecto.Changeset` (Oban validates the job via a changeset), so no
          # non-changeset error term can reach here. A catch-all would be unreachable
          # dead code (`pattern_match_cov`), and `@dialyzer` suppressions are forbidden.
          # Dialyzer is the compile-time guard: if `remember/2` ever gains a new error
          # shape, this case stops being total and the build breaks — a stronger
          # contract than a runtime catch-all.
      end
    end)
  end

  @doc "POST /api/v1/memory/recall"
  def recall(conn, params) do
    case parse_project_id(params["project_id"]) do
      {:ok, project_id} ->
        recall_with_project(conn, params, project_id)

      :error ->
        invalid_project_id(conn)
    end
  end

  defp recall_with_project(conn, params, project_id) do
    with_scope(conn, project_id, fn scope ->
      case coerce_query(params["query"]) do
        {:ok, query} ->
          opts = [
            query: query,
            limit: params["limit"],
            include_superseded: params["include_superseded"]
          ]

          json(conn, MemoryJSON.recall(Memory.recall(scope, opts)))

        :error ->
          invalid_query(conn)
      end
    end)
  end

  @doc "POST /api/v1/recall"
  def context(conn, params) do
    case parse_project_id(params["project_id"]) do
      {:ok, project_id} ->
        context_with_project(conn, params, project_id)

      :error ->
        invalid_project_id(conn)
    end
  end

  defp context_with_project(conn, params, project_id) do
    with_scope(conn, project_id, fn scope ->
      case coerce_context_query(params["query"]) do
        {:ok, query} ->
          opts =
            [query: query, limit: params["limit"]]
            |> Keyword.merge(knowledge_scope_opts(conn))

          json(conn, RecallJSON.context(Memory.recall_context(scope, opts)))

        {:error, :query_too_long} ->
          query_too_long(conn)

        {:error, :invalid_query} ->
          invalid_query(conn)
      end
    end)
  end

  # Coerce + trim the merged-recall query ONCE at the boundary, treating blank/
  # whitespace-only AND over-length uniformly across both halves. The knowledge half
  # (`search_combined/3` → `validate_query_string/1`) trims, rejects blank with
  # `{:error, :empty_query}`, AND rejects > #{@max_context_query_length}-char queries
  # with `{:error, :bad_request, _}`; the memory half would ILIKE/embed the untrimmed
  # value regardless. So an absent/blank OR an over-length query previously yielded a
  # confusing "memory-only with a spuriously degraded knowledge side" response and a
  # false `degraded?` alert — AND the over-length case additionally spent an outbound
  # embedding provider call on the full (multi-KB) query BEFORE the knowledge cap
  # rejected it. The merged recall REQUIRES a non-blank, ≤ #{@max_context_query_length}-
  # char query (the knowledge half is its point), so both are a clean 422 up front —
  # matching the sibling knowledge search/context endpoints, not the degraded path, and
  # rejecting BEFORE `recall_context/2` generates the shared embedding.
  defp coerce_context_query(query) do
    with {:ok, coerced} <- coerce_query(query),
         trimmed = String.trim(coerced),
         {:blank, false} <- {:blank, trimmed == ""},
         {:too_long, false} <-
           {:too_long, String.length(trimmed) > @max_context_query_length} do
      {:ok, trimmed}
    else
      {:too_long, true} -> {:error, :query_too_long}
      _ -> {:error, :invalid_query}
    end
  end

  # Knowledge-side read scoping for the merged recall, mirroring
  # `KnowledgeContextController`: agent/orchestrator keys are forced to `:published`
  # articles, and the agent-memory visibility scope (#163) hides other agents'
  # private/owner memories. `:api_key_id` is threaded so `search_combined/3` records
  # knowledge read-access analytics for /recall traffic (the sibling search/context
  # endpoints set it too; without it the analytics guard silently records nothing).
  #
  # Higher roles (user/superadmin) pass NO `:status`, but `search_keyword`/
  # `search_semantic` default `:status` to `:published`, so — unlike `/knowledge/context`
  # (which accepts a `?status` override) — this endpoint has NO override and returns
  # published-only knowledge for EVERY role, not "all statuses".
  defp knowledge_scope_opts(conn) do
    role = conn.assigns.current_api_key.role
    role_atom = if is_binary(role), do: String.to_existing_atom(role), else: role

    conn
    |> Visibility.scope_opts()
    |> Keyword.put(:api_key_id, conn.assigns.current_api_key.id)
    |> maybe_force_published(role_atom)
  end

  defp maybe_force_published(opts, role) when role in [:agent, :orchestrator],
    do: Keyword.put(opts, :status, :published)

  defp maybe_force_published(opts, _role), do: opts

  @doc "POST /api/v1/memory/promote"
  def promote(conn, params) do
    with_scope(conn, fn %Scope{} = scope ->
      case Memory.promote_session(%{scope | session_id: params["session_id"]}) do
        {:ok, %Oban.Job{}} ->
          # The enqueue reference is the caller's own `session_id` (the promotion is
          # unique per (tenant, subject, session)), NOT the raw `Oban.Job.id`. That id
          # is a SYSTEM-WIDE monotonic bigserial: returning it to an agent-role key
          # leaks a cross-tenant throughput side-channel (sample the counter over time
          # → estimate aggregate platform job volume). session_id is tenant-scoped, is
          # what the caller already supplied, and is a sufficient work reference
          # (US-29.3 finding fix).
          conn
          |> put_status(:accepted)
          |> json(%{
            data: %{session_id: params["session_id"], status: "enqueued"}
          })

        {:error, :budget_exceeded} ->
          conn
          |> put_status(:too_many_requests)
          |> json(%{
            error: %{
              status: 429,
              code: "promotion_budget_exceeded",
              message:
                "The tenant's per-hour memory-promotion budget has been reached. " <>
                  "The session was not enqueued and no LLM call was made; retry later."
            }
          })

        {:error, :missing_session_id} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{
            error: %{
              status: 422,
              code: "missing_session_id",
              message: "A non-blank `session_id` is required to promote a session."
            }
          })

        # Catch-all for the documented `{:error, term()}` branch of
        # `Memory.promote_session/1`. Its success path ends in `Oban.insert/1`,
        # which returns `{:ok, job}` OR `{:error, %Ecto.Changeset{}}` (and, by
        # spec, `{:error, term()}`). Without this clause an enqueue failure would
        # raise CaseClauseError and escape as an UNSTRUCTURED HTTP 500 that the
        # action_fallback cannot rescue (a raised error never returns a tuple to
        # the action). The caller did nothing wrong (args are server-built and
        # always valid; unique conflicts return `{:ok, existing}`, not an error),
        # so this is a genuine server-side failure → a structured 500 envelope
        # with a named code, NOT a client 4xx. Declared as 500 in
        # `operation(:promote)` so the published contract covers this path.
        {:error, _reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{
            error: %{
              status: 500,
              code: "promotion_enqueue_failed",
              message:
                "The promotion could not be enqueued due to an unexpected server error. " <>
                  "No LLM call was made and no session was promoted. Please retry; if the " <>
                  "problem persists, contact support."
            }
          })
      end
    end)
  end

  @doc "POST /api/v1/memory/graduate"
  def graduate(conn, params) do
    case parse_memory_id(params["memory_id"]) do
      {:ok, memory_id} ->
        graduate_with_id(conn, params, memory_id)

      :error ->
        invalid_memory_id(conn)
    end
  end

  defp graduate_with_id(conn, params, memory_id) do
    with_scope(conn, fn %Scope{} = scope ->
      case Memory.graduate_memory(scope, memory_id, graduate_opts(params)) do
        # `:created` / `:gated_to_draft` materialized a NEW article (a published one, or an
        # unpublished review draft) → 201. `:duplicate` / `:deduplicated` returned the
        # canonical EXISTING article (nothing created) → 200. Mirrors ArticleController's
        # verdict→status convention for the novelty gate.
        {:ok, verdict, article} ->
          conn
          |> put_status(graduate_status(verdict))
          |> json(MemoryJSON.graduate(%{verdict: verdict, article: article}))

        # A foreign/nonexistent memory_id — no cross-subject existence oracle (404 via
        # the FallbackController, same as forget/2).
        {:error, :not_found} = error ->
          error

        # `re_scope: :global` on an already-graduated memory: a memory has at most one
        # graduated article, so this refuses LOUDLY rather than returning the wrong-scoped
        # article as success. A benign, deterministic conflict → 409.
        {:error, :already_graduated} ->
          conn
          |> put_status(:conflict)
          |> json(%{
            error: %{
              status: 409,
              code: "already_graduated",
              message:
                "This memory has already been graduated into a knowledge article, so it " <>
                  "cannot be re-graduated with a different scope. To globalize a memory, " <>
                  "pass re_scope: \"global\" on its FIRST graduation; re-pointing an " <>
                  "already-published article's scope is a separate curation action."
            }
          })

        # The novelty gate FELL OPEN (embedding backend down) — it could not assess
        # novelty, so nothing was created and the memory was NOT stamped. Transient
        # server-side dependency outage → 503 so the caller retries once embeddings
        # recover, rather than a 4xx that reads as a client error.
        {:error, :gate_unavailable} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{
            error: %{
              status: 503,
              code: "gate_unavailable",
              message:
                "The novelty gate is temporarily unavailable (the embedding backend could " <>
                  "not assess this memory), so nothing was graduated. The memory stays " <>
                  "eligible — retry once embeddings recover."
            }
          })

        # A STRUCTURAL validation failure (e.g. an over-size body). Deterministic → 422
        # via the FallbackController's changeset clause.
        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end)
  end

  # `re_scope: "global"` maps to `re_scope: :global` (local→global graduation); absent or
  # `"inherit"` keeps the memory's own scope (the default — no opt passed).
  defp graduate_opts(params) do
    case params["re_scope"] do
      "global" -> [re_scope: :global]
      _ -> []
    end
  end

  defp graduate_status(verdict) when verdict in [:created, :gated_to_draft], do: :created
  defp graduate_status(_verdict), do: :ok

  @doc "GET /api/v1/memory"
  def index(conn, params) do
    api_key = conn.assigns.current_api_key
    superadmin_all = all_subjects?(params) and api_key.role == :superadmin

    cond do
      # A superadmin key is tenant-less (api_key.ex forbids a superadmin tenant_id),
      # so the oversight reader needs an impersonation target to resolve a tenant
      # scope. Without X-Impersonate-Tenant, refuse deterministically rather than
      # letting the nil tenant_id crash `list_all_subjects/2` (guarded
      # `when is_binary(tenant_id)`) with a bare 500.
      superadmin_all and is_nil(api_key.tenant_id) ->
        impersonation_tenant_required(conn)

      superadmin_all ->
        json(
          conn,
          MemoryJSON.index(Memory.list_all_subjects(api_key.tenant_id, list_opts(params)))
        )

      true ->
        with_scope(conn, fn scope ->
          json(conn, MemoryJSON.index(Memory.list(scope, list_opts(params))))
        end)
    end
  end

  @doc "DELETE /api/v1/memory/:id"
  def delete(conn, %{"id" => id}) do
    api_key = conn.assigns.current_api_key
    superadmin? = api_key.role == :superadmin

    cond do
      # Same tenant-less-superadmin guard as `index/2`: `forget_any/2` is guarded
      # `when is_binary(tenant_id)`, so a superadmin delete WITHOUT an impersonation
      # target would crash with a bare 500. Refuse deterministically instead.
      superadmin? and is_nil(api_key.tenant_id) ->
        impersonation_tenant_required(conn)

      superadmin? ->
        render_delete(conn, Memory.forget_any(api_key.tenant_id, id), id)

      true ->
        with_scope(conn, fn scope -> render_delete(conn, Memory.forget(scope, id), id) end)
    end
  end

  # --- Private helpers ---

  # Shared list pagination opts for both the own-subject (`list/2`) and superadmin
  # oversight (`list_all_subjects/2`) readers. Values are coerced/clamped downstream.
  defp list_opts(params) do
    [
      limit: params["limit"],
      offset: params["offset"],
      include_superseded: params["include_superseded"],
      source: params["source"]
    ]
  end

  # Render a forget/forget_any outcome: 200 on delete, else delegate the
  # `{:error, :not_found}` to the FallbackController (404, no existence leak).
  defp render_delete(conn, {:ok, :deleted}, id), do: json(conn, %{data: %{id: id, deleted: true}})
  defp render_delete(_conn, {:error, :not_found} = error, _id), do: error

  # Resolve the `(tenant_id, subject_id)` scope from the API key (NEVER the body)
  # and run `fun` with it. A subject that cannot be resolved is rejected with a
  # deterministic 422 rather than a null-scoped operation (AC-28.3.2).
  #
  # A tenant-less key (a superadmin without X-Impersonate-Tenant — api_key.ex
  # forbids a superadmin tenant_id) has `tenant_id: nil`. `subject_id_for/1` still
  # resolves a subject (the key id), so WITHOUT this guard the own-scope path would
  # build a `%Scope{tenant_id: nil}` and every reachable action would evaluate
  # `m.tenant_id == ^nil`, which Ecto raises at query-BUILD time ("comparing with
  # nil is forbidden") — escaping as a bare HTTP 500. Guard it here, mirroring the
  # index/2 + delete/2 oversight guards, so a tenant-less key gets the deterministic
  # 422 impersonation envelope instead of a null-scoped op (AC-28.3.2 / .5).
  # `project_id` is an OPTIONAL, UUID-validated scope input — a PARTITION key, NOT an
  # isolation boundary. It is threaded onto the `%Scope{}` for create + recall (the
  # only paths where project scoping is meaningful); `index/2` and `delete/2` pass
  # `nil`. Unlike `project_id`, `tenant_id`/`subject_id` are NEVER read from the body —
  # they are the isolation boundary and stay key-derived.
  defp with_scope(conn, project_id \\ nil, fun) do
    api_key = conn.assigns.current_api_key

    if is_nil(api_key.tenant_id) do
      impersonation_tenant_required(conn)
    else
      resolve_scope(conn, api_key, project_id, fun)
    end
  end

  defp resolve_scope(conn, api_key, project_id, fun) do
    case Memory.subject_id_for(api_key) do
      {:ok, subject_id} ->
        fun.(%Scope{tenant_id: api_key.tenant_id, subject_id: subject_id, project_id: project_id})

      {:error, :subject_id_unresolvable} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            status: 422,
            code: "subject_id_unresolvable",
            message:
              "The subject scope for this API key could not be resolved; the memory " <>
                "operation was refused rather than writing/reading a null scope."
          }
        })
    end
  end

  # Deterministic 422 for a tenant-less key (a superadmin without an impersonation
  # target). Every memory operation is tenant-scoped: oversight (all_subjects list /
  # any-subject delete) AND the caller's own-scope create/recall/list/delete all need
  # a resolved tenant_id. Without X-Impersonate-Tenant a superadmin's tenant_id is
  # nil and there is nothing to scope to, so refuse deterministically rather than
  # attempting a null-scoped op.
  defp impersonation_tenant_required(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: "impersonation_tenant_required",
        message:
          "A superadmin memory request needs an impersonation target (superadmin " <>
            "keys are tenant-less). Set the X-Impersonate-Tenant header so the " <>
            "tenant scope can be resolved."
      }
    })
  end

  # Coerce the recall `query` to a binary rather than blindly `to_string/1`-ing it
  # (which raises Protocol.UndefinedError on a map/list body value → HTTP 500). A
  # missing/nil query defaults to ""; a present non-binary value is rejected 422.
  defp coerce_query(nil), do: {:ok, ""}
  defp coerce_query(query) when is_binary(query), do: {:ok, query}
  defp coerce_query(_), do: :error

  defp invalid_query(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: "invalid_query",
        message: "The `query` field must be a string."
      }
    })
  end

  # Reject an over-length merged-recall query with a distinct 422 BEFORE any embedding
  # is generated, matching the knowledge half's 500-char cap. A generic `invalid_query`
  # would mislead ("must be a string"), so this names the length constraint explicitly.
  defp query_too_long(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: "query_too_long",
        message: "The `query` must be at most #{@max_context_query_length} characters."
      }
    })
  end

  # Parse the optional `project_id` scope input (#411 Gap 2). `project_id` is a
  # PARTITION key (recall merges `global ∪ active-project`), NOT an isolation
  # boundary — so, unlike tenant_id/subject_id, it MAY come from the body, but it is
  # validated as a UUID here so a malformed value is a deterministic 422 rather than
  # a downstream cast error. Absent/blank (including whitespace-only) → global scope
  # (`nil`) — the value is trimmed before the blank check so `"   "` matches the
  # schema's documented "absent/blank writes a tenant-wide (global) memory" wording
  # rather than falling through to a spurious 422; a valid UUID string → that project;
  # anything else → `:error`. This gate is FORMAT-only. Tenant-ownership of a
  # well-formed UUID is enforced separately AND ASYMMETRICALLY: the write path
  # (`Memory.remember/2`) validates it and 422s a foreign/nonexistent project; the
  # recall path deliberately does NOT (project_id is a partition key there, so an
  # unowned id reads as an empty partition → global-only, no error). See
  # `Loopctl.Memory.recall/2` for why.
  defp parse_project_id(nil), do: {:ok, nil}

  defp parse_project_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> cast_project_uuid(trimmed)
    end
  end

  defp parse_project_id(_), do: :error

  # Require the CANONICAL 36-char hyphenated form BEFORE `Ecto.UUID.cast`. `cast/1`
  # alone also accepts a raw 16-BYTE binary (e.g. a 16-char ASCII string) and
  # hex-encodes it, so a plainly-non-UUID value would slip through the format gate.
  # Matching the hyphenated shape first makes the boundary a deterministic 422 for
  # such input rather than deferring to a downstream lookup.
  defp cast_project_uuid(trimmed) do
    with true <- canonical_uuid?(trimmed),
         {:ok, uuid} <- Ecto.UUID.cast(trimmed) do
      {:ok, uuid}
    else
      _ -> :error
    end
  end

  @uuid_format ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  defp canonical_uuid?(value), do: Regex.match?(@uuid_format, value)

  defp invalid_project_id(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: "invalid_project_id",
        message:
          "The `project_id` field must be a valid UUID identifying a project in your " <>
            "own tenant."
      }
    })
  end

  # Parse the REQUIRED `memory_id` for graduation. Unlike `project_id` (an optional
  # partition key), `memory_id` identifies the row to graduate — a missing/blank/malformed
  # value is a deterministic 422 up front rather than a downstream cast error. The same
  # canonical-UUID gate as `parse_project_id/1` (hyphenated form BEFORE `Ecto.UUID.cast`,
  # so a raw 16-byte binary cannot slip through). Ownership is enforced separately by
  # `Memory.graduate_memory/3` via the `(tenant_id, subject_id)` scope (a foreign/unknown
  # id → 404, no cross-subject oracle).
  defp parse_memory_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :error
      trimmed -> cast_project_uuid(trimmed)
    end
  end

  defp parse_memory_id(_), do: :error

  defp invalid_memory_id(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        status: 422,
        code: "invalid_memory_id",
        message: "The `memory_id` field is required and must be a valid memory UUID."
      }
    })
  end

  # Pass only the recognized memory attributes through to the context. tenant_id and
  # subject_id in the body are always dropped here — they are the isolation boundary
  # and are derived from the key. `project_id` is NOT a memory attribute either: it is
  # now an explicit, UUID-validated scope input on create/recall (#411 Gap 2), threaded
  # via the `%Scope{}` (see `parse_project_id/1` + `with_scope/3`), never cast from
  # `attrs`. `tier` is read by `Memory.remember/2`.
  defp memory_attrs(params), do: Map.take(params, @memory_attr_keys)

  defp all_subjects?(params), do: params["all_subjects"] in [true, "true"]
end
