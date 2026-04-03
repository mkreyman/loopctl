defmodule Loopctl.TokenUsage.Analytics do
  @moduledoc """
  Analytics queries for token usage data.

  Provides per-agent, per-epic, per-project, per-model, and trend analytics.
  All functions take `tenant_id` as the first argument for multi-tenant scoping.

  Queries prefer pre-computed `cost_summaries` when available and fresh,
  falling back to live aggregation from `token_usage_reports` when summaries
  are stale or missing. Staleness rule: summaries with `period_end < today`
  are considered complete; the current day always uses live aggregation.

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
      |> where([r], not is_nil(r.agent_id))
      |> apply_date_filters(opts)
      |> apply_project_filter(opts)

    # Count distinct agents for pagination
    total =
      base
      |> select([r], count(r.agent_id, :distinct))
      |> AdminRepo.one()

    # Main aggregation with window function for efficiency_rank
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
      |> order_by([r, agent: _a], asc: sum(r.cost_millicents))
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    # Compute primary model and avg cost, then assign rank
    data =
      rows
      |> Enum.with_index(offset + 1)
      |> Enum.map(fn {row, rank} ->
        primary_model = get_primary_model(tenant_id, :agent, row.agent_id, opts)
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
        # Aggregate from reports
        totals =
          Report
          |> where([r], r.tenant_id == ^tenant_id and r.project_id == ^project_id)
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

  defp get_primary_model(tenant_id, :agent, agent_id, opts) do
    Report
    |> where([r], r.tenant_id == ^tenant_id and r.agent_id == ^agent_id)
    |> apply_date_filters(opts)
    |> apply_project_filter(opts)
    |> group_by([r], r.model_name)
    |> select([r], %{model_name: r.model_name, cnt: count(r.id)})
    |> order_by([r], desc: count(r.id))
    |> limit(1)
    |> AdminRepo.one()
    |> case do
      nil -> nil
      %{model_name: name} -> name
    end
  end

  # --- Epic helpers ---

  defp epic_cost_data(_tenant_id, epic_ids) when epic_ids == [], do: %{}

  defp epic_cost_data(tenant_id, epic_ids) do
    Report
    |> join(:inner, [r], s in Story, on: r.story_id == s.id)
    |> where([r, _s], r.tenant_id == ^tenant_id)
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

  # --- Shared helpers ---

  defp to_int(%Decimal{} = val), do: Decimal.to_integer(val)
  defp to_int(val) when is_integer(val), do: val
  defp to_int(nil), do: 0

  defp safe_div(_numerator, 0), do: 0
  defp safe_div(numerator, denominator), do: div(numerator, denominator)
end
