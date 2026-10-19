defmodule Loopctl.Repo.Migrations.AddChgModeToIntakeSources do
  @moduledoc """
  US-47.2: intake mode `chg`, the forcing function that closes the PR route for a repository
  enrolled in the change protocol (Epic 47 PRD §3 item 3, §5, §6).

  - `intake_sources_mode` widens to `('pr', 'chg')`.
  - `change_events_secret` — the HMAC key chg-server signs its event webhook with
    (`POST /api/v1/change_events/:source_id`, PRD §5). `bytea`, encrypted by the application
    exactly as `webhook_secret` is (`Loopctl.Vault.Binary`, AES-256-GCM). It is a SEPARATE
    column because `webhook_secret` is GitHub's and is not reused.
  - `chg_root_dispatch_id` — the parentless orchestrator-role dispatch chg-server's key was
    minted from (PRD §6). A custody input: later stories accept a review only from a CHILD of
    it and refuse it as a verifier.
  - `intake_sources_chg_requires_credentials` — a `chg` source carries BOTH. The application
    refuses the write first (422); this is the database's copy of the same rule, so a backfill
    or a repair script cannot enrol a `chg` source that no event could ever authenticate to.

  ## The reference to `dispatches` is single-column, like every other one

  `stories.implementer_dispatch_id`, `stories.verifier_dispatch_id` and
  `story_acceptance_criteria.verified_by_dispatch_id` all reference `dispatches(id)` alone,
  `ON DELETE NO ACTION`. A composite `(tenant_id, id)` reference would need a unique index on
  `dispatches (tenant_id, id)`, a hot write path that would have to be built CONCURRENTLY in a
  migration of its own; the cross-tenant case is instead refused by `Loopctl.Intake`, which
  reads the dispatch by id AND tenant under `FOR SHARE` inside the write's transaction, and
  answers an unknown id and another tenant's id with the same `422 chg_root_invalid`.

  NO ACTION rather than RESTRICT for the reason `20260921100000_add_target_epic_to_intake_sources`
  records: it is re-checked at the end of the statement, so a delete that removes both sides in
  one statement is not refused by trigger firing order. Production never deletes dispatches;
  the test sweep that does clears this column first.

  The partial index serves that referential check, which a dispatch delete runs per row
  (`20260928140000_index_foreign_keys_into_dispatches`). `intake_sources` is small, so it is
  built in the migration's transaction.
  """

  use Ecto.Migration

  def up do
    alter table(:intake_sources) do
      add :change_events_secret, :binary
      add :chg_root_dispatch_id, references(:dispatches, type: :binary_id, on_delete: :nothing)
    end

    drop constraint(:intake_sources, :intake_sources_mode)
    create constraint(:intake_sources, :intake_sources_mode, check: "mode IN ('pr', 'chg')")

    create constraint(:intake_sources, :intake_sources_chg_requires_credentials,
             check:
               "mode <> 'chg' OR " <>
                 "(change_events_secret IS NOT NULL AND chg_root_dispatch_id IS NOT NULL)"
           )

    create index(:intake_sources, [:chg_root_dispatch_id],
             where: "chg_root_dispatch_id IS NOT NULL"
           )
  end

  def down do
    drop index(:intake_sources, [:chg_root_dispatch_id])
    drop constraint(:intake_sources, :intake_sources_chg_requires_credentials)

    # A `chg` source has no route once the column it names is gone, so it goes back to `pr`
    # before the CHECK narrows.
    execute("UPDATE intake_sources SET mode = 'pr' WHERE mode = 'chg'")
    drop constraint(:intake_sources, :intake_sources_mode)
    create constraint(:intake_sources, :intake_sources_mode, check: "mode IN ('pr')")

    alter table(:intake_sources) do
      remove :chg_root_dispatch_id
      remove :change_events_secret
    end
  end
end
