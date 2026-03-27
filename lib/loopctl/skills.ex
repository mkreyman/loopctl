defmodule Loopctl.Skills do
  @moduledoc """
  Context module for skill versioning and management.

  Skills are versioned prompts and instructions used by orchestrators and
  agents. All operations are tenant-scoped via `tenant_id` with audit
  logging via `Ecto.Multi`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Skills.Skill
  alias Loopctl.Skills.SkillResult
  alias Loopctl.Skills.SkillVersion

  # ===================================================================
  # Skill CRUD
  # ===================================================================

  @doc """
  Creates a new skill with an initial version (v1).

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with `name`, `description`, `prompt_text`, optional `project_id`
  - `opts` -- keyword list with `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %{skill: %Skill{}, version: %SkillVersion{}}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec create_skill(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{skill: Skill.t(), version: SkillVersion.t()}}
          | {:error, Ecto.Changeset.t()}
  def create_skill(tenant_id, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label, "user")
    actor_type = Keyword.get(opts, :actor_type, "api_key")
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    skill_changeset =
      %Skill{tenant_id: tenant_id, project_id: project_id}
      |> Skill.create_changeset(attrs)

    multi =
      Multi.new()
      |> Multi.insert(:skill, skill_changeset)
      |> Multi.run(:version, fn _repo, %{skill: skill} ->
        version_changeset =
          %SkillVersion{
            tenant_id: tenant_id,
            skill_id: skill.id,
            version: 1
          }
          |> SkillVersion.create_changeset(%{
            prompt_text: Map.get(attrs, "prompt_text") || Map.get(attrs, :prompt_text) || "",
            created_by: actor_label
          })

        AdminRepo.insert(version_changeset)
      end)
      |> Audit.log_in_multi(:audit, fn %{skill: skill} ->
        %{
          tenant_id: tenant_id,
          entity_type: "skill",
          entity_id: skill.id,
          action: "created",
          actor_type: actor_type,
          actor_id: actor_id,
          actor_label: actor_label,
          new_state: %{
            "name" => skill.name,
            "status" => to_string(skill.status),
            "current_version" => 1
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{skill: skill, version: version}} ->
        {:ok, %{skill: skill, version: version}}

      {:error, :skill, changeset, _} ->
        {:error, changeset}

      {:error, :version, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Lists skills for a tenant with optional filters and pagination.

  ## Options

  - `:project_id` -- filter by project
  - `:status` -- filter by status
  - `:name_pattern` -- filter by name pattern (ILIKE)
  - `:page` -- page number (default 1)
  - `:page_size` -- skills per page (default 20, max 100)
  """
  @spec list_skills(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [Skill.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_skills(tenant_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      Skill
      |> where([s], s.tenant_id == ^tenant_id)
      |> apply_skill_filters(opts)

    total = AdminRepo.aggregate(base_query, :count, :id)

    skills =
      base_query
      |> order_by([s], asc: s.name)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: skills, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Gets a skill by ID, scoped to a tenant.
  """
  @spec get_skill(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Skill.t()} | {:error, :not_found}
  def get_skill(tenant_id, skill_id) do
    case AdminRepo.get_by(Skill, id: skill_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      skill -> {:ok, skill}
    end
  end

  @doc """
  Gets a skill by name, scoped to a tenant.
  """
  @spec get_skill_by_name(Ecto.UUID.t(), String.t()) ::
          {:ok, Skill.t()} | {:error, :not_found}
  def get_skill_by_name(tenant_id, name) do
    case AdminRepo.get_by(Skill, name: name, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      skill -> {:ok, skill}
    end
  end

  @doc """
  Updates a skill's metadata (NOT prompt text -- that requires a new version).
  """
  @spec update_skill(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Skill.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_skill(tenant_id, skill_id, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    actor_type = Keyword.get(opts, :actor_type, "api_key")

    with {:ok, skill} <- get_skill(tenant_id, skill_id) do
      changeset = Skill.update_changeset(skill, attrs)
      old_state = %{"description" => skill.description, "status" => to_string(skill.status)}

      multi =
        Multi.new()
        |> Multi.update(:skill, changeset)
        |> Audit.log_in_multi(:audit, fn %{skill: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "skill",
            entity_id: updated.id,
            action: "updated",
            actor_type: actor_type,
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: old_state,
            new_state: %{
              "description" => updated.description,
              "status" => to_string(updated.status)
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{skill: skill}} -> {:ok, skill}
        {:error, :skill, changeset, _} -> {:error, changeset}
      end
    end
  end

  @doc """
  Archives a skill (sets status to :archived).
  """
  @spec archive_skill(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Skill.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def archive_skill(tenant_id, skill_id, opts \\ []) do
    update_skill(tenant_id, skill_id, %{"status" => "archived"}, opts)
  end

  # ===================================================================
  # Skill Versions
  # ===================================================================

  @doc """
  Creates a new version for an existing skill.

  Auto-increments the version number and updates the skill's `current_version`.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `skill_id` -- the skill UUID
  - `attrs` -- map with `prompt_text`, `changelog`, optional `created_by`
  - `opts` -- keyword list with `:actor_id`, `:actor_label`
  """
  @spec create_version(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{skill: Skill.t(), version: SkillVersion.t()}}
          | {:error, :not_found | Ecto.Changeset.t()}
  def create_version(tenant_id, skill_id, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label, "user")
    actor_type = Keyword.get(opts, :actor_type, "api_key")

    with {:ok, skill} <- get_skill(tenant_id, skill_id) do
      next_version = skill.current_version + 1

      version_changeset =
        %SkillVersion{
          tenant_id: tenant_id,
          skill_id: skill_id,
          version: next_version
        }
        |> SkillVersion.create_changeset(
          Map.put(attrs, "created_by", Map.get(attrs, "created_by", actor_label))
        )

      skill_changeset =
        skill
        |> Ecto.Changeset.change(%{current_version: next_version})

      multi =
        Multi.new()
        |> Multi.insert(:version, version_changeset)
        |> Multi.update(:skill, skill_changeset)
        |> Audit.log_in_multi(:audit, fn %{version: ver} ->
          %{
            tenant_id: tenant_id,
            entity_type: "skill_version",
            entity_id: ver.id,
            action: "created",
            actor_type: actor_type,
            actor_id: actor_id,
            actor_label: actor_label,
            new_state: %{
              "skill_id" => skill_id,
              "version" => next_version,
              "changelog" => ver.changelog
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{skill: updated_skill, version: version}} ->
          {:ok, %{skill: updated_skill, version: version}}

        {:error, :version, changeset, _} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Lists all versions for a skill, ordered by version number.
  """
  @spec list_versions(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, [SkillVersion.t()]} | {:error, :not_found}
  def list_versions(tenant_id, skill_id, _opts \\ []) do
    with {:ok, _skill} <- get_skill(tenant_id, skill_id) do
      versions =
        SkillVersion
        |> where([sv], sv.skill_id == ^skill_id and sv.tenant_id == ^tenant_id)
        |> order_by([sv], asc: sv.version)
        |> AdminRepo.all()

      {:ok, versions}
    end
  end

  @doc """
  Gets a specific version for a skill.
  """
  @spec get_version(Ecto.UUID.t(), Ecto.UUID.t(), integer()) ::
          {:ok, SkillVersion.t()} | {:error, :not_found}
  def get_version(tenant_id, skill_id, version_number) do
    case AdminRepo.get_by(SkillVersion,
           skill_id: skill_id,
           tenant_id: tenant_id,
           version: version_number
         ) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  # ===================================================================
  # Skill Results (Performance Tracking)
  # ===================================================================

  @doc """
  Records a skill result linking a verification to a skill version.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with `skill_version_id`, `verification_result_id`, `story_id`, `metrics`
  """
  @spec create_skill_result(Ecto.UUID.t(), map()) ::
          {:ok, SkillResult.t()} | {:error, Ecto.Changeset.t()}
  def create_skill_result(tenant_id, attrs) do
    skill_version_id =
      Map.get(attrs, "skill_version_id") || Map.get(attrs, :skill_version_id)

    verification_result_id =
      Map.get(attrs, "verification_result_id") || Map.get(attrs, :verification_result_id)

    story_id = Map.get(attrs, "story_id") || Map.get(attrs, :story_id)

    changeset =
      %SkillResult{
        tenant_id: tenant_id,
        skill_version_id: skill_version_id,
        verification_result_id: verification_result_id,
        story_id: story_id
      }
      |> SkillResult.create_changeset(attrs)

    AdminRepo.insert(changeset)
  end

  @doc """
  Returns aggregate performance stats for a skill across all versions.

  Groups by version and computes pass/fail/partial counts plus
  average metrics from the metrics JSONB.
  """
  @spec skill_stats(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, list(map())} | {:error, :not_found}
  def skill_stats(tenant_id, skill_id) do
    with {:ok, _skill} <- get_skill(tenant_id, skill_id) do
      stats =
        SkillResult
        |> join(:inner, [sr], sv in SkillVersion, on: sr.skill_version_id == sv.id)
        |> join(:inner, [sr, _sv], vr in Loopctl.Artifacts.VerificationResult,
          on: sr.verification_result_id == vr.id
        )
        |> where([sr, sv, _vr], sv.skill_id == ^skill_id and sr.tenant_id == ^tenant_id)
        |> group_by([sr, sv, _vr], sv.version)
        |> select([sr, sv, vr], %{
          version: sv.version,
          total_results: count(sr.id),
          pass_count: count(fragment("CASE WHEN ? = 'pass' THEN 1 END", vr.result)),
          fail_count: count(fragment("CASE WHEN ? = 'fail' THEN 1 END", vr.result)),
          partial_count: count(fragment("CASE WHEN ? = 'partial' THEN 1 END", vr.result))
        })
        |> order_by([_sr, sv, _vr], asc: sv.version)
        |> AdminRepo.all()

      {:ok, stats}
    end
  end

  @doc """
  Lists individual results for a specific skill version.
  """
  @spec list_version_results(Ecto.UUID.t(), Ecto.UUID.t(), integer(), keyword()) ::
          {:ok, [SkillResult.t()]} | {:error, :not_found}
  def list_version_results(tenant_id, skill_id, version_number, _opts \\ []) do
    with {:ok, version} <- get_version(tenant_id, skill_id, version_number) do
      results =
        SkillResult
        |> where(
          [sr],
          sr.skill_version_id == ^version.id and sr.tenant_id == ^tenant_id
        )
        |> order_by([sr], desc: sr.inserted_at)
        |> AdminRepo.all()

      {:ok, results}
    end
  end

  # ===================================================================
  # Skill Import
  # ===================================================================

  @doc """
  Bulk imports skills from an array of skill objects.

  Implements create-or-update (idempotent) logic: if a skill with the
  same name exists within the tenant, it creates a new version instead
  of a new skill.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `skills_data` -- list of maps with `name`, `prompt_text`, optional `description`, `project_id`
  - `opts` -- keyword list with `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, summary}` with counts of created, updated, and errored skills
  """
  @spec import_skills(Ecto.UUID.t(), [map()], keyword()) :: {:ok, map()}
  def import_skills(tenant_id, skills_data, opts \\ []) when is_list(skills_data) do
    results =
      Enum.map(skills_data, fn skill_data ->
        import_single_skill(tenant_id, skill_data, opts)
      end)

    summary = %{
      "total" => length(results),
      "created" => Enum.count(results, &(&1 == :created)),
      "updated" => Enum.count(results, &(&1 == :updated)),
      "errored" => Enum.count(results, &(&1 == :errored))
    }

    {:ok, summary}
  end

  defp import_single_skill(tenant_id, skill_data, opts) do
    name = Map.get(skill_data, "name") || Map.get(skill_data, :name)

    case get_skill_by_name(tenant_id, name) do
      {:ok, existing_skill} ->
        case create_version(tenant_id, existing_skill.id, skill_data, opts) do
          {:ok, _} -> :updated
          {:error, _} -> :errored
        end

      {:error, :not_found} ->
        case create_skill(tenant_id, skill_data, opts) do
          {:ok, _} -> :created
          {:error, _} -> :errored
        end
    end
  end

  # --- Private helpers ---

  defp apply_skill_filters(query, opts) do
    query
    |> filter_project_id(Keyword.get(opts, :project_id))
    |> filter_status(Keyword.get(opts, :status))
    |> filter_name_pattern(Keyword.get(opts, :name_pattern))
  end

  defp filter_project_id(query, nil), do: query
  defp filter_project_id(query, id), do: where(query, [s], s.project_id == ^id)

  defp filter_status(query, nil), do: query

  defp filter_status(query, status) when is_binary(status) do
    where(query, [s], s.status == ^status)
  end

  defp filter_status(query, status) when is_atom(status) do
    where(query, [s], s.status == ^status)
  end

  defp filter_name_pattern(query, nil), do: query

  defp filter_name_pattern(query, pattern) do
    like_pattern = "%#{pattern}%"
    where(query, [s], ilike(s.name, ^like_pattern))
  end
end
