defmodule Loopctl.Repo.Migrations.CreateRetrievalMetricSnapshots do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # Agents' KB #3: a daily time series of retrieval PRECISION — of the articles a search
  # surfaced, how many the agent then actually opened (search -> get/context within a
  # window). A proxy for "is retrieval getting better" that should trend up as dedup (#1),
  # navigation (#5) and conflict resolution (#4) clean the corpus.
  def change do
    create table(:retrieval_metric_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :day, :date, null: false
      add :window_seconds, :integer, null: false
      add :searched, :integer, null: false, default: 0
      add :followed_through, :integer, null: false, default: 0
      add :precision, :float, null: false, default: 0.0
      add :computed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One snapshot per (tenant, day, window). Recompute upserts.
    create unique_index(:retrieval_metric_snapshots, [:tenant_id, :day, :window_seconds],
             name: :retrieval_metric_snapshots_tenant_day_window_index
           )

    create index(:retrieval_metric_snapshots, [:tenant_id, :day])

    enable_rls(:retrieval_metric_snapshots)
  end
end
