defmodule LoopctlWeb.EgressController do
  @moduledoc """
  Egress posture + `local_only` marking + tenant-declared trusted endpoints
  (US-41.4). No UI — this is the JSON surface behind the MCP tools.

  ## Roles are ASYMMETRIC, deliberately

  | operation                   | role           | why |
  |-----------------------------|----------------|-----|
  | `GET  /egress/posture`      | `:agent`       | verify-before-harvest must work with the key an agent already has |
  | `POST /egress/repin`        | `:agent`       | `:pin_stale` recovery must not need a human — but ONLY for a host the tenant already uses (see `repin/2`) |
  | `POST /egress/local-only`   | `:orchestrator`| TIGHTENING is safe to automate |
  | `DELETE /egress/local-only` | `:user`        | CLEARING is the self-widening move an agent must never make |
  | `POST /egress/trusted-endpoints`   | `:user` | a declaration changes the locality verdict |
  | `DELETE /egress/trusted-endpoints` | `:user` | ditto |

  Clearing `local_only` at anything below `:user` would let an agent re-open
  egress one tool call before a harvest while US-41.7's witnessed claim
  faithfully attested the weakened posture.

  There is NO route that mutates the deployment allowlist, at any role including
  `:user`: it is the trust root and it is operator-plane, not tenant, state.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Egress
  alias Loopctl.Egress.Policy
  alias Loopctl.Egress.Scope
  alias Loopctl.Egress.TrustedEndpoint
  alias Loopctl.Projects

  action_fallback LoopctlWeb.FallbackController

  tags(["Egress"])

  @json "application/json"
  @free_object %OpenApiSpex.Schema{type: :object, additionalProperties: true}

  operation(:posture,
    summary: "Egress posture",
    description:
      "Resolved embedding + chat endpoints with a locality VERDICT for each, the tenant's " <>
        "declared trusted endpoints (labelled 'tenant-declared (unverified attestation), " <>
        "not network-local'), per-scope local_only/encrypt_body, and named posture defects. " <>
        "Endpoints are shown; KEYS NEVER ARE. Deployment-allowlist CONTENTS appear only at " <>
        "role :user+ — at :agent each endpoint carries only a boolean saying whether the " <>
        "verdict came from the allowlist. Role :agent.",
    responses: %{
      200 => {"Egress posture", @json, @free_object},
      401 => {"Unauthorized", @json, Schemas.ErrorResponse}
    }
  )

  operation(:enable_local_only,
    summary: "Enable local_only for a scope",
    description:
      "TIGHTENS the posture (role :orchestrator+). Runs the MANDATORY PRE-FLIGHT: if any " <>
        "currently-resolved endpoint would become egress_blocked, responds 409 " <>
        "would_block_endpoints NAMING each offending endpoint; retry with acknowledge=true " <>
        "to proceed, and the response then REPORTS the resulting blocked posture.",
    request_body: {"local_only enable request", @json, @free_object},
    responses: %{
      200 => {"local_only enabled", @json, @free_object},
      403 => {"Insufficient role", @json, Schemas.ErrorResponse},
      409 => {"Would block resolved endpoints", @json, Schemas.ErrorResponse}
    }
  )

  operation(:clear_local_only,
    summary: "Clear local_only for a scope",
    description:
      "WIDENS the posture, so it is role :user ONLY — an agent or orchestrator key must " <>
        "never be able to re-open egress one tool call before a harvest. Audited.",
    parameters: [
      project_id: [in: :query, type: :string, required: false, description: "Project UUID"]
    ],
    responses: %{
      200 => {"local_only cleared", @json, @free_object},
      403 => {"Insufficient role", @json, Schemas.ErrorResponse}
    }
  )

  operation(:list_trusted,
    summary: "List tenant-declared trusted endpoints",
    description:
      "Role :agent. Every entry is labelled 'tenant-declared (unverified attestation), not " <>
        "network-local' — loopctl does not prove the declaring tenant owns the host.",
    responses: %{200 => {"Declared endpoints", @json, @free_object}}
  )

  operation(:declare_trusted,
    summary: "Declare a tenant-trusted endpoint",
    description:
      "Role :user ONLY. PUBLIC addresses only (enforced at write time AND again at pin " <>
        "time), purpose-scoped (inference, webhook and/or ingest), vendor hosts excluded. A " <>
        "declaration carves NOTHING out of the SSRF denylist — only the operator " <>
        "deployment allowlist can do that, and it has no route at any role.",
    request_body: {"Trusted endpoint declaration", @json, @free_object},
    responses: %{
      201 => {"Endpoint declared", @json, @free_object},
      403 => {"Insufficient role", @json, Schemas.ErrorResponse},
      422 => {"Rejected declaration", @json, Schemas.ErrorResponse}
    }
  )

  operation(:revoke_trusted,
    summary: "Revoke a tenant-declared trusted endpoint",
    description: "Role :user ONLY. Invalidates the pin cache immediately.",
    parameters: [
      host: [in: :path, type: :string, required: true, description: "Declared host"]
    ],
    responses: %{
      200 => {"Endpoint revoked", @json, @free_object},
      403 => {"Insufficient role", @json, Schemas.ErrorResponse},
      404 => {"Not found", @json, Schemas.ErrorResponse}
    }
  )

  operation(:repin,
    summary: "Re-pin a host after a :pin_stale refusal",
    description:
      "Role :agent. The :pin_stale remediation — target deployments change IP routinely, " <>
        "so recovery must NOT require a role :user write. The host must be one the tenant " <>
        "actually uses: a currently-resolved endpoint for the scope, or one of the tenant's " <>
        "declared trusted endpoints (both readable at :agent via GET /egress/posture). An " <>
        "arbitrary host is refused with 422 host_not_repinnable — returning a locality " <>
        "verdict for any host would be a deployment-allowlist / internal-DNS membership " <>
        "oracle at the lowest-privileged role.",
    request_body: {"Repin request", @json, @free_object},
    responses: %{
      200 => {"Re-pinned", @json, @free_object},
      422 => {"Repin failed or host not repinnable", @json, Schemas.ErrorResponse}
    }
  )

  # TIGHTENING the posture is safe to automate.
  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:enable_local_only]

  # WIDENING the posture — and every write that changes a locality verdict — is a
  # human-key operation.
  plug LoopctlWeb.Plugs.RequireRole,
       [role: :user] when action in [:clear_local_only, :declare_trusted, :revoke_trusted]

  @doc """
  GET /api/v1/egress/posture — role `:agent`.

  Reports the resolved embedding + chat endpoints, each one's locality VERDICT,
  the tenant's declared endpoints with purposes, per-scope `local_only` /
  `encrypt_body`, and any named posture defects. Endpoints are shown; KEYS NEVER
  ARE. The deployment allowlist CONTENTS appear only at `:user`+ — at `:agent`
  the payload carries only a boolean per endpoint saying whether the verdict came
  from the allowlist.
  """
  def posture(conn, _params) do
    key = conn.assigns.current_api_key
    json(conn, Egress.posture(key.tenant_id, key.role))
  end

  @doc """
  POST /api/v1/egress/local-only — role `:orchestrator`+.

  Body: `{"project_id": "<uuid>"|null, "acknowledge": bool}`.

  Runs the MANDATORY PRE-FLIGHT: if any currently-resolved endpoint would become
  `egress_blocked`, responds `409 would_block_endpoints` NAMING each offending
  endpoint. Retry with `"acknowledge": true` to proceed; the response then
  REPORTS the resulting blocked posture. Never a silent tenant-wide outage.
  """
  def enable_local_only(conn, params) do
    key = conn.assigns.current_api_key

    opts = Keyword.put(actor_opts(conn), :acknowledge, params["acknowledge"] == true)

    with {:ok, project_id} <- tenant_project_id(key.tenant_id, params["project_id"]) do
      do_enable_local_only(conn, key, project_id, params, opts)
    end
  end

  defp do_enable_local_only(conn, key, project_id, params, opts) do
    case Egress.enable_local_only(key.tenant_id, project_id, opts) do
      {:ok, %{blocked_endpoints: blocked}} ->
        json(conn, %{
          local_only: true,
          scope: scope_label(params["project_id"]),
          blocked_endpoints: blocked,
          acknowledged: params["acknowledge"] == true,
          note: blocked_note(blocked)
        })

      {:error, {:would_block, blocked}} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "would_block_endpoints",
          message:
            "Enabling local_only on this scope would immediately block " <>
              "#{length(blocked)} currently-resolved endpoint(s). Configure a " <>
              "satisfying endpoint AT TENANT level (role :user), declare a trusted " <>
              "endpoint (role :user), or retry with acknowledge=true to accept the " <>
              "resulting blocked posture.",
          blocked_endpoints: blocked
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  DELETE /api/v1/egress/local-only — role `:user` ONLY.

  Body/query: `project_id` (optional). Audited.
  """
  def clear_local_only(conn, params) do
    key = conn.assigns.current_api_key

    with {:ok, project_id} <- tenant_project_id(key.tenant_id, params["project_id"]),
         {:ok, :cleared} <-
           Egress.clear_local_only(key.tenant_id, project_id, actor_opts(conn)) do
      json(conn, %{local_only: false, scope: scope_label(project_id)})
    end
  end

  @doc "GET /api/v1/egress/trusted-endpoints — role `:agent`."
  def list_trusted(conn, _params) do
    key = conn.assigns.current_api_key

    json(conn, %{
      data: Enum.map(Egress.list_trusted_endpoints(key.tenant_id), &endpoint_view/1),
      locality_label: Egress.tenant_declared_label()
    })
  end

  @doc """
  POST /api/v1/egress/trusted-endpoints — role `:user` ONLY.

  Body: `{"host": "ollama.example.com", "purposes": ["inference"]}`.

  Public addresses ONLY (validated at write time AND again at pin time),
  purpose-scoped, vendor hosts excluded. The declaration is an UNVERIFIED TENANT
  ATTESTATION and is never presented as network-local.
  """
  def declare_trusted(conn, params) do
    key = conn.assigns.current_api_key
    attrs = Map.take(params, ["host", "purposes", "note"])

    with {:ok, endpoint} <-
           Egress.declare_trusted_endpoint(key.tenant_id, attrs, actor_opts(conn)) do
      conn
      |> put_status(:created)
      |> json(endpoint_view(endpoint))
    end
  end

  @doc "DELETE /api/v1/egress/trusted-endpoints/:host — role `:user` ONLY. Invalidates immediately."
  def revoke_trusted(conn, %{"host" => host}) do
    key = conn.assigns.current_api_key

    case Egress.revoke_trusted_endpoint(key.tenant_id, host, actor_opts(conn)) do
      # Echo the CANONICAL stored form, not a bare downcase — otherwise the
      # response names a host that is not the one that was deleted.
      {:ok, :revoked} -> json(conn, %{revoked: true, host: TrustedEndpoint.normalize_host(host)})
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/egress/repin — role `:agent`.

  The `:pin_stale` remediation. Target deployments (home Ollama box, tailscale
  funnel, DHCP VPS) change IP routinely, so recovery must NOT require a human
  `:user` write — that would contradict the epic's agent-native, no-UI design.
  """
  def repin(conn, %{"host" => host} = params) when is_binary(host) do
    key = conn.assigns.current_api_key

    with {:ok, project_id} <- tenant_project_id(key.tenant_id, params["project_id"]) do
      scope = Scope.new(key.tenant_id, project_id)
      do_repin(conn, scope, TrustedEndpoint.normalize_host(host))
    end
  end

  # A non-string `host` (`{"host": 123}`) must be a clean 422, not a
  # FunctionClauseError 500 — every other body-sourced param on this controller is
  # guarded the same way.
  def repin(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_host",
      message: "\"host\" is required and must be a string naming an endpoint this tenant uses."
    })
  end

  # AC-41.4.8 withholds the deployment-allowlist CONTENTS from role `:agent`, and
  # `Egress.posture/2` gates them behind `:user` for exactly that reason. An
  # ARBITRARY-host repin re-opens that one guess at a time: the verdict is a 3-way
  # membership oracle (`network_local` = in the OPERATOR allowlist, `denylisted` =
  # resolves into private/CGNAT/link-local/6PN space, otherwise public), and it also
  # forces server-side DNS resolution of caller-chosen names (an existing internal
  # name 200s, a nonexistent one 422s) while inserting each probed host into the
  # pin table the refresher then maintains.
  #
  # So the host must be one the CALLER already knows about: a currently-resolved
  # endpoint for the scope, or one of the tenant's own declarations. Both sets are
  # already readable at `:agent` via `GET /egress/posture`, so nothing new is
  # disclosed, and the `:pin_stale` remediation — the whole point of this route —
  # still needs no human `:user` write.
  defp do_repin(conn, scope, host) do
    if repinnable_host?(scope, host) do
      repin_known_host(conn, scope, host)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{
        error: "host_not_repinnable",
        message:
          "Only an endpoint this tenant actually uses can be re-pinned: one of the " <>
            "scope's resolved endpoints or one of the tenant's declared trusted " <>
            "endpoints (see GET /api/v1/egress/posture). Re-pinning is not a lookup " <>
            "service for arbitrary hosts."
      })
    end
  end

  defp repinnable_host?(scope, host) do
    resolved =
      scope
      |> Egress.resolved_endpoints()
      |> Enum.map(fn {_kind, url} -> URI.parse(url).host || url end)

    declared = Enum.map(Egress.list_trusted_endpoints(scope.tenant_id), & &1.host)

    host in resolved or host in declared
  end

  defp repin_known_host(conn, scope, host) do
    case Policy.repin(scope, host, :inference) do
      {:ok, classification} ->
        json(conn, %{host: host, repinned: true, verdict: to_string(classification.verdict)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "repin_failed", message: inspect(reason)})
    end
  end

  # `project_id` arrives in the REQUEST BODY, so it must be resolved against the
  # CALLER's tenant before it is written or scoped on. Without this:
  #
  #   * tenant A could persist a marking row whose `project_id` FK points at tenant
  #     B's project (the migration's FK has no tenant component), leaving
  #     cross-tenant referential state in a table US-41.7's custody claim later
  #     serializes;
  #   * a valid FOREIGN project UUID would 200 while a nonexistent one 422'd on the
  #     FK — a cross-tenant existence oracle, in a codebase whose router guarantees
  #     byte-identical responses elsewhere for exactly this reason;
  #   * a non-UUID would raise `Ecto.Query.CastError` deep in `get_marking/2` and
  #     surface as a 500 rather than a 422.
  #
  # Foreign, nonexistent and malformed all return the SAME 404, so the response
  # discloses nothing about another tenant's projects.
  defp tenant_project_id(_tenant_id, nil), do: {:ok, nil}
  defp tenant_project_id(_tenant_id, ""), do: {:ok, nil}

  defp tenant_project_id(tenant_id, project_id) when is_binary(project_id) do
    # `Projects.get_project/2` is the shared chokepoint: it guards the UUID cast
    # (malformed → `:not_found`, never a 500) AND scopes by tenant_id, so a foreign
    # project is indistinguishable from a nonexistent one — a 404 either way.
    with {:ok, project} <- Projects.get_project(tenant_id, project_id) do
      {:ok, project.id}
    end
  end

  defp tenant_project_id(_tenant_id, _other), do: {:error, :not_found}

  defp endpoint_view(%TrustedEndpoint{} = endpoint) do
    %{
      id: endpoint.id,
      host: endpoint.host,
      purposes: endpoint.purposes,
      note: endpoint.note,
      # Verbatim by contract: never present a declaration as network-local.
      locality_label: Egress.tenant_declared_label(),
      declared_at: endpoint.inserted_at
    }
  end

  defp blocked_note([]), do: "No currently-resolved endpoint became blocked."

  defp blocked_note(blocked) do
    "local_only is ACTIVE and #{length(blocked)} resolved endpoint(s) are now " <>
      "egress_blocked. Embedding, extraction, classification and merge for this scope " <>
      "will be refused until a local or tenant-declared endpoint is configured at " <>
      "TENANT level (role :user), or the marking is cleared (role :user)."
  end

  defp scope_label(nil), do: "tenant"
  defp scope_label(project_id), do: "project:#{project_id}"

  defp actor_opts(conn) do
    key = conn.assigns.current_api_key
    [actor_type: "api_key", actor_id: key.id, actor_label: "#{key.role}:#{key.name}"]
  end
end
