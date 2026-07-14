defmodule Loopctl.Repo.Migrations.CreateAuditSthCheckpoints do
  use Ecto.Migration

  @moduledoc """
  US-35.1 — Additive `CREATE TABLE` for the per-tenant incremental STH
  checkpoint (stable Merkle peaks + last chain_position). CREATE TABLE does
  not touch or lock `audit_chain` / `audit_signed_tree_heads`.

  RLS is ENABLED (not FORCED) per project rule: the production role
  (`schema_admin`) owns the table without BYPASSRLS, and the STH job path reads
  via `Loopctl.AdminRepo` (BYPASSRLS) with an explicit `tenant_id` predicate.
  """

  def change do
    create table(:audit_sth_checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
      add :chain_position, :bigint, null: false
      add :peaks, {:array, :binary}, null: false
      timestamps(type: :utc_datetime_usec)
    end

    # One checkpoint per tenant (upserted on conflict).
    create unique_index(:audit_sth_checkpoints, [:tenant_id])

    execute(
      "ALTER TABLE audit_sth_checkpoints ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE audit_sth_checkpoints DISABLE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_policy ON audit_sth_checkpoints
        USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
      """,
      "DROP POLICY IF EXISTS tenant_isolation_policy ON audit_sth_checkpoints"
    )
  end
end
