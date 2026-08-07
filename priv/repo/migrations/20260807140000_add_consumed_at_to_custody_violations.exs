defmodule Loopctl.Repo.Migrations.AddConsumedAtToCustodyViolations do
  use Ecto.Migration

  # Stamped when this row has been CLAIMED as the evidence for a halt. The row is
  # retained (the forensic record is the point), but it can never arm a second
  # halt — which is what lets the break-glass ceremony actually recover a tenant
  # instead of leaving a loaded window behind it.
  #
  # Its own migration rather than an edit to CreateCustodyViolations: any database
  # that already ran that version records it in `schema_migrations` and would never
  # pick the column up, and every ViolationMonitor query references it — a miss
  # raises inside `record/3`'s rescue and turns L6 silently OFF, which is the exact
  # failure this column exists to prevent. `add_if_not_exists` so the boxes that
  # ran the in-place edit converge here too.
  def change do
    alter table(:custody_violations) do
      add_if_not_exists :consumed_at, :utc_datetime_usec
    end
  end
end
