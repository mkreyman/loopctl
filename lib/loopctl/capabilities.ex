defmodule Loopctl.Capabilities do
  @moduledoc """
  US-26.3.1 — Capability token management: mint, verify, consume.

  Capability tokens are signed, scoped, non-replayable authorization
  tokens that gate custody-critical operations. Each token is bound to
  a specific story, lineage, and operation type.
  """

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
  """
  @spec mint(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, CapabilityToken.t()} | {:error, term()}
  def mint(tenant_id, typ, story_id, lineage) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, @cap_ttl_seconds, :second)
    nonce = :crypto.strong_rand_bytes(32)

    case TenantKeys.get_private_key(tenant_id) do
      {:ok, private_key} ->
        message = build_message(tenant_id, typ, story_id, lineage, now, expires_at, nonce)
        signature = :crypto.sign(:eddsa, :sha512, message, [private_key, :ed25519])

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

      {:error, reason} ->
        {:error, {:key_unavailable, reason}}
    end
  end

  @doc """
  Verifies a capability token against the expected parameters.

  Checks (`validate_cap/6`, in order): type match, story match, lineage exact
  match, not expired, not consumed, and a valid ed25519 SIGNATURE over the
  token's fields, verified against the tenant's `audit_signing_public_key`
  (`verify_signature/2`). The signature check fails CLOSED when the tenant has
  no public key — it is the only cryptographic check here, so never drop it.
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
      not verify_signature(tenant_id, cap) -> {:error, :invalid_signature}
      true -> {:ok, cap}
    end
  end

  defp verify_signature(tenant_id, cap) do
    import Ecto.Query

    pub_key =
      from(t in Loopctl.Tenants.Tenant,
        where: t.id == ^tenant_id,
        select: t.audit_signing_public_key
      )
      |> AdminRepo.one()

    if pub_key do
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

      :crypto.verify(:eddsa, :sha512, message, cap.signature, [pub_key, :ed25519])
    else
      # No public key — can't verify, reject
      false
    end
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
