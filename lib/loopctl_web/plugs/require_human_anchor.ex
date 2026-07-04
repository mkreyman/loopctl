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
  """

  @behaviour Plug

  import Plug.Conn

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

  def call(conn, _opts) do
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
        remediation: %{
          learn_more: "https://loopctl.com/wiki/chain-of-custody",
          enrollment_upgrade: "https://loopctl.com/wiki/tenant-signup"
        }
      }
    })
    |> halt()
  end
end
