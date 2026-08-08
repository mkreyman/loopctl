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
    %{gate: gate, bulk: Keyword.get(opts, :bulk, false)}
  end

  # Bulk/aggregate custody actions (bulk verify, epic verify-all, mark-complete)
  # cannot carry a per-item claim signature, so under the `signed` profile an
  # enrolled caller is refused here rather than silently waived — closing the
  # bypass where an enrolled verifier signs one story but verifies a whole set
  # unsigned (LCP-1 §9.3).
  def call(conn, %{bulk: true}) do
    tenant_id = conn.assigns[:current_api_key] && conn.assigns.current_api_key.tenant_id
    api_key_id = conn.assigns[:current_api_key] && conn.assigns.current_api_key.id

    case SignedProfilePolicy.verify_bulk_request(
           SignedProfilePolicy.profile(),
           tenant_id,
           api_key_id
         ) do
      :ok -> conn
      {:error, code} -> reject(conn, code)
    end
  end

  def call(conn, %{gate: gate}) do
    tenant_id = conn.assigns[:current_api_key] && conn.assigns.current_api_key.tenant_id
    api_key_id = conn.assigns[:current_api_key] && conn.assigns.current_api_key.id
    work_item_id = conn.params["id"]
    capability_id = conn.params["capability"] || conn.params["cap_id"]
    # A non-map `claim` (a stray string/list) must yield the plug's own
    # malformed/required rejection, never a BadMapError 500 downstream.
    claim_params =
      case conn.params["claim"] do
        %{} = c -> c
        _ -> %{}
      end

    profile = SignedProfilePolicy.profile()

    case SignedProfilePolicy.verify_request(
           profile,
           tenant_id,
           api_key_id,
           gate,
           work_item_id,
           capability_id,
           claim_params
         ) do
      {:ok, dispatch} ->
        # On the verified signed path, stash the claim so the custody controller can
        # persist it in the gate's HASH-CHAINED audit entry (LCP-1 §9.4). Without this
        # durable cryptographic residue the verified signature evaporates at request
        # end and a malicious operator could fabricate an "agent-signed" record.
        # `verify_request/7` already resolved and returned the enrolled dispatch
        # (`nil` on a waived path), so we reuse it instead of re-querying.
        stash_verified_claim(conn, profile, gate, dispatch, claim_params)

      {:error, code} ->
        reject(conn, code)
    end
  end

  # Only stash when a signature was actually VERIFIED — i.e. signed profile AND the
  # caller is enrolled (a non-nil resolved dispatch carrying a pubkey) AND a
  # claim_sig is present. The waived bearer/legacy path returns `{:ok, nil}`, with
  # nothing to record.
  defp stash_verified_claim(
         conn,
         :signed,
         gate,
         %{agent_pubkey: pk, alg: alg},
         %{"claim_sig" => sig} = claim
       )
       when is_binary(pk) and is_binary(sig) do
    Plug.Conn.assign(conn, :custody_signed_claim, %{
      gate: gate,
      agent_pubkey_hex: Base.encode16(pk, case: :lower),
      alg: alg,
      claim_sig: String.downcase(sig),
      claimed_at: claim["claimed_at"]
    })
  end

  defp stash_verified_claim(conn, _profile, _gate, _dispatch, _claim), do: conn

  defp reject(conn, code) do
    {plug_status, http_status} = status_for(code)

    conn
    |> put_status(plug_status)
    |> Phoenix.Controller.json(%{
      error: %{
        status: http_status,
        code: Atom.to_string(code),
        message: message_for(code),
        remediation: %{learn_more: "https://loopctl.com/spec/LCP-1"}
      }
    })
    |> halt()
  end

  # A signature/auth failure is 401. A custody-SEPARATION failure — the signing key
  # is the implementer's own key — is a 403: the caller authenticated fine, but this
  # key may not verify this work.
  defp status_for(:self_signed_claim), do: {:forbidden, 403}
  defp status_for(:agent_enrollment_required), do: {:forbidden, 403}
  defp status_for(_), do: {:unauthorized, 401}

  defp message_for(:claim_signature_required),
    do:
      "This deployment runs the LCP-1 signed custody profile and your dispatch is " <>
        "enrolled with an agent key, so this custody claim MUST carry a valid claim " <>
        "signature. Sign the claim (LCP-1 §9.3) and resend it in the `claim` object."

  defp message_for(:invalid_claim_signature),
    do:
      "The claim signature did not verify against your dispatch's enrolled agent " <>
        "key (LCP-1 §9.3). Re-sign the exact gate/work-item/capability/claimed_at."

  # §9.3 keeps "no signature" and "signature present but the claim is malformed"
  # distinct so the client's recovery differs: fix the claim SHAPE, do not (re)sign.
  defp message_for(:malformed_claim),
    do:
      "Your `claim` object is present but malformed (LCP-1 §9.3): `alg` must be a " <>
        "non-empty string, `claimed_at` an integer (Unix seconds), and `claim_sig` " <>
        "lowercase/mixed-case hex. Fix the claim shape and resend — do not re-sign."

  defp message_for(:claim_expired),
    do:
      "The claim's `claimed_at` is outside the accepted freshness window (LCP-1 §9.3). " <>
        "Re-sign the claim with a current timestamp and resend it."

  defp message_for(:claim_condition_unmet),
    do:
      "Your dispatch's owner/parent attestation does not authorize this claim: a " <>
        "§9.2 condition (`gate=<name>` or `expires<ts>`) is unmet. Use a dispatch " <>
        "whose attestation covers this gate and is unexpired."

  defp message_for(:agent_enrollment_required),
    do:
      "This agent has an enrolled signing key (LCP-1 §9), but you are calling on a " <>
        "BEARER dispatch that carries none. Use the agent's ENROLLED dispatch (which can " <>
        "sign the claim); an unsigned bearer dispatch may not act in an enrolled agent's " <>
        "name. On a BULK/aggregate custody action the enrolled dispatch is refused too " <>
        "(`bulk_signature_unsupported` — no per-item signature is possible), so there the " <>
        "terminal remedy is to verify each story individually on the single-story signed path."

  defp message_for(:self_signed_claim),
    do:
      "The key signing this claim is the SAME key that implemented the work (LCP-1 " <>
        "custody separation). An independent verifier — a different enrolled key — " <>
        "must sign the verify/review claim; you cannot verify your own implementation."

  defp message_for(:bulk_signature_unsupported),
    do:
      "This deployment runs the LCP-1 signed custody profile and your dispatch is " <>
        "enrolled with an agent key. Bulk/aggregate custody actions cannot carry the " <>
        "per-item claim signature §9.3 requires for each work item, so an enrolled " <>
        "caller must verify each story individually via the single-story signed path."
end
