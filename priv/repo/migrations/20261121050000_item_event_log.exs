defmodule Loopctl.Repo.Migrations.ItemEventLog do
  @moduledoc """
  US-52.16: `story_stage_events` becomes the work item's whole event log. Every event names
  the holder that acted (`actor_holder_id`, NULL when the system acted) and a reason a person
  can read (`reason`, 1..2000 characters, NOT NULL). Non-stage events (`claimed`, `released`,
  `note_written`) carry no stage row, so `story_stage_id`, `to_stage` and `lock_version`
  become nullable and `story_stage_events_stage_fields` requires all three for the stage
  events only. `idempotency_key` makes a replayed item event a no-op.

  The backfill sets `reason` on existing rows from `data->>'reason'`, else the edge, else the
  event name, before the column becomes NOT NULL. It is one UPDATE over the table, inside the
  migration's transaction; the table is append-only and small enough for that.
  """

  use Ecto.Migration

  @stage_events ~w(opened transitioned effect_recorded rebound merge_gate_unevaluated
                   post_deploy_unresolved merge_instructed runner_absence)
  @item_events ~w(claimed released note_written)

  def up do
    alter table(:story_stage_events) do
      add :actor_holder_id, references(:holders, type: :binary_id, on_delete: :nothing)
      add :reason, :text
      add :idempotency_key, :text
    end

    execute("""
    UPDATE story_stage_events
    SET reason = left(
      COALESCE(NULLIF(btrim(data->>'reason'), ''), edge, event),
      2000
    )
    WHERE reason IS NULL
    """)

    execute("ALTER TABLE story_stage_events ALTER COLUMN reason SET NOT NULL")

    create constraint(:story_stage_events, :story_stage_events_reason_length,
             check: "char_length(reason) BETWEEN 1 AND 2000"
           )

    execute("ALTER TABLE story_stage_events ALTER COLUMN story_stage_id DROP NOT NULL")
    execute("ALTER TABLE story_stage_events ALTER COLUMN to_stage DROP NOT NULL")
    execute("ALTER TABLE story_stage_events ALTER COLUMN lock_version DROP NOT NULL")

    create constraint(:story_stage_events, :story_stage_events_stage_fields,
             check:
               "event NOT IN (#{quoted(@stage_events)}) OR " <>
                 "(story_stage_id IS NOT NULL AND to_stage IS NOT NULL AND " <>
                 "lock_version IS NOT NULL)"
           )

    drop constraint(:story_stage_events, :story_stage_events_event)

    create constraint(:story_stage_events, :story_stage_events_event,
             check: "event IN (#{quoted(@stage_events ++ @item_events)})"
           )

    create unique_index(:story_stage_events, [:tenant_id, :story_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL",
             name: :story_stage_events_idempotency_uidx
           )

    create index(:story_stage_events, [:actor_holder_id], where: "actor_holder_id IS NOT NULL")
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM story_stage_events WHERE event IN (#{quoted(@item_events)})
      ) THEN
        RAISE EXCEPTION 'refusing to roll back: story_stage_events holds claimed, released or note_written rows, the only record of who held and released each story; delete them by hand first';
      END IF;
    END
    $$;
    """)

    drop index(:story_stage_events, [:actor_holder_id])

    drop index(:story_stage_events, [:tenant_id, :story_id, :idempotency_key],
           name: :story_stage_events_idempotency_uidx
         )

    drop constraint(:story_stage_events, :story_stage_events_event)

    create constraint(:story_stage_events, :story_stage_events_event,
             check: "event IN (#{quoted(@stage_events)})"
           )

    drop constraint(:story_stage_events, :story_stage_events_stage_fields)
    execute("ALTER TABLE story_stage_events ALTER COLUMN lock_version SET NOT NULL")
    execute("ALTER TABLE story_stage_events ALTER COLUMN to_stage SET NOT NULL")
    execute("ALTER TABLE story_stage_events ALTER COLUMN story_stage_id SET NOT NULL")
    drop constraint(:story_stage_events, :story_stage_events_reason_length)

    alter table(:story_stage_events) do
      remove :idempotency_key
      remove :reason
      remove :actor_holder_id
    end
  end

  defp quoted(names), do: Enum.map_join(names, ", ", &"'#{&1}'")
end
