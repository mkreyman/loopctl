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

  @discovery_base %{
    spec_version: "2",
    mcp_server: %{
      name: "loopctl-mcp-server",
      npm_version: @mcp_version,
      repository_url: "https://github.com/mkreyman/loopctl/tree/master/mcp-server"
    },
    audit_signing_key_url: "#{@base_url}/api/v1/tenants/{tenant_id}/audit_public_key",
    capability_scheme_url: "#{@base_url}/wiki/capability-tokens",
    chain_of_custody_spec_url: "#{@base_url}/wiki/chain-of-custody",
    # LCP-1 §2.1 — the custody-profile discovery fields a third-party verifier
    # keys off. loopctl still accepts unsigned custody claims, so the profile is
    # `bearer` (§2.1: a deployment emitting signatures but accepting unsigned
    # claims is bearer, not signed). `audit_leaf_hash_version` is §8.4's "advertise
    # what you are CURRENTLY writing", single-sourced from the writer so it can
    # never drift from `build_entry_attrs`; §10.2.1's "end to end" caveat is a
    # separate, stronger claim about the historical chain that this field does not
    # make.
    custody_profile: "bearer",
    custody_spec: "#{@base_url}/spec/LCP-1",
    custody_gates: ["report", "review_complete", "verify"],
    audit_leaf_hash_version: Loopctl.AuditChain.LeafHash.current_version(),
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

  @doc """
  The discovery document, built at RUNTIME.

  Two capability fields are DEPLOYMENT-DEPENDENT and must therefore be derived
  from the same runtime config the application itself validates against — a
  compile-time literal would publish a constraint the running instance does not
  actually enforce, to UNAUTHENTICATED agents, with no way for the runtime value
  to reach the document:

    * `supported_embedding_dimensions` — read from `:embedding_dimensions`, the
      key `Loopctl.Memory.Memory`'s validator reads (US-41.1 AC-41.1.3).
    * `tenant_supplied_endpoints_permitted` — TRUE only once the endpoint-config
      surface exists (US-41.2). Declaring a TRUSTED endpoint, which does ship in
      US-41.4, changes the locality VERDICT for an endpoint — it does not let a
      tenant point loopctl at their own Ollama box — so it does not make this
      flag true. AC-41.4.10's whole purpose is that an agent can discover the
      instance's constraints BEFORE authenticating; advertising a capability the
      instance cannot honour defeats it.
  """
  @spec discovery_body() :: map()
  def discovery_body do
    put_in(@discovery_base, [:capabilities], capabilities())
  end

  defp capabilities do
    Map.merge(@discovery_base.capabilities, %{
      # US-41.1 AC-41.1.3: the FULL supported set, not just the deployment default.
      # Single-sourced with the per-dimension ANN indexes the migration builds and
      # with the compile-time cast set `VectorSearch` can emit, so the document can
      # never advertise a dimension the instance has no index (or no query) for.
      supported_embedding_dimensions: Loopctl.Embeddings.supported_dimensions(),
      default_embedding_dimension: Loopctl.Embeddings.default_dimension(),
      tenant_supplied_endpoints_permitted: tenant_supplied_endpoints_permitted?()
    })
  end

  # US-41.2 lands the tenant-configurable endpoint surface; until then no tenant
  # can supply an endpoint on this instance, whatever the deployment config says.
  defp tenant_supplied_endpoints_permitted?,
    do: Application.get_env(:loopctl, :tenant_supplied_endpoints_permitted, false)

  @doc """
  GET /.well-known/loopctl

  Returns the discovery document. Supports conditional GET via ETag. The body and
  its ETag are built per request (the document is a small map) so a
  deployment-configured embedding dimension is reflected without a recompile.
  """
  def discovery(conn, _params) do
    json = Jason.encode!(discovery_body())
    etag = etag_for(json)
    if_none_match = get_req_header(conn, "if-none-match") |> List.first()

    if if_none_match == etag do
      conn
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> put_resp_header("etag", etag)
      |> send_resp(:not_modified, "")
    else
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> put_resp_header("etag", etag)
      |> send_resp(:ok, json)
    end
  end

  defp etag_for(json) do
    hash = :sha256 |> :crypto.hash(json) |> Base.encode16(case: :lower) |> String.slice(0, 16)
    ~s(W/"#{hash}")
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
                   "custody_profile",
                   "custody_spec",
                   "custody_gates",
                   "audit_leaf_hash_version",
                   "system_articles_endpoint",
                   "signup_endpoint"
                 ],
                 properties: %{
                   spec_version: %{type: "string"},
                   custody_profile: %{type: "string", enum: ["bearer", "signed"]},
                   custody_spec: %{type: "string", format: "uri"},
                   custody_gates: %{type: "array", items: %{type: "string"}},
                   audit_leaf_hash_version: %{type: "integer"},
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
