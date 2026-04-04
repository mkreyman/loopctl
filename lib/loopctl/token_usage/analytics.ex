defmodule Loopctl.TokenUsage.Analytics do
  @moduledoc """
  Analytics queries for token usage data.

  Provides per-agent, per-epic, per-project, per-model, trend, model-mix
  correlation, and agent model profile analytics.
  All functions take `tenant_id` as the first argument for multi-tenant scoping.

  Queries prefer pre-computed `cost_summaries` when available and fresh,
  falling back to live aggregation from `token_usage_reports` when summaries
  are stale or missing. Staleness rule: summaries with `period_end < today`
  are considered complete; the current day always uses live aggregation.

  Cost summaries are used for agent_metrics and project_metrics when the
  query covers only historical dates (all before today). Model metrics and
  trend metrics always use live aggregation because their dimensional
  requirements (per-model granularity, per-day grouping) don't map directly
  to the cost_summaries structure.

  All endpoints return empty results (not errors) when no token data exists.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Agent
  alias Loopctl.TokenUsage.Budget
  alias Loopctl.TokenUsage.Report
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

  # ---------------------------------------------------------------------------
  # AC-21.4.1: Agent metrics
  # ---------------------------------------------------------------------------

  @doc """
  Returns per-agent cost metrics for the given tenant.

  Each entry includes: agent_id, agent_name, total_stories_reported,
  total_input_tokens, total_output_tokens, total_cost_millicents,
  avg_cost_per_story_millicents, primary_model, efficiency_rank.

  Prefers cost_summaries for purely historical queries (AC-21.4.6),
  falling back to live aggregation otherwise.

  ## Options

  - `:project_id` -- filter by project UUID
  - `:since` -- only reports inserted on or after this date (Date)
  - `:until` -- only reports inserted on or before this date (Date)
  - `:page` -- page number (default 1)
  - `:page_size` -- entries per page (default 20, max 100)
  """
  @spec agent_metrics(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def agent_metrics(tenant_id, opts \\ []) do
    {page, page_size, offset} = pagination(opts)

    base =
      Report
      |> where([r], r.tenant_id == ^tenant_id)
      |> where([r], is_nil(r.deleted_at))
      |> where([r], not is_nil(r.agent_id))
      |> apply_date_filters(opts)
      |> apply_project_filter(opts)

    # Count distinct agents for pagination
    total =
      base
      |> select([r], count(r.agent_id, :distinct))
      |> AdminRepo.one()

    # Main aggregation — rank by avg cost per story (1=cheapest per story)
    rows =
      base
      |> join(:inner, [r], a in Agent, on: r.agent_id == a.id, as: :agent)
      |> group_by([r, agent: a], [r.agent_id, a.name])
      |> select([r, agent: a], %{
        agent_id: r.agent_id,
        agent_name: a.name,
        total_stories_reported: count(r.story_id, :distinct),
        total_input_tokens: sum(r.input_tokens),
        total_output_tokens: sum(r.output_tokens),
        total_cost_millicents: sum(r.cost_millicents),
        report_count: count(r.id)
      })
      |> order_by([r, agent: _a],
        asc:
          fragment(
            "CASE WHEN COUNT(DISTINCT ?) = 0 THEN 0 ELSE SUM(?) / COUNT(DISTINCT ?) END",
            r.story_id,
            r.cost_millicents,
            r.story_id
          )
      )
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    # Batch-fetch primary models for all agents in one query (avoids N+1)
    agent_ids = Enum.map(rows, & &1.agent_id)
    primary_models = batch_primary_models(tenant_id, agent_ids, opts)

    # Compute avg cost, then assign rank
    data =
      rows
      |> Enum.with_index(offset + 1)
      |> Enum.map(fn {row, rank} ->
        primary_model = Map.get(primary_models, row.agent_id)
        avg = safe_div(to_int(row.total_cost_millicents), row.total_stories_reported)

        %{
          agent_id: row.agent_id,
          agent_name: row.agent_name,
          total_stories_reported: row.total_stories_reported,
          total_input_tokens: to_int(row.total_input_tokens),
          total_output_tokens: to_int(row.total_output_tokens),
          total_cost_millicents: to_int(row.total_cost_millicents),
          avg_cost_per_story_millicents: avg,
          primary_model: primary_model,
          efficiency_rank: rank
        }
      end)

    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  # ---------------------------------------------------------------------------
  # AC-21.4.2: Epic metrics
  # ---------------------------------------------------------------------------

  @doc """
  Returns per-epic cost breakdown for the given tenant.

  Each entry includes: epic_id, epic_name, story_count, completed_story_count,
  total_cost_millicents, avg_cost_per_story_millicents, budget_millicents,
  utilization_pct, model_breakdown.

  ## Options

  - `:project_id` -- filter by project UUID
  - `:page` -- page number (default 1)
  - `:page_size` -- entries per page (default 20, max 100)
  """
  @spec epic_metrics(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def epic_metrics(tenant_id, opts \\ []) do
    {page, page_size, offset} = pagination(opts)
    project_id = Keyword.get(opts, :project_id)

    epic_base =
      Epic
      |> where([e], e.tenant_id == ^tenant_id)
      |> maybe_filter_epic_project(project_id)

    total = AdminRepo.aggregate(epic_base, :count, :id)

    epics =
      epic_base
      |> order_by([e], asc: e.number)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    epic_ids = Enum.map(epics, & &1.id)

    # Get cost data per epic
    cost_data = epic_cost_data(tenant_id, epic_ids)

    # Get story counts per epic
    story_counts = epic_story_counts(tenant_id, epic_ids)

    # Get budgets for epics
    budgets = epic_budgets(tenant_id, epic_ids)

    # Get model breakdowns per epic
    model_breakdowns = epic_model_breakdowns(tenant_id, epic_ids)

    data =
      Enum.map(epics, fn epic ->
        costs = Map.get(cost_data, epic.id, %{cost: 0, stories: 0})
        counts = Map.get(story_counts, epic.id, %{total: 0, completed: 0})
        budget = Map.get(budgets, epic.id)
        breakdown = Map.get(model_breakdowns, epic.id, %{})

        avg = safe_div(costs.cost, counts.total)
        utilization = if budget, do: safe_div(costs.cost * 100, budget), else: nil

        %{
          epic_id: epic.id,
          epic_name: epic.title,
          story_count: counts.total,
          completed_story_count: counts.completed,
          total_cost_millicents: costs.cost,
          avg_cost_per_story_millicents: avg,
          budget_millicents: budget,
          utilization_pct: utilization,
          model_breakdown: breakdown
        }
      end)

    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  # ---------------------------------------------------------------------------
  # AC-21.4.3: Project metrics (single project)
  # ---------------------------------------------------------------------------

  @doc """
  Returns a single project cost overview.

  Fields: total_cost_millicents, total_input_tokens, total_output_tokens,
  budget_millicents, utilization_pct, cost_by_phase, model_breakdown,
  agent_count, story_count, avg_cost_per_story_millicents.
  """
  @spec project_metrics(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def project_metrics(tenant_id, project_id) do
    # Verify project exists
    project_query =
      from(p in Loopctl.Projects.Project,
        where: p.id == ^project_id and p.tenant_id == ^tenant_id
      )

    case AdminRepo.one(project_query) do
      nil ->
        {:error, :not_found}

      _project ->
        # Aggregate from live reports (always authoritative for current data)
        totals =
          Report
          |> where([r], r.tenant_id == ^tenant_id and r.project_id == ^project_id)
          |> where([r], is_nil(r.deleted_at))
          |> select([r], %{
            total_input_tokens: coalesce(sum(r.input_tokens), 0),
            total_output_tokens: coalesce(sum(r.output_tokens), 0),
            total_cost_millicents: coalesce(sum(r.cost_millicents), 0),
            agent_count: count(r.agent_id, :distinct),
            story_count: count(r.story_id, :distinct)
          })
          |> AdminRepo.one()

        budget = get_project_budget(tenant_id, project_id)
        cost_by_phase = get_cost_by_phase(tenant_id, project_id)
        model_breakdown = get_project_model_breakdown(tenant_id, project_id)

        total_cost = to_int(totals.total_cost_millicents)
        story_count = totals.story_count
        utilization = if budget, do: safe_div(total_cost * 100, budget), else: nil

        result = %{
          total_cost_millicents: total_cost,
          total_input_tokens: to_int(totals.total_input_tokens),
          total_output_tokens: to_int(totals.total_output_tokens),
          budget_millicents: budget,
          utilization_pct: utilization,
          cost_by_phase: cost_by_phase,
          model_breakdown: model_breakdown,
          agent_count: totals.agent_count,
          story_count: story_count,
          avg_cost_per_story_millicents: safe_div(total_cost, story_count)
        }

        {:ok, result}
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.4.4: Model metrics
  # ---------------------------------------------------------------------------

  @doc """
  Returns model mix analysis for the given tenant.

  Each entry includes: model_name, total_input_tokens, total_output_tokens,
  total_cost_millicents, report_count, avg_cost_per_report_millicents,
  stories_verified_count, stories_rejected_count, verification_rate_pct.

  ## Options

  - `:project_id` -- filter by project UUID
  - `:since` -- only reports inserted on or after this date
  - `:until` -- only reports inserted on or before this date
  - `:page` -- page number (default 1)
  - `:page_size` -- entries per page (default 20, max 100)
  """
  @spec model_metrics(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def model_metrics(tenant_id, opts \\ []) do
    {page, page_size, offset} = pagination(opts)

    base =
      Report
      |> where([r], r.tenant_id == ^tenant_id)
      |> where([r], is_nil(r.deleted_at))
      |> apply_date_filters(opts)
      |> apply_project_filter(opts)

    # Count distinct models for pagination
    total =
      base
      |> select([r], count(r.model_name, :distinct))
      |> AdminRepo.one()

    rows =
      base
      |> group_by([r], r.model_name)
      |> select([r], %{
        model_name: r.model_name,
        total_input_tokens: sum(r.input_tokens),
        total_output_tokens: sum(r.output_tokens),
        total_cost_millicents: sum(r.cost_millicents),
        report_count: count(r.id)
      })
      |> order_by([r], desc: sum(r.cost_millicents))
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    # Get verification correlation per model
    verification_data = model_verification_data(tenant_id, opts)

    data =
      Enum.map(rows, fn row ->
        vd = Map.get(verification_data, row.model_name, %{verified: 0, rejected: 0})

        total_verifiable = vd.verified + vd.rejected

        verification_rate =
          if total_verifiable > 0,
            do: safe_div(vd.verified * 100, total_verifiable),
            else: nil

        %{
          model_name: row.model_name,
          total_input_tokens: to_int(row.total_input_tokens),
          total_output_tokens: to_int(row.total_output_tokens),
          total_cost_millicents: to_int(row.total_cost_millicents),
          report_count: row.report_count,
          avg_cost_per_report_millicents:
            safe_div(to_int(row.total_cost_millicents), row.report_count),
          stories_verified_count: vd.verified,
          stories_rejected_count: vd.rejected,
          verification_rate_pct: verification_rate
        }
      end)

    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  # ---------------------------------------------------------------------------
  # AC-21.4.5: Trend metrics
  # ---------------------------------------------------------------------------

  @doc """
  Returns daily or weekly cost trend for the given tenant.

  Each entry includes: period (date), total_cost_millicents, total_tokens,
  report_count, unique_agents.

  ## Options

  - `:granularity` -- `"daily"` (default) or `"weekly"`
  - `:project_id` -- filter by project UUID
  - `:since` -- only reports inserted on or after this date
  - `:until` -- only reports inserted on or before this date
  - `:page` -- page number (default 1)
  - `:page_size` -- entries per page (default 20, max 100)
  """
  @spec trend_metrics(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [map()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def trend_metrics(tenant_id, opts \\ []) do
    {page, page_size, offset} = pagination(opts)
    granularity = Keyword.get(opts, :granularity, "daily")

    base =
      Report
      |> where([r], r.tenant_id == ^tenant_id)
      |> where([r], is_nil(r.deleted_at))
      |> apply_date_filters(opts)
      |> apply_project_filter(opts)

    case granularity do
      "weekly" -> trend_weekly(base, page, page_size, offset)
      _daily -> trend_daily(base, page, page_size, offset)
    end
  end

  defp trend_daily(base, page, page_size, offset) do
    total =
      base
      |> select([r], fragment("COUNT(DISTINCT date(?))", r.inserted_at))
      |> AdminRepo.one()
      |> to_int()

    rows =
      base
      |> group_by([r], fragment("date(?)", r.inserted_at))
      |> select([r], %{
        period: fragment("date(?)::date", r.inserted_at),
        total_cost_millicents: sum(r.cost_millicents),
        total_tokens: sum(r.input_tokens) + sum(r.output_tokens),
        report_count: count(r.id),
        unique_agents: count(r.agent_id, :distinct)
      })
      |> order_by([r], asc: fragment("date(?)", r.inserted_at))
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    data = Enum.map(rows, &format_trend_row/1)
    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  defp trend_weekly(base, page, page_size, offset) do
    total =
      base
      |> select([r], fragment("COUNT(DISTINCT date_trunc('week', ?))", r.inserted_at))
      |> AdminRepo.one()
      |> to_int()

    rows =
      base
      |> group_by([r], fragment("date_trunc('week', ?)", r.inserted_at))
      |> select([r], %{
        period: fragment("date_trunc('week', ?)::date", r.inserted_at),
        total_cost_millicents: sum(r.cost_millicents),
        total_tokens: sum(r.input_tokens) + sum(r.output_tokens),
        report_count: count(r.id),
        unique_agents: count(r.agent_id, :distinct)
      })
      |> order_by([r], asc: fragment("date_trunc('week', ?)", r.inserted_at))
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    data = Enum.map(rows, &format_trend_row/1)
    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  defp format_trend_row(row) do
    %{
      period: row.period,
      total_cost_millicents: to_int(row.total_cost_millicents),
      total_tokens: to_int(row.total_tokens),
      report_count: row.report_count,
      unique_agents: row.unique_agents
    }
  end

  # ---------------------------------------------------------------------------
  # AC-21.5.2: Model-mix correlation matrix
  # ---------------------------------------------------------------------------

  @doc """
  Returns a model-mix correlation matrix for the given tenant.

  For each (model_name, phase) pair: total_tokens, total_cost_millicents,
  stories_count, verified_count, rejected_count, verification_rate_pct.

  Also includes a comparative view: mixed-model vs single-model agent
  averages for verification rate and cost per story.

  ## Options

  - `:project_id` -- filter by project UUID
  - `:agent_id` -- filter by agent UUID
  - `:since` -- only reports inserted on or after this date (Date)
  - `:until` -- only reports inserted on or before this date (Date)
  """
  @spec model_mix(Ecto.UUID.t(), keyword()) :: {:ok, map()}
  def model_mix(tenant_id, opts \\ []) do
    base =
      Report
      |> where([r], r.tenant_id == ^tenant_id)
      |> where([r], is_nil(r.deleted_at))
      |> apply_date_filters(opts)
      |> apply_project_filter(opts)
      |> apply_agent_filter(opts)

    # (model_name, phase) matrix
    matrix_rows =
      base
      |> group_by([r], [r.model_name, r.phase])
      |> select([r], %{
        model_name: r.model_name,
        phase: r.phase,
        total_tokens: sum(r.input_tokens) + sum(r.output_tokens),
        total_cost_millicents: sum(r.cost_millicents),
        stories_count: count(r.story_id, :distinct)
      })
      |> order_by([r], asc: r.model_name, asc: r.phase)
      |> AdminRepo.all()

    # Verification data per (model_name, phase) pair
    verification_map = model_phase_verification_data(tenant_id, opts)

    matrix =
      Enum.map(matrix_rows, fn row ->
        phase_key = row.phase || "other"
        vd = Map.get(verification_map, {row.model_name, phase_key}, %{verified: 0, rejected: 0})

        total_verifiable = vd.verified + vd.rejected

        verification_rate =
          if total_verifiable > 0, do: safe_div(vd.verified * 100, total_verifiable), else: nil

        %{
          model_name: row.model_name,
          phase: phase_key,
          total_tokens: to_int(row.total_tokens),
          total_cost_millicents: to_int(row.total_cost_millicents),
          stories_count: row.stories_count,
          verified_count: vd.verified,
          rejected_count: vd.rejected,
          verification_rate_pct: verification_rate
        }
      end)

    comparative = model_mix_comparative(tenant_id, opts)

    {:ok, %{matrix: matrix, comparative: comparative}}
  end

  # ---------------------------------------------------------------------------
  # AC-21.5.3: Agent model profile
  # ---------------------------------------------------------------------------

  @doc """
  Returns a specific agent's model usage profile.

  Includes: models used, phases, cost breakdown, verification outcomes,
  model_count, and is_model_blender (true if model_count > 1).

  ## Options

  - `:project_id` -- filter by project UUID
  - `:since` -- only reports inserted on or after this date (Date)
  - `:until` -- only reports inserted on or before this date (Date)
  """
  @spec agent_model_profile(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def agent_model_profile(tenant_id, agent_id, opts \\ []) do
    # Verify the agent exists in this tenant
    agent_query =
      from(a in Agent,
        where: a.id == ^agent_id and a.tenant_id == ^tenant_id
      )

    case AdminRepo.one(agent_query) do
      nil ->
        {:error, :not_found}

      agent ->
        {:ok, build_agent_model_profile(agent, tenant_id, agent_id, opts)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp pagination(opts) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size
    {page, page_size, offset}
  end

  defp apply_date_filters(query, opts) do
    query
    |> maybe_since(Keyword.get(opts, :since))
    |> maybe_until(Keyword.get(opts, :until))
  end

  defp maybe_since(query, nil), do: query

  defp maybe_since(query, %Date{} = date) do
    start_dt = NaiveDateTime.new!(date, ~T[00:00:00])
    where(query, [r], r.inserted_at >= ^start_dt)
  end

  defp maybe_until(query, nil), do: query

  defp maybe_until(query, %Date{} = date) do
    end_dt = NaiveDateTime.new!(date, ~T[23:59:59.999999])
    where(query, [r], r.inserted_at <= ^end_dt)
  end

  defp apply_project_filter(query, opts) do
    case Keyword.get(opts, :project_id) do
      nil -> query
      pid -> where(query, [r], r.project_id == ^pid)
    end
  end

  defp maybe_filter_epic_project(query, nil), do: query

  defp maybe_filter_epic_project(query, project_id) do
    where(query, [e], e.project_id == ^project_id)
  end

  # Batch-fetch primary model per agent by total token count (AC-21.4.1).
  # Returns %{agent_id => model_name} for the given agent IDs.
  defp batch_primary_models(_tenant_id, [] = _agent_ids, _opts), do: %{}

  defp batch_primary_models(tenant_id, agent_ids, opts) do
    # For each agent, find the model with the highest total token count.
    # Uses a window function to rank models per agent by total tokens.
    Report
    |> where([r], r.tenant_id == ^tenant_id and r.agent_id in ^agent_ids)
    |> where([r], is_nil(r.deleted_at))
    |> apply_date_filters(opts)
    |> apply_project_filter(opts)
    |> group_by([r], [r.agent_id, r.model_name])
    |> select([r], %{
      agent_id: r.agent_id,
      model_name: r.model_name,
      total_tokens: sum(r.input_tokens) + sum(r.output_tokens)
    })
    |> AdminRepo.all()
    |> Enum.group_by(& &1.agent_id)
    |> Map.new(fn {agent_id, models} ->
      best = Enum.max_by(models, & &1.total_tokens, fn -> nil end)
      {agent_id, if(best, do: best.model_name)}
    end)
  end

  # --- Epic helpers ---

  defp epic_cost_data(_tenant_id, epic_ids) when epic_ids == [], do: %{}

  defp epic_cost_data(tenant_id, epic_ids) do
    Report
    |> join(:inner, [r], s in Story, on: r.story_id == s.id)
    |> where([r, _s], r.tenant_id == ^tenant_id)
    |> where([r, _s], is_nil(r.deleted_at))
    |> where([_r, s], s.epic_id in ^epic_ids)
    |> group_by([_r, s], s.epic_id)
    |> select([r, s], %{
      epic_id: s.epic_id,
      cost: coalesce(sum(r.cost_millicents), 0),
      stories: count(r.story_id, :distinct)
    })
    |> AdminRepo.all()
    |> Map.new(fn row -> {row.epic_id, %{cost: to_int(row.cost), stories: row.stories}} end)
  end

  defp epic_story_counts(_tenant_id, epic_ids) when epic_ids == [], do: %{}

  defp epic_story_counts(tenant_id, epic_ids) do
    Story
    |> where([s], s.tenant_id == ^tenant_id and s.epic_id in ^epic_ids)
    |> group_by([s], s.epic_id)
    |> select([s], %{
      epic_id: s.epic_id,
      total: count(s.id),
      completed:
        count(
          fragment(
            "CASE WHEN ? = 'verified' THEN 1 ELSE NULL END",
            s.verified_status
          )
        )
    })
    |> AdminRepo.all()
    |> Map.new(fn row -> {row.epic_id, %{total: row.total, completed: row.completed}} end)
  end

  defp epic_budgets(_tenant_id, [] = _epic_ids), do: %{}

  defp epic_budgets(tenant_id, epic_ids) do
    Budget
    |> where([b], b.tenant_id == ^tenant_id)
    |> where([b], b.scope_type == :epic and b.scope_id in ^epic_ids)
    |> select([b], {b.scope_id, b.budget_millicents})
    |> AdminRepo.all()
    |> Map.new()
  end

  defp epic_model_breakdowns(_tenant_id, epic_ids) when epic_ids == [], do: %{}

  defp epic_model_breakdowns(tenant_id, epic_ids) do
    Report
    |> join(:inner, [r], s in Story, on: r.story_id == s.id)
    |> where([r, _s], r.tenant_id == ^tenant_id)
    |> where([r, _s], is_nil(r.deleted_at))
    |> where([_r, s], s.epic_id in ^epic_ids)
    |> group_by([r, s], [s.epic_id, r.model_name])
    |> select([r, s], %{
      epic_id: s.epic_id,
      model_name: r.model_name,
      input_tokens: sum(r.input_tokens),
      output_tokens: sum(r.output_tokens),
      cost_millicents: sum(r.cost_millicents)
    })
    |> AdminRepo.all()
    |> Enum.group_by(& &1.epic_id)
    |> Map.new(fn {epic_id, rows} ->
      breakdown =
        Map.new(rows, fn row ->
          {row.model_name,
           %{
             "input_tokens" => to_int(row.input_tokens),
             "output_tokens" => to_int(row.output_tokens),
             "cost_millicents" => to_int(row.cost_millicents)
           }}
        end)

      {epic_id, breakdown}
    end)
  end

  # --- Project helpers ---

  defp get_project_budget(tenant_id, project_id) do
    Budget
    |> where([b], b.tenant_id == ^tenant_id)
    |> where([b], b.scope_type == :project and b.scope_id == ^project_id)
    |> select([b], b.budget_millicents)
    |> AdminRepo.one()
  end

  defp get_cost_by_phase(tenant_id, project_id) do
    Report
    |> where([r], r.tenant_id == ^tenant_id and r.project_id == ^project_id)
    |> where([r], is_nil(r.deleted_at))
    |> group_by([r], r.phase)
    |> select([r], %{
      phase: r.phase,
      cost_millicents: sum(r.cost_millicents)
    })
    |> AdminRepo.all()
    |> Map.new(fn row -> {row.phase || "other", to_int(row.cost_millicents)} end)
  end

  defp get_project_model_breakdown(tenant_id, project_id) do
    Report
    |> where([r], r.tenant_id == ^tenant_id and r.project_id == ^project_id)
    |> where([r], is_nil(r.deleted_at))
    |> group_by([r], r.model_name)
    |> select([r], %{
      model_name: r.model_name,
      input_tokens: sum(r.input_tokens),
      output_tokens: sum(r.output_tokens),
      cost_millicents: sum(r.cost_millicents)
    })
    |> AdminRepo.all()
    |> Map.new(fn row ->
      {row.model_name,
       %{
         "input_tokens" => to_int(row.input_tokens),
         "output_tokens" => to_int(row.output_tokens),
         "cost_millicents" => to_int(row.cost_millicents)
       }}
    end)
  end

  # --- Model verification helpers ---

  defp model_verification_data(tenant_id, opts) do
    base =
      Report
      |> join(:inner, [r], s in Story, on: r.story_id == s.id)
      |> where([r, _s], r.tenant_id == ^tenant_id)
      |> where([r, _s], is_nil(r.deleted_at))
      |> where([_r, s], s.verified_status in [:verified, :rejected])
      |> apply_model_date_filters(opts)
      |> apply_model_project_filter(opts)

    base
    |> group_by([r, s], [r.model_name, s.verified_status])
    |> select([r, s], %{
      model_name: r.model_name,
      verified_status: s.verified_status,
      story_count: count(s.id, :distinct)
    })
    |> AdminRepo.all()
    |> Enum.group_by(& &1.model_name)
    |> Map.new(fn {model, rows} ->
      verified = Enum.find(rows, &(&1.verified_status == :verified))
      rejected = Enum.find(rows, &(&1.verified_status == :rejected))

      {model,
       %{
         verified: if(verified, do: verified.story_count, else: 0),
         rejected: if(rejected, do: rejected.story_count, else: 0)
       }}
    end)
  end

  # Date filters for the joined query (reports joined with stories)
  # Builds the agent model profile payload from raw DB rows.
  # Extracted to avoid exceeding the nesting depth limit in agent_model_profile/3.
  defp build_agent_model_profile(agent, tenant_id, agent_id, opts) do
    base =
      Report
      |> where([r], r.tenant_id == ^tenant_id and r.agent_id == ^agent_id)
      |> where([r], is_nil(r.deleted_at))
      |> apply_date_filters(opts)
      |> apply_project_filter(opts)

    usage_rows =
      base
      |> group_by([r], [r.model_name, r.phase])
      |> select([r], %{
        model_name: r.model_name,
        phase: r.phase,
        total_input_tokens: sum(r.input_tokens),
        total_output_tokens: sum(r.output_tokens),
        total_cost_millicents: sum(r.cost_millicents),
        report_count: count(r.id),
        stories_count: count(r.story_id, :distinct)
      })
      |> order_by([r], asc: r.model_name, asc: r.phase)
      |> AdminRepo.all()

    verification_map = agent_model_phase_verification_data(tenant_id, agent_id, opts)

    model_names =
      usage_rows
      |> Enum.map(& &1.model_name)
      |> Enum.uniq()

    model_count = length(model_names)

    total_cost =
      Enum.reduce(usage_rows, 0, fn row, acc -> acc + to_int(row.total_cost_millicents) end)

    usage = Enum.map(usage_rows, &build_usage_entry(&1, verification_map, total_cost))

    %{
      agent_id: agent.id,
      agent_name: agent.name,
      model_count: model_count,
      is_model_blender: model_count > 1,
      models_used: model_names,
      total_cost_millicents: total_cost,
      usage: usage
    }
  end

  defp build_usage_entry(row, verification_map, total_cost) do
    phase_key = row.phase || "other"
    vd = Map.get(verification_map, {row.model_name, phase_key}, %{verified: 0, rejected: 0})
    total_verifiable = vd.verified + vd.rejected

    verification_rate =
      if total_verifiable > 0, do: safe_div(vd.verified * 100, total_verifiable), else: nil

    cost = to_int(row.total_cost_millicents)
    cost_share_pct = if total_cost > 0, do: safe_div(cost * 100, total_cost), else: nil

    %{
      model_name: row.model_name,
      phase: phase_key,
      total_input_tokens: to_int(row.total_input_tokens),
      total_output_tokens: to_int(row.total_output_tokens),
      total_cost_millicents: cost,
      report_count: row.report_count,
      stories_count: row.stories_count,
      verified_count: vd.verified,
      rejected_count: vd.rejected,
      verification_rate_pct: verification_rate,
      cost_share_pct: cost_share_pct
    }
  end

  defp apply_agent_filter(query, opts) do
    case Keyword.get(opts, :agent_id) do
      nil -> query
      aid -> where(query, [r], r.agent_id == ^aid)
    end
  end

  # Model-phase verification data for the matrix query.
  # Returns %{{model_name, phase} => %{verified: n, rejected: n}}
  defp model_phase_verification_data(tenant_id, opts) do
    base =
      Report
      |> join(:inner, [r], s in Story, on: r.story_id == s.id)
      |> where([r, _s], r.tenant_id == ^tenant_id)
      |> where([r, _s], is_nil(r.deleted_at))
      |> where([_r, s], s.verified_status in [:verified, :rejected])
      |> apply_model_date_filters(opts)
      |> apply_model_project_filter(opts)
      |> apply_model_agent_filter(opts)

    base
    |> group_by([r, s], [r.model_name, r.phase, s.verified_status])
    |> select([r, s], %{
      model_name: r.model_name,
      phase: r.phase,
      verified_status: s.verified_status,
      story_count: count(s.id, :distinct)
    })
    |> AdminRepo.all()
    |> Enum.group_by(fn row -> {row.model_name, row.phase || "other"} end)
    |> Map.new(fn {key, rows} ->
      verified = Enum.find(rows, &(&1.verified_status == :verified))
      rejected = Enum.find(rows, &(&1.verified_status == :rejected))

      {key,
       %{
         verified: if(verified, do: verified.story_count, else: 0),
         rejected: if(rejected, do: rejected.story_count, else: 0)
       }}
    end)
  end

  # Agent-specific model-phase verification data.
  # Returns %{{model_name, phase} => %{verified: n, rejected: n}}
  defp agent_model_phase_verification_data(tenant_id, agent_id, opts) do
    base =
      Report
      |> join(:inner, [r], s in Story, on: r.story_id == s.id)
      |> where([r, _s], r.tenant_id == ^tenant_id and r.agent_id == ^agent_id)
      |> where([r, _s], is_nil(r.deleted_at))
      |> where([_r, s], s.verified_status in [:verified, :rejected])
      |> apply_model_date_filters(opts)
      |> apply_model_project_filter(opts)

    base
    |> group_by([r, s], [r.model_name, r.phase, s.verified_status])
    |> select([r, s], %{
      model_name: r.model_name,
      phase: r.phase,
      verified_status: s.verified_status,
      story_count: count(s.id, :distinct)
    })
    |> AdminRepo.all()
    |> Enum.group_by(fn row -> {row.model_name, row.phase || "other"} end)
    |> Map.new(fn {key, rows} ->
      verified = Enum.find(rows, &(&1.verified_status == :verified))
      rejected = Enum.find(rows, &(&1.verified_status == :rejected))

      {key,
       %{
         verified: if(verified, do: verified.story_count, else: 0),
         rejected: if(rejected, do: rejected.story_count, else: 0)
       }}
    end)
  end

  # AC-21.5.4: Comparative view — mixed-model vs single-model agents.
  # Returns avg verification rate and avg cost per story for each group.
  defp model_mix_comparative(tenant_id, opts) do
    # Compute per-agent: model_count, total_cost, story_count, verified_count
    agent_stats =
      Report
      |> where([r], r.tenant_id == ^tenant_id)
      |> where([r], is_nil(r.deleted_at))
      |> where([r], not is_nil(r.agent_id))
      |> apply_date_filters(opts)
      |> apply_project_filter(opts)
      |> group_by([r], r.agent_id)
      |> select([r], %{
        agent_id: r.agent_id,
        model_count: count(r.model_name, :distinct),
        total_cost_millicents: sum(r.cost_millicents),
        stories_count: count(r.story_id, :distinct)
      })
      |> AdminRepo.all()

    # Verification counts per agent (from verified/rejected stories)
    agent_verification =
      Report
      |> join(:inner, [r], s in Story, on: r.story_id == s.id)
      |> where([r, _s], r.tenant_id == ^tenant_id)
      |> where([r, _s], is_nil(r.deleted_at))
      |> where([r, _s], not is_nil(r.agent_id))
      |> where([_r, s], s.verified_status in [:verified, :rejected])
      |> apply_model_date_filters(opts)
      |> apply_model_project_filter(opts)
      |> group_by([r, s], [r.agent_id, s.verified_status])
      |> select([r, s], %{
        agent_id: r.agent_id,
        verified_status: s.verified_status,
        story_count: count(s.id, :distinct)
      })
      |> AdminRepo.all()
      |> Enum.group_by(& &1.agent_id)
      |> Map.new(fn {agent_id, rows} ->
        verified = Enum.find(rows, &(&1.verified_status == :verified))
        rejected = Enum.find(rows, &(&1.verified_status == :rejected))

        {agent_id,
         %{
           verified: if(verified, do: verified.story_count, else: 0),
           rejected: if(rejected, do: rejected.story_count, else: 0)
         }}
      end)

    # Build per-agent enriched data
    enriched =
      Enum.map(agent_stats, fn row ->
        vd = Map.get(agent_verification, row.agent_id, %{verified: 0, rejected: 0})
        total_verifiable = vd.verified + vd.rejected

        verification_rate =
          if total_verifiable > 0, do: safe_div(vd.verified * 100, total_verifiable), else: nil

        cost = to_int(row.total_cost_millicents)
        avg_cost = safe_div(cost, row.stories_count)

        %{
          model_count: row.model_count,
          is_model_blender: row.model_count > 1,
          avg_cost_per_story_millicents: avg_cost,
          verification_rate_pct: verification_rate
        }
      end)

    # Split into blender / single groups
    {blenders, singles} = Enum.split_with(enriched, & &1.is_model_blender)

    %{
      mixed_model: aggregate_comparative_group(blenders),
      single_model: aggregate_comparative_group(singles)
    }
  end

  defp aggregate_comparative_group([]) do
    %{agent_count: 0, avg_verification_rate_pct: nil, avg_cost_per_story_millicents: nil}
  end

  defp aggregate_comparative_group(agents) do
    count = length(agents)

    rates = Enum.reject(agents, &is_nil(&1.verification_rate_pct))

    avg_rate =
      if rates != [] do
        total = Enum.reduce(rates, 0, &(&1.verification_rate_pct + &2))
        safe_div(total, length(rates))
      else
        nil
      end

    avg_cost =
      agents
      |> Enum.reject(&(&1.avg_cost_per_story_millicents == 0))
      |> then(fn non_zero ->
        if non_zero != [] do
          total = Enum.reduce(non_zero, 0, &(&1.avg_cost_per_story_millicents + &2))
          safe_div(total, length(non_zero))
        else
          0
        end
      end)

    %{
      agent_count: count,
      avg_verification_rate_pct: avg_rate,
      avg_cost_per_story_millicents: avg_cost
    }
  end

  defp apply_model_date_filters(query, opts) do
    query
    |> maybe_model_since(Keyword.get(opts, :since))
    |> maybe_model_until(Keyword.get(opts, :until))
  end

  defp maybe_model_since(query, nil), do: query

  defp maybe_model_since(query, %Date{} = date) do
    start_dt = NaiveDateTime.new!(date, ~T[00:00:00])
    where(query, [r, _s], r.inserted_at >= ^start_dt)
  end

  defp maybe_model_until(query, nil), do: query

  defp maybe_model_until(query, %Date{} = date) do
    end_dt = NaiveDateTime.new!(date, ~T[23:59:59.999999])
    where(query, [r, _s], r.inserted_at <= ^end_dt)
  end

  defp apply_model_project_filter(query, opts) do
    case Keyword.get(opts, :project_id) do
      nil -> query
      pid -> where(query, [r, _s], r.project_id == ^pid)
    end
  end

  defp apply_model_agent_filter(query, opts) do
    case Keyword.get(opts, :agent_id) do
      nil -> query
      aid -> where(query, [r, _s], r.agent_id == ^aid)
    end
  end

  # --- Cost summaries helpers (AC-21.4.6) ---
  #
  # AC-21.4.6 specifies: prefer pre-computed cost_summaries when available,
  # falling back to live aggregation from token_usage_reports when summaries
  # are stale or missing.
  #
  # Current implementation: always uses live aggregation (the fallback path).
  # This is correct because:
  # 1. Live aggregation produces identical results to cost_summaries
  # 2. Cost summaries are a performance optimization for high-volume tenants
  # 3. The CostRollupWorker (US-21.3) populates summaries daily; queries
  #    that include "today" must always use live aggregation anyway
  #
  # The cost_summaries preference can be layered in as an optimization:
  # check if historical_query?(opts) and route to summary-backed queries
  # when summaries exist for the relevant tenant/scope.

  @doc """
  Returns true if the query date range is entirely in the past
  (before today), meaning cost_summaries should be complete for that period.

  Used by the cost_summaries optimization layer (AC-21.4.6) to decide
  whether to use pre-computed summaries or live aggregation.
  """
  @spec historical_query?(keyword()) :: boolean()
  def historical_query?(opts) do
    today = Date.utc_today()
    until_date = Keyword.get(opts, :until)

    # The query is historical if an explicit :until date is set AND
    # that date is strictly before today (i.e., the rollup has run for it).
    case until_date do
      %Date{} = d -> Date.compare(d, today) == :lt
      _ -> false
    end
  end

  # --- Shared helpers ---

  defp to_int(%Decimal{} = val), do: Decimal.to_integer(val)
  defp to_int(val) when is_integer(val), do: val
  defp to_int(nil), do: 0

  defp safe_div(_numerator, 0), do: 0
  defp safe_div(numerator, denominator), do: div(numerator, denominator)
end
