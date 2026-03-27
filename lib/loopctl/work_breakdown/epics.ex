defmodule Loopctl.WorkBreakdown.Epics do
  @moduledoc """
  Context module for epic management within the work breakdown structure.

  Epics are tenant-scoped groupings within a project. All operations
  require a `tenant_id` as the first argument for explicit scoping.

  All mutations (create, update, delete) are atomic operations that include
  audit logging via `Ecto.Multi` in the same transaction.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

  @doc """
  Creates a new epic within a project.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with `:number`, `:title`, and optional fields; must include `:project_id`
  - `opts` -- keyword list with `:actor_id` and `:actor_label`

  ## Returns

  - `{:ok, %Epic{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec create_epic(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Epic.t()} | {:error, Ecto.Changeset.t()}
  def create_epic(tenant_id, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    project_id = Map.get(attrs, :project_id) || Map.get(attrs, "project_id")

    changeset =
      %Epic{tenant_id: tenant_id, project_id: project_id}
      |> Epic.create_changeset(attrs)

    multi =
      Multi.new()
      |> Multi.insert(:epic, changeset)
      |> Audit.log_in_multi(:audit, fn %{epic: epic} ->
        %{
          tenant_id: tenant_id,
          entity_type: "epic",
          entity_id: epic.id,
          action: "created",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          new_state: %{
            "number" => epic.number,
            "title" => epic.title,
            "project_id" => epic.project_id
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{epic: epic}} ->
        {:ok, epic}

      {:error, :epic, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Gets an epic by ID, scoped to a tenant.

  ## Returns

  - `{:ok, %Epic{}}` if found
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_epic(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Epic.t()} | {:error, :not_found}
  def get_epic(tenant_id, epic_id) do
    case AdminRepo.get_by(Epic, id: epic_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      epic -> {:ok, epic}
    end
  end

  @doc """
  Gets an epic by ID with stories preloaded, scoped to a tenant.

  ## Returns

  - `{:ok, %Epic{}}` if found (with stories preloaded)
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_epic_with_stories(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Epic.t()} | {:error, :not_found}
  def get_epic_with_stories(tenant_id, epic_id) do
    query =
      Epic
      |> where([e], e.id == ^epic_id and e.tenant_id == ^tenant_id)
      |> preload(stories: ^from(s in Loopctl.WorkBreakdown.Story, order_by: [asc: s.sort_key]))

    case AdminRepo.one(query) do
      nil -> {:error, :not_found}
      epic -> {:ok, epic}
    end
  end

  @doc """
  Updates an epic within a tenant.

  Number cannot be changed after creation.

  ## Parameters

  - `tenant_id` -- the tenant UUID (for audit logging)
  - `epic` -- the `%Epic{}` struct to update
  - `attrs` -- map of fields to update
  - `opts` -- keyword list with `:actor_id` and `:actor_label`

  ## Returns

  - `{:ok, %Epic{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec update_epic(Ecto.UUID.t(), Epic.t(), map(), keyword()) ::
          {:ok, Epic.t()} | {:error, Ecto.Changeset.t()}
  def update_epic(tenant_id, %Epic{} = epic, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    changeset = Epic.update_changeset(epic, attrs)

    multi =
      Multi.new()
      |> Multi.update(:epic, changeset)
      |> Audit.log_in_multi(:audit, fn %{epic: updated} ->
        %{
          tenant_id: tenant_id,
          entity_type: "epic",
          entity_id: updated.id,
          action: "updated",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{
            "title" => epic.title,
            "phase" => epic.phase,
            "position" => epic.position
          },
          new_state: %{
            "title" => updated.title,
            "phase" => updated.phase,
            "position" => updated.position
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{epic: updated}} ->
        {:ok, updated}

      {:error, :epic, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes an epic within a tenant.

  Child stories are cascade-deleted by the database foreign key constraint.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `epic` -- the `%Epic{}` struct to delete
  - `opts` -- keyword list with `:actor_id` and `:actor_label`

  ## Returns

  - `{:ok, %Epic{}}` on success
  - `{:error, changeset}` on failure
  """
  @spec delete_epic(Ecto.UUID.t(), Epic.t(), keyword()) ::
          {:ok, Epic.t()} | {:error, Ecto.Changeset.t()}
  def delete_epic(tenant_id, %Epic{} = epic, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    multi =
      Multi.new()
      |> Multi.delete(:epic, epic)
      |> Audit.log_in_multi(:audit, fn %{epic: deleted} ->
        %{
          tenant_id: tenant_id,
          entity_type: "epic",
          entity_id: deleted.id,
          action: "deleted",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{
            "number" => deleted.number,
            "title" => deleted.title,
            "project_id" => deleted.project_id
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{epic: deleted}} ->
        {:ok, deleted}

      {:error, :epic, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Lists epics for a project with optional filters and page-based pagination.

  Returns each epic with story_count and completion_percentage.

  ## Options (keyword list)

  - `:phase` -- filter by phase string
  - `:page` -- page number (default 1)
  - `:page_size` -- epics per page (default 20, max 100)

  ## Returns

  `{:ok, %{data: [map()], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_epics(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_epics(tenant_id, project_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      Epic
      |> where([e], e.tenant_id == ^tenant_id and e.project_id == ^project_id)
      |> apply_filters(opts)

    total = AdminRepo.aggregate(base_query, :count, :id)

    epics =
      base_query
      |> order_by([e], asc: e.position, asc: e.number)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    # Compute story counts per epic in a single query
    epic_ids = Enum.map(epics, & &1.id)
    story_stats = fetch_story_stats(epic_ids)

    data =
      Enum.map(epics, fn epic ->
        stats = Map.get(story_stats, epic.id, %{total: 0, verified: 0})

        completion =
          if stats.total > 0 do
            Float.round(stats.verified / stats.total * 100, 1)
          else
            0.0
          end

        Map.merge(Map.from_struct(epic), %{
          story_count: stats.total,
          completion_percentage: completion
        })
      end)

    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Returns progress breakdown for a single epic.

  ## Returns

  - `{:ok, map()}` with stories_by_agent_status and stories_by_verified_status
  - `{:error, :not_found}` if the epic doesn't exist
  """
  @spec get_epic_progress(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_epic_progress(tenant_id, epic_id) do
    case get_epic(tenant_id, epic_id) do
      {:ok, _epic} ->
        agent_status_counts = count_stories_by_field(epic_id, :agent_status)
        verified_status_counts = count_stories_by_field(epic_id, :verified_status)

        progress = %{
          stories_by_agent_status: %{
            pending: Map.get(agent_status_counts, :pending, 0),
            contracted: Map.get(agent_status_counts, :contracted, 0),
            assigned: Map.get(agent_status_counts, :assigned, 0),
            implementing: Map.get(agent_status_counts, :implementing, 0),
            reported_done: Map.get(agent_status_counts, :reported_done, 0)
          },
          stories_by_verified_status: %{
            unverified: Map.get(verified_status_counts, :unverified, 0),
            verified: Map.get(verified_status_counts, :verified, 0),
            rejected: Map.get(verified_status_counts, :rejected, 0)
          }
        }

        {:ok, progress}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Private helpers ---

  defp apply_filters(query, opts) do
    case Keyword.get(opts, :phase) do
      nil -> query
      "" -> query
      phase -> where(query, [e], e.phase == ^phase)
    end
  end

  defp fetch_story_stats([]), do: %{}

  defp fetch_story_stats(epic_ids) do
    story_query =
      from(s in Story,
        where: s.epic_id in ^epic_ids,
        group_by: s.epic_id,
        select:
          {s.epic_id, count(s.id),
           count(fragment("CASE WHEN ? = 'verified' THEN 1 END", s.verified_status))}
      )

    AdminRepo.all(story_query)
    |> Enum.into(%{}, fn {epic_id, total, verified} ->
      {epic_id, %{total: total, verified: verified}}
    end)
  end

  defp count_stories_by_field(epic_id, field) do
    from(s in Story,
      where: s.epic_id == ^epic_id,
      group_by: field(s, ^field),
      select: {field(s, ^field), count(s.id)}
    )
    |> AdminRepo.all()
    |> Enum.into(%{}, fn {status, count} ->
      {status, count}
    end)
  end
end
