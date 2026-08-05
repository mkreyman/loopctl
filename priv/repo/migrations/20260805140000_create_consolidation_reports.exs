defmodule Loopctl.Repo.Migrations.CreateConsolidationReports do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # #584 stage 1 — the nightly consolidation ("dream") pass, REPORT ONLY.
  #
  # One report row per (tenant, day) plus its numbered proposals. The pass writes
  # NOTHING to `articles`, `article_links` or `conflict_resolutions`; these two
  # tables are the entire write surface, so the calibration stage (#584 stage 2)
  # has something to approve against.
  def change do
    create table(:consolidation_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :day, :date, null: false
      add :generated_at, :utc_datetime_usec, null: false
      # Published articles in the scanned scope at scan time — the denominator for
      # every "share of the corpus" reading of proposal_count.
      add :corpus_size, :integer, null: false, default: 0
      # TRUE pre-cap proposal total across all classes. `persisted_count` is how many
      # proposal ROWS this report actually carries (fewer when a class truncates).
      add :proposal_count, :integer, null: false, default: 0
      add :persisted_count, :integer, null: false, default: 0
      add :proposals_by_class, :map, null: false, default: %{}
      add :truncated, :map, null: false, default: %{}
      add :max_per_class, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:consolidation_reports, [:tenant_id, :day],
             name: :consolidation_reports_tenant_day_index
           )

    enable_rls(:consolidation_reports)

    create table(:consolidation_proposals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :report_id,
          references(:consolidation_reports, type: :binary_id, on_delete: :delete_all),
          null: false

      add :number, :integer, null: false
      add :proposal_class, :string, null: false
      add :article_ids, {:array, :binary_id}, null: false, default: []
      add :evidence, {:array, :map}, null: false, default: []
      add :rationale, :text, null: false
      add :suggested_action, :text, null: false
      add :severity, :string, null: false, default: "info"
      # Stable across runs: class + the sorted article-id set. A re-run UPSERTS the
      # same proposal rather than duplicating it.
      add :fingerprint, :string, null: false

      # Human judgment (used by #584 stage 2). A re-run of the machine step RESETS
      # these in the same on_conflict clause — see ConsolidationProposal's moduledoc.
      add :review_status, :string, null: false, default: "pending"
      add :reviewed_by, :string
      add :reviewed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:consolidation_proposals, [:report_id, :fingerprint],
             name: :consolidation_proposals_report_fingerprint_index
           )

    create index(:consolidation_proposals, [:tenant_id, :report_id, :number])

    enable_rls(:consolidation_proposals)
  end
end
