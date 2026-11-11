defmodule Loopctl.Repo.Migrations.CreateChangeEvents do
  @moduledoc """
  US-47.3: the change-events webhook's record (Epic 47 PRD §5).

  `change_events` holds every event chg-server delivered (or loopctl pulled) for a change, one
  row per `(tenant_id, repo, change_id, event_seq)`. That unique index IS the idempotency key: a
  redelivery inserts nothing. `applied_at` is NULL while an event waits ahead of a gap.

  `change_cursors` holds one row per change: how far its events have been applied
  (`applied_seq`), when the last one arrived, and when loopctl last pulled it. The row is also
  the per-change LOCK every ingest takes, so two events of one change never apply concurrently.

  `repo` is the canonical key on both tables — the repository name downcased
  (`Loopctl.Changes.Events.repo_key/1`) — held by a CHECK, so a spelling variant can never
  split one change across two keys.

  Two new tables and nothing else, so the code running before this release keeps working
  against the new schema during Fly's rolling deploy.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def up do
    create table(:change_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :source_id, references(:intake_sources, type: :binary_id, on_delete: :delete_all),
        null: false

      add :repo, :string, null: false
      add :change_id, :string, null: false
      add :event_seq, :bigint, null: false
      add :kind, :string, null: false
      add :revision, :integer, null: false
      add :sha, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :data, :map, null: false, default: %{}
      add :received_via, :string, null: false
      add :applied_at, :utc_datetime_usec
      add :effect, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:change_events, [:tenant_id, :repo, :change_id, :event_seq])

    # The gap sweep's read: events still waiting, oldest first, across tenants.
    create index(:change_events, [:inserted_at], where: "applied_at IS NULL")

    create constraint(:change_events, :change_events_event_seq_positive, check: "event_seq >= 1")

    create constraint(:change_events, :change_events_repo_canonical, check: "repo = lower(repo)")

    create constraint(:change_events, :change_events_received_via,
             check: "received_via IN ('push', 'pull')"
           )

    enable_rls(:change_events)

    create table(:change_cursors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :source_id, references(:intake_sources, type: :binary_id, on_delete: :delete_all),
        null: false

      add :repo, :string, null: false
      add :change_id, :string, null: false
      add :applied_seq, :bigint, null: false, default: 0
      add :last_event_at, :utc_datetime_usec, null: false
      add :last_pulled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:change_cursors, [:tenant_id, :repo, :change_id])

    # The staleness sweep's read: changes that have gone quiet, across tenants.
    create index(:change_cursors, [:last_event_at])

    create constraint(:change_cursors, :change_cursors_applied_seq_non_negative,
             check: "applied_seq >= 0"
           )

    create constraint(:change_cursors, :change_cursors_repo_canonical,
             check: "repo = lower(repo)"
           )

    enable_rls(:change_cursors)
  end

  def down do
    drop table(:change_cursors)
    drop table(:change_events)
  end
end
