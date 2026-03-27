defmodule Loopctl.Webhooks.TestAndAutoDisableTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Webhooks
  alias Loopctl.Webhooks.Webhook
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.Workers.WebhookDeliveryWorker

  describe "test_webhook/2" do
    test "creates a webhook.test event and enqueues it" do
      tenant = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      {:ok, event} = Webhooks.test_webhook(tenant.id, webhook.id)

      assert event.event_type == "webhook.test"
      assert event.status == :pending
      assert event.payload["event"] == "webhook.test"
      assert event.payload["data"]["webhook_id"] == webhook.id
    end

    test "works on inactive webhooks" do
      tenant = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant.id, active: false})

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      {:ok, event} = Webhooks.test_webhook(tenant.id, webhook.id)
      assert event.event_type == "webhook.test"
    end

    test "returns not_found for missing webhook" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Webhooks.test_webhook(tenant.id, Ecto.UUID.generate())
    end
  end

  describe "list_deliveries/3" do
    test "lists delivery events for a webhook" do
      tenant = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      fixture(:webhook_event, %{
        tenant_id: tenant.id,
        webhook_id: webhook.id,
        status: :delivered
      })

      fixture(:webhook_event, %{
        tenant_id: tenant.id,
        webhook_id: webhook.id,
        status: :failed
      })

      {:ok, result} = Webhooks.list_deliveries(tenant.id, webhook.id)

      assert length(result.data) == 2
      assert result.total == 2
    end

    test "returns not_found for other tenant's webhook" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} = Webhooks.list_deliveries(tenant_a.id, webhook.id)
    end
  end

  describe "maybe_auto_disable/2" do
    test "disables webhook at threshold" do
      tenant = fixture(:tenant, %{settings: %{"webhook_max_consecutive_failures" => 3}})

      webhook =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          active: true,
          consecutive_failures: 3
        })

      assert {:ok, :disabled} = Webhooks.maybe_auto_disable(tenant.id, webhook)

      reloaded = AdminRepo.get!(Webhook, webhook.id)
      assert reloaded.active == false
    end

    test "does not disable below threshold" do
      tenant = fixture(:tenant, %{settings: %{"webhook_max_consecutive_failures" => 10}})

      webhook =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          active: true,
          consecutive_failures: 5
        })

      assert {:ok, :still_active} = Webhooks.maybe_auto_disable(tenant.id, webhook)

      reloaded = AdminRepo.get!(Webhook, webhook.id)
      assert reloaded.active == true
    end

    test "creates audit log entry on auto-disable" do
      tenant = fixture(:tenant, %{settings: %{"webhook_max_consecutive_failures" => 3}})

      webhook =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          active: true,
          consecutive_failures: 3
        })

      {:ok, :disabled} = Webhooks.maybe_auto_disable(tenant.id, webhook)

      {:ok, %{data: entries}} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "webhook",
          entity_id: webhook.id,
          action: "webhook_auto_disabled"
        )

      assert length(entries) == 1
    end

    test "uses default threshold of 10 when not configured" do
      tenant = fixture(:tenant)

      webhook =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          active: true,
          consecutive_failures: 9
        })

      assert {:ok, :still_active} = Webhooks.maybe_auto_disable(tenant.id, webhook)

      # Now at threshold 10
      webhook10 =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          active: true,
          consecutive_failures: 10
        })

      assert {:ok, :disabled} = Webhooks.maybe_auto_disable(tenant.id, webhook10)
    end
  end

  describe "reactivation resets consecutive_failures" do
    test "PATCH active=true resets failures via update_webhook" do
      tenant = fixture(:tenant)

      webhook =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          active: false,
          consecutive_failures: 10
        })

      {:ok, updated} =
        Webhooks.update_webhook(tenant.id, webhook.id, %{"active" => true})

      assert updated.active == true
      assert updated.consecutive_failures == 0
    end
  end

  describe "auto-disable via delivery worker integration" do
    test "webhook auto-disabled after exhausted delivery at threshold" do
      tenant = fixture(:tenant, %{settings: %{"webhook_max_consecutive_failures" => 3}})

      webhook =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          events: ["story.status_changed"],
          active: true,
          consecutive_failures: 2
        })

      event =
        fixture(:webhook_event, %{
          tenant_id: tenant.id,
          webhook_id: webhook.id,
          status: :pending,
          attempts: 5
        })

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Error")
      end)

      job = %Oban.Job{
        args: %{
          "webhook_event_id" => event.id,
          "tenant_id" => tenant.id
        }
      }

      WebhookDeliveryWorker.perform(job)

      reloaded_webhook = AdminRepo.get!(Webhook, webhook.id)
      assert reloaded_webhook.consecutive_failures == 3
      assert reloaded_webhook.active == false

      reloaded_event = AdminRepo.get!(WebhookEvent, event.id)
      assert reloaded_event.status == :exhausted
    end
  end
end
