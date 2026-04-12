defmodule Loopctl.Repo.Migrations.CreateAuditChain do
  use Ecto.Migration

  def change do
    create table(:audit_chain, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
      add :chain_position, :bigint, null: false
      add :prev_entry_hash, :binary, null: false
      add :action, :text, null: false
      add :actor_lineage, :map, null: false, default: "[]"
      add :entity_type, :text, null: false
      add :entity_id, :binary_id
      add :payload, :map, null: false, default: "{}"
      add :entry_hash, :binary, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    # Unique per-tenant chain position (no gaps, no duplicates)
    create unique_index(:audit_chain, [:tenant_id, :chain_position])

    # Timeline queries
    create index(:audit_chain, [:tenant_id, :inserted_at], using: "btree")

    # Action filtering
    create index(:audit_chain, [:tenant_id, :action])

    # RLS
    execute(
      "ALTER TABLE audit_chain ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE audit_chain DISABLE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_policy ON audit_chain
        USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
      """,
      "DROP POLICY IF EXISTS tenant_isolation_policy ON audit_chain"
    )

    # Trigger: prevent UPDATE
    execute(
      """
      CREATE OR REPLACE FUNCTION audit_chain_prevent_update()
      RETURNS TRIGGER AS $$
      BEGIN
        RAISE EXCEPTION 'cannot_modify_audit_chain: audit chain entries are immutable'
          USING ERRCODE = 'P0001';
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS audit_chain_prevent_update() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER audit_chain_prevent_update_trigger
        BEFORE UPDATE ON audit_chain
        FOR EACH ROW
        EXECUTE FUNCTION audit_chain_prevent_update();
      """,
      "DROP TRIGGER IF EXISTS audit_chain_prevent_update_trigger ON audit_chain"
    )

    # Trigger: prevent DELETE
    execute(
      """
      CREATE OR REPLACE FUNCTION audit_chain_prevent_delete()
      RETURNS TRIGGER AS $$
      BEGIN
        RAISE EXCEPTION 'cannot_delete_audit_chain: audit chain entries cannot be removed'
          USING ERRCODE = 'P0001';
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS audit_chain_prevent_delete() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER audit_chain_prevent_delete_trigger
        BEFORE DELETE ON audit_chain
        FOR EACH ROW
        EXECUTE FUNCTION audit_chain_prevent_delete();
      """,
      "DROP TRIGGER IF EXISTS audit_chain_prevent_delete_trigger ON audit_chain"
    )

    # Trigger: verify chain invariants on INSERT
    execute(
      """
      CREATE OR REPLACE FUNCTION audit_chain_verify_invariants()
      RETURNS TRIGGER AS $$
      DECLARE
        expected_position BIGINT;
        expected_prev_hash BYTEA;
      BEGIN
        -- Get the current max position for this tenant
        SELECT MAX(chain_position) INTO expected_position
        FROM audit_chain
        WHERE tenant_id = NEW.tenant_id;

        IF expected_position IS NULL THEN
          -- Genesis entry: position must be 0, prev_hash must be 32 zero bytes
          expected_position := 0;
          expected_prev_hash := decode(repeat('00', 32), 'hex');
        ELSE
          expected_position := expected_position + 1;
          SELECT entry_hash INTO expected_prev_hash
          FROM audit_chain
          WHERE tenant_id = NEW.tenant_id AND chain_position = expected_position - 1;
        END IF;

        -- Verify chain_position
        IF NEW.chain_position != expected_position THEN
          RAISE EXCEPTION 'audit_chain_position_violation: expected position %, got %',
            expected_position, NEW.chain_position
            USING ERRCODE = 'P0001';
        END IF;

        -- Verify prev_entry_hash
        IF NEW.prev_entry_hash != expected_prev_hash THEN
          RAISE EXCEPTION 'audit_chain_hash_violation: prev_entry_hash does not match expected'
            USING ERRCODE = 'P0001';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS audit_chain_verify_invariants() CASCADE"
    )

    execute(
      """
      CREATE TRIGGER audit_chain_verify_invariants_trigger
        BEFORE INSERT ON audit_chain
        FOR EACH ROW
        EXECUTE FUNCTION audit_chain_verify_invariants();
      """,
      "DROP TRIGGER IF EXISTS audit_chain_verify_invariants_trigger ON audit_chain"
    )
  end
end
