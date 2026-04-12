defmodule Loopctl.Repo.Migrations.CreateCapabilityTokens do
  use Ecto.Migration

  def change do
    create table(:capability_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
      add :typ, :string, null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :nothing)
      add :issued_to_lineage, {:array, :binary_id}, null: false, default: "{}"
      add :issued_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :nonce, :binary, null: false
      add :signature, :binary, null: false
    end

    # Replay protection: unique nonce per tenant
    create unique_index(:capability_tokens, [:tenant_id, :nonce])
    create index(:capability_tokens, [:tenant_id, :story_id])
    create index(:capability_tokens, [:tenant_id, :typ])

    # RLS
    execute(
      "ALTER TABLE capability_tokens ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE capability_tokens DISABLE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_policy ON capability_tokens
        USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
      """,
      "DROP POLICY IF EXISTS tenant_isolation_policy ON capability_tokens"
    )
  end
end
