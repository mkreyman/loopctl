defmodule Loopctl.Repo.Migrations.CreateVerificationRuns do
  use Ecto.Migration

  def change do
    create table(:verification_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :nothing), null: false
      add :commit_sha, :text
      add :commit_content_hash, :binary
      add :status, :string, null: false, default: "pending"
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :runner_type, :string
      add :ac_results, :map, default: "{}"
      add :logs_url, :text
      add :machine_id, :text

      timestamps()
    end

    create index(:verification_runs, [:tenant_id])
    create index(:verification_runs, [:story_id])
    create index(:verification_runs, [:status])

    execute(
      "ALTER TABLE verification_runs ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE verification_runs DISABLE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_policy ON verification_runs
        USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
      """,
      "DROP POLICY IF EXISTS tenant_isolation_policy ON verification_runs"
    )
  end
end
