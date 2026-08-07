defmodule LoopctlWeb.CapabilityController do
  @moduledoc """
  Delivers capability tokens already issued to the caller's dispatch lineage.

  Issue #621: the L1 capability layer minted tokens at every custody transition
  but no client-facing path ever handed them over, so each keyed tenant's next
  lifecycle call failed with `403 missing_capability`. `start_cap` and
  `report_cap` are now returned inline by the transitions that mint them
  (`claim` / `start`); this endpoint covers `verify_cap`, which cannot be
  returned inline because it is minted during REPORT, bound to the lineage of a
  verifier that loopctl selects — the report response belongs to the reporter,
  and handing the reporter a verify_cap would hand it self-verification.

  Security:

    * This is DELIVERY, never minting. It returns only tokens already minted for
      the caller's own lineage, resolved SERVER-SIDE from the authenticating key
      (`Dispatches.lineage_for_api_key/2`); a client-supplied lineage is never
      read. Compare `CapRecoveryController`, which DOES mint and is therefore
      restricted to `start_cap`.
    * The token still has to survive `Capabilities.verify/2` at consume time —
      exact lineage match, story match, type match, expiry, single-use, and an
      ed25519 signature. Listing a token is not authorization to use it.
    * A caller whose key was not minted by a dispatch has lineage `[]`, and
      `Capabilities.list_for_lineage/3` fails closed on `[]` rather than
      matching every other legacy caller's `[]`-bound tokens.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Capabilities
  alias Loopctl.Dispatches

  action_fallback LoopctlWeb.FallbackController

  # Both custody roles need this: `report` is exact_role [:agent, :orchestrator]
  # and `verify` is exact_role :orchestrator, so an orchestrator must be able to
  # collect a verify_cap. Matching the sibling custody endpoints, hierarchy does
  # NOT apply — a :user or :superadmin key is 403'd like any other non-member.
  plug LoopctlWeb.Plugs.RequireRole, exact_role: [:agent, :orchestrator]

  # US-26.7.1 — work-breakdown surface requires a human-anchored tenant.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:index]

  tags(["Progress"])

  operation(:index,
    summary: "List capabilities issued to the caller for a story",
    description:
      "Returns the live (unconsumed, unexpired) capability tokens already issued to the " <>
        "CALLER'S OWN dispatch lineage for this story. Delivery only — this never mints. " <>
        "Use it to collect a verify_cap, which is minted during report and bound to the " <>
        "verifier loopctl selected. start_cap and report_cap are returned inline by the " <>
        "claim and start responses and normally do not need this call. Returns an empty " <>
        "list for a key that was not minted by a dispatch.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"Capabilities", "application/json", Schemas.CapabilityListResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "GET /api/v1/stories/:id/capabilities"
  def index(conn, %{"id" => story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    lineage = Dispatches.lineage_for_api_key(tenant_id, api_key.id)

    caps =
      tenant_id
      |> Capabilities.list_for_lineage(story_id, lineage)
      |> Enum.map(&Capabilities.serialize/1)

    json(conn, %{data: caps})
  end
end
