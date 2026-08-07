defmodule LoopctlWeb.CapabilityController do
  @moduledoc """
  Delivers capability tokens already issued to the caller's dispatch lineage.

  Issue #621: the L1 capability layer minted tokens at every custody transition
  but no client-facing path ever handed them over, so each keyed tenant's next
  lifecycle call failed with `403 missing_capability`. The `start_cap` now rides
  the `claim` response; this endpoint is the RECOVERY path for a client that lost
  that response to a crash or a network timeout, which otherwise left the story
  stuck in `assigned` with no way forward.

  Security:

    * This is DELIVERY, never minting. It returns only tokens already minted for
      the caller's own lineage, resolved SERVER-SIDE from the authenticating key
      (`Dispatches.lineage_for_api_key/2`); a client-supplied lineage is never
      read. Compare `CapRecoveryController`, which DOES mint and is therefore
      restricted to `start_cap`.
    * The token still has to survive `Capabilities.verify/2` at consume time —
      exact lineage match, story match, type match, expiry, single-use, and an
      ed25519 signature. Listing a token is not authorization to use it.
    * A caller whose key was not minted by a dispatch has lineage `[]`, which
      every OTHER legacy key in the tenant also resolves to — so lineage cannot
      discriminate and `Capabilities.list_for_lineage/3` fails closed on it.
      Such a caller is served by ASSIGNMENT instead
      (`Capabilities.list_for_assigned_agent/3`), and only on an `:agent`-role key:
      the principal the token was minted for is the only one that may collect it,
      the same line `CapRecoveryController` draws for the mint path beside this one.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Capabilities
  alias Loopctl.Dispatches

  action_fallback LoopctlWeb.FallbackController

  # Both custody roles are admitted, matching the sibling custody endpoints:
  # hierarchy does NOT apply — a :user or :superadmin key is 403'd like any other
  # non-member. Admission is not access: the list is scoped to the caller.
  plug LoopctlWeb.Plugs.RequireRole, exact_role: [:agent, :orchestrator]

  # DELIBERATELY NOT behind RequireHumanAnchor, unlike its mutating siblings.
  # `TierCapabilities` advertises the tier gate as `applies_to: "mutating_actions"`
  # with reads open on every surface (tier_capabilities.ex:287), and this action is a
  # GET. Gating it would have made the advertised contract false for an agent-rooted
  # tenant — and bought nothing: such a tenant cannot claim a story, so it has no
  # capabilities to list and this returns an empty array either way. The scoping that
  # does the work here is the caller's own lineage, not the tenant's trust tier.

  tags(["Progress"])

  operation(:index,
    summary: "List capabilities issued to the caller for a story",
    description:
      "Returns the live (unconsumed, unexpired) capability tokens already issued to the " <>
        "CALLER for this story. Delivery only — this never mints. The start_cap rides the " <>
        "claim response, so this call is the recovery path when that response was lost. " <>
        "Scoped by the caller's dispatch lineage, resolved server-side; for a key not " <>
        "minted by a dispatch, scoped instead to the story's assigned agent.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"Capabilities", "application/json", Schemas.CapabilityListResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc "GET /api/v1/stories/:id/capabilities"
  def index(conn, %{"id" => raw_story_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    # story_id is client input: uncast, a non-UUID raises Ecto.Query.CastError.
    case Ecto.UUID.cast(raw_story_id) do
      {:ok, story_id} ->
        caps =
          case Dispatches.lineage_for_api_key(tenant_id, api_key.id) do
            [] -> assigned_agent_caps(tenant_id, story_id, api_key)
            lineage -> Capabilities.list_for_lineage(tenant_id, story_id, lineage)
          end

        json(conn, %{data: Enum.map(caps, &Capabilities.serialize/1)})

      :error ->
        {:error, :not_found}
    end
  end

  # ASSIGNMENT fallback, agent-role only — see the moduledoc.
  defp assigned_agent_caps(tenant_id, story_id, %{role: :agent} = api_key) do
    Capabilities.list_for_assigned_agent(tenant_id, story_id, api_key.agent_id)
  end

  defp assigned_agent_caps(_tenant_id, _story_id, _api_key), do: []
end
