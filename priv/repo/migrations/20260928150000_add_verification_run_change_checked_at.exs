defmodule Loopctl.Repo.Migrations.AddVerificationRunChangeCheckedAt do
  @moduledoc """
  US-26.4.6: `verification_runs.change_checked_at` — when the run's commit passed story
  verification's change check (it is not an empty change and touches no CI definition, by the
  merge gate's own rules). The check runs ONCE per run: a merge landing during the run's CI
  wait empties the commit's diff with the base, and must not turn a commit already checked
  into a refused one (AC-26.4.6.3). NULL until the check passes, which is also every existing
  row: none of them was ever checked.

  A migration of its own rather than an edit to `20260928120000`, so a database that already
  ran that one still gets this column. No RLS change: the table's policy covers new columns.
  """

  use Ecto.Migration

  def change do
    alter table(:verification_runs) do
      add :change_checked_at, :utc_datetime_usec
    end
  end
end
