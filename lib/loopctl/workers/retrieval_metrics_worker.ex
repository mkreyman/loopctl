defmodule Loopctl.Workers.RetrievalMetricsWorker do
  @moduledoc """
  Daily snapshot of retrieval precision (agents' KB #3). Fans out over active tenants and
  records yesterday's `RetrievalMetrics.snapshot/3` — the share of surfaced search results
  the agent then opened. Additive/idempotent (upsert per tenant/day/window); computes the
  previous FULL day so the window is complete.

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

  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id} = args}) do
    day = day_arg(args)

    case RetrievalMetrics.snapshot(tenant_id, day) do
      {:ok, snap} ->
        Logger.info(
          "RetrievalMetricsWorker: tenant=#{tenant_id} day=#{day} " <>
            "searched=#{snap.searched} followed=#{snap.followed_through} " <>
            "precision=#{Float.round(snap.precision, 3)}"
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
