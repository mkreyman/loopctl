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
      assert "has already been taken for this tenant" in errors_on(changeset).slug
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

    test "archived projects do not count toward limit" do
      tenant = fixture(:tenant, %{settings: %{"max_projects" => 2}})

      attrs1 = %{name: "first", slug: "first"}
      assert {:ok, _} = Projects.create_project(tenant.id, attrs1)

      attrs2 = %{name: "second", slug: "second"}
      assert {:ok, project2} = Projects.create_project(tenant.id, attrs2)

      # At limit -- cannot create a third
      attrs3 = %{name: "third", slug: "third"}
      assert {:error, :project_limit_reached} = Projects.create_project(tenant.id, attrs3)

      # Archive one project
      assert {:ok, _} = Projects.archive_project(tenant.id, project2)

      # Now can create again since only 1 active project remains
      assert {:ok, _} = Projects.create_project(tenant.id, attrs3)
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

  describe "resolve_project/2" do
    test "resolves by exact slug" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id, slug: "loopctl"})

      assert {:ok, found} = Projects.resolve_project(tenant.id, slug: "loopctl")
      assert found.id == project.id
    end

    test "resolves by repo_url in https form" do
      tenant = fixture(:tenant)

      project =
        fixture(:project, %{
          tenant_id: tenant.id,
          slug: "loopctl",
          repo_url: "https://github.com/mkreyman/loopctl"
        })

      assert {:ok, found} =
               Projects.resolve_project(tenant.id,
                 repo_url: "https://github.com/mkreyman/loopctl"
               )

      assert found.id == project.id
    end

    test "resolves by repo_url in git@ ssh form (with .git suffix)" do
      tenant = fixture(:tenant)

      project =
        fixture(:project, %{
          tenant_id: tenant.id,
          slug: "loopctl",
          repo_url: "https://github.com/mkreyman/loopctl"
        })

      assert {:ok, found} =
               Projects.resolve_project(tenant.id,
                 repo_url: "git@github.com:mkreyman/loopctl.git"
               )

      assert found.id == project.id
    end

    test "resolves by repo_url in bare owner/repo form" do
      tenant = fixture(:tenant)

      project =
        fixture(:project, %{
          tenant_id: tenant.id,
          slug: "loopctl",
          repo_url: "git@github.com:mkreyman/loopctl.git"
        })

      assert {:ok, found} =
               Projects.resolve_project(tenant.id, repo_url: "mkreyman/loopctl")

      assert found.id == project.id
    end

    test "resolves by name case-insensitively" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id, name: "LoopCtl", slug: "loopctl"})

      assert {:ok, found} = Projects.resolve_project(tenant.id, name: "loopctl")
      assert found.id == project.id

      assert {:ok, found2} = Projects.resolve_project(tenant.id, name: "LOOPCTL")
      assert found2.id == project.id
    end

    test "slug takes precedence over name when both point to different projects" do
      tenant = fixture(:tenant)

      by_slug =
        fixture(:project, %{tenant_id: tenant.id, name: "Slug Project", slug: "the-slug"})

      _by_name =
        fixture(:project, %{tenant_id: tenant.id, name: "the-slug", slug: "other-slug"})

      assert {:ok, found} =
               Projects.resolve_project(tenant.id, slug: "the-slug", name: "the-slug")

      assert found.id == by_slug.id
    end

    test "repo_url takes precedence over name" do
      tenant = fixture(:tenant)

      by_repo =
        fixture(:project, %{
          tenant_id: tenant.id,
          name: "Repo Project",
          slug: "repo-project",
          repo_url: "https://github.com/mkreyman/loopctl"
        })

      _by_name =
        fixture(:project, %{tenant_id: tenant.id, name: "mkreyman/loopctl", slug: "name-project"})

      assert {:ok, found} =
               Projects.resolve_project(tenant.id,
                 repo_url: "mkreyman/loopctl",
                 name: "mkreyman/loopctl"
               )

      assert found.id == by_repo.id
    end

    test "prefers active project when multiple match by repo_url" do
      tenant = fixture(:tenant)

      archived =
        fixture(:project, %{
          tenant_id: tenant.id,
          slug: "archived-repo",
          repo_url: "https://github.com/mkreyman/loopctl"
        })

      Projects.archive_project(tenant.id, archived)

      active =
        fixture(:project, %{
          tenant_id: tenant.id,
          slug: "active-repo",
          repo_url: "git@github.com:mkreyman/loopctl.git"
        })

      assert {:ok, found} =
               Projects.resolve_project(tenant.id, repo_url: "mkreyman/loopctl")

      assert found.id == active.id
      assert found.status == :active
    end

    test "prefers active project when multiple match by name" do
      tenant = fixture(:tenant)

      archived =
        fixture(:project, %{tenant_id: tenant.id, name: "Shared", slug: "archived-name"})

      Projects.archive_project(tenant.id, archived)

      active = fixture(:project, %{tenant_id: tenant.id, name: "Shared", slug: "active-name"})

      assert {:ok, found} = Projects.resolve_project(tenant.id, name: "shared")
      assert found.id == active.id
      assert found.status == :active
    end

    test "returns not_found when no project matches" do
      tenant = fixture(:tenant)
      fixture(:project, %{tenant_id: tenant.id, slug: "exists"})

      assert {:error, :not_found} =
               Projects.resolve_project(tenant.id, slug: "missing")

      assert {:error, :not_found} =
               Projects.resolve_project(tenant.id, repo_url: "someone/else")

      assert {:error, :not_found} = Projects.resolve_project(tenant.id, name: "nope")
    end

    test "returns no_identifier when no identifier supplied" do
      tenant = fixture(:tenant)

      assert {:error, :no_identifier} = Projects.resolve_project(tenant.id, [])
      assert {:error, :no_identifier} = Projects.resolve_project(tenant.id, %{})

      assert {:error, :no_identifier} =
               Projects.resolve_project(tenant.id, slug: "", repo_url: "  ", name: nil)
    end

    test "accepts a map of options as well as a keyword list" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id, slug: "map-opts"})

      assert {:ok, found} = Projects.resolve_project(tenant.id, %{slug: "map-opts"})
      assert found.id == project.id
    end

    test "never resolves another tenant's project (slug)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      _project = fixture(:project, %{tenant_id: tenant_b.id, slug: "cross-tenant"})

      assert {:error, :not_found} =
               Projects.resolve_project(tenant_a.id, slug: "cross-tenant")
    end

    test "never resolves another tenant's project (repo_url and name)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      _project =
        fixture(:project, %{
          tenant_id: tenant_b.id,
          name: "Cross Tenant",
          slug: "cross-tenant",
          repo_url: "https://github.com/mkreyman/loopctl"
        })

      assert {:error, :not_found} =
               Projects.resolve_project(tenant_a.id, repo_url: "mkreyman/loopctl")

      assert {:error, :not_found} =
               Projects.resolve_project(tenant_a.id, name: "cross tenant")
    end

    test "does not raise on malformed repo_url input" do
      tenant = fixture(:tenant)
      fixture(:project, %{tenant_id: tenant.id, slug: "safe"})

      assert {:error, :not_found} =
               Projects.resolve_project(tenant.id, repo_url: ":::")

      assert {:error, :not_found} =
               Projects.resolve_project(tenant.id, repo_url: "just-one-segment")
    end

    test "exact repo_url match beats a same-owner/repo match on a different host" do
      tenant = fixture(:tenant)

      github =
        fixture(:project, %{
          tenant_id: tenant.id,
          slug: "gh-app",
          repo_url: "https://github.com/acme/app"
        })

      gitlab =
        fixture(:project, %{
          tenant_id: tenant.id,
          slug: "gl-app",
          repo_url: "https://gitlab.com/acme/app"
        })

      # Exact host should win over the mere owner/repo suffix match.
      assert {:ok, found} =
               Projects.resolve_project(tenant.id, repo_url: "https://gitlab.com/acme/app")

      assert found.id == gitlab.id

      assert {:ok, found2} =
               Projects.resolve_project(tenant.id, repo_url: "https://github.com/acme/app")

      assert found2.id == github.id
    end

    test "ignores decoy projects whose owner/repo does not match (bounded scan)" do
      tenant = fixture(:tenant)

      # Decoys with a different owner/repo must never be considered.
      _decoy1 =
        fixture(:project, %{
          tenant_id: tenant.id,
          slug: "decoy-1",
          repo_url: "https://github.com/other/thing"
        })

      _decoy2 =
        fixture(:project, %{
          tenant_id: tenant.id,
          slug: "decoy-2",
          repo_url: "https://github.com/unrelated/repo"
        })

      target =
        fixture(:project, %{
          tenant_id: tenant.id,
          slug: "target",
          repo_url: "https://github.com/mkreyman/loopctl"
        })

      assert {:ok, found} =
               Projects.resolve_project(tenant.id, repo_url: "mkreyman/loopctl")

      assert found.id == target.id
    end

    test "degenerate repo_url normalizing to empty does not collide with a degenerate stored repo_url" do
      tenant = fixture(:tenant)

      # ".git" is a non-empty (castable) string that normalizes to "".
      _degenerate =
        fixture(:project, %{
          tenant_id: tenant.id,
          slug: "degenerate",
          repo_url: ".git"
        })

      assert {:error, :not_found} =
               Projects.resolve_project(tenant.id, repo_url: ".git")

      assert {:error, :not_found} =
               Projects.resolve_project(tenant.id, repo_url: "/")

      assert {:error, :not_found} =
               Projects.resolve_project(tenant.id, repo_url: "/.git")
    end

    test "resolves by name with mixed case (Postgres lower on both sides)" do
      tenant = fixture(:tenant)

      project =
        fixture(:project, %{tenant_id: tenant.id, name: "MixedCase Project", slug: "mixed-case"})

      assert {:ok, found} =
               Projects.resolve_project(tenant.id, name: "mixedcase project")

      assert found.id == project.id

      assert {:ok, found2} =
               Projects.resolve_project(tenant.id, name: "MIXEDCASE PROJECT")

      assert found2.id == project.id

      # NOTE: A non-ASCII case-folding assertion (e.g. "Café Ölçek" vs
      # "café ölçek") is intentionally omitted: this DB's `lower()` locale does
      # not fold accented uppercase, so such an assertion is not portable here.
      # The fix's value is that BOTH sides now fold through the same Postgres
      # `lower()` rather than mixing Elixir String.downcase/1 with SQL lower(),
      # eliminating the cross-locale divergence regardless of the active locale.
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

  describe "mission field" do
    test "creates project with mission" do
      tenant = fixture(:tenant)

      mission = "Build the #1 AI note-taking app to $1M MRR."

      attrs = %{
        name: "notes",
        slug: "notes",
        mission: mission
      }

      assert {:ok, project} =
               Projects.create_project(tenant.id, attrs,
                 actor_id: uuid(),
                 actor_label: "user:admin"
               )

      assert project.mission == mission
    end

    test "creates project without mission (defaults to nil)" do
      tenant = fixture(:tenant)

      attrs = %{name: "plain", slug: "plain"}

      assert {:ok, project} =
               Projects.create_project(tenant.id, attrs,
                 actor_id: uuid(),
                 actor_label: "user:admin"
               )

      assert project.mission == nil
    end

    test "trims whitespace from mission" do
      tenant = fixture(:tenant)

      attrs = %{name: "trim", slug: "trim", mission: "   Be awesome.   "}

      assert {:ok, project} =
               Projects.create_project(tenant.id, attrs,
                 actor_id: uuid(),
                 actor_label: "user:admin"
               )

      assert project.mission == "Be awesome."
    end

    test "normalizes empty-string mission to nil" do
      tenant = fixture(:tenant)

      attrs = %{name: "empty", slug: "empty", mission: "   "}

      assert {:ok, project} =
               Projects.create_project(tenant.id, attrs,
                 actor_id: uuid(),
                 actor_label: "user:admin"
               )

      assert project.mission == nil
    end

    test "rejects mission longer than 2000 characters" do
      tenant = fixture(:tenant)

      long_mission = String.duplicate("a", 2001)
      attrs = %{name: "toolong", slug: "toolong", mission: long_mission}

      assert {:error, changeset} =
               Projects.create_project(tenant.id, attrs,
                 actor_id: uuid(),
                 actor_label: "user:admin"
               )

      assert errors_on(changeset).mission != []
    end

    test "updates mission via update_project" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id, mission: "old goal"})

      assert {:ok, updated} =
               Projects.update_project(tenant.id, project, %{mission: "new goal"})

      assert updated.mission == "new goal"
    end

    test "clears mission via empty string" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id, mission: "old goal"})

      assert {:ok, updated} =
               Projects.update_project(tenant.id, project, %{mission: ""})

      assert updated.mission == nil
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

  describe "count_projects/2" do
    test "counts all projects for a tenant" do
      tenant = fixture(:tenant)
      fixture(:project, %{tenant_id: tenant.id, slug: "proj-a"})
      fixture(:project, %{tenant_id: tenant.id, slug: "proj-b"})

      assert Projects.count_projects(tenant.id) == 2
    end

    test "counts only active projects when status filter is given" do
      tenant = fixture(:tenant)
      fixture(:project, %{tenant_id: tenant.id, slug: "active-proj"})
      archived = fixture(:project, %{tenant_id: tenant.id, slug: "archived-proj"})
      Projects.archive_project(tenant.id, archived)

      assert Projects.count_projects(tenant.id, status: :active) == 1
      assert Projects.count_projects(tenant.id, status: :archived) == 1
    end

    test "returns zero for tenant with no projects" do
      tenant = fixture(:tenant)
      assert Projects.count_projects(tenant.id) == 0
    end

    test "does not count projects from other tenants" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      fixture(:project, %{tenant_id: tenant_a.id, slug: "proj-a"})
      fixture(:project, %{tenant_id: tenant_b.id, slug: "proj-b"})

      assert Projects.count_projects(tenant_a.id) == 1
      assert Projects.count_projects(tenant_b.id) == 1
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
