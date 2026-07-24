defmodule Loopctl.Custody.SignedProfilePolicy do
  @moduledoc """
  Deployment-level activation of the LCP-1 §9 signed profile: reads the deployment
  profile and, when it is `signed`, requires and pre-verifies an agent claim
  signature for enrolled dispatches BEFORE a custody gate runs (§9.3).

  `Loopctl.Custody.SignedProfile` is the pure crypto core; this module is the
  impure orchestration that reads config, resolves the caller's dispatch
  server-side, and decides whether a signature is required and whether it verifies.

  ## Profile (config-driven, default `bearer`)

  Stored as the integer `SystemConfig` key `custody_signed_profile_enforcement`
  (0 = `bearer`, 1 = `signed`), mirroring the `hnsw_iterative_scan` toggle
  convention. Default 0 → every existing deployment is `bearer` and unchanged.

  ## Gradual rollout — enrolled dispatches only

  Under `signed`, a caller whose dispatch carries an `agent_pubkey` MUST present a
  valid claim signature; a caller with no enrolled key (a bearer dispatch, or a
  legacy env-var key with no dispatch) is NOT forced to sign. This lets a fleet
  migrate agent-by-agent: enroll a key, and that agent's claims immediately require
  a signature, without breaking un-migrated agents. A future stricter posture (all
  dispatches must be enrolled + signed) is an additional config value, not a change
  to this contract.

  ## What the claim binds (v1)

  The signature binds `gate + work_item_id + capability_id + claimed_at` over an
  EMPTY `body` (§9.3 preimage with `body = %{}`). This proves "agent X authorized a
  `<gate>` claim on work item Y with capability Z at time T" — the custody-critical
  identity/authorization binding. Signing the finding/artifact CONTENT is a
  forward-compatible extension (populate `body`); it is deliberately out of the
  first activation to keep the agent/server contract unambiguous.
  """

  require Logger

  alias Loopctl.Custody.SignedProfile
  alias Loopctl.Dispatches

  @profile_key "custody_signed_profile_enforcement"

  @doc "The active deployment custody profile (`:bearer` | `:signed`)."
  @spec profile() :: :bearer | :signed
  def profile do
    case config_get_int(@profile_key, 0) do
      0 -> :bearer
      _ -> :signed
    end
  end

  @doc "The profile as the wire string advertised in `/.well-known/loopctl` (§2.1)."
  @spec profile_string() :: String.t()
  def profile_string, do: Atom.to_string(profile())

  @doc """
  Verifies (or waives) the signed claim for a custody request, per the active
  profile. Returns `:ok` to proceed to the gate, or `{:error, reason}` to reject
  before the gate runs.

  `claim_params` is the caller-supplied `claim` object from the request body:
  `%{"alg" => ..., "claim_sig" => <hex>, "claimed_at" => <int>}` (string keys).

    * `:bearer` profile → always `:ok` (signatures ignored).
    * `:signed`, caller NOT enrolled → `:ok` (gradual rollout).
    * `:signed`, caller enrolled, no/blank signature → `{:error, :claim_signature_required}`.
    * `:signed`, caller enrolled, signature present → verifies it (§9.3); `:ok` or
      `{:error, :invalid_claim_signature}` / a decode/shape error.
  """
  @spec verify_request(
          :bearer | :signed,
          Ecto.UUID.t(),
          Ecto.UUID.t() | nil,
          String.t(),
          binary(),
          binary() | nil,
          map()
        ) :: :ok | {:error, atom()}
  # `profile` is passed in (the plug supplies `profile/0`) so the enforcement logic
  # is exercised in async tests without mutating VM-global config.
  def verify_request(:bearer, _tenant_id, _api_key_id, _gate, _work_item_id, _cap, _claim),
    do: :ok

  def verify_request(
        :signed,
        tenant_id,
        api_key_id,
        gate,
        work_item_id,
        capability_id,
        claim_params
      ) do
    case Dispatches.dispatch_for_api_key(tenant_id, api_key_id) do
      {:ok, %{agent_pubkey: pubkey} = dispatch} when is_binary(pubkey) ->
        verify_enrolled(tenant_id, dispatch, gate, work_item_id, capability_id, claim_params)

      _not_enrolled ->
        # No enrolled key: gradual-rollout waiver. A legacy/bearer caller is still
        # bounded by the role gate and the lineage self-* checks.
        :ok
    end
  end

  defp verify_enrolled(tenant_id, dispatch, gate, work_item_id, capability_id, claim_params) do
    with {:ok, alg} <- fetch_string(claim_params, "alg"),
         {:ok, sig_hex} <- fetch_string(claim_params, "claim_sig"),
         {:ok, claimed_at} <- fetch_int(claim_params, "claimed_at"),
         {:ok, signature} <- decode_hex(sig_hex) do
      SignedProfile.verify_claim(
        alg: alg,
        dispatch_alg: dispatch.alg,
        agent_pubkey: dispatch.agent_pubkey,
        tenant_id: tenant_id,
        gate: gate,
        work_item_id: work_item_id,
        body: %{},
        capability_id: capability_id,
        claimed_at: claimed_at,
        signature: signature
      )
      |> case do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "signed_profile: claim rejected — gate=#{gate} work_item=#{work_item_id} " <>
              "dispatch=#{dispatch.id} reason=#{reason}"
          )

          {:error, :invalid_claim_signature}
      end
    else
      _ -> {:error, :claim_signature_required}
    end
  end

  defp fetch_string(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> :error
    end
  end

  defp fetch_int(params, key) do
    case Map.get(params, key) do
      v when is_integer(v) -> {:ok, v}
      _ -> :error
    end
  end

  defp decode_hex(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, raw} -> {:ok, raw}
      :error -> :error
    end
  end

  # Injection seam so tests can drive the profile without a global VM mutation:
  # config/test.exs maps :custody_profile_source to a stub that returns the int.
  defp config_get_int(key, default) do
    case Application.get_env(:loopctl, :custody_profile_source) do
      nil -> Loopctl.SystemConfig.get_int(key, default)
      mod -> mod.get_int(key, default)
    end
  end
end
