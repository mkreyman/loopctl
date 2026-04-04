defmodule Loopctl.Repo.Migrations.AddSoftDeleteAndCorrectionsToTokenUsage do
  use Ecto.Migration

  def change do
    # --- token_usage_reports: soft delete and corrections ---

    alter table(:token_usage_reports) do
      add :deleted_at, :utc_datetime_usec, null: true
      add :corrects_report_id, references(:token_usage_reports, type: :binary_id), null: true
    end

    # Partial index for active (non-deleted) reports — used by tenant-scoped queries
    execute(
      "CREATE INDEX token_usage_reports_active_idx ON token_usage_reports (tenant_id, story_id) WHERE deleted_at IS NULL",
      "DROP INDEX token_usage_reports_active_idx"
    )

    # --- cost_summaries: stale flag ---

    alter table(:cost_summaries) do
      add :stale, :boolean, default: false, null: false
    end
  end
end
