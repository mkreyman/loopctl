defmodule Loopctl.Repo.Migrations.AddProvenanceBreakdownToRetrievalMetricSnapshots do
  use Ecto.Migration

  # US-31.2 review finding 3 (AC-31.2.5): the hybrid resolver's provenance decision
  # (curated vs retrieved) needs to be observable through the NAMED RetrievalMetrics /
  # retrieval_metric_snapshot surface, not just via ad-hoc raw `article_access_events`
  # queries on the `mode` metadata tag. Adds a curated/retrieved breakdown alongside
  # the existing aggregate searched/followed_through/precision columns.
  def change do
    alter table(:retrieval_metric_snapshots) do
      add :curated_searched, :integer, null: false, default: 0
      add :curated_followed_through, :integer, null: false, default: 0
      add :curated_precision, :float, null: false, default: 0.0
      add :retrieved_searched, :integer, null: false, default: 0
      add :retrieved_followed_through, :integer, null: false, default: 0
      add :retrieved_precision, :float, null: false, default: 0.0
    end
  end
end
