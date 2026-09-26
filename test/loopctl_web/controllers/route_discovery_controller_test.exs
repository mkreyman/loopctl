defmodule LoopctlWeb.RouteDiscoveryControllerTest do
  @moduledoc """
  Tests for GET /api/v1/routes — agent-readable API discovery endpoint.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Knowledge.Analytics

  setup :verify_on_exit!

  # Codes a row may name, and what must produce each. A plug-produced code is bound to the
  # plug being mounted for the action; any other is bound to a string literal in a function
  # the action reaches.
  @plug_codes %{
    "insufficient_role" => "RequireRole",
    "custody_tier_required" => "RequireHumanAnchor",
    "api_key_mint_forbidden" => "RequireUnlineagedCaller"
  }
  @refusal_codes Map.keys(@plug_codes) ++
                   [
                     "root_dispatch_forbidden",
                     "parent_outside_caller_lineage",
                     "dispatch_outside_caller_lineage",
                     "unlineaged_revoke_forbidden"
                   ]

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
        served_routes()
        |> Enum.filter(fn {method, path} ->
          method == "GET" and String.starts_with?(path, "/api/v1/admin")
        end)
        |> MapSet.new()

      indexed = indexed_routes()

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
        served_routes()
        |> Enum.filter(fn {_method, path} -> String.starts_with?(path, "/api/v1/channel") end)
        |> MapSet.new()

      indexed = indexed_routes()

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
        served_routes()
        |> Enum.filter(fn {_method, path} -> String.starts_with?(path, "/api/v1/corpora") end)
        |> MapSet.new()

      indexed = indexed_routes()

      assert MapSet.size(router_corpora) > 0,
             "the filter matched nothing — it has drifted from the router's shape and this " <>
               "test is now vacuous"

      missing = MapSet.difference(router_corpora, indexed)

      assert MapSet.equal?(missing, MapSet.new()),
             "corpus-tier routes missing from the curated /routes index: " <>
               inspect(MapSet.to_list(missing))
    end

    # The FOURTH closed set, and the one that shipped broken: #874 merged five intake routes
    # and added no row here, so on release 671 GET /api/v1/routes returned 184 routes with
    # not one of them. That is the reachability failure CLAUDE.md's "an operator-facing
    # endpoint is NOT DONE until an MCP tool calls it" section names, one layer out — the
    # tools existed, the discovery surface a session reads to FIND them did not. A loop with
    # no intake source has no input, so an undiscoverable enrolment route is the difference
    # between a delivery loop and a queue nobody can feed.
    #
    # PUT is excluded where its PATCH twin is indexed: `resources ... only: [:update]`
    # generates both for one action, the MCP tool and the docs both name PATCH, and a second
    # row for the same endpoint would be noise in a hand-curated index. A PUT-only route
    # would still be required, so this cannot hide a whole endpoint.
    test "every /api/v1/intake route in the router appears in the curated index" do
      indexed = indexed_routes()

      router_intake =
        served_routes()
        |> Enum.filter(fn {_method, path} -> String.starts_with?(path, "/api/v1/intake") end)
        |> Enum.reject(fn {method, path} ->
          method == "PUT" and MapSet.member?(indexed, {"PATCH", path})
        end)
        |> MapSet.new()

      assert MapSet.size(router_intake) > 0,
             "the filter matched nothing — it has drifted from the router's shape and this " <>
               "test is now vacuous"

      missing = MapSet.difference(router_intake, indexed)

      assert MapSet.equal?(missing, MapSet.new()),
             "GitHub-intake routes missing from the curated /routes index: " <>
               inspect(MapSet.to_list(missing))
    end

    # The delivery loop's own surface past intake (#878): enrolling a runner, the pool,
    # placement, revocation and the merge gate. A session that found the intake tools still
    # could not discover these, which is the rest of wiring the loop up.
    #
    # Every fact a row states about its gate is bound to where that gate actually lives, so
    # the text cannot drift from the code it describes:
    #
    #   - "MCP tool: none" <-> a `gap` in mcp-server/test/route_coverage.test.js's DECLARED,
    #     both directions. That a NAMED tool really sends the row's route is asserted on the
    #     JS side (mcp-server/test/route_index_tools.test.js), where the call sites are.
    #   - "human-anchored" <-> the route's controller mounting RequireHumanAnchor FOR THAT
    #     ACTION, read from the controller source's `when action in [...]` scoping.
    #   - each refusal code a row names <-> something on the route producing it: a plug
    #     mounted for the action, or a string literal in a function the action reaches.
    test "every delivery-loop runner, dispatch, merge-gate and stage route is indexed, with a real role and tool" do
      indexed =
        LoopctlWeb.RouteDiscoveryController.curated_routes()
        |> Map.new(&{{&1.method, &1.path}, &1.description})

      gaps = declared_gaps()

      # EACH clause must match on its own, or a renamed route drops out of the check silently.
      clauses = [
        runners: &String.starts_with?(&1, "/api/v1/runners"),
        dispatches: &String.starts_with?(&1, "/api/v1/dispatches"),
        merge_gate: &String.ends_with?(&1, "/merge-precondition"),
        story_stage: &(&1 =~ ~r{^/api/v1/stories/:id/(stage|stage/resolve|escalate|renew-claim)$})
      ]

      for {clause, match?} <- clauses do
        routes = Enum.filter(served_routes(), fn {_method, path} -> match?.(path) end)
        assert routes != [], "the #{clause} clause matched no served route — it has drifted"

        for route <- routes do
          description = Map.get(indexed, route)
          assert description, "#{inspect(route)} is served but not in the curated /routes index"
          assert description =~ "Role:", "#{inspect(route)} names no role"

          gap? = MapSet.member?(gaps, coverage_key(route))

          case Regex.run(~r/MCP tool: ([a-z_]+)/, description, capture: :all_but_first) do
            ["none"] ->
              assert gap?,
                     "#{inspect(route)} says MCP tool: none, but route_coverage.test.js " <>
                       "does not declare it a gap"

            [tool] ->
              refute gap?,
                     "#{inspect(route)} is a declared gap in route_coverage.test.js, but its " <>
                       "row names MCP tool #{tool} — one of the two is wrong"

            nil ->
              flunk("#{inspect(route)} names no MCP tool")
          end

          %{plug: controller, plug_opts: action} = router_route(route)

          assert description =~ "human-anchored" ==
                   mounts_for_action?(controller, "RequireHumanAnchor", action),
                 "#{inspect(route)}: the row's human-anchored claim disagrees with whether " <>
                   "#{inspect(controller)} mounts RequireHumanAnchor for :#{action}"

          assert description =~ "api_key_mint_forbidden" ==
                   mounts_for_action?(controller, "RequireUnlineagedCaller", action),
                 "#{inspect(route)}: the row's api_key_mint_forbidden claim disagrees with " <>
                   "whether #{inspect(controller)} mounts RequireUnlineagedCaller for :#{action}"

          for code <- @refusal_codes, description =~ code do
            assert refusal_produced?(controller, action, code),
                   "#{inspect(route)} names #{code}, which nothing on " <>
                     "#{inspect(controller)}.#{action} produces"
          end
        end
      end

      # Outside the sections too: a row anywhere that says "none" is a declared gap.
      for %{method: method, path: path, description: description} <-
            LoopctlWeb.RouteDiscoveryController.curated_routes(),
          description =~ "MCP tool: none" do
        assert MapSet.member?(gaps, coverage_key({method, path})),
               "#{method} #{path} says MCP tool: none, but route_coverage.test.js does not " <>
                 "declare it a gap"
      end
    end

    # The create row is the one a session acts on, and two of its facts are the expensive
    # ones to learn by probing: a dispatch-minted key can never call it however privileged
    # it is, and the webhook secret is returned once and is then unrecoverable. Asserted on
    # the text because the text is what the agent reads.
    test "the intake enrolment row names the unlineaged-caller gate and the one-shot secret" do
      row =
        Enum.find(
          LoopctlWeb.RouteDiscoveryController.curated_routes(),
          &(&1.method == "POST" and &1.path == "/api/v1/intake/sources")
        )

      assert row, "POST /api/v1/intake/sources is not in the curated index"
      assert row.description =~ "api_key_mint_forbidden"
      assert row.description =~ ~r/UNLINEAGED/
      assert row.description =~ ~r/EXACTLY ONCE/
      assert row.description =~ "intake_source_enroll"
    end

    test "every METHOD and path in the curated index is actually served" do
      # Method AND path: a row with the wrong verb on a served path advertises a 404.
      served = served_routes()

      phantom =
        LoopctlWeb.RouteDiscoveryController.curated_routes()
        |> Enum.map(&{&1.method, &1.path})
        |> Enum.reject(&MapSet.member?(served, &1))

      assert phantom == [],
             "the index advertises routes the router does not serve: " <> inspect(phantom)
    end
  end

  # The two sets every router-versus-index check compares, written once each: what the
  # curated index advertises, and what the router serves, both as {"METHOD", path}.
  defp indexed_routes do
    LoopctlWeb.RouteDiscoveryController.curated_routes()
    |> Enum.map(&{&1.method, &1.path})
    |> MapSet.new()
  end

  defp served_routes do
    LoopctlWeb.Router.__routes__()
    |> Enum.map(&{verb_string(&1.verb), &1.path})
    |> MapSet.new()
  end

  defp router_route({method, path}) do
    Enum.find(
      LoopctlWeb.Router.__routes__(),
      &(verb_string(&1.verb) == method and &1.path == path)
    )
  end

  defp verb_string(verb), do: verb |> to_string() |> String.upcase()

  # The `gap` entries of route_coverage.test.js's DECLARED, keyed the way that file keys them.
  defp declared_gaps do
    source = File.read!("mcp-server/test/route_coverage.test.js")
    [block] = Regex.run(~r/const DECLARED = \{(.*?)\n\};/s, source, capture: :all_but_first)

    gaps =
      ~r/^\s*"([A-Z]+ \/[^"]*)": "gap",/m
      |> Regex.scan(block, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    assert MapSet.size(gaps) > 0, "no gap parsed from DECLARED — its shape has drifted"
    gaps
  end

  # route_coverage.test.js normalises every path parameter to `:param`.
  defp coverage_key({method, path}),
    do: method <> " " <> Regex.replace(~r/:[A-Za-z0-9_]+/, path, ":param")

  defp refusal_produced?(controller, action, code) do
    case Map.fetch(@plug_codes, code) do
      {:ok, plug} -> mounts_for_action?(controller, plug, action)
      :error -> action_emits?(controller, action, code)
    end
  end

  defp controller_source(controller) do
    controller.__info__(:compile)[:source] |> to_string() |> File.read!()
  end

  # Action-scoped: a `plug <Name>` line with no guard applies to every action, one with
  # `when action in [...]` to those it names. Any other shape — a
  # guard this cannot read, or a plug statement wrapped past one line — fails loudly rather
  # than being guessed at.
  defp mounts_for_action?(controller, plug, action) do
    ~r/^\s*plug\s+(?:LoopctlWeb\.Plugs\.)?#{plug}\b([^\n]*)$/m
    |> Regex.scan(controller_source(controller), capture: :all_but_first)
    |> Enum.any?(fn [tail] -> plug_scope_includes?(tail, action, controller) end)
  end

  defp plug_scope_includes?(tail, action, controller) do
    in_list = Regex.run(~r/when action in \[([^\]]*)\]/, tail, capture: :all_but_first)

    cond do
      String.ends_with?(String.trim(tail), ",") ->
        flunk("#{inspect(controller)} wraps a plug statement past one line: #{tail}")

      in_list ->
        to_string(action) in List.flatten(
          Regex.scan(~r/:(\w+)/, hd(in_list), capture: :all_but_first)
        )

      String.contains?(tail, "when") ->
        flunk("#{inspect(controller)} scopes a plug in a shape this test cannot read: #{tail}")

      true ->
        true
    end
  end

  # Source-read reachability: the action's own clauses plus every function of the module
  # they name, transitively, comments stripped. A name mentioned is a name reached, so it
  # errs toward passing a row; the one way it errs the other way is a def head wrapped past
  # its first line, whose body it does not see — that fails the test loudly, never silently.
  defp action_emits?(controller, action, code) do
    bodies = function_bodies(controller_source(controller))

    bodies
    |> reachable([to_string(action)], MapSet.new())
    |> Enum.any?(&String.contains?(Map.fetch!(bodies, &1), ~s("#{code}")))
  end

  defp reachable(_bodies, [], seen), do: seen

  defp reachable(bodies, [name | rest], seen) do
    if MapSet.member?(seen, name) or not Map.has_key?(bodies, name) do
      reachable(bodies, rest, seen)
    else
      called =
        ~r/\b([a-z_][a-zA-Z0-9_]*[?!]?)/
        |> Regex.scan(Map.fetch!(bodies, name), capture: :all_but_first)
        |> List.flatten()
        |> Enum.filter(&Map.has_key?(bodies, &1))

      reachable(bodies, called ++ rest, MapSet.put(seen, name))
    end
  end

  # Every top-level def/defp's text, clauses of one name concatenated. A function ends at the
  # next line indented exactly two spaces (its `end`, an attribute, a plug, the next head).
  defp function_bodies(source) do
    {bodies, _current} =
      source
      |> String.split("\n")
      |> Enum.reduce({%{}, nil}, &take_line/2)

    bodies
  end

  defp take_line(line, {acc, current}) do
    head = Regex.run(~r/^  defp? ([a-z_][a-zA-Z0-9_]*[?!]?)/, line, capture: :all_but_first)

    cond do
      head -> {Map.update(acc, hd(head), line, &(&1 <> "\n" <> line)), hd(head)}
      Regex.match?(~r/^  \S/, line) or is_nil(current) -> {acc, nil}
      true -> {Map.update!(acc, current, &(&1 <> "\n" <> strip_comment(line))), current}
    end
  end

  defp strip_comment(line), do: Regex.replace(~r/(^|\s)#(?!\{).*$/, line, "")

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
