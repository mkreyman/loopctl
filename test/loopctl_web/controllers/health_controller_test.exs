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

    test "stays 200 even when readiness (scale_alerts config-guard) is false — liveness must not depool a healthy node",
         %{conn: conn} do
      expect(Loopctl.MockHealthChecker, :check, fn ->
        {:ok,
         %{
           status: "ok",
           ready: false,
           version: "0.1.0",
           checks: %{database: "ok", oban: "ok", scale_alerts: "error"},
           reasons: %{scale_alerts: "scale alerts enabled but SCALE_ALERT_WEBHOOK_URL is not set"}
         }}
      end)

      conn = get(conn, "/health")

      assert conn.status == 200
      assert json_response(conn, 200)["status"] == "ok"
    end

    test "stays 200 even when readiness (Oban orphan backlog) is false — a queue backlog must not depool a node (AC-34.2.2)",
         %{conn: conn} do
      expect(Loopctl.MockHealthChecker, :check, fn ->
        {:ok,
         %{
           status: "ok",
           ready: false,
           version: "0.1.0",
           checks: %{database: "ok", oban: "ok", scale_alerts: "ok", oban_orphans: "error"},
           reasons: %{oban_orphans: "oban executing-orphan count 11 exceeds threshold 10"}
         }}
      end)

      conn = get(conn, "/health")

      assert conn.status == 200
      assert json_response(conn, 200)["status"] == "ok"
    end
  end

  describe "GET /health/ready (US-32.4)" do
    test "returns 200 when ready", %{conn: conn} do
      expect(Loopctl.MockHealthChecker, :check, fn ->
        {:ok,
         %{
           status: "ok",
           ready: true,
           version: "0.1.0",
           checks: %{database: "ok", oban: "ok", scale_alerts: "ok"}
         }}
      end)

      conn = get(conn, "/health/ready")

      assert conn.status == 200
      assert json_response(conn, 200)["ready"] == true
    end

    test "returns 503 when the scale_alerts config-guard is unsatisfied even though liveness is ok",
         %{conn: conn} do
      expect(Loopctl.MockHealthChecker, :check, fn ->
        {:ok,
         %{
           status: "ok",
           ready: false,
           version: "0.1.0",
           checks: %{database: "ok", oban: "ok", scale_alerts: "error"},
           reasons: %{scale_alerts: "scale alerts enabled but SCALE_ALERT_WEBHOOK_URL is not set"}
         }}
      end)

      conn = get(conn, "/health/ready")

      assert conn.status == 503
      body = json_response(conn, 503)
      assert body["ready"] == false
      assert body["reasons"]["scale_alerts"] =~ "SCALE_ALERT_WEBHOOK_URL"
    end

    test "returns 503 when the Oban orphan backlog exceeds its threshold even though liveness is ok (AC-34.2.2)",
         %{conn: conn} do
      expect(Loopctl.MockHealthChecker, :check, fn ->
        {:ok,
         %{
           status: "ok",
           ready: false,
           version: "0.1.0",
           checks: %{database: "ok", oban: "ok", scale_alerts: "ok", oban_orphans: "error"},
           reasons: %{oban_orphans: "oban executing-orphan count 11 exceeds threshold 10"}
         }}
      end)

      conn = get(conn, "/health/ready")

      assert conn.status == 503
      body = json_response(conn, 503)
      assert body["ready"] == false
      assert body["reasons"]["oban_orphans"] =~ "exceeds threshold"
    end

    test "returns 503 when the underlying liveness is degraded too", %{conn: conn} do
      expect(Loopctl.MockHealthChecker, :check, fn ->
        {:ok,
         %{
           status: "degraded",
           ready: false,
           version: "0.1.0",
           checks: %{database: "error", oban: "ok", scale_alerts: "ok"}
         }}
      end)

      conn = get(conn, "/health/ready")

      assert conn.status == 503
    end

    test "falls back to `status` when a health_checker implementation omits `ready`", %{
      conn: conn
    } do
      expect(Loopctl.MockHealthChecker, :check, fn ->
        {:ok,
         %{
           status: "ok",
           version: "0.1.0",
           checks: %{database: "ok", oban: "ok"}
         }}
      end)

      conn = get(conn, "/health/ready")

      assert conn.status == 200
    end
  end
end
