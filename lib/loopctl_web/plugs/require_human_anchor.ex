defmodule LoopctlWeb.Plugs.RequireHumanAnchor do
  @moduledoc """
  US-26.7.1 — gates the work-breakdown / chain-of-custody surface behind the
  TENANT's `trust_tier`, deliberately orthogonal to role.

  A role-based gate would be trivially escaped by a tenant self-minting a
  higher-role key (`ApiKeyController.create` only blocks minting
  `superadmin`; a `role: :user` caller can mint an `orchestrator` key
  today). Keying on `current_tenant.trust_tier` instead closes that bypass:
  no key a tenant can mint for itself changes its own trust tier.

  ## Behavior

  - Superadmin with NO impersonation (`current_tenant: nil` — set by
    `LoopctlWeb.Plugs.SetTenant`'s identical pattern-match convention for a
    `tenant_id: nil` key) passes through unconditionally. This is a LEADING
    clause so it never falls through to a crash on a nil tenant.
  - `trust_tier: :human_anchored` passes through.
  - `trust_tier: :agent_rooted` halts with `403 custody_tier_required`.
  - No `current_tenant` assign at all (should not happen this late in the
    pipeline) is treated as NOT human-anchored — nil is never permissive.

  `LoopctlWeb.Plugs.Impersonate` reassigns `current_tenant` to the
  impersonated tenant BEFORE controller plugs run, so a superadmin
  impersonating an agent-rooted tenant is correctly routed through THAT
  tenant's tier (not exempted).

  ## Usage

  Applied per-controller, exactly like `RequireRole`, and composes with it
  (both plugs must pass):

      plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create, :update, :delete]

  ### `:alternative` (optional, #505)

  A mount MAY name the agent-native endpoint that covers the adjacent
  non-custody need, which is surfaced as `remediation.agent_native_alternative`
  in the 403 body:

      plug LoopctlWeb.Plugs.RequireHumanAnchor,
           [
             alternative: %{
               tool: "create_kb_scope",
               endpoint: "POST /api/v1/kb-scopes",
               description: "..."
             }
           ]
           when action in [:create]

  Only pass it where an alternative GENUINELY exists — an invented one is worse
  than none. Most custody endpoints have no substitute by design, and those
  mounts pass no opts.

  ## Discoverability (#505)

  The 403 was previously a dead end: it told the caller the surface was closed
  but not which surfaces were open, so an agent-rooted tenant could only map the
  boundary by taking a 403 per endpoint. The body now embeds
  `Loopctl.Tenants.TierCapabilities.for_tenant/1` — the SAME map advertised up front
  on `GET /api/v1/tenants/me` — so a caller can either read it before writing or
  recover from the 403 without a second round trip.

  This is discoverability only. The gate itself is unchanged: it is L0 of the
  trust model, and letting an agent-rooted tenant open a custody surface for
  itself is precisely the failure the product exists to prevent.
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.Tenants.TierCapabilities

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{current_tenant: nil}} = conn, _opts) do
    # Superadmin, not impersonating — ResolveApiKey assigns `current_tenant: nil`
    # for a tenant_id-nil (superadmin) key, mirroring SetTenant's identical
    # `tenant_id: nil` convention. No tenant to gate against.
    conn
  end

  def call(%{assigns: %{current_tenant: %{trust_tier: :human_anchored}}} = conn, _opts) do
    conn
  end

  def call(conn, opts) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{
      error: %{
        status: 403,
        code: "custody_tier_required",
        message:
          "This operation requires a human-anchored tenant (a WebAuthn signup ceremony). " <>
            "Your tenant is on the agent-rooted knowledge-base tier, which does not " <>
            "include the work-breakdown / chain-of-custody surface.",
        capabilities: capabilities(conn),
        remediation: remediation(opts)
      }
    })
    |> halt()
  end

  # A missing `current_tenant` assign should not happen this late in the pipeline,
  # but nil is never permissive — fall back to the most restrictive tier's map
  # rather than crashing or omitting the block.
  defp capabilities(conn) do
    case conn.assigns[:current_tenant] do
      %{trust_tier: tier} when tier in [:agent_rooted, :human_anchored] ->
        TierCapabilities.for_tier(tier)

      _ ->
        TierCapabilities.for_tier(:agent_rooted)
    end
  end

  defp remediation(opts) do
    base = TierCapabilities.remediation()

    case Keyword.get(opts || [], :alternative) do
      nil -> base
      alternative -> Map.put(base, :agent_native_alternative, alternative)
    end
  end
end
