defmodule Loopctl.Projects do
  @moduledoc """
  Context module for project management.

  Projects are tenant-scoped codebases tracked by AI agents. All operations
  require a `tenant_id` as the first argument for explicit scoping.

  All mutations (create, update, archive) are atomic operations that include
  audit logging via `Ecto.Multi` in the same transaction.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Projects.Project
  alias Loopctl.Tenants.Tenant

  @doc """
  Creates a new project within a tenant.

  Enforces the tenant's `max_projects` setting (default 50). Creates the
  project record and writes an audit log entry in a single transaction.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with `:name`, `:slug`, and optional fields
  - `opts` -- keyword list with:
    - `:actor_id` -- UUID of the API key performing the action
    - `:actor_label` -- human-readable label (e.g., "user:admin")

  ## Returns

  - `{:ok, %Project{}}` on success
  - `{:error, changeset}` on validation failure
  - `{:error, :project_limit_reached}` when tenant limit exceeded
  """
  @spec create_project(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :project_limit_reached}
  def create_project(tenant_id, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    changeset =
      %Project{tenant_id: tenant_id}
      |> Project.create_changeset(attrs)

    multi =
      Multi.new()
      |> Multi.run(:check_limit, fn _repo, _changes ->
        count = count_projects(tenant_id, status: :active)
        max = get_project_limit(tenant_id)

        if count < max, do: {:ok, count}, else: {:error, :project_limit_reached}
      end)
      |> Multi.insert(:project, changeset)
      |> Audit.log_in_multi(:audit, fn %{project: project} ->
        %{
          tenant_id: tenant_id,
          entity_type: "project",
          entity_id: project.id,
          action: "created",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          new_state: %{
            "name" => project.name,
            "slug" => project.slug,
            "status" => to_string(project.status)
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{project: project}} ->
        {:ok, project}

      {:error, :check_limit, :project_limit_reached, _changes} ->
        {:error, :project_limit_reached}

      {:error, :project, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Gets a project by ID, scoped to a tenant.

  ## Returns

  - `{:ok, %Project{}}` if found
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_project(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Project.t()} | {:error, :not_found}
  def get_project(tenant_id, project_id) do
    case AdminRepo.get_by(Project, id: project_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Gets a project by slug, scoped to a tenant.

  ## Returns

  - `{:ok, %Project{}}` if found
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_project_by_slug(Ecto.UUID.t(), String.t()) ::
          {:ok, Project.t()} | {:error, :not_found}
  def get_project_by_slug(tenant_id, slug) do
    case AdminRepo.get_by(Project, slug: slug, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Updates a project within a tenant.

  Slug cannot be changed after creation.

  ## Parameters

  - `tenant_id` -- the tenant UUID (for audit logging)
  - `project` -- the `%Project{}` struct to update
  - `attrs` -- map of fields to update
  - `opts` -- keyword list with `:actor_id` and `:actor_label`

  ## Returns

  - `{:ok, %Project{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec update_project(Ecto.UUID.t(), Project.t(), map(), keyword()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update_project(tenant_id, %Project{} = project, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    changeset = Project.update_changeset(project, attrs)

    multi =
      Multi.new()
      |> Multi.update(:project, changeset)
      |> Audit.log_in_multi(:audit, fn %{project: updated} ->
        %{
          tenant_id: tenant_id,
          entity_type: "project",
          entity_id: updated.id,
          action: "updated",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{
            "name" => project.name,
            "status" => to_string(project.status)
          },
          new_state: %{
            "name" => updated.name,
            "status" => to_string(updated.status)
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{project: updated}} ->
        {:ok, updated}

      {:error, :project, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Archives a project by setting its status to `:archived`.

  The record is not deleted from the database.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `project` -- the `%Project{}` struct to archive
  - `opts` -- keyword list with `:actor_id` and `:actor_label`

  ## Returns

  - `{:ok, %Project{}}` on success
  - `{:error, changeset}` on failure
  """
  @spec archive_project(Ecto.UUID.t(), Project.t(), keyword()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def archive_project(tenant_id, %Project{} = project, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    changeset = Project.archive_changeset(project)

    multi =
      Multi.new()
      |> Multi.update(:project, changeset)
      |> Audit.log_in_multi(:audit, fn %{project: archived} ->
        %{
          tenant_id: tenant_id,
          entity_type: "project",
          entity_id: archived.id,
          action: "archived",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{"status" => to_string(project.status)},
          new_state: %{"status" => to_string(archived.status)}
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{project: archived}} ->
        {:ok, archived}

      {:error, :project, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Lists projects for a tenant with optional filters and page-based pagination.

  ## Options (keyword list)

  - `:status` -- filter by status (`:active` or `:archived`)
  - `:include_archived` -- when `true`, includes archived projects (default false)
  - `:page` -- page number (default 1)
  - `:page_size` -- projects per page (default 20, max 100)

  ## Returns

  `{:ok, %{data: [%Project{}], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_projects(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [Project.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_projects(tenant_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      Project
      |> where([p], p.tenant_id == ^tenant_id)
      |> apply_filters(opts)

    total = AdminRepo.aggregate(base_query, :count, :id)

    projects =
      base_query
      |> order_by([p], asc: p.name)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: projects, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Returns a progress summary for a project.

  NOTE: Story and Epic schemas don't exist yet (Epic 6). Returns zeroed/empty
  progress data. The queries will be updated when Epic 6 is implemented.

  ## Returns

  - `{:ok, map}` with progress summary fields
  - `{:error, :not_found}` if the project doesn't exist
  """
  @spec get_project_progress(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_project_progress(tenant_id, project_id) do
    case get_project(tenant_id, project_id) do
      {:ok, _project} ->
        # NOTE(Epic 6): Replace with actual aggregate queries when Story and Epic
        # schemas are available. Use SQL GROUP BY / COUNT for efficiency rather than
        # loading all stories into memory.
        progress = %{
          total_stories: 0,
          stories_by_agent_status: %{
            pending: 0,
            contracted: 0,
            assigned: 0,
            implementing: 0,
            reported_done: 0
          },
          stories_by_verified_status: %{
            unverified: 0,
            verified: 0,
            rejected: 0
          },
          total_epics: 0,
          epics_completed: 0,
          verification_percentage: 0.0,
          estimated_hours_total: 0,
          estimated_hours_completed: 0
        }

        {:ok, progress}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Counts projects for a tenant with optional status filtering.

  ## Options (keyword list)

  - `:status` -- filter by status (`:active` or `:archived`). When omitted, counts all projects.

  ## Returns

  A non-negative integer count.
  """
  @spec count_projects(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def count_projects(tenant_id, opts \\ []) do
    query = where(Project, [p], p.tenant_id == ^tenant_id)

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [p], p.status == ^status)
      end

    AdminRepo.aggregate(query, :count, :id)
  end

  # --- Private helpers ---

  defp apply_filters(query, opts) do
    include_archived = Keyword.get(opts, :include_archived, false)
    status = Keyword.get(opts, :status)

    cond do
      status != nil ->
        where(query, [p], p.status == ^status)

      include_archived ->
        query

      true ->
        where(query, [p], p.status == :active)
    end
  end

  defp get_project_limit(tenant_id) do
    tenant = AdminRepo.get!(Tenant, tenant_id)
    Map.get(tenant.settings, "max_projects", 50)
  end
end
