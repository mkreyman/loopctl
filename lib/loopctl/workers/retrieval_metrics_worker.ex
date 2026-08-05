defmodule Loopctl.Workers.RetrievalMetricsWorker do
  @moduledoc """
  Daily snapshot of retrieval precision (agents' KB #3). Fans out over active tenants and
  records yesterday's `RetrievalMetrics.snapshot/3` — the share of surfaced search RESULTS
  the agent then opened, plus the separate per-CALL follow-through rate (#582). Additive/
  idempotent (upsert per tenant/day/window); computes the previous FULL day so the window
  is complete.

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
            "search_follow_through=#{Float.round(snap.search_follow_through, 3)}"
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
