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
  alias Loopctl.Agents.Agent
  alias Loopctl.Audit
  alias Loopctl.Tenants.Tenant
  alias Loopctl.TokenUsage.CostAnomaly
  alias Loopctl.TokenUsage.CostSummary
  alias Loopctl.TokenUsage.Report
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.WebhookDeliveryWorker

  @high_cost_threshold Decimal.new("3.0")
  @low_cost_threshold Decimal.new("0.1")

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    {period_start, period_end} = resolve_period(args)

    tenants = list_active_tenants()
    Logger.info("CostAnomalyWorker: scanning #{length(tenants)} tenants for anomalies")

    Enum.each(tenants, fn tenant ->
      detect_anomalies(tenant.id, period_start, period_end)
    end)

    :ok
  end

  defp detect_anomalies(tenant_id, period_start, period_end) do
    # Which epics to (re-)evaluate this run: those that were rolled up in the
    # period. The rollup writes DAILY epic summaries (period_start == period_end
    # == day), so a backfill range D1..D3 is covered by matching any summary
    # whose period_start falls within [period_start, period_end] rather than an
    # exact (start, end) pair (tokens-09 consistency).
    epic_ids =
      CostSummary
      |> where([cs], cs.tenant_id == ^tenant_id)
      |> where([cs], cs.scope_type == :epic)
      |> where([cs], cs.period_start >= ^period_start and cs.period_start <= ^period_end)
      |> select([cs], cs.scope_id)
      |> distinct(true)
      |> AdminRepo.all()

    if epic_ids != [] do
      check_all_epic_stories(tenant_id, epic_ids)
    end

    :ok
  end

  # Anomaly detection compares LIKE-FOR-LIKE: a story's CUMULATIVE lifetime cost
  # against the epic's per-story average of those same cumulative totals
  # (tokens-06). Using a single day's slice both (a) missed multi-day-expensive
  # stories whose per-day cost stayed under threshold, and (b) produced false
  # `suspiciously_low` flags when an already-counted story got a tiny follow-up
  # report on a later day. There is deliberately NO inserted_at window here.
  #
  # Issues ONE query for per-story lifetime costs across ALL epics, then
  # processes in memory.
  defp check_all_epic_stories(tenant_id, epic_ids) do
    story_costs =
      Report
      |> join(:inner, [r], s in Story, on: r.story_id == s.id)
      |> where([r, _s], r.tenant_id == ^tenant_id)
      |> where([r, _s], is_nil(r.deleted_at))
      |> Report.exclude_stranded_corrections()
      |> where([_r, s], s.epic_id in ^epic_ids)
      |> group_by([r, s], [r.story_id, s.epic_id])
      |> select([r, s], %{
        story_id: r.story_id,
        epic_id: s.epic_id,
        total_cost: sum(r.cost_millicents)
      })
      |> AdminRepo.all()

    epic_avg_map = build_epic_avg_map(story_costs)

    Enum.each(story_costs, fn %{story_id: story_id, epic_id: epic_id, total_cost: total_cost} ->
      epic_avg = Map.get(epic_avg_map, epic_id)
      cost = to_int(total_cost)
      check_and_flag_anomaly(tenant_id, story_id, cost, epic_avg)
    end)
  end

  # Epic per-story-total average, computed from the same cumulative story totals
  # we compare against (each story counted once).
  defp build_epic_avg_map(story_costs) do
    story_costs
    |> Enum.group_by(& &1.epic_id)
    |> Map.new(fn {epic_id, stories} ->
      totals = Enum.map(stories, &to_int(&1.total_cost))
      count = length(totals)
      avg = if count > 0, do: div(Enum.sum(totals), count), else: 0
      {epic_id, avg}
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
    # Check if an unresolved anomaly of this type already exists for this story.
    # The unique partial index (cost_anomalies_unresolved_unique) prevents races,
    # but we still check first so that updates do NOT emit audit/webhook events.
    existing =
      CostAnomaly
      |> where([a], a.tenant_id == ^tenant_id)
      |> where([a], a.story_id == ^story_id)
      |> where([a], a.anomaly_type == ^anomaly_type)
      |> where([a], a.resolved == false)
      |> AdminRepo.one()

    if existing do
      # Update the existing anomaly with latest figures (no audit/webhook)
      case existing
           |> CostAnomaly.create_changeset(%{
             story_cost_millicents: story_cost,
             reference_avg_millicents: epic_avg,
             deviation_factor: Decimal.round(factor, 2)
           })
           |> AdminRepo.update() do
        {:ok, updated} ->
          updated

        {:error, changeset} ->
          Logger.warning(
            "CostAnomalyWorker: failed to update anomaly #{existing.id}: #{inspect(changeset.errors)}"
          )

          existing
      end
    else
      changeset =
        %CostAnomaly{tenant_id: tenant_id, story_id: story_id}
        |> CostAnomaly.create_changeset(%{
          anomaly_type: anomaly_type,
          story_cost_millicents: story_cost,
          reference_avg_millicents: epic_avg,
          deviation_factor: Decimal.round(factor, 2)
        })

      # Use on_conflict: :nothing to gracefully handle a race with the unique
      # partial index (cost_anomalies_unresolved_unique) -- ADV-3.
      case AdminRepo.insert(changeset,
             on_conflict: :nothing,
             conflict_target:
               {:unsafe_fragment,
                ~s|("tenant_id","story_id","anomaly_type") WHERE resolved = false|}
           ) do
        {:ok, anomaly} ->
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

          # Fire token.anomaly_detected webhook event (AC-21.7.7)
          fire_anomaly_webhook(tenant_id, anomaly)

          anomaly

        {:error, changeset} ->
          Logger.warning(
            "CostAnomalyWorker: failed to insert anomaly for story #{story_id}: #{inspect(changeset.errors)}"
          )

          nil
      end
    end
  end

  # Fires a token.anomaly_detected webhook for newly created anomalies.
  # Looks up story title and agent name for a rich payload. Passes project_id
  # so project-scoped webhooks also receive anomaly events.
  # Errors are caught and logged rather than bubbling up (the anomaly record
  # is already created; losing the webhook should not lose the anomaly).
  defp fire_anomaly_webhook(tenant_id, anomaly) do
    {story_title, agent_id, agent_name, project_id} =
      fetch_story_context(anomaly.story_id, tenant_id)

    webhooks =
      EventGenerator.matching_webhooks(tenant_id, "token.anomaly_detected", project_id)

    if webhooks != [] do
      payload = %{
        "anomaly_id" => anomaly.id,
        "story_id" => anomaly.story_id,
        "story_title" => story_title,
        "agent_id" => agent_id,
        "agent_name" => agent_name,
        "anomaly_type" => to_string(anomaly.anomaly_type),
        "story_cost_millicents" => anomaly.story_cost_millicents,
        "reference_avg_millicents" => anomaly.reference_avg_millicents,
        "deviation_factor" => Decimal.to_string(anomaly.deviation_factor)
      }

      Enum.each(webhooks, &deliver_anomaly_event(tenant_id, &1, payload, anomaly.id))
    end
  end

  # Delivers a single anomaly webhook event. Errors are logged, not raised.
  defp deliver_anomaly_event(tenant_id, webhook, payload, anomaly_id) do
    with {:ok, event} <-
           %WebhookEvent{tenant_id: tenant_id, webhook_id: webhook.id}
           |> WebhookEvent.create_changeset(%{
             event_type: "token.anomaly_detected",
             payload: payload
           })
           |> AdminRepo.insert(),
         {:ok, _job} <-
           WebhookDeliveryWorker.new(%{webhook_event_id: event.id, tenant_id: tenant_id})
           |> Oban.insert() do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "Failed to create token.anomaly_detected webhook event " <>
            "for anomaly #{anomaly_id}: #{inspect(reason)}"
        )
    end
  end

  # Fetches story title, assigned agent name, and project_id for the anomaly webhook payload.
  # Returns {story_title, agent_id, agent_name, project_id} with nil fallbacks.
  defp fetch_story_context(story_id, tenant_id) do
    story = AdminRepo.get_by(Story, id: story_id, tenant_id: tenant_id)

    case story do
      nil ->
        {nil, nil, nil, nil}

      %Story{assigned_agent_id: nil} ->
        {story.title, nil, nil, story.project_id}

      %Story{assigned_agent_id: agent_id} ->
        agent = AdminRepo.get_by(Agent, id: agent_id, tenant_id: tenant_id)
        agent_name = if agent, do: agent.name, else: nil
        {story.title, agent_id, agent_name, story.project_id}
    end
  end

  defp resolve_period(args) do
    case {Map.get(args, "period_start"), Map.get(args, "period_end")} do
      {nil, nil} ->
        yesterday = Date.add(Date.utc_today(), -1)
        {yesterday, yesterday}

      {start_str, end_str} when is_binary(start_str) and is_binary(end_str) ->
        yesterday = Date.add(Date.utc_today(), -1)

        start_date =
          case Date.from_iso8601(start_str) do
            {:ok, d} ->
              d

            {:error, _} ->
              Logger.warning(
                "CostAnomalyWorker: malformed period_start #{inspect(start_str)}, defaulting to yesterday"
              )

              yesterday
          end

        end_date =
          case Date.from_iso8601(end_str) do
            {:ok, d} ->
              d

            {:error, _} ->
              Logger.warning(
                "CostAnomalyWorker: malformed period_end #{inspect(end_str)}, defaulting to yesterday"
              )

              yesterday
          end

        {start_date, end_date}

      other ->
        Logger.warning(
          "CostAnomalyWorker: invalid period args #{inspect(other)}, defaulting to yesterday"
        )

        yesterday = Date.add(Date.utc_today(), -1)
        {yesterday, yesterday}
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
