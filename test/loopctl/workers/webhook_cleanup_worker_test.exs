defmodule Loopctl.Workers.WebhookCleanupWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.Workers.WebhookCleanupWorker

  describe "perform/1" do
    test "prunes delivered events older than retention period" do
      tenant = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      # Create an old delivered event
      old_event =
        fixture(:webhook_event, %{
          tenant_id: tenant.id,
          webhook_id: webhook.id,
          status: :delivered
        })

      # Make it old (45 days ago)
      old_event
      |> Ecto.Changeset.change(%{
        inserted_at: DateTime.add(DateTime.utc_now(), -45 * 86_400, :second)
      })
      |> AdminRepo.update!()

      # Create a recent delivered event
      _recent_event =
        fixture(:webhook_event, %{
          tenant_id: tenant.id,
          webhook_id: webhook.id,
          status: :delivered
        })

      assert :ok = WebhookCleanupWorker.perform(%Oban.Job{})

      remaining =
        WebhookEvent
        |> where([e], e.tenant_id == ^tenant.id)
        |> AdminRepo.all()

      # Only the recent one should remain
      assert length(remaining) == 1
    end

    test "does not prune pending or failed events" do
      tenant = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      # Create old pending event
      pending_event =
        fixture(:webhook_event, %{
          tenant_id: tenant.id,
          webhook_id: webhook.id,
          status: :pending
        })

      pending_event
      |> Ecto.Changeset.change(%{
        inserted_at: DateTime.add(DateTime.utc_now(), -45 * 86_400, :second)
      })
      |> AdminRepo.update!()

      assert :ok = WebhookCleanupWorker.perform(%Oban.Job{})

      remaining =
        WebhookEvent
        |> where([e], e.tenant_id == ^tenant.id)
        |> AdminRepo.all()

      assert length(remaining) == 1
    end
  end
end
