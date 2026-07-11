defmodule Loopctl.E2E.ContextRetrieverJourneyTest do
  @moduledoc """
  US-30.7 (TC-30.7.1) — terminal end-to-end journey for the Epic 30 Context
  Retriever: the FULL path a live agent takes across API + MCP.

  Define an entity with a filterable AND a searchable field via the HTTP API
  (user key) → assert BOTH generated tools appear via `GET /api/v1/retrieve/tools`
  (agent key) → run a FILTER query and a SEARCH query via `POST /api/v1/retrieve/:entity`
  using BOTH a direct-API body AND the request body the MCP client derives from the
  returned tool spec (mirroring `mcp-server/lib/generated-tools.js` `buildRetrieveBody`)
  → assert the API and MCP-derived legs return the SAME tenant-scoped result set.

  Excluded from the default suite (`@moduletag :e2e`); run with `mix test.e2e`
  or `E2E_TESTS=1 mix test --only e2e`.

  ## Why `async: false` + a COMMITTED tenant (see `context_retriever_controller_test.exs`)

  The executor reads backing rows through `Loopctl.Repo.with_tenant/2` (RLS
  transactions with `SET LOCAL ROLE loopctl_app`) on the `Loopctl.Repo` connection,
  while the AUTH pipeline resolves the API key through `Loopctl.AdminRepo` — two
  distinct sandbox connections that cannot see each other's UNCOMMITTED rows. The
  tenant must be visible to BOTH (FK from api_keys[AdminRepo] AND stories[Repo]),
  so it is inserted via `Sandbox.unboxed_run/2` (a real, committed connection) and
  swept at module boundaries by a slug marker. The `async: true` used by the
  knowledge/memory journeys does not apply here — a committed row would leak across
  parallel tests. Because the executor's tenant scoping runs under the NON-owner
  `loopctl_app` role (RLS is ENABLE, not FORCE), the tenant-scoping assertion here
  actually proves isolation rather than silently passing.
  """
  use LoopctlWeb.ConnCase, async: false

  @moduletag :e2e

  setup :verify_on_exit!

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Projects.Project
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

  import Ecto.Query

  @tenant_marker "crjourney-"

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

  # A committed, human-anchored tenant visible to BOTH the AdminRepo auth path and
  # the Repo executor path (see moduledoc).
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

  # Backing rows are seeded on the Repo connection (the executor reads via
  # Repo.with_tenant). A story needs a project + epic; the committed tenant
  # satisfies the FK, the Repo inserts roll back at test exit.
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

  # A fresh conn carrying the witness STH header (each dispatched request needs its
  # own conn).
  defp fresh_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")

  # Mirror of the MCP client's `buildRetrieveBody(metadata, args)`
  # (`mcp-server/lib/http-helpers.js`): derive the `POST /retrieve/:entity` body
  # from the RETURNED tool spec's metadata + required arg, exactly as the JS
  # dispatch path does. This proves the spec → body → results wire the MCP leg
  # rides is the SAME one the direct API uses.
  defp mcp_body_from_spec(
         %{"metadata" => %{"operation" => "filter", "field" => field}} = spec,
         args
       ) do
    [required_key] = spec["input_schema"]["required"]
    %{"op" => "filter", "field" => field, "value" => Map.fetch!(args, required_key)}
  end

  defp mcp_body_from_spec(%{"metadata" => %{"operation" => "search"}}, args) do
    %{"op" => "search", "query" => Map.fetch!(args, "query")}
  end

  describe "TC-30.7.1: define → ListTools → filter + search (API + MCP) agree" do
    test "both generated tools list; API and MCP-derived filter+search return the same tenant-scoped set",
         %{conn: _conn} do
      tenant = commit_tenant()
      other = commit_tenant()
      user = user_key(tenant.id)
      agent = agent_key(tenant.id)

      # A distinctive searchable term so the search match is unambiguous.
      marker = "zqcontext#{System.unique_integer([:positive])}"

      # Two matching stories for the filter + one for search in the caller tenant.
      seed_story(tenant.id, %{title: "#{marker} alpha report", number: "101"})
      seed_story(tenant.id, %{title: "#{marker} alpha report", number: "102"})
      seed_story(tenant.id, %{title: "unrelated beta", number: "103"})

      # POSITIVE CONTROL is the whole point of tenant-scoping: seed an
      # IDENTICALLY-titled row in another tenant that must NEVER surface for
      # `tenant`. If it did, a green result would mean "scoping regressed", not
      # "scoping works".
      seed_story(other.id, %{title: "#{marker} alpha report", number: "201"})

      # 1) Define a `story` entity: title is BOTH filterable and searchable, so the
      #    generator emits a filter tool AND a search tool.
      created =
        fresh_conn()
        |> auth(user)
        |> post(~p"/api/v1/entities", %{
          "name" => "story",
          "backing_source" => "stories",
          "fields" => [
            %{"name" => "title", "type" => "string", "filterable" => true, "searchable" => true},
            %{"name" => "number", "type" => "string", "filterable" => true, "searchable" => false}
          ]
        })

      assert %{"data" => %{"name" => "story"}} = json_response(created, 201)

      # 2) BOTH generated tools appear via GET /retrieve/tools (agent key).
      tools_resp = fresh_conn() |> auth(agent) |> get(~p"/api/v1/retrieve/tools")
      %{"data" => specs} = json_response(tools_resp, 200)
      spec_names = Enum.map(specs, & &1["name"])

      assert "cr_filter_story_by_title" in spec_names
      assert "cr_search_story" in spec_names

      filter_spec = Enum.find(specs, &(&1["name"] == "cr_filter_story_by_title"))
      search_spec = Enum.find(specs, &(&1["name"] == "cr_search_story"))

      # 3a) FILTER via the DIRECT API body.
      api_filter =
        fresh_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/story", %{
          "op" => "filter",
          "field" => "title",
          "value" => "#{marker} alpha report"
        })

      %{"results" => api_filter_results, "meta" => api_filter_meta} =
        json_response(api_filter, 200)

      # 3b) FILTER via the MCP-DERIVED body (from the returned spec + the field-named arg).
      mcp_filter_body = mcp_body_from_spec(filter_spec, %{"title" => "#{marker} alpha report"})

      mcp_filter =
        fresh_conn() |> auth(agent) |> post(~p"/api/v1/retrieve/story", mcp_filter_body)

      %{"results" => mcp_filter_results} = json_response(mcp_filter, 200)

      # API and MCP agree, and the set is tenant-scoped (2 rows for `tenant`, NOT
      # the identically-titled `other`-tenant row).
      assert api_filter_meta["total_count"] == 2
      assert length(api_filter_results) == 2
      assert api_filter_results == mcp_filter_results
      assert Enum.all?(api_filter_results, &(&1["title"] == "#{marker} alpha report"))
      # Numbers are the caller tenant's, never 201 (the other tenant's row).
      assert Enum.sort(Enum.map(api_filter_results, & &1["number"])) == ["101", "102"]
      # Shaped to declared columns only — never tenant_id.
      refute Enum.any?(api_filter_results, &Map.has_key?(&1, "tenant_id"))

      # 4a) SEARCH via the DIRECT API body.
      api_search =
        fresh_conn()
        |> auth(agent)
        |> post(~p"/api/v1/retrieve/story", %{"op" => "search", "query" => marker})

      %{"results" => api_search_results, "meta" => api_search_meta} =
        json_response(api_search, 200)

      # 4b) SEARCH via the MCP-DERIVED body.
      mcp_search_body = mcp_body_from_spec(search_spec, %{"query" => marker})

      mcp_search =
        fresh_conn() |> auth(agent) |> post(~p"/api/v1/retrieve/story", mcp_search_body)

      %{"results" => mcp_search_results} = json_response(mcp_search, 200)

      # Search finds the caller tenant's two matching stories (title contains the
      # marker), agrees across API + MCP, and never returns the other tenant's row.
      assert api_search_meta["total_count"] == 2
      assert api_search_results == mcp_search_results

      numbers = api_search_results |> Enum.map(& &1["number"]) |> Enum.sort()
      assert numbers == ["101", "102"]
      refute Enum.any?(api_search_results, &(&1["number"] == "201"))
    end
  end
end
