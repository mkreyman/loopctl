defmodule Loopctl.ImportExport do
  @moduledoc """
  Context module for bulk import and export of project work breakdowns.

  Supports:
  - **Fresh import** (`import_project/4`): Creates all epics, stories, and
    dependencies in a single transaction. Rejects if duplicate numbers exist.
  - **Merge import** (`merge_import_project/4`): Creates new entities, updates
    existing ones (matched by number), preserves status fields, and reports orphans.
  - **Export** (`export_project/2`): Serializes a project to a JSON-compatible
    map in the import format for round-trip fidelity.

  All mutations are atomic (Ecto.Multi) with audit logging and webhook events.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.EpicDependency
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.WorkBreakdown.StoryDependency

  # ===================================================================
  # Fresh Import (US-12.1)
  # ===================================================================

  @doc """
  Imports a complete work breakdown into a project.

  Creates all epics, stories, and dependencies in a single Ecto.Multi
  transaction. Validates the dependency graph for cycles before committing.

  If the project already contains epics/stories with numbers matching the
  import payload and `merge` is not true, returns `{:error, :conflict, details}`.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `project_id` -- the project UUID
  - `data` -- map with `"epics"` and optional `"story_dependencies"` / `"epic_dependencies"`
  - `opts` -- keyword list with `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, summary}` on success
  - `{:error, :conflict, details}` if duplicate numbers found (AC-12.1.11)
  - `{:error, :validation, message}` for payload validation errors
  - `{:error, :cycle_detected, message}` for dependency cycles
  """
  @spec import_project(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()}
          | {:error, :conflict, map()}
          | {:error, :validation, String.t()}
          | {:error, :cycle_detected, String.t()}
  def import_project(tenant_id, project_id, data, opts \\ []) do
    epics_data = Map.get(data, "epics", [])
    story_deps_data = Map.get(data, "story_dependencies", [])
    epic_deps_data = Map.get(data, "epic_dependencies", [])

    with :ok <- validate_payload_structure(epics_data),
         :ok <- validate_no_duplicate_numbers(epics_data),
         :ok <- check_no_existing_conflicts(tenant_id, project_id, epics_data) do
      execute_fresh_import(
        tenant_id,
        project_id,
        epics_data,
        story_deps_data,
        epic_deps_data,
        opts
      )
    end
  end

  # ===================================================================
  # Merge Import (US-12.3)
  # ===================================================================

  @doc """
  Merge-imports a work breakdown into a project.

  Matches epics and stories by number. Creates new entities, updates existing
  ones (metadata only -- status fields are preserved), and reports orphans.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `project_id` -- the project UUID
  - `data` -- map with `"epics"` and optional dependency arrays
  - `opts` -- keyword list with `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, summary}` on success with detailed merge counts and orphan list
  - `{:error, :validation, message}` for payload validation errors
  - `{:error, :cycle_detected, message}` for dependency cycles
  """
  @spec merge_import_project(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()}
          | {:error, :validation, String.t()}
          | {:error, :cycle_detected, String.t()}
  def merge_import_project(tenant_id, project_id, data, opts \\ []) do
    epics_data = Map.get(data, "epics", [])
    story_deps_data = Map.get(data, "story_dependencies", [])
    epic_deps_data = Map.get(data, "epic_dependencies", [])

    with :ok <- validate_payload_structure(epics_data),
         :ok <- validate_no_duplicate_numbers(epics_data) do
      execute_merge_import(
        tenant_id,
        project_id,
        epics_data,
        story_deps_data,
        epic_deps_data,
        opts
      )
    end
  end

  # ===================================================================
  # Export (US-12.2)
  # ===================================================================

  @doc """
  Exports a complete project as a JSON-compatible map.

  The export format matches the import format for round-trip fidelity.
  Epics are ordered by number, stories within each epic are ordered by number,
  and dependencies are ordered deterministically.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `project_id` -- the project UUID

  ## Returns

  - `{:ok, export_map}` on success
  - `{:error, :not_found}` if project not found
  """
  @spec export_project(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :not_found}
  def export_project(tenant_id, project_id) do
    project =
      Loopctl.Projects.Project
      |> where([p], p.id == ^project_id and p.tenant_id == ^tenant_id)
      |> AdminRepo.one()

    case project do
      nil ->
        {:error, :not_found}

      project ->
        epics = load_epics_with_stories(tenant_id, project_id)
        story_deps = load_all_story_dependencies(tenant_id, project_id)
        epic_deps = load_all_epic_dependencies(tenant_id, project_id)

        # Build story_id -> story_number and epic_id -> epic_number maps
        story_id_to_number = build_story_id_map(epics)
        epic_id_to_number = build_epic_id_map(epics)

        export = %{
          "export_metadata" => %{
            "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
            "loopctl_version" => Application.spec(:loopctl, :vsn) |> to_string(),
            "project_id" => project.id,
            "tenant_id" => project.tenant_id
          },
          "project" => %{
            "name" => project.name,
            "slug" => project.slug,
            "description" => project.description,
            "repo_url" => project.repo_url,
            "tech_stack" => project.tech_stack,
            "status" => to_string(project.status),
            "metadata" => project.metadata
          },
          "epics" => Enum.map(epics, &serialize_epic/1),
          "story_dependencies" =>
            story_deps
            |> Enum.sort_by(fn dep -> {dep.story_id, dep.depends_on_story_id} end)
            |> Enum.map(fn dep ->
              %{
                "story" => Map.get(story_id_to_number, dep.story_id),
                "depends_on" => Map.get(story_id_to_number, dep.depends_on_story_id)
              }
            end),
          "epic_dependencies" =>
            epic_deps
            |> Enum.sort_by(fn dep -> {dep.epic_id, dep.depends_on_epic_id} end)
            |> Enum.map(fn dep ->
              %{
                "epic" => Map.get(epic_id_to_number, dep.epic_id),
                "depends_on" => Map.get(epic_id_to_number, dep.depends_on_epic_id)
              }
            end)
        }

        {:ok, export}
    end
  end

  # ===================================================================
  # Private: Fresh Import Implementation
  # ===================================================================

  defp execute_fresh_import(
         tenant_id,
         project_id,
         epics_data,
         story_deps_data,
         epic_deps_data,
         opts
       ) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    multi =
      Multi.new()
      |> insert_epics(tenant_id, project_id, epics_data)
      |> insert_stories(tenant_id, project_id, epics_data)
      |> resolve_and_validate_story_deps(tenant_id, story_deps_data, epics_data)
      |> resolve_and_validate_epic_deps(tenant_id, epic_deps_data, epics_data)
      |> audit_import(tenant_id, project_id, actor_id, actor_label)
      |> EventGenerator.generate_events(:webhook_events, fn changes ->
        epic_count = count_created_epics(changes)
        story_count = count_created_stories(changes)

        %{
          tenant_id: tenant_id,
          event_type: "project.imported",
          project_id: project_id,
          payload: %{
            "event" => "project.imported",
            "project_id" => project_id,
            "epic_count" => epic_count,
            "story_count" => story_count,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, changes} ->
        summary = build_import_summary(changes)
        {:ok, summary}

      {:error, :cycle_check, message, _changes} ->
        {:error, :cycle_detected, message}

      {:error, step, reason, _changes} ->
        handle_import_error(step, reason)
    end
  end

  defp insert_epics(multi, tenant_id, project_id, epics_data) do
    epics_data
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {epic_data, index}, multi ->
      Multi.run(multi, {:epic, index}, fn _repo, _changes ->
        do_insert_epic(tenant_id, project_id, epic_data, index)
      end)
    end)
  end

  defp do_insert_epic(tenant_id, project_id, epic_data, index) do
    attrs = %{
      number: epic_data["number"],
      title: epic_data["title"],
      description: epic_data["description"],
      phase: epic_data["phase"],
      position: epic_data["position"] || index,
      metadata: epic_data["metadata"] || %{}
    }

    %Epic{tenant_id: tenant_id, project_id: project_id}
    |> Epic.create_changeset(attrs)
    |> AdminRepo.insert()
    |> case do
      {:ok, epic} -> {:ok, epic}
      {:error, cs} -> {:error, format_changeset_path_error(cs, "epics[#{index}]")}
    end
  end

  defp insert_stories(multi, tenant_id, project_id, epics_data) do
    story_steps = flatten_story_steps(epics_data)

    Enum.reduce(story_steps, multi, fn {epic_index, story_index, story_data}, multi ->
      Multi.run(multi, {:story, epic_index, story_index}, fn _repo, changes ->
        epic = Map.fetch!(changes, {:epic, epic_index})
        do_insert_story(tenant_id, project_id, epic.id, story_data, epic_index, story_index)
      end)
    end)
  end

  defp flatten_story_steps(epics_data) do
    Enum.flat_map(Enum.with_index(epics_data), fn {epic_data, epic_index} ->
      epic_data
      |> Map.get("stories", [])
      |> Enum.with_index()
      |> Enum.map(fn {story_data, story_index} -> {epic_index, story_index, story_data} end)
    end)
  end

  defp do_insert_story(tenant_id, project_id, epic_id, story_data, epic_index, story_index) do
    attrs = %{
      number: story_data["number"],
      title: story_data["title"],
      description: story_data["description"],
      acceptance_criteria: story_data["acceptance_criteria"],
      estimated_hours: story_data["estimated_hours"],
      metadata: story_data["metadata"] || %{}
    }

    %Story{tenant_id: tenant_id, project_id: project_id, epic_id: epic_id}
    |> Story.create_changeset(attrs)
    |> AdminRepo.insert()
    |> case do
      {:ok, story} ->
        {:ok, story}

      {:error, cs} ->
        {:error, format_changeset_path_error(cs, "epics[#{epic_index}].stories[#{story_index}]")}
    end
  end

  defp resolve_and_validate_story_deps(multi, tenant_id, story_deps_data, epics_data) do
    if Enum.empty?(story_deps_data) do
      # Still add the cycle check step but as a no-op pass
      Multi.run(multi, :cycle_check, fn _repo, _changes -> {:ok, :no_deps} end)
    else
      multi
      |> Multi.run(:resolve_story_deps, fn _repo, changes ->
        number_to_id = build_number_to_id_from_changes(changes, epics_data)
        resolve_story_dep_references(story_deps_data, number_to_id)
      end)
      |> Multi.run(:cycle_check, fn _repo, %{resolve_story_deps: resolved_deps} ->
        detect_story_cycles(resolved_deps)
      end)
      |> Multi.run(:insert_story_deps, fn _repo, %{resolve_story_deps: resolved_deps} ->
        insert_resolved_story_deps(tenant_id, resolved_deps)
      end)
    end
  end

  defp resolve_and_validate_epic_deps(multi, tenant_id, epic_deps_data, epics_data) do
    if Enum.empty?(epic_deps_data) do
      multi
    else
      multi
      |> Multi.run(:resolve_epic_deps, fn _repo, changes ->
        number_to_id = build_epic_number_to_id_from_changes(changes, epics_data)
        resolve_epic_dep_references(epic_deps_data, number_to_id)
      end)
      |> Multi.run(:epic_cycle_check, fn _repo, %{resolve_epic_deps: resolved_deps} ->
        detect_epic_cycles(resolved_deps)
      end)
      |> Multi.run(:insert_epic_deps, fn _repo, %{resolve_epic_deps: resolved_deps} ->
        insert_resolved_epic_deps(tenant_id, resolved_deps)
      end)
    end
  end

  defp audit_import(multi, tenant_id, project_id, actor_id, actor_label) do
    Audit.log_in_multi(multi, :audit, fn changes ->
      epic_count = count_created_epics(changes)
      story_count = count_created_stories(changes)

      %{
        tenant_id: tenant_id,
        entity_type: "project",
        entity_id: project_id,
        action: "imported",
        actor_type: "api_key",
        actor_id: actor_id,
        actor_label: actor_label,
        new_state: %{
          "epics_created" => epic_count,
          "stories_created" => story_count
        }
      }
    end)
  end

  # ===================================================================
  # Private: Merge Import Implementation
  # ===================================================================

  defp execute_merge_import(
         tenant_id,
         project_id,
         epics_data,
         story_deps_data,
         epic_deps_data,
         opts
       ) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    # Load existing data
    existing_epics = load_existing_epics(tenant_id, project_id)
    existing_stories = load_existing_stories(tenant_id, project_id)
    existing_story_deps = load_all_story_dependencies(tenant_id, project_id)

    epic_by_number = Map.new(existing_epics, &{&1.number, &1})
    story_by_number = Map.new(existing_stories, &{&1.number, &1})

    multi =
      Multi.new()
      |> merge_epics(tenant_id, project_id, epics_data, epic_by_number)
      |> merge_stories(tenant_id, project_id, epics_data, epic_by_number, story_by_number)
      |> merge_story_deps(
        tenant_id,
        project_id,
        story_deps_data,
        story_by_number,
        existing_story_deps,
        epics_data
      )
      |> merge_epic_deps(tenant_id, project_id, epic_deps_data, epics_data, epic_by_number)
      |> audit_merge_import(tenant_id, project_id, actor_id, actor_label)
      |> EventGenerator.generate_events(:webhook_events, fn changes ->
        {epics_created, _epics_updated} = count_merge_epics(changes)
        {stories_created, stories_updated} = count_merge_stories(changes)

        %{
          tenant_id: tenant_id,
          event_type: "project.imported",
          project_id: project_id,
          payload: %{
            "event" => "project.imported",
            "project_id" => project_id,
            "merge" => true,
            "epics_created" => epics_created,
            "stories_created" => stories_created,
            "stories_updated" => stories_updated,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, changes} ->
        # Compute orphaned stories
        import_story_numbers = extract_all_story_numbers(epics_data)

        orphaned =
          existing_stories
          |> Enum.reject(fn s -> s.number in import_story_numbers end)
          |> Enum.map(fn s -> %{"number" => s.number, "title" => s.title} end)

        summary = build_merge_summary(changes, orphaned, existing_story_deps)
        {:ok, summary}

      {:error, :merge_cycle_check, message, _changes} ->
        {:error, :cycle_detected, message}

      {:error, step, reason, _changes} ->
        handle_import_error(step, reason)
    end
  end

  defp merge_epics(multi, tenant_id, project_id, epics_data, epic_by_number) do
    epics_data
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {epic_data, index}, multi ->
      existing = Map.get(epic_by_number, epic_data["number"])

      Multi.run(multi, {:merge_epic, index}, fn _repo, _changes ->
        do_merge_epic(tenant_id, project_id, epic_data, existing, index)
      end)
    end)
  end

  defp do_merge_epic(tenant_id, project_id, epic_data, nil, index) do
    attrs = %{
      number: epic_data["number"],
      title: epic_data["title"],
      description: epic_data["description"],
      phase: epic_data["phase"],
      position: epic_data["position"] || index,
      metadata: epic_data["metadata"] || %{}
    }

    %Epic{tenant_id: tenant_id, project_id: project_id}
    |> Epic.create_changeset(attrs)
    |> AdminRepo.insert()
    |> case do
      {:ok, epic} -> {:ok, {:created, epic}}
      {:error, cs} -> {:error, format_changeset_path_error(cs, "epics[#{index}]")}
    end
  end

  defp do_merge_epic(_tenant_id, _project_id, epic_data, existing_epic, index) do
    attrs =
      %{}
      |> maybe_put("title", epic_data["title"])
      |> maybe_put("description", epic_data["description"])
      |> maybe_put("phase", epic_data["phase"])
      |> maybe_put("position", epic_data["position"])
      |> maybe_put("metadata", epic_data["metadata"])

    Epic.update_changeset(existing_epic, attrs)
    |> AdminRepo.update()
    |> case do
      {:ok, epic} -> {:ok, {:updated, epic}}
      {:error, cs} -> {:error, format_changeset_path_error(cs, "epics[#{index}]")}
    end
  end

  defp merge_stories(multi, tenant_id, project_id, epics_data, epic_by_number, story_by_number) do
    merge_story_steps = flatten_merge_story_steps(epics_data, story_by_number, epic_by_number)

    Enum.reduce(merge_story_steps, multi, fn step, multi ->
      ctx = Map.merge(step.ctx, %{tenant_id: tenant_id, project_id: project_id})

      Multi.run(multi, {:merge_story, step.epic_index, step.story_index}, fn _repo, changes ->
        do_merge_story(step.story_data, step.existing, changes, ctx)
      end)
    end)
  end

  defp flatten_merge_story_steps(epics_data, story_by_number, epic_by_number) do
    Enum.flat_map(Enum.with_index(epics_data), fn {epic_data, epic_index} ->
      epic_data
      |> Map.get("stories", [])
      |> Enum.with_index()
      |> Enum.map(fn {story_data, story_index} ->
        %{
          epic_index: epic_index,
          story_index: story_index,
          story_data: story_data,
          existing: Map.get(story_by_number, story_data["number"]),
          ctx: %{
            epic_index: epic_index,
            story_index: story_index,
            epic_by_number: epic_by_number,
            epic_number: epic_data["number"]
          }
        }
      end)
    end)
  end

  defp do_merge_story(story_data, nil, changes, ctx) do
    epic =
      resolve_epic_from_merge_changes(
        changes,
        ctx.epic_index,
        ctx.epic_by_number,
        ctx.epic_number
      )

    attrs = %{
      number: story_data["number"],
      title: story_data["title"],
      description: story_data["description"],
      acceptance_criteria: story_data["acceptance_criteria"],
      estimated_hours: story_data["estimated_hours"],
      metadata: story_data["metadata"] || %{}
    }

    %Story{tenant_id: ctx.tenant_id, project_id: ctx.project_id, epic_id: epic.id}
    |> Story.create_changeset(attrs)
    |> AdminRepo.insert()
    |> case do
      {:ok, story} ->
        {:ok, {:created, story}}

      {:error, cs} ->
        {:error,
         format_changeset_path_error(cs, "epics[#{ctx.epic_index}].stories[#{ctx.story_index}]")}
    end
  end

  defp do_merge_story(story_data, existing_story, _changes, ctx) do
    # AC-12.3.12: absent fields NOT nulled
    attrs =
      %{}
      |> maybe_put("title", story_data["title"])
      |> maybe_put("description", story_data["description"])
      |> maybe_put("acceptance_criteria", story_data["acceptance_criteria"])
      |> maybe_put("estimated_hours", story_data["estimated_hours"])
      |> maybe_put("metadata", story_data["metadata"])

    Story.update_changeset(existing_story, attrs)
    |> AdminRepo.update()
    |> case do
      {:ok, story} ->
        {:ok, {:updated, story}}

      {:error, cs} ->
        {:error,
         format_changeset_path_error(cs, "epics[#{ctx.epic_index}].stories[#{ctx.story_index}]")}
    end
  end

  defp merge_story_deps(
         multi,
         tenant_id,
         _project_id,
         story_deps_data,
         story_by_number,
         existing_deps,
         epics_data
       ) do
    multi
    |> Multi.run(:merge_resolve_deps, fn _repo, changes ->
      # Build number->ID map from both existing and newly created stories
      number_to_id =
        story_by_number
        |> Map.new(fn {number, story} -> {number, story.id} end)
        |> Map.merge(build_number_to_id_from_merge_changes(changes, epics_data))

      resolve_story_dep_references(story_deps_data, number_to_id)
    end)
    |> Multi.run(:merge_cycle_check, fn _repo, %{merge_resolve_deps: resolved_deps} ->
      # Combine existing deps with new deps for cycle detection
      existing_edges =
        Enum.map(existing_deps, fn dep -> {dep.story_id, dep.depends_on_story_id} end)

      new_edges =
        Enum.map(resolved_deps, fn %{story_id: sid, depends_on_story_id: did} -> {sid, did} end)

      all_edges = existing_edges ++ new_edges
      detect_cycle_in_edges(all_edges)
    end)
    |> Multi.run(:merge_insert_deps, fn _repo, %{merge_resolve_deps: resolved_deps} ->
      # Only insert deps that don't already exist
      existing_dep_set =
        MapSet.new(existing_deps, fn dep -> {dep.story_id, dep.depends_on_story_id} end)

      new_deps =
        Enum.reject(resolved_deps, fn dep ->
          MapSet.member?(existing_dep_set, {dep.story_id, dep.depends_on_story_id})
        end)

      insert_resolved_story_deps(tenant_id, new_deps)
    end)
  end

  defp merge_epic_deps(
         multi,
         _tenant_id,
         _project_id,
         epic_deps_data,
         _epics_data,
         _epic_by_number
       )
       when epic_deps_data == [] do
    multi
  end

  defp merge_epic_deps(multi, tenant_id, project_id, epic_deps_data, epics_data, epic_by_number) do
    multi
    |> Multi.run(:merge_resolve_epic_deps, fn _repo, changes ->
      number_to_id =
        epic_by_number
        |> Map.new(fn {number, epic} -> {number, epic.id} end)
        |> Map.merge(build_epic_number_to_id_from_merge_changes(changes, epics_data))

      resolve_epic_dep_references(epic_deps_data, number_to_id)
    end)
    |> Multi.run(:merge_insert_epic_deps, fn _repo, %{merge_resolve_epic_deps: resolved_deps} ->
      insert_new_epic_deps(tenant_id, project_id, resolved_deps)
    end)
  end

  defp insert_new_epic_deps(tenant_id, project_id, resolved_deps) do
    existing = load_all_epic_dependencies(tenant_id, project_id)

    existing_set =
      MapSet.new(existing, fn dep -> {dep.epic_id, dep.depends_on_epic_id} end)

    new_deps =
      Enum.reject(resolved_deps, fn dep ->
        MapSet.member?(existing_set, {dep.epic_id, dep.depends_on_epic_id})
      end)

    insert_resolved_epic_deps(tenant_id, new_deps)
  end

  defp audit_merge_import(multi, tenant_id, project_id, actor_id, actor_label) do
    Audit.log_in_multi(multi, :audit, fn changes ->
      {created, updated} = count_merge_stories(changes)

      %{
        tenant_id: tenant_id,
        entity_type: "project",
        entity_id: project_id,
        action: "merge_imported",
        actor_type: "api_key",
        actor_id: actor_id,
        actor_label: actor_label,
        new_state: %{
          "stories_created" => created,
          "stories_updated" => updated
        }
      }
    end)
  end

  # ===================================================================
  # Private: Validation
  # ===================================================================

  defp validate_payload_structure(epics_data) when is_list(epics_data) do
    case validate_epics_list(epics_data) do
      :ok -> :ok
      {:error, msg} -> {:error, :validation, msg}
    end
  end

  defp validate_payload_structure(_), do: {:error, :validation, "epics must be an array"}

  defp validate_epics_list(epics_data) do
    epics_data
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {epic, index}, :ok ->
      case validate_single_epic(epic, index) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_single_epic(epic, index) do
    cond do
      not is_map(epic) ->
        {:error, "epics[#{index}]: must be an object"}

      is_nil(epic["number"]) ->
        {:error, "epics[#{index}].number: is required"}

      is_nil(epic["title"]) or epic["title"] == "" ->
        {:error, "epics[#{index}].title: can't be blank"}

      true ->
        validate_stories_list(Map.get(epic, "stories", []), index)
    end
  end

  defp validate_stories_list(stories, epic_index) when is_list(stories) do
    stories
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {story, story_index}, :ok ->
      cond do
        not is_map(story) ->
          {:halt, {:error, "epics[#{epic_index}].stories[#{story_index}]: must be an object"}}

        is_nil(story["number"]) ->
          {:halt, {:error, "epics[#{epic_index}].stories[#{story_index}].number: is required"}}

        is_nil(story["title"]) or story["title"] == "" ->
          {:halt, {:error, "epics[#{epic_index}].stories[#{story_index}].title: can't be blank"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_stories_list(_, epic_index),
    do: {:error, "epics[#{epic_index}].stories: must be an array"}

  defp validate_no_duplicate_numbers(epics_data) do
    # Check duplicate epic numbers
    epic_numbers = Enum.map(epics_data, & &1["number"])

    case find_duplicate(epic_numbers) do
      nil ->
        # Check duplicate story numbers across all epics
        story_numbers =
          Enum.flat_map(epics_data, fn epic ->
            Enum.map(Map.get(epic, "stories", []), & &1["number"])
          end)

        case find_duplicate(story_numbers) do
          nil -> :ok
          dup -> {:error, :validation, "Duplicate story number: #{dup}"}
        end

      dup ->
        {:error, :validation, "Duplicate epic number: #{dup}"}
    end
  end

  defp find_duplicate(list) do
    list
    |> Enum.reduce_while(%{}, fn item, seen ->
      if Map.has_key?(seen, item) do
        {:halt, item}
      else
        {:cont, Map.put(seen, item, true)}
      end
    end)
    |> case do
      item when is_map(item) -> nil
      dup -> dup
    end
  end

  defp check_no_existing_conflicts(tenant_id, project_id, epics_data) do
    # Get all story numbers from the import payload
    import_story_numbers =
      Enum.flat_map(epics_data, fn epic ->
        Enum.map(Map.get(epic, "stories", []), &to_string(&1["number"]))
      end)

    import_epic_numbers = Enum.map(epics_data, & &1["number"])

    # Check for existing stories with matching numbers
    existing_story_numbers =
      Story
      |> where([s], s.tenant_id == ^tenant_id and s.project_id == ^project_id)
      |> where([s], s.number in ^import_story_numbers)
      |> select([s], s.number)
      |> AdminRepo.all()

    # Check for existing epics with matching numbers
    existing_epic_numbers =
      Epic
      |> where([e], e.tenant_id == ^tenant_id and e.project_id == ^project_id)
      |> where([e], e.number in ^import_epic_numbers)
      |> select([e], e.number)
      |> AdminRepo.all()

    duplicate_stories = existing_story_numbers
    duplicate_epics = existing_epic_numbers

    if Enum.empty?(duplicate_stories) and Enum.empty?(duplicate_epics) do
      :ok
    else
      {:error, :conflict,
       %{
         duplicate_epic_numbers: duplicate_epics,
         duplicate_story_numbers: duplicate_stories
       }}
    end
  end

  # ===================================================================
  # Private: Dependency Resolution
  # ===================================================================

  defp build_number_to_id_from_changes(changes, epics_data) do
    epics_data
    |> Enum.with_index()
    |> Enum.flat_map(fn {epic_data, epic_index} ->
      stories_data = Map.get(epic_data, "stories", [])

      stories_data
      |> Enum.with_index()
      |> Enum.map(fn {_story_data, story_index} ->
        story = Map.fetch!(changes, {:story, epic_index, story_index})
        {story.number, story.id}
      end)
    end)
    |> Map.new()
  end

  defp build_number_to_id_from_merge_changes(changes, epics_data) do
    epics_data
    |> Enum.with_index()
    |> Enum.flat_map(fn {epic_data, epic_index} ->
      stories_data = Map.get(epic_data, "stories", [])

      stories_data
      |> Enum.with_index()
      |> Enum.filter(fn {_story_data, story_index} ->
        Map.has_key?(changes, {:merge_story, epic_index, story_index})
      end)
      |> Enum.map(fn {_story_data, story_index} ->
        {_status, story} = Map.fetch!(changes, {:merge_story, epic_index, story_index})
        {story.number, story.id}
      end)
    end)
    |> Map.new()
  end

  defp build_epic_number_to_id_from_changes(changes, epics_data) do
    epics_data
    |> Enum.with_index()
    |> Enum.map(fn {_epic_data, index} ->
      epic = Map.fetch!(changes, {:epic, index})
      {epic.number, epic.id}
    end)
    |> Map.new()
  end

  defp build_epic_number_to_id_from_merge_changes(changes, epics_data) do
    epics_data
    |> Enum.with_index()
    |> Enum.filter(fn {_epic_data, index} ->
      Map.has_key?(changes, {:merge_epic, index})
    end)
    |> Enum.map(fn {_epic_data, index} ->
      {_status, epic} = Map.fetch!(changes, {:merge_epic, index})
      {epic.number, epic.id}
    end)
    |> Map.new()
  end

  defp resolve_story_dep_references(deps_data, number_to_id) do
    deps_data
    |> Enum.reduce_while([], fn dep, acc ->
      story_number = to_string(dep["story"] || dep["story_number"])
      depends_on_number = to_string(dep["depends_on"] || dep["depends_on_story"])

      story_id = Map.get(number_to_id, story_number)
      depends_on_id = Map.get(number_to_id, depends_on_number)

      cond do
        is_nil(story_id) ->
          {:halt,
           {:error,
            "Unresolved dependency reference: story '#{story_number}' not found in import"}}

        is_nil(depends_on_id) ->
          {:halt,
           {:error,
            "Unresolved dependency reference: story '#{depends_on_number}' not found in import"}}

        true ->
          {:cont, [%{story_id: story_id, depends_on_story_id: depends_on_id} | acc]}
      end
    end)
    |> case do
      {:error, msg} -> {:error, msg}
      resolved when is_list(resolved) -> {:ok, Enum.reverse(resolved)}
    end
  end

  defp resolve_epic_dep_references(deps_data, number_to_id) do
    deps_data
    |> Enum.reduce_while([], fn dep, acc ->
      epic_number = dep["epic"] || dep["epic_number"]
      depends_on_number = dep["depends_on"] || dep["depends_on_epic"]

      epic_id = Map.get(number_to_id, epic_number)
      depends_on_id = Map.get(number_to_id, depends_on_number)

      cond do
        is_nil(epic_id) ->
          {:halt,
           {:error, "Unresolved dependency reference: epic '#{epic_number}' not found in import"}}

        is_nil(depends_on_id) ->
          {:halt,
           {:error,
            "Unresolved dependency reference: epic '#{depends_on_number}' not found in import"}}

        true ->
          {:cont, [%{epic_id: epic_id, depends_on_epic_id: depends_on_id} | acc]}
      end
    end)
    |> case do
      {:error, msg} -> {:error, msg}
      resolved when is_list(resolved) -> {:ok, Enum.reverse(resolved)}
    end
  end

  # ===================================================================
  # Private: Cycle Detection
  # ===================================================================

  defp detect_story_cycles(resolved_deps) do
    edges = Enum.map(resolved_deps, fn %{story_id: s, depends_on_story_id: d} -> {s, d} end)
    detect_cycle_in_edges(edges)
  end

  defp detect_epic_cycles(resolved_deps) do
    edges = Enum.map(resolved_deps, fn %{epic_id: e, depends_on_epic_id: d} -> {e, d} end)
    detect_cycle_in_edges(edges)
  end

  defp detect_cycle_in_edges(edges) do
    # Build adjacency list
    adjacency =
      Enum.reduce(edges, %{}, fn {from, to}, acc ->
        Map.update(acc, from, [to], &[to | &1])
      end)

    all_nodes =
      edges
      |> Enum.flat_map(fn {from, to} -> [from, to] end)
      |> Enum.uniq()

    case find_cycle_dfs(adjacency, all_nodes) do
      nil -> {:ok, :no_cycles}
      cycle_path -> {:error, "Cycle detected: #{Enum.join(cycle_path, " -> ")}"}
    end
  end

  defp find_cycle_dfs(adjacency, nodes) do
    Enum.reduce_while(nodes, MapSet.new(), fn node, visited ->
      explore_node(adjacency, node, visited)
    end)
    |> case do
      {:found, path} -> path
      %MapSet{} -> nil
    end
  end

  defp explore_node(adjacency, node, visited) do
    if MapSet.member?(visited, node) do
      {:cont, visited}
    else
      case dfs_visit(adjacency, node, visited, MapSet.new(), []) do
        {:cycle, path} -> {:halt, {:found, path}}
        {:ok, updated_visited} -> {:cont, updated_visited}
      end
    end
  end

  defp dfs_visit(adjacency, node, visited, rec_stack, path) do
    visited = MapSet.put(visited, node)
    rec_stack = MapSet.put(rec_stack, node)
    path = path ++ [node]

    adjacency
    |> Map.get(node, [])
    |> Enum.reduce_while({:ok, visited}, fn neighbor, {:ok, vis} ->
      visit_neighbor(adjacency, neighbor, vis, rec_stack, path)
    end)
  end

  defp visit_neighbor(adjacency, neighbor, visited, rec_stack, path) do
    cond do
      MapSet.member?(rec_stack, neighbor) ->
        {:halt, {:cycle, path ++ [neighbor]}}

      not MapSet.member?(visited, neighbor) ->
        case dfs_visit(adjacency, neighbor, visited, rec_stack, path) do
          {:cycle, _} = cycle -> {:halt, cycle}
          {:ok, vis2} -> {:cont, {:ok, vis2}}
        end

      true ->
        {:cont, {:ok, visited}}
    end
  end

  # ===================================================================
  # Private: Dependency Insertion
  # ===================================================================

  defp insert_resolved_story_deps(tenant_id, resolved_deps) do
    results =
      Enum.map(resolved_deps, fn dep ->
        changeset =
          %StoryDependency{
            tenant_id: tenant_id,
            story_id: dep.story_id,
            depends_on_story_id: dep.depends_on_story_id
          }
          |> StoryDependency.create_changeset()

        AdminRepo.insert(changeset)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, dep} -> dep end)}
    else
      {:error, hd(errors) |> elem(1)}
    end
  end

  defp insert_resolved_epic_deps(tenant_id, resolved_deps) do
    results =
      Enum.map(resolved_deps, fn dep ->
        changeset =
          %EpicDependency{
            tenant_id: tenant_id,
            epic_id: dep.epic_id,
            depends_on_epic_id: dep.depends_on_epic_id
          }
          |> EpicDependency.create_changeset()

        AdminRepo.insert(changeset)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, dep} -> dep end)}
    else
      {:error, hd(errors) |> elem(1)}
    end
  end

  # ===================================================================
  # Private: Export Helpers
  # ===================================================================

  defp load_epics_with_stories(tenant_id, project_id) do
    stories_query = from(s in Story, order_by: [asc: s.sort_key])

    Epic
    |> where([e], e.tenant_id == ^tenant_id and e.project_id == ^project_id)
    |> order_by([e], asc: e.number)
    |> preload(stories: ^stories_query)
    |> AdminRepo.all()
  end

  defp load_all_story_dependencies(tenant_id, project_id) do
    story_ids_query =
      from(s in Story,
        where: s.tenant_id == ^tenant_id and s.project_id == ^project_id,
        select: s.id
      )

    story_ids = AdminRepo.all(story_ids_query)

    StoryDependency
    |> where([d], d.tenant_id == ^tenant_id and d.story_id in ^story_ids)
    |> order_by([d], asc: d.inserted_at)
    |> AdminRepo.all()
  end

  defp load_all_epic_dependencies(tenant_id, nil) do
    EpicDependency
    |> where([d], d.tenant_id == ^tenant_id)
    |> AdminRepo.all()
  end

  defp load_all_epic_dependencies(tenant_id, project_id) do
    epic_ids_query =
      from(e in Epic,
        where: e.tenant_id == ^tenant_id and e.project_id == ^project_id,
        select: e.id
      )

    epic_ids = AdminRepo.all(epic_ids_query)

    EpicDependency
    |> where([d], d.tenant_id == ^tenant_id and d.epic_id in ^epic_ids)
    |> order_by([d], asc: d.inserted_at)
    |> AdminRepo.all()
  end

  defp build_story_id_map(epics) do
    Enum.flat_map(epics, fn epic ->
      Enum.map(epic.stories, fn story -> {story.id, story.number} end)
    end)
    |> Map.new()
  end

  defp build_epic_id_map(epics) do
    Map.new(epics, fn epic -> {epic.id, epic.number} end)
  end

  defp serialize_epic(epic) do
    %{
      "number" => epic.number,
      "title" => epic.title,
      "description" => epic.description,
      "phase" => epic.phase,
      "position" => epic.position,
      "metadata" => epic.metadata,
      "stories" => Enum.map(epic.stories, &serialize_story/1)
    }
  end

  defp serialize_story(story) do
    %{
      "number" => story.number,
      "title" => story.title,
      "description" => story.description,
      "acceptance_criteria" => story.acceptance_criteria,
      "estimated_hours" => decimal_to_number(story.estimated_hours),
      "agent_status" => to_string(story.agent_status),
      "verified_status" => to_string(story.verified_status),
      "assigned_agent_id" => story.assigned_agent_id,
      "assigned_at" => maybe_to_iso8601(story.assigned_at),
      "reported_done_at" => maybe_to_iso8601(story.reported_done_at),
      "verified_at" => maybe_to_iso8601(story.verified_at),
      "rejected_at" => maybe_to_iso8601(story.rejected_at),
      "rejection_reason" => story.rejection_reason,
      "metadata" => story.metadata
    }
  end

  defp maybe_to_iso8601(nil), do: nil
  defp maybe_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp decimal_to_number(nil), do: nil
  defp decimal_to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_number(val) when is_number(val), do: val

  # ===================================================================
  # Private: Merge Helpers
  # ===================================================================

  defp load_existing_epics(tenant_id, project_id) do
    Epic
    |> where([e], e.tenant_id == ^tenant_id and e.project_id == ^project_id)
    |> AdminRepo.all()
  end

  defp load_existing_stories(tenant_id, project_id) do
    Story
    |> where([s], s.tenant_id == ^tenant_id and s.project_id == ^project_id)
    |> AdminRepo.all()
  end

  defp resolve_epic_from_merge_changes(changes, epic_index, epic_by_number, epic_number) do
    case Map.get(changes, {:merge_epic, epic_index}) do
      {_status, epic} -> epic
      nil -> Map.get(epic_by_number, epic_number)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp extract_all_story_numbers(epics_data) do
    Enum.flat_map(epics_data, fn epic ->
      Enum.map(Map.get(epic, "stories", []), fn s -> to_string(s["number"]) end)
    end)
  end

  # ===================================================================
  # Private: Summary Builders
  # ===================================================================

  defp build_import_summary(changes) do
    epic_count = count_created_epics(changes)
    story_count = count_created_stories(changes)

    dep_count =
      case Map.get(changes, :insert_story_deps) do
        nil -> 0
        deps when is_list(deps) -> length(deps)
        _ -> 0
      end

    epic_dep_count =
      case Map.get(changes, :insert_epic_deps) do
        nil -> 0
        deps when is_list(deps) -> length(deps)
        _ -> 0
      end

    %{
      epics_created: epic_count,
      stories_created: story_count,
      dependencies_created: dep_count + epic_dep_count
    }
  end

  defp build_merge_summary(changes, orphaned, existing_story_deps) do
    {epics_created, epics_updated} = count_merge_epics(changes)
    {stories_created, stories_updated} = count_merge_stories(changes)

    deps_created =
      case Map.get(changes, :merge_insert_deps) do
        nil -> 0
        deps when is_list(deps) -> length(deps)
        _ -> 0
      end

    deps_existing = length(existing_story_deps)

    %{
      epics_created: epics_created,
      epics_updated: epics_updated,
      stories_created: stories_created,
      stories_updated: stories_updated,
      stories_orphaned: orphaned,
      dependencies_created: deps_created,
      dependencies_existing: deps_existing
    }
  end

  defp count_created_epics(changes) do
    changes
    |> Enum.count(fn
      {{:epic, _index}, %Epic{}} -> true
      _ -> false
    end)
  end

  defp count_created_stories(changes) do
    changes
    |> Enum.count(fn
      {{:story, _ei, _si}, %Story{}} -> true
      _ -> false
    end)
  end

  defp count_merge_epics(changes) do
    changes
    |> Enum.reduce({0, 0}, fn
      {{:merge_epic, _}, {:created, _}}, {c, u} -> {c + 1, u}
      {{:merge_epic, _}, {:updated, _}}, {c, u} -> {c, u + 1}
      _, acc -> acc
    end)
  end

  defp count_merge_stories(changes) do
    changes
    |> Enum.reduce({0, 0}, fn
      {{:merge_story, _, _}, {:created, _}}, {c, u} -> {c + 1, u}
      {{:merge_story, _, _}, {:updated, _}}, {c, u} -> {c, u + 1}
      _, acc -> acc
    end)
  end

  # ===================================================================
  # Private: Error Handling
  # ===================================================================

  defp format_changeset_path_error(changeset, path) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    error_details =
      Enum.map_join(errors, "; ", fn {field, messages} ->
        "#{path}.#{field}: #{Enum.join(messages, ", ")}"
      end)

    error_details
  end

  defp handle_import_error(_step, reason) when is_binary(reason) do
    {:error, :validation, reason}
  end

  defp handle_import_error(_step, %Ecto.Changeset{} = changeset) do
    {:error, :validation, format_changeset_path_error(changeset, "")}
  end

  defp handle_import_error(_step, reason) do
    {:error, :validation, inspect(reason)}
  end
end
