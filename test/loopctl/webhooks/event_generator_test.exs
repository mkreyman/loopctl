defmodule Loopctl.Webhooks.EventGeneratorTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Progress
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Webhooks.WebhookEvent

  describe "generate_events/3" do
    test "creates webhook events for matching active webhooks" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      webhook =
        fixture(:webhook, %{
          tenant_id: tenant.id,
          events: ["story.status_changed"],
          active: true
        })

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:story, fn _repo, _changes -> {:ok, story} end)
        |> EventGenerator.generate_events(:webhook_events, %{
          tenant_id: tenant.id,
          event_type: "story.status_changed",
          project_id: project.id,
          payload: %{"event" => "story.status_changed", "story_id" => story.id}
        })

      {:ok, %{webhook_events: events}} = AdminRepo.transaction(multi)

      assert length(events) == 1
      event = List.first(events)
      assert event.webhook_id == webhook.id
      assert event.event_type == "story.status_changed"
      assert event.status == :pending
      assert event.tenant_id == tenant.id
    end

    test "inactive webhooks do not receive events" do
      tenant = fixture(:tenant)

      fixture(:webhook, %{
        tenant_id: tenant.id,
        events: ["story.status_changed"],
        active: false
      })

      multi =
        Ecto.Multi.new()
        |> EventGenerator.generate_events(:webhook_events, %{
          tenant_id: tenant.id,
          event_type: "story.status_changed",
          payload: %{"event" => "story.status_changed"}
        })

      {:ok, %{webhook_events: events}} = AdminRepo.transaction(multi)
      assert events == []
    end

    test "webhook with unsubscribed event type does not receive events" do
      tenant = fixture(:tenant)

      fixture(:webhook, %{
        tenant_id: tenant.id,
        events: ["story.verified"],
        active: true
      })

      multi =
        Ecto.Multi.new()
        |> EventGenerator.generate_events(:webhook_events, %{
          tenant_id: tenant.id,
          event_type: "story.status_changed",
          payload: %{"event" => "story.status_changed"}
        })

      {:ok, %{webhook_events: events}} = AdminRepo.transaction(multi)
      assert events == []
    end

    test "project-scoped webhook only receives events for that project" do
      tenant = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant.id})
      project_b = fixture(:project, %{tenant_id: tenant.id})

      fixture(:webhook, %{
        tenant_id: tenant.id,
        events: ["story.status_changed"],
        project_id: project_a.id,
        active: true
      })

      # Event for project A
      multi_a =
        Ecto.Multi.new()
        |> EventGenerator.generate_events(:webhook_events, %{
          tenant_id: tenant.id,
          event_type: "story.status_changed",
          project_id: project_a.id,
          payload: %{"event" => "story.status_changed"}
        })

      {:ok, %{webhook_events: events_a}} = AdminRepo.transaction(multi_a)
      assert length(events_a) == 1

      # Event for project B
      multi_b =
        Ecto.Multi.new()
        |> EventGenerator.generate_events(:webhook_events, %{
          tenant_id: tenant.id,
          event_type: "story.status_changed",
          project_id: project_b.id,
          payload: %{"event" => "story.status_changed"}
        })

      {:ok, %{webhook_events: events_b}} = AdminRepo.transaction(multi_b)
      assert events_b == []
    end

    test "global webhook (project_id=nil) receives events from any project" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      fixture(:webhook, %{
        tenant_id: tenant.id,
        events: ["story.status_changed"],
        active: true
      })

      multi =
        Ecto.Multi.new()
        |> EventGenerator.generate_events(:webhook_events, %{
          tenant_id: tenant.id,
          event_type: "story.status_changed",
          project_id: project.id,
          payload: %{"event" => "story.status_changed"}
        })

      {:ok, %{webhook_events: events}} = AdminRepo.transaction(multi)
      assert length(events) == 1
    end

    test "multiple webhooks receive the same event" do
      tenant = fixture(:tenant)

      fixture(:webhook, %{
        tenant_id: tenant.id,
        events: ["story.status_changed"],
        active: true
      })

      fixture(:webhook, %{
        tenant_id: tenant.id,
        events: ["story.status_changed"],
        active: true
      })

      multi =
        Ecto.Multi.new()
        |> EventGenerator.generate_events(:webhook_events, %{
          tenant_id: tenant.id,
          event_type: "story.status_changed",
          payload: %{"event" => "story.status_changed"}
        })

      {:ok, %{webhook_events: events}} = AdminRepo.transaction(multi)
      assert length(events) == 2
    end

    test "accepts function for lazy event params" do
      tenant = fixture(:tenant)

      fixture(:webhook, %{
        tenant_id: tenant.id,
        events: ["story.status_changed"],
        active: true
      })

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:story_id, fn _repo, _changes -> {:ok, Ecto.UUID.generate()} end)
        |> EventGenerator.generate_events(:webhook_events, fn %{story_id: story_id} ->
          %{
            tenant_id: tenant.id,
            event_type: "story.status_changed",
            payload: %{"event" => "story.status_changed", "story_id" => story_id}
          }
        end)

      {:ok, %{webhook_events: events}} = AdminRepo.transaction(multi)
      assert length(events) == 1
    end

    test "cross-tenant isolation -- other tenant's webhook not triggered" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      fixture(:webhook, %{
        tenant_id: tenant_b.id,
        events: ["story.status_changed"],
        active: true
      })

      multi =
        Ecto.Multi.new()
        |> EventGenerator.generate_events(:webhook_events, %{
          tenant_id: tenant_a.id,
          event_type: "story.status_changed",
          payload: %{"event" => "story.status_changed"}
        })

      {:ok, %{webhook_events: events}} = AdminRepo.transaction(multi)
      assert events == []
    end
  end

  describe "story status change creates webhook events via Progress" do
    test "claim creates story.status_changed event transactionally" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      agent = fixture(:agent, %{tenant_id: tenant.id})

      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :contracted
        })

      fixture(:webhook, %{
        tenant_id: tenant.id,
        events: ["story.status_changed"],
        active: true
      })

      {:ok, _updated} =
        Progress.claim_story(tenant.id, story.id,
          agent_id: agent.id,
          actor_id: agent.id,
          actor_label: "agent:#{agent.name}"
        )

      events =
        WebhookEvent
        |> where([e], e.tenant_id == ^tenant.id and e.event_type == "story.status_changed")
        |> AdminRepo.all()

      assert events != []
      event = List.first(events)
      assert event.status == :pending
      assert event.payload["story_id"] == story.id
    end
  end
end
