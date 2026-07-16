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
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

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
    actor_type = Keyword.get(opts, :actor_type, "api_key")
    metadata = Keyword.get(opts, :metadata, %{})

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
          actor_type: actor_type,
          actor_id: actor_id,
          actor_label: actor_label,
          metadata: metadata,
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
  @spec get_project(Ecto.UUID.t(), term()) ::
          {:ok, Project.t()} | {:error, :not_found}
  def get_project(tenant_id, project_id) do
    # `id: project_id` on a :binary_id column raises Ecto.Query.CastError for a
    # non-UUID value (a malformed path segment reaches here from the many
    # `/projects/:project_id/*` endpoints that scope through this function). Guard
    # the cast so a malformed project_id is a clean :not_found (-> 404), never a
    # 500. This is the shared chokepoint for project-scoped work-breakdown reads.
    if valid_uuid?(project_id) do
      case AdminRepo.get_by(Project, id: project_id, tenant_id: tenant_id) do
        nil -> {:error, :not_found}
        project -> {:ok, project}
      end
    else
      {:error, :not_found}
    end
  end

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_), do: false

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
  Resolves a project within a tenant from one or more identifiers.

  Intended as the single cheap call the harness uses to turn "I'm working in
  repo X" into a loopctl project. Tries identifiers in precedence order and
  returns the first hit:

  1. exact `:slug`
  2. normalized `:repo_url` (see `normalize_repo_url/1` — matches across
     `git@github.com:owner/repo.git`, `https://github.com/owner/repo`, and the
     bare `owner/repo`)
  3. case-insensitive exact `:name`

  When a lower-precedence key (`:repo_url` or `:name`) matches more than one
  project, an `:active` project is preferred over an `:archived` one.

  ## Parameters

  - `tenant_id` -- the tenant UUID (strictly scoped)
  - `opts` -- keyword list or map with any subset of `:slug`, `:repo_url`,
    `:name`. Blank/whitespace-only values are ignored.

  ## Returns

  - `{:ok, %Project{}}` on the first matching identifier
  - `{:error, :not_found}` when identifiers were supplied but nothing matched
  - `{:error, :no_identifier}` when no non-blank identifier was supplied

  Never raises on malformed input.
  """
  @spec resolve_project(Ecto.UUID.t(), keyword() | map()) ::
          {:ok, Project.t()} | {:error, :not_found | :no_identifier}
  def resolve_project(tenant_id, opts) do
    slug = opts |> fetch_opt(:slug) |> presence()
    repo_url = opts |> fetch_opt(:repo_url) |> presence()
    name = opts |> fetch_opt(:name) |> presence()

    if is_nil(slug) and is_nil(repo_url) and is_nil(name) do
      {:error, :no_identifier}
    else
      with :error <- resolve_by_slug(tenant_id, slug),
           :error <- resolve_by_repo_url(tenant_id, repo_url),
           :error <- resolve_by_name(tenant_id, name) do
        {:error, :not_found}
      end
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
    actor_type = Keyword.get(opts, :actor_type, "api_key")
    metadata = Keyword.get(opts, :metadata, %{})

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
          actor_type: actor_type,
          actor_id: actor_id,
          actor_label: actor_label,
          metadata: metadata,
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
    actor_type = Keyword.get(opts, :actor_type, "api_key")
    metadata = Keyword.get(opts, :metadata, %{})

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
          actor_type: actor_type,
          actor_id: actor_id,
          actor_label: actor_label,
          metadata: metadata,
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

  Uses aggregate queries against the epics and stories tables for efficiency.

  ## Returns

  - `{:ok, map}` with progress summary fields
  - `{:error, :not_found}` if the project doesn't exist
  """
  @spec get_project_progress(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_project_progress(tenant_id, project_id) do
    case get_project(tenant_id, project_id) do
      {:ok, _project} ->
        total_epics = count_epics(tenant_id, project_id)
        story_counts = count_stories_by_status(tenant_id, project_id)

        total_stories = Map.values(story_counts.by_agent_status) |> Enum.sum()
        verified_count = Map.get(story_counts.by_verified_status, :verified, 0)

        verification_percentage =
          if total_stories > 0 do
            Float.round(verified_count / total_stories * 100, 1)
          else
            0.0
          end

        hours = estimate_hours(tenant_id, project_id)

        epics_completed = count_completed_epics(tenant_id, project_id)

        progress = %{
          total_stories: total_stories,
          stories_by_agent_status: %{
            pending: Map.get(story_counts.by_agent_status, :pending, 0),
            contracted: Map.get(story_counts.by_agent_status, :contracted, 0),
            assigned: Map.get(story_counts.by_agent_status, :assigned, 0),
            implementing: Map.get(story_counts.by_agent_status, :implementing, 0),
            reported_done: Map.get(story_counts.by_agent_status, :reported_done, 0)
          },
          stories_by_verified_status: %{
            unverified: Map.get(story_counts.by_verified_status, :unverified, 0),
            verified: Map.get(story_counts.by_verified_status, :verified, 0),
            rejected: Map.get(story_counts.by_verified_status, :rejected, 0)
          },
          total_epics: total_epics,
          epics_completed: epics_completed,
          verification_percentage: verification_percentage,
          estimated_hours_total: hours.total,
          estimated_hours_completed: hours.completed
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

  @doc """
  Counts epics for a project within a tenant.
  """
  @spec count_epics(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer()
  def count_epics(tenant_id, project_id) do
    Epic
    |> where([e], e.tenant_id == ^tenant_id and e.project_id == ^project_id)
    |> AdminRepo.aggregate(:count, :id)
  end

  @doc """
  Counts stories for a project within a tenant.
  """
  @spec count_stories(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer()
  def count_stories(tenant_id, project_id) do
    Story
    |> where([s], s.tenant_id == ^tenant_id and s.project_id == ^project_id)
    |> AdminRepo.aggregate(:count, :id)
  end

  # --- Private helpers ---

  # resolve_project/2 support. Each returns {:ok, %Project{}} or :error so the
  # caller can chain them with `with` in precedence order.

  defp fetch_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp fetch_opt(opts, key) when is_map(opts), do: Map.get(opts, key)

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  defp resolve_by_slug(_tenant_id, nil), do: :error

  defp resolve_by_slug(tenant_id, slug) do
    case AdminRepo.get_by(Project, slug: slug, tenant_id: tenant_id) do
      nil -> :error
      project -> {:ok, project}
    end
  end

  defp resolve_by_name(_tenant_id, nil), do: :error

  defp resolve_by_name(tenant_id, name) do
    # Lower BOTH sides in Postgres so the comparison uses a single, consistent
    # locale. Downcasing in Elixir (String.downcase/1) and comparing to
    # `lower(name)` diverges on non-ASCII (Turkish dotless I, ß, final sigma),
    # producing false negatives.
    Project
    |> where([p], p.tenant_id == ^tenant_id)
    |> where([p], fragment("lower(?)", p.name) == fragment("lower(?)", ^name))
    |> prefer_active_one()
  end

  defp resolve_by_repo_url(_tenant_id, nil), do: :error

  defp resolve_by_repo_url(tenant_id, repo_url) do
    target_norm = normalize_repo_url(repo_url)
    target_key = repo_owner_repo(repo_url)

    # A repo_url that normalizes to "" (e.g. ".git", "/", "/.git") or has no
    # derivable "owner/repo" is not a usable identifier -- treat the branch as
    # a miss so the caller falls through to name resolution. Without this, an
    # empty-normalizing target could collide with a project stored with a
    # degenerate repo_url (the `not is_nil(repo_url)` guard doesn't exclude "").
    if target_norm in [nil, ""] or is_nil(target_key) do
      :error
    else
      do_resolve_by_repo_url(tenant_id, target_norm, target_key)
    end
  end

  defp do_resolve_by_repo_url(tenant_id, target_norm, target_key) do
    # Bound the scan in SQL to plausible candidates (those whose stored repo_url
    # contains the target's "owner/repo") so a tenant with thousands of
    # unrelated projects doesn't materialize them all. The Elixir pass below is
    # kept ONLY to enforce exact-vs-suffix precedence over this shrunken set.
    pattern = "%" <> escape_like(target_key) <> "%"

    candidates =
      Project
      |> where([p], p.tenant_id == ^tenant_id and not is_nil(p.repo_url))
      |> where([p], ilike(p.repo_url, ^pattern))
      |> order_by([p],
        asc: fragment("CASE WHEN ? = 'active' THEN 0 ELSE 1 END", p.status),
        asc: p.inserted_at
      )
      |> AdminRepo.all()
      |> Enum.reject(fn project -> normalize_repo_url(project.repo_url) in [nil, ""] end)

    # Two-pass: an EXACT normalized-URL match wins across all candidates (so an
    # exact host beats a same-owner/repo match on a different host); only if
    # none exists do we fall back to the "owner/repo" suffix match. Candidates
    # are active-first then oldest-first, so `Enum.find` stays deterministic.
    exact =
      Enum.find(candidates, fn project ->
        normalize_repo_url(project.repo_url) == target_norm
      end)

    match =
      exact ||
        Enum.find(candidates, fn project ->
          repo_owner_repo(project.repo_url) == target_key
        end)

    case match do
      nil -> :error
      project -> {:ok, project}
    end
  end

  # Orders active-first, then oldest-first for determinism, and returns the top row.
  defp prefer_active_one(query) do
    query
    |> order_by([p],
      asc: fragment("CASE WHEN ? = 'active' THEN 0 ELSE 1 END", p.status),
      asc: p.inserted_at
    )
    |> limit(1)
    |> AdminRepo.one()
    |> case do
      nil -> :error
      project -> {:ok, project}
    end
  end

  # Lowercase, strip a trailing "/" then a trailing ".git" (then any residual "/").
  defp normalize_repo_url(nil), do: nil

  defp normalize_repo_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.downcase()
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.trim_trailing("/")
  end

  # Reduces a repo URL to its trailing "owner/repo" segment so the ssh, https,
  # and bare forms all compare equal. Returns nil when fewer than two segments.
  defp repo_owner_repo(nil), do: nil

  defp repo_owner_repo(url) when is_binary(url) do
    url
    |> normalize_repo_url()
    |> String.replace(":", "/")
    |> String.split("/", trim: true)
    |> Enum.take(-2)
    |> case do
      [owner, repo] -> owner <> "/" <> repo
      _ -> nil
    end
  end

  # Escape LIKE metacharacters so an "owner/repo" containing `%` or `_` is
  # matched literally rather than as a wildcard in the ILIKE pre-filter.
  defp escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

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

  defp count_stories_by_status(tenant_id, project_id) do
    agent_counts =
      from(s in Story,
        where: s.tenant_id == ^tenant_id and s.project_id == ^project_id,
        group_by: s.agent_status,
        select: {s.agent_status, count(s.id)}
      )
      |> AdminRepo.all()
      |> Enum.into(%{})

    verified_counts =
      from(s in Story,
        where: s.tenant_id == ^tenant_id and s.project_id == ^project_id,
        group_by: s.verified_status,
        select: {s.verified_status, count(s.id)}
      )
      |> AdminRepo.all()
      |> Enum.into(%{})

    %{by_agent_status: agent_counts, by_verified_status: verified_counts}
  end

  defp estimate_hours(tenant_id, project_id) do
    total =
      from(s in Story,
        where: s.tenant_id == ^tenant_id and s.project_id == ^project_id,
        select: coalesce(sum(s.estimated_hours), 0)
      )
      |> AdminRepo.one()

    completed =
      from(s in Story,
        where:
          s.tenant_id == ^tenant_id and s.project_id == ^project_id and
            s.verified_status == :verified,
        select: coalesce(sum(s.estimated_hours), 0)
      )
      |> AdminRepo.one()

    %{total: decimal_to_number(total), completed: decimal_to_number(completed)}
  end

  defp decimal_to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_number(val) when is_number(val), do: val
  defp decimal_to_number(_), do: 0

  defp count_completed_epics(tenant_id, project_id) do
    # An epic is "completed" when all its stories are verified
    epic_ids =
      from(e in Epic,
        where: e.tenant_id == ^tenant_id and e.project_id == ^project_id,
        select: e.id
      )
      |> AdminRepo.all()

    Enum.count(epic_ids, fn epic_id ->
      story_count =
        from(s in Story, where: s.epic_id == ^epic_id)
        |> AdminRepo.aggregate(:count, :id)

      verified_count =
        from(s in Story, where: s.epic_id == ^epic_id and s.verified_status == :verified)
        |> AdminRepo.aggregate(:count, :id)

      story_count > 0 and story_count == verified_count
    end)
  end
end
