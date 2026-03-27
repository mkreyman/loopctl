defmodule Loopctl.WorkBreakdown.EpicsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Epics

  describe "create_epic/3" do
    test "creates an epic with valid attributes" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      attrs = %{
        project_id: project.id,
        number: 1,
        title: "Foundation",
        description: "Core infrastructure",
        phase: "p0_foundation",
        position: 1,
        metadata: %{"priority" => "high"}
      }

      assert {:ok, %Epic{} = epic} =
               Epics.create_epic(tenant.id, attrs,
                 actor_id: uuid(),
                 actor_label: "user:admin"
               )

      assert epic.number == 1
      assert epic.title == "Foundation"
      assert epic.description == "Core infrastructure"
      assert epic.phase == "p0_foundation"
      assert epic.position == 1
      assert epic.tenant_id == tenant.id
      assert epic.project_id == project.id
      assert epic.metadata == %{"priority" => "high"}
    end

    test "creates an epic with minimal attributes" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      attrs = %{project_id: project.id, number: 1, title: "Minimal"}

      assert {:ok, %Epic{} = epic} = Epics.create_epic(tenant.id, attrs)
      assert epic.number == 1
      assert epic.title == "Minimal"
      assert epic.position == 0
      assert epic.metadata == %{}
    end

    test "creates audit log entry on creation" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      actor_id = uuid()

      attrs = %{project_id: project.id, number: 1, title: "Audited Epic"}

      assert {:ok, %Epic{}} =
               Epics.create_epic(tenant.id, attrs,
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "epic", action: "created")

      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.entity_type == "epic"
      assert entry.action == "created"
      assert entry.actor_id == actor_id
      assert entry.new_state["title"] == "Audited Epic"
    end

    test "rejects duplicate number within same project" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1})

      attrs = %{project_id: project.id, number: 1, title: "Duplicate"}
      assert {:error, changeset} = Epics.create_epic(tenant.id, attrs)
      assert errors_on(changeset).tenant_id != []
    end

    test "allows same number in different projects" do
      tenant = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant.id})
      project_b = fixture(:project, %{tenant_id: tenant.id})

      fixture(:epic, %{tenant_id: tenant.id, project_id: project_a.id, number: 1})

      attrs = %{project_id: project_b.id, number: 1, title: "Same Number"}
      assert {:ok, _} = Epics.create_epic(tenant.id, attrs)
    end

    test "rejects missing required fields" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      assert {:error, changeset} = Epics.create_epic(tenant.id, %{project_id: project.id})
      errors = errors_on(changeset)
      assert errors.number != []
      assert errors.title != []
    end

    test "defaults metadata to empty map" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      attrs = %{project_id: project.id, number: 1, title: "No Meta"}
      assert {:ok, epic} = Epics.create_epic(tenant.id, attrs)
      assert epic.metadata == %{}
    end
  end

  describe "get_epic/2" do
    test "returns epic by ID within tenant" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      assert {:ok, found} = Epics.get_epic(tenant.id, epic.id)
      assert found.id == epic.id
    end

    test "returns not_found for unknown ID" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Epics.get_epic(tenant.id, uuid())
    end

    test "returns not_found for epic in different tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant_b.id})
      epic = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project.id})

      assert {:error, :not_found} = Epics.get_epic(tenant_a.id, epic.id)
    end
  end

  describe "update_epic/4" do
    test "updates epic title" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      assert {:ok, updated} = Epics.update_epic(tenant.id, epic, %{title: "Updated Title"})
      assert updated.title == "Updated Title"
    end

    test "creates audit log entry on update" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      actor_id = uuid()

      assert {:ok, _} =
               Epics.update_epic(tenant.id, epic, %{title: "Renamed"},
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "epic", action: "updated")

      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.action == "updated"
      assert entry.actor_id == actor_id
    end
  end

  describe "delete_epic/3" do
    test "deletes an epic" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      assert {:ok, _deleted} = Epics.delete_epic(tenant.id, epic)
      assert {:error, :not_found} = Epics.get_epic(tenant.id, epic.id)
    end

    test "creates audit log entry on delete" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      actor_id = uuid()

      assert {:ok, _} =
               Epics.delete_epic(tenant.id, epic,
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "epic", action: "deleted")

      assert length(result.data) == 1
    end
  end

  describe "list_epics/3" do
    test "lists epics for a project ordered by position then number" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 2, position: 0})
      fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 1, position: 0})
      fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: 3, position: 1})

      {:ok, result} = Epics.list_epics(tenant.id, project.id)

      numbers = Enum.map(result.data, & &1.number)
      # position 0 first (numbers 1,2), then position 1 (number 3)
      assert numbers == [1, 2, 3]
      assert result.total == 3
    end

    test "filters by phase" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      fixture(:epic, %{
        tenant_id: tenant.id,
        project_id: project.id,
        number: 1,
        phase: "p0_foundation"
      })

      fixture(:epic, %{
        tenant_id: tenant.id,
        project_id: project.id,
        number: 2,
        phase: "p1_core"
      })

      {:ok, result} = Epics.list_epics(tenant.id, project.id, phase: "p0_foundation")
      assert length(result.data) == 1
      assert hd(result.data).phase == "p0_foundation"
    end

    test "paginates results" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      for i <- 1..5 do
        fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, number: i})
      end

      {:ok, page1} = Epics.list_epics(tenant.id, project.id, page: 1, page_size: 2)
      assert length(page1.data) == 2
      assert page1.total == 5

      {:ok, page3} = Epics.list_epics(tenant.id, project.id, page: 3, page_size: 2)
      assert length(page3.data) == 1
    end

    test "caps page_size at 100" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      {:ok, result} = Epics.list_epics(tenant.id, project.id, page_size: 200)
      assert result.page_size == 100
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's epics" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      fixture(:epic, %{tenant_id: tenant_a.id, project_id: project_a.id, number: 1})
      fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id, number: 1})

      {:ok, result_a} = Epics.list_epics(tenant_a.id, project_a.id)
      assert length(result_a.data) == 1

      # Tenant A cannot get tenant B's epic
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id, number: 2})
      assert {:error, :not_found} = Epics.get_epic(tenant_a.id, epic_b.id)
    end
  end
end
