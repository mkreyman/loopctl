defmodule Loopctl.Repo.Migrations.AddChangeStageMapping do
  @moduledoc """
  US-47.4: the stage mapping from chg change events (Epic 47 PRD §5).

  - `story_stages.trunk_verified_sha` — the `verified/master` commit chg's trunk verifier
    passed on, recorded from a `verified` event. A record, not a stage, and merge-keyed
    (`Loopctl.Delivery.StageMachine.merge_keyed/0`), so it is cleared with `merge_sha`.
  - `change_revert_issues` — the OUTBOX for the GitHub issue a revert opens when it reaches a
    story that is already `done` (AC-47.4.5). The event's transaction writes one row; the
    drainer (`Loopctl.Workers.ChangeRevertIssueWorker`) opens the issue later with nothing
    held, so the webhook still makes no outbound call. One row per revert, decided by the
    unique index on the event's own key.

  A nullable column and a new table, so the code running before this release keeps working
  against the new schema during Fly's rolling deploy. The new edges need no constraint: no
  CHECK lists edges, and `story_stage_events_event` already allows the `effect_recorded` and
  `transitioned` events they write.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  @sha "'^[0-9a-f]{40}([0-9a-f]{24})?$'"

  def up do
    alter table(:story_stages) do
      add :trunk_verified_sha, :text, null: true
    end

    create constraint(:story_stages, :story_stages_trunk_verified_sha,
             check: "trunk_verified_sha ~ #{@sha}"
           )

    create table(:change_revert_issues, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false

      add :source_id, references(:intake_sources, type: :binary_id, on_delete: :delete_all),
        null: false

      # The reverted event's own key, canonical like `change_events.repo`.
      add :repo, :text, null: false
      add :change_id, :text, null: false
      add :event_seq, :bigint, null: false

      # The TARGET and the text, captured when the revert applied: the outward act addresses
      # the repository the event was about and says what chg said then.
      add :repo_full_name, :text, null: false
      add :title, :text, null: false
      add :body, :text, null: false

      add :status, :text, null: false, default: "pending"
      add :issue_number, :integer, null: true
      add :opened_at, :utc_datetime_usec, null: true

      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec, null: true
      add :last_error, :text, null: true
      add :abandoned_reason, :text, null: true

      timestamps(type: :utc_datetime_usec)
    end

    # THE at-most-once guarantee: one row per revert event, so a redelivery, a pull and a
    # replay insert none.
    create unique_index(:change_revert_issues, [:tenant_id, :repo, :change_id, :event_seq],
             name: :change_revert_issues_event_uidx
           )

    # The drainer's candidate read, as `intake_issue_closures_due_idx` serves its own.
    create index(:change_revert_issues, [:inserted_at, :id],
             where: "status = 'pending'",
             name: :change_revert_issues_due_idx
           )

    create constraint(:change_revert_issues, :change_revert_issues_repo_canonical,
             check: "repo = lower(repo)"
           )

    create constraint(:change_revert_issues, :change_revert_issues_status,
             check: "status IN ('pending', 'opened', 'abandoned')"
           )

    # An opened row always names its issue and when, and only an opened row does. An
    # abandoned row always says why, and only an abandoned row does.
    create constraint(:change_revert_issues, :change_revert_issues_terminal_shape,
             check:
               "(status = 'opened') = (opened_at IS NOT NULL AND issue_number IS NOT NULL) AND " <>
                 "(status = 'abandoned') = (abandoned_reason IS NOT NULL)"
           )

    create constraint(:change_revert_issues, :change_revert_issues_issue_number,
             check: "issue_number > 0"
           )

    create constraint(:change_revert_issues, :change_revert_issues_counts,
             check: "attempts >= 0 AND event_seq >= 1"
           )

    create constraint(:change_revert_issues, :change_revert_issues_text_bounds,
             check:
               "octet_length(repo_full_name) <= 200 AND octet_length(repo) <= 200 AND " <>
                 "octet_length(change_id) <= 255 AND " <>
                 "char_length(title) BETWEEN 1 AND 256 AND " <>
                 "octet_length(body) BETWEEN 1 AND 65536 AND " <>
                 "(last_error IS NULL OR char_length(last_error) <= 2000) AND " <>
                 "(abandoned_reason IS NULL OR char_length(abandoned_reason) <= 2000)"
           )

    enable_rls(:change_revert_issues)
  end

  def down do
    drop table(:change_revert_issues)
    drop constraint(:story_stages, :story_stages_trunk_verified_sha)

    alter table(:story_stages) do
      remove :trunk_verified_sha
    end
  end
end
