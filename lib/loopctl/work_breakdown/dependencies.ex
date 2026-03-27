defmodule Loopctl.WorkBreakdown.Dependencies do
  @moduledoc """
  Context module for managing epic and story dependency edges.

  Dependencies are directed edges forming a DAG (directed acyclic graph).
  Cycle detection prevents circular dependencies. Cross-level consistency
  checks prevent deadlocks between epic and story dependency layers.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.EpicDependency
  alias Loopctl.WorkBreakdown.Graph
  alias Loopctl.WorkBreakdown.Story

  # ===================================================================
  # Epic Dependencies
  # ===================================================================

  @doc """
  Creates an epic dependency edge: `epic_id` depends on `depends_on_epic_id`.

  Validates:
  - No self-dependency
  - Both epics belong to the same project
  - No cycle would be created
  - No cross-level deadlock with story dependencies

  ## Returns

  - `{:ok, %EpicDependency{}}` on success
  - `{:error, :self_dependency}` if epic_id == depends_on_epic_id
  - `{:error, :cross_project}` if epics are in different projects
  - `{:error, :cycle_detected}` if adding the edge would create a cycle
  - `{:error, :cross_level_deadlock, message}` if story deps conflict
  - `{:error, :conflict}` if the dependency already exists
  - `{:error, changeset}` on validation failure
  """
  @spec create_epic_dependency(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, EpicDependency.t()}
          | {:error,
             :self_dependency
             | :cross_project
             | :cycle_detected
             | :conflict
             | :not_found
             | {:cross_level_deadlock, String.t()}
             | Ecto.Changeset.t()}
  def create_epic_dependency(tenant_id, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    epic_id = Map.get(attrs, :epic_id) || Map.get(attrs, "epic_id")
    depends_on_id = Map.get(attrs, :depends_on_epic_id) || Map.get(attrs, "depends_on_epic_id")

    with :ok <- validate_not_self(epic_id, depends_on_id),
         {:ok, epic} <- get_epic(tenant_id, epic_id),
         {:ok, dep_epic} <- get_epic(tenant_id, depends_on_id),
         :ok <- validate_same_project(epic, dep_epic),
         :ok <- validate_no_epic_cycle(tenant_id, epic.project_id, epic_id, depends_on_id),
         :ok <- validate_no_cross_level_deadlock(tenant_id, epic_id, depends_on_id) do
      changeset =
        %EpicDependency{tenant_id: tenant_id}
        |> EpicDependency.create_changeset(%{
          epic_id: epic_id,
          depends_on_epic_id: depends_on_id
        })

      multi =
        Multi.new()
        |> Multi.insert(:dependency, changeset)
        |> Audit.log_in_multi(:audit, fn %{dependency: dep} ->
          %{
            tenant_id: tenant_id,
            entity_type: "epic_dependency",
            entity_id: dep.id,
            action: "created",
            actor_type: "api_key",
            actor_id: actor_id,
            actor_label: actor_label,
            new_state: %{
              "epic_id" => dep.epic_id,
              "depends_on_epic_id" => dep.depends_on_epic_id
            }
          }
        end)

      multi
      |> AdminRepo.transaction()
      |> handle_dependency_result()
    end
  end

  @doc """
  Deletes an epic dependency edge.
  """
  @spec delete_epic_dependency(Ecto.UUID.t(), EpicDependency.t(), keyword()) ::
          {:ok, EpicDependency.t()} | {:error, Ecto.Changeset.t()}
  def delete_epic_dependency(tenant_id, %EpicDependency{} = dep, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    multi =
      Multi.new()
      |> Multi.delete(:dependency, dep)
      |> Audit.log_in_multi(:audit, fn %{dependency: deleted} ->
        %{
          tenant_id: tenant_id,
          entity_type: "epic_dependency",
          entity_id: deleted.id,
          action: "deleted",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{
            "epic_id" => deleted.epic_id,
            "depends_on_epic_id" => deleted.depends_on_epic_id
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{dependency: deleted}} -> {:ok, deleted}
      {:error, :dependency, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Gets an epic dependency by ID, scoped to a tenant.
  """
  @spec get_epic_dependency(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, EpicDependency.t()} | {:error, :not_found}
  def get_epic_dependency(tenant_id, dep_id) do
    case AdminRepo.get_by(EpicDependency, id: dep_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      dep -> {:ok, dep}
    end
  end

  @doc """
  Lists all epic dependency edges for a project.
  """
  @spec list_epic_dependencies(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [EpicDependency.t()]}
  def list_epic_dependencies(tenant_id, project_id) do
    epic_ids =
      from(e in Epic,
        where: e.tenant_id == ^tenant_id and e.project_id == ^project_id,
        select: e.id
      )
      |> AdminRepo.all()

    deps =
      EpicDependency
      |> where([d], d.tenant_id == ^tenant_id)
      |> where([d], d.epic_id in ^epic_ids)
      |> order_by([d], asc: d.inserted_at)
      |> AdminRepo.all()

    {:ok, deps}
  end

  # ===================================================================
  # Private: Epic Dependency Validation
  # ===================================================================

  defp validate_not_self(id, id) when is_binary(id), do: {:error, :self_dependency}
  defp validate_not_self(_, _), do: :ok

  defp get_epic(tenant_id, epic_id) do
    case AdminRepo.get_by(Epic, id: epic_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      epic -> {:ok, epic}
    end
  end

  defp validate_same_project(epic, dep_epic) do
    if epic.project_id == dep_epic.project_id do
      :ok
    else
      {:error, :cross_project}
    end
  end

  defp validate_no_epic_cycle(tenant_id, project_id, epic_id, depends_on_id) do
    # Load all existing epic dependency edges for this project
    edges = load_epic_edges(tenant_id, project_id)

    if Graph.would_create_cycle?(edges, epic_id, depends_on_id) do
      {:error, :cycle_detected}
    else
      :ok
    end
  end

  defp load_epic_edges(tenant_id, project_id) do
    epic_ids =
      from(e in Epic,
        where: e.tenant_id == ^tenant_id and e.project_id == ^project_id,
        select: e.id
      )
      |> AdminRepo.all()

    from(d in EpicDependency,
      where: d.tenant_id == ^tenant_id and d.epic_id in ^epic_ids,
      select: {d.epic_id, d.depends_on_epic_id}
    )
    |> AdminRepo.all()
  end

  defp validate_no_cross_level_deadlock(tenant_id, epic_id, depends_on_epic_id) do
    # If Epic A (epic_id) depends on Epic B (depends_on_epic_id),
    # then no story in Epic B may depend on any story in Epic A.
    # Check if there are any story_dependencies where:
    #   story in depends_on_epic_id depends on story in epic_id

    # Only check if story_dependencies table exists (it may not exist yet in US-6.3)
    case AdminRepo.query("SELECT to_regclass('story_dependencies')") do
      {:ok, %{rows: [[nil]]}} ->
        :ok

      {:ok, _} ->
        check_cross_level_story_deps(tenant_id, epic_id, depends_on_epic_id)

      _ ->
        :ok
    end
  end

  defp check_cross_level_story_deps(tenant_id, epic_id, depends_on_epic_id) do
    # Stories in depends_on_epic_id (Epic B)
    stories_in_b =
      from(s in Story,
        where: s.tenant_id == ^tenant_id and s.epic_id == ^depends_on_epic_id,
        select: s.id
      )
      |> AdminRepo.all()

    # Stories in epic_id (Epic A)
    stories_in_a =
      from(s in Story,
        where: s.tenant_id == ^tenant_id and s.epic_id == ^epic_id,
        select: s.id
      )
      |> AdminRepo.all()

    if Enum.empty?(stories_in_b) or Enum.empty?(stories_in_a) do
      :ok
    else
      # Check if any story in B depends on any story in A
      conflicting =
        from(d in "story_dependencies",
          where: d.story_id in ^stories_in_b and d.depends_on_story_id in ^stories_in_a,
          select: {d.story_id, d.depends_on_story_id}
        )
        |> AdminRepo.all()

      if Enum.empty?(conflicting) do
        :ok
      else
        {story_b_id, story_a_id} = hd(conflicting)

        msg =
          "Cross-level deadlock: story #{story_b_id} (in prerequisite epic) " <>
            "depends on story #{story_a_id} (in dependent epic)"

        {:error, {:cross_level_deadlock, msg}}
      end
    end
  end

  defp handle_dependency_result({:ok, %{dependency: dep}}), do: {:ok, dep}

  defp handle_dependency_result({:error, :dependency, changeset, _changes}) do
    if has_unique_constraint_error?(changeset) do
      {:error, :conflict}
    else
      {:error, changeset}
    end
  end

  defp has_unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end
end
