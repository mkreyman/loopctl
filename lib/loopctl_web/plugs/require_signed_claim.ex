defmodule LoopctlWeb.Plugs.RequireSignedClaim do
  @moduledoc """
  LCP-1 §9.3 pre-gate check: when the deployment custody profile is `signed`,
  require and verify an agent claim signature for an enrolled caller BEFORE the
  custody gate runs. A no-op under the default `bearer` profile.

  Mounted per custody action with the gate name it guards:

      plug LoopctlWeb.Plugs.RequireSignedClaim, gate: "report" when action in [:report]

  The gate name is the plug's, not the client's — it binds the signature to the
  specific transition (a `report` signature cannot be replayed as a `verify`). All
  other identity/authorization inputs (`tenant_id`, `api_key_id`, and thus the
  enrolled `agent_pubkey`) are resolved server-side; only the signature, `alg`, and
  `claimed_at` come from the request `claim` object.

  A signature failure halts with **401** and a distinct code, NOT a custody 409:
  §9.3 requires signature failure and custody rejection to be different conditions
  (a client's recovery differs), so this never masquerades as `self_*_blocked`.
  """
  import Plug.Conn

  alias Loopctl.Custody.SignedProfilePolicy

  def init(opts) do
    gate = Keyword.fetch!(opts, :gate)
    unless gate in ["report", "review_complete", "verify"], do: raise("unknown custody gate")
    %{gate: gate}
  end

  def call(conn, %{gate: gate}) do
    tenant_id = conn.assigns[:current_api_key] && conn.assigns.current_api_key.tenant_id
    api_key_id = conn.assigns[:current_api_key] && conn.assigns.current_api_key.id
    work_item_id = conn.params["id"]
    capability_id = conn.params["capability"] || conn.params["cap_id"]
    claim_params = conn.params["claim"] || %{}

    case SignedProfilePolicy.verify_request(
           SignedProfilePolicy.profile(),
           tenant_id,
           api_key_id,
           gate,
           work_item_id,
           capability_id,
           claim_params
         ) do
      :ok ->
        conn

      {:error, code} ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{
          error: %{
            status: 401,
            code: Atom.to_string(code),
            message: message_for(code),
            remediation: %{learn_more: "https://loopctl.com/spec/LCP-1"}
          }
        })
        |> halt()
    end
  end

  defp message_for(:claim_signature_required),
    do:
      "This deployment runs the LCP-1 signed custody profile and your dispatch is " <>
        "enrolled with an agent key, so this custody claim MUST carry a valid claim " <>
        "signature. Sign the claim (LCP-1 §9.3) and resend it in the `claim` object."

  defp message_for(:invalid_claim_signature),
    do:
      "The claim signature did not verify against your dispatch's enrolled agent " <>
        "key (LCP-1 §9.3). Re-sign the exact gate/work-item/capability/claimed_at."
end
