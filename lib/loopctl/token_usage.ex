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

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Projects.Project
  alias Loopctl.Tenants.Tenant
  alias Loopctl.TokenUsage.Budget
  alias Loopctl.TokenUsage.Report
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

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
          {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def create_report(tenant_id, attrs, opts \\ []) do
    attrs = normalize_attrs(attrs)

    story_id = Map.get(attrs, :story_id)
    agent_id = Map.get(attrs, :agent_id)
    project_id = Map.get(attrs, :project_id)

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

        # Audit log the creation
        Audit.create_log_entry(tenant_id, %{
          entity_type: "token_usage_report",
          entity_id: report.id,
          action: "created",
          actor_type: Keyword.get(opts, :actor_type, "api_key"),
          actor_id: Keyword.get(opts, :actor_id),
          actor_label: Keyword.get(opts, :actor_label),
          new_state: %{
            "story_id" => report.story_id,
            "agent_id" => report.agent_id,
            "project_id" => report.project_id,
            "input_tokens" => report.input_tokens,
            "output_tokens" => report.output_tokens,
            "model_name" => report.model_name,
            "cost_millicents" => report.cost_millicents,
            "phase" => report.phase
          }
        })

        {:ok, report}

      {:error, changeset} ->
        {:error, changeset}
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

  # --- Private helpers ---

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
    where(query, [b], b.scope_type == ^value)
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
    |> select([r], coalesce(sum(r.cost_millicents), 0))
  end

  defp spend_query(tenant_id, :epic, scope_id) do
    Report
    |> join(:inner, [r], s in Story, on: r.story_id == s.id)
    |> where([r, s], r.tenant_id == ^tenant_id and s.epic_id == ^scope_id)
    |> select([r, _s], coalesce(sum(r.cost_millicents), 0))
  end

  defp spend_query(tenant_id, :project, scope_id) do
    Report
    |> where([r], r.tenant_id == ^tenant_id and r.project_id == ^scope_id)
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
    |> group_by([r], r.story_id)
    |> select([r], {r.story_id, coalesce(sum(r.cost_millicents), 0)})
    |> AdminRepo.all()
    |> Enum.map(fn {scope_id, spend} -> {{:story, scope_id}, decimal_to_int(spend)} end)
  end

  defp batch_spend_query(tenant_id, :epic, scope_ids) do
    Report
    |> join(:inner, [r], s in Story, on: r.story_id == s.id)
    |> where([r, s], r.tenant_id == ^tenant_id and s.epic_id in ^scope_ids)
    |> group_by([r, s], s.epic_id)
    |> select([r, s], {s.epic_id, coalesce(sum(r.cost_millicents), 0)})
    |> AdminRepo.all()
    |> Enum.map(fn {scope_id, spend} -> {{:epic, scope_id}, decimal_to_int(spend)} end)
  end

  defp batch_spend_query(tenant_id, :project, scope_ids) do
    Report
    |> where([r], r.tenant_id == ^tenant_id and r.project_id in ^scope_ids)
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
end
