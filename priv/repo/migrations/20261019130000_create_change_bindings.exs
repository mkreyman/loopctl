defmodule Loopctl.Repo.Migrations.CreateChangeBindings do
  @moduledoc """
  US-47.1: the join between a story and the chg change that implements it (Epic 47 PRD §4).

  `change_bindings` holds one row per `(tenant_id, repo, change_id)` — a change binds at most one
  story, ever — and at most one CURRENT row per story (`superseded_at IS NULL`), held by a
  partial unique index so the database, not a read-then-write in the context, decides it.

  `unbound_change_events` records a bind that named a `story_id` the tenant does not own. It is a
  table of its own rather than a nullable-story row in `change_bindings` (see
  `Loopctl.Changes.UnboundEvent`): `claimed_story_id` is free text with no foreign key, because a
  foreign key would accept another tenant's story id and reject an unknown one — the existence
  oracle the context exists to deny.
  """

  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def up do
    create table(:change_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :repo, :string, null: false
      add :change_id, :string, null: false
      add :superseded_at, :utc_datetime_usec

      add :submitter_agent_id,
          references(:agents, type: :binary_id, on_delete: :nilify_all)

      add :submitter_not_claimant, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:change_bindings, [:tenant_id, :repo, :change_id])

    create unique_index(:change_bindings, [:tenant_id, :story_id],
             where: "superseded_at IS NULL",
             name: :change_bindings_one_current_per_story
           )

    create index(:change_bindings, [:tenant_id, :story_id, :inserted_at])

    enable_rls(:change_bindings)

    create table(:unbound_change_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :repo, :string, null: false
      add :change_id, :string, null: false
      add :claimed_story_id, :string, null: false

      add :submitter_agent_id,
          references(:agents, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # A redelivered bind records nothing new: one event per (change, claimed id).
    create unique_index(:unbound_change_events, [
             :tenant_id,
             :repo,
             :change_id,
             :claimed_story_id
           ])

    enable_rls(:unbound_change_events)
  end

  def down do
    drop table(:unbound_change_events)
    drop table(:change_bindings)
  end
end
