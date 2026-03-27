defmodule Loopctl.WorkBreakdown.StoryDependenciesTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.WorkBreakdown.Dependencies

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
