defmodule Loopctl.Repo.Migrations.AddCustodyOwnerKeyHistory do
  use Ecto.Migration

  @moduledoc """
  LCP-1 §9.2 owner-key ROTATION history — so prior root attestations stay
  offline-verifiable after the owner key rotates.

  `register_custody_owner_key/3` doubles as rotation and overwrites
  `tenants.custody_owner_pubkey` in place. Every ROOT dispatch attestation was
  signed by the owner key that was current at enrollment time, so once the key
  rotates a third party can no longer re-verify those root enrollments offline
  against the sole advertised key — defeating the §9.2 "re-verify the enrollment
  chain offline" goal. This adds the analogue of `tenant_audit_key_history`:

    * `tenant_custody_owner_key_history` — every retired owner key with its
      `[rotated_in, rotated_out)` validity window, so a verifier can pick the key
      that was current when a given root attestation was signed.

    * `tenants.custody_owner_key_set_at` — when the CURRENT owner key became
      active, so a rotation knows the retiring key's `rotated_in` boundary.

  Additive and nullable; existing tenants are untouched. RLS is ENABLE (never
  FORCE), matching every other tenant-scoped table.
  """

  def up do
    alter table(:tenants) do
      add :custody_owner_key_set_at, :utc_datetime_usec
    end

    create table(:tenant_custody_owner_key_history, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :public_key, :binary, null: false
      add :alg, :string, null: false
      add :rotated_in, :utc_datetime_usec, null: false
      add :rotated_out, :utc_datetime_usec, null: false

      timestamps()
    end

    create index(:tenant_custody_owner_key_history, [:tenant_id])

    execute(
      "ALTER TABLE tenant_custody_owner_key_history ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE tenant_custody_owner_key_history DISABLE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation ON tenant_custody_owner_key_history
        USING (tenant_id = current_tenant_id())
      """,
      "DROP POLICY IF EXISTS tenant_isolation ON tenant_custody_owner_key_history"
    )
  end

  def down do
    execute("DROP POLICY IF EXISTS tenant_isolation ON tenant_custody_owner_key_history")
    drop table(:tenant_custody_owner_key_history)

    alter table(:tenants) do
      remove :custody_owner_key_set_at
    end
  end
end
