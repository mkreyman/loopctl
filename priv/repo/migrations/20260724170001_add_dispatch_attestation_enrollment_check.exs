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

  ## Deploy safety

  A prior migration (`20260724000000`, shipped in #515) added `agent_pubkey` while
  enrollment was still UNATTESTED, so a deployment may already hold rows with a
  non-NULL `agent_pubkey` and a NULL `attestation`. Those rows violate the CHECK
  and CANNOT be backfilled — an owner/parent attestation is unforgeable. Since an
  unattested enrollment is not owner-authorized under §9.2 (it was never really a
  trusted signed dispatch), the correct remediation is to DOWNGRADE such rows to
  bearer (drop the key), forcing a proper re-enrollment. Done first so the CHECK
  is satisfiable, then added `NOT VALID` + separately `VALIDATE`d so it never takes
  an ACCESS EXCLUSIVE full-table scan on the unbounded, append-only `dispatches`
  table (mirrors the repo's online-constraint pattern).
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Downgrade any pre-attestation enrolled dispatch to bearer. Idempotent (after
    # this runs, no such row remains). These carried no owner attestation and so
    # were never a valid §9.2 enrollment; dropping the key forces re-enrollment.
    execute("""
    UPDATE dispatches
       SET agent_pubkey = NULL, alg = NULL
     WHERE agent_pubkey IS NOT NULL AND attestation IS NULL
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'dispatches_attestation_matches_enrollment'
      ) THEN
        ALTER TABLE dispatches
          ADD CONSTRAINT dispatches_attestation_matches_enrollment
          CHECK ((agent_pubkey IS NULL) = (attestation IS NULL))
          NOT VALID;
      END IF;
    END $$;
    """)

    execute(
      "ALTER TABLE dispatches VALIDATE CONSTRAINT dispatches_attestation_matches_enrollment"
    )
  end

  def down do
    execute(
      "ALTER TABLE dispatches DROP CONSTRAINT IF EXISTS dispatches_attestation_matches_enrollment"
    )
  end
end
