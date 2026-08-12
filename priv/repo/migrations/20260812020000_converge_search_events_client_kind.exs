defmodule Loopctl.Repo.Migrations.ConvergeSearchEventsClientKind do
  @moduledoc """
  Converges `search_events` onto `client_kind`, whichever shape an environment already has.

  WHY THIS EXISTS. `20260812000000_create_search_events` first created a boolean
  `client_subagent`, and I later edited that same migration to create a string
  `client_kind` instead. Editing an ALREADY-APPLIED migration is the bug: `ecto.migrate`
  records a version as done and never re-runs it, so any database that applied the first
  shape keeps it forever and the code then queries a column that does not exist.

  It passed locally only because I had manually rolled back and re-migrated. It failed in
  CI because the self-hosted runner's Postgres is long-lived — the version was already
  recorded there, the edit was skipped, and every test touching the table died on
  `42703 undefined_column`. Any developer machine that ran the first version would have hit
  the same thing. Prod never saw either shape.

  Rather than edit history a second time, this converges every environment idempotently:
  drop the old column if present, add the new one if absent. Safe to run on a database
  that already has the final shape (both guards are no-ops), and safe on one that has the
  original.

  The lesson worth carrying: an unreleased migration still has to be treated as immutable
  the moment ANY environment has applied it, and "it passed locally" is exactly the signal
  that a persistent database elsewhere disagrees.
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE search_events DROP COLUMN IF EXISTS client_subagent"
    execute "ALTER TABLE search_events ADD COLUMN IF NOT EXISTS client_kind varchar(255)"
  end

  def down do
    # Reversing to the original boolean would DISCARD the recorded kind, and the two are not
    # equivalent (`client_kind` deliberately carries a third, offline-derived value that a
    # boolean cannot express). Dropping the column is the honest inverse.
    execute "ALTER TABLE search_events DROP COLUMN IF EXISTS client_kind"
  end
end
