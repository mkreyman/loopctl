defmodule Loopctl.WorkBreakdown.QueriesTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.WorkBreakdown.Queries

  defp setup_project do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    %{tenant: tenant, project: project}
  end

  describe "list_ready_stories/2" do
    test "returns pending stories with no dependencies" do
      %{tenant: tenant, project: project} = setup_project()
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.1",
          agent_status: :pending
        })

      {:ok, result} = Queries.list_ready_stories(tenant.id, project_id: project.id)

      ids = Enum.map(result.data, & &1.id)
      assert story.id in ids
    end

    test "excludes stories with unverified dependencies" do
      %{tenant: tenant, project: project} = setup_project()
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      dep_story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.1",
          agent_status: :pending,
          verified_status: :unverified
        })

      blocked_story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.2",
          agent_status: :pending
        })

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: blocked_story.id,
        depends_on_story_id: dep_story.id
      })

      {:ok, result} = Queries.list_ready_stories(tenant.id, project_id: project.id)

      ids = Enum.map(result.data, & &1.id)
      # dep_story is ready (no deps), blocked_story is not
      assert dep_story.id in ids
      refute blocked_story.id in ids
    end

    test "includes stories whose dependencies are all verified" do
      %{tenant: tenant, project: project} = setup_project()
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      verified_dep =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.1",
          verified_status: :verified
        })

      ready_story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.2",
          agent_status: :pending
        })

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: ready_story.id,
        depends_on_story_id: verified_dep.id
      })

      {:ok, result} = Queries.list_ready_stories(tenant.id, project_id: project.id)

      ids = Enum.map(result.data, & &1.id)
      assert ready_story.id in ids
    end

    test "excludes non-pending stories" do
      %{tenant: tenant, project: project} = setup_project()
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.1",
        agent_status: :assigned
      })

      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        number: "1.2",
        agent_status: :implementing
      })

      {:ok, result} = Queries.list_ready_stories(tenant.id, project_id: project.id)
      assert result.data == []
    end

    test "filters by epic_id" do
      %{tenant: tenant, project: project} = setup_project()
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      story_in_1 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic_1.id,
          number: "1.1",
          agent_status: :pending
        })

      _story_in_2 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic_2.id,
          number: "2.1",
          agent_status: :pending
        })

      {:ok, result} = Queries.list_ready_stories(tenant.id, epic_id: epic_1.id)

      ids = Enum.map(result.data, & &1.id)
      assert length(ids) == 1
      assert story_in_1.id in ids
    end

    test "respects epic-level dependencies" do
      %{tenant: tenant, project: project} = setup_project()
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      # Epic 2 depends on Epic 1
      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_2.id,
        depends_on_epic_id: epic_1.id
      })

      # Epic 1 has an unverified story
      _story_1 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic_1.id,
          number: "1.1",
          agent_status: :reported_done,
          verified_status: :unverified
        })

      # Epic 2 has a pending story
      story_2 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic_2.id,
          number: "2.1",
          agent_status: :pending
        })

      {:ok, result} = Queries.list_ready_stories(tenant.id, project_id: project.id)

      ids = Enum.map(result.data, & &1.id)
      # story_2 should NOT be ready because epic 1 has unverified stories
      refute story_2.id in ids
    end
  end

  describe "list_blocked_stories/2" do
    test "returns stories with blocking dependencies" do
      %{tenant: tenant, project: project} = setup_project()
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      blocker =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.1",
          agent_status: :implementing,
          verified_status: :unverified
        })

      blocked =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          number: "1.2",
          agent_status: :pending
        })

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: blocked.id,
        depends_on_story_id: blocker.id
      })

      {:ok, result} = Queries.list_blocked_stories(tenant.id, project_id: project.id)

      assert length(result.data) == 1
      item = hd(result.data)
      assert item.story.id == blocked.id
      assert length(item.blocking_dependencies) == 1
      assert hd(item.blocking_dependencies).id == blocker.id
    end
  end

  describe "get_dependency_graph/2" do
    test "returns full graph with epics, stories, and edges" do
      %{tenant: tenant, project: project} = setup_project()
      epic_1 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})
      epic_2 = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2})

      fixture(:epic_dependency, %{
        tenant_id: tenant.id,
        epic_id: epic_2.id,
        depends_on_epic_id: epic_1.id
      })

      story_1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_1.id, number: "1.1"})
      story_2 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic_2.id, number: "2.1"})

      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: story_2.id,
        depends_on_story_id: story_1.id
      })

      {:ok, graph} = Queries.get_dependency_graph(tenant.id, project.id)

      assert length(graph.epics) == 2
      assert length(graph.epic_dependencies) == 1
      assert length(graph.story_dependencies) == 1

      epic_dep = hd(graph.epic_dependencies)
      assert epic_dep.from == epic_2.id
      assert epic_dep.to == epic_1.id

      story_dep = hd(graph.story_dependencies)
      assert story_dep.from == story_2.id
      assert story_dep.to == story_1.id
    end

    test "returns not_found for nonexistent project" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Queries.get_dependency_graph(tenant.id, uuid())
    end

    test "returns not_found for project in different tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} = Queries.get_dependency_graph(tenant_a.id, project_b.id)
    end
  end
end
