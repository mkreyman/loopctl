defmodule Loopctl.AuditChain.Verifier do
  @moduledoc """
  Stateless STH verification — verifies an ed25519 signature over a
  Signed Tree Head against a tenant's public audit key.

  This module is pure (no IO) and can be used for client-side verification.
  """

  @doc """
  Verifies an STH signature against a public key.

  ## Parameters

  - `sth` — map with `:tenant_id`, `:chain_position`, `:merkle_root`, `:signed_at`, `:signature`
  - `public_key` — 32-byte ed25519 public key

  ## Returns

  - `{:ok, true}` if the signature is valid
  - `{:error, :invalid_signature}` if verification fails
  """
  @spec verify_sth(map(), binary()) :: {:ok, true} | {:error, :invalid_signature}
  def verify_sth(sth, public_key) when is_binary(public_key) do
    message = build_message(sth)

    if :crypto.verify(:eddsa, :sha512, message, sth.signature, [public_key, :ed25519]) do
      {:ok, true}
    else
      {:error, :invalid_signature}
    end
  end

  @doc """
  US-41.7 (AC-41.7.4) — verifies a MERKLE AUDIT PATH against a signed tree head's
  root.

  Pure, so an external verifier can run it on the JSON the public endpoints
  return: fetch the STH, check `verify_sth/2` with the tenant's published audit
  key, then check that the record's leaf hash folds up to that same
  `merkle_root` through `audit_path`.

  `audit_path` is an ordered list of `%{position: :left | :right, hash: binary}`
  siblings, leaf level first, exactly as `Loopctl.AuditChain.inclusion_proof/2`
  emits them.
  """
  @spec verify_inclusion(binary(), [map()], binary()) ::
          {:ok, true} | {:error, :invalid_inclusion_proof}
  def verify_inclusion(leaf_hash, audit_path, merkle_root)
      when is_binary(leaf_hash) and is_list(audit_path) and is_binary(merkle_root) do
    computed =
      Enum.reduce(audit_path, leaf_hash, fn
        %{position: :right, hash: sibling}, acc -> :crypto.hash(:sha256, acc <> sibling)
        %{position: :left, hash: sibling}, acc -> :crypto.hash(:sha256, sibling <> acc)
      end)

    if computed == merkle_root do
      {:ok, true}
    else
      {:error, :invalid_inclusion_proof}
    end
  end

  defp build_message(sth) do
    unix_ts = DateTime.to_unix(sth.signed_at)

    sth.tenant_id <>
      Integer.to_string(sth.chain_position) <>
      sth.merkle_root <>
      Integer.to_string(unix_ts)
  end
end
