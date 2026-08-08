defmodule Loopctl.Capabilities do
  @moduledoc """
  US-26.3.1 — Capability token management: mint, verify, consume.

  Capability tokens are signed, scoped, non-replayable authorization
  tokens that gate custody-critical operations. Each token is bound to
  a specific story, lineage, and operation type.
  """

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Capabilities.CapabilityToken
  alias Loopctl.TenantKeys

  @cap_ttl_seconds 3600

  @doc """
  Mints a new capability token signed by the tenant's audit key.

  ## Parameters

  - `tenant_id` — the tenant UUID
  - `typ` — token type. Only `start_cap` is minted today; `report_cap` and
    `verify_cap` were retired in #621 (see `Progress.verify_story/4`).
  - `story_id` — the story UUID
  - `lineage` — the dispatch lineage path of the recipient

  ## Returns

  `{:ok, %CapabilityToken{}}` or `{:error, reason}`

  ## The mint checks its own signature

  The private key comes from `TenantKeys`, a node-LOCAL ETS cache. A rotation
  reaches peer nodes over PubSub (`TenantKeys.invalidate_cluster/1`), but a
  dropped broadcast would leave this node signing with the SUPERSEDED key — and a
  token signed by a retired key verifies as `:invalid_signature`, which
  `Progress.record_cap_refusal/4` chains as `capability_forged`, `byzantine:
  true`. So the signature is verified against the key the tenant ADVERTISES
  before the token is persisted: a mismatch busts the cache entry and re-signs
  ONCE off the freshly fetched key, and only a second mismatch is refused with
  `{:error, {:key_unavailable, :signing_key_superseded}}` — a second mismatch
  means the cache was never the cause, leaving the deploy window in which the
  new private half is not readable yet, which closes on its own. A mint failure is
  already handled (`Progress` logs it and the operation proceeds capability-less),
  which is strictly better than issuing a token that reads as a forgery.
  """
  @spec mint(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, CapabilityToken.t()} | {:error, term()}
  def mint(tenant_id, typ, story_id, lineage),
    do: mint_signed(tenant_id, typ, story_id, lineage, :retry_stale_key)

  defp mint_signed(tenant_id, typ, story_id, lineage, on_mismatch) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, @cap_ttl_seconds, :second)
    nonce = :crypto.strong_rand_bytes(32)

    # The mint VERIFIES ITS OWN SIGNATURE against the key the tenant ADVERTISES
    # before persisting anything: the signer here can be the RETIRED half, and that
    # token later lands as `capability_forged`, `byzantine: true`, about an agent
    # that did nothing wrong. A signature that could not be PRODUCED at all is
    # reported separately (`:signing_key_malformed`): the remedy is corrupt key
    # material in the secret store, not a rotation an operator would go looking for.
    #
    # TWO different causes put a retired key in the signer's hand, and they take
    # different remedies:
    #
    #   * this node's ETS entry is STALE — the rotation's PubSub invalidation was
    #     dropped (delivery is best-effort). Busting the entry and re-signing fixes
    #     it immediately, which is why `on_mismatch` exists at all.
    #   * the new private half is not READABLE yet — a rotation commits the new
    #     public key before the secret is deployed (the Fly adapter reads
    #     `System.get_env/1`). No cache bust helps; the window closes on its own,
    #     so it answers `:signing_key_superseded`, which `mint_failure_class/1`
    #     leaves retryable.
    #
    # Trying the bust FIRST costs one wasted signature in the second case and
    # distinguishes them for free: if a fresh fetch still mismatches, the cache was
    # never the problem.
    with {:ok, private_key} <- TenantKeys.get_private_key(tenant_id),
         message = build_message(tenant_id, typ, story_id, lineage, now, expires_at, nonce),
         {:ok, signature} <- sign(message, private_key),
         true <- verifies?(current_key(tenant_id).public_key, message, signature) do
      %CapabilityToken{tenant_id: tenant_id}
      |> CapabilityToken.changeset(%{
        typ: typ,
        story_id: story_id,
        issued_to_lineage: lineage,
        issued_at: now,
        expires_at: expires_at,
        nonce: nonce,
        signature: signature
      })
      |> AdminRepo.insert()
    else
      false -> mismatched_signing_key(tenant_id, typ, story_id, lineage, on_mismatch)
      :error -> {:error, {:key_unavailable, :signing_key_malformed}}
      {:error, reason} -> {:error, {:key_unavailable, reason}}
    end
  end

  defp mismatched_signing_key(tenant_id, typ, story_id, lineage, :retry_stale_key) do
    Logger.warning(
      "capability_mint_stale_key: the cached audit private key does not match the key " <>
        "tenant_id=#{tenant_id} advertises (a rotation this node may not have observed); " <>
        "busting the cache entry and re-signing once."
    )

    TenantKeys.invalidate(tenant_id)
    mint_signed(tenant_id, typ, story_id, lineage, :refuse)
  end

  defp mismatched_signing_key(tenant_id, _typ, _story_id, _lineage, :refuse) do
    Logger.error(
      "capability_mint_key_superseded: the audit private key for tenant_id=#{tenant_id} " <>
        "does not match its advertised public key even after a fresh fetch, so the cache " <>
        "was not the cause — the new secret is most likely not deployed yet. Refusing to " <>
        "mint: a token signed by a superseded key is recorded as capability_forged."
    )

    {:error, {:key_unavailable, :signing_key_superseded}}
  end

  # A secret store that is momentarily unreachable is RETRYABLE, and so is
  # `:signing_key_superseded`: it is the window between a rotation committing the
  # new public key and the deploy that makes the new private half readable, which
  # closes on its own. A key that is ABSENT, CORRUPT, belongs to no tenant, or
  # whose store is not configured at all is a persistent OPERATOR condition, and
  # answering it as retryable made agents hot-loop a claim they cannot fix.
  @persistent_key_faults [
    :not_found,
    :tenant_not_found,
    :corrupt_secret,
    :corrupt_secrets_file,
    :signing_key_malformed,
    :fly_not_configured
  ]

  @doc "Classifies a `mint/4` failure into the error its caller should answer with."
  @spec mint_failure_class(term()) :: :capability_key_unavailable | :capability_mint_failed
  def mint_failure_class({:key_unavailable, reason}) when reason in @persistent_key_faults,
    do: :capability_key_unavailable

  def mint_failure_class({:key_unavailable, {:secrets_file_unreadable, _reason}}),
    do: :capability_key_unavailable

  def mint_failure_class(_reason), do: :capability_mint_failed

  @doc """
  Verifies a capability token against the expected parameters.

  Checks (`validate_cap/6`, in order): type match, story match, lineage exact
  match, not expired, not consumed, and a valid ed25519 SIGNATURE over the
  token's fields, verified against the tenant's `audit_signing_public_key`
  (`check_signature/2`). The signature check fails CLOSED when the tenant has
  no public key — it is the only cryptographic check here, so never drop it.

  A signature that does not verify yields ONE OF TWO reasons, and they are not
  interchangeable:

    * `:invalid_signature` — the key that was in force when the token was issued
      IS available, and the signature did not verify against it. That is a
      forgery signal, recorded as `capability_forged` with `byzantine: true` in
      the append-only audit chain.
    * `:signing_key_unavailable` — there is no USABLE key to check against: the
      audit key was cleared, was replaced without a `tenant_audit_key_history`
      row covering the token's `issued_at`, or the advertised public key no
      longer corresponds to the private key the tenant signs with. The token is
      refused the same way, but it is an OPERATOR key-state fault, not evidence
      about the caller. Branding it a forgery writes a permanent false accusation
      into a log that by construction cannot be retracted.

  The distinction is derived entirely from SERVER state (the tenant row, the key
  history, and a keypair-coherence probe against the tenant's own signing key),
  never from the presented token, so it cannot be steered by a caller to
  downgrade its own forgery. A probe that could not RUN — the secret store is
  unreachable, or its failure is negatively cached — is INCONCLUSIVE and leaves
  the forgery classification standing: turning the detection off for as long as
  an unrelated dependency is unhappy would hand an attacker the switch.
  """
  @spec verify(Ecto.UUID.t(), map()) ::
          {:ok, CapabilityToken.t()} | {:error, atom()}
  def verify(tenant_id, %{
        "cap_id" => cap_id,
        "typ" => expected_typ,
        "story_id" => expected_story_id,
        "lineage" => caller_lineage
      }) do
    now = DateTime.utc_now()

    # cap_id is client input: a non-UUID raises Ecto.Query.CastError in the query
    # below, which surfaced as a 500 instead of the documented refusal.
    with {:ok, cap_id} <- Ecto.UUID.cast(cap_id),
         cap = %CapabilityToken{} <-
           AdminRepo.get_by(CapabilityToken, id: cap_id, tenant_id: tenant_id) do
      validate_cap(cap, tenant_id, expected_typ, expected_story_id, caller_lineage, now)
    else
      _ -> {:error, :invalid_capability}
    end
  end

  def verify(_tenant_id, _params), do: {:error, :invalid_capability}

  @doc """
  Consumes a capability token (marks as used). Must be called inside
  an Ecto.Multi with the custody operation for atomicity.
  """
  @spec consume(CapabilityToken.t()) :: {:ok, CapabilityToken.t()} | {:error, term()}
  def consume(%CapabilityToken{id: id, consumed_at: nil}) do
    import Ecto.Query

    now = DateTime.utc_now()

    # Atomic: only updates if consumed_at IS NULL, preventing TOCTOU race
    case from(c in CapabilityToken, where: c.id == ^id and is_nil(c.consumed_at))
         |> AdminRepo.update_all(set: [consumed_at: now]) do
      {1, _} -> {:ok, %CapabilityToken{id: id, consumed_at: now}}
      {0, _} -> {:error, :replay}
    end
  end

  def consume(%CapabilityToken{consumed_at: _}), do: {:error, :replay}

  @doc """
  Lists the live capabilities issued to `lineage` for `story_id`.

  DELIVERY, NOT MINTING (#621) — the recovery path for a client that lost the
  `claim` response carrying its `start_cap`. Returns only tokens ALREADY minted,
  unconsumed and unexpired; the lineage must still match exactly at consume time
  (`validate_cap/6`), where the signature is checked.

  An empty lineage fails CLOSED: every key not minted by a dispatch resolves to
  `[]`, so matching on it would hand ONE legacy caller every other legacy
  caller's tokens. Use `list_for_assigned_agent/3` there instead.
  """
  @spec list_for_lineage(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) :: [CapabilityToken.t()]
  def list_for_lineage(_tenant_id, _story_id, []), do: []

  def list_for_lineage(tenant_id, story_id, lineage), do: live_caps(tenant_id, story_id, lineage)

  @doc """
  Lists the live `[]`-lineage capabilities for `story_id`, but only when
  `agent_id` is the story's ASSIGNED agent — the discriminator lineage cannot
  supply for a legacy key. Without it such a claimant had NO recovery path at
  all: `recover_cap` needs an `implementer_dispatch_id` its claim never records.
  """
  @spec list_for_assigned_agent(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          [CapabilityToken.t()]
  def list_for_assigned_agent(_tenant_id, _story_id, nil), do: []

  def list_for_assigned_agent(tenant_id, story_id, agent_id) do
    import Ecto.Query

    assigned? =
      from(s in Loopctl.WorkBreakdown.Story,
        where:
          s.id == ^story_id and s.tenant_id == ^tenant_id and s.assigned_agent_id == ^agent_id
      )
      |> AdminRepo.exists?()

    if assigned?, do: live_caps(tenant_id, story_id, []), else: []
  end

  @doc """
  Returns a JSON-serializable representation of a capability token.
  """
  @spec serialize(CapabilityToken.t()) :: map()
  def serialize(cap) do
    %{
      cap_id: cap.id,
      typ: cap.typ,
      story_id: cap.story_id,
      issued_to_lineage: cap.issued_to_lineage,
      issued_at: cap.issued_at,
      expires_at: cap.expires_at,
      nonce: Base.url_encode64(cap.nonce, padding: false),
      signature: Base.url_encode64(cap.signature, padding: false)
    }
  end

  # --- Private ---

  defp live_caps(tenant_id, story_id, lineage) do
    import Ecto.Query

    now = DateTime.utc_now()

    from(c in CapabilityToken,
      where:
        c.tenant_id == ^tenant_id and c.story_id == ^story_id and
          c.issued_to_lineage == ^lineage and is_nil(c.consumed_at) and
          c.expires_at > ^now,
      order_by: [desc: c.issued_at]
    )
    |> AdminRepo.all()
  end

  defp validate_cap(cap, tenant_id, expected_typ, expected_story_id, caller_lineage, now) do
    cond do
      cap.typ != expected_typ -> {:error, :wrong_type}
      cap.story_id != expected_story_id -> {:error, :wrong_story}
      cap.issued_to_lineage != caller_lineage -> {:error, :wrong_lineage}
      DateTime.compare(cap.expires_at, now) != :gt -> {:error, :expired}
      cap.consumed_at != nil -> {:error, :replay}
      true -> check_signature(tenant_id, cap)
    end
  end

  # Fails CLOSED on every path — the only question this decides is WHICH refusal,
  # and therefore what the audit chain is made to assert about the caller.
  defp check_signature(tenant_id, cap) do
    %{current: current, historical: historical} = signing_context(tenant_id, cap.issued_at)

    message =
      build_message(
        tenant_id,
        cap.typ,
        cap.story_id,
        cap.issued_to_lineage,
        cap.issued_at,
        cap.expires_at,
        cap.nonce
      )

    candidates = Enum.reject([current.public_key | historical], &is_nil/1)

    cond do
      Enum.any?(candidates, &verifies?(&1, message, cap.signature)) ->
        {:ok, cap}

      issuance_key_available?(tenant_id, current, historical, cap.issued_at) ->
        {:error, :invalid_signature}

      true ->
        {:error, :signing_key_unavailable}
    end
  end

  # Was the key that was IN FORCE at `issued_at` available to check against?
  #
  #   * a history row covering `issued_at` IS that key, by definition; or
  #   * the tenant's current key, when nothing has been rotated in since
  #     `issued_at` AND that key is still the one the tenant signs with.
  # None of that holds when the audit key was CLEARED, REPLACED WITHOUT HISTORY
  # (rotated in after issuance, nothing archived), or replaced OUT OF BAND — the
  # last is why `audit_key_rotated_at` cannot decide this alone: a direct UPDATE
  # of the key leaves the timestamp untouched, so a stale-but-earlier `rotated_at`
  # reads as "in force since before issuance" and every outstanding token becomes
  # a forgery. KEYPAIR COHERENCE is the discriminator a timestamp cannot be: a
  # public key that does not correspond to the private key we sign with could not
  # have verified an authentic token either, so it is key state, not the caller.
  #
  # The current key stays a verification CANDIDATE regardless of this test: a
  # rotation committing between `mint/4`'s timestamp and its signature would put
  # `issued_at` before `audit_key_rotated_at` on a token it genuinely signed.
  defp issuance_key_available?(tenant_id, current, historical, issued_at) do
    cond do
      historical != [] -> true
      is_nil(current.public_key) -> false
      rotated_after?(current.rotated_at, issued_at) -> false
      true -> keypair_coherence(tenant_id, current.public_key) != :incoherent
    end
  end

  defp rotated_after?(nil, _issued_at), do: false
  defp rotated_after?(at, issued_at), do: DateTime.compare(at, issued_at) == :gt

  # Does the private key we would SIGN with still correspond to the public key the
  # tenant ADVERTISES? Only `:incoherent` — the probe RAN and disagreed — may
  # soften a refusal, because only that is evidence about the key. `:unknown` (the
  # probe could not run: unreachable or negatively-cached secret store, unusable
  # key material) learns nothing, so the timestamp/history decision stands and a
  # bad signature is still a forgery; collapsing the two suppressed every
  # `capability_forged` entry for as long as the store stayed unhappy.
  defp keypair_coherence(tenant_id, public_key) do
    with {:ok, private_key} <- TenantKeys.get_private_key(tenant_id),
         probe = "loopctl:cap-keypair-probe:" <> tenant_id,
         {:ok, signature} <- sign(probe, private_key) do
      if verifies?(public_key, probe, signature), do: :coherent, else: :incoherent
    else
      _ ->
        Logger.warning(
          "capability_keypair_probe_degraded: could not read the tenant's signing key, so " <>
            "keypair coherence is unknown and the signature classification stands as-is " <>
            "tenant_id=#{tenant_id}"
        )

        :unknown
    end
  end

  # The tenant's CURRENT advertised key and the instant it was rotated in. ONE
  # definition of "current key" in this module: `mint/4` checks its own signature
  # against it and `signing_context/2` offers it as a verification candidate.
  defp current_key(tenant_id) do
    import Ecto.Query

    from(t in Loopctl.Tenants.Tenant,
      where: t.id == ^tenant_id,
      select: %{public_key: t.audit_signing_public_key, rotated_at: t.audit_key_rotated_at}
    )
    |> AdminRepo.one()
    |> Kernel.||(%{public_key: nil, rotated_at: nil})
  end

  # Malformed key material RAISES out of :crypto rather than answering false. It
  # is reported as `:error` — NOT as an empty signature — because "no signature
  # could be produced" and "a signature that did not verify" have different
  # operator remedies, and the empty binary made the first read as the second.
  defp sign(message, private_key) do
    {:ok, :crypto.sign(:eddsa, :sha512, message, [private_key, :ed25519])}
  rescue
    _ -> :error
  end

  defp verifies?(nil, _message, _signature), do: false

  defp verifies?(public_key, message, signature) do
    :crypto.verify(:eddsa, :sha512, message, signature, [public_key, :ed25519])
  rescue
    _ -> false
  end

  # The tenant's CURRENT audit key (with the instant it was rotated in), plus any
  # historical key whose [rotated_in, rotated_out) window covers the token's
  # issuance. A rotation is a documented tenant operation; without the history a
  # benign rotation turned every outstanding token into `:invalid_signature`,
  # which is BYZANTINE and halts the whole tenant — the same blast radius #621
  # removed for expiry.
  defp signing_context(tenant_id, issued_at) do
    import Ecto.Query

    historical =
      from(h in Loopctl.Tenants.AuditKeyHistory,
        where:
          h.tenant_id == ^tenant_id and h.rotated_in <= ^issued_at and
            (is_nil(h.rotated_out) or h.rotated_out > ^issued_at),
        select: h.public_key
      )
      |> AdminRepo.all()

    %{current: current_key(tenant_id), historical: Enum.reject(historical, &is_nil/1)}
  end

  defp build_message(tenant_id, typ, story_id, lineage, issued_at, expires_at, nonce) do
    tenant_id <>
      typ <>
      (story_id || "") <>
      Enum.join(lineage, ",") <>
      DateTime.to_iso8601(issued_at) <>
      DateTime.to_iso8601(expires_at) <>
      nonce
  end
end
