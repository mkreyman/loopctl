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
      assert body["info"]["version"] == "1.0.0"
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

      # Spot-check key endpoints are present. US-26.0.1 removed
      # `POST /api/v1/tenants/register` — signup is now the only
      # tenant-creation path and it's a LiveView, not an API route.
      assert "/api/v1/tenants/me" in paths
      assert "/health" in paths
      assert "/api/v1/projects" in paths
      assert "/api/v1/stories/{id}" in paths
      # US-26.7.1 (#10) — the public agent-rooted self-signup endpoint must stay
      # registered in the OpenAPI spec (it's the API tenant-creation path).
      assert "/api/v1/signup" in paths
      # US-26.7.2 — the opt-in WebAuthn trust-tier upgrade ceremony endpoints
      # must be registered.
      assert "/api/v1/tenants/{id}/authenticators/challenge" in paths
      assert "/api/v1/tenants/{id}/authenticators" in paths
      assert "/api/v1/tenants/{id}/authenticators/revoke-challenge" in paths
      assert "/api/v1/tenants/{id}/authenticators/{auth_id}" in paths
    end

    # US-28.5 (AC-28.5.2) — the Agent Memory endpoints (Epic 28) must render in the
    # OpenAPI spec (declared via `operation(...)` in MemoryController), so they show
    # up at /swaggerui.
    test "includes the Agent Memory (Epic 28) endpoints", %{conn: conn} do
      body = conn |> get("/api/v1/openapi") |> json_response(200)
      paths = body["paths"]

      assert Map.has_key?(paths, "/api/v1/memory")
      assert Map.has_key?(paths, "/api/v1/memory/recall")
      assert Map.has_key?(paths, "/api/v1/memory/promote")
      assert Map.has_key?(paths, "/api/v1/memory/{id}")

      # The verbs the controller declares: remember (POST), list (GET), recall
      # (POST), promote (POST), forget (DELETE).
      assert Map.has_key?(paths["/api/v1/memory"], "post")
      assert Map.has_key?(paths["/api/v1/memory"], "get")
      assert Map.has_key?(paths["/api/v1/memory/recall"], "post")
      assert Map.has_key?(paths["/api/v1/memory/promote"], "post")
      assert Map.has_key?(paths["/api/v1/memory/{id}"], "delete")

      # And the Memory* response schemas are registered under components.
      schemas = body["components"]["schemas"]
      assert Map.has_key?(schemas, "Memory")
      assert Map.has_key?(schemas, "MemoryRecallResponse")
      assert Map.has_key?(schemas, "MemoryPromoteRequest")
    end

    # US-30.4 (AC-30.4.5) — the Context Retriever endpoints (Epic 30) must render
    # in the OpenAPI spec (declared via `operation(...)` in
    # ContextRetrieverController) so they show up at /swaggerui.
    test "includes the Context Retriever (Epic 30) endpoints", %{conn: conn} do
      body = conn |> get("/api/v1/openapi") |> json_response(200)
      paths = body["paths"]

      assert Map.has_key?(paths, "/api/v1/entities")
      assert Map.has_key?(paths, "/api/v1/entities/{id}")
      assert Map.has_key?(paths, "/api/v1/retrieve/tools")
      assert Map.has_key?(paths, "/api/v1/retrieve/{entity}")

      # The verbs each route declares.
      assert Map.has_key?(paths["/api/v1/entities"], "get")
      assert Map.has_key?(paths["/api/v1/entities"], "post")
      assert Map.has_key?(paths["/api/v1/entities/{id}"], "get")
      assert Map.has_key?(paths["/api/v1/entities/{id}"], "patch")
      assert Map.has_key?(paths["/api/v1/entities/{id}"], "delete")
      assert Map.has_key?(paths["/api/v1/retrieve/tools"], "get")
      assert Map.has_key?(paths["/api/v1/retrieve/{entity}"], "post")

      # And the Context Retriever schemas are registered under components.
      schemas = body["components"]["schemas"]
      assert Map.has_key?(schemas, "EntityDefinition")
      assert Map.has_key?(schemas, "EntityDefinitionRequest")
      assert Map.has_key?(schemas, "EntityDefinitionListResponse")
      assert Map.has_key?(schemas, "RetrieveToolsResponse")
      assert Map.has_key?(schemas, "RetrieveResponse")
    end

    # US-39.2 (AC-39.2.1) — the Coordination Bus write endpoint (Epic 39) must
    # render in the OpenAPI spec (declared via `operation(...)` in
    # ChannelPostController) so it shows up at /swaggerui.
    test "includes the Coordination Bus (Epic 39) write endpoint", %{conn: conn} do
      body = conn |> get("/api/v1/openapi") |> json_response(200)
      paths = body["paths"]

      assert Map.has_key?(paths, "/api/v1/channel/posts")
      assert Map.has_key?(paths["/api/v1/channel/posts"], "post")

      schemas = body["components"]["schemas"]
      assert Map.has_key?(schemas, "ChannelPostRequest")
      assert Map.has_key?(schemas, "ChannelPostResponse")
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
      assert body["version"] == "1.0.0"
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
