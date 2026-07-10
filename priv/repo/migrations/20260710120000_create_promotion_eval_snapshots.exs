defmodule Loopctl.Repo.Migrations.CreatePromotionEvalSnapshots do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # Epic 29 / US-29.5: a daily time series of the memory-promotion COMPILER's quality —
  # precision & recall of `Loopctl.Memory.Promoter`'s emitted durable-fact candidates
  # against a COMMITTED labeled synthetic dataset (known expected facts vs. known noise,
  # including an injection case). Calibration/observability ONLY — it never gates
  # promotion (that stays the US-29.1 confidence threshold) and never re-judges
  # production memories with an LLM. Modeled on `retrieval_metric_snapshots` (US-27.15).
  def change do
    create table(:promotion_eval_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :day, :date, null: false
      add :dataset_version, :string, null: false
      add :session_count, :integer, null: false, default: 0
      add :true_positives, :integer, null: false, default: 0
      add :false_positives, :integer, null: false, default: 0
      add :false_negatives, :integer, null: false, default: 0
      add :precision, :float, null: false, default: 0.0
      add :recall, :float, null: false, default: 0.0
      add :computed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One snapshot per (tenant, dataset_version, day). A recompute upserts.
    create unique_index(:promotion_eval_snapshots, [:tenant_id, :dataset_version, :day],
             name: :promotion_eval_snapshots_tenant_version_day_index
           )

    create index(:promotion_eval_snapshots, [:tenant_id, :day])

    enable_rls(:promotion_eval_snapshots)
  end
end
