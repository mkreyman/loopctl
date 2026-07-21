defmodule LoopctlWeb.ContextRetrieverControllerTest do
  @moduledoc """
  US-30.4 — HTTP JSON API for the Context Retriever (`/api/v1/entities*`,
  `/api/v1/retrieve/*`).

  ## Why `async: false` + a COMMITTED tenant

  The executor and registry read/write through `Loopctl.Repo.with_tenant/2` (RLS
  transactions with `SET LOCAL ROLE loopctl_app`) on the `Loopctl.Repo`
  connection, while the AUTH pipeline resolves the API key through
  `Loopctl.AdminRepo` — two distinct sandbox connections that cannot see each
  other's UNCOMMITTED rows. A single tenant row must therefore be visible to
  BOTH: we insert it via `Sandbox.unboxed_run/2` (a real, committed connection)
  and delete it on exit. The api_key/agent (AdminRepo) and the entity
  definitions + backing rows (Repo) then reference that committed tenant from
  their own rolled-back sandbox transactions.

  Because the executor's isolation runs under the NON-owner `loopctl_app` role
  (RLS is ENABLE, not FORCE), the cross-tenant assertions actually prove
  isolation rather than silently passing — mirroring `executor_test.exs` /
  `registry_test.exs`.
  """
  use LoopctlWeb.ConnCase, async: false

  setup :verify_on_exit!

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.ContextRetriever.Registry
  alias Loopctl.Projects.Project
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant

  # Slug marker so the committed test tenants can be swept without touching real
  # data. See `commit_tenant/0` + the module teardown below.
  @tenant_marker "ctrtest-"

  # Sweep every committed marker tenant at module setup AND teardown. This runs
  # OUTSIDE any per-test sandbox transaction, so no open transaction holds an FK
  # lock on the tenant rows (a per-test on_exit delete deadlocks: it fires BEFORE
  # the sandbox transaction that inserted the FK-referencing api_keys/entities is
  # rolled back). Cleaning at module boundaries sidesteps that entirely.
  setup_all do
    sweep_marker_tenants()
    on_exit(&sweep_marker_tenants/0)
    :ok
  end

  defp sweep_marker_tenants do
    Sandbox.unboxed_run(AdminRepo, fn ->
      AdminRepo.delete_all(from(t in Tenant, where: like(t.slug, ^"#{@tenant_marker}%")))
    end)
  end

  # --- Committed-tenant + seeding helpers (see moduledoc) ---

  # Insert a tenant on a real (committed) connection so BOTH the AdminRepo auth
  # path and the Repo executor path can see it. Cleanup is handled by the
  # module-level sweep (see above), not a per-test on_exit.
  defp commit_tenant do
    seq = System.unique_integer([:positive])
    id = Ecto.UUID.generate()

    Sandbox.unboxed_run(AdminRepo, fn ->
      %Tenant{}
      |> Tenant.create_changeset(%{
        name: "T#{seq}",
        slug: "#{@tenant_marker}#{seq}",
        email: "#{@tenant_marker}#{seq}@example.com"
      })
      |> Ecto.Changeset.put_change(:id, id)
      # Defining/mutating entity definitions is gated behind RequireHumanAnchor
      # (a security root), so the test tenant must be human-anchored. trust_tier is
      # excluded from create_changeset's cast, so set it programmatically (mirrors
      # the tenant fixture's post-insert convention).
      |> Ecto.Changeset.put_change(:trust_tier, :human_anchored)
      |> AdminRepo.insert!()
    end)

    AdminRepo.get!(Tenant, id)
  end

  # A user-role key (may define/mutate entity definitions).
  defp user_key(tenant_id) do
    {raw, _key} = fixture(:api_key, %{tenant_id: tenant_id, role: :user})
    raw
  end

  # An agent-role key (query only). api_keys.agent_id FKs agents, so mint a real
  # agent per agent key.
  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, _key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    raw
  end

  # An orchestrator-role key (role 2 < user 3). Deliberately elevated to write
  # work-breakdown data, but NOT to define entity definitions (a security root) —
  # so define/mutate must 403 it, exactly like an agent key (AC-30.4.2).
  defp orchestrator_key(tenant_id) do
    {raw, _key} = fixture(:api_key, %{tenant_id: tenant_id, role: :orchestrator})
    raw
  end

  # Seed a backing project on the Repo connection (the executor reads via
  # Repo.with_tenant). Status defaults to :active.
  defp seed_project(tenant_id, attrs \\ %{}) do
    %Project{tenant_id: tenant_id}
    |> Project.create_changeset(build(:project, attrs))
    |> Repo.insert!()
  end

  # A "project" entity exposing a filterable `status` field.
  defp project_status_fields do
    [%{name: "status", type: "string", filterable: true, searchable: false}]
  end

  # `status` filterable + `slug` declared but NOT filterable. Exercises the
  # execute-time allowlist re-check: a raw `/retrieve` naming `slug` op:"filter"
  # must be rejected (422 field_not_allowlisted), never executed.
  defp project_status_and_unfilterable_slug_fields do
    [
      %{name: "status", type: "string", filterable: true, searchable: false},
      %{name: "slug", type: "string", filterable: false, searchable: false}
    ]
  end

  # A "project" entity exposing a vector-covered searchable text field (`name` is
  # in the projects search_vector) — authorizes the op:"search" path.
  defp project_searchable_name_fields do
    [%{name: "name", type: "string", filterable: false, searchable: true}]
  end

  # A "project" entity declaring `slug` searchable — allowlisted, but NOT covered
  # by the projects search_vector (name/description/mission). A raw op:"search"
  # must be rejected (422 search_not_indexed), never silently searched.
  defp project_unindexed_searchable_slug_fields do
    [%{name: "slug", type: "string", filterable: false, searchable: true}]
  end

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  # A fresh conn carrying the witness STH header (each dispatched request needs
  # its own conn).
  defp base_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")

  defp create_project_entity(conn, raw_user_key, fields) do
    conn
    |> auth(raw_user_key)
    |> post(~p"/api/v1/entities", %{
      "name" => "project",
      "backing_source" => "projects",
      "fields" => fields
    })
  end

  # --- TC-30.4.1: create + tools + retrieve happy path ---

  describe "TC-30.4.1: CRUD create, tools, retrieve" do
    test "user creates an entity, agent lists tools and retrieves rows", %{conn: conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      seed_project(tenant.id)
      seed_project(tenant.id)

      created = create_project_entity(conn, user, project_status_fields())
      assert %{"data" => data} = json_response(created, 201)
      assert data["name"] == "project"
      assert data["backing_source"] == "projects"

      tools = base_conn() |> auth(agent) |> get(~p"/api/v1/retrieve/tools")
      %{"data" => specs} = json_response(tools, 200)
      tool_names = Enum.map(specs, & &1["name"])
      assert "cr_filter_project_by_status" in tool_names

      retrieved =
        base_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/project", %{
          "field" => "status",
          "op" => "filter",
          "value" => "active"
        })

      body = json_response(retrieved, 200)
      assert %{"results" => results, "meta" => meta} = body
      assert length(results) == 2
      assert meta["total_count"] == 2
      # Results are shaped to declared columns only.
      assert Enum.all?(results, &Map.has_key?(&1, "status"))
      refute Enum.any?(results, &Map.has_key?(&1, "tenant_id"))
    end
  end

  # --- TC-30.4.1b: GET index + show over HTTP ---

  describe "TC-30.4.1: GET /entities (index) and GET /entities/:id (show)" do
    test "index lists the tenant's definitions ordered by name", %{conn: _conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      # Two definitions with names that sort z-before-a to prove ordering.
      base_conn()
      |> auth(user)
      |> post(~p"/api/v1/entities", %{
        "name" => "zeta",
        "backing_source" => "projects",
        "fields" => project_status_fields()
      })
      |> json_response(201)

      base_conn()
      |> auth(user)
      |> post(~p"/api/v1/entities", %{
        "name" => "alpha",
        "backing_source" => "projects",
        "fields" => project_status_fields()
      })
      |> json_response(201)

      # Query-role (agent) may list — index requires only authentication.
      resp = base_conn() |> auth(agent) |> get(~p"/api/v1/entities")
      %{"data" => data} = json_response(resp, 200)

      names = Enum.map(data, & &1["name"])
      assert names == ["alpha", "zeta"]
      assert Enum.all?(data, &(&1["backing_source"] == "projects"))
    end

    test "show returns one definition by id (query role allowed)", %{conn: conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      created = create_project_entity(conn, user, project_status_fields())
      %{"data" => %{"id" => id}} = json_response(created, 201)

      resp = base_conn() |> auth(agent) |> get(~p"/api/v1/entities/#{id}")
      assert %{"data" => data} = json_response(resp, 200)
      assert data["id"] == id
      assert data["name"] == "project"
    end

    test "show is 404 for an unknown id", %{conn: _conn} do
      tenant = commit_tenant()
      agent = agent_key(tenant.id)

      resp = base_conn() |> auth(agent) |> get(~p"/api/v1/entities/#{Ecto.UUID.generate()}")
      assert json_response(resp, 404)
    end

    test "show is 404 for another tenant's id (no cross-tenant read over HTTP)", %{conn: conn} do
      tenant_t = commit_tenant()
      tenant_u = commit_tenant()
      user_t = user_key(tenant_t.id)
      agent_u = agent_key(tenant_u.id)

      created = create_project_entity(conn, user_t, project_status_fields())
      %{"data" => %{"id" => id}} = json_response(created, 201)

      resp = base_conn() |> auth(agent_u) |> get(~p"/api/v1/entities/#{id}")
      assert json_response(resp, 404)
    end
  end

  # --- TC-30.4.2: role gating ---

  describe "TC-30.4.2: role gating" do
    test "agent key cannot create an entity (403, below user)", %{conn: conn} do
      tenant = commit_tenant()
      agent = agent_key(tenant.id)

      resp = create_project_entity(conn, agent, project_status_fields())
      assert json_response(resp, 403)
    end

    test "orchestrator key cannot create an entity (403, role 2 < user 3)", %{conn: conn} do
      # AC-30.4.2: define/mutate is 403 for orchestrator too. An orchestrator is
      # deliberately elevated to write work-breakdown data (CLAUDE.md), but an
      # entity definition is the executor's field allowlist (a security root), so
      # RequireRole role: :user must still block it — the more meaningful negative
      # case than the below-floor agent.
      tenant = commit_tenant()
      orchestrator = orchestrator_key(tenant.id)

      resp = create_project_entity(conn, orchestrator, project_status_fields())
      assert json_response(resp, 403)
    end

    test "orchestrator key cannot PATCH or DELETE an entity (403)", %{conn: conn} do
      # The same role gate covers the other define/mutate verbs. Create as a user,
      # then prove an orchestrator key is refused on both PATCH and DELETE.
      tenant = commit_tenant()
      user = user_key(tenant.id)
      orchestrator = orchestrator_key(tenant.id)

      created = create_project_entity(conn, user, project_status_fields())
      %{"data" => %{"id" => id}} = json_response(created, 201)

      patched =
        base_conn()
        |> auth(orchestrator)
        |> patch(~p"/api/v1/entities/#{id}", %{"fields" => project_status_fields()})

      assert json_response(patched, 403)

      deleted = base_conn() |> auth(orchestrator) |> delete(~p"/api/v1/entities/#{id}")
      assert json_response(deleted, 403)
    end

    test "retrieve with no key is 401 (never a below-agent 403)", %{conn: conn} do
      resp = post(conn, ~p"/api/v1/retrieve/project", %{"field" => "status", "op" => "filter"})
      assert json_response(resp, 401)
    end

    test "retrieve with an invalid key is 401", %{conn: _conn} do
      resp =
        base_conn()
        |> auth("loopctl_bogus_invalid_key")
        |> post(~p"/api/v1/retrieve/project", %{"field" => "status", "op" => "filter"})

      assert json_response(resp, 401)
    end
  end

  # --- TC-30.4.4: update + delete reflected in tools ---

  describe "TC-30.4.4: PATCH + DELETE reflected in generated tools" do
    test "patch adds a filterable field; delete removes the entity's tools", %{conn: conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)

      created = create_project_entity(conn, user, project_status_fields())
      %{"data" => %{"id" => id}} = json_response(created, 201)

      # PATCH: mark `name` filterable in addition to `status`.
      patched =
        base_conn()
        |> auth(user)
        |> patch(~p"/api/v1/entities/#{id}", %{
          "fields" => [
            %{
              "name" => "status",
              "type" => "string",
              "filterable" => true,
              "searchable" => false
            },
            %{"name" => "name", "type" => "string", "filterable" => true, "searchable" => false}
          ]
        })

      assert json_response(patched, 200)

      tools = base_conn() |> auth(user) |> get(~p"/api/v1/retrieve/tools")
      names = json_response(tools, 200)["data"] |> Enum.map(& &1["name"])
      assert "cr_filter_project_by_status" in names
      assert "cr_filter_project_by_name" in names

      deleted = base_conn() |> auth(user) |> delete(~p"/api/v1/entities/#{id}")
      assert json_response(deleted, 200)

      tools_after = base_conn() |> auth(user) |> get(~p"/api/v1/retrieve/tools")
      names_after = json_response(tools_after, 200)["data"] |> Enum.map(& &1["name"])
      refute "cr_filter_project_by_status" in names_after
      refute "cr_filter_project_by_name" in names_after
    end
  end

  # --- TC-30.4.5: rate limit ---

  describe "TC-30.4.5: retrieve is rate-limited per tenant" do
    test "over-limit returns 429 and does not execute", %{conn: conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      create_project_entity(conn, user, project_status_fields())
      seed_project(tenant.id)

      # sec-4: let the fail-CLOSED auth-path gate (`auth_ip:*`) pass so this test
      # exercises the CR controller's OWN per-tenant limiter over-limit path.
      # Without scoping, the deny-all stub trips the AuthPathThrottle plug (first
      # in the :authenticated pipeline) and 429s BEFORE the CR controller runs —
      # the assertion would then pass for the wrong reason (CR limiter untested).
      Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn
        "auth_ip:" <> _, _window, _limit -> {:allow, 1}
        _bucket, _window, _limit -> {:deny, 999}
      end)

      resp =
        base_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/project", %{
          "field" => "status",
          "op" => "filter",
          "value" => "active"
        })

      assert json_response(resp, 429)
    end

    test "a limiter-store FAULT fails CLOSED (429), not open (#461 item 7)", %{conn: conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      create_project_entity(conn, user, project_status_fields())
      seed_project(tenant.id)

      # Let the auth-path gate pass, but make the CR per-tenant retrieve bucket's
      # limiter FAULT ({:error, _}). The old fail-OPEN gate (within_limit?/3) would
      # have ALLOWED this (200); the new fail-CLOSED gate (gate_ok?/3) must DENY it
      # so a store fault can't unleash an unbounded per-request DB-query storm.
      Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn
        "auth_ip:" <> _, _window, _limit -> {:allow, 1}
        "cr_retrieve:" <> _, _window, _limit -> {:error, :limiter_store_down}
        _bucket, _window, _limit -> {:allow, 1}
      end)

      resp =
        base_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/project", %{
          "field" => "status",
          "op" => "filter",
          "value" => "active"
        })

      assert json_response(resp, 429)
    end
  end

  # --- TC-30.4.6: execute-time allowlist re-check (the raw-/retrieve bypass close) ---

  describe "TC-30.4.6: execute-time field-allowlist rejection" do
    test "op:filter naming a declared-but-non-filterable field is 422, not executed",
         %{conn: conn} do
      # `slug` is declared on the entity but `filterable: false`. The generate-time
      # tool surface never exposes a filter tool for it, but a raw POST can still
      # name it — the executor's execute-time re-check must REJECT it (422
      # field_not_allowlisted), never run the query. This is the most
      # security-relevant branch of the story (the raw-/retrieve bypass close).
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      create_project_entity(conn, user, project_status_and_unfilterable_slug_fields())
      seed_project(tenant.id)

      resp =
        base_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/project", %{
          "field" => "slug",
          "op" => "filter",
          "value" => "anything"
        })

      assert %{"error" => %{"code" => "field_not_allowlisted"}} = json_response(resp, 422)
    end

    test "op:filter naming a field the entity never declares is 422", %{conn: conn} do
      # `mission` is a server-allowlisted projects column, but this entity does not
      # declare it — the executor rejects it the same way (never executed).
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      create_project_entity(conn, user, project_status_fields())
      seed_project(tenant.id)

      resp =
        base_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/project", %{
          "field" => "mission",
          "op" => "filter",
          "value" => "anything"
        })

      assert %{"error" => %{"code" => "field_not_allowlisted"}} = json_response(resp, 422)
    end
  end

  # --- TC-30.4.7: op:"search" over HTTP ---

  describe "TC-30.4.7: retrieve op:search" do
    test "search over a vector-covered text field returns 200 with results + meta",
         %{conn: conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      create_project_entity(conn, user, project_searchable_name_fields())
      seed_project(tenant.id, %{name: "Photosynthesis research initiative"})
      seed_project(tenant.id, %{name: "Unrelated ledger tooling"})

      resp =
        base_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/project", %{
          "op" => "search",
          "query" => "photosynthesis"
        })

      assert %{"results" => results, "meta" => meta} = json_response(resp, 200)
      assert results == [%{"name" => "Photosynthesis research initiative"}]
      assert meta["total_count"] == 1
      # Shaped to declared columns only.
      refute Enum.any?(results, &Map.has_key?(&1, "tenant_id"))
    end

    test "search over a declared-but-unindexed searchable field is 422 search_not_indexed",
         %{conn: conn} do
      # `slug` is allowlisted + declared searchable, but NOT covered by the
      # projects search_vector (name/description/mission). The generate-time tool
      # surface suppresses the search tool, but a raw POST op:"search" must be
      # rejected (422 search_not_indexed), never silently searched against the
      # vector's different columns.
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      create_project_entity(conn, user, project_unindexed_searchable_slug_fields())
      seed_project(tenant.id)

      resp =
        base_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/project", %{
          "op" => "search",
          "query" => "anything"
        })

      assert %{"error" => %{"code" => "search_not_indexed"}} = json_response(resp, 422)
    end

    test "an unknown op is 422 invalid_operation", %{conn: conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      create_project_entity(conn, user, project_status_fields())

      resp =
        base_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/project", %{"op" => "sort", "field" => "status"})

      assert %{"error" => %{"code" => "invalid_operation"}} = json_response(resp, 422)
    end
  end

  # --- TC-30.4.3: tenant isolation (mandatory) ---

  describe "TC-30.4.3: tenant isolation" do
    test "another tenant's key sees none of tenant_t's tools or rows", %{conn: conn} do
      tenant_t = commit_tenant()
      tenant_u = commit_tenant()

      user_t = user_key(tenant_t.id)
      agent_u = agent_key(tenant_u.id)

      # tenant_t has an entity + backing rows.
      create_project_entity(conn, user_t, project_status_fields())
      seed_project(tenant_t.id)

      # tenant_u's agent sees NONE of tenant_t's tools.
      tools_u = base_conn() |> auth(agent_u) |> get(~p"/api/v1/retrieve/tools")
      assert %{"data" => []} = json_response(tools_u, 200)

      # POST /retrieve/project (tenant_t's entity name) as tenant_u's key ⇒
      # unknown entity (404), never tenant_t's rows.
      resp =
        base_conn()
        |> auth(agent_u)
        |> post(~p"/api/v1/retrieve/project", %{
          "field" => "status",
          "op" => "filter",
          "value" => "active"
        })

      assert json_response(resp, 404)
    end

    test "the registry cannot read another tenant's entity by id", %{conn: conn} do
      tenant_t = commit_tenant()
      tenant_u = commit_tenant()
      user_t = user_key(tenant_t.id)

      created = create_project_entity(conn, user_t, project_status_fields())
      %{"data" => %{"id" => id}} = json_response(created, 201)

      # Cross-tenant id fetch returns nil (no existence leak).
      assert Registry.get_entity_by_id(tenant_u.id, id) == nil
    end
  end
end
