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

    # US-41.5 review: `:blocked` is TERMINAL, and it is the status a persistent
    # misconfiguration produces in VOLUME — a blocked delivery deliberately does
    # not increment consecutive_failures, so the auto-disable valve never fires
    # and rows accumulate for every matching state change. Leaving it out of the
    # retention predicate meant those rows were never reclaimed.
    test "prunes BLOCKED events older than the retention period" do
      tenant = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      for status <- [:blocked, :exhausted] do
        fixture(:webhook_event, %{
          tenant_id: tenant.id,
          webhook_id: webhook.id,
          status: status
        })
        |> Ecto.Changeset.change(%{
          inserted_at: DateTime.add(DateTime.utc_now(), -45 * 86_400, :second)
        })
        |> AdminRepo.update!()
      end

      recent_blocked =
        fixture(:webhook_event, %{
          tenant_id: tenant.id,
          webhook_id: webhook.id,
          status: :blocked
        })

      assert :ok = WebhookCleanupWorker.perform(%Oban.Job{})

      remaining =
        WebhookEvent
        |> where([e], e.tenant_id == ^tenant.id)
        |> AdminRepo.all()

      assert [%{id: id}] = remaining
      assert id == recent_blocked.id
    end
  end
end
