defmodule Loopctl.Repo.Migrations.CreateStoryAcceptanceCriteria do
  use Ecto.Migration

  def change do
    create table(:story_acceptance_criteria, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :ac_id, :string, null: false
      add :description, :text, null: false
      add :verification_criterion, :map, default: ~s({"type": "manual", "description": "legacy"})
      add :status, :string, null: false, default: "pending"
      add :verified_at, :utc_datetime_usec
      add :verified_by_dispatch_id, references(:dispatches, type: :binary_id, on_delete: :nothing)
      add :evidence_path, :text

      timestamps()
    end

    create unique_index(:story_acceptance_criteria, [:story_id, :ac_id])
    create index(:story_acceptance_criteria, [:tenant_id])
    create index(:story_acceptance_criteria, [:story_id])

    # RLS
    execute(
      "ALTER TABLE story_acceptance_criteria ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE story_acceptance_criteria DISABLE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_policy ON story_acceptance_criteria
        USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
      """,
      "DROP POLICY IF EXISTS tenant_isolation_policy ON story_acceptance_criteria"
    )

    # Backfill existing stories' jsonb ACs into the new table
    execute(
      """
      INSERT INTO story_acceptance_criteria (id, tenant_id, story_id, ac_id, description, verification_criterion, status, inserted_at, updated_at)
      SELECT
        gen_random_uuid(),
        s.tenant_id,
        s.id,
        COALESCE(ac->>'id', 'AC-' || row_number() OVER (PARTITION BY s.id ORDER BY ordinality)),
        COALESCE(ac->>'description', ac->>'criterion', 'No description'),
        '{"type": "manual", "description": "legacy"}',
        'pending',
        NOW(),
        NOW()
      FROM stories s,
        LATERAL jsonb_array_elements(s.acceptance_criteria) WITH ORDINALITY AS t(ac, ordinality)
      WHERE s.acceptance_criteria IS NOT NULL
        AND jsonb_array_length(s.acceptance_criteria) > 0
      ON CONFLICT (story_id, ac_id) DO NOTHING
      """,
      "DELETE FROM story_acceptance_criteria WHERE verification_criterion->>'description' = 'legacy'"
    )
  end
end
