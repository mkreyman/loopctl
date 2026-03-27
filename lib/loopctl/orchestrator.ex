defmodule Loopctl.Orchestrator do
  @moduledoc """
  Context module for orchestrator state management.

  Provides functions to save and restore orchestrator state with
  optimistic locking. State is keyed by `(project_id, state_key)`,
  allowing multiple named state slots per project.

  All mutations include audit logging via `Ecto.Multi`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Orchestrator.OrchestratorState
  alias Loopctl.Projects.Project

  @doc """
  Saves (upserts) orchestrator state for a project with optimistic locking.

  When no state exists for the given `(project_id, state_key)`, a new record
  is created with `version=1`. The request must include `version=0` (or omit it).

  When state already exists, the update succeeds only if the provided version
  matches the current version in the database. The version is then incremented
  by 1.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `project_id` -- the project UUID
  - `attrs` -- map with `:state_key`, `:state_data`, and `:version`
  - `opts` -- keyword list with `:actor_id` and `:actor_label`

  ## Returns

  - `{:ok, %OrchestratorState{}}` on success
  - `{:error, :not_found}` if the project doesn't exist in this tenant
  - `{:error, :version_conflict}` if the version doesn't match
  - `{:error, changeset}` on validation failure
  """
  @spec save_state(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, OrchestratorState.t()}
          | {:error, :not_found | :version_conflict | Ecto.Changeset.t()}
  def save_state(tenant_id, project_id, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    state_key = Map.get(attrs, :state_key) || Map.get(attrs, "state_key")
    expected_version = Map.get(attrs, :version) || Map.get(attrs, "version") || 0

    with {:ok, _} <- validate_state_key(state_key, tenant_id, project_id, attrs),
         {:ok, _project} <- get_project(tenant_id, project_id) do
      existing = get_existing_state(tenant_id, project_id, state_key)

      resolve_save(
        existing,
        expected_version,
        tenant_id,
        project_id,
        attrs,
        actor_id,
        actor_label
      )
    end
  end

  @doc """
  Gets orchestrator state for a project, optionally filtered by state_key.

  When `state_key` is not provided, defaults to `"main"`.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `project_id` -- the project UUID
  - `state_key` -- optional state key (default: `"main"`)

  ## Returns

  - `{:ok, %OrchestratorState{}}` if found
  - `{:error, :not_found}` if not found or project doesn't exist in this tenant
  """
  @spec get_state(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, OrchestratorState.t()} | {:error, :not_found}
  def get_state(tenant_id, project_id, state_key \\ "main") do
    with {:ok, _project} <- get_project(tenant_id, project_id) do
      case AdminRepo.get_by(OrchestratorState,
             tenant_id: tenant_id,
             project_id: project_id,
             state_key: state_key
           ) do
        nil -> {:error, :not_found}
        state -> {:ok, state}
      end
    end
  end

  @doc """
  Returns version history for orchestrator state by querying the audit log.

  History entries are derived from audit_log entries with
  `entity_type="orchestrator_state"` and `action="saved"`.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `project_id` -- the project UUID
  - `opts` -- keyword list with:
    - `:state_key` -- filter by state key (default: `"main"`)
    - `:page` -- page number (default 1)
    - `:page_size` -- entries per page (default 25, max 100)

  ## Returns

  `{:ok, %{data: [map()], total: integer, page: integer, page_size: integer}}`
  """
  @spec get_state_history(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
          | {:error, :not_found}
  def get_state_history(tenant_id, project_id, opts \\ []) do
    with {:ok, _project} <- get_project(tenant_id, project_id) do
      state_key = Keyword.get(opts, :state_key, "main")
      page = max(Keyword.get(opts, :page, 1), 1)
      page_size = opts |> Keyword.get(:page_size, 25) |> max(1) |> min(100)
      offset = (page - 1) * page_size

      base_query =
        Loopctl.Audit.AuditLog
        |> where([a], a.tenant_id == ^tenant_id)
        |> where([a], a.entity_type == "orchestrator_state")
        |> where([a], a.action == "saved")
        |> where(
          [a],
          fragment("?->>'state_key' = ?", a.new_state, ^state_key)
        )
        |> where(
          [a],
          fragment("?->>'project_id' = ?", a.new_state, ^project_id)
        )

      total = AdminRepo.aggregate(base_query, :count, :id)

      entries =
        base_query
        |> order_by([a], desc: a.inserted_at)
        |> limit(^page_size)
        |> offset(^offset)
        |> AdminRepo.all()

      history =
        Enum.map(entries, fn entry ->
          new_state = entry.new_state || %{}

          %{
            version: new_state["version"],
            state_data: new_state["state_data"],
            saved_by: entry.actor_label,
            saved_at: entry.inserted_at
          }
        end)

      {:ok, %{data: history, total: total, page: page, page_size: page_size}}
    end
  end

  # --- Private helpers ---

  defp validate_state_key(state_key, tenant_id, project_id, attrs) do
    if is_nil(state_key) or (is_binary(state_key) and String.trim(state_key) == "") do
      changeset =
        %OrchestratorState{tenant_id: tenant_id, project_id: project_id}
        |> OrchestratorState.create_changeset(attrs)

      {:error, %{changeset | action: :insert}}
    else
      {:ok, state_key}
    end
  end

  defp get_existing_state(tenant_id, project_id, state_key) do
    AdminRepo.get_by(OrchestratorState,
      tenant_id: tenant_id,
      project_id: project_id,
      state_key: state_key
    )
  end

  defp resolve_save(nil, v, tenant_id, project_id, attrs, actor_id, actor_label)
       when v in [0, nil] do
    insert_state(tenant_id, project_id, attrs, actor_id, actor_label)
  end

  defp resolve_save(nil, _v, _tenant_id, _project_id, _attrs, _actor_id, _actor_label) do
    {:error, :version_conflict}
  end

  defp resolve_save(
         %OrchestratorState{version: current} = existing,
         expected,
         tenant_id,
         _project_id,
         attrs,
         actor_id,
         actor_label
       )
       when current == expected do
    update_state(existing, attrs, tenant_id, actor_id, actor_label)
  end

  defp resolve_save(
         %OrchestratorState{},
         _expected,
         _tenant_id,
         _project_id,
         _attrs,
         _actor_id,
         _actor_label
       ) do
    {:error, :version_conflict}
  end

  defp get_project(tenant_id, project_id) do
    case AdminRepo.get_by(Project, id: project_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  defp insert_state(tenant_id, project_id, attrs, actor_id, actor_label) do
    changeset =
      %OrchestratorState{tenant_id: tenant_id, project_id: project_id}
      |> OrchestratorState.create_changeset(attrs)

    multi =
      Multi.new()
      |> Multi.insert(:state, changeset)
      |> Audit.log_in_multi(:audit, fn %{state: state} ->
        %{
          tenant_id: tenant_id,
          entity_type: "orchestrator_state",
          entity_id: state.id,
          action: "saved",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          new_state: %{
            "project_id" => project_id,
            "state_key" => state.state_key,
            "state_data" => state.state_data,
            "version" => state.version
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{state: state}} ->
        {:ok, state}

      {:error, :state, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp update_state(existing, attrs, tenant_id, actor_id, actor_label) do
    changeset = OrchestratorState.update_changeset(existing, attrs)

    if changeset.valid? do
      do_atomic_update(existing, changeset, tenant_id, actor_id, actor_label)
    else
      {:error, %{changeset | action: :update}}
    end
  end

  defp do_atomic_update(existing, changeset, tenant_id, actor_id, actor_label) do
    new_version = existing.version + 1
    new_state_data = Ecto.Changeset.get_change(changeset, :state_data, existing.state_data)

    multi =
      Multi.new()
      |> Multi.run(:state, fn _repo, _changes ->
        atomic_version_update(existing, new_state_data, new_version)
      end)
      |> Audit.log_in_multi(:audit, fn %{state: state} ->
        build_update_audit(existing, state, tenant_id, actor_id, actor_label)
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{state: state}} ->
        {:ok, state}

      {:error, :state, :version_conflict, _changes} ->
        {:error, :version_conflict}

      {:error, :state, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp atomic_version_update(existing, new_state_data, new_version) do
    query =
      from(s in OrchestratorState,
        where: s.id == ^existing.id and s.version == ^existing.version
      )

    case AdminRepo.update_all(query,
           set: [state_data: new_state_data, version: new_version, updated_at: DateTime.utc_now()]
         ) do
      {1, _} -> {:ok, AdminRepo.get!(OrchestratorState, existing.id)}
      {0, _} -> {:error, :version_conflict}
    end
  end

  defp build_update_audit(existing, state, tenant_id, actor_id, actor_label) do
    %{
      tenant_id: tenant_id,
      entity_type: "orchestrator_state",
      entity_id: state.id,
      action: "saved",
      actor_type: "api_key",
      actor_id: actor_id,
      actor_label: actor_label,
      old_state: %{
        "project_id" => existing.project_id,
        "state_key" => existing.state_key,
        "state_data" => existing.state_data,
        "version" => existing.version
      },
      new_state: %{
        "project_id" => state.project_id,
        "state_key" => state.state_key,
        "state_data" => state.state_data,
        "version" => state.version
      }
    }
  end
end
