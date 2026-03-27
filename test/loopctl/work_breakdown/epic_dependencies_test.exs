defmodule Loopctl.WorkBreakdown.EpicDependenciesTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.WorkBreakdown.Dependencies

  describe "create_epic_dependency/3" do
    test "creates a valid dependency" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      assert {:ok, dep} =
               Dependencies.create_epic_dependency(tenant.id, %{
                 epic_id: epic_b.id,
                 depends_on_epic_id: epic_a.id
               })

      assert dep.epic_id == epic_b.id
      assert dep.depends_on_epic_id == epic_a.id
      assert dep.tenant_id == tenant.id
    end

    test "creates audit log entry" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})
      actor_id = uuid()

      assert {:ok, _dep} =
               Dependencies.create_epic_dependency(
                 tenant.id,
                 %{epic_id: epic_b.id, depends_on_epic_id: epic_a.id},
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "epic_dependency",
          action: "created"
        )

      assert length(result.data) == 1
    end

    test "rejects self-dependency" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      assert {:error, :self_dependency} =
               Dependencies.create_epic_dependency(tenant.id, %{
                 epic_id: epic.id,
                 depends_on_epic_id: epic.id
               })
    end

    test "rejects cross-project dependency" do
      tenant = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant.id})
      project_b = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project_a.id})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project_b.id})

      assert {:error, :cross_project} =
               Dependencies.create_epic_dependency(tenant.id, %{
                 epic_id: epic_b.id,
                 depends_on_epic_id: epic_a.id
               })
    end

    test "rejects direct cycle (A depends on B, B depends on A)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_b.id,
        depends_on_epic_id: epic_a.id
      })

      assert {:error, :cycle_detected} =
               Dependencies.create_epic_dependency(tenant.id, %{
                 epic_id: epic_a.id,
                 depends_on_epic_id: epic_b.id
               })
    end

    test "rejects transitive cycle (A->B->C->A)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})
      epic_c = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 3})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_b.id,
        depends_on_epic_id: epic_a.id
      })

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_c.id,
        depends_on_epic_id: epic_b.id
      })

      assert {:error, :cycle_detected} =
               Dependencies.create_epic_dependency(tenant.id, %{
                 epic_id: epic_a.id,
                 depends_on_epic_id: epic_c.id
               })
    end

    test "rejects duplicate dependency" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_b.id,
        depends_on_epic_id: epic_a.id
      })

      assert {:error, :conflict} =
               Dependencies.create_epic_dependency(tenant.id, %{
                 epic_id: epic_b.id,
                 depends_on_epic_id: epic_a.id
               })
    end

    test "rejects cross-level deadlock from epic side (story dep exists, epic dep would conflict)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      story_a = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_a.id, number: "1.1"})
      story_b = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_b.id, number: "2.1"})

      # Story B depends on Story A (cross-epic)
      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: story_b.id,
        depends_on_story_id: story_a.id
      })

      # Now try: Epic A depends on Epic B — this conflicts because
      # story_b (in Epic B, the prerequisite) depends on story_a (in Epic A, the dependent)
      assert {:error, {:cross_level_deadlock, msg}} =
               Dependencies.create_epic_dependency(tenant.id, %{
                 epic_id: epic_a.id,
                 depends_on_epic_id: epic_b.id
               })

      assert msg =~ "Cross-level deadlock"
    end
  end

  describe "delete_epic_dependency/3" do
    test "deletes a dependency" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      dep =
        fixture(:epic_dependency, %{
          tenant_id: tenant.id,
          epic_id: epic_b.id,
          depends_on_epic_id: epic_a.id
        })

      assert {:ok, _} = Dependencies.delete_epic_dependency(tenant.id, dep)
      assert {:error, :not_found} = Dependencies.get_epic_dependency(tenant.id, dep.id)
    end

    test "creates audit log entry on delete" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      dep =
        fixture(:epic_dependency, %{
          tenant_id: tenant.id,
          epic_id: epic_b.id,
          depends_on_epic_id: epic_a.id
        })

      actor_id = uuid()

      assert {:ok, _} =
               Dependencies.delete_epic_dependency(tenant.id, dep,
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "epic_dependency",
          action: "deleted"
        )

      assert length(result.data) == 1
    end
  end

  describe "list_epic_dependencies/2" do
    test "lists dependencies for a project" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic_a = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_b = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_b.id,
        depends_on_epic_id: epic_a.id
      })

      {:ok, deps} = Dependencies.list_epic_dependencies(tenant.id, project.id)
      assert length(deps) == 1
      assert hd(deps).epic_id == epic_b.id
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot access tenant B's dependencies" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b1 = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id, number: 1})
      epic_b2 = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id, number: 2})

      dep =
        fixture(:epic_dependency, %{
          tenant_id: tenant_b.id,
          epic_id: epic_b2.id,
          depends_on_epic_id: epic_b1.id
        })

      assert {:error, :not_found} = Dependencies.get_epic_dependency(tenant_a.id, dep.id)
    end
  end
end
