defmodule Loopctl.TokenUsage do
  @moduledoc """
  Context module for token usage reporting.

  Provides functions to create and query token usage reports.
  All functions take `tenant_id` as the first argument for multi-tenant
  scoping.

  ## Usage

  ### Creating a report

      Loopctl.TokenUsage.create_report(tenant_id, %{
        story_id: story_id,
        agent_id: agent_id,
        project_id: project_id,
        input_tokens: 1000,
        output_tokens: 500,
        model_name: "claude-opus-4",
        cost_millicents: 2500,
        phase: "implementing"
      })

  ### Listing reports for a story

      Loopctl.TokenUsage.list_reports_for_story(tenant_id, story_id)

  ### Getting totals for a story

      Loopctl.TokenUsage.get_story_totals(tenant_id, story_id)
  """

  require Logger

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Projects.Project
  alias Loopctl.Skills.Skill
  alias Loopctl.Skills.SkillVersion
  alias Loopctl.Tenants.Tenant
  alias Loopctl.TokenUsage.Budget
  alias Loopctl.TokenUsage.CostAnomaly
  alias Loopctl.TokenUsage.CostSummary
  alias Loopctl.TokenUsage.Report
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.WebhookDeliveryWorker

  @doc """
  Creates a new token usage report.

  The `attrs` map must include: `story_id`, `agent_id`, `project_id`,
  `input_tokens`, `output_tokens`, `model_name`, `cost_millicents`.

  Optional: `phase`, `session_id`, `skill_version_id`, `metadata`.

  The `tenant_id`, `agent_id`, `project_id`, and `story_id` are set
  programmatically on the struct (not via cast).

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  ## Returns

  - `{:ok, %Report{}}` on success
  - `{:error, %Ecto.Changeset{}}` on validation failure
  """
  @spec create_report(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Report.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :unprocessable_entity, String.t()}
  def create_report(tenant_id, attrs, opts \\ []) do
    attrs = normalize_attrs(attrs)

    story_id = Map.get(attrs, :story_id)
    agent_id = Map.get(attrs, :agent_id)
    project_id = Map.get(attrs, :project_id)
    skill_version_id = Map.get(attrs, :skill_version_id)

    with :ok <- validate_skill_version_ownership(tenant_id, skill_version_id) do
      changeset =
        %Report{
          tenant_id: tenant_id,
          story_id: story_id,
          agent_id: agent_id,
          project_id: project_id
        }
        |> Report.create_changeset(attrs)

      case AdminRepo.insert(changeset) do
        {:ok, report} ->
          # Refetch to populate the DB-generated total_tokens column
          report = AdminRepo.get!(Report, report.id)

          # Audit log the creation (also serves as the change feed entry for AC-21.8.1)
          Audit.create_log_entry(tenant_id, %{
            entity_type: "token_usage_report",
            entity_id: report.id,
            action: "created",
            actor_type: Keyword.get(opts, :actor_type, "api_key"),
            actor_id: Keyword.get(opts, :actor_id),
            actor_label: Keyword.get(opts, :actor_label),
            project_id: report.project_id,
            new_state: %{
              "story_id" => report.story_id,
              "agent_id" => report.agent_id,
              "model_name" => report.model_name,
              "cost_millicents" => report.cost_millicents,
              "total_tokens" => report.total_tokens,
              "skill_version_id" => report.skill_version_id
            },
            metadata: %{
              "story_id" => report.story_id,
              "agent_id" => report.agent_id,
              "model_name" => report.model_name,
              "cost_millicents" => report.cost_millicents,
              "total_tokens" => report.total_tokens,
              "skill_version_id" => report.skill_version_id
            }
          })

          # Check budget thresholds after report creation (AC-21.8.2).
          # Wrapped in try/rescue so a DB failure during threshold checking
          # does not crash the report creation flow (the report is committed).
          try do
            check_budget_thresholds(tenant_id, report)
          rescue
            e ->
              Logger.warning(
                "Budget threshold check failed for report #{report.id}: " <>
                  Exception.message(e)
              )
          end

          {:ok, report}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Creates a token usage report within an Ecto.Multi pipeline.

  Used by `Progress.report_story/4` to atomically create a token usage
  report alongside a status transition.

  ## Parameters

  - `multi` -- the Ecto.Multi struct
  - `name` -- the step name in the multi
  - `tenant_id` -- the tenant UUID
  - `attrs` -- map of report attributes (story_id, agent_id, project_id, etc.)

  ## Returns

  The updated Ecto.Multi struct.
  """
  @spec create_report_in_multi(Ecto.Multi.t(), atom(), Ecto.UUID.t(), map()) :: Ecto.Multi.t()
  def create_report_in_multi(multi, name, tenant_id, attrs) do
    attrs = normalize_attrs(attrs)

    story_id = Map.get(attrs, :story_id)
    agent_id = Map.get(attrs, :agent_id)
    project_id = Map.get(attrs, :project_id)

    Ecto.Multi.insert(multi, name, fn _changes ->
      %Report{
        tenant_id: tenant_id,
        story_id: story_id,
        agent_id: agent_id,
        project_id: project_id
      }
      |> Report.create_changeset(attrs)
    end)
  end

  @doc """
  Lists all token usage reports for a story, ordered by inserted_at descending.

  Includes pagination and total count.

  ## Options

  - `:page` -- page number (default 1)
  - `:page_size` -- entries per page (default 20, max 100)

  ## Returns

  `{:ok, %{data: [%Report{}], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_reports_for_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [Report.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_reports_for_story(tenant_id, story_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      Report
      |> where([r], r.tenant_id == ^tenant_id and r.story_id == ^story_id)
      |> where([r], is_nil(r.deleted_at))

    total = AdminRepo.aggregate(base_query, :count, :id)

    reports =
      base_query
      |> order_by([r], desc: r.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: reports, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Returns aggregated token usage totals for a story.

  ## Returns

  `{:ok, %{total_input_tokens: integer, total_output_tokens: integer, total_tokens: integer, total_cost_millicents: integer, report_count: integer}}`
  """
  @spec get_story_totals(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok,
           %{
             total_input_tokens: non_neg_integer(),
             total_output_tokens: non_neg_integer(),
             total_tokens: non_neg_integer(),
             total_cost_millicents: non_neg_integer(),
             report_count: non_neg_integer()
           }}
  def get_story_totals(tenant_id, story_id) do
    query =
      Report
      |> where([r], r.tenant_id == ^tenant_id and r.story_id == ^story_id)
      |> where([r], is_nil(r.deleted_at))
      |> select([r], %{
        total_input_tokens: coalesce(sum(r.input_tokens), 0),
        total_output_tokens: coalesce(sum(r.output_tokens), 0),
        total_tokens: coalesce(sum(r.input_tokens), 0) + coalesce(sum(r.output_tokens), 0),
        total_cost_millicents: coalesce(sum(r.cost_millicents), 0),
        report_count: count(r.id)
      })

    result = AdminRepo.one(query)

    {:ok,
     %{
       total_input_tokens: decimal_to_int(result.total_input_tokens),
       total_output_tokens: decimal_to_int(result.total_output_tokens),
       total_tokens: decimal_to_int(result.total_tokens),
       total_cost_millicents: decimal_to_int(result.total_cost_millicents),
       report_count: result.report_count
     }}
  end

  # --- Report deletion and correction (US-21.13) ---

  @doc """
  Gets a single token usage report by ID, scoped to a tenant.

  Only returns non-deleted reports.

  ## Returns

  - `{:ok, %Report{}}` if found and active
  - `{:error, :not_found}` if not found, wrong tenant, or soft-deleted
  """
  @spec get_report(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Report.t()} | {:error, :not_found}
  def get_report(tenant_id, report_id) do
    case AdminRepo.get_by(Report, id: report_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      %Report{deleted_at: nil} = report -> {:ok, report}
      %Report{} -> {:error, :not_found}
    end
  end

  @doc """
  Soft-deletes a token usage report by setting `deleted_at`.

  The report is excluded from all queries and analytics after deletion.
  Budget warning/exceeded flags are reset if the new spend drops below
  their respective thresholds.

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  ## Returns

  - `{:ok, %Report{}}` on success
  - `{:error, :not_found}` if not found, wrong tenant, or already deleted
  """
  @spec delete_report(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Report.t()} | {:error, :not_found}
  def delete_report(tenant_id, report_id, opts \\ []) do
    with {:ok, report} <- get_report(tenant_id, report_id) do
      old_state = %{
        "story_id" => report.story_id,
        "cost_millicents" => report.cost_millicents,
        "total_tokens" => report.total_tokens,
        "model_name" => report.model_name
      }

      multi =
        Multi.new()
        |> Multi.update(:report, Loopctl.Schema.soft_delete_changeset(report))
        |> Audit.log_in_multi(:audit, fn _changes ->
          %{
            tenant_id: tenant_id,
            entity_type: "token_usage_report",
            entity_id: report.id,
            action: "deleted",
            actor_type: Keyword.get(opts, :actor_type, "api_key"),
            actor_id: Keyword.get(opts, :actor_id),
            actor_label: Keyword.get(opts, :actor_label),
            old_state: old_state,
            metadata: %{
              "story_id" => report.story_id,
              "project_id" => report.project_id,
              "cost_millicents" => report.cost_millicents
            }
          }
        end)
        |> mark_affected_cost_summaries_stale_multi(tenant_id, report)

      case AdminRepo.transaction(multi) do
        {:ok, %{report: deleted_report}} ->
          # Reset budget flags if spend dropped below thresholds
          try do
            reset_budget_flags_if_needed(tenant_id, report)
          rescue
            e ->
              Logger.warning(
                "Budget flag reset failed after deleting report #{report.id}: " <>
                  Exception.message(e)
              )
          end

          {:ok, deleted_report}

        {:error, _step, error, _} ->
          {:error, error}
      end
    end
  end

  @doc """
  Creates a correction report that references the original report.

  Corrections allow negative `input_tokens`, `output_tokens`, and
  `cost_millicents` to subtract from the story's running total.

  ## Validation

  The sum of the original report's fields plus the correction values must be
  >= 0 for `input_tokens`, `output_tokens`, and `cost_millicents`. Returns
  `{:error, :unprocessable_entity, message}` if the correction would make
  any total negative.

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  ## Returns

  - `{:ok, %Report{}}` on success (the correction report)
  - `{:error, :not_found}` if the original report not found or wrong tenant
  - `{:error, :unprocessable_entity, message}` if the correction would produce
    negative totals
  - `{:error, %Ecto.Changeset{}}` on validation failure
  """
  @spec create_correction(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Report.t()}
          | {:error, :not_found}
          | {:error, :unprocessable_entity, String.t()}
          | {:error, Ecto.Changeset.t()}
  def create_correction(tenant_id, original_report_id, attrs, opts \\ []) do
    attrs = normalize_attrs(attrs)

    with {:ok, original} <- get_report(tenant_id, original_report_id),
         :ok <- validate_correction_totals(tenant_id, original, attrs) do
      correction_input_tokens = Map.get(attrs, :input_tokens, 0)
      correction_output_tokens = Map.get(attrs, :output_tokens, 0)

      changeset =
        %Report{
          tenant_id: tenant_id,
          story_id: original.story_id,
          agent_id: original.agent_id,
          project_id: original.project_id,
          corrects_report_id: original.id
        }
        |> Report.correction_changeset(
          Map.merge(
            %{
              model_name: original.model_name,
              phase: original.phase
            },
            attrs
          )
        )

      multi =
        Multi.new()
        |> Multi.insert(:correction, changeset)
        |> Audit.log_in_multi(:audit, fn %{correction: correction} ->
          %{
            tenant_id: tenant_id,
            entity_type: "token_usage_report",
            entity_id: correction.id,
            action: "corrected",
            actor_type: Keyword.get(opts, :actor_type, "api_key"),
            actor_id: Keyword.get(opts, :actor_id),
            actor_label: Keyword.get(opts, :actor_label),
            new_state: %{
              "corrects_report_id" => original.id,
              "story_id" => correction.story_id,
              "input_tokens" => correction.input_tokens,
              "output_tokens" => correction.output_tokens,
              "cost_millicents" => correction.cost_millicents,
              "model_name" => correction.model_name
            },
            metadata: %{
              "corrects_report_id" => original.id,
              "story_id" => correction.story_id,
              "project_id" => correction.project_id,
              "input_tokens" => correction_input_tokens,
              "output_tokens" => correction_output_tokens,
              "cost_millicents" => Map.get(attrs, :cost_millicents, 0)
            }
          }
        end)
        |> mark_affected_cost_summaries_stale_multi(tenant_id, original)

      case AdminRepo.transaction(multi) do
        {:ok, %{correction: correction}} ->
          # Refetch to populate the DB-generated total_tokens column
          correction = AdminRepo.get!(Report, correction.id)

          # Reset budget flags if spend dropped below thresholds
          try do
            reset_budget_flags_if_needed(tenant_id, original)
          rescue
            e ->
              Logger.warning(
                "Budget flag reset failed after correcting report #{original.id}: " <>
                  Exception.message(e)
              )
          end

          {:ok, correction}

        {:error, :correction, %Ecto.Changeset{} = changeset, _} ->
          {:error, changeset}

        {:error, _step, error, _} ->
          {:error, error}
      end
    end
  end

  # Validates that the sum of story totals + correction values >= 0.
  # AC-21.13.3: Negative corrections are valid as long as the sum is non-negative.
  defp validate_correction_totals(tenant_id, original, attrs) do
    {:ok, totals} = get_story_totals(tenant_id, original.story_id)

    correction_input = Map.get(attrs, :input_tokens, 0)
    correction_output = Map.get(attrs, :output_tokens, 0)
    correction_cost = Map.get(attrs, :cost_millicents, 0)

    new_input = totals.total_input_tokens + correction_input
    new_output = totals.total_output_tokens + correction_output
    new_cost = totals.total_cost_millicents + correction_cost

    cond do
      new_input < 0 ->
        {:error, :unprocessable_entity,
         "correction would make total input_tokens negative (current: #{totals.total_input_tokens}, correction: #{correction_input})"}

      new_output < 0 ->
        {:error, :unprocessable_entity,
         "correction would make total output_tokens negative (current: #{totals.total_output_tokens}, correction: #{correction_output})"}

      new_cost < 0 ->
        {:error, :unprocessable_entity,
         "correction would make total cost_millicents negative (current: #{totals.total_cost_millicents}, correction: #{correction_cost})"}

      true ->
        :ok
    end
  end

  # Marks cost_summaries as stale for all scopes affected by a report change.
  # AC-21.13.7: When a report is deleted or corrected, related summaries are stale.
  defp mark_affected_cost_summaries_stale_multi(multi, tenant_id, report) do
    Multi.run(multi, :mark_summaries_stale, fn _repo, _changes ->
      story_scope_ids = [report.story_id]

      epic_scope_ids =
        case AdminRepo.get_by(Story, id: report.story_id, tenant_id: tenant_id) do
          nil -> []
          story -> [story.epic_id]
        end

      project_scope_ids = [report.project_id]

      # Mark story-scope summaries stale
      {_n, _} =
        CostSummary
        |> where([cs], cs.tenant_id == ^tenant_id)
        |> where([cs], cs.scope_type == :story and cs.scope_id in ^story_scope_ids)
        |> AdminRepo.update_all(set: [stale: true])

      # Mark epic-scope summaries stale
      if epic_scope_ids != [] do
        CostSummary
        |> where([cs], cs.tenant_id == ^tenant_id)
        |> where([cs], cs.scope_type == :epic and cs.scope_id in ^epic_scope_ids)
        |> AdminRepo.update_all(set: [stale: true])
      end

      # Mark project-scope summaries stale
      {_n, _} =
        CostSummary
        |> where([cs], cs.tenant_id == ^tenant_id)
        |> where([cs], cs.scope_type == :project and cs.scope_id in ^project_scope_ids)
        |> AdminRepo.update_all(set: [stale: true])

      {:ok, :ok}
    end)
  end

  # Resets warning_fired/exceeded_fired on applicable budgets when spend
  # drops below the threshold after a deletion or correction.
  # AC-21.13.4.
  defp reset_budget_flags_if_needed(tenant_id, report) do
    budgets = find_applicable_budgets(tenant_id, report)
    Enum.each(budgets, &maybe_reset_budget_flags(tenant_id, &1))
  end

  defp maybe_reset_budget_flags(tenant_id, budget) do
    spend = get_scope_spend(tenant_id, budget.scope_type, budget.scope_id)

    utilization_pct =
      if budget.budget_millicents > 0, do: spend * 100 / budget.budget_millicents, else: 0

    reset_attrs =
      %{}
      |> maybe_reset_flag(budget, :warning_fired, utilization_pct < budget.alert_threshold_pct)
      |> maybe_reset_flag(budget, :exceeded_fired, utilization_pct < 100)

    apply_budget_flag_reset(budget, reset_attrs)
  end

  defp apply_budget_flag_reset(_budget, attrs) when attrs == %{}, do: :ok

  defp apply_budget_flag_reset(budget, reset_attrs) do
    case budget |> Ecto.Changeset.change(reset_attrs) |> AdminRepo.update() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to reset budget flags on budget #{budget.id}: #{inspect(reason)}")
    end
  end

  defp maybe_reset_flag(attrs, budget, :warning_fired, should_reset)
       when should_reset and budget.warning_fired do
    Map.put(attrs, :warning_fired, false)
  end

  defp maybe_reset_flag(attrs, budget, :exceeded_fired, should_reset)
       when should_reset and budget.exceeded_fired do
    Map.put(attrs, :exceeded_fired, false)
  end

  defp maybe_reset_flag(attrs, _budget, _flag, _should_reset), do: attrs

  # --- Budget functions ---

  @doc """
  Creates a new token budget for a given scope.

  The `scope_type` must be one of `:project`, `:epic`, or `:story`, and the
  `scope_id` must reference an existing entity of the correct type within
  the tenant.

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  ## Returns

  - `{:ok, %Budget{}}` on success
  - `{:error, %Ecto.Changeset{}}` on validation failure
  - `{:error, :not_found}` if the scope entity does not exist
  - `{:error, :conflict}` if a budget already exists for this scope
  """
  @spec create_budget(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Budget.t()} | {:error, Ecto.Changeset.t() | :not_found | :conflict}
  def create_budget(tenant_id, attrs, opts \\ []) do
    attrs = normalize_budget_attrs(attrs)

    scope_type = Map.get(attrs, :scope_type)
    scope_id = Map.get(attrs, :scope_id)

    with :ok <- validate_scope_entity(tenant_id, scope_type, scope_id) do
      changeset =
        %Budget{tenant_id: tenant_id}
        |> Budget.create_changeset(attrs)

      multi =
        Multi.new()
        |> Multi.insert(:budget, changeset)
        |> Audit.log_in_multi(:audit, fn %{budget: budget} ->
          %{
            tenant_id: tenant_id,
            entity_type: "token_budget",
            entity_id: budget.id,
            action: "created",
            actor_type: Keyword.get(opts, :actor_type, "api_key"),
            actor_id: Keyword.get(opts, :actor_id),
            actor_label: Keyword.get(opts, :actor_label),
            new_state: %{
              "scope_type" => to_string(budget.scope_type),
              "scope_id" => budget.scope_id,
              "budget_millicents" => budget.budget_millicents,
              "budget_input_tokens" => budget.budget_input_tokens,
              "budget_output_tokens" => budget.budget_output_tokens,
              "alert_threshold_pct" => budget.alert_threshold_pct
            }
          }
        end)

      multi
      |> AdminRepo.transaction()
      |> handle_budget_insert_result()
    end
  end

  defp handle_budget_insert_result({:ok, %{budget: budget}}), do: {:ok, budget}

  defp handle_budget_insert_result({:error, :budget, %Ecto.Changeset{} = changeset, _}) do
    if has_unique_constraint_error?(changeset),
      do: {:error, :conflict},
      else: {:error, changeset}
  end

  defp handle_budget_insert_result({:error, _step, changeset, _}), do: {:error, changeset}

  @doc """
  Gets a single token budget by ID, scoped to a tenant.

  ## Returns

  - `{:ok, %Budget{}}` if found
  - `{:error, :not_found}` if not found or wrong tenant
  """
  @spec get_budget(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Budget.t()} | {:error, :not_found}
  def get_budget(tenant_id, budget_id) do
    case AdminRepo.get_by(Budget, id: budget_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      budget -> {:ok, budget}
    end
  end

  @doc """
  Lists token budgets for a tenant with optional filtering and pagination.

  ## Options

  - `:scope_type` -- filter by scope type (`:project`, `:epic`, or `:story`)
  - `:scope_id` -- filter by scope ID (UUID)
  - `:page` -- page number (default 1)
  - `:page_size` -- entries per page (default 20, max 100)

  ## Returns

  `{:ok, %{data: [%Budget{}], total: integer, page: integer, page_size: integer}}`

  Each budget in the result includes `:current_spend_millicents` and
  `:remaining_millicents` virtual fields populated from token_usage_reports.
  """
  @spec list_budgets(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_budgets(tenant_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      Budget
      |> where([b], b.tenant_id == ^tenant_id)
      |> apply_budget_filter(:scope_type, Keyword.get(opts, :scope_type))
      |> apply_budget_filter(:scope_id, Keyword.get(opts, :scope_id))

    total = AdminRepo.aggregate(base_query, :count, :id)

    budgets =
      base_query
      |> order_by([b], desc: b.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    budgets_with_spend = batch_attach_spend(tenant_id, budgets)

    {:ok, %{data: budgets_with_spend, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Updates an existing token budget.

  Cannot change `scope_type` or `scope_id`.

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  ## Returns

  - `{:ok, %Budget{}}` on success
  - `{:error, %Ecto.Changeset{}}` on validation failure
  - `{:error, :not_found}` if budget not found
  """
  @spec update_budget(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Budget.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_budget(tenant_id, budget_id, attrs, opts \\ []) do
    attrs = normalize_budget_attrs(attrs)

    with {:ok, budget} <- get_budget(tenant_id, budget_id) do
      old_state = %{
        "budget_millicents" => budget.budget_millicents,
        "budget_input_tokens" => budget.budget_input_tokens,
        "budget_output_tokens" => budget.budget_output_tokens,
        "alert_threshold_pct" => budget.alert_threshold_pct
      }

      changeset = Budget.update_changeset(budget, attrs)

      multi =
        Multi.new()
        |> Multi.update(:budget, changeset)
        |> Audit.log_in_multi(:audit, fn %{budget: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "token_budget",
            entity_id: updated.id,
            action: "updated",
            actor_type: Keyword.get(opts, :actor_type, "api_key"),
            actor_id: Keyword.get(opts, :actor_id),
            actor_label: Keyword.get(opts, :actor_label),
            old_state: old_state,
            new_state: %{
              "budget_millicents" => updated.budget_millicents,
              "budget_input_tokens" => updated.budget_input_tokens,
              "budget_output_tokens" => updated.budget_output_tokens,
              "alert_threshold_pct" => updated.alert_threshold_pct
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{budget: budget}} -> {:ok, budget}
        {:error, :budget, changeset, _} -> {:error, changeset}
        {:error, _step, changeset, _} -> {:error, changeset}
      end
    end
  end

  @doc """
  Deletes a token budget. Does not delete associated token usage reports.

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  ## Returns

  - `{:ok, %Budget{}}` on success
  - `{:error, :not_found}` if budget not found
  """
  @spec delete_budget(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Budget.t()} | {:error, :not_found}
  def delete_budget(tenant_id, budget_id, opts \\ []) do
    with {:ok, budget} <- get_budget(tenant_id, budget_id) do
      multi =
        Multi.new()
        |> Multi.delete(:budget, budget)
        |> Audit.log_in_multi(:audit, fn _changes ->
          %{
            tenant_id: tenant_id,
            entity_type: "token_budget",
            entity_id: budget.id,
            action: "deleted",
            actor_type: Keyword.get(opts, :actor_type, "api_key"),
            actor_id: Keyword.get(opts, :actor_id),
            actor_label: Keyword.get(opts, :actor_label),
            old_state: %{
              "scope_type" => to_string(budget.scope_type),
              "scope_id" => budget.scope_id,
              "budget_millicents" => budget.budget_millicents
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{budget: budget}} -> {:ok, budget}
        {:error, _step, error, _} -> {:error, error}
      end
    end
  end

  @doc """
  Returns the effective budget for a given scope, using budget inheritance.

  Resolution order:
  1. Explicit budget for the given (scope_type, scope_id)
  2. For stories: check epic budget, then project budget, then tenant default
  3. For epics: check project budget, then tenant default
  4. For projects: tenant default (for stories only)

  ## Returns

  - `{:ok, {budget_millicents, source}}` where source is `:explicit`,
    `:epic_inherited`, `:project_inherited`, or `:tenant_default`
  - `{:ok, nil}` when no budget at any level
  """
  @spec get_effective_budget(Ecto.UUID.t(), atom(), Ecto.UUID.t()) ::
          {:ok, {integer(), atom()} | nil}
  def get_effective_budget(tenant_id, scope_type, scope_id) do
    # 1. Check for explicit budget
    case get_explicit_budget(tenant_id, scope_type, scope_id) do
      {:ok, budget} ->
        {:ok, {budget.budget_millicents, :explicit}}

      :none ->
        resolve_inherited_budget(tenant_id, scope_type, scope_id)
    end
  end

  @doc """
  Calculates current spend for a budget scope.

  For `:story` -- sums cost_millicents WHERE story_id = scope_id.
  For `:epic` -- sums cost_millicents WHERE the report's story belongs to the epic.
  For `:project` -- sums cost_millicents WHERE the report's project_id = scope_id.

  ## Returns

  An integer representing total spend in millicents.
  """
  @spec get_scope_spend(Ecto.UUID.t(), atom(), Ecto.UUID.t()) :: non_neg_integer()
  def get_scope_spend(tenant_id, scope_type, scope_id) do
    query = spend_query(tenant_id, scope_type, scope_id)

    result = AdminRepo.one(query)
    decimal_to_int(result || 0)
  end

  # --- Budget threshold check (AC-21.8.2, AC-21.7.5, AC-21.7.6) ---

  # After a token usage report is created, check all applicable budgets
  # and emit threshold_crossed audit entries and webhook events for any
  # that have been crossed. Deduplication is enforced via warning_fired
  # and exceeded_fired boolean flags on the budget.
  #
  # When a single report pushes spend past both thresholds (e.g., from 50%
  # to 120%), both the warning AND exceeded events fire independently.
  defp check_budget_thresholds(tenant_id, report) do
    budgets = find_applicable_budgets(tenant_id, report)

    Enum.each(budgets, fn budget ->
      spend = get_scope_spend(tenant_id, budget.scope_type, budget.scope_id)

      utilization_pct =
        if budget.budget_millicents > 0, do: spend * 100 / budget.budget_millicents, else: 0

      # Fire warning and exceeded independently so both fire when a single
      # report pushes past both thresholds at once.
      if utilization_pct >= budget.alert_threshold_pct do
        emit_threshold_crossed(tenant_id, budget, utilization_pct, "warning")
        maybe_fire_warning_webhook(tenant_id, budget, spend, utilization_pct, report)
      end

      if utilization_pct >= 100 do
        emit_threshold_crossed(tenant_id, budget, utilization_pct, "exceeded")
        maybe_fire_exceeded_webhook(tenant_id, budget, spend, utilization_pct, report)
      end
    end)
  end

  # Fires a budget_warning webhook event if not already fired (dedup via warning_fired flag).
  defp maybe_fire_warning_webhook(tenant_id, budget, spend, utilization_pct, report) do
    if not budget.warning_fired do
      payload = %{
        "budget_id" => budget.id,
        "scope_type" => to_string(budget.scope_type),
        "scope_id" => budget.scope_id,
        "budget_millicents" => budget.budget_millicents,
        "current_spend_millicents" => spend,
        "utilization_pct" => utilization_pct,
        "alert_threshold_pct" => budget.alert_threshold_pct,
        "triggering_report_id" => report.id
      }

      fire_budget_event(tenant_id, "token.budget_warning", report.project_id, payload)
      mark_budget_flag(budget, :warning_fired)
    end
  end

  # Fires a budget_exceeded webhook event if not already fired (dedup via exceeded_fired flag).
  defp maybe_fire_exceeded_webhook(tenant_id, budget, spend, utilization_pct, report) do
    if not budget.exceeded_fired do
      overage = max(spend - budget.budget_millicents, 0)

      payload = %{
        "budget_id" => budget.id,
        "scope_type" => to_string(budget.scope_type),
        "scope_id" => budget.scope_id,
        "budget_millicents" => budget.budget_millicents,
        "current_spend_millicents" => spend,
        "utilization_pct" => utilization_pct,
        "alert_threshold_pct" => budget.alert_threshold_pct,
        "triggering_report_id" => report.id,
        "overage_millicents" => overage
      }

      fire_budget_event(tenant_id, "token.budget_exceeded", report.project_id, payload)
      mark_budget_flag(budget, :exceeded_fired)
    end
  end

  # Creates webhook events for matching subscriptions. Passes project_id so
  # project-scoped webhooks also receive budget alerts. Errors are caught to
  # avoid crashing the report creation flow (the report is already committed).
  defp fire_budget_event(tenant_id, event_type, project_id, payload) do
    webhooks = EventGenerator.matching_webhooks(tenant_id, event_type, project_id)

    Enum.each(webhooks, fn webhook ->
      with {:ok, event} <-
             %WebhookEvent{
               tenant_id: tenant_id,
               webhook_id: webhook.id
             }
             |> WebhookEvent.create_changeset(%{
               event_type: event_type,
               payload: payload
             })
             |> AdminRepo.insert(),
           {:ok, _job} <-
             WebhookDeliveryWorker.new(%{
               webhook_event_id: event.id,
               tenant_id: tenant_id
             })
             |> Oban.insert() do
        :ok
      else
        {:error, reason} ->
          Logger.warning(
            "Failed to create #{event_type} webhook event for tenant #{tenant_id}: #{inspect(reason)}"
          )
      end
    end)
  end

  # Updates a dedup flag on the budget. Logs failures instead of crashing.
  defp mark_budget_flag(budget, flag) when flag in [:warning_fired, :exceeded_fired] do
    case budget |> Ecto.Changeset.change(%{flag => true}) |> AdminRepo.update() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to set #{flag} on budget #{budget.id}: #{inspect(reason)}")
    end
  end

  # Finds all budgets applicable to a report: story-level, epic-level, project-level.
  defp find_applicable_budgets(tenant_id, report) do
    story_budget =
      AdminRepo.get_by(Budget,
        tenant_id: tenant_id,
        scope_type: :story,
        scope_id: report.story_id
      )

    # Look up the story's epic_id for epic-level budget check
    epic_budget =
      case AdminRepo.get_by(Story, id: report.story_id, tenant_id: tenant_id) do
        nil ->
          nil

        story ->
          AdminRepo.get_by(Budget,
            tenant_id: tenant_id,
            scope_type: :epic,
            scope_id: story.epic_id
          )
      end

    project_budget =
      AdminRepo.get_by(Budget,
        tenant_id: tenant_id,
        scope_type: :project,
        scope_id: report.project_id
      )

    [story_budget, epic_budget, project_budget]
    |> Enum.reject(&is_nil/1)
  end

  defp emit_threshold_crossed(tenant_id, budget, utilization_pct, threshold_type) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "token_budget",
      entity_id: budget.id,
      action: "threshold_crossed",
      actor_type: "system",
      new_state: %{
        "budget_id" => budget.id,
        "scope_type" => to_string(budget.scope_type),
        "scope_id" => budget.scope_id,
        "utilization_pct" => utilization_pct,
        "threshold_type" => threshold_type,
        "budget_millicents" => budget.budget_millicents
      },
      metadata: %{
        "budget_id" => budget.id,
        "scope_type" => to_string(budget.scope_type),
        "scope_id" => budget.scope_id,
        "threshold_type" => threshold_type
      }
    })
  end

  # --- Private helpers ---

  # Validates that skill_version_id (if provided) exists and belongs to the tenant.
  # The ownership chain is: skill_versions -> skills -> tenant_id.
  @spec validate_skill_version_ownership(Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          :ok | {:error, :unprocessable_entity, String.t()}
  defp validate_skill_version_ownership(_tenant_id, nil), do: :ok

  defp validate_skill_version_ownership(tenant_id, skill_version_id) do
    exists =
      SkillVersion
      |> join(:inner, [sv], s in Skill, on: sv.skill_id == s.id)
      |> where([sv, s], sv.id == ^skill_version_id and s.tenant_id == ^tenant_id)
      |> AdminRepo.exists?()

    if exists do
      :ok
    else
      {:error, :unprocessable_entity,
       "skill_version_id does not exist or belongs to a different tenant"}
    end
  end

  @known_attrs ~w(
    story_id agent_id project_id skill_version_id
    input_tokens output_tokens model_name cost_millicents
    phase session_id metadata
  )a

  defp normalize_attrs(attrs) when is_map(attrs) do
    known_strings = MapSet.new(@known_attrs, &Atom.to_string/1)

    Map.new(attrs, fn
      {k, v} when is_atom(k) ->
        {k, v}

      {k, v} when is_binary(k) ->
        if MapSet.member?(known_strings, k) do
          {String.to_existing_atom(k), v}
        else
          # Discard unknown string keys to prevent atom table exhaustion
          {:__discard__, v}
        end
    end)
    |> Map.delete(:__discard__)
  end

  defp decimal_to_int(%Decimal{} = val), do: Decimal.to_integer(val)
  defp decimal_to_int(val) when is_integer(val), do: val
  defp decimal_to_int(nil), do: 0

  # --- Budget private helpers ---

  @budget_attrs ~w(
    scope_type scope_id budget_millicents budget_input_tokens
    budget_output_tokens alert_threshold_pct metadata
  )a

  defp normalize_budget_attrs(attrs) when is_map(attrs) do
    known_strings = MapSet.new(@budget_attrs, &Atom.to_string/1)

    Map.new(attrs, fn
      {k, v} when is_atom(k) ->
        {k, v}

      {k, v} when is_binary(k) ->
        if MapSet.member?(known_strings, k) do
          {String.to_existing_atom(k), v}
        else
          {:__discard__, v}
        end
    end)
    |> Map.delete(:__discard__)
    |> maybe_atomize_scope_type()
  end

  defp maybe_atomize_scope_type(%{scope_type: st} = attrs) when is_binary(st) do
    if st in ~w(project epic story) do
      Map.put(attrs, :scope_type, String.to_existing_atom(st))
    else
      attrs
    end
  end

  defp maybe_atomize_scope_type(attrs), do: attrs

  defp validate_scope_entity(_tenant_id, nil, _scope_id), do: :ok
  defp validate_scope_entity(_tenant_id, _scope_type, nil), do: :ok

  defp validate_scope_entity(tenant_id, scope_type, scope_id) do
    case to_scope_atom(scope_type) do
      nil ->
        # Unknown scope type — skip entity validation, let changeset catch it
        :ok

      atom_type ->
        atom_type
        |> scope_schema()
        |> check_entity_exists(scope_id, tenant_id)
    end
  end

  @known_scope_types ~w(project epic story)
  defp to_scope_atom(st) when is_binary(st) do
    if st in @known_scope_types, do: String.to_existing_atom(st), else: nil
  end

  defp to_scope_atom(st) when st in [:project, :epic, :story], do: st
  defp to_scope_atom(_), do: nil

  defp scope_schema(:project), do: Project
  defp scope_schema(:epic), do: Epic
  defp scope_schema(:story), do: Story
  defp scope_schema(_), do: nil

  defp check_entity_exists(nil, _scope_id, _tenant_id), do: :ok

  defp check_entity_exists(schema, scope_id, tenant_id) do
    case AdminRepo.get_by(schema, id: scope_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      _entity -> :ok
    end
  end

  defp apply_budget_filter(query, _field, nil), do: query
  defp apply_budget_filter(query, _field, ""), do: query

  defp apply_budget_filter(query, :scope_type, value) when is_binary(value) do
    # Convert string to atom for Ecto.Enum compatibility; unknown values return no results
    case to_scope_atom(value) do
      nil -> where(query, [_b], false)
      atom_val -> where(query, [b], b.scope_type == ^atom_val)
    end
  end

  defp apply_budget_filter(query, :scope_type, value) when is_atom(value) do
    where(query, [b], b.scope_type == ^value)
  end

  defp apply_budget_filter(query, :scope_id, value) do
    where(query, [b], b.scope_id == ^value)
  end

  defp spend_query(tenant_id, :story, scope_id) do
    Report
    |> where([r], r.tenant_id == ^tenant_id and r.story_id == ^scope_id)
    |> where([r], is_nil(r.deleted_at))
    |> select([r], coalesce(sum(r.cost_millicents), 0))
  end

  defp spend_query(tenant_id, :epic, scope_id) do
    Report
    |> join(:inner, [r], s in Story, on: r.story_id == s.id)
    |> where([r, s], r.tenant_id == ^tenant_id and s.epic_id == ^scope_id)
    |> where([r, _s], is_nil(r.deleted_at))
    |> select([r, _s], coalesce(sum(r.cost_millicents), 0))
  end

  defp spend_query(tenant_id, :project, scope_id) do
    Report
    |> where([r], r.tenant_id == ^tenant_id and r.project_id == ^scope_id)
    |> where([r], is_nil(r.deleted_at))
    |> select([r], coalesce(sum(r.cost_millicents), 0))
  end

  # Batch computes spend for all budgets in at most 3 queries (one per scope type)
  # instead of N individual queries (N+1 pattern).
  defp batch_attach_spend(tenant_id, budgets) do
    spend_map =
      budgets
      |> Enum.group_by(& &1.scope_type)
      |> Enum.flat_map(fn {scope_type, scope_budgets} ->
        scope_ids = Enum.map(scope_budgets, & &1.scope_id)
        batch_spend_query(tenant_id, scope_type, scope_ids)
      end)
      |> Map.new()

    Enum.map(budgets, fn budget ->
      spend = Map.get(spend_map, {budget.scope_type, budget.scope_id}, 0)
      remaining = max(budget.budget_millicents - spend, 0)

      %{
        budget: budget,
        current_spend_millicents: spend,
        remaining_millicents: remaining
      }
    end)
  end

  defp batch_spend_query(tenant_id, :story, scope_ids) do
    Report
    |> where([r], r.tenant_id == ^tenant_id and r.story_id in ^scope_ids)
    |> where([r], is_nil(r.deleted_at))
    |> group_by([r], r.story_id)
    |> select([r], {r.story_id, coalesce(sum(r.cost_millicents), 0)})
    |> AdminRepo.all()
    |> Enum.map(fn {scope_id, spend} -> {{:story, scope_id}, decimal_to_int(spend)} end)
  end

  defp batch_spend_query(tenant_id, :epic, scope_ids) do
    Report
    |> join(:inner, [r], s in Story, on: r.story_id == s.id)
    |> where([r, s], r.tenant_id == ^tenant_id and s.epic_id in ^scope_ids)
    |> where([r, _s], is_nil(r.deleted_at))
    |> group_by([r, s], s.epic_id)
    |> select([r, s], {s.epic_id, coalesce(sum(r.cost_millicents), 0)})
    |> AdminRepo.all()
    |> Enum.map(fn {scope_id, spend} -> {{:epic, scope_id}, decimal_to_int(spend)} end)
  end

  defp batch_spend_query(tenant_id, :project, scope_ids) do
    Report
    |> where([r], r.tenant_id == ^tenant_id and r.project_id in ^scope_ids)
    |> where([r], is_nil(r.deleted_at))
    |> group_by([r], r.project_id)
    |> select([r], {r.project_id, coalesce(sum(r.cost_millicents), 0)})
    |> AdminRepo.all()
    |> Enum.map(fn {scope_id, spend} -> {{:project, scope_id}, decimal_to_int(spend)} end)
  end

  defp get_explicit_budget(tenant_id, scope_type, scope_id)
       when scope_type in [:project, :epic, :story] do
    case AdminRepo.get_by(Budget,
           tenant_id: tenant_id,
           scope_type: scope_type,
           scope_id: scope_id
         ) do
      nil -> :none
      budget -> {:ok, budget}
    end
  end

  defp resolve_inherited_budget(tenant_id, :story, scope_id) do
    # Story -> check epic budget -> check project budget -> tenant default
    with %Story{} = story <- AdminRepo.get_by(Story, id: scope_id, tenant_id: tenant_id),
         :none <- get_explicit_budget(tenant_id, :epic, story.epic_id),
         :none <- get_explicit_budget(tenant_id, :project, story.project_id) do
      check_tenant_default(tenant_id)
    else
      nil -> {:ok, nil}
      {:ok, %{scope_type: :epic} = budget} -> {:ok, {budget.budget_millicents, :epic_inherited}}
      {:ok, budget} -> {:ok, {budget.budget_millicents, :project_inherited}}
    end
  end

  defp resolve_inherited_budget(tenant_id, :epic, scope_id) do
    # Epic -> check project budget -> tenant default
    case AdminRepo.get_by(Epic, id: scope_id, tenant_id: tenant_id) do
      nil ->
        {:ok, nil}

      epic ->
        case get_explicit_budget(tenant_id, :project, epic.project_id) do
          {:ok, budget} ->
            {:ok, {budget.budget_millicents, :project_inherited}}

          :none ->
            check_tenant_default(tenant_id)
        end
    end
  end

  defp resolve_inherited_budget(tenant_id, :project, _scope_id) do
    # Project -> tenant default
    check_tenant_default(tenant_id)
  end

  defp check_tenant_default(tenant_id) do
    case AdminRepo.get(Tenant, tenant_id) do
      nil ->
        {:ok, nil}

      tenant ->
        if tenant.default_story_budget_millicents do
          {:ok, {tenant.default_story_budget_millicents, :tenant_default}}
        else
          {:ok, nil}
        end
    end
  end

  defp has_unique_constraint_error?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:tenant_id, {_msg, meta}} ->
        Keyword.get(meta, :constraint) == :unique

      _ ->
        false
    end)
  end

  # --- Cost Anomaly functions ---

  @doc """
  Lists unresolved cost anomalies for a tenant with filtering and pagination.

  Results include the story title and agent name for display purposes.

  ## Options

  - `:anomaly_type` -- filter by anomaly type (`:high_cost`, `:suspiciously_low`, `:budget_exceeded`)
  - `:project_id` -- filter by project UUID
  - `:resolved` -- filter by resolved status (default: false)
  - `:page` -- page number (default 1)
  - `:page_size` -- entries per page (default 20, max 100)

  ## Returns

  `{:ok, %{data: [map()], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_anomalies(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_anomalies(tenant_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size
    resolved = Keyword.get(opts, :resolved, false)

    base_query =
      CostAnomaly
      |> where([a], a.tenant_id == ^tenant_id)
      |> where([a], a.resolved == ^resolved)
      |> apply_anomaly_filter(:anomaly_type, Keyword.get(opts, :anomaly_type))
      |> apply_anomaly_filter(:project_id, Keyword.get(opts, :project_id), tenant_id)

    total = AdminRepo.aggregate(base_query, :count, :id)

    anomalies =
      base_query
      |> order_by([a], desc: a.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()
      |> AdminRepo.preload(story: [:assigned_agent])

    data = Enum.map(anomalies, &format_anomaly/1)

    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Gets a single cost anomaly by ID, scoped to a tenant.

  ## Returns

  - `{:ok, %CostAnomaly{}}` if found
  - `{:error, :not_found}` if not found or wrong tenant
  """
  @spec get_anomaly(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, CostAnomaly.t()} | {:error, :not_found}
  def get_anomaly(tenant_id, anomaly_id) do
    case AdminRepo.get_by(CostAnomaly, id: anomaly_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      anomaly -> {:ok, anomaly}
    end
  end

  @doc """
  Marks a cost anomaly as resolved.

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  ## Returns

  - `{:ok, %CostAnomaly{}}` on success
  - `{:error, :not_found}` if anomaly not found
  """
  @spec resolve_anomaly(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, CostAnomaly.t()} | {:error, :not_found}
  def resolve_anomaly(tenant_id, anomaly_id, opts \\ []) do
    with {:ok, anomaly} <- get_anomaly(tenant_id, anomaly_id) do
      changeset = CostAnomaly.resolve_changeset(anomaly)

      multi =
        Multi.new()
        |> Multi.update(:anomaly, changeset)
        |> Audit.log_in_multi(:audit, fn %{anomaly: resolved} ->
          %{
            tenant_id: tenant_id,
            entity_type: "cost_anomaly",
            entity_id: resolved.id,
            action: "resolved",
            actor_type: Keyword.get(opts, :actor_type, "api_key"),
            actor_id: Keyword.get(opts, :actor_id),
            actor_label: Keyword.get(opts, :actor_label),
            old_state: %{"resolved" => false},
            new_state: %{"resolved" => true}
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{anomaly: anomaly}} -> {:ok, anomaly}
        {:error, :anomaly, changeset, _} -> {:error, changeset}
        {:error, _step, error, _} -> {:error, error}
      end
    end
  end

  # --- Anomaly private helpers ---

  defp apply_anomaly_filter(query, _field, nil), do: query
  defp apply_anomaly_filter(query, _field, ""), do: query

  defp apply_anomaly_filter(query, :anomaly_type, value) when is_binary(value) do
    known = ~w(high_cost suspiciously_low budget_exceeded)

    if value in known do
      atom_val = String.to_existing_atom(value)
      where(query, [a], a.anomaly_type == ^atom_val)
    else
      where(query, [_a], false)
    end
  end

  defp apply_anomaly_filter(query, :anomaly_type, value) when is_atom(value) do
    where(query, [a], a.anomaly_type == ^value)
  end

  defp apply_anomaly_filter(query, :project_id, nil, _tenant_id), do: query
  defp apply_anomaly_filter(query, :project_id, "", _tenant_id), do: query

  defp apply_anomaly_filter(query, :project_id, project_id, _tenant_id) do
    query
    |> join(:inner, [a], s in Story, on: a.story_id == s.id)
    |> where([_a, s], s.project_id == ^project_id)
  end

  defp format_anomaly(%CostAnomaly{} = anomaly) do
    story_title =
      if Ecto.assoc_loaded?(anomaly.story),
        do: anomaly.story.title,
        else: nil

    agent_name =
      if Ecto.assoc_loaded?(anomaly.story) and
           anomaly.story.assigned_agent != nil and
           Ecto.assoc_loaded?(anomaly.story.assigned_agent),
         do: anomaly.story.assigned_agent.name,
         else: nil

    %{
      id: anomaly.id,
      tenant_id: anomaly.tenant_id,
      story_id: anomaly.story_id,
      story_title: story_title,
      agent_name: agent_name,
      anomaly_type: anomaly.anomaly_type,
      story_cost_millicents: anomaly.story_cost_millicents,
      reference_avg_millicents: anomaly.reference_avg_millicents,
      deviation_factor: anomaly.deviation_factor,
      resolved: anomaly.resolved,
      metadata: anomaly.metadata,
      inserted_at: anomaly.inserted_at,
      updated_at: anomaly.updated_at
    }
  end
end
