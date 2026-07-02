defmodule Loopctl.Repo.Migrations.AddCorrectsReportIdIndex do
  use Ecto.Migration

  # Supports the tokens-03 archival "skip-if-referenced" guard, whose
  # `NOT EXISTS (... WHERE corrects_report_id = <original>.id)` self-join
  # otherwise triggers a full table scan on every hard-delete batch, for every
  # tenant, every weekly run. Partial index (only correction rows carry a
  # non-null corrects_report_id) keeps it small. Also supports the tokens-04
  # "count a correction only if its original is live" lookups.
  #
  # Index only — no RLS change needed.
  def change do
    create index(:token_usage_reports, [:corrects_report_id],
             where: "corrects_report_id IS NOT NULL",
             name: :token_usage_reports_corrects_report_id_idx
           )
  end
end
