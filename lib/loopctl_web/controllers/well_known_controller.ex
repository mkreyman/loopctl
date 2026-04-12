defmodule LoopctlWeb.WellKnownController do
  @moduledoc """
  US-26.0.4 — RFC 8615 discovery endpoint at `/.well-known/loopctl`.

  Returns a JSON document describing the loopctl deployment's protocol
  version, MCP server coordinates, system article URLs, and trust model
  pointers. No authentication required.
  """

  use LoopctlWeb, :controller

  @base_url "https://loopctl.com"

  # Read the MCP server version from package.json at compile time.
  @external_resource mcp_package = Path.join([__DIR__, "../../../../mcp-server/package.json"])
  @mcp_version (case File.read(mcp_package) do
                  {:ok, contents} ->
                    contents |> Jason.decode!() |> Map.get("version", "0.0.0")

                  {:error, _} ->
                    "0.0.0"
                end)

  @discovery_body %{
    spec_version: "2",
    mcp_server: %{
      name: "loopctl-mcp-server",
      npm_version: @mcp_version,
      repository_url: "https://github.com/mkreyman/loopctl/tree/master/mcp-server"
    },
    audit_signing_key_url: "#{@base_url}/api/v1/tenants/{tenant_id}/audit_public_key",
    capability_scheme_url: "#{@base_url}/wiki/capability-tokens",
    chain_of_custody_spec_url: "#{@base_url}/wiki/chain-of-custody",
    discovery_bootstrap_url: "#{@base_url}/wiki/agent-bootstrap",
    required_agent_pattern_url: "#{@base_url}/wiki/agent-pattern",
    system_articles_endpoint: "#{@base_url}/api/v1/articles/system",
    contact: "operator@loopctl.com"
  }

  @discovery_json Jason.encode!(@discovery_body)
  @etag "W/\"#{:crypto.hash(:sha256, @discovery_json) |> Base.encode16(case: :lower) |> String.slice(0, 16)}\""

  @doc """
  GET /.well-known/loopctl

  Returns the discovery document. Supports conditional GET via ETag.
  """
  def discovery(conn, _params) do
    if_none_match = get_req_header(conn, "if-none-match") |> List.first()

    if if_none_match == @etag do
      conn
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> put_resp_header("etag", @etag)
      |> send_resp(:not_modified, "")
    else
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> put_resp_header("etag", @etag)
      |> send_resp(:ok, @discovery_json)
    end
  end

  @schema_body Jason.encode!(%{
                 "$schema": "https://json-schema.org/draft/2020-12/schema",
                 "$id": "https://loopctl.com/.well-known/loopctl/schema.json",
                 title: "loopctl Discovery Document",
                 type: "object",
                 required: [
                   "spec_version",
                   "mcp_server",
                   "audit_signing_key_url",
                   "capability_scheme_url",
                   "chain_of_custody_spec_url",
                   "system_articles_endpoint"
                 ],
                 properties: %{
                   spec_version: %{type: "string"},
                   mcp_server: %{
                     type: "object",
                     properties: %{
                       name: %{type: "string"},
                       npm_version: %{type: "string"},
                       repository_url: %{type: "string", format: "uri"}
                     }
                   },
                   audit_signing_key_url: %{type: "string", format: "uri-template"},
                   capability_scheme_url: %{type: "string", format: "uri"},
                   chain_of_custody_spec_url: %{type: "string", format: "uri"},
                   discovery_bootstrap_url: %{type: "string", format: "uri"},
                   required_agent_pattern_url: %{type: "string", format: "uri"},
                   system_articles_endpoint: %{type: "string", format: "uri"},
                   contact: %{type: "string"}
                 }
               })

  @doc """
  GET /.well-known/loopctl/schema.json

  Returns the JSON Schema for the discovery document.
  """
  def schema(conn, _params) do
    conn
    |> put_resp_content_type("application/schema+json")
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> send_resp(:ok, @schema_body)
  end
end
