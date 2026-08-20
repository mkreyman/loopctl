defmodule Loopctl.Repo.Migrations.DropDeadProvenanceColumnsFromRetrievalSnapshots do
  use Ecto.Migration

  @moduledoc """
  Drops the six `curated_*` / `retrieved_*` columns (US-31.2, AC-31.2.5).

  They were structurally incapable of reporting anything, and published a confident `0`
  rather than an absence:

    * Nothing has ever been curated. `curated_at` was NULL on all 85,325 production
      articles at removal, so every provenance decision resolves `:retrieved` over an
      empty candidate set and `curated_searched` was a constant `0`.
    * The buckets filtered `mode` for `hybrid_curated` / `hybrid_retrieved`, which only
      `hybrid_search/3` writes, while the DEFAULT search path has tagged the same decision
      `combined_curated` / `combined_retrieved` since #670 — 8,090 rows the metric could
      not see against 252 it could.

  No data is lost that could not be recomputed: every value is derived from
  `article_access_events`, which is not pruned, so a future breakdown that reads both tag
  namespaces can backfill any day still covered by that table.

  Irreversible by construction — `down/0` restores the columns (so a rollback boots), but
  their historical values are NOT restored. They were `0` and `0.0` on every row anyway.
  """

  def up do
    alter table(:retrieval_metric_snapshots) do
      remove :curated_searched
      remove :curated_followed_through
      remove :curated_precision
      remove :retrieved_searched
      remove :retrieved_followed_through
      remove :retrieved_precision
    end
  end

  def down do
    alter table(:retrieval_metric_snapshots) do
      add :curated_searched, :integer, default: 0, null: false
      add :curated_followed_through, :integer, default: 0, null: false
      add :curated_precision, :float, default: 0.0, null: false
      add :retrieved_searched, :integer, default: 0, null: false
      add :retrieved_followed_through, :integer, default: 0, null: false
      add :retrieved_precision, :float, default: 0.0, null: false
    end
  end
end
