defmodule LoopctlWeb.MemoryController do
  @moduledoc """
  Controller for the Agent Memory HTTP API (US-28.3) — a thin JSON layer over the
  `Loopctl.Memory` context. The MCP layer (US-28.4) calls THIS API, not the context.

  - `POST   /api/v1/memory`         — remember (write a long-term or session memory)
  - `POST   /api/v1/memory/recall`  — semantic recall (query in the request BODY)
  - `POST   /api/v1/memory/promote` — trigger session→long-term promotion (US-29.3)
  - `GET    /api/v1/memory`         — list (limit/offset + total_count meta)
  - `DELETE /api/v1/memory/:id`     — forget

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
  alias LoopctlWeb.MemoryJSON

  action_fallback LoopctlWeb.FallbackController

  # Documentation parity only — agent is the floor role, so this is a no-op. The
  # enforced boundary is (tenant_id, subject_id) + the in-controller superadmin
  # check for all_subjects/any-delete. See @moduledoc.
  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Agent Memory"])

  @memory_attr_keys ~w(tier text session_id role content expires_at confidence source_session_id tags metadata)

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
        "GLOBAL (tenant-wide) memories only, while a present `project_id` returns the " <>
        "merged `global ∪ that-project` set; another project's memories are excluded. " <>
        "A malformed `project_id` is a 422 (`invalid_project_id`). The query is " <>
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

  # Parse the optional `project_id` scope input (#411 Gap 2). `project_id` is a
  # PARTITION key (recall merges `global ∪ active-project`), NOT an isolation
  # boundary — so, unlike tenant_id/subject_id, it MAY come from the body, but it is
  # validated as a UUID here so a malformed value is a deterministic 422 rather than
  # a downstream cast error. Absent/blank (including whitespace-only) → global scope
  # (`nil`) — the value is trimmed before the blank check so `"   "` matches the
  # schema's documented "absent/blank writes a tenant-wide (global) memory" wording
  # rather than falling through to a spurious 422; a valid UUID string → that project;
  # anything else → `:error`. (Tenant-ownership of a well-formed UUID is enforced
  # separately at the context write path — see `Memory.remember/2`.)
  defp parse_project_id(nil), do: {:ok, nil}

  defp parse_project_id(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      trimmed ->
        case Ecto.UUID.cast(trimmed) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> :error
        end
    end
  end

  defp parse_project_id(_), do: :error

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

  # Pass only the recognized memory attributes through to the context. tenant_id and
  # subject_id in the body are always dropped here — they are the isolation boundary
  # and are derived from the key. `project_id` is NOT a memory attribute either: it is
  # now an explicit, UUID-validated scope input on create/recall (#411 Gap 2), threaded
  # via the `%Scope{}` (see `parse_project_id/1` + `with_scope/3`), never cast from
  # `attrs`. `tier` is read by `Memory.remember/2`.
  defp memory_attrs(params), do: Map.take(params, @memory_attr_keys)

  defp all_subjects?(params), do: params["all_subjects"] in [true, "true"]
end
