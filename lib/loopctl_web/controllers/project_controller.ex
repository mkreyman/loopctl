defmodule LoopctlWeb.ProjectController do
  @moduledoc """
  Controller for project CRUD operations and progress summary.

  - `POST /api/v1/projects` -- orchestrator+, creates a project
  - `GET /api/v1/projects` -- agent+, lists projects with pagination
  - `GET /api/v1/projects/:id` -- agent+, project detail
  - `PATCH /api/v1/projects/:id` -- orchestrator+, updates a project
  - `DELETE /api/v1/projects/:id` -- user role, archives a project
  - `GET /api/v1/projects/:id/progress` -- agent+, progress summary
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Projects
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:create, :update]
  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:delete]

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent]
       when action in [
              :index,
              :show,
              :progress,
              :resolve,
              :create_kb_scope,
              :archive_kb_scope,
              :restore_kb_scope
            ]

  # US-26.7.1 — work-breakdown surface requires a human-anchored tenant.
  # NOTE: :create_kb_scope is deliberately NOT gated here — a :kb scope carries no
  # chain-of-custody surface (RequireWorkProject bars work attachment), so an agent-rooted
  # tenant may create one to partition its own knowledge. Extends owner decision #331.
  #
  # #505 — the 403 names `create_kb_scope` as the agent-native alternative. An
  # agent-rooted tenant hitting this gate almost always wants "a project row for
  # the repo I am on", which a :kb scope gives it without a custody surface; the
  # 403 previously left it with no path forward but a human WebAuthn upgrade.
  plug LoopctlWeb.Plugs.RequireHumanAnchor,
       [
         alternative: %{
           tool: "create_kb_scope",
           endpoint: "POST /api/v1/kb-scopes",
           description:
             "Creates a kind: kb project scope for this repo at agent role, with no " <>
               "human anchor required. It partitions knowledge articles by repo but " <>
               "cannot host epics/stories/dispatch — the work-breakdown surface stays " <>
               "human-anchored by design."
         }
       ]
       when action in [:create, :update, :delete]

  tags(["Projects"])

  operation(:create,
    summary: "Create project",
    description: "Creates a new project. Requires user+ role.",
    request_body: {"Project params", "application/json", Schemas.ProjectCreateRequest},
    responses: %{
      201 => {"Project created", "application/json", Schemas.ProjectResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:create_kb_scope,
    summary: "Create knowledge-only project scope",
    description:
      "Creates a knowledge-only project scope (kind: kb). Available at agent+ role and NOT " <>
        "gated by the human-anchor tier, because a kb scope is structurally barred from the " <>
        "work-breakdown / chain-of-custody surface. Use it to partition knowledge articles " <>
        "by repo on the agent-rooted KB tier.",
    request_body: {"KB scope params", "application/json", Schemas.ProjectCreateRequest},
    responses: %{
      201 => {"KB scope created", "application/json", Schemas.ProjectResponse},
      422 =>
        {"Validation error or project limit reached", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:archive_kb_scope,
    summary: "Archive a knowledge-only project scope",
    description:
      "Archives (soft-deletes, reversible) a kind: kb project scope owned by the tenant. " <>
        "Agent+ role and NOT human-anchor gated (extends #331 / create_kb_scope). Archiving " <>
        "frees the scope's slot in the tenant's max_projects budget so agents can reclaim " <>
        "KB-scope capacity. A kind: work project is rejected (422) — archiving a work project " <>
        "remains human-anchored via DELETE /projects/:id.",
    parameters: [id: [in: :path, type: :string, description: "KB scope (project) UUID"]],
    responses: %{
      200 => {"Archived KB scope", "application/json", Schemas.ProjectResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Not a KB scope", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:restore_kb_scope,
    summary: "Restore (un-archive) a knowledge-only project scope",
    description:
      "Re-activates an archived kind: kb scope owned by the tenant (the reverse of DELETE " <>
        "/kb-scopes/:id). Agent+ role, not human-anchor gated. Re-activating consumes an " <>
        "active max_projects slot, so it is rejected 422 when the tenant is at its cap. A " <>
        "kind: work project is rejected 422.",
    parameters: [id: [in: :path, type: :string, description: "KB scope (project) UUID"]],
    responses: %{
      200 => {"Restored KB scope", "application/json", Schemas.ProjectResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 =>
        {"Not a KB scope, or project limit reached", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List projects",
    description: "Lists projects for the current tenant with pagination.",
    parameters: [
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"],
      status: [in: :query, type: :string, description: "Filter by status (active/archived)"],
      include_archived: [in: :query, type: :boolean, description: "Include archived projects"]
    ],
    responses: %{
      200 =>
        {"Project list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: Schemas.ProjectResponse},
             meta: Schemas.PaginationMeta
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:show,
    summary: "Get project",
    description: "Returns project detail with epic and story counts.",
    parameters: [id: [in: :path, type: :string, description: "Project UUID"]],
    responses: %{
      200 => {"Project detail", "application/json", Schemas.ProjectResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Update project",
    description: "Updates a project. Slug cannot be changed. Requires user+ role.",
    parameters: [id: [in: :path, type: :string, description: "Project UUID"]],
    request_body: {"Update params", "application/json", Schemas.ProjectCreateRequest},
    responses: %{
      200 => {"Updated project", "application/json", Schemas.ProjectResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:delete,
    summary: "Archive project",
    description: "Archives a project (soft delete). Requires user+ role.",
    parameters: [id: [in: :path, type: :string, description: "Project UUID"]],
    responses: %{
      200 => {"Archived project", "application/json", Schemas.ProjectResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:resolve,
    summary: "Resolve project",
    description:
      "Resolves a project from any of slug, repo_url, or name (precedence: slug, repo_url, name). Requires agent+ role.",
    parameters: [
      slug: [in: :query, type: :string, description: "Exact project slug"],
      repo_url: [
        in: :query,
        type: :string,
        description: "Repository URL (ssh, https, or bare owner/repo)"
      ],
      name: [in: :query, type: :string, description: "Project name (case-insensitive)"]
    ],
    responses: %{
      200 => {"Resolved project", "application/json", Schemas.ProjectResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"No identifier supplied", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:progress,
    summary: "Get project progress",
    description: "Returns progress summary for a project.",
    parameters: [id: [in: :path, type: :string, description: "Project UUID"]],
    responses: %{
      200 =>
        {"Progress summary", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  POST /api/v1/projects

  Creates a new project. Requires user+ role.
  """
  def create(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    attrs = %{
      name: params["name"],
      slug: params["slug"],
      repo_url: params["repo_url"],
      description: params["description"],
      tech_stack: params["tech_stack"],
      mission: params["mission"],
      metadata: params["metadata"] || %{}
    }

    case Projects.create_project(tenant_id, attrs, audit_opts) do
      {:ok, project} ->
        conn
        |> put_status(:created)
        |> json(%{project: project_json(project)})

      {:error, :project_limit_reached} ->
        {:error, :unprocessable_entity, "Project limit reached for this tenant"}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  POST /api/v1/kb-scopes

  Creates a knowledge-only project scope (`kind: :kb`). Available at agent+ role and NOT
  gated by `RequireHumanAnchor`: a `:kb` scope carries no chain-of-custody surface
  (`RequireWorkProject` bars work attachment), so an agent-rooted (KB-tier) tenant may
  create one to partition its knowledge articles by repo. Delete stays user + human-anchored.
  Extends owner decision #331 (the KB content surface is fully agent-usable) to KB scoping.
  """
  def create_kb_scope(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    # No `mission`: a mission cascades into story context, and a :kb scope has no stories.
    attrs = %{
      name: params["name"],
      slug: params["slug"],
      repo_url: params["repo_url"],
      description: params["description"],
      tech_stack: params["tech_stack"],
      metadata: params["metadata"] || %{}
    }

    case Projects.create_project(tenant_id, attrs, Keyword.put(audit_opts, :kind, :kb)) do
      {:ok, project} ->
        conn
        |> put_status(:created)
        |> json(%{project: project_json(project)})

      {:error, :project_limit_reached} ->
        {:error, :unprocessable_entity, "Project limit reached for this tenant"}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  DELETE /api/v1/kb-scopes/:id

  Archives (soft-deletes, reversible) a `kind: :kb` project scope owned by the tenant.
  Agent+ role, NOT human-anchor gated — a KB scope is agent-managed (extends owner decision
  #331 / create_kb_scope, and archive is a reversible, audited soft-delete, the class of KB
  op #331 keeps agent-usable). Archiving frees the scope's slot in the tenant's max_projects
  active budget, so an agent can reclaim KB-scope capacity it created. A `kind: :work` project
  is rejected with 422 — archiving a work project stays human-anchored via DELETE /projects/:id.
  A missing or cross-tenant id is a clean 404 (get_project is tenant-scoped). Reverse it with
  POST /kb-scopes/:id/restore (also agent role), so the KB-scope lifecycle is fully
  agent-managed. Idempotent: archiving an already-archived scope is a no-op with no new audit
  row.
  """
  def archive_kb_scope(conn, %{"id" => project_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    with {:ok, project} <- Projects.get_project(tenant_id, project_id),
         :ok <- ensure_kb_scope(project),
         {:ok, archived} <- Projects.archive_project(tenant_id, project, audit_opts) do
      json(conn, %{project: project_json(archived)})
    end
  end

  @doc """
  POST /api/v1/kb-scopes/:id/restore

  Re-activates an archived `kind: :kb` scope owned by the tenant — the reverse of
  DELETE /kb-scopes/:id, so the KB-scope lifecycle is fully agent-managed. Agent+ role, NOT
  human-anchor gated. Re-activating consumes an active max_projects slot, so it is rejected
  422 (project limit reached) when the tenant is at its cap. A `kind: :work` project is
  rejected 422; a missing or cross-tenant id is a clean 404.
  """
  def restore_kb_scope(conn, %{"id" => project_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    with {:ok, project} <- Projects.get_project(tenant_id, project_id),
         :ok <- ensure_kb_scope(project),
         {:ok, activated} <- restore_result(tenant_id, project, audit_opts) do
      json(conn, %{project: project_json(activated)})
    end
  end

  defp restore_result(tenant_id, project, opts) do
    case Projects.unarchive_project(tenant_id, project, opts) do
      {:ok, activated} ->
        {:ok, activated}

      {:error, :project_limit_reached} ->
        {:error, :unprocessable_entity, "Project limit reached for this tenant"}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # Only a knowledge-only scope may be archived/restored at agent role. A work project falls
  # through to this 422 so it can never be archived or restored without the human-anchored
  # DELETE/PATCH /projects/:id path.
  defp ensure_kb_scope(%{kind: :kb}), do: :ok

  defp ensure_kb_scope(_project),
    do:
      {:error, :unprocessable_entity,
       "Only a knowledge-only project scope (kind: kb) can be managed (archive/restore) at " <>
         "agent role; a work project requires a human-anchored tenant."}

  @doc """
  GET /api/v1/projects

  Lists projects for the current tenant. Requires agent+ role.
  Supports pagination via ?page=N&page_size=M.
  """
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> maybe_add_opt(:status, safe_to_status(params["status"]))
      |> maybe_add_opt(:include_archived, parse_bool(params["include_archived"]))
      |> maybe_add_opt(:page, parse_int(params["page"]))
      |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

    {:ok, result} = Projects.list_projects(tenant_id, opts)

    json(conn, %{
      data: Enum.map(result.data, &project_json/1),
      meta: %{
        page: result.page,
        page_size: result.page_size,
        total_count: result.total,
        total_pages: ceil_div(result.total, result.page_size)
      }
    })
  end

  @doc """
  GET /api/v1/projects/:id

  Returns project detail. Requires agent+ role.
  Returns epic_count and story_count aggregates (zeroed until Epic 6).
  """
  def show(conn, %{"id" => project_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Projects.get_project(tenant_id, project_id) do
      {:ok, project} ->
        epic_count = Projects.count_epics(tenant_id, project_id)
        story_count = Projects.count_stories(tenant_id, project_id)

        json(conn, %{
          project:
            project_json(project)
            |> Map.merge(%{epic_count: epic_count, story_count: story_count})
        })

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  PATCH /api/v1/projects/:id

  Updates a project. Requires user+ role. Slug cannot be changed.
  """
  def update(conn, %{"id" => project_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    with {:ok, project} <- Projects.get_project(tenant_id, project_id) do
      attrs = %{
        name: params["name"],
        repo_url: params["repo_url"],
        description: params["description"],
        tech_stack: params["tech_stack"],
        status: safe_to_status(params["status"]),
        mission: params["mission"],
        metadata: params["metadata"]
      }

      # Remove nil values so we only update provided fields. Mission can
      # still be cleared by sending an empty string, which the changeset
      # normalizes back to nil.
      attrs = Map.reject(attrs, fn {_k, v} -> is_nil(v) end)

      case Projects.update_project(tenant_id, project, attrs, audit_opts) do
        {:ok, updated} ->
          json(conn, %{project: project_json(updated)})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  DELETE /api/v1/projects/:id

  Archives a project (soft delete). Requires user+ role.
  """
  def delete(conn, %{"id" => project_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    with {:ok, project} <- Projects.get_project(tenant_id, project_id) do
      case Projects.archive_project(tenant_id, project, audit_opts) do
        {:ok, archived} ->
          json(conn, %{project: project_json(archived)})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  # Defense-in-depth cap on the length of each resolve identifier. HTTP
  # request-line limits and the small per-tenant project count already bound the
  # real cost, but this rejects a pathologically long value before it reaches the
  # regex passes in repo_ref/1 and the leading-wildcard ILIKE scan.
  @max_identifier_length 512

  @doc """
  GET /api/v1/projects/resolve

  Resolves a project from any of slug, repo_url, or name. Requires agent+ role.
  Returns 200 with the project (and `matched_by`, the identifier that produced
  the hit) on a match, 404 when nothing matches, 409 when a fuzzy identifier
  matches more than one active project (ambiguous), and 422 when no identifier
  was supplied or an identifier exceeds the length cap.
  """
  def resolve(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts = [
      slug: params["slug"],
      repo_url: params["repo_url"],
      name: params["name"]
    ]

    with :ok <- validate_identifier_lengths(opts),
         {:ok, project, matched_by} <- resolve_result(tenant_id, opts) do
      json(conn, %{project: project_json(project), matched_by: matched_by})
    end
  end

  defp validate_identifier_lengths(opts) do
    if Enum.any?(opts, fn {_key, value} ->
         is_binary(value) and byte_size(value) > @max_identifier_length
       end) do
      {:error, :unprocessable_entity,
       "Identifier values must be at most #{@max_identifier_length} characters"}
    else
      :ok
    end
  end

  # Map the resolver's outcomes onto FallbackController clauses so this endpoint
  # emits the standard error envelope (%{error: %{status, message}}) like every
  # other action. :not_found flows straight through to the 404 clause; the
  # {:ok, project, matched_by} success passes through unchanged.
  defp resolve_result(tenant_id, opts) do
    case Projects.resolve_project(tenant_id, opts) do
      {:ok, project, matched_by} ->
        {:ok, project, matched_by}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :ambiguous} ->
        {:error, :ambiguous_resolution}

      {:error, :no_identifier} ->
        {:error, :unprocessable_entity, "Provide slug, repo_url, or name"}
    end
  end

  @doc """
  GET /api/v1/projects/:id/progress

  Returns progress summary for a project. Requires agent+ role.
  """
  def progress(conn, %{"id" => project_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Projects.get_project_progress(tenant_id, project_id) do
      {:ok, progress} ->
        json(conn, %{progress: progress})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Private helpers ---

  defp project_json(project) do
    %{
      id: project.id,
      tenant_id: project.tenant_id,
      name: project.name,
      slug: project.slug,
      repo_url: project.repo_url,
      description: project.description,
      tech_stack: project.tech_stack,
      status: project.status,
      kind: project.kind,
      mission: project.mission,
      metadata: project.metadata,
      inserted_at: project.inserted_at,
      updated_at: project.updated_at
    }
  end

  defp safe_to_status(nil), do: nil

  defp safe_to_status(status) when is_binary(status) do
    case status do
      "active" -> :active
      "archived" -> :archived
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp parse_bool(nil), do: nil
  defp parse_bool("true"), do: true
  defp parse_bool("1"), do: true
  defp parse_bool(_), do: false

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)
end
