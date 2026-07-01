defmodule LoopctlWeb.WelcomeControllerTest do
  use LoopctlWeb.ConnCase, async: true

  describe "GET /api/v1/" do
    test "returns discovery document", %{conn: conn} do
      conn = get(conn, "/api/v1/")

      body = json_response(conn, 200)
      assert body["name"] == "loopctl"
      assert body["docs"] == "/api/v1/openapi"
      assert body["swagger_ui"] == "/swaggerui"
      assert body["health"] == "/health"
    end

    test "points agents at discovery, routes, wiki, and the MCP server", %{conn: conn} do
      conn = get(conn, "/api/v1/")

      body = json_response(conn, 200)
      assert body["discovery"] == "/.well-known/loopctl"
      assert body["routes"] == "/api/v1/routes"
      assert body["wiki"] == "/wiki"
      assert body["mcp_server"]["npm"] == "loopctl-mcp-server"
      assert body["mcp_server"]["registry"] =~ "npmjs.com"
    end
  end
end
