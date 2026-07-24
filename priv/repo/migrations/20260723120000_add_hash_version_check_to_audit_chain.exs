defmodule Loopctl.Repo.Migrations.AddHashVersionCheckToAuditChain do
  use Ecto.Migration

  # Run each ALTER in its OWN auto-committed transaction. This is REQUIRED for the
  # NOT VALID / VALIDATE split to actually help: inside a single Ecto-wrapped
  # transaction Postgres would hold the ADD-CONSTRAINT lock until COMMIT, i.e.
  # through the whole VALIDATE scan — an ACCESS EXCLUSIVE write block on
  # `audit_chain`, the tenant-wide, unbounded, append-only custody log that EVERY
  # custody gate decision writes to (LCP-1 §8; `AuditChain.append` does a
  # SELECT..FOR UPDATE + INSERT). With the DDL transaction disabled, ADD
  # CONSTRAINT ... NOT VALID commits first (fast, catalog-only, no scan), THEN
  # VALIDATE CONSTRAINT runs on its own taking only SHARE UPDATE EXCLUSIVE
  # (concurrent appends allowed). Same repo pattern as
  # 20260702130100_add_reported_done_requires_agent_check_to_stories.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Constrains `audit_chain.hash_version` to the leaf-hash versions this codebase
  can actually construct (LCP-1 §8.4 defines 1 and 2).

  `Loopctl.AuditChain.LeafHash.compute/2` only knows versions 1 and 2; an entry
  carrying any other value cannot be recomputed and so cannot be validated. This
  CHECK makes an out-of-range version unwritable at the database level, keeping
  the tamper-detection path from ever meeting a version it must reject. Purely
  additive: every existing row is 1 (the column default) or 2 (new writes), both
  of which satisfy the constraint, so VALIDATE passes without a rewrite.

  Online-safe locking: `@disable_ddl_transaction true` (see the module attribute
  note) makes `ADD CONSTRAINT ... NOT VALID` and `VALIDATE CONSTRAINT` each run
  in their own auto-committed transaction, so VALIDATE holds only a SHARE UPDATE
  EXCLUSIVE lock — concurrent custody appends continue during the scan instead of
  being blocked for its full duration.

  Reversible: `down` drops the constraint (idempotent `IF EXISTS`).
  """

  def up do
    execute(
      "ALTER TABLE audit_chain ADD CONSTRAINT audit_chain_hash_version_valid CHECK (hash_version IN (1, 2)) NOT VALID"
    )

    execute("ALTER TABLE audit_chain VALIDATE CONSTRAINT audit_chain_hash_version_valid")
  end

  def down do
    execute("ALTER TABLE audit_chain DROP CONSTRAINT IF EXISTS audit_chain_hash_version_valid")
  end
end
