defmodule LoopctlWeb.WelcomeControllerTest do
  use LoopctlWeb.ConnCase, async: true

  describe "GET /" do
    test "redirects to /api/v1/", %{conn: conn} do
      conn = get(conn, "/")

      assert redirected_to(conn, 302) == "/api/v1/"
    end
  end

  describe "GET /api/v1/" do
    test "returns discovery document", %{conn: conn} do
      conn = get(conn, "/api/v1/")

      body = json_response(conn, 200)
      assert body["name"] == "loopctl"
      assert body["docs"] == "/api/v1/openapi"
      assert body["swagger_ui"] == "/swaggerui"
      assert body["health"] == "/health"
    end
  end
end
