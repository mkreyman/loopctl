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

  # Bounded freshness window for a signed claim's agent-controlled `claimed_at`
  # (§9.3 delegates timeliness to the caller). A valid signature binds `claimed_at`,
  # so enforcing it against the server clock stops a captured claim signature from
  # being replayed indefinitely. Generous enough to absorb ordinary clock skew and
  # in-flight latency.
  @claim_max_age_seconds 300
  @claim_max_future_skew_seconds 60

  @doc "The active deployment custody profile (`:bearer` | `:signed`)."
  @spec profile() :: :bearer | :signed
  def profile do
    case config_get_int(@profile_key, 0) do
      0 ->
        :bearer

      1 ->
        :signed

      other ->
        # Fail SAFE to bearer, but never SILENTLY: an unrecognized value most likely
        # means an operator who intended `signed` misconfigured the key, and would
        # otherwise have signed-claim enforcement waived with no signal. Surface it.
        Logger.warning(
          "custody_signed_profile_enforcement=#{inspect(other)} is not a recognized value " <>
            "(0=bearer, 1=signed); defaulting to bearer — signed-claim enforcement is OFF."
        )

        :bearer
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
    * `:signed`, caller enrolled, signature present but the claim object is malformed
      (bad `alg`/`claimed_at` type, undecodable `claim_sig`) → `{:error, :malformed_claim}`.
    * `:signed`, caller enrolled, signature verifies but `claimed_at` is outside the
      freshness window → `{:error, :claim_expired}`.
    * `:signed`, caller enrolled, signature verifies but the attestation's §9.2
      condition (`gate=`/`expires<`) is unmet → `{:error, :claim_condition_unmet}`.
    * `:signed`, caller enrolled, signature present and well-formed → verifies it
      (§9.3); `:ok` or `{:error, :invalid_claim_signature}`.
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
        # No enrolled key: the enrolled-only gradual-rollout waiver. A legacy/bearer
        # caller is NOT forced to sign — it stays bounded by the role gate and the
        # lineage self-* custody checks, but its claims are NOT cryptographically
        # attributable. For un-enrolled work the §9.1.1 transparency layer is the
        # only guarantee (DETECTION, not prevention). Tightening this to "every
        # dispatch must be enrolled + signed" is a future, stricter config value —
        # an ADDITIVE posture, not a change to this contract (see the moduledoc).
        :ok
    end
  end

  defp verify_enrolled(tenant_id, dispatch, gate, work_item_id, capability_id, claim_params) do
    # `require_sig/1` distinguishes "no signature" (`:claim_signature_required`) from
    # "signature present but the claim object is malformed" (`:malformed_claim`), per
    # §9.3 — a client's recovery differs (send a signature vs fix the claim shape). A
    # bare `with` returns the first non-matching `{:error, _}`, so no catch-all else.
    with {:ok, sig_hex} <- require_sig(claim_params),
         {:ok, alg} <- require_present(claim_params, "alg"),
         {:ok, claimed_at} <- require_int(claim_params, "claimed_at"),
         {:ok, signature} <- decode_sig(sig_hex),
         :ok <-
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
           |> normalize_verify_result(gate, work_item_id, dispatch),
         :ok <- check_claim_fresh(claimed_at, gate, work_item_id, dispatch) do
      # Last step is the with's value (`:ok` or `{:error, :claim_condition_unmet}`).
      check_attestation_conditions(dispatch, gate)
    end
  end

  # The signature proves authorship of the claim (including the signed `claimed_at`),
  # but §9.3 delegates timeliness to the caller. Bound it against the server clock so
  # a captured valid claim signature is not indefinitely replayable.
  defp check_claim_fresh(claimed_at, gate, work_item_id, dispatch) do
    now = System.os_time(:second)

    cond do
      claimed_at < now - @claim_max_age_seconds ->
        log_reject(gate, work_item_id, dispatch, "claimed_at too old (#{claimed_at})")
        {:error, :claim_expired}

      claimed_at > now + @claim_max_future_skew_seconds ->
        log_reject(gate, work_item_id, dispatch, "claimed_at in the future (#{claimed_at})")
        {:error, :claim_expired}

      true ->
        :ok
    end
  end

  # Enforce the verified attestation's §9.2 conditions (`gate=<name>` / `expires<ts>`)
  # at claim time. Without this an owner attestation scoped to `gate=report` would be
  # accepted for a `verify` claim, and one carrying `expires<T>` accepted after `T`.
  # `conditions_met?/3` fails CLOSED on an unparseable clause.
  defp check_attestation_conditions(dispatch, gate) do
    conditions = dispatch.attestation_conditions || ""
    now = System.os_time(:second)

    case SignedProfile.conditions_met?(conditions, gate, now) do
      :ok ->
        :ok

      {:error, :condition_unmet} ->
        log_reject(gate, nil, dispatch, "attestation condition unmet (#{inspect(conditions)})")
        {:error, :claim_condition_unmet}
    end
  end

  defp normalize_verify_result(:ok, _gate, _work_item_id, _dispatch), do: :ok

  defp normalize_verify_result({:error, reason}, gate, work_item_id, dispatch) do
    log_reject(gate, work_item_id, dispatch, "signature #{reason}")
    {:error, :invalid_claim_signature}
  end

  defp log_reject(gate, work_item_id, dispatch, detail) do
    Logger.warning(
      "signed_profile: claim rejected — gate=#{gate} work_item=#{work_item_id} " <>
        "dispatch=#{dispatch.id} — #{detail}"
    )
  end

  # A blank/absent claim signature is the "not signed" condition.
  defp require_sig(params) do
    case Map.get(params, "claim_sig") do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, :claim_signature_required}
    end
  end

  # A present-but-wrong-shape field (given a signature WAS supplied) is malformed,
  # not "signature required".
  defp require_present(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, :malformed_claim}
    end
  end

  defp require_int(params, key) do
    case Map.get(params, key) do
      v when is_integer(v) -> {:ok, v}
      _ -> {:error, :malformed_claim}
    end
  end

  defp decode_sig(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :malformed_claim}
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
