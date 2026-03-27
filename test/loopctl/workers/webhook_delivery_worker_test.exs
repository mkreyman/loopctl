defmodule Loopctl.Workers.WebhookDeliveryWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Webhooks.Webhook
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.Workers.WebhookDeliveryWorker

  defp create_test_event(opts \\ %{}) do
    tenant = fixture(:tenant, Map.get(opts, :tenant_attrs, %{}))

    webhook =
      fixture(:webhook, %{
        tenant_id: tenant.id,
        url: "https://example.com/hooks",
        events: ["story.status_changed"],
        active: Map.get(opts, :active, true),
        consecutive_failures: Map.get(opts, :consecutive_failures, 0)
      })

    event =
      fixture(:webhook_event, %{
        tenant_id: tenant.id,
        webhook_id: webhook.id,
        event_type: "story.status_changed",
        payload: %{"event" => "story.status_changed", "story_id" => Ecto.UUID.generate()},
        status: :pending,
        attempts: Map.get(opts, :attempts, 0)
      })

    %{tenant: tenant, webhook: webhook, event: event}
  end

  defp build_job(event, tenant) do
    %Oban.Job{
      args: %{
        "webhook_event_id" => event.id,
        "tenant_id" => tenant.id
      }
    }
  end

  describe "successful delivery" do
    test "marks event as delivered and resets consecutive_failures" do
      %{tenant: tenant, webhook: webhook, event: event} =
        create_test_event(%{consecutive_failures: 5})

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert :ok = WebhookDeliveryWorker.perform(build_job(event, tenant))

      updated_event = AdminRepo.get!(WebhookEvent, event.id)
      assert updated_event.status == :delivered
      assert updated_event.delivered_at != nil
      assert updated_event.attempts == 1

      updated_webhook = AdminRepo.get!(Webhook, webhook.id)
      assert updated_webhook.consecutive_failures == 0
      assert updated_webhook.last_delivery_at != nil
    end

    test "delivery payload includes correct structure" do
      %{tenant: tenant, event: event} = create_test_event()
      test_pid = self()

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        parsed = Jason.decode!(body)
        send(test_pid, {:request, conn, parsed})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert :ok = WebhookDeliveryWorker.perform(build_job(event, tenant))

      assert_receive {:request, conn, body}
      assert body["id"] == event.id
      assert body["event"] == "story.status_changed"
      assert is_binary(body["timestamp"])
      assert is_map(body["data"])

      content_type =
        conn.req_headers
        |> Enum.find(fn {k, _v} -> k == "content-type" end)
        |> elem(1)

      assert content_type == "application/json"
    end
  end

  describe "failed delivery" do
    test "increments attempts and returns snooze on failure" do
      %{tenant: tenant, event: event} = create_test_event()

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      assert {:snooze, 60} = WebhookDeliveryWorker.perform(build_job(event, tenant))

      updated_event = AdminRepo.get!(WebhookEvent, event.id)
      assert updated_event.attempts == 1
      assert updated_event.last_attempt_at != nil
      assert updated_event.error =~ "500"
      assert updated_event.status == :pending
    end
  end

  describe "exhausted delivery" do
    test "marks as exhausted after max attempts" do
      %{tenant: tenant, webhook: webhook, event: event} =
        create_test_event(%{attempts: 5, consecutive_failures: 5})

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      assert :ok = WebhookDeliveryWorker.perform(build_job(event, tenant))

      updated_event = AdminRepo.get!(WebhookEvent, event.id)
      assert updated_event.status == :exhausted
      assert updated_event.attempts == 6

      updated_webhook = AdminRepo.get!(Webhook, webhook.id)
      assert updated_webhook.consecutive_failures == 6
    end
  end

  describe "deactivated webhook" do
    test "skips delivery for deactivated webhook" do
      %{tenant: tenant, event: event} = create_test_event(%{active: false})

      # No HTTP stub needed -- should not make any request
      assert :ok = WebhookDeliveryWorker.perform(build_job(event, tenant))

      updated_event = AdminRepo.get!(WebhookEvent, event.id)
      assert updated_event.status == :failed
      assert updated_event.error == "webhook_deactivated"
    end
  end

  describe "backoff_seconds/1" do
    test "returns correct backoff for each attempt" do
      assert WebhookDeliveryWorker.backoff_seconds(1) == 60
      assert WebhookDeliveryWorker.backoff_seconds(2) == 300
      assert WebhookDeliveryWorker.backoff_seconds(3) == 1500
      assert WebhookDeliveryWorker.backoff_seconds(4) == 7200
      assert WebhookDeliveryWorker.backoff_seconds(5) == 36_000
    end
  end

  describe "security headers" do
    test "includes all required security headers" do
      %{tenant: tenant, event: event} = create_test_event()
      test_pid = self()

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert :ok = WebhookDeliveryWorker.perform(build_job(event, tenant))

      assert_receive {:headers, headers}
      header_map = Map.new(headers)

      assert header_map["x-webhook-id"] == event.id
      assert is_binary(header_map["x-webhook-timestamp"])
      assert String.starts_with?(header_map["x-signature-256"], "sha256=")
      assert header_map["user-agent"] == "Loopctl-Webhook/1.0"
      assert header_map["content-type"] == "application/json"
    end

    test "signature is valid HMAC-SHA256" do
      %{tenant: tenant, webhook: webhook, event: event} = create_test_event()
      test_pid = self()

      Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_data, conn.req_headers, body})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert :ok = WebhookDeliveryWorker.perform(build_job(event, tenant))

      assert_receive {:request_data, headers, body}
      header_map = Map.new(headers)
      signature = header_map["x-signature-256"]

      # Reload webhook to get decrypted signing secret
      reloaded_webhook = AdminRepo.get!(Webhook, webhook.id)
      secret = reloaded_webhook.signing_secret_encrypted

      expected_hmac =
        :crypto.mac(:hmac, :sha256, secret, body)
        |> Base.encode16(case: :lower)

      assert signature == "sha256=#{expected_hmac}"
    end
  end

  describe "tenant isolation" do
    test "delivery worker uses correct tenant context" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      webhook_b =
        fixture(:webhook, %{
          tenant_id: tenant_b.id,
          events: ["story.status_changed"],
          active: true
        })

      event_b =
        fixture(:webhook_event, %{
          tenant_id: tenant_b.id,
          webhook_id: webhook_b.id
        })

      # Attempt to deliver with wrong tenant
      job = %Oban.Job{
        args: %{
          "webhook_event_id" => event_b.id,
          "tenant_id" => tenant_a.id
        }
      }

      # Should not find the event (wrong tenant)
      assert :ok = WebhookDeliveryWorker.perform(job)

      # Event should remain unchanged (not delivered, not failed)
      unchanged_event = AdminRepo.get!(WebhookEvent, event_b.id)
      assert unchanged_event.status == :pending
    end
  end
end
