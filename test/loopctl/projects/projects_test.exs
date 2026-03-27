defmodule Loopctl.ProjectsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Projects
  alias Loopctl.Projects.Project

  describe "create_project/3" do
    test "creates a project with valid attributes" do
      tenant = fixture(:tenant)

      attrs = %{
        name: "loopctl",
        slug: "loopctl",
        repo_url: "https://github.com/mkreyman/loopctl",
        tech_stack: "elixir/phoenix",
        description: "Agent-native project state store",
        metadata: %{"category" => "tooling"}
      }

      assert {:ok, %Project{} = project} =
               Projects.create_project(tenant.id, attrs,
                 actor_id: uuid(),
                 actor_label: "user:admin"
               )

      assert project.name == "loopctl"
      assert project.slug == "loopctl"
      assert project.repo_url == "https://github.com/mkreyman/loopctl"
      assert project.tech_stack == "elixir/phoenix"
      assert project.status == :active
      assert project.tenant_id == tenant.id
      assert project.metadata == %{"category" => "tooling"}
    end

    test "creates a project with minimal attributes" do
      tenant = fixture(:tenant)

      attrs = %{name: "minimal", slug: "minimal"}

      assert {:ok, %Project{} = project} = Projects.create_project(tenant.id, attrs)
      assert project.name == "minimal"
      assert project.slug == "minimal"
      assert project.status == :active
      assert project.metadata == %{}
    end

    test "creates audit log entry on creation" do
      tenant = fixture(:tenant)
      actor_id = uuid()

      attrs = %{name: "audited-project", slug: "audited-project"}

      assert {:ok, %Project{}} =
               Projects.create_project(tenant.id, attrs,
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "project", action: "created")

      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.entity_type == "project"
      assert entry.action == "created"
      assert entry.actor_id == actor_id
      assert entry.actor_label == "user:admin"
      assert entry.new_state["name"] == "audited-project"
      assert entry.new_state["slug"] == "audited-project"
      assert entry.new_state["status"] == "active"
    end

    test "rejects duplicate slug within same tenant" do
      tenant = fixture(:tenant)

      attrs = %{name: "First", slug: "my-project"}
      assert {:ok, _} = Projects.create_project(tenant.id, attrs)

      attrs2 = %{name: "Second", slug: "my-project"}
      assert {:error, changeset} = Projects.create_project(tenant.id, attrs2)
      assert "has already been taken for this tenant" in errors_on(changeset).tenant_id
    end

    test "allows same slug in different tenants" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      attrs = %{name: "Shared", slug: "shared-slug"}

      assert {:ok, _} = Projects.create_project(tenant_a.id, attrs)
      assert {:ok, _} = Projects.create_project(tenant_b.id, attrs)
    end

    test "rejects missing required fields" do
      tenant = fixture(:tenant)

      assert {:error, changeset} = Projects.create_project(tenant.id, %{})
      errors = errors_on(changeset)
      assert errors.name != []
      assert errors.slug != []
    end

    test "rejects invalid slug format" do
      tenant = fixture(:tenant)

      # Uppercase
      assert {:error, changeset} =
               Projects.create_project(tenant.id, %{name: "Test", slug: "INVALID"})

      assert errors_on(changeset).slug != []

      # Too short
      assert {:error, changeset} = Projects.create_project(tenant.id, %{name: "Test", slug: "a"})
      assert errors_on(changeset).slug != []

      # Starts with hyphen
      assert {:error, changeset} =
               Projects.create_project(tenant.id, %{name: "Test", slug: "-bad"})

      assert errors_on(changeset).slug != []
    end

    test "defaults metadata to empty map" do
      tenant = fixture(:tenant)

      attrs = %{name: "no-meta", slug: "no-meta"}
      assert {:ok, project} = Projects.create_project(tenant.id, attrs)
      assert project.metadata == %{}
    end

    test "enforces project limit" do
      tenant = fixture(:tenant, %{settings: %{"max_projects" => 1}})

      attrs1 = %{name: "first", slug: "first"}
      assert {:ok, _} = Projects.create_project(tenant.id, attrs1)

      attrs2 = %{name: "second", slug: "second"}
      assert {:error, :project_limit_reached} = Projects.create_project(tenant.id, attrs2)
    end

    test "defaults project limit to 50" do
      tenant = fixture(:tenant)

      # Should succeed (well under default limit of 50)
      attrs = %{name: "within-limit", slug: "within-limit"}
      assert {:ok, _} = Projects.create_project(tenant.id, attrs)
    end
  end

  describe "get_project/2" do
    test "returns project by ID within tenant" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id, name: "my-project", slug: "my-project"})

      assert {:ok, found} = Projects.get_project(tenant.id, project.id)
      assert found.id == project.id
      assert found.name == "my-project"
    end

    test "returns not_found for unknown ID" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Projects.get_project(tenant.id, uuid())
    end

    test "returns not_found for project in different tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} = Projects.get_project(tenant_a.id, project.id)
    end
  end

  describe "get_project_by_slug/2" do
    test "returns project by slug within tenant" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id, slug: "my-slug"})

      assert {:ok, found} = Projects.get_project_by_slug(tenant.id, "my-slug")
      assert found.id == project.id
    end

    test "returns not_found for unknown slug" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Projects.get_project_by_slug(tenant.id, "nonexistent")
    end

    test "returns not_found for slug in different tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      _project = fixture(:project, %{tenant_id: tenant_b.id, slug: "cross-tenant"})

      assert {:error, :not_found} = Projects.get_project_by_slug(tenant_a.id, "cross-tenant")
    end
  end

  describe "update_project/4" do
    test "updates project name" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      assert {:ok, updated} =
               Projects.update_project(tenant.id, project, %{name: "Updated Name"})

      assert updated.name == "Updated Name"
    end

    test "updates project metadata" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      new_metadata = %{"version" => "2.0"}

      assert {:ok, updated} =
               Projects.update_project(tenant.id, project, %{metadata: new_metadata})

      assert updated.metadata == new_metadata
    end

    test "creates audit log entry on update" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id, name: "original"})
      actor_id = uuid()

      assert {:ok, _} =
               Projects.update_project(tenant.id, project, %{name: "renamed"},
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "project", action: "updated")

      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.action == "updated"
      assert entry.actor_id == actor_id
      assert entry.new_state["name"] == "renamed"
    end

    test "rejects invalid status" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      assert {:error, changeset} =
               Projects.update_project(tenant.id, project, %{status: :invalid})

      assert errors_on(changeset).status != []
    end
  end

  describe "archive_project/3" do
    test "archives project by setting status to archived" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      assert {:ok, archived} = Projects.archive_project(tenant.id, project)
      assert archived.status == :archived
      assert archived.id == project.id
    end

    test "creates audit log entry on archive" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      actor_id = uuid()

      assert {:ok, _} =
               Projects.archive_project(tenant.id, project,
                 actor_id: actor_id,
                 actor_label: "user:admin"
               )

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "project", action: "archived")

      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.action == "archived"
      assert entry.new_state["status"] == "archived"
    end
  end

  describe "list_projects/2" do
    test "lists active projects for a tenant" do
      tenant = fixture(:tenant)
      fixture(:project, %{tenant_id: tenant.id, name: "project-a", slug: "project-a"})
      fixture(:project, %{tenant_id: tenant.id, name: "project-b", slug: "project-b"})

      {:ok, result} = Projects.list_projects(tenant.id)

      assert length(result.data) == 2
      assert result.total == 2
      assert result.page == 1
      assert result.page_size == 20
    end

    test "excludes archived projects by default" do
      tenant = fixture(:tenant)
      fixture(:project, %{tenant_id: tenant.id, slug: "active-one"})
      archived = fixture(:project, %{tenant_id: tenant.id, slug: "archived-one"})
      Projects.archive_project(tenant.id, archived)

      {:ok, result} = Projects.list_projects(tenant.id)

      assert length(result.data) == 1
      slugs = Enum.map(result.data, & &1.slug)
      assert "active-one" in slugs
      refute "archived-one" in slugs
    end

    test "includes archived projects when include_archived is true" do
      tenant = fixture(:tenant)
      fixture(:project, %{tenant_id: tenant.id, slug: "active-one"})
      archived = fixture(:project, %{tenant_id: tenant.id, slug: "archived-one"})
      Projects.archive_project(tenant.id, archived)

      {:ok, result} = Projects.list_projects(tenant.id, include_archived: true)

      assert length(result.data) == 2
    end

    test "paginates results" do
      tenant = fixture(:tenant)

      for i <- 1..5 do
        fixture(:project, %{
          tenant_id: tenant.id,
          name: "project-#{String.pad_leading(to_string(i), 2, "0")}",
          slug: "project-#{String.pad_leading(to_string(i), 2, "0")}"
        })
      end

      {:ok, page1} = Projects.list_projects(tenant.id, page: 1, page_size: 2)
      assert length(page1.data) == 2
      assert page1.total == 5
      assert page1.page == 1

      {:ok, page3} = Projects.list_projects(tenant.id, page: 3, page_size: 2)
      assert length(page3.data) == 1
    end

    test "returns projects ordered by name" do
      tenant = fixture(:tenant)
      fixture(:project, %{tenant_id: tenant.id, name: "zeta-project", slug: "zeta-project"})
      fixture(:project, %{tenant_id: tenant.id, name: "alpha-project", slug: "alpha-project"})

      {:ok, result} = Projects.list_projects(tenant.id)

      names = Enum.map(result.data, & &1.name)
      assert names == ["alpha-project", "zeta-project"]
    end

    test "caps page_size at 100" do
      tenant = fixture(:tenant)
      fixture(:project, %{tenant_id: tenant.id})

      {:ok, result} = Projects.list_projects(tenant.id, page_size: 200)
      assert result.page_size == 100
    end
  end

  describe "get_project_progress/2" do
    test "returns zeroed progress for existing project" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      assert {:ok, progress} = Projects.get_project_progress(tenant.id, project.id)

      assert progress.total_stories == 0
      assert progress.total_epics == 0
      assert progress.epics_completed == 0
      assert progress.verification_percentage == 0.0
      assert progress.estimated_hours_total == 0
      assert progress.estimated_hours_completed == 0

      assert progress.stories_by_agent_status == %{
               pending: 0,
               contracted: 0,
               assigned: 0,
               implementing: 0,
               reported_done: 0
             }

      assert progress.stories_by_verified_status == %{
               unverified: 0,
               verified: 0,
               rejected: 0
             }
    end

    test "returns not_found for nonexistent project" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Projects.get_project_progress(tenant.id, uuid())
    end

    test "returns not_found for project in different tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} = Projects.get_project_progress(tenant_a.id, project.id)
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's projects" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      fixture(:project, %{tenant_id: tenant_a.id, name: "project-a", slug: "project-a"})
      fixture(:project, %{tenant_id: tenant_b.id, name: "project-b", slug: "project-b"})

      {:ok, result_a} = Projects.list_projects(tenant_a.id)
      {:ok, result_b} = Projects.list_projects(tenant_b.id)

      assert length(result_a.data) == 1
      assert hd(result_a.data).name == "project-a"

      assert length(result_b.data) == 1
      assert hd(result_b.data).name == "project-b"
    end

    test "get_project returns not_found for cross-tenant access" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} = Projects.get_project(tenant_a.id, project_b.id)
    end
  end
end
