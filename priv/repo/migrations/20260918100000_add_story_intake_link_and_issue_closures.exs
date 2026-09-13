defmodule Loopctl.Repo.Migrations.AddStoryIntakeLinkAndIssueClosures do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # Issues #803 §4/§9 and #805: the story-to-intake link, and the at-most-once record of
  # closing the reporter's GitHub issue.
  #
  # `stories.intake_record_id` is PROVENANCE, the same kind of field as
  # `implementer_dispatch_id`: set once at creation, never rewritten, and absent from every
  # changeset `cast` list. It is NULLABLE and always will be — most stories are authored,
  # never reported, and nothing may require one.
  #
  # `intake_issue_closures` is the outbox. One row per story, inserted inside the very
  # transaction that writes the terminal verdict, and drained by
  # `Loopctl.Workers.IntakeIssueCloseWorker` OUTSIDE any transaction. The unique index on
  # (tenant_id, story_id) IS the at-most-once guarantee: closing a reporter's ticket is an
  # outward act on somebody else's system, and a second close re-fires the reporting
  # system's resolution email.
  def change do
    # ---------------------------------------------------------------------------------
    # The link
    # ---------------------------------------------------------------------------------

    # The composite FK below needs a unique key on exactly these two columns. `id` alone is
    # already unique; this pair is what lets Postgres refuse a story pointing at ANOTHER
    # TENANT'S record, rather than leaving that to an application check somebody can forget.
    create unique_index(:intake_records, [:tenant_id, :id], name: :intake_records_tenant_id_uidx)

    alter table(:stories) do
      add :intake_record_id, :binary_id, null: true
    end

    create index(:stories, [:tenant_id, :intake_record_id],
             where: "intake_record_id IS NOT NULL",
             name: :stories_intake_record_idx
           )

    # MATCH SIMPLE (the default) is what makes the link OPTIONAL and the tenant binding
    # MANDATORY at the same time: with any column NULL the constraint is not checked, and
    # `intake_record_id` is the nullable one — so an unlinked story is unconstrained while a
    # linked one must name a record of its OWN tenant.
    #
    # NO ACTION, never RESTRICT: deleting a tenant cascades `stories` and `intake_records`
    # in one statement, and only NO ACTION re-checks at the end of it, by which point the
    # referencing story is gone too. RESTRICT checks immediately and would refuse the
    # tenant delete.
    execute(
      """
      ALTER TABLE stories
        ADD CONSTRAINT stories_intake_record_fkey
        FOREIGN KEY (tenant_id, intake_record_id)
        REFERENCES intake_records (tenant_id, id)
        ON DELETE NO ACTION
      """,
      "ALTER TABLE stories DROP CONSTRAINT stories_intake_record_fkey"
    )

    # ---------------------------------------------------------------------------------
    # The closure outbox
    # ---------------------------------------------------------------------------------

    create table(:intake_issue_closures, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false

      add :intake_record_id,
          references(:intake_records, type: :binary_id, on_delete: :delete_all),
          null: false

      # The TARGET, captured at verdict time rather than joined at close time. The outward
      # act must address the issue the verdict was about, not whatever the record points at
      # by the time a worker gets to it.
      add :repo_full_name, :text, null: false
      add :issue_number, :integer, null: false

      add :verdict, :text, null: false
      add :status, :text, null: false, default: "pending"

      # Per-step markers. Each is written straight after its own forge call, so a crash
      # duplicates AT MOST the one step it died inside, never the whole sequence.
      add :labelled_at, :utc_datetime_usec, null: true
      add :commented_at, :utc_datetime_usec, null: true
      add :closed_at, :utc_datetime_usec, null: true

      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec, null: true
      add :last_error, :text, null: true
      add :abandoned_reason, :text, null: true

      timestamps(type: :utc_datetime_usec)
    end

    # THE at-most-once guarantee. Not a code path, not a status check: one row per story,
    # decided by the index, so two concurrent verdict transitions insert one row between
    # them and a replay inserts none.
    create unique_index(:intake_issue_closures, [:tenant_id, :story_id],
             name: :intake_issue_closures_story_uidx
           )

    # The drainer's candidate read: pending work, oldest first.
    create index(:intake_issue_closures, [:status, :next_attempt_at],
             name: :intake_issue_closures_due_idx
           )

    create constraint(:intake_issue_closures, :intake_issue_closures_verdict,
             check: "verdict IN ('shipped', 'not_actionable')"
           )

    create constraint(:intake_issue_closures, :intake_issue_closures_status,
             check: "status IN ('pending', 'closed', 'abandoned')"
           )

    # A closed row always says WHEN, and only a closed row does. An abandoned row always
    # says WHY, and only an abandoned row does. Neither claim can be made by a row that is
    # still pending.
    create constraint(:intake_issue_closures, :intake_issue_closures_terminal_shape,
             check:
               "(status = 'closed') = (closed_at IS NOT NULL) AND " <>
                 "(status = 'abandoned') = (abandoned_reason IS NOT NULL)"
           )

    create constraint(:intake_issue_closures, :intake_issue_closures_issue_number,
             check: "issue_number > 0"
           )

    create constraint(:intake_issue_closures, :intake_issue_closures_attempts,
             check: "attempts >= 0"
           )

    # Text bounds, so a forge reason echoed onto the row can never be the thing that makes
    # the write fail. Same reasoning as `story_stages_text_bounds`.
    create constraint(:intake_issue_closures, :intake_issue_closures_text_bounds,
             check:
               "octet_length(repo_full_name) <= 200 AND " <>
                 "(last_error IS NULL OR char_length(last_error) <= 2000) AND " <>
                 "(abandoned_reason IS NULL OR char_length(abandoned_reason) <= 2000)"
           )

    enable_rls(:intake_issue_closures)
  end
end
