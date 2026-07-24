defmodule Loopctl.Repo.Migrations.AddDispatchAttestationEnrollmentCheck do
  use Ecto.Migration

  @moduledoc """
  LCP-1 §9.2 — bind `dispatches.attestation` to enrollment at the DATABASE level.

  The sibling migration added `attestation`/`attestation_conditions` as nullable
  columns but left the both-or-neither invariant to application code
  (`enrolled_attestation_for_storage/2` + `verify_enrollment_attestation/4`): every
  ENROLLED (key-carrying) dispatch retains its owner/parent attestation for offline
  enrollment-chain re-verification, and a BEARER dispatch (no key) stores none.

  A future code path or a manual write could persist an `agent_pubkey` with a NULL
  `attestation` (silently breaking offline re-verification) or a stray attestation
  on a keyless row (an unverified blob that could be mistaken for a verified
  enrollment). Enforce the invariant in the schema, mirroring the both-or-neither
  CHECK already binding `agent_pubkey`/`alg`.

    (agent_pubkey IS NULL) = (attestation IS NULL)
  """

  def up do
    execute("""
    ALTER TABLE dispatches
      ADD CONSTRAINT dispatches_attestation_matches_enrollment
      CHECK ((agent_pubkey IS NULL) = (attestation IS NULL))
    """)
  end

  def down do
    execute(
      "ALTER TABLE dispatches DROP CONSTRAINT IF EXISTS dispatches_attestation_matches_enrollment"
    )
  end
end
