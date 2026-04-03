defmodule Loopctl.Repo.Migrations.CreateTokenUsageReports do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:token_usage_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :input_tokens, :bigint, null: false
      add :output_tokens, :bigint, null: false

      add :model_name, :string, null: false
      add :cost_millicents, :bigint, null: false

      add :phase, :string, null: false, default: "other"
      add :session_id, :string

      add :skill_version_id,
          references(:skill_versions, type: :binary_id, on_delete: :nilify_all)

      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Generated column: total_tokens = input_tokens + output_tokens
    execute(
      "ALTER TABLE token_usage_reports ADD COLUMN total_tokens bigint GENERATED ALWAYS AS (input_tokens + output_tokens) STORED",
      "ALTER TABLE token_usage_reports DROP COLUMN total_tokens"
    )

    # Phase CHECK constraint
    execute(
      "ALTER TABLE token_usage_reports ADD CONSTRAINT token_usage_reports_phase_check CHECK (phase IN ('planning', 'implementing', 'reviewing', 'other'))",
      "ALTER TABLE token_usage_reports DROP CONSTRAINT token_usage_reports_phase_check"
    )

    # Composite indexes for common query patterns
    create index(:token_usage_reports, [:tenant_id, :story_id])
    create index(:token_usage_reports, [:tenant_id, :agent_id])
    create index(:token_usage_reports, [:tenant_id, :project_id])
    create index(:token_usage_reports, [:tenant_id, :inserted_at])

    enable_rls(:token_usage_reports)
  end
end
