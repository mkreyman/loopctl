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

  defp build_message(sth) do
    unix_ts = DateTime.to_unix(sth.signed_at)

    sth.tenant_id <>
      Integer.to_string(sth.chain_position) <>
      sth.merkle_root <>
      Integer.to_string(unix_ts)
  end
end
