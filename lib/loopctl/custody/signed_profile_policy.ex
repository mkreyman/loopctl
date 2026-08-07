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
  `<gate>` claim on work item Y at time T" — the custody-critical
  identity/authorization binding. Signing the finding/artifact CONTENT is a
  forward-compatible extension (populate `body`); it is deliberately out of the
  first activation to keep the agent/server contract unambiguous.

  `capability_id` is bound INTO the preimage when the caller supplies a
  `capability`/`cap_id` param, so a signature over one capability cannot be
  presented for another. But the v1 custody gates (`report`/`review_complete`/
  `verify`) do NOT themselves consume a separate capability token, so in practice
  the field is usually absent and its binding is forward-compatible rather than
  load-bearing today — do not read the v1 claim as proving "capability Z was
  exercised".

  ## Replay window (by design, §9.3)

  A signed claim is verified STATELESSLY: there is no server-issued nonce and no
  single-use consumption record. A captured, still-valid claim signature over the
  same `gate + work_item_id + capability_id + claimed_at` is therefore accepted
  repeatedly until its `claimed_at` leaves the 300-second freshness window
  (`@claim_max_age_seconds`, `check_claim_fresh/4`). This is deliberate: §9.3 delegates
  timeliness to the caller and a claim proves AUTHORSHIP, not one-time execution.
  Practical impact is bounded by the custody STATE MACHINE — `report`/
  `review_complete`/`verify` are one-way transitions, so a replayed claim on an
  already-transitioned work item is rejected (409) by the gate regardless. Binding
  and consuming a per-claim server nonce is a future, additive tightening, not a
  change to this contract. Capability tokens (`Loopctl.Capabilities`) remain the
  one-time-use primitive when a gate genuinely needs single-use semantics.
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Custody.SignedProfile
  alias Loopctl.Dispatches
  alias Loopctl.WorkBreakdown.Story

  @profile_key "custody_signed_profile_enforcement"

  @doc "The `SystemConfig` integer key backing `profile/0` (0=bearer, 1=signed)."
  @spec profile_key() :: String.t()
  def profile_key, do: @profile_key

  # Bounded freshness window for a signed claim's agent-controlled `claimed_at`
  # (§9.3 delegates timeliness to the caller). A valid signature binds `claimed_at`,
  # so enforcing it against the server clock stops a captured claim signature from
  # being replayed indefinitely. Generous enough to absorb ordinary clock skew and
  # in-flight latency.
  @claim_max_age_seconds 300
  @claim_max_future_skew_seconds 60

  # Sentinel default for the config read: `SystemConfig.get_int/2` cannot report a
  # miss, and 0 is ALSO the legitimate `bearer` value — so reading with a default of
  # 0 makes "an operator deliberately chose bearer" and "the key is not set at all"
  # the same observation. A value outside the valid domain separates them.
  @profile_unset -1

  @doc """
  The active deployment custody profile (`:bearer` | `:signed`).

  Emits `[:loopctl, :custody, :profile_resolved]` on EVERY resolution, with the
  resolved `profile`, the `source` (`:unset` | `:configured` | `:invalid`) and the
  `raw` config value. Only the `:invalid` branch used to make any noise, so the
  most likely real-world drift — a deployment intended to run `signed` whose config
  row never landed, silently serving `bearer` — produced no signal whatsoever and
  looked exactly like a healthy bearer deployment. Alert on
  `source: :unset`/`profile: :bearer` where `signed` is expected.
  """
  @spec profile() :: :bearer | :signed
  def profile do
    raw = config_get_int(@profile_key, @profile_unset)

    {profile, source} =
      case raw do
        @profile_unset ->
          {:bearer, :unset}

        0 ->
          {:bearer, :configured}

        1 ->
          {:signed, :configured}

        other ->
          # Fail SAFE to bearer, but never SILENTLY: an unrecognized value most likely
          # means an operator who intended `signed` misconfigured the key, and would
          # otherwise have signed-claim enforcement waived with no signal. Surface it.
          Logger.warning(
            "custody_signed_profile_enforcement=#{inspect(other)} is not a recognized value " <>
              "(0=bearer, 1=signed); defaulting to bearer — signed-claim enforcement is OFF."
          )

          {:bearer, :invalid}
      end

    :telemetry.execute(
      [:loopctl, :custody, :profile_resolved],
      %{count: 1},
      %{profile: profile, source: source, raw: raw}
    )

    profile
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

  On success the resolved enrolled dispatch is returned (`{:ok, dispatch}`) so the
  caller can persist the verified claim WITHOUT re-querying it; waived paths
  return `{:ok, nil}` (there is no dispatch to record).

    * `:bearer` profile → always `{:ok, nil}` (signatures ignored).
    * `:signed`, caller NOT enrolled → `{:ok, nil}` (gradual rollout).
    * `:signed`, caller enrolled, no/blank signature → `{:error, :claim_signature_required}`.
    * `:signed`, caller enrolled, signature present but the claim object is malformed
      (bad `alg`/`claimed_at` type, undecodable `claim_sig`) → `{:error, :malformed_claim}`.
    * `:signed`, caller enrolled, signature verifies but `claimed_at` is outside the
      freshness window → `{:error, :claim_expired}`.
    * `:signed`, caller enrolled, signature verifies but the attestation's §9.2
      condition (`gate=`/`expires<`) is unmet → `{:error, :claim_condition_unmet}`.
    * `:signed`, caller enrolled, signature present and well-formed → verifies it
      (§9.3); `{:ok, dispatch}` or `{:error, :invalid_claim_signature}`.
  """
  @spec verify_request(
          :bearer | :signed,
          Ecto.UUID.t(),
          Ecto.UUID.t() | nil,
          String.t(),
          binary(),
          binary() | nil,
          map()
        ) :: {:ok, map() | nil} | {:error, atom()}
  # `profile` is passed in (the plug supplies `profile/0`) so the enforcement logic
  # is exercised in async tests without mutating VM-global config.
  def verify_request(:bearer, _tenant_id, _api_key_id, _gate, _work_item_id, _cap, _claim),
    do: {:ok, nil}

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

      {:ok, %{agent_id: agent_id}} when is_binary(agent_id) ->
        # A BEARER dispatch (no enrolled key). Normally waived (gradual rollout) — BUT
        # if this AGENT has opted into signing elsewhere (an active enrolled dispatch),
        # a bearer dispatch for the same agent_id must NOT make unsigned claims in its
        # name, or it impersonates precisely the agents that migrated. Close that gap;
        # otherwise apply the waiver.
        if Dispatches.agent_has_enrolled_key?(tenant_id, agent_id) do
          {:error, :agent_enrollment_required}
        else
          {:ok, nil}
        end

      _no_dispatch ->
        # A legacy env-var key with no dispatch at all: the enrolled-only
        # gradual-rollout waiver. Bounded by the role gate and the lineage self-*
        # checks, but NOT cryptographically attributable — §9.1.1 transparency is the
        # only guarantee (DETECTION, not prevention) until every key is dispatch-minted.
        {:ok, nil}
    end
  end

  @doc """
  Signed-profile gate for SET-BASED custody actions (bulk verify, epic verify-all,
  bulk mark-complete), which reach the same `verified` transition as single-story
  verify but carry an unbounded set of work items and therefore CANNOT present the
  per-item claim signature §9.3 requires for each work item.

  Under the `signed` profile an ENROLLED caller is refused — it must use the
  single-story signed path so every verified transition carries its own signature;
  otherwise an enrolled verifier forced to sign one verify could verify an entire
  epic unsigned, defeating the §9.3 attribution guarantee on the highest-volume
  path. A bearer/legacy caller is unaffected, mirroring `verify_request/7`'s
  enrolled-only gradual-rollout waiver.

  "Enrolled" is decided the SAME way as on the single-story path: an enrolled
  dispatch, OR a bearer dispatch belonging to an agent that has an enrolled key
  elsewhere (`Dispatches.agent_has_enrolled_key?/2`). Without that second clause the
  bulk gate is strictly WEAKER than the single-story gate it mirrors — an agent that
  had migrated to signing could take its BEARER dispatch to verify-all and clear a
  whole epic unsigned, which is the exact bypass this function exists to close.

  The two cases answer with DIFFERENT codes because their remedies differ, and each
  message must be true of the caller it is sent to. An ENROLLED dispatch gets
  `:bulk_signature_unsupported` ("verify each story individually") — its next call
  succeeds. A BEARER dispatch gets `:agent_enrollment_required` ("use your enrolled
  dispatch") exactly as on the single-story path; answering it
  `:bulk_signature_unsupported` told it "your dispatch is enrolled with an agent key"
  (false) and sent it to a single-story path that then 403s the same bearer key —
  a dead end wrapped in a misdescription of its own credential.
  """
  @spec verify_bulk_request(:bearer | :signed, Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          :ok | {:error, :bulk_signature_unsupported | :agent_enrollment_required}
  def verify_bulk_request(:bearer, _tenant_id, _api_key_id), do: :ok

  def verify_bulk_request(:signed, tenant_id, api_key_id) do
    case Dispatches.dispatch_for_api_key(tenant_id, api_key_id) do
      {:ok, %{agent_pubkey: pubkey}} when is_binary(pubkey) ->
        {:error, :bulk_signature_unsupported}

      {:ok, %{agent_id: agent_id}} when is_binary(agent_id) ->
        if Dispatches.agent_has_enrolled_key?(tenant_id, agent_id) do
          {:error, :agent_enrollment_required}
        else
          :ok
        end

      _not_enrolled ->
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
         :ok <- check_claim_fresh(claimed_at, gate, work_item_id, dispatch),
         :ok <- check_attestation_conditions(dispatch, gate) do
      # Final custody-separation check: the signing key must differ from the
      # implementer's enrolled key (see check_pubkey_separation/4). On success
      # return the resolved dispatch so the plug can stash the verified claim
      # without a second `dispatch_for_api_key` query.
      case check_pubkey_separation(tenant_id, dispatch, gate, work_item_id) do
        :ok -> {:ok, dispatch}
        {:error, _reason} = err -> err
      end
    else
      # The `require_sig`/`require_present`/`require_int`/`decode_sig` guards return
      # BEFORE `normalize_verify_result`/`check_claim_fresh`/`check_attestation_conditions`
      # have logged, so an enrolled caller repeatedly hitting "no signature" or
      # "malformed claim" (an attacker probing the signed gate, or a misconfigured
      # agent) would otherwise leave zero server-side signal. Emit the same
      # `log_reject` those later branches do; the already-logged reasons are returned
      # untouched (no double log).
      {:error, reason} = err when reason in [:claim_signature_required, :malformed_claim] ->
        log_reject(gate, work_item_id, dispatch, "claim rejected pre-verify (#{reason})")
        err

      {:error, _reason} = err ->
        err
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

  # LCP-1 custody separation at the CRYPTOGRAPHIC-identity level. The lineage/agent-id
  # self-checks (`Progress.validate_not_self_*`) compare dispatch lineages and agent
  # ids, but NEVER the enrolled public keys — so one keypair enrolled on two
  # independently-rooted dispatches (distinct agent ids) could sign BOTH the
  # implementer's report AND the verifier's claim, defeating the separation the
  # product exists to enforce. On `verify`/`review_complete`, reject when the signing
  # (caller) key equals the implementer dispatch's enrolled key. Only meaningful when
  # the story has a dispatched, enrolled implementer; otherwise the lineage/agent-id
  # gates apply and this is a no-op.
  defp check_pubkey_separation(tenant_id, dispatch, gate, work_item_id)
       when gate in ["verify", "review_complete"] do
    case implementer_pubkey(tenant_id, work_item_id) do
      pk when is_binary(pk) and pk == dispatch.agent_pubkey ->
        log_reject(
          gate,
          work_item_id,
          dispatch,
          "signing key equals the implementer's enrolled key"
        )

        {:error, :self_signed_claim}

      _ ->
        :ok
    end
  end

  defp check_pubkey_separation(_tenant_id, _dispatch, _gate, _work_item_id), do: :ok

  defp implementer_pubkey(tenant_id, story_id) when is_binary(story_id) do
    impl_dispatch_id =
      from(s in Story,
        where: s.id == ^story_id and s.tenant_id == ^tenant_id,
        select: s.implementer_dispatch_id
      )
      |> AdminRepo.one()

    case impl_dispatch_id && Dispatches.get_dispatch(tenant_id, impl_dispatch_id) do
      {:ok, %{agent_pubkey: pk}} -> pk
      _ -> nil
    end
  end

  defp implementer_pubkey(_tenant_id, _story_id), do: nil

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
