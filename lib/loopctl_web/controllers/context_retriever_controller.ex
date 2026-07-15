defmodule LoopctlWeb.ContextRetrieverController do
  @moduledoc """
  Controller for the Context Retriever HTTP API (Epic 30, US-30.4) — a thin JSON
  layer wiring the already-built domain (US-30.1 Registry/Entity, US-30.2
  ToolGenerator, US-30.3 Executor) to `/api/v1` on the `:authenticated` pipeline.
  The MCP layer (US-30.5) calls THIS API, not the contexts directly.

  ## Endpoints

    * `POST   /api/v1/entities`         — create an entity definition (user+)
    * `GET    /api/v1/entities`         — list the tenant's definitions
    * `GET    /api/v1/entities/:id`     — fetch one definition
    * `PATCH  /api/v1/entities/:id`     — update a definition (user+)
    * `DELETE /api/v1/entities/:id`     — delete a definition (user+)
    * `GET    /api/v1/retrieve/tools`   — the tenant's generated tool specs
    * `POST   /api/v1/retrieve/:entity` — execute a filter/search via the Executor

  ## Scope is derived from the KEY, never the body (AC-30.4.1)

  The `tenant_id` is resolved SERVER-SIDE from the resolved API key
  (`conn.assigns.current_api_key`). Any `tenant_id` in the request body is
  ignored. A tenant-less key (a superadmin without an impersonation target — the
  api_key schema forbids a superadmin `tenant_id`) is refused deterministically
  with a 422 rather than a null-scoped operation, mirroring
  `LoopctlWeb.MemoryController`.

  ## Role gating (AC-30.4.2)

  Defining/mutating a definition requires `>= :user` (403 for agent/orchestrator).
  Querying (`/retrieve/*`, list, show) requires only authentication — `:agent` is
  the FLOOR role, so the `role: :agent` plug is a documentation no-op; the real
  negative case for a query is 401 (unauthenticated, handled by `RequireAuth` in
  the pipeline), never a below-agent 403.

  ## Rate limiting the model-invoked path (AC-30.4.6)

  `POST /retrieve/:entity` is additionally rate-limited PER TENANT via the
  configured `Loopctl.RateLimiter.Hammer` (DI key `:rate_limiter`) so a looping or
  hostile agent cannot flood the executor. Over-limit returns 429 and does NOT
  execute.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.ContextRetriever.Entity
  alias Loopctl.ContextRetriever.Executor
  alias Loopctl.ContextRetriever.Registry
  alias Loopctl.ContextRetriever.Scope
  alias LoopctlWeb.AuditContext
  alias Plug.Conn.Status

  action_fallback LoopctlWeb.FallbackController

  # AC-30.4.2: define/mutate requires >= user; querying is floored at agent (a
  # documentation no-op — every authenticated key clears it; the negative case is
  # a pipeline 401, not a below-agent 403).
  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:create, :update, :delete]

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent] when action in [:index, :show, :tools, :retrieve]

  # An entity definition IS a security root (the executor's field allowlist), so
  # DEFINING/MUTATING one is gated behind the human-anchored tenant tier — exactly
  # like the rest of the work-breakdown surface (project_controller /
  # story_dependency_controller). Querying (`/retrieve/*`, list, show) is NOT
  # tier-gated: an agent-rooted KB-tier tenant may still query its own definitions.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create, :update, :delete]

  tags(["Context Retriever"])

  @entity_attr_keys ~w(name backing_source fields)

  # The default per-tenant window/limit for the model-invoked /retrieve path.
  # Overridable via config; kept generous (a real agent bursts) but finite.
  @retrieve_rate_window_ms 60_000
  @retrieve_rate_limit 120

  # Reserved param keys the US-30.3 Executor reads for search/pagination
  # (`params["query"]` / `params["limit"]` / `params["offset"]`). `exec_params/2`
  # writes a `:filter` field's value into that SAME string-keyed param namespace,
  # so a filterable column literally named one of these would clobber (or be
  # clobbered by) the caller's search/pagination value — silently mis-paginating.
  # No phase-1 backing source allowlists such a column, so the coupling is latent
  # today; the compile-time guard below ASSERTS that, so a future
  # `Entity.@column_allowlist` addition of a `query`/`limit`/`offset` column fails
  # loudly here (mirroring the compile-time guards in `Entity`/`ToolGenerator`)
  # instead of regressing into a silent mis-pagination.
  @reserved_exec_keys ~w(query limit offset)

  for {source, cols} <- Entity.column_allowlist() do
    collisions = Enum.filter(cols, &(Atom.to_string(&1) in @reserved_exec_keys))

    unless collisions == [] do
      raise CompileError,
        description:
          "LoopctlWeb.ContextRetrieverController: backing source #{inspect(source)} allowlists " <>
            "column(s) #{inspect(collisions)} that collide with the reserved Executor param " <>
            "keys #{inspect(@reserved_exec_keys)}. `exec_params/2` shares one param namespace " <>
            "with the executor's search/pagination reads, so such a column would silently " <>
            "mis-paginate. Namespace the filter value into a dedicated slot before adding it."
    end
  end

  operation(:create,
    summary: "Create an entity definition",
    description:
      "Creates a tenant-scoped entity definition (name + typed, allowlisted fields " <>
        "+ a backing source). Requires >= user role. `tenant_id` is derived from the " <>
        "key. Returns 201 with the created definition.",
    request_body: {"Entity params", "application/json", Schemas.EntityDefinitionRequest},
    responses: %{
      201 => {"Created", "application/json", Schemas.EntityDefinitionResponse},
      422 =>
        {"Validation error or entity limit reached", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List entity definitions",
    description: "Lists the calling tenant's entity definitions, ordered by name.",
    responses: %{
      200 => {"Definitions", "application/json", Schemas.EntityDefinitionListResponse}
    }
  )

  operation(:show,
    summary: "Fetch an entity definition",
    description: "Fetches one of the calling tenant's entity definitions by id.",
    parameters: [id: [in: :path, type: :string, description: "Entity definition UUID"]],
    responses: %{
      200 => {"Definition", "application/json", Schemas.EntityDefinitionResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:update,
    summary: "Update an entity definition",
    description:
      "Updates a definition by id, re-validating against the SERVER column " <>
        "allowlist (a PATCH can never relax it). Requires >= user role. Omitted " <>
        "top-level fields keep their current value.",
    parameters: [id: [in: :path, type: :string, description: "Entity definition UUID"]],
    request_body: {"Entity params", "application/json", Schemas.EntityDefinitionRequest},
    responses: %{
      200 => {"Updated", "application/json", Schemas.EntityDefinitionResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:delete,
    summary: "Delete an entity definition",
    description: "Deletes a definition by id. Requires >= user role.",
    parameters: [id: [in: :path, type: :string, description: "Entity definition UUID"]],
    responses: %{
      200 => {"Deleted", "application/json", Schemas.EntityDefinitionResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:tools,
    summary: "List generated tool specs",
    description:
      "Returns the generated agent tool specs (ToolGenerator over the tenant's " <>
        "entity definitions) for the CALLING tenant only. Another tenant's entities " <>
        "never appear.",
    responses: %{
      200 => {"Tool specs", "application/json", Schemas.RetrieveToolsResponse}
    }
  )

  operation(:retrieve,
    summary: "Execute a filter/search over an entity",
    description:
      "Executes a `filter` or `search` over the named entity via the US-30.3 " <>
        "Executor, which re-validates the field/operation against the tenant's " <>
        "definition + the SERVER allowlist and dual tenant-scopes the query. " <>
        "Rate-limited per tenant (429 over-limit, not executed). An unknown entity " <>
        "or non-allowlisted field is 4xx and never executed.",
    parameters: [entity: [in: :path, type: :string, description: "Entity name"]],
    request_body: {"Retrieve params", "application/json", Schemas.RetrieveRequest},
    responses: %{
      200 => {"Results + meta", "application/json", Schemas.RetrieveResponse},
      400 => {"Malformed request", "application/json", Schemas.ErrorResponse},
      404 => {"Unknown entity", "application/json", Schemas.ErrorResponse},
      422 =>
        {"Field not allowlisted / invalid operation", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  # --- Entity definition CRUD ---

  @doc "POST /api/v1/entities"
  def create(conn, params) do
    with_tenant(conn, fn tenant_id ->
      audit_opts = AuditContext.from_conn(conn)

      case Registry.create_entity(tenant_id, entity_attrs(params), audit_opts) do
        {:ok, entity} ->
          conn |> put_status(:created) |> json(%{data: entity_json(entity)})

        {:error, :entity_limit} ->
          entity_limit_error(conn)

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}

        {:error, reason} ->
          registry_error(conn, reason)
      end
    end)
  end

  @doc "GET /api/v1/entities"
  def index(conn, _params) do
    with_tenant(conn, fn tenant_id ->
      entities = Registry.for_tenant(tenant_id)
      json(conn, %{data: Enum.map(entities, &entity_json/1)})
    end)
  end

  @doc "GET /api/v1/entities/:id"
  def show(conn, %{"id" => id}) do
    with_tenant(conn, fn tenant_id ->
      case Registry.get_entity_by_id(tenant_id, id) do
        nil -> {:error, :not_found}
        entity -> json(conn, %{data: entity_json(entity)})
      end
    end)
  end

  @doc "PATCH /api/v1/entities/:id"
  def update(conn, %{"id" => id} = params) do
    with_tenant(conn, fn tenant_id ->
      audit_opts = AuditContext.from_conn(conn)

      case Registry.update_entity(tenant_id, id, entity_attrs(params), audit_opts) do
        {:ok, entity} -> json(conn, %{data: entity_json(entity)})
        {:error, :not_found} -> {:error, :not_found}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        {:error, reason} -> registry_error(conn, reason)
      end
    end)
  end

  @doc "DELETE /api/v1/entities/:id"
  def delete(conn, %{"id" => id}) do
    with_tenant(conn, fn tenant_id ->
      audit_opts = AuditContext.from_conn(conn)

      case Registry.delete_entity(tenant_id, id, audit_opts) do
        {:ok, entity} -> json(conn, %{data: entity_json(entity)})
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> registry_error(conn, reason)
      end
    end)
  end

  # --- Generated tools ---

  @doc "GET /api/v1/retrieve/tools"
  def tools(conn, _params) do
    with_tenant(conn, fn tenant_id ->
      # Per-tenant tool-spec fan-out lives in the context (Registry.tool_specs/1),
      # not inline here — keeps this a thin JSON layer and gives US-30.5's MCP
      # client one canonical entry point (see the moduledoc).
      json(conn, %{data: Registry.tool_specs(tenant_id)})
    end)
  end

  # --- Execute ---

  @doc "POST /api/v1/retrieve/:entity"
  def retrieve(conn, %{"entity" => entity_name} = params) do
    with_tenant(conn, fn tenant_id ->
      # AC-30.4.6: per-tenant rate limit BEFORE dispatching to the executor, so a
      # looping/hostile agent cannot flood it. Over-limit returns 429, unexecuted.
      case check_retrieve_rate(tenant_id) do
        :ok -> run_retrieve(conn, entity_name, params)
        {:error, :rate_limited} -> {:error, :rate_limited}
      end
    end)
  end

  defp run_retrieve(conn, entity_name, params) do
    # Map the request into the executor's dispatch tuple + params. `op`/`operation`
    # is pattern-matched to an atom (never String.to_atom on model input).
    case operation_atom(params["op"] || params["operation"]) do
      {:ok, operation} ->
        field = string_or_nil(params["field"])
        scope = build_scope(conn)
        exec_params = exec_params(params, field)

        case Executor.run(scope, {entity_name, field, operation}, exec_params) do
          {:ok, %{results: results, meta: meta}} ->
            json(conn, %{results: results, meta: meta})

          {:error, reason} ->
            executor_error(conn, reason)
        end

      :error ->
        invalid_operation(conn)
    end
  end

  # --- Private helpers ---

  # Resolve the tenant_id from the KEY (never the body) and run `fun` with it. A
  # tenant-less key (a superadmin without an impersonation target) is refused with
  # a deterministic 422 rather than a null-scoped op — the Registry functions are
  # guarded `when is_binary(tenant_id)` and the Executor returns `{:error,
  # :no_tenant}`, so refuse here consistently (mirrors MemoryController).
  defp with_tenant(conn, fun) do
    case conn.assigns.current_api_key.tenant_id do
      tenant_id when is_binary(tenant_id) -> fun.(tenant_id)
      _ -> impersonation_tenant_required(conn)
    end
  end

  # Build the Executor scope from the authenticated key: tenant_id + role from the
  # key, actor_id = key id, actor_label = "<role>:<name>" (the audit actor).
  defp build_scope(conn) do
    api_key = conn.assigns.current_api_key

    %Scope{
      tenant_id: api_key.tenant_id,
      role: api_key.role,
      actor_id: api_key.id,
      actor_label: "#{api_key.role}:#{api_key.name}"
    }
  end

  # Build the executor param map: for :filter the executor reads `params[field]`,
  # so map the body's `value` (fallback: a value already under the field key) to
  # that key. `query`/`limit`/`offset` pass through. Any body `tenant_id` is
  # dropped (the executor ignores it regardless).
  defp exec_params(params, field) do
    base = %{
      "query" => params["query"],
      "limit" => params["limit"],
      "offset" => params["offset"]
    }

    if is_binary(field) do
      filter_value =
        if Map.has_key?(params, "value"), do: params["value"], else: params[field]

      Map.put(base, field, filter_value)
    else
      base
    end
  end

  # Map the operation string to its atom WITHOUT String.to_atom on model input.
  defp operation_atom("filter"), do: {:ok, :filter}
  defp operation_atom("search"), do: {:ok, :search}
  defp operation_atom(_), do: :error

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil

  defp entity_attrs(params), do: Map.take(params, @entity_attr_keys)

  # Serialize an entity definition for the JSON envelope (declared surface only).
  defp entity_json(entity) do
    %{
      id: entity.id,
      tenant_id: entity.tenant_id,
      name: entity.name,
      backing_source: entity.backing_source,
      fields: entity.fields,
      inserted_at: entity.inserted_at,
      updated_at: entity.updated_at
    }
  end

  defp check_retrieve_rate(tenant_id) do
    bucket = "cr_retrieve:tenant:#{tenant_id}"

    case Loopctl.RateLimiter.impl().check_rate(
           bucket,
           retrieve_rate_window_ms(),
           retrieve_rate_limit()
         ) do
      {:allow, _count} -> :ok
      {:deny, _limit} -> {:error, :rate_limited}
    end
  end

  defp retrieve_rate_window_ms do
    Application.get_env(
      :loopctl,
      :context_retriever_retrieve_rate_window_ms,
      @retrieve_rate_window_ms
    )
  end

  defp retrieve_rate_limit do
    Application.get_env(:loopctl, :context_retriever_retrieve_rate_limit, @retrieve_rate_limit)
  end

  # --- Error envelopes (executor / registry errors aren't handled by the
  # FallbackController, so render them here with named codes) ---

  # Map Executor `{:error, reason}` to the right status + stable code.
  defp executor_error(conn, :unknown_entity),
    do: error(conn, :not_found, "unknown_entity", "No such entity is defined for this tenant.")

  defp executor_error(conn, :field_not_allowlisted),
    do:
      error(
        conn,
        :unprocessable_entity,
        "field_not_allowlisted",
        "The requested field is not a filterable/searchable field of this entity."
      )

  defp executor_error(conn, :invalid_operation), do: invalid_operation(conn)

  defp executor_error(conn, :search_not_indexed),
    do:
      error(
        conn,
        :unprocessable_entity,
        "search_not_indexed",
        "This entity's searchable fields are not full-text indexed, so search is unavailable."
      )

  defp executor_error(conn, :unsupported_filter_type),
    do:
      error(
        conn,
        :unprocessable_entity,
        "unsupported_filter_type",
        "The requested field's column type does not support equality filtering."
      )

  defp executor_error(conn, :invalid_params),
    do: error(conn, :bad_request, "invalid_params", "The request body is malformed.")

  defp executor_error(conn, :no_tenant), do: impersonation_tenant_required(conn)

  defp executor_error(conn, :stale_entity),
    do:
      error(
        conn,
        :unprocessable_entity,
        "stale_entity",
        "The entity definition no longer matches its backing source; update or recreate it."
      )

  defp executor_error(conn, :audit_failed),
    do:
      error(
        conn,
        :internal_server_error,
        "audit_failed",
        "The query could not be audited, so no results were returned. Please retry."
      )

  # A registry write failing for a non-changeset reason (e.g. an audit-step
  # failure surfaced via the trailing catch-all) is a server-side error.
  defp registry_error(conn, _reason),
    do:
      error(
        conn,
        :internal_server_error,
        "internal_error",
        "The operation could not be completed due to an unexpected server error."
      )

  defp entity_limit_error(conn) do
    error(
      conn,
      :unprocessable_entity,
      "entity_limit",
      "The per-tenant entity-definition limit has been reached. " <>
        "Delete an existing definition before creating a new one."
    )
  end

  defp invalid_operation(conn) do
    error(
      conn,
      :unprocessable_entity,
      "invalid_operation",
      "`op` must be one of \"filter\" or \"search\"."
    )
  end

  defp impersonation_tenant_required(conn) do
    error(
      conn,
      :unprocessable_entity,
      "impersonation_tenant_required",
      "A superadmin Context-Retriever request needs an impersonation target " <>
        "(superadmin keys are tenant-less). Set the X-Impersonate-Tenant header."
    )
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{status: Status.code(status), code: code, message: message}})
  end
end
