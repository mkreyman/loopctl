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
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:index, :show, :progress]

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
        metadata: params["metadata"]
      }

      # Remove nil values so we only update provided fields
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
