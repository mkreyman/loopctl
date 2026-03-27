defmodule Loopctl.Workers.WebhookCleanupWorker do
  @moduledoc """
  Oban worker that prunes old webhook_events records.

  Runs daily via the Oban Cron plugin. Deletes webhook events with status
  `delivered` or `exhausted` that are older than the configurable retention
  period (default: 30 days). Events with status `pending` or `failed` are
  never pruned (they are still in-flight).

  Deletions are batched (1000 per iteration) to avoid long-running transactions.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants
  alias Loopctl.Webhooks.WebhookEvent

  @default_retention_days 30
  @batch_size 1000

  @impl Oban.Worker
  def perform(_job) do
    {:ok, tenants} = Tenants.list_tenants()

    total_deleted =
      Enum.reduce(tenants, 0, fn tenant, acc ->
        retention_days =
          Tenants.get_tenant_settings(
            tenant,
            "webhook_event_retention_days",
            @default_retention_days
          )

        cutoff = DateTime.utc_now() |> DateTime.add(-retention_days * 86_400, :second)

        deleted = delete_in_batches(tenant.id, cutoff)

        if deleted > 0 do
          Logger.info(
            "WebhookCleanupWorker pruned #{deleted} webhook events for tenant #{tenant.id} " <>
              "(retention: #{retention_days} days)"
          )
        end

        acc + deleted
      end)

    if total_deleted > 0 do
      Logger.info("WebhookCleanupWorker total pruned: #{total_deleted} webhook events")
    end

    :ok
  end

  defp delete_in_batches(tenant_id, cutoff) do
    delete_in_batches(tenant_id, cutoff, 0)
  end

  defp delete_in_batches(tenant_id, cutoff, total_deleted) do
    ids =
      WebhookEvent
      |> where([e], e.tenant_id == ^tenant_id)
      |> where([e], e.status in [:delivered, :exhausted])
      |> where([e], e.inserted_at < ^cutoff)
      |> select([e], e.id)
      |> limit(@batch_size)
      |> AdminRepo.all()

    case ids do
      [] ->
        total_deleted

      batch_ids ->
        {count, _} =
          WebhookEvent
          |> where([e], e.id in ^batch_ids)
          |> AdminRepo.delete_all()

        delete_in_batches(tenant_id, cutoff, total_deleted + count)
    end
  end
end
