defmodule LoopctlWeb.HealthControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  describe "GET /health" do
    test "returns 200 when all systems are healthy", %{conn: conn} do
      expect(Loopctl.MockHealthChecker, :check, fn ->
        {:ok,
         %{
           status: "ok",
           version: "0.1.0",
           checks: %{database: "ok", oban: "ok"}
         }}
      end)

      conn = get(conn, "/health")

      assert json_response(conn, 200)["status"] == "ok"
      assert json_response(conn, 200)["version"] == "0.1.0"
      assert json_response(conn, 200)["checks"]["database"] == "ok"
      assert json_response(conn, 200)["checks"]["oban"] == "ok"
    end

    test "does not require authentication", %{conn: conn} do
      expect(Loopctl.MockHealthChecker, :check, fn ->
        {:ok,
         %{
           status: "ok",
           version: "0.1.0",
           checks: %{database: "ok", oban: "ok"}
         }}
      end)

      # No Authorization header set
      conn = get(conn, "/health")
      assert conn.status == 200
    end

    test "returns 503 when database is unavailable", %{conn: conn} do
      expect(Loopctl.MockHealthChecker, :check, fn ->
        {:ok,
         %{
           status: "degraded",
           version: "0.1.0",
           checks: %{database: "error", oban: "ok"}
         }}
      end)

      conn = get(conn, "/health")

      assert conn.status == 503
      body = json_response(conn, 503)
      assert body["status"] == "degraded"
      assert body["checks"]["database"] == "error"
    end

    test "includes application version", %{conn: conn} do
      expect(Loopctl.MockHealthChecker, :check, fn ->
        {:ok,
         %{
           status: "ok",
           version: "1.2.3",
           checks: %{database: "ok", oban: "ok"}
         }}
      end)

      conn = get(conn, "/health")
      body = json_response(conn, 200)

      assert is_binary(body["version"])
      assert body["version"] != ""
    end

    test "responds with JSON content type", %{conn: conn} do
      expect(Loopctl.MockHealthChecker, :check, fn ->
        {:ok,
         %{
           status: "ok",
           version: "0.1.0",
           checks: %{database: "ok", oban: "ok"}
         }}
      end)

      conn = get(conn, "/health")

      content_type =
        conn
        |> get_resp_header("content-type")
        |> hd()

      assert content_type =~ "application/json"
    end
  end
end
