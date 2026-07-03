defmodule Loopctl.WorkBreakdown.Queries do
  @moduledoc """
  Advanced query functions for the work breakdown dependency graph.

  Provides the ready, blocked, and full graph queries that drive
  orchestrator decision-making.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Projects.Project
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.EpicDependency
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.WorkBreakdown.StoryDependency

  @doc """
  Returns stories that are ready to be assigned.

  A story is "ready" when:
  1. agent_status = :pending
  2. ALL story dependencies have verified_status = :verified (or no deps)
  3. ALL parent epic dependencies have ALL their stories verified

  ## Options

  - `:project_id` -- filter to one project
  - `:epic_id` -- filter to one epic
  - `:page` -- page number (default 1)
  - `:page_size` -- stories per page (default 100, max 500)
  """
  @spec list_ready_stories(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [Story.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_ready_stories(tenant_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 100) |> max(1) |> min(500)
    offset = (page - 1) * page_size

    base_query =
      Story
      |> where([s], s.tenant_id == ^tenant_id and s.agent_status == :pending)
      |> apply_project_filter(opts)
      |> apply_epic_filter(opts)

    # Exclude stories with unverified story-level dependencies
    ready_query =
      base_query
      |> where(
        [s],
        fragment(
          """
          NOT EXISTS (
            SELECT 1 FROM story_dependencies sd
            JOIN stories dep ON dep.id = sd.depends_on_story_id
            WHERE sd.story_id = ?
            AND dep.verified_status != 'verified'
          )
          """,
          s.id
        )
      )
      # Exclude stories whose parent epic has unmet epic-level dependencies
      |> where(
        [s],
        fragment(
          """
          NOT EXISTS (
            SELECT 1 FROM epic_dependencies ed
            WHERE ed.epic_id = ?
            AND EXISTS (
              SELECT 1 FROM stories prereq_story
              WHERE prereq_story.epic_id = ed.depends_on_epic_id
              AND prereq_story.verified_status != 'verified'
            )
          )
          """,
          s.epic_id
        )
      )

    # Also exclude stories in epics that depend on empty prerequisite epics
    # (An epic dependency means the prereq epic must have ALL stories verified,
    #  which is vacuously true if the epic has no stories. We allow this.)

    total = AdminRepo.aggregate(ready_query, :count, :id)

    stories =
      ready_query
      # asc: s.id is a unique, deterministic tiebreaker so OFFSET pagination
      # never skips or duplicates rows sharing a sort_key (sort_key is NOT
      # unique — especially across projects when no project_id filter is set).
      |> order_by([s], asc: s.sort_key, asc: s.id)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: stories, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Returns stories that are blocked by unverified dependencies.

  A story is "blocked" when it has at least one dependency (story or epic-level)
  with verified_status != :verified.

  Includes blocking_dependencies for each story.

  ## Options

  - `:project_id` -- filter to one project
  - `:page` -- page number (default 1)
  - `:page_size` -- stories per page (default 100, max 500)
  """
  @spec list_blocked_stories(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_blocked_stories(tenant_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 100) |> max(1) |> min(500)
    offset = (page - 1) * page_size

    # Stories that have at least one unverified dependency (story-level or epic-level)
    blocked_query =
      Story
      |> where([s], s.tenant_id == ^tenant_id)
      |> apply_project_filter(opts)
      |> where(
        [s],
        fragment(
          """
          EXISTS (
            SELECT 1 FROM story_dependencies sd
            JOIN stories dep ON dep.id = sd.depends_on_story_id
            WHERE sd.story_id = ?
            AND dep.verified_status != 'verified'
          )
          OR EXISTS (
            SELECT 1 FROM epic_dependencies ed
            WHERE ed.epic_id = ?
            AND EXISTS (
              SELECT 1 FROM stories prereq_story
              WHERE prereq_story.epic_id = ed.depends_on_epic_id
              AND prereq_story.verified_status != 'verified'
            )
          )
          """,
          s.id,
          s.epic_id
        )
      )

    total = AdminRepo.aggregate(blocked_query, :count, :id)

    stories =
      blocked_query
      # asc: s.id is a unique, deterministic tiebreaker so OFFSET pagination
      # never skips or duplicates rows sharing a sort_key.
      |> order_by([s], asc: s.sort_key, asc: s.id)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    # Batch-fetch blocking dependencies for the whole page in O(1) queries
    # (two total) instead of 2 per story, to avoid N+1 resource exhaustion on
    # this agent-polled endpoint.
    story_ids = Enum.map(stories, & &1.id)
    epic_ids = stories |> Enum.map(& &1.epic_id) |> Enum.uniq()

    story_blockers_by_story = fetch_blocking_story_dependencies(tenant_id, story_ids)
    epic_blockers_by_epic = fetch_blocking_epic_dependencies(tenant_id, epic_ids)

    data =
      Enum.map(stories, fn story ->
        story_blockers = Map.get(story_blockers_by_story, story.id, [])
        epic_blockers = Map.get(epic_blockers_by_epic, story.epic_id, [])

        %{
          story: story,
          blocking_dependencies: story_blockers ++ epic_blockers
        }
      end)

    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Returns the full dependency graph for a project.

  Includes all epics with nested stories, epic dependency edges,
  and story dependency edges.
  """
  @spec get_dependency_graph(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_dependency_graph(tenant_id, project_id) do
    if valid_uuid?(project_id) do
      build_dependency_graph(tenant_id, project_id)
    else
      # `project_id` is a :binary_id column; a non-UUID path segment would raise
      # Ecto.Query.CastError (an unhandled 500) on the existence check below. A
      # malformed value is a clean :not_found (-> 404), matching Projects.get_project.
      {:error, :not_found}
    end
  end

  defp build_dependency_graph(tenant_id, project_id) do
    # Verify the project exists
    project_exists =
      from(p in Project,
        where: p.id == ^project_id and p.tenant_id == ^tenant_id,
        select: p.id
      )
      |> AdminRepo.one()

    if is_nil(project_exists) do
      {:error, :not_found}
    else
      epics =
        Epic
        |> where([e], e.tenant_id == ^tenant_id and e.project_id == ^project_id)
        |> order_by([e], asc: e.position, asc: e.number)
        |> preload(stories: ^from(s in Story, order_by: [asc: s.sort_key]))
        |> AdminRepo.all()

      epic_ids = Enum.map(epics, & &1.id)

      epic_deps =
        EpicDependency
        |> where([d], d.tenant_id == ^tenant_id and d.epic_id in ^epic_ids)
        |> AdminRepo.all()

      story_ids =
        epics
        |> Enum.flat_map(fn epic -> Enum.map(epic.stories, & &1.id) end)

      story_deps =
        StoryDependency
        |> where([d], d.tenant_id == ^tenant_id and d.story_id in ^story_ids)
        |> AdminRepo.all()

      graph = %{
        epics:
          Enum.map(epics, fn epic ->
            %{
              id: epic.id,
              number: epic.number,
              title: epic.title,
              phase: epic.phase,
              position: epic.position,
              stories:
                Enum.map(epic.stories, fn story ->
                  %{
                    id: story.id,
                    number: story.number,
                    title: story.title,
                    agent_status: story.agent_status,
                    verified_status: story.verified_status,
                    sort_key: story.sort_key
                  }
                end)
            }
          end),
        epic_dependencies:
          Enum.map(epic_deps, fn dep ->
            %{from: dep.epic_id, to: dep.depends_on_epic_id}
          end),
        story_dependencies:
          Enum.map(story_deps, fn dep ->
            %{from: dep.story_id, to: dep.depends_on_story_id}
          end)
      }

      {:ok, graph}
    end
  end

  # --- Private helpers ---

  defp apply_project_filter(query, opts) do
    case Keyword.get(opts, :project_id) do
      nil ->
        query

      "" ->
        query

      project_id ->
        # `project_id` is a :binary_id column; a non-UUID value would raise
        # Ecto.Query.CastError (an unhandled 500). Callers validate at the API
        # boundary and 422 first, but a malformed value reaching here must not
        # crash — treat it as "matches nothing" (defense in depth).
        if valid_uuid?(project_id) do
          where(query, [s], s.project_id == ^project_id)
        else
          where(query, [s], false)
        end
    end
  end

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_), do: false

  defp apply_epic_filter(query, opts) do
    case Keyword.get(opts, :epic_id) do
      nil -> query
      "" -> query
      epic_id -> where(query, [s], s.epic_id == ^epic_id)
    end
  end

  # Batch-fetch story-level blockers for an entire page of blocked stories in a
  # single query. Returns %{story_id => [blocker_map, ...]} so each story can be
  # attached its own blockers in memory (O(1) queries per page, not O(page_size)).
  defp fetch_blocking_story_dependencies(_tenant_id, [] = _story_ids), do: %{}

  defp fetch_blocking_story_dependencies(tenant_id, story_ids) do
    from(sd in StoryDependency,
      join: dep in Story,
      on: dep.id == sd.depends_on_story_id,
      where:
        sd.tenant_id == ^tenant_id and sd.story_id in ^story_ids and
          dep.verified_status != :verified,
      select: %{
        story_id: sd.story_id,
        id: dep.id,
        number: dep.number,
        title: dep.title,
        agent_status: dep.agent_status,
        verified_status: dep.verified_status
      }
    )
    |> AdminRepo.all()
    |> Enum.group_by(& &1.story_id, &Map.delete(&1, :story_id))
  end

  # Batch-fetch epic-level blockers for an entire page in a single query.
  # Returns %{epic_id => [blocker_map, ...]} keyed by the blocked story's epic.
  defp fetch_blocking_epic_dependencies(_tenant_id, [] = _epic_ids), do: %{}

  defp fetch_blocking_epic_dependencies(tenant_id, epic_ids) do
    # Find unverified stories in prerequisite epics (via epic_dependencies)
    from(ed in EpicDependency,
      join: prereq_story in Story,
      on: prereq_story.epic_id == ed.depends_on_epic_id,
      where:
        ed.tenant_id == ^tenant_id and ed.epic_id in ^epic_ids and
          prereq_story.verified_status != :verified,
      select: %{
        epic_id: ed.epic_id,
        id: prereq_story.id,
        number: prereq_story.number,
        title: prereq_story.title,
        agent_status: prereq_story.agent_status,
        verified_status: prereq_story.verified_status
      }
    )
    |> AdminRepo.all()
    |> Enum.group_by(& &1.epic_id, &Map.delete(&1, :epic_id))
  end
end
