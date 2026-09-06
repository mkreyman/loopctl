defmodule LoopctlWeb.RouteDiscoveryControllerTest do
  @moduledoc """
  Tests for GET /api/v1/routes — agent-readable API discovery endpoint.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Knowledge.Analytics

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "curated index vs the router" do
    # The index is HAND-CURATED and says so ("common routes"), which makes omission legal in
    # general — but not for /admin. That is a small closed set, every other member is listed,
    # and a superadmin route missing from the index is invisible to the one audience that
    # goes looking for it. This caught exactly that: the per-tenant KB breakdown shipped and
    # the index still listed only stats and audit.
    test "every /api/v1/admin GET route in the router appears in the curated index" do
      router_admin_gets =
        LoopctlWeb.Router.__routes__()
        |> Enum.filter(&(&1.verb == :get and String.starts_with?(&1.path, "/api/v1/admin")))
        |> Enum.map(& &1.path)
        |> MapSet.new()

      indexed =
        LoopctlWeb.RouteDiscoveryController.curated_routes()
        |> Enum.filter(&(&1.method == "GET"))
        |> Enum.map(& &1.path)
        |> MapSet.new()

      missing = MapSet.difference(router_admin_gets, indexed)

      assert MapSet.size(router_admin_gets) > 0,
             "the filter matched nothing — it has drifted from the router's shape and this " <>
               "test is now vacuous"

      assert MapSet.equal?(missing, MapSet.new()),
             "admin GET routes missing from the curated /routes index: " <>
               inspect(MapSet.to_list(missing))
    end

    # The SECOND closed set that earns coverage, for the same reason /admin does and not
    # merely because it would be tidy. The coordination bus is the mechanism a session is
    # TOLD to reach for when it hands work to another machine, and this index is what an
    # agent reads "before probing blindly" — so a channel route missing here is invisible
    # to exactly the audience that needs it, and the failure mode is work done twice or
    # dropped, not a mild inconvenience. The whole surface was absent until #707's read
    # was added; without this test it can silently fall out again.
    test "every /api/v1/channel route in the router appears in the curated index" do
      router_channel =
        LoopctlWeb.Router.__routes__()
        |> Enum.filter(&String.starts_with?(&1.path, "/api/v1/channel"))
        |> Enum.map(&{verb_string(&1.verb), &1.path})
        |> MapSet.new()

      indexed =
        LoopctlWeb.RouteDiscoveryController.curated_routes()
        |> Enum.map(&{&1.method, &1.path})
        |> MapSet.new()

      assert MapSet.size(router_channel) > 0,
             "the filter matched nothing — it has drifted from the router's shape and this " <>
               "test is now vacuous"

      missing = MapSet.difference(router_channel, indexed)

      assert MapSet.equal?(missing, MapSet.new()),
             "coordination-bus routes missing from the curated /routes index: " <>
               inspect(MapSet.to_list(missing))
    end

    # The THIRD closed set, added with US-43.2 and for the same reason as the other two.
    # The router-to-index direction of this file is filtered by PREFIX, so without an arm
    # of its own an omitted corpus route fails nothing and the whole surface ships
    # undiscoverable via GET /api/v1/routes — which is where an agent is told to look
    # "before probing blindly", and the corpus tier is a surface an agent has no other way
    # to learn about. Carries the same non-empty-filter assertion, so it cannot go vacuous
    # if the route shape drifts.
    test "every /api/v1/corpora route in the router appears in the curated index" do
      router_corpora =
        LoopctlWeb.Router.__routes__()
        |> Enum.filter(&String.starts_with?(&1.path, "/api/v1/corpora"))
        |> Enum.map(&{verb_string(&1.verb), &1.path})
        |> MapSet.new()

      indexed =
        LoopctlWeb.RouteDiscoveryController.curated_routes()
        |> Enum.map(&{&1.method, &1.path})
        |> MapSet.new()

      assert MapSet.size(router_corpora) > 0,
             "the filter matched nothing — it has drifted from the router's shape and this " <>
               "test is now vacuous"

      missing = MapSet.difference(router_corpora, indexed)

      assert MapSet.equal?(missing, MapSet.new()),
             "corpus-tier routes missing from the curated /routes index: " <>
               inspect(MapSet.to_list(missing))
    end

    test "every path in the curated index actually exists in the router" do
      router_paths =
        LoopctlWeb.Router.__routes__() |> Enum.map(& &1.path) |> MapSet.new()

      phantom =
        LoopctlWeb.RouteDiscoveryController.curated_routes()
        |> Enum.map(& &1.path)
        |> Enum.reject(&MapSet.member?(router_paths, &1))

      assert phantom == [],
             "the index advertises routes the router does not serve: " <> inspect(phantom)
    end
  end

  defp verb_string(verb), do: verb |> to_string() |> String.upcase()

  describe "GET /api/v1/routes" do
    test "returns list of routes with method, path, description", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/routes")

      body = json_response(conn, 200)

      assert is_list(body["routes"])
      assert body["count"] == length(body["routes"])
      assert body["count"] > 0

      first = hd(body["routes"])
      assert Map.has_key?(first, "method")
      assert Map.has_key?(first, "path")
      assert Map.has_key?(first, "description")
    end

    test "includes key story endpoints", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/routes")

      body = json_response(conn, 200)
      paths = Enum.map(body["routes"], & &1["path"])

      assert "/api/v1/stories" in paths
      assert "/api/v1/stories/:id" in paths
      assert "/api/v1/stories/:id/contract" in paths
      assert "/api/v1/stories/:id/claim" in paths
      assert "/api/v1/stories/:id/start" in paths
      assert "/api/v1/stories/:id/report" in paths
      assert "/api/v1/stories/:id/verify" in paths
      assert "/api/v1/stories/:id/reject" in paths
    end

    test "documents limit/page_size aliasing for story listing", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/routes")

      body = json_response(conn, 200)

      stories_route =
        Enum.find(body["routes"], fn r ->
          r["path"] == "/api/v1/stories" && r["method"] == "GET"
        end)

      assert stories_route != nil
      assert stories_route["description"] =~ "limit"
      assert stories_route["description"] =~ "page_size"

      epic_stories_route =
        Enum.find(body["routes"], fn r ->
          r["path"] == "/api/v1/epics/:epic_id/stories" && r["method"] == "GET"
        end)

      assert epic_stories_route != nil
      assert epic_stories_route["description"] =~ "page_size"
      assert epic_stories_route["description"] =~ "limit"
    end

    test "the article-stats description matches what total_events actually counts",
         %{conn: conn} do
      # The route index is the FIRST thing an agent reads about an endpoint, so a
      # description that overstates a counter re-tells the exact lie the counter was
      # changed to stop telling: `referenced` is client-asserted, and a self-asserted
      # signal must not read as delivery. Asserted together with the behaviour, so the
      # text can only be right while it describes what `get_article_stats/2` does.
      tenant = fixture(:tenant)
      {raw_key, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      for access_type <- ["search", "referenced"] do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          api_key_id: key.id,
          article_id: article.id,
          access_type: access_type
        })
      end

      stats = Analytics.get_article_stats(tenant.id, article.id)

      assert stats.total_events == 1,
             "the impression counts and the client assertion does not"

      assert stats.accesses_by_type["referenced"] == 1,
             "the assertion stays visible under its own key"

      body =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/routes")
        |> json_response(200)

      stats_route =
        Enum.find(body["routes"], fn r ->
          r["path"] == "/api/v1/knowledge/articles/:id/stats" && r["method"] == "GET"
        end)

      assert stats_route != nil
      assert stats_route["description"] =~ "impressions"
      assert stats_route["description"] =~ ~r/referenced rows EXCLUDED/
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/routes")
      assert json_response(conn, 401)
    end

    test "count field matches routes list length", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/routes")

      body = json_response(conn, 200)
      assert body["count"] == length(body["routes"])
    end

    test "accessible with orchestrator role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/routes")

      assert json_response(conn, 200)
    end
  end
end
