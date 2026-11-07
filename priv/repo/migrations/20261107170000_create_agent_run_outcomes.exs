defmodule Loopctl.Repo.Migrations.CreateAgentRunOutcomes do
  @moduledoc """
  `agent_run_outcomes` (Epic 48, US-48.12): one row per runner dispatch, keyed by the agent
  spec `{id, version}` it ran under, carrying what later happened to its work.

  ## Core columns are columns, signals are a map

  The identity and the session's own facts — spec, prompt template, story, project, start,
  end, elapsed seconds, turns, cost, end reason — are real columns, because the summary
  aggregates over them. What happened downstream (merge gate decision, CI result, merge,
  review counts, a human override) is `signals`, a jsonb map of
  `signal_name => {"value", "at", "source"}`, so a signal added later needs no migration.
  Each signal is written once, by the system event that proves it (`source` names it).

  `turns` and `cost_millicents` are nullable and stay NULL until a runner message reports
  them: no message on runner contract 1.26.0 carries either.

  ## The unique index is the idempotency

  `(tenant_id, dispatch_id)` makes a redelivered session end or a repeated gate event find
  the row it already wrote. No foreign key on `dispatch_id`: the ledger row is pruned and this
  record must outlive it, as `triage_verdicts` and `reply_drafts` do.

  ## Isolation

  `tenant_id` on every row, RLS ENABLED (not FORCE — the production role owns the table
  without BYPASSRLS), with the same `tenant_isolation` policy as its siblings.

  No backfill and no manual step: the table starts empty and fills from the next dispatch.
  """

  use Ecto.Migration

  def up do
    create table(:agent_run_outcomes, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :dispatch_id, :binary_id, null: false
      add :runner_id, :binary_id
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
      add :kind, :string, null: false
      add :spec_id, :string, null: false
      add :spec_version, :integer, null: false
      add :archetype, :string, null: false
      add :prompt_template_id, :string, null: false
      add :prompt_template_version, :integer, null: false
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :elapsed_s, :integer
      add :turns, :integer
      add :cost_millicents, :bigint
      add :end_reason, :string
      add :signals, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_run_outcomes, [:tenant_id, :dispatch_id],
             name: :agent_run_outcomes_dispatch_uidx
           )

    # The summary: one spec's rows in a window, grouped by version.
    create index(:agent_run_outcomes, [:tenant_id, :spec_id, :inserted_at])

    # The build signals find a story's rows.
    create index(:agent_run_outcomes, [:tenant_id, :story_id])

    create constraint(:agent_run_outcomes, :agent_run_outcomes_archetype,
             check: "archetype IN ('judge', 'build', 'draft')"
           )

    create constraint(:agent_run_outcomes, :agent_run_outcomes_counts,
             check:
               "spec_version > 0 AND prompt_template_version > 0 " <>
                 "AND (elapsed_s IS NULL OR elapsed_s >= 0) " <>
                 "AND (turns IS NULL OR turns >= 0) " <>
                 "AND (cost_millicents IS NULL OR cost_millicents >= 0)"
           )

    create constraint(:agent_run_outcomes, :agent_run_outcomes_signals_object,
             check: "jsonb_typeof(signals) = 'object'"
           )

    execute("ALTER TABLE agent_run_outcomes ENABLE ROW LEVEL SECURITY")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'agent_run_outcomes' AND policyname = 'tenant_isolation'
      ) THEN
        EXECUTE 'CREATE POLICY tenant_isolation ON agent_run_outcomes USING (tenant_id = current_tenant_id())';
      END IF;
    END $$;
    """)
  end

  def down do
    execute("DROP POLICY IF EXISTS tenant_isolation ON agent_run_outcomes")
    drop table(:agent_run_outcomes)
  end
end
