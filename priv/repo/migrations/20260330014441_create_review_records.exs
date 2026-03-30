defmodule Loopctl.Repo.Migrations.CreateReviewRecords do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:review_records, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false

      add :reviewer_agent_id,
          references(:agents, type: :binary_id, on_delete: :nilify_all),
          null: true

      add :review_type, :string, null: false
      add :findings_count, :integer, null: false, default: 0
      add :fixes_count, :integer, null: false, default: 0
      add :summary, :text, null: true
      add :completed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:review_records, [:tenant_id])
    create index(:review_records, [:tenant_id, :story_id])

    enable_rls(:review_records)
  end
end
