defmodule Loopctl.Repo.Migrations.AddCallLevelColumnsToRetrievalMetricSnapshots do
  use Ecto.Migration

  # #582: `precision` is followed_through / searched, where `searched` counts SURFACED
  # RESULTS — one row per result a search put in front of an agent. It was read as
  # "share of searches that led to an open", a different and much smaller denominator,
  # and that misreading made it out of the system.
  #
  # `precision` keeps its meaning and its column: silently redefining a persisted series
  # would make every historical row incomparable. The per-CALL quantity is added
  # ALONGSIDE it (`searches`, `searches_with_follow_through`, `search_follow_through`)
  # so the two can be told apart instead of confused, plus `results_returned` — the true
  # un-truncated result count for the counted CALLS, so the per-search recording cap is
  # reported instead of silently shrinking the denominator. Do NOT read the cap off
  # `searched` vs `results_returned`: the two aggregate different row populations (the
  # call-level filter is per ROW), so `results_returned < searched` is the normal shape of
  # a legacy-heavy or browse-heavy day, not a truncation signal.
  #
  # Rows written before this migration carry 0/0.0: the source events have no
  # `search_id` in metadata, so no call-level figure can be reconstructed for them.
  # Same "additive, never breaking" convention as the provenance-breakdown columns.
  def change do
    alter table(:retrieval_metric_snapshots) do
      add :searches, :integer, null: false, default: 0
      add :searches_with_follow_through, :integer, null: false, default: 0
      add :search_follow_through, :float, null: false, default: 0.0
      add :results_returned, :integer, null: false, default: 0
    end
  end
end
