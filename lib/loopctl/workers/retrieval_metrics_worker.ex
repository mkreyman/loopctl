defmodule Loopctl.Workers.RetrievalMetricsWorker do
  # How many days BEFORE the cron target get re-snapshotted so a late `referenced` row
  # lands. One: a reference posted the morning after its recall is the case this exists
  # for, and each extra day is another full `compute/3` per tenant per run.
  @resnapshot_lookback_days 1

  @moduledoc """
  Daily snapshot of retrieval precision (agents' KB #3). Fans out over active tenants and
  records yesterday's `RetrievalMetrics.snapshot/3` — the share of surfaced search RESULTS
  the agent then opened, plus the separate per-CALL follow-through rate (#582). Additive/
  idempotent (upsert per tenant/day/window); computes the previous FULL day so the window
  is complete.

  ## Why the cron run also RE-snapshots the day before its target

  `referenced` is the one counter whose input can arrive after its day has closed.
  `RetrievalMetrics.compute_referenced/3` buckets a reference by the day the article was
  SURFACED, not by the day it was referenced — deliberately, so the numerator shares
  `precision`'s denominator — and it puts no upper bound on the reference row's own
  `accessed_at`. An agent that recalls at 17:00 and posts `recall_referenced` the next
  morning therefore belongs to yesterday's snapshot, which was already written hours
  earlier by the run that had not seen it.

  Nothing else ever revisits a written day, so that reference stayed permanently
  uncounted and `reference_rate` was biased DOWN by exactly the late-posting behaviour
  the metric exists to observe. The cron path now re-snapshots the preceding
  #{@resnapshot_lookback_days} day(s), which lands any reference posted before the
  following run.
  `snapshot/3` is a full recompute + upsert on `{tenant, day, window}`, so the re-run is
  idempotent and rewrites the whole row from source events rather than incrementing it.

  The lookback is a FIXED constant, not a scan for stale rows: a worker that walks
  backwards until it finds nothing to change grows without bound as the table does, and
  every day it re-reads costs a full `compute/3` over `article_access_events`. A reference
  posted more than a day after its surfacing day closed is not counted, and that is the
  deliberate bound — widen `@resnapshot_lookback_days` if the lag turns out to be longer.

  An EXPLICIT `"day"` argument suppresses the re-snapshot: that job is a backfill of one
  named day, and quietly rewriting its neighbour would make a targeted repair untargeted.

  Scheduled daily via the Oban Cron plugin.
  """

  use Oban.Worker,
    queue: :knowledge,
    max_attempts: 3,
    unique: [fields: [:worker, :args], period: 300]

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.RetrievalMetrics
  alias Loopctl.Oban.FairShare
  alias Loopctl.Tenants.Tenant

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"}}) do
    from(t in Tenant, where: t.status == :active, select: t.id)
    |> AdminRepo.all()
    |> Enum.each(fn tenant_id ->
      %{"tenant_id" => tenant_id} |> __MODULE__.new() |> Oban.insert()
    end)

    :ok
  end

  def perform(%Oban.Job{id: id, args: %{"tenant_id" => tenant_id} = args}) do
    # US-36.2: fair-share gate on the shared :knowledge queue (the all_tenants
    # dispatcher clause above is NOT gated — it has no tenant_id). `id` excludes THIS
    # (already-executing) job from its own count — see FairShare.
    case FairShare.gate(tenant_id, :knowledge, id) do
      {:snooze, _n} = snooze -> snooze
      :ok -> snapshot_tenant(tenant_id, args)
    end
  end

  defp snapshot_tenant(tenant_id, args) do
    day = day_arg(args)

    with :ok <- snapshot_day(tenant_id, day) do
      # Only the CRON path (no explicit "day") sweeps up late references — see the
      # moduledoc. Bounded by `@resnapshot_lookback_days`, so this can never walk
      # backwards further than the constant allows.
      resnapshot_recent(tenant_id, args, day)
    end
  end

  defp resnapshot_recent(_tenant_id, %{"day" => iso}, _day) when is_binary(iso), do: :ok

  defp resnapshot_recent(tenant_id, _args, day) do
    Enum.reduce_while(1..@resnapshot_lookback_days, :ok, fn back, _acc ->
      case snapshot_day(tenant_id, Date.add(day, -back)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp snapshot_day(tenant_id, day) do
    case RetrievalMetrics.snapshot(tenant_id, day) do
      {:ok, snap} ->
        # `searched` is RECORDED SURFACED RESULTS (capped per call) and `searches` is
        # search CALLS (#582) — both are logged with their own ratio so the line cannot
        # be read as one number.
        Logger.info(
          "RetrievalMetricsWorker: tenant=#{tenant_id} day=#{day} " <>
            "results_recorded=#{snap.searched} results_returned=#{snap.results_returned} " <>
            "followed=#{snap.followed_through} " <>
            "precision=#{Float.round(snap.precision, 3)} " <>
            "searches=#{snap.searches} " <>
            "search_follow_through=#{Float.round(snap.search_follow_through, 3)} " <>
            "referenced=#{snap.referenced}"
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Default: yesterday (the last complete UTC day). An explicit "day" arg (ISO8601)
  # allows backfilling a specific day.
  defp day_arg(%{"day" => iso}) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, d} -> d
      _ -> yesterday()
    end
  end

  defp day_arg(_), do: yesterday()

  defp yesterday, do: Date.add(DateTime.utc_now() |> DateTime.to_date(), -1)
end
