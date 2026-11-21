defmodule Loopctl.Repo.Migrations.WorkItemNotes do
  @moduledoc """
  US-52.17: a work item carries its notes, and `orchestrator_states` is retired.

  ## story_notes

  Append-only notes on a story, by section (`plan`, `progress`, `decision`, `question`),
  written by the item's holder or an orchestrator+ key (`Loopctl.WorkItems.write_note/4`).
  `tenant_id` on every row, RLS ENABLED (not FORCE: the production role owns the table
  without BYPASSRLS). `story_notes_idempotency_uidx` makes a retried write one note.

  ## orchestrator_states

  No MCP tool ever reached it and the fleet's guardrail refuses curl to loopctl, so only the
  CLI or iex wrote it, and every documented key duplicates story or stage state. Each row is
  copied into `audit_log` (`entity_type` project, `action` orchestrator_state_retired) as
  history, then the table is dropped. `audit_log` FORCEs row level security and its INSERT
  policy checks `current_tenant_id()`, which the table owner is held to as well, so the copy
  sets the tenant GUC per tenant, transaction-locally. `down/0` recreates the empty table
  only: the rows are in `audit_log`, which is append-only.
  """

  use Ecto.Migration

  import Loopctl.Repo.RlsHelpers

  def up do
    create table(:story_notes, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :holder_id, references(:holders, type: :binary_id, on_delete: :nothing)
      add :author_api_key_id, :binary_id, null: false
      add :section, :string, null: false
      add :body, :text, null: false
      add :idempotency_key, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:story_notes, :story_notes_section_known,
             check: "section IN ('plan', 'progress', 'decision', 'question')"
           )

    create constraint(:story_notes, :story_notes_body_size,
             check: "octet_length(body) BETWEEN 1 AND 16384"
           )

    create index(:story_notes, [:tenant_id, :story_id, :inserted_at, :id])

    create unique_index(:story_notes, [:tenant_id, :story_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL",
             name: :story_notes_idempotency_uidx
           )

    enable_rls(:story_notes)

    execute("""
    DO $$
    DECLARE
      t uuid;
    BEGIN
      FOR t IN SELECT DISTINCT tenant_id FROM orchestrator_states LOOP
        PERFORM set_config('app.current_tenant_id', t::text, true);

        INSERT INTO audit_log
          (tenant_id, project_id, entity_type, entity_id, action, actor_type, actor_label,
           new_state, metadata)
        SELECT tenant_id, project_id, 'project', project_id, 'orchestrator_state_retired',
               'system', 'migration:20261121060000',
               jsonb_build_object('state_key', state_key, 'version', version,
                                  'state_data', state_data),
               jsonb_build_object('orchestrator_state_id', id,
                                  'inserted_at', inserted_at, 'updated_at', updated_at)
        FROM orchestrator_states
        WHERE tenant_id = t;
      END LOOP;

      PERFORM set_config('app.current_tenant_id', '', true);
    END
    $$;
    """)

    drop table(:orchestrator_states)
  end

  def down do
    create table(:orchestrator_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :state_key, :string, null: false
      add :state_data, :map, null: false, default: %{}
      add :version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:orchestrator_states, [:tenant_id, :project_id, :state_key])
    create index(:orchestrator_states, [:tenant_id])
    create index(:orchestrator_states, [:project_id])
    enable_rls(:orchestrator_states)

    drop table(:story_notes)
  end
end
