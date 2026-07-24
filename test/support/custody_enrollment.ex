defmodule Loopctl.Test.CustodyEnrollment do
  @moduledoc """
  Test helper for LCP-1 §9.2 attested agent-key enrollment.

  Under owner-attested enrollment, `Dispatches.create_dispatch` with an
  `agent_pubkey` REQUIRES a valid owner/parent attestation. This helper performs
  the full ceremony so tests don't repeat it: register a tenant owner key, sign a
  root attestation over the agent key, and enroll.
  """

  alias Loopctl.Custody.SignedProfile
  alias Loopctl.Dispatches
  alias Loopctl.Tenants

  @doc """
  Ensures the tenant has an owner key and returns `{owner_pub, owner_priv}`.

  Idempotent per test PROCESS: the keypair is generated + registered on the first
  call for a tenant and cached in the process dictionary, so repeat calls (e.g.
  `enroll_root/2` invoked several times in one test) reuse the SAME owner key
  instead of rotating it. Rotation now requires a proof-of-possession signature by
  the outgoing key, so a helper that silently re-registered a fresh key on every
  call would fail — and a single owner key per tenant is the realistic shape anyway.
  """
  def ensure_owner_key(tenant_id) do
    case Process.get({__MODULE__, :owner_key, tenant_id}) do
      {_pub, _priv} = cached ->
        cached

      nil ->
        {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
        {:ok, _} = Tenants.register_custody_owner_key(tenant_id, pub, "ed25519")
        Process.put({__MODULE__, :owner_key, tenant_id}, {pub, priv})
        {pub, priv}
    end
  end

  @doc """
  Signs a ROOT attestation over `agent_pub` with the owner private key (lineage
  `[]`, conditions `""` unless overridden). Returns the raw signature.
  """
  def root_attestation(tenant_id, agent_pub, owner_priv, conditions \\ "") do
    preimage = SignedProfile.attestation_preimage("ed25519", tenant_id, agent_pub, [], conditions)
    SignedProfile.sign("ed25519", preimage, owner_priv)
  end

  @doc """
  Full attested root enrollment. Registers an owner key, mints an agent keypair,
  signs the attestation, and calls `create_dispatch`. Returns
  `%{dispatch:, agent_pub:, agent_priv:, owner_pub:, owner_priv:, raw_key:}`.

  `attrs` are merged into the `create_dispatch` map (e.g. `role`, `agent_id`).
  """
  def enroll_root(tenant_id, attrs \\ %{}) do
    {owner_pub, owner_priv} = ensure_owner_key(tenant_id)
    {agent_pub, agent_priv} = :crypto.generate_key(:eddsa, :ed25519)
    # Sign the attestation over the SAME conditions the dispatch enrolls with, so a
    # caller can exercise `attestation_conditions` (e.g. "gate=report", "expires<T>")
    # end-to-end without the signature failing over a conditions mismatch.
    conditions = Map.get(attrs, :attestation_conditions, "")
    attestation = root_attestation(tenant_id, agent_pub, owner_priv, conditions)

    {:ok, %{dispatch: dispatch, raw_key: raw_key}} =
      Dispatches.create_dispatch(
        tenant_id,
        Map.merge(
          %{
            role: :agent,
            agent_pubkey: agent_pub,
            alg: "ed25519",
            attestation: attestation,
            attestation_conditions: conditions
          },
          attrs
        )
      )

    %{
      dispatch: dispatch,
      agent_pub: agent_pub,
      agent_priv: agent_priv,
      owner_pub: owner_pub,
      owner_priv: owner_priv,
      raw_key: raw_key
    }
  end
end
