defmodule LoopctlWeb.WellKnownControllerTest do
  @moduledoc """
  Tests for US-26.0.4 — the /.well-known/loopctl discovery endpoint.
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  describe "GET /.well-known/loopctl" do
    test "returns the discovery document with expected fields", %{conn: _conn} do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, "/.well-known/loopctl")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"

      body = Jason.decode!(conn.resp_body)
      assert body["spec_version"] == "2"
      assert body["mcp_server"]["name"] == "loopctl-mcp-server"
      assert is_binary(body["mcp_server"]["npm_version"])
      assert body["audit_signing_key_url"] =~ "{tenant_id}"
      assert body["capability_scheme_url"] =~ "loopctl.com/wiki/capability-tokens"
      assert body["chain_of_custody_spec_url"] =~ "loopctl.com/wiki/chain-of-custody"
      assert body["discovery_bootstrap_url"] =~ "loopctl.com/wiki/agent-bootstrap"
      assert body["required_agent_pattern_url"] =~ "loopctl.com/wiki/agent-pattern"
      assert body["system_articles_endpoint"] =~ "loopctl.com/api/v1/articles/system"
      assert is_binary(body["contact"])
    end

    test "includes Cache-Control and ETag headers", %{conn: _conn} do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, "/.well-known/loopctl")

      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]

      [etag] = get_resp_header(conn, "etag")
      assert String.starts_with?(etag, "W/\"")
    end

    test "conditional GET returns 304 with matching ETag", %{conn: _conn} do
      conn = Phoenix.ConnTest.build_conn()
      first = get(conn, "/.well-known/loopctl")
      [etag] = get_resp_header(first, "etag")

      second =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("if-none-match", etag)
        |> get("/.well-known/loopctl")

      assert second.status == 304
    end

    test "URLs are hardcoded to loopctl.com, not derived from request", %{conn: _conn} do
      conn =
        %{Phoenix.ConnTest.build_conn() | host: "localhost"}
        |> get("/.well-known/loopctl")

      body = Jason.decode!(conn.resp_body)
      assert body["chain_of_custody_spec_url"] =~ "loopctl.com"
      refute body["chain_of_custody_spec_url"] =~ "localhost"
    end

    test "does not leak tenant-specific information", %{conn: _conn} do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, "/.well-known/loopctl")

      body = Jason.decode!(conn.resp_body)
      # audit_signing_key_url uses a template placeholder, not a real tenant ID
      assert body["audit_signing_key_url"] =~ "{tenant_id}"
      # No other field contains tenant data
      refute Map.has_key?(body, "tenants")
    end

    test "accessible without authentication", %{conn: _conn} do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, "/.well-known/loopctl")
      assert conn.status == 200
    end
  end

  describe "GET /.well-known/loopctl/schema.json" do
    test "returns a valid JSON schema", %{conn: _conn} do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, "/.well-known/loopctl/schema.json")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/schema+json"

      body = Jason.decode!(conn.resp_body)
      assert body["$schema"] =~ "json-schema.org"
      assert body["type"] == "object"
      assert "spec_version" in body["required"]
    end
  end
end
