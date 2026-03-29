defmodule Loopctl.QualityAssurance do
  @moduledoc """
  Context module for UI test run management.

  UI test runs track automated or manual UI testing sessions against
  a project, following a guide reference. Each run records structured
  findings with severity levels, screenshots, and a final summary.

  All operations use AdminRepo (BYPASSRLS) with explicit tenant_id
  scoping, following the same pattern as other loopctl contexts.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.QualityAssurance.UiTestRun

  # --- Public API ---

  @doc """
  Starts a new UI test run for a project.

  Creates a run with status `:in_progress` and records the
  `ui_test.started` audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `project_id` -- the project UUID
  - `params` -- map with `guide_reference` (required)
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %UiTestRun{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec start_ui_test(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, UiTestRun.t()} | {:error, Ecto.Changeset.t()}
  def start_ui_test(tenant_id, project_id, params, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    attrs = Map.put(params, "started_at", DateTime.utc_now())

    changeset =
      %UiTestRun{
        tenant_id: tenant_id,
        project_id: project_id,
        started_by_agent_id: agent_id
      }
      |> UiTestRun.create_changeset(attrs)

    multi =
      Multi.new()
      |> Multi.insert(:run, changeset)
      |> Audit.log_in_multi(:audit, fn %{run: run} ->
        %{
          tenant_id: tenant_id,
          entity_type: "ui_test_run",
          entity_id: run.id,
          action: "ui_test.started",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          new_state: %{
            "project_id" => project_id,
            "guide_reference" => run.guide_reference,
            "started_by_agent_id" => agent_id,
            "status" => "in_progress"
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{run: run}} -> {:ok, run}
      {:error, :run, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Appends a finding to a UI test run.

  Only works on runs with status `:in_progress`. Increments
  `findings_count` and the appropriate severity count. Records
  the `ui_test.finding_added` audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `run_id` -- the UI test run UUID
  - `finding_params` -- map with:
    - `step` -- the UI step where the finding occurred
    - `severity` -- `critical | high | medium | low`
    - `type` -- `crash | wrong_behavior | ui_defect | ...`
    - `description` -- human-readable description
    - `screenshot_path` -- optional path to screenshot
    - `console_errors` -- optional console error output

  ## Returns

  - `{:ok, %UiTestRun{}}` on success
  - `{:error, :not_found}` if the run does not belong to the tenant
  - `{:error, :run_not_in_progress}` if the run is already completed
  """
  @spec add_finding(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, UiTestRun.t()} | {:error, :not_found | :run_not_in_progress}
  def add_finding(tenant_id, run_id, finding_params) do
    with {:ok, run} <- get_ui_test(tenant_id, run_id),
         :ok <- require_in_progress(run) do
      changeset = UiTestRun.add_finding_changeset(run, finding_params)

      multi =
        Multi.new()
        |> Multi.update(:run, changeset)
        |> Audit.log_in_multi(:audit, fn %{run: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "ui_test_run",
            entity_id: updated.id,
            action: "ui_test.finding_added",
            actor_type: "api_key",
            actor_id: nil,
            actor_label: nil,
            new_state: %{
              "findings_count" => updated.findings_count,
              "severity" => Map.get(finding_params, "severity", "low"),
              "type" => Map.get(finding_params, "type"),
              "step" => Map.get(finding_params, "step")
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{run: updated}} -> {:ok, updated}
        {:error, :run, changeset, _} -> {:error, changeset}
      end
    end
  end

  @doc """
  Completes a UI test run.

  Sets status to `:passed` or `:failed` based on params, fills in
  `summary`, and sets `completed_at`. Records the `ui_test.completed`
  audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `run_id` -- the UI test run UUID
  - `params` -- map with:
    - `status` -- `passed | failed` (required)
    - `summary` -- completion summary text (required)
  - `opts` -- keyword list with `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %UiTestRun{}}` on success
  - `{:error, :not_found}` if the run does not belong to the tenant
  - `{:error, :run_not_in_progress}` if the run is already completed
  - `{:error, changeset}` on validation failure
  """
  @spec complete_ui_test(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, UiTestRun.t()} | {:error, :not_found | :run_not_in_progress | Ecto.Changeset.t()}
  def complete_ui_test(tenant_id, run_id, params, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    with {:ok, run} <- get_ui_test(tenant_id, run_id),
         :ok <- require_in_progress(run) do
      changeset = UiTestRun.complete_changeset(run, params)

      multi =
        Multi.new()
        |> Multi.update(:run, changeset)
        |> Audit.log_in_multi(:audit, fn %{run: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "ui_test_run",
            entity_id: updated.id,
            action: "ui_test.completed",
            actor_type: "api_key",
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: %{"status" => "in_progress"},
            new_state: %{
              "status" => to_string(updated.status),
              "findings_count" => updated.findings_count,
              "critical_count" => updated.critical_count,
              "high_count" => updated.high_count
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{run: updated}} -> {:ok, updated}
        {:error, :run, changeset, _} -> {:error, changeset}
      end
    end
  end

  @doc """
  Lists UI test runs for a project with optional filtering and pagination.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `project_id` -- the project UUID
  - `opts` -- keyword list with:
    - `:status` -- filter by status string (optional)
    - `:limit` -- max records to return (default 20)
    - `:offset` -- records to skip for pagination (default 0)

  ## Returns

  - `{:ok, %{data: [%UiTestRun{}], total: integer(), limit: integer(), offset: integer()}}`
  """
  @spec list_ui_tests(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [UiTestRun.t()],
             total: non_neg_integer(),
             limit: pos_integer(),
             offset: non_neg_integer()
           }}
  def list_ui_tests(tenant_id, project_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    status = Keyword.get(opts, :status)

    base =
      from(r in UiTestRun,
        where: r.tenant_id == ^tenant_id and r.project_id == ^project_id,
        order_by: [desc: r.started_at]
      )

    base =
      if status do
        where(base, [r], r.status == ^status)
      else
        base
      end

    total = AdminRepo.aggregate(base, :count, :id)

    runs =
      base
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: runs, total: total, limit: limit, offset: offset}}
  end

  @doc """
  Gets a single UI test run by ID, scoped to the tenant.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `run_id` -- the UI test run UUID

  ## Returns

  - `{:ok, %UiTestRun{}}` if found
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_ui_test(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, UiTestRun.t()} | {:error, :not_found}
  def get_ui_test(tenant_id, run_id) do
    case AdminRepo.get_by(UiTestRun, id: run_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  # --- Private helpers ---

  defp require_in_progress(%UiTestRun{status: :in_progress}), do: :ok
  defp require_in_progress(%UiTestRun{}), do: {:error, :run_not_in_progress}
end
