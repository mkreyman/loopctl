defmodule Loopctl.Workers.CostRollupWorker do
  @moduledoc """
  Oban worker that computes daily cost summaries for all active tenants.

  Runs daily at 02:00 UTC via Oban Cron (`0 2 * * *`). For each active
  tenant, aggregates token usage reports from the previous day into
  `cost_summaries` records grouped by scope (agent, epic, project).

  The rollup is idempotent: uses UPSERT keyed on the composite unique
  index `(tenant_id, scope_type, scope_id, period_start)`.

  After completing all tenant rollups, chains the `CostAnomalyWorker`
  to detect cost anomalies.

  ## DI

  Uses compile-time DI for the rollup service:

      @rollup_service Application.compile_env(:loopctl, :cost_rollup, Loopctl.TokenUsage.DefaultRollup)

  In test, `config/test.exs` maps to `Loopctl.MockCostRollup`.
  """

  use Oban.Worker, queue: :analytics, max_attempts: 3

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.TokenUsage.CostSummary
  alias Loopctl.Workers.CostAnomalyWorker

  @rollup_service Application.compile_env(
                    :loopctl,
                    :cost_rollup,
                    Loopctl.TokenUsage.DefaultRollup
                  )

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Allow overriding the period for testing/backfills
    {period_start, period_end} = resolve_period(args)

    tenants = list_active_tenants()
    Logger.info("CostRollupWorker: starting rollup for #{length(tenants)} tenants")

    results =
      Enum.map(tenants, fn tenant ->
        case rollup_tenant(tenant.id, period_start, period_end) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("CostRollupWorker: failed for tenant #{tenant.id}: #{inspect(reason)}")

            {:error, tenant.id, reason}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _, _}, &1))

    if errors == [] do
      # Chain the anomaly worker after successful rollup
      chain_anomaly_worker(period_start, period_end)
      :ok
    else
      Logger.warning("CostRollupWorker: #{length(errors)} tenant(s) failed")
      # Return :ok so the job is not retried for partial failures.
      # Individual tenant failures are logged above.
      :ok
    end
  end

  @doc false
  def rollup_tenant(tenant_id, period_start, period_end) do
    case @rollup_service.aggregate(tenant_id, period_start, period_end) do
      {:ok, rows} ->
        upsert_summaries(tenant_id, rows, period_start, period_end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_summaries(tenant_id, rows, period_start, period_end) do
    Enum.each(rows, fn row ->
      changeset =
        %CostSummary{tenant_id: tenant_id}
        |> CostSummary.changeset(
          Map.merge(row, %{
            period_start: period_start,
            period_end: period_end,
            stale: false
          })
        )

      AdminRepo.insert!(changeset,
        on_conflict:
          {:replace,
           [
             :period_end,
             :total_input_tokens,
             :total_output_tokens,
             :total_cost_millicents,
             :report_count,
             :model_breakdown,
             :avg_cost_per_story_millicents,
             :stale,
             :updated_at
           ]},
        conflict_target: [:tenant_id, :scope_type, :scope_id, :period_start]
      )
    end)

    :ok
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
    import Ecto.Query

    Tenant
    |> where([t], t.status == :active)
    |> AdminRepo.all()
  end

  defp chain_anomaly_worker(period_start, period_end) do
    %{
      "period_start" => Date.to_iso8601(period_start),
      "period_end" => Date.to_iso8601(period_end)
    }
    |> CostAnomalyWorker.new(scheduled_at: scheduled_anomaly_time())
    |> Oban.insert()
  end

  # Schedule the anomaly worker 5 minutes after the rollup
  defp scheduled_anomaly_time do
    DateTime.add(DateTime.utc_now(), 300, :second)
  end
end
