defmodule Loopctl.WebhooksTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Webhooks
  alias Loopctl.Webhooks.Webhook

  describe "create_webhook/3" do
    test "creates a webhook with valid data and returns signing secret" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook, signing_secret: secret}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["story.status_changed", "story.verified"]
        })

      assert webhook.url == "https://example.com/hooks"
      assert webhook.events == ["story.status_changed", "story.verified"]
      assert webhook.active == true
      assert webhook.consecutive_failures == 0
      assert is_nil(webhook.project_id)
      assert is_binary(secret)
      assert byte_size(secret) == 64
    end

    test "creates a project-scoped webhook" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["story.verified"],
          "project_id" => project.id
        })

      assert webhook.project_id == project.id
    end

    test "signing secret is encrypted at rest" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook, signing_secret: raw_secret}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["story.status_changed"]
        })

      # The decrypted value should match the raw secret
      reloaded = Loopctl.AdminRepo.get!(Webhook, webhook.id)
      assert reloaded.signing_secret_encrypted == raw_secret
    end

    test "rejects invalid event types" do
      tenant = fixture(:tenant)

      {:error, changeset} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["invalid.event"]
        })

      assert errors_on(changeset).events
    end

    test "rejects empty events list" do
      tenant = fixture(:tenant)

      {:error, changeset} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => []
        })

      assert errors_on(changeset).events
    end

    test "rejects URL without valid host" do
      tenant = fixture(:tenant)

      {:error, changeset} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "not-a-url",
          "events" => ["story.status_changed"]
        })

      assert errors_on(changeset).url
    end

    test "enforces max_webhooks limit" do
      tenant = fixture(:tenant, %{settings: %{"max_webhooks" => 2}})

      {:ok, _} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://a.example.com/hooks",
          "events" => ["story.status_changed"]
        })

      {:ok, _} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://b.example.com/hooks",
          "events" => ["story.status_changed"]
        })

      assert {:error, :webhook_limit_reached} =
               Webhooks.create_webhook(tenant.id, %{
                 "url" => "https://c.example.com/hooks",
                 "events" => ["story.status_changed"]
               })
    end

    test "creates audit log entry" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["story.status_changed"]
        })

      {:ok, %{data: entries}} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "webhook",
          entity_id: webhook.id,
          action: "created"
        )

      assert length(entries) == 1
    end
  end

  describe "list_webhooks/2" do
    test "lists webhooks for a tenant with pagination" do
      tenant = fixture(:tenant)
      fixture(:webhook, %{tenant_id: tenant.id})
      fixture(:webhook, %{tenant_id: tenant.id})

      {:ok, result} = Webhooks.list_webhooks(tenant.id, page: 1, page_size: 10)

      assert length(result.data) == 2
      assert result.total == 2
      assert result.page == 1
    end

    test "returns empty for tenant with no webhooks" do
      tenant = fixture(:tenant)
      {:ok, result} = Webhooks.list_webhooks(tenant.id)
      assert result.data == []
      assert result.total == 0
    end
  end

  describe "get_webhook/2" do
    test "returns webhook by ID" do
      tenant = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      assert {:ok, found} = Webhooks.get_webhook(tenant.id, webhook.id)
      assert found.id == webhook.id
    end

    test "returns not_found for wrong tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} = Webhooks.get_webhook(tenant_a.id, webhook.id)
    end
  end

  describe "update_webhook/4" do
    test "updates webhook fields" do
      tenant = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      {:ok, updated} =
        Webhooks.update_webhook(tenant.id, webhook.id, %{
          "url" => "https://new.example.com/hooks",
          "events" => ["story.verified", "story.rejected"],
          "active" => false
        })

      assert updated.url == "https://new.example.com/hooks"
      assert updated.events == ["story.verified", "story.rejected"]
      assert updated.active == false
    end

    test "reactivation resets consecutive_failures" do
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

    test "creates audit log on update" do
      tenant = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      {:ok, _updated} =
        Webhooks.update_webhook(tenant.id, webhook.id, %{"active" => false})

      {:ok, %{data: entries}} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "webhook",
          entity_id: webhook.id,
          action: "updated"
        )

      assert length(entries) == 1
    end
  end

  describe "delete_webhook/3" do
    test "deletes a webhook" do
      tenant = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      {:ok, deleted} = Webhooks.delete_webhook(tenant.id, webhook.id)
      assert deleted.id == webhook.id

      assert {:error, :not_found} = Webhooks.get_webhook(tenant.id, webhook.id)
    end

    test "returns not_found for missing webhook" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Webhooks.delete_webhook(tenant.id, Ecto.UUID.generate())
    end

    test "creates audit log on delete" do
      tenant = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      {:ok, _} = Webhooks.delete_webhook(tenant.id, webhook.id)

      {:ok, %{data: entries}} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "webhook",
          entity_id: webhook.id,
          action: "deleted"
        )

      assert length(entries) == 1
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's webhooks" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      fixture(:webhook, %{tenant_id: tenant_b.id})

      {:ok, result} = Webhooks.list_webhooks(tenant_a.id)
      assert result.data == []
    end

    test "tenant A cannot get tenant B's webhook by ID" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} = Webhooks.get_webhook(tenant_a.id, webhook.id)
    end

    test "tenant A cannot update tenant B's webhook" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} =
               Webhooks.update_webhook(tenant_a.id, webhook.id, %{"active" => false})
    end

    test "tenant A cannot delete tenant B's webhook" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      webhook = fixture(:webhook, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} = Webhooks.delete_webhook(tenant_a.id, webhook.id)
    end
  end
end
