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
  - `typ` — token type (start_cap, report_cap, verify_cap, review_complete_cap)
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

  Checks: type match, story match, lineage exact match, not expired,
  not consumed, nonce exists.
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

    case AdminRepo.get_by(CapabilityToken, id: cap_id, tenant_id: tenant_id) do
      nil ->
        {:error, :invalid_capability}

      cap ->
        validate_cap(cap, tenant_id, expected_typ, expected_story_id, caller_lineage, now)
    end
  end

  def verify(_tenant_id, _params), do: {:error, :invalid_capability}

  @doc """
  Consumes a capability token (marks as used). Must be called inside
  an Ecto.Multi with the custody operation for atomicity.
  """
  @spec consume(CapabilityToken.t()) :: {:ok, CapabilityToken.t()} | {:error, term()}
  def consume(%CapabilityToken{consumed_at: nil} = cap) do
    cap
    |> CapabilityToken.changeset(%{consumed_at: DateTime.utc_now()})
    |> AdminRepo.update()
  end

  def consume(%CapabilityToken{consumed_at: _}), do: {:error, :replay}

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
