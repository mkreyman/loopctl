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

  # A backfill wider than this is almost certainly a typo (a normal nightly run
  # is one day; a legitimate backfill is a few weeks). The per-day loop is
  # O(tenants x days), so an unbounded range would monopolize one of the few
  # :analytics queue slots. Clamp instead of running unbounded (tokens-03/FIX3).
  @max_backfill_days 90

  # Backstop timeout so a pathological range can never occupy an :analytics slot
  # indefinitely (the queue is shared with CostAnomalyWorker + CoT sanity work).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

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
    # successful tenants still get anomaly detection (ADV-11). The chained job
    # is deduplicated (CostAnomalyWorker is `unique` on the period args), so a
    # retry of this job does not multiply anomaly jobs or their notifications.
    chain_anomaly_worker(period_start, period_end)

    handle_failures(failures, args)
  end

  # A failed tenant/day rollup (e.g. a transient DB timeout or connection drop)
  # must NOT be reported as success -- Oban treats :ok as done and would never
  # retry, permanently losing that day's cost_summaries (tokens-08). Succeeded
  # tenant/days are already persisted via the idempotent upsert.
  defp handle_failures([], _args), do: :ok

  defp handle_failures(failures, args) do
    failed_tenant_ids =
      failures |> Enum.map(fn {tenant_id, _day, _reason} -> tenant_id end) |> Enum.uniq()

    if scoped_retry?(args) do
      # This job is ALREADY a scoped follow-up. Do NOT re-enqueue another (that
      # would be an unbounded loop) -- return an error and let Oban's bounded
      # retry (max_attempts + backoff) handle it (FIX4).
      Logger.warning(
        "CostRollupWorker: scoped retry still failing for tenant(s) " <>
          "#{inspect(failed_tenant_ids)}; returning error for Oban retry"
      )

      {:error, {:rollup_failed, failed_tenant_ids}}
    else
      # Top-level batch: re-enqueue a NARROW follow-up scoped to only the failed
      # tenant/day pairs so healthy tenants/days are not re-computed, then report
      # success so Oban doesn't re-run the whole batch (FIX4). If enqueueing the
      # scoped retry itself fails, fall back to a bounded whole-batch retry so the
      # failure is never silently dropped.
      case enqueue_scoped_retries(failures) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "CostRollupWorker: could not enqueue scoped retry (#{inspect(reason)}); " <>
              "falling back to whole-batch retry"
          )

          {:error, {:rollup_failed, failed_tenant_ids}}
      end
    end
  end

  # Re-enqueue one narrow follow-up job per failed day, carrying only that day's
  # failed tenant ids. Tagged `scoped_retry` so the follow-up uses Oban's native
  # bounded retry instead of re-enqueueing again.
  defp enqueue_scoped_retries(failures) do
    failures
    |> Enum.group_by(
      fn {_tenant_id, day, _reason} -> day end,
      fn {tenant_id, _day, _reason} -> tenant_id end
    )
    |> Enum.reduce_while(:ok, fn {day, tenant_ids}, :ok ->
      args = %{
        "tenant_ids" => Enum.uniq(tenant_ids),
        "period_start" => Date.to_iso8601(day),
        "period_end" => Date.to_iso8601(day),
        "scoped_retry" => true
      }

      case args |> new() |> Oban.insert() do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp scoped_retry?(args), do: Map.get(args, "scoped_retry", false) == true

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

        normalize_and_cap(start_date, end_date)

      other ->
        Logger.warning(
          "CostRollupWorker: invalid period args #{inspect(other)}, defaulting to yesterday"
        )

        yesterday = Date.add(Date.utc_today(), -1)
        {yesterday, yesterday}
    end
  end

  # Normalize a (possibly reversed) parsed range and cap its width. A reversed
  # range (start > end) is swapped so `Date.range/2` never produces a descending
  # range (which would emit a warning and, in the anomaly worker, silently match
  # no summaries) (FIX2). A range wider than @max_backfill_days is clamped (FIX3).
  defp normalize_and_cap(start_date, end_date) do
    {s, e} =
      if Date.compare(start_date, end_date) == :gt,
        do: {end_date, start_date},
        else: {start_date, end_date}

    if Date.diff(e, s) > @max_backfill_days do
      capped_end = Date.add(s, @max_backfill_days)

      Logger.warning(
        "CostRollupWorker: backfill range #{Date.to_iso8601(s)}..#{Date.to_iso8601(e)} " <>
          "exceeds #{@max_backfill_days} days; clamping end to #{Date.to_iso8601(capped_end)}"
      )

      {s, capped_end}
    else
      {s, e}
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
    case %{
           "period_start" => Date.to_iso8601(period_start),
           "period_end" => Date.to_iso8601(period_end)
         }
         |> CostAnomalyWorker.new(scheduled_at: scheduled_anomaly_time())
         |> Oban.insert() do
      # A unique conflict returns {:ok, job} (conflict? true) -- that is the
      # dedup working, not an error.
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        # Don't lose anomaly detection silently: log a failed enqueue (FIX1b).
        Logger.error(
          "CostRollupWorker: failed to enqueue CostAnomalyWorker for " <>
            "#{Date.to_iso8601(period_start)}..#{Date.to_iso8601(period_end)}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Schedule the anomaly worker 5 minutes after the rollup
  defp scheduled_anomaly_time do
    DateTime.add(DateTime.utc_now(), 300, :second)
  end
end
