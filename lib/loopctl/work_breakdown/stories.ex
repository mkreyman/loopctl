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
  alias Loopctl.Repo
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
      # asc: s.id is a unique, deterministic tiebreaker so OFFSET pagination
      # never skips or duplicates rows sharing a sort_key.
      |> order_by([s], asc: s.sort_key, asc: s.id)
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
  - `:strategy` -- read-path selector, `:admin` | `:rls` (US-33.7 pilot). This is a
    SECURITY-PATH selector: `:admin` reads through the BYPASSRLS `AdminRepo`,
    `:rls` reads through the RLS `Repo` via `Repo.with_tenant/2`. It exists so the
    release-gate tests can exercise BOTH paths without `Application.put_env`. When
    OMITTED (the normal caller contract), the path is resolved from the default-OFF
    `:rls_reroute_list_stories_by_project` flag at call time — production callers
    should NOT pass `:strategy` and let the flag decide.

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

    # US-33.7 pilot: pick the read path. Default is the BYPASSRLS `AdminRepo`
    # (today's behavior). The `:strategy` opt is an explicit selector so both
    # branches can be exercised in-test without `Application.put_env`; when it is
    # absent the strategy is resolved from the default-OFF config flag at call time.
    strategy = Keyword.get(opts, :strategy, default_list_stories_strategy())

    list_stories_by_project(strategy, tenant_id, project_id, opts, limit, offset)
  end

  # RLS path resolved from config unless the caller passed an explicit `:strategy`.
  defp default_list_stories_strategy do
    if Application.get_env(:loopctl, :rls_reroute_list_stories_by_project, false) do
      :rls
    else
      :admin
    end
  end

  # AdminRepo path (default) — BYPASSRLS pool, unchanged from before the pilot.
  defp list_stories_by_project(:admin, tenant_id, project_id, opts, limit, offset) do
    base_query = project_stories_query(tenant_id, project_id, opts)

    total = AdminRepo.aggregate(base_query, :count, :id)
    stories = base_query |> paginate_project_stories(limit, offset) |> AdminRepo.all()

    {:ok, %{data: stories, total: total, limit: limit, offset: offset}}
  end

  # RLS path fail-closed guard (AC-33.7.3 / TC-33.7.3): a missing or blank tenant
  # context yields ZERO rows, never cross-tenant rows and never a leaking error.
  # `Repo.with_tenant/2` guards `is_binary(tenant_id)`, and building the base query
  # with a blank `tenant_id` against the `:binary_id` column would raise a
  # CastError — so short-circuit BEFORE constructing or executing anything.
  defp list_stories_by_project(:rls, tenant_id, _project_id, _opts, limit, offset)
       when not is_binary(tenant_id) or tenant_id == "" do
    {:ok, %{data: [], total: 0, limit: limit, offset: offset}}
  end

  # RLS path (US-33.7 pilot) — RLS `Repo` pool via `with_tenant/2`. RLS is the
  # primary enforcement (`tenant_id = current_tenant_id()`); the explicit
  # `where s.tenant_id == ^tenant_id` predicate in `project_stories_query/3` is kept
  # as defense-in-depth (mirrors `ContextRetriever.Executor`). Both count and page
  # run inside ONE tenant-scoped transaction.
  #
  # DB-error semantics: this fun never calls `Repo.rollback/1`, so `with_tenant/2`
  # (a `Repo.transaction/1`) always returns `{:ok, {total, stories}}` on the happy
  # path. A DB error inside `Repo.aggregate/2` or `Repo.all/1` RAISES `Postgrex.Error`,
  # which rolls back and RE-RAISES out of the transaction — it propagates as a 500,
  # exactly like the `:admin` path's uncaught `AdminRepo` calls. We deliberately do
  # NOT swallow that into an empty page: masking a DB failure as "zero rows" would
  # hide the error and could look like a (wrong) fail-closed. Fail LOUD, at parity
  # with the AdminRepo path; RLS/tenant fail-closed is handled by the guard clause
  # above and by RLS itself, not by catching DB errors here.
  defp list_stories_by_project(:rls, tenant_id, project_id, opts, limit, offset) do
    base_query = project_stories_query(tenant_id, project_id, opts)
    page_query = paginate_project_stories(base_query, limit, offset)

    {:ok, {total, stories}} =
      Repo.with_tenant(tenant_id, fn ->
        total = Repo.aggregate(base_query, :count, :id)
        stories = Repo.all(page_query)
        {total, stories}
      end)

    {:ok, %{data: stories, total: total, limit: limit, offset: offset}}
  end

  defp project_stories_query(tenant_id, project_id, opts) do
    Story
    |> where([s], s.tenant_id == ^tenant_id)
    |> scope_by_project(project_id)
    |> apply_project_filters(opts)
  end

  defp paginate_project_stories(query, limit, offset) do
    query
    # asc: s.id is a unique, deterministic tiebreaker so OFFSET pagination
    # never skips or duplicates rows sharing a sort_key.
    |> order_by([s], asc: s.sort_key, asc: s.id)
    |> limit(^limit)
    |> offset(^offset)
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

  defp filter_by_epic_id(query, epic_id) do
    # `epic_id` is a :binary_id column; a non-UUID value would raise
    # Ecto.Query.CastError (500 -> global handler 404). Treat a malformed value
    # as "matches nothing", consistent with a nonexistent epic (defense in depth).
    if valid_uuid?(epic_id) do
      where(query, [s], s.epic_id == ^epic_id)
    else
      where(query, [s], false)
    end
  end

  # `project_id` is mandatory here (stories are scoped to a project). A non-UUID
  # value would raise Ecto.Query.CastError; scope to nothing instead, matching a
  # valid-but-nonexistent project. The controller 422s a malformed value first.
  defp scope_by_project(query, project_id) do
    if valid_uuid?(project_id) do
      where(query, [s], s.project_id == ^project_id)
    else
      where(query, [s], false)
    end
  end

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_), do: false

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
