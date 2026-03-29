defmodule LoopctlWeb.RouteDiscoveryControllerTest do
  @moduledoc """
  Tests for GET /api/v1/routes — agent-readable API discovery endpoint.
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

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
