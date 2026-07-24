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
  Idempotent per test — generates and registers on first call.
  """
  def ensure_owner_key(tenant_id) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, _} = Tenants.register_custody_owner_key(tenant_id, pub, "ed25519")
    {pub, priv}
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
    attestation = root_attestation(tenant_id, agent_pub, owner_priv)

    {:ok, %{dispatch: dispatch, raw_key: raw_key}} =
      Dispatches.create_dispatch(
        tenant_id,
        Map.merge(
          %{
            role: :agent,
            agent_pubkey: agent_pub,
            alg: "ed25519",
            attestation: attestation,
            attestation_conditions: ""
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
