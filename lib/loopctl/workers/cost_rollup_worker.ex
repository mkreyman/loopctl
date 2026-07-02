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

    # cost_summaries are DAILY-granularity rows keyed on the unique index
    # (tenant_id, scope_type, scope_id, period_start). A multi-day range is a
    # backfill: roll up and upsert EACH day independently (each day is the
    # window [day, day]) so daily summaries stay correct and a range never
    # collapses into a single overwriting row at period_start (tokens-09).
    days = Date.range(period_start, period_end)

    tenants = list_active_tenants(args)

    Logger.info(
      "CostRollupWorker: starting rollup for #{length(tenants)} tenant(s) over #{Enum.count(days)} day(s)"
    )

    failures =
      for tenant <- tenants, day <- days, reduce: [] do
        acc ->
          case rollup_tenant(tenant.id, day, day) do
            :ok ->
              acc

            {:error, reason} ->
              Logger.warning(
                "CostRollupWorker: failed for tenant #{tenant.id} on #{Date.to_iso8601(day)}: " <>
                  "#{inspect(reason)}"
              )

              [{tenant.id, day, reason} | acc]
          end
      end

    # Chain the anomaly worker regardless of partial failures so that
    # successful tenants still get anomaly detection (ADV-11). Both the upsert
    # and the chained job are idempotent, so a retry of this job re-runs them
    # safely.
    chain_anomaly_worker(period_start, period_end)

    handle_failures(failures)
  end

  # A failed tenant/day rollup (e.g. a transient DB timeout or connection drop)
  # must NOT be reported as success -- Oban treats :ok as done and would never
  # retry, permanently losing that day's cost_summaries (tokens-08). Succeeded
  # tenant/days are already persisted via the idempotent upsert, so returning an
  # error only re-computes identical rows for them on retry while giving the
  # failed ones another attempt. Failed tenant ids are surfaced for observability.
  defp handle_failures([]), do: :ok

  defp handle_failures(failures) do
    failed_tenant_ids =
      failures |> Enum.map(fn {tenant_id, _day, _reason} -> tenant_id end) |> Enum.uniq()

    Logger.warning(
      "CostRollupWorker: #{length(failures)} tenant/day rollup(s) failed across " <>
        "#{length(failed_tenant_ids)} tenant(s); returning error so Oban retries"
    )

    {:error, {:rollup_failed, failed_tenant_ids}}
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

      {start_str, end_str} when is_binary(start_str) and is_binary(end_str) ->
        yesterday = Date.add(Date.utc_today(), -1)

        start_date =
          case Date.from_iso8601(start_str) do
            {:ok, d} ->
              d

            {:error, _} ->
              Logger.warning(
                "CostRollupWorker: malformed period_start #{inspect(start_str)}, defaulting to yesterday"
              )

              yesterday
          end

        end_date =
          case Date.from_iso8601(end_str) do
            {:ok, d} ->
              d

            {:error, _} ->
              Logger.warning(
                "CostRollupWorker: malformed period_end #{inspect(end_str)}, defaulting to yesterday"
              )

              yesterday
          end

        {start_date, end_date}

      other ->
        Logger.warning(
          "CostRollupWorker: invalid period args #{inspect(other)}, defaulting to yesterday"
        )

        yesterday = Date.add(Date.utc_today(), -1)
        {yesterday, yesterday}
    end
  end

  defp list_active_tenants(%{"tenant_ids" => ids}) when is_list(ids) and ids != [] do
    import Ecto.Query

    Tenant
    |> where([t], t.status == :active and t.id in ^ids)
    |> AdminRepo.all()
  end

  defp list_active_tenants(_args) do
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
