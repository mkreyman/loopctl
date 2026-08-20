defmodule Loopctl.Repo.Migrations.AddMetricVersionToRetrievalSnapshots do
  use Ecto.Migration

  @moduledoc """
  Records WHICH SET OF DEFINITIONS produced each retrieval-metric snapshot row.

  Three changes have already altered what a figure in this table MEANS, each forward-looking,
  each leaving no mark on the row: #582 redefined `searched` from search calls to recorded
  surfaced results, #673 began excluding infrastructure traffic, and #711 rescoped the
  disposition trio and fixed a reformulation predicate that had been measuring search density.

  A reader comparing across one of those boundaries is comparing definitions rather than days,
  and nothing in the data let them notice. That is the mechanism behind every "these numbers
  don't make sense" report this table has produced, and it is what this column ends.

  Defaults to `0`, meaning "written before the stamp existed, definitions unknown". Existing
  rows are deliberately NOT backfilled to `1`: they were computed by older code and claiming
  otherwise would be the exact false confidence this column exists to remove.
  """

  def change do
    alter table(:retrieval_metric_snapshots) do
      add :metric_version, :integer, default: 0, null: false
    end
  end
end
