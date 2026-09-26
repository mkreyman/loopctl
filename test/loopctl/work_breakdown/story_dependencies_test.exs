defmodule Loopctl.WorkBreakdown.StoryDependenciesTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.WorkBreakdown.Dependencies
  alias Loopctl.WorkBreakdown.Queries
  alias Loopctl.WorkBreakdown.Story

  describe "dependency_status/2" do
    # #887 review round 2: the one definition the claim and the dispatch driver share.
    test "an unverified prerequisite is unmet, a verified one is met, another tenant is not found" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      blocker = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})

      {:ok, _dep} =
        Dependencies.create_story_dependency(tenant.id, %{
          story_id: story.id,
          depends_on_story_id: blocker.id
        })

      assert Dependencies.dependency_status(tenant.id, story.id) == :unmet

      # Tenant isolation: asked as another tenant the story is not there, and that is its own
      # answer, never "satisfied".
      assert Dependencies.dependency_status(fixture(:tenant).id, story.id) == :not_found

      Loopctl.AdminRepo.update_all(
        from(s in Story, where: s.id == ^blocker.id),
        set: [verified_status: :verified]
      )

      assert Dependencies.dependency_status(tenant.id, story.id) == :met
    end
  end

  describe "dependency_status/2 and unmet_story_ids/2" do
    # #890 review round 1: the EPIC half, and the three answers kept apart.
    test "an epic whose prerequisite epic holds an unverified story is unmet, until it is verified" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      prereq_epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})
      prereq = fixture(:story, %{tenant_id: tenant.id, epic_id: prereq_epic.id, number: "1.1"})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "2.1"})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        depends_on_epic_id: prereq_epic.id
      })

      assert Dependencies.dependency_status(tenant.id, story.id) == :unmet

      assert Dependencies.unmet_story_ids(tenant.id, [story.id, prereq.id]) ==
               MapSet.new([story.id])

      Loopctl.AdminRepo.update_all(
        from(s in Story, where: s.id == ^prereq.id),
        set: [verified_status: :verified]
      )

      assert Dependencies.dependency_status(tenant.id, story.id) == :met
      assert Dependencies.unmet_story_ids(tenant.id, [story.id]) == MapSet.new()
    end

    test "unmet_story_ids/2 reads only its own tenant's stories" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      blocker = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})

      {:ok, _dep} =
        Dependencies.create_story_dependency(tenant.id, %{
          story_id: story.id,
          depends_on_story_id: blocker.id
        })

      assert Dependencies.unmet_story_ids(tenant.id, [story.id]) == MapSet.new([story.id])
      assert Dependencies.unmet_story_ids(fixture(:tenant).id, [story.id]) == MapSet.new()
    end

    test "a story that is not there is :not_found, never :met" do
      tenant = fixture(:tenant)
      assert Dependencies.dependency_status(tenant.id, Ecto.UUID.generate()) == :not_found
    end
  end

  describe "Queries.list_blocked_stories/2" do
    # #890 review round 3: a prerequisite that blocks both directly and through its epic is
    # listed once.
    test "a prerequisite blocking directly AND through its epic is listed once" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      prereq_epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})
      blocker = fixture(:story, %{tenant_id: tenant.id, epic_id: prereq_epic.id, number: "1.1"})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "2.1"})

      {:ok, _dep} =
        Dependencies.create_story_dependency(tenant.id, %{
          story_id: story.id,
          depends_on_story_id: blocker.id
        })

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        depends_on_epic_id: prereq_epic.id
      })

      {:ok, %{data: rows}} = Queries.list_blocked_stories(tenant.id)
      row = Enum.find(rows, &(&1.story.id == story.id)) || Enum.find(rows, &(&1[:id] == story.id))
      assert row, "the story is listed as blocked"
      assert [%{id: id}] = row.blocking_dependencies
      assert id == blocker.id
    end
  end

  describe "create_story_dependency/3" do
    test "creates a valid dependency within same epic" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story_a = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      story_b = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})

      assert {:ok, dep} =
               Dependencies.create_story_dependency(tenant.id, %{
                 story_id: story_b.id,
                 depends_on_story_id: story_a.id
               })

      assert dep.story_id == story_b.id
      assert dep.depends_on_story_id == story_a.id
    end

    test "creates a cross-epic dependency within same project" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})
      story_1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_1.id, number: "1.1"})
      story_2 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_2.id, number: "2.1"})

      assert {:ok, dep} =
               Dependencies.create_story_dependency(tenant.id, %{
                 story_id: story_2.id,
                 depends_on_story_id: story_1.id
               })

      assert dep.story_id == story_2.id
    end

    test "rejects self-dependency" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      assert {:error, :self_dependency} =
               Dependencies.create_story_dependency(tenant.id, %{
                 story_id: story.id,
                 depends_on_story_id: story.id
               })
    end

    test "rejects cycle" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story_a = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      story_b = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: story_b.id,
        depends_on_story_id: story_a.id
      })

      assert {:error, :cycle_detected} =
               Dependencies.create_story_dependency(tenant.id, %{
                 story_id: story_a.id,
                 depends_on_story_id: story_b.id
               })
    end

    test "rejects cross-project dependency" do
      tenant = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant.id})
      project_b = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project_a.id})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project_b.id})
      story_a = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_a.id, number: "1.1"})
      story_b = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_b.id, number: "2.1"})

      assert {:error, :cross_project} =
               Dependencies.create_story_dependency(tenant.id, %{
                 story_id: story_b.id,
                 depends_on_story_id: story_a.id
               })
    end

    test "rejects cross-level deadlock (story in B depends on story in A, but epic A depends on epic B)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      # Epic A depends on Epic B
      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_a.id,
        depends_on_epic_id: epic_b.id
      })

      story_a = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_a.id, number: "1.1"})
      story_b = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_b.id, number: "2.1"})

      # Story in B depends on story in A would conflict
      assert {:error, {:cross_level_deadlock, msg}} =
               Dependencies.create_story_dependency(tenant.id, %{
                 story_id: story_b.id,
                 depends_on_story_id: story_a.id
               })

      assert msg =~ "Cross-level deadlock"
    end

    test "creates audit log entry" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story_a = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      story_b = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})
      actor_id = uuid()

      assert {:ok, _} =
               Dependencies.create_story_dependency(
                 tenant.id,
                 %{story_id: story_b.id, depends_on_story_id: story_a.id},
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "story_dependency",
          action: "created"
        )

      assert length(result.data) == 1
    end
  end

  describe "delete_story_dependency/3" do
    test "deletes a dependency" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story_a = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.1"})
      story_b = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, number: "1.2"})

      dep =
        fixture(:story_dependency, %{
          tenant_id: tenant.id,
          story_id: story_b.id,
          depends_on_story_id: story_a.id
        })

      assert {:ok, _} = Dependencies.delete_story_dependency(tenant.id, dep)
      assert {:error, :not_found} = Dependencies.get_story_dependency(tenant.id, dep.id)
    end
  end

  describe "list_story_dependencies_for_epic/2" do
    test "includes cross-epic deps" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})
      story_1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_1.id, number: "1.1"})
      story_2 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_2.id, number: "2.1"})

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: story_2.id,
        depends_on_story_id: story_1.id
      })

      {:ok, deps} = Dependencies.list_story_dependencies_for_epic(tenant.id, epic_2.id)
      assert length(deps) == 1
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot access tenant B's story dependencies" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id})
      story_b1 = fixture(:story, %{tenant_id: tenant_b.id, epic_id: epic_b.id, number: "1.1"})
      story_b2 = fixture(:story, %{tenant_id: tenant_b.id, epic_id: epic_b.id, number: "1.2"})

      dep =
        fixture(:story_dependency, %{
          tenant_id: tenant_b.id,
          story_id: story_b2.id,
          depends_on_story_id: story_b1.id
        })

      assert {:error, :not_found} = Dependencies.get_story_dependency(tenant_a.id, dep.id)
    end
  end
end
