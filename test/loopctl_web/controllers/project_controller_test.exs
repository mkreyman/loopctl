defmodule LoopctlWeb.ProjectControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Projects

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/projects" do
    test "creates a project with valid attributes", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects", %{
          "name" => "loopctl",
          "slug" => "loopctl",
          "repo_url" => "https://github.com/mkreyman/loopctl",
          "tech_stack" => "elixir/phoenix"
        })

      body = json_response(conn, 201)
      project = body["project"]

      assert project["name"] == "loopctl"
      assert project["slug"] == "loopctl"
      assert project["status"] == "active"
      assert project["kind"] == "work"
      assert project["repo_url"] == "https://github.com/mkreyman/loopctl"
      assert project["tech_stack"] == "elixir/phoenix"
      assert project["tenant_id"] == tenant.id
      assert is_binary(project["id"])
    end

    test "rejects duplicate slug within tenant", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      fixture(:project, %{tenant_id: tenant.id, slug: "my-project"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects", %{
          "name" => "Other",
          "slug" => "my-project"
        })

      assert json_response(conn, 422)
    end

    test "rejects missing required fields", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects", %{})

      assert json_response(conn, 422)
    end

    test "enforces project limit", %{conn: conn} do
      tenant = fixture(:tenant, %{settings: %{"max_projects" => 1}})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects", %{
          "name" => "over-limit",
          "slug" => "over-limit"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "Project limit reached"
    end

    test "requires user role (agent cannot create)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects", %{
          "name" => "test",
          "slug" => "test-project"
        })

      assert json_response(conn, 403)
    end

    test "creates audit log entries", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/projects", %{
        "name" => "audited",
        "slug" => "audited"
      })

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "project", action: "created")

      assert length(result.data) == 1
    end

    test "creates project with mission and round-trips it in the response", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects", %{
          "name" => "mission-test",
          "slug" => "mission-test",
          "mission" => "Build the #1 AI dev loop tool by 2027."
        })

      project = json_response(conn, 201)["project"]
      assert project["mission"] == "Build the #1 AI dev loop tool by 2027."
    end

    test "returns mission as nil when not provided", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects", %{"name" => "plain", "slug" => "plain"})

      project = json_response(conn, 201)["project"]
      assert Map.has_key?(project, "mission")
      assert project["mission"] == nil
    end
  end

  describe "POST /api/v1/kb-scopes" do
    test "agent-rooted tenant creates a KB scope with an agent key", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/kb-scopes", %{
          "name" => "memory-loop-testbed",
          "slug" => "memory-loop-testbed",
          "repo_url" => "https://github.com/mkreyman/memory-loop-testbed"
        })

      project = json_response(conn, 201)["project"]
      assert project["kind"] == "kb"
      assert project["slug"] == "memory-loop-testbed"
      assert project["status"] == "active"
      assert project["tenant_id"] == tenant.id
    end

    test "KB scope is resolvable by repo_url (feeds capture project scoping)", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/kb-scopes", %{
        "name" => "tb",
        "slug" => "tb",
        "repo_url" => "https://github.com/mkreyman/tb"
      })

      assert {:ok, project, _matched_by} =
               Projects.resolve_project(tenant.id, repo_url: "https://github.com/mkreyman/tb")

      assert project.kind == :kb
    end

    test "kind cannot be forced to :work via the request body", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/kb-scopes", %{"name" => "xx", "slug" => "xx", "kind" => "work"})

      assert json_response(conn, 201)["project"]["kind"] == "kb"
    end

    test "KB scopes share the max_projects budget", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted, settings: %{"max_projects" => 1}})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {:ok, _} = Projects.create_project(tenant.id, %{name: "first", slug: "first"}, kind: :kb)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/kb-scopes", %{"name" => "second", "slug" => "second"})

      assert json_response(conn, 422)["error"]["message"] =~ "Project limit reached"
    end

    test "a KB scope is a valid article scope", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {:ok, kb} = Projects.create_project(tenant.id, %{name: "kb", slug: "kb"}, kind: :kb)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{kb.id}/articles", %{
          "title" => "Testbed convention",
          "body" => "A durable project-scoped fact for the testbed.",
          "category" => "pattern"
        })

      assert json_response(conn, 201)["data"]["project_id"] == kb.id
    end

    test "existing POST /projects is unchanged: agent-rooted still 403s", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects", %{"name" => "w", "slug" => "w"})

      assert json_response(conn, 403)["error"]["code"] == "custody_tier_required"
    end
  end

  describe "DELETE /api/v1/kb-scopes/:id (agent archive of own KB scope)" do
    test "agent-rooted tenant archives its own :kb scope", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {:ok, kb} = Projects.create_project(tenant.id, %{name: "kb", slug: "kb"}, kind: :kb)

      conn = conn |> auth_conn(raw_key) |> delete(~p"/api/v1/kb-scopes/#{kb.id}")

      project = json_response(conn, 200)["project"]
      assert project["id"] == kb.id
      assert project["status"] == "archived"
      assert project["kind"] == "kb"
    end

    test "archiving a :kb scope frees the max_projects budget slot", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted, settings: %{"max_projects" => 1}})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {:ok, kb} = Projects.create_project(tenant.id, %{name: "first", slug: "first"}, kind: :kb)

      # At the cap: a second create is rejected.
      over =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/kb-scopes", %{"name" => "second", "slug" => "second"})

      assert json_response(over, 422)["error"]["message"] =~ "Project limit reached"

      # Archive the first, then the create succeeds (slot reclaimed).
      _ = conn |> auth_conn(raw_key) |> delete(~p"/api/v1/kb-scopes/#{kb.id}")

      again =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/kb-scopes", %{"name" => "third", "slug" => "third"})

      assert json_response(again, 201)["project"]["kind"] == "kb"
    end

    test "rejects archiving a :work project at agent role (422)", %{conn: conn} do
      # A human-anchored tenant (so it can hold a :work project) with an agent key.
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      work = fixture(:project, %{tenant_id: tenant.id, slug: "work"})

      conn = conn |> auth_conn(raw_key) |> delete(~p"/api/v1/kb-scopes/#{work.id}")

      assert json_response(conn, 422)["error"]["message"] =~ "kind: kb"
      # And it is NOT archived.
      assert {:ok, %{status: :active}} = Projects.get_project(tenant.id, work.id)
    end

    test "404 for a cross-tenant or missing scope", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      other = fixture(:tenant, %{trust_tier: :agent_rooted})
      {:ok, foreign} = Projects.create_project(other.id, %{name: "xx", slug: "xx"}, kind: :kb)

      conn = conn |> auth_conn(raw_key) |> delete(~p"/api/v1/kb-scopes/#{foreign.id}")

      assert json_response(conn, 404)
      # The foreign scope is untouched.
      assert {:ok, %{status: :active}} = Projects.get_project(other.id, foreign.id)
    end

    test "restore re-activates an archived :kb scope", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {:ok, kb} = Projects.create_project(tenant.id, %{name: "kb", slug: "kb"}, kind: :kb)
      {:ok, _} = Projects.archive_project(tenant.id, kb)

      conn = conn |> auth_conn(raw_key) |> post(~p"/api/v1/kb-scopes/#{kb.id}/restore")

      assert json_response(conn, 200)["project"]["status"] == "active"
    end

    test "restore is rejected 422 when the tenant is at its project cap", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted, settings: %{"max_projects" => 1}})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {:ok, kb} = Projects.create_project(tenant.id, %{name: "a", slug: "aa"}, kind: :kb)
      {:ok, _} = Projects.archive_project(tenant.id, kb)
      # Fill the single active slot with another scope.
      {:ok, _} = Projects.create_project(tenant.id, %{name: "b", slug: "bb"}, kind: :kb)

      conn = conn |> auth_conn(raw_key) |> post(~p"/api/v1/kb-scopes/#{kb.id}/restore")

      assert json_response(conn, 422)["error"]["message"] =~ "Project limit reached"
      assert {:ok, %{status: :archived}} = Projects.get_project(tenant.id, kb.id)
    end

    test "archive is idempotent (no error on an already-archived scope)", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {:ok, kb} = Projects.create_project(tenant.id, %{name: "kb", slug: "kb"}, kind: :kb)

      _ = conn |> auth_conn(raw_key) |> delete(~p"/api/v1/kb-scopes/#{kb.id}")
      again = conn |> auth_conn(raw_key) |> delete(~p"/api/v1/kb-scopes/#{kb.id}")

      assert json_response(again, 200)["project"]["status"] == "archived"
    end

    test "restore rejects a :work project (422)", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      work = fixture(:project, %{tenant_id: tenant.id, slug: "work"})

      conn = conn |> auth_conn(raw_key) |> post(~p"/api/v1/kb-scopes/#{work.id}/restore")

      assert json_response(conn, 422)["error"]["message"] =~ "kind: kb"
    end
  end

  describe "kind: :kb rejects work-breakdown (RequireWorkProject)" do
    test "ui-test create on a :kb scope 422s (agent-rooted, the reachable surface)", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {:ok, kb} = Projects.create_project(tenant.id, %{name: "kb", slug: "kb"}, kind: :kb)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{kb.id}/ui-tests", %{"name" => "run"})

      assert json_response(conn, 422)["error"]["code"] == "kb_project_no_work"
    end

    test "epic create on a :kb scope 422s (human-anchored caller)", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      {:ok, kb} = Projects.create_project(tenant.id, %{name: "kb", slug: "kb"}, kind: :kb)

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/projects/#{kb.id}/epics", %{"name" => "e"})

      assert json_response(conn, 422)["error"]["code"] == "kb_project_no_work"
    end

    test "story create_in_project on a :kb scope 422s (human-anchored caller)", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      {:ok, kb} = Projects.create_project(tenant.id, %{name: "kb", slug: "kb"}, kind: :kb)

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/projects/#{kb.id}/stories", %{"epic_number" => 1, "title" => "s"})

      assert json_response(conn, 422)["error"]["code"] == "kb_project_no_work"
    end

    test "import on a :kb scope 422s (human-anchored caller)", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      {:ok, kb} = Projects.create_project(tenant.id, %{name: "kb", slug: "kb"}, kind: :kb)

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/projects/#{kb.id}/import", %{"epics" => []})

      assert json_response(conn, 422)["error"]["code"] == "kb_project_no_work"
    end

    test "orchestrator-state save on a :kb scope 422s (human-anchored caller)", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :human_anchored})
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      {:ok, kb} = Projects.create_project(tenant.id, %{name: "kb", slug: "kb"}, kind: :kb)

      conn =
        conn
        |> auth_conn(orch_key)
        |> put(~p"/api/v1/orchestrator/state/#{kb.id}", %{"state" => %{}})

      assert json_response(conn, 422)["error"]["code"] == "kb_project_no_work"
    end

    test "a work project (kind: :work) is NOT rejected by the guard", %{conn: conn} do
      tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      work = fixture(:project, %{tenant_id: tenant.id, slug: "work"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{work.id}/ui-tests", %{"name" => "run"})

      # It passes RequireWorkProject and reaches the action; whatever the action returns,
      # it must NOT be the kb_project_no_work rejection.
      refute conn.status == 422 and
               Jason.decode!(conn.resp_body)["error"]["code"] == "kb_project_no_work"
    end
  end

  describe "GET /api/v1/projects" do
    test "lists projects for tenant", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:project, %{tenant_id: tenant.id, name: "project-a", slug: "project-a"})
      fixture(:project, %{tenant_id: tenant.id, name: "project-b", slug: "project-b"})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 2
      assert body["meta"]["page"] == 1
    end

    test "excludes archived projects by default", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:project, %{tenant_id: tenant.id, slug: "active-one"})
      archived = fixture(:project, %{tenant_id: tenant.id, slug: "archived-one"})
      Projects.archive_project(tenant.id, archived)

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      slugs = Enum.map(body["data"], & &1["slug"])
      assert "active-one" in slugs
      refute "archived-one" in slugs
    end

    test "includes archived projects when include_archived=true", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:project, %{tenant_id: tenant.id, slug: "active-one"})
      archived = fixture(:project, %{tenant_id: tenant.id, slug: "archived-one"})
      Projects.archive_project(tenant.id, archived)

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects?include_archived=true")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
    end

    test "paginates results", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      for i <- 1..5 do
        fixture(:project, %{
          tenant_id: tenant.id,
          name: "project-#{String.pad_leading(to_string(i), 2, "0")}",
          slug: "project-#{String.pad_leading(to_string(i), 2, "0")}"
        })
      end

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects?page=1&page_size=2")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 5
      assert body["meta"]["page"] == 1
      assert body["meta"]["page_size"] == 2
      assert body["meta"]["total_pages"] == 3
    end

    test "filters by status query parameter", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:project, %{tenant_id: tenant.id, slug: "active-one"})
      archived = fixture(:project, %{tenant_id: tenant.id, slug: "archived-one"})
      Projects.archive_project(tenant.id, archived)

      # Filter for archived only
      conn_archived =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects?status=archived")

      body = json_response(conn_archived, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["slug"] == "archived-one"

      # Filter for active only
      conn_active =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects?status=active")

      body_active = json_response(conn_active, 200)
      assert length(body_active["data"]) == 1
      assert hd(body_active["data"])["slug"] == "active-one"
    end

    test "returns pagination metadata", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      fixture(:project, %{tenant_id: tenant.id})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects")

      body = json_response(conn, 200)
      assert Map.has_key?(body, "meta")
      meta = body["meta"]
      assert Map.has_key?(meta, "page")
      assert Map.has_key?(meta, "page_size")
      assert Map.has_key?(meta, "total_count")
      assert Map.has_key?(meta, "total_pages")
    end
  end

  describe "GET /api/v1/projects/:id" do
    test "returns project detail with counts", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id, name: "my-project"})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{project.id}")

      body = json_response(conn, 200)
      assert body["project"]["id"] == project.id
      assert body["project"]["name"] == "my-project"
      # Zeroed counts until Epic 6
      assert body["project"]["epic_count"] == 0
      assert body["project"]["story_count"] == 0
    end

    test "returns 404 for nonexistent project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{uuid()}")

      assert json_response(conn, 404)
    end

    test "returns 404 for project in different tenant", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{project_b.id}")

      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/projects/:id" do
    test "updates project fields", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/projects/#{project.id}", %{
          "name" => "Updated Name",
          "description" => "New description"
        })

      body = json_response(conn, 200)
      assert body["project"]["name"] == "Updated Name"
      assert body["project"]["description"] == "New description"
    end

    test "updates project mission via PATCH", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id, mission: "old goal"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/projects/#{project.id}", %{"mission" => "new goal"})

      assert json_response(conn, 200)["project"]["mission"] == "new goal"
    end

    test "clears mission when sent as empty string", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id, mission: "old goal"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/projects/#{project.id}", %{"mission" => ""})

      assert json_response(conn, 200)["project"]["mission"] == nil
    end

    test "does not change slug (slug not in update cast)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id, slug: "original-slug"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/projects/#{project.id}", %{
          "slug" => "new-slug",
          "name" => "Updated"
        })

      body = json_response(conn, 200)
      # Slug should remain unchanged since it's not in update_changeset cast
      assert body["project"]["slug"] == "original-slug"
    end

    test "creates audit log entry on update", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn
      |> auth_conn(raw_key)
      |> patch(~p"/api/v1/projects/#{project.id}", %{"name" => "Renamed"})

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "project", action: "updated")

      assert length(result.data) == 1
    end

    test "requires user role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/projects/#{project.id}", %{"name" => "nope"})

      assert json_response(conn, 403)
    end

    test "returns 404 for nonexistent project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/projects/#{uuid()}", %{"name" => "nope"})

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/v1/projects/:id" do
    test "archives the project (soft delete)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/projects/#{project.id}")

      body = json_response(conn, 200)
      assert body["project"]["status"] == "archived"
      assert body["project"]["id"] == project.id
    end

    test "archived project excluded from default listing", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      # Archive
      conn
      |> auth_conn(raw_key)
      |> delete(~p"/api/v1/projects/#{project.id}")

      # List should not include archived
      list_conn =
        build_conn()
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/projects")

      body = json_response(list_conn, 200)
      assert body["data"] == []
    end

    test "creates audit log entry on archive", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn
      |> auth_conn(raw_key)
      |> delete(~p"/api/v1/projects/#{project.id}")

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "project", action: "archived")

      assert length(result.data) == 1
    end

    test "requires user role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/projects/#{project.id}")

      assert json_response(conn, 403)
    end

    test "returns 404 for nonexistent project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/projects/#{uuid()}")

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/projects/:id/progress" do
    test "returns zeroed progress for project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/#{project.id}/progress")

      body = json_response(conn, 200)
      progress = body["progress"]

      assert progress["total_stories"] == 0
      assert progress["total_epics"] == 0
      assert progress["epics_completed"] == 0
      assert progress["verification_percentage"] == 0.0
      assert progress["estimated_hours_total"] == 0
      assert progress["estimated_hours_completed"] == 0

      assert progress["stories_by_agent_status"]["pending"] == 0
      assert progress["stories_by_agent_status"]["implementing"] == 0
      assert progress["stories_by_agent_status"]["reported_done"] == 0

      assert progress["stories_by_verified_status"]["unverified"] == 0
      assert progress["stories_by_verified_status"]["verified"] == 0
      assert progress["stories_by_verified_status"]["rejected"] == 0
    end

    test "returns 404 for nonexistent project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{uuid()}/progress")

      assert json_response(conn, 404)
    end

    test "returns 404 for project in different tenant", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project_b.id}/progress")

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/projects/resolve" do
    test "resolves by slug and returns the project", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id, slug: "loopctl", name: "loopctl"})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/resolve?slug=loopctl")

      body = json_response(conn, 200)
      assert body["project"]["id"] == project.id
      assert body["project"]["slug"] == "loopctl"
      assert body["matched_by"] == "slug"
    end

    test "resolves by repo_url in ssh form", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      project =
        fixture(:project, %{
          tenant_id: tenant.id,
          slug: "loopctl",
          repo_url: "https://github.com/mkreyman/loopctl"
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/resolve?repo_url=git@github.com:mkreyman/loopctl.git")

      body = json_response(conn, 200)
      assert body["project"]["id"] == project.id
    end

    test "resolves by name case-insensitively", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id, name: "LoopCtl", slug: "loopctl"})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/resolve?name=loopctl")

      body = json_response(conn, 200)
      assert body["project"]["id"] == project.id
    end

    test "returns 404 with not_found error when no match", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/resolve?slug=missing")

      body = json_response(conn, 404)
      assert body["error"]["status"] == 404
      assert is_binary(body["error"]["message"])
    end

    test "returns 422 with no_identifier error when no identifier supplied", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/resolve")

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
      assert is_binary(body["error"]["message"])
    end

    test "respects tenant isolation (never resolves another tenant's project)", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      _project_b =
        fixture(:project, %{
          tenant_id: tenant_b.id,
          slug: "cross-tenant",
          repo_url: "https://github.com/mkreyman/loopctl"
        })

      conn = conn |> auth_conn(key_a) |> get(~p"/api/v1/projects/resolve?slug=cross-tenant")
      assert json_response(conn, 404)["error"]["status"] == 404

      conn2 =
        build_conn()
        |> auth_conn(key_a)
        |> get(~p"/api/v1/projects/resolve?repo_url=mkreyman/loopctl")

      assert json_response(conn2, 404)["error"]["status"] == 404
    end

    test "returns 409 ambiguous_resolution when a bare repo_url matches two hosts", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:project, %{
        tenant_id: tenant.id,
        slug: "gh-mirror",
        repo_url: "https://github.com/acme/app"
      })

      fixture(:project, %{
        tenant_id: tenant.id,
        slug: "gl-mirror",
        repo_url: "https://gitlab.com/acme/app"
      })

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/resolve?repo_url=acme/app")

      body = json_response(conn, 409)
      assert body["error"]["status"] == 409
      assert body["error"]["code"] == "ambiguous_resolution"
    end

    test "returns 422 when an identifier exceeds the length cap", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      long_name = String.duplicate("a", 513)

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/projects/resolve?name=#{long_name}")

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
      assert is_binary(body["error"]["message"])
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/projects/resolve?slug=loopctl")
      assert json_response(conn, 401)
    end
  end

  describe "cross-tenant isolation" do
    test "cannot list another tenant's projects", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})
      fixture(:project, %{tenant_id: tenant_a.id, name: "project-a", slug: "project-a"})
      fixture(:project, %{tenant_id: tenant_b.id, name: "project-b", slug: "project-b"})

      conn = conn |> auth_conn(key_a) |> get(~p"/api/v1/projects")

      body = json_response(conn, 200)
      names = Enum.map(body["data"], & &1["name"])
      assert "project-a" in names
      refute "project-b" in names
    end

    test "allow same slug in different tenants", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      {key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :user})

      conn_a =
        conn
        |> auth_conn(key_a)
        |> post(~p"/api/v1/projects", %{"name" => "Shared", "slug" => "shared-slug"})

      assert json_response(conn_a, 201)

      conn_b =
        build_conn()
        |> auth_conn(key_b)
        |> post(~p"/api/v1/projects", %{"name" => "Shared", "slug" => "shared-slug"})

      assert json_response(conn_b, 201)
    end
  end
end
