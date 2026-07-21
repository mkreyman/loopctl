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
  # Use project root (File.cwd!) rather than __DIR__ traversal — the latter
  # breaks in Docker where __DIR__ is /app/lib/loopctl_web/controllers and
  # ../../../../ resolves outside the /app WORKDIR.
  @external_resource mcp_package = Path.join(File.cwd!(), "mcp-server/package.json")
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
    # US-26.7.1 — public, agent-rooted (KB-tier) self-signup: no WebAuthn
    # ceremony required. A stranger agent discovering loopctl cold can POST
    # here to obtain a working tenant + key.
    signup_endpoint: "#{@base_url}/api/v1/signup",
    contact: "operator@loopctl.com",
    # US-41.4 (AC-41.4.10) — INSTANCE CAPABILITIES, so an agent can discover the
    # instance's constraints BEFORE authenticating. Strictly instance-wide: no
    # tenant-specific data appears here, and no tenant can influence it.
    capabilities: %{
      # The FIXED set of embedding dimensions this instance supports (US-41.1
      # AC-41.1.3). A tenant-supplied endpoint whose model emits a different
      # dimension cannot be stored.
      supported_embedding_dimensions: [1536],
      # Whether a tenant may point loopctl at their OWN inference endpoint at all.
      tenant_supplied_endpoints_permitted: true,
      # The privacy/storage tiers this instance implements today.
      tiers: ["standard", "local_only"],
      # The egress guarantee, narrowed to exactly what the static chokepoint check
      # proves. HTTP inside a dependency, and the separate mcp-server/ codebase,
      # are outside it — and webhook delivery is not covered until US-41.5.
      egress_guarantee:
        "fail-closed local_only enforcement on every outbound HTTP call made by " <>
          "loopctl application code on the model-provider path",
      egress_posture_endpoint: "#{@base_url}/api/v1/egress/posture"
    }
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
                   "system_articles_endpoint",
                   "signup_endpoint"
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
                   signup_endpoint: %{type: "string", format: "uri"},
                   contact: %{type: "string"},
                   capabilities: %{
                     type: "object",
                     required: [
                       "supported_embedding_dimensions",
                       "tenant_supplied_endpoints_permitted",
                       "tiers"
                     ],
                     properties: %{
                       supported_embedding_dimensions: %{
                         type: "array",
                         items: %{type: "integer"}
                       },
                       tenant_supplied_endpoints_permitted: %{type: "boolean"},
                       tiers: %{type: "array", items: %{type: "string"}},
                       egress_guarantee: %{type: "string"},
                       egress_posture_endpoint: %{type: "string", format: "uri"}
                     }
                   }
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
