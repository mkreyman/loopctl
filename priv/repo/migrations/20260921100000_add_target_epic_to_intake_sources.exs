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
  escalated to a human rather than landing somewhere chosen for it. An unset column means the
  question has not been answered, which is different from any answer this migration could
  invent.

  ## NO ACTION, never RESTRICT — and this repository already said so

  `20260918100000_add_story_intake_link_and_issue_closures.exs` states the rule for the
  sibling reference and the reason is identical here: deleting a tenant cascades `epics` and
  `intake_sources` as two independent paths in one statement, and only NO ACTION re-checks at
  the END of it, by which point the referencing source is gone too. RESTRICT checks
  immediately, so whether a tenant delete succeeded would depend on which cascade fired first
  — and the firing order is by RI trigger NAME, so the same schema could behave differently
  on two databases.

  The first version of this migration used RESTRICT. It was caught in review, and the way it
  was failing is worth recording: `sweep_committed_runner_tenants/0` hard-deletes its test
  tenants behind a bare `rescue`, so the refusal was swallowed as a warning and the shared
  test database accumulated undeletable tenants instead of the suite going red.

  ## Composite, so a cross-tenant target epic is not merely discouraged

  `(tenant_id, target_epic_id) REFERENCES epics (tenant_id, id)`, the same shape and for the
  same stated reason as `stories_intake_record_fkey`: a single-column reference to `epics(id)`
  leaves application code as the only thing stopping a source in one tenant targeting an epic
  in another, and any other writer — a backfill, a repair script, a future update path —
  would be accepted by the database. It needs a unique index on `(tenant_id, id)` to point
  at, which `epics` did not have.
  """
  use Ecto.Migration

  def change do
    # The target the composite reference needs. `id` is already unique on its own, so this
    # adds no constraint that was not already true; it exists so the FK below can be written.
    create unique_index(:epics, [:tenant_id, :id], name: :epics_tenant_id_uidx)

    alter table(:intake_sources) do
      add :target_epic_id, :binary_id, null: true
    end

    execute(
      """
      ALTER TABLE intake_sources
        ADD CONSTRAINT intake_sources_target_epic_fkey
        FOREIGN KEY (tenant_id, target_epic_id)
        REFERENCES epics (tenant_id, id)
        ON DELETE NO ACTION
      """,
      "ALTER TABLE intake_sources DROP CONSTRAINT intake_sources_target_epic_fkey"
    )

    # Partial: only the rows that name an epic, which is the set the FK and any
    # "what points at this epic" question care about.
    create index(:intake_sources, [:target_epic_id], where: "target_epic_id IS NOT NULL")
  end
end
