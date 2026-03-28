defmodule Loopctl.WorkBreakdown.Stories do
  @moduledoc """
  Context module for story management within the work breakdown structure.

  Stories are tenant-scoped atomic work units within epics. All operations
  require a `tenant_id` as the first argument for explicit scoping.

  The project_id is denormalized from the parent epic for efficient querying
  and project-wide uniqueness of story numbers.

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
  Creates a new story within an epic.

  The `project_id` is derived from the parent epic's `project_id`.
  The `sort_key` is computed from the story number for natural numeric sorting.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with `:epic_id`, `:number`, `:title`, and optional fields
  - `opts` -- keyword list with `:actor_id` and `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, changeset}` on validation failure
  - `{:error, :epic_not_found}` if the epic doesn't exist
  """
  @spec create_story(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Story.t()} | {:error, Ecto.Changeset.t() | :epic_not_found}
  def create_story(tenant_id, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    epic_id = Map.get(attrs, :epic_id) || Map.get(attrs, "epic_id")

    with {:ok, epic} <- get_parent_epic(tenant_id, epic_id) do
      changeset =
        %Story{tenant_id: tenant_id, project_id: epic.project_id, epic_id: epic.id}
        |> Story.create_changeset(attrs)

      multi =
        Multi.new()
        |> Multi.insert(:story, changeset)
        |> Audit.log_in_multi(:audit, fn %{story: story} ->
          %{
            tenant_id: tenant_id,
            entity_type: "story",
            entity_id: story.id,
            action: "created",
            actor_type: "api_key",
            actor_id: actor_id,
            actor_label: actor_label,
            new_state: %{
              "number" => story.number,
              "title" => story.title,
              "epic_id" => story.epic_id,
              "project_id" => story.project_id,
              "agent_status" => to_string(story.agent_status),
              "verified_status" => to_string(story.verified_status)
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{story: story}} ->
          {:ok, story}

        {:error, :story, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Gets a story by ID, scoped to a tenant.

  ## Returns

  - `{:ok, %Story{}}` if found
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_story(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Story.t()} | {:error, :not_found}
  def get_story(tenant_id, story_id) do
    case AdminRepo.get_by(Story, id: story_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      story -> {:ok, story}
    end
  end

  @doc """
  Updates a story within a tenant.

  Only metadata fields can be updated (title, description, acceptance_criteria,
  estimated_hours, metadata). Status fields are managed via dedicated endpoints.
  Number cannot be changed after creation.

  ## Parameters

  - `tenant_id` -- the tenant UUID (for audit logging)
  - `story` -- the `%Story{}` struct to update
  - `attrs` -- map of fields to update
  - `opts` -- keyword list with `:actor_id` and `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec update_story(Ecto.UUID.t(), Story.t(), map(), keyword()) ::
          {:ok, Story.t()} | {:error, Ecto.Changeset.t()}
  def update_story(tenant_id, %Story{} = story, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    changeset = Story.update_changeset(story, attrs)

    multi =
      Multi.new()
      |> Multi.update(:story, changeset)
      |> Audit.log_in_multi(:audit, fn %{story: updated} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: updated.id,
          action: "updated",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{
            "title" => story.title,
            "description" => story.description
          },
          new_state: %{
            "title" => updated.title,
            "description" => updated.description
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} ->
        {:ok, updated}

      {:error, :story, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes a story within a tenant.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story` -- the `%Story{}` struct to delete
  - `opts` -- keyword list with `:actor_id` and `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, changeset}` on failure
  """
  @spec delete_story(Ecto.UUID.t(), Story.t(), keyword()) ::
          {:ok, Story.t()} | {:error, Ecto.Changeset.t()}
  def delete_story(tenant_id, %Story{} = story, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    multi =
      Multi.new()
      |> Multi.delete(:story, story)
      |> Audit.log_in_multi(:audit, fn %{story: deleted} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: deleted.id,
          action: "deleted",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{
            "number" => deleted.number,
            "title" => deleted.title,
            "epic_id" => deleted.epic_id
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: deleted}} ->
        {:ok, deleted}

      {:error, :story, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Lists stories for an epic with optional filters and page-based pagination.

  Stories are ordered by sort_key (natural numeric order).

  ## Options (keyword list)

  - `:agent_status` -- filter by agent_status enum value
  - `:verified_status` -- filter by verified_status enum value
  - `:page` -- page number (default 1)
  - `:page_size` -- stories per page (default 20, max 100)

  ## Returns

  `{:ok, %{data: [%Story{}], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_stories(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [Story.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_stories(tenant_id, epic_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      Story
      |> where([s], s.tenant_id == ^tenant_id and s.epic_id == ^epic_id)
      |> apply_filters(opts)

    total = AdminRepo.aggregate(base_query, :count, :id)

    stories =
      base_query
      |> order_by([s], asc: s.sort_key)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: stories, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Lists stories for a project with optional filters and offset-based pagination.

  Stories are ordered by sort_key (natural numeric order).

  ## Options (keyword list)

  - `:agent_status` -- filter by agent_status enum value
  - `:verified_status` -- filter by verified_status enum value
  - `:epic_id` -- filter to a specific epic within the project
  - `:limit` -- max stories to return (default 100, max 500)
  - `:offset` -- how many stories to skip (default 0)

  ## Returns

  `{:ok, %{data: [%Story{}], total: integer, limit: integer, offset: integer}}`
  """
  @spec list_stories_by_project(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [Story.t()],
             total: non_neg_integer(),
             limit: pos_integer(),
             offset: non_neg_integer()
           }}
  def list_stories_by_project(tenant_id, project_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(500)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base_query =
      Story
      |> where([s], s.tenant_id == ^tenant_id and s.project_id == ^project_id)
      |> apply_project_filters(opts)

    total = AdminRepo.aggregate(base_query, :count, :id)

    stories =
      base_query
      |> order_by([s], asc: s.sort_key)
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: stories, total: total, limit: limit, offset: offset}}
  end

  # --- Private helpers ---

  defp get_parent_epic(tenant_id, epic_id) when is_binary(epic_id) do
    case AdminRepo.get_by(Epic, id: epic_id, tenant_id: tenant_id) do
      nil -> {:error, :epic_not_found}
      epic -> {:ok, epic}
    end
  end

  defp get_parent_epic(_tenant_id, _epic_id), do: {:error, :epic_not_found}

  defp apply_filters(query, opts) do
    query
    |> filter_by_agent_status(Keyword.get(opts, :agent_status))
    |> filter_by_verified_status(Keyword.get(opts, :verified_status))
  end

  defp apply_project_filters(query, opts) do
    query
    |> filter_by_agent_status(Keyword.get(opts, :agent_status))
    |> filter_by_verified_status(Keyword.get(opts, :verified_status))
    |> filter_by_epic_id(Keyword.get(opts, :epic_id))
  end

  defp filter_by_epic_id(query, nil), do: query
  defp filter_by_epic_id(query, ""), do: query
  defp filter_by_epic_id(query, epic_id), do: where(query, [s], s.epic_id == ^epic_id)

  defp filter_by_agent_status(query, nil), do: query
  defp filter_by_agent_status(query, ""), do: query

  defp filter_by_agent_status(query, status) when is_binary(status) do
    case safe_to_status_atom(status) do
      nil -> query
      atom -> where(query, [s], s.agent_status == ^atom)
    end
  end

  defp filter_by_agent_status(query, status) when is_atom(status) do
    where(query, [s], s.agent_status == ^status)
  end

  defp filter_by_verified_status(query, nil), do: query
  defp filter_by_verified_status(query, ""), do: query

  defp filter_by_verified_status(query, status) when is_binary(status) do
    case safe_to_status_atom(status) do
      nil -> query
      atom -> where(query, [s], s.verified_status == ^atom)
    end
  end

  defp filter_by_verified_status(query, status) when is_atom(status) do
    where(query, [s], s.verified_status == ^status)
  end

  @valid_statuses %{
    "pending" => :pending,
    "contracted" => :contracted,
    "assigned" => :assigned,
    "implementing" => :implementing,
    "reported_done" => :reported_done,
    "unverified" => :unverified,
    "verified" => :verified,
    "rejected" => :rejected
  }

  defp safe_to_status_atom(str) do
    Map.get(@valid_statuses, str)
  end
end
