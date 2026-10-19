defmodule Loopctl.Repo.Migrations.AddGenerationToIntakeRecords do
  @moduledoc """
  US-47.10 (#986 item 3): an issue gets one intake record per GENERATION.

  chg closes an issue it filed only once the failure's fingerprint has been quiet for a while
  after the merge, and REOPENS it if the failure comes back. Before this, that reopen updated
  the one record of the issue, whose story had already merged or shipped, so the record
  stayed outside the triage drain for good and the recurrence was never worked. A reopen of an
  issue whose newest record has reached the end of the loop now starts a NEW record,
  `generation` one higher, and the earlier generation's record, story and closure are left as
  they were: they are the record of the first fix (`Loopctl.Intake`, "Generations").

  The column is added with a constant default, which Postgres stores as metadata without
  rewriting the table, and every existing row becomes generation 1.

  The issue's unique index gains the column. `stories_intake_record_uidx` (one story per
  record) and `intake_issue_closures_record_uidx` (one closure per record) are NOT changed:
  each generation is its own record, so each still gets at most one story and one closure.

  No new table, so no RLS change. No backfill, no manual step.

  ## The rolling deploy

  The previous release inserts records with `ON CONFLICT (tenant_id, source_id,
  issue_number)`, and Postgres can infer that target only from a unique index on exactly
  those three columns. Once this migration has run, a machine still on the previous release
  fails every `issues` delivery it receives with a 500 until it is replaced. GitHub does not
  retry a failed delivery, so a delivery that lands on an old machine during the rollout is
  lost until someone presses Redeliver in the webhook's Recent Deliveries. A redelivery
  reuses the delivery id, so it cannot be applied twice. No three-column index can be kept
  next to this one, because it would refuse generation 2. See CHANGELOG.md.

  Plain (transactional) DDL rather than `CONCURRENTLY`. `intake_records` holds one row per
  reported issue, so building the index takes milliseconds. A plain build keeps the swap
  atomic: the table is never without a unique key on the issue.
  """

  use Ecto.Migration

  def up do
    alter table(:intake_records) do
      add :generation, :integer, null: false, default: 1
    end

    create constraint(:intake_records, :intake_records_generation_positive,
             check: "generation >= 1"
           )

    create unique_index(:intake_records, [:tenant_id, :source_id, :issue_number, :generation],
             name: :intake_records_issue_generation_uidx
           )

    drop index(:intake_records, [:tenant_id, :source_id, :issue_number],
           name: :intake_records_issue_uidx
         )
  end

  # Fails while any issue has a second generation, because the three-column index refuses it,
  # and that failure is the correct answer. Rolling back would mean deleting a reopened
  # issue's queue entry together with whatever story and closure it has. That is a decision
  # for an operator, not something a migration should do on its own.
  def down do
    create unique_index(:intake_records, [:tenant_id, :source_id, :issue_number],
             name: :intake_records_issue_uidx
           )

    drop index(:intake_records, [:tenant_id, :source_id, :issue_number, :generation],
           name: :intake_records_issue_generation_uidx
         )

    drop constraint(:intake_records, :intake_records_generation_positive)

    alter table(:intake_records) do
      remove :generation
    end
  end
end
