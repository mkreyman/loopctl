defmodule LoopctlWeb.WellKnownControllerTest do
  @moduledoc """
  Tests for US-26.0.4 — the /.well-known/loopctl discovery endpoint.
  """

  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AuditChain.LeafHash

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
      # US-26.7.1: a stranger agent discovering loopctl cold can find the
      # public, agent-rooted self-signup path.
      assert body["signup_endpoint"] =~ "loopctl.com/api/v1/signup"
      assert is_binary(body["contact"])
    end

    test "advertises the LCP-1 §2.1 custody-profile discovery fields", %{conn: _conn} do
      conn = Phoenix.ConnTest.build_conn()
      conn = get(conn, "/.well-known/loopctl")

      body = Jason.decode!(conn.resp_body)
      # LCP-1 §2.1: a verifier keys off these; loopctl accepts unsigned claims so
      # the profile is `bearer`.
      assert body["custody_profile"] == "bearer"
      # custody_spec points at a SERVED /wiki/* route (like the sibling *_url
      # fields), not a /spec/* path that has no route and would 404.
      assert body["custody_spec"] =~ "loopctl.com/wiki/chain-of-custody"
      assert body["custody_gates"] == ["report", "review_complete", "verify"]
      # LCP-1 §8.4: advertise the leaf-hash version currently being WRITTEN (v2),
      # single-sourced from the writer so it cannot drift.
      assert body["audit_leaf_hash_version"] == LeafHash.current_version()
      assert body["audit_leaf_hash_version"] == 2
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
      # LCP-1 §2.1 custody fields are required by the published schema too.
      assert "custody_profile" in body["required"]
      assert "custody_spec" in body["required"]
      assert "custody_gates" in body["required"]
      assert "audit_leaf_hash_version" in body["required"]
    end
  end
end
