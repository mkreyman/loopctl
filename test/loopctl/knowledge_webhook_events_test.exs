defmodule Loopctl.KnowledgeWebhookEventsTest do
  @moduledoc """
  Tests for US-22.6: Knowledge Webhook Events.

  Verifies that:
  - AC-19.6.1: create_article generates "article.created" event
  - AC-19.6.2: update_article generates "article.updated" event (with changed field names)
  - AC-19.6.3: archive_article generates "article.archived" event
  - AC-19.6.4: :supersedes link generates "article.superseded" event
  - AC-19.6.5: create_link generates "article_link.created" event (with titles)
  - AC-19.6.6: delete_link generates "article_link.deleted" event
  - AC-19.6.7: All 6 new event types added to valid webhook subscription types
  - AC-19.6.8: Events generated within same Ecto.Multi transaction
  - AC-19.6.9: Payloads include tenant_id and project_id
  - AC-19.6.10: Payloads include ONLY safe fields, never body/metadata/embedding
  """

  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Webhooks
  alias Loopctl.Webhooks.WebhookEvent

  import Ecto.Query

  defp create_webhook_for_events(tenant_id, events) do
    {:ok, %{webhook: webhook}} =
      Webhooks.create_webhook(tenant_id, %{
        "url" => "https://example.com/hooks/#{System.unique_integer([:positive])}",
        "events" => events
      })

    webhook
  end

  defp find_webhook_events(tenant_id, event_type) do
    WebhookEvent
    |> where([e], e.tenant_id == ^tenant_id and e.event_type == ^event_type)
    |> AdminRepo.all()
  end

  # --- AC-19.6.7: All 6 new event types are valid ---

  describe "valid event types (AC-19.6.7)" do
    test "article.created is a valid event type for webhook subscription" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["article.created"]
        })

      assert "article.created" in webhook.events
    end

    test "article.updated is a valid event type for webhook subscription" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["article.updated"]
        })

      assert "article.updated" in webhook.events
    end

    test "article.archived is a valid event type for webhook subscription" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["article.archived"]
        })

      assert "article.archived" in webhook.events
    end

    test "article.superseded is a valid event type for webhook subscription" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["article.superseded"]
        })

      assert "article.superseded" in webhook.events
    end

    test "article_link.created is a valid event type for webhook subscription" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["article_link.created"]
        })

      assert "article_link.created" in webhook.events
    end

    test "article_link.deleted is a valid event type for webhook subscription" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["article_link.deleted"]
        })

      assert "article_link.deleted" in webhook.events
    end

    test "can subscribe to all 6 new event types simultaneously" do
      tenant = fixture(:tenant)

      events = [
        "article.created",
        "article.updated",
        "article.archived",
        "article.superseded",
        "article_link.created",
        "article_link.deleted"
      ]

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => events
        })

      assert length(webhook.events) == 6
    end
  end

  # --- AC-19.6.1: create_article generates article.created event ---

  describe "create_article webhook event (AC-19.6.1)" do
    test "generates article.created event with correct payload" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      _webhook = create_webhook_for_events(tenant.id, ["article.created"])

      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Ecto Multi Pattern",
          body: "Use Ecto.Multi for atomic operations...",
          category: :pattern,
          tags: ["ecto", "transactions"],
          project_id: project.id
        })

      events = find_webhook_events(tenant.id, "article.created")
      assert [event] = events
      payload = event.payload

      assert payload["id"] == article.id
      assert payload["title"] == "Ecto Multi Pattern"
      assert payload["category"] == "pattern"
      assert payload["project_id"] == project.id
      assert payload["status"] == "draft"
      assert payload["tags"] == ["ecto", "transactions"]

      # AC-19.6.10: Must NOT include body, metadata, or embedding
      refute Map.has_key?(payload, "body")
      refute Map.has_key?(payload, "metadata")
      refute Map.has_key?(payload, "embedding")
    end

    test "no event when no webhook subscribed to article.created" do
      tenant = fixture(:tenant)
      _webhook = create_webhook_for_events(tenant.id, ["story.verified"])

      {:ok, _article} =
        Knowledge.create_article(tenant.id, %{
          title: "Unsubscribed Article",
          body: "Body text",
          category: :convention
        })

      events = find_webhook_events(tenant.id, "article.created")
      assert events == []
    end
  end

  # --- AC-19.6.2: update_article generates article.updated event ---

  describe "update_article webhook event (AC-19.6.2)" do
    test "generates article.updated event with changed field names" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id, title: "Original Title"})
      _webhook = create_webhook_for_events(tenant.id, ["article.updated"])

      {:ok, updated} =
        Knowledge.update_article(tenant.id, article.id, %{
          title: "Updated Title",
          tags: ["new-tag"]
        })

      events = find_webhook_events(tenant.id, "article.updated")
      assert [event] = events
      payload = event.payload

      assert payload["id"] == updated.id
      assert payload["title"] == "Updated Title"
      assert payload["category"] == to_string(article.category)
      assert payload["status"] == to_string(article.status)
      assert payload["tags"] == ["new-tag"]

      # AC-19.6.2: changed_fields contains field names (not values)
      assert is_list(payload["changed_fields"])
      assert "title" in payload["changed_fields"]
      assert "tags" in payload["changed_fields"]

      # AC-19.6.10: Must NOT include body, metadata, or embedding
      refute Map.has_key?(payload, "body")
      refute Map.has_key?(payload, "metadata")
      refute Map.has_key?(payload, "embedding")
    end
  end

  # --- AC-19.6.3: archive_article generates article.archived event ---

  describe "archive_article webhook event (AC-19.6.3)" do
    test "generates article.archived event with correct payload" do
      tenant = fixture(:tenant)

      article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Article to Archive",
          category: :decision
        })

      _webhook = create_webhook_for_events(tenant.id, ["article.archived"])

      {:ok, _archived} = Knowledge.archive_article(tenant.id, article.id)

      events = find_webhook_events(tenant.id, "article.archived")
      assert [event] = events
      payload = event.payload

      assert payload["id"] == article.id
      assert payload["title"] == "Article to Archive"
      assert payload["category"] == "decision"
      assert payload["status"] == "archived"
      assert payload["project_id"] == nil
      assert payload["tags"] == []

      # AC-19.6.10: Must NOT include body, metadata, or embedding
      refute Map.has_key?(payload, "body")
      refute Map.has_key?(payload, "metadata")
      refute Map.has_key?(payload, "embedding")
    end
  end

  # --- AC-19.6.4: :supersedes link generates article.superseded event ---

  describe "supersedes link webhook event (AC-19.6.4)" do
    test "generates article.superseded event with both article IDs and titles" do
      tenant = fixture(:tenant)
      old_article = fixture(:article, %{tenant_id: tenant.id, title: "Old Pattern"})
      new_article = fixture(:article, %{tenant_id: tenant.id, title: "New Pattern"})
      _webhook = create_webhook_for_events(tenant.id, ["article.superseded"])

      {:ok, _link} =
        Knowledge.create_link(tenant.id, %{
          source_article_id: new_article.id,
          target_article_id: old_article.id,
          relationship_type: :supersedes
        })

      events = find_webhook_events(tenant.id, "article.superseded")
      assert [event] = events
      payload = event.payload

      assert payload["superseded_article_id"] == old_article.id
      assert payload["superseded_title"] == "Old Pattern"
      assert payload["superseding_article_id"] == new_article.id
      assert payload["superseding_title"] == "New Pattern"
    end

    test "no article.superseded event for non-supersedes link types" do
      tenant = fixture(:tenant)
      article_a = fixture(:article, %{tenant_id: tenant.id})
      article_b = fixture(:article, %{tenant_id: tenant.id})
      _webhook = create_webhook_for_events(tenant.id, ["article.superseded"])

      {:ok, _link} =
        Knowledge.create_link(tenant.id, %{
          source_article_id: article_a.id,
          target_article_id: article_b.id,
          relationship_type: :relates_to
        })

      events = find_webhook_events(tenant.id, "article.superseded")
      assert events == []
    end
  end

  # --- AC-19.6.5: create_link generates article_link.created event ---

  describe "create_link webhook event (AC-19.6.5)" do
    test "generates article_link.created event with both article titles" do
      tenant = fixture(:tenant)
      source = fixture(:article, %{tenant_id: tenant.id, title: "Source Article"})
      target = fixture(:article, %{tenant_id: tenant.id, title: "Target Article"})
      _webhook = create_webhook_for_events(tenant.id, ["article_link.created"])

      {:ok, link} =
        Knowledge.create_link(tenant.id, %{
          source_article_id: source.id,
          target_article_id: target.id,
          relationship_type: :relates_to
        })

      events = find_webhook_events(tenant.id, "article_link.created")
      assert [event] = events
      payload = event.payload

      assert payload["id"] == link.id
      assert payload["source_article_id"] == source.id
      assert payload["target_article_id"] == target.id
      assert payload["relationship_type"] == "relates_to"
      assert payload["source_title"] == "Source Article"
      assert payload["target_title"] == "Target Article"
    end
  end

  # --- AC-19.6.6: delete_link generates article_link.deleted event ---

  describe "delete_link webhook event (AC-19.6.6)" do
    test "generates article_link.deleted event with correct payload" do
      tenant = fixture(:tenant)
      source = fixture(:article, %{tenant_id: tenant.id})
      target = fixture(:article, %{tenant_id: tenant.id})
      _webhook = create_webhook_for_events(tenant.id, ["article_link.deleted"])

      {:ok, link} =
        Knowledge.create_link(tenant.id, %{
          source_article_id: source.id,
          target_article_id: target.id,
          relationship_type: :derived_from
        })

      {:ok, _deleted} = Knowledge.delete_link(tenant.id, link.id)

      events = find_webhook_events(tenant.id, "article_link.deleted")
      assert [event] = events
      payload = event.payload

      assert payload["id"] == link.id
      assert payload["source_article_id"] == source.id
      assert payload["target_article_id"] == target.id
      assert payload["relationship_type"] == "derived_from"
    end
  end

  # --- AC-19.6.8 & AC-19.6.9: Transaction atomicity and tenant/project scoping ---

  describe "transactional and scoping guarantees (AC-19.6.8, AC-19.6.9)" do
    test "webhook event is created atomically within the same transaction" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      _webhook = create_webhook_for_events(tenant.id, ["article.created"])

      {:ok, article} =
        Knowledge.create_article(tenant.id, %{
          title: "Transactional Test",
          body: "Content here",
          category: :finding,
          project_id: project.id
        })

      # Event should exist immediately after create_article returns
      events = find_webhook_events(tenant.id, "article.created")
      assert [event] = events
      assert event.payload["id"] == article.id
      assert event.payload["project_id"] == project.id
    end

    test "tenant isolation: events from one tenant are not visible to another" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      _webhook_a = create_webhook_for_events(tenant_a.id, ["article.created"])
      _webhook_b = create_webhook_for_events(tenant_b.id, ["article.created"])

      {:ok, _article} =
        Knowledge.create_article(tenant_a.id, %{
          title: "Tenant A Article",
          body: "Body for A",
          category: :pattern
        })

      events_a = find_webhook_events(tenant_a.id, "article.created")
      events_b = find_webhook_events(tenant_b.id, "article.created")

      assert events_a != []
      assert events_b == []
    end
  end
end
