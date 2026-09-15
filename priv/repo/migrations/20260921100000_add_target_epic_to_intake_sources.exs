defmodule Loopctl.Repo.Migrations.AddTargetEpicToIntakeSources do
  @moduledoc """
  Where a triaged story lands (issue #803 §4).

  A story requires an epic, and an intake source only knew its project — so the worker that
  turns a reported issue into a story had nowhere to put it. Three shapes were possible: the
  source names an epic, the worker finds-or-creates a per-project one, or it picks by some
  rule over the existing epics.

  The source names it, because the other two guess. Find-or-create makes a worker a writer of
  work-breakdown structure as a side effect of a webhook arriving, and any rule over existing
  epics is a convention nobody declared that breaks the first time a project's epics are
  reorganised. An operator enrolling a source already knows where its work belongs; this is
  the field where they say so.

  NULLABLE, and that is the whole backward-compatibility story: every source enrolled before
  this migration keeps working, and a record arriving from a source with no target epic is
  ESCALATED to a human rather than landing somewhere chosen for it. An unset column means the
  question has not been answered, which is different from any answer this migration could
  invent.

  `ON DELETE RESTRICT`, not `nilify` or `delete_all`: deleting an epic that an active source
  points at would silently turn that source's next report into an escalation (nilify), or
  delete the source and lose the webhook binding (delete_all). Refusing the delete makes the
  operator look at the source first, which is the only one of the three where nothing changes
  behind their back.
  """
  use Ecto.Migration

  def change do
    alter table(:intake_sources) do
      add :target_epic_id,
          references(:epics, type: :binary_id, on_delete: :restrict),
          null: true
    end

    # Partial: only the rows that name an epic, which is the set the FK and any
    # "what points at this epic" question care about.
    create index(:intake_sources, [:target_epic_id], where: "target_epic_id IS NOT NULL")
  end
end
