defmodule LoopctlWeb.RouterSnapshotTest do
  @moduledoc """
  THE ORACLE HALF of the MCP route-coverage sweep.

  `mcp-server/test/route_coverage.test.js` asserts that every `/api/v1` route loopctl
  serves is reachable by an MCP tool or declared with a reason. It runs under `node --test`
  with no BEAM, so it cannot ask the router anything; it reads
  `mcp-server/test/router-routes.json`, which `mix loopctl.routes_snapshot` generates FROM
  the router.

  That file is only worth reading if it is current, and this is what makes staleness loud.
  It runs in `mix precommit` (the commit hook) and in the CI Test job, both of which fire
  on every change to this project — including a change to `router.ex` alone, which the
  node workflow's `mcp-server/**` path filter would otherwise skip entirely.

  ## The failure it exists to end

  The node suite used to PARSE `router.ex` with regexes and treat its own output as the
  complete route table. Over two review rounds that parse was silently wrong four times —
  unexpanded `resources`, a wrapped verb macro, a `#` comment inside a wrapped
  declaration, and a plug mounted with no action atom — and the sweep was green through
  all of them, because nothing compared the parse to the router. A second source of truth
  that nobody reconciles is not a check; it is a guess with a test suite around it.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopctl.RoutesSnapshot

  test "the checked-in route snapshot is byte-identical to the router's own route table" do
    assert File.exists?(RoutesSnapshot.snapshot_path()),
           "#{RoutesSnapshot.snapshot_path()} is missing. The MCP coverage sweep reads it as " <>
             "its inventory of what loopctl serves. Regenerate it: mix loopctl.routes_snapshot"

    assert File.read!(RoutesSnapshot.snapshot_path()) == RoutesSnapshot.render(),
           """
           The router's route table and mcp-server/test/router-routes.json disagree.

           That file is what mcp-server/test/route_coverage.test.js believes loopctl serves,
           so while they disagree the MCP coverage sweep is answering for a surface that no
           longer exists — a route added with no tool reads as absent rather than as debt.

           Regenerate it and commit the result:

               mix loopctl.routes_snapshot

           Then run the node suite (cd mcp-server && npm test): a NEW route with no MCP tool
           will fail the coverage sweep there, which is the point.
           """
  end

  test "the snapshot is not vacuous — it carries the surface the sweep depends on" do
    # Byte equality above is satisfied by two empty files, and by a `render/0` that lost its
    # route source and returned a frame with no routes in it. Anchored on routes that must
    # exist for loopctl to work at all, and on the plug mount whose SHAPE is what the parser
    # this replaces could not see, rather than on a count (wrong by the next merge).
    rendered = RoutesSnapshot.render()
    routes = Jason.decode!(rendered)["routes"]
    keys = MapSet.new(routes, fn [verb, path, _plug, _opts] -> "#{verb} #{path}" end)

    api_routes = Enum.filter(routes, fn [_verb, path, _plug, _opts] -> path =~ ~r"^/api/v1" end)

    assert length(api_routes) > 100,
           "only #{length(api_routes)} /api/v1 routes were rendered"

    assert MapSet.member?(keys, "PATCH /api/v1/stories/:id")
    assert MapSet.member?(keys, "GET /api/v1/projects")

    # A bare plug mount: no action atom, and therefore the one route shape a line-matching
    # parser drops without noticing.
    assert MapSet.member?(keys, "GET /api/v1/openapi")

    # A route whose declaration is WRAPPED across lines in router.ex, which is the other
    # shape that was invisible. Nothing about rendering from the router cares how the
    # source was laid out, and this is what says so.
    assert MapSet.member?(keys, "GET /api/v1/knowledge/analytics/projects/:id/usage")
  end
end
