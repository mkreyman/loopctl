defmodule Loopctl.E2E.ContextRetrieverSecurityTest do
  @moduledoc """
  US-30.7 (TC-30.7.2) — TERMINAL, epic-wide security suite for the Epic 30 Context
  Retriever. Proves the six AC-30.7.4 properties end-to-end across API + MCP +
  context, run under the NON-owner `loopctl_app` app role (RLS is ENABLE, not
  FORCE, so isolation assertions genuinely prove isolation):

    (a) injection payloads in BOTH a filter value AND a search query match
        literally (no SQL execution) — with a positive control proving the value
        is genuinely matchable;
    (b) a non-allowlisted field is rejected on EVERY surface (define-time AND
        execute-time);
    (c) cross-tenant define/list/query isolation via context, API, and the
        MCP-equivalent tool-listing/dispatch surface — with a positive control;
    (d) no undeclared column leaks (only declared fields returned);
    (e) an `audit_log` record exists per `/retrieve` execution;
    (f) `/retrieve` is rate-limited (429, unexecuted).

  Excluded from the default suite (`@moduletag :e2e`); run with `mix test.e2e`.

  ## Why `async: false` + a COMMITTED tenant

  Same as `context_retriever_journey_test.exs` / `context_retriever_controller_test.exs`:
  the executor reads backing rows via `Loopctl.Repo.with_tenant/2` (RLS + `SET
  LOCAL ROLE loopctl_app`) on the Repo connection while auth resolves via
  AdminRepo — two sandbox connections. The tenant must be committed (visible to
  both) so it is inserted via `Sandbox.unboxed_run/2` and swept by a slug marker at
  module boundaries.
  """
  use LoopctlWeb.ConnCase, async: false

  @moduletag :e2e

  setup :verify_on_exit!

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.ContextRetriever.Registry
  alias Loopctl.Projects.Project
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

  @tenant_marker "crsec-"

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
      |> Ecto.Changeset.put_change(:trust_tier, :human_anchored)
      |> AdminRepo.insert!()
    end)

    AdminRepo.get!(Tenant, id)
  end

  defp user_key(tenant_id) do
    {raw, _key} = fixture(:api_key, %{tenant_id: tenant_id, role: :user})
    raw
  end

  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, _key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    raw
  end

  defp seed_project(tenant_id, attrs \\ %{}) do
    %Project{tenant_id: tenant_id}
    |> Project.create_changeset(build(:project, attrs))
    |> Repo.insert!()
  end

  defp seed_epic(tenant_id, project_id) do
    %Epic{tenant_id: tenant_id, project_id: project_id}
    |> Epic.create_changeset(build(:epic, %{}))
    |> Repo.insert!()
  end

  defp seed_story(tenant_id, attrs) do
    project = seed_project(tenant_id)
    epic = seed_epic(tenant_id, project.id)

    %Story{tenant_id: tenant_id, project_id: project.id, epic_id: epic.id}
    |> Story.create_changeset(build(:story, attrs))
    |> Repo.insert!()
  end

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp fresh_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")

  # A `story` entity: title (filterable + searchable), number (filterable).
  defp define_story_entity(user_key) do
    resp =
      fresh_conn()
      |> auth(user_key)
      |> post(~p"/api/v1/entities", %{
        "name" => "story",
        "backing_source" => "stories",
        "fields" => [
          %{"name" => "title", "type" => "string", "filterable" => true, "searchable" => true},
          %{"name" => "number", "type" => "string", "filterable" => true, "searchable" => false}
        ]
      })

    json_response(resp, 201)
  end

  defp context_audits(tenant_id) do
    AdminRepo.all(
      from a in AuditLog,
        where: a.tenant_id == ^tenant_id and a.entity_type == "context_retrieval"
    )
  end

  # --- (a) injection in filter + search matches literally ---

  describe "AC-30.7.4a: injection payloads (filter + search) match literally, no SQL" do
    test "a filter injection value and a search injection query both match nothing; legit values match",
         %{conn: _conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      marker = "zqinj#{System.unique_integer([:positive])}"
      seed_story(tenant.id, %{title: "#{marker} legitimate story", number: "101"})
      define_story_entity(user)

      # POSITIVE CONTROL: the legit value genuinely matches — so a 0-row injection
      # result below means "injection was neutralized", not "filter matches nothing".
      legit =
        fresh_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/story", %{
          "op" => "filter",
          "field" => "title",
          "value" => "#{marker} legitimate story"
        })

      assert %{"results" => [_one], "meta" => %{"total_count" => 1}} = json_response(legit, 200)

      # Injection in a FILTER value → literal, matches nothing, no SQL error.
      filter_inj =
        fresh_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/story", %{
          "op" => "filter",
          "field" => "title",
          "value" => "' OR 1=1 --"
        })

      assert %{"results" => [], "meta" => %{"total_count" => 0}} = json_response(filter_inj, 200)

      # Injection in a SEARCH query → literal tsquery term, matches nothing, and
      # the table is NOT dropped.
      search_inj =
        fresh_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/story", %{
          "op" => "search",
          "query" => "'; DROP TABLE stories; --"
        })

      assert %{"results" => [], "meta" => %{"total_count" => 0}} = json_response(search_inj, 200)

      # The stories table still exists and is queryable — the payload was a literal.
      assert Repo.aggregate(from(s in Story), :count, :id) >= 0
    end
  end

  # --- (b) non-allowlisted field rejected on every surface ---

  describe "AC-30.7.4b: non-allowlisted field rejected on every surface" do
    test "define-time: declaring a non-allowlisted column is 422", %{conn: _conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)

      # `tenant_id` is a real column but DELIBERATELY excluded from the server
      # allowlist — declaring it must be rejected at create time (422), never
      # persisted into a security-root entity definition.
      resp =
        fresh_conn()
        |> auth(user)
        |> post(~p"/api/v1/entities", %{
          "name" => "leaky",
          "backing_source" => "stories",
          "fields" => [
            %{
              "name" => "tenant_id",
              "type" => "string",
              "filterable" => true,
              "searchable" => false
            }
          ]
        })

      assert json_response(resp, 422)
    end

    test "execute-time: a declared-but-non-filterable field, and an undeclared field, are 422",
         %{conn: _conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      seed_story(tenant.id, %{title: "Anything", number: "101"})

      # description declared searchable-only (filterable: false).
      fresh_conn()
      |> auth(user)
      |> post(~p"/api/v1/entities", %{
        "name" => "story",
        "backing_source" => "stories",
        "fields" => [
          %{"name" => "title", "type" => "string", "filterable" => true, "searchable" => true},
          %{
            "name" => "description",
            "type" => "string",
            "filterable" => false,
            "searchable" => true
          }
        ]
      })
      |> json_response(201)

      # A raw op:filter naming `description` (declared, not filterable) → 422,
      # never executed (the execute-time allowlist re-check closes the raw-/retrieve
      # bypass).
      non_filterable =
        fresh_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/story", %{
          "op" => "filter",
          "field" => "description",
          "value" => "x"
        })

      assert %{"error" => %{"code" => "field_not_allowlisted"}} =
               json_response(non_filterable, 422)

      # A field the entity never declares (`agent_status`, a real allowlisted
      # column) is rejected the same way.
      undeclared =
        fresh_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/story", %{
          "op" => "filter",
          "field" => "agent_status",
          "value" => "pending"
        })

      assert %{"error" => %{"code" => "field_not_allowlisted"}} = json_response(undeclared, 422)
    end
  end

  # --- (c) cross-tenant isolation via context, API, MCP ---

  describe "AC-30.7.4c: cross-tenant define/list/query isolation (context + API + MCP)" do
    test "tenant B sees none of tenant A's entity or rows on any surface; A sees its own",
         %{conn: _conn} do
      tenant_a = commit_tenant()
      tenant_b = commit_tenant()
      user_a = user_key(tenant_a.id)
      agent_a = agent_key(tenant_a.id)
      agent_b = agent_key(tenant_b.id)

      %{"data" => %{"id" => entity_id}} = define_story_entity(user_a)
      seed_story(tenant_a.id, %{title: "TenantA secret story", number: "101"})

      # POSITIVE CONTROL — tenant A's own key sees its entity + rows, so a green
      # isolation result below means "isolation works", not "everything is empty".
      tools_a = fresh_conn() |> auth(agent_a) |> get(~p"/api/v1/retrieve/tools")
      names_a = json_response(tools_a, 200)["data"] |> Enum.map(& &1["name"])
      assert "cr_filter_story_by_title" in names_a

      own =
        fresh_conn()
        |> auth(agent_a)
        |> post(~p"/api/v1/retrieve/story", %{
          "op" => "filter",
          "field" => "title",
          "value" => "TenantA secret story"
        })

      assert %{"meta" => %{"total_count" => 1}} = json_response(own, 200)

      # ISOLATION — CONTEXT path: tenant B cannot read A's entity by id, and A's
      # entity is absent from B's listing.
      assert Registry.get_entity_by_id(tenant_b.id, entity_id) == nil
      refute Enum.any?(Registry.for_tenant(tenant_b.id), &(&1.id == entity_id))

      # ISOLATION — API path: B's GET /entities does not include A's entity.
      b_entities = fresh_conn() |> auth(agent_b) |> get(~p"/api/v1/entities")
      b_ids = json_response(b_entities, 200)["data"] |> Enum.map(& &1["id"])
      refute entity_id in b_ids

      # ISOLATION — MCP-equivalent path: B's tool listing (what its MCP client
      # fetches) sees none of A's generated tools...
      tools_b = fresh_conn() |> auth(agent_b) |> get(~p"/api/v1/retrieve/tools")
      assert %{"data" => []} = json_response(tools_b, 200)

      # ...and dispatching A's entity name as B's key is an unknown entity (404),
      # never A's rows.
      cross =
        fresh_conn()
        |> auth(agent_b)
        |> post(~p"/api/v1/retrieve/story", %{
          "op" => "filter",
          "field" => "title",
          "value" => "TenantA secret story"
        })

      assert json_response(cross, 404)
    end
  end

  # --- (d) no undeclared column leaks ---

  describe "AC-30.7.4d: only declared columns are returned" do
    test "results carry only declared fields — never tenant_id/metadata/custody columns",
         %{conn: _conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      seed_story(tenant.id, %{title: "Shaped story", number: "101"})
      define_story_entity(user)

      resp =
        fresh_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/story", %{
          "op" => "filter",
          "field" => "title",
          "value" => "Shaped story"
        })

      %{"results" => [row]} = json_response(resp, 200)

      # Exactly the two declared columns, nothing more.
      assert Map.keys(row) |> Enum.sort() == ["number", "title"]
      refute Map.has_key?(row, "tenant_id")
      refute Map.has_key?(row, "metadata")
      refute Map.has_key?(row, "id")
    end
  end

  # --- (e) an audit record per execution ---

  describe "AC-30.7.4e: every /retrieve execution writes an audit record" do
    test "a successful filter execution appends a context_retrieval audit row",
         %{conn: _conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      seed_story(tenant.id, %{title: "Audited story", number: "101"})
      define_story_entity(user)

      assert context_audits(tenant.id) == []

      resp =
        fresh_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/story", %{
          "op" => "filter",
          "field" => "title",
          "value" => "Audited story"
        })

      assert json_response(resp, 200)

      assert [audit] = context_audits(tenant.id)
      assert audit.entity_type == "context_retrieval"
      assert audit.action == "filter"
      assert audit.metadata["entity"] == "story"
      assert audit.metadata["field"] == "title"
      assert audit.metadata["row_count"] == 1
      # Raw filter value is never stored (only a digest).
      refute audit.metadata["param_digest"] =~ "Audited story"
    end
  end

  # --- (f) rate limited ---

  describe "AC-30.7.4f: /retrieve is rate-limited" do
    test "over the per-tenant limit returns 429 and does not execute", %{conn: _conn} do
      tenant = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      seed_story(tenant.id, %{title: "RateLimited", number: "101"})
      define_story_entity(user)

      # Force the per-tenant bucket over-limit (config-based DI mock; no put_env).
      Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
        {:deny, 999}
      end)

      resp =
        fresh_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/story", %{
          "op" => "filter",
          "field" => "title",
          "value" => "RateLimited"
        })

      assert json_response(resp, 429)

      # Over-limit did NOT execute → no audit row was written.
      assert context_audits(tenant.id) == []
    end
  end
end
