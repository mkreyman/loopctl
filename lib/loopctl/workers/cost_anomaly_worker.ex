defmodule Loopctl.Workers.CostAnomalyWorker do
  @moduledoc """
  Oban worker that detects cost anomalies after each daily rollup.

  Compares each story's total cost to its epic's average cost per story.
  Stories that deviate significantly are flagged as anomalies:

  - `high_cost` -- story cost > 3x the epic average
  - `suspiciously_low` -- story cost < 0.1x the epic average

  Runs after `CostRollupWorker` completes, chained via `Oban.insert/1`.

  ## Thresholds

  Hardcoded defaults for v1:
  - High cost: 3.0x average
  - Suspiciously low: 0.1x average
  """

  use Oban.Worker, queue: :analytics, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Tenants.Tenant
  alias Loopctl.TokenUsage.CostAnomaly
  alias Loopctl.TokenUsage.CostSummary
  alias Loopctl.TokenUsage.Report
  alias Loopctl.WorkBreakdown.Story

  @high_cost_threshold Decimal.new("3.0")
  @low_cost_threshold Decimal.new("0.1")

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    {period_start, period_end} = resolve_period(args)

    tenants = list_active_tenants()
    Logger.info("CostAnomalyWorker: scanning #{length(tenants)} tenants for anomalies")

    Enum.each(tenants, fn tenant ->
      case detect_anomalies(tenant.id, period_start, period_end) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("CostAnomalyWorker: failed for tenant #{tenant.id}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp detect_anomalies(tenant_id, period_start, period_end) do
    # Get epic summaries for this period that have an avg cost
    epic_summaries =
      CostSummary
      |> where([cs], cs.tenant_id == ^tenant_id)
      |> where([cs], cs.scope_type == :epic)
      |> where([cs], cs.period_start == ^period_start)
      |> where([cs], cs.period_end == ^period_end)
      |> where([cs], not is_nil(cs.avg_cost_per_story_millicents))
      |> where([cs], cs.avg_cost_per_story_millicents > 0)
      |> AdminRepo.all()

    # For each epic, get per-story costs in this period
    Enum.each(epic_summaries, fn summary ->
      check_epic_stories(tenant_id, summary, period_start, period_end)
    end)

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp check_epic_stories(tenant_id, epic_summary, period_start, period_end) do
    start_dt = NaiveDateTime.new!(period_start, ~T[00:00:00])
    end_dt = NaiveDateTime.new!(period_end, ~T[23:59:59.999999])
    epic_avg = epic_summary.avg_cost_per_story_millicents

    # Get per-story costs for this epic in the period
    story_costs =
      Report
      |> join(:inner, [r], s in Story, on: r.story_id == s.id)
      |> where([r, s], r.tenant_id == ^tenant_id)
      |> where([_r, s], s.epic_id == ^epic_summary.scope_id)
      |> where([r, _s], r.inserted_at >= ^start_dt and r.inserted_at <= ^end_dt)
      |> group_by([r, _s], r.story_id)
      |> select([r, _s], %{
        story_id: r.story_id,
        total_cost: sum(r.cost_millicents)
      })
      |> AdminRepo.all()

    Enum.each(story_costs, fn %{story_id: story_id, total_cost: total_cost} ->
      cost = to_int(total_cost)
      check_and_flag_anomaly(tenant_id, story_id, cost, epic_avg)
    end)
  end

  defp check_and_flag_anomaly(tenant_id, story_id, story_cost, epic_avg) when epic_avg > 0 do
    factor = Decimal.div(Decimal.new(story_cost), Decimal.new(epic_avg))

    cond do
      Decimal.compare(factor, @high_cost_threshold) == :gt ->
        create_anomaly(tenant_id, story_id, :high_cost, story_cost, epic_avg, factor)

      Decimal.compare(factor, @low_cost_threshold) == :lt ->
        create_anomaly(tenant_id, story_id, :suspiciously_low, story_cost, epic_avg, factor)

      true ->
        :ok
    end
  end

  defp check_and_flag_anomaly(_tenant_id, _story_id, _story_cost, _epic_avg), do: :ok

  defp create_anomaly(tenant_id, story_id, anomaly_type, story_cost, epic_avg, factor) do
    # Check if an unresolved anomaly of this type already exists for this story
    existing =
      CostAnomaly
      |> where([a], a.tenant_id == ^tenant_id)
      |> where([a], a.story_id == ^story_id)
      |> where([a], a.anomaly_type == ^anomaly_type)
      |> where([a], a.resolved == false)
      |> AdminRepo.one()

    if existing do
      # Update the existing anomaly with latest figures
      existing
      |> CostAnomaly.create_changeset(%{
        story_cost_millicents: story_cost,
        reference_avg_millicents: epic_avg,
        deviation_factor: Decimal.round(factor, 2)
      })
      |> AdminRepo.update!()
    else
      anomaly =
        %CostAnomaly{tenant_id: tenant_id, story_id: story_id}
        |> CostAnomaly.create_changeset(%{
          anomaly_type: anomaly_type,
          story_cost_millicents: story_cost,
          reference_avg_millicents: epic_avg,
          deviation_factor: Decimal.round(factor, 2)
        })
        |> AdminRepo.insert!()

      # Emit change feed + audit log entry for the newly detected anomaly (AC-21.8.3, AC-21.8.5)
      Audit.create_log_entry(tenant_id, %{
        entity_type: "cost_anomaly",
        entity_id: anomaly.id,
        action: "detected",
        actor_type: "system",
        new_state: %{
          "anomaly_type" => to_string(anomaly.anomaly_type),
          "story_id" => anomaly.story_id,
          "deviation_factor" => Decimal.to_string(anomaly.deviation_factor),
          "story_cost_millicents" => anomaly.story_cost_millicents,
          "reference_avg_millicents" => anomaly.reference_avg_millicents
        },
        metadata: %{
          "anomaly_id" => anomaly.id,
          "story_id" => anomaly.story_id,
          "anomaly_type" => to_string(anomaly.anomaly_type),
          "deviation_factor" => Decimal.to_string(anomaly.deviation_factor)
        }
      })

      anomaly
    end
  end

  defp resolve_period(args) do
    case {Map.get(args, "period_start"), Map.get(args, "period_end")} do
      {nil, nil} ->
        yesterday = Date.add(Date.utc_today(), -1)
        {yesterday, yesterday}

      {start_str, end_str} ->
        {Date.from_iso8601!(start_str), Date.from_iso8601!(end_str)}
    end
  end

  defp list_active_tenants do
    Tenant
    |> where([t], t.status == :active)
    |> AdminRepo.all()
  end

  defp to_int(%Decimal{} = val), do: Decimal.to_integer(val)
  defp to_int(val) when is_integer(val), do: val
  defp to_int(nil), do: 0
end
