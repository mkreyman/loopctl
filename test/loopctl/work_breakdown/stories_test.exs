defmodule Loopctl.WorkBreakdown.StoriesTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.WorkBreakdown.Story

  describe "create_story/3" do
    test "creates a story with valid attributes" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      attrs = %{
        epic_id: epic.id,
        number: "1.1",
        title: "Phoenix scaffold",
        description: "Set up Phoenix application",
        acceptance_criteria: [%{"id" => "AC-1", "description" => "App boots"}],
        estimated_hours: Decimal.new("8"),
        metadata: %{"complexity" => "low"}
      }

      assert {:ok, %Story{} = story} =
               Stories.create_story(tenant.id, attrs,
                 actor_id: uuid(),
                 actor_label: "user:admin"
               )

      assert story.number == "1.1"
      assert story.title == "Phoenix scaffold"
      assert story.agent_status == :pending
      assert story.verified_status == :unverified
      assert story.tenant_id == tenant.id
      assert story.project_id == project.id
      assert story.epic_id == epic.id
      assert story.sort_key == 10_010
    end

    test "creates a story with minimal attributes" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      attrs = %{epic_id: epic.id, number: "1.1", title: "Minimal"}

      assert {:ok, %Story{} = story} = Stories.create_story(tenant.id, attrs)
      assert story.agent_status == :pending
      assert story.verified_status == :unverified
      assert story.metadata == %{}
      assert story.acceptance_criteria == []
      assert story.assigned_agent_id == nil
    end

    test "derives project_id from parent epic" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      attrs = %{epic_id: epic.id, number: "1.1", title: "Test"}

      assert {:ok, story} = Stories.create_story(tenant.id, attrs)
      assert story.project_id == project.id
    end

    test "computes sort_key from story number" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      assert {:ok, s1} =
               Stories.create_story(tenant.id, %{
                 epic_id: epic.id,
                 number: "1.1",
                 title: "S1"
               })

      assert {:ok, s2} =
               Stories.create_story(tenant.id, %{
                 epic_id: epic.id,
                 number: "1.10",
                 title: "S2"
               })

      assert {:ok, s3} =
               Stories.create_story(tenant.id, %{
                 epic_id: epic.id,
                 number: "2.1",
                 title: "S3"
               })

      # 1.1 -> 10010, 1.10 -> 10100, 2.1 -> 20010
      assert s1.sort_key == 10_010
      assert s2.sort_key == 10_100
      assert s3.sort_key == 20_010
      assert s1.sort_key < s2.sort_key
      assert s2.sort_key < s3.sort_key
    end

    test "creates audit log entry on creation" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      actor_id = uuid()

      attrs = %{epic_id: epic.id, number: "1.1", title: "Audited Story"}

      assert {:ok, %Story{}} =
               Stories.create_story(tenant.id, attrs,
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "story", action: "created")

      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.entity_type == "story"
      assert entry.action == "created"
      assert entry.actor_id == actor_id
    end

    test "rejects duplicate number within same project" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      assert {:ok, _} =
               Stories.create_story(tenant.id, %{
                 epic_id: epic.id,
                 number: "1.1",
                 title: "First"
               })

      assert {:error, changeset} =
               Stories.create_story(tenant.id, %{
                 epic_id: epic.id,
                 number: "1.1",
                 title: "Duplicate"
               })

      assert errors_on(changeset).tenant_id != []
    end

    test "rejects duplicate number across epics in same project" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      assert {:ok, _} =
               Stories.create_story(tenant.id, %{
                 epic_id: epic_a.id,
                 number: "1.1",
                 title: "First"
               })

      assert {:error, changeset} =
               Stories.create_story(tenant.id, %{
                 epic_id: epic_b.id,
                 number: "1.1",
                 title: "Same number different epic"
               })

      assert errors_on(changeset).tenant_id != []
    end

    test "rejects missing required fields" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      assert {:error, changeset} =
               Stories.create_story(tenant.id, %{epic_id: epic.id})

      errors = errors_on(changeset)
      assert errors.number != []
      assert errors.title != []
    end

    test "returns error for nonexistent epic" do
      tenant = fixture(:tenant)
      attrs = %{epic_id: uuid(), number: "1.1", title: "Orphan"}
      assert {:error, :epic_not_found} = Stories.create_story(tenant.id, attrs)
    end
  end

  describe "get_story/2" do
    test "returns story by ID within tenant" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      assert {:ok, found} = Stories.get_story(tenant.id, story.id)
      assert found.id == story.id
    end

    test "returns not_found for unknown ID" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Stories.get_story(tenant.id, uuid())
    end

    test "returns not_found for story in different tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant_b.id})
      epic = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant_b.id, epic_id: epic.id})

      assert {:error, :not_found} = Stories.get_story(tenant_a.id, story.id)
    end
  end

  describe "update_story/4" do
    test "updates story title" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      assert {:ok, updated} =
               Stories.update_story(tenant.id, story, %{title: "Updated Title"})

      assert updated.title == "Updated Title"
    end

    test "does not allow updating agent_status or verified_status" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      assert {:ok, updated} =
               Stories.update_story(tenant.id, story, %{
                 agent_status: :reported_done,
                 verified_status: :verified,
                 title: "Updated"
               })

      assert updated.title == "Updated"
      # Status fields are not in update_changeset cast, so they remain unchanged
      assert updated.agent_status == :pending
      assert updated.verified_status == :unverified
    end

    test "creates audit log entry on update" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
      actor_id = uuid()

      assert {:ok, _} =
               Stories.update_story(tenant.id, story, %{title: "Renamed"},
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "story", action: "updated")

      assert length(result.data) == 1
    end
  end

  describe "delete_story/3" do
    test "deletes a story" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      assert {:ok, _deleted} = Stories.delete_story(tenant.id, story)
      assert {:error, :not_found} = Stories.get_story(tenant.id, story.id)
    end

    test "creates audit log entry on delete" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
      actor_id = uuid()

      assert {:ok, _} =
               Stories.delete_story(tenant.id, story,
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "story", action: "deleted")

      assert length(result.data) == 1
    end
  end

  describe "list_stories/3" do
    test "lists stories ordered by sort_key (natural numeric order)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})

      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.10"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "2.1"})

      {:ok, result} = Stories.list_stories(tenant.id, epic.id)

      numbers = Enum.map(result.data, & &1.number)
      # Natural order: 1.1, 1.2, 1.10, 2.1 (NOT lexicographic: 1.1, 1.10, 1.2, 2.1)
      assert numbers == ["1.1", "1.2", "1.10", "2.1"]
    end

    test "filters by agent_status" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        agent_status: :pending
      })

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.2",
        agent_status: :implementing
      })

      {:ok, result} =
        Stories.list_stories(tenant.id, epic.id, agent_status: "pending")

      assert length(result.data) == 1
      assert hd(result.data).agent_status == :pending
    end

    test "filters by verified_status" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        verified_status: :verified
      })

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.2",
        verified_status: :unverified
      })

      {:ok, result} =
        Stories.list_stories(tenant.id, epic.id, verified_status: "verified")

      assert length(result.data) == 1
      assert hd(result.data).verified_status == :verified
    end

    test "paginates results" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      for i <- 1..5 do
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.#{i}"})
      end

      {:ok, page1} = Stories.list_stories(tenant.id, epic.id, page: 1, page_size: 2)
      assert length(page1.data) == 2
      assert page1.total == 5
    end
  end

  describe "list_stories_by_project/3" do
    test "lists all stories across epics in a project" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:story, %{tenant_id: tenant.id, epic_id: epic1.id, number: "1.1"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic2.id, number: "2.1"})

      {:ok, result} = Stories.list_stories_by_project(tenant.id, project.id)

      assert result.total == 2
      assert length(result.data) == 2
    end

    test "filters by epic_id" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:story, %{tenant_id: tenant.id, epic_id: epic1.id, number: "1.1"})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic2.id, number: "2.1"})

      {:ok, result} = Stories.list_stories_by_project(tenant.id, project.id, epic_id: epic1.id)

      assert result.total == 1
      assert hd(result.data).epic_id == epic1.id
    end

    test "filters by agent_status" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        agent_status: :pending
      })

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.2",
        agent_status: :implementing
      })

      {:ok, result} =
        Stories.list_stories_by_project(tenant.id, project.id, agent_status: "pending")

      assert result.total == 1
      assert hd(result.data).agent_status == :pending
    end

    test "respects limit and offset" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      for i <- 1..5 do
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.#{i}"})
      end

      {:ok, result} = Stories.list_stories_by_project(tenant.id, project.id, limit: 2, offset: 0)
      assert length(result.data) == 2
      assert result.total == 5
      assert result.limit == 2
      assert result.offset == 0

      {:ok, result2} =
        Stories.list_stories_by_project(tenant.id, project.id, limit: 2, offset: 2)

      assert length(result2.data) == 2
      assert result2.offset == 2
    end

    test "does not return stories from another tenant's project" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id})
      fixture(:story, %{tenant_id: tenant_b.id, epic_id: epic_b.id})

      {:ok, result} = Stories.list_stories_by_project(tenant_a.id, project_b.id)

      assert result.total == 0
      assert result.data == []
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's stories" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id})
      story_b = fixture(:story, %{tenant_id: tenant_b.id, epic_id: epic_b.id})

      assert {:error, :not_found} = Stories.get_story(tenant_a.id, story_b.id)
    end
  end
end
