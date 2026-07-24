defmodule Loopctl.Repo.Migrations.AddCustodyOwnerKeyAndDispatchAttestation do
  use Ecto.Migration

  @moduledoc """
  LCP-1 §9.2 owner-attested enrollment — the root of trust that makes the signed
  profile deliver PREVENTION (an operator cannot forge an agent-attributable
  claim), not just detection.

  Two additive, nullable column groups:

    * `tenants.custody_owner_pubkey` / `custody_owner_alg` — the tenant's OWNER key.
      Unlike `audit_signing_public_key` (whose private half is server-held for STH /
      capability signing), the owner key's private half is held by the OWNER and
      never by the operator. It is the root that authorizes root agent-key
      enrollments. NULL until an owner registers one (human-anchored).

    * `dispatches.attestation` / `attestation_conditions` — the §9.2 owner/parent
      attestation over the enrolled `agent_pubkey`, retained so a third party can
      re-verify the enrollment chain offline (owner → root agent → child agent).
      NULL for a bearer dispatch (no key).

  Both groups are nullable with no default and no backfill: every existing tenant
  and dispatch is untouched, and the whole change is catalog-only. CHECK
  constraints bind alg to a known algorithm and keep the owner key's two columns
  both-or-neither.
  """

  def up do
    alter table(:tenants) do
      add :custody_owner_pubkey, :binary
      add :custody_owner_alg, :string
    end

    alter table(:dispatches) do
      add :attestation, :binary
      add :attestation_conditions, :string
    end

    execute("""
    ALTER TABLE tenants
      ADD CONSTRAINT tenants_custody_owner_key_valid
      CHECK (
        (custody_owner_pubkey IS NULL AND custody_owner_alg IS NULL)
        OR (custody_owner_pubkey IS NOT NULL AND custody_owner_alg = 'ed25519'
            AND octet_length(custody_owner_pubkey) = 32)
      )
    """)
  end

  def down do
    execute("ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_custody_owner_key_valid")

    alter table(:dispatches) do
      remove :attestation
      remove :attestation_conditions
    end

    alter table(:tenants) do
      remove :custody_owner_pubkey
      remove :custody_owner_alg
    end
  end
end
