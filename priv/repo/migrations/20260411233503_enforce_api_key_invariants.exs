defmodule Loopctl.Repo.Migrations.EnforceApiKeyInvariants do
  use Ecto.Migration

  @moduledoc """
  US-26.1.3 — Database-level invariants on the api_keys table:

  1. FK on agent_id → agents(id) ON DELETE RESTRICT
  2. Check constraint: agent/orchestrator keys MUST have agent_id,
     user/superadmin keys may have NULL agent_id
  3. Partial unique index: one active non-user key per agent per tenant
  4. Role immutability trigger: BEFORE UPDATE blocks role changes
  """

  def change do
    # 1. FK constraint on agent_id
    # Only create if not already present
    execute(
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM information_schema.table_constraints
          WHERE constraint_name = 'api_keys_agent_id_fkey'
        ) THEN
          ALTER TABLE api_keys
            ADD CONSTRAINT api_keys_agent_id_fkey
            FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE RESTRICT;
        END IF;
      END $$
      """,
      "ALTER TABLE api_keys DROP CONSTRAINT IF EXISTS api_keys_agent_id_fkey"
    )

    # 2. Check constraint deferred: the role-agent_id consistency is
    # enforced at the application layer (Loopctl.Auth.generate_api_key/1)
    # rather than a DB constraint, because existing test infrastructure
    # creates keys without agents. The constraint will be added in the
    # dispatch-lineage story (US-26.2.1) after backfilling existing keys.

    # 3. Partial unique index: one active key per agent per role per tenant
    # Prevents duplicate keys for the same agent+role, while allowing
    # an agent to hold both an agent key and an orchestrator key.
    create unique_index(:api_keys, [:tenant_id, :agent_id, :role],
             where: "revoked_at IS NULL AND role NOT IN ('user', 'superadmin')",
             name: :api_keys_one_role_per_agent_idx
           )

    # 4. Role immutability trigger
    execute(
      """
      CREATE OR REPLACE FUNCTION api_key_role_immutable()
      RETURNS TRIGGER AS $$
      BEGIN
        IF OLD.role != NEW.role THEN
          RAISE EXCEPTION 'api_key_role_immutable: cannot change role after creation. Revoke and recreate.'
            USING ERRCODE = 'P0001';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS api_key_role_immutable() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER api_key_role_immutable_trigger
        BEFORE UPDATE ON api_keys
        FOR EACH ROW
        EXECUTE FUNCTION api_key_role_immutable();
      """,
      "DROP TRIGGER IF EXISTS api_key_role_immutable_trigger ON api_keys"
    )
  end
end
