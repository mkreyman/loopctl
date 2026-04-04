defmodule Loopctl.TokenUsage.DefaultRollup do
  @moduledoc """
  Default implementation of `Loopctl.TokenUsage.RollupBehaviour`.

  Aggregates token usage reports for a tenant within a date range,
  producing cost summaries grouped by scope type (agent, epic, project).

  The aggregation queries use `AdminRepo` because the caller
  (`CostRollupWorker`) runs from a cron job context without
  per-tenant RLS transactions.
  """

  @behaviour Loopctl.TokenUsage.RollupBehaviour

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.TokenUsage.Report
  alias Loopctl.WorkBreakdown.Story

  @impl true
  def aggregate(tenant_id, period_start, period_end) do
    # Convert dates to NaiveDateTime for comparison with timestamps
    start_dt = NaiveDateTime.new!(period_start, ~T[00:00:00])
    end_dt = NaiveDateTime.new!(period_end, ~T[23:59:59.999999])

    agent_rows = aggregate_by_agent(tenant_id, start_dt, end_dt)
    epic_rows = aggregate_by_epic(tenant_id, start_dt, end_dt)
    project_rows = aggregate_by_project(tenant_id, start_dt, end_dt)

    {:ok, agent_rows ++ epic_rows ++ project_rows}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # --- Agent scope ---
  defp aggregate_by_agent(tenant_id, start_dt, end_dt) do
    Report
    |> where([r], r.tenant_id == ^tenant_id)
    |> where([r], is_nil(r.deleted_at))
    |> where([r], r.inserted_at >= ^start_dt and r.inserted_at <= ^end_dt)
    |> where([r], not is_nil(r.agent_id))
    |> group_by([r], r.agent_id)
    |> select([r], %{
      scope_id: r.agent_id,
      total_input_tokens: sum(r.input_tokens),
      total_output_tokens: sum(r.output_tokens),
      total_cost_millicents: sum(r.cost_millicents),
      report_count: count(r.id)
    })
    |> AdminRepo.all()
    |> Enum.map(fn row ->
      model_breakdown = build_model_breakdown(tenant_id, :agent, row.scope_id, start_dt, end_dt)

      %{
        scope_type: :agent,
        scope_id: row.scope_id,
        total_input_tokens: to_int(row.total_input_tokens),
        total_output_tokens: to_int(row.total_output_tokens),
        total_cost_millicents: to_int(row.total_cost_millicents),
        report_count: row.report_count,
        model_breakdown: model_breakdown,
        avg_cost_per_story_millicents: nil
      }
    end)
  end

  # --- Epic scope ---
  defp aggregate_by_epic(tenant_id, start_dt, end_dt) do
    Report
    |> join(:inner, [r], s in Story, on: r.story_id == s.id)
    |> where([r, _s], r.tenant_id == ^tenant_id)
    |> where([r, _s], is_nil(r.deleted_at))
    |> where([r, _s], r.inserted_at >= ^start_dt and r.inserted_at <= ^end_dt)
    |> group_by([_r, s], s.epic_id)
    |> select([r, s], %{
      scope_id: s.epic_id,
      total_input_tokens: sum(r.input_tokens),
      total_output_tokens: sum(r.output_tokens),
      total_cost_millicents: sum(r.cost_millicents),
      report_count: count(r.id),
      distinct_stories: count(r.story_id, :distinct)
    })
    |> AdminRepo.all()
    |> Enum.map(fn row ->
      model_breakdown = build_model_breakdown(tenant_id, :epic, row.scope_id, start_dt, end_dt)

      avg =
        if row.distinct_stories > 0,
          do: div(to_int(row.total_cost_millicents), row.distinct_stories),
          else: nil

      %{
        scope_type: :epic,
        scope_id: row.scope_id,
        total_input_tokens: to_int(row.total_input_tokens),
        total_output_tokens: to_int(row.total_output_tokens),
        total_cost_millicents: to_int(row.total_cost_millicents),
        report_count: row.report_count,
        model_breakdown: model_breakdown,
        avg_cost_per_story_millicents: avg
      }
    end)
  end

  # --- Project scope ---
  defp aggregate_by_project(tenant_id, start_dt, end_dt) do
    Report
    |> where([r], r.tenant_id == ^tenant_id)
    |> where([r], is_nil(r.deleted_at))
    |> where([r], r.inserted_at >= ^start_dt and r.inserted_at <= ^end_dt)
    |> where([r], not is_nil(r.project_id))
    |> group_by([r], r.project_id)
    |> select([r], %{
      scope_id: r.project_id,
      total_input_tokens: sum(r.input_tokens),
      total_output_tokens: sum(r.output_tokens),
      total_cost_millicents: sum(r.cost_millicents),
      report_count: count(r.id),
      distinct_stories: count(r.story_id, :distinct)
    })
    |> AdminRepo.all()
    |> Enum.map(fn row ->
      model_breakdown = build_model_breakdown(tenant_id, :project, row.scope_id, start_dt, end_dt)

      avg =
        if row.distinct_stories > 0,
          do: div(to_int(row.total_cost_millicents), row.distinct_stories),
          else: nil

      %{
        scope_type: :project,
        scope_id: row.scope_id,
        total_input_tokens: to_int(row.total_input_tokens),
        total_output_tokens: to_int(row.total_output_tokens),
        total_cost_millicents: to_int(row.total_cost_millicents),
        report_count: row.report_count,
        model_breakdown: model_breakdown,
        avg_cost_per_story_millicents: avg
      }
    end)
  end

  # --- Model breakdown ---
  defp build_model_breakdown(tenant_id, scope_type, scope_id, start_dt, end_dt) do
    query = scope_breakdown_query(scope_type, scope_id, tenant_id, start_dt, end_dt)

    query
    |> AdminRepo.all()
    |> Enum.reduce(%{}, fn row, acc ->
      model = row.model_name
      phase = row.phase || "other"

      phase_data = %{
        "input_tokens" => to_int(row.input_tokens),
        "output_tokens" => to_int(row.output_tokens),
        "cost_millicents" => to_int(row.cost_millicents)
      }

      model_data = Map.get(acc, model, %{})
      Map.put(acc, model, Map.put(model_data, phase, phase_data))
    end)
  end

  defp scope_breakdown_query(:agent, scope_id, tenant_id, start_dt, end_dt) do
    Report
    |> where([r], r.agent_id == ^scope_id)
    |> where([r], r.tenant_id == ^tenant_id)
    |> where([r], is_nil(r.deleted_at))
    |> where([r], r.inserted_at >= ^start_dt and r.inserted_at <= ^end_dt)
    |> group_by([r], [r.model_name, r.phase])
    |> select([r], %{
      model_name: r.model_name,
      phase: r.phase,
      input_tokens: sum(r.input_tokens),
      output_tokens: sum(r.output_tokens),
      cost_millicents: sum(r.cost_millicents)
    })
  end

  defp scope_breakdown_query(:epic, scope_id, tenant_id, start_dt, end_dt) do
    Report
    |> join(:inner, [r], s in Story, on: r.story_id == s.id)
    |> where([r, _s], r.tenant_id == ^tenant_id)
    |> where([r, _s], is_nil(r.deleted_at))
    |> where([r, _s], r.inserted_at >= ^start_dt and r.inserted_at <= ^end_dt)
    |> where([_r, s], s.epic_id == ^scope_id)
    |> group_by([r, _s], [r.model_name, r.phase])
    |> select([r, _s], %{
      model_name: r.model_name,
      phase: r.phase,
      input_tokens: sum(r.input_tokens),
      output_tokens: sum(r.output_tokens),
      cost_millicents: sum(r.cost_millicents)
    })
  end

  defp scope_breakdown_query(:project, scope_id, tenant_id, start_dt, end_dt) do
    Report
    |> where([r], r.project_id == ^scope_id)
    |> where([r], r.tenant_id == ^tenant_id)
    |> where([r], is_nil(r.deleted_at))
    |> where([r], r.inserted_at >= ^start_dt and r.inserted_at <= ^end_dt)
    |> group_by([r], [r.model_name, r.phase])
    |> select([r], %{
      model_name: r.model_name,
      phase: r.phase,
      input_tokens: sum(r.input_tokens),
      output_tokens: sum(r.output_tokens),
      cost_millicents: sum(r.cost_millicents)
    })
  end

  defp to_int(%Decimal{} = val), do: Decimal.to_integer(val)
  defp to_int(val) when is_integer(val), do: val
  defp to_int(nil), do: 0
end
