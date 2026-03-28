defmodule LoopctlWeb.OpenApiTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  describe "GET /api/v1/openapi" do
    test "returns a valid OpenAPI 3.0 JSON spec", %{conn: conn} do
      conn = get(conn, "/api/v1/openapi")

      assert json_response(conn, 200)
      body = json_response(conn, 200)

      # Must have top-level OpenAPI keys
      assert body["openapi"] |> String.starts_with?("3.")
      assert body["info"]["title"] == "loopctl"
      assert body["info"]["version"] == "0.1.0"
      assert is_map(body["paths"])
      assert is_map(body["components"])
    end

    test "includes BearerAuth security scheme", %{conn: conn} do
      body = conn |> get("/api/v1/openapi") |> json_response(200)

      bearer = get_in(body, ["components", "securitySchemes", "BearerAuth"])
      assert bearer["type"] == "http"
      assert bearer["scheme"] == "bearer"
    end

    test "is accessible without authentication", %{conn: conn} do
      conn = get(conn, "/api/v1/openapi")
      assert conn.status == 200
    end

    test "includes paths for major endpoints", %{conn: conn} do
      body = conn |> get("/api/v1/openapi") |> json_response(200)
      paths = Map.keys(body["paths"])

      # Spot-check key endpoints are present
      assert "/api/v1/tenants/register" in paths
      assert "/health" in paths
      assert "/api/v1/projects" in paths
      assert "/api/v1/stories/{id}" in paths
    end
  end

  describe "GET /swaggerui" do
    test "serves Swagger UI HTML page", %{conn: conn} do
      conn = get(conn, "/swaggerui")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() |> String.contains?("text/html")
      assert conn.resp_body =~ "swagger"
    end

    test "is accessible without authentication", %{conn: conn} do
      conn = get(conn, "/swaggerui")
      assert conn.status == 200
    end
  end

  describe "GET /api/v1/" do
    test "returns welcome response with discovery links", %{conn: conn} do
      body = conn |> get("/api/v1/") |> json_response(200)

      assert body["name"] == "loopctl"
      assert body["version"] == "0.1.0"
      assert body["docs"] == "/api/v1/openapi"
      assert body["swagger_ui"] == "/swaggerui"
      assert body["health"] == "/health"
    end

    test "is accessible without authentication", %{conn: conn} do
      conn = get(conn, "/api/v1/")
      assert conn.status == 200
    end
  end
end
