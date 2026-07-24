defmodule Loopctl.Repo.Migrations.AddDispatchEnrollmentTransparencyTrigger do
  use Ecto.Migration

  @moduledoc """
  DB-layer backstop for LCP-1 §9.1.1 enrollment transparency (defense-in-depth, L2).

  `Loopctl.Dispatches.create_dispatch/3` records every `agent_pubkey`-carrying
  dispatch on the hash-chained `audit_chain` inside the SAME atomic `Ecto.Multi` as
  the dispatch insert, so a tenant can enumerate every enrolled key from the log
  alone. That guarantee, however, was enforced ONLY in application code: nothing at
  the database tied a `dispatches` row with `agent_pubkey IS NOT NULL` to a matching
  `dispatch_created_with_agent_key` audit entry. An operator with direct DB access —
  precisely the adversary §9.1.1 defends against — could `INSERT`/`UPDATE` a signed
  dispatch straight through `AdminRepo`/raw SQL and omit the audit entry, and that
  key would be INVISIBLE to `enrolled_agent_keys/1`.

  This adds a DEFERRABLE INITIALLY DEFERRED constraint trigger that fires at COMMIT
  (after the sanctioned Multi's audit append has landed) and requires, for any
  committed dispatch row carrying an `agent_pubkey`, a matching enrollment entry on
  the audit chain for the same tenant and dispatch id. The legitimate path passes
  because its audit append is part of the same transaction; a direct insert that
  omits the audit entry now fails CLOSED at commit.

  Deferred + `WHEN (NEW.agent_pubkey IS NOT NULL)` so it never fires for the common
  bearer dispatch (no key) and is evaluated once per transaction after all rows and
  the audit entry are present.
  """

  def up do
    execute(
      """
      CREATE OR REPLACE FUNCTION dispatches_enrollment_transparency_check()
      RETURNS TRIGGER AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM audit_chain
          WHERE tenant_id = NEW.tenant_id
            AND action = 'dispatch_created_with_agent_key'
            AND entity_id = NEW.id
        ) THEN
          RAISE EXCEPTION
            'dispatch_enrollment_transparency_violation: dispatch % enrolls an agent key with no matching audit_chain entry (LCP-1 §9.1.1)',
            NEW.id
            USING ERRCODE = 'P0001';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS dispatches_enrollment_transparency_check() CASCADE"
    )

    execute(
      """
      CREATE CONSTRAINT TRIGGER dispatches_enrollment_transparency_trigger
        AFTER INSERT OR UPDATE ON dispatches
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW
        WHEN (NEW.agent_pubkey IS NOT NULL)
        EXECUTE FUNCTION dispatches_enrollment_transparency_check();
      """,
      "DROP TRIGGER IF EXISTS dispatches_enrollment_transparency_trigger ON dispatches"
    )
  end

  def down do
    execute("DROP TRIGGER IF EXISTS dispatches_enrollment_transparency_trigger ON dispatches")
    execute("DROP FUNCTION IF EXISTS dispatches_enrollment_transparency_check() CASCADE")
  end
end
